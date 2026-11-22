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

- ~~声纹跨文件：session 内用 `SpeakerClusterResult.centroids` 与后续文件的簇做余弦匹配
  （阈值 ~0.75），避免每 10 分钟说话人编号跳变；匹配不上才新建编号。~~
  已实现（2026-11-09）：`services/recordings/speaker_profile_store.dart`；
  质心按语音时长加权合并、同文件重跑不重复累加、本地 `recordings/_sessions/` 落盘。
- 声纹置信度：低相似度（<0.5）或小簇（总时长 <2.5s）统一显示「未区分」。
- ASR/VAD 模型生产规格：SenseVoice 官方 size/sha 待 manifest 下发；当前 dev 规格 size=0。
- 真实双人/多人录音的聚类阈值需要用真机数据调参（当前只用重复单人音频验证了链路）。
  跨文件匹配阈值（0.75）同样待真实双人录音校准。

## 6. 真机全链路（2026-11-09）

- 设备 DYJV2_T4W25T，固件 0.3.8 / WiFi 0.1.3，电量 61%。
- 取回最小且 ≥200KB 的 `62B1755F.APM`（25.2s）：
  **1 片 → 6 句原始 → 6 turn → 1 段 → 2 个说话人**。
- 全程 1:06（BLE 下载 + 转码 + VAD + SenseVoice + Campplus + 假云端润色/分段）。
- 证据测试：`app/integration_test/pipeline_device_test.dart`
  （`maxFiles:1, smallestFirst:true, minFileSize:200000`）。
  注意 `take_file_to_dir` 是移动语义：测试会把该文件从录音卡删除，所以只取一个；
  不传 `RC_E2E` 时默认取最小文件。
- 开发期模型：用 `devicectl` 把 `models/` 拷进应用容器
  （见 `/tmp/run_pipeline_device.sh` 或 handoff 的 P7 命令）。
- iOS 重装会重置 TCC：每次真机首跑需在设备上点一次「允许蓝牙」/
  「允许查找本地网络」；授权后 `BluetoothPermission.request()` 返回 granted。

## 7. Android 各品牌系统语音识别接口评估与三层兼容策略（2026-11-19 更新）

本节依据最新 Android 13–16（API 33–36）及各主流手机厂商官方开发文档，梳理音频文件流注入可行性（`EXTRA_AUDIO_SOURCE` / `ComponentName` 显式绑定 / 厂商 SDK）、端侧离线隐私合规与接入成本，作为 `SystemSpeechBridge.kt` 三层自适应策略与 UI 平台隔离展示的真源依据。

### 7.1 Android 最新官方文档与主流品牌接口评估表

