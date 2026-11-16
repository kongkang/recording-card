//! card_bridge —— 统一硬件桥（C ABI 单一入口），同时驱动三款自研蓝牙硬件：
//! - 录音卡 V2（`reai-card-sdk` v0.0.8，广播前缀 `DYJV2_`，IMA-ADPCM 16kHz）
//! - 点一机 V1（`reai-dyj-sdk` v0.1.x，广播前缀 `DYJ_`，AMR-WB 16kHz + 相机媒体 + SoftAP）
//! - 语音 AI 键盘 V2.1（`reai-board-sdk` v0.3.x，广播前缀 `REAI_VB_`，mSBC 16kHz Timeline Lease）
//!
//! 对上层 Dart 保持完全一致的 JSON 回调协议与 16kHz 单声道 i16 PCM 实时流契约。

pub mod amr_transcode;
pub mod capabilities;

use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use btleplug::api::{Central as _, CentralEvent, Manager as _, Peripheral as _, ScanFilter};
use futures::StreamExt;
use capabilities::{classify_ble_advertisement, DeviceKind};
use reai_ext_sdk::{RecorderDevice, RecorderSdkDriver, SdkDeviceEvent};
use reai_getseed_sdk::GetSeedSdkDriver;
use reai_omi_sdk::OmiSdkDriver;
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
    External {
        kind: DeviceKind,
        device: Arc<dyn RecorderDevice>,
        name: String,
    },
}

