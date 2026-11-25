# 点一机录音卡 V2（DYJ-HD v2）重要客户实测反馈：跨层归因与需求分流总览

- **反馈来源**：高岩科技 · 杨顺（2026-11-25，含 11-24 同场 1 小时 44 分多人研讨会逐字稿/音频盲评对比与两周真机测试证据）
- **被测设备**：`DYJ-HD v2`，主控固件 `0.3.17` / Wi-Fi 固件 `0.1.4`；对比设备：钉钉录音卡（云端转写）
- **客户端环境**：客户侧为 Windows 11 + 自建 Python/Sage 管线 + 自建 HTTP 接收端 `reai-card-receiver` + 本机 `Qwen3-ASR 0.6B` / `SenseVoice`；我方移动端基线为 `kongkang/recording-card@668dd10`
- **文档导航**：
  1. 总览与分流表（本文）
  2. [01-firmware-requirements.md](./01-firmware-requirements.md) — 固件层需求（`ReAI-com/dyj-hd-v2` `#13`–`#16`）
  3. [02-sdk-requirements.md](./02-sdk-requirements.md) — SDK 层需求（`ReAI-com/reai-card-sdk` `#9`–`#10`）
  4. [03-mobile-app-adjustment-plan.md](./03-mobile-app-adjustment-plan.md) — 移动端软件（Rust `card_bridge` + Flutter `app/`）问题诊断与调整 Plan

---

## 一、核心战略判断

1. **麦克风硬件底子过关，无需硬件推倒重来**：
   - 同场 1h44m 音频在校正 2.7% 语速漂移并拉平音量后，交由同一本机引擎转写并随机盲评，**REAI vs 钉钉为 `13 : 12`（15 段打平）**。
   - 这说明差距不在麦克风本身，而在**固件工程质量（PDM 时钟/前置增益、RTC 时间戳、Wi-Fi 传输与 SHA-256 删源、拨杆与低电保护）+ SDK 跨平台（Windows/Python）+ 软件端转写配套（私有云 ASR/热词/隐私模式/时间轴自愈）**。
2. **多项客户痛点已在源码中定位到精确根因**：
   - `-2.7%` 频偏：`pcm.c` 配 `1000K / RATIO64 = 15,625 Hz` 且未锁外部 32MHz 晶振 HFXO（叠加约 `-0.3%` 温漂恰好为实测比例 `0.9736`）。
   - `25 段挤在 09:07–09:21`：`time_lib.c` 用 24-bit `RTC1` 差值（16,384 Hz 下每 `1,024s = 17m04s` 溢出回绕）且 `time_tick_handler()` 为空函数；`setting_lib.c` 把未配持久化 `g_offset` 的 `time_synced=true` 写死进 FDS。
   - `Windows 扫描 0 台`：`reai-card-sdk` `btleplug_transport.rs` 传入 `ScanFilter { services }`，WinRT 丢弃不带 UUID 的 Scan Response 包导致 `local_name` 恒为 `None`。
   - `断电重启拨杆失效`：`toggle_lib_init()` 直接吞掉了初始电平，仅检测运行期跳变边沿。
3. **续航可立即靠升级 `0.3.19` 缓解**：
   - 客户实测 `0.3.17` 推算满电约 7 小时；主控仓 `v0.3.19` 已合入 WFI 空闲休眠 + PDM/OLED 按需断电 + DCDC + 32k 晶振，实测连接态静默录音达 **23.3h+（稳态 `2.2%/h`）**，可引导客户优先升级验证；但 `0.3.19` 测试报告暴露 `low_battery_callback = NULL` 放到 2% 仍未停录，需在后续固件补齐保护链。

---

## 二、11 项实测问题 + 12 项优化建议跨层分流总表

