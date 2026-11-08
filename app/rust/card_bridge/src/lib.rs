//! card_bridge —— 把 reai-card-sdk（异步 Rust + btleplug）经最小 C ABI 暴露给 Flutter。
//!
//! 设计要点：
//! - **单一入口** `card_bridge_command(kind, payload_json, cb, user_data)`：
//!   新增能力只改 kind 分支，C ABI 面不再膨胀（Dart 侧只需一个 dispatcher）。
//! - 回调消息统一为 JSON，含 `final` 字段：
//!   `{"ok":true,"data":…,"final":true}` 终态成功；
//!   `{"ok":true,"progress":…,"final":false}` 过程进度（OTA 等长任务，可多次）；
//!   `{"ok":false,"error":"…","final":true}` 终态失败。
//! - 回调交出的 JSON 指针**所有权移交 Dart**：Dart 拷贝完必须调 `card_bridge_free_string`。
//!   （Dart 侧用 `NativeCallable.listener`，回调是异步投递，cb 返回不代表 Dart 已读完。）
//! - 设备命令严格串行（SDK 规则）：全局仅保存一个已连接设备，Dart 侧另有串行闸。

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::OnceLock;
use std::time::Duration;

use reai_card_sdk::{
    DfuPackage, DeviceManager, DeviceEvent, DyjDevice, OtaInfo, OtaModule, SdkError,
};
use serde_json::{json, Value};

/// Dart 注册的回调：`fn(user_data, json_utf8_ptr)`。
type Callback = extern "C" fn(user_data: *mut c_void, json: *const c_char);

struct BridgeState {
    runtime: tokio::runtime::Runtime,
    device: tokio::sync::Mutex<Option<DyjDevice>>,
}

static STATE: OnceLock<BridgeState> = OnceLock::new();
static VERSION: &str = concat!("card_bridge/", env!("CARGO_PKG_VERSION"), " reai-card-sdk/0.0.6");

fn state() -> &'static BridgeState {
    STATE.get_or_init(|| BridgeState {
        runtime: tokio::runtime::Builder::new_multi_thread()
            .worker_threads(3)
            .enable_all()
            .build()
            .expect("tokio runtime"),
        device: tokio::sync::Mutex::new(None),
    })
}

fn emit_raw(cb: Callback, user_data: usize, value: Value) {
    let json = CString::new(value.to_string()).expect("no NUL in json");
    // into_raw：所有权交给 Dart，由它拷贝后 free_string。
    cb(user_data as *mut c_void, json.into_raw());
}

/// 一条结果通道：同一个 (cb, user_data) 可发多条进度，最后一条必为终态。
#[derive(Clone, Copy)]
struct Emitter {
    cb: Callback,
    user_data: usize,
}

impl Emitter {
    fn progress(&self, value: Value) {
        emit_raw(self.cb, self.user_data, json!({"ok": true, "progress": value, "final": false}));
    }

    fn ok(&self, value: Value) {
        emit_raw(self.cb, self.user_data, json!({"ok": true, "data": value, "final": true}));
    }

    fn fail(&self, error: impl std::fmt::Display) {
        emit_raw(
            self.cb,
            self.user_data,
            json!({"ok": false, "error": error.to_string(), "final": true}),
        );
    }
}

// ── C ABI ───────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn card_bridge_version() -> *const c_char {
    static V: OnceLock<CString> = OnceLock::new();
    V.get_or_init(|| CString::new(VERSION).expect("no NUL")).as_ptr()
}

/// 释放 emit 交出的 JSON 字符串；Dart 侧在拷贝完成后调用一次。
///
/// # Safety
/// `ptr` 必须是本库 `CString::into_raw` 交出且尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn card_bridge_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// 统一命令入口。`kind` 见 `dispatch`；`payload` 为 JSON 字符串（可空）。
///
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
    let emitter = Emitter { cb, user_data: user_data as usize };
    state().runtime.spawn(async move {
        if let Err(error) = dispatch(&kind, payload, emitter).await {
            emitter.fail(error);
        }
    });
}

// ── 命令分发 ────────────────────────────────────────────────

