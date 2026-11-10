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
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use serde_json::{json, Value};

/// Dart 注册的回调：`fn(user_data, json_utf8_ptr)`。
type Callback = extern "C" fn(user_data: *mut c_void, json: *const c_char);

struct BridgeState {
    runtime: tokio::runtime::Runtime,
    device: tokio::sync::Mutex<Option<DyjDevice>>,
    /// 扫描/连接共用一个 DeviceManager。
    ///
    /// 以前每条命令都 `DeviceManager::new()`：每次都会新建一套平台蓝牙栈
    /// （iOS 上是 CBCentralManager）。旧管理器在 connect 返回后就被丢弃，
    /// 而它名下的连接并不会随之释放——再连一次就会出现两条链路，
    /// 断连只能断掉其中一条，设备端因此保持"已连接、不广播"。
    manager: tokio::sync::OnceCell<DeviceManager>,
    /// 设备事件泵：断连/重连时必须先停，否则它持有的句柄会把旧链路留在原地。
    event_pump: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// 最近一次 connect 的设备 id：断开时用于日志与诊断（设备地址不是敏感数据）。
    last_device_id: std::sync::Mutex<Option<String>>,
    /// 实时音频流的停止信号：每次开始的录音会话一个。
    realtime_stop: std::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    /// 设备事件订阅通道上最近一次事件的 JSON（Dart 侧按 seq 增量取走）。
    ///
    /// 设备是**主动推送**的：拨杆/按键触发的录音状态变化会自己发上来，
    /// 不该靠 App 轮询去问——那是延迟的根源。
    events: std::sync::Mutex<EventFeed>,
}

/// 事件队列：单调递增 seq + 最近 N 条，Dart 侧用 seq 做增量读。
struct EventFeed {
    seq: u64,
    items: std::collections::VecDeque<Value>,
}

impl EventFeed {
    fn new() -> Self {
        Self { seq: 0, items: std::collections::VecDeque::new() }
    }

    fn push(&mut self, value: Value) {
        self.seq += 1;
        self.items.push_back(json!({"seq": self.seq, "event": value}));
        // 只留最近 64 条：Dart 一秒拉一次，足够；防止长时间不读把内存撑大
        while self.items.len() > 64 {
            self.items.pop_front();
        }
    }

    fn since(&self, after: u64) -> Value {
        let items: Vec<Value> = self
            .items
            .iter()
            .filter(|item| {
                item.get("seq").and_then(Value::as_u64).map(|s| s > after).unwrap_or(false)
            })
            .cloned()
            .collect();
        json!({"seq": self.seq, "events": items})
    }
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
        manager: tokio::sync::OnceCell::new(),
        event_pump: tokio::sync::Mutex::new(None),
        last_device_id: std::sync::Mutex::new(None),
        realtime_stop: std::sync::Mutex::new(None),
        events: std::sync::Mutex::new(EventFeed::new()),
    })
}

fn emit_raw(cb: Callback, user_data: usize, value: Value) {
    let json = CString::new(value.to_string()).expect("no NUL in json");
    // into_raw：所有权交给 Dart，由它拷贝后 free_string。
    cb(user_data as *mut c_void, json.into_raw());
}

/// 需要附带诊断信息的失败：消息给人看，detail 给排障看。
struct BridgeError {
    message: String,
    detail: Option<Value>,
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

