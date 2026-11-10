# 交接：断连未释放 BLE 链路（2026-11-10 第二轮）

> 接上一份 `handoff-2026-11-10-recording-blocked.md`。PR #31 修完了「开关无限卡在忙/无障碍禁用」，并在文末列出
> **「点断开连接后蓝牙链路并未释放」**这个问题留待单独一轮。本文就是那一轮。
>
> 结论先说：**代码层已修，真机未验证**（本机没有 Xcode / iOS SDK，也没有接手机）。

## 一、问题回顾（来自 PR #31 的实测记录）

- App 里点「断开连接」后界面显示已断开，但电脑侧扫不到录音卡（设备被 App 连着时不广播）。
- 杀掉 App 约 6 秒后设备重新出现——说明连接是被系统在进程退出时兜底断掉的，不是我们断掉的。

## 二、代码层查到的四个成因（全部在本轮修掉）

1. **事件泵自引用持有设备句柄**（`card_bridge/src/lib.rs`）
   `spawn_event_pump(device.clone())` 把 `DyjDevice` clone 进常驻任务；任务不退，句柄就不释放，
   旧链路的 Core/Transport 一直活着。断连只清掉了 `state().device` 这一份引用。
2. **每次 connect/scan 都新建 `DeviceManager`**（同上）
   平台蓝牙栈（iOS 上是 CBCentralManager）随 `connect()` 返回被丢弃，它名下的连接失去可管理句柄：
   下一次连接会形成第二条链路，断连只能断掉最新那条，旧链路留在设备端。
3. **断连无条件上报成功**（同上）
   `dispatch("disconnect")` 无论有没有设备、SDK 断没断成功都回 `{"disconnected":true}`；
   Dart 侧把「命令发出去了」当成了「已经断开」。
4. **看门狗只改 UI 状态（假断开）**（`device_store.dart`）
   探测失败 → 直接把胶囊切成蓝点/灰点再重连，没有先释放桥里的旧句柄；
   设备端因此继续认为「已连接」，不重新广播，重连扫描也扫不到它。
   另外：**重连成功后没有重启心跳**，一次掉线重连之后就再也没人探测。

## 三、改动

### Rust 桥（`app/rust/card_bridge/src/lib.rs`）

- `BridgeState` 新增 `manager: OnceCell<DeviceManager>`：扫描/连接/OTA 共用同一套平台栈，进程内只建一次。
- 事件泵改为 `spawn_event_pump(&device) -> JoinHandle`：**任务里只持有事件接收端**，不再持有 `DyjDevice`；
  句柄一丢，发送端关闭，任务自己结束。句柄存进 `event_pump`，断连/重连时先 `abort()`。
- 新增 `release_device()`：按「停事件泵 → 停实时流 → 取走设备 → 带 8s 超时调 SDK 断连」执行，
  返回如实结果：
  `{disconnected, hadDevice, deviceId, sdk: ok|error:…|timeout, released}`。
- `connect` 在扫描前先 `release_device()`，避免新旧两条链路并存；快照失败时也主动 `disconnect()` 再报错。
- `snapshot` 不再跨 5 条命令长期占住 device 锁，用户点断开不用等快照跑完。
- OTA 前同样先停泵、清 `last_device_id`；DFU 复用共享 manager。
- `manager()` 用 `OnceCell::get_or_try_init`，初始化失败下次还能重试。

### Dart 网关 / 状态机

- `CardGateway.disconnect()` 由 `Future<void>` 改为 `Future<CardDisconnectReport>`
  （`released` / `hadDevice` / `detail`）；桥的 `released=false` 不会被吞掉。
- `DeviceStore.disconnectDevice()`：带 12s 超时；失败原因（超时/桥报未释放）写进 `linkError` 并在弹层就地展示，
  成功则清空错误。桥不可用（模拟器）不算用户错误，不提示。
- 看门狗：探测失败后**先 `_releaseLink()` 再重连**；重连失败再释放一次半开连接；
  重连成功后 `_startHeartbeat()` 重新挂表。
- 没有设备 id 可重连时，先立刻回灰点（不让用户干等蓝点），再后台尽力释放旧链路。

### 构建脚本（`app/rust/build-ios.sh`）

- 不再写死宿主三元组 `aarch64-apple-darwin`，按 `$RUSTUP_HOME/toolchains/1.94.0-*/bin` 查找
  （Apple Silicon / Intel 都能构建）；顺手修了 warning 文案里 `$TOOLCHAIN，` 在 `set -u` 下触发
  `unbound variable` 的问题（Intel 上必现）。

## 四、验证（如实）

- `cargo check`：通过
- `cargo build --release`（宿主 macOS）：通过，桥完整链接
- `flutter analyze`：0 issue
- `flutter test`：**240 项全过**（原 237 + 新增 3 项：桥确认释放、桥报未释放如实提示、桥不可用时仍落到未连接）
- 看门狗测试新增断言：判定掉线先 `disconnect` 再 `connect`（顺序用 `disconnectCallsAtConnect` 锁定）、
  重连成功后心跳继续值班
- **未验证**：
  - iOS 静态库构建（本机只有 CommandLineTools，没有 Xcode / iphoneos SDK）
  - 真机断连后电脑侧能否立刻扫到设备
  - 真机看门狗掉线 → 释放 → 重连的完整动线
  - `code -2` 的 App 侧原始回包（需要设备在线抓日志）

## 五、下一轮建议

1. 在装有 Xcode + 真机的机器上 `bash .work/build-device.sh <build>` 装机，复验：
   点断开 → 电脑侧 10 秒内能扫到设备；App 里点重连能扫到同一台。
2. 看门狗复验：录音卡放远/断电 → 胶囊蓝点 → 恢复后自动回橙/绿，且之后仍会每 30 秒探测。
3. 若断连仍偶发不释放，抓桥日志 `[card_bridge] disconnect had_device=… sdk=… released=…`
   ——现在每次断连都会打印，能直接区分「桥里没设备」和「SDK 断连超时」。
4. `code -2` 的 App 侧原始回包仍未抓到；`record.start` 失败时桥会带 `detail` 打到 `debugPrint`，装机后复现一次即可取到。
