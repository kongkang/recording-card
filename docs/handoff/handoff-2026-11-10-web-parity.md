# 交接：按官方 web 控制台对齐 App 设备链路（2026-11-10 第三轮）

> 参考实现：`~/Developer/reai-card-sdk`（HEAD `5571890`，v0.0.6-2）
> `examples/dyj_web.rs` + `examples/dyj_web.html` —— 同一台真卡已跑通扫描/连接/状态/电池/存储。
> 本轮只做「照着参考实现找出并修掉 App 的偏差」，**不打包 App**（本机没有 Xcode），
> 改动在 PR 里等明天到公司用真机复验。

## 一、对齐时查到的偏差与处理

### 已修（有测试或明确依据）

1. **固件升级第二阶段根本没重连**（`device_store.dart`）
   主控 DFU 后循环里只 `scan()` + `snapshot()`，从未 `connect()`。桥在 DFU 前已取走设备句柄，
   `snapshot` 只会报「未连接」，10 次重试后固定失败「升级后未能重新连接录音卡」。
   参考实现 DFU 后要求重新扫描连接，也不会直接读状态。
   → 扫描到目标后 `connect(target.id)`；测试：`web_parity_test.dart`「固件第二阶段」。
   顺带把重连超时从 12s 提到 20s（桥内 4s→6s 两档扫描 + 建链路）。

2. **App 的 connect 预拉整份状态快照**（`card_bridge` / `card_gateway` / `device_store`）
   桥的 `connect` 连发 BASE_INFO/STATE_INFO/BATTERY/STORAGE/RECORD_STATUS 五条命令才返回；
   任一条失败（旧固件字段缺失）会把「已经连上」判成「连接失败」，慢的时候还会撞上 Dart 侧超时。
   参考实现的 `/api/connect` 只回 `{connected:true}`，状态卡另外查。
   → 桥 `connect` 只建链路并回 `{connected:true}`；`CardGateway.connect` 返回 `CardSnapshot?`（真实实现为 null）；
   `DeviceStore` 收到 null 不覆盖状态，连上后由 `_afterConnect → refreshFromDevice` 补一次；
   `_afterConnect` 里多余的 `syncTime()` 也删了（SDK 的 connect 内部已同步过时间）。
   测试：「连接返回空快照」。

3. **BASE_INFO 失败会拖垮整份快照**（`card_bridge`）
   battery/state 早已降级到原始回包，但 `device_info().await?` 仍是硬失败。
   参考实现从不因「设备信息读不到」拒绝连接。
   → BASE_INFO 同样降级到 `raw_command`，再失败就留空；电池/录音状态照常返回。

4. **STORAGE 的剩余量读错字段**（`card_gateway`）
   SDK `StorageInfo` 只有 `total` / `used`，App 读的是不存在的 `free`，永远得到 0。
   → `free = total - used`（负数按 0）；测试：「STORAGE」。

5. **电量读不到时冒充 1%**（`card_gateway` / `device_store`）
   `CardSnapshot` 没有「是否读到电量」，`_applySnapshot` 又把 0 `clamp(1,100)`，界面显示「1% 电量低」。
   参考实现在 `level === undefined` 时不渲染电量。
   → 新增 `CardSnapshot.hasBattery`；没读到就保持「未知」，不 clamp 出假数字。测试：「电量读不到」。

6. **设备自停的错误码被吞**（`device_store`）
   固件 `RECORD_STATUS` 推送带 `error`（如 -2）时，App 只把开关关掉，不告诉用户；参考实现会展示整条状态。
   → `_applyRecordStatus` 把 error 写进 `recordingError`（弹层就地展示）；新录音开始时清空。测试：「设备推送录音错误码」。

