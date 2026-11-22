//! card_bridge —— 统一硬件桥（C ABI 单一入口），同时驱动三款自研蓝牙硬件：
//! - 录音卡 V2（`reai-card-sdk` v0.0.8，广播前缀 `DYJV2_`，IMA-ADPCM 16kHz）
//! - 点一机 V1（`reai-dyj-sdk` v0.1.x，广播前缀 `DYJ_`，AMR-WB 16kHz + 相机媒体 + SoftAP）
//! - 语音 AI 键盘 V2.1（`reai-board-sdk` v0.3.x，广播前缀 `REAI_VB_`，mSBC 16kHz Timeline Lease）
//!
//! 对上层 Dart 保持完全一致的 JSON 回调协议与 16kHz 单声道 i16 PCM 实时流契约。

pub mod amr_transcode;
pub mod capabilities;
pub mod card_v2_ble;
pub mod dyj_v1_session;
pub mod legacy_upgrade;

use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use btleplug::api::{
    Central as _, CentralEvent, Manager as _, Peripheral as _, PeripheralProperties, ScanFilter,
};
use futures::StreamExt;
use capabilities::{classify_ble_advertisement, DeviceKind};
use dyj_v1_session::{parse_dyj_audio_filename, version_code_from_semver, DyjV1Session};
use reai_ext_sdk::{RecorderDevice, RecorderSdkDriver, SdkDeviceEvent};
use reai_feishu_sdk::FeishuSdkDriver;
use reai_getseed_sdk::GetSeedSdkDriver;
use reai_omi_sdk::OmiSdkDriver;
use reai_board_sdk::kernel::audio::{
    AudioFrame, AudioStreamAction, AudioStreamScope, AudioTransport,
};
use reai_board_sdk::kernel::sink::AudioFrameSink;
use reai_board_sdk::{BoardConfig, BoardDevice, BoardEvent};
use card_v2_ble::CardV2ConnectOutcome;
use reai_card_sdk::{
    DeviceEvent as CardV2Event, DfuPackage, DyjDevice as CardV2Device, OtaInfo, OtaModule,
    SdkError as CardSdkError, NUS_SERVICE_UUID,
};
use reai_dyj_sdk::{
    ApClient as DyjV1ApClient, DeviceEvent as DyjV1Event, SdkError as DyjV1SdkError,
    ServerClient as DyjV1ServerClient,
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

#[derive(Clone, Debug, Default)]
struct DyjV1CachedMeta {
    device_id: Option<String>,
    fw_version: String,
    fw_version_code: u64,
    model: String,
    saved_ssids: Vec<String>,
}

impl DyjV1CachedMeta {
    fn record_saved_ssid(&mut self, ssid: &str) {
        let trimmed = ssid.trim();
        if trimmed.is_empty() {
            return;
        }
        if !self.saved_ssids.iter().any(|s| s == trimmed) {
            self.saved_ssids.push(trimmed.to_string());
        }
    }

    fn remove_saved_ssid(&mut self, ssid: &str) {
        let trimmed = ssid.trim();
        self.saved_ssids.retain(|s| s != trimmed);
    }
}

#[derive(Clone)]
enum ActiveDevice {
    CardV2 {
        device: CardV2Device,
        name: String,
    },
    CardV2DfuRecovery {
        id: String,
        name: String,
    },
    DyjV1 {
        device: Arc<DyjV1Session>,
        name: String,
        meta: Arc<Mutex<DyjV1CachedMeta>>,
        realtime_active: Arc<AtomicBool>,
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
            Self::CardV2 { .. } | Self::CardV2DfuRecovery { .. } => DeviceKind::CardV2,
            Self::DyjV1 { .. } => DeviceKind::DyjV1,
            Self::BoardV21 { .. } => DeviceKind::BoardV21,
            Self::External { kind, .. } => *kind,
        }
    }
}

struct BridgeState {
    runtime: tokio::runtime::Runtime,
    device: tokio::sync::Mutex<Option<ActiveDevice>>,
    connecting_peripheral: Mutex<Option<btleplug::platform::Peripheral>>,
    scan_adapter: tokio::sync::OnceCell<btleplug::platform::Adapter>,
    scan_cache: Mutex<HashMap<String, CachedScanEntry>>,
    event_pump: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    last_device_id: Mutex<Option<String>>,
    last_card_v2_target: Mutex<Option<(String, String)>>,
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
    " card-v2/0.0.8 dyj-v1/0.1 board-v21/0.3 getseed/0.1 omi/0.1 feishu/0.1"
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
        connecting_peripheral: Mutex::new(None),
        scan_adapter: tokio::sync::OnceCell::new(),
        scan_cache: Mutex::new(HashMap::new()),
        event_pump: tokio::sync::Mutex::new(None),
        last_device_id: Mutex::new(None),
        last_card_v2_target: Mutex::new(None),
        realtime_stop: Mutex::new(None),
        board_lease_seq: AtomicU32::new(1),
        events: Mutex::new(EventFeed::new()),
    })
}

fn emit_raw(cb: Callback, user_data: usize, value: Value) {
    let json = CString::new(value.to_string()).expect("no NUL in json");
    cb(user_data as *mut c_void, json.into_raw());
}

#[derive(Debug)]
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

