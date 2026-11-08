//! card_bridge —— 把 reai-card-sdk（异步 Rust + btleplug）经最小 C ABI 暴露给 Flutter。
//!
//! 约定：
//! - 所有异步结果经 `Callback` 回调一次 JSON 字符串；Dart 侧用 NativeCallable.listener 接收。
//! - 回调里的 json 指针只在回调返回前有效，Dart 侧必须同步拷贝。
//! - 设备命令严格串行（SDK 规则）：全局仅保存一个已连接设备，状态查询顺序执行。
//!
//! 未实现（接通硬件后逐项补，见 docs/SDK-CAPABILITY.md 登记）：OTA 触发、AP 文件快传、
//! 实时音频流、Wi-Fi 配置下发。

use std::ffi::{c_char, CStr, CString};
use std::sync::OnceLock;
use std::time::Duration;

use reai_card_sdk::{BatteryInfo, DeviceInfo, DeviceManager, DeviceState, DyjDevice, SdkError};

/// Dart 注册的回调：`fn(user_data, json_utf8_ptr)`。
type Callback = extern "C" fn(user_data: *mut core::ffi::c_void, json: *const c_char);

struct BridgeState {
    runtime: tokio::runtime::Runtime,
    device: tokio::sync::Mutex<Option<DyjDevice>>,
}

static STATE: OnceLock<BridgeState> = OnceLock::new();
static VERSION: &str = concat!("card_bridge/", env!("CARGO_PKG_VERSION"), " reai-card-sdk/0.0.6");

fn state() -> &'static BridgeState {
    STATE.get_or_init(|| BridgeState {
        runtime: tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime"),
        device: tokio::sync::Mutex::new(None),
    })
}

fn emit(cb: Callback, user_data: *mut core::ffi::c_void, value: serde_json::Value) {
    let json = CString::new(value.to_string()).expect("no NUL in json");
    cb(user_data, json.as_ptr());
    // json 在回调返回后 drop；Dart 侧须在回调内同步拷贝
}

/// 共享骨架：runtime 上跑异步任务，Ok/Err 转 {"ok":..} 并回调。
fn run_emit<F>(cb: Callback, user_data: *mut core::ffi::c_void, fut: F)
where
    F: std::future::Future<Output = Result<serde_json::Value, SdkError>> + Send + 'static,
{
    let ud_addr = user_data as usize; // 裸指针 !Send，按地址过桥，回调线程还原
    state().runtime.spawn(async move {
        let value: serde_json::Value = match fut.await {
            Ok(v) => serde_json::json!({ "ok": true, "data": v }),
            Err(e) => serde_json::json!({ "ok": false, "error": e.to_string() }),
        };
        emit(cb, ud_addr as *mut core::ffi::c_void, value);
    });
}

// ── FFI surface ────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn card_bridge_version() -> *const c_char {
    static V: OnceLock<CString> = OnceLock::new();
    V.get_or_init(|| CString::new(VERSION).expect("no NUL")).as_ptr()
}

/// 预留：当前所有跨界字符串均为静态或回调内临时拷贝，无需释放。
#[no_mangle]
pub extern "C" fn card_bridge_free_string(_ptr: *mut c_char) {}

/// BLE 扫描 NUS 设备（名称 DYJ 前缀）。timeout_ms 为扫描窗口。
///
/// # Safety
/// `user_data` 由 Dart 侧定义；`cb` 必须是有效的 Dart NativeCallable 入口。
#[no_mangle]
pub unsafe extern "C" fn card_bridge_scan(
    timeout_ms: u32,
    cb: Callback,
    user_data: *mut core::ffi::c_void,
) {
    run_emit(cb, user_data, async move {
        let manager = DeviceManager::new().await?;
        let devices = manager
            .scan(Duration::from_millis(timeout_ms as u64))
            .await?;
        Ok(serde_json::to_value(&devices)?)
    });
}

/// 连接指定设备（scan 返回的 id），成功后回传 battery/state/device_info 快照并存全局句柄。
///
/// # Safety
/// 同 `card_bridge_scan`。
#[no_mangle]
pub unsafe extern "C" fn card_bridge_connect(
    device_id: *const c_char,
    cb: Callback,
    user_data: *mut core::ffi::c_void,
) {
    let id = cstr(device_id);
    run_emit(cb, user_data, async move {
        let manager = DeviceManager::new().await?;
        let devices = manager.scan(Duration::from_secs(3)).await?;
        let found = devices
            .iter()
            .find(|d| d.id == id)
            .ok_or_else(|| SdkError::DeviceNotFound(id.clone()))?;
        let device = manager.connect(found).await?;
        let snapshot = device_snapshot(&device).await?;
        *state().device.lock().await = Some(device);
        Ok(snapshot)
    });
}

/// 已连接设备的 battery/state/device_info 快照（未连接时返回 ok=false）。
///
/// # Safety
/// 同 `card_bridge_scan`。
#[no_mangle]
pub unsafe extern "C" fn card_bridge_status(cb: Callback, user_data: *mut core::ffi::c_void) {
    run_emit(cb, user_data, async {
        let guard = state().device.lock().await;
        match guard.as_ref() {
            Some(device) => device_snapshot(device).await,
            None => Err(SdkError::Disconnected),
        }
    });
}

/// 断开并清空已连接设备。
///
/// # Safety
/// 同 `card_bridge_scan`。
#[no_mangle]
pub unsafe extern "C" fn card_bridge_disconnect(cb: Callback, user_data: *mut core::ffi::c_void) {
    run_emit(cb, user_data, async {
        let device = state().device.lock().await.take();
        if let Some(device) = device.as_ref() {
            device.disconnect().await?;
        }
        Ok(serde_json::json!({ "disconnected": true }))
    });
}

async fn device_snapshot(device: &DyjDevice) -> Result<serde_json::Value, SdkError> {
    // SDK 规则：命令严格串行，顺序查询
    let battery: BatteryInfo = device.battery().await?;
    let state: DeviceState = device.state().await?;
    let info: DeviceInfo = device.device_info().await?;
    Ok(serde_json::json!({
        "battery": battery,
        "state": state,
        "info": info,
    }))
}

/// # Safety
/// 指针须为合法 C 字符串。
unsafe fn cstr(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}
