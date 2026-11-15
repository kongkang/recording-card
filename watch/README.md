# 录音卡 · Apple Watch 独立硬件端（`watch/`）

> 定位：**录音卡**（`com.reai.recordingcard`）统一套件的腕上采集硬件，作为与 `录音卡 V2` / `点一机 V1` / `语音AI键盘 V2.1` 平级的 **第 4 款录音硬件**（`DeviceKind.appleWatch`）接入现有手机主端 `app/`。  
> 开源项目调研与系统边界论证见：[RESEARCH.md](./RESEARCH.md)。

---

## 一、开源调研结论与统一架构

经调研 `BasedHardware/omi`、`n0an/VivaDicta`、`yiyizhi/WatchNote`、`RJoshi141/utter`、`VorobyevS/WatchRecordApp` 等开源项目并结合 watchOS 系统限制：

1. **同一套软件、非独立伴侣 App**：
   - watchOS Target 直接嵌入 `app/ios/Runner.xcodeproj`：
     - iPhone 主端：`com.reai.recordingcard`
     - watchOS 手表端：`com.reai.recordingcard.watchkitapp`（`WKCompanionAppBundleIdentifier = com.reai.recordingcard`）
     - 表盘复杂功能扩展：`com.reai.recordingcard.watchkitapp.widgets`
   - 在已有「录音卡」App **`Setting → 硬件设备联动 → Apple Watch 联动`** 开启后，Apple Watch 进入右上角胶囊与设备列表；默认关闭时扫描列表保持 3 款 BLE 硬件。
2. **手机远程开录 & 表盘常驻保活**：
   - 表达前台可达时经 `WCSession.sendMessage` 毫秒级启停/打点；表端熄屏挂起时经 `HKHealthStore().startWatchApp(toHandle:)` 远程拉起手表录音。
   - 手表侧提供 4 种 WidgetKit 表盘复杂功能（圆角、圆形、矩形含计时器、内联），开录自动激活 `HKWorkoutSession`（降级 `WKExtendedRuntimeSession` + 音频后台模式），支持垂腕熄屏持续录音。
3. **极轻本地采集 + 断连暂存 + 手机本地转码入库**：
   - 表端无转写、不传云端，使用 Ping-Pong 双 `AVAudioRecorder` 滚动录制 **60s / `16kHz` / Mono / 32kbps AAC (`.m4a`)**，断连落盘至本地队列与原子账本 `manifest.json`。
   - 靠近 iPhone 后由 `WatchSessionSyncEngine` → `WatchHardwareBridge.swift` 本地传回，手机端本地解码重采样为标准 **`16kHz / 16-bit / Mono PCM WAV`**，通过 `AppStore.ingestLiveSlice` 接入 SenseVoice 本地转写、滑动窗口润色与 Timeline 展示。
4. **胶囊能力门控、灵动岛与零功耗本机保底**：
   - 连上 Apple Watch 后，状态弹层展示「录音状态」开关、三档电量（**高/中/低，不展示百分比与“已充满”**）与「同步」按钮；隐藏 Wi-Fi、固件 OTA 与独立本机录音行。
   - 录播期间同步点亮 iOS 灵动岛与锁屏实况；若录音中发生非手动异常断连，自动拉起手机本机麦克风接力保底。

---

## 二、目录结构

```text
watch/
├── Config/Shared.xcconfig                  # 统一 Bundle ID (com.reai.recordingcard*) 与 Team ID (35N5SGDE59)
├── Packages/WatchRecorderCore/             # iOS/watchOS/macOS 共享协议、离线队列账本、M4A->WAV 转码与自检
├── WatchApp/                               # 嵌入 Runner 的 watchOS 客户端（WatchApp target）
├── WatchWidgets/                           # 表盘 WidgetKit 复杂功能（WatchWidgets extension）
├── prototype/                              # 1:1 录音卡手机端 × Apple Watch 双端联动 HTML 设计稿
├── scripts/                                # 图标生成与统一 Runner IPA TestFlight 归档脚本
└── RESEARCH.md                             # 开源手表录音笔调研报告与 watchOS 系统边界论证
```

对应主端接入代码位于 `app/ios/Runner/WatchHardwareBridge.swift`、`app/lib/services/watch/watch_hardware_service.dart`、`app/lib/core/store/device_store.dart` 与 `app/lib/pages/`。

---

## 三、Xcode 真机实测与线上打包步骤

### 1. 真机联调（iPhone + Apple Watch 配对）
1. 先按主端步骤准备 Flutter iOS 工程与 Rust 硬件桥（`cd app && flutter pub get && flutter build ios --config-only --no-codesign`）；
2. 用 Xcode 打开 **`app/ios/Runner.xcworkspace`**（选择 `Runner` Scheme，目标选真机 iPhone，会自动连带把 `RecordingCardWatchApp.app` 安装到配对 Apple Watch）；
3. 在 Apple Watch 上长按表盘 →「编辑」→ 添加 **「录音卡」** 复杂功能；
4. 打开手机端「录音卡」App → 底部 **Setting → 硬件设备联动 → Apple Watch 联动** 开启开关 → 返回点右上角状态胶囊连接 Apple Watch，验证远程开录、灵动岛/表盘同步计时、断连离线暂存与重连自动转码入 Timeline。

### 2. TestFlight 归档脚本
前提：确保 Developer 后台已为 `com.reai.recordingcard`、`com.reai.recordingcard.watchkitapp`、`com.reai.recordingcard.watchkitapp.widgets` 启用 `HealthKit` 与统一套件所需能力。

```bash
./watch/scripts/archive_testflight.sh            # 归档统一 Runner.xcarchive 并导出 .ipa 到 watch/build/ipa/
./watch/scripts/archive_testflight.sh --upload   # 归档并上传 App Store Connect / TestFlight
```

---

## 四、双端 1:1 HTML 设计稿预览与校验

```bash
# 本地启动静态服务预览主端与手表双端联动设计稿：
python3 -m http.server 18923 --bind 127.0.0.1
# 主端设计稿: http://127.0.0.1:18923/prototype/current.html
# 双端联动稿: http://127.0.0.1:18923/watch/prototype/index.html

# 自动化校验：
node prototype/verify.cjs
node watch/prototype/verify.mjs
```
