# PR 测试与实机标定文档：端侧大小双模型、前台流式总结与录音卡共享时间戳输入法

> 分支：`feat/local-llm-voice-keyboard-mvp`  
> 目标：在不改破坏现有主干能力的前提下，最小化落地「录音只录不转 + 单槽位防杀后台 + 端侧大小双模型与老旧机自动切云端 + 总结前台流式与断点续跑 + 录音卡共享时间戳语音输入法」，并提供端到端自动化测试与 **iPhone 13 mini (4GB) vs iPhone 16 Pro (8GB)** 双机压测标定方案。

---

## 一、核心设计与资源最省方案

### 1. 录音卡共享时间戳输入法（极省资源 IPC）

为了彻底避开 iOS Keyboard Extension 的 **~30–60MB Jetsam 内存红线** 与 **禁止调用麦克风沙盒限制**：

1. **进程职责彻底隔离**：
   - **Keyboard Extension（`app/ios/VoiceKeyboardExtension/`）**：只包含轻量 UIKit 按钮与 `WaveformView`（CoreGraphics 32 柱），**零模型权重、零麦克风采集、不传原始 PCM**，常驻内存控制在 **< 15 MB**。
   - **主 App（`VoiceKeyboardIpcBridge.swift` + `VoiceKeyboardPipelineService`）**：真正持有录音卡蓝牙实时流（`LiveAudioRecorder.ringBuffer`）、ASR 与端侧小 LLM。
2. **极轻跨进程通信（App Group + Darwin Notification）**：
   - 共享容器：`group.com.reai.recordingcard`（主 App `Runner.entitlements` 已配置）。
   - **开始/结束时间戳**：键盘点开始写 `voice_keyboard_cmd.json`（含 `type: "start"|"stop"`, `timestampMs`, `sessionToken`）并发 Darwin 通知 `com.reai.recordingcard.kbd.cmd`。
   - **实时波形回传**：主 App 在听写激活期间对实时流按 ~15Hz 节流计算 1 个 `0..255` 电平，滚入 32 字节环形数组并原子写入固定 **128 字节** 二进制文件 `voice_keyboard_wave.bin`（Magic `RCWV` + seq + timestampMs + 32B bars），发 Darwin 通知 `com.reai.recordingcard.kbd.wave` 触发键盘重绘。
   - **±2 秒找气口切片（`BreathBoundarySnapper`）**：收到 `tEndMs` 后，主 App 在 `[tStartMs - 2000ms, tEndMs + 2000ms]` 窗口内做 20ms 短时 RMS 能量扫描 + 自适应底噪门限，若用户起止按下/松开落在发声中间，自动向前后吸附到最近静音气口（±60ms 保护垫片），防止吞掉首尾半个词。
   - **转写 + 极速润色**：通过 `LocalModelMemoryGuard` 单槽位申请 `asr` 完成短窗转写，紧接着调 `LocalLlmService.polishShortText`（紧凑机型优先端侧 `Qwen3.5-0.8B-Q4_K_M` 且用完即卸，老旧/低余量机型自动切云端），通过 `voice_keyboard_result.json` + `com.reai.recordingcard.kbd.result` 回传上屏。

### 2. 防杀后台与大小双模型分级策略

- **录音期只录不转（`AppStore.pauseTranscriptionWhileRecording = true`）**：录音期间仅静默落盘切片与维护内存环形缓冲，不触发周期转写和切页自动转写；停录后统一批量转写（或用户主动下拉手动刷新）。
- **单槽位重模型互斥守卫（`LocalModelMemoryGuard`）**：内存中永远最多只允许 1 个重模型槽位（`asr` / `smallLlm` / `largeLlm`）激活，切换前串行释放旧模型并调用 `trimNativeMemory()`。
- **设备能力分级（`evaluateDeviceLlmTier`）**：
  - `legacyCloudOnly`（物理内存 `< 3.5 GiB`、可用余量 `< 900 MiB` 或严重过热 `critical`）→ 全程自动切云端。
  - `compactLocal`（`3.5 ~ 5.5 GiB`，对应 **iPhone 13 mini 4GB**）→ 默认允许端侧小模型润色（`nCtx = 1024`），总结默认自动切云端（支持设置/测试通过 `LocalLlmRoutingOverride.forceLocalLarge` 强开压测）。
  - `fullLocal`（`>= 5.5 GiB`，对应 **iPhone 16 Pro 8GB**）→ 端侧小模型润色 + 端侧大模型（`Qwen3.5-2B-Q4_K_M`, `nCtx = 2048`, Q8 KV Cache）前台流式总结均可开启；若未放 GGUF 且为 iOS 26+，支持走 `Apple Foundation Models`。
