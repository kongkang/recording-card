//! card_bridge —— 统一硬件桥（C ABI 单一入口），同时驱动三款自研蓝牙硬件：
//! - 录音卡 V2（`reai-card-sdk` v0.0.8，广播前缀 `DYJV2_`，IMA-ADPCM 16kHz）
//! - 点一机 V1（`reai-dyj-sdk` v0.1.x，广播前缀 `DYJ_`，AMR-WB 16kHz + 相机媒体 + SoftAP）
//! - 语音 AI 键盘 V2.1（`reai-board-sdk` v0.3.x，广播前缀 `REAI_VB_`，mSBC 16kHz Timeline Lease）
//!
//! 对上层 Dart 保持完全一致的 JSON 回调协议与 16kHz 单声道 i16 PCM 实时流契约。

pub mod amr_transcode;
pub mod capabilities;

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use btleplug::api::{Central as _, Manager as _, Peripheral as _, ScanFilter};
use capabilities::{classify_ble_name, DeviceKind};
use reai_board_sdk::kernel::audio::{
    AudioFrame, AudioStreamAction, AudioStreamScope, AudioTransport,
};
use reai_board_sdk::kernel::sink::AudioFrameSink;
use reai_board_sdk::{BoardConfig, BoardDevice, BoardEvent};
use reai_card_sdk::{
    DeviceEvent as CardV2Event, DeviceManager as CardV2Manager, DfuPackage,
    DyjDevice as CardV2Device, OtaInfo, OtaModule, SdkError as CardSdkError,
};
use reai_dyj_sdk::{
    ApClient as DyjV1ApClient, DeviceEvent as DyjV1Event, DeviceManager as DyjV1Manager,
    DyjDevice as DyjV1Device, ServerClient as DyjV1ServerClient,
};
use serde_json::{json, Value};

/// Dart 注册的回调：`fn(user_data, json_utf8_ptr)`。
type Callback = extern "C" fn(user_data: *mut c_void, json: *const c_char);

#[derive(Clone, Debug)]
struct CachedScanEntry {
    name: String,
    kind: DeviceKind,
}

#[derive(Clone, Debug)]
struct BoardPcmChunk {
    samples: Vec<i16>,
    sample_rate: u32,
    channels: u8,
    discontinuous: bool,
}

struct BoardAudioForwarder {
    tx: tokio::sync::broadcast::Sender<BoardPcmChunk>,
}

impl AudioFrameSink for BoardAudioForwarder {
    fn on_audio_frame(&self, frame: AudioFrame<'_>) {
        if frame.pcm.is_empty() {
            return;
        }
        let samples: Vec<i16> = frame
            .pcm
            .iter()
            .map(|&s| (s.clamp(-1.0, 1.0) * 32767.0) as i16)
            .collect();
        let _ = self.tx.send(BoardPcmChunk {
            samples,
            sample_rate: frame.sample_rate,
            channels: frame.channels,
            discontinuous: frame.discontinuity(),
        });
    }
}

#[derive(Clone)]
enum ActiveDevice {
    CardV2 {
        device: CardV2Device,
        name: String,
    },
    DyjV1 {
        device: DyjV1Device,
        name: String,
        device_id_meta: Arc<Mutex<Option<String>>>,
    },
    BoardV21 {
        board: Arc<BoardDevice>,
        name: String,
        audio_tx: tokio::sync::broadcast::Sender<BoardPcmChunk>,
        recording: Arc<AtomicBool>,
        cached_info: Arc<Mutex<Option<reai_board_sdk::kernel::event::DeviceInfo>>>,
    },
}

impl ActiveDevice {
    fn kind(&self) -> DeviceKind {
        match self {
            Self::CardV2 { .. } => DeviceKind::CardV2,
            Self::DyjV1 { .. } => DeviceKind::DyjV1,
            Self::BoardV21 { .. } => DeviceKind::BoardV21,
        }
    }
}

struct BridgeState {
    runtime: tokio::runtime::Runtime,
    device: tokio::sync::Mutex<Option<ActiveDevice>>,
    scan_adapter: tokio::sync::OnceCell<btleplug::platform::Adapter>,
    card_v2_manager: tokio::sync::OnceCell<CardV2Manager>,
    dyj_v1_manager: tokio::sync::OnceCell<DyjV1Manager>,
    scan_cache: Mutex<HashMap<String, CachedScanEntry>>,
    event_pump: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    last_device_id: Mutex<Option<String>>,
    realtime_stop: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    board_lease_seq: AtomicU32,
    events: Mutex<EventFeed>,
}

/// 事件队列：单调递增 seq + 最近 N 条，Dart 侧用 seq 做增量读（零蓝牙开销）。
struct EventFeed {
    seq: u64,
    items: std::collections::VecDeque<Value>,
}

impl EventFeed {
    fn new() -> Self {
        Self {
            seq: 0,
            items: std::collections::VecDeque::new(),
        }
    }

    fn push(&mut self, value: Value) {
        self.seq += 1;
        self.items.push_back(json!({"seq": self.seq, "event": value}));
        while self.items.len() > 64 {
            self.items.pop_front();
        }
    }

    fn since(&self, after: u64) -> Value {
        let items: Vec<Value> = self
            .items
            .iter()
            .filter(|item| {
                item.get("seq")
                    .and_then(Value::as_u64)
                    .map(|s| s > after)
                    .unwrap_or(false)
            })
            .cloned()
            .collect();
        json!({"seq": self.seq, "events": items})
    }
}

static STATE: OnceLock<BridgeState> = OnceLock::new();
static VERSION: &str = concat!(
    "card_bridge/",
    env!("CARGO_PKG_VERSION"),
    " card-v2/0.0.8 dyj-v1/0.1 board-v21/0.3"
);

fn state() -> &'static BridgeState {
    STATE.get_or_init(|| BridgeState {
        runtime: tokio::runtime::Builder::new_multi_thread()
            .worker_threads(3)
            .enable_all()
            .build()
            .expect("tokio runtime"),
        device: tokio::sync::Mutex::new(None),
        scan_adapter: tokio::sync::OnceCell::new(),
        card_v2_manager: tokio::sync::OnceCell::new(),
        dyj_v1_manager: tokio::sync::OnceCell::new(),
        scan_cache: Mutex::new(HashMap::new()),
        event_pump: tokio::sync::Mutex::new(None),
        last_device_id: Mutex::new(None),
        realtime_stop: Mutex::new(None),
        board_lease_seq: AtomicU32::new(1),
        events: Mutex::new(EventFeed::new()),
    })
}

fn emit_raw(cb: Callback, user_data: usize, value: Value) {
    let json = CString::new(value.to_string()).expect("no NUL in json");
    cb(user_data as *mut c_void, json.into_raw());
}

struct BridgeError {
    message: String,
    detail: Option<Value>,
}

impl From<CardSdkError> for BridgeError {
    fn from(e: CardSdkError) -> Self {
        Self {
            message: e.to_string(),
            detail: None,
        }
    }
}

impl From<reai_dyj_sdk::SdkError> for BridgeError {
    fn from(e: reai_dyj_sdk::SdkError) -> Self {
        Self {
            message: e.to_string(),
            detail: None,
        }
    }
}

impl From<String> for BridgeError {
    fn from(message: String) -> Self {
        Self {
            message,
            detail: None,
        }
    }
}

impl BridgeError {
    fn disconnected() -> Self {
        Self {
            message: CardSdkError::Disconnected.to_string(),
            detail: None,
        }
    }
}

#[derive(Clone, Copy)]
struct Emitter {
    cb: Callback,
    user_data: usize,
}

impl Emitter {
    fn progress(&self, value: Value) {
        emit_raw(
            self.cb,
            self.user_data,
            json!({"ok": true, "progress": value, "final": false}),
        );
    }

    fn ok(&self, value: Value) {
        emit_raw(
            self.cb,
            self.user_data,
            json!({"ok": true, "data": value, "final": true}),
        );
    }

    fn fail(&self, error: impl std::fmt::Display) {
        emit_raw(
            self.cb,
            self.user_data,
            json!({"ok": false, "error": error.to_string(), "final": true}),
        );
    }

    fn fail_detail(&self, message: String, detail: Option<Value>) {
        emit_raw(
            self.cb,
            self.user_data,
            json!({"ok": false, "error": message, "detail": detail, "final": true}),
        );
    }
}

// ── C ABI ───────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn card_bridge_version() -> *const c_char {
    static V: OnceLock<CString> = OnceLock::new();
    V.get_or_init(|| CString::new(VERSION).expect("no NUL"))
        .as_ptr()
}

