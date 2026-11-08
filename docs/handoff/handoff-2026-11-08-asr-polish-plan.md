# Handoff · 语音转写 / 增量润色 / 分段总结（2026-11-08 批准）

> 本文件是 owner 已确认的开发计划，作为 P0~P7 的执行依据。设计来源：owner 2026-11-08 口头方案 + 现有代码盘点。
> 新会话接手时先读本文件，再读 `AGENTS.md` 的「当前阶段」。

## 1. 基线

- **不是 master 从零做**。PR #7 已把 `fix/mobile-hw-design` 合并进 master（`664211f`），其中包含：
  - `app/rust/card_bridge` 单一入口 `card_bridge_command`：扫描/连接/电量/存储/录音控制/mark/文件列表与下载/APM→WAV/Wi-Fi/同步上传/两阶段 OTA；
  - 真实 OAuth2 PKCE + Keychain；模型网关 ASR + chat；真实总结生成；导出；本地持久化；设置/隐私页；
  - 测试：`flutter analyze` 0 issues，`flutter test` 108 项全绿。
- 本阶段分支：`stage/asr-polish-timeline`。
- Android 仍不支持 BLE（Rust 桥仅 iOS），不在本期范围。

## 2. 目标链路

```
录音卡 .apm（10 分钟/段，IMA ADPCM 16k mono）
  → BLE take_file_to_dir（3~8 KB/s）
  → apm_to_wav（16k/16bit/mono）
  → SlicePlanner（Silero VAD，45~75s 一片，静音切，硬上限 90s，无重叠）
  → 本地 SenseVoice 转写（worker isolate；text/tokens/timestamps/emotion/lang）
  → 声纹聚类（pyannote segmentation + 3dspeaker embedding + fast clustering；session 质心跨文件对齐）
  → 云端滑动窗口改写（[k-2,k] 原始句 + 上一段润色尾 → PolishedTurn[] + boundary）
  → SegmentBuilder（静音≥20s / mark / topic / 15min 兜底）
  → 一份数据三处展示：Timeline / 对话详情（润色）/ 原始数据（本地原文+时间戳+情绪+声纹）
```

## 3. 已定决策

| 事项 | 决策 |
|---|---|
| 传输 | V1 文件拉取 + 本地切片；实时流/AP 快传放 M3 可选 |
| 延迟 | 接受 20~35 分钟（10 分钟设备段 + BLE 10~27 分钟 + 转写/改写 2~5 分钟） |
| 本地 ASR | SenseVoice int8 + Silero VAD；云端只做改写/总结，不做 ASR 兜底 |
| 窗口 | 当前片 + 前 2 片（约 3 分钟）；只允许改窗口内 turn，窗口外冻结 |
| 分段 | 静音 ≥20s / 手动 mark / LLM topic / 单段 15 分钟兜底 / 录音结束 |
| 说话人 | 文件级聚类 + session 质心匹配；展示「说话人 1/2（推测）」，低置信度「未区分」；不断言身份 |
| 持久化 | 每录音文件一份 JSON + `rc_recordings_index_v2` 轻量索引；原子写；v1 迁移不丢数据 |
| 音频保留 | 文本永久；音频默认 7 天（可设 1/7/30 天），先删 WAV 再删 APM |
| 模型 | SenseVoice 237MB + tokens + VAD（随包）+ pyannote ~6MB + 3dspeaker ~28MB；`RC_MODEL_MANIFEST/BASE` 下载 + SHA-256 + 续传；缺失时排队不冒充 |

## 4. 分阶段与工作量

| 阶段 | 内容 | 人日 |
|---|---|---|
| P0 | 基线合并 + 文档 + Spike（真机 SenseVoice/diarization 可行性） | 2.0 |
| P1 | 模型管理 + sherpa worker + SlicePlanner + WAV IO | 6.5 |
| P2 | 声纹聚类 + 跨文件质心 + 情绪/语种 + 映射 | 4.5 |
| P3 | CardFile 元数据 + 同步器 + 流水线 + 存储/迁移/保留策略 + 调度 | 7.5 |
| P4 | 增量窗口改写 + 严格 JSON + 对账/冻结/重试 | 7.5 |
| P5 | 分段边界 + 段总结 + live/closed 生命周期 | 4.5 |
| P6 | 录音状态块 + 详情三 tab + 总结文章 + 设置 + 宽窄屏/逐帧自查 | 8.5 |
| P7 | 真机长跑/性能/修复缓冲/发布准备 | 5.5 |
| **合计** | | **46.5 ≈ 47** |

