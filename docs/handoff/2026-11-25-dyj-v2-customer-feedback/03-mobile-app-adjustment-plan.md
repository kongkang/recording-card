# 移动端软件（`recording-card`）代码问题诊断与调整 Plan

> **状态**：仅诊断与规划阶段（基线 `master @ 668dd10`），未修改任何业务代码。待 owner 确认优先级与交互细节后分阶段实施。

---

## 一、移动端现状盘点（已具备 vs 真实缺口）

在拉取最新 `master`（`668dd10`）并核查 `app/rust/card_bridge` 与 `app/lib/` 后，先对齐客观事实：

- **已具备的能力（可直接用于回应/展示给客户）**：
  - Windows/macOS 扫描隔离与 `ScanFilter::default()`：已在 `app/rust/card_bridge/src/card_v2_ble.rs:286-289` 实现，不丢 Scan Response；
  - 语音直流偏置消除与远场柔和增益：已在 `app/lib/services/transcribe/wav_io.dart:253-307`（`conditionSpeechSamples`）实现；
  - 声纹注册认出「我」与多说话人归因：已在 PR #121（`app/lib/services/voiceprint/joint_speaker_resolver.dart`）落地「我的声音」+ 5 常用槽位 + 跨设备通道校准；
  - 自定义模型 API（文本侧）：`app/lib/services/net/model_provider_store.dart:10-34` 已支持 OpenAI / DeepSeek / OpenRouter / 自定义 API 用于**总结 / 润色 / 话题分段 / Agent**。
- **实测暴露的真实缺口（分两部分：Rust `card_bridge` 接入层 + Flutter `app/` 应用层）**如下。

---

## 二、Rust `card_bridge`（SDK 接入层）5 项问题与改造 Plan

### Plan-R1【P0】：接入 Card V2 AP 热点局域网快传，修复 `ap_start` 误调陷阱
- **代码现状（实证缺陷）**：
  - `app/rust/card_bridge/src/lib.rs:6032-6060` 中 `ActiveDevice::CardV2` 的 `ap_start` / `ap_stop` 直接调用了 `device.start_access_point(ssid, password)` / `stop_access_point()`。
  - 根据 `reai-card-sdk/docs/protocol-support.md:95`，**v0.3.x nRF 固件从未实现 `AP_START` / `AP_STOP` 透传**，调用必烧满 10 秒超时！真实流程是：`open_wifi()`（ESP32 上电自启固定热点 `DYJ-HD-AP` / `192.168.4.1:80`）→ `wait_for_ap_ready()` → `device.access_point_client()`。
  - `card_bridge` 目前完全未暴露 `AccessPointClient` 的列表/只读下载/校验删源通道，Card V2 取大文件只能走 BLE（在 5GHz/企业网公司场景下无法走 STA 云上传）。
- **改造方案**：
  1. 修正 `CardV2` 的 `ap_start` / `ap_stop` 为 `open_wifi()` + `wait_for_ap_ready()` / `close_wifi()`；
  2. 新增 `card_v2.ap_list` / `card_v2.ap_download_verified` 命令：经 `AccessPointClient`（`192.168.4.1:80`）以只读 HTTP 下载 `.APM` 至 `.part`，**校验下载字节数与预期 `size` 严格一致并完成原子 `rename` 后**，才按需显式调用 `delete_file` 删源，彻底消除 BLE 慢传与误删源风险。

### Plan-R2【P0】：修复 `take_card_v2_file` 丢弃 `session` / `seq` 元数据
- **代码现状**：
  - `app/rust/card_bridge/src/lib.rs:3851-3862` 在取回 Card V2 文件返回 JSON 时，仅调用了 `reai_card_sdk::RecordingStamp::parse(&taken.name)`，只透出了 `startAt` 和 `timeSynced`，**丢弃了固件传回名 `synced_<ts>_<session>_<seq>.apm` 中的 `session` 与 `seq`**。
  - 一旦出现 `FILE_LIST` 遗漏或直接走 `take_oldest` 边录边拉场景，上层管线会丢失段序关系，无法触发同会话时间轴自愈与分段关联。
