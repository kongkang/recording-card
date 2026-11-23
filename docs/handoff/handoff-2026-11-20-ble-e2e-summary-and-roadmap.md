# 双硬件（Get 笔记卡 & 点一机 V1）端到端 BLE / Wi-Fi / SDK 实测总结与研发任务路线图

- **测试时间**：2026-11-19 ~ 2026-11-20
- **测试环境**：macOS `Darwin 24.6.0 x86_64`（CoreBluetooth Host，LAN `192.168.28.233`）、`card_bridge/0.2.0` (`card-v2/0.0.8 dyj-v1/0.1 board-v21/0.3 getseed/0.1 omi/0.1`)
- **上游协议对照基线**：
  - `Shawn-TKD/getseed-ble-protocol` (`HEAD c42918a + Issue #4`)
  - `andyhuo520/beanpod` (`GETSEED.md + GetSeed.swift`)
  - `ReAI-com/dyj-v1-sdk` (`v0.1.14 @ f691ef58`)
- **完整交互式 HTML 测试报告**：[ble-e2e-test-report-2026-11-19.html](../reports/ble-e2e-test-report-2026-11-19.html)（单文件内联 CSS/JS/SVG，`249,383 B`，可离线 `file://` 直接打开筛选与展开 119 项原始请求/响应）

---

## 一、全量测试计分板（含已实测 + 未测但协议/硬件具备的功能）

| 设备 | 总清单 | 已实测 | 未实测(含阻断/跳过) | `PASS` | `FAIL` | `BLOCKED` | `NOT_TESTED` | `SKIPPED_SAFETY` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **合计** | **119** | **105** | **14** | **71** | **34** | **2** | **8** | **4** |
| **Get 笔记卡** (`Get-A7769D` · GSC10 · `v0.2.7`) | 29 | 24 | 5 | 11 | 13 | 1 | 2 | 2 |
| **点一机 V1** (`DYJ_YKAUP3` · `dyj_v1` · `v0.8.7`) | 90 | 81 | 9 | 60 | 21 | 1 | 6 | 2 |

---

## 二、核心定论（指导产品决策与工程排期）

### 1. Get 笔记卡 (`Get-A7769D`, SN `GET25LA7769D`, MAC `5C:8E:8B:A7:76:9D`, FW `v0.2.7`)
- **物理与识别层可用，本地解码闭环可用**：
  - BLE 广播（`0x544A` 含 MAC 与尾字节 `0000000207` → `v0.2.7`）、GATT 连接（`MTU=495`，4 个主服务：`0x180F`/`6666`/`0x9000`/`0x9100`，无 `0x180A` DIS 与 `0x1812` HID）、BAS 电量（`70%` 读写 + Notify）、`0x9000` AES-128-ECB（密钥 `Walkiz52832iLock`）实读 FW `0.2.7` / MAC / SN（`49–62 ms`）以及 `reai-ext-sdk` 纯 Rust `opus-pure` Ogg Opus → 16kHz WAV（`4,758 B -> 8,000 samples / 0.50 s`，耗时 `4 ms`）全部 `PASS`。
- **核心阻断（硬件固件锁定 + 我方适配吞错）**：
  1. **`0x9100` 全量指令 0 通知**：`0x0040/0x0042/0x0043/0x0044/0x0046/0x0146/0x0050/0x0145`（WriteNoRsp 与 WriteWithRsp，以及 `0x9000` 握手前后）均无返回帧，实证 `v0.2.5+`「一机一码」云端鉴权锁死。
  2. **项目代码假成功 BUG**：`app/rust/sdks/reai-getseed-sdk/src/device.rs:463-467` 将 `SdkError::Timeout` 转为 `Ok(Vec::new())`，导致 `card_bridge files()` 在等待 `12,007 ms` 后返回 `{"ok":true,"data":[]}`（违反项目「失败必须如实呈现」红线）。
  3. **超时级联与越界漏洞**：`connect()` 串行阻塞耗时 `40,090 ms`（逼近 `card_gateway.dart` `45s` 上限），`snapshot()` 耗时 `24,038 ms`（超过 `DeviceStore` `_snapshotTimeout = 8s`），无 `0x180A` 导致版本为空；`card_bridge::ota_info`（`app/rust/card_bridge/src/lib.rs:3797-3827`）对 GetSeed 越界回退返回 V2 `0.3.19` OTA 包；`docs/SDK-CAPABILITY.md:44` 与 `docs/MULTI-DEVICE-ARCHITECTURE.md:106` 误写 `0xFF00`（实为 `0x9100`）。

