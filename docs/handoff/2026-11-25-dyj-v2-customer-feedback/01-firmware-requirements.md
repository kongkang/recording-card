# 固件层（`ReAI-com/dyj-hd-v2`）需求与修复规格书

- **适用仓库**：`ReAI-com/dyj-hd-v2`（nRF52840 主控 `nrf52840dk/` + ESP32-C3 Wi-Fi `esp32c3wifi/`）
- **实测基线版本**：主控 `0.3.17` / Wi-Fi `0.1.4`（注：主控 `0.3.19` 已合入待机与录音功耗优化）
- **已提交 GitHub Issues**：
  - [#13](https://github.com/ReAI-com/dyj-hd-v2/issues/13) — `[nRF][P0] PDM 采样时钟频偏约 -2.7%（1000K/RATIO64=15625Hz + 未锁 HFXO）及默认增益偏低（-46.3 dBFS）`
  - [#14](https://github.com/ReAI-com/dyj-hd-v2/issues/14) — `[nRF/ESP][P0] 录音时间戳每 1024s（17m04s）回绕重叠（RTC1 24-bit 溢出）及断电重启时间错乱/缺 STA 自动对时`
  - [#15](https://github.com/ReAI-com/dyj-hd-v2/issues/15) — `[ESP][P0] Wi-Fi 批量上传 0 字节断连（~32s 周期）、缺 SHA-256 回执校验导致重发/删源风险及 USB-C 直读核查`
  - [#16](https://github.com/ReAI-com/dyj-hd-v2/issues/16) — `[nRF][P0/P1] 防漏录与防误录：开机拨杆电平补检、低电量安全停录保护、静音超时自动停录、仅本机模式与 OLED 待传提示`
  - 关联历史 Issue：[#11](https://github.com/ReAI-com/dyj-hd-v2/issues/11)（UART EasyDMA 掉字节，待用双缓冲链式接收彻底修复）、[#12](https://github.com/ReAI-com/dyj-hd-v2/issues/12)（STA 模式 WebServer + `UPLOAD_FILE` 命名）

---

## 一、P0：音频采样时钟校准与前置增益（Issue #13）

### 1.1 源码级根因
1. **时钟频偏 `-2.7%`**：
   - `nrf52840dk/src/lib/audio/pcm.c:229-236` 配置 `.clock_freq = NRF_PDM_FREQ_1000K`（`1.000 MHz`），配合 nRF52840 默认 `RATIO64`（64 倍抽取），实际输出采样率天然为 `1,000,000 / 64 = 15,625 Hz`（天生比 16,000 Hz 慢 `-2.34375%`）。
   - 录音期间未请求锁定外部 32 MHz 晶振（HFXO），若运行于内部 64 MHz RC（HFINT，典型偏差 `-0.3% ~ -1.5%`），`15,625 × 0.997 ≈ 15,578 Hz`，与客户实测比例 **`0.9736`（`15,578 / 16,000`）** 及线性校正后 `0.3s` 残差完全吻合。
   - 同时 `pcm.c:42` 注明麦克风为 `MP34DB02`，其规格书推荐时钟范围为 `1.2–3.25 MHz`，`1.000 MHz` 低于推荐下限。
2. **默认 `0 dB` 增益导致 ADPCM 量化信噪比损失**：
   - `pcm.c:230-231` 配置 `.gain_l = NRF_PDM_GAIN_DEFAULT`（`0 dB`）。会议桌场景说话声 P95 仅 `-46.3 dBFS`（动态范围仅用 ~0.5%），直接进 4-bit IMA-ADPCM 编码后量化台阶噪声显著，事后软件增益无法还原精度。

### 1.2 改动要求
1. `pcm_start_recording()` 请求 HFXO（`sd_clock_hfclk_request()`），`pcm_stop_recording()` 释放。
2. 将 PDM 时钟改配为 **`1.280 MHz`（`NRF_PDM_FREQ_1280K` / `0x0A000000`）+ `NRF_PDM_RATIO_80X`**，精确产出 `1,280,000 / 80 = 16,000.000 Hz`。
3. 在 `.txt` 旁车（可选字段 `"sample_rate": 16000`）及 `BASE_INFO` 暴露实际采样率，便于上位机区分已校准新固件与存量固件。
4. 提高 `gain_l` 默认值（并支持 `CONFIG_SET mic_gain` 切换「近讲 / 会议桌」档位或 dB 值），把会议室正常语音 P95 抬至 `-24 ~ -16 dBFS`；**禁止在固件端加入破坏性降噪**。

### 1.3 验收标准
- 连续录音 1 小时，输出音频时长与标准墙钟误差 **`< 1 秒`**；
- 会议室 1.5–2 米说话声 P95 峰值达到 `-24 ~ -16 dBFS`，无削顶爆音。

---

## 二、P0：消除 1024s 时间戳回绕与对时持久化错乱（Issue #14）

### 2.1 源码级根因
1. **24-bit RTC1 每 1,024 秒溢出回绕**：
   - `nrf52840dk/src/pca10056/s140/config/sdk_config.h:5844` 设 `APP_TIMER_CONFIG_RTC_FREQUENCY = 1`（`16,384 Hz`）。
   - `nrf52840dk/src/lib/time_lib.c:116-126` 用 `app_timer_cnt_diff_compute(ticks_now(), g_boot_ticks)` 计算运行秒数；nRF52840 `RTC1->COUNTER` 仅有 **24-bit**（上限 `16,777,216` ticks），每 **`16,777,216 / 16,384 = 1,024 秒（17 分 04 秒）` 必然回绕归零**，且 `time_lib.c:27-28` 的 1 秒回调 `time_tick_handler` 是空函数，导致 4 小时 25 段的 `start_at` 全部折叠在 `[t0, t0+1024s]` 内（实测表现为全挤在 `09:07–09:21`）。
2. **`time_synced` 误持久化、重启错标日期**：
   - `time_lib.c:67, 103-104` 将 `g_offset` 仅存 RAM，却调 `setting_set_time_synced(true)` 修改全局结构体；此后任何 `setting_set_realtime_enabled()` / `setting_set_auth_state()`（`setting_lib.c:420-435`）触发 `settings_save(&g_settings)` 时，会把 `time_synced = true, time_offset = 0` 写入 FDS。断电重启未同步时，`time_lib_now_unix()` 返回 `0..1023` 且标为 `synced: true`。
3. **ESP32 连 Wi-Fi 未自动对时**：脱离手机仅靠 Wi-Fi 上传场景缺少 SNTP 自动对时回写主控。

### 2.2 改动要求
1. `time_lib.c` 维护 64-bit 累计 tick（在 `time_tick_handler` 与 `time_lib_now_unix` 中基于 `g_last_rtc_ticks` 增量累加），彻底消除 1024s 溢出。
2. `setting_lib.c` 启动加载后内存态强制 `time_synced = false`（仅当本次上电后收到过有效 `SYNC_TIME` 才为 `true`）；可另持久化一个「最后已知合法时间戳」供离线兜底排序。
3. ESP32 STA 联网后跑 SNTP，拿到合法 Unix 时间通过 UART 发至主控；主控在本次开机首次收到 `SYNC_TIME` 时，利用本次开机单调 `uptime_sec` 回推修正本次开机已产生的 `nosync` `.txt` 文件；`.txt` 增加可选 `tz_offset_min`。

---

## 三、P0：Wi-Fi 上传稳定性、SHA-256 回执删源与 USB-C 核查（Issue #15）

### 3.1 源码级根因
1. `esp32c3wifi/src/http_client.cpp:230-304` 复用类成员 `HTTPClient _http` 连续上传几十个 4.8 MB 文件，未调用 `_http.setReuse(false)`，且上传期未关闭 ESP32-C3 Wi-Fi Modem-sleep，易在半开连接/休眠唤醒期触发 ~32s TCP 重传复位（接收端观测到 0 字节早期断开）。
2. `upload_manager.cpp:154-162` 仅凭 `httpCode 200..299` 即删源，不读取响应体、不携带/核对 SHA-256；若服务端回 `200` 但卡端读超时（返回负数），则保留源文件导致下轮重复上传。
3. `commandHandler.cpp:1203, 1228` 中 `UPLOAD_DELETE` / `UPLOAD_CLEAR` 调用 `SD.remove(fileName)` 未补前导 `/` 且未成对删 `.txt`。

### 3.2 改动要求
1. 上传期间设置 `esp_wifi_set_ps(WIFI_PS_NONE)`，每次 `postFile()` 用独立局部 `WiFiClient` + `_http.setReuse(false)`，排查堆内存碎片与 SD 读超时。
2. 流式计算 `mbedtls_sha256` 并带 `x-sha256` 请求头；当服务端 2xx JSON 响应带 `sha256` 字段时，**严格校验一致后才删 `.APM` 与 `.TXT`**，否则保留源文件待重试。
3. 修复 `UPLOAD_DELETE`/`UPLOAD_CLEAR` 前导 `/` 与 `.txt` 成对删；协同 `#12` 开放 STA 下 WebServer 局域网拉取，并保持 AP `/api/files/download` 严格只读。
4. **硬件原理图核查**：确认 `SCH_nrf52840_ESP32C3_2025-08-26.pdf` 中 Type-C `D+/D-` 是否连至 nRF52840 USBD；若连通，排期开启 `APP_USBD_MSC_ENABLED` 支持 USB-C U 盘直读。

---

## 四、P0/P1：防漏录、防误录、低电安全停录与 P2 OLED 待传显示（Issue #16）

1. **开机拨杆电平补检（P0）**：`toggle_lib.c:32-36` 初始化吞掉初始电平；需在 `main.c` 完成绑定加载后检查 `toggle_lib_is_on()`，若 `switch_on` 绑定为 `record_start` 则立即启动录音，并确保起停有 `vibrate_lib`（`P1.03`）+ OLED 明确反馈、边充边录不被充电事件误中断。
2. **低电量保护链（P0）**：修复 `v0.3.19` 测试中暴露的 `low_battery_callback = NULL` 问题（实测放到 2% / 3060mV 仍未停录）：5% 告警、3%/3.3V 先优雅停录封口 `.APM/.TXT` 再关机。
3. **防误录与仅本机隐私模式（P0）**：支持 `CONFIG_SET silence_stop_min`（如 30 分钟连续低能量静音自动停录）与 `local_only=1`（阻断 `SYNC_START` / `UPLOAD_*`）。
4. **OLED 待传段数（P2）**：主屏/充电唤醒屏展示 SD 根目录待传 `.APM` 数量。
5. **UART 掉字节根因彻底修复**：沿 `dyj-hd-v2#11` 讨论的双缓冲链式接收完成 `hw_uart_lib.c` 重构，消除配置/扫描长帧偶发缺字节。
