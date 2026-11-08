# 本地转写流水线（P1 实现说明 + 真机 Spike 数据）

状态：2026-11-08 · P1 基础设施 + 声纹方案已验证。真机：iPhone 13 mini（iOS 27.0.1），
模型：SenseVoice int8（237MB）+ Silero VAD（644KB）+ Campplus 声纹嵌入（28MB）。

## 1. 链路

```
.apm（设备 10 分钟段）
  → apm_to_wav（16k/16bit/mono）
  → VAD（Silero，512 采样窗口喂）→ SpeechSpan[]
  → SlicePlanner（45~90s、静音处切、不重叠）→ slices/*.wav
  → SenseVoice（worker isolate）→ text + tokens + timestamps + emotion/lang
  → token 对齐切句（停顿 ≥500ms / 句末标点）→ RawUtterance[]
  → Campplus 句级嵌入 + 本地聚类 → speakerCluster → speakerLabel（推测）
```

## 2. 真机实测（2026-11-08）

| 项 | 结果 |
|---|---|
| SenseVoice 加载 | 0.52~0.58s |
| 转写 60.9s 音频 | 2.65s（RTF **0.043**） |
| Silero VAD 67s 音频 | 0.19~0.39s（12 段） |
| 切片 | 67s → 2 片（60.9s / 5.2s） |
| tokens / timestamps | **都有**；143 tokens = 143 timestamps |
| tokens ↔ text | 中文逐字对齐，`tokens.join() == text` |
| 时间戳范围 | 240~60240ms（相对切片） |
| emotion / lang / event | `NEUTRAL` / `yue` / `Speech`（带 `<|...|>` 包装，已归一化） |
| **Campplus 声纹嵌入** | **12/12 段，0.94s**（真机） |
| 聚类 | 1 人（重复同一段音频，符合预期） |

结论：
1. **SenseVoice 有 token 级时间戳**，且 token 是中文字符。`utterance_builder`
   优先按 token 停顿切句，不再依赖标点（SenseVoice 这段输出没有标点）。
2. VAD 必须按 **512 采样窗口**喂；一次性喂 67s 会因内部 30s 环形缓冲只保留 0.6s。
3. **pyannote 分割路线放弃**：`OfflineSpeakerDiarization` 在 iOS 真机上 fp32/int8
   都会卡死（>9 分钟不返回，Mac 6.5s 正常）。改用「VAD 段 → Campplus embedding
   → 本地聚类」，真机 12 段 0.94s，完全够用；不再下载 pyannote 模型。
4. 延迟预算（10 分钟设备段）：BLE 传 10~27 分钟 + 转写 10 片约 27 秒（RTF 0.043 理想值）
   + 云端改写；用户看到时间轴约 **20~35 分钟**后，与计划一致。

## 3. 模块与契约

- `services/transcribe/asr_models.dart`：模型规格 + 下载（Range 续传/SHA-256/原子写）+ 随包 VAD 复制。
- `services/transcribe/local_asr_service.dart`：worker isolate；`load` / `transcribe` /
  `loadVad` / `detectSpeech` / `unload` / `dispose`。ASR 超时会杀 worker 重建。
- `services/transcribe/sherpa_runtime.dart`：iOS 绑定 `SherpaOnnxC.framework`
  （上游包的 iOS 路径写死为 `sherpa_onnx.framework`，1.13.x 用不了）。
- `services/transcribe/slice_planner.dart`：纯函数切片；长静音（≥15s）一定收片。
- `services/transcribe/wav_io.dart`：16k/16bit/mono WAV 读写，字节级无损切片。
- `services/transcribe/utterance_builder.dart`：token 优先、标点兜底。

## 4. 失败语义

- 模型缺失：切片留在 `queued`，界面提示「本地转写模型未就绪」，**不上传音频、不编造文本**。
- 解码超时：杀 worker，切片标 `failed`，下次同步重试。
- 空文本：正常结果（静音/无法识别），不抛异常，不生成空分段。
- 润色失败：保留本地原文（`polishStale=true`），详情页如实提示。

## 5. 待办（P2/P3）

- 声纹跨文件：session 内用 `SpeakerClusterResult.centroids` 与后续文件的簇做余弦匹配
  （阈值 ~0.75），避免每 10 分钟说话人编号跳变；匹配不上才新建编号。
- 声纹置信度：低相似度（<0.5）或小簇（总时长 <2.5s）统一显示「未区分」。
- ASR/VAD 模型生产规格：SenseVoice 官方 size/sha 待 manifest 下发；当前 dev 规格 size=0。
- 真实双人/多人录音的聚类阈值需要用真机数据调参（当前只用重复单人音频验证了链路）。