- **改造方案**：改用 `reai_card_sdk::RecordingSegmentName::parse(&taken.name)`，在返回 JSON 中一并透出 `session`、`seq`、`startAt`、`timeSynced`。

### Plan-R3【P0】：旧固件（`≤ 0.3.19`）`-2.7%` 采样时钟频偏软件重采样补偿
- **代码现状**：
  - `app/rust/card_bridge/src/lib.rs:820` 直接调用 `reai_card_sdk::apm_to_wav(src_path, wav_path)` 固定按 `16,000 Hz` 封装；`recording_pipeline.dart` 与 `wav_io.dart` 也假设所有输入均为严格 `16,000 Hz`。
  - 对未修复 PDM 时钟的存量卡（`0.3.17`~`0.3.19`），1 小时音频播放偏快 97 秒、100 分钟会议与手机相册照片/本机麦克风对照漂移近 3 分钟。
- **改造方案**：
  1. 在 `card_bridge` 中为 `transcode_apm`（以及 Card V2 实时 ADPCM 流解码器）增加可选 `sourceSampleRateHz` 参数；
  2. 当连接设备为 `CardV2` 且固件 `versionCode <= 319`（或文件旁车/参数未声明精确 `16000` Hz、且在设置中启用「旧固件时钟校准（~0.9736x）」）时，在 Rust 层用线性/三阶插值将实际 `~15,578 Hz` 重采样为标准 `16,000 Hz` 16-bit PCM；新固件（如 `≥ 0.3.20`）自动旁路。

### Plan-R4【P1】：Card V2 开录支持可配硬件分片时长 + 边录边拉协同
- **代码现状**：
  - `app/rust/card_bridge/src/lib.rs:3018-3030` 已接入 `start_recording_with_duration(secs)`，但 `device_store.dart:2767, 3435, 3566` 调用 `_gw.startRecording()` 时未传 `durationSecs`，导致固件始终按默认 `600s`（10 分钟、~4.8 MB）切片，用户体感同步延迟大、单包传输风险高。
- **改造方案**：为 `CardV2`（`versionCode >= 313`）提供可配默认硬件分片时长（如 180s / 300s，或沿用用户偏好），配合 `0.3.17+` 33 KB/s BLE 连发显著缩短取件耗时并降低单段断传代价。

### Plan-R5【P1】：升级 `reai-card-sdk` 依赖至最新（含后续 `#9`/`#10`/`#8`/`#6`）并引导 `0.3.19` OTA
- **代码现状**：`app/rust/card_bridge/Cargo.toml:18` 仍锁在 `3b7a5c5`（v0.0.8）；待 SDK 合并修复后升级并同步提示用户将 `0.3.17` 卡片 OTA 至 `0.3.19+` 以获得 23h+ 续航。

---

## 三、Flutter `app/`（应用层）6 项问题与改造 Plan

### Plan-F1【P0】：同会话 `1024s` 时间戳回绕与 `nosync` 时间轴自愈（数据层 Bug 修复）
- **代码现状**：
  - `app/lib/services/recordings/recording_pipeline.dart:1145` 按 `_startSecond(b).compareTo(_startSecond(a))` 排序，`1543-1551` 直接信任设备/下载返回的 `startAtSec`（即使在固件 24-bit RTC1 回绕导致 25 段全落在 `09:07–09:21` 时，也直接落盘写入 `file.startAtMs`）。
  - 结果：同一场 4 小时会议的所有切片在 Timeline 上时间完全重叠、顺序错乱、与手机相册和日历事件彻底脱节。
