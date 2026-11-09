//! Safe C ABI for reai-card-sdk v0.0.6 (not dyj-v1-sdk).
//! Every callback transfers a Rust heap CString; the receiver MUST free it exactly
//! once, including late/unknown tickets. Callback return does NOT end its lifetime.
//! One lane owns scan, connect, BLE commands, SD/AP transfer and OTA. A timeout
//! of a required command invalidates the connection. Optional metadata failures
//! are reported separately and never manufacture a physical disconnect.
#[cfg(target_os = "android")]
mod android;
mod firmware;
mod live_audio;
mod safe_transfer;
use safe_transfer::{confirm_delete, download_preserving, DownloadReceipt};

use reai_card_sdk::{
    ControlAction, ControlInput, DeviceEvent, DeviceManager, DiscoveredDevice, DyjDevice, SdkError,
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    ffi::{c_char, CStr, CString},
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};
use tokio::task::JoinHandle;

pub type Callback = extern "C" fn(usize, *mut c_char);
pub(crate) type Result<T> = std::result::Result<T, Error>;
#[derive(Debug)]
pub(crate) struct Error {
    pub code: &'static str,
    pub message: String,
}
impl Error {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}
impl From<SdkError> for Error {
    fn from(e: SdkError) -> Self {
        let code = match &e {
            SdkError::Timeout { .. } => "timeout",
            SdkError::Disconnected => "disconnected",
            SdkError::Transport(_) => "transport",
            SdkError::Protocol(_) => "protocol",
            _ => "sdk",
        };
        Self::new(code, e.to_string())
    }
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::new("io", e.to_string())
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Self::new("json", e.to_string())
    }
}

pub(crate) struct Connection {
    pub device: DyjDevice,
    pub discovered: DiscoveredDevice,
    events: JoinHandle<()>,
}
#[derive(Default)]
pub(crate) struct Session {
    pub connection: Option<Connection>,
    recovery: Option<JoinHandle<()>>,
    pub live: Option<live_audio::LiveTask>,
    pub dfu: Option<Arc<reai_card_sdk::DfuTarget>>,
    receipts: HashMap<String, DownloadReceipt>,
    next_receipt: u64,
    receipt_epoch: u64,
    #[cfg(test)]
    transfer_io_fault: Option<&'static str>,
}
struct State {
    runtime: tokio::runtime::Runtime,
    lane: tokio::sync::Mutex<Session>,
    event_callback: Mutex<Option<Callback>>,
    transfer_cancel: Mutex<HashMap<usize, tokio::sync::watch::Sender<bool>>>,
}
static STATE: OnceLock<State> = OnceLock::new();
fn state() -> &'static State {
    STATE.get_or_init(|| State {
        runtime: tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("Tokio runtime"),
        lane: tokio::sync::Mutex::new(Session::default()),
        event_callback: Mutex::new(None),
        transfer_cancel: Mutex::new(HashMap::new()),
    })
}
fn owned_json(value: Value) -> *mut c_char {
    CString::new(value.to_string())
        .expect("JSON escapes NUL")
        .into_raw()
}
pub(crate) fn emit(cb: Callback, ticket: usize, value: Value) {
    cb(ticket, owned_json(value));
}
fn event(value: Value) {
    // Keep the lock during dispatch: clearing callback waits for the last dispatch.
    if let Some(cb) = *state().event_callback.lock().expect("event callback lock") {
        emit(cb, 0, json!({"event": value}));
    }
}
pub(crate) fn progress(
    cb: Callback,
    ticket: usize,
    stage: &str,
    done: Option<u64>,
    total: Option<u64>,
) {
    emit(
        cb,
        ticket,
        json!({"event": {"kind":"progress", "stage":stage, "done":done, "total":total}}),
    );
}

