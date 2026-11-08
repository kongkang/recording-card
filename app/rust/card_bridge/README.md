# card_bridge

录音卡 SDK → Flutter 的 C ABI 桥。SDK 锁定 git tag v0.0.6；目标为 staticlib/cdylib/rlib。当前生产入口使用 `RealCardGateway.maybe()` 或明确不可用网关，不回退预置设备值。

## 构建和平台

Linux 本轮验证命令（不扫描、不连接硬件）：

```bash
export PATH=/home/ubuntu/flutter/bin:$HOME/.cargo/bin:$PATH
cd app/rust/card_bridge
cargo check --locked --offline
cargo test --locked --offline
cargo build --locked --offline
```

iOS 在获授权 Mac/Xcode 执行 `scripts/build_ios.sh`，Runner 的 Card Rust Bridge phase 按当前 SDK/架构生成 `build/ios/<platform>/libcard_bridge.a`。`app/ios/Flutter/CardBridge.xcconfig` force-load 当前 archive，并保留四个 C symbols。依赖 CoreBluetooth/CoreLocation/Foundation/Security 和系统链接库；Podfile 目标 iOS 15，Sherpa iOS native 依赖由 Flutter/CocoaPods 解析。**Linux 单测不证明 iOS archive、Pods、链接、签名或真机通过。**

Android 的 `scripts/build_android.sh` 与 `scripts/prepare_android_java.sh` 配合 Gradle/JNI；Android SDK/NDK 和设备构建尚未在本轮验证。权限与 JNI 初始化已在 Android 平台入口实现。

Mac 受控构建总入口：仓库根 `scripts/run_ios_device.sh --check|--build|--run`，完整操作边界见 `docs/DEVICE-TEST-HANDOFF.md`。

## 真实 API 与所有权

C symbols：`card_bridge_request`、`card_bridge_free_string`、`card_bridge_set_event_callback`、`card_bridge_version`。请求 UTF-8 在 native request 中同步复制。native 结果以 `CString.into_raw()` 转移到 Dart，**回调返回后仍有效**；Dart 在 decode 的 finally 中调用 free，Rust `CString.from_raw()` 释放一次。超时/迟到/未知 ticket 同样释放。NativeCallable listener 为 process lifetime；不能因 App dispose 直接 close listener 造成迟到回调 UAF。

SDK 命令通过单一连接/串行 mutex 车道执行并有超时/清理。已封装 scan/connect/status/files、AP 下载、Wi-Fi、recordMark/controlBindings、实时 PCM 分片、音频转换及精确 main/wifi 固件操作。Dart 完整签名在 `lib/core/device/card_gateway.dart`。

下载默认 AP 且 `allowDestructive=false`。BLE take 可删源，未单独精确授权时 Dart/Rust 均拒绝；生产下载适配器永不使用 take。AP 与实时传输/设备录音 SD 所有权冲突时拒绝，不能暗停用户已有录音。断开/退出停止 App 实时传输并恢复 priorRealtime，不停其他 owner 的 SD 录音。

实时 task ID 仅 ASCII 字母数字、`-`、`_`，最多80字节。native 完成 WAV 和 audioChunk JSON sidecar 留在 App 私有 capture 目录；`.part` 不视为完整录音。Dart 启动恢复 sidecar，持久化原始 ASR、窗口/阶段快照和失败任务；`discontinuous` 表示缺口后首片，`interrupted` 表示缺口前末片。缺口后的 epoch 不能回到旧会话窗口。BLE 断流和空 ASR **不是静音**；只有经校验 Silero VAD 的证据可触发 long_silence。

## 安全测试层

设置绝对动态库路径后，可运行真实跨 FFI suite（内存回调、未连接状态、PCM→WAV，无硬件操作）：

```bash
cd app
CARD_BRIDGE_TEST_LIBRARY="$PWD/rust/card_bridge/target/debug/libcard_bridge.so" \
  flutter test --no-pub test/device/card_gateway_test.dart --reporter expanded
```

真实 OAuth、模型调用、BLE/Wi-Fi、ASR 权重推理和 OTA 均需另外提供配置/授权和逐项验收，不以测试 spy 或参考 SDK 成熟度冒充真实链路。
