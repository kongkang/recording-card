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

## 多硬件 SDK 包装矩阵（2026-11-15 更新）

`app/rust/card_bridge` 作为 C ABI 统一桥接层，聚合了自研 SDK 与 `app/rust/sdks/` 下的第三方 ReAI 风格包装层：

| SDK Crate | 对应硬件 (`deviceKind`) | 广播识别 / 开关门控 | 核心能力 |
|---|---|---|---|
| `reai-card-sdk` (v0.0.8) | 录音卡 V2 (`card_v2`) | `DYJV2_*`（默认开启） | ADPCM 实时流、`.APM` BLE 同步（75s 无进度停滞看门狗 + 字节流续期）、物理按键手势上报（`click`/`double_click`/`long_press` 归一化并保留原始 `gesture`/`action`）、懒加载非阻塞 BLE KV 元数据缓存、2.4GHz Wi-Fi 配网、双芯 OTA |
| `reai-dyj-sdk` (v0.1.14) | 点一机 V1 (`dyj_v1`) | `DYJ_*`（默认开启） | AMR-WB 实时流与离线解码（DTX `SID` mode 9 / `SPEECH_LOST` mode 14 / `NO_DATA` mode 15 严格补齐 20ms 静音防时间轴漂移）、扫描缓存 `PeripheralId` 零重扫快速直连（避开间歇广播静默窗口）、`.amr` 与相机照片 `<dest>.part` 原子落盘 + 非零预期字节与 `#!AMR-WB\n` 头完整性校验、Wi-Fi 配网、前向兼容 `dyj_tts_speak`（`0.8.14` 固件返回 `1001` 未知命令时干净返回 `unsupported` 错误且不断开 BLE 会话，宿主自动回退手机扬声器 TTS） |
| `reai-board-sdk` (v0.3.5) | 语音 AI 键盘 V2.1 (`board_v21`) | `REAI_VB_*`（默认开启） | Vendor GATT `0xFE60` mSBC 实时流、`AiVoiceKey` 物理语音键 |
| `reai-ext-sdk` | 第三方统一契约层 | — | `RecorderDriver` / `RecorderDevice` trait、纯 Rust Ogg Opus / Raw Opus / LC3 → 16kHz Mono PCM 解码 |
| `reai-getseed-sdk` | 得到 Get 笔记录音卡 (`getseed_gsc10`) | `Get-*` / `0x544A`（Setting 按需开启） | `hasRemoteRecordControl=false`（机身按键控录）、GATT `0xFF00` `.ogg`/`.wav` 下载与单文件删除（禁用 `0x0041` 全盘清除） |
| `reai-omi-sdk` | Omi 量产版 / Friend Pendant (`omi_cv1`) | UUID / `Omi-*` / `Friend_*`（Setting 按需开启） | BLE 实时流（Opus/PCM/μ-law/LC3）、按键手势事件、StorageRing 离线文件同步、BAS 电量 |
| `reai-feishu-sdk` | 飞书录音豆 D3200 (`feishu_d3200`，设置项标 Beta) | Service `020cf5da-…` / `D3200-*` / `soundcore Work`（Setting 按需开启） | BLE 目录、远程启停、ECDH + AES-CTR 离线 Opus 拉取并转 16kHz WAV。不含实时流、SoftAP 与固件升级。尚未真机验证 |

> Priority 3（Plaud Note / Pro / `reai-plaud-sdk`）仍待后续独立分支沿同一 `reai-ext-sdk` 契约接入。飞书录音豆的 Wi-Fi SoftAP 快传不在当前 BLE 接入包内。

## 清洗需求与数据边界
持续源录音默认不分段；偶尔手动 mark，后续分析结合标记推测意图。大段无意义/空白作为阶段边界；清洗内容优先，原始脏数据完整保留、低权重，含口误。声纹近似或偏差时由 LLM 推测归整，必须保留原始映射，不能断言身份。这是产品需求，不代表演示已实现 ASR、声纹、LLM 或完整原始音频存储。

主屏不展示 API 名。所有设备与分析交互均本地静态演示；「需独立云端服务，当前未接」显著标明。历史五月边界不作为拒绝本次新设计的依据。