| # | 客户问题 / 诉求 | 优先级 | 源码实证根因 | 主责层 | 协同/兜底层 | 关联 GitHub Issue |
|---|---|---|---|---|---|---|
| 1 | **采样时钟偏快 2.7%**（616–618s 录出 600s，`0.9736`） | **P0** | `pcm.c:229-236` 配 `1000K/RATIO64=15625Hz` 且未锁 HFXO | **固件 (nRF)** | **SDK (`#10`) + App (`card_bridge`)** 对 `≤0.3.19` 做重采样补偿 | [dyj-hd-v2#13](https://github.com/ReAI-com/dyj-hd-v2/issues/13) / [reai-card-sdk#10](https://github.com/ReAI-com/reai-card-sdk/issues/10) |
| 2 | **Wi-Fi 批量上传 0 字节断开**（21 次，~32s 周期） | **P0** | `http_client.cpp:230-304` 复用 `_http` 未关连接复用、未关 Wi-Fi Modem-sleep | **固件 (ESP32)** | **App (`card_bridge`)** 补齐 AP 热点快传（`192.168.4.1`） | [dyj-hd-v2#15](https://github.com/ReAI-com/dyj-hd-v2/issues/15) / 既有 `#11`, `#12` |
| 3 | **蓝牙取文件太慢**（4.8MB 耗时 6.5–9.5m；注 `0.3.17` 已提速至 ~33KB/s） | **P0** | BLE 物理上限（244B MTU 最高 ~33KB/s），不适合扛 50 段大批量 | **固件 (ESP32/USB)** | **App** 启用 AP 快传 + 可选 60s/300s 边录边拉 | [dyj-hd-v2#15](https://github.com/ReAI-com/dyj-hd-v2/issues/15) / [reai-card-sdk#6](https://github.com/ReAI-com/reai-card-sdk/issues/6) |
| 4 | **重复上传（回 2xx 仍重发）/ 缺 SHA-256 校验删源** | **P0** | `http_client.cpp:297` 仅凭 `httpCode 2xx` 删源、不读回执 body 与 SHA-256 | **固件 (ESP32)** | **App** AP 下载校验字节/哈希后再显式 `DELETE` | [dyj-hd-v2#15](https://github.com/ReAI-com/dyj-hd-v2/issues/15) |
| 5 | **时间戳不可信**（25 段挤在 09:07–09:21；断电变 2016-01-01） | **P0** | `time_lib.c:116` 24-bit RTC1 每 1024s 回绕；`setting_lib.c` 误持久化 `time_synced`；缺 STA NTP | **固件 (nRF/ESP32)** | **SDK (`#10`) + App (`recording_pipeline`)** 同 session 递增重建 | [dyj-hd-v2#14](https://github.com/ReAI-com/dyj-hd-v2/issues/14) / [reai-card-sdk#10](https://github.com/ReAI-com/reai-card-sdk/issues/10) |
| 6 | **续航偏短**（`0.3.17` ~7h，目标 10h+）& **低电过放保护** | **P1** | `0.3.19` 已将续航提至 23.3h+，但 `low_battery_callback = NULL` 放到 2% 不停录 | **固件 (nRF)** | **App** 监测 `≤5%` 触发本机接力 + 优雅停录封口 | [dyj-hd-v2#16](https://github.com/ReAI-com/dyj-hd-v2/issues/16) |
| 7 | **忘了关一直录（误录隐私）+ 缺「仅本机」模式** | **P0** | 固件无静音超时停录与 `local_only` 锁；App 缺纯离线总开关 | **固件 + App** | SDK 透传 `CONFIG_SET` 配置项 | [dyj-hd-v2#16](https://github.com/ReAI-com/dyj-hd-v2/issues/16) |
| 8 | **断电重启后拨杆在录音位不起作用（漏录）** | **P0** | `toggle_lib.c:32-36` 初始化吞掉当前电平，只认后续跳变边沿 | **固件 (nRF)** | **App** 连接态核对 `switch==on && !isRecording` 告警 | [dyj-hd-v2#16](https://github.com/ReAI-com/dyj-hd-v2/issues/16) |
| 9 | **录音偏轻**（`-46.3 dBFS` vs 钉钉 `-24.6 dBFS`） | **P1** | `pcm.c:230-231` 默认 `0 dB` 导致 ADPCM 量化前信噪比受损 | **固件 (nRF)** | **SDK (`#10`)** 补齐去直流柔和增益（App `wav_io.dart` 已有） | [dyj-hd-v2#13](https://github.com/ReAI-com/dyj-hd-v2/issues/13) / [reai-card-sdk#10](https://github.com/ReAI-com/reai-card-sdk/issues/10) |
| 10 | **只认 2.4GHz + 普通密码 Wi-Fi**（公司为 5GHz + WPA2-Enterprise） | **P1** | ESP32-C3 **物理射频仅支持 2.4GHz**（不可软件升 5GHz） | **硬件边界 + 固件** | USB-C 直读（待核原理图）+ **App AP 快传 / BLE 实时中转** | [dyj-hd-v2#15](https://github.com/ReAI-com/dyj-hd-v2/issues/15) |
| 11 | **Windows 扫不到设备 + 缺 Python 接口** | **P1** | `btleplug_transport.rs:56` 用 UUID `ScanFilter` 丢弃 Scan Response `local_name` | **SDK (Rust/Py)** | App 侧 `card_v2_ble.rs` 已用 `ScanFilter::default()` 规避 | [reai-card-sdk#9](https://github.com/ReAI-com/reai-card-sdk/issues/9) / [reai-card-sdk#10](https://github.com/ReAI-com/reai-card-sdk/issues/10) |
| 12 | **转写配套**（自建私有云 ASR / 热词术语表 / 声纹认「我」） | **P1** | App 文本总结已开放自定义 API，但 ASR 仍绑定外脑网关、无热词表；声纹认「我」PR #121 已落地 | **移动端软件 (App)** | Python 侧可评估开放声纹注册复用指南 | 见 [03-mobile-app-adjustment-plan.md](./03-mobile-app-adjustment-plan.md) |
| 13 | **P2：更高音质选项 & OLED 待传状态显示** | **P2** | `72×40` OLED 已可用；硬件已确认单麦 `MP34DB02`（无多麦阵列） | **固件 + App** | App 同步后可通过 `DISPLAY_SHOW` 推送待传状态位图 | [dyj-hd-v2#16](https://github.com/ReAI-com/dyj-hd-v2/issues/16) |

---

## 三、硬件物理边界核查结论（基于 `dyj-hd-v2` 源码）

1. **麦克风型号与声道数**：`pcm.c:42` 明确标注为单颗 **`MP34DB02`**（单声道 PDM 麦克风，典型 CLK 1.2–3.25 MHz）。因此 V2 **不支持物理多声道拾音**；“更高音质”仅能通过固件提供 16-bit 无损 PCM 选项（需配合 USB-C 或高速 Wi-Fi）。
2. **震动马达**：`config.h:117` 与 `vibrate_lib.c` 证实主控板已配置独立震动马达（`VIBRATE_PIN = P1.03`），无需新增硬件即可提供清晰的起停/低电/超时震动反馈。
3. **Wi-Fi 频段**：主控/Wi-Fi 仓已实证模块为 **ESP32-C3**，射频物理仅支持 2.4 GHz；V2 硬件无法支持 5 GHz，必须坦诚向客户说明并通过 **AP 热点直连 / 手机 BLE 实时中转 /（若连通）USB-C 有线直读**解决企业办公网传文件问题。
4. **唯一待硬件/原理图核实项**：`nrf52840dk/src/pca10056/s140/config/sdk_config.h:6270` 存在 `APP_USBD_MSC_ENABLED` 宏（当前为 `0`），需硬件工程师核对 `docs/原理图/SCH_nrf52840_ESP32C3_2025-08-26.pdf` 中 Type-C 口 `D+/D-` 是否连入 nRF52840 USBD 引脚（已写入 `dyj-hd-v2#15`）。