    /// 失败并附带设备侧诊断信息（排障用：只给错误码不足以定位）。
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
            let manager = manager().await?;
            let devices = manager.scan(Duration::from_millis(timeout)).await?;
            out.ok(serde_json::to_value(&devices).map_err(to_sdk)?);
        }
        "connect" => out.ok(connect(payload).await?),
        // 断开必须如实回包：调用方（Dart）据此判断链路是否真的释放了。
        // 以前无论有没有设备、SDK 断没断成功都回 `{"disconnected":true}`，
        // 界面显示已断开、设备端却仍保持连接，排障时完全看不到真相。
        "disconnect" => out.ok(release_device().await),
        "snapshot" => {
            // 不长期占住 device 锁：快照内部要连发 5 条命令，最长可达 50s；
            // 期间用户点断开会被堵在锁外面。命令串行由 SDK 自己的 command_gate 保证。
            out.ok(with_device(|d| async move { snapshot(&d).await }).await?);
        }
        "record" => {
            let action = payload.get("action").and_then(Value::as_str).unwrap_or("toggle");
            // 失败时把命令名、动作与设备原始回包一起抛出去：
            // 只回一句 "code -2" 无法判断是存储没挂载、还在传输、还是别的原因。
            let device = {
                let guard = state().device.lock().await;
                guard.as_ref().ok_or(SdkError::Disconnected)?.clone()
            };
            let outcome = {
                let d = device;
                let d = d.clone();
                let action = action.to_owned();
                async move {
                let result = match action.as_str() {
                    "start" => d.start_recording().await.and_then(|r| to_value(r)),
                    "stop" => d.stop_recording().await.and_then(|r| to_value(r)),
                    _ => d.toggle_recording().await.and_then(|r| to_value(r)),
                };
                if let Err(error) = &result {
                    // 再查一次设备状态，带着当时的上下文（是否在录、实时流开没开）一起报
                    let probe = d.record_status().await.ok();
                    let state = d.state().await.ok();
                    eprintln!(
                        "[card_bridge] record 失败 action={action} error={error} record_status={probe:?} state={state:?}"
                    );
                    let detail = json!({
                        "command": "RECORD",
                        "action": action,
                        "record": probe.map(|r| serde_json::to_value(r).unwrap_or(Value::Null)),
                        "state": state.map(|s| serde_json::to_value(s).unwrap_or(Value::Null)),
                    });
                    return Err(BridgeError {
                        message: error.to_string(),
                        detail: Some(detail),
                    });
                }
                result.map_err(|error| BridgeError {
                    message: error.to_string(),
                    detail: None,
                })
                }
            }
            .await;
            match outcome {
                Ok(value) => out.ok(value),
                Err(error) => out.fail_detail(error.message, error.detail),
            }
        }
        // 明确的开始/停止：不走 SDK 的 start_recording（它内部 state() 解析在本机固件
        // 上会因缺 bootType 而整体失败），直接发 RECORD_START / RECORD_STOP。
        "record.start" => {
            out.ok(with_device(|d| async move {
                d.raw_command("RECORD_START", None).await
            })
            .await?);
        }
        "record.stop" => {
            out.ok(with_device(|d| async move {
                d.raw_command("RECORD_STOP", None).await
            })
            .await?);
        }
        "mark" => {
            out.ok(with_device(|d| async move {
                d.record_mark().await.and_then(|r| to_value(r))
            })
            .await?);
        }
        // 打开实时音频流（PCM 16k 单声道 i16，走 progress 回调逐块下发。
        // 只开流不改录音状态：录音开关仍由 `record` 控制，两条命令互不干扰。
        // 拉取设备主动推送的事件（录音状态/按键/开关/充电/电源…）。
        // 这里**不访问设备**，只读本地队列，所以可以高频调用而不打扰蓝牙链路。
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

/// 常驻监听设备事件：设备（拨杆/按键/固件）主动推上来的状态变化进本地队列，
/// 由 Dart 顺带取走。**这是"硬件侧操作能立刻反映到手机"的关键**——
/// 靠轮询至少要等一个周期，靠推送是毫秒级。
///
/// 任务里**只持有事件接收端，不持有设备句柄**：以前把 `DyjDevice` clone 进任务，
/// 它会一直给 Core 续命（自引用式的持有），断连后旧链路因此留在设备端不释放。
/// 只拿 receiver 时，设备句柄一丢，发送端随之关闭，任务自己就结束了。
fn spawn_event_pump(device: &DyjDevice) -> tokio::task::JoinHandle<()> {
    let mut events = device.subscribe_events();
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(event) => {
                    let value = match event {
                        DeviceEvent::RecordStatus(status) => serde_json::to_value(&status)
                            .map(|v| json!({"kind": "record", "status": v}))
                            .unwrap_or(Value::Null),
                        DeviceEvent::ToggleSwitch(_) => json!({"kind": "toggle_switch"}),
                        DeviceEvent::Button(_) => json!({"kind": "button"}),
                        DeviceEvent::Power(power) => serde_json::to_value(&power)
                            .map(|v| json!({"kind": "power", "power": v}))
                            .unwrap_or(Value::Null),
                        DeviceEvent::Sync(sync) => serde_json::to_value(&sync)
                            .map(|v| json!({"kind": "sync", "sync": v}))
                            .unwrap_or(Value::Null),
                        DeviceEvent::UploadComplete(_) => json!({"kind": "upload_complete"}),
                        _ => continue,
                    };
                    if value.is_null() {
                        continue;
                    }
                    let mut feed = state().events.lock().expect("events lock");
                    feed.push(value);
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break, // 链路已断：连接重建时会重新起泵
            }
        }
    })
}