/// # Safety
/// `ptr` 必须是本库 `CString::into_raw` 交出且尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn card_bridge_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// # Safety
/// `cb` 必须是有效的 Dart NativeCallable 入口；`kind` / `payload` 为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn card_bridge_command(
    kind: *const c_char,
    payload: *const c_char,
    cb: Callback,
    user_data: *mut c_void,
) {
    let kind = cstr(kind);
    let payload: Value = if payload.is_null() {
        Value::Null
    } else {
        serde_json::from_str(&cstr(payload)).unwrap_or(Value::Null)
    };
    let emitter = Emitter {
        cb,
        user_data: user_data as usize,
    };
    state().runtime.spawn(async move {
        if let Err(error) = dispatch(&kind, payload, emitter).await {
            if error.detail.is_some() {
                emitter.fail_detail(error.message, error.detail);
            } else {
                emitter.fail(error.message);
            }
        }
    });
}

// ── 命令分发 ────────────────────────────────────────────────

async fn dispatch(kind: &str, payload: Value, out: Emitter) -> Result<(), BridgeError> {
    match kind {
        "scan" => {
            let timeout = payload
                .get("timeoutMs")
                .and_then(Value::as_u64)
                .unwrap_or(5000);
            let devices = unified_scan(Duration::from_millis(timeout)).await?;
            out.ok(Value::Array(devices));
        }
        "connect" => out.ok(connect_device(payload).await?),
        "disconnect" => out.ok(release_device().await),
        "snapshot" => {
            let active = active_device().await?;
            out.ok(snapshot_device(&active).await?);
        }
        "record" => {
            let action = payload
                .get("action")
                .and_then(Value::as_str)
                .unwrap_or("toggle");
            let active = active_device().await?;
            out.ok(record_action(&active, action).await?);
        }
        "record.start" => {
            let duration_secs = payload
                .get("durationSecs")
                .or_else(|| payload.get("duration"))
                .and_then(Value::as_u64)
                .map(|v| v.min(u32::MAX as u64) as u32);
            let active = active_device().await?;
            out.ok(record_start(&active, duration_secs).await?);
        }
        "record.stop" => {
            let active = active_device().await?;
            out.ok(record_stop(&active).await?);
        }
        "mark" => {
            let active = active_device().await?;
            out.ok(record_mark(&active).await?);
        }
        "events.pull" => {
            let after = payload.get("after").and_then(Value::as_u64).unwrap_or(0);
            let feed = state().events.lock().expect("events lock");
            out.ok(feed.since(after));
        }
        "realtime.open" => realtime_open(out).await?,
        "realtime.close" => {
            let stop = state().realtime_stop.lock().expect("realtime lock").take();
            if let Some(stop) = stop {
                let _ = stop.send(());
            }
            out.ok(json!({"closed": true}));
        }
        "files" => {
            let active = active_device().await?;
            out.ok(list_device_files(&active).await?);
        }
        "download" => {
            let name = str_field(&payload, "name");
            let dir = str_field(&payload, "dir");
            let active = active_device().await?;
            out.ok(download_device_file(&active, &name, &dir).await?);
        }
        "file.takeOldest" | "takeOldest" => {
            let dir = str_field(&payload, "dir");
            let active = active_device().await?;
            out.ok(take_oldest_device_file(&active, &dir).await?);
        }
        "deleteFile" => {
            let name = str_field(&payload, "name");
            let active = active_device().await?;
            out.ok(delete_device_file(&active, &name).await?);
        }
        "camera.list" => {
            let active = active_device().await?;
            out.ok(camera_list(&active).await?);
        }
        "camera.sync" => {
            let dir = str_field(&payload, "dir");
            let server_origin = payload
                .get("serverOrigin")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let active = active_device().await?;
            out.ok(camera_sync(&active, &dir, server_origin.as_deref()).await?);
        }
        "wifi.scan" => {
            let active = active_device().await?;
            out.ok(wifi_scan(&active).await?);
        }
        "wifi.connect" => {
            let ssid = str_field(&payload, "ssid");
            let password = str_field(&payload, "password");
            let active = active_device().await?;
            out.ok(wifi_connect(&active, &ssid, &password).await?);
        }
        "wifi.open" => {
            let active = active_device().await?;
            out.ok(wifi_open(&active).await?);
        }
        "wifi.close" => {
            let active = active_device().await?;
            out.ok(wifi_close(&active).await?);
        }
        "wifi.credentials" => {
            let active = active_device().await?;
            out.ok(wifi_credentials(&active).await?);
        }
        "wifi.forget" => {
            let ssid = str_field(&payload, "ssid");
            let active = active_device().await?;
            out.ok(wifi_forget(&active, &ssid).await?);
        }
        "sync.start" => {
            let active = active_device().await?;
            out.ok(sync_start(&active).await?);
        }
        "sync.status" => {
            let active = active_device().await?;
            out.ok(sync_status(&active).await?);
        }
        "upload.setUrl" => {
            let url = str_field(&payload, "url");
            let active = active_device().await?;
            out.ok(upload_set_url(&active, &url).await?);
        }
        "ap.start" => {
            let ssid = payload
                .get("ssid")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let password = payload
                .get("password")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let active = active_device().await?;
            out.ok(ap_start(&active, ssid.as_deref(), password.as_deref()).await?);
        }
        "ap.stop" => {
            let active = active_device().await?;
            out.ok(ap_stop(&active).await?);
        }
        "time.sync" => {
            let active = active_device().await?;
            out.ok(time_sync(&active).await?);
        }
        "transcode" => {
            let src = str_field(&payload, "apm");
            let wav = str_field(&payload, "wav");
            let src_path = Path::new(&src);
            let wav_path = Path::new(&wav);
            let head = tokio::fs::read(src_path)
                .await
                .map(|b| b.into_iter().take(16).collect::<Vec<u8>>())
                .unwrap_or_default();
            if amr_transcode::is_amr_wb_file(src_path, &head) {
                let result = amr_transcode::amr_wb_to_wav(src_path, wav_path).await?;
                out.ok(json!({
                    "path": wav,
                    "samples": result.samples,
                    "durationSecs": result.duration_secs,
                }));
            } else {
                let result = reai_card_sdk::apm_to_wav(src_path, wav_path).await?;
                out.ok(json!({
                    "path": result.path.to_string_lossy(),
                    "samples": result.samples,
                    "durationSecs": result.duration_secs(),
                }));
            }
        }
        "ota.info" => out.ok(ota_info(&payload).await?),
        "ota.main" => ota_main(payload, out).await?,
        "ota.wifi" => ota_wifi(payload, out).await?,
        other => {
            return Err(BridgeError::from(format!("unknown command: {other}")));
        }
    }
    Ok(())
}

// ── 统一扫描与连接 ────────────────────────────────────────────

async fn scan_adapter() -> Result<&'static btleplug::platform::Adapter, BridgeError> {
    state()
        .scan_adapter
        .get_or_try_init(|| async {
            let manager = btleplug::platform::Manager::new()
                .await
                .map_err(|e| BridgeError::from(format!("BLE unavailable: {e}")))?;
            let adapter = manager
                .adapters()
                .await
                .map_err(|e| BridgeError::from(format!("BLE adapters failed: {e}")))?
                .into_iter()
                .next()
                .ok_or_else(|| BridgeError::from("no Bluetooth adapter available".to_string()))?;
            Ok(adapter)
        })
        .await
}

async fn card_v2_manager() -> Result<&'static CardV2Manager, BridgeError> {
    state()
        .card_v2_manager
        .get_or_try_init(CardV2Manager::new)
        .await
        .map_err(BridgeError::from)
}

async fn dyj_v1_manager() -> Result<&'static DyjV1Manager, BridgeError> {
    state()
        .dyj_v1_manager
        .get_or_try_init(DyjV1Manager::new)
        .await
        .map_err(BridgeError::from)
}

/// 单次 BLE 扫描同时发现录音卡 V2 (`DYJV2_`)、点一机 V1 (`DYJ_`) 与语音 AI 键盘 V2.1 (`REAI_VB_`)。
async fn unified_scan(duration: Duration) -> Result<Vec<Value>, BridgeError> {
    let adapter = scan_adapter().await?;
    adapter
        .start_scan(ScanFilter::default())
        .await
        .map_err(|e| BridgeError::from(format!("BLE start_scan failed: {e}")))?;
    tokio::time::sleep(duration).await;
    let _ = adapter.stop_scan().await;

    let peripherals = adapter
        .peripherals()
        .await
        .map_err(|e| BridgeError::from(format!("BLE peripherals failed: {e}")))?;

    let mut discovered: Vec<(i16, String, Value)> = Vec::new();
    let mut cache_updates: Vec<(String, CachedScanEntry)> = Vec::new();

    for p in peripherals {
        let Ok(Some(props)) = p.properties().await else {
            continue;
        };
        let Some(raw_name) = props.local_name else {
            continue;
        };
        let name = raw_name.trim().to_string();
        let Some((kind, caps)) = classify_ble_name(&name) else {
            continue;
        };
        // CoreBluetooth 本地缓存但未广播的旧外设通常无 RSSI；若已系统连接则仍展示
        let is_conn = p.is_connected().await.unwrap_or(false);
        let rssi = match props.rssi {
            Some(r) => r,
            None if is_conn => -58,
            None => continue,
        };
        let id = p.id().to_string();
        cache_updates.push((
            id.clone(),
            CachedScanEntry {
                name: name.clone(),
                kind,
            },
        ));
        discovered.push((
            rssi,
            id.clone(),
            json!({
                "id": id,
                "name": name,
                "rssi": rssi,
                "deviceKind": kind.as_str(),
                "displayModel": kind.display_model(),
                "capabilities": caps,
            }),
        ));
    }

    {
        let mut cache = state().scan_cache.lock().expect("scan cache lock");
        for (id, entry) in cache_updates {
            cache.insert(id, entry);
        }
    }

    // 去重（同名保留信号最强的一条），按 RSSI 从强到弱排序
    discovered.sort_by(|a, b| b.0.cmp(&a.0));
    let mut seen_ids = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(discovered.len());
    for (_, id, val) in discovered {
        if seen_ids.insert(id) {
            out.push(val);
        }
    }
    Ok(out)
}

