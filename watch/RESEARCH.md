# 手表端录音笔开源调研与技术方案定稿

> 调研日期：2026-11-15  
> 目标：为 `recording-card` 构建极简、轻量、支持**手机远程一键开录**、**表盘常驻 + 垂腕息屏持续录音**、**断连本地暂存 / 连上本地直推手机（不走云端）**的 Apple Watch 客户端（`watch/`）。

---

## 一、开源项目横向调研

通过联网检索 GitHub 开源生态，已有多款验证过「Apple Watch 录音 + 表盘一键触发 + 传回 iPhone」链路的项目与参考实现：

| 项目 | 仓库 | 技术栈 | 表盘 / 快捷唤醒 | 后台连续录音方案 | 手表 → 手机传输 | 借鉴与避坑点 |
| --- | --- | --- | --- | --- | --- | --- |
| **Omi (`omiWatchApp`)** | `BasedHardware/omi` | Flutter (iOS) + SwiftUI (watchOS) | App 内触发 + 伴侣同步 | `AVAudioEngine` / 会话保活 | `WatchConnectivity` | 证明「主端 Flutter + 独立原生 watchOS 伴侣」可行；其 GitHub Issues（`#21169`、`#4890`、`#11776`）暴露了 `WCSession` 长时断连状态漂移、独立打包签名对齐等坑点 |
| **VivaDicta** | `n0an/VivaDicta` | SwiftUI (iOS & watchOS) | `WidgetKit` 表盘复杂功能 + Action Button + `AudioRecordingIntent` | `WKExtendedRuntimeSession` + `AVAudioRecorder` | `WCSession.default.transferFile` | 工业级标杆：手表只负责低功耗采集并落本地 `.m4a`，用系统后台队列 `transferFile` 推给手机转写；表盘一键直达录音 |
| **WatchNote** | `yiyizhi/WatchNote` | SwiftUI + Whisper/LLM 管线 | 快捷入口 | 本地音频会话 | 本地传回手机/端侧处理 | 验证了「手表采集 → 手机/桌面本地优先处理」的极简分工模型 |
| **Utter** | `RJoshi141/utter` | SwiftUI | 轻量化视图 | `AVAudioRecorder` | `WCSession.transferFile` | 极简 UI 范式，代码清晰 |
| **WatchRecordApp** | `VorobyevS/WatchRecordApp` | Swift + WatchKit | 基础视图 | `AVAudioRecorder` + 后台模式 | `WCSession.transferFile` | 展示了最简可工作的 `WCSession` 文件队列与 iPhone `didReceive` 落盘 |
| **WristRecorder** *(Wear OS 对照)* | `tberghuis/WristRecorder` | Jetpack Compose (Wear OS + Android) | 物理按键 (`STEM1`) 盲操 | 前台服务录制 | 伴侣 App 拉取同步 | 验证了「物理/表盘快捷开录 + 离线暂存 + 手机同步」跨平台共性需求 |
| **ClawHark** *(Wear OS 对照)* | `ivar2000/clawhark` | Wear OS + VAD | 独立运行 | 前台服务 | 分片异步同步 | 分片化落盘避免长录单文件失败重传成本 |

---

## 二、watchOS 核心系统边界与工程结论

### 1. 为什么不能让 Apple Watch 伪装成“普通 BLE 录音卡”被手机扫连？
- Apple 官方 `CoreBluetooth` 明确限制：**watchOS 不支持 `CBPeripheralManager` 广播 BLE GATT 服务**（手表只能做 Central，不能做 Peripheral）。
- 因此手表无法像硬件录音卡 V2（`DYJV2_*`）那样被手机端的 `btleplug` 扫描直连。
- **正解**：采用 Apple 原生 **`WatchConnectivity`（`WCSession`）**。系统在底层自动协调低功耗蓝牙（BLE）与点对点 Wi-Fi Direct，无需人工配对、支持在手机 App 挂起/锁屏时自动在后台接收文件并唤醒处理（`session(_:didReceive file:)`），**100% 走本地设备间直传，不经由任何云端服务器**。