// ── 实时音频流 ──────────────────────────────────────────────

/// 打开实时音频流：发 `RECORD_REALTIME_ENABLE(true)`，再把解码后的 PCM 逐块下发。
///
/// 设计要点：
/// - **不在这里改录音状态**：录音仍由 `record` 命令控制，本命令只负责"边录边收"，
///   所以不能在实时流里调用 `start_realtime_recording`（那会连带开始录音）。
/// - 每块 PCM 作为一条 progress 回调（`final:false`）送出去，Dart 侧拼 WAV 落盘；
///   同一会话的最终回调带 `final:true`。
/// - ADPCM 解码状态跨整段录音连续，**必须**在 SDK 的通知 worker 里解码 ——
///   这里只消费已经解码好的 `PcmChunk`，不做任何二次拼接或重新解码。
async fn realtime_open(out: Emitter) -> Result<(), SdkError> {
    let device = {
        let guard = state().device.lock().await;
        guard.as_ref().ok_or(SdkError::Disconnected)?.clone()
    };
    device.set_realtime_enabled(true).await?;

    let mut audio = device.subscribe_audio();
    let (stop_tx, mut stop_rx) = tokio::sync::oneshot::channel::<()>();
    {
        let mut slot = state().realtime_stop.lock().expect("realtime lock");
        if let Some(previous) = slot.take() {
            let _ = previous.send(());
        }
        *slot = Some(stop_tx);
    }

    out.progress(json!({"state": "open"}));

    tokio::spawn(async move {
        let mut blocks: u64 = 0;
        let mut samples: u64 = 0;
        let mut gaps: u64 = 0;
        loop {
            tokio::select! {
                _ = &mut stop_rx => break,
                received = audio.recv() => match received {
                    Ok(chunk) => {
                        if chunk.discontinuous {
                            gaps += 1;
                            // 断开要如实告诉上层：这是"这一段可能不完整"的证据链
                            out.progress(json!({
                                "state": "gap",
                                "gapIndex": gaps,
                                "receivedSamples": samples,
                            }));
                        }
                        // PCM 以紧凑字节数组下发，避免逐样本 JSON 撑爆回调
                        let mut bytes = Vec::with_capacity(chunk.samples.len() * 2);
                        for sample in &chunk.samples {
                            let raw = i16::from_le_bytes(sample.to_le_bytes());
                            bytes.extend_from_slice(&raw.to_le_bytes());
                        }
                        blocks += 1;
                        samples += chunk.samples.len() as u64;
                        out.progress(json!({
                            "state": "audio",
                            "sampleRate": chunk.sample_rate,
                            "channels": chunk.channels,
                            "samples": chunk.samples.len(),
                            "receivedSamples": samples,
                            "bytes": bytes.len(),
                            // base64 稳定、无转义开销，Dart 侧一次解码即可
                            "pcm": BASE64.encode(bytes),
                        }));
                    }
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
        // 收尾：关闭实时开关（不碰录音状态，录音由 `record` 管）
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


/// 全局唯一的蓝牙管理器：扫描与连接共用同一个平台栈。
///
/// 进程内只建一次。每次 connect 都新建 manager 会让旧连接失去可管理的句柄，
/// 断连时只能断掉最新那条，旧链路留在设备端（真机表现：App 说已断开，
/// 电脑侧却扫不到设备，杀掉 App 约 6 秒后才重新广播）。
async fn manager() -> Result<&'static DeviceManager, SdkError> {
    state().manager.get_or_try_init(DeviceManager::new).await
}

/// 释放当前链路：停事件泵 → 停实时流 → 断开并如实报告结果。
///
/// 返回给 Dart 的字段：
/// - `hadDevice`：桥里是否还有设备句柄（false = 本来就没连）
/// - `sdk`：SDK 断连调用的结果（ok / error:… / timeout）
/// - `released`：本次是否确认释放（没句柄也算已释放，因为已无别的持有者）
async fn release_device() -> Value {
    // 1) 事件泵先停：它曾经持有设备句柄，会让"已经断开"的链路在设备端继续存在
    let pump = state().event_pump.lock().await.take();
    if let Some(pump) = pump {
        pump.abort();
    }
    // 2) 实时流收尾：不先关，任务里的设备句柄会拦住释放
    let stop = state().realtime_stop.lock().expect("realtime lock").take();
    if let Some(stop) = stop {
        let _ = stop.send(());
    }
    // 3) 取走设备与 id
    let device = state().device.lock().await.take();
    let device_id = state().last_device_id.lock().expect("device id lock").take();
    let had_device = device.is_some();
    let sdk = match device.as_ref() {
        // SDK 内部先 `is_connected()` 再调平台断连；给硬超时，避免平台回调丢失时永远挂住。
        Some(device) => match tokio::time::timeout(Duration::from_secs(8), device.disconnect()).await {
            Ok(Ok(())) => json!("ok"),
            Ok(Err(error)) => json!(format!("error: {error}")),
            Err(_) => json!("timeout"),
        },
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

async fn connect(payload: Value) -> Result<Value, SdkError> {
    let id = str_field(&payload, "id");
    // 重连前先把旧链路彻底释放。否则旧句柄留在事件泵/实时流任务里，
    // 新连接会与旧连接并存（同一台设备两条 BLE 链路），断开只能断掉新的那条。
    release_device().await;
    let manager = manager().await?;
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
    let snap = match snapshot(&device).await {
        Ok(snap) => snap,
        Err(error) => {
            // 连上了但快照失败：必须主动断开，否则这个句柄一丢，
            // 设备端就停在"已连接、不广播"的状态里。
            let _ = device.disconnect().await;
            return Err(error);
        }
    };
    let pump = spawn_event_pump(&device);
    *state().event_pump.lock().await = Some(pump);
    *state().last_device_id.lock().expect("device id lock") = Some(id);
    *state().device.lock().await = Some(device);
    Ok(snap)
}

async fn snapshot(device: &DyjDevice) -> Result<Value, SdkError> {
    // SDK 规则：命令严格串行，顺序查询；storage 可能不支持，失败不致命。
    // 本机固件回的字段比 SDK 严格结构少（缺 bootType / levelText），
    // 用严格解析会让整个快照失败、界面永远拿不到状态。这里降级为原始回包。
    let battery = match device.battery().await {
        Ok(v) => serde_json::to_value(v).unwrap_or(Value::Null),
        Err(_) => device.raw_command("BATTERY", None).await.unwrap_or(Value::Null),
    };
    let state = match device.state().await {
        Ok(v) => serde_json::to_value(v).unwrap_or(Value::Null),
        Err(_) => device.raw_command("STATE_INFO", None).await.unwrap_or(Value::Null),
    };
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
    // 事件泵先停：它订阅的是即将失效的那条链路，留着也会自动结束，但先停更干净。
    if let Some(pump) = state().event_pump.lock().await.take() {
        pump.abort();
    }
    state().last_device_id.lock().expect("device id lock").take();
    let device = state().device.lock().await.take();
    let Some(device) = device else {
        out.fail(SdkError::Disconnected);
        return Ok(());
    };

    let manager = match manager().await {
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

// ── Android：JNI 初始化 ──────────────────────────────────────
//
// btleplug 在 Android 上的后端（droidplug）不走 CoreBluetooth，而是通过 JNI 调
// Android 的 BluetoothAdapter。所以必须在 JavaVM 可用时调一次
// `btleplug::platform::init(&env)`，否则首次 scan 会 panic
// 「Droidplug has not been initialized」。
//
// Flutter 加载 .so 时会调用 JNI_OnLoad，这是最早能拿到 JavaVM 的时机；
// 在这里初始化，之后 Dart 侧的扫描/连接都直接可用。
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn JNI_OnLoad(
    vm: *mut jni::sys::JavaVM,
    _reserved: *mut core::ffi::c_void,
) -> jni::sys::jint {
    // 初始化期间不能抛 Java 异常，任何失败都只记录并返回既有版本号，
    // 让 App 仍能启动（蓝牙功能会在首次使用时给出明确错误）。
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
