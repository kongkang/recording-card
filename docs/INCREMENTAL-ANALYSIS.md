# 增量分析模块（2026-11-09）

本模块补的是「原始 ASR → 时间轴事件」之间的缺口：正式版原先是整文件一次
云端 ASR 生成 `RecordEvent`；现在**长录音**会先按窗口切成合法 WAV 子片，
逐片 ASR → 滑动窗口润色 → 长静音阶段总结，再写回录音清单，Timeline/详情/
原始数据三处直接消费分段结果。短录音仍走整文件单次 ASR。

## 数据流（已接线）

```
RecordingSyncService
  └─ 时长 ≥ 30s 且 ASR/文本模型都可用
       ├─ WavSplitter：16k/mono PCM WAV → 30s 子 WAV（含合法 RIFF 头）
       ├─ CloudAsrTranscriptionService：逐片 ModelGateway.transcribe
       ├─ TranscriptionPipeline：Setting 的自动转录/清洗/说话人开关生效
       ├─ IncrementalRefineCoordinator：A / A+B / A+B+C / B+C+D
       ├─ StagedSummaryCoordinator：长静音切事件 + 上一事件上下文
       └─ RecordingsManifest：segments（raw/clean/speaker/emotion）+ events
            → RecordEvent：对话=clean、原始数据=raw、标题/概览=事件总结
```

短录音、模型未配置或分段链路异常时，自动回退整文件 ASR，不丢已下载音频。

## 模块

| 文件 | 职责 |
|---|---|
| `lib/services/audio/wav_splitter.dart` | 解析 RIFF/WAVE + PCM fmt/data；按窗口切出合法子 WAV，时间轴连续 |
| `lib/services/transcription/cloud_asr_transcription_service.dart` | 现有 `ModelGateway.transcribe` → `TranscriptionService` |
| `lib/services/transcription/segmented_transcription_pipeline.dart` | 切片 → 逐片 ASR → 润色 → 阶段总结；单片失败继续，原始文本按片保留 |
| `lib/services/analysis/chat_completion.dart` | 文本补全接缝；生产包住 `ModelGateway`，测试注入 Fake |
| `lib/services/analysis/incremental_refine.dart` | 窗口推进；按 id 合并；缺失 id 回退原文、未知 id 丢弃、失败保留已润色结果 |
| `lib/services/analysis/staged_summary.dart` | 长静音切事件；每事件带上一事件上下文；失败回退原文事件 |
| `lib/services/analysis/live_analysis_pipeline.dart` | 「润色 → 切段 → 事件总结」实时管线 |
| `lib/services/transcription/transcription_pipeline.dart` | ASR 结果 + Setting 开关（自动转录 / 清洗 / 说话人） |
| `lib/services/audio/recording_status.dart` | 录音状态机（idle/recording/processing/transcribing/error + pendingSlices） |
| `lib/widgets/recording_status_block.dart` | Timeline 顶部只读状态块；idle 收起，不占布局 |

## 测试

- `test/wav_splitter_test.dart`（6）
- `test/segmented_pipeline_test.dart`（3）
- `test/recording_manifest_test.dart`（4）
- `test/incremental_refine_test.dart`（8）
- `test/staged_summary_test.dart`（7）
- `test/live_analysis_pipeline_test.dart`（3）
- `test/transcription_test.dart`（6）
- `test/recording_status_block_test.dart` / `test/recording_status_integration_test.dart`（4）
- 全量：`cd app && flutter analyze && flutter test`（150 用例，2026-11-09；CI 同）

## 已知边界（不伪装）

1. 分段 ASR 仍是**云端逐片调用**，不是本地 sherpa/SenseVoice；本地模型与
   230MB 模型包尚未接入，端侧离线转写仍待后续。
2. 切片来自**已下载 WAV**，不是录音卡实时 ADPCM 流；实时切片拉取仍待 Dart
   侧桥接。
3. 说话人/情绪字段来自分析层（当前模型不返回时为空，界面标「未区分」），
   不做真实声纹身份断言。
4. 静音切段目前没有真正的 VAD：分段间隔为 0 时用「单事件最长 5 分钟」兜底
   切段；长静音检测待接入音频 VAD 后替换。
5. 多阶段事件已投影为 Timeline 一条事件一张卡（按 segmentIds 拆分）。
6. 录音状态块目前由 `DeviceStore.isRecording` 驱动；`transcribing` /
   `pendingSlices` 状态机已就绪，但同步管线尚未逐片回调。
7. 长录音会按 30s 片数增加云端 ASR 调用次数；这是用分段精度换请求数，后续
   接本地 ASR 后可替换。