| 品牌 / 平台接口 | 最新官方 SDK / 接口细节 | 离线转写硬件卡片音频文件（无麦 / 不上云） | 接入成本 & 前置门槛 | 运行时分层策略 |
|---|---|---|---|---|
| **AOSP Standard (Android 13–16)**<br>Pixel / 海外 GMS 机型 | `createOnDeviceSpeechRecognizer` + `EXTRA_AUDIO_SOURCE` (PCM 16kHz 16-bit mono `ParcelFileDescriptor`)；Android 13+ 支持 `checkRecognitionSupport` 与 `EXTRA_SEGMENTED_SESSION` (`onSegmentResults`)；Android 14+ 支持 `ModelDownloadListener` 进度/队列回调 | **原生可行**：剥离 WAV 头后通过 PFD 注入 16k PCM；需避免混用旧 `EXTRA_SPEECH_INPUT_*` 以防 `Bundle[EMPTY_PARCEL]` 丢结果，固定带 `EXTRA_PREFER_OFFLINE = true` | **低**：纯标准 Android SDK，零白名单；~12s 能量谷底窗口切片消除单次识别长度上限 | **Layer 1 `native_on_device`**：优先匹配并默认免下载启用 |
| **Google 服务显式兼容绑定**<br>（三星 One UI 等预装 `com.google.android.tts` 机型） | `createSpeechRecognizer(ctx, ComponentName("com.google.android.tts", "com.google.android.apps.speech.tts.googletts.service.GoogleTTSRecognitionService"))` + `PackageManager.queryIntentServices` (`<queries>` 声明) | **兼容可行**：官方文档与社区实测确认 Samsung 设备默认 `com.google.android.as` 或 Bixby 易忽略/报错 `EXTRA_AUDIO_SOURCE`，而显式直连 `com.google.android.tts` 并通过 `checkRecognitionSupport(EXTRA_PREFER_OFFLINE=true)` 中文端侧校验后可稳定离线注入 PCM | **中低**：无需厂商合作，需在 `AndroidManifest.xml` `<queries>` 声明包可见性并做严格端侧中文门控（仅接受端侧语言列表含 `zh*`/`cmn*` 的服务） | **Layer 2 `compat_service`**：绕开 Bixby / 问题默认引擎，优先显式直连 `com.google.android.tts`（或已验证端侧中文的非 Bixby `RecognitionService`） |
| **Google ML Kit GenAI ASR**<br>(`com.google.mlkit:genai-speech-recognition:1.0.0-alpha1`, 2026-01) | 基于 Android **AICore** + Gemini Nano，`SpeechRecognizerOptions.Mode.MODE_ADVANCED / MODE_BASIC`，支持 `AudioSource.fromFile` / `fromUri` / `fromPfd` | **有限可行**：仅支持未解锁 Bootloader 的 Pixel 8–10、Galaxy S24+ 等旗舰芯片；**需 Kotlin 2.3+** 且国内无 AICore 覆盖 | **中**：仅作未来旗舰可选增强，不替代标准 API | 保留关注，当前由标准 Layer 1 / Layer 2 统一覆盖 |
| **三星 Galaxy（One UI）**<br>无 Google 服务纯国行 Bixby / SMT | `config_defaultOnDeviceSpeechRecognitionService` 指向 `com.samsung.android.bixby.*` 或 `com.samsung.SMT` | **不可行**：Bixby / SMT 会忽略 `EXTRA_AUDIO_SOURCE` 并**静默回退打开手机物理麦克风** | **高风险拦截**：仅当本机未装 `com.google.android.tts` 时才完全阻断 | 有 `com.google.android.tts` 时走 **Layer 2 兼容方案**；仅 Bixby 时拦截并进 **Layer 3 `local_self_hosted`**（优先 SenseVoice） |
| **小米 / Redmi（HyperOS）** | 小爱开放平台（AIVS-SDK）提供鉴权/唤醒/交互协议，**未向普通 App 开放免签名端侧音频文件流 ASR**；MiMo-V2.5-ASR 为自部署大模型 | **国行原生不可行**：标准 `RecognitionService` 不提供纯端侧 `zh-CN` 离线包 | **极高**：AIVS 核心语音需企业邮件/商务白名单授权且偏交互/云端；自部署 MiMo 与自研 SenseVoice 定位重叠 | 无兼容 GMS 时进 **Layer 3**：首选外脑本地模型 SenseVoice（如手机侧有安装第三方/兼容离线 `RecognitionService` 且过中文端侧门控可自动升格 Layer 2） |
| **OPPO / 一加 / realme（ColorOS）** | ColorOS Breeno / `AIUnit` On-Device Compute | **国行不开放**：官方明确纯离线 ASR 与 AIUnit 能力仅面向深度合作方开放内部 AAR 白名单 | **极高**：无公开免审核离线文件转写 SDK | 仅海外 GMS 走 Layer 1/2；国内机进 **Layer 3**（本地 SenseVoice 首选） |
| **vivo / iQOO（OriginOS）** | 蓝心大模型 / VCAP 计算加速平台（主要开放给 BlueOS 穿戴与合作应用，需开发者账号 `appId`/`appKey` 及特定权限协议） | **国行受限**：OriginOS 手机端无公开免鉴权本地 PCM 文件流 `RecognitionService` | **高**：需商务邮件 `developers-ai@vivo.com` 申请权限协议与渠道 SDK | 国内机未匹配标准兼容服务时进 **Layer 3**（本地 SenseVoice 首选） |
| **荣耀 HONOR（MagicOS 7.0–10.0）** | **Magic Live 离线语音识别工具**（`com.hihonor.mcs.intelligence.voice.mcp.tools`，如 `OfflineSpeechRecognizerRequest`，单文件最高 2h/200MB）；私有 Maven 仓库 `https://developer.hihonor.com/repo` | **技术可行但渠道强绑定**：需企业资质、Maven 私有凭据与签名指纹认证，非标准化开放接口 | **高**：重度渠道签名绑定与体积引入；海外版带 GMS 可直接走标准 Layer 1/2 | 海外 GMS 走 Layer 1/2；国行无兼容服务时进 **Layer 3**（优先本地 SenseVoice；Honor 私有工具列为后续按需通道评估项） |
| **华为 HUAWEI（HarmonyOS 4 / NEXT）** | Android 兼容层：HMS `ml-computer-voice-aft:3.11.0.301`（音频文件转写 AFT **走华为云端**）；纯血鸿蒙 NEXT：`@kit.CoreSpeechKit` | **Android 端不可行**：HMS AFT 上传音频到云端，**违反本地隐私红线**；Core Speech Kit 为纯 ArkTS 原生 API，非 Android APK 接口 | **极高 / 架构隔离**：NEXT 需独立 ArkTS 原生工程 | 在 Android 包内明确标识华为设备并进 **Layer 3**（严禁上传音频上云，本地 SenseVoice 为唯一首选） |
| **Android 12 及以下（API ≤ 32）** | 无 `EXTRA_AUDIO_SOURCE` 文件流接口 | **物理不可行** | 无标准 API | 一律进 **Layer 3**（本地 SenseVoice 为第一选择） |

