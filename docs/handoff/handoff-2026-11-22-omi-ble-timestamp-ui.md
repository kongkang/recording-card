# Handoff · Omi / 多硬件 BLE 重连幽灵连接、时间轴乱序、状态条抖动与下拉卡死修复（2026-11-22）

## 1. 现场问题与本地环境限制说明

- **现场截图证据**：`~/Downloads/IMG_8674.PNG`（同时出现三项异常）：
  1. 时间轴离线条目落在当日 `00:28`（上传同步墙钟时刻，而非原始录音时刻）；
  2. 顶部 `RecordingStatusBlock` 副标题被拼接为 `已录 00:03:25 · 正在取回 00:28 这段\n(156/159)`，发生 2 行折行并在 `RecordingStatusController` 与 `AppShell` 周期刷新之间交替切换，造成列表上下抖动；
  3. 页面上方 `RefreshIndicator` 圆形转圈长期悬停不消失。
- **本机日志采集限制记录**：当前工作机未安装 Xcode / `xcrun devicectl` / `idevicesyslog`（仅安装了 Rust `cargo 1.94.0` 与 `gh` CLI，无 `flutter`/`dart`/`node`），且系统未枚举到通过 USB 连接的 iPhone 真机，无法直接拉取真机 syslog / App 容器日志；所有定位基于真机截图与仓库全链路源码核查，后续需 owner 在带 Xcode 的环境完成真机验收后再合并 PR。

---

## 2. 四项根因与改动清单

### 问题 A：蓝牙断开重连后设备蓝灯常亮（CoreBluetooth 已连）但 App 仍反复重连
- **根因**：
  1. `btleplug` CoreBluetooth 后端在 `connect_peripheral()` 时未对系统已处于 `CBPeripheralState::Connected` 的外设做短路建链与 delegate 重新绑定；也缺少 `retrieveConnectedPeripheralsWithServices:` 能力去找回/释放不广播但系统已连的硬件。
  2. `OmiDevice::connect_peripheral` 在建链后初始化失败时未执行回滚断开，造成 CoreBluetooth 句柄滞留；`release_device()` 残留清理白名单遗漏 Omi / Friend / Feishu / BoardV21。
  3. Dart 侧 `_retryConnectTimeout`（25s）短于 Rust 扫描+重连最坏耗时，且 `DeviceStore._heartbeatTick` 未感知 `RecordingPipeline.sync()` 占用的蓝牙传输通道，导致长文件同步时看门狗误判掉线重连；手动 `connectTo` 也未立即废除在途后台自动重连 epoch。
- **修复**：
  - `app/rust/vendor/btleplug-0.12.0/src/api/mod.rs`、`corebluetooth/internal.rs`、`corebluetooth/adapter.rs`：新增 `Central::retrieve_connected_peripherals`（CoreBluetooth 走 `retrieveConnectedPeripheralsWithServices:`，其它平台提供安全默认空实现）；`connect_peripheral` 对已处于 `CBPeripheralState::Connected` 的外设直接补挂 `CBPeripheralDelegate` 并返回 `Connected`。
  - `app/rust/sdks/reai-omi-sdk/src/device.rs`：`connect_peripheral` 初始化报错时先尝试断开防止系统连接泄漏；持有 `storage_lock` 期间跳过冗余 GATT 查询；`disconnect()` 超时提升至 2800ms。
  - `app/rust/card_bridge/src/lib.rs`、`card_v2_ble.rs`、`dyj_v1_session.rs`：统一纳入 Known BLE Service UUID 召回（`retrieve_os_connected_peripherals`）；收紧扫描/直连预算（8s / 10s）；将 `release_device` 残留清理覆盖所有家族硬件（DYJ / CardV2 / Omi / Friend / Feishu / BoardV21 / DFU）。
  - `app/lib/core/device/card_gateway.dart`、`app/lib/core/store/device_store.dart`、`app/lib/main.dart`：引入 `RealCardGateway.onDownloadProgressActivity` 与 `DeviceStore.isExternalBleSyncBusy = () => _pipeline.isBusy`；看门狗忙碌期顺延不误探；`_retryConnectTimeout` 放宽至 32s；手动 `connectTo` 立即递增 `_epoch` 并取消在途后台重连。

### 问题 B：离线同步录音按「上传时刻」落时间轴（时间轴错乱）
- **根因**：
  1. `reai-omi-sdk` Ring Buffer（444B 记录含 4 字节大端 Unix 秒头 `[ts:4 BE]`）已在 `extract_ring_encoded_frames` 解出时间戳，但 `download_file()` 丢弃了 `ts` 且未对单块跨越 >60 秒静默间隔的多段录音做分段拆分，`SdkSavedFile` 也无 `start_at` / `timeSynced` / `parts` 结构字段。
  2. `reai-feishu-sdk` `session.rs` 的 `file_entry()` 错误地把秒乘以 1000 当作 `start_at`。
  3. `card_bridge` 与 `RecordingPipeline` 对 `startAt` 未统一传递，且转码环节 `source.startAtSec == null` 时会用 `DateTime.now()` 覆盖 `download.startAtSec`；`RecordingPipeline.sync()` 未按起始序号升序拉取 `OMI_RING_*` 且未在本地落盘后调用 `deleteFile()` 推进设备环形队列指针。