async fn connect_device(payload: Value) -> Result<Value, BridgeError> {
    let id = str_field(&payload, "id");
    let explicit_name = payload
        .get("name")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    let explicit_kind = payload.get("deviceKind").and_then(Value::as_str);

    let cached = state()
        .scan_cache
        .lock()
        .expect("scan cache lock")
        .get(&id)
        .cloned();
    let target_name = explicit_name.or_else(|| cached.as_ref().map(|c| c.name.clone()));
    let target_kind = DeviceKind::from_hint(explicit_kind, target_name.as_deref())
        .or_else(|| cached.as_ref().map(|c| c.kind))
        .unwrap_or(DeviceKind::CardV2);

    release_device().await;

    match target_kind {
        DeviceKind::CardV2 => connect_card_v2(&id, target_name.as_deref()).await,
        DeviceKind::DyjV1 => {
            let name = target_name.ok_or_else(|| {
                BridgeError::from(format!("点一机 V1 连接需要设备广播名称（id={id}）"))
            })?;
            connect_dyj_v1(&id, &name).await
        }
        DeviceKind::BoardV21 => {
            let name = target_name.ok_or_else(|| {
                BridgeError::from(format!("语音 AI 键盘连接需要设备广播名称（id={id}）"))
            })?;
            connect_board_v21(&id, &name).await
        }
    }
}

async fn connect_card_v2(id: &str, name_hint: Option<&str>) -> Result<Value, BridgeError> {
    let manager = card_v2_manager().await?;
    let mut found = None;
    for window in [Duration::from_secs(4), Duration::from_secs(6)] {
        let devices = manager.scan(window).await?;
        if let Some(d) = devices
            .iter()
            .find(|d| d.id == id || name_hint.is_some_and(|nh| d.name == nh))
            .cloned()
        {
            found = Some(d);
            break;
        }
    }
    let found = found.ok_or_else(|| CardSdkError::DeviceNotFound(id.to_string()))?;
    let connected_name = found.name.clone();
    let device = manager.connect(&found).await?;
    let pump = spawn_card_v2_event_pump(&device);
    *state().event_pump.lock().await = Some(pump);
    *state().last_device_id.lock().expect("device id lock") = Some(id.to_string());
    *state().device.lock().await = Some(ActiveDevice::CardV2 {
        device,
        name: connected_name.clone(),
    });
    Ok(json!({
        "connected": true,
        "name": connected_name,
        "deviceKind": DeviceKind::CardV2.as_str(),
        "displayModel": DeviceKind::CardV2.display_model(),
        "capabilities": DeviceKind::CardV2.capabilities(),
    }))
}

async fn connect_dyj_v1(id: &str, name: &str) -> Result<Value, BridgeError> {
    let manager = dyj_v1_manager().await?;
    let device = match manager.connect_by_name(name).await {
        Ok(d) => d,
        Err(_) => manager.connect_by_name(name).await?,
    };
    // auto_audio=false：连上时不自动推流，等用户打开录音开关再开启实时流
    let _ = device.hello("recording-card", false).await;
    let device_id_meta = Arc::new(Mutex::new(None));
    if let Ok(info) = device.device_info(false).await {
        if let Some(did) = info.get("device_id").and_then(Value::as_str) {
            *device_id_meta.lock().unwrap() = Some(did.to_string());
        }
    }
    let pump = spawn_dyj_v1_event_pump(&device);
    *state().event_pump.lock().await = Some(pump);
    *state().last_device_id.lock().expect("device id lock") = Some(id.to_string());
    *state().device.lock().await = Some(ActiveDevice::DyjV1 {
        device,
        name: name.to_string(),
        device_id_meta,
    });
    Ok(json!({
        "connected": true,
        "name": name,
        "deviceKind": DeviceKind::DyjV1.as_str(),
        "displayModel": DeviceKind::DyjV1.display_model(),
        "capabilities": DeviceKind::DyjV1.capabilities(),
    }))
}

async fn connect_board_v21(id: &str, name: &str) -> Result<Value, BridgeError> {
    let board = Arc::new(
        BoardDevice::open(BoardConfig::default())
            .map_err(|e| BridgeError::from(format!("打开键盘 SDK 失败: {e}")))?,
    );
    let (audio_tx, _) = tokio::sync::broadcast::channel::<BoardPcmChunk>(256);
    board.set_audio_frame_sink(Arc::new(BoardAudioForwarder {
        tx: audio_tx.clone(),
    }));
    let mut rx = board.subscribe();
    board
        .start()
        .await
        .map_err(|e| BridgeError::from(format!("启动键盘 BLE 服务失败: {e}")))?;
    board.connect_ble(name);

    let cached_info: Arc<Mutex<Option<reai_board_sdk::kernel::event::DeviceInfo>>> = Arc::new(Mutex::new(None));
    let deadline = tokio::time::Instant::now() + Duration::from_secs(14);
    let mut connected = board.is_connected();
    while !connected && tokio::time::Instant::now() < deadline {
        let remain = deadline.saturating_duration_since(tokio::time::Instant::now());
        match tokio::time::timeout(remain.min(Duration::from_millis(600)), rx.recv()).await {
            Ok(Ok(BoardEvent::Connection(c))) if c.connected => {
                connected = true;
                break;
            }
            Ok(Ok(BoardEvent::DeviceInfo(info))) => {
                *cached_info.lock().unwrap() = Some(info);
                connected = true;
                break;
            }
            Ok(Ok(BoardEvent::HostBinding(b))) => {
                board.shutdown();
                return Err(BridgeError::from(format!(
                    "该语音键盘已绑定其他主机（{b:?}），请先通过 USB 重绑或解绑"
                )));
            }
            _ => {
                if board.is_connected() {
                    connected = true;
                    break;
                }
            }
        }
    }

    if !connected {
        let _ = board.disconnect_ble().await;
        board.shutdown();
        return Err(BridgeError::from(format!(
            "连接语音 AI 键盘 {name} 超时，请确认键盘电源已开且在蓝牙范围内"
        )));
    }

    let recording = Arc::new(AtomicBool::new(false));
    let pump = spawn_board_event_pump(&board, cached_info.clone());
    *state().event_pump.lock().await = Some(pump);
    *state().last_device_id.lock().expect("device id lock") = Some(id.to_string());
    *state().device.lock().await = Some(ActiveDevice::BoardV21 {
        board,
        name: name.to_string(),
        audio_tx,
        recording,
        cached_info,
    });
    Ok(json!({
        "connected": true,
        "name": name,
        "deviceKind": DeviceKind::BoardV21.as_str(),
        "displayModel": DeviceKind::BoardV21.display_model(),
        "capabilities": DeviceKind::BoardV21.capabilities(),
    }))
}

async fn active_device() -> Result<ActiveDevice, BridgeError> {
    let guard = state().device.lock().await;
    guard.as_ref().cloned().ok_or_else(BridgeError::disconnected)
}

async fn release_device() -> Value {
    if let Some(pump) = state().event_pump.lock().await.take() {
        pump.abort();
    }
    let stop = state().realtime_stop.lock().expect("realtime lock").take();
    if let Some(stop) = stop {
        let _ = stop.send(());
    }
    let active = state().device.lock().await.take();
    let device_id = state().last_device_id.lock().expect("device id lock").take();
    let had_device = active.is_some();
    let sdk = match active {
        Some(ActiveDevice::CardV2 { device, .. }) => {
            match tokio::time::timeout(Duration::from_secs(8), device.disconnect()).await {
                Ok(Ok(())) => json!("ok"),
                Ok(Err(error)) => json!(format!("error: {error}")),
                Err(_) => json!("timeout"),
            }
        }
        Some(ActiveDevice::DyjV1 { device, .. }) => {
            match tokio::time::timeout(Duration::from_secs(8), device.disconnect()).await {
                Ok(Ok(())) => json!("ok"),
                Ok(Err(error)) => json!(format!("error: {error}")),
                Err(_) => json!("timeout"),
            }
        }
        Some(ActiveDevice::BoardV21 { board, .. }) => {
            board.stop_local_audio_reader();
            let res = match tokio::time::timeout(Duration::from_secs(6), board.disconnect_ble()).await
            {
                Ok(Ok(())) => json!("ok"),
                Ok(Err(error)) => json!(format!("error: {error}")),
                Err(_) => json!("timeout"),
            };
            board.shutdown();
            res
        }
        None => Value::Null,
    };
    let released = !had_device || sdk == json!("ok");
    eprintln!(
        "[card_bridge] disconnect had_device={had_device} id={device_id:?} sdk={sdk} released={released}"
    );
    json!({
        "disconnected": true,
        "hadDevice": had_device,
        "deviceId": device_id,
        "sdk": sdk,
        "released": released,
    })
}

