//! Safe C ABI for reai-card-sdk v0.0.6 (not dyj-v1-sdk).
//! Every callback transfers a Rust heap CString; the receiver MUST free it exactly
//! once, including late/unknown tickets. Callback return does NOT end its lifetime.
//! One lane owns scan, connect, BLE commands, SD/AP transfer and OTA. A timeout
//! invalidates the connection rather than reusing an ambiguous protocol response.
#[cfg(target_os = "android")]
mod android;
mod firmware;
mod live_audio;

use reai_card_sdk::{
    ControlAction, ControlInput, DeviceEvent, DeviceManager, DiscoveredDevice, DyjDevice, SdkError,
};
use serde_json::{json, Value};
use std::{
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
}
struct State {
    runtime: tokio::runtime::Runtime,
    lane: tokio::sync::Mutex<Session>,
    event_callback: Mutex<Option<Callback>>,
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
    state().runtime.spawn(async move {
        let result = match parsed {
            Ok(req) => run(req, cb, ticket).await,
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
    let op = text(&req, "op")?.to_owned();
    let mut session = tokio::time::timeout(Duration::from_secs(15), state().lane.lock())
        .await
        .map_err(|_| Error::new("busy", "设备命令车道忙，请等待当前传输/升级结束"))?;
    if let Some(recovery) = &session.recovery {
        if !recovery.is_finished() {
            return Err(Error::new("busy", "上一次连接超时，正在释放蓝牙连接槽"));
        }
        session.recovery.take();
    }
    let seconds = match op.as_str() {
        "firmwareUpdate" => 600,
        "downloadFile" => 300,
        "convertAudio" => 120,
        _ => 65,
    };
    let result = tokio::time::timeout(
        Duration::from_secs(seconds),
        execute(&mut session, &op, &req, cb, ticket),
    )
    .await;
    let result = result.unwrap_or_else(|_| {
        Err(Error::new(
            "timeout",
            format!("{op} 超时；连接已失效，请重连"),
        ))
    });
    if result
        .as_ref()
        .err()
        .is_some_and(|e| matches!(e.code, "timeout" | "disconnected" | "protocol"))
    {
        cleanup(&mut session).await;
    }
    result
}
pub(crate) async fn cleanup(session: &mut Session) {
    let _ = close_connection(session).await;
}
pub(crate) async fn close_connection(session: &mut Session) -> Result<()> {
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
    tokio::spawn(async move {
        loop {
            let value = match rx.recv().await {
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
    let info = dev.device_info().await?;
    let recording = dev.record_status().await?;
    let wifi = dev.wifi_status().await?;
    Ok(json!({"battery":battery,"state":state,"info":info,"record":recording,"wifi":wifi}))
}

async fn execute(
    session: &mut Session,
    op: &str,
    req: &Value,
    cb: Callback,
    ticket: usize,
) -> Result<Value> {
    if session.live.is_some()
        && matches!(
            op,
            "connect"
                | "downloadFile"
                | "setWifiEnabled"
                | "setRealtimeEnabled"
                | "setRecording"
                | "firmwareUpdate"
        )
    {
        return Err(Error::new(
            "busy",
            "实时音频分片任务占有通道；先显式停止采集，不混用历史take/Wi-Fi/OTA",
        ));
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
            if flag(req, "enabled") {
                d.start_recording().await?;
            } else {
                d.stop_recording().await?;
            }
            serialize(d.record_status().await?)
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
        d.take_file_to_dir(name, directory).await?
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
                "下载长度与文件列表不一致，不可用于转写",
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
