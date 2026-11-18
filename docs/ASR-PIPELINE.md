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

## 7. Android 各品牌系统语音识别接口评估与端侧策略（2026-11-18）

本节总结各品牌 Android 设备的原生/厂商语音识别能力、音频文件流注入可行性（`RecognizerIntent.EXTRA_AUDIO_SOURCE`）、离线隐私合规与接入成本，作为 `SystemSpeechBridge.kt` 运行时判定与 UI 平台隔离展示的依据。

### 7.1 Android 各品牌/接口横向对比与接入成本表

| 品牌 / 系统 | 底层服务 / 公开接口 | 离线转写硬件卡片音频文件（无麦/不上云） | 接入成本 & 前置门槛 | V1 运行时策略 |
|---|---|---|---|---|
| **Google Pixel / 海外版 GMS 机型**<br>（Android 13+, API 33+） | AOSP `SpeechRecognizer.createOnDeviceSpeechRecognizer()` + `EXTRA_AUDIO_SOURCE`<br>底层 `com.google.android.as`（System Intelligence / AICore）或 `com.google.android.tts` | **可行**：剥离 WAV 头后通过 `ParcelFileDescriptor` 注入 16kHz 16-bit mono PCM，配合 ~12s 能量谷底切片与 `EXTRA_ENABLE_FORMATTING` | **低**：纯标准 Android SDK，零白名单、零商业商务接入费；单次 ~15–25s 断句上限由窗切消除 | **支持**：默认启用「系统内置」（免下载 228MB SenseVoice）；若缺中文语言包可调用 `triggerModelDownload` 按需拉取 |
| **Android Flagship（ML Kit GenAI / AICore）** | Google `mlkit:genai-speech-recognition`（Gemini Nano 端侧） | **有限可行**：仅 Pixel 8–10 / Samsung S24+ 等海外旗舰白名单芯片；国内机 0 覆盖 | **中**：仅覆盖极窄高端海外机型，无法替代通用分支 | 当前由标准 Android 13+ On-Device API 统一覆盖 Pixel / GMS 旗舰 |
| **三星 Galaxy（One UI）**<br>海外 GMS vs 国行 Bixby | 底层绑定 `com.google.android.as` 时走标准通道；若 `config_defaultOnDeviceSpeechRecognitionService` 指向 `com.samsung.android.bixby.*` 或 `com.samsung.SMT` | **海外 GMS 可行；国行 / Bixby 不可行**：实测 Bixby / SMT 会忽略 `EXTRA_AUDIO_SOURCE` 并**静默回退打开手机物理麦克风** | **高风险拦截成本**：不可直接依赖 `isOnDeviceRecognitionAvailable == true`，必须读取系统资源判断默认包名 | **强制拦截**：识别 `servicePkg` 含 `bixby` 或 `com.samsung.smt` 时 `supportsModernSystemAsr = false`，明确提示原因并仅显示 SenseVoice |
| **小米 / Redmi（HyperOS / MIUI）** | 国行 `com.miui.voiceassistant`（小爱）<br>海外版带 GMS 的 Xiaomi 14/15 取决于系统是否预置 Google 端侧语言包 | **国行不可行**：`isOnDeviceRecognitionAvailable == false`；小爱开放平台偏云端/唤醒场景 | **极高**：小爱私有接口需商业白名单与系统签名，普通应用不可接 | 国行与未开 GMS 服务机型返回不支持并识别设备型号，仅保留 SenseVoice 增强模型 |
| **OPPO / OnePlus / realme（ColorOS）** | ColorOS Breeno / `AIUnit` | **国行不可行**：标准端侧 API 不可用；AIUnit AAR 对接需企业商务审核与机型白名单 | **高**：仅适配特定 ColorOS 高端机 + 额外 SDK 体积 + 商务白名单 | 仅海外 GMS 可用；其余统一屏蔽系统项，引导下载 SenseVoice |
| **vivo / iQOO（OriginOS）** | OriginOS 蓝心大模型 / Jovi 语音 | **国行不可行**：未向第三方开放无麦克风的离线音频文件 PCM 转写流 | **高 / 封闭**：无公开第三方离线转写 SDK | 国行统一屏蔽系统项，仅保留 SenseVoice |
| **荣耀 HONOR（MagicOS）** | Honor Voice Kit vs 海外 GMS | **国行受限**：Honor Voice Kit 需开发者资质审核、AppId + 签名指纹绑定，且偏在线/交互场景；海外 GMS 可走标准 API | **高**：额外维护厂商私钥/签名与渠道 SDK，偏离离线卡片录音场景 | 检测是否具备标准非 Bixby 端侧服务；未开放时仅显示 SenseVoice |
| **华为 HUAWEI（HarmonyOS 4 / EMUI / NEXT）** | Android 兼容层无 GMS；HMS `ml-computer-voice-aft` 为**云端接口**；HarmonyOS NEXT `@kit.CoreSpeechKit` 非 Android APK | **不可行**：HMS 音频文件转写会将音频上传华为云，违反本地隐私红线；HarmonyOS NEXT 不走 Android 通道 | **极高 / 架构隔离**：需独立 ArkTS 原生工程 | 在 Android 包内明确标识为华为设备，禁用系统引擎，纯本地使用 SenseVoice |
| **Android 12 及以下（API ≤ 32）** | 无 `EXTRA_AUDIO_SOURCE` 与无 `createOnDeviceSpeechRecognizer`（或仅 API 31/32 无文件流注入） | **物理不可行**：Android 13（API 33）之前无法将文件描述符作为 `SpeechRecognizer` 输入 | 无标准 API 可用 | 一律返回不支持，隐藏系统模型项，仅显示 SenseVoice |