- **改造方案**：
  1. 在 `RecordingPipeline.sync()` 拉齐同一 `session` 列表时，按 `seq` 升序校验 `startAtMs` 单调性；
  2. 若检测到同 `session` 内 `seq > 1` 出现时间倒退、或相邻两段差值与前段真实 `durationMs` 偏差超过 `±15s`（典型 `1024s` 回绕特征），自动以 `seq=1`（或同批次首个可信时间戳）为基准，按前序段实测 `durationMs` 累加重建 `startAtMs`，同时标注「时间轴由段序推算」；
  3. 对 `timeSynced == false`（如固件 `nosync`）但与当前连接/对时窗口相邻的文件，结合设备上报的开机偏移估算校准。

### Plan-F2【P0】：防漏录（开机拨杆状态校验）+ 低电安全停录保底（控制协同）
- **代码现状**：
  - `app/lib/core/store/device_store.dart` 连接成功同步快照后，若物理拨杆处于 `ON` 位（`switchState == on`）但硬件 `isRecording == false`（即客户遭遇的“断电重启后拨杆不起作用”），App 无任何校验或提示；
  - `device_store.dart:2514` 监测到实时电量 `_liveBattery`，但未在极低电量时做主动保护（`≤0.3.19` 固件放到 2% 仍不停录）。
- **改造方案**：
  1. **防漏录提醒**：若设备能力含物理拨杆且在连接刷新时检测到「硬件未录音，但用户配置 `switch_on = record_start` 且近期拨杆状态/上下文异常」，在胶囊与 Timeline 顶部给出醒目提示「检测到录音未启动，点击立即补录」；
  2. **App 侧低电量安全停录 + 手机接力**：蓝牙连接中监测到 `_liveBattery != null && _liveBattery <= 5 && isRecording && !isCharging` 时，自动先启动手机本机麦克风（或 Watch）无缝接力继续录音，再向卡片发送 `stopRecording()` 安全封口卡端 `.APM` 文件，防止过放写坏 FAT 分区。

### Plan-F3【P1】：支持自定义私有云 / 自建局域网 ASR 转写服务（BYO-ASR）
- **代码现状（实证缺口）**：
  - `app/lib/services/net/model_provider_store.dart:23-34` 的 `ModelScene` 仅覆盖 `summary / agent / polish / segmentation / organize / vision`，没有 `asr`；
  - `app/lib/services/net/model_gateway.dart:337-358` 的 `transcribe()` 硬编码调用 `_config.audioTranscriptionsUrl`（即外脑官方网关 `/api/model-gateway/v1/audio/transcriptions`）与 `_client`（OAuth Bearer），用户即使配了自定义 OpenAI 兼容服务端，**音频转写仍无法指向自己的私有云 Whisper / Qwen3-ASR / FunASR**。
- **改造方案**：
  1. 在转写引擎设置（`Setting` → `本地语音引擎`）除现有「外脑网关 / 纯本机 SenseVoice / 系统引擎」外，新增 **「私有云 / 自建转写服务（OpenAI Whisper 兼容）」**；
  2. 支持独立配置 `ASR Base URL`（支持局域网 `http://192.168.x.x` 或私有 `https://`）、`API Key`、`Model Name` 与测试连通性；
  3. `RecordingPipeline` 支持选路：音频直接 Multipart POST 到用户私有端点，**完全不经过 ReAI 服务器**，同时无缝衔接后续端侧声纹聚类（Campplus）与文本管线。

### Plan-F4【P1】：个人热词与行业术语表（Hotwords / Glossary）
- **代码现状**：
  - `SlicePolishService`（`app/lib/services/polish/slice_polish_service.dart:182`）、`RollingCleanSegmentService`（`app/lib/services/segment/rolling_clean_segment_service.dart:696`）与 `SummaryGenerator`（`app/lib/services/ai/summary_generator.dart:96`）仅读取 `AgentConfigStore.promptFor(...)` 自由提示词，缺乏结构化「术语/热词表」输入。