// ── 事件泵（三款硬件归一为统一语义事件） ────────────────────────

fn spawn_card_v2_event_pump(device: &CardV2Device) -> tokio::task::JoinHandle<()> {
    let mut events = device.subscribe_events();
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(event) => {
                    let value = match event {
                        CardV2Event::RecordStatus(status) => serde_json::to_value(&status)
                            .map(|v| json!({"kind": "record", "status": v}))
                            .unwrap_or(Value::Null),
                        CardV2Event::ToggleSwitch(_) => json!({"kind": "toggle_switch"}),
                        CardV2Event::Button(_) => json!({"kind": "button"}),
                        CardV2Event::Power(power) => serde_json::to_value(&power)
                            .map(|v| json!({"kind": "power", "power": v}))
                            .unwrap_or(Value::Null),
                        CardV2Event::Sync(sync) => serde_json::to_value(&sync)
                            .map(|v| json!({"kind": "sync", "sync": v}))
                            .unwrap_or(Value::Null),
                        CardV2Event::UploadComplete(_) => json!({"kind": "upload_complete"}),
                        _ => continue,
                    };
                    if !value.is_null() {
                        state().events.lock().expect("events lock").push(value);
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    })
}

fn spawn_dyj_v1_event_pump(device: &DyjV1Device) -> tokio::task::JoinHandle<()> {
    let mut events = device.subscribe_events();
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(DyjV1Event::Event { evt, ts, data }) => {
                    let value = match evt.as_str() {
                        "record.segment" => json!({
                            "kind": "record_segment",
                            "ts": ts,
                            "data": data,
                        }),
                        "button.event" => {
                            let btn_type = data.get("type").and_then(Value::as_str).unwrap_or("");
                            if matches!(btn_type, "click" | "double_click" | "long_press_start") {
                                json!({"kind": "button", "gesture": btn_type, "ts": ts})
                            } else {
                                continue;
                            }
                        }
                        "camera.segment" | "camera.capture" => json!({
                            "kind": "camera",
                            "evt": evt,
                            "ts": ts,
                            "data": data,
                        }),
                        "upload.state" => {
                            let st = data.get("state").and_then(Value::as_str).unwrap_or("");
                            if st == "done" {
                                json!({"kind": "upload_complete", "data": data})
                            } else {
                                json!({"kind": "sync", "sync": data})
                            }
                        }
                        _ if evt.starts_with("battery.") => json!({
                            "kind": "power",
                            "power": data,
                        }),
                        _ => continue,
                    };
                    state().events.lock().expect("events lock").push(value);
                }
                Ok(DyjV1Event::Disconnected) => {
                    state()
                        .events
                        .lock()
                        .expect("events lock")
                        .push(json!({"kind": "disconnected"}));
                    break;
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    })
}

fn spawn_board_event_pump(
    board: &BoardDevice,
    cached_info: Arc<Mutex<Option<reai_board_sdk::kernel::event::DeviceInfo>>>,
) -> tokio::task::JoinHandle<()> {
    let mut events = board.subscribe();
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(BoardEvent::DeviceInfo(info)) => {
                    let level = info.battery_level;
                    let charging = info.battery_charging;
                    *cached_info.lock().unwrap() = Some(info);
                    state().events.lock().expect("events lock").push(json!({
                        "kind": "power",
                        "power": {
                            "charging": charging,
                            "level": level,
                        }
                    }));
                }
                Ok(BoardEvent::AiVoiceKey(ev)) => {
                    if ev.pressed {
                        state().events.lock().expect("events lock").push(json!({
                            "kind": "voice_key",
                            "pressed": true,
                        }));
                    }
                }
                Ok(BoardEvent::Connection(c)) if !c.connected => {
                    state()
                        .events
                        .lock()
                        .expect("events lock")
                        .push(json!({"kind": "disconnected"}));
                    break;
                }
                Ok(_) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    })
}

// ── 状态快照与录音控制 ──────────────────────────────────────────

async fn snapshot_device(active: &ActiveDevice) -> Result<Value, BridgeError> {
    let kind = active.kind();
    match active {
        ActiveDevice::CardV2 { device, name } => {
            let battery = match device.battery().await {
                Ok(v) => serde_json::to_value(v).unwrap_or(Value::Null),
                Err(_) => device
                    .raw_command("BATTERY", None)
                    .await
                    .unwrap_or(Value::Null),
            };
            let state_val = match device.state().await {
                Ok(v) => serde_json::to_value(v).unwrap_or(Value::Null),
                Err(_) => device
                    .raw_command("STATE_INFO", None)
                    .await
                    .unwrap_or(Value::Null),
            };
            let info = match device.device_info().await {
                Ok(v) => serde_json::to_value(v).unwrap_or(Value::Null),
                Err(_) => device
                    .raw_command("BASE_INFO", None)
                    .await
                    .unwrap_or(Value::Null),
            };
            let storage = device.storage().await.ok();
            let record = device.record_status().await.ok();
            Ok(json!({
                "deviceKind": kind.as_str(),
                "displayModel": kind.display_model(),
                "deviceName": name,
                "capabilities": kind.capabilities(),
                "battery": battery,
                "state": state_val,
                "info": info,
                "storage": storage,
                "record": record,
            }))
        }
        ActiveDevice::DyjV1 {
            device,
            name,
            device_id_meta,
        } => {
            let batt_raw = device.battery().await.unwrap_or(Value::Null);
            let level = batt_raw.get("level").and_then(Value::as_u64);
            let status_str = batt_raw
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("");
            let plugged = batt_raw.get("plugged").and_then(Value::as_i64).unwrap_or(0);
            let charging = status_str == "charging" || plugged != 0;

            let info_raw = device.device_info(false).await.unwrap_or(Value::Null);
            if let Some(did) = info_raw.get("device_id").and_then(Value::as_str) {
                *device_id_meta.lock().unwrap() = Some(did.to_string());
            }
            let fw = info_raw
                .get("app_version")
                .and_then(Value::as_str)
                .unwrap_or("");

            let stor_raw = device.storage().await.unwrap_or(Value::Null);
            let total_bytes = stor_raw.get("data_total_bytes").and_then(Value::as_u64);
            let free_bytes = stor_raw.get("data_free_bytes").and_then(Value::as_u64);
            let used_bytes = match (total_bytes, free_bytes) {
                (Some(t), Some(f)) => Some(t.saturating_sub(f)),
                _ => None,
            };

            let rec_raw = device.record_status().await.unwrap_or(Value::Null);
            let recording = rec_raw
                .get("recording")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let cam_raw = device.camera_status().await.unwrap_or(Value::Null);
            let wifi_raw = device.wifi_status().await.unwrap_or(Value::Null);

            Ok(json!({
                "deviceKind": kind.as_str(),
                "displayModel": kind.display_model(),
                "deviceName": name,
                "capabilities": kind.capabilities(),
                "battery": {
                    "level": level,
                    "charging": charging,
                },
                "state": {
                    "recording": recording,
                    "wifiEnabled": wifi_raw.get("wifi_enabled").and_then(Value::as_bool).unwrap_or(false),
                },
                "info": {
                    "firmwareVersion": fw,
                    "deviceId": info_raw.get("device_id"),
                    "model": info_raw.get("model"),
                },
                "storage": {
                    "totalBytes": total_bytes,
                    "freeBytes": free_bytes,
                    "usedBytes": used_bytes,
                },
                "record": {
                    "recording": recording,
                    "currentFile": rec_raw.get("current_file"),
                    "files": rec_raw.get("files"),
                },
                "camera": cam_raw,
            }))
        }
        ActiveDevice::BoardV21 {
            board,
            name,
            recording,
            cached_info,
            ..
        } => {
            if !board.is_connected() {
                return Err(BridgeError::disconnected());
            }
            let info = match board.read_device_info().await {
                Ok(fresh) => {
                    *cached_info.lock().unwrap() = Some(fresh.clone());
                    Some(fresh)
                }
                Err(_) => cached_info.lock().unwrap().clone(),
            };
            let is_rec = recording.load(Ordering::SeqCst);
            let (level, charging, fw) = match info {
                Some(i) => (
                    Some(i.battery_level),
                    i.battery_charging,
                    i.firmware_version,
                ),
                None => (None, false, String::new()),
            };
            Ok(json!({
                "deviceKind": kind.as_str(),
                "displayModel": kind.display_model(),
                "deviceName": name,
                "capabilities": kind.capabilities(),
                "battery": {
                    "level": level,
                    "charging": charging,
                },
                "state": {
                    "recording": is_rec,
                },
                "info": {
                    "firmwareVersion": fw,
                },
                "storage": Value::Null,
                "record": {
                    "recording": is_rec,
                },
            }))
        }
    }
}

