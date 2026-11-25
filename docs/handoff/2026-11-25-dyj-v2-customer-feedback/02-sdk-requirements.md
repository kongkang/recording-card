# SDK 层（`ReAI-com/reai-card-sdk`）需求与修复规格书

- **适用仓库**：`ReAI-com/reai-card-sdk`（Rust SDK，当前移动端锁在 `3b7a5c5` / v0.0.8，上游最新 `250f12a` / v0.0.9+）
- **已提交 GitHub Issues**：
  - [#9](https://github.com/ReAI-com/reai-card-sdk/issues/9) — `[bug][Windows] DeviceManager::scan / scan_dfu_targets 按 Service UUID 过滤导致 Windows 11 丢失 Scan Response 设备名、始终扫出 0 台`
  - [#10](https://github.com/ReAI-com/reai-card-sdk/issues/10) — `[feature] 面向桌面/B2B 管线的 SDK 增强：Python 绑定（PyO3）、apm_to_wav 频偏重采样与增益归一化选项、1024s 回绕时间戳会话重建`
  - 关联历史 Issue：[#6](https://github.com/ReAI-com/reai-card-sdk/issues/6)（暴露 `UPLOAD_LIST` / `UPLOAD_FILE`）、[#8](https://github.com/ReAI-com/reai-card-sdk/issues/8)（macOS btleplug DFU 写超时与续传）

---

## 一、P0/P1：修复 Windows 11 扫描始终 0 台的 Bug（Issue #9）

### 1.1 源码级根因
- `src/btleplug_transport.rs:53-85`：
  - 第 56–59 行：`self.adapter.start_scan(ScanFilter { services: vec![service] })` 按 128-bit NUS UUID（`6e400001-...`）过滤。
  - 第 70–75 行：`let Some(name) = properties.local_name else { continue; };` 强依赖设备名。
- **Windows WinRT 行为**：DYJ-HD v2 的 128-bit NUS UUID 占满主广播包（Advertising Data），设备名 `DYJV2_XXXXXX` 在 **Scan Response** 中下发。WinRT `BluetoothLEAdvertisementWatcher` 启用服务 UUID 过滤后会丢弃不含该 UUID 的 Scan Response 包，致使 `properties.local_name` 恒为 `None`，扫描循环跳过全部设备。

### 1.2 修复方案
1. `DeviceManager::scan` 与 `DeviceManager::scan_dfu_targets`（第 168–203 行）统一改用 **`ScanFilter::default()`**（与移动端 `recording-card/app/rust/card_bridge/src/card_v2_ble.rs:286-289` 已验证方案一致）；
2. 订阅 `adapter.events()` 聚合发现事件，在应用层过滤：`local_name` 匹配 `DYJ` 前缀 **或** `properties.services.contains(&nus_service)`；若已命中 `nus_service` 但名字暂缺，不直接 `continue` 丢弃，兜底赋予 `"DYJV2"`；
3. 在 Windows 11 真机运行 `dyj_cli scan` 回归验证通过后发布小版本（建议同步合入 `#6`、`#8`）。

---

## 二、P1：Python 绑定与 Windows CLI 发行物（Issue #10）

### 2.1 背景
B2B 客户（高岩科技）及桌面后端自动化管线以 **Windows 11 + Python** 为主；当前仓库只有 Rust crate，缺乏标准 Python 包装与开箱即用 Windows 可执行文件。

### 2.2 交付设计
1. **新增 `crates/reai-card-py`（`PyO3 + maturin`）**：
   - 内部复用同一 Tokio runtime，向 Python 暴露同步/异步接口：
     - `scan(timeout_ms=5000) -> list[DiscoveredDevice]`
     - `connect(device_id) -> DyjCard`
     - `device_info() / battery() / storage() / sync_time()`
     - `list_files() / take_file_to_dir(name, dir) / take_oldest_file_to_dir(dir)`
     - `open_wifi() / access_point_files() / access_point_download(name, dir) / access_point_delete(name)`
     - `apm_to_wav(apm_path, wav_path, source_sample_rate=None, condition_speech=False)`
2. **Release 自动化构建**：GitHub Actions 产出 Windows x86_64 `.whl` + `dyj_cli.exe`（`dyj_cli` 为 `scan` / `files` / `take` 等命令提供 `--json` 机器可读输出）。

---

## 三、P1：`apm_to_wav` 频偏重采样与柔和信号调理选项（Issue #10）

### 3.1 背景
在存量固件（`≤0.3.19`）升级前，或面对已落盘的历史 `.APM` 文件时，B2B 客户与各端消费者都会遇到：
1. **`-2.7%` 时钟频偏**（实际 ~15,578 Hz，1 小时差 ~97 秒）；
2. **远场偏轻（-46.3 dBFS）与实时 ADPCM 直流漂移**。

### 3.2 改动要求
在 `src/audio.rs` 与 `src/recording.rs` 保留现有 `apm_to_wav()` 无损默认行为不变，新增 `ApmDecodeOptions` 与 `apm_to_wav_with_options(apm, wav, opts)`：
1. `source_sample_rate_hz: Option<f64>`：当指定（如 `15578.0` / `15625.0` 或从 `.txt` `sample_rate` 字段读取）且与 `16000.0` 偏差超过阈值时，执行线性/窗口 Sinc 重采样输出标准 `16,000 Hz` 16-bit Mono WAV；
2. `condition_speech: bool`：移植移动端 `wav_io.dart` 已验证的预处理逻辑——一阶高通去直流（~12.7 Hz 截止）+ 50 ms 帧 95 分位 RMS 噪声门控柔和增益（渐进上限 2x–10x + 软限幅），不引入降噪伪影。

---

## 四、P1：同 `session` 分片 1024s 回绕时间戳校验与重建辅助（Issue #10）

- 针对主控 `≤0.3.19` `time_lib.c` 24-bit RTC1 溢出导致长会议分片 `start_at` 折叠在 17 分钟内的历史/存量数据：
- 在 `src/types.rs` / `src/recording.rs` 提供 `reconcile_session_timestamps` 纯函数：
  - 按 `(session, seq)` 分组排序；
  - 检测相邻 `seq` 是否出现 `start_at` 倒退或停滞（与前片时长不符）；
  - 以首个有效锚点 + 每片实际文件字节推算时长（`bytes * 2 / sample_rate`）逐片外推单调连续时间戳，并输出 `timestamp_inferred: bool` 标记（严格遵守“不伪造未标注推测”）。

---

## 五、P0/P1：既有未合入 Issue 协同优先级

1. **优先合入 [#8](https://github.com/ReAI-com/reai-card-sdk/issues/8)**：给 `BtleplugTransport` / `BtleplugDfuTransport` 补上写超时与断链清理、macOS DFU 包间 4ms 节流与断点续传，保证客户测试机后续刷 `0.3.20+` 固件一次成功。
2. **优先合入 [#6](https://github.com/ReAI-com/reai-card-sdk/issues/6)**：暴露 `upload_list()` 与带可配长超时的 `upload_file()`，消除 `raw_command` 10s 超时误报与串帧风险。
3. **新增设备配置类型化封装**：补充 `mic_gain`、`silence_stop_min`、`local_only` 的便捷读写方法（透传 `CONFIG_SET/GET`）与 `RecordingStamp` / `FileEntry` 可选 `sample_rate` 字段解析。