- **总结前台流式 + 离开应用缓存上下文（`SummaryCheckpointStore`）**：
  - 前台实时展示流式生成文本（`Key('gen-stream-preview')`）与不离开提示（`Key('gen-stay-hint')`）。
  - `AppLifecycleState.inactive`（对应 iOS `willResignActive`）抢先中断生成、排空 Metal GPU 命令（防 `SIGABRT`），将已完成的 Map-Reduce 批次摘要与已吐出文本前缀持久化为轻量 JSON 检查点；回前台或进程被杀重启后自动恢复「暂停可续跑」状态（`Key('gen-resume')`），继续生成并跳过已完成批次。

---

## 二、本地自动化测试点与执行命令

在 `app/` 目录下执行：

```bash
export PATH="/Users/kongkang/Developer/tools/flutter/bin:$HOME/.cargo/bin:$PATH"
cd app
flutter analyze
flutter test \
  test/breath_boundary_snapper_test.dart \
  test/local_llm_capability_and_slot_test.dart \
  test/recording_no_transcribe_while_recording_test.dart \
  test/summary_streaming_checkpoint_test.dart \
  test/voice_keyboard_e2e_test.dart
```

并跑全量回归 `flutter test` 确保现有全部用例通过。

| 测试文件 | 覆盖的关键验证点 |
|---|---|
| `test/breath_boundary_snapper_test.dart` | 起止时间戳落在发声中间时，在 ±2s 内向前/向后吸附气口；连续语音严格钳制 ≤ 2000ms；空缓冲安全返回 |
| `test/local_llm_capability_and_slot_test.dart` | iPhone 13 mini (4GB) → `compactLocal`；iPhone 16 Pro (8GB) → `fullLocal`；老旧/低余量机自动切云端；ASR ↔ 小 LLM ↔ 大 LLM 单槽位互斥与退后台全卸 |
| `test/recording_no_transcribe_while_recording_test.dart` | 录音期间哪怕超过 `transcribeCycleMinutes` 或触发 `view-resume`，仍严格只录不转；停录 `finishLiveRecording()` 后立刻转写 |
| `test/summary_streaming_checkpoint_test.dart` | 总结前台 SSE 流式输出实时更新 `gen-stream-preview`；切后台自动暂停并落盘检查点；冷重启恢复卡片并从断点续跑完成（含 Map-Reduce 跳过已完成批次） |
| `test/voice_keyboard_e2e_test.dart` | 录音卡推流中键盘发 `tStartMs` → 实时收到 32 柱波形 → 发 `tEndMs` → ±2s 找气口切片 → 单槽位 ASR → 端侧小模型润色并回传结果；未开录音卡时明确报错 |

---

## 三、有 Xcode 的 Mac 上的原生联调步骤（约 5 分钟）

> 本分支编写于无 Xcode 环境。主 App 新增的 `LocalLlmBridge.swift` 与 `VoiceKeyboardIpcBridge.swift` 已写入 `Runner.xcodeproj/project.pbxproj` 并完成弱链接防护；`VoiceKeyboardExtension` 放在独立目录以免破坏未签名 Target 构建。

1. **挂载 `llama.xcframework`（启用 GGUF 端侧推理）**：
   - 获取预编译带 Metal 的 `llama.xcframework`（llama.cpp 官方 release 或自行 `build-xcframework.sh` 编译，启用 `GGML_METAL=ON`）。
   - 用 Xcode 打开 `app/ios/Runner.xcworkspace`，把 `llama.xcframework` 拖入 `Runner` Target 的 **Frameworks, Libraries, and Embedded Content**（Embed & Sign）。
   - 因代码使用 `#if canImport(llama)`，未拖入时也可直接编译运行（此时端侧 GGUF 自动回报未链接并回落云端/Apple Foundation Models）。
2. **添加第三方键盘 Target（实测系统输入法）**：
   - Xcode → `File` → `New` → `Target` → 选择 **Custom Keyboard Extension**，命名为 `VoiceKeyboardExtension`，Bundle ID 设为 `com.reai.recordingcard.voicekeyboard`。
   - 将自动生成的模板文件替换为 `app/ios/VoiceKeyboardExtension/` 下的 `KeyboardViewController.swift`、`WaveformView.swift`、`Info.plist` 和 `VoiceKeyboardExtension.entitlements`。
   - 在 `Signing & Capabilities` 中为该 Target 添加 **App Groups**，勾选 `group.com.reai.recordingcard`（与主 App `Runner` 保持一致）。
   - 真机运行后，到「iPhone 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 录音卡语音输入法」，并开启「允许完全访问」（用于读写 App Group 容器）。