### 7.2 运行时判定与平台 UI 隔离约束

1. **Android 运行时检测链路（`SystemSpeechBridge.kt`）**：
   - 通过 `Build.MANUFACTURER` / `Build.BRAND` / `Build.MODEL` 及系统属性（`ro.mi.os.version.name`、`ro.miui.ui.version.name`、`ro.build.version.opporom`、`ro.vivo.os.build.display.id`、`ro.build.version.magic`、`hw_sc.build.platform.version`、`ro.build.version.emui`、`ro.build.version.oneui`）生成 `brandId`（`pixel`/`samsung`/`xiaomi`/`oppo`/`vivo`/`honor`/`huawei`/`other`）与 `deviceSummary`。
   - 读取 AOSP 系统字符串 `android:string/config_defaultOnDeviceSpeechRecognitionService` 对应的默认服务包名 `onDeviceServicePackage`。
   - 当且仅当 `Build.VERSION.SDK_INT >= 33`（TIRAMISU）且 `SpeechRecognizer.isOnDeviceRecognitionAvailable(context) == true` 且服务包名不包含 `bixby` 与 `com.samsung.smt` 时，`supportsModernSystemAsr = true`。
   - 返回真实 `engineName`（如 `Android 系统端侧语音（System Intelligence）` 或 `Google 端侧离线语音引擎`）与通过 `checkRecognitionSupport` 探测到的 `offlinePackInstalled` / `canDownloadOfflinePack`，支持点击「下载系统中文离线包」触发 `SpeechRecognizer.triggerModelDownload`。
2. **平台纯净化（Platform-Pure UI）**：
   - Android 端界面（`SettingSubPage` / `ModelManagerController` / `SystemSpeechCapabilities`）禁止出现任何 `iOS` 或 `SpeechAnalyzer` 字样；iOS 端同样不出现 `Android` / `Bixby` / 国产 ROM 文案。
   - 当当前设备 `!supportsSystemAsr` 时，**完全隐藏 `asr-opt-system` 选项行**，在 `asr-engine-group` 内仅渲染本机可选的模型（`SenseVoice 增强模型`）并在 `local-status-card` 顶部通过 `Key('local-device-summary')` 如实展示当前识别到的设备及不支持原因。

