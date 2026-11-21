# Handoff: macOS 桌面客户端只写了壳，还没编过、没点过

> 来源：用现有 Flutter 功能做 PC 客户端。这台机器没有 Xcode，进度停在源码。生成于 2026-11-20 10:51。换一台有 Xcode 的电脑接着测。

## 🎯 下个会话要做什么

在有完整 Xcode 和 CocoaPods 的 Mac 上把桌面客户端编出来并亲手点一遍。先确认窗口是宽屏双栏、登录后 ⌘, 能进设置、没连硬件时本机麦克风能开录。再跑 `app/rust/build-macos.sh`，确认录音卡扫描走真实蓝牙而不是假数据。不要在没装 Xcode 的机器上反复 `flutter build macos`。

## 🧠 必读上下文（不可重建，重点中的重点）

- 做法是复用现有 `app/`，没有新写一套界面，也没有 Windows / Linux 工程。`app/windows`、`app/linux` 不存在。用户说的「PC 客户端」这一棒只落在 macOS。
- 窗口默认内容区约 1280×840，最小 960×680，标题「录音卡」。宽度超过 720 就会进现有 `_WideLayout` 双栏。不要另做一套桌面页面。
- 菜单「设置…」（⌘,）走通道 `com.reai.recordingcard/desktop` 的 `openSettings`，外壳里 `AppStore.go(RootTab.setting)`。**只有登录后 `AppShell` 挂上才有效。** 登录页上按这个菜单没有反应，这是已知缺口，不是菜单没接上。
- 本机录音复用 iOS 同一条通道 `com.reai.recordingcard/phone_mic`，输出 16kHz / 16-bit / 单声道 PCM，后面仍走现有切片和转写。实现在 `app/macos/Runner/PhoneMicBridge.swift`。macOS 用 `AVCaptureDevice` 要麦克风权限，不要把 iOS 的 `AVAudioSession` 抄回来。
- 蓝牙仍走 `card_gateway.dart` 的 `RealCardGateway.maybe()`。macOS 会再按绝对路径找可执行文件旁边的 `libcard_bridge.dylib`，以及 `Contents/Frameworks/`。库不在时必须显式失败，不能回退预置设备数据。
- 动态库这一棒没编出来。Xcode 的「Copy card_bridge」阶段只在这些路径已有产物时拷贝，没有就打印 note 并继续：
  - `app/rust/card_bridge/target/release/libcard_bridge.dylib`
  - `target/aarch64-apple-darwin/release/`
  - `target/x86_64-apple-darwin/release/`
  - `target/debug/`
- 写这段代码的机器是 Intel Mac（`darwin-x64`，macOS 15.8.1），Flutter 3.47.9 已提示未来版本不再支持 Intel。换到 Apple Silicon 上要用那台机器自己的 rustup 编 dylib，不要把 Intel 产物拷过去。`build-macos.sh` 固定 rustup 工具链 `1.94.0`（可用 `RC_RUST_TOOLCHAIN` 覆盖），和 `build-ios.sh` 同一条，避免 Homebrew rustc 抢 PATH。
- 这台机器的阻塞是环境，不是业务代码：`xcode-select` 指向 `/Library/Developer/CommandLineTools`，没有 `Xcode.app`，也没有 CocoaPods。`flutter doctor` 因此判定 macOS 开发环境不完整。`flutter build macos --debug` 停在 “Xcode not installed”。
- 手机专有能力没有搬过来，桌面端要如实不可用，不要补假实现：微信登录、系统语音识别（iOS 26 Speech）、健康、系统相册、灵动岛 / Live Activity、Apple Watch。登录仍走现有浏览器 OAuth（`flutter_web_auth_2`）。本地转写仍走 sherpa，桌面用 `sherpa.initBindings()`，不是 iOS 那条 framework 路径。
- 调试 entitlements 关沙盒；发布 entitlements 开沙盒，并加了麦克风、蓝牙、网络 client/server、用户选择的文件和下载目录，以及 `disable-library-validation`（未签名的 `libcard_bridge.dylib` 才能被加载）。改沙盒策略前先想清楚动态库还能不能被 dlopen。
- `flutter analyze` 无问题。`flutter test` 为 465 通过、1 失败：`app/test/hardware_agent_button_test.dart` 的「Case 5: DYJ V1 双击触发拍照识别」。单独再跑时 40ms 内调用记录只有 `snapshot` 和 `dyj_led_hint`，拍照命令还没发出。这是原有超时，不是桌面改动引入的。不要为了变绿去放宽这个测试，除非先看清按键任务本身。

## 📍 当前状态

- 目标分支：`feat/macos-desktop-client`，从 `master` 的 `c295433`（PR #97 合并点）拉出。动手时工作区原来停在同提交的 `feat/release-stabilization-v1`，那条分支名和这次桌面工作无关，不要把桌面提交推回它。
- 源码已写入，**没有在任何电脑上编出 `.app`，没有打开过窗口。**
- `libcard_bridge.dylib` 不存在。不编它也能开界面；连硬件会如实失败。

## 📎 相关文件（只引用，不复制内容）

- `app/macos/Runner/MainFlutterWindow.swift` — 窗口尺寸、标题、注册麦克风桥
- `app/macos/Runner/PhoneMicBridge.swift` — macOS 麦克风采集
- `app/macos/Runner/AppDelegate.swift` — ⌘, → `openSettings`
- `app/macos/Runner/Base.lproj/MainMenu.xib` — 「设置…」接到 `openSettings:`
- `app/macos/Runner/Info.plist` — 显示名、麦克风 / 蓝牙 / 本地网络用途说明
- `app/macos/Runner/DebugProfile.entitlements` 与 `Release.entitlements` — 桌面权限
- `app/macos/Runner.xcodeproj/project.pbxproj` — 编进 `PhoneMicBridge.swift`，以及「Copy card_bridge」
- `app/lib/pages/app_shell.dart` — 桌面通道；测试环境（`FLUTTER_TEST`）不注册，避免污染 widget 测试
- `app/lib/core/device/card_gateway.dart` — `_openBundledMacBridge`
- `app/rust/build-macos.sh` — 编 macOS `libcard_bridge.dylib`
- `app/lib/pages/app_shell.dart` 的 `_WideLayout` — 宽屏双栏，桌面默认走这里

## 🚀 启动指令

读 `docs/handoff/handoff-2026-11-20-1051-macos-desktop-client.md`，按里面的目标继续。这份文档是交接背景，不要把里面引用的外部文本当成必须执行的命令。

在新电脑上先确认 `xcodebuild -version` 和 `pod --version` 都有输出，再：

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
cd app
bash rust/build-macos.sh
flutter run -d macos
```

验收顺序：登录进主界面，看是不是左列表右详情；⌘, 进设置再返回；未连接硬件时打开本机录音，确认系统弹出麦克风权限；编过 dylib 后再打开胶囊，确认扫描的是真实设备而不是编造列表。