3. **Sideload 大小两个端侧模型到两台测试机**：
   - 下载 GGUF 权重（建议关闭 thinking 的 Qwen3.5 量化版）：
     - 小模型：`Qwen3.5-0.8B-Q4_K_M.gguf`（~555 MB）
     - 大模型：`Qwen3.5-2B-Q4_K_M.gguf`（~1.38 GB）
   - 通过 `xcrun devicectl` 拷贝进两台测试机 App 容器的 `Library/Application Support/models/llm/`（与现存 ASR 模型同根）：
     ```bash
     # 小模型（两台设备都拷）
     xcrun devicectl device copy to \
       --device <DEVICE_ID> \
       --domain-type appDataContainer \
       --domain-identifier com.reai.recordingcard \
       --source ./Qwen3.5-0.8B-Q4_K_M.gguf \
       --destination "Library/Application Support/models/llm/qwen3.5-0.8b-q4_k_m/Qwen3.5-0.8B-Q4_K_M.gguf"

     # 大模型（16 Pro 必拷；13 mini 用于压测强开临界点）
     xcrun devicectl device copy to \
       --device <DEVICE_ID> \
       --domain-type appDataContainer \
       --domain-identifier com.reai.recordingcard \
       --source ./Qwen3.5-2B-Q4_K_M.gguf \
       --destination "Library/Application Support/models/llm/qwen3.5-2b-q4_k_m/Qwen3.5-2B-Q4_K_M.gguf"
     ```

---

## 四、iPhone 13 mini (4GB) vs iPhone 16 Pro (8GB) 双机实测验收表

请在两台真机上按以下项目逐一实测记录，用以标定「自动丝滑切换」的精确内存阈值：

| 测试项 | 观测指标 | iPhone 13 mini (4GB) 预期/实测记录 | iPhone 16 Pro (8GB) 预期/实测记录 |
|---|---|---|---|
| **1. 设备能力自检** | `LocalLlmBridge.capabilities` 返回 `physicalMemoryBytes` / `os_proc_available_memory` | 预期：`compactLocal`（可用内存 ~1.3–1.8 GB） | 预期：`fullLocal`（可用内存 ~4.0+ GB） |
| **2. 连续录音 10 分钟** | 录音中内存占用与是否触发 ASR | 内存 < 180 MB，ASR 调用 0 次，不杀后台 | 内存 < 200 MB，ASR 调用 0 次，不杀后台 |
| **3. 语音输入法（小模型）** | 弹起键盘 → 点开始 → 波形延迟 → 说 8 秒 → 松手出字耗时与内存峰值 | 波形 ~15Hz 跟手；±2s 不吞字；端侧 0.8B 润色后立刻卸载，不闪退 | 同左，吐字更快；可直接对比端侧 vs 云端延迟 |
| **4. 前台流式总结（默认路由）** | 选 3 段录音生成总结：首字延迟、tok/s、是否触发内存警告 | 自动走云端流式 SSE，稳定完成 | 自动走端侧 `Qwen3.5-2B-Q4_K_M`（或 iOS 26 系统模型）前台流式输出 |
| **5. 13 mini 强开 2B 大模型压测** | 临时设置 `summaryRoutingOverride = forceLocalLarge` | 观察 `nCtx=2048` vs `nCtx=1024` 时是否触发 Jetsam；确定 4GB 机型禁用 2B 的红线值 | 对比 2B 与更大上下文（2048/4096）流畅度 |
| **6. 总结中途切后台 / 杀进程恢复** | 生成到约 40% 时按 Home 退后台 10 秒再回来（及强杀重启） | `willResignActive` 无 `SIGABRT` 闪退；回来后显示「继续生成」并接续完成 | 同左 |

> **关键标定目标**：通过对比第 3、5 项在 **13 mini** 上的 `os_proc_available_memory()` 实测余量，即可精准微调 `evaluateDeviceLlmTier` 中的 `minCompactAvailableBytes`（当前 900 MiB）与 `minFullAvailableBytes`（当前 2.0 GiB），做到既不浪费硬件算力又绝不触碰 Jetsam 红线。