async fn record_action(active: &ActiveDevice, action: &str) -> Result<Value, BridgeError> {
    match action {
        "start" => record_start(active, None).await,
        "stop" => record_stop(active).await,
        _ => match active {
            ActiveDevice::CardV2 { device, .. } => {
                let result = device.toggle_recording().await.and_then(to_value);
                if let Err(error) = &result {
                    let probe = device.record_status().await.ok();
                    let st = device.state().await.ok();
                    return Err(BridgeError {
                        message: error.to_string(),
                        detail: Some(json!({
                            "command": "RECORD",
                            "action": action,
                            "record": probe,
                            "state": st,
                        })),
                    });
                }
                result.map_err(BridgeError::from)
            }
            ActiveDevice::DyjV1 { device, .. } => {
                let rec = device
                    .record_status()
                    .await
                    .ok()
                    .and_then(|v| v.get("recording").and_then(Value::as_bool))
                    .unwrap_or(false);
                if rec {
                    record_stop(active).await
                } else {
                    record_start(active, None).await
                }
            }
            ActiveDevice::BoardV21 { recording, .. } => {
                let prev = recording.load(Ordering::SeqCst);
                if prev {
                    record_stop(active).await
                } else {
                    record_start(active, None).await
                }
            }
        },
    }
}

async fn ensure_sd_on_nrf(device: &CardV2Device) {
    if device.state().await.map(|s| s.wifi_open).unwrap_or(false) {
        let _ = tokio::time::timeout(Duration::from_secs(6), device.close_wifi()).await;
    }
}

async fn record_start(
    active: &ActiveDevice,
    duration_secs: Option<u32>,
) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            ensure_sd_on_nrf(device).await;
            let resp = match duration_secs.filter(|&d| d > 0) {
                Some(secs) => device.start_recording_with_duration(secs).await?,
                None => device.start_recording().await?,
            };
            Ok(to_value(resp)?)
        }
        ActiveDevice::DyjV1 { device, .. } => {
            let _ = device.audio_capture_start().await;
            let mins = duration_secs
                .filter(|&d| d > 0)
                .map(|d| u64::from(d.div_ceil(60).max(1)))
                .or(Some(5));
            Ok(device.record_start(mins, None).await?)
        }
        ActiveDevice::BoardV21 {
            board, recording, ..
        } => {
            if !board.is_connected() {
                return Err(BridgeError::disconnected());
            }
            recording.store(true, Ordering::SeqCst);
            Ok(json!({"recording": true, "mode": "stream_only"}))
        }
    }
}

async fn record_stop(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.raw_command("RECORD_STOP", None).await?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.record_stop().await?),
        ActiveDevice::BoardV21 {
            board, recording, ..
        } => {
            recording.store(false, Ordering::SeqCst);
            board.stop_local_audio_reader();
            Ok(json!({"recording": false, "mode": "stream_only"}))
        }
    }
}

async fn record_mark(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.raw_command("RECORD_MARK", None).await?),
        ActiveDevice::DyjV1 { .. } | ActiveDevice::BoardV21 { .. } => {
            Ok(json!({"marked": true, "localOnly": true}))
        }
    }
}

// ── 统一实时音频流（16kHz / 单声道 / i16 小端 PCM） ────────────────

async fn realtime_open(out: Emitter) -> Result<(), BridgeError> {
    let active = active_device().await?;
    match active {
        ActiveDevice::CardV2 { device, .. } => realtime_open_card_v2(device, out).await,
        ActiveDevice::DyjV1 { device, .. } => realtime_open_dyj_v1(device, out).await,
        ActiveDevice::BoardV21 {
            board,
            audio_tx,
            recording,
            ..
        } => realtime_open_board_v21(board, audio_tx, recording, out).await,
    }
}

fn install_realtime_stop() -> tokio::sync::oneshot::Receiver<()> {
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let mut slot = state().realtime_stop.lock().expect("realtime lock");
    if let Some(previous) = slot.take() {
        let _ = previous.send(());
    }
    *slot = Some(stop_tx);
    stop_rx
}

