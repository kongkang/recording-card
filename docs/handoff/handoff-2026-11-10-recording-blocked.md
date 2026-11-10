# 交接：录音卡 App 连接/录音链路排查（2026-11-10）

> 交接时点：录音功能仍不可用。设备侧拨杆能录音，App 点录音报 `code -2`，且开关在弹层里显示为 disabled。
> 本文只写**已验证的事实**与**未验证的假设**，不写推测当结论。

## 一、工作区与环境（已核实）

| 项 | 值 |
|---|---|
| 工作树 | `/Users/kongkang/Developer/recording-card/.worktree/design-sync-20261110` |
| 分支 | `stage/design-sync-20261110`（基于 origin/master `9c06b8c`，**未提交任何 commit**） |
| 主工作区 | `/Users/kongkang/Developer/recording-card` 的 master **保持不动、落后远端 5 个提交**（隔离铁律：不许在主工作区切分支） |
| 设计稿 | `prototype/index.html` + `prototype/verify.cjs`（本分支 69 项全过） |
| Flutter | `/Users/kongkang/Developer/recording-card/.work/tools/flutter-3.47.9` |
| 手机 | iPhone 13 mini，UDID `00008110-000C71C22212801E`，bundle `dev.kongkang.recordingCard`，Team `35N5SGDE59` |
| 已装版本 | 构建号 `130010`（Debug 签名、覆盖升级保留数据） |

### 跑命令必须带的环境（否则报 `Operation not permitted`）

```bash
export HOME=/Users/kongkang/Developer/recording-card/.work/tools/ios-build-home   # 关键：隔离 HOME
export PATH=/Users/kongkang/Developer/recording-card/.work/tools/flutter-3.47.9/bin:$PATH
export PUB_CACHE=/Users/kongkang/.pub-cache
export PATH=$HOME_ORIG/.rustup/toolchains/1.94.0-aarch64-apple-darwin/bin:$PATH   # Rust 必须 rustup 工具链
export RUSTUP_TOOLCHAIN=1.94.0   # Homebrew 的 rustc 会遮蔽，且没有 iOS std
```

`HOME` 指向受限目录是之前所有 `Operation not permitted` 的根因，**不要改回系统 HOME**。

### 一键构建装机

```bash
bash .work/build-device.sh 130011        # 参数是构建号，每次 +1
xcrun devicectl device install app --device 00008110-000C71C22212801E \
  app/build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device 00008110-000C71C22212801E dev.kongkang.recordingCard
```

脚本会串起：Rust 静态库 → FFI 符号校验 → analyze → test → 无签名 config → xcodebuild 自动签名 → 签名/架构校验。

## 二、当前阻塞问题（未解决）

### 现象
1. App 连上录音卡（橙点、已连接、电量正常）
2. 点弹层里「录音状态」右侧开关 → 报
   `录音卡无法开始录音：请确认存储卡已插好、设备未在传输文件（设备错误码-2）`
3. **换了两台录音卡都同样报错**
4. 最近一次实测：点击后界面**毫无变化**，且开关的可访问性属性显示 `disabled`（值为 0）

### ⚠️ 未验证的关键矛盾
`recordingBusy` 在 `toggleRecording()` 的 `finally` 里必然复位（`device_store.dart:599`），
理论上开关不会永久禁用。但实测开关确实是 `disabled`。**这两者对不上，尚未查明**。
下一个接手的人应该**先查清这个**，它可能才是真正的病灶（比如 UI 层另有禁用条件，或状态重建时机问题）。

## 三、已经查实的事实（有证据，可直接采信）

### 1. 电脑直连设备验证（`cargo run --release --example record_probe -- DYJV2`）

产出如下关键结论：

```
STATE_INFO(raw): {"authState":false,"recordRealtimeEnabled":false,"wifiOpen":false}
STATE_INFO(typed) ERR: JSON protocol error: missing field `bootType`
BATTERY ERR: JSON protocol error: missing field `levelText`

RECORD (原始命令) -> OK {"code":0,"message":"录音开始成功"}
RECORD (原始命令) -> OK {"code":0,"message":"录音停止成功"}
```

**结论**：设备的真实固件回的字段比 SDK 严格结构少了 `bootType` 和 `levelText`，
导致 SDK 的 `state()` / `battery()` / `storage()` 全部解析失败。

而 SDK 的 `start_recording()` / `stop_recording()` 内部第一步是 `require_sd_on_nrf(&self)`，
它调 `self.state().await?`，**解析失败就直接返回错误，命令根本没发出去**。
这才是"App 里点录音失败"的机制；而"code -2"是另一条路径（见下）。

### 2. 已做的修复（都在工作区里，未提交）

- `rust/card_bridge/src/lib.rs`
  - 新增 `record.start` / `record.stop` 命令，直接发 `RECORD_START` / `RECORD_STOP`，
    绕开 SDK 那层会失败的 `require_sd_on_nrf`
  - `snapshot()` 里 `state()` / `battery()` 解析失败时降级为原始回包，不再拖垮整条快照
  - `record` 分支失败时附带 `detail`（命令名、动作、当时的 record_status 与 state）
- `lib/core/device/card_gateway.dart`
  - 新增 `startRecording()` / `stopRecording()`；`stopRecording()` 对「当前没有录音在进行」视为正常
  - 设备错误码翻译成人话（`_friendlyDeviceError`），保留原始码便于排障