- MVP（M1+M2）≈ 22.5 人日 / 4~5 周；完整版 1 人 9~10 周，2 人 5~6 周。
- LLM 成本粗算 ¥8~12/天（8 小时活跃），24 小时约 ¥25/天；存储 APM 0.7GB/天、WAV 2.8GB/天。

## 5. 关键接口与文件（计划）

```
app/lib/core/models/recording.dart          RecordingFile / AudioSlice / RawUtterance / PolishedTurn / SegmentRecord
app/lib/core/store/pipeline_store.dart      实时队列/录音块状态
app/lib/services/transcribe/                sherpa_stt_service / slice_planner / diarization_service / wav_io
app/lib/services/transcribe/model_manager/  模型 spec / 下载 / SHA / 删除（移植 reai）
app/lib/services/polish/                    polish_service / polish_prompt / polish_reconciler
app/lib/services/segment/                   segment_builder / segment_summarizer
app/lib/services/recordings/                recording_pipeline / recording_store
app/lib/pages/widgets/live_status_block.dart
```

复用参考工程：
- `reai_mobile_app/lib/services/transcribe/sherpa_stt_service.dart`（worker isolate/模型加载/decode）
- `.../long_audio_transcription.dart`（VAD/chunk 规划，改目标时长 12s→45~75s）
- `.../bundled_vad_model.dart`（asset 校验/复制）
- `.../model_manager/*`（安装/续传/SHA；去掉本地 LLM 部分）
- `.../refine_prompts.dart`（注入防护思路）

必须扩展：`_decodeSamples` 返回 `tokens/timestamps/emotion/event/lang`；新增无重叠切片；接 `OfflineSpeakerDiarization`。

## 6. 增量改写协议（草案）

请求：录音起始时间、当前分段标题/上段摘要、窗口前最后 6 条润色 turn、窗口内原始句（绝对时间/说话人/情绪）。

返回：

```json
{"turns":[{"src":["s12u0","s12u1"],"start_ms":720000,"end_ms":726400,
           "speaker":"2","text":"..."}],
 "boundary":{"type":"none|topic|silence","reason":"..."},
 "segment":{"title":"...","brief":"...","long":"..."}}
```

校验：`src` 必须命中窗口内 id；时间在窗口 ±2s 且单调；文本长度 0.3~2.5× 原句；speaker 仅已知集合或「未区分」。
对账：删除窗口内旧 turn → 按 start_ms 插入 → `polishedThroughSlice=k`；幂等、可重启续跑。
失败：保留上一版润色（无则原文），标 `stale`，5s/15s/60s/5min 退避；详情页如实提示。

## 7. 验证

1. 单测：slice_planner / polish_window / reconciler / segment_builder / recording_store / diarization mapping / CardFile 解析。
2. Widget：录音块三态且不可点、详情三 tab 真实数据、总结文章 Segment 源。
3. 真机集成：`integration_test/local_asr_device_test.dart`、`polish_pipeline_test.dart`、扩展 `hardware_probe_test.dart`。
4. E2E：`flutter drive --driver=test_driver/integration_test.dart --target=integration_test/ui_flow_test.dart -d <deviceId>`。
5. 回归：`cd app && flutter analyze && flutter test`；`cd prototype && npm run verify`（55 项）。
6. 目检：脉冲点/声波/live 卡片逐帧截图；锁屏/后台/低电量。

## 8. 风险与待确认

| # | 事项 | 默认 |
|---|---|---|
| 1 | 模型 CDN/manifest 地址与 SenseVoice/pyannote/3dspeaker 许可 | 开发期 sideload 本机模型；上线前必须给地址 |
| 2 | 云端润色模型 | 沿用 `chat/completions`；建议新增 `RC_MODEL_POLISH`，确认额度/单价 |
| 3 | iOS 后台 BLE | 先 Spike；不可行则前台同步 + 如实状态 |
| 4 | 声纹准确率 | 标注「推测」，低置信度降级「未区分」 |
| 5 | 实时流/AP 快传 | M3 可选，不进 V1 |

## 9. 明确不做

实时音频流（V1）、AP 快传（V1）、云端 ASR 兜底、跨会话陌生人声纹库、Android BLE 桥、任意 HTML 执行。
