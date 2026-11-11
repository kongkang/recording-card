# Handoff · 三硬件 SDK 统一解耦 / Setting V2 与 Agent 配置 / 照片时间轴对齐 / 电量与总结 Tab 修复（2026-11-11）

## 1. 交付概览

- **工作分支**：`feat/multi-device-agent-settings`（基于 `master` @ `6000ad9`）
- **真机覆盖安装版本**：`dev.kongkang.recordingCard` `1.0.0 (Build 130016)`（Release AOT 签名包，保留原有蓝牙/本地网络 TCC 授权、Keychain OAuth 登录态与 258 MB 端侧模型）
- **合并策略**：按约定已推送分支并创建 PR，**未合并进 `master`**，留待真机验收确认后合并。
- **验收与测试结果**：
  - `cd prototype && node verify.cjs`：**72/72 项全部通过**（`pass: true, errors: [], networkRequests: []`，`390x844 @2x + 900x1100`）
  - `cargo test --manifest-path app/rust/card_bridge/Cargo.toml`：**3/3 通过**（三硬件前缀无碰撞识别、AMR-WB → 16kHz WAV 解码、上传源解析）
  - `cd app && flutter analyze --no-pub`：**`No issues found!`**
  - `cd app && flutter test --no-pub`：**`267/267 All tests passed!`**

---

## 2. 本轮完成的核心模块

### 2.1 三款自有硬件 SDK 统一接入与能力矩阵解耦（`card_bridge v0.2.0`）
- **统一 Rust FFI 桥**（`app/rust/card_bridge/`）：保持单一 `card_bridge_command` C ABI 入口，内部按设备能力矩阵路由三套官方 SDK（当前阶段单连接活跃设备，底层已完成 Phase-2 多设备并发连接与按信号无缝切换解耦设计，详见 `docs/MULTI-DEVICE-ARCHITECTURE.md`）：
  1. **录音卡 V2**（`reai-card-sdk v0.0.6`，BLE 前缀 `DYJV2_`）：IMA-ADPCM 实时流 → 16kHz PCM、SD 卡 `.APM` 补传、Wi-Fi、双芯片两阶段 OTA。
  2. **点一机 V1**（`dyj-v1-sdk v0.1.14`，BLE 前缀 `DYJ_` 且严格排除 `DYJV2_`）：AMR-WB 实时流 → 16kHz PCM、`.amr` 离线文件同步与转码（`amr_transcode.rs`）、硬件按键拍照事件（`camera`）与 SoftAP `8788` / Server 照片拉取（`syncCameraPhotos`）。
  3. **语音 AI 键盘 V2.1**（`reai-board-sdk v0.3.5`，`default-features = false, features = ["ble"]`，BLE 前缀 `REAI_VB_`）：Vendor GATT `0xFE60`、mSBC 实时流（`AudioStreamScope::Timeline` 租约续期 + 旧固件回退）→ 16kHz PCM → 1 分钟滚动 WAV 切片送本地 SenseVoice、物理 `AiVoiceKey` 按键翻转录音开关。
- **能力门控 UI**（`HardwareCapabilities` + `StatusSheet`）：
  - 扫描列表按 RSSI 从强到弱排序，并为每台设备渲染型号徽标（`录音卡 V2` / `点一机 V1` / `语音AI键盘 V2.1`）。
  - 连接语音 AI 键盘 V2.1（无机身存储）时自动隐藏「可录至 …」、「同步」、「Wi-Fi」、「固件」行，保留统一录音开关；连接点一机 V1 时隐藏双芯片固件升级行。

### 2.2 电量滞后修复与展示红线守护
- **事件驱动实时刷新**：Rust 桥监听三套 SDK 的电源/电池主动通知并推入 `power` 事件，Flutter `DeviceStore` 后台 1s（弹层打开时 200ms）零蓝牙流量消费内存事件队列，插拔充电器或档位变化即时更新。
- **低频看门狗降频防抢占**：待机空闲 30s 探一次；正在录音推流期间自动降频至 `120s`（`recordingHeartbeatIdle`），避免频繁查询与音频流争抢 BLE 带宽。
- **严守设计红线**：仅展示绿/橙/红电池图标与 `充电中` / `电量高` / `电量中` / `电量低`，不展示百分比数字，不出现「已充满」字样。

### 2.3 总结 Tab 下拉刷新隔离与空态修复
- 切到「总结」Tab（`FeedFilter.summary`）时：
  - 空态明确展示 `还没有总结 · 点击右上角「总结」选择记录生成`，不再误导显示「下拉可从录音卡取回」。
  - 下拉刷新走 `AppStore.refreshSummariesOnly()`，仅重读本地持久化总结状态，**绝不触发蓝牙拉取录音卡文件**（`syncRecordings()`）。