async fn dispatch(kind: &str, payload: Value, out: Emitter) -> Result<(), SdkError> {
    match kind {
        "scan" => {
            let timeout = payload.get("timeoutMs").and_then(Value::as_u64).unwrap_or(6000);
            let manager = DeviceManager::new().await?;
            let devices = manager.scan(Duration::from_millis(timeout)).await?;
            out.ok(serde_json::to_value(&devices).map_err(to_sdk)?);
        }
        "connect" => out.ok(connect(payload).await?),
        "disconnect" => {
            let device = state().device.lock().await.take();
            if let Some(device) = device.as_ref() {
                let _ = device.disconnect().await;
            }
            out.ok(json!({"disconnected": true}));
        }
        "snapshot" => {
            let guard = state().device.lock().await;
            let device = guard.as_ref().ok_or(SdkError::Disconnected)?;
            out.ok(snapshot(device).await?);
        }
        "record" => {
            let action = payload.get("action").and_then(Value::as_str).unwrap_or("toggle");
            out.ok(with_device(|d| async move {
                match action {
                    "start" => d.start_recording().await.and_then(|r| to_value(r)),
                    "stop" => d.stop_recording().await.and_then(|r| to_value(r)),
                    _ => d.toggle_recording().await.and_then(|r| to_value(r)),
                }
            })
            .await?);
        }
        "mark" => {
            out.ok(with_device(|d| async move {
                d.record_mark().await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "files" => {
            out.ok(with_device(|d| async move {
                d.list_files(None).await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "download" => {
            let name = str_field(&payload, "name");
            let dir = str_field(&payload, "dir");
            out.ok(with_device(|d| async move {
                let saved = d.take_file_to_dir(&name, &dir).await?;
                // SavedRecording 未实现 Serialize，按需挑选字段手工投影
                Ok(json!({
                    "path": saved.path.to_string_lossy(),
                    "bytesWritten": saved.bytes_written,
                    "originalName": saved.original_name,
                    "deviceName": saved.device_name,
                }))
            })
            .await?);
        }
        "deleteFile" => {
            let name = str_field(&payload, "name");
            out.ok(with_device(|d| async move {
                d.delete_file(&name).await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "wifi.scan" => {
            out.ok(with_device(|d| async move {
                d.scan_wifi().await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "wifi.connect" => {
            let ssid = str_field(&payload, "ssid");
            let password = str_field(&payload, "password");
            out.ok(with_device(|d| async move {
                d.connect_wifi(&ssid, &password).await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "wifi.open" => {
            out.ok(with_device(|d| async move { d.open_wifi().await.and_then(|r| to_value(r)) }).await?);
        }
        "wifi.close" => {
            out.ok(with_device(|d| async move { d.close_wifi().await.and_then(|r| to_value(r)) }).await?);
        }
        "wifi.credentials" => {
            out.ok(with_device(|d| async move {
                d.list_wifi_credentials().await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "wifi.forget" => {
            let ssid = str_field(&payload, "ssid");
            out.ok(with_device(|d| async move {
                d.delete_wifi_credential(&ssid).await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "sync.start" => {
            out.ok(with_device(|d| async move {
                d.start_sync().await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "sync.status" => {
            out.ok(with_device(|d| async move {
                d.sync_status().await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "upload.setUrl" => {
            let url = str_field(&payload, "url");
            out.ok(with_device(|d| async move {
                d.set_wifi_upload_url(&url).await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "ap.start" => {
            let ssid = payload.get("ssid").and_then(Value::as_str).map(str::to_owned);
            let password = payload.get("password").and_then(Value::as_str).map(str::to_owned);
            out.ok(with_device(|d| async move {
                d.start_access_point(ssid.as_deref(), password.as_deref())
                    .await
                    .and_then(|r| to_value(r))
            })
            .await?);
        }
        "ap.stop" => {
            out.ok(with_device(|d| async move {
                d.stop_access_point().await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "time.sync" => {
            out.ok(with_device(|d| async move {
                d.sync_time_now().await.and_then(|r| to_value(r))
            })
            .await?);
        }
        "transcode" => {
            // 设备原始 .apm（裸 IMA ADPCM）→ 16kHz/16bit 单声道 WAV，供 ASR 上传。
            let apm = str_field(&payload, "apm");
            let wav = str_field(&payload, "wav");
            let result = reai_card_sdk::apm_to_wav(
                std::path::Path::new(&apm),
                std::path::Path::new(&wav),
            )
            .await?;
            out.ok(json!({
                "path": result.path.to_string_lossy(),
                "samples": result.samples,
                "durationSecs": result.duration_secs(),
            }));
        }
        "ota.info" => out.ok(ota_info(&payload).await?),
        "ota.main" => ota_main(payload, out).await?,
        "ota.wifi" => ota_wifi(payload, out).await?,
        other => {
            return Err(SdkError::InvalidCommand(format!("unknown command: {other}")));
        }
    }
    Ok(())
}

// ── 具体实现 ────────────────────────────────────────────────

async fn connect(payload: Value) -> Result<Value, SdkError> {
    let id = str_field(&payload, "id");
    let manager = DeviceManager::new().await?;
    // 先按 id 找；找不到再放宽窗口重扫一次（广播有抖动）
    let mut found = None;
    for window in [Duration::from_secs(4), Duration::from_secs(6)] {
        let devices = manager.scan(window).await?;
        if let Some(d) = devices.iter().find(|d| d.id == id).cloned() {
            found = Some(d);
            break;
        }
    }
    let found = found.ok_or_else(|| SdkError::DeviceNotFound(id.clone()))?;
    let device = manager.connect(&found).await?;
    let snap = snapshot(&device).await?;
    *state().device.lock().await = Some(device);
    Ok(snap)
}

async fn snapshot(device: &DyjDevice) -> Result<Value, SdkError> {
    // SDK 规则：命令严格串行，顺序查询；storage 可能不支持，失败不致命。
    let battery = device.battery().await?;
    let state = device.state().await?;
    let info = device.device_info().await?;
    let storage = device.storage().await.ok();
    let record = device.record_status().await.ok();
    Ok(json!({
        "battery": battery,
        "state": state,
        "info": info,
        "storage": storage,
        "record": record,
    }))
}

/// 取全局设备执行命令；未连接时明确报错（Dart 侧据此提示"未连接"而不是静默）。
async fn with_device<F, Fut>(f: F) -> Result<Value, SdkError>
where
    F: FnOnce(DyjDevice) -> Fut,
    Fut: std::future::Future<Output = Result<Value, SdkError>>,
{
    let guard = state().device.lock().await;
    let device = guard.as_ref().ok_or(SdkError::Disconnected)?.clone();
    drop(guard);
    f(device).await
}

async fn ota_info(payload: &Value) -> Result<Value, SdkError> {
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
    to_value(info)
}

/// 主控固件：查询 → 下载 → 进 bootloader → Secure DFU 上传，全程推进度。
async fn ota_main(payload: Value, out: Emitter) -> Result<(), SdkError> {
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

    // 取出设备所有权：进 DFU 后原连接即失效，不能留旧句柄。
    let device = state().device.lock().await.take();
    let Some(device) = device else {
        out.fail(SdkError::Disconnected);
        return Ok(());
    };

    let manager = match DeviceManager::new().await {
        Ok(manager) => manager,
        Err(error) => {
            out.fail(error);
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
                // DFU 占总体 5%→95%
                "percent": 5 + (progress.percent() as f64 * 0.9) as u8,
                "text": "正在写入主控固件…",
                "sent": progress.sent,
                "total": progress.total,
            }));
        })
        .await;

    let _ = device.disconnect().await;
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

/// WiFi 模组：由 ESP32 自己从 api_url 拉固件；这里只发命令并跟进进度。
async fn ota_wifi(payload: Value, out: Emitter) -> Result<(), SdkError> {
    let wait = Duration::from_secs(payload.get("waitSecs").and_then(Value::as_u64).unwrap_or(600));
    out.progress(json!({"stage": "checking", "percent": 0, "text": "正在检查 Wi-Fi 模块固件…"}));

    let guard = state().device.lock().await;
    let Some(device) = guard.as_ref() else {
        out.fail(SdkError::Disconnected);
        return Ok(());
    };
    let device = device.clone();
    drop(guard);

    // 固件要求 check 与 start 在同一上电周期内先后执行。
    let check = match device.check_wifi_ota().await {
        Ok(check) => check,
        Err(error) => {
            out.fail(error);
            return Ok(());
        }
    };
    if !check.update_available {
        out.ok(json!({"module": "wifi", "upToDate": true, "check": check}));
        return Ok(());
    }

    // 订阅事件跟进进度（SDK 的 update_wifi_firmware 内部会消费事件流，这里自己跟）。
    let mut events = device.subscribe_events();
    if let Err(error) = device.start_wifi_ota().await {
        out.fail(error);
        return Ok(());
    }

    let deadline = tokio::time::Instant::now() + wait;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            out.fail(SdkError::Timeout { command: "OTA_WIFI".into(), seconds: wait.as_secs() });
            return Ok(());
        }
        match tokio::time::timeout(remaining, events.recv()).await {
            Ok(Ok(DeviceEvent::WifiOtaProgress(progress))) => {
                let terminal = progress.status.is_terminal();
                let percent = progress.percentage.min(100) as u8;
                if terminal {
                    out.ok(json!({"module": "wifi", "progress": progress}));
                    return Ok(());
                }
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
                out.fail(SdkError::Disconnected);
                return Ok(());
            }
            Err(_) => {
                out.fail(SdkError::Timeout { command: "OTA_WIFI".into(), seconds: wait.as_secs() });
                return Ok(());
            }
        }
    }
}

// ── 小工具 ──────────────────────────────────────────────────

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, SdkError> {
    serde_json::to_value(value).map_err(to_sdk)
}

fn to_sdk(error: serde_json::Error) -> SdkError {
    SdkError::InvalidCommand(format!("serialize: {error}"))
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
