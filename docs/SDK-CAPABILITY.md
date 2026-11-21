# SDK / 产品能力对照

状态：接入施工中（card_bridge FFI 已落地）。2026-11-08 Asia/Shanghai。

## 上游核验句
最新 tag **v0.0.6**（2026-11-08 本地核验：已克隆源码确认 `src/ota.rs`/`src/dfu.rs` 存在，OTA 接口不再是"未记录"）。上游 https://github.com/ReAI-com/reai-card-sdk ，异步 Rust + btleplug（Tokio），不是 Flutter 插件；经本仓库 `app/rust/card_bridge`（C ABI FFI 桥，host 编译通过）接入 Flutter。

## 接入架构（2026-11-08 起）
```
Flutter DeviceStore ──CardGateway(FFI)──> card_bridge(staticlib) ──> reai-card-sdk ──BLE──> 录音卡
        └─ 桥不可用/无硬件时回退预置数据（MockCardGateway，界面无标注，诚实边界只在文档）
```
- 桥符号就绪 = `RealCardGateway.maybe()` 非 null（iOS staticlib 链入 / 桌面 libcard_bridge.dylib）。
- 桥 API：scan / connect / status(battery+state+device_info) / disconnect；回调经 NativeCallable.listener。
- iOS 构建依赖：rustup target aarch64-apple-ios + Xcode 链接 libcard_bridge.a + Info.plist NSBluetoothAlwaysUsageDescription。

## 新信息架构
旧三主页口径作废。底栏仅 Timeline / Setting。Timeline 是每日导入记录、阶段切片事件、清洗对话、手动总结的高频入口；Setting 放系统和功能设置。实时硬件统一顶部角落胶囊及其弹层。

|能力|实际边界 / 接口对照（仅文档）|本原型|
|---|---|---|
|能力|实际边界 / 接口对照|当前接入|
|---|---|---|
|扫描/连接/断开|SDK：DeviceManager::scan/connect、DyjDevice::disconnect|card_bridge scan/connect/disconnect 已封装；真机联调待硬件在环|
|电量/设备状态|SDK：battery/state/device_info|**已接真实链路**：弹层打开时 refreshFromDevice() 刷 CardGateway.status()；无硬件回退 82% 示例值|
|文件取回/上传通道|SDK：list_files、take_file_to_dir、AP download_to_dir、upload_*_via_sta|桥未封装（下一轮）；UI 演示|
|固件升级（主控 + Wi-Fi 两阶段）|**v0.0.6 已有 ota.rs/dfu.rs**（Secure DFU + Wi-Fi OTA，2026-11-08 核验）|桥未封装（下一轮）；UI 演示|
|持续录音默认不分段|产品硬件假设；实时音频 ADPCM 通道 SDK 已具备（audio.rs）|未接；示例共用连续源时间轴|
|手动 mark 起止/重要对话|SDK：record_mark()|桥未封装；仅示例标记|
|ASR / 阶段切片 / 清洗|SDK 无 ASR；需独立云端或本地分析服务，当前未接|静态预置数据（SDK 范围外，诚实边界）|
|声纹 / LLM 归整|SDK 无该能力；分析服务未接|说话人 A/B，标注推测归整；不推断真实身份|
|手动总结 / Markdown / 交互 HTML|SDK 无总结；分析服务未接|可选片段生成本地预制结果卡，不调用模型；安全预置 DOM，无动态执行|

## 多硬件 SDK 包装矩阵（2026-11-21 更新）

`app/rust/card_bridge` 作为 C ABI 统一桥接层，聚合了自研 SDK 与 `app/rust/sdks/` 下的第三方 ReAI 风格包装层；完整 8 硬件对比矩阵与真机实测结果见 [hardware-sdk-acceptance-report-2026-11-21.html](reports/hardware-sdk-acceptance-report-2026-11-21.html) 与 [handoff-2026-11-21-sdk-update-and-full-hardware-acceptance.md](handoff/handoff-2026-11-21-sdk-update-and-full-hardware-acceptance.md)：

