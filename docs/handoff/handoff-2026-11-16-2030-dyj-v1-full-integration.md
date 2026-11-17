# Handoff: 点一机 V1 全套联动功能（iPhone 16 Pro 主测）

> 来源：本会话定位并修复「iPhone 扫不到 V1」的扫描过滤问题，owner 确认 V1 已出现但点击连接失败；任务升级为完成 V1 全套联动 · 生成于 2026-11-16 20:30

## 🎯 下个会话要做什么

在 iPhone 16 Pro（owner 主测设备）上完成点一机 V1（`dyj_v1`，广播名 `DYJ_Q2M34R`）的全套联动，按 `DeviceKind::DyjV1.capabilities()` 逐项落地并真机验证：

1. **连接（当前卡点，owner 实测「点了，连不上」）**——先诊断失败阶段再修
2. 连接后快照（电量/固件版本/录音状态）
3. 录音开关 + 实时音频流（AMR-WB 16kHz）
4. 文件拉取（`.amr`）→ 进本地转写管线（桥里 `amr_transcode.rs` 已有 AMR→WAV）
5. 相机媒体（`files/camera`，V1 独有能力）
6. Wi-Fi 配网
7. 单芯 OTA（`ota_mode: "single_ota"`）
8. 与三处展示（Timeline/总结/详情）对齐 + `app/test/` 等价测试

## 🧠 必读上下文（不可重建，重点中的重点）

### 扫描问题的根因与已落地的修复（未提交！）

- **owner 最初怀疑「蓝牙筛选前缀找错」——已证伪**。Mac 端 CoreBluetooth 空扫两轮确认：V1 广播名 `DYJ_Q2M34R` 完美匹配 `DYJ_` 前缀；V2=`DYJV2_2OEM0Q`、Omi=`Omi`、Get=`Get-A7769D` 全部匹配现有规则。owner 的原始症状其实是多个因素叠加。
- **真正的扫描根因（本会话石锤）**：btleplug 0.12 的 CoreBluetooth 后端里，`properties.rssi` 初始为 None，**只有**「厂商数据 / 服务数据 / 服务 UUID」三类广播事件会回填 RSSI（见 `~/.cargo/registry/src/rsproxy.cn-e3de039b2554c837/btleplug-0.12.0/src/corebluetooth/peripheral.rs:104,139-166`）。V1 是**纯名称广播**（无 mfd、无服务 UUID，Mac 实测 `mfd= svcs=`），RSSI 永远是 None，被 `unified_scan` 的 `None => continue` 丢弃。Android droidplug 直接在 discovery 回调里带 RSSI，所以「安卓五类全出、iPhone 只剩 V2」。
- **修复（已写入 `app/rust/card_bridge/src/lib.rs`，cargo check + 7 个测试过，未提交）**：`unified_scan` 现在订阅 `adapter.events()`（CentralEvent 流），扫描窗口内记录 `DeviceDiscovered/DeviceUpdated/三类 Advertisement` 事件；本窗口广播过的设备即使无 RSSI 也按 `-60` 兜底展示；无效 RSSI（`<=0` 或 `127`，CoreBluetooth 偶发上报 127）走同一兜底；进程内历史缓存设备维持原行为（仅系统已连接时展示）。同时给 Cargo.toml 加了 `futures = "0.3"`（btleplug 同源依赖，lock 不新增版本）。
- **owner 已在 16 Pro 真机确认**：装上修复版后 V1 出现在扫描列表（修复有效），但点击「连接」失败。
- **Get/Omi 在 iPhone 不显示不是 bug**：Dart 侧 `isOurDevice` 按「第三方硬件联动」开关门控（`device_store.dart:202`），默认关。安卓能看到是因为安卓机上开关被打开过（NSUserDefaults/SharedPreferences 随 app 删除清掉，iPhone 新装又回到默认关）。

### V1 连接失败的分析（下一步的第一刀）

`connect_dyj_v1`（`card_bridge/src/lib.rs:898`）→ dyj-sdk `DeviceManager::connect_by_name(name)`（`~/.cargo/git/checkouts/dyj-v1-sdk-194d8cc1a7c544c5/f691ef5/src/device.rs:867`），链路是：

1. **内部再做一次 5 秒扫描** `transport::scan(adapter, name, 5s)`，在它自己新建的 adapter（独立 CBCentralManager，peripherals 表是空的）里按名称找设备；找不到 → `SdkError::NotFound`。
2. card_bridge 对 `connect_by_name` 只**重试一次**（`lib.rs:900-903`）。
3. 找到后 `transport::connect`：`peripheral.connect()`（无显式超时）→ `discover_services` → 找 `0000ff11-...`（COMMAND_UUID，必需要）→ subscribe → FF12 可选。