### 7.2 三层运行时解析与 `NT` 标记规范（2026-11-19）

1. **三层自适应链路（`SystemSpeechBridge.kt`）**：
   - **Layer 1 (`native_on_device`)**：API 33+ 且 `isOnDeviceRecognitionAvailable == true` 且非 Bixby/SMT；窗口失败时如检测到本机安装 `com.google.android.tts` 会自动重试兼容组件。
   - **Layer 2 (`compat_service`)**：枚举 `PackageManager.queryIntentServices(RecognitionService.SERVICE_INTERFACE)`，过滤 `bixby` / `com.samsung.smt` 后以 `com.google.android.tts` 为最高优先级逐个通过 `checkRecognitionSupport(EXTRA_PREFER_OFFLINE=true)` 校验 `installedOnDeviceLanguages` / `supportedOnDeviceLanguages` / `pendingOnDeviceLanguages` 是否包含 `zh*` / `cmn*`（严格拦截仅支持在线云端的服务），并用 `createSpeechRecognizer(ctx, ComponentName)` 直连绑定。`downloadSystemModel` 在 Android 14+ 优先使用 `ModelDownloadListener` 获取进度/调度结果。
   - **Layer 3 (`local_self_hosted`)**：前两层均未匹配时如实返回品牌识别结果与拦截说明，前端隐藏 `asr-opt-system`，将外脑本地模型 SenseVoice 置为第一选择（全程不跨端出现 `iOS` / `SpeechAnalyzer` 字样）。
2. **设计稿 `NT`（Need Test）状态追踪**：
   - 已开发的 Android 多品牌自适应与兼容方案界面在 `prototype/current.html` 与 `prototype/index.html` 中标注紫色 `NT` 徽章及顶栏 `NT·1` 清单（见 `Setting` → `本地语音引擎`），用于追踪后续交互细化设计与多机型真机兼容性实测，待实测全部通过后再摘除 `NT`。

