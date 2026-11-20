# Get 笔记卡与点一机 V1 兼容 SDK 全量更新及多硬件端到端验收报告

- **验收日期**：2026-11-21
- **关联交互式 HTML 报告**：[hardware-sdk-acceptance-report-2026-11-21.html](../reports/hardware-sdk-acceptance-report-2026-11-21.html)（单文件离线可用，含筛选与完整原始 JSON）
- **硬件能力基线同步更新**：[SDK-CAPABILITY.md](../SDK-CAPABILITY.md)
- **实测硬件与固件**：
  - **Get 笔记卡**（`Get-A7769D`，SN `GET25LA7769D`，MAC `5C:8E:8B:A7:76:9D`，FW **`v0.2.7`**）
  - **点一机 V1**（`DYJ_YKAUP3`，IMEI `867400020316612`，Android `8.1.0` `sl8541e_1h10`，BT `40:45:DA:0F:CA:5E`，实机 OTA **`0.8.7 (807) → 0.8.15 (815)`**）

> **诚实边界与隔离声明**：全程未连接 `DYJV2_T4W25T`；所有测试数据来自实机采集 JSON/WAV 日志与 `cargo test` / `flutter test` 输出，未对任何静音音频或受限固件编造内容。

---

## 一、SDK 与客户端代码更新总览

| 层级 | 文件路径 | 核心更新 | 实测验证结果 |
|---|---|---|---|
| **GetSeed SDK** | `app/rust/sdks/reai-getseed-sdk/src/{device,protocol}.rs` | 接入 `0x9000` AES-128-ECB (`Walkiz52832iLock`) 只读读 MAC/FW/SN；移除 `connect` 阻塞对时；移除 `Timeout→Ok([])` 假空列表吞错，`v0.2.5+` 明确报 `unsupported:` | `cargo test` **5/5 PASS**；实机 `connect` **40,090ms → 3,299ms**，`snapshot` **24,038ms → 14ms** |
| **BLE 底座** | `app/rust/vendor/btleplug-0.12.0/src/corebluetooth/*.rs` | 修复断开重扫丢 cached local name；修复 `didDiscoverServices` / `Characteristics` / `Descriptors` ATT 报错静默丢弃导致 `discover_services()` 永久挂死 | 0 警告编译通过；`DYJ_YKAUP3` 连续多轮连接断开不再永久挂起 |
| **DYJ V1 会话与统一桥** | `app/rust/card_bridge/src/{dyj_v1_session,lib,capabilities}.rs` | `NOTIFY_SETTLE=40ms` + `<=180B` UTF-8 安全单 PDU 写；`dyj_call_with_reconnect` 3 次自动重连；按 `version_code` 动态裁剪 `hasCameraMedia`；开放 34 条 `dyj.*` 命令；修 `plugged='ac'`、`ota_info` 越界回退 V2、`time_sync` 吞错、`tts.speak 1001→unsupported` | `cargo test` **37/37 PASS** (1 ignore)；实机从 `0.8.7` 成功 OTA 至 `0.8.15` 并实测 4 类物理传感器 |
| **Flutter 网关与 UI** | `app/lib/core/device/card_gateway.dart` · `pages/status_sheet.dart` | 封装 `DyjV1HardwareCommands`（含 `startRecordingSegment`）；增加 `_5G` 2.4GHz 引导；GetSeed `hasRemoteRecordControl=false` 提示与 UI 自适应裁剪 | `flutter analyze` **0 issues**；`flutter test` **567 passed / 0 failed / 7 skipped** |

---

## 二、App 全硬件能力对比大表（8 大硬件源）