impl ActiveDevice {
    fn kind(&self) -> DeviceKind {
        match self {
            Self::CardV2 { .. } => DeviceKind::CardV2,
            Self::DyjV1 { .. } => DeviceKind::DyjV1,
            Self::BoardV21 { .. } => DeviceKind::BoardV21,
            Self::External { kind, .. } => *kind,
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
    " card-v2/0.0.8 dyj-v1/0.1 board-v21/0.3 getseed/0.1 omi/0.1"
);

/// Android 直连 logcat 的零依赖检查点输出（不经 log crate，绕开 logger 初始化问题）。
#[cfg(target_os = "android")]
mod alog {
    use std::ffi::{c_char, CString};

    #[link(name = "log")]
    extern "C" {
        fn __android_log_print(
            prio: i32,
            tag: *const c_char,
            fmt: *const c_char,
            ...
        ) -> i32;
    }

    pub fn info(msg: &str) {
        let tag = CString::new("card_bridge").unwrap_or_default();
        let fmt = CString::new("%s").unwrap_or_default();
        let msg = CString::new(msg.replace('\0', " ")).unwrap_or_default();
        unsafe {
            __android_log_print(4, tag.as_ptr(), fmt.as_ptr(), msg.as_ptr());
        }
    }
}

#[cfg(not(target_os = "android"))]
mod alog {
    pub fn info(_msg: &str) {}
}

fn state() -> &'static BridgeState {
    STATE.get_or_init(|| BridgeState {
        runtime: tokio::runtime::Builder::new_multi_thread()
            .worker_threads(3)
            .on_thread_start(ensure_jvm_thread_attached)
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

impl From<reai_ext_sdk::SdkError> for BridgeError {
    fn from(e: reai_ext_sdk::SdkError) -> Self {
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
            let passive = payload
                .get("passive")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let active = active_device().await?;
            out.ok(wifi_credentials(&active, passive).await?);
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
            let lower = src_path
                .extension()
                .and_then(|e| e.to_str())
                .map(str::to_ascii_lowercase)
                .unwrap_or_default();
            if amr_transcode::is_amr_wb_file(src_path, &head) {
                let result = amr_transcode::amr_wb_to_wav(src_path, wav_path).await?;
                out.ok(json!({
                    "path": wav,
                    "samples": result.samples,
                    "durationSecs": result.duration_secs,
                }));
            } else if lower == "ogg" || lower == "opus" || head.starts_with(b"OggS") {
                let src_owned = src_path.to_path_buf();
                let wav_owned = wav_path.to_path_buf();
                let result = tokio::task::spawn_blocking(move || {
                    reai_ext_sdk::audio::ogg_opus_to_wav_16k_mono(&src_owned, &wav_owned)
                })
                .await
                .map_err(|e| BridgeError::from(format!("音频解码任务失败: {e}")))??;
                out.ok(json!({
                    "path": wav,
                    "samples": result.samples,
                    "durationSecs": result.duration_secs,
                }));
            } else if lower == "wav" || head.starts_with(b"RIFF") {
                let src_owned = src_path.to_path_buf();
                let wav_owned = wav_path.to_path_buf();
                let result = tokio::task::spawn_blocking(move || {
                    reai_ext_sdk::audio::wav_to_16k_mono(&src_owned, &wav_owned)
                })
                .await
                .map_err(|e| BridgeError::from(format!("音频重采样任务失败: {e}")))??;
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
    alog::info("unified_scan: begin");
    let adapter = scan_adapter().await?;
    alog::info("unified_scan: adapter ready");
    // btleplug 的 CoreBluetooth 后端只在「厂商数据 / 服务数据 / 服务 UUID」三类广播
    // 事件里回填 properties.rssi（初始 None）；只带本地名的广播（如点一机 V1 `DYJ_*`）
    // 永远拿不到 RSSI，曾被下方 `None => continue` 误丢——安卓后端无此问题，故出现
    // 「安卓五类硬件全出、iPhone 只剩 V2」（真机对照实测 2026-11-16）。
    // 这里订阅扫描窗口内的事件流，记录「本窗口确实广播过」的设备，作为无 RSSI 时的展示依据。
    let mut scan_events = adapter
        .events()
        .await
        .map_err(|e| BridgeError::from(format!("BLE events failed: {e}")))?;
    let mut seen_this_scan: HashSet<String> = HashSet::new();
    adapter
        .start_scan(ScanFilter::default())
        .await
        .map_err(|e| {
            alog::info(&format!("unified_scan: start_scan 失败 {e:?}"));
            log::warn!("unified_scan start_scan 失败: {e:?}");
            BridgeError::from(format!("BLE start_scan failed: {e:?}"))
        })?;
    alog::info("unified_scan: scanning…");
    let pump = async {
        while let Some(ev) = scan_events.next().await {
            let id = match ev {
                CentralEvent::DeviceDiscovered(id)
                | CentralEvent::DeviceUpdated(id)
                | CentralEvent::ManufacturerDataAdvertisement { id, .. }
                | CentralEvent::ServiceDataAdvertisement { id, .. }
                | CentralEvent::ServicesAdvertisement { id, .. } => id,
                _ => continue,
            };
            seen_this_scan.insert(id.to_string());
        }
    };
    let _ = tokio::time::timeout(duration, pump).await;
    alog::info(&format!(
        "unified_scan: sleep done, {} advertised this window",
        seen_this_scan.len()
    ));
    let _ = adapter.stop_scan().await;
    alog::info("unified_scan: stopped");

    let peripherals = adapter
        .peripherals()
        .await
        .map_err(|e| BridgeError::from(format!("BLE peripherals failed: {e}")))?;
    alog::info(&format!("unified_scan: {} peripherals", peripherals.len()));

    let mut discovered: Vec<(i16, String, Value)> = Vec::new();
    let mut cache_updates: Vec<(String, CachedScanEntry)> = Vec::new();

    for (idx, p) in peripherals.into_iter().enumerate() {
        if idx % 10 == 0 {
            alog::info(&format!("unified_scan: loop[{idx}] begin"));
        }
        // droidplug 的 properties() 是同步 Mutex 锁（真机实测会被 Java 回调线程卡死，
        // 直接 await 会把 tokio worker 整个挂住）。丢进 blocking 池 + 有界超时，
        // 单台卡死只损失一个 blocking 线程，扫描列表照常产出。
        let props = {
            let p = p.clone();
            match tokio::time::timeout(
                Duration::from_millis(400),
                tokio::task::spawn_blocking(move || {
                    tokio::runtime::Handle::current().block_on(p.properties())
                }),
            )
            .await
            {
                Ok(Ok(Ok(Some(props)))) => props,
                _ => {
                    alog::info(&format!("unified_scan: loop[{idx}] properties 卡死/失败，跳过"));
                    continue;
                }
            }
        };
        // 2026-11-16 调试直连结束，恢复过滤基线：未识别设备直接跳过
        // （classify 覆盖自有 3 款硬件 + 开启联动的 Get/Omi/Watch）。
        let Some((name, kind, caps)) = classify_ble_advertisement(
            &p.id().to_string(),
            props.local_name.as_deref(),
            &props.services,
            &props.manufacturer_data,
        ) else {
            continue;
        };
        let kind_str = kind.as_str();
        let display_model = kind.display_model();
        let caps_json = serde_json::to_value(&caps).unwrap_or(serde_json::Value::Null);
        // CoreBluetooth 本地缓存但未广播的旧外设通常无 RSSI；若已系统连接则仍展示。
        // RSSI 0/127 为无效值（CoreBluetooth 偶发上报 127），一并走兜底。
        let id = p.id().to_string();
        let advertised_now = seen_this_scan.contains(&id);
        let props_rssi = props.rssi.filter(|r| *r > 0 && *r != 127);
        let rssi = match props_rssi {
            Some(r) => r,
            None if advertised_now => {
                // 本窗口广播过但无 RSSI 载体事件（纯名称广播）：设备必然在附近，按近距离兜底展示
                -60
            }
            None => {
                let p = p.clone();
                let is_conn = match tokio::time::timeout(
                    Duration::from_millis(400),
                    tokio::task::spawn_blocking(move || {
                        tokio::runtime::Handle::current().block_on(p.is_connected())
                    }),
                )
                .await
                {
                    Ok(Ok(Ok(v))) => v,
                    _ => false,
                };
                if is_conn {
                    -58
                } else {
                    continue;
                }
            }
        };
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
                "deviceKind": kind_str,
                "displayModel": display_model,
                "capabilities": caps_json,
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
    alog::info(&format!("unified_scan: classified {} devices", discovered.len()));
    for (_, id, val) in discovered {
        if seen_ids.insert(id) {
            out.push(val);
        }
    }
    alog::info(&format!("unified_scan: done, {} entries out", out.len()));
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

    let mut res = match target_kind {
        DeviceKind::CardV2 => connect_card_v2(&id, target_name.as_deref()).await?,
        DeviceKind::DyjV1 => {
            let name = target_name.ok_or_else(|| {
                BridgeError::from(format!("点一机 V1 连接需要设备广播名称（id={id}）"))
            })?;
            connect_dyj_v1(&id, &name).await?
        }
        DeviceKind::BoardV21 => {
            let name = target_name.ok_or_else(|| {
                BridgeError::from(format!("语音 AI 键盘连接需要设备广播名称（id={id}）"))
            })?;
            connect_board_v21(&id, &name).await?
        }
        DeviceKind::GetSeedGsc10 | DeviceKind::OmiCv1 => {
            connect_external_sdk(&id, target_name.as_deref(), target_kind).await?
        }
    };
    if let Ok(active) = active_device().await {
        if let Ok(snap) = snapshot_device(&active).await {
            res["snapshot"] = snap;
        }
    }
    Ok(res)
}

async fn bootstrap_card_v2_ble_metadata_if_missing(device: &CardV2Device) {
    if let Ok(Some(_)) = device.wifi_firmware_version().await {
        return;
    }
    if device
        .record_status()
        .await
        .map(|r| r.is_recording)
        .unwrap_or(false)
    {
        return;
    }
    let was_open = device.state().await.map(|s| s.wifi_open).unwrap_or(false);
    if !was_open && device.open_wifi().await.is_err() {
        return;
    }
    let _ = device.wait_for_ap_ready(Duration::from_secs(4)).await;
    let _ = device.wifi_status().await;
    if let Ok(creds) = device.list_wifi_credentials().await {
        sync_ble_wifi_creds_kv(device, &creds).await;
    }
    if !was_open {
        close_wifi_quietly(device).await;
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
    bootstrap_card_v2_ble_metadata_if_missing(&device).await;
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

async fn connect_external_sdk(
    id: &str,
    name_hint: Option<&str>,
    kind: DeviceKind,
) -> Result<Value, BridgeError> {
    use btleplug::api::{Central as _, Peripheral as _, ScanFilter};

    let driver: &dyn RecorderSdkDriver = match kind {
        DeviceKind::GetSeedGsc10 => &GetSeedSdkDriver,
        DeviceKind::OmiCv1 => &OmiSdkDriver,
        _ => {
            return Err(BridgeError::from(format!(
                "非第三方 SDK 设备类型: {}",
                kind.as_str()
            )))
        }
    };

    let adapter = scan_adapter().await?;
    let mut found: Option<(btleplug::platform::Peripheral, String)> = None;
    for window in [Duration::from_secs(3), Duration::from_secs(5)] {
        adapter
            .start_scan(ScanFilter::default())
            .await
            .map_err(|e| BridgeError::from(format!("BLE 扫描启动失败: {e}")))?;
        tokio::time::sleep(window).await;
        let _ = adapter.stop_scan().await;
        let peripherals = adapter
            .peripherals()
            .await
            .map_err(|e| BridgeError::from(format!("读取 BLE 外设列表失败: {e}")))?;
        for p in peripherals {
            let pid = p.id().to_string();
            let props = p.properties().await.ok().flatten();
            let local_name = props
                .as_ref()
                .and_then(|pr| pr.local_name.as_deref())
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let id_match = !id.is_empty() && pid == id;
            let name_match = name_hint
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .is_some_and(|nh| local_name == Some(nh));
            let adv_match = props.as_ref().is_some_and(|pr| {
                driver.matches_advertisement(
                    local_name,
                    &pr.services,
                    &pr.manufacturer_data,
                )
            });
            if id_match || (name_match && adv_match) {
                let display_name = local_name
                    .map(str::to_owned)
                    .or_else(|| name_hint.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()))
                    .unwrap_or_else(|| driver.fallback_ble_name(&pid));
                found = Some((p, display_name));
                break;
            }
        }
        if found.is_some() {
            break;
        }
    }

    let (peripheral, ble_name) = found.ok_or_else(|| {
        BridgeError::from(format!(
            "未扫描到设备 {}（id={id}），请确认设备已开机且在蓝牙范围内",
            kind.display_model()
        ))
    })?;

    let device = driver.connect(peripheral, ble_name.clone()).await?;
    let connected_name = device.device_name().to_string();
    let caps = capabilities::HardwareCapabilities::from_sdk(device.capabilities());
    let pump = spawn_external_event_pump(&device);
    *state().event_pump.lock().await = Some(pump);
    *state().last_device_id.lock().expect("device id lock") = Some(id.to_string());
    *state().device.lock().await = Some(ActiveDevice::External {
        kind,
        device,
        name: connected_name.clone(),
    });
    Ok(json!({
        "connected": true,
        "name": connected_name,
        "deviceKind": kind.as_str(),
        "displayModel": kind.display_model(),
        "capabilities": caps,
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
        Some(ActiveDevice::External { device, .. }) => {
            match tokio::time::timeout(Duration::from_secs(6), device.disconnect()).await {
                Ok(Ok(())) => json!("ok"),
                Ok(Err(error)) => json!(format!("error: {error}")),
                Err(_) => json!("timeout"),
            }
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

fn spawn_external_event_pump(device: &Arc<dyn RecorderDevice>) -> tokio::task::JoinHandle<()> {
    let mut events = device.subscribe_events();
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(event) => {
                    let value = match event {
                        SdkDeviceEvent::RecordStatus(status) => serde_json::to_value(&status)
                            .map(|v| json!({"kind": "record", "status": v}))
                            .unwrap_or(Value::Null),
                        SdkDeviceEvent::Power(batt) => json!({
                            "kind": "power",
                            "battery": {
                                "level": batt.level,
                                "isCharging": batt.is_charging,
                            },
                        }),
                        SdkDeviceEvent::VoiceKey { pressed } => json!({
                            "kind": "voice_key",
                            "pressed": pressed,
                        }),
                        SdkDeviceEvent::Button { gesture } => json!({
                            "kind": "button",
                            "gesture": gesture,
                        }),
                        SdkDeviceEvent::Disconnected => json!({
                            "kind": "disconnected",
                        }),
                    };
                    if !value.is_null() {
                        state().events.lock().expect("events lock").push(value);
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    })
}

async fn snapshot_device(active: &ActiveDevice) -> Result<Value, BridgeError> {
    let kind = active.kind();
    match active {
        ActiveDevice::External { device, .. } => {
            let snap = device.snapshot().await?;
            let caps = capabilities::HardwareCapabilities::from_sdk(snap.capabilities);
            let storage = snap.storage.map(|st| {
                json!({
                    "total": st.total_mb,
                    "used": st.used_mb,
                })
            });
            Ok(json!({
                "battery": {
                    "level": snap.battery.level,
                    "isCharging": snap.battery.is_charging,
                },
                "state": {
                    "wifiOpen": false,
                    "recording": snap.record.is_recording,
                },
                "info": {
                    "version": snap.fw_version,
                    "versionCode": 0,
                    "deviceName": snap.device_name,
                    "deviceId": snap.device_id,
                    "wifiVersion": "",
                    "wifiVersionCode": 0,
                },
                "storage": storage,
                "record": snap.record,
                "deviceKind": kind.as_str(),
                "displayModel": kind.display_model(),
                "deviceName": snap.device_name,
                "capabilities": caps,
            }))
        }
        ActiveDevice::CardV2 { device, name } => {
            let battery_res = match device.battery().await {
                Ok(v) if v.level > 0 => Ok(v),
                _ => {
                    tokio::time::sleep(Duration::from_millis(120)).await;
                    device.battery().await
                }
            };
            let battery = match battery_res {
                Ok(v) => serde_json::to_value(v).unwrap_or(Value::Null),
                Err(_) => device
                    .raw_command("BATTERY", None)
                    .await
                    .unwrap_or(Value::Null),
            };
            let state_res = match device.state().await {
                Ok(v) => Ok(v),
                Err(_) => {
                    tokio::time::sleep(Duration::from_millis(120)).await;
                    device.state().await
                }
            };
            let wifi_open_now = state_res.as_ref().map(|s| s.wifi_open).unwrap_or(false);
            let state_val = match state_res {
                Ok(v) => serde_json::to_value(v).unwrap_or(Value::Null),
                Err(_) => device
                    .raw_command("STATE_INFO", None)
                    .await
                    .unwrap_or(Value::Null),
            };
            let info_res = match device.device_info().await {
                Ok(v) if !v.version.trim().is_empty() => Ok(v),
                _ => {
                    tokio::time::sleep(Duration::from_millis(120)).await;
                    device.device_info().await
                }
            };
            let info = match info_res {
                Ok(v) => serde_json::to_value(v).unwrap_or(Value::Null),
                Err(_) => device
                    .raw_command("BASE_INFO", None)
                    .await
                    .unwrap_or(Value::Null),
            };
            let storage = if wifi_open_now {
                None
            } else {
                match device.storage().await {
                    Ok(v) => Some(v),
                    Err(_) => {
                        tokio::time::sleep(Duration::from_millis(120)).await;
                        device.storage().await.ok()
                    }
                }
            };
            let record = match device.record_status().await {
                Ok(v) => Some(v),
                Err(_) => {
                    tokio::time::sleep(Duration::from_millis(120)).await;
                    device.record_status().await.ok()
                }
            };
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
            ActiveDevice::External { device, .. } => {
                let snap = device.snapshot().await?;
                if snap.record.is_recording {
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
        ActiveDevice::External { device, .. } => {
            let st = device.start_record(duration_secs).await?;
            Ok(serde_json::to_value(&st).unwrap_or(json!({"recording": true})))
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
        ActiveDevice::External { device, .. } => {
            let st = device.stop_record().await?;
            Ok(serde_json::to_value(&st).unwrap_or(json!({"recording": false})))
        }
    }
}

async fn record_mark(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.raw_command("RECORD_MARK", None).await?),
        ActiveDevice::External { device, kind, .. } => {
            if !device.capabilities().has_mark_button {
                return Err(BridgeError::from(format!(
                    "{} 不支持语音重点打标",
                    kind.display_model()
                )));
            }
            Ok(device.mark().await?)
        }
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
        ActiveDevice::External { kind, device, .. } => {
            realtime_open_external(kind, device, out).await
        }
    }
}

async fn realtime_open_external(
    kind: DeviceKind,
    device: Arc<dyn RecorderDevice>,
    out: Emitter,
) -> Result<(), BridgeError> {
    // 单例语义：已在推流时不再重复订阅/重置停止槽（Dart 侧偶发双开竞态，
    // 第二个 open 若重装停止槽会让第一个任务失去停止句柄、随后一次 close 整体退订）。
    if state()
        .realtime_stop
        .lock()
        .expect("realtime lock")
        .is_some()
    {
        out.progress(json!({ "state": "open", "deviceKind": kind.as_str(), "alreadyOpen": true }));
        return Ok(());
    }
    let mut audio = device.subscribe_audio();
    device.set_realtime_enabled(true).await?;
    let mut stop_rx = install_realtime_stop();
    out.progress(json!({
        "state": "open",
        "deviceKind": kind.as_str(),
    }));

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
                }
            }
        }
        let _ = device.set_realtime_enabled(false).await;
        out.ok(json!({
            "stopped": true,
            "blocks": blocks,
            "samples": samples,
            "gaps": gaps,
        }));
    });
    Ok(())
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
        ActiveDevice::External { device, .. } => {
            let files = device.list_files().await?;
            Ok(serde_json::to_value(&files).unwrap_or_else(|_| Value::Array(Vec::new())))
        }
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
        ActiveDevice::External { device, name: dev_name, .. } => {
            let saved = device.download_file(name, dir).await?;
            Ok(json!({
                "path": saved.path.to_string_lossy(),
                "bytesWritten": saved.bytes_written,
                "originalName": saved.original_name,
                "deviceName": saved.device_name.or_else(|| Some(dev_name.clone())),
            }))
        }
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
        ActiveDevice::External { device, name: dev_name, .. } => {
            let files = device.list_files().await?;
            let first = files.into_iter().next().ok_or_else(|| {
                BridgeError::from("设备存储中暂无待取回的录音文件".to_string())
            })?;
            let saved = device.download_file(&first.name, dir).await?;
            let _ = device.delete_file(&first.name).await;
            Ok(json!({
                "path": saved.path.to_string_lossy(),
                "bytesWritten": saved.bytes_written,
                "originalName": saved.original_name,
                "deviceName": saved.device_name.or_else(|| Some(dev_name.clone())),
            }))
        }
    }
}

async fn delete_device_file(active: &ActiveDevice, name: &str) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::External { device, .. } => {
            device.delete_file(name).await?;
            Ok(json!({"deleted": name}))
        }
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

async fn ensure_wifi_open_card_v2(device: &CardV2Device) -> Result<bool, CardSdkError> {
    let was_open = device.state().await?.wifi_open;
    if !was_open {
        device.open_wifi().await?;
        let _ = device.wait_for_ap_ready(Duration::from_secs(5)).await;
    }
    Ok(was_open)
}

async fn wifi_scan(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            ensure_wifi_open_card_v2(device).await?;
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
        ActiveDevice::BoardV21 { .. } | ActiveDevice::External { .. } => {
            Ok(Value::Array(Vec::new()))
        }
    }
}

const BLE_WIFI_CRED_SUMMARY_KEY: &str = "ble_wcred";

fn encode_ssid_list_kv(ssids: &[String]) -> String {
    let clean: Vec<&str> = ssids
        .iter()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    let header = format!("{}|", clean.len());
    if clean.is_empty() {
        return header;
    }
    let full = format!("{header}{}", clean.join("\n"));
    if full.len() <= 63 {
        return full;
    }
    let mut end = 63;
    while !full.is_char_boundary(end) {
        end -= 1;
    }
    full[..end].to_owned()
}

fn decode_ssid_list_kv(raw: &str) -> Vec<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let Some((count_str, body)) = trimmed.split_once('|') else {
        return trimmed
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect();
    };
    let count = count_str.trim().parse::<usize>().unwrap_or(0).min(16);
    if count == 0 {
        return Vec::new();
    }
    let mut items: Vec<String> = body
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    if items.len() > count {
        items.truncate(count);
    }
    while items.len() < count {
        items.push(format!("已保存网络 {}", items.len() + 1));
    }
    items
}

async fn sync_ble_wifi_creds_kv(
    device: &CardV2Device,
    creds: &[reai_card_sdk::WifiCredential],
) {
    let ssids: Vec<String> = creds
        .iter()
        .map(|c| c.ssid.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect();
    let encoded = encode_ssid_list_kv(&ssids);
    let _ = device.set_config(BLE_WIFI_CRED_SUMMARY_KEY, &encoded).await;
}

async fn wifi_connect(
    active: &ActiveDevice,
    ssid: &str,
    password: &str,
) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            ensure_wifi_open_card_v2(device).await?;
            let connected = device.connect_wifi(ssid, password).await?;
            if let Ok(creds) = device.list_wifi_credentials().await {
                sync_ble_wifi_creds_kv(device, &creds).await;
            }
            Ok(to_value(connected)?)
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
        ActiveDevice::External { kind, .. } => Err(BridgeError::from(format!(
            "{} 不支持设备端 Wi-Fi 配置",
            kind.display_model()
        ))),
    }
}

async fn wifi_open(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.open_wifi().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.wifi_status().await?),
        ActiveDevice::BoardV21 { .. } | ActiveDevice::External { .. } => {
            Ok(json!({"enabled": false}))
        }
    }
}

async fn wifi_close(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.close_wifi().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { .. }
        | ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. } => Ok(json!({"closed": true})),
    }
}

async fn wifi_credentials(active: &ActiveDevice, passive: bool) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            let was_open = device.state().await?.wifi_open;
            if was_open {
                let creds = device.list_wifi_credentials().await?;
                sync_ble_wifi_creds_kv(device, &creds).await;
                return Ok(to_value(creds)?);
            }
            if passive {
                let cached = device
                    .config_value(BLE_WIFI_CRED_SUMMARY_KEY)
                    .await
                    .ok()
                    .flatten()
                    .map(|raw| decode_ssid_list_kv(&raw))
                    .unwrap_or_default();
                let arr: Vec<Value> = cached
                    .into_iter()
                    .map(|ssid| json!({"ssid": ssid}))
                    .collect();
                return Ok(Value::Array(arr));
            }
            if device
                .record_status()
                .await
                .map(|r| r.is_recording)
                .unwrap_or(false)
            {
                return Err(BridgeError::from(
                    "正在录音中，暂不开启 Wi-Fi 读取凭据".to_string(),
                ));
            }
            device.open_wifi().await?;
            let _ = device.wait_for_ap_ready(Duration::from_secs(5)).await;
            let creds = device.list_wifi_credentials().await;
            if let Ok(ref list) = creds {
                sync_ble_wifi_creds_kv(device, list).await;
            }
            close_wifi_quietly(device).await;
            Ok(creds.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => {
            let st = device.wifi_status().await.unwrap_or(Value::Null);
            let mut creds = Vec::new();
            if let Some(ssid) = st.get("ssid").and_then(Value::as_str).filter(|s| !s.is_empty()) {
                creds.push(json!({"ssid": ssid, "connected": true}));
            }
            Ok(Value::Array(creds))
        }
        ActiveDevice::BoardV21 { .. } | ActiveDevice::External { .. } => {
            Ok(Value::Array(Vec::new()))
        }
    }
}

async fn wifi_forget(active: &ActiveDevice, ssid: &str) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            let was_open = device.state().await?.wifi_open;
            if was_open {
                let res = device.delete_wifi_credential(ssid).await;
                if res.is_ok() {
                    if let Ok(creds) = device.list_wifi_credentials().await {
                        sync_ble_wifi_creds_kv(device, &creds).await;
                    }
                }
                return Ok(res.and_then(to_value)?);
            }
            if device
                .record_status()
                .await
                .map(|r| r.is_recording)
                .unwrap_or(false)
            {
                return Err(BridgeError::from(
                    "正在录音中，无法开启 Wi-Fi 删除网络凭据".to_string(),
                ));
            }
            device.open_wifi().await?;
            let _ = device.wait_for_ap_ready(Duration::from_secs(5)).await;
            let res = device.delete_wifi_credential(ssid).await;
            if res.is_ok() {
                if let Ok(creds) = device.list_wifi_credentials().await {
                    sync_ble_wifi_creds_kv(device, &creds).await;
                }
            }
            close_wifi_quietly(device).await;
            Ok(res.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => Ok(device.wifi_forget(Some(ssid)).await?),
        ActiveDevice::BoardV21 { .. } | ActiveDevice::External { .. } => {
            Ok(json!({"removed": 0}))
        }
    }
}

