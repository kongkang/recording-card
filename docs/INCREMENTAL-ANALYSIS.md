# 增量分析模块（2026-11-08）

本模块补的是「原始 ASR → 时间轴事件」之间的缺口：当前正式版由
`RecordingSyncService` 按文件做一次云端 ASR 生成 `RecordEvent`；本模块提供
**分段级滑动窗口润色 + 长静音阶段总结**，等本地 ASR/音频切片接入后可直接编排。

## 模块

| 文件 | 职责 |
|---|---|
| `lib/services/analysis/chat_completion.dart` | 文本补全接缝；生产 `ModelGatewayChatCompletion` 包住现有 `ModelGateway`，测试注入 Fake |
| `lib/services/analysis/incremental_refine.dart` | 窗口 A / A+B / A+B+C / B+C+D；按 id 合并；缺失 id 回退原文；未知 id 丢弃；失败保留已润色结果 |
| `lib/services/analysis/staged_summary.dart` | 相邻分段间隔达到阈值即切事件；每事件送总结（带上一事件上下文）；失败回退原文事件并上报 error |
| `lib/services/analysis/live_analysis_pipeline.dart` | 把「润色 → 阶段总结」串成一条实时管线，输出 refined / changed / events |
| `lib/services/transcription/*` | ASR 接缝 + 设置开关管线（自动转录 / 清洗 / 说话人）；真实 ASR 未接 |
| `lib/services/audio/recording_status.dart` | 录音状态机（idle/recording/processing/transcribing/error + pendingSlices） |
| `lib/widgets/recording_status_block.dart` | Timeline 顶部只读状态块；idle 收起，不占布局 |

## 测试

- `test/incremental_refine_test.dart`（8）
- `test/staged_summary_test.dart`（7）
- `test/live_analysis_pipeline_test.dart`（3）
- `test/transcription_test.dart`（6）
- `test/recording_status_block_test.dart` / `test/recording_status_integration_test.dart`（4）
- 全量：`cd app && flutter analyze && flutter test`（136 用例，2026-11-08）

## 与正式版主线的接入点

```
RecordingSyncService（现有：文件 → 云端 ASR → RecordEvent）
        │  待本地 ASR 产出分段后改为：
        ▼
TranscriptionPipeline → IncrementalRefineCoordinator → StagedSummaryCoordinator
        │                                    │
        ▼                                    ▼
refined 分段（详情/原始数据）          事件总结（Timeline 分段）
```

当前未接原因（不伪装）：

1. 正式版 ASR 是**整文件云端转写**，没有分段/时间轴输出；本地 `sherpa_onnx`
   与 SenseVoice 模型包尚未接入。
2. 录音卡的实时 ADPCM 切片拉取尚未在 Dart 侧实现（桥只提供文件下载）。
3. 因此本模块目前是「代码 + 自动测试通过」，不是「真实链路通过」。

## 录音状态块

`AppShell` 监听 `DeviceStore.isRecording`：设备录音时启动
`RecordingStatusController`，Timeline 顶部显示「正在录音」；停止后收起。
切片/转写细分状态（`pendingSlices`、`transcribing`）已由状态机支持，等
音频切片管线接入后补事件驱动。