#[no_mangle]
pub extern "C" fn card_bridge_version() -> *const c_char {
    static VERSION: OnceLock<CString> = OnceLock::new();
    VERSION
        .get_or_init(|| CString::new("card_bridge/0.2.0 reai-card-sdk/0.0.6").unwrap())
        .as_ptr()
}
/// # Safety
/// Only pointers returned by a callback may be freed, exactly once. Version is static.
#[no_mangle]
pub unsafe extern "C" fn card_bridge_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
#[no_mangle]
pub extern "C" fn card_bridge_set_event_callback(cb: Option<Callback>) {
    *state().event_callback.lock().expect("event callback lock") = cb;
}
/// Copies request synchronously; Dart may immediately free its input. The callback
/// stays valid for process lifetime, and each request receives one final envelope.
/// # Safety
/// request must be a valid NUL terminated UTF-8 string; callback must remain live.
#[no_mangle]
pub unsafe extern "C" fn card_bridge_request(request: *const c_char, cb: Callback, ticket: usize) {
    let parsed = if request.is_null() {
        Err(Error::new("argument", "请求指针为空"))
    } else {
        CStr::from_ptr(request)
            .to_str()
            .map_err(|_| Error::new("argument", "请求不是UTF-8"))
            .and_then(|s| serde_json::from_str::<Value>(s).map_err(Error::from))
    };
    // Register synchronously BEFORE spawning: a cancel submitted immediately
    // after this FFI call can signal even before the transfer task is scheduled.
    let parsed = parsed.and_then(|req| {
        let transfer =
            if req.get("op").and_then(Value::as_str) == Some("downloadFilePreservingSource") {
                Some(safe_transfer::register_transfer(ticket)?)
            } else {
                None
            };
        Ok((req, transfer))
    });
    state().runtime.spawn(async move {
        let result = match parsed {
            Ok((req, Some(transfer))) => {
                run_in_lane_registered(req, cb, ticket, &state().lane, Some(transfer)).await
            }
            Ok((req, None)) => run(req, cb, ticket).await,
            Err(e) => Err(e),
        };
        let envelope = match result {
            Ok(data) => json!({"ok":true,"data":data}),
            Err(e) => json!({"ok":false,"error":e.message,"code":e.code}),
        };
        emit(cb, ticket, envelope);
    });
}
async fn run(req: Value, cb: Callback, ticket: usize) -> Result<Value> {
    if req.get("op").and_then(Value::as_str) == Some("cancelFileTransfer") {
        return safe_transfer::cancel_transfer(&req);
    }
    run_in_lane(req, cb, ticket, &state().lane).await
}
async fn run_in_lane(
    req: Value,
    cb: Callback,
    ticket: usize,
    lane: &tokio::sync::Mutex<Session>,
) -> Result<Value> {
    let transfer = if req.get("op").and_then(Value::as_str) == Some("downloadFilePreservingSource")
    {
        Some(safe_transfer::register_transfer(ticket)?)
    } else {
        None
    };
    run_in_lane_registered(req, cb, ticket, lane, transfer).await
}
async fn run_in_lane_registered(
    req: Value,
    cb: Callback,
    ticket: usize,
    lane: &tokio::sync::Mutex<Session>,
    mut transfer: Option<safe_transfer::TransferCancellation>,
) -> Result<Value> {
    let op = text(&req, "op")?.to_owned();
    let waiting = tokio::time::timeout(Duration::from_secs(15), lane.lock());
    let locked = if let Some(transfer) = transfer.as_mut() {
        tokio::select! {
            biased;
            _ = transfer.cancelled.wait_for(|cancelled| *cancelled) => return Err(Error::new("cancelled", "保源下载排队期间已取消；未触碰设备")),
            result = waiting => result,
        }
    } else {
        waiting.await
    };
    let mut session =
        locked.map_err(|_| Error::new("busy", "设备命令车道忙，请等待当前传输/升级结束"))?;
    if let Some(recovery) = &session.recovery {
        if !recovery.is_finished() {
            return Err(Error::new("busy", "上一次连接超时，正在释放蓝牙连接槽"));
        }
        session.recovery.take();
    }
    let seconds = match op.as_str() {
        // Scan + retained SDK handshake + required snapshot + bounded metadata.
        // Optional reads cannot exhaust the former 65-second connect deadline.
        "connect" => 120,
        "firmwareUpdate" => 600,
        "downloadFile" => 300,
        "downloadFilePreservingSource" => 7260,
        "convertAudio" => 120,
        _ => 65,
    };
    let result = tokio::time::timeout(Duration::from_secs(seconds), async {
        if let Some(transfer) = transfer.as_ref() {
            safe_transfer::download_registered(
                &mut session,
                &req,
                cb,
                ticket,
                transfer.cancelled.clone(),
            )
            .await
        } else {
            execute(&mut session, &op, &req, cb, ticket).await
        }
    })
    .await;
    let result = result.unwrap_or_else(|_| {
        Err(Error::new(
            "timeout",
            if matches!(
                op.as_str(),
                "wifiStatus" | "wifiOtaStatus" | "apOtaStatus" | "checkFirmware" | "checkWifiOta"
            ) {
                format!("{op} 可选查询超过应答窗口（并非物理断连）")
            } else {
                format!("{op} 超时；连接已失效，请重连")
            },
        ))
    });
    // These queries are optional capabilities, not connection health probes.
    // SDK timeout/JSON/firmware refusal is surfaced without tearing down BLE.
    let result = if matches!(
        op.as_str(),
        "wifiStatus" | "wifiOtaStatus" | "apOtaStatus" | "checkFirmware" | "checkWifiOta"
    ) {
        result.map_err(|e| {
            if matches!(e.code, "timeout" | "json" | "sdk") {
                Error::new(
                    "optionalUnavailable",
                    format!("{op} 暂不可用：{}", e.message),
                )
            } else {
                e
            }
        })
    } else {
        result
    };
    if result.as_ref().err().is_some_and(|e| {
        matches!(
            e.code,
            "timeout" | "disconnected" | "transport" | "protocol" | "cancelled"
        )
    }) || session
        .connection
        .as_ref()
        .is_some_and(|c| c.device.is_terminal())
    {
        cleanup(&mut session).await;
    }
    result
}
pub(crate) async fn cleanup(session: &mut Session) {
    let _ = close_connection(session).await;
}
pub(crate) async fn close_connection(session: &mut Session) -> Result<()> {
    // A receipt is valid only in the exact connection that downloaded it.
    session.receipt_epoch += 1;
    session.receipts.clear();
    live_audio::cleanup_live(session).await;
    if let Some(dfu) = session.dfu.take() {
        let mut job = tokio::spawn(async move { dfu.disconnect().await });
        match tokio::time::timeout(Duration::from_secs(5), &mut job).await {
            Ok(result) => {
                result.map_err(|_| Error::new("protocol", "DFU清理任务异常停止"))??;
            }
            Err(_) => {
                session.recovery = Some(tokio::spawn(async move {
                    let _ = job.await;
                }));
                return Err(Error::new("timeout", "DFU断连超时，正在释放目标连接槽"));
            }
        }
    }
    if let Some(c) = session.connection.take() {
        c.events.abort();
        let mut job = tokio::spawn(async move { c.device.disconnect().await });
        match tokio::time::timeout(Duration::from_secs(5), &mut job).await {
            Ok(result) => {
                result.map_err(|_| Error::new("protocol", "断连任务异常停止"))??;
            }
            Err(_) => {
                session.recovery = Some(tokio::spawn(async move {
                    let _ = job.await;
                }));
                return Err(Error::new(
                    "timeout",
                    "蓝牙断连超时；保留清理任务，禁止重用连接槽",
                ));
            }
        }
    }
    Ok(())
}
pub(crate) fn device(session: &Session) -> Result<&DyjDevice> {
    session
        .connection
        .as_ref()
        .map(|c| &c.device)
        .ok_or_else(|| Error::new("disconnected", "录音卡未连接"))
}
pub(crate) fn text<'a>(req: &'a Value, key: &str) -> Result<&'a str> {
    req.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| Error::new("argument", format!("缺少参数 {key}")))
}
fn flag(req: &Value, key: &str) -> bool {
    req.get(key).and_then(Value::as_bool) == Some(true)
}
pub(crate) fn confirmed(req: &Value) -> Result<()> {
    if flag(req, "userConfirmed") {
        Ok(())
    } else {
        Err(Error::new("confirmation", "需要用户明确确认本次设备操作"))
    }
}
fn serialize(v: impl serde::Serialize) -> Result<Value> {
    Ok(serde_json::to_value(v)?)
}