async fn sync_start(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.start_sync().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.upload_start(None).await?),
        ActiveDevice::BoardV21 { .. } | ActiveDevice::External { .. } => Ok(json!({"queued": 0})),
    }
}

async fn sync_status(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.sync_status().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.upload_status().await?),
        ActiveDevice::BoardV21 { .. } | ActiveDevice::External { .. } => {
            Ok(json!({"uploading": false}))
        }
    }
}

async fn upload_set_url(active: &ActiveDevice, url: &str) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            Ok(device.set_wifi_upload_url(url).await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => Ok(device.upload_config_set(Some(url), None).await?),
        ActiveDevice::BoardV21 { .. } | ActiveDevice::External { .. } => Ok(json!({"url": url})),
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
        ActiveDevice::External { kind, .. } => Err(BridgeError::from(format!(
            "{} 不支持热点模式",
            kind.display_model()
        ))),
    }
}

async fn ap_stop(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            Ok(device.stop_access_point().await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => Ok(device.ap_stop().await?),
        ActiveDevice::BoardV21 { .. } | ActiveDevice::External { .. } => {
            Ok(json!({"active": false}))
        }
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
        ActiveDevice::External { device, .. } => Ok(device.sync_time().await?),
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

fn should_restore_wifi_open(payload: &Value, was_open_now: bool) -> bool {
    payload
        .get("restoreWifiOpen")
        .and_then(Value::as_bool)
        .unwrap_or(was_open_now)
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

    let was_open_now = device.state().await.map(|s| s.wifi_open).unwrap_or(false);
    let prev_status = if was_open_now {
        device.wifi_status().await.ok()
    } else {
        None
    };
    let prev_connected_ssid = prev_status
        .as_ref()
        .filter(|s| s.connected)
        .and_then(|s| s.ssid.clone())
        .filter(|s| !s.trim().is_empty());
    let restore_wifi_open = should_restore_wifi_open(&payload, was_open_now);

    let outcome =
        ota_wifi_with_device(&device, &api_base, wait, was_open_now, prev_status, out).await;
    let esp32_rebooted = outcome.as_ref().map(|(_, rebooted)| *rebooted).unwrap_or(false);

    // 务必在 emit 终态（final: true）之前把硬件 Wi-Fi 开关改回升级前模式：
    // 否则上层 Dart 收到 final: true 后立刻 refreshFromDevice() 会与关 Wi-Fi 竞态，
    // 且可能导致 SD 总线仍归 ESP32 占用。
    if !restore_wifi_open {
        if outcome.is_ok() {
            out.progress(json!({
                "stage": "wifi",
                "percent": 99,
                "text": "正在恢复 Wi-Fi 开关至升级前状态…",
            }));
        }
        close_wifi_quietly(&device).await;
    } else {
        if !device.state().await.map(|s| s.wifi_open).unwrap_or(false) {
            let _ = device.open_wifi().await;
            let _ = device.wait_for_ap_ready(Duration::from_secs(6)).await;
        }
        if esp32_rebooted {
            if let Some(ssid) = prev_connected_ssid.as_deref() {
                let _ = device.connect_wifi(ssid, "").await;
            }
        }
    }

    match outcome {
        Ok((data, _)) => out.ok(data),
        Err(error) => out.fail(error),
    }
    Ok(())
}

async fn ota_wifi_with_device(
    device: &CardV2Device,
    api_base: &str,
    wait: Duration,
    was_open_now: bool,
    prev_status: Option<reai_card_sdk::WifiStatus>,
    out: Emitter,
) -> Result<(Value, bool), String> {
    let server_info = OtaInfo::fetch(api_base, OtaModule::Wifi).await.ok();

    let mut status = match prev_status {
        Some(s) => Some(s),
        None if was_open_now => device.wifi_status().await.ok(),
        None => None,
    };
    if !was_open_now || status.as_ref().is_some_and(|s| s.status == "off" || !s.enabled) {
        out.progress(json!({"stage": "wifi", "percent": 3, "text": "正在自动开启录音卡 Wi-Fi 模块…"}));
        device
            .open_wifi()
            .await
            .map_err(|error| format!("自动开启 Wi-Fi 模块失败：{error}"))?;
        let _ = device.wait_for_ap_ready(Duration::from_secs(6)).await;
        // 等待 ESP32 完成 WIFI_SYNC，把最新 wifiVersion 同步给主控 BASE_INFO。
        tokio::time::sleep(Duration::from_millis(300)).await;
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
            return Ok((
                json!({
                    "module": "wifi",
                    "upToDate": true,
                    "version": status.as_ref().and_then(|s| s.version.clone()),
                    "versionCode": code,
                }),
                false,
            ));
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
            return Err(CardSdkError::InvalidCommand(msg.to_owned()).to_string());
        }
    }

    out.progress(json!({"stage": "wifi", "percent": 12, "text": "正在向服务器检查 Wi-Fi 固件…"}));
    let check = device.check_wifi_ota().await.map_err(|e| e.to_string())?;
    if !check.update_available {
        return Ok((
            json!({"module": "wifi", "upToDate": true, "check": check}),
            false,
        ));
    }

    let mut events = device.subscribe_events();
    device.start_wifi_ota().await.map_err(|e| e.to_string())?;

    let deadline = tokio::time::Instant::now() + wait;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(CardSdkError::Timeout {
                command: "OTA_WIFI".into(),
                seconds: wait.as_secs(),
            }
            .to_string());
        }
        match tokio::time::timeout(remaining, events.recv()).await {
            Ok(Ok(CardV2Event::WifiOtaProgress(progress))) => {
                if progress.status == reai_card_sdk::OtaStatus::Success {
                    out.progress(json!({
                        "stage": "wifi",
                        "percent": 96,
                        "text": "Wi-Fi 固件写入完成，正在重启同步版本…",
                    }));
                    // 等 ESP32 重启并发送 WIFI_AP_START / WIFI_SYNC（最多 10 秒），确保主控更新缓存版本号。
                    let sync_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
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
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    let _ = device.wifi_status().await;
                    let _ = device.device_info().await;
                    return Ok((json!({"module": "wifi", "progress": progress}), true));
                }
                if progress.status.is_terminal() {
                    return Err(
                        "Wi-Fi 模组固件下载或校验失败，已保留原版本运行，请检查网络信号后重试"
                            .to_owned(),
                    );
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
            Ok(Err(_)) => return Err(CardSdkError::Disconnected.to_string()),
            Err(_) => {
                return Err(CardSdkError::Timeout {
                    command: "OTA_WIFI".into(),
                    seconds: wait.as_secs(),
                }
                .to_string());
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
static ANDROID_VM: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// tokio 运行时线程启动钩子：把线程永久附加到 JavaVM。
/// droidplug 从任意线程调 `global_jvm().get_env()`，未附加线程会 `JniCall(ThreadDetached)`
/// （Jelly Star 2026-11-16 实测扫描挂此）。任务可在 worker 间迁移，必须按线程附加。
#[cfg(target_os = "android")]
fn ensure_jvm_thread_attached() {
    use std::sync::atomic::Ordering;
    let raw = ANDROID_VM.load(Ordering::SeqCst) as *mut jni::sys::JavaVM;
    if raw.is_null() {
        return;
    }
    if let Ok(vm) = unsafe { jni::JavaVM::from_raw(raw) } {
        let _ = vm.attach_current_thread_permanently();
    }
}

#[cfg(not(target_os = "android"))]
fn ensure_jvm_thread_attached() {}

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn JNI_OnLoad(
    vm: *mut jni::sys::JavaVM,
    _reserved: *mut core::ffi::c_void,
) -> jni::sys::jint {
    // Rust log! → logcat（tag "card_bridge"），btleplug/jni 内部错误由此落盘可见。
    // 必须显式 with_max_level，否则默认过滤吞掉 info（2026-11-16 Jelly Star 实测）。
    static LOGGER: std::sync::Once = std::sync::Once::new();
    LOGGER.call_once(|| {
        let _ = android_logger::init_once(
            android_logger::Config::default()
                .with_tag("card_bridge")
                .with_max_level(log::LevelFilter::Info),
        );
        // panic 默认输出到 /dev/null，真机上等于静默死亡——直通 logcat 才能排障。
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            alog::info(&format!("PANIC: {info}"));
            default_hook(info);
        }));
    });
    let result = std::panic::catch_unwind(|| {
        ANDROID_VM.store(vm as usize, std::sync::atomic::Ordering::SeqCst);
        let vm = unsafe { jni::JavaVM::from_raw(vm)? };
        let env = vm.attach_current_thread()?;
        btleplug::platform::init(&env)?;
        Ok::<(), Box<dyn std::error::Error>>(())
    });
    match result {
        Ok(Ok(())) => log::info!("Android BLE 平台初始化成功"),
        Ok(Err(error)) => log::error!("Android BLE 初始化失败: {error}"),
        Err(_) => log::error!("Android BLE 初始化 panic"),
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

    #[test]
    fn resolves_wifi_restore_mode_from_payload_or_hardware_state() {
        assert!(!should_restore_wifi_open(&json!({}), false));
        assert!(should_restore_wifi_open(&json!({}), true));
        assert!(!should_restore_wifi_open(&json!({"restoreWifiOpen": null}), false));
        assert!(should_restore_wifi_open(&json!({"restoreWifiOpen": null}), true));
        assert!(should_restore_wifi_open(&json!({"restoreWifiOpen": true}), false));
        assert!(!should_restore_wifi_open(&json!({"restoreWifiOpen": false}), true));
    }

    #[test]
    fn encodes_and_decodes_ble_wifi_credential_summary() {
        let empty = encode_ssid_list_kv(&[]);
        assert_eq!(empty, "0|");
        assert!(decode_ssid_list_kv(&empty).is_empty());

        let normal = encode_ssid_list_kv(&["Office-2.4G".into(), "Home".into()]);
        assert_eq!(normal, "2|Office-2.4G\nHome");
        assert_eq!(
            decode_ssid_list_kv(&normal),
            vec!["Office-2.4G".to_string(), "Home".to_string()]
        );

        // UTF-8 multibyte SSIDs truncated within 63-byte nRF KV cap without panicking
        let long = vec![
            "实验室无线路由器一二三四五六七".to_string(),
            "备用路由器甲乙丙丁".to_string(),
            "第三路由器".to_string(),
        ];
        let encoded = encode_ssid_list_kv(&long);
        assert!(encoded.len() <= 63);
        let decoded = decode_ssid_list_kv(&encoded);
        assert_eq!(decoded.len(), 3);
    }
}
