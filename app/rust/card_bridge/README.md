# card_bridge

reai-card-sdk → Flutter 的 FFI 桥（最小 C ABI）。

## 构建产物

| 目标 | 产物 | 用途 |
| --- | --- | --- |
| `aarch64-apple-ios` | `libcard_bridge.a`（staticlib） | 链入 Runner.app，`DynamicLibrary.process()` 直接命中符号 |
| `aarch64-apple-darwin` | `libcard_bridge.dylib` | macOS 桌面开发（`DynamicLibrary.open` 兜底） |

## iOS 构建

```bash
rustup target add aarch64-apple-ios
rustup run stable-aarch64-apple-darwin cargo build --release --target aarch64-apple-ios
```

产物：`target/aarch64-apple-ios/release/libcard_bridge.a`

链入 Xcode（Runner target）：
1. Build Phases → Link Binary With Libraries → 加入上面的 `.a`
2. Build Settings → Library Search Paths → 加 `$(PROJECT_DIR)/../../rust/card_bridge/target/aarch64-apple-ios/release`
3. Frameworks 依赖：CoreBluetooth、CoreLocation（btleplug）
4. Info.plist：`NSBluetoothAlwaysUsageDescription`（已加）

## Dart 侧

`lib/core/device/card_gateway.dart`：
- `RealCardGateway.maybe()` 非空即桥可用；`DeviceStore` 构造时自动注入。
- 弹层打开 → `refreshFromDevice()` → 真实 battery/state 刷 UI；桥不可用回退预置值。

## 约定

- 回调 JSON 指针仅在回调返回前有效，Dart 侧同步 `jsonDecode`。
- SDK 命令严格串行；全局仅保存一个已连接设备。
- OTA / AP 快传 / 实时音频流 / mark：桥尚未封装，接通硬件后逐项补（不编造接口）。