async fn connect(session: &mut Session, id: &str) -> Result<Value> {
    close_connection(session).await?;
    let manager = DeviceManager::new().await?;
    let found = manager
        .scan(Duration::from_secs(3))
        .await?
        .into_iter()
        .find(|d| d.id == id)
        .ok_or_else(|| Error::new("notFound", "指定录音卡不在扫描范围内"))?;
    // Never abort SDK connect after it has acquired a peripheral. Retain its task
    // for late disconnect, and block the next connection until cleanup completes.
    let discovered = found.clone();
    let mut job = tokio::spawn(async move { manager.connect(&found).await });
    let dev = match tokio::time::timeout(Duration::from_secs(40), &mut job).await {
        Ok(joined) => joined.map_err(|_| Error::new("protocol", "连接任务异常停止"))??,
        Err(_) => {
            session.recovery = Some(tokio::spawn(async move {
                if let Ok(Ok(d)) = job.await {
                    let _ = d.disconnect().await;
                }
            }));
            return Err(Error::new(
                "timeout",
                "建立蓝牙连接超时；保留任务以释放迟到连接",
            ));
        }
    };
    let events = pump_events(&dev);
    // Save BEFORE snapshot; failed/timeout snapshot can now explicitly disconnect.
    session.connection = Some(Connection {
        device: dev,
        discovered,
        events,
    });
    match snapshot(device(session)?).await {
        Ok(value) => Ok(value),
        Err(e) => {
            cleanup(session).await;
            Err(e)
        }
    }
}
fn pump_events(dev: &DyjDevice) -> JoinHandle<()> {
    let mut rx = dev.subscribe_events();
    let already_terminal = dev.is_terminal();
    tokio::spawn(async move {
        if already_terminal {
            event(json!({"kind":"disconnected","sessionInvalidated":true}));
            return;
        }
        loop {
            let value = match rx.recv().await {
                Ok(DeviceEvent::Disconnected) => {
                    event(json!({"kind":"disconnected","sessionInvalidated":true}));
                    break;
                }
                Ok(DeviceEvent::RecordStatus(s)) => json!({"kind":"recordStatus", "data":s}),
                Ok(DeviceEvent::WifiOtaProgress(p)) => json!({"kind":"wifiOtaProgress", "data":p}),
                Ok(DeviceEvent::Sync(s)) => json!({"kind":"sync", "data":s}),
                Ok(DeviceEvent::Power(p)) => json!({"kind":"power", "data":p}),
                Ok(_) => continue, // Do not forward raw payloads (may contain credentials).
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    json!({"kind":"eventGap", "skipped":n})
                }
                Err(_) => {
                    event(json!({"kind":"disconnected"}));
                    break;
                }
            };
            event(value);
        }
    })
}
pub(crate) async fn snapshot(dev: &DyjDevice) -> Result<Value> {
    let battery = dev.battery().await?;
    let state = dev.state().await?;
    let recording = dev.record_status().await?;
    // BASE_INFO may be absent/malformed on older firmware. It must not hide an
    // otherwise confirmed battery/state/recording reading or disconnect the card.
    let mut warnings = serde_json::Map::new();
    let info = optional_query("info", "BASE_INFO", dev.device_info(), &mut warnings).await?;
    // Do not send UART commands to a powered-down Wi-Fi chip. Off is known;
    // powered-on but failed query is unknown, not a fabricated disconnected STA.
    let wifi = if state.wifi_open {
        optional_query("wifi", "WIFI_STATUS", dev.wifi_status(), &mut warnings).await?
    } else {
        json!({"status":"off", "connected":false})
    };
    Ok(
        json!({"battery":battery,"state":state,"info":info,"record":recording,"wifi":wifi,"optionalErrors":warnings}),
    )
}
async fn optional_query<T: serde::Serialize>(
    field: &str,
    command: &str,
    query: impl std::future::Future<Output = std::result::Result<T, SdkError>>,
    warnings: &mut serde_json::Map<String, Value>,
) -> Result<Value> {
    // SDK resets its wait on unrelated frames. A hard optional deadline prevents
    // continuous notifications from keeping metadata pending indefinitely.
    let result = tokio::time::timeout(Duration::from_secs(11), query)
        .await
        .unwrap_or_else(|_| {
            Err(SdkError::Timeout {
                command: command.to_owned(),
                seconds: 11,
            })
        });
    optional_status(field, result, warnings)
}
fn optional_status<T: serde::Serialize>(
    field: &str,
    result: std::result::Result<T, SdkError>,
    warnings: &mut serde_json::Map<String, Value>,
) -> Result<Value> {
    match result {
        Ok(value) => serialize(value),
        Err(e @ (SdkError::Disconnected | SdkError::Transport(_) | SdkError::Protocol(_))) => {
            Err(e.into())
        }
        Err(e) => {
            let error = Error::from(e);
            warnings.insert(
                field.to_owned(),
                json!({"code":error.code,"message":error.message}),
            );
            Ok(Value::Null)
        }
    }
}
fn live_blocks(op: &str) -> bool {
    // The live task issues background wire commands outside the Session lane.
    // Its stop/cleanup owns that interval; do not interleave multi-command reads.
    !matches!(
        op,
        "stopAudioCapture" | "audioCaptureStatus" | "disconnect" | "convertAudio"
    )
}