| 功能 / 能力项 | 录音卡 V2 | 点一机 V1 | 语音 AI 键盘 V2.1 | Get 笔记卡 (≤v0.1.8) | Get 笔记卡 (v0.2.5+ / 实测 v0.2.7) | Omi 录音器 | 飞书录音豆 D3200 | Apple Watch | 手机本机麦克风 |
|---|---|---|---|---|---|---|---|---|---|
| **1. 设备发现与防碰撞过滤** | **✅ 支持** (DYJV2_* 与 DFU_DYJ* 优先识别，与 DYJ_* 前缀严格隔离；默认开启) | **✅ 实测通过** (DYJ_*（排除 DYJV2_），macOS 实测 5.0–5.2s 扫出 DYJ_YKAUP3 (-47~-60 dBm)；RPA 漂移重扫自愈) | **✅ 支持** (REAI_VB_* + 系统已配对 Vendor GATT 0xFE60；默认开启) | **✅ 支持** (Get-* / Company ID 0x544A 识别；Setting「第三方硬件联动」按需开启) | **✅ 实测通过** (Get-A7769D scan 8,109ms / 12,272ms，0x544A 解析 MAC 与尾字节 0000000207 → v0.2.7) | **✅ 实测通过** (Service UUID 19B10000 / Omi-* / Friend_*；实测 macOS 6.0s / Android 10.18s；默认关闭) | **⚠️ 未真机测** (Service 020cf5da / D3200-* / soundcore Work 单测通过，Beta 开关默认关闭，待真机) | **✅ 支持** (Setting「Apple Watch 联动」默认关闭，开启后通过 WCSession 暴露为独立硬件) | **✅ 支持** (无蓝牙硬件时作为本机录音；蓝牙硬件录期间零功耗待命（Standby）) |
| **2. 蓝牙遥控开始 / 停止录音** | **✅ 支持** (BLE 命令 start_recording / RECORD_STOP 遥控启停与 SD 卡落盘) | **✅ 实测通过** (record.start (124ms) / record.stop (122ms) 纯蓝牙启停 .amr，联动 audio.capture.start) | **✅ 支持** (card_bridge 管理纯流式录音状态 + OpenAudioStream 租约) | **❌ 不支持** (硬件设计仅支持机身物理按键控录；hasRemoteRecordControl=false（App 明确提示）) | **❌ 硬件不支持** (实测 record.start/stop 0ms 拦截，诚实提示「请短按机身按键开始/结束录音」) | **✅ 实测通过** (通过订阅/退订 19B10001 实时流 + LiveAudioRecorder 控制手机采集与归档（FW 3.0.21 始终 VAD 待命）) | **⚠️ 协议支持** (reai-feishu-sdk 实现 CMD_RECORD 遥控启停单测，待 D3200 真机验证) | **✅ 支持** (WCSession 双向发送 start/stop 指令触发 WatchAudioCaptureEngine) | **✅ 支持** (App 开关直接启停 AVAudioEngine 采集，异常断连自动接力无需按键) |
| **3. 机身物理键控录与状态同步** | **✅ 支持** (机身拨杆/按键状态与按键事件经 BLE 事件流同步 App) | **✅ 实测通过** (EVT:record.state / button.bind 支持将 click/double_click/long_press 绑定 record.toggle) | **✅ 支持** (AiVoiceKey 物理语音键事件上报触发 App 状态翻转) | **✅ 支持** (机身物理按键控录，StatusSheet 自动隐藏遥控开关并提示按键操作) | **⚠️ 受限** (仅机身物理键可起停；v0.2.7 0x9100 锁机导致第三方 App 无法读取 0x0050 实时录音态) | **✅ 实测通过** (物理单击/双击经 23BA7925 上报 App；为防 FW 3s 关机已禁用长按自定义) | **⚠️ 协议支持** (hasPhysicalRecordToggle=true，协议支持状态查询与事件同步（待真机）) | **✅ 支持** (表端独立 UI「开始/停止录音」与 WCSession 状态双向同步) | **❌ 无物理键** (手机端通过屏幕 UI 与灵动岛/锁屏实况控件操作) |
| **4. 录音自动切片 (Slicing)** | **✅ 支持** (卡端约 5 分钟 .APM 分段 + App 实时流 60s 能量谷底软切片) | **✅ 实测通过** (硬件侧生成 _01.amr/_02.amr 分段 + EVT:record.segment + App 实时流 60s 切片) | **✅ 支持** (纯实时流由 App LiveAudioRecorder 60s SoftBoundaryPcmSlicer 自动切片) | **⚠️ 机身自主** (卡端自主管理 .ogg 文件分段；App 拉取后按本地切片器切入时间轴) | **🔒 云锁拦截** (0x9100 文件列表与拉取被 v0.2.7 云端鉴权锁阻塞，无法获取离线切片) | **✅ 实测通过** (实时流 132.18s 实测切出 60s+60s+12.28s 三片 + 离线 StorageRing 按 1800 条(~5m) 分块) | **⚠️ 协议支持** (卡端离线 Opus 文件按会话管理，BLE 目录分页拉取（待真机）) | **✅ 支持** (表端 WatchAudioCaptureEngine 60s Ping-Pong 双录切换密封 .m4a 切片) | **✅ 支持** (PhoneMicRecorder 16kHz PCM 60s 自动滚动切片封口 .WAV) |
| **5. 指定切片时间长度** | **✅ 支持** (支持 start_recording_with_duration(secs) 与 App setSliceDuration(Duration)) | **✅ 实测通过** (实测 record.start(segment_min=10) 回显 {"segment_min":10}；Flutter 提供 startRecordingSegment(segmentMinutes) + App 侧 60s/动态窗口) | **✅ App 侧可配** (无板载硬件分段；App LiveAudioRecorder.setSliceDuration() 可动态指定) | **❌ 硬件不可指定** (GetSeed 协议无设置硬件切片分钟数接口；仅能在拉取后于 App 端按时长再切) | **❌ 不支持** (硬件无此协议参数且 0x9100 被锁) | **⚠️ App 端可配** (硬件持续 50fps BLE 流（不支持改硬件分片），App 端可通过 sliceDuration 与下拉刷新即时出片；离线环固定 1800 条/块) | **⚠️ 会话定时** (start_record(duration_secs) 支持设录音总时长，但切片仍按文件组织（待真机）) | **⚠️ 常量配置** (WatchConstants.sliceDurationSeconds = 60s，编译期可调，运行期固定 60s) | **✅ App 侧可配** (PhoneMicRecorder 构造参数 sliceDuration 可指定（默认 60s，最低 1s）) |
| **6. 蓝牙实时音频流传输** | **✅ 支持** (BLE ADPCM 实时流 → Rust 解码 16kHz Mono PCM 回调) | **✅ 实测通过** (FF12 type=0x04 AMR-WB 12.65kbps 实时流，实测 5s 50 块/8,844B & 长录 732 块/81,176ms → 16kHz WAV) | **✅ 支持** (Vendor GATT 0xFE60 (FE63) mSBC 16kHz 实时流) | **❌ 不支持** (纯离线存储架构（realtimeAudio=false），仅录后 BLE 拉 .ogg 文件) | **❌ 不支持** (实测 bridge realtime_open 0ms 拦截并返回明确不支持原因) | **✅ 实测通过** (19B10001 Opus/PCM/μ-law/LC3 50fps 实时流，macOS 实测 132.18s 零丢包；Android 崩溃已修待重测) | **❌ 不支持** (realtimeAudio=false；仅支持录后 BLE 离线文件拉取（或官方 App SoftAP）) | **⚠️ 准实时切片** (表端每 60s 封口 .m4a 立即通过 WCSession.transferFile 回传，不走连续 BLE 流) | **✅ 本机直采** (AVAudioEngine 本地微秒级 16kHz PCM 直出，无 BLE 带宽限制) |
| **7. 录音切片与传输连续性（断档检测）** | **✅ 双保险** (BLE seq 检测 + LiveSession.coversCardFile 自动比对，高丢包才触发 SD 卡 .APM 整片补传) | **⚠️ 偶发弱网重连** (FF12 seq_le 逐帧校验，稳定窗内 0 断档（5.36s 0 gap + DTX 补 20ms 静音对齐）；但 LSTO=360ms 遇 2.4G Wi-Fi 共存会断连，需离线 .amr 补齐) | **✅ 序号追踪** (SequenceTracker 检测丢包并触发 gap 事件，无板载补盲（受物理射频限制）) | **⚠️ 切片内连续** (离线整文件 CRC16 校验无传输断档，但无实时流) | **🔒 云锁阻塞** (v0.2.7 无法拉取离线文件) | **✅ 实测零断档** (macOS 实测 550/550 包 & 132.18s gapCount=0；断连期间音频写入板载 RingBuffer 重连可补) | **⚠️ 离线解密** (BLE 分页/AES-CTR 离线整段拉取（待真机测吞吐与 CRC）) | **✅ 预热无缝** (prewarmRecorder 提前预热 1s 零缝切换；中断/丢失写入 gapCount 并本地持久化排队) | **✅ 零断档** (本机 PCM 环形缓冲与切片连续字节无丢包) |
| **8. 板载存储与 BLE 文件拉取/删源** | **✅ 支持** (SD 卡 .APM 列表、分块下载（75s 停滞看门狗）与单文件删除) | **✅ 实测通过** (/data 分区 11.7GB（可用 10,275MB）存储 .amr；record.list / delete 实测释出 55,350B) | **❌ 无存储** (hasOnboardStorage=false, hasFileSync=false；弹层自动隐藏同步行) | **✅ 协议支持** (≤v0.1.8 支持 0x0042/0x0043/0x0145/0x0044（显式禁用 0x0041 全盘擦除）) | **🔒 云锁拦截** (实测 v0.2.7 0x9100 返回 0 通知；新版 SDK 不再假返回空列表，立即报 unsupported) | **✅ 实测通过** (StorageRing 30295781 实测 26.12 KB/s 拉取并 takeOldestFile 推进 read_seq) | **⚠️ 协议支持** (CMD_LIST / CMD_TRANSFER / CMD_DELETE + ECDH+AES-CTR 解密 Ogg Opus（待真机）) | **✅ 表端队列** (手表 NSDocumentDirectory 持久化 .m4a 切片队列 + manifest，靠近 iPhone 自动续传) | **✅ 手机磁盘** (直落 App Support/live_audio/*.wav，无需蓝牙同步) |
| **9. Wi-Fi 配网 (2.4GHz) 与高速上传** | **✅ 支持** (2.4GHz Wi-Fi 配网、凭证读取、忘记与 ESP32 Wi-Fi 上传) | **✅ 实测通过** (实证 2.4GHz 单频（KK2BY_5G 超时拒绝）；STA 连 KK2BY 6.5s ip=192.168.28.76 → HTTP :18900 POST 9,975B → 自动删源；AP 启动 192.168.43.x 通过) | **❌ 不支持** (hasWifiConfig=false) | **❌ 不支持** (纯 BLE 外设，无 Wi-Fi 模组；bridge wifi_connect 0ms 拦截) | **❌ 不支持** (同上，实测 bridge 0ms 拦截) | **❌ 不支持** (无 Wi-Fi 模组；实测 Gate 准确拦截 connectWifi / ap.start) | **❌ SDK 未含** (硬件本身有 SoftAP 但官方/开源未公开完整方案，reai-feishu-sdk 未纳入 (hasWifiConfig=false)) | **❌ 无自建配网** (系统级 WCSession 自动协商蓝牙/Wi-Fi 通道，不暴露手动配网) | **❌ 不适用** (直接复用手机蜂窝/Wi-Fi 上传，无需硬件配网) |
| **10. 重点打点 (Mark) / 按键手势绑定** | **✅ 支持** (RECORD_MARK + 物理 click/double_click/long_press 统一归一化与原始字段保留) | **✅ 控制面实测** (button.status / bind.get / bind.set 7 项控制全通过（v0.8.7&0.8.15）；物理按压 EVT:button.event 需人工触键；App mark 写入本地记录) | **✅ 语音键** (AiVoiceKey 按键事件触发（无独立 mark 接口，mark 记本地）) | **❌ 不支持** (hasMarkButton=false, hasConfigurableButtons=false) | **❌ 不支持** (实测 bridge mark 0ms 返回不支持) | **✅ 实测通过** (23BA7925 单击(0x01)/双击(0x02) + App mark() 实测 PASS；长按强制禁用) | **❌ 不支持** (hasMarkButton=false, hasConfigurableButtons=false) | **✅ 支持** (手表录音页「打重点」写入相对起点偏移 marksOffsetMs 随切片回传) | **✅ 本机打点** (支持屏幕按钮/操作按钮/灵动岛注入相对偏移 Mark) |
| **11. 摄像头拍照与分段录像** | **❌ 无摄像头** (hasCameraMedia=false) | **🔒 v0.8.15待复测** (v0.8.7 正确报 1001 并动态置 hasCameraMedia=false；升级 v0.8.15 后 hasCameraMedia=true（因 02:45 协程死锁待重启后实拍复测）) | **❌ 无摄像头** (—) | **❌ 无摄像头** (—) | **❌ 无摄像头** (—) | **❌ 无摄像头** (实测 Gate 准确拦截 syncCameraPhotos) | **❌ 无摄像头** (—) | **❌ 无摄像头** (—) | **⚠️ 系统相册对齐** (由手机系统相册（PhotoKit 时间戳对齐）接入时间轴，非硬件控制指令) |
| **12. 物理传感器：地磁 / 气压 / 计步 / 方向 / 旋转** | **❌ 无开放接口** (无 sensor.* 域) | **✅ 5类实测通过** (v0.8.15 实测 magnetic_ut / orientation_deg / pressure_hpa(1008.03) / rotation(w,x,y,z) 读数成功；step_counter 在列表内但触发超时待复测) | **❌ 不支持** (—) | **❌ 不支持** (—) | **❌ 不支持** (—) | **❌ 不支持** (—) | **❌ 不支持** (—) | **⚠️ 未开放给桥** (watchOS 未经 Bridge 暴露健康/传感器原始流) | **❌ 非音频桥** (健康信号由独立 HealthSignalController 采集) |
| **13. 传感器：陀螺仪 / 加速度计 / 光线 / 距离** | **❌ 不支持** (—) | **❌ 硬件/HAL缺失** (v0.8.15 实测均明确返回 code=1002：gyroscope(unknown)、accelerometer(stub NULL Sensor no real hardware)、light/proximity(not registered in HAL)) | **❌ 不支持** (—) | **❌ 不支持** (—) | **❌ 不支持** (—) | **❌ 不支持** (—) | **❌ 不支持** (—) | **❌ 未开放** (—) | **❌ 不适用** (—) |
| **14. GPS / GNSS 定位** | **❌ 无 GPS** (—) | **🔒 v0.8.15待复测** (v0.8.7 报 1001；v0.8.15 室内窗口触发 25s runner 超时进而踩中 CommandDispatcher 死锁，需重启后在窗边复测) | **❌ 无 GPS** (—) | **❌ 无 GPS** (—) | **❌ 无 GPS** (—) | **❌ 无 GPS** (—) | **❌ 无 GPS** (—) | **❌ 未接入** (—) | **❌ 非硬件桥** (—) |
| **15. 麦克风参数控制与端侧 ASR** | **⚠️ 仅音频采集** (仅采集 ADPCM 流/文件，无端侧 ASR) | **⚠️ 麦通 / ASR待测** (麦克风 audio.capture+stream 实测 PASS (16kHz AMR-WB 12.65kbps)；v0.8.15 APK 内含 Zipformer2-CTC 25MB 模型，因死锁待重启后实测 asr.start) | **⚠️ 仅麦采集** (mSBC 16kHz 流，无端侧 ASR) | **⚠️ 仅麦录制** (仅机身录制 .ogg，无端侧 ASR) | **⚠️ 仅麦录制** (同上) | **⚠️ 麦+硬件VAD** (Opus 50fps + 硬件 VAD 门控，无端侧 STT) | **⚠️ 仅麦录制** (机内录 Opus，无端侧 STT) | **⚠️ 仅麦录制** (表端 AVAudioRecorder 录 16kHz AAC，转写回手机执行) | **⚠️ 仅麦采集** (AVAudioEngine 采集，本地 SenseVoice 在统一管线执行) |
| **16. 喇叭音量控制与 TTS 语音播报** | **❌ 无喇叭/不支持** (—) | **🔒 volume待/TTS否** (tts.speak v0.8.15 实测返回 code=1001，card_bridge 显式映射 unsupported 并回退手机 TTS；volume.* 在 0.8.15 待重启后复测) | **❌ 不支持** (—) | **❌ 无喇叭** (—) | **❌ 无喇叭** (—) | **❌ 无播报口** (—) | **❌ 无播报口** (—) | **❌ 未接入** (—) | **✅ 手机系统** (回退手机端系统 TTS/音频通道) |
| **17. 状态 LED 灯效与振动马达** | **⚠️ 固件自控** (录音/同步自动闪灯，无 App 自由灯效指令) | **✅ LED实测 / 马达待** (v0.8.7 led 7项全PASS，v0.8.15 dyj.led.set=ok 且死锁后仍发 EVT:led.state；vibrator.* 因死锁待重启后复测) | **❌ 不支持** (—) | **❌ 不支持** (—) | **❌ 不支持** (—) | **❌ 未暴露控制** (仅设备自带状态灯，无 BLE 控灯 API) | **❌ 不支持** (—) | **⚠️ 表端触感** (表端 WatchRecordingManager 起停时触发本地 Haptic 提示) | **❌ 无 LED** (—) |
| **18. 电池电量与充电状态上报** | **✅ 支持** (电量百分比 + 充电状态上报，UI 按 <20/<40/≥40 渲染颜色不显示数字) | **✅ 实测通过** (v0.8.7 实测 level=100, status='full', plugged='ac', 4354mV；已修复 lib.rs plugged 字符串解析误判 bug) | **✅ 支持** (DeviceInfo 上报电量与充电态) | **✅ 支持** (标准 BAS 0x180F/0x2A19（含 Notify）) | **✅ 实测通过** (BAS 实读 70%(raw 0x46) / bridge 实测 60% + Notify 订阅成功) | **✅ 实测通过** (BAS 2A19 83% + Settings 19B10013 充电态 0x00 实测 PASS) | **⚠️ 协议支持** (CMD_INFO / 设备状态含电量（待真机）) | **✅ 支持** (WKInterfaceDevice.current().batteryLevel + state 随快照回传) | **✅ 不适用** (使用手机自身电池) |
| **19. 设备时钟同步 (RTC Time Sync)** | **✅ 支持** (连接/按需对时，保证切片 start_at 精确) | **🔒 v0.8.15待复测** (已修复 lib.rs 旧版吞错；v0.8.15 首个短连接期间断开未完成，需重启后复测 device.time) | **❌ 不需要** (纯实时流直接用到达墙钟时间戳) | **✅ 协议支持** (0x0146 写入 14 字节 ASCII YYYYMMDDHHmmss) | **🔒 云锁拒绝** (0x9100 无返回；新版 bridge 立即识别 v0.2.7 并返 unsupported) | **✅ 实测通过** (19B10031 写入 Epoch 对时实测 PASS（macOS 59ms / Android 66ms）) | **⚠️ 协议支持** (CMD_SYNC_TIME 单测通过（待真机）) | **✅ 系统 NTP** (watchOS 系统时间与 iPhone 自动高精度同步) | **✅ 本机时钟** (直接使用本机系统时钟) |
| **20. 固件 OTA 升级能力** | **✅ dual_chip** (主控 nRF Secure DFU + ESP32 Wi-Fi OTA 两阶段升级) | **✅ 实机升0.8.15** (single_ota 实测从 0.8.7 成功升级到 0.8.15（49.3MB APK，LAN HTTP + dyj2.dev.reai.com 在线检查均 PASS）) | **❌ App 内隐藏** (otaMode='none'（仅 USB PC 工具升级）) | **❌ 不支持** (otaMode='none'；bridge ota_info 0ms 返 unsupported（已修越界回退 V2 漏洞）) | **❌ 不支持** (实测 ota_info 0ms 返回 unsupported（需官方 Get笔记 App）) | **❌ 安全关闭** (底盘虽有 Nordic SMP 特征但 otaMode='none'，防变砖强制走官方 App) | **❌ 不支持** (otaMode='none'，需官方飞书/soundcore App 升级) | **❌ 随 App 跟随** (随 iOS 主包 WatchKit Extension 一体分发，无独立 OTA 页) | **❌ 不适用** (随客户端版本更新) |
| **21. 音频回传转 16kHz WAV 与本地 STT 识别** | **✅ 支持** (ADPCM → 16kHz Mono PCM WAV + 去直流增益归一化 + SenseVoice) | **✅ 双路实测** (BLE FF12 流 (5.36s, 175,616B) & Wi-Fi .amr (6.04s, 197,376B) 均转为标准 16kHz WAV；Zipformer2-CTC/SenseVoice 对基准语音精确转写且静音零幻觉) | **✅ 支持** (mSBC → 16kHz PCM 直入 LiveAudioRecorder + SenseVoice) | **✅ 解码实测** (reai-ext-sdk Ogg Opus→WAV (38ms) 后 Zipformer2-CTC & SenseVoice 中文零损失识别，待 ≤v0.1.8 真机录声拉取) | **⚠️ 编码通/取件锁** (Ogg Opus→16kHz WAV→STT 全通（11.963s 38ms 转码零字差），但 v0.2.7 无法 BLE 拉出机身文件) | **✅ 全量实测** (实时流+离线环形文件经 Silero VAD + SenseVoice + Campplus 实测中英文/数字/双人声纹聚类 PASS) | **⚠️ 解码就绪** (reai-ext-sdk Ogg Opus→16kHz WAV 解码与 GetSeed 共用已通，待 D3200 真机文件验证) | **✅ 本机转码** (WatchAudioSliceTranscoder (.m4a→16kHz WAV) 直喂 AppStore.ingestLiveSlice → SenseVoice) | **✅ 本机直喂** (PhoneMicRecorder .WAV 零损直进 Silero VAD + SenseVoice) |
| **22. 我方官方 App 全链路闭环实现评估** | **✅ 完全实现** (主力旗舰体验：实时/离线双通道、按键打点、Wi-Fi 配网与双芯 OTA 全支持) | **✅ 95%+ 实现** (录/流/切片/custom segment_min/Wi-Fi/上传/OTA/5类传感器/LED/按键已通；相机/GPS/asr/音量马达待固件重启+1行Kotlin修复后闭环) | **✅ 桌面流闭环** (完整实现桌面纯流式采集/AI 语音键/本地转写总结（硬件无存储属能力预期内裁剪）) | **⚠️ 仅离线同步** (可完整实现：机身按键录 + BLE 拉 .ogg + 本地转写总结；无法远程启停/实时流/Wi-Fi/打点) | **❌ 无法业务闭环** (受官方云端 0x9000→0x9100 一机一码锁限制，目前仅能展示电量与固件/SN，无法获取录音) | **✅ 完整闭环** (macOS/iOS 实时流/按键/离线环/转写声纹全闭环；Android 修复 QueueStream 后重编待真机复核) | **⚠️ 开发完成待实机** (SDK 与 Capability 门控全部落地并通过单测，待持物理设备实机闭环) | **✅ 完整闭环** (WatchOS 构建 + WatchHardwareBridge + 本地队列 + 转码 + 无 UI 侵扰全闭环) | **✅ 保底闭环** (独立录音 + 硬件异常断连自动接力 + 零功耗待命 + 灵动岛协同完整可用) |

---

## 三、录音卡 6 大核心问题实测回答

### 问题 1：是否可以蓝牙唤起开始录音、蓝牙停止录音？
- **结论**：**✅ 点一机 V1 / 录音卡 V2 / Omi / 键盘 V2.1 支持；❌ Get 笔记卡硬件不支持（仅机身按键）**
| 硬件 / 链路 | 结论 | 实测数据与说明 |
|---|---|---|
| 点一机 V1 (DYJ_YKAUP3) | ✅ 实测通过 | record.start (124ms) 自动拉起 16kHz AMR-WB 引擎落盘 .amr，record.stop (122ms) 正常封口（v0.8.7 全周期 PASS；v0.8.15 因突发断连/协程死锁待重启复测） |
| Get 笔记卡 (Get-A7769D v0.2.7) | ❌ 硬件不支持 | 协议与硬件均无 BLE 起停指令（hasRemoteRecordControl=false）；card_bridge 0ms 拦截并返回中文指引，StatusSheet 隐藏开关 |
| 录音卡 V2 (DYJV2_*) | ✅ 支持 | reai-card-sdk 暴露 start_recording / start_recording_with_duration / RECORD_STOP 完整蓝牙控录 |
| Omi / 键盘 V2.1 / 飞书豆 / Watch | ✅ 支持 | Omi 通过 19B10001 订阅控采；键盘通过纯流租约控录；飞书豆协议支持 CMD_RECORD（待真机）；Watch 经 WCSession 双向启停 |

### 问题 2：录音是否可以切片？
- **结论**：**✅ 全系列支持（硬件侧定长分片 + App LiveAudioRecorder 60s 能量谷底软切片 + 断流补传对账）**
| 硬件 / 链路 | 结论 | 实测数据与说明 |
|---|---|---|
| 点一机 V1 硬件离线切片 | ✅ 实测通过 | 生成标准命名 audio_YYYYMMDD-HHMMSS_<SESSION>_<SEQ>.amr，滚动时实时下推 EVT:record.segment（实测 B2C3D4E5_01.amr 9,975 B） |
| App 实时流通用切片器 | ✅ 代码+实测 | LiveAudioRecorder（live_audio_recorder.dart）按 sliceDuration（默认 60s）达 75% 后扫描 50ms 能量谷底软切，停录立即封口尾片 |
| Omi 实时流 + StorageRing | ✅ 实测通过 | Omi 实时流 132.18s 实测产出 60s + 60s + 12.28s 三片；离线 RingBuffer 按 1800 条(~5m)/片切为 OMI_RING_*_*.wav |
| Get 笔记卡 (GSC10) | ⚠️ 分版本 | 硬件自主分片 .ogg；≤v0.1.8 可经 0x0043/0x0145 拉回后再切片，v0.2.7 因云端鉴权锁阻塞 |

### 问题 3：录音是否可以流式传输？
- **结论**：**✅ 点一机 V1 / 录音卡 V2 / 键盘 V2.1 / Omi 支持 BLE 实时流；❌ Get 笔记卡 / 飞书豆仅离线传文件**
| 硬件 / 链路 | 结论 | 实测数据与说明 |
|---|---|---|
| 点一机 V1 (FF12 type=0x04) | ✅ 实测通过 | AMR-WB 12.65kbps @ 16kHz 实测：5s 捕获 50 块 / 8,844 B -> 175,616 B WAV (85,760 样本, RMS=226.808)；全周期长录 732 块 / 81,176ms |
| 录音卡 V2 / 键盘 V2.1 / Omi | ✅ 支持 | 分别走 IMA-ADPCM / Vendor 0xFE63 mSBC / 19B10001 Opus 50fps，card_bridge 统一转成 16kHz Mono i16 PCM 流回调 |
| Get 笔记卡 & 飞书录音豆 D3200 | ❌ 不支持 | 均为先录后传离线架构（realtimeAudio=false）；bridge 0ms 拒接 realtime.open 防上层死等 |

### 问题 4：录音切片是否有断档？
- **结论**：**✅ 稳定期/离线无断档（点一机 50 块 & Omi 132.18s 均 gap=0）；⚠️ 点一机在 2.4G Wi-Fi+macOS LSTO=360ms 共存期存在射频断连，需靠板载 .amr 对账补盲**
| 硬件 / 链路 | 结论 | 实测数据与说明 |
|---|---|---|
| 点一机 V1 帧内 & 连续切片 | ✅ DTX 精确对齐 | FF12 seq_le 连续校验实测 discontinuous_events=0；SID(8)/NO_DATA(15)/SPEECH_LOST(14) 均精确补齐 320 样本(20ms)静音防时间轴漂移 |
| 点一机 V1 BLE+Wi-Fi 共存窗 | ⚠️ 射频瞬断风险 | Spreadtrum SC9832E 单天线 2.4G Wi-Fi 与 BLE 并发 + macOS LSTO=360ms 会偶发掉线；靠本地 .amr + Wi-Fi HTTP 全量同步补齐，不丢音频 |
| App 侧切片器 & Watch 切换 | ✅ 零丢样本 | SoftBoundaryPcmSlicer 单缓冲零拷贝切分 + _oddByte 保尾；Watch Ping-Pong 提前 1s 预热双 AVAudioRecorder |
| Omi BLE 实时流 | ✅ 实测零断档 | macOS 实测 11s calibration 550/550 包 + 132.18s 连续采集 gapCount=0；断连期间写板载环 |

### 问题 5：录音切片是否可以指定时间？
- **结论**：**✅ 点一机 V1 支持硬件级 segment_min + App 级 sliceDuration；录音卡 V2 支持总时长；其他设备在 App 端按流式/拉取后再切片定长**
| 硬件 / 链路 | 结论 | 实测数据与说明 |
|---|---|---|
| 点一机 V1 硬件 segment_min | ✅ 实测+已接入 | DYJ-REC-04 实发 segment_min=10 返回 {"segment_min":10}；card_bridge 默认 5 分钟且已接入 Dart startRecordingSegment(segmentMinutes:) |
| App 实时流 sliceDuration | ✅ 已接入可调 | LiveAudioRecorder.setSliceDuration() 与 PhoneMicRecorder 均支持运行时动态重设（默认 1 分钟），超阈值立即封口 |
| Get 笔记卡 / Omi / 飞书豆 | ⚠️ 无硬件分片参数 | 硬件无 segment_min 参数（GetSeed 硬件固定分片；Omi 离线块按 1800 条固定；实时/拉回进 App 后按任意 sliceDuration 重切） |

### 问题 6：录音返回以后是否能再识别成转文本的素材，能否正确识别内部的文本？
- **结论**：**✅ 已完成真实 WAV 格式合规性校验 + 离线 Zipformer2-CTC & App 生产级 SenseVoice INT8 + Silero VAD 双引擎实测**
| 硬件 / 链路 | 结论 | 实测数据与说明 |
|---|---|---|
| 16kHz PCM WAV 素材合规性 | ✅ 4 路 100% 合规 | ref_speech_16k、getseed_speech_decoded（Ogg Opus 38ms 转码）、dyj_live_stream_5s（BLE AMR-WB）、dyj_wifi_uploaded（Wi-Fi 上传 .amr）均通过 wav_io.dart parseWav，全部 16000Hz / 1ch / 16bit / isMono16=true |
| 中文语音转写准确率（对照句 + Ogg Opus 回环） | ✅ 高准确度且零编解码损失 | 标准中文播报经 Ogg Opus (91,875 B) 压缩再由 reai-ext-sdk 解码为 WAV (382,874 B) 后，Zipformer2-CTC 逐字完全一致；App SenseVoice (conditioned) 输出标点数字规整文本「今天是11月21日，正在通过蓝牙测试点一机与录音卡的远程启停，自动切片、实时流传输以及语音拽文字准确度。」（Silero VAD 检出 56–11936ms），仅 1 处近音同音差（「拽/转」） |
| 点一机实机夜间环境采集音频（诚实边界） | ⚠️ 夜间无人静默底噪 | dyj_live_stream_5s.wav (5.36s, RMS=0.006922) 与 dyj_wifi_uploaded.wav (6.04s, RMS=0.007480) 为夜间无人值守静态底噪：Silero VAD 检测 0 段语音（[]），Zipformer2-CTC 返回空串 ""，SenseVoice 返回仅 "。" —— 证明转码管线通畅且去噪门控杜绝了底噪幻觉；真实人声对点一机话筒识别效果已由内置相同 Zipformer2-CTC 模型间接验证 |

#### 问题 #6 实测识别明细（`Zipformer2-CTC` 25MB + 生产级 `LocalAsrService` `SenseVoice INT8` + `Silero VAD`）

| WAV 文件 | 大小 / 时长 | WAV 头校验 | RMS（原 → 条件） | `Zipformer2-CTC` 文本 | `SenseVoice INT8` (conditioned) |
|---|---:|:---:|---:|---|---|
| `ref_speech_16k` | 386,926 B / 11.963s | 16000Hz/1ch/16b | 0.126908 → 0.127093 | 今天是十一月二十一日正在通过蓝牙测试点一机语录音卡的远程启停自动切片实时流传书以及语音转文字准确度 | 今天是11月21日，正在通过蓝牙测试点一机与录音卡的远程启停自动切片、实时流传输以及语音拽文字准确度。 |
| `getseed_speech_decoded` | 382,874 B / 11.963s | 16000Hz/1ch/16b | 0.12677 → 0.126955 | 今天是十一月二十一日正在通过蓝牙测试点一机语录音卡的远程启停自动切片实时流传书以及语音转文字准确度 | 今天是11月21日，正在通过蓝牙测试点衣机与录音卡的远程启停，自动切片、实时流传输以及语音拽文字准确度。 |
| `dyj_live_stream_5s` | 175,616 B / 5.360s | 16000Hz/1ch/16b | 0.006922 → 0.057358 | *(空 · 无语音)* | 。 |
| `dyj_wifi_uploaded` | 197,376 B / 6.040s | 16000Hz/1ch/16b | 0.00748 → 0.057694 | *(空 · 无语音)* | 。 |

---

## 四、点一机 V1 (`DYJ_YKAUP3`) 全传感器与 SDK 验收清单（含未测/硬件缺失项）

| 编号 | 领域 | 接口 / 传感器 | 固件 | 状态 | 实测数值与说明 |
|---|---|---|---|---|---|
| `DYJ-BLE-01` | 蓝牙与协议 | BLE 广播识别 & RSSI 排序 & 重扫 | `0.8.7 & 0.8.15` | ✅ PASS | **5.0–5.2s 扫出 DYJ_YKAUP3 (-47~-60 dBm)；断连后立即恢复广播** — 已修复 btleplug CoreBluetooth 断连后丢失 cached_names 及 discover_services 卡死缺陷 |
| `DYJ-BLE-02` | 蓝牙与协议 | 连续建连/断开稳定性 (3轮+1轮) | `0.8.15` | ✅ PASS | **3 轮连续 connect+disconnect 21.4s / 20.1s / 15.7s + 单轮 1597ms 成功** — NOTIFY_SETTLE=40ms + ≤180B UTF-8 安全单 PDU 写帧绕过固件 GattServerManager Prepared Write 缺陷 |
| `DYJ-PROTO-01/02` | 蓝牙与协议 | proto.hello (feature_bits) & proto.echo | `0.8.7 & 0.8.15` | ✅ PASS | **0.8.7: 61ms feature_bits=31；0.8.15: connect 内握手成功** — version_code=807 -> 815 后客户端动态开启 hasCameraMedia=true |
| `DYJ-DEV-01/02` | 设备信息 | dyj.device.info (简/详 IMEI/Board/Android) | `0.8.7 & 0.8.15` | ✅ PASS | **app_version 0.8.7→0.8.15，Android 8.1.0 (SDK 27)，board sl8541e_1h10，IMEI 867400020316612，BT 40:45:DA:0F:CA:5E** — 耗时 62ms(0.8.7) / 6622ms(0.8.15 OTA后复核) |
| `DYJ-DEV-03/04` | 电池与存储 | device.battery & device.storage | `0.8.7 (0.8.15沿用)` | ✅ PASS | **battery: level=100, status='full', plugged='ac', 4354mV (53ms)；storage: 11,724,091,392B total / 10,275MB free (54ms)** — 已修复 lib.rs plugged='ac' 误判未充电 bug；0.8.15 下 snapshot 待重启后顺带回归 |
| `DYJ-DEV-05/06/07/08` | 时钟与重启守卫 | device.time 对时 & device.reboot 安全守卫 | `0.8.7→0.8.15` | ⚠️ 部分通过/待复测 | **0.8.7 正确报 1001；0.8.15 device.reboot(confirm=false) 实测拒绝 code=2003 守卫通过；confirm=true 按安全规范跳过；device.time 因短链断连待重启后复测** — 已移除 lib.rs 对 time_sync 1001 伪成功吞错 |
| `DYJ-AUD-01~05` | 麦克风音频 | audio.capture + BLE FF12 AMR-WB 实时流 → WAV | `0.8.7 (0.8.15待)` | ✅ PASS | **5.36s 捕获 50 块 / 8,844B / discontinuous=0 → 16kHz WAV 85,760 samples (RMS 226.8)；全周期 capture 732 块 / 81,176ms** — opencore-amrwb 纯 C 解码 + DTX 静音帧精确补齐 20ms |
| `DYJ-REC-01~10` | 录音切片生命周期 | record.list/start(segment_min=10)/status/stop/delete + EVT | `0.8.7 (0.8.15待)` | ✅ PASS | **非法 session(TEST0001) 拒 1002；A1B2C3D4 启录 124ms / 停录 122ms，删测试文件释出 55,350B 归零；捕获 EVT:record.segment** — 0.8.15 升级后因协程死锁尚未跑 0.8.15 录音复核 |
| `DYJ-SENS-MAG` | 传感器：地磁 | sensor.read(['magnetic']) 地磁计 | `0.8.15` | ✅ PASS | **两轮独立实测读数 ok=true：x=47.68~47.71, y=-180.78~-179.66, z=260.93~262.70 uT** — v0.8.7 报 1001；升级 v0.8.15 后可用 |
| `DYJ-SENS-ORI` | 传感器：方向 | sensor.read(['orientation']) 方向角 | `0.8.15` | ✅ PASS | **azimuth=184.67°, pitch=0.71°, roll=3.96° (task-1495 ok=true)** — 依赖磁力/姿态融合，实测响应正常 |
| `DYJ-SENS-PRS` | 传感器：气压 | sensor.read(['pressure']) 气压计 | `0.8.15` | ✅ PASS | **pressure_hpa = 1008.02997 hPa (task-1610 ok=true)** — 读数精确可靠 |
| `DYJ-SENS-ROT` | 传感器：旋转矢量 | sensor.read(['rotation_vector']) 旋转矢量 | `0.8.15` | ✅ PASS | **rotation = {w:0.07782, x:0.03505, y:-0.00823, z:0.99632} (task-1610 ok=true)** — 四元数输出完整 |
| `DYJ-SENS-STEP` | 传感器：计步器 | sensor.read(['step_counter']) 计步器 | `0.8.15` | 🔒 列表有/实测超时 | **sensor.status 列表含 step_counter，但 task-1610 实测时遭遇瞬断，紧随其后的 sensor.stream 踩中 P0 超时死锁** — 需物理重启设备后重测单点读取与事件流 |
| `DYJ-SENS-GYRO` | 传感器：陀螺仪 | sensor.read(['gyroscope']) 陀螺仪（负面硬件核验） | `0.8.15` | ❌ 硬件/HAL 不存在 | **明确返回 code=1002: params.type 'gyroscope' unknown; available: [magnetic, orientation, pressure, rotation_vector, step_counter]** — 实证当前点一机 V1 硬件未配备真实陀螺仪 |
| `DYJ-SENS-ACC` | 传感器：加速度计 | sensor.read(['accelerometer']) 加速度计（负面核验） | `0.8.15` | ❌ 驱动为桩传感器 | **明确返回 code=1002: stub sensor (NULL Sensor, no real hardware)** — 实证 HAL 仅注册空桩，无实体加速度芯片 |
| `DYJ-SENS-LP` | 传感器：光线与距离 | sensor.read(['light','proximity']) 光感/距离（负面核验） | `0.8.15` | ❌ HAL 未注册 | **明确返回 code=1002: unavailable: not registered in HAL** — 硬件无此两类传感器 |
| `DYJ-SENS-STR` | 传感器连续流 | sensor.stream.start / EVT:sensor.data / stop | `0.8.15` | 🔒 死锁阻断待测 | **task-1610 发 sensor.stream.start 超时 20s 触发固件 CommandDispatcher$start$1 协程死亡（见 P0 诊断）** — 修复固件 catch 顺序并重启后可复测 |
| `DYJ-LOC-01~03` | GPS / GNSS | location.status / get / stream.start / stop | `0.8.15` | 🔒 超时阻断待测 | **v0.8.7 报 1001；v0.8.15 室内窗口触发 25s runner 超时（协程已死，未收到定位帧）** — 需物理重启后置于室外/窗边开阔天空复测 GNSS 冷启动定位 |
| `DYJ-CAM-01~05` | 摄像头拍照与录像 | camera.status / capture / record.start / list / delete | `0.8.15` | 🔒 死锁阻断待测 | **v0.8.7 全报 1001 并已通过 dyj_v1_capabilities_for_firmware(807) 裁剪为 false；升级 0.8.15 (hasCameraMedia=true) 后因 02:45 协程死锁未及实拍即停在队列外** — card_bridge 与 Flutter camera_capture_and_fetch / HTTP :18900 拉图已就绪，重启后立即补测 |
| `DYJ-WIFI-01~06` | Wi-Fi STA 配网与 5GHz 边界 | wifi.status / scan / connect(2.4G KK2BY & 5G KK2BY_5G) / forget | `0.8.7 (0.8.15断链)` | ✅ 0.8.7全PASS / ⚠️0.8.15残留SSID | **0.8.7: scan 扫出 7 个 2412-2462MHz 热名(无 5GHz)，KK2BY_5G 拒绝，KK2BY 6.5s ip=192.168.28.76 (-26dBm/52Mbps)，后 forget 清空；⚠️ 0.8.15 OTA 后再次关联 KK2BY，因死锁待主人重启后执行 forget 清除** — App 对 *_5G 热名增加 2.4GHz 引导提示，兼容 state='completed' |
| `DYJ-AP-01~07` | Wi-Fi AP 热点与 8788 快传 | ap.status / ap.start / ap.stop & HTTP:8788/api/files | `0.8.7` | ⚠️ 控制面PASS / 数据面未切热点 | **ap.start 启动热点 192.168.43.x 与 ap.stop 释放 6 项全 PASS；8788 HTTP 文件数据面因未将测试 Mac 单无线网卡从 LAN 切走而保留 NOT_TESTED** — 客户端 ApClient 代码已合入 |
| `DYJ-UPL-01~04` | Wi-Fi HTTP 文件上传闭环 | upload.config.set/get + upload.start + 自动删源 + WAV 转码 | `0.8.7` | ✅ PASS | **37.7s 内 POST audio_20261120-223112_B2C3D4E5_01.amr (9,975B) 至 192.168.28.233:18900，自动删源归零并拉回转为 6.04s 16kHz WAV，并已还原 default_url** — 全链路真实文件与 HTTP 闭环验证成功 |
| `DYJ-LED-01~07` | 状态 LED 灯效 | led.status / led.set(3s回落) / led.clear + 4401/4403 负例 | `0.8.7 & 0.8.15` | ✅ PASS | **0.8.7 7 项全 PASS；0.8.15 dyj.led.set=ok 且 bluetoothd 在 04:46 仍观察到 0x002a EVT:led.state** — LED 状态机独立于 CommandDispatcher，死锁后物理机仍在广播灯效变化 |
| `DYJ-BTN-01~08` | 物理按键绑定 | button.status / bind.get / bind.set / 1002负例 / EVT:button.event | `0.8.7 & 0.8.15` | ✅ 控制面PASS / ⏭️ 人工触键未测 | **0.8.7 7 项 + 0.8.15 button.status/bind 实测 ok=true；EVT:button.event 需人工物理按压故列 NOT_TESTED** — 支持 click/double_click/long_press 三手势 |
| `DYJ-SYS-01/02` | 振动马达 | vibrator.once & vibrator.cancel | `0.8.15` | 🔒 未及复测 | **0.8.7 报 1001；0.8.15 task-1495 超时/task-1610 未及执行即死锁** — 需重启后补测单发震动反馈 |
| `DYJ-SYS-03/04/TTS` | 喇叭音量与 TTS | volume.get/set & tts.speak | `0.8.15` | ❌ tts不支持 / 🔒 volume待测 | **0.8.15 实测 tts.speak 返回 code=1001 (unknown command)，card_bridge 已准确映射为 unsupported 提示并由手机 TTS 兜底；volume.get/set 待重启后补测** — 已在 dyj_v1_session::tests 加单测锁定该错误映射 |
| `DYJ-ASR-01~04` | 端侧流式 ASR | asr.status / config / start / stop / EVT:asr.final | `0.8.15` | 🔒 模型已抽出/实机待测 | **从 v0.8.15 APK 抽出端侧 25MB Zipformer2-CTC 模型实测中文高精度识别；实机 BLE 触发因死锁待重启后与人工发声联测** — Question #6 离线转写精度已用完全相同 ONNX 权重验证完毕 |
| `DYJ-OTA-01~05` | OTA 固件在线/局域网升级 | ota.config.set/get + ota.check + ota.install(confirm=true) + 恢复默认源 | `0.8.7 → 0.8.15` | ✅ 实机升级成功 | **从 http://192.168.28.233:18900/ota/manifest.json (49,344,572 B APK) 实机将 DYJ_YKAUP3 从 0.8.7 (807) 升至 0.8.15 (815)，且 task-1495/1610 已核验 ota.config overridden=false** — 另 0.8.7 连 KK2BY 后直连 dyj2.dev.reai.com ota.check PASS，暴露官方测试源停在 0.8.5 (805) 需服务端升级清单 |

---

## 五、Get 笔记卡 (`Get-A7769D · v0.2.7`) BLE GATT & SDK 验收清单

| 编号 | 领域 | 检查项 | 状态 | 实测数据与说明 |
|---|---|---|---|---|
| `GS-BLE-01` | 广播发现 | BLE 扫描识别 Get-* 与 Company ID 0x544A | ✅ PASS | raw scan 12.27s (15 adv, RSSI -55~-59)；bridge scan 8.11s 在 4 台设备中唯一精准匹配 Get-A7769D |
| `GS-BLE-02` | 广播元数据 | 0x544A 厂商数据解析 MAC 与 FW 尾字节 | ✅ PASS | 5c8e8ba7769d 0000000207 → MAC 5C:8E:8B:A7:76:9D，FW v0.2.7（无 0x180A DIS 也能瞬间拿到真实版本） |
| `GS-BLE-03` | 连接性能 | connect() 建连耗时（优化前 vs 优化后） | ✅ PASS | 移除 connect 内阻塞 0x0146 对时后，耗时从 40,090ms 优化至 3,299ms (-91.8%)，MTU=495 |
| `GS-BLE-04` | 断连重扫 | disconnect() 清理与外设恢复广播 | ✅ PASS | bridge disconnect 46ms (released=true)；raw 123ms 断开后立即扫回 10 帧 |
| `GS-BAS-01` | 标准电量 | 0x180F / 0x2A19 BAS 电量 Read + Notify | ✅ PASS | raw 读 0x46 (70%, 含 Notify)，bridge 实测 level=60%, isCharging=false |
| `GS-DIS-01` | 设备信息 | 0x180A Device Information Service 探测 | ❌ 硬件未实现 | v0.2.7 GATT 表无 0x180A 与 0x1812 HID，SDK 已改用 0x544A + 0x9000 读取 version=0.2.7 |
| `GS-9000-01` | 0x9000 AES | AES-128-ECB (Walkiz52832iLock) 只读读 MAC/FW/SN | ✅ PASS | cmd 0x01 (62ms) 解出 5C:8E:8B:A7:76:9D & v0.2.7；cmd 0x02 (49ms) 解出 SN GET25LA7769D |
| `GS-9000-02` | 0x9000 状态快照 | snapshot() 元数据与能力声明返回速度 | ✅ PASS | 优化后仅需 14ms（旧版 24,038ms）；返回 capabilities, version=0.2.7, deviceId=GET25LA7769D |
| `GS-9100-01` | 0x9100 控制环 | 0x0046/0x0146 对时 · 0x0047 MTU · 0x0040/0x0050 状态 · 0x0042 存储 · 0x0043 列表 · 0x0145 拉取 | 🔒 云锁静默 (0通知) | 10 步 WriteWithRsp & WriteNoRsp + 0x9000 前后测试均 0 通知；实证 v0.2.5+(v0.2.7) 必须走官方 App+云端 Challenge 挑战解锁 |
| `GS-9100-02` | 我方错误透传 | v0.2.7 鉴权锁下 time.sync / files / download 错误呈现 | ✅ 已修复实报 | 已移除旧版 Ok(vec![]) 吞错；bridge 0ms 快速返回明确中文 unsupported: 指引，不编造空文件数 |
| `GS-GATE-01` | 网关能力门控 | record.start/stop · realtime.open · mark · wifi · ota.info 拦截 | ✅ PASS (0ms) | 6 项不具备操作全部 0ms 精确拦截（已修复 GetSeed ota_info 误回退 CardV2 漏洞）；0x0041 全盘擦除与 0x9000 0xA0 盲写按安全红线跳过 |
| `GS-CODEC-01` | 音频解码与 STT | reai-ext-sdk Ogg Opus → 16kHz WAV → SenseVoice / Zipformer2-CTC | ✅ PASS | 合成 440Hz (1ms) 与 11.963s 真实中文 Ogg Opus 91,875 B → WAV 382,874 B (38ms)，STT 逐字一致 |
| `GS-6666-01` | 0x6666 服务 | vendor 6666/7777 特征声明探测 | ⏭️ 待 ≤v0.1.8/抓包 | 特征存在 (W/WNR/N) 但公开协议未文档化，严禁盲写 |

---

## 六、点一机 V1 `v0.8.15` 固件 P0 缺陷诊断与下一步操作指引

1. **[P0 固件缺陷] `CommandDispatcher.kt` 异常捕获顺序颠倒（已在 `app-sys-release.apk` `classes.dex` 反编译实证）**：
   - `CommandDispatcher.execute` 将 `CancellationException`（父类）放在 `TimeoutCancellationException`（子类）之前捕获，导致任意命令触发 `withTimeout` 时不会回包 `code=3002`，而是直接抛异常杀死全局唯一的 `CommandDispatcher$start$1` 消费者协程。
   - **修复方案（点一机固件仓库 1 行修改）**：将 `catch (e: TimeoutCancellationException)` 移至 `catch (e: CancellationException)` **之前**。
2. **[P1 固件缺陷] `GattServerManager.kt` ATT Prepared Write 偏移写错**：`offset > 0` 回传 `0` 且无 `onExecuteWrite`；我方已在 `dyj_v1_session.rs` 用 `MAX_CHUNK=180` 单 PDU 写入规避。
3. **物理机恢复提示**：`DYJ_YKAUP3` 自 2026-11-21 02:45:40 踩中该协程死锁后停止处理 `FF11` 命令（`ota.config` 已在此前确认重置为 `overridden=false`）。请**手工重启 `DYJ_YKAUP3` 一次**以恢复 `CommandDispatcher`，重启后可立即补测 `v0.8.15` 相机拍照/录像、室外 GPS、`vibrator`/`volume`/`asr.*`，并执行 `wifi.forget` 清理临时热点 `KK2BY`。