fn emit_pcm_chunk(
    out: &Emitter,
    samples_slice: &[i16],
    sample_rate: u32,
    channels: u8,
    discontinuous: bool,
    blocks: &mut u64,
    samples: &mut u64,
    gaps: &mut u64,
) {
    if discontinuous {
        *gaps += 1;
        out.progress(json!({
            "state": "gap",
            "gapIndex": *gaps,
            "receivedSamples": *samples,
        }));
    }
    let mut bytes = Vec::with_capacity(samples_slice.len() * 2);
    for sample in samples_slice {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    *blocks += 1;
    *samples += samples_slice.len() as u64;
    out.progress(json!({
        "state": "audio",
        "sampleRate": sample_rate,
        "channels": channels,
        "samples": samples_slice.len(),
        "receivedSamples": *samples,
        "bytes": bytes.len(),
        "pcm": BASE64.encode(bytes),
    }));
}

async fn realtime_open_card_v2(device: CardV2Device, out: Emitter) -> Result<(), BridgeError> {
    device.set_realtime_enabled(true).await?;
    let mut audio = device.subscribe_audio();
    let mut stop_rx = install_realtime_stop();
    out.progress(json!({"state": "open", "deviceKind": "card_v2"}));

    tokio::spawn(async move {
        let mut blocks: u64 = 0;
        let mut samples: u64 = 0;
        let mut gaps: u64 = 0;
        loop {
            tokio::select! {
                _ = &mut stop_rx => break,
                received = audio.recv() => match received {
                    Ok(chunk) => emit_pcm_chunk(
                        &out,
                        &chunk.samples,
                        chunk.sample_rate,
                        chunk.channels,
                        chunk.discontinuous,
                        &mut blocks,
                        &mut samples,
                        &mut gaps,
                    ),
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                        gaps += 1;
                        out.progress(json!({
                            "state": "gap",
                            "gapIndex": gaps,
                            "skipped": skipped,
                            "receivedSamples": samples,
                        }));
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                },
            }
        }
        let _ = device.set_realtime_enabled(false).await;
        out.ok(json!({
            "closed": true,
            "blocks": blocks,
            "receivedSamples": samples,
            "gaps": gaps,
        }));
    });
    Ok(())
}

async fn realtime_open_dyj_v1(device: DyjV1Device, out: Emitter) -> Result<(), BridgeError> {
    let _ = device.audio_capture_start().await;
    device.audio_stream_start().await?;
    let mut audio = device.subscribe_audio();
    let mut stop_rx = install_realtime_stop();
    out.progress(json!({"state": "open", "deviceKind": "dyj_v1"}));

    tokio::spawn(async move {
        let mut blocks: u64 = 0;
        let mut samples: u64 = 0;
        let mut gaps: u64 = 0;
        loop {
            tokio::select! {
                _ = &mut stop_rx => break,
                received = audio.recv() => match received {
                    Ok(chunk) => emit_pcm_chunk(
                        &out,
                        &chunk.samples,
                        chunk.sample_rate,
                        chunk.channels,
                        chunk.discontinuous,
                        &mut blocks,
                        &mut samples,
                        &mut gaps,
                    ),
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                        gaps += 1;
                        out.progress(json!({
                            "state": "gap",
                            "gapIndex": gaps,
                            "skipped": skipped,
                            "receivedSamples": samples,
                        }));
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                },
            }
        }
        let _ = device.audio_stream_stop().await;
        out.ok(json!({
            "closed": true,
            "blocks": blocks,
            "receivedSamples": samples,
            "gaps": gaps,
        }));
    });
    Ok(())
}

async fn realtime_open_board_v21(
    board: Arc<BoardDevice>,
    audio_tx: tokio::sync::broadcast::Sender<BoardPcmChunk>,
    recording: Arc<AtomicBool>,
    out: Emitter,
) -> Result<(), BridgeError> {
    if !board.is_connected() {
        return Err(BridgeError::disconnected());
    }
    let mut audio = audio_tx.subscribe();
    let lease_id = state()
        .board_lease_seq
        .fetch_add(1, Ordering::Relaxed)
        .max(1);
    let default_ttl_ms: u16 = 15_000;

    // 优先使用版本化 Timeline 连续租约；若固件较旧则回退旧版 FE63 会话读取
    let lease_mode = match board
        .start_board_audio(
            AudioTransport::BleGatt,
            AudioStreamScope::Timeline,
            lease_id,
            default_ttl_ms,
        )
        .await
    {
        Ok(st) => Some(st.ttl_ms.max(4_000)),
        Err(_) => {
            board
                .start_legacy_ble_session_reader()
                .map_err(|e| BridgeError::from(format!("开启键盘麦克风流失败: {e}")))?;
            None
        }
    };
    recording.store(true, Ordering::SeqCst);

    let mut stop_rx = install_realtime_stop();
    out.progress(json!({
        "state": "open",
        "deviceKind": "board_v21",
        "lease": lease_mode.is_some(),
    }));

    tokio::spawn(async move {
        let mut blocks: u64 = 0;
        let mut samples: u64 = 0;
        let mut gaps: u64 = 0;
        let hb_period = Duration::from_millis(u64::from(lease_mode.unwrap_or(12_000)) / 3);
        let mut hb_interval = tokio::time::interval(hb_period.max(Duration::from_secs(2)));
        hb_interval.tick().await; // skip immediate tick

        loop {
            tokio::select! {
                _ = &mut stop_rx => break,
                _ = hb_interval.tick(), if lease_mode.is_some() => {
                    if let Some(ttl) = lease_mode {
                        let _ = board.control_audio_stream(
                            AudioStreamAction::Heartbeat,
                            AudioTransport::BleGatt,
                            AudioStreamScope::Timeline,
                            lease_id,
                            ttl,
                        ).await;
                    }
                }
                received = audio.recv() => match received {
                    Ok(chunk) => emit_pcm_chunk(
                        &out,
                        &chunk.samples,
                        chunk.sample_rate,
                        chunk.channels,
                        chunk.discontinuous,
                        &mut blocks,
                        &mut samples,
                        &mut gaps,
                    ),
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                        gaps += 1;
                        out.progress(json!({
                            "state": "gap",
                            "gapIndex": gaps,
                            "skipped": skipped,
                            "receivedSamples": samples,
                        }));
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        }
        recording.store(false, Ordering::SeqCst);
        if let Some(ttl) = lease_mode {
            let _ = board
                .control_audio_stream(
                    AudioStreamAction::Stop,
                    AudioTransport::BleGatt,
                    AudioStreamScope::Timeline,
                    lease_id,
                    ttl,
                )
                .await;
        }
        board.stop_local_audio_reader();
        out.ok(json!({
            "closed": true,
            "blocks": blocks,
            "receivedSamples": samples,
            "gaps": gaps,
        }));
    });
    Ok(())
}

// ── 文件同步、相机媒体同步与 Wi-Fi 配置 ─────────────────────────

async fn list_device_files(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            ensure_sd_on_nrf(device).await;
            Ok(device.list_files(None).await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => {
            let agg = device.record_list().await?;
            let items = agg
                .get("items")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let files: Vec<Value> = items
                .into_iter()
                .map(|it| {
                    json!({
                        "name": it.get("name").and_then(Value::as_str).unwrap_or_default(),
                        "size": it.get("bytes").and_then(Value::as_u64).unwrap_or(0),
                        "createTime": it.get("mtime").and_then(Value::as_u64).unwrap_or(0),
                    })
                })
                .collect();
            Ok(json!({ "files": files }))
        }
        ActiveDevice::BoardV21 { .. } => Ok(json!({ "files": [] })),
    }
}

async fn download_device_file(
    active: &ActiveDevice,
    name: &str,
    dir: &str,
) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, name: dev_name } => {
            ensure_sd_on_nrf(device).await;
            let saved = device.take_file_to_dir(name, dir).await?;
            Ok(json!({
                "path": saved.path.to_string_lossy(),
                "bytesWritten": saved.bytes_written,
                "originalName": saved.original_name,
                "deviceName": saved.device_name.or_else(|| Some(dev_name.clone())),
            }))
        }
        ActiveDevice::DyjV1 {
            device,
            name: dev_name,
            device_id_meta,
        } => {
            // 1) 若设备热点已开启且可达，优先走 SoftAP 8788 快传
            if let Ok(ap_st) = device.ap_status().await {
                if ap_st.get("active").and_then(Value::as_bool) == Some(true) {
                    if let Ok(client) = DyjV1ApClient::from_status(&ap_st) {
                        if let Ok(saved) = client.download_to_dir(name, dir).await {
                            return Ok(json!({
                                "path": saved.path.to_string_lossy(),
                                "bytesWritten": saved.bytes_written,
                                "originalName": saved.name,
                                "deviceName": dev_name,
                            }));
                        }
                    }
                }
            }
            // 2) 若设备已上传到配网服务器，从上传源站拉回
            let did = device_id_meta.lock().unwrap().clone();
            if let (Some(device_id), Ok(cfg)) = (did, device.upload_config_get().await) {
                if let Some(upload_url) = cfg.get("url").and_then(Value::as_str) {
                    if let Some(origin) = extract_origin(upload_url) {
                        if let Ok(server) = DyjV1ServerClient::new(&origin) {
                            let only = vec![name.to_string()];
                            if let Ok(mut list) =
                                server.download_to_dir(&device_id, dir, Some(&only)).await
                            {
                                if let Some(saved) = list.pop() {
                                    return Ok(json!({
                                        "path": saved.path.to_string_lossy(),
                                        "bytesWritten": saved.bytes_written,
                                        "originalName": saved.name,
                                        "deviceName": dev_name,
                                    }));
                                }
                            }
                        }
                    }
                }
            }
            Err(BridgeError::from(
                "点一机 V1 离线音频走 Wi-Fi 上传或热点快传，请先连接 Wi-Fi 同步或开启实时录音流"
                    .to_string(),
            ))
        }
        ActiveDevice::BoardV21 { .. } => Err(BridgeError::from(
            "语音 AI 键盘无板载录音存储，仅支持实时音频流".to_string(),
        )),
    }
}

async fn take_oldest_device_file(active: &ActiveDevice, dir: &str) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, name: dev_name } => {
            ensure_sd_on_nrf(device).await;
            let saved = device.take_oldest_file_to_dir(dir).await?;
            Ok(json!({
                "path": saved.path.to_string_lossy(),
                "bytesWritten": saved.bytes_written,
                "originalName": saved.original_name,
                "deviceName": saved.device_name.or_else(|| Some(dev_name.clone())),
            }))
        }
        ActiveDevice::DyjV1 { .. } => Err(BridgeError::from(
            "点一机 V1 不支持按最旧切片指令取回，请使用文件列表同步".to_string(),
        )),
        ActiveDevice::BoardV21 { .. } => Err(BridgeError::from(
            "语音 AI 键盘无板载录音存储，仅支持实时音频流".to_string(),
        )),
    }
}

async fn delete_device_file(active: &ActiveDevice, name: &str) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            Ok(device.delete_file(name).await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => Ok(device.record_delete(name).await?),
        ActiveDevice::BoardV21 { .. } => Ok(json!({"deleted": false})),
    }
}

async fn camera_list(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::DyjV1 { device, .. } => Ok(device.camera_list().await?),
        _ => Ok(json!({"total": 0, "items": []})),
    }
}

/// 同步点一机 V1 硬件按键拍摄的照片（触发 `upload.start` 并从配网媒体服务拉取照片到本地 `dir`）。
async fn camera_sync(
    active: &ActiveDevice,
    dir: &str,
    server_origin_override: Option<&str>,
) -> Result<Value, BridgeError> {
    let ActiveDevice::DyjV1 {
        device,
        device_id_meta,
        ..
    } = active
    else {
        return Ok(json!({"photos": [], "pendingOnDevice": 0}));
    };

    let cam = device.camera_list().await.unwrap_or(Value::Null);
    let items = cam
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let photo_items: Vec<Value> = items
        .into_iter()
        .filter(|it| {
            it.get("kind").and_then(Value::as_str) == Some("photo")
                || it
                    .get("name")
                    .and_then(Value::as_str)
                    .is_some_and(|n| n.ends_with(".jpg") || n.ends_with(".jpeg"))
        })
        .collect();

    // 若设备上有未上传照片，尝试触发后台 Wi-Fi 上传（未连 Wi-Fi 时忽略 3003 错误，保留设备列表元信息）
    if !photo_items.is_empty() {
        let _ = device.upload_start(None).await;
    }

    let mut device_id = device_id_meta.lock().unwrap().clone();
    if device_id.is_none() {
        if let Ok(info) = device.device_info(false).await {
            device_id = info
                .get("device_id")
                .and_then(Value::as_str)
                .map(str::to_owned);
            *device_id_meta.lock().unwrap() = device_id.clone();
        }
    }

    let origin = match server_origin_override {
        Some(o) if !o.is_empty() => Some(o.to_string()),
        _ => device
            .upload_config_get()
            .await
            .ok()
            .and_then(|c| c.get("url").and_then(Value::as_str).and_then(extract_origin)),
    };

    let mut downloaded = Vec::new();
    if let (Some(did), Some(orig)) = (device_id, origin) {
        if let Ok(server) = DyjV1ServerClient::new(&orig) {
            if let Ok(remote_list) = server.list_files(&did).await {
                let photo_names: Vec<String> = remote_list
                    .files
                    .iter()
                    .filter(|f| f.name.ends_with(".jpg") || f.name.ends_with(".jpeg"))
                    .map(|f| f.name.clone())
                    .collect();
                if !photo_names.is_empty() {
                    if let Ok(saved_files) =
                        server.download_to_dir(&did, dir, Some(&photo_names)).await
                    {
                        for sf in saved_files {
                            downloaded.push(json!({
                                "name": sf.name,
                                "path": sf.path.to_string_lossy(),
                                "bytes": sf.bytes_written,
                                "source": "dyj_v1",
                            }));
                        }
                    }
                }
            }
        }
    }

    Ok(json!({
        "photos": downloaded,
        "devicePhotos": photo_items,
        "pendingOnDevice": photo_items.len(),
    }))
}