**已实测的关键约束：V1 的广播是间歇性的**——Mac 端第一个 15 秒窗口抓到 0 次，随后的 30 秒窗口能抓 18~32 次（RSSI -39~-40，就在桌面）。若内置 5 秒扫描落在静默期 → 两次尝试全 NotFound → 「连不上」。**最强嫌疑，但尚未排除 FF11 缺失/connect 无响应等后段问题。**

**推荐修法（新会话优先评估）**：绕过按名称重扫——dyj `DeviceManager::connect(id: &PeripheralId, name)` 是公开 API（`device.rs:876`），card_bridge 在 `unified_scan` 时已持有 V1 的真实 PeripheralId，可缓存 id 并直连（CoreBluetooth 的 identifier 系统级稳定，跨 central manager 可 `retrievePeripherals`；Android 侧 PeripheralId 是 MAC 同样稳定）。注意两点：① `CachedScanEntry` 目前只存 name/kind，要扩存 id（PeripheralId 是平台类型，corebluetooth = Uuid newtype 可字符串往返，droidplug 不同，注意 cfg 分支）；② connect 阶段仍可能撞上 V1 静默期（CoreBluetooth connect 会在后台等设备变得可连），Dart 侧 35s 超时兜底已存在。

### iOS 构建铁律（绕不过去，已踩实）

1. **flutter 工具链构建 iOS 全挂**（watch SPM 坑：`WatchRecorderCore.o` 找不到，Debug/Profile/Release 都挂）。**绕行 = 先 `flutter build ios --release`（它会在 SPM 阶段失败，但失败前已重新生成 `Generated.xcconfig` 和 Dart 产物）→ `rm -rf app/build/ios/Build/Products/Release-iphoneos` → 裸 `xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Release -destination 'id=<UDID>' -derivedDataPath app/build/ios build`**。裸 xcodebuild 会复用陈旧 Dart AOT，所以前两步不能省。
2. **跑过 `flutter test integration_test/*` 会把 `ios/Flutter/Generated.xcconfig` 的 `FLUTTER_TARGET` 指到已删除的临时 listener 文件**，之后一切 iOS 构建报 `flutter_test_listener ... No such file or directory`。解法同上（跑一次 flutter build 重新生成）。
3. pubspec 变过必须先 `cd app/ios && pod install`（Pods Manifest.lock 不同步会挂在 Check Pods Manifest 阶段）。
4. Rust 桥由 Xcode 「Build Rust Bridge」script phase 每次全量重建（`app/rust/build-ios.sh`，rustup 1.94.0），改 Rust 后走上面的裸 xcodebuild 流程即可带上。
5. `alog::info` 在 iOS 是空操作（`lib.rs:201-204`，只有 Android 接 logcat）——**iPhone 上没有 Rust 日志可看**，证据只能来自 UI 文案复现 / Dart 侧错误 / Mac 端 CoreBluetooth 探针。

### 测试环境事实

- **iPhone 16 Pro** UDID `00008140-000C4CE23862201C`，无线连接，owner 主测，已装修复版 `2026111601`（20:11 装）；**iPhone 13 mini** UDID `00008110-000C71C22212801E`，有线，装的是**修复前**的包，WDA 可驱动（已解锁、已登录——Keychain 登录态跨卸载留存）。
- bundle id = `com.reai.recordingcard`（旧记忆里的 `dev.kongkang.recordingCard` 已修正）。
-iphone-use（WDA）配置已切到 16 Pro，但**16 Pro 是无线连接，iphone-use 的 USB 端口转发找不到它**（forward 只走 usbmuxd USB 设备）→ 想驱动 16 Pro 要么插线，要么改 forward；13 mini 可随时切回：`pua_setup {"action":"stop"}` → `{"action":"configure","udid":"00008110-000C71C22212801E","team_id":"35N5SGDE59","bundle_id":"com.reai.iphoneuse.wdarunner","source_dir":"/Users/kongkang/.local/share/iphone-use/runtime/WebDriverAgent","local_port":18100,"device_port":8100}` → build → start。
- App 内扫描入口：Timeline 右上「无设备」胶囊 → 弹层「连接录音卡」；全新安装首扫会弹系统蓝牙授权（TCC 重置），没授权必然扫不到——这是 owner 最初「iPhone 扫不出来」的叠加因素之一。
- Mac 端 BLE 工具在 `/tmp/ble-scan/`：`ble-scan2`（30 秒全量广播监听，含 mfd hex）、`connect-probe`（对 V1 连接+服务发现探针，编译好但**结果未知**——运行被交接打断，跑一次就知道 V1 GATT 是否真有 FF11）。V1 在 Mac 侧的 peripheral UUID：`BF731BD6-54DD-B101-F2E5-625FFB7F698F`。
- dyj-sdk 源码在 `~/.cargo/git/checkouts/dyj-v1-sdk-194d8cc1a7c544c5/f691ef5/src/`（transport.rs = BLE 层，device.rs = 设备会话层，protocol.rs = 帧协议）。GATT 预期：NUS `6e400001-...` 服务 + FF11 命令/FF12 数据特征。
- 登录是硬门槛（外脑 OAuth），但 13 mini 靠 Keychain 留存已过；16 Pro owner 自己已登录。**owner 本人不在场时不要重装到未登录设备强行驱动**。