- 自动润色与跨切片合并：按约定本轮不改动现有转写/润色执行管线，完整单线程全天上下文方案已输出至 `docs/FULL-DAY-AGENT-CONTEXT-PLAN.md`。

### 2.4 点一机 V1 硬件抓拍 + iOS 系统相册时间轴对齐
- **双通道照片接入**：
  1. 点一机 V1 硬件拍照键触发（无 App 端快门按钮），通过 `syncCameraPhotos` 拉取 JPEG 并按拍摄时间戳对齐到对应录音段落。
  2. iOS 原生 `PhotoKit` 通道（`AppDelegate.swift` 中 `com.reai.recordingcard/photos` 的 `importInWindows`），可在 `Setting → 录音 → 关联录音期间系统相册照片` 按录音时间窗口一键对齐导入手机相册照片。
- **三处界面联动**（严格对齐 `AGENTS.md` 设计基线）：
  - Timeline 记录右侧 `45×45` 正方形相册缩略图（1 张单图、2~3 张层叠、>3 张第 4 层带总数遮罩）。
  - 详情页「对话详情」按照片拍摄时间穿插进对话流；点击「不属于本段」后外侧缩略图同步减少，并归入当天分组顶部的「未归类图片」卡片。
  - 总结卡右侧显示 `含 X 张图片`（统计未排除的来源图片数）。

### 2.5 Setting V2 与 Agent 驱动二级配置页（全量持久化 + 实时生效）
- 先在 `prototype/index.html` 与 `prototype/verify.cjs`（扩充至 72 项检查）定稿，再 1:1 落地 Flutter（`AgentConfigStore` + `SettingSubPage`）：
  1. **本地语音引擎**（`set-local-model`）：清晰拆解阶段 1 `Silero VAD`（随包约 1.8MB，人声/静音切分）、阶段 2 `SenseVoice Small INT8`（约 230MB，离线语音转文字）、阶段 3 `3D-Speaker CAM++`（约 27MB，本机声纹特征聚类推测），支持完整性校验与下载管理。
  2. **云端模型设置**（`set-cloud-model`）：支持切换总结推理模型（`deepseek-v3` / `qwen-max` / `gpt-4o` / `claude-3-7-sonnet` 及网关 `/models` 动态发现模型）、上下文策略（`全天连续单上下文` vs `仅所选记录独立上下文`）与采样温度（`0.2 / 0.5 / 0.8`）。
  3. **预设风格与提示词**（`set-prompts`）：提供 `通用纪要 / 深度会议 / 访谈提炼 / 极简待办 / 自定义` 预设，支持可视化编辑保存 `总结生成 / 口语清洗与分段 / 日报与做梦` 三套 System Prompt（总结生成提示词已实时接入 `SummaryGenerator`，JSON 结构契约由客户端自动追加保护）。
  4. **扩展能力**（`set-extensions`）：统一管理 `Skills · Tools · MCP` 开关与自定义 MCP Server 增删，已启用的 Skills 自动注入总结生成指令。

---

## 3. 明早真机验收建议清单

1. **蓝牙多设备扫描与型号识别**：点右上角状态胶囊，确认附近开启广播的 `DYJV2_*`（录音卡 V2）、`DYJ_*`（点一机 V1）或 `REAI_VB_*`（语音 AI 键盘 V2.1）按距离排序且显示对应型号标签。
2. **能力裁剪与录音推流**：
   - 连接键盘 V2.1：确认弹层隐藏同步/Wi-Fi/固件与「可录至」，打开录音开关（或按键盘物理语音键）每满 1 分钟生成本地转写记录。
   - 连接点一机 V1 / 录音卡 V2：确认录音推流、充电插拔时电量档位实时更新且无百分比数字。
3. **总结 Tab 与自定义 Agent 生成**：
   - 切到「总结」Tab 下拉刷新，确认不会触发蓝牙拉卡。
   - 进入 `Setting → 云端模型设置 / 预设风格与提示词` 切换预设或修改提示词，回到 Timeline 勾选记录生成总结，验证总结风格按新配置输出。
4. **照片对齐与排除**：在录音时段用手机拍照（或点一机按键抓拍），进入 `Setting → 关联录音期间系统相册照片` 导入后，检查 Timeline `45px` 缩略图、详情页对话内嵌照片及「不属于本段 → 未归类图片」闭环。
