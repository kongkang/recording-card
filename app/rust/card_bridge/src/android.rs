//! Initialize btleplug's Java class cache on the UI thread before Tokio.
//! Latch failures: upstream JVM setup is partially one-shot; blindly retrying a
//! failed class-cache initialization could incorrectly report readiness.
use jni::{JNIEnv, objects::JClass, sys::jstring};
use std::sync::OnceLock;
static INITIALIZED: OnceLock<bool> = OnceLock::new();

#[no_mangle]
pub extern "system" fn Java_dev_kongkang_recording_1card_CardNative_initialize(env: JNIEnv, _class: JClass) -> jstring {
    let ready=*INITIALIZED.get_or_init(|| matches!(
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| btleplug::platform::init(&env))),
        Ok(Ok(()))
    ));
    if ready { return std::ptr::null_mut(); }
    let _=env.exception_clear();
    env.new_string("蓝牙JNI初始化失败；检查Java类与权限并重启应用，不能访问未初始化适配器")
        .map(|s|s.into_inner()).unwrap_or(std::ptr::null_mut())
}