| SDK Crate / 通道 | 对应硬件 (`deviceKind`) | 广播识别 / 开关门控 | 核心能力与实测边界 |
|---|---|---|---|
| `reai-card-sdk` (v0.0.8 / `3b7a5c5`) | 录音卡 V2 (`card_v2`) | `DYJV2_*` / `DFU_DYJ*`（默认开启） | ADPCM 实时流、`.APM` BLE 同步（75s 无进度停滞看门狗 + 字节流续期）、实体按键/拨杆 KV 配置（`CONFIG_SET/GET/DEL`、`click`/`double_click`/`long_press`/`switch_on`/`switch_off`）、72×40 OLED 显示（`DISPLAY_SHOW/CLEAR`）、懒加载非阻塞 BLE KV 元数据缓存、2.4GHz Wi-Fi 配网、双芯 OTA（`dual_chip`） |
| `reai-dyj-sdk` (v0.1.14) + `DyjV1Session` | 点一机 V1 (`dyj_v1`) | `DYJ_*`（排除 `DYJV2_`，默认开启） | AMR-WB 12.65kbps 实时流（`FF12 type=0x04`）与 `.amr` 离线解码（`segment_min` 自定义切片、DTX 静音帧补齐防漂移）、`NOTIFY_SETTLE=40ms` + `<=180B` UTF-8 安全单 PDU 写帧（规避固件 `GattServerManager.kt` ATT Prepared Write 缺位）+ `dyj_call_with_reconnect` 断连自愈；实机已完成 `0.8.7 → 0.8.15` OTA 升级（`version_code 807→815`），动态能力位 `dyj_v1_capabilities_for_firmware` 裁剪 `hasCameraMedia`；`v0.8.15` 已实测 `sensor.*`（`magnetic`/`orientation`/`pressure`/`rotation_vector`/`step_counter`；`gyroscope`/`accelerometer`/`light`/`proximity` 固件 HAL 缺失/桩返回 `code=1002`）、`led.set`、`button.status`/`bind`、`device.reboot` `code=2003` 守卫、`tts.speak` `1001 → unsupported:`；Wi-Fi 2.4GHz STA/AP/HTTP 上传闭环实测通过；⚠️ 已定位 `v0.8.15` 固件 `CommandDispatcher.kt` 异常处理顺序 P0 缺陷（`CancellationException` 早于 `TimeoutCancellationException` 捕获导致超时会杀掉分发协程） |
| `reai-board-sdk` (v0.3.5) | 语音 AI 键盘 V2.1 (`board_v21`) | `REAI_VB_*`（默认开启） | Vendor GATT `0xFE60` mSBC 16kHz 实时流（`AudioStreamScope::Timeline` 租约续期）、`AiVoiceKey` 物理语音键、纯流式无板载存储/Wi-Fi/OTA |
| `reai-ext-sdk` | 第三方统一契约层 | — | `RecorderDriver` / `RecorderDevice` trait、纯 Rust Ogg Opus / Raw Opus / LC3 / WAV → 16kHz Mono PCM 解码（38ms 转码实测后本地 Zipformer2-CTC & SenseVoice 转写零退化） |
| `reai-getseed-sdk` (v0.2.0) | 得到 Get 笔记录音卡 (`getseed_gsc10`) | `Get-*` / `0x544A`（Setting 按需开启） | `hasRemoteRecordControl=false`（仅机身按键控录）、`realtimeAudio=false`、`otaMode=none`、`0x180F` BAS 电量、`0x9000` AES-128-ECB（`Walkiz52832iLock`）`<900ms` 只读读取 MAC/FW/SN；`≤v0.1.8` 走 `0x9100` TLV 列表/拉取 `.ogg`/单文件删除（禁用 `0x0041` 全盘擦除）；实机 `v0.2.7`（`v0.2.5+`）`0x9100` 已启官方云端「一机一码」鉴权锁，`time.sync`/`files`/`download` 均如实返回 `unsupported:` 中文引导（已移除旧版假空列表吞错） |
| `reai-omi-sdk` | Omi 量产版 / Friend Pendant (`omi_cv1`) | UUID / `Omi-*` / `Friend_*`（Setting 按需开启） | BLE 实时流（Opus/PCM/μ-law/LC3，50fps 实测 132.18s 零丢包）、按键单击/双击事件、StorageRing 离线文件同步（`26.12 KB/s`）与游标推进、BAS 电量、`otaMode=none` |
| `reai-feishu-sdk` | 飞书录音豆 D3200 (`feishu_d3200`，设置项标 Beta) | Service `020cf5da-…` / `D3200-*` / `soundcore Work`（Setting 按需开启） | BLE 目录、远程启停、ECDH P-256 + AES-CTR 离线 Opus 拉取并转 16kHz WAV。不含实时流、SoftAP 与固件升级（`otaMode=none`）。尚未真机验证 |
| `WatchHardwareBridge` | Apple Watch 独立采集 (`apple_watch`) | Setting「Apple Watch 联动」（默认关闭） | `WCSession` 双向控录/打点、表端 60s Ping-Pong 无缝双录切换（`Prewarm`）产 `.m4a` 切片、iPhone 侧离线转 16kHz WAV 接入同一 Pipeline；无硬件 Wi-Fi/相机/蓝牙外设桥 |
| `PhoneMicRecorder` | 手机本机麦克风保底（未独立归档为蓝牙卡） | 硬件断连自动接力 / 无硬件独立开录 | `AVAudioEngine` 16kHz Mono PCM 采集，硬件蓝牙录期间零功耗待命、异常断连自动无缝接力、1 分钟切片直入本地 VAD+SenseVoice |