impl From<DyjV1SdkError> for BridgeError {
    fn from(e: DyjV1SdkError) -> Self {
        let message = match &e {
            DyjV1SdkError::Disconnected { .. } => CardSdkError::Disconnected.to_string(),
            DyjV1SdkError::Device { code: 3001, msg } => {
                format!("点一机忙碌或存储空间不足（3001）：{msg}")
            }
            DyjV1SdkError::Device { code: 3003, msg } => {
                format!("点一机尚未连接 Wi-Fi（3003）：{msg}")
            }
            DyjV1SdkError::Device { code: 3401, msg } => {
                format!("点一机需要开启系统定位开关后才能扫描 Wi-Fi（3401）：{msg}")
            }
            _ => e.to_string(),
        };
        Self {
            message,
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
        "disconnect" => {
            state()
                .last_card_v2_target
                .lock()
                .expect("card v2 target lock")
                .take();
            out.ok(release_device().await);
        }
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
        "camera_capture_and_fetch" => {
            let dir = str_field(&payload, "dir");
            let server_origin = payload
                .get("serverOrigin")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let active = active_device().await?;
            out.ok(camera_capture_and_fetch(&active, &dir, server_origin.as_deref()).await?);
        }
        "dyj_button_status" => {
            let active = active_device().await?;
            out.ok(dyj_button_status(&active).await?);
        }
        "dyj_led_hint" => {
            let mode = str_field(&payload, "mode");
            let active = active_device().await?;
            out.ok(dyj_led_hint(&active, &mode).await?);
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
        "legacy_upgrade_open" => {
            let adapter = scan_adapter().await?;
            out.ok(legacy_upgrade::open_session(adapter, &payload).await?);
        }
        "legacy_upgrade_scan_wifi" => out.ok(legacy_upgrade::scan_wifi().await?),
        "legacy_upgrade_connect_wifi" => out.ok(legacy_upgrade::connect_wifi(&payload).await?),
        "legacy_upgrade_run_ota" => {
            let stream_out = out;
            match legacy_upgrade::run_ota(&|p| stream_out.progress(p)).await {
                Ok(data) => out.ok(data),
                Err(err) => out.fail(err.message),
            }
        }
        "legacy_upgrade_close" => out.ok(legacy_upgrade::close_session().await),
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

fn now_unix_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 已知全部蓝牙录音硬件服务 UUID（用于向 CoreBluetooth 查询已被系统保持连接的设备，
/// 避免已连接设备不对外广播而进入扫描死循环）。
pub(crate) fn known_hardware_service_uuids() -> Vec<uuid::Uuid> {
    let mut out = Vec::new();
    for s in [NUS_SERVICE_UUID, reai_card_sdk::DFU_SERVICE_UUID] {
        if let Ok(u) = uuid::Uuid::parse_str(s) {
            out.push(u);
        }
    }
    out.push(uuid::Uuid::from_u128(0x0000ff10_0000_1000_8000_00805f9b34fb));
    out.push(reai_board_sdk::kernel::protocol_gatt::SERVICE_UUID);
    out.push(uuid::Uuid::from_u128(0x0000fe60_0000_1000_8000_00805f9b34fb));
    out.push(reai_getseed_sdk::protocol::SVC_CTL_UUID);
    out.push(reai_omi_sdk::protocol::SVC_OMI_AUDIO_UUID);
    out.push(reai_feishu_sdk::SERVICE_UUID);
    out
}

#[cfg(target_vendor = "apple")]
pub(crate) async fn retrieve_cached_or_connected_peripherals(
    adapter: &btleplug::platform::Adapter,
    id_hints: &[&str],
    services: &[uuid::Uuid],
) -> Vec<btleplug::platform::Peripheral> {
    let identifiers: Vec<uuid::Uuid> = id_hints
        .iter()
        .filter_map(|raw| uuid::Uuid::parse_str(raw.trim()).ok())
        .collect();
    if identifiers.is_empty() && services.is_empty() {
        return Vec::new();
    }
    match tokio::time::timeout(
        Duration::from_secs(2),
        adapter.retrieve_peripherals(&identifiers, services),
    )
    .await
    {
        Ok(Ok(list)) => list,
        _ => Vec::new(),
    }
}

#[cfg(not(target_vendor = "apple"))]
pub(crate) async fn retrieve_cached_or_connected_peripherals(
    _adapter: &btleplug::platform::Adapter,
    _id_hints: &[&str],
    _services: &[uuid::Uuid],
) -> Vec<btleplug::platform::Peripheral> {
    Vec::new()
}

pub(crate) async fn retrieve_system_connected_ids(
    adapter: &btleplug::platform::Adapter,
    services: &[uuid::Uuid],
) -> HashSet<String> {
    if services.is_empty() {
        return HashSet::new();
    }
    retrieve_cached_or_connected_peripherals(adapter, &[], services)
        .await
        .into_iter()
        .map(|p| p.id().to_string())
        .collect()
}

/// droidplug 的 properties() 是同步 Mutex 锁（真机实测会被 Java 回调线程卡死，
/// 直接 await 会把 tokio worker 整个挂住）。丢进 blocking 池 + 有界超时。
pub(crate) async fn read_peripheral_props_bounded(
    p: &btleplug::platform::Peripheral,
) -> Option<PeripheralProperties> {
    let p = p.clone();
    match tokio::time::timeout(
        Duration::from_millis(400),
        tokio::task::spawn_blocking(move || tokio::runtime::Handle::current().block_on(p.properties())),
    )
    .await
    {
        Ok(Ok(Ok(props))) => props,
        _ => None,
    }
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
    // 这里订阅扫描窗口内的事件流，记录「本窗口确实广播过」的设备及最后收到广播的墙钟时刻。
    let mut scan_events = adapter
        .events()
        .await
        .map_err(|e| BridgeError::from(format!("BLE events failed: {e}")))?;
    let mut seen_this_scan: HashMap<String, i64> = HashMap::new();
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
            seen_this_scan.insert(id.to_string(), now_unix_ms());
        }
    };
    let _ = tokio::time::timeout(duration, pump).await;
    alog::info(&format!(
        "unified_scan: sleep done, {} advertised this window",
        seen_this_scan.len()
    ));
    let _ = adapter.stop_scan().await;
    let scan_completed_at_ms = now_unix_ms();
    alog::info("unified_scan: stopped");

    // 主动向系统蓝牙栈找回“已被系统连接因此不再广播”的本系硬件，防止回 App 扫描为空陷入死循环。
    let last_id = state()
        .last_device_id
        .lock()
        .expect("device id lock")
        .clone();
    let known_services = known_hardware_service_uuids();
    let system_connected = retrieve_system_connected_ids(adapter, &known_services).await;
    if let Some(lid) = last_id.as_deref() {
        let _ = retrieve_cached_or_connected_peripherals(adapter, &[lid], &[]).await;
    }

    let peripherals = adapter
        .peripherals()
        .await
        .map_err(|e| BridgeError::from(format!("BLE peripherals failed: {e}")))?;
    alog::info(&format!(
        "unified_scan: {} peripherals ({} system-connected)",
        peripherals.len(),
        system_connected.len()
    ));

    let mut discovered: Vec<(i16, String, String, String, Value)> = Vec::new();
    let mut cache_updates: Vec<(String, CachedScanEntry)> = Vec::new();

    for (idx, p) in peripherals.into_iter().enumerate() {
        if idx % 10 == 0 {
            alog::info(&format!("unified_scan: loop[{idx}] begin"));
        }
        let Some(props) = read_peripheral_props_bounded(&p).await else {
            alog::info(&format!("unified_scan: loop[{idx}] properties 卡死/失败，跳过"));
            continue;
        };
        let id = p.id().to_string();
        let is_system_connected = system_connected.contains(&id);
        // 2026-11-16 调试直连结束，恢复过滤基线：未识别设备直接跳过
        // （classify 覆盖自有 3 款硬件 + 开启联动的 Get/Omi/Watch）。
        let classified = classify_ble_advertisement(
            &id,
            props.local_name.as_deref(),
            &props.services,
            &props.manufacturer_data,
        )
        .or_else(|| {
            if !is_system_connected {
                return None;
            }
            let cached = state()
                .scan_cache
                .lock()
                .expect("scan cache lock")
                .get(&id)
                .cloned()?;
            Some((cached.name, cached.kind, cached.kind.capabilities()))
        });
        let Some((name, kind, caps)) = classified else {
            continue;
        };
        let kind_str = kind.as_str();
        let display_model = kind.display_model();
        let caps_json = serde_json::to_value(&caps).unwrap_or(serde_json::Value::Null);
        // CoreBluetooth 本地缓存但未广播的旧外设通常无 RSSI；若已系统连接则仍展示。
        // RSSI 0/127 为无效值（CoreBluetooth 偶发上报 127），一并走兜底。
        let last_seen_at_ms = seen_this_scan.get(&id).copied();
        let advertised_now = last_seen_at_ms.is_some();
        let props_rssi = props.rssi.filter(|r| *r < 0);
        // CoreBluetooth 会把旧外设及其历史 rssi 长期留在 adapter.peripherals() 里，哪怕设备早已断开或轮换了 RPA 地址。
        // 若本扫描窗口完全没收到它的广播，仅当系统仍处于已连接状态时才保留，绝不把过期 RPA 当作新发现返回。
        let rssi = if advertised_now {
            props_rssi.unwrap_or(-60)
        } else if is_system_connected {
            props_rssi.unwrap_or(-55)
        } else {
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
                props_rssi.unwrap_or(-58)
            } else {
                continue;
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
            kind_str.to_string(),
            name.clone(),
            json!({
                "id": id,
                "name": name,
                "rssi": rssi,
                "lastSeenAtMs": last_seen_at_ms.unwrap_or(scan_completed_at_ms),
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

    // 去重（同款同名设备只保留信号最强的一条，防 RPA 轮换留下双重条目），按 RSSI 从强到弱排序
    discovered.sort_by(|a, b| b.0.cmp(&a.0));
    let mut seen_ids = std::collections::HashSet::new();
    let mut seen_names = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(discovered.len());
    alog::info(&format!("unified_scan: classified {} devices", discovered.len()));
    for (_, id, kind_str, name, val) in discovered {
        if !seen_ids.insert(id) {
            continue;
        }
        let trimmed = name.trim();
        if !trimmed.is_empty() && !seen_names.insert(format!("{kind_str}:{trimmed}")) {
            continue;
        }
        out.push(val);
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

    release_device_except((!id.is_empty()).then_some(id.as_str())).await;

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
        DeviceKind::GetSeedGsc10 | DeviceKind::OmiCv1 | DeviceKind::FeishuD3200 => {
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

pub(crate) fn matches_card_v2_candidate(
    pid: &str,
    id_hint: &str,
    name_hint: Option<&str>,
    local_name: Option<&str>,
    services: &[uuid::Uuid],
) -> Option<String> {
    let trimmed_hint = name_hint.map(str::trim).filter(|s| !s.is_empty());
    let trimmed_local = local_name.map(str::trim).filter(|s| !s.is_empty());
    let is_dfu = capabilities::is_card_v2_dfu_advertisement(trimmed_local, services);
    if let (Some(nh), Some(ln)) = (trimmed_hint, trimmed_local) {
        if nh != ln && !(nh.eq_ignore_ascii_case("DFU_DYJ") && is_dfu) {
            return None;
        }
    }
    if let Some(nh) = trimmed_hint {
        if trimmed_local == Some(nh) {
            return Some(nh.to_string());
        }
        if nh.eq_ignore_ascii_case("DFU_DYJ") && is_dfu {
            return Some(trimmed_local.unwrap_or(nh).to_string());
        }
    }
    let nus_uuid = uuid::Uuid::parse_str(NUS_SERVICE_UUID).ok();
    let id_match = !id_hint.is_empty() && pid == id_hint;
    if id_match {
        let valid_identity = trimmed_local.is_none()
            || trimmed_local.is_some_and(|n| {
                let u = n.to_ascii_uppercase();
                u.starts_with("DYJV2") || u.starts_with("DYJ") || u.starts_with("DFU")
            })
            || nus_uuid.is_some_and(|u| services.contains(&u))
            || is_dfu;
        if valid_identity {
            return Some(
                trimmed_local
                    .or(trimmed_hint)
                    .unwrap_or(pid)
                    .to_string(),
            );
        }
    }
    None
}

fn matches_external_candidate(
    driver: &dyn RecorderSdkDriver,
    pid: &str,
    id_hint: &str,
    name_hint: Option<&str>,
    local_name: Option<&str>,
    services: &[uuid::Uuid],
    manufacturer_data: &HashMap<u16, Vec<u8>>,
) -> Option<String> {
    let trimmed_hint = name_hint.map(str::trim).filter(|s| !s.is_empty());
    let trimmed_local = local_name.map(str::trim).filter(|s| !s.is_empty());
    if let (Some(nh), Some(ln)) = (trimmed_hint, trimmed_local) {
        if nh != ln {
            return None;
        }
    }
    let adv_match = driver.matches_advertisement(trimmed_local, services, manufacturer_data);
    let id_match = !id_hint.is_empty() && pid == id_hint;
    let name_match = trimmed_hint.is_some_and(|nh| trimmed_local == Some(nh)) && adv_match;
    if id_match || name_match {
        return Some(
            trimmed_local
                .or(trimmed_hint)
                .map(str::to_owned)
                .unwrap_or_else(|| driver.fallback_ble_name(pid)),
        );
    }
    None
}

async fn try_connect_peripheral_with_slot(
    p: &btleplug::platform::Peripheral,
    label: &str,
    timeout: Duration,
    connecting_slot: &Mutex<Option<btleplug::platform::Peripheral>>,
) -> Result<(), BridgeError> {
    *connecting_slot.lock().unwrap() = Some(p.clone());
    let res = tokio::time::timeout(timeout, p.connect()).await;
    match res {
        Ok(Ok(())) => {
            *connecting_slot.lock().unwrap() = None;
            Ok(())
        }
        Ok(Err(e)) => {
            *connecting_slot.lock().unwrap() = None;
            let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
            Err(BridgeError::from(format!("连接{label}失败: {e}")))
        }
        Err(_) => {
            *connecting_slot.lock().unwrap() = None;
            let _ = tokio::time::timeout(Duration::from_secs(2), p.disconnect()).await;
            Err(BridgeError::from(format!(
                "连接{label}超时，请确认设备已开机且在蓝牙范围内"
            )))
        }
    }
}

/// 统一实时扫描 + RPA 地址容错建连：
/// 1. 若刚扫到精确 `id_hint`，用 4 秒短超时直连；若发生 RPA 轮换或已离线，显式断开取消挂起链路；
/// 2. 随后开启 `adapter.events()` 实时监听本轮真正广播出的匹配设备并建连（14 秒超时），避免命中缓存僵尸外设。
async fn connect_fresh_peripheral<F>(
    adapter: &btleplug::platform::Adapter,
    id_hint: &str,
    label: &str,
    connecting_slot: &Mutex<Option<btleplug::platform::Peripheral>>,
    matcher: F,
) -> Result<(btleplug::platform::Peripheral, String), BridgeError>
where
    F: Fn(&str, Option<&PeripheralProperties>) -> Option<String>,
{
    struct SlotGuard<'a>(&'a Mutex<Option<btleplug::platform::Peripheral>>);
    impl Drop for SlotGuard<'_> {
        fn drop(&mut self) {
            *self.0.lock().unwrap() = None;
        }
    }
    let _guard = SlotGuard(connecting_slot);
    let mut last_err: Option<BridgeError> = None;

    let id_hint_arr = [id_hint];
    let id_hints: &[&str] = if id_hint.is_empty() { &[] } else { &id_hint_arr };
    let retrieved = retrieve_cached_or_connected_peripherals(
        adapter,
        id_hints,
        &known_hardware_service_uuids(),
    )
    .await;

    if !id_hint.is_empty() {
        if let Ok(peripherals) = adapter.peripherals().await {
            if let Some(cached) = peripherals.into_iter().find(|p| p.id().to_string() == id_hint) {
                let props = read_peripheral_props_bounded(&cached).await;
                if let Some(display_name) = matcher(id_hint, props.as_ref()) {
                    match try_connect_peripheral_with_slot(
                        &cached,
                        label,
                        Duration::from_secs(4),
                        connecting_slot,
                    )
                    .await
                    {
                        Ok(()) => return Ok((cached, display_name)),
                        Err(e) => last_err = Some(e),
                    }
                }
            }
        }
    }

    for cached in retrieved {
        let pid = cached.id().to_string();
        if pid == id_hint {
            continue;
        }
        let is_conn = matches!(
            tokio::time::timeout(Duration::from_millis(350), cached.is_connected()).await,
            Ok(Ok(true))
        );
        if !is_conn {
            continue;
        }
        let props = read_peripheral_props_bounded(&cached).await;
        if let Some(display_name) = matcher(&pid, props.as_ref()) {
            match try_connect_peripheral_with_slot(
                &cached,
                label,
                Duration::from_secs(4),
                connecting_slot,
            )
            .await
            {
                Ok(()) => return Ok((cached, display_name)),
                Err(e) => last_err = Some(e),
            }
        }
    }

    let mut events = adapter
        .events()
        .await
        .map_err(|e| BridgeError::from(format!("BLE 扫描事件流失败: {e}")))?;
    adapter
        .start_scan(ScanFilter::default())
        .await
        .map_err(|e| BridgeError::from(format!("BLE 扫描启动失败: {e}")))?;

    let scan_deadline = tokio::time::Instant::now() + Duration::from_secs(12);
    let mut fresh: Option<(btleplug::platform::Peripheral, String)> = None;
    loop {
        let now = tokio::time::Instant::now();
        if now >= scan_deadline {
            break;
        }
        let rem = scan_deadline.saturating_duration_since(now);
        let ev = match tokio::time::timeout(rem, events.next()).await {
            Ok(Some(ev)) => ev,
            _ => break,
        };
        let ev_id = match ev {
            CentralEvent::DeviceDiscovered(id)
            | CentralEvent::DeviceUpdated(id)
            | CentralEvent::ManufacturerDataAdvertisement { id, .. }
            | CentralEvent::ServiceDataAdvertisement { id, .. }
            | CentralEvent::ServicesAdvertisement { id, .. } => id,
            _ => continue,
        };
        if let Ok(p) = adapter.peripheral(&ev_id).await {
            let pid = ev_id.to_string();
            let props = read_peripheral_props_bounded(&p).await;
            if let Some(display_name) = matcher(&pid, props.as_ref()) {
                fresh = Some((p, display_name));
                break;
            }
        }
    }
    let _ = adapter.stop_scan().await;
    tokio::time::sleep(Duration::from_millis(120)).await;

    let Some((fresh_peripheral, display_name)) = fresh else {
        return Err(last_err.unwrap_or_else(|| {
            BridgeError::from(format!(
                "未扫描到设备 {label}（id={id_hint}），请确认设备已开机且在蓝牙范围内"
            ))
        }));
    };

    try_connect_peripheral_with_slot(
        &fresh_peripheral,
        label,
        Duration::from_secs(14),
        connecting_slot,
    )
    .await?;
    Ok((fresh_peripheral, display_name))
}

async fn connect_card_v2(id: &str, name_hint: Option<&str>) -> Result<Value, BridgeError> {
    let adapter = scan_adapter().await?;
    match card_v2_ble::connect_card_v2_on_adapter(
        adapter,
        id,
        name_hint,
        Some(&state().connecting_peripheral),
    )
    .await?
    {
        CardV2ConnectOutcome::Connected {
            device,
            id: actual_id,
            name: connected_name,
        } => {
            bootstrap_card_v2_ble_metadata_if_missing(&device).await;
            let pump = spawn_card_v2_event_pump(&device);
            *state().event_pump.lock().await = Some(pump);
            *state().last_device_id.lock().expect("device id lock") = Some(actual_id.clone());
            *state()
                .last_card_v2_target
                .lock()
                .expect("card v2 target lock") = Some((actual_id.clone(), connected_name.clone()));
            state().scan_cache.lock().expect("scan cache lock").insert(
                actual_id,
                CachedScanEntry {
                    name: connected_name.clone(),
                    kind: DeviceKind::CardV2,
                },
            );
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
        CardV2ConnectOutcome::DfuRecovery {
            id: actual_id,
            name: dfu_name,
        } => {
            *state().event_pump.lock().await = None;
            *state().last_device_id.lock().expect("device id lock") = Some(actual_id.clone());
            state().scan_cache.lock().expect("scan cache lock").insert(
                actual_id.clone(),
                CachedScanEntry {
                    name: dfu_name.clone(),
                    kind: DeviceKind::CardV2,
                },
            );
            *state().device.lock().await = Some(ActiveDevice::CardV2DfuRecovery {
                id: actual_id,
                name: dfu_name.clone(),
            });
            Ok(json!({
                "connected": true,
                "name": dfu_name,
                "deviceKind": DeviceKind::CardV2.as_str(),
                "displayModel": "录音卡 V2（恢复模式）",
                "capabilities": capabilities::card_v2_dfu_recovery_capabilities(),
            }))
        }
    }
}

fn update_dyj_v1_meta_from_info(meta: &Arc<Mutex<DyjV1CachedMeta>>, info: &Value) {
    let mut guard = meta.lock().unwrap();
    if let Some(did) = info.get("device_id").and_then(Value::as_str).filter(|s| !s.is_empty()) {
        guard.device_id = Some(did.to_string());
    }
    if let Some(ver) = info
        .get("app_version")
        .or_else(|| info.get("version"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        guard.fw_version = ver.to_string();
        if guard.fw_version_code == 0 {
            guard.fw_version_code = version_code_from_semver(ver);
        }
    }
    if let Some(code) = info
        .get("version_code")
        .or_else(|| info.get("app_version_code"))
        .or_else(|| info.get("versionCode"))
        .and_then(Value::as_u64)
        .filter(|&c| c > 0)
    {
        guard.fw_version_code = code;
    }
    if let Some(model) = info.get("model").and_then(Value::as_str).filter(|s| !s.is_empty()) {
        guard.model = model.to_string();
    }
}

async fn connect_dyj_v1(id: &str, name: &str) -> Result<Value, BridgeError> {
    let adapter = scan_adapter().await?;
    let (device, hello) =
        DyjV1Session::connect(adapter, id, name, Some(&state().connecting_peripheral)).await?;
    let actual_id = device.peripheral().id().to_string();
    let mut initial_meta = DyjV1CachedMeta::default();
    if let Some(did) = hello
        .get("device_id")
        .or_else(|| hello.get("deviceId"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        initial_meta.device_id = Some(did.to_string());
    }
    if let Some(ver) = hello
        .get("app_version")
        .or_else(|| hello.get("fw_version"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        initial_meta.fw_version = ver.to_string();
        initial_meta.fw_version_code = version_code_from_semver(ver);
    }
    let meta = Arc::new(Mutex::new(initial_meta));
    // 尽量用 hello 信息建连，首轮 snapshot 会按需补齐 device.info 与 wifi_status；
    // 对时与按键模式检查异步延后执行，避免阻塞握手并挤占首包指令通道。
    let bg_device = Arc::downgrade(&device);
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let Some(dev) = bg_device.upgrade() else {
            return;
        };
        if !dev.is_connected().await.unwrap_or(false) {
            return;
        }
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        if now_ms > 0 {
            let _ = dev.device_time(Some(now_ms)).await;
        }
        dev.ensure_buttons_event_only().await;
    });
    let pump = spawn_dyj_v1_event_pump(&device);
    *state().event_pump.lock().await = Some(pump);
    *state().last_device_id.lock().expect("device id lock") = Some(actual_id.clone());
    state().scan_cache.lock().expect("scan cache lock").insert(
        actual_id,
        CachedScanEntry {
            name: name.to_string(),
            kind: DeviceKind::DyjV1,
        },
    );
    *state().device.lock().await = Some(ActiveDevice::DyjV1 {
        device,
        name: name.to_string(),
        meta,
        realtime_active: Arc::new(AtomicBool::new(false)),
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
    let driver: &dyn RecorderSdkDriver = match kind {
        DeviceKind::GetSeedGsc10 => &GetSeedSdkDriver,
        DeviceKind::OmiCv1 => &OmiSdkDriver,
        DeviceKind::FeishuD3200 => &FeishuSdkDriver,
        _ => {
            return Err(BridgeError::from(format!(
                "非第三方 SDK 设备类型: {}",
                kind.as_str()
            )))
        }
    };

    let adapter = scan_adapter().await?;
    let label = name_hint
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(kind.display_model());
    let (peripheral, ble_name) = connect_fresh_peripheral(
        adapter,
        id,
        label,
        &state().connecting_peripheral,
        |pid, props| {
            let local_name = props.and_then(|pr| pr.local_name.as_deref());
            let services = props.map(|pr| pr.services.as_slice()).unwrap_or(&[]);
            let mfd = props.map(|pr| &pr.manufacturer_data);
            match mfd {
                Some(data) => matches_external_candidate(
                    driver, pid, id, name_hint, local_name, services, data,
                ),
                None => {
                    let empty_mfd = HashMap::new();
                    matches_external_candidate(
                        driver, pid, id, name_hint, local_name, services, &empty_mfd,
                    )
                }
            }
        },
    )
    .await?;

    let actual_id = peripheral.id().to_string();
    let device = driver.connect(peripheral, ble_name.clone()).await?;
    let connected_name = device.device_name().to_string();
    let caps = capabilities::HardwareCapabilities::from_sdk(device.capabilities());
    let pump = spawn_external_event_pump(&device);
    *state().event_pump.lock().await = Some(pump);
    *state().last_device_id.lock().expect("device id lock") = Some(actual_id.clone());
    state().scan_cache.lock().expect("scan cache lock").insert(
        actual_id,
        CachedScanEntry {
            name: connected_name.clone(),
            kind,
        },
    );
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
    release_device_except(None).await
}

async fn release_device_except(keep_id: Option<&str>) -> Value {
    if let Some(pump) = state().event_pump.lock().await.take() {
        pump.abort();
    }
    let stop = state().realtime_stop.lock().expect("realtime lock").take();
    if let Some(stop) = stop {
        let _ = stop.send(());
    }
    let active = state().device.lock().await.take();
    let connecting = state().connecting_peripheral.lock().unwrap().take();
    if let Some(p) = connecting {
        if keep_id != Some(p.id().to_string().as_str()) {
            let _ = tokio::time::timeout(Duration::from_secs(3), p.disconnect()).await;
        }
    }
    // 兜底释放：若此前某次 connect 超时或半连接遗留在 CoreBluetooth，把 adapter 里仍连着的 DYJ_/DYJV2_/DFU 外设也断开。
    // 当正在直接重连 keep_id 时，保留该系统连接句柄以免把刚找回的 OS 链接先掐断再重扫。
    if let Some(adapter) = state().scan_adapter.get() {
        if let Ok(peripherals) = adapter.peripherals().await {
            for p in peripherals {
                if keep_id == Some(p.id().to_string().as_str()) {
                    continue;
                }
                if let Ok(true) = tokio::time::timeout(Duration::from_millis(350), p.is_connected())
                    .await
                    .unwrap_or(Ok(false))
                {
                    let is_reai_ble = read_peripheral_props_bounded(&p)
                        .await
                        .and_then(|pr| pr.local_name)
                        .is_some_and(|n| {
                            let t = n.trim();
                            t.starts_with("DYJ_")
                                || t.starts_with("DYJV2_")
                                || t.to_ascii_uppercase().starts_with("DFU")
                        });
                    if is_reai_ble {
                        let _ = tokio::time::timeout(Duration::from_secs(3), p.disconnect()).await;
                    }
                }
            }
        }
    }
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
        Some(ActiveDevice::CardV2DfuRecovery { .. }) => json!("ok"),
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

fn map_dyj_v1_event_to_json(
    evt: &str,
    ts: u64,
    data: Value,
    received_at_ms: u64,
) -> Option<Value> {
    let mapped = match evt {
        "record.segment" => json!({
            "kind": "record_segment",
            "ts": ts,
            "data": data,
        }),
        "record.state" | "record.stop" | "record.error" => {
            let is_rec = data
                .get("recording")
                .or_else(|| data.get("isRecording"))
                .or_else(|| data.get("is_recording"))
                .and_then(Value::as_bool)
                .unwrap_or(evt != "record.stop" && evt != "record.error");
            json!({
                "kind": "record",
                "status": {
                    "isRecording": is_rec,
                    "session": data.get("session"),
                    "error": data.get("error").or_else(|| data.get("code")),
                },
            })
        }
        _ if evt == "button.event" || evt.starts_with("button.") => {
            let suffix = evt.strip_prefix("button.").unwrap_or("");
            let btn_type = data
                .get("type")
                .or_else(|| data.get("gesture"))
                .or_else(|| data.get("event"))
                .or_else(|| data.get("action"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty() && *s != "event")
                .unwrap_or(suffix);
            if matches!(
                btn_type,
                "down"
                    | "up"
                    | "click"
                    | "double_click"
                    | "long_press"
                    | "long_press_start"
                    | "long_press_end"
            ) {
                let duration_ms = data
                    .get("duration_ms")
                    .or_else(|| data.get("durationMs"))
                    .cloned()
                    .unwrap_or(Value::Null);
                json!({
                    "kind": "button",
                    "gesture": btn_type,
                    "durationMs": duration_ms,
                    "deviceTs": ts,
                    "receivedAtMs": received_at_ms,
                })
            } else {
                return None;
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
        "ota.progress" => json!({
            "kind": "ota",
            "evt": evt,
            "ts": ts,
            "data": data,
        }),
        _ if evt.starts_with("battery.") => {
            let level = data.get("level").and_then(Value::as_u64);
            let status_str = data.get("status").and_then(Value::as_str).unwrap_or("");
            let plugged = data.get("plugged").and_then(Value::as_i64).unwrap_or(0);
            let charging = data
                .get("isCharging")
                .or_else(|| data.get("charging"))
                .and_then(Value::as_bool)
                .unwrap_or_else(|| status_str == "charging" || plugged != 0);
            json!({
                "kind": "power",
                "battery": {
                    "level": level,
                    "isCharging": charging,
                },
                "power": data,
            })
        }
        _ => return None,
    };
    Some(mapped)
}

fn spawn_dyj_v1_event_pump(device: &DyjV1Session) -> tokio::task::JoinHandle<()> {
    let mut events = device.subscribe_events();
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(DyjV1Event::Event { evt, ts, data }) => {
                    let received_at_ms = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_millis() as u64)
                        .unwrap_or(0);
                    if let Some(value) = map_dyj_v1_event_to_json(&evt, ts, data, received_at_ms) {
                        state().events.lock().expect("events lock").push(value);
                    }
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

fn build_dyj_v1_snapshot_json(
    kind: DeviceKind,
    name: &str,
    meta: &DyjV1CachedMeta,
    batt_raw: &Value,
    stor_raw: &Value,
    rec_raw: &Value,
    wifi_raw: &Value,
    realtime_enabled: bool,
) -> Value {
    let level = batt_raw.get("level").and_then(Value::as_u64);
    let status_str = batt_raw.get("status").and_then(Value::as_str).unwrap_or("");
    let plugged = batt_raw.get("plugged").and_then(Value::as_i64).unwrap_or(0);
    let charging = status_str == "charging" || plugged != 0;

    let total_bytes = stor_raw.get("data_total_bytes").and_then(Value::as_u64);
    let free_bytes = stor_raw.get("data_free_bytes").and_then(Value::as_u64);
    let used_bytes = match (total_bytes, free_bytes) {
        (Some(t), Some(f)) => Some(t.saturating_sub(f)),
        _ => None,
    };
    let total_mb = total_bytes.map(|b| b / (1024 * 1024));
    let used_mb = used_bytes.map(|b| b / (1024 * 1024));
    let storage_val = match (total_mb, used_mb) {
        (Some(t), Some(u)) => json!({
            "total": t,
            "used": u,
            "totalBytes": total_bytes,
            "freeBytes": free_bytes,
            "usedBytes": used_bytes,
        }),
        _ => Value::Null,
    };

    let recording = rec_raw
        .get("recording")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let wifi_enabled = wifi_raw
        .get("wifi_enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let wifi_ssid = wifi_raw
        .get("ssid")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let wifi_state = wifi_raw.get("state").and_then(Value::as_str).unwrap_or("");
    let wifi_ip = wifi_raw
        .get("ip")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let wifi_connected =
        wifi_state.eq_ignore_ascii_case("connected") || (wifi_ssid.is_some() && wifi_ip.is_some());

    json!({
        "deviceKind": kind.as_str(),
        "displayModel": kind.display_model(),
        "deviceName": name,
        "capabilities": kind.capabilities(),
        "battery": {
            "level": level,
            "isCharging": charging,
            "charging": charging,
        },
        "state": {
            "recording": recording,
            "wifiOpen": wifi_enabled,
            "wifiEnabled": wifi_enabled,
            "wifiConnected": wifi_connected,
            "ssid": wifi_ssid,
            "ip": wifi_ip,
        },
        "info": {
            "version": meta.fw_version,
            "firmwareVersion": meta.fw_version,
            "versionCode": meta.fw_version_code,
            "deviceName": name,
            "deviceId": meta.device_id,
            "wifiVersion": "",
            "wifiVersionCode": 0,
            "model": (!meta.model.is_empty()).then_some(meta.model.as_str()),
        },
        "storage": storage_val,
        "record": {
            "isRecording": recording,
            "recording": recording,
            "realtimeEnabled": realtime_enabled,
            "session": rec_raw.get("session"),
            "currentFile": rec_raw.get("current_file"),
            "files": rec_raw.get("files"),
        },
    })
}

fn is_dyj_disconnected_err<T>(res: &Result<T, DyjV1SdkError>) -> bool {
    matches!(res, Err(DyjV1SdkError::Disconnected { .. }))
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
        ActiveDevice::CardV2DfuRecovery { id, name } => Ok(json!({
            "deviceKind": kind.as_str(),
            "displayModel": "录音卡 V2（恢复模式）",
            "deviceName": name,
            "capabilities": capabilities::card_v2_dfu_recovery_capabilities(),
            "battery": {
                "level": 0,
                "isCharging": false,
            },
            "state": {
                "wifiOpen": false,
                "recording": false,
            },
            "info": {
                "version": "恢复模式",
                "versionCode": 1,
                "deviceName": name,
                "deviceId": id,
                "wifiVersion": "",
                "wifiVersionCode": 0,
            },
            "storage": Value::Null,
            "record": {
                "isRecording": false,
            },
        })),
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
            meta,
            realtime_active,
        } => {
            if !device.is_connected().await.unwrap_or(false) {
                return Err(BridgeError::disconnected());
            }
            let need_info = {
                let g = meta.lock().unwrap();
                g.fw_version.is_empty() || g.device_id.is_none()
            };
            if need_info {
                if let Ok(info_raw) = device.device_info(false).await {
                    update_dyj_v1_meta_from_info(meta, &info_raw);
                }
            }
            let batt_res = device.battery().await;
            let stor_res = device.storage().await;
            let rec_res = device.record_status().await;
            let wifi_res = device.wifi_status().await;
            if is_dyj_disconnected_err(&batt_res)
                && is_dyj_disconnected_err(&stor_res)
                && is_dyj_disconnected_err(&rec_res)
                && is_dyj_disconnected_err(&wifi_res)
            {
                return Err(BridgeError::disconnected());
            }
            let batt_raw = batt_res.unwrap_or(Value::Null);
            let stor_raw = stor_res.unwrap_or(Value::Null);
            let rec_raw = rec_res.unwrap_or(Value::Null);
            let wifi_raw = wifi_res.unwrap_or(Value::Null);
            if let Some(ssid) = wifi_raw
                .get("ssid")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
            {
                meta.lock().unwrap().record_saved_ssid(ssid);
            }
            let cached_meta = meta.lock().unwrap().clone();
            Ok(build_dyj_v1_snapshot_json(
                kind,
                name,
                &cached_meta,
                &batt_raw,
                &stor_raw,
                &rec_raw,
                &wifi_raw,
                realtime_active.load(Ordering::SeqCst),
            ))
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
            ActiveDevice::CardV2DfuRecovery { .. } => Err(BridgeError::from(
                "录音卡处于恢复模式，请先完成固件升级".to_string(),
            )),
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
        ActiveDevice::CardV2DfuRecovery { .. } => Err(BridgeError::from(
            "录音卡处于恢复模式，请先完成固件升级".to_string(),
        )),
    }
}

async fn record_stop(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.raw_command("RECORD_STOP", None).await?),
        ActiveDevice::DyjV1 {
            device,
            realtime_active,
            ..
        } => {
            let res = device.record_stop().await?;
            if !realtime_active.load(Ordering::SeqCst) {
                let _ = device.audio_capture_stop().await;
            }
            Ok(res)
        }
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
        ActiveDevice::CardV2DfuRecovery { .. } => Err(BridgeError::from(
            "录音卡处于恢复模式，请先完成固件升级".to_string(),
        )),
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
        ActiveDevice::CardV2DfuRecovery { .. } => Err(BridgeError::from(
            "录音卡处于恢复模式，请先完成固件升级".to_string(),
        )),
    }
}

// ── 统一实时音频流（16kHz / 单声道 / i16 小端 PCM） ────────────────

async fn realtime_open(out: Emitter) -> Result<(), BridgeError> {
    let active = active_device().await?;
    match active {
        ActiveDevice::CardV2 { device, .. } => realtime_open_card_v2(device, out).await,
        ActiveDevice::DyjV1 {
            device,
            realtime_active,
            ..
        } => realtime_open_dyj_v1(device, realtime_active, out).await,
        ActiveDevice::BoardV21 {
            board,
            audio_tx,
            recording,
            ..
        } => realtime_open_board_v21(board, audio_tx, recording, out).await,
        ActiveDevice::External { kind, device, .. } => {
            realtime_open_external(kind, device, out).await
        }
        ActiveDevice::CardV2DfuRecovery { .. } => Err(BridgeError::from(
            "录音卡处于恢复模式，请先完成固件升级".to_string(),
        )),
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

async fn realtime_open_dyj_v1(
    device: Arc<DyjV1Session>,
    realtime_active: Arc<AtomicBool>,
    out: Emitter,
) -> Result<(), BridgeError> {
    if state()
        .realtime_stop
        .lock()
        .expect("realtime lock")
        .is_some()
    {
        out.progress(json!({
            "state": "open",
            "deviceKind": "dyj_v1",
            "alreadyOpen": true,
        }));
        return Ok(());
    }
    let _ = device.audio_capture_start().await;
    device.audio_stream_start().await?;
    realtime_active.store(true, Ordering::SeqCst);
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
        realtime_active.store(false, Ordering::SeqCst);
        let _ = device.audio_stream_stop().await;
        let still_recording = device
            .record_status()
            .await
            .ok()
            .and_then(|v| v.get("recording").and_then(Value::as_bool))
            .unwrap_or(false);
        if !still_recording {
            let _ = device.audio_capture_stop().await;
        }
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

fn normalize_mtime_sec(raw: u64) -> Option<u64> {
    if raw == 0 {
        None
    } else if raw > 1_000_000_000_000 {
        Some(raw / 1000)
    } else {
        Some(raw)
    }
}

fn build_dyj_file_entry(
    name: &str,
    size: u64,
    mtime_raw: u64,
    session_hint: Option<&str>,
    seq_hint: Option<u64>,
    synced: bool,
) -> Value {
    let parsed = parse_dyj_audio_filename(name);
    let session = session_hint
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .or_else(|| parsed.as_ref().and_then(|p| p.session.clone()));
    let seq = seq_hint.or_else(|| parsed.as_ref().and_then(|p| p.seq.map(u64::from)));
    let created_at = normalize_mtime_sec(mtime_raw);
    json!({
        "name": name,
        "size": size,
        "created_at": created_at,
        "session": session,
        "seq": seq,
        "synced": synced,
    })
}

fn is_dyj_wifi_connected(wifi_raw: &Value) -> bool {
    let state_str = wifi_raw.get("state").and_then(Value::as_str).unwrap_or("");
    let ip = wifi_raw
        .get("ip")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    let ssid = wifi_raw
        .get("ssid")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    state_str.eq_ignore_ascii_case("connected") || (!ip.is_empty() && !ssid.is_empty())
}

async fn resolve_dyj_device_id(
    device: &DyjV1Session,
    meta: &Arc<Mutex<DyjV1CachedMeta>>,
) -> Option<String> {
    if let Some(id) = meta.lock().unwrap().device_id.clone() {
        return Some(id);
    }
    if let Ok(info) = device.device_info(false).await {
        update_dyj_v1_meta_from_info(meta, &info);
    }
    meta.lock().unwrap().device_id.clone()
}

async fn resolve_dyj_server_origin(
    device: &DyjV1Session,
    override_origin: Option<&str>,
) -> Option<String> {
    if let Some(o) = override_origin.map(str::trim).filter(|s| !s.is_empty()) {
        return extract_origin(o).or_else(|| Some(o.trim_end_matches('/').to_string()));
    }
    device
        .upload_config_get()
        .await
        .ok()
        .and_then(|c| c.get("url").and_then(Value::as_str).and_then(extract_origin))
}

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
        ActiveDevice::DyjV1 { device, meta, .. } => {
            let agg = device.record_list().await?;
            let items = agg
                .get("items")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let mut seen_names = HashSet::new();
            let mut files = Vec::new();
            for it in items {
                let name = it.get("name").and_then(Value::as_str).unwrap_or_default();
                if name.is_empty() || !seen_names.insert(name.to_string()) {
                    continue;
                }
                let size = it.get("bytes").and_then(Value::as_u64).unwrap_or(0);
                let mtime = it.get("mtime").and_then(Value::as_u64).unwrap_or(0);
                let session = it.get("session").and_then(Value::as_str);
                let seq = it.get("seq").and_then(Value::as_u64);
                files.push(build_dyj_file_entry(name, size, mtime, session, seq, false));
            }
            // 兼顾已自动/手动上传并删源的云端暂存 .amr：3 秒内快速合并去重
            if let (Some(did), Some(origin)) = (
                resolve_dyj_device_id(device, meta).await,
                resolve_dyj_server_origin(device, None).await,
            ) {
                if let Ok(server) = DyjV1ServerClient::new(&origin) {
                    if let Ok(Ok(remote)) =
                        tokio::time::timeout(Duration::from_secs(3), server.list_files(&did)).await
                    {
                        for rf in remote.files {
                            let lower = rf.name.to_ascii_lowercase();
                            if !lower.ends_with(".amr") && !lower.ends_with(".wav") {
                                continue;
                            }
                            if seen_names.insert(rf.name.clone()) {
                                files.push(build_dyj_file_entry(
                                    &rf.name, rf.size, 0, None, None, true,
                                ));
                            }
                        }
                    }
                }
            }
            Ok(Value::Array(files))
        }
        ActiveDevice::BoardV21 { .. } | ActiveDevice::CardV2DfuRecovery { .. } => {
            Ok(Value::Array(Vec::new()))
        }
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
            meta,
            ..
        } => {
            // 1) 若设备热点已开启且可达，优先走 SoftAP 8788 快传
            if let Ok(ap_st) = device.ap_status().await {
                if ap_st.get("active").and_then(Value::as_bool) == Some(true) {
                    if let Ok(client) = DyjV1ApClient::from_status(&ap_st) {
                        if let Ok(saved) = client.download_to_dir(name, dir).await {
                            let _ = device.record_delete(name).await;
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
            // 2) 通过配网上传服务取回：若服务器尚无该文件且设备连了 Wi-Fi，先触发单文件 upload.start 等完成
            let did = resolve_dyj_device_id(device, meta).await.ok_or_else(|| {
                BridgeError::from("未能读取点一机设备标识，请重连后重试同步".to_string())
            })?;
            let origin = resolve_dyj_server_origin(device, None).await.ok_or_else(|| {
                BridgeError::from("点一机未配置上传服务地址，请检查固件上传配置".to_string())
            })?;
            let server = DyjV1ServerClient::new(&origin)?;
            let already_on_server = server
                .list_files(&did)
                .await
                .map(|list| list.files.iter().any(|f| f.name == name))
                .unwrap_or(false);

            if !already_on_server {
                let wifi_st = device.wifi_status().await.unwrap_or(Value::Null);
                if !is_dyj_wifi_connected(&wifi_st) {
                    return Err(BridgeError::from(
                        "点一机 V1 尚未连接 Wi-Fi，请先在「Wi-Fi 设置」中连接网络后再同步离线录音"
                            .to_string(),
                    ));
                }
                device.upload_start(Some(name)).await?;
                let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
                while tokio::time::Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(800)).await;
                    if let Ok(st) = device.upload_status().await {
                        let uploading = st.get("uploading").and_then(Value::as_bool).unwrap_or(false);
                        let last_err = st
                            .get("last")
                            .and_then(|l| l.get("error"))
                            .and_then(Value::as_str)
                            .filter(|s| !s.is_empty());
                        let last_state = st
                            .get("last")
                            .and_then(|l| l.get("state"))
                            .and_then(Value::as_str)
                            .unwrap_or("");
                        let last_name = st
                            .get("last")
                            .and_then(|l| l.get("name"))
                            .and_then(Value::as_str)
                            .unwrap_or("");
                        if last_name == name && last_state == "failed" {
                            if let Some(err) = last_err {
                                return Err(BridgeError::from(format!("点一机上传录音失败：{err}")));
                            }
                        }
                        if !uploading {
                            break;
                        }
                    }
                }
            }

            let only = vec![name.to_string()];
            let mut list = server.download_to_dir(&did, dir, Some(&only)).await?;
            if let Some(saved) = list.pop() {
                return Ok(json!({
                    "path": saved.path.to_string_lossy(),
                    "bytesWritten": saved.bytes_written,
                    "originalName": saved.name,
                    "deviceName": dev_name,
                }));
            }
            Err(BridgeError::from(format!(
                "未能从上传服务取回 {name}，请确认点一机 Wi-Fi 网络畅通后重试"
            )))
        }
        ActiveDevice::BoardV21 { .. } => Err(BridgeError::from(
            "语音 AI 键盘无板载录音存储，仅支持实时音频流".to_string(),
        )),
        ActiveDevice::CardV2DfuRecovery { .. } => Err(BridgeError::from(
            "录音卡处于恢复模式，请先完成固件升级".to_string(),
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
        ActiveDevice::DyjV1 { device, .. } => {
            let Value::Array(mut files) = list_device_files(active).await? else {
                return Err(BridgeError::from("设备存储中暂无待取回的录音文件".to_string()));
            };
            files.sort_by_key(|f| f.get("created_at").and_then(Value::as_u64).unwrap_or(u64::MAX));
            let oldest_name = files
                .into_iter()
                .filter_map(|f| f.get("name").and_then(Value::as_str).map(str::to_owned))
                .find(|n| n.to_ascii_lowercase().ends_with(".amr"))
                .ok_or_else(|| BridgeError::from("设备存储中暂无待取回的录音文件".to_string()))?;
            let saved = download_device_file(active, &oldest_name, dir).await?;
            let _ = device.record_delete(&oldest_name).await;
            Ok(saved)
        }
        ActiveDevice::BoardV21 { .. } => Err(BridgeError::from(
            "语音 AI 键盘无板载录音存储，仅支持实时音频流".to_string(),
        )),
        ActiveDevice::CardV2DfuRecovery { .. } => Err(BridgeError::from(
            "录音卡处于恢复模式，请先完成固件升级".to_string(),
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
        ActiveDevice::BoardV21 { .. } | ActiveDevice::CardV2DfuRecovery { .. } => {
            Ok(json!({"deleted": false}))
        }
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
    let ActiveDevice::DyjV1 { device, meta, .. } = active else {
        return Ok(json!({"photos": [], "pendingOnDevice": 0}));
    };

    let cam = device.camera_list().await.unwrap_or(Value::Null);
    let items = cam
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut mtime_by_name: HashMap<String, u64> = HashMap::new();
    let photo_items: Vec<Value> = items
        .into_iter()
        .filter(|it| {
            it.get("kind").and_then(Value::as_str) == Some("photo")
                || it
                    .get("name")
                    .and_then(Value::as_str)
                    .is_some_and(|n| {
                        let low = n.to_ascii_lowercase();
                        low.ends_with(".jpg") || low.ends_with(".jpeg")
                    })
        })
        .map(|it| {
            if let (Some(n), Some(m)) = (
                it.get("name").and_then(Value::as_str),
                it.get("mtime").and_then(Value::as_u64),
            ) {
                if let Some(sec) = normalize_mtime_sec(m) {
                    mtime_by_name.insert(n.to_string(), sec);
                }
            }
            it
        })
        .collect();

    // 若设备上有未上传照片且已连接 Wi-Fi，触发后台上传并短暂等待落盘后再查服务器列表
    if !photo_items.is_empty() {
        let wifi_st = device.wifi_status().await.unwrap_or(Value::Null);
        if is_dyj_wifi_connected(&wifi_st) {
            if device.upload_start(None).await.is_ok() {
                let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
                while tokio::time::Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(600)).await;
                    let Ok(st) = device.upload_status().await else {
                        break;
                    };
                    if st.get("uploading").and_then(Value::as_bool) != Some(true) {
                        break;
                    }
                }
            }
        }
    }

    let device_id = resolve_dyj_device_id(device, meta).await;
    let origin = resolve_dyj_server_origin(device, server_origin_override).await;

    let mut downloaded = Vec::new();
    if let (Some(did), Some(orig)) = (device_id, origin) {
        if let Ok(server) = DyjV1ServerClient::new(&orig) {
            if let Ok(remote_list) = server.list_files(&did).await {
                let photo_names: Vec<String> = remote_list
                    .files
                    .iter()
                    .filter(|f| {
                        let low = f.name.to_ascii_lowercase();
                        low.ends_with(".jpg") || low.ends_with(".jpeg")
                    })
                    .map(|f| f.name.clone())
                    .collect();
                if !photo_names.is_empty() {
                    if let Ok(saved_files) =
                        server.download_to_dir(&did, dir, Some(&photo_names)).await
                    {
                        for sf in saved_files {
                            let captured_at = mtime_by_name.get(&sf.name).copied();
                            downloaded.push(json!({
                                "name": sf.name,
                                "path": sf.path.to_string_lossy(),
                                "bytesWritten": sf.bytes_written,
                                "bytes": sf.bytes_written,
                                "capturedAt": captured_at,
                                "source": "dyj_camera",
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

async fn dyj_button_status(active: &ActiveDevice) -> Result<Value, BridgeError> {
    let ActiveDevice::DyjV1 { device, .. } = active else {
        return Err(BridgeError::from("当前硬件不支持点一机物理按键配置".to_string()));
    };
    Ok(device.button_status().await?)
}

async fn dyj_led_hint(active: &ActiveDevice, mode: &str) -> Result<Value, BridgeError> {
    let ActiveDevice::DyjV1 { device, .. } = active else {
        return Ok(json!({"supported": false}));
    };
    let ok = match mode {
        "listening" => {
            let res = device.led_set("breathe", Some("mid"), Some(850), Some(60)).await;
            if res.is_err() {
                device
                    .led_set("blink", Some("mid"), Some(850), Some(60))
                    .await
                    .is_ok()
            } else {
                true
            }
        }
        "thinking" => device
            .led_set("blink", Some("mid"), Some(850), Some(30))
            .await
            .is_ok(),
        _ => device.led_clear().await.is_ok(),
    };
    Ok(json!({"ok": ok, "mode": mode}))
}

async fn camera_capture_and_fetch(
    active: &ActiveDevice,
    dir: &str,
    server_origin_override: Option<&str>,
) -> Result<Value, BridgeError> {
    let ActiveDevice::DyjV1 { device, meta, .. } = active else {
        return Err(BridgeError::from("当前设备不支持拍照识别".to_string()));
    };
    let cap = device.camera_capture().await?;
    let name = cap
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let bytes = cap.get("bytes").and_then(Value::as_u64).unwrap_or(0);
    if name.is_empty() {
        return Err(BridgeError::from("点一机拍照未返回文件名".to_string()));
    }

    let wifi_st = device.wifi_status().await.unwrap_or(Value::Null);
    if !is_dyj_wifi_connected(&wifi_st) {
        return Ok(json!({
            "name": name,
            "bytes": bytes,
            "wifiConnected": false,
            "downloaded": false,
            "error": "点一机尚未连接 Wi-Fi，照片已保存在设备，配网后可回传识别",
        }));
    }

    let Some(did) = resolve_dyj_device_id(device, meta).await else {
        return Ok(json!({
            "name": name,
            "bytes": bytes,
            "wifiConnected": true,
            "downloaded": false,
            "error": "未获取到点一机设备标识，请稍后重试",
        }));
    };
    let Some(origin) = resolve_dyj_server_origin(device, server_origin_override).await else {
        return Ok(json!({
            "name": name,
            "bytes": bytes,
            "wifiConnected": true,
            "downloaded": false,
            "error": "未配置点一机上传服务地址，暂时无法回传照片",
        }));
    };

    if let Err(e) = device.upload_start(Some(&name)).await {
        return Ok(json!({
            "name": name,
            "bytes": bytes,
            "wifiConnected": true,
            "downloaded": false,
            "error": format!("触发照片上传失败: {e}"),
        }));
    }

    let deadline = tokio::time::Instant::now() + Duration::from_secs(12);
    while tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(400)).await;
        let Ok(st) = device.upload_status().await else {
            continue;
        };
        let last = st.get("last");
        let last_name = last.and_then(|l| l.get("name")).and_then(Value::as_str);
        let last_state = last.and_then(|l| l.get("state")).and_then(Value::as_str);
        if last_name == Some(name.as_str()) && last_state == Some("failed") {
            let err_msg = last
                .and_then(|l| l.get("error"))
                .and_then(Value::as_str)
                .unwrap_or("照片上传失败");
            return Ok(json!({
                "name": name,
                "bytes": bytes,
                "wifiConnected": true,
                "downloaded": false,
                "error": err_msg,
            }));
        }
        if st.get("uploading").and_then(Value::as_bool) != Some(true) {
            break;
        }
    }

    let server = DyjV1ServerClient::new(&origin)?;
    let filter = vec![name.clone()];
    let mut saved_files = server
        .download_to_dir(&did, dir, Some(&filter))
        .await
        .unwrap_or_default();
    if saved_files.is_empty() {
        tokio::time::sleep(Duration::from_millis(600)).await;
        saved_files = server
            .download_to_dir(&did, dir, Some(&filter))
            .await
            .unwrap_or_default();
    }

    if let Some(sf) = saved_files.into_iter().next() {
        return Ok(json!({
            "name": sf.name,
            "path": sf.path.to_string_lossy(),
            "bytes": sf.bytes_written,
            "wifiConnected": true,
            "downloaded": true,
        }));
    }

    Ok(json!({
        "name": name,
        "bytes": bytes,
        "wifiConnected": true,
        "downloaded": false,
        "error": "照片尚未同步到云端暂存，请稍后在时间线查看",
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
        ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. }
        | ActiveDevice::CardV2DfuRecovery { .. } => Ok(Value::Array(Vec::new())),
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

fn map_dyj_wifi_connect_result(ssid: &str, resp: Value) -> Result<Value, BridgeError> {
    if resp.get("connected").and_then(Value::as_bool) == Some(true) {
        return Ok(resp);
    }
    let phase = resp.get("phase").and_then(Value::as_str).unwrap_or("");
    let msg = match phase {
        "auth" => format!("Wi-Fi「{ssid}」密码错误，请核对后重试"),
        "dhcp" => format!("Wi-Fi「{ssid}」获取 IP 地址失败（DHCP 超时），请重试"),
        "timeout" => format!("连接 Wi-Fi「{ssid}」超时，请确认路由器在 2.4GHz 范围内后重试"),
        _ => format!("连接 Wi-Fi「{ssid}」失败，请确认信号与密码后重试"),
    };
    Err(BridgeError::from(msg))
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
        ActiveDevice::DyjV1 { device, meta, .. } => {
            let pwd = if password.is_empty() {
                None
            } else {
                Some(password)
            };
            let resp = device.wifi_connect(ssid, pwd, None).await?;
            let ok = map_dyj_wifi_connect_result(ssid, resp)?;
            meta.lock().unwrap().record_saved_ssid(ssid);
            Ok(ok)
        }
        ActiveDevice::BoardV21 { .. } => {
            Err(BridgeError::from("语音 AI 键盘不支持设备端 Wi-Fi 配置".to_string()))
        }
        ActiveDevice::CardV2DfuRecovery { .. } => Err(BridgeError::from(
            "录音卡处于恢复模式，请先完成固件升级".to_string(),
        )),
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
        ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. }
        | ActiveDevice::CardV2DfuRecovery { .. } => Ok(json!({"enabled": false})),
    }
}

async fn wifi_close(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.close_wifi().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { .. }
        | ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. }
        | ActiveDevice::CardV2DfuRecovery { .. } => Ok(json!({"closed": true})),
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
        ActiveDevice::DyjV1 { device, meta, .. } => {
            let st = device.wifi_status().await.unwrap_or(Value::Null);
            let current_ssid = st
                .get("ssid")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            if let Some(ref s) = current_ssid {
                meta.lock().unwrap().record_saved_ssid(s);
            }
            let saved = meta.lock().unwrap().saved_ssids.clone();
            let creds: Vec<Value> = saved
                .into_iter()
                .map(|ssid| {
                    let connected = current_ssid.as_deref() == Some(ssid.as_str());
                    json!({"ssid": ssid, "connected": connected})
                })
                .collect();
            Ok(Value::Array(creds))
        }
        ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. }
        | ActiveDevice::CardV2DfuRecovery { .. } => Ok(Value::Array(Vec::new())),
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
        ActiveDevice::DyjV1 { device, meta, .. } => {
            let res = device.wifi_forget(Some(ssid)).await?;
            meta.lock().unwrap().remove_saved_ssid(ssid);
            Ok(res)
        }
        ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. }
        | ActiveDevice::CardV2DfuRecovery { .. } => Ok(json!({"removed": 0})),
    }
}

async fn sync_start(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.start_sync().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.upload_start(None).await?),
        ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. }
        | ActiveDevice::CardV2DfuRecovery { .. } => Ok(json!({"queued": 0})),
    }
}

async fn sync_status(active: &ActiveDevice) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => Ok(device.sync_status().await.and_then(to_value)?),
        ActiveDevice::DyjV1 { device, .. } => Ok(device.upload_status().await?),
        ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. }
        | ActiveDevice::CardV2DfuRecovery { .. } => Ok(json!({"uploading": false})),
    }
}

async fn upload_set_url(active: &ActiveDevice, url: &str) -> Result<Value, BridgeError> {
    match active {
        ActiveDevice::CardV2 { device, .. } => {
            Ok(device.set_wifi_upload_url(url).await.and_then(to_value)?)
        }
        ActiveDevice::DyjV1 { device, .. } => Ok(device.upload_config_set(Some(url), None).await?),
        ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. }
        | ActiveDevice::CardV2DfuRecovery { .. } => Ok(json!({"url": url})),
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
        ActiveDevice::CardV2DfuRecovery { .. } => Err(BridgeError::from(
            "录音卡处于恢复模式，请先完成固件升级".to_string(),
        )),
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
        ActiveDevice::BoardV21 { .. }
        | ActiveDevice::External { .. }
        | ActiveDevice::CardV2DfuRecovery { .. } => Ok(json!({"active": false})),
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
        ActiveDevice::CardV2DfuRecovery { .. } => Ok(json!({"synced": false})),
        ActiveDevice::External { device, .. } => Ok(device.sync_time().await?),
    }
}

// ── 固件 OTA（CardV2 双芯 DFU + 点一机 V1 single_ota）────────────

fn format_version_from_code(code: u64) -> String {
    if code == 0 {
        return String::new();
    }
    if code >= 100 {
        format!("{}.{}.{}", code / 10_000, (code % 10_000) / 100, code % 100)
    } else {
        format!("0.0.{code}")
    }
}

fn parse_dyj_ota_info_response(chk: &Value) -> Value {
    let need_update = chk
        .get("need_update")
        .or_else(|| chk.get("needUpdate"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let current = chk.get("current").unwrap_or(&Value::Null);
    let current_code = current
        .get("version_code")
        .or_else(|| current.get("versionCode"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let remote = chk.get("remote").unwrap_or(&Value::Null);
    let remote_code = remote
        .get("versionCode")
        .or_else(|| remote.get("version_code"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let remote_ver_raw = remote
        .get("versionName")
        .or_else(|| remote.get("version"))
        .or_else(|| remote.get("version_name"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    let version = remote_ver_raw.unwrap_or_else(|| format_version_from_code(remote_code));
    let url = remote
        .get("url")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    json!({
        "version": version,
        "versionCode": remote_code,
        "url": url,
        "needUpdate": need_update,
        "currentVersionCode": current_code,
    })
}

async fn dyj_v1_ota_check_with_fallback(device: &DyjV1Session) -> Result<Value, BridgeError> {
    match device.ota_check().await {
        Ok(chk) => {
            let parsed = parse_dyj_ota_info_response(&chk);
            let remote_code = parsed.get("versionCode").and_then(Value::as_u64).unwrap_or(0);
            if remote_code >= 815 {
                return Ok(parsed);
            }
            let _ = device
                .ota_config_set(legacy_upgrade::default_target_ota_info_url())
                .await;
            if let Ok(chk2) = device.ota_check().await {
                let parsed2 = parse_dyj_ota_info_response(&chk2);
                if parsed2.get("versionCode").and_then(Value::as_u64).unwrap_or(0) >= remote_code {
                    return Ok(parsed2);
                }
            }
            Ok(parsed)
        }
        Err(first_err) => {
            if device
                .ota_config_set(legacy_upgrade::default_target_ota_info_url())
                .await
                .is_ok()
            {
                if let Ok(chk2) = device.ota_check().await {
                    return Ok(parse_dyj_ota_info_response(&chk2));
                }
            }
            Err(BridgeError::from(first_err))
        }
    }
}

async fn ota_info(payload: &Value) -> Result<Value, BridgeError> {
    let mod_str = payload.get("mod").and_then(Value::as_str);
    if let Ok(ActiveDevice::DyjV1 { device, .. }) = active_device().await {
        if mod_str == Some("wifi") {
            return Ok(json!({
                "version": "",
                "versionCode": 0,
                "url": "",
                "needUpdate": false,
            }));
        }
        let wifi_st = device.wifi_status().await.unwrap_or(Value::Null);
        if !is_dyj_wifi_connected(&wifi_st) {
            return Err(BridgeError::from(
                "点一机检查固件更新需要先连接 Wi-Fi 网络".to_string(),
            ));
        }
        return dyj_v1_ota_check_with_fallback(&device).await;
    }

    let module = match mod_str {
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

async fn enter_dfu_mode_tolerating_reboot(device: &CardV2Device) -> Result<(), CardSdkError> {
    match tokio::time::timeout(Duration::from_secs(6), device.enter_dfu_mode()).await {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(CardSdkError::Disconnected)) | Ok(Err(CardSdkError::Timeout { .. })) | Err(_) => {
            Ok(())
        }
        Ok(Err(err)) => Err(err),
    }
}

async fn ota_main(payload: Value, out: Emitter) -> Result<(), BridgeError> {
    let current_active = state().device.lock().await.clone();
    if let Some(ActiveDevice::DyjV1 { device, .. }) = current_active {
        return ota_main_dyj_v1(device, out).await;
    }
    if matches!(
        current_active,
        Some(ActiveDevice::BoardV21 { .. } | ActiveDevice::External { .. })
    ) {
        out.fail("当前连接设备不支持双芯 DFU 固件升级");
        return Ok(());
    }

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

    let adapter = match scan_adapter().await {
        Ok(adapter) => adapter,
        Err(error) => {
            out.fail(error.message);
            return Ok(());
        }
    };

    let dfu_budget = match active {
        Some(ActiveDevice::CardV2 { device, .. }) => {
            out.progress(json!({"stage": "dfu", "percent": 5, "text": "设备重启进 bootloader…"}));
            let enter_res = enter_dfu_mode_tolerating_reboot(&device).await;
            let _ = tokio::time::timeout(Duration::from_secs(3), device.disconnect()).await;
            if let Err(error) = enter_res {
                out.fail(error);
                return Ok(());
            }
            Duration::from_secs(20)
        }
        Some(ActiveDevice::CardV2DfuRecovery { .. }) => {
            out.progress(json!({"stage": "dfu", "percent": 5, "text": "正在连接恢复模式 Bootloader…"}));
            Duration::from_secs(12)
        }
        None => {
            let dfu_nearby =
                matches!(card_v2_ble::scan_dfu_peripheral(adapter, Duration::from_secs(3)).await, Ok(Some(_)));
            if dfu_nearby {
                out.progress(json!({"stage": "dfu", "percent": 5, "text": "发现 Bootloader，正在续传主控固件…"}));
                Duration::from_secs(12)
            } else {
                let saved_target = state()
                    .last_card_v2_target
                    .lock()
                    .expect("card v2 target lock")
                    .clone();
                let Some((tid, tname)) = saved_target else {
                    out.fail("当前未连接录音卡，也未检测到 DFU_DYJ 恢复设备");
                    return Ok(());
                };
                out.progress(json!({"stage": "dfu", "percent": 4, "text": "正在重连录音卡进入升级模式…"}));
                match card_v2_ble::connect_card_v2_on_adapter(
                    adapter,
                    &tid,
                    Some(&tname),
                    Some(&state().connecting_peripheral),
                )
                .await
                {
                    Ok(CardV2ConnectOutcome::Connected { device, .. }) => {
                        out.progress(json!({"stage": "dfu", "percent": 5, "text": "设备重启进 bootloader…"}));
                        let enter_res = enter_dfu_mode_tolerating_reboot(&device).await;
                        let _ = tokio::time::timeout(Duration::from_secs(3), device.disconnect()).await;
                        if let Err(error) = enter_res {
                            out.fail(error);
                            return Ok(());
                        }
                        Duration::from_secs(20)
                    }
                    Ok(CardV2ConnectOutcome::DfuRecovery { .. }) => {
                        out.progress(json!({"stage": "dfu", "percent": 5, "text": "正在连接恢复模式 Bootloader…"}));
                        Duration::from_secs(12)
                    }
                    Err(error) => {
                        out.fail(error.message);
                        return Ok(());
                    }
                }
            }
        }
        Some(_) => {
            out.fail("当前连接设备不支持双芯 DFU 固件升级");
            return Ok(());
        }
    };

    let ota_out = out;
    let options = reai_card_sdk::DfuOptions::default();
    let report = card_v2_ble::run_dfu_upload_with_resume(
        &package,
        &options,
        move |_attempt| card_v2_ble::connect_dfu_target_on_adapter(adapter, dfu_budget),
        move |percent, text, sent, total| {
            ota_out.progress(json!({
                "stage": "dfu",
                "percent": percent,
                "text": text,
                "sent": sent,
                "total": total,
            }));
        },
    )
    .await;

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

async fn ota_main_dyj_v1(device: Arc<DyjV1Session>, out: Emitter) -> Result<(), BridgeError> {
    out.progress(json!({
        "stage": "checking",
        "percent": 2,
        "text": "正在检查点一机系统固件版本…",
    }));
    let wifi_st = device.wifi_status().await.unwrap_or(Value::Null);
    if !is_dyj_wifi_connected(&wifi_st) {
        out.fail("点一机升级固件需要先连接 Wi-Fi 网络");
        return Ok(());
    }
    let parsed = match dyj_v1_ota_check_with_fallback(&device).await {
        Ok(p) => p,
        Err(e) => {
            out.fail(e.message);
            return Ok(());
        }
    };
    let target_ver = parsed
        .get("version")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if parsed.get("needUpdate").and_then(Value::as_bool) != Some(true) {
        out.progress(json!({
            "stage": "done",
            "percent": 100,
            "text": "点一机系统固件已是最新版本",
        }));
        out.ok(json!({
            "module": "main",
            "upToDate": true,
            "version": target_ver,
        }));
        return Ok(());
    }

    if let Some(pump) = state().event_pump.lock().await.take() {
        pump.abort();
    }
    if let Some(stop) = state().realtime_stop.lock().expect("realtime lock").take() {
        let _ = stop.send(());
    }
    let mut events = device.subscribe_events();
    out.progress(json!({
        "stage": "downloading",
        "percent": 5,
        "text": "正在下载系统固件…",
        "version": target_ver,
    }));
    if let Err(e) = device.ota_install(true).await {
        out.fail(BridgeError::from(e).message);
        return Ok(());
    }

    let deadline = tokio::time::Instant::now() + Duration::from_secs(300);
    let mut last_state = String::from("downloading");
    let mut seen_installing = false;
    let mut install_deadline: Option<tokio::time::Instant> = None;

    loop {
        let now = tokio::time::Instant::now();
        let target_deadline = match install_deadline {
            Some(id) if id < deadline => id,
            _ => deadline,
        };
        let remaining = target_deadline.saturating_duration_since(now);
        if remaining.is_zero() {
            if seen_installing {
                break;
            }
            out.fail("点一机系统固件升级超时，请重连设备确认版本后重试");
            return Ok(());
        }
        match tokio::time::timeout(remaining, events.recv()).await {
            Ok(Ok(DyjV1Event::Event { evt, data, .. })) if evt == "ota.progress" => {
                let state_str = data.get("state").and_then(Value::as_str).unwrap_or("");
                if !state_str.is_empty() {
                    last_state = state_str.to_string();
                }
                match state_str {
                    "downloading" => {
                        let raw_pct = data.get("progress").and_then(Value::as_u64).unwrap_or(0);
                        let pct = 5 + ((raw_pct.min(100) * 65) / 100) as u8;
                        out.progress(json!({
                            "stage": "downloading",
                            "percent": pct,
                            "text": "正在下载系统固件…",
                            "version": target_ver,
                        }));
                    }
                    "verifying" => {
                        out.progress(json!({
                            "stage": "verifying",
                            "percent": 75,
                            "text": "正在校验系统固件完整性…",
                            "version": target_ver,
                        }));
                    }
                    "installing" => {
                        seen_installing = true;
                        install_deadline.get_or_insert_with(|| {
                            tokio::time::Instant::now() + Duration::from_secs(4)
                        });
                        out.progress(json!({
                            "stage": "installing",
                            "percent": 90,
                            "text": "正在安装系统固件并重启设备…",
                            "version": target_ver,
                        }));
                    }
                    "failed" => {
                        let err_msg = data
                            .get("error")
                            .and_then(Value::as_str)
                            .filter(|s| !s.trim().is_empty())
                            .unwrap_or("固件下载或校验失败");
                        out.fail(format!("点一机系统固件升级失败：{err_msg}"));
                        return Ok(());
                    }
                    _ => {}
                }
            }
            Ok(Ok(DyjV1Event::Disconnected)) => {
                if seen_installing || matches!(last_state.as_str(), "verifying" | "installing") {
                    break;
                }
                out.fail("升级过程中与点一机连接意外断开，请重新连接后查看当前固件版本");
                return Ok(());
            }
            Ok(Ok(_)) => continue,
            Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => continue,
            Ok(Err(_)) => {
                if seen_installing {
                    break;
                }
                out.fail("升级监听通道意外中断，请重新连接设备查看版本");
                return Ok(());
            }
            Err(_) => {
                if seen_installing {
                    break;
                }
                out.fail("点一机系统固件升级超时，请重连设备确认版本后重试");
                return Ok(());
            }
        }
    }

    // 覆盖安装杀进程重启：显式清理本地会话，交由上层重连读取新版本
    release_device().await;
    out.ok(json!({
        "module": "main",
        "upToDate": false,
        "version": target_ver,
    }));
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

    #[test]
    fn builds_dyj_v1_snapshot_matching_card_snapshot_schema() {
        let meta = DyjV1CachedMeta {
            device_id: Some("C5F96AD5895ADF02".into()),
            fw_version: "0.8.15".into(),
            fw_version_code: 815,
            model: "DYJ-V1".into(),
            saved_ssids: vec!["CloudOS.com".into()],
        };
        let batt = json!({"level": 76, "status": "charging", "plugged": 1});
        let stor = json!({
            "data_total_bytes": 16u64 * 1024 * 1024 * 1024,
            "data_free_bytes": 12u64 * 1024 * 1024 * 1024,
        });
        let rec = json!({"recording": true, "session": "A1B2C3D4", "files": 3});
        let wifi = json!({"wifi_enabled": true, "state": "connected", "ssid": "CloudOS.com", "ip": "192.168.31.57"});

        let snap = build_dyj_v1_snapshot_json(
            DeviceKind::DyjV1,
            "DYJ_Q2M34R",
            &meta,
            &batt,
            &stor,
            &rec,
            &wifi,
            true,
        );
        assert_eq!(snap["battery"]["level"], 76);
        assert_eq!(snap["battery"]["isCharging"], true);
        assert_eq!(snap["state"]["wifiOpen"], true);
        assert_eq!(snap["state"]["wifiConnected"], true);
        assert_eq!(snap["record"]["isRecording"], true);
        assert_eq!(snap["record"]["realtimeEnabled"], true);
        assert_eq!(snap["record"]["session"], "A1B2C3D4");
        assert_eq!(snap["info"]["version"], "0.8.15");
        assert_eq!(snap["info"]["versionCode"], 815);
        assert_eq!(snap["info"]["deviceName"], "DYJ_Q2M34R");
        assert_eq!(snap["storage"]["total"], 16 * 1024);
        assert_eq!(snap["storage"]["used"], 4 * 1024);
    }

    #[test]
    fn builds_dyj_file_entries_and_normalizes_millis_mtime() {
        let e = build_dyj_file_entry(
            "audio_20261026-153000_A1B2C3D4_03.amr",
            48_000,
            1_730_000_000_123,
            None,
            None,
            false,
        );
        assert_eq!(e["name"], "audio_20261026-153000_A1B2C3D4_03.amr");
        assert_eq!(e["size"], 48_000);
        assert_eq!(e["created_at"], 1_730_000_000);
        assert_eq!(e["session"], "A1B2C3D4");
        assert_eq!(e["seq"], 3);
        assert_eq!(e["synced"], false);
    }

    #[test]
    fn maps_dyj_wifi_connect_failures_and_ota_check_schema() {
        assert!(map_dyj_wifi_connect_result("Office", json!({"connected": true, "ip": "1.2.3.4"})).is_ok());
        let auth_err = map_dyj_wifi_connect_result("Office", json!({"connected": false, "phase": "auth"}))
            .err()
            .unwrap();
        assert!(auth_err.message.contains("密码错误"));
        let dhcp_err = map_dyj_wifi_connect_result("Office", json!({"connected": false, "phase": "dhcp"}))
            .err()
            .unwrap();
        assert!(dhcp_err.message.contains("DHCP"));

        let ota = parse_dyj_ota_info_response(&json!({
            "need_update": true,
            "current": {"version_name": "0.8.12", "version_code": 812},
            "remote": {"versionCode": 815, "url": "https://ota.example/app.apk"}
        }));
        assert_eq!(ota["needUpdate"], true);
        assert_eq!(ota["version"], "0.8.15");
        assert_eq!(ota["versionCode"], 815);
        assert_eq!(ota["currentVersionCode"], 812);
        assert_eq!(ota["url"], "https://ota.example/app.apk");
    }

    #[test]
    fn maps_dyj_v1_battery_and_camera_and_record_and_button_events() {
        let batt = map_dyj_v1_event_to_json(
            "battery.changed",
            1000,
            json!({"level": 52, "status": "charging", "plugged": 1}),
            1_700_000_001_000,
        )
        .unwrap();
        assert_eq!(batt["kind"], "power");
        assert_eq!(batt["battery"]["level"], 52);
        assert_eq!(batt["battery"]["isCharging"], true);

        let cam = map_dyj_v1_event_to_json(
            "camera.capture",
            2000,
            json!({"name": "img_20261116-200000-001.jpg"}),
            1_700_000_002_000,
        )
        .unwrap();
        assert_eq!(cam["kind"], "camera");

        let rec = map_dyj_v1_event_to_json(
            "record.stop",
            3000,
            json!({"session": "DEADBEEF"}),
            1_700_000_003_000,
        )
        .unwrap();
        assert_eq!(rec["kind"], "record");
        assert_eq!(rec["status"]["isRecording"], false);
        assert_eq!(rec["status"]["session"], "DEADBEEF");

        for gesture in [
            "down",
            "up",
            "click",
            "double_click",
            "long_press_start",
            "long_press_end",
        ] {
            let btn = map_dyj_v1_event_to_json(
                "button.event",
                4567,
                json!({"type": gesture, "duration_ms": 1820}),
                1_700_000_004_567,
            )
            .unwrap();
            assert_eq!(btn["kind"], "button");
            assert_eq!(btn["gesture"], gesture);
            assert_eq!(btn["durationMs"], 1820);
            assert_eq!(btn["deviceTs"], 4567);
            assert_eq!(btn["receivedAtMs"], 1_700_000_004_567u64);
        }
        for (evt_name, gesture) in [
            ("button.click", "click"),
            ("button.double_click", "double_click"),
            ("button.long_press", "long_press"),
        ] {
            let btn = map_dyj_v1_event_to_json(evt_name, 5123, json!({}), 1_700_000_005_123).unwrap();
            assert_eq!(btn["kind"], "button");
            assert_eq!(btn["gesture"], gesture);
        }
        assert!(map_dyj_v1_event_to_json(
            "button.event",
            5000,
            json!({"type": "unknown"}),
            1_700_000_005_000,
        )
        .is_none());
    }

    #[test]
    fn card_v2_candidate_matcher_handles_rpa_and_rejects_mismatch() {
        let nus_uuid = uuid::Uuid::parse_str(NUS_SERVICE_UUID).unwrap();
        // 1) RPA 轮换后 ID 变化，但广播名与提示名匹配，命中新外设
        assert_eq!(
            matches_card_v2_candidate(
                "new-rpa-id",
                "old-id",
                Some("DYJV2_T4W25T"),
                Some("DYJV2_T4W25T"),
                &[],
            ),
            Some("DYJV2_T4W25T".to_string())
        );
        // 2) ID 相同但本地名明确指向另一台设备，拒绝误连
        assert_eq!(
            matches_card_v2_candidate(
                "same-id",
                "same-id",
                Some("DYJV2_T4W25T"),
                Some("DYJV2_OTHER"),
                &[nus_uuid],
            ),
            None
        );
        // 3) ID 相同且带有 NUS 服务 UUID（本地名缺失时），允许按 hint 建连
        assert_eq!(
            matches_card_v2_candidate(
                "same-id",
                "same-id",
                Some("DYJV2_T4W25T"),
                None,
                &[nus_uuid],
            ),
            Some("DYJV2_T4W25T".to_string())
        );
        // 4) 不同 ID 且无本地名，即使有 NUS 也不盲连
        assert_eq!(
            matches_card_v2_candidate(
                "other-id",
                "same-id",
                Some("DYJV2_T4W25T"),
                None,
                &[nus_uuid],
            ),
            None
        );
    }

    #[test]
    fn external_candidate_matcher_handles_rpa_for_getseed_omi_feishu() {
        let empty_mfd = HashMap::new();
        assert_eq!(
            matches_external_candidate(
                &GetSeedSdkDriver,
                "new-rpa-id",
                "old-id",
                Some("Get-A102"),
                Some("Get-A102"),
                &[],
                &empty_mfd,
            ),
            Some("Get-A102".to_string())
        );
        assert_eq!(
            matches_external_candidate(
                &GetSeedSdkDriver,
                "other-id",
                "old-id",
                Some("Get-A102"),
                Some("Get-B999"),
                &[],
                &empty_mfd,
            ),
            None
        );
        assert_eq!(
            matches_external_candidate(
                &OmiSdkDriver,
                "new-rpa-omi",
                "old-id",
                Some("Omi-7F20"),
                Some("Omi-7F20"),
                &[],
                &empty_mfd,
            ),
            Some("Omi-7F20".to_string())
        );
        assert_eq!(
            matches_external_candidate(
                &FeishuSdkDriver,
                "new-rpa-feishu",
                "old-id",
                Some("D3200-C3A1"),
                Some("D3200-C3A1"),
                &[],
                &empty_mfd,
            ),
            Some("D3200-C3A1".to_string())
        );
        assert!(now_unix_ms() > 0);
    }

    #[test]
    fn known_service_uuids_and_cached_id_matching_cover_all_hardware() {
        let services = known_hardware_service_uuids();
        let nus_uuid = uuid::Uuid::parse_str(NUS_SERVICE_UUID).unwrap();
        let dfu_uuid = uuid::Uuid::parse_str(reai_card_sdk::DFU_SERVICE_UUID).unwrap();
        assert!(services.contains(&nus_uuid));
        assert!(services.contains(&dfu_uuid));
        assert!(services.contains(&reai_board_sdk::kernel::protocol_gatt::SERVICE_UUID));
        assert!(services.contains(&reai_getseed_sdk::protocol::SVC_CTL_UUID));
        assert!(services.contains(&reai_omi_sdk::protocol::SVC_OMI_AUDIO_UUID));
        assert!(services.contains(&reai_feishu_sdk::SERVICE_UUID));

        // CoreBluetooth retrievePeripheralsWithIdentifiers 常返回无 local_name 的外设对象，
        // 只要 UUID 命中缓存即应允许按提示名快速直连。
        assert_eq!(
            matches_card_v2_candidate(
                "cached-uuid-1",
                "cached-uuid-1",
                Some("DYJV2_9920"),
                None,
                &[],
            ),
            Some("DYJV2_9920".to_string())
        );
    }

    #[test]
    #[ignore = "requires physical DYJ_* device nearby"]
    fn dyj_v1_live_ble_probe() {
        let rt = &state().runtime;
        rt.block_on(async {
            let find_v1 = |list: &[Value]| {
                list.iter()
                    .find(|d| {
                        d.get("name")
                            .and_then(Value::as_str)
                            .is_some_and(|n| n.starts_with("DYJ_") && !n.starts_with("DYJV2_"))
                    })
                    .cloned()
            };
            let t0 = std::time::Instant::now();
            let mut target = None;
            for attempt in 0..3 {
                let list1 = unified_scan(Duration::from_millis(5000))
                    .await
                    .expect("unified_scan must succeed");
                eprintln!("[probe] scan1[{attempt}] ({:?}): {list1:#?}", t0.elapsed());
                if let Some(found) = find_v1(&list1) {
                    target = Some(found);
                    break;
                }
            }
            let target = target.expect("expected a nearby DYJ_* V1 device in scan1");
            let rssi = target["rssi"].as_i64().unwrap();
            assert!(rssi < 0, "expected real negative RSSI, got {rssi}");

            let id = target["id"].as_str().unwrap().to_string();
            let name = target["name"].as_str().unwrap().to_string();
            let t1 = std::time::Instant::now();
            let conn_res = connect_device(json!({
                "id": id,
                "name": name,
                "deviceKind": "dyj_v1",
            }))
            .await;
            eprintln!("[probe] connect ({:?}): {:?}", t1.elapsed(), conn_res.as_ref().map_err(|e| &e.message));
            if let Err(err) = conn_res {
                assert!(
                    err.message.contains("LEGACY_UPGRADE_REQUIRED")
                        || err.message.contains("v0.7.2")
                        || err.message.contains("v0.8.12")
                        || err.message.contains("固件"),
                    "unexpected connect error: {}",
                    err.message
                );
                assert!(t1.elapsed() < Duration::from_secs(12), "legacy connect took too long: {:?}", t1.elapsed());
            } else {
                let _ = release_device().await;
            }

            tokio::time::sleep(Duration::from_millis(1200)).await;
            let mut found_again = false;
            for attempt in 0..3 {
                let list2 = unified_scan(Duration::from_millis(5000))
                    .await
                    .expect("second unified_scan must succeed");
                eprintln!("[probe] scan2[{attempt}] count={}", list2.len());
                if list2
                    .iter()
                    .any(|d| d.get("name").and_then(Value::as_str) == Some(name.as_str()))
                {
                    found_again = true;
                    break;
                }
            }
            assert!(found_again, "expected {name} to immediately resume advertising after disconnect");
        });
    }
}