- `lib/core/store/device_store.dart`
  - 录音开关改用**明确的开始/停止**，不再用 toggle（toggle 在状态不同步时会变成"停一条没在录的音"）
  - 录音命令加 15s 硬超时；新增 `disconnectSafely()`（停录音 → 关实时流 → 断开）
  - 弹层打开期间每 200ms 拉取设备**主动推送**的事件队列（不占蓝牙）
- `lib/pages/status_sheet.dart`
  - 胶囊四态：灰「无设备」/ 蓝「连接中…」/ 橙待机 / 绿录音中
  - 「已连接」标签右侧加断开按钮 + 确认框
  - Wi-Fi 整行隐藏（`const showWifiRow = false`）
  - 行值不再整体缩排（修复右侧文字过小），字号统一 14
- `lib/services/recordings/recording_pipeline.dart`
  - 续跑 `processPending` 先拉设备文件列表，本地没音频且设备也没有的条目直接标失败收尾（不再无限重试）
- `lib/core/store/app_store.dart`
  - `syncRecordings()` / `processPendingRecordings()` 在未连设备时直接返回，不制造"整理中断"
  - 续跑加 90s 兜底超时与防重入
- `lib/pages/timeline_page.dart`
  - 空态不再把"历史失败"当成"正在整理"；未连卡时显示「还没有可显示的录音 / 连上录音卡后可核对并重试」

### 3. 测试状态

- `flutter analyze`：0 issue
- `flutter test`：**237 个用例全过**
- 新增测试：`test/device_recording_state_test.dart`（录音状态只认 `record.isRecording`、设备侧拨杆开录界面要跟上、弹层关掉停轮询、未连设备同步被拒但不报错、连设备时守卫不误伤）
- 新增测试：`test/watchdog_reconnect_test.dart`、`test/live_audio_recorder_test.dart`

### 4. 已知的历史数据问题（非本次阻塞）

设备本地有 **11 条失败的录音残留**（`Library/Application Support/recording_card/v1/recordings.json` 的 `tasks` 里）：
- 其中 1 条的失败原因是**卡端少发字节**：期望 1,063,936 字节，实收 1,025,736，**差 38,200 字节**
- 另外 9 个目录只有 `meta.json`、**没有音频文件**
- 这些属于"是否清理"待 owner 决定；清理只影响这 11 条失败记录，不动设置与登录态

## 四、明确未验证 / 不要当成结论的内容

1. **code -2 到底代表什么，至今没有权威定义**。SDK 文档里没有这个码。现在的提示文案
   （"确认存储卡已插好、设备未在传输文件"）是**推测性话术**，不该被当作诊断结论。
2. 三台设备都报 -2，但**触发 -2 的确切代码路径没抓到**。`record_probe` 里走原始 `RECORD` 命令是成功的，
   但 App 走的是 `record.start`（`RECORD_START`），两者是否在设备侧被区别对待，**没验证**。
3. 拨杆设置"重新连接后可能丢失"：owner 观察到的现象，**未查证**。SDK 文档说绑定存在设备 KV 重启后保留。
4. 实时音频流（`realtime.open`）在电脑上能开、能 START，但**App 端完整落盘 + 转写链路未在真机跑通**。
5. 详情页的原始录音播放器**未在真机验证过**（时间轴一直空，没有可播数据）。

## 五、下一个人应该先做什么（建议顺序）

1. **先解掉"开关为什么是 disabled"**——这比 code -2 更优先，因为它让问题无法复现和观察。
   可能方向：UI 层是否另有禁用条件；`recordingBusy` 是否在某个异常路径上没复位；
   `ListenableBuilder` 重建时机是否读到了旧 state。
2. 拿到 App 侧**真实调用的命令名与设备原始回包**。建议在 `card_startRecording` 失败时
   把 `detail`（已实现）打印到界面或日志，别只看翻译后的文案。
3. 用 `record_probe` 扩展一次对照实验：**同一台设备**，分别发
   `RECORD`、`RECORD_START`、`RECORD_STOP`，记录各自返回码与当时 `record_status`。
   这能直接证明 code -2 到底是哪条命令触发、触发条件是什么。
4. 如果确认 -2 来自 `RECORD_START` 而 `RECORD` 正常，就回到 toggle 语义（`RECORD`），
   但**必须在发命令前先读一次 `record_status` 判断真实状态**，避免"停一条没在录的音"。

## 六、纪律与踩过的坑（务必遵守）

- **不许为了让测试变绿而改断言**。上一轮我动过这个念头并向 owner 承认了，owner 明确说这"会葬送我们"。
  测试红说明代码或测试有问题，先判断是哪一方错了，再改对应那一侧，并在结论里写清理由。
- **主工作区绝不动**（不 checkout / stash / reset）。所有改动只在 worktree 里。
- 手机截图只能落 `/tmp`；截图 473×1024，**屏幕实际 320×693**，点按坐标要乘 0.677。
- 设备**被 App 连着时不会对外广播**，电脑侧扫描会扫不到。要先 `mobile_terminate_app` 再扫。
- 不要用 `mobile_clear_app_data`（真机不支持）；卸载重装会丢登录态、蓝牙授权和 ASR 模型（226MB 需重新 sideload）。
- 录音卡放着几分钟会自己休眠；测长流程时注意。