- **修复**：
  - `app/rust/sdks/reai-ext-sdk/src/types.rs`、`src/lib.rs`：为 `SdkSavedFile` 增加 `start_at`、`time_synced` 与 `parts: Vec<SdkSavedFilePart>`。
  - `app/rust/sdks/reai-omi-sdk/src/protocol.rs`、`device.rs`：新增合理时间戳范围校验（2020–2100）、按 `> 60s` 时间跳变切分的 `split_ring_encoded_segments`，并在 `download_file()` 逐段落盘 WAV 并返回准确 `start_at` / `time_synced` / `parts`。
  - `app/rust/sdks/reai-feishu-sdk/src/session.rs`：修正 `file_entry()` 与 `download_file()` 时间单位为 Unix 秒。
  - `app/rust/card_bridge/src/lib.rs`：新增合理 Epoch 校验 `normalize_mtime_sec`，为 CardV2（解析 `RecordingStamp`）与 External（Omi / Feishu）统一输出 `startAt`、`timeSynced` 与 `parts`。
  - `app/lib/core/device/card_gateway.dart`、`app/lib/services/recordings/recording_pipeline.dart`、`app/lib/services/recordings/recording_sync_service.dart`：`CardFile` / `CardDownload` / `CardDownloadPart` 统一规范化 Epoch；`OMI_RING_*` 按起始 seq 升序处理，在本地落盘确认后调用 `deleteFile()` 推进设备游标；保留 `download.startAtSec` 不被 `DateTime.now()` 覆盖，并对 multi-part `download.parts` 拆出独立 `#p$k` 记录。

### 问题 C：顶部「正在录音」状态条文案折行、与同步态来回切换导致画面抖动
- **根因**：
  - `RecordingPipeline` 输出包含具体段时刻的冗长文案（如 `正在取回 00:28 这段（157/159）`），`_onPipelineProgress` 每次回调把 `_phase` 切为 `syncing` 覆盖副标题，`AppShell` 下 1 秒调用 `ensureRecording()` 又切回 `recording` 却未清空 `_detail`，在 `maxLines: 2` 下造成 1 行 / 2 行高度高频跳变。
- **修复**：
  - `app/lib/services/audio/recording_status.dart`：`RecordingStatusController` 独立维护 `syncDone` / `syncTotal`；`_sessionActive == true` 时 `updateSync()` 不篡改 `_phase`、不覆盖 `_detail`。
  - `app/lib/widgets/recording_status_block.dart`：状态块增加 `minHeight: 42` 锁定最小高度；副标题设为 `maxLines: 1`、`softWrap: false`、`overflow: TextOverflow.ellipsis`；录音中存在队列进度时简洁展示为 `已录 HH:MM:SS · 已存 done/total 段`。
  - `app/lib/services/recordings/recording_pipeline.dart`、`recording_sync_service.dart`、`app/lib/core/store/app_store.dart`：统一精简进度文案，去掉时间片段描述。

### 问题 D：下拉刷新 loading 转圈长期卡住 + 实时录音与离线拉取互相阻塞
- **根因**：
  - `TimelinePage` 的 `RefreshIndicator.onRefresh` 直接等待耗时百余段的 `syncRecordings()`；且在实时录音切片切分过程中若之前已有离线 `pipeline.sync()` 在途，`ingestLiveSlice` 会阻塞等待 `_waitUntilIdle()`，反过来拖住 `RefreshIndicator`。
- **修复**：
  - `app/lib/core/store/app_store.dart`、`app/lib/pages/timeline_page.dart`：`TimelinePage` 下拉改调 `AppStore.pullToRefresh()`（复用在途任务且最长等待 600ms 即完成 `RefreshIndicator` 收起，并在 `dispose()` 中严格清理定时器）；后台继续逐文件完成同步并通过 `onFileReady` 增量刷新时间轴。
  - `app/lib/services/recordings/recording_pipeline.dart`、`app/lib/pages/app_shell.dart`：新增协作让步机制 `requestSyncPauseForLiveRecording()`；一旦现场开始实时录音或录音中下拉刷新，在途离线同步在当前文件安全落盘后礼让暂停并标记待恢复队列，避免实时链路等待锁死。

---

## 3. 真机验收检查清单（待 owner 实测）

1. **Omi 断连/重连恢复**：连接 Omi 录制后强断蓝牙或杀 App 重开（观察设备蓝灯仍亮场景），触发连接/重连后确认 App 状态胶囊能在无反复断连提示下恢复并正常读写文件与状态。
2. **离线历史时间轴排序**：在设备离线录两段间隔 >2 分钟的录音后回到手机边连接同步，确认时间轴卡片按各自原始开录时间分别展示并落入对应时刻，而非全部挤在同步当前分钟；重启 App 或二次同步不重复拉取同一批 Omi Ring 数据。
3. **状态条单行稳定性**：边连接硬件/本机录音边观察顶部 `RecordingStatusBlock` 在同步队列推进（如 `已存 x/y 段`）及正计时每秒跳动过程中高度恒定、不折行、不与同步态来回闪烁。
4. **下拉刷新不卡转圈**：在队列有大量待同步切片或正在录音时下拉 Timeline，确认 `RefreshIndicator` 在 ~0.6s 内正常回弹消失，同步内容随处理完成逐条增量出现在时间轴上；且长链路蓝牙拉取过程不触发假掉线。