async fn execute(
    session: &mut Session,
    op: &str,
    req: &Value,
    cb: Callback,
    ticket: usize,
) -> Result<Value> {
    if session.live.is_some() && live_blocks(op) {
        return Err(Error::new(
            "busy",
            "实时音频分片任务占有通道；先显式停止采集，不混用历史take/Wi-Fi/OTA",
        ));
    }
    // Invalidate before any possibly mutating attempt, including a refused or
    // partially executed command; SDK worker also updates the wire epoch for
    // hardware-originated changes synchronously before broadcasting them.
    if matches!(
        op,
        "setRecording"
            | "setWifiEnabled"
            | "connectWifi"
            | "disconnectWifi"
            | "setRealtimeEnabled"
            | "recordMark"
            | "startAudioCapture"
            | "stopAudioCapture"
            | "firmwareUpdate"
            | "downloadFile"
    ) {
        session.receipt_epoch += 1;
    }
    match op {
        "scan" => {
            let ms = req
                .get("timeoutMs")
                .and_then(Value::as_u64)
                .unwrap_or(3000)
                .clamp(500, 10000);
            serialize(
                DeviceManager::new()
                    .await?
                    .scan(Duration::from_millis(ms))
                    .await?,
            )
        }
        "connect" => connect(session, text(req, "id")?).await,
        "disconnect" => {
            close_connection(session).await?;
            Ok(json!({"disconnected":true}))
        }
        "status" => snapshot(device(session)?).await,
        "listFiles" => {
            let d = device(session)?;
            // Listing blocks firmware's SD loop; never enumerate while recording
            // or while unframed realtime binary notifications may be flowing.
            let record = d.record_status().await?;
            if record.is_recording || record.realtime_enabled {
                return Err(Error::new(
                    "busy",
                    "请先显式停止录音及实时传输，再读取历史文件列表",
                ));
            }
            if d.state().await?.wifi_open {
                let client = d.access_point_client().await?;
                let mut files = Vec::new();
                let mut page = 1;
                loop {
                    let result = client.list_files(page, 100).await?;
                    files.extend(result.files.into_iter().map(|f| json!({"name":f.name,"size":f.size,"createdAt":f.timestamp,"session":f.session,"seq":f.seq,"startAt":f.start_at,"synced":f.synced,"isDirectory":false,"transport":"ap"})));
                    if page >= result.total_pages {
                        break;
                    }
                    page += 1;
                    if page > 1000 {
                        return Err(Error::new("protocol", "AP文件页数异常"));
                    }
                }
                Ok(Value::Array(files))
            } else {
                let files = d
                    .list_files(req.get("folder").and_then(Value::as_str))
                    .await?;
                Ok(Value::Array(files.into_iter().map(|f| json!({"name":f.name,"size":f.size,"createdAt":f.created_at,"session":f.session,"seq":f.seq,"startAt":f.start_at,"synced":f.synced,"isDirectory":f.is_dir == Some(1),"transport":"ble"})).collect()))
            }
        }
        "downloadFile" => download(session, req, cb, ticket).await,
        "downloadFilePreservingSource" => download_preserving(session, req, cb, ticket).await,
        "confirmDeleteFile" => confirm_delete(session, req).await,
        "fileTransferCapabilities" => safe_transfer::capabilities(session).await,
        "convertAudio" => convert(req).await,
        "startAudioCapture" => live_audio::start(session, req).await,
        "stopAudioCapture" => live_audio::stop(session, req).await,
        "audioCaptureStatus" => live_audio::status(session),
        "setWifiEnabled" => {
            let d = device(session)?;
            if flag(req, "enabled") && d.record_status().await?.is_recording {
                return Err(Error::new(
                    "busy",
                    "不能在录音期间将SD切给Wi-Fi；请先显式停止录音",
                ));
            }
            serialize(if flag(req, "enabled") {
                d.open_wifi().await?
            } else {
                d.close_wifi().await?
            })
        }
        "wifiStatus" => serialize(device(session)?.wifi_status().await?),
        "scanWifi" => serialize(device(session)?.scan_wifi().await?),
        "wifiOtaStatus" => serialize(device(session)?.wifi_ota_status().await?),
        "apOtaStatus" => serialize(
            device(session)?
                .access_point_client()
                .await?
                .ota_status()
                .await?,
        ),
        "connectWifi" => {
            let result = device(session)?
                .connect_wifi(
                    text(req, "ssid")?,
                    req.get("password").and_then(Value::as_str).unwrap_or(""),
                )
                .await;
            result.map_err(|_| Error::new("wifi", "连接Wi-Fi失败；请检查网络、密码和设备状态"))?;
            let wifi = device(session)?.wifi_status().await?;
            if !wifi.connected {
                return Err(Error::new("wifi", "Wi-Fi命令已接受但设备尚未连接"));
            }
            serialize(wifi)
        }
        "disconnectWifi" => serialize(device(session)?.disconnect_wifi().await?),
        "listWifiCredentials" => serialize(device(session)?.list_wifi_credentials().await?),
        "deleteWifiCredential" => serialize(
            device(session)?
                .delete_wifi_credential(text(req, "ssid")?)
                .await?,
        ),
        "setRecording" => {
            let d = device(session)?;
            let enabled = flag(req, "enabled");
            if enabled {
                d.start_recording().await?;
            } else {
                d.stop_recording().await?;
            }
            let actual = d.record_status().await?;
            if actual.is_recording != enabled {
                return Err(Error::new(
                    "verification",
                    "设备录音命令已返回，但读回状态未确认；请重试状态读取",
                ));
            }
            serialize(actual)
        }
        "setRealtimeEnabled" => serialize(
            device(session)?
                .set_realtime_enabled(flag(req, "enabled"))
                .await?,
        ),
        "recordMark" => serialize(device(session)?.record_mark().await?),
        "controlBindings" => serialize(device(session)?.control_bindings().await?),
        "setMarkEnabled" => {
            confirmed(req)?;
            let d = device(session)?;
            let input = ControlInput::from_config_key(text(req, "input")?)
                .ok_or_else(|| Error::new("argument", "未知硬件输入绑定"))?;
            let current = d.control_action(input).await?;
            let expected = text(req, "expectedAction")?;
            if current.wire_name() != expected {
                return Err(Error::new("conflict", "硬件绑定已经变化，请重新读取并确认"));
            }
            let target = if flag(req, "enabled") {
                ControlAction::RecordMark
            } else {
                ControlAction::None
            };
            d.set_control_action(input, target.clone()).await?;
            let actual = d.control_action(input).await?;
            if actual != target {
                return Err(Error::new("verification", "mark绑定写入后读回不一致"));
            }
            Ok(json!({"input":input.config_key(),"action":actual.wire_name()}))
        }
        "checkFirmware" => firmware::check(session, req).await,
        "firmwareUpdate" => firmware::update(session, req, cb, ticket).await,
        "checkWifiOta" => {
            let base = text(req, "apiBaseUrl")?;
            firmware::validate_https(base, req)?;
            let d = device(session)?;
            if d.sta_api_base_url().await?.as_deref() != Some(base) {
                return Err(Error::new(
                    "configuration",
                    "设备OTA服务地址与配置不一致；拒绝使用默认未知源",
                ));
            }
            serialize(d.check_wifi_ota().await?)
        }
        _ => Err(Error::new("argument", "未知设备操作")),
    }
}
fn validate_remote(path: &str) -> Result<()> {
    if path.contains("..") || path.contains('\\') || path.contains('\0') || path.ends_with('/') {
        return Err(Error::new("argument", "非法设备文件路径"));
    }
    Ok(())
}
async fn hash_local(path: &std::path::Path, expected_bytes: u64) -> Result<String> {
    use sha2::{Digest, Sha256};
    use tokio::io::AsyncReadExt;
    let mut file = tokio::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .await?;
    if !file.metadata().await?.is_file() || file.metadata().await?.len() != expected_bytes {
        return Err(Error::new(
            "integrity",
            "本机下载长度不匹配或不是普通文件；保留卡端原件",
        ));
    }
    file.sync_all().await?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut read = 0;
    loop {
        let n = file.read(&mut buffer).await?;
        if n == 0 {
            break;
        }
        read += n as u64;
        hasher.update(&buffer[..n]);
    }
    if read != expected_bytes || file.metadata().await?.len() != expected_bytes {
        return Err(Error::new(
            "integrity",
            "校验期间本机文件长度变化；保留卡端原件",
        ));
    }
    Ok(format!("{:x}", hasher.finalize()))
}
async fn download(session: &Session, req: &Value, cb: Callback, ticket: usize) -> Result<Value> {
    let name = text(req, "name")?;
    validate_remote(name)?;
    let directory = std::path::Path::new(text(req, "directory")?);
    if !directory.is_absolute() {
        return Err(Error::new("argument", "下载目录必须是应用私有绝对路径"));
    }
    let use_ble = req.get("transport").and_then(Value::as_str) == Some("ble");
    if use_ble && !flag(req, "allowDestructive") {
        return Err(Error::new(
            "destructive",
            "BLE take成功会删除卡上原文件；需要显式allowDestructive",
        ));
    }
    let d = device(session)?;
    if use_ble {
        let recording = d.record_status().await?;
        if recording.is_recording || recording.realtime_enabled {
            return Err(Error::new(
                "busy",
                "历史BLE take不得与录音或实时传输混用；先显式停止二者",
            ));
        }
    }
    progress(
        cb,
        ticket,
        if use_ble { "bleTake" } else { "apDownload" },
        None,
        None,
    );
    let saved = if use_ble {
        d.take_file_to_dir(name, directory).await.map_err(|e| {
            let mut error = Error::from(e);
            error.message = format!(
                "{}；旧BLE take可能已删源（在客户端最终落盘/入库前），不能承诺可重试保源",
                error.message
            );
            error
        })?
    } else {
        // Never silently switch to BLE on AP failure. Power/network changes are separate APIs.
        if !d.state().await?.wifi_open {
            return Err(Error::new(
                "apUnavailable",
                "请先打开卡Wi-Fi并在系统加入录音卡热点；不会自动改用删源BLE路径",
            ));
        }
        let client = d.access_point_client().await?;
        client.download_to_dir(name, directory).await?
    };
    if let Some(expected) = req.get("expectedBytes").and_then(Value::as_u64) {
        if saved.bytes_written != expected {
            return Err(Error::new(
                "integrity",
                if use_ble {
                    "下载长度与文件列表不一致；旧BLE take已提前删源，不能宣称保源或入库成功"
                } else {
                    "下载长度与文件列表不一致，卡端原件保留，不可用于转写"
                },
            ));
        }
    }
    progress(
        cb,
        ticket,
        "downloaded",
        Some(saved.bytes_written),
        Some(saved.bytes_written),
    );
    Ok(
        json!({"path":saved.path,"bytes":saved.bytes_written,"originalName":saved.original_name,"deviceName":saved.device_name,"recordedAt":saved.recorded_at.map(|v|v.to_rfc3339()),"sourceDeleted":use_ble}),
    )
}
async fn convert(req: &Value) -> Result<Value> {
    let source = std::path::Path::new(text(req, "source")?);
    let destination = std::path::Path::new(text(req, "destination")?);
    if source == destination || !source.is_absolute() || !destination.is_absolute() {
        return Err(Error::new("argument", "转换必须使用不同的应用私有绝对路径"));
    }
    if tokio::fs::try_exists(destination).await? {
        return Err(Error::new("conflict", "转换目标已存在，不覆盖已有录音"));
    }
    let metadata = tokio::fs::metadata(source).await?;
    if metadata.len() > 128 * 1024 * 1024 {
        return Err(Error::new("resource", "音频超过128MiB，请按段转换"));
    }
    let format = text(req, "format")?;
    let sample_count = match format {
        "apm" => metadata.len() * 2,
        "pcm" => {
            if metadata.len() % 2 != 0 {
                return Err(Error::new("integrity", "PCM16LE长度必须是偶数"));
            }
            metadata.len() / 2
        }
        _ => {
            return Err(Error::new(
                "argument",
                "只支持裸IMA ADPCM apm或16kHz单声道PCM16LE",
            ))
        }
    };
    if sample_count == 0 {
        return Err(Error::new("integrity", "音频文件为空"));
    }
    let mut header = reai_card_sdk::wav_bytes(&[], reai_card_sdk::SAMPLE_RATE_HZ);
    header[4..8].copy_from_slice(&((36 + sample_count * 2) as u32).to_le_bytes());
    header[40..44].copy_from_slice(&((sample_count * 2) as u32).to_le_bytes());
    let mut part = destination.as_os_str().to_os_string();
    part.push(".part");
    let result: Result<()> = async {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let mut reader = tokio::fs::File::open(source).await?;
        let mut writer = tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(std::path::Path::new(&part))
            .await?;
        writer.write_all(&header).await?;
        let mut decoder = reai_card_sdk::AdpcmDecoder::new();
        let mut buffer = vec![0u8; 65536];
        let mut remaining = metadata.len();
        while remaining > 0 {
            let count = (remaining as usize).min(buffer.len());
            reader.read_exact(&mut buffer[..count]).await?;
            let samples: Vec<i16> = if format == "apm" {
                decoder.decode(&buffer[..count])
            } else {
                buffer[..count]
                    .chunks_exact(2)
                    .map(|b| i16::from_le_bytes([b[0], b[1]]))
                    .collect()
            };
            // Decoder state spans read buffers; PCM WAV chunks share one header.
            let chunk = reai_card_sdk::wav_bytes(&samples, 16000);
            writer.write_all(&chunk[44..]).await?;
            remaining -= count as u64;
        }
        let mut extra = [0u8; 1];
        if reader.read(&mut extra).await? != 0 {
            return Err(Error::new("integrity", "转换期间源音频长度发生变化"));
        }
        writer.sync_all().await?;
        Ok(())
    }
    .await;
    result?; // Preserve failed .part for explicit recovery; never delete a preexisting file.
    tokio::fs::rename(std::path::Path::new(&part), destination).await?;
    Ok(
        json!({"path":destination,"samples":sample_count,"sampleRate":16000,"channels":1,"durationSeconds":sample_count as f64/16000.0}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use reai_card_sdk::{BleTransport, NotificationStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    include!("safe_transfer_tests.rs");

    #[derive(Clone)]
    enum UploadAction {
        Frame(Vec<u8>),
        Delay(Duration),
        Terminal,
    }

    extern "C" fn discard(_ticket: usize, ptr: *mut c_char) {
        unsafe {
            card_bridge_free_string(ptr);
        }
    }

    /// SDK's real parser and notification worker run against this in-memory
    /// transport only. No DeviceManager/adapter/scan/connect path is touched.
    struct TestBlock {
        entered: tokio::sync::Semaphore,
        release: tokio::sync::Semaphore,
    }
    impl TestBlock {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                entered: tokio::sync::Semaphore::new(0),
                release: tokio::sync::Semaphore::new(0),
            })
        }
        async fn wait(&self) {
            self.entered.add_permits(1);
            self.release.acquire().await.unwrap().forget();
        }
        async fn reached(&self) {
            self.entered.acquire().await.unwrap().forget();
        }
    }
    struct FakeTransport {
        tx: tokio::sync::mpsc::UnboundedSender<reai_card_sdk::Result<Vec<u8>>>,
        rx: tokio::sync::Mutex<
            Option<tokio::sync::mpsc::UnboundedReceiver<reai_card_sdk::Result<Vec<u8>>>>,
        >,
        buffer: tokio::sync::Mutex<Vec<u8>>,
        commands: Mutex<Vec<String>>,
        replies: Mutex<HashMap<String, Value>>,
        silent: Mutex<Vec<String>>,
        recording: AtomicBool,
        wifi: AtomicBool,
        disconnected: AtomicBool,
        source_deleted: AtomicBool,
        record_pushes: AtomicBool,
        payloads: Mutex<Vec<(String, Value)>>,
        upload_script: Mutex<Option<Vec<UploadAction>>>,
        file_entries: Mutex<Option<Vec<Value>>>,
        notifications_count: std::sync::atomic::AtomicUsize,
        disconnect_count: std::sync::atomic::AtomicUsize,
        disconnect_block: Mutex<Option<Arc<TestBlock>>>,
        write_blocks: Mutex<HashMap<String, Arc<TestBlock>>>,
        block_upload_write: Mutex<Option<Arc<TestBlock>>>,
    }
    impl FakeTransport {
        fn new() -> Arc<Self> {
            let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
            Arc::new(Self {
                tx,
                rx: tokio::sync::Mutex::new(Some(rx)),
                buffer: tokio::sync::Mutex::new(Vec::new()),
                commands: Mutex::new(Vec::new()),
                replies: Mutex::new(HashMap::new()),
                silent: Mutex::new(Vec::new()),
                recording: AtomicBool::new(false),
                wifi: AtomicBool::new(false),
                disconnected: AtomicBool::new(false),
                source_deleted: AtomicBool::new(false),
                record_pushes: AtomicBool::new(true),
                payloads: Mutex::new(Vec::new()),
                upload_script: Mutex::new(None),
                file_entries: Mutex::new(None),
                notifications_count: std::sync::atomic::AtomicUsize::new(0),
                disconnect_count: std::sync::atomic::AtomicUsize::new(0),
                disconnect_block: Mutex::new(None),
                write_blocks: Mutex::new(HashMap::new()),
                block_upload_write: Mutex::new(None),
            })
        }
        fn send(&self, command: &str, payload: Value) {
            self.tx
                .send(Ok(format!("{command}:{payload}\r\n").into_bytes()))
                .unwrap();
        }
        fn respond(&self, command: &str) {
            self.commands.lock().unwrap().push(command.to_owned());
            if self.silent.lock().unwrap().iter().any(|s| s == command) {
                return;
            }
            if command == "FILE_UPLOAD" {
                let default = vec![
                    UploadAction::Frame(b"FILE_UPLOAD:{\"code\":0,\"state\":\"start\",\"size\":3,\"name\":\"a.apm\"}\r\n".to_vec()),
                    UploadAction::Frame(vec![0,1,2,3]),
                    UploadAction::Frame(b"FILE_UPLOAD:{\"code\":0,\"state\":\"end\"}\r\n".to_vec()),
                ];
                let script = self
                    .upload_script
                    .lock()
                    .unwrap()
                    .clone()
                    .unwrap_or(default);
                let tx = self.tx.clone();
                tokio::spawn(async move {
                    for action in script {
                        match action {
                            UploadAction::Frame(bytes) => {
                                let _ = tx.send(Ok(bytes));
                            }
                            UploadAction::Delay(duration) => tokio::time::sleep(duration).await,
                            UploadAction::Terminal => {
                                let _ = tx.send(Err(SdkError::Disconnected));
                                break;
                            }
                        }
                    }
                });
                return;
            }
            if command == "FILE_LIST" {
                if let Some(entries) = self.file_entries.lock().unwrap().clone() {
                    for entry in entries {
                        self.send(command, entry);
                    }
                    self.send(command, json!({"index":-1}));
                    return;
                }
            }
            if let Some(payload) = self.replies.lock().unwrap().get(command).cloned() {
                self.send(command, payload);
                return;
            }
            let payload = match command {
                "BATTERY" => {
                    json!({"level":52,"levelText":"mid","isCharging":false,"voltage":3800,"adc_raw":1})
                }
                "STATE_INFO" => {
                    json!({"authState":false,"recordRealtimeEnabled":false,"wifiOpen":self.wifi.load(Ordering::SeqCst),"bootType":"normal","lowPowerMode":false})
                }
                "BASE_INFO" => {
                    json!({"version":"0.3.9","versionCode":309,"deviceId":"fake-card","deviceName":"DYJV2_FAKE","timestamp":1})
                }
                "WIFI_OPEN" => {
                    self.wifi.store(true, Ordering::SeqCst);
                    json!({"code":0})
                }
                "WIFI_CLOSE" => {
                    self.wifi.store(false, Ordering::SeqCst);
                    json!({"code":0})
                }
                "RECORD_START" => {
                    self.recording.store(true, Ordering::SeqCst);
                    json!({"code":0})
                }
                "RECORD_STOP" => {
                    self.recording.store(false, Ordering::SeqCst);
                    json!({"code":0})
                }
                "RECORD_STATUS" => {
                    // Same-name unsolicited frame precedes the true query reply.
                    if self.record_pushes.load(Ordering::SeqCst) {
                        self.send(command, json!({"isRecording":!self.recording.load(Ordering::SeqCst),"realtimeEnabled":true,"reason":"button"}));
                        // Realtime binary notify must not become a command response.
                        self.tx.send(Ok(vec![0, 1, 2, 3])).unwrap();
                    }
                    json!({"isRecording":self.recording.load(Ordering::SeqCst),"realtimeEnabled":false})
                }
                "FILE_LIST" => {
                    self.send(
                        command,
                        json!({"index":0,"name":"a.apm","size":3,"is_dir":0}),
                    );
                    json!({"index":-1})
                }
                _ => json!({"code":0}),
            };
            self.send(command, payload);
        }
    }
    #[async_trait::async_trait]
    impl BleTransport for FakeTransport {
        async fn write(&self, bytes: &[u8]) -> reai_card_sdk::Result<()> {
            // Stall the FIRST upload chunk, before it reaches the fake device.
            let block = if bytes.starts_with(b"FILE_UPLOAD") {
                self.block_upload_write.lock().unwrap().clone()
            } else {
                None
            };
            if let Some(block) = block {
                block.wait().await;
            }
            let mut buffer = self.buffer.lock().await;
            buffer.extend_from_slice(bytes);
            while let Some(end) = buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = buffer.drain(..=end).collect();
                let line = String::from_utf8(line).unwrap();
                let command = line.trim().split(':').next().unwrap();
                let payload = line
                    .trim()
                    .split_once(':')
                    .and_then(|(_, body)| serde_json::from_str::<Value>(body).ok())
                    .unwrap_or(Value::Null);
                if command == "FILE_DELETE"
                    || (command == "FILE_UPLOAD"
                        && payload.get("keep").and_then(Value::as_bool) != Some(true))
                {
                    self.source_deleted.store(true, Ordering::SeqCst);
                }
                self.payloads
                    .lock()
                    .unwrap()
                    .push((command.to_owned(), payload));
                self.respond(command);
                let block = self.write_blocks.lock().unwrap().get(command).cloned();
                if let Some(block) = block {
                    block.wait().await;
                }
            }
            Ok(())
        }
        async fn notifications(&self) -> reai_card_sdk::Result<NotificationStream> {
            self.notifications_count.fetch_add(1, Ordering::SeqCst);
            let rx = self.rx.lock().await.take().unwrap();
            Ok(Box::pin(futures::stream::unfold(rx, |mut rx| async {
                let item = rx.recv().await?;
                if matches!(&item, Ok(bytes) if bytes.is_empty()) {
                    None
                } else {
                    Some((item, rx))
                }
            })))
        }
        async fn disconnect(&self) -> reai_card_sdk::Result<()> {
            let count = self.disconnect_count.fetch_add(1, Ordering::SeqCst);
            // Only the FIRST disconnect stalls; a buggy second cleanup would
            // return immediately and let Native wrongly cross its barrier.
            let block = self.disconnect_block.lock().unwrap().clone();
            if count == 0 {
                if let Some(block) = block {
                    block.wait().await;
                }
            }
            self.disconnected.store(true, Ordering::SeqCst);
            Ok(())
        }
    }
    async fn fake_session(transport: Arc<FakeTransport>) -> Session {
        let device = DyjDevice::from_transport(transport).await.unwrap();
        Session {
            connection: Some(Connection {
                device,
                discovered: DiscoveredDevice {
                    id: "fake-transport".into(),
                    name: "DYJV2_FAKE".into(),
                    rssi: None,
                },
                events: tokio::spawn(std::future::pending()),
            }),
            ..Default::default()
        }
    }
    #[tokio::test(start_paused = true)]
    async fn optional_info_and_wifi_timeout_do_not_disconnect_valid_core_status() {
        let t = FakeTransport::new();
        t.wifi.store(true, Ordering::SeqCst);
        t.silent
            .lock()
            .unwrap()
            .extend(["BASE_INFO".to_owned(), "WIFI_STATUS".to_owned()]);
        let lane = tokio::sync::Mutex::new(fake_session(t.clone()).await);
        let result = run_in_lane(json!({"op":"status"}), discard, 1, &lane)
            .await
            .unwrap();
        assert_eq!(result["battery"]["level"], 52);
        assert_eq!(result["record"]["isRecording"], false);
        assert!(result["info"].is_null());
        assert!(result["wifi"].is_null());
        assert_eq!(result["optionalErrors"]["wifi"]["code"], "timeout");
        assert!(lane.lock().await.connection.is_some());
        assert!(!t.disconnected.load(Ordering::SeqCst));
    }
    #[tokio::test(start_paused = true)]
    async fn optional_query_has_absolute_deadline_even_if_sdk_never_finishes() {
        let mut warnings = serde_json::Map::new();
        let result =
            optional_query::<Value>("info", "BASE_INFO", std::future::pending(), &mut warnings)
                .await
                .unwrap();
        assert!(result.is_null());
        assert_eq!(warnings["info"]["code"], "timeout");
    }
    #[tokio::test]
    async fn optional_malformed_info_and_powered_down_wifi_are_not_connection_failure() {
        let t = FakeTransport::new();
        t.replies
            .lock()
            .unwrap()
            .insert("BASE_INFO".into(), json!({"code":0,"version":"0.3.9"}));
        let session = fake_session(t.clone()).await;
        let result = snapshot(device(&session).unwrap()).await.unwrap();
        assert!(result["info"].is_null());
        assert_eq!(result["wifi"]["status"], "off");
        assert!(!t
            .commands
            .lock()
            .unwrap()
            .iter()
            .any(|s| s == "WIFI_STATUS"));
        assert!(!t.disconnected.load(Ordering::SeqCst));
    }
    #[tokio::test(start_paused = true)]
    async fn required_status_timeout_still_invalidates_and_releases_connection() {
        let t = FakeTransport::new();
        t.silent.lock().unwrap().push("BATTERY".into());
        let lane = tokio::sync::Mutex::new(fake_session(t.clone()).await);
        assert_eq!(
            run_in_lane(json!({"op":"status"}), discard, 1, &lane)
                .await
                .unwrap_err()
                .code,
            "timeout"
        );
        assert!(lane.lock().await.connection.is_none());
        assert!(t.disconnected.load(Ordering::SeqCst));
    }
    #[tokio::test(start_paused = true)]
    async fn optional_query_timeout_preserves_lane_but_stream_disconnect_is_fatal() {
        let t = FakeTransport::new();
        t.wifi.store(true, Ordering::SeqCst);
        t.silent.lock().unwrap().push("WIFI_STATUS".into());
        let lane = tokio::sync::Mutex::new(fake_session(t.clone()).await);
        assert_eq!(
            run_in_lane(json!({"op":"wifiStatus"}), discard, 1, &lane)
                .await
                .unwrap_err()
                .code,
            "optionalUnavailable"
        );
        assert!(lane.lock().await.connection.is_some());
        t.tx.send(Err(SdkError::Transport("fake link died".into())))
            .unwrap();
        tokio::task::yield_now().await;
        assert_eq!(
            run_in_lane(json!({"op":"status"}), discard, 2, &lane)
                .await
                .unwrap_err()
                .code,
            "disconnected"
        );
        assert!(t.disconnected.load(Ordering::SeqCst));
    }
    #[tokio::test]
    async fn state_record_and_file_transactions_are_contiguous_despite_realtime_notifications() {
        let t = FakeTransport::new();
        let lane = tokio::sync::Mutex::new(fake_session(t.clone()).await);
        let (status, stopped, files) = tokio::join!(
            run_in_lane(json!({"op":"status"}), discard, 1, &lane),
            run_in_lane(
                json!({"op":"setRecording","enabled":false}),
                discard,
                2,
                &lane
            ),
            run_in_lane(json!({"op":"listFiles"}), discard, 3, &lane)
        );
        assert_eq!(status.unwrap()["record"]["isRecording"], false);
        assert_eq!(stopped.unwrap()["isRecording"], false);
        assert_eq!(files.unwrap().as_array().unwrap().len(), 1);
        assert_eq!(
            *t.commands.lock().unwrap(),
            vec![
                "SYNC_TIME",
                "BATTERY",
                "STATE_INFO",
                "RECORD_STATUS",
                "BASE_INFO",
                "RECORD_STOP",
                "RECORD_STATUS",
                "RECORD_STATUS",
                "STATE_INFO",
                "STATE_INFO",
                "FILE_LIST"
            ]
        );
    }
    #[tokio::test]
    async fn record_control_verifies_readback_and_never_accepts_push_as_query_reply() {
        let t = FakeTransport::new();
        let mut session = fake_session(t.clone()).await;
        let started = execute(
            &mut session,
            "setRecording",
            &json!({"enabled":true}),
            discard,
            1,
        )
        .await
        .unwrap();
        assert_eq!(started["isRecording"], true);
        assert_eq!(started["realtimeEnabled"], false);
        t.replies.lock().unwrap().insert(
            "RECORD_STATUS".into(),
            json!({"isRecording":true,"realtimeEnabled":false}),
        );
        let error = execute(
            &mut session,
            "setRecording",
            &json!({"enabled":false}),
            discard,
            2,
        )
        .await
        .unwrap_err();
        assert_eq!(error.code, "verification");
    }
    #[tokio::test]
    async fn file_list_is_busy_while_recording_and_never_sends_file_command() {
        let t = FakeTransport::new();
        t.recording.store(true, Ordering::SeqCst);
        let mut session = fake_session(t.clone()).await;
        assert_eq!(
            execute(&mut session, "listFiles", &json!({}), discard, 1)
                .await
                .unwrap_err()
                .code,
            "busy"
        );
        assert!(!t.commands.lock().unwrap().iter().any(|s| s == "FILE_LIST"));
    }
    #[test]
    fn live_capture_blocks_every_multi_command_wire_transaction() {
        for op in [
            "status",
            "listFiles",
            "setRecording",
            "recordMark",
            "downloadFile",
            "downloadFilePreservingSource",
            "confirmDeleteFile",
            "scanWifi",
        ] {
            assert!(live_blocks(op));
        }
        for op in [
            "disconnect",
            "stopAudioCapture",
            "audioCaptureStatus",
            "convertAudio",
        ] {
            assert!(!live_blocks(op));
        }
    }
    #[tokio::test]
    async fn safe_download_and_uncommitted_delete_require_explicit_arguments() {
        let mut session = Session::default();
        let req = json!({"name":"a.apm","directory":"/tmp","transport":"ble"});
        assert_eq!(
            download_preserving(&mut session, &req, discard, 1)
                .await
                .unwrap_err()
                .code,
            "argument"
        );
        assert_eq!(
            confirm_delete(&mut session, &json!({"downloadId":"1"}))
                .await
                .unwrap_err()
                .code,
            "confirmation"
        );
        assert_eq!(
            confirm_delete(
                &mut session,
                &json!({"downloadId":"1","repositoryCommitted":true})
            )
            .await
            .unwrap_err()
            .code,
            "receipt"
        );
    }
    #[tokio::test]
    async fn confirmed_delete_rehashes_local_file_and_rejects_changed_content() {
        let dir = std::env::temp_dir().join(format!("card-receipt-test-{}", std::process::id()));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let path = dir.join("a.apm");
        tokio::fs::write(&path, [1u8, 2, 3]).await.unwrap();
        let digest = hash_local(&path, 3).await.unwrap();
        let mut session = Session::default();
        session.receipts.insert(
            "receipt".into(),
            DownloadReceipt {
                name: "a.apm".into(),
                device_id: "fake-card".into(),
                transport_id: "fake-transport".into(),
                path: path.clone(),
                bytes: 3,
                sha256: digest.clone(),
                ap: false,
                local_epoch: 0,
                source_epoch: 0,
                generation: None,
                deleted: false,
            },
        );
        tokio::fs::write(&path, [3u8, 2, 1]).await.unwrap();
        let error = confirm_delete(&mut session, &json!({"downloadId":"receipt","repositoryCommitted":true,"expectedDeviceId":"fake-card","sha256":digest})).await.unwrap_err();
        assert_eq!(error.code, "integrity"); // Rejected before accessing a device.
        assert!(session.receipts.contains_key("receipt"));
        assert!(hash_local(&path, 4).await.is_err());
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    #[test]
    fn heap_string_survives_callback_return() {
        let ptr = owned_json(json!({"text":"测试\u{0}late"}));
        // The owner is deliberately not a temporary CString.
        let text = unsafe { CStr::from_ptr(ptr).to_str().unwrap().to_owned() };
        assert_eq!(
            serde_json::from_str::<Value>(&text).unwrap()["text"],
            "测试\u{0}late"
        );
        unsafe {
            card_bridge_free_string(ptr);
            card_bridge_free_string(std::ptr::null_mut());
        }
    }
    #[test]
    fn rejects_unsafe_remote_paths() {
        assert!(validate_remote("../a.apm").is_err());
        assert!(validate_remote("records/a.apm").is_ok());
    }
    #[tokio::test]
    async fn ble_take_requires_consent_before_device_access() {
        extern "C" fn cb(_ticket: usize, ptr: *mut c_char) {
            unsafe {
                card_bridge_free_string(ptr);
            }
        }
        let req = json!({"name":"a.apm","directory":"/tmp","transport":"ble"});
        let error = download(&Session::default(), &req, cb, 1)
            .await
            .unwrap_err();
        assert_eq!(error.code, "destructive"); // No adapter or device accessed.
        assert!(confirmed(&req).is_err());
    }
    #[tokio::test]
    async fn converts_real_pcm_to_wav() {
        let dir = std::env::temp_dir().join(format!("card-bridge-test-{}", std::process::id()));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let src = dir.join("sample.pcm");
        let dst = dir.join("sample.wav");
        tokio::fs::write(&src, [0u8, 0, 1, 0, 255, 255])
            .await
            .unwrap();
        let result = convert(&json!({"source":src,"destination":dst,"format":"pcm"}))
            .await
            .unwrap();
        assert_eq!(result["samples"], 3);
        assert_eq!(&tokio::fs::read(&dst).await.unwrap()[..4], b"RIFF");
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
    #[tokio::test]
    async fn adpcm_decoder_state_is_continuous_across_read_buffers() {
        let dir = std::env::temp_dir().join(format!("card-adpcm-test-{}", std::process::id()));
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let bytes: Vec<u8> = (0..65537).map(|i| (i % 256) as u8).collect();
        let source = dir.join("input.apm");
        let destination = dir.join("output.wav");
        tokio::fs::write(&source, &bytes).await.unwrap();
        convert(&json!({"source":source,"destination":destination,"format":"apm"}))
            .await
            .unwrap();
        let expected =
            reai_card_sdk::wav_bytes(&reai_card_sdk::AdpcmDecoder::new().decode(&bytes), 16000);
        assert_eq!(tokio::fs::read(destination).await.unwrap(), expected);
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }
}