fn extract_origin(url: &str) -> Option<String> {
    let idx = url.find("://")?;
    let rest = &url[idx + 3..];
    let host_end = rest.find('/').unwrap_or(rest.len());
    Some(format!("{}{}", &url[..idx + 3], &rest[..host_end]))
}

fn is_wifi_encryption_secured(encryption: Option<&str>) -> bool {
    let Some(raw) = encryption else {
        return false;
    };
    let trimmed = raw.trim();
    !trimmed.is_empty()
        && !trimmed.eq_ignore_ascii_case("open")
        && !trimmed.eq_ignore_ascii_case("none")
}

async fn wifi_scan(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            let list = device.scan_wifi().await?;
            let items: Vec<Value> = list
                .into_iter()
                .map(|net| {
                    let secured = is_wifi_encryption_secured(net.encryption.as_deref());
                    json!({
                        "index": net.index,
                        "ssid": net.ssid,
                        "rssi": net.rssi,
                        "encryption": net.encryption,
                        "secured": secured,
                    })
                })
                .collect();
            Ok(Value::Array(items))
        }
        ActiveDevice::DyjV1 { device, .. } => {
            let agg = device.wifi_scan().await?;
            let items = agg
                .get("items")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let networks: Vec<Value> = items
                .into_iter()
                .filter(|it| {
                    it.get("frequency")
                        .and_then(Value::as_i64)
                        .is_none_or(|f| f < 5000)
                })
                .map(|it| {
                    let sec = it.get("security").and_then(Value::as_str);
                    json!({
                        "ssid": it.get("ssid").and_then(Value::as_str).unwrap_or_default(),
                        "rssi": it.get("rssi").and_then(Value::as_i64).unwrap_or(-70),
                        "secured": is_wifi_encryption_secured(sec),
                        "frequency": it.get("frequency"),
                    })
                })
                .collect();
            Ok(Value::Array(networks))
        }
        ActiveDevice::BoardV21 { .. } => Ok(Value::Array(Vec::new())),
    }
}

async fn wifi_connect(
    active: &ActiveDevice,
    ssid: &str,
    password: &str,
) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            Ok(device.connect_wifi(ssid, password).await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => {
            let pwd = if password.is_empty() {
                None
            } else {
                Some(password)
            };
            Ok(device.wifi_connect(ssid, pwd, None).await?)
        }
        ActiveDevice::BoardV21 { .. } => {
            Err(BridgeError::from("语音 AI 键盘不支持设备端 Wi-Fi 配置".to_string()))
        }
    }
}

async fn wifi_open(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.open_wifi().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.wifi_status().await?),
        ActiveDevice::BoardV21 { .. } => Ok(json!({"enabled": false})),
    }
}

async fn wifi_close(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.close_wifi().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { .. } | ActiveDevice::BoardV21 { .. } => Ok(json!({"closed": true})),
    }
}

async fn wifi_credentials(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            Ok(device.list_wifi_credentials().await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => {
            let st = device.wifi_status().await.unwrap_or(Value::Null);
            let mut creds = Vec::new();
            if let Some(ssid) = st.get("ssid").and_then(Value::as_str).filter(|s| !s.is_empty()) {
                creds.push(json!({"ssid": ssid, "connected": true}));
            }
            Ok(Value::Array(creds))
        }
        ActiveDevice::BoardV21 { .. } => Ok(Value::Array(Vec::new())),
    }
}

async fn wifi_forget(active: &ActiveDevice, ssid: &str) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            Ok(device.delete_wifi_credential(ssid).await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => Ok(device.wifi_forget(Some(ssid)).await?),
        ActiveDevice::BoardV21 { .. } => Ok(json!({"removed": 0})),
    }
}

async fn sync_start(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.start_sync().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.upload_start(None).await?),
        ActiveDevice::BoardV21 { .. } => Ok(json!({"queued": 0})),
    }
}

async fn sync_status(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.sync_status().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.upload_status().await?),
        ActiveDevice::BoardV21 { .. } => Ok(json!({"uploading": false})),
    }
}

async fn upload_set_url(active: &ActiveDevice, url: &str) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            Ok(device.set_wifi_upload_url(url).await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => Ok(device.upload_config_set(Some(url), None).await?),
        ActiveDevice::BoardV21 { .. } => Ok(json!({"url": url})),
    }
}

async fn ap_start(
    active: &ActiveDevice,
    ssid: Option<&str>,
    password: Option<&str>,
) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device
            .start_access_point(ssid, password)
            .await
            .and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.ap_start(ssid, password, true).await?),
        ActiveDevice::BoardV21 { .. } => {
            Err(BridgeError::from("语音 AI 键盘不支持热点模式".to_string()))
        }
    }
}

async fn ap_stop(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            Ok(device.stop_access_point().await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => Ok(device.ap_stop().await?),
        ActiveDevice::BoardV21 { .. } => Ok(json!({"active": false})),
    }
}

async fn time_sync(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.sync_time_now().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => {
            let now_ms = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            Ok(device
                .device_time(Some(now_ms))
                .await
                .unwrap_or_else(|_| json!({"epoch_ms": now_ms})))
        }
        ActiveDevice::BoardV21 { .. } => Ok(json!({"synced": true, "hostClock": true})),
    }
}

// ── 录音卡 V2 两阶段固件 OTA ────────────────────────────────────

async fn ota_info(payload: &Value) -> Result<Value, BridgeError> {
    let module = match payload.get("mod").and_then(Value::as_str) {
        Some("wifi") => OtaModule::Wifi,
        _ => OtaModule::Main,
    };
    let api_base = payload
        .get("apiBase")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| reai_card_sdk::OTA_DEFAULT_API_BASE_URL.to_owned());
    let info = OtaInfo::fetch(&api_base, module).await?;
    Ok(to_value(info)?)
}

async fn ota_main(payload: Value, out: Emitter) -> Result<(), BridgeError> {
    let api_base = payload
        .get("apiBase")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| reai_card_sdk::OTA_DEFAULT_API_BASE_URL.to_owned());

    out.progress(json!({"stage": "checking", "percent": 0, "text": "正在检查主控固件版本…"}));
    let info = match OtaInfo::fetch(&api_base, OtaModule::Main).await {
        Ok(info) => info,
        Err(error) => {
            out.fail(error);
            return Ok(());
        }
    };

    out.progress(json!({"stage": "downloading", "percent": 2, "text": "正在下载主控固件…", "version": info.version}));
    let bytes = match info.download().await {
        Ok(bytes) => bytes,
        Err(error) => {
            out.fail(error);
            return Ok(());
        }
    };
    let package = match DfuPackage::from_zip_bytes(&bytes) {
        Ok(package) => package,
        Err(error) => {
            out.fail(error);
            return Ok(());
        }
    };

    if let Some(pump) = state().event_pump.lock().await.take() {
        pump.abort();
    }
    let stop = state().realtime_stop.lock().expect("realtime lock").take();
    if let Some(stop) = stop {
        let _ = stop.send(());
    }
    state().last_device_id.lock().expect("device id lock").take();
    let active = state().device.lock().await.take();
    let Some(ActiveDevice::CardV2 { device, .. }) = active else {
        out.fail("当前连接设备不支持双芯 DFU 固件升级");
        return Ok(());
    };

    let manager = match card_v2_manager().await {
        Ok(manager) => manager,
        Err(error) => {
            out.fail(error.message);
            return Ok(());
        }
    };

    out.progress(json!({"stage": "dfu", "percent": 5, "text": "设备重启进 bootloader…"}));
    let ota_out = out;
    let options = reai_card_sdk::DfuOptions::default();
    let report = manager
        .update_main_firmware(&device, &package, &options, move |progress| {
            ota_out.progress(json!({
                "stage": "dfu",
                "percent": 5 + (progress.percent() as f64 * 0.9) as u8,
                "text": "正在写入主控固件…",
                "sent": progress.sent,
                "total": progress.total,
            }));
        })
        .await;

    let _ = tokio::time::timeout(Duration::from_secs(3), device.disconnect()).await;
    match report {
        Ok(report) => out.ok(json!({
            "module": "main",
            "version": info.version,
            "firmwareBytes": report.firmware_bytes,
            "objects": report.objects,
            "seconds": report.elapsed.as_secs_f64(),
        })),
        Err(error) => out.fail(error),
    }
    Ok(())
}