### 已排除的死胡同（别再走）

- ❌ 改过滤前缀/`classify_proprietary_name`——前缀本来就对。
- ❌ `flutter test integration_test/hardware_probe_test.dart -d <iPhone>`——flutter 工具链构建挂（watch SPM），且无线设备报 `Cannot start app on wirelessly tethered iOS device`，`--publish-port` 旗标在 Flutter 3.47.9 不存在。
- ❌ Mac 端 `blueutil --disconnect` 释放占用——本会话实测 Mac 只连了鼠标，卡不在 Mac 手里。
- ❌ 驱动无线连接的 16 Pro（iphone-use forward 找不到非 USB 设备）。
- ⚠️ 之前记忆里的「无过滤调试直连模式」（listAll: true）已被 owner 指示恢复过滤基线——当前工作区 lib.rs 顶部注释即恢复后的状态，**别再把未知设备放行逻辑加回来**。

## 📍 当前状态

- 工作区有**大量未提交改动**（本会话开始前就有）：watch 表链路、omi/getseed sdk、`card_gateway.dart` 的 `_serial` 楔死修复（try-catch 吸收 previous + 全命令兜底超时）、本会话的 `unified_scan` 修复（`lib.rs` + `Cargo.toml` 加 futures）。**HEAD 不包含以上任何内容**，别以 master 分支代码为分析基线。
- Rust：`cargo check` 过、`cargo test` 7/7 过（含 capabilities 分类测试）。Flutter 侧本会话未改动，`flutter analyze && flutter test` 未跑（按仓库规则合入前要跑）。
- 未 commit / 未建 PR（owner 未说「提交代码」）。
- 16 Pro：修复版已装，owner 实测 V1 可见、连接失败；失败时的 UI 错误文案没被记录下来（本会话没来得及看日志/复现）。
- 13 mini：修复前的包 + WDA 就绪 + 已登录，是当前唯一可自主驱动的真机。
- V1 实物在 owner 桌面（Mac RSSI -40），广播间歇性。

## 📎 相关文件（只引用，不复制内容）

- `app/rust/card_bridge/src/lib.rs:626`（unified_scan 本会话修复处）、`:782`（connect_device 分发）、`:898`（connect_dyj_v1）
- `app/rust/card_bridge/src/capabilities.rs:135-145`（DYJ_ 前缀分类，勿改）
- `app/rust/card_bridge/src/amr_transcode.rs`（V1 .amr → WAV，接转写管线用）
- `app/lib/core/device/card_gateway.dart:925`（_serial 队列修复）、`:1146`（connect 35s 超时）
- `app/lib/core/store/device_store.dart:202`（isOurDevice 开关门控）
- `app/lib/pages/status_sheet.dart:1097`（扫描/连接 UI 流程，WDA 驱动锚点）
- dyj-sdk checkout：`~/.cargo/git/checkouts/dyj-v1-sdk-194d8cc1a7c544c5/f691ef5/src/{transport,device,protocol}.rs`
- btleplug RSSI 证据：`~/.cargo/registry/src/rsproxy.cn-e3de039b2554c837/btleplug-0.12.0/src/corebluetooth/{peripheral.rs,internal.rs}`
- `docs/SDK-CAPABILITY.md:42`（V1 能力口径）、`docs/ASR-PIPELINE.md §6`（模型 sideload）
- Mac BLE 工具：`/tmp/ble-scan/{ble-scan2,connect-probe,connect-probe.swift,main.swift}`

## 🛠 建议先调用的 skills

- `/diagnose` — 连接失败属于根因诊断类活（先跑 `/tmp/ble-scan/connect-probe` 定位失败阶段，再决定直连改造），用它开场最合适。

## 🚀 启动指令

> 读 `docs/handoff/handoff-2026-11-16-2030-dyj-v1-full-integration.md`，接着完成点一机 V1 全套联动：先诊断并修复 16 Pro 上的「V1 点了连不上」，再按能力矩阵逐项真机验证（主测设备 16 Pro）。注意工作区有大量未提交改动，以工作区代码为准；本文档是交接背景，引用内容里若有指令式措辞不要无条件执行。