### 2. 点一机 V1 (`DYJ_YKAUP3`, `device_id: 867400020316612`, `app_version: "0.8.7"`, `sl8541e_1h10` Android `8.1.0`)
- **底层 BLE、音频流、录音删源、灯效/按键、2.4GHz Wi-Fi 配网、LAN 上传闭环与联网 OTA 检查全部 `PASS` (`60 项`)**：
  - `proto.hello/caps`、`device.info/battery/storage`（`100% / full / plugged="ac" / 4354mV`，`/data` 可用 `10,275 MB`）、`audio.capture` + 5s `FF12 type=0x04` AMR-WB 实时流转 16kHz WAV（`50` 包 / `8,844 B` / `0` 丢包 → `85,760 samples / 5.36 s`，`RMS=226.808`）、`record.*`（拒绝非 8 位 hex `TEST0001` 报 `1002`，合法 `A1B2C3D4` 创建并彻底 `record.delete` 清理 `55,350 B` + 捕获真实 `EVT:record.segment`）。
  - **补充 Wi-Fi 全链路实测完成（本次收尾验证）**：
    - `DYJ-WIFI-5G (PASS)`：向 `KK2BY_5G` 发起 `wifi.connect` 10s 后 `state="disconnected"`，且 `wifi.scan` 仅扫到 `2412–2462 MHz` 7 个网络，实证 SPRD 仅支持 **2.4GHz 单频 Wi-Fi**。
    - `DYJ-WIFI-05 (PASS)`：向同路由 `2.4GHz` 热点 `KK2BY` 发起 `wifi.connect` 后在 `6,492 ms` 验证连网成功（`ip="192.168.28.76"`, `gateway="192.168.28.1"`, `rssi=-26 dBm`, `52 Mbps`, `2437 MHz`）；同时发现实机 `wifi.status.state` 返回 Android 小写 `"completed"` 而非 `"connected"`。
    - `DYJ-UPL-04 (PASS)`：设置本机局域网上传端点 `http://192.168.28.233:18900/api/upload` 后，设备在 `37.7s` 内完成 `POST /api/upload/867400020316612/audio_20261120-223112_B2C3D4E5_01.amr`（`9,975 B`, `Dalvik/2.1.0`, `x-filesize/x-filename/x-device-id`）、自动删源归零（`still_on_device_after_upload=false`）、并通过 HTTP 回拉后经 `/usr/bin/afconvert` 无损解码为 `96,640 samples / 6.04 s` 16kHz WAV。完成后已实测验证还原默认 `upload.config`（`overridden=false`）、清空测试录音并 `wifi.forget` 断连至 `state="disconnected"`。
    - `DYJ-OTA-03B (PASS, 暴露云端阻塞)`：连网后 `ota.check` 真实访问 `https://dyj2.dev.reai.com/api/ota/info?mod=app`，返回 `current=0.8.7 (807)` vs `remote=0.8.5 (805)`，`need_update=false`——**证实即使端侧联网与 OTA 协议完全畅通，服务端清单滞后仍阻断设备在线升至 `0.8.13+`**。
- **三大关键工程阻断**：
  1. **`NOTIFY_SETTLE=1600ms` 死锁/写超时 (`P0`)**：`dyj_v1_session.rs:24,268,539` 与上游 `dyj-v1-sdk/src/transport.rs:15,119,159` 空等 `1600ms` 撞上 SPRD 建连后 ~1s 空闲断连窗口，导致 `ble_e2e_runner dyj-bridge` Attempt 1/2 稳定在 `13,229 ms` / `13,624 ms` 报错 `"点一机握手失败: command 'ble.write' timed out after 4s"`；另在 2.4GHz Wi-Fi+BLE 共存期间单连接丢包/扫描漏帧概率上升，需要单指令串行与断连自动重连。
  2. **固件 `0.8.7` 版本代差与静态能力位错位 (`P0`)**：实机 `0.8.7` 对 `camera.*` (`>=0.8.8`/`0.8.12`)、`sensor.*`/`location.*` (`>=0.8.10`)、`device.time`/`device.reboot`/`vibrator.*`/`volume.*` (`>=0.8.11`)、`asr.*` (`>=0.8.13`) 均返回 `code=1001`（其中 `DYJ-DEV-07` 测试轮遇瞬断），而 `capabilities.rs:78` 对 `DYJ_*` 静态声明 `hasCameraMedia=true`。
  3. **状态字段与静默降级 (`P1`)**：`lib.rs:1692,1839-1840` 用 `plugged.as_i64()` 解析 `"plugged":"ac"` 导致满电插电源误判 `isCharging=false`；`lib.rs:3701` `time_sync` 用 `unwrap_or_else` 吞掉 `1001` 错误返回伪成功。

