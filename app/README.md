# 录音卡 · Flutter 客户端

配合硬件录音卡使用的手机 App：BLE 连接设备、同步录音、转写、生成总结与导出。界面中文，手机竖屏为主，≥720px 宽屏切双栏。

## 快速开始

```bash
cd app
flutter pub get
flutter run                      # 默认连已启动的模拟器/真机
flutter analyze && flutter test  # 提交前必过
```

- 设计真源是仓库根目录的 `prototype/index.html`（只读），她的 55 个 `verify.cjs` check 在 `test/` 里逐项对应；
- 正式版走真实链路：`card_bridge`（BLE）+ 后端模型网关（ASR / 总结）+ 真实 OAuth；未配置/未连接时显式失败，不回退预置假数据；
- OAuth 端点与客户端标识走 `--dart-define`（见 `lib/core/config/remote/`）。

## 目录结构

```
lib/
├── core/
│   ├── config/      端点、鉴权模式、隐私政策文案（privacy_text.dart）
│   ├── device/      录音卡网关（Rust 桥 / 模拟实现）
│   ├── models/      记录、总结的数据模型
│   ├── platform/    应用级能力：crash_guard.dart（错误兜底）、app_info.dart（版本号）
│   ├── storage/     KeyValueStore 抽象（PrefsStore / InMemoryStore）、安全存储
│   ├── store/       AppStore / DeviceStore（ChangeNotifier）
│   └── theme/       tokens.dart：色板与尺寸，唯一视觉真源
├── data/            预置示例数据
├── pages/           页面（timeline / detail / summary_result / setting / privacy …）
├── services/        鉴权、网络、导出
└── widgets/         复用组件
```

## 发布相关

- 上架流程、签名、图标重新生成、检查清单：**`docs/RELEASE.md`**；
- 隐私政策完整条款：**`docs/PRIVACY.md`**（App 内展示的是 `lib/core/config/privacy_text.dart` 的精要版，两处需同步）；
- 图标唯一设计真源：`assets/icon/app_icon.svg`，改完执行 `bash assets/icon/render_icons.sh` 重生成两端全套。

两端身份信息：bundle id / applicationId `com.reai.recordingcard`，显示名「录音卡」，版本 `1.0.0 (1)`。

## 平台配置要点

- **iOS**：`Info.plist` 已声明蓝牙、本地网络用途文案；`ITSAppUsesNonExemptEncryption=false`；AppIcon 无 alpha 通道；`LaunchScreen.storyboard` 为米白底 + 应用名。Rust 静态库由 Xcode 的 **Build Rust Bridge** 阶段调用 `rust/build-ios.sh` 编译（仅真机）。
- **Android**：权限按系统版本分层声明（蓝牙 12+ 用 `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT`，老系统回退定位权限；Wi-Fi 用 `NEARBY_WIFI_DEVICES`）。release 签名读 `android/key.properties`（模板 `android/key.properties.example`），缺失时回退 debug 签名并告警；release 开启 R8 压缩，规则在 `android/app/proguard-rules.pro`。

## 已知边界

- 硬件/ASR/云端为真实链路；桥不可用（模拟器）或未配置网关时显式提示，不伪造数据；
- 声纹/说话人分离：ASR 不返回，界面按「未区分」呈现，不编造身份；
- 增量分段润色 / 长静音阶段总结模块已完成代码+单测（见 `docs/INCREMENTAL-ANALYSIS.md`），待本地 ASR/音频切片接入后串联；
- 固件 OTA 接口、Wi-Fi 是否仅 2.4GHz 等待定项登记在 `docs/SDK-CAPABILITY.md`；
- 待人工确认的发布项（Bonjour 服务类型、局域网 http 配网、云端删除实现等）见 `docs/RELEASE.md` 第 5 节。