async fn close_wifi_quietly(device: &CardV2Device) {
    let _ = tokio::time::timeout(Duration::from_secs(6), device.close_wifi()).await;
}

async fn ota_wifi(payload: Value, out: Emitter) -> Result<(), BridgeError> {
    let api_base = payload
        .get("apiBase")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| reai_card_sdk::OTA_DEFAULT_API_BASE_URL.to_owned());
    let wait = Duration::from_secs(
        payload
            .get("waitSecs")
            .and_then(Value::as_u64)
            .unwrap_or(600),
    );
    out.progress(json!({"stage": "checking", "percent": 0, "text": "正在检查 Wi-Fi 模块固件…"}));

    let guard = state().device.lock().await;
    let Some(ActiveDevice::CardV2 { device, .. }) = guard.as_ref() else {
        out.fail("当前连接设备不支持 Wi-Fi 模组固件升级");
        return Ok(());
    };
    let device = device.clone();
    drop(guard);

    ota_wifi_with_device(&device, &api_base, wait, out).await;
    // 无论成功、已是最新还是中途失败，退出前始终归还 SD 卡总线给主控，避免后续录音/取文件报 SdOwnedByWifiModule。
    close_wifi_quietly(&device).await;
    Ok(())
}

async fn ota_wifi_with_device(
    device: &CardV2Device,
    api_base: &str,
    wait: Duration,
    out: Emitter,
) {
    let server_info = OtaInfo::fetch(api_base, OtaModule::Wifi).await.ok();

    let was_open = device.state().await.map(|s| s.wifi_open).unwrap_or(false);
    let mut status = device.wifi_status().await.ok();
    if !was_open || status.as_ref().is_some_and(|s| s.status == "off" || !s.enabled) {
        out.progress(json!({"stage": "wifi", "percent": 3, "text": "正在开启录音卡 Wi-Fi 模块…"}));
        if let Err(error) = device.open_wifi().await {
            out.fail(format!("开启 Wi-Fi 模块失败：{error}"));
            return;
        }
        // 等待 ESP32 完成 WIFI_SYNC，把最新 wifiVersion 同步给主控 BASE_INFO。
        tokio::time::sleep(Duration::from_millis(400)).await;
        status = device.wifi_status().await.ok();
    }

    let live_code = match status.as_ref().and_then(|s| s.version_code) {
        Some(code) => Some(code),
        None => device
            .device_info()
            .await
            .ok()
            .and_then(|info| info.wifi_version_code),
    };
    if let (Some(code), Some(info)) = (live_code, server_info.as_ref()) {
        if !info.is_newer_than(code) {
            out.progress(json!({"stage": "wifi", "percent": 100, "text": "Wi-Fi 模块固件已是最新"}));
            out.ok(json!({
                "module": "wifi",
                "upToDate": true,
                "version": status.as_ref().and_then(|s| s.version.clone()),
                "versionCode": code,
            }));
            return;
        }
    }

    let mut connected = status.as_ref().is_some_and(|s| s.connected);
    if !connected {
        let creds = device.list_wifi_credentials().await.unwrap_or_default();
        for cred in creds.iter().filter(|c| !c.ssid.trim().is_empty()) {
            out.progress(json!({
                "stage": "wifi",
                "percent": 8,
                "text": format!("正在自动连接已保存网络 {}…", cred.ssid),
            }));
            if device.connect_wifi(&cred.ssid, "").await.is_ok() {
                connected = true;
                break;
            }
        }
        if !connected {
            let msg = if creds.is_empty() {
                "录音卡尚未配置 Wi-Fi 网络，请先在录音卡弹层「Wi-Fi」中连接 2.4GHz 路由器后再升级"
            } else {
                "未能自动连上已保存的 Wi-Fi 网络，请先在录音卡弹层「Wi-Fi」中确认 2.4GHz 路由器在范围内并连接后再升级"
            };
            out.fail(CardSdkError::InvalidCommand(msg.to_owned()));
            return;
        }
    }

    out.progress(json!({"stage": "wifi", "percent": 12, "text": "正在向服务器检查 Wi-Fi 固件…"}));
    let check = match device.check_wifi_ota().await {
        Ok(check) => check,
        Err(error) => {
            out.fail(error);
            return;
        }
    };
    if !check.update_available {
        out.ok(json!({"module": "wifi", "upToDate": true, "check": check}));
        return;
    }

    let mut events = device.subscribe_events();
    if let Err(error) = device.start_wifi_ota().await {
        out.fail(error);
        return;
    }

    let deadline = tokio::time::Instant::now() + wait;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            out.fail(CardSdkError::Timeout {
                command: "OTA_WIFI".into(),
                seconds: wait.as_secs(),
            });
            return;
        }
        match tokio::time::timeout(remaining, events.recv()).await {
            Ok(Ok(CardV2Event::WifiOtaProgress(progress))) => {
                if progress.status == reai_card_sdk::OtaStatus::Success {
                    out.progress(json!({
                        "stage": "wifi",
                        "percent": 98,
                        "text": "Wi-Fi 固件写入完成，正在重启同步版本…",
                    }));
                    // 等 ESP32 重启并发送 WIFI_AP_START / WIFI_SYNC（最多 8 秒），确保主控更新缓存版本号。
                    let sync_deadline = tokio::time::Instant::now() + Duration::from_secs(8);
                    loop {
                        let rem = sync_deadline.saturating_duration_since(tokio::time::Instant::now());
                        if rem.is_zero() {
                            break;
                        }
                        match tokio::time::timeout(rem, events.recv()).await {
                            Ok(Ok(CardV2Event::AccessPointReady(_))) => break,
                            Ok(Ok(_)) => continue,
                            _ => break,
                        }
                    }
                    tokio::time::sleep(Duration::from_millis(400)).await;
                    out.ok(json!({"module": "wifi", "progress": progress}));
                    return;
                }
                if progress.status.is_terminal() {
                    out.fail("Wi-Fi 模组固件下载或校验失败，已保留原版本运行，请检查网络信号后重试");
                    return;
                }
                let percent = (15 + (u16::from(progress.percentage.min(100)) * 80 / 100)) as u8;
                out.progress(json!({
                    "stage": "wifi",
                    "percent": percent,
                    "text": "Wi-Fi 模组写入中，请保持连接…",
                    "detail": progress,
                }));
            }
            Ok(Ok(_)) => continue,
            Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => continue,
            Ok(Err(_)) => {
                out.fail(CardSdkError::Disconnected);
                return;
            }
            Err(_) => {
                out.fail(CardSdkError::Timeout {
                    command: "OTA_WIFI".into(),
                    seconds: wait.as_secs(),
                });
                return;
            }
        }
    }
}

// ── 小工具 ──────────────────────────────────────────────────

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, CardSdkError> {
    serde_json::to_value(value).map_err(to_sdk)
}

fn to_sdk(error: serde_json::Error) -> CardSdkError {
    CardSdkError::InvalidCommand(format!("serialize: {error}"))
}

fn str_field(payload: &Value, key: &str) -> String {
    payload
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// # Safety
/// 指针须为合法 C 字符串。
unsafe fn cstr(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn JNI_OnLoad(
    vm: *mut jni::sys::JavaVM,
    _reserved: *mut core::ffi::c_void,
) -> jni::sys::jint {
    let result = std::panic::catch_unwind(|| {
        let vm = unsafe { jni::JavaVM::from_raw(vm)? };
        let env = vm.attach_current_thread()?;
        btleplug::platform::init(&env)?;
        Ok::<(), Box<dyn std::error::Error>>(())
    });
    match result {
        Ok(Ok(())) => {}
        Ok(Err(error)) => eprintln!("card_bridge: Android BLE 初始化失败: {error}"),
        Err(_) => eprintln!("card_bridge: Android BLE 初始化 panic"),
    }
    jni::sys::JNI_VERSION_1_6
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_server_origin_from_upload_endpoint() {
        assert_eq!(
            extract_origin("https://media.wainao.chat/api/upload"),
            Some("https://media.wainao.chat".to_string())
        );
        assert_eq!(
            extract_origin("http://192.168.43.1:8788/api/files"),
            Some("http://192.168.43.1:8788".to_string())
        );
        assert_eq!(extract_origin("invalid-url"), None);
    }

    #[test]
    fn detects_wifi_encryption_security() {
        assert!(is_wifi_encryption_secured(Some("WPA2")));
        assert!(is_wifi_encryption_secured(Some("WPA/WPA2")));
        assert!(!is_wifi_encryption_secured(Some("OPEN")));
        assert!(!is_wifi_encryption_secured(Some("none")));
        assert!(!is_wifi_encryption_secured(Some("  ")));
        assert!(!is_wifi_encryption_secured(None));
    }
}