- **改造方案**：
  1. 在 `SettingsStore` / `AgentConfigStore` 新增结构化「热词与专有名词表」（支持按行或逗号维护中英文词条、人名、品牌名，如 `sriracha`、`savory`、`umami`、`KA`、`杨顺`）；
  2. **双处注入**：调用自定义 ASR（Plan-F3）时自动拼接为 `prompt` 参数提升首轮声学解码命中率；同时自动附加到润色、话题分段、总结的 System Prompt，将本地小模型写错的同音词（如「仙/先 → 鲜」「是啊差 → sriracha」）自动纠偏。

### Plan-F5【P0】：全局「仅本机隐私模式」开关
- **代码现状**：
  - `SettingsStore` 目前只有单项开关（`rc.set.trans.auto` / `rc.set.trans.clean` 等），没有一键物理隔离全部云端上行的总开关；用户担心误触云润色/总结/卡片 STA 上传导致涉密会议文本外泄。
- **改造方案**：
  1. 在 `SettingsStore` 新增 `rc.set.privacy.localOnly`；
  2. 开启后：① `ModelGateway` 强拦截所有出站文本/音频网关请求（除用户显式指定的内网 BYO-ASR 外）；② 禁用卡片 `STA 云上传` 入口并在设备状态页提示「仅本机模式已锁定，仅允许蓝牙/热点本地取回」；③ 下发 `CONFIG_SET local_only=1`（待固件 `#16` 支持后联动硬件锁定）。

### Plan-F6【P0/P2】：连接态防误录长静音提醒/自动停录 & OLED 待传状态同步
- **改造方案**：
  1. 在 `SettingsStore` 增加可选「连接态连续静音超时自动停录 / 提醒（默认关，可选 30 分钟）」：借助手机端接收的实时流能量检测或状态巡检，超时弹窗/本地通知提醒并可选自动发 `stopRecording()`；
  2. 每次同步完成、录音停止或连接建立时，统计卡上待传 `.APM` 数量并调用 `DISPLAY_SHOW` 360B 位图推送至卡片 OLED（如「待传 12 段 / 已同步」），补齐卡片屏显反馈。

---

## 四、落地分类与规范门控（遵循 `AGENTS.md`）

为保证不破坏现有线上稳定性并严格遵循 `AGENTS.md` 双版本规范，建议按两类拆分推进：

| 类别 | 包含项 | 是否涉及新 UI | 实施路径 |
|---|---|---|---|
| **第一批：底层 Bug 修复与数据自愈（无新 UI 变更）** | • **Plan-R1（底层通道）**：修 `ap_start`/`ap_stop` 与封装 `AccessPointClient` 只读校验下载<br>• **Plan-R2**：`take_card_v2_file` 透传 `session`/`seq`<br>• **Plan-R3**：旧固件（`≤0.3.19`）`-2.7%` 重采样补偿<br>• **Plan-F1**：同 `session` `1024s` 回绕时间轴自愈<br>• **Plan-F2**：低电量 `≤5%` 接力停录保护 + 拨杆漏录告警 | 否（或仅提示横幅/告警） | 直接修 `app/rust/card_bridge` 与 `app/lib/`，补齐 Rust 单测与 Flutter widget/pipeline 单测，跑 `cargo test` + `flutter analyze && flutter test` |
| **第二批：产品能力与设置项增强（需先过原型 `NC` 确认）** | • **Plan-F3**：自定义私有云 ASR 端点（BYO-ASR）<br>• **Plan-F4**：热词与行业术语表管理<br>• **Plan-F5**：「仅本机隐私模式」全局总开关<br>• **Plan-F6**：静音超时自动停录设置 + AP 快传一键按钮<br>• **Plan-R4**：Card V2 硬件切片时长配置 | **是**（Setting 二级页 / 弹层交互） | 严格按 `AGENTS.md`：**先更新 `prototype/current.html` + `prototype/index.html` 标注 `NC` → 跑 `verify.cjs` → owner 确认设计 → 再实现 `app/` 与 `app/test/` 并去标 `NC`** |