### 2. 为什么必须加到表盘 + 保活会话才能「持续开启、持续录音」？
- **手表放下手腕熄屏即挂起**：仅声明 `WKBackgroundModes = audio` 时，watchOS 仍可能在几十秒到几分钟后因电量策略挂起普通录音进程。
- **双层保活策略**：
  1. **加到表盘（Complication · `WidgetKit`）**：表盘复杂功能不仅提供「抬腕一秒即点即录 / 状态常驻可视（含实时计时器）」，也使 App 在 watchOS 系统中获得最高级别的后台调度与快照刷新优先级。
  2. **双模运行契约（`WatchRuntimeKeepAlive`）**：开录时优先创建室内 **`HKWorkoutSession`**（`.mindAndBody`，不依赖传感器写健康数据，仅利用 watchOS 授予运动会话的连续后台 CPU 与麦克风常驻权），若用户暂未授予健康权限或处于受限环境，自动平滑降级到 **`WKExtendedRuntimeSession`**（`.mindfulness` / `.selfCare`）+ `WKBackgroundModes`（`audio` + `workout-processing`）。

### 3. 如何实现「手机上直接开启手表录音」？
watchOS 不允许未激活的后台手表 App 仅凭 `WCSession.sendMessage` 被动拉起麦克风（`isReachable` 为 `false` 时消息无法即时唤醒）。因此本方案采用**双通道指令路由**：
- **热态（手表在前台/保活中，`WCSession.default.isReachable == true`）**：手机端直接 `sendMessage` 毫秒级下发 `startRecording` / `stopRecording` / `addMark` / `flushPending`，同步写入 `updateApplicationContext` 保底。
- **冷态（手表休眠或仅在表盘后台，`isReachable == false`）**：手机端先更新 `applicationContext`，同时调用 Apple 官方唯一允许跨设备从手机唤醒手表长时任务的 API——**`HKHealthStore().startWatchApp(toHandle: HKWorkoutConfiguration)`**。系统唤醒手表 `WKApplicationDelegate.handle(_ workoutConfiguration:)` 后，手表立即激活保活会话并自动启动录音。

### 4. 音频编码与断连容错设计（全本地 Store-and-Forward）
- **编码与带宽账**：
  - 未压缩 `16kHz / 16-bit / Mono PCM WAV` ≈ **1.9 MB/分钟**，通过表端蓝牙慢速直传极易堵死队列、耗电且在断连时占满手表有限闪存。
  - **16kHz / Mono / 32kbps AAC-LC (`.m4a`)** ≈ **240 KB/分钟**（体积缩小 **8 倍**），60 秒一块仅 240KB，蓝牙传一片仅需数秒；连续离线录制 10 小时仅占用约 **144 MB**。
- **Ping-Pong 双录制器无缝 60s 滚动切片**：
  - 第 55 秒预创建并 `prepareToRecord()` 下一片 `AVAudioRecorder`，第 60 秒无缝切换封口当前片，零丢帧。
  - 每次封口立即写入本地原子账本 `manifest.json`（`pending` → `transferring` → `synced`）。
  - **连着手机时**：立即调用 `WCSession.default.transferFile` 推送到手机；手机端在 `session(_:didReceive file:)` 内**同步拷贝**落盘并转码为与主端 `app/` 完全兼容的标准 `16kHz / 16-bit / Mono Little-Endian WAV`（`LIVE_WATCH_<sessionId>_<seq>.WAV`），同时回发 `ackSlice` 通知手表清理已送达文件释放闪存。
  - **未连手机时**：切片以 `pending` 状态安稳存在手表本地；一旦手表重新接近并连接手机，`WCSession` 激活或可达状态恢复后立即按 `(startAtMs, sliceIndex)` 顺序自动补推，**100% 不丢数据、不走云端**。
  - **异常中断兜底**：启动时扫描 `Application Support/WatchRecorder/recordings/` 目录自动恢复未入账的孤儿 `.m4a`；手机或手表来电/闹钟中断自动封口当前片、恢复后自动开新片并如实记录 `gapCount`；手表剩余空间 `< 20 MB` 时先清理已同步文件，仍不足则显式报错停录，绝不静默丢数据。