7. **停止录音后自动同步与实时流关闭并发**（`app_shell`）
   原来 `unawaited(_liveAudio.stop())` 紧接着 `unawaited(_autoSyncAfterRecording())`；
   取文件可能赶在 `RECORD_REALTIME_ENABLE(false)` 之前开始。SDK 文档明确要求取文件前不能有实时流/录音在跑
   （二进制帧不区分音频与文件数据）。
   → 改成 `_onRecordingStopped()`：先 `await _liveAudio.stop()` 封口 WAV/关实时流，再同步；
   封口期间用户重新开录则跳过本次同步。测试：「停止录音：先关实时流，再开始取文件」。

8. **打点命令绕不过 STATE_INFO 预检**（`card_bridge`）
   `record_mark()` 先 `require_sd_on_nrf` → 严格解析 STATE_INFO；字段不全的固件在**发命令前**就失败。
   网页的「打标」按钮直接发 `RECORD_MARK`。录音开关在 PR #31 已改用原始命令，打点漏了。
   → `mark` 改发 `raw_command("RECORD_MARK")`（`request_value` 仍会检查 `code`）。

9. **主控 DFU 后无限期等待断连**（`card_bridge`）
   `ota_main` 在 DFU 结束后 `device.disconnect().await` 没有上限；平台断连回调丢失时，
   升级结果永远发不出去。参考实现直接丢弃句柄。
   → 加 3s 上限，绝不阻塞最终结果。

10. **Wi-Fi 模组 OTA 缺少联网预检**（`card_bridge`）
    参考实现在 `OTA_WIFI_CHECK` 前先 `wifi_status()`，模块没连路由器时给出可执行提示。
    App 直接把固件错误码抛给用户。
    → 同样预检（`WIFI_STATUS` 不可用时放行，交给设备判断）。

### 查到但本轮**没改**的（需要 owner / 真机决定）

- **实时流开启顺序**：SDK 的 `start_realtime_recording` 是「先开实时传输，再 RECORD_START」，
  App 是录起来后再开流。试过把开流前置到 `toggleRecording`，但开流要做目录/文件 IO，
  会卡住录音命令（widget 测试直接挂起），而且参考实现的「开始」按钮本身不开实时流。
  结论：实时流是辅助能力，不能挡录音；是否改成 SDK 会话式（`start_realtime_recording`）需单独评估。
- **`LiveAudioRecorder.bindFileToSession` 没有任何生产调用**：详情页「原始数据」按文件名找不到绑定时，
  会回落到「最新一个实时会话」，可能播错录音。需要按时间把设备切片映射到实时会话，设计待定。
- **`code -2` 的成因**：仍无权威定义；本轮没有抓 App 侧原始回包（需要真机）。
- **Wi-Fi 快速传输（AP）**：参考实现支持热点 HTTP 快传；App 仍走 BLE 文件拉取（阶段性设计，不是缺陷）。

## 二、验证

- `flutter analyze`：0 issue
- `flutter test`：**246 项全过**（原 240 + 本轮 6 项）
- `cargo check`：通过
- 新增测试：`app/test/web_parity_test.dart`（storage、电量未知、空快照连接、固件第二阶段、录音错误推送、停止顺序）
- **未验证**：真机（本机无 Xcode / iphoneos SDK）；固件升级、打点、OTA 预检都需要明天装机复验。

## 三、明天到公司建议按这个顺序验

1. 连卡 → 看电池/存储：电量应为真实百分比（不再 1%），存储剩余量应等于 `总量 - 已用`。
2. 连接耗时：应明显短于以前（不再等 5 条状态命令）；胶囊连上后 1 秒内出数据。
3. 固件升级：主控阶段结束后应真正进入 Wi-Fi 阶段，不再停在「升级后未能重新连接录音卡」。
   若卡未连 Wi-Fi，应先看到「Wi-Fi 模块未连接路由器」的中文提示。
4. 录音中打点：应返回成功（不再报 STATE_INFO 解析失败）。
5. 停止录音 → 看日志顺序：先 `realtime.close`，再开始列文件/取文件。
6. 设备侧制造录音错误（如拔卡）→ 弹层应出现「录音中断（设备错误码 …）」。