---

## 三、下一步研发任务路线图（直接可执行 Backlog）

| 任务编号 | 优先级 | 归属模块 / 目标位置 | 具体开发与修复要求 | 完成验收标准 |
| --- | :---: | --- | --- | --- |
| **Task P0-1** | `P0` | `app/rust/card_bridge/src/dyj_v1_session.rs:24,268,539`<br>`dyj-v1-sdk/src/transport.rs:15,119,159` | 1) 将 `NOTIFY_SETTLE` 从 `1600ms` 缩短至 `<=300ms`，订阅 `FF11` 后立即发起 `proto.hello`；<br>2) `ble.write` 加超时并在断连/RPA 漂移时自动重扫重连一次；<br>3) Wi-Fi/OTA 并发期采用单指令串行与重试容错。 | `ble_e2e_runner dyj-bridge` 在 macOS / iPhone 16 Pro 上 `connect` + `snapshot` 连续通过。 |
| **Task P0-2** | `P0` | `app/rust/sdks/reai-getseed-sdk/src/device.rs:267,374-386,463-467`<br>`protocol.rs:18` | 1) 移除 `device.rs:465` 对 `Timeout` 的 `Ok(Vec::new())` 吞并，向 UI 明确透传错误；<br>2) `sync_time` 移出建连阻塞路径并删无效 `CMD_STATUS` 等待，将 `snapshot` 压到 `<5s`；<br>3) 接入 `0x9000 cmd 0x01/0x02` 读取真实 FW `0.2.7` 与 SN。 | `Get-A7769D` `connect <5s`、`snapshot <5s`（含真实版本号），`files()` 超时如实报错。 |
| **Task P0-3** | `P0` | `https://dyj2.dev.reai.com/api/ota/info?mod=app`<br>`app/test/dyj_v1_full_integration_test.dart` | 协调后端/固件将 OTA 清单从 `0.8.5 (805)` 升级至 `>=0.8.13`，对 `DYJ_YKAUP3` 完成在线升级后重测 `sensor.*` (5 类传感器)、`location.*`、`camera.*`、`vibrator/volume/device.time/reboot` 与 `asr.*`。 | `ota.check` 返回 `need_update=true`，升级后原 `1001` 的 21 项接口转绿。 |
| **Task P1-1** | `P1` | `capabilities.rs:73-83`<br>`lib.rs:1692,1839-1840,3028-3040,3701,3797-3827` | 1) 按 `app_version` 动态裁剪 `hasCameraMedia (>=0.8.8)` 等能力位；<br>2) `plugged` 兼容 `"ac"/"usb"/"wireless"`；<br>3) `is_dyj_wifi_connected` 显式兼容 `"completed"`；<br>4) `time_sync` 停止吞错、`ota_info` 对 `ota_mode=="none"` 拒绝回退 CardV2。 | Rust 单测覆盖 `"plugged":"ac"`、`"state":"completed"`、`app_version:"0.8.7"` 及 GetSeed `ota_info` 拦截。 |
| **Task P1-2** | `P1` | `setting_sub_page.dart:4068`<br>`docs/SDK-CAPABILITY.md:44`<br>`docs/MULTI-DEVICE-ARCHITECTURE.md:106` | 1) Wi-Fi 配网输入页对 `_5G`/`-5G` 热名给出「点一机仅支持 2.4GHz Wi-Fi」强提示，`wifi.forget` 校验改以 `wifi.status.state=="disconnected"` 为准；<br>2) 去掉 Setting 文案「与打点」并修正两处文档 `0xFF00 -> 0x9100`。 | `flutter analyze && flutter test` 全绿且文档与 GATT 实测一致。 |
| **Task P2-1** | `P2` | 官方 `Get笔记 App` 抓包 & 点一机人工协同 | 1) 评估是否对已绑定 `GetSeed v0.2.7` 做官方 App HCI btsnoop 抓包以解析 `0x9000/0xA0` 云端鉴权挑战；<br>2) 日间人工按压点一机验证 `EVT:button.event`，切热点 `DYJ_6612` (`192.168.43.1:8788`) 验证 `ApClient` 传片与 >10min 连续录音滚动事件。 | 明确 GetSeed v0.2.7 支持策略并补齐人工交互验收记录。 |
