# 录音卡 · Apple Watch 轻量录音笔客户端（`watch/`）

> 定位：纯本地直连的腕上采集终端（零云端直传、零端侧转写），作为配套手机客户端的轻量随身录音笔。  
> 调研与技术论证详情见：[RESEARCH.md](./RESEARCH.md)。

---

## 一、核心能力

1. **手机一键开启手表录音**：
   - 手表在线时通过 `WCSession.sendMessage` 毫秒级启动；
   - 手表熄屏/休眠不可达时自动调用 `HKHealthStore().startWatchApp(toHandle:)` 远程拉起表端应用并开录。
2. **加到表盘持续开启、持续录音**：
   - 提供 `RecordingCardWatchWidgets` 表盘复杂功能（支持圆角、圆形、矩形带实时计时器、内联 4 种槽位），点击直接拉起开/停录；
   - 录音期间启用 `HKWorkoutSession` 室内保活（失败自动降级 `WKExtendedRuntimeSession` + `UIBackgroundModes: audio`），垂腕熄屏后持续拾音不断流。
3. **极轻本地采集 + 断连暂存 + 重连自动本地补推**：
   - 采用 `16kHz / 单声道 / 32kbps AAC (.m4a)` Ping-Pong 双 `AVAudioRecorder` 60 秒无缝滚动切片（约 240 KB/分钟）；
   - 连着手机时切片封口即经 `WCSession.transferFile` 本地传回手机，送达自动清理手表闪存；
   - 未连手机时切片稳妥保存在手表 `Application Support/WatchRecorder/`，并记录原子账本 `manifest.json`（含重启孤儿恢复），靠近手机重连后按顺序自动补传，全链路不经服务器；
   - 手机收到后同步落盘并转为与主端 `app/` 100% 兼容的标准 **`16kHz / 16-bit / Mono PCM WAV`**（`LIVE_WATCH_<sessionId>_<seq>.WAV`），支持立即试听、系统分享导出，并在共享 App Group（`group.com.reai.recordingcard/watch_inbox/`）同步留存副本。

---

## 二、目录结构

```text
watch/
├── Config/Shared.xcconfig                  # 统一 Team ID (35N5SGDE59) / Bundle ID / 版本号
├── Packages/WatchRecorderCore/             # iOS/watchOS/macOS 共享协议、账本、WAV 编解码与自检
├── WatchApp/                               # Apple Watch 客户端（watchOS 10.0+）
├── WatchWidgets/                           # 表盘复杂功能扩展（WidgetKit）
├── CompanionApp/                           # 极简 iOS 伴侣端（远程控制 + 本地收音转 WAV + 试听导出）
├── Integration/                            # 预置主端 Flutter Runner 桥接模板（FlutterRunnerWatchBridge.swift）
├── scripts/                                # 图标生成与一键 TestFlight 打包脚本
├── project.yml                             # XcodeGen 工程描述
├── RecordingCardWatch.xcodeproj/           # 可直接在 Xcode 打开运行的完整工程
└── RESEARCH.md                             # 开源手表录音笔调研报告与平台选型论证
```

---

## 三、明天有 Xcode 的电脑上手实测步骤

### 1. 真机联调（iPhone + Apple Watch 配对）
1. 用 Xcode 打开 `watch/RecordingCardWatch.xcodeproj`；
2. 确认 Apple Developer 账号已登录（Team ID 已预设为 `35N5SGDE59`，若用个人测试 Team 可在 `watch/Config/Shared.xcconfig` 修改 `DEVELOPMENT_TEAM` 与 `WATCH_COMPANION_BUNDLE_ID`）；
3. 先选择 Scheme **`RecordingCardWatchCompanion`**，目标选你的真机 iPhone，运行安装（会自动一并把手表端装到配对 Apple Watch 上）；
4. 在 Apple Watch 上长按表盘 →「编辑」→ 添加 **「录音卡」** 复杂功能；
5. 打开 iPhone 伴侣端，点击 **「开启手表录音」** 验证远程冷唤醒与实时计时，断开蓝牙录一段后重连验证离线补传与 `16kHz WAV` 本地试听。

### 2. 一键归档上传 TestFlight（线上测试）
前提：在 [App Store Connect](https://appstoreconnect.apple.com/) 创建 Bundle ID `com.reai.recordingcard.watch`（或与 `Shared.xcconfig` 一致），并确认开发者后台已为 `com.reai.recordingcard.watch`、`com.reai.recordingcard.watch.watchkitapp`、`com.reai.recordingcard.watch.watchkitapp.widgets` 启用 **HealthKit** 与 **App Groups (`group.com.reai.recordingcard`)**。

```bash
cd watch
./scripts/archive_testflight.sh            # 仅归档并导出 .ipa 到 watch/build/ipa/
./scripts/archive_testflight.sh --upload   # 归档并直接上传 TestFlight
```

上传处理完成后，测试员在 iPhone TestFlight 安装 `录音卡手表伴侣`，并在下方「在 Apple Watch 上显示 App」开启安装即可直接线上测试。

---

## 四、后续合入主端 `app/` 的方式

若要把手表采集直接并入主端 `app/`（共享 SenseVoice 本地转写与 Timeline）：
1. 将 `watch/WatchApp` 与 `watch/WatchWidgets` 目标及其 `Embed Watch Content` 阶段并入 `app/ios/Runner.xcodeproj`（确保 `WKCompanionAppBundleIdentifier` 设为 `com.reai.recordingcard`）；
2. 将 `watch/Integration/FlutterRunnerWatchBridge.swift` 加入 `Runner` 并在 `AppDelegate.didInitializeImplicitFlutterEngine` 调用 `FlutterRunnerWatchBridge.shared.register(with:)`；
3. 主端 Dart 侧监听 `com.reai.recordingcard/watch` 通道收到的切片路径，构造 `LiveAudioSlice` 喂入现有 `AppStore.ingestLiveSlice(...)` 即可。