> Priority 3（Plaud Note / Pro / `reai-plaud-sdk`）仍待后续独立分支沿同一 `reai-ext-sdk` 契约接入。飞书录音豆的 Wi-Fi SoftAP 快传不在当前 BLE 接入包内。另已在 `app/rust/vendor/btleplug-0.12.0` 修复 CoreBluetooth 断开重扫丢失缓存设备名及 `discover_services` ATT 出错时永久挂死的底层问题。

## 录音卡 V2 按键/拨杆配置与 OLED 屏幕边界（2026-11-21 核验）

1. **物理按键与侧边拨杆（`reai-card-sdk` rev `3b7a5c5`）**
   - 协议支持通过 `CONFIG_SET/GET/DEL` 读写 5 项输入槽位：`btn_single`、`btn_double`、`btn_long_press`、`btn_long_release`、`switch_on`、`switch_off`，并持续上行 `BTN_CLICK` 与 `TOGGLE_SWITCH` 事件（`app/rust/card_bridge` 已映射 `card_controls.get` / `card_controls.set`）。
   - 固件内置原生动作：`record_mark`、`record_start`、`record_stop`、`record_toggle`、`sync_upload`（开启 Wi-Fi 上传）。App 侧自定义动作写入 `app_sync`（双击立即触发 App BLE/切片同步，避免抢占 SD 总线）与 `agent_voice`（长按语音触发 Agent）。
   - 默认推荐绑定（首次连上且硬件尚未绑定任何非 `none` 动作时自动写入）：单击 `mark`（`record_mark`）、双击 `syncNow`（`app_sync`）、长按 `agentVoice`（`agent_voice`）、拨杆开 `recordStart`（`record_start`）、拨杆关 `recordStop`（`record_stop`）。
   - **冲突优先级**：软件蓝牙录音开关使用幂等显式 `RECORD_START`/`RECORD_STOP`（Rust 桥在设备回错时自动复核 `record_status()` 收敛），优先级高于拨杆当前位置；拨杆物理拨动后根据硬件 `RECORD_STATUS` / `TOGGLE_SWITCH` 状态与屏幕变化在 App 侧同步跟随，不重复重放固件已执行的原生动作。

2. **72×40 单色 OLED 屏幕（`DISPLAY_SHOW` / `DISPLAY_CLEAR`，固件 ≥ 0.3.7）**
   - `DISPLAY_SHOW` 的纯文本 `lines` 模式仅支持 5×8 ASCII（12 字符 × 5 行），不支持中文字符；发送中文提示必须走 **360 字节单色位图**（`72×40` 像素、5 页 × 72 列、`bit 0` 为页顶行）经 `bitmap` 字段 Base64 下发（App 侧由 `FlutterOledBitmapRenderer` 栅格化后推送）。
   - **扫描期限制（不可由 App/SDK 单方面绕过）**：蓝牙扫描阶段设备仅做被动 BLE 广播（Advertising），未建立 GATT 连接前手机无法向 NUS RX 特征值（`6e400002-...`）写入 `DISPLAY_SHOW` 命令，因此「被扫描到时在录音卡屏幕上亮出型号标签」无法仅靠 App/SDK 实现，必须由卡端固件在广播态自行刷新 OLED。App 侧已在**建立连接成功第一时间**自动下发「已连接 + 型号短号」位图提示，并在开始/停止录音、拨杆切换、打重点、立即同步、语音 Agent 各阶段及按键设置变更时推送中文屏幕提示。

## 清洗需求与数据边界
持续源录音默认不分段；偶尔手动 mark，后续分析结合标记推测意图。大段无意义/空白作为阶段边界；清洗内容优先，原始脏数据完整保留、低权重，含口误。声纹近似或偏差时由 LLM 推测归整，必须保留原始映射，不能断言身份。这是产品需求，不代表演示已实现 ASR、声纹、LLM 或完整原始音频存储。

主屏不展示 API 名。所有设备与分析交互均本地静态演示；「需独立云端服务，当前未接」显著标明。历史五月边界不作为拒绝本次新设计的依据。
