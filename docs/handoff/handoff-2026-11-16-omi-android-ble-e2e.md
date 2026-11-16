# Handoff · Omi Android BLE 打通与录音闭环（2026-11-16）

> 状态：**E2E 已在 Jelly Star 真机验证通过**（录音 → 切片 → SenseVoice 本地转写 → Timeline 文本记录）。
> Owner 计划晚些真机复验，本文给出验收步骤与已知边界。调试直连模式（无过滤列出）已按 owner 指示还原为过滤基线。

## 一、最终验收证据（2026-11-16 20:44-20:46，Jelly Star 实录）

- Timeline 出现转写文本记录：**「产品评审会与蓝牙调试工作 20:39 · 1分47秒 · 已合并 2 分片」**
  （音源 = Mac `say` 播放的测试稿，Omi 放在 Mac 喇叭旁拾音；标题为转写后自动生成的摘要）
- 状态块「正在录音 已录 00:05:18 · 已存 1 片」；停录后尾片冲刷正常合并。
- Mac bleak 直连差分实验：codec=21 (OpusFS320)、订阅即推流、说话期间 ~48 包/秒稳定收流。

## 二、Omi CV1（固件 3.0.21）设备行为清单 · 重要

| 行为 | 说明 | 对产品的影响 |
|---|---|---|
| **VAD 门控推流** | 订阅即吐 ~240 包预滚缓冲；静默期**零发包**；有声立即恢复 ~48 包/秒（20ms 帧） | 属正常策略，不是 bug；「录音中但 0 包」先确认是否有声音 |
| **无 mute 特征** | `19b10015` 在该固件上不存在 | SDK 的 mute 写是防御性空操作，无需修改 |
| **环形下载挂起实时流** | `list_files`/ring 下载完成后固件不再推 BLE 实时音频，**重启设备才恢复** | 待办：录音期间避免触发 ring 同步；或向官方求证恢复方式 |
| **环形存储持续积压** | 设备持续把音频写板载 ring（`OMI_RING_<read>_<write>.wav`），App 自动同步取回 | 离线补录通道正常；大量积压时 BLE 下载耗时长 |
| **长下载占用命令队列** | ring 下载期间 Dart `_serial` 串行队列被占，`record.start` 等排队超时（曾报「录音命令超时」） | 待办：长下载移出串行队列或并发化 |
| **~100 秒后停流（疑似）** | Android 侧连续推流约 100 秒后通知停止；Mac 同场景 60 秒内正常。疑似 droidplug 未请求 `CONNECTION_PRIORITY_HIGH`（官方 App 会请求），连接参数降档后 20ms×50pkt/s 超出低档链路能力 | 待办：给 droidplug 补 `requestConnectionPriority` 或换官方参数策略 |

## 三、本次修复清单（按层）

### Rust `card_bridge`（`rust/card_bridge/`）
1. **线程附加**：`on_thread_start(ensure_jvm_thread_attached)` —— droidplug 从任意线程取 `JNIEnv`，
   未附加线程报 `JniCall(ThreadDetached)`（扫描挂死的第一层根因）。
2. **扫描元数据锁死绕过**：droidplug `properties()` 同步 Mutex 真机会被 Java 回调线程永久占住；
   扫描循环改为 `spawn_blocking + 400ms 超时`，单台卡死仅损失一个 blocking 线程。
3. **`realtime.open` 单例化**：已推流时直接应答，不重装停止槽（配合 Dart 侧防双开竞态）。
4. **可观测性**：零依赖 `alog`（`__android_log_print` 直连 logcat，tag `card_bridge`）+
   `android_logger`（**必须 `with_max_level(Info)`**，否则 info 全被吞）+ panic 钩子直通 logcat
   （此前 Rust panic 默认进 /dev/null，真机上等于静默死亡——getseed 的 UTF-8 panic 就是靠它抓到的）。

### Rust SDK
5. **`reai-getseed-sdk` UTF-8 panic**：`matches_advertisement` 里 `t[..4]` 字节切片遇中文广播名
   （现场真实设备「讯飞录音笔A1_11E0」）panic 在字符边界，炸掉整个扫描任务；改 `get(..4)`。
   教训：**广播名是任意 UTF-8，任何按字节前缀匹配都必须用 `get()`**。

### Dart
6. **`card_gateway.dart` `_serial` 队列错误吸收**：原 `await previous` 不捕获异常，任一命令失败
   会把串行链上后续所有命令永久排队（「scan 超时（36s）」的真根因，iOS/Android 同病）。
7. **无超时命令全部补兜底超时**（snapshot/disconnect/record/mark/time.sync/sync.start/sync.status/
   wifi.close/wifi.forget/deleteFile/upload.setUrl 等）。
8. **`maybe()` 库加载链修复**：Android `System.loadLibrary` 走 `RTLD_LOCAL`，`dlopen(NULL)` 看不到符号；
   改为「打开 + 符号查找」整体尝试：process → `libcard_bridge.dylib` → `libcard_bridge.so`。
9. **`live_audio_recorder.dart` 防双开**：`start()` 内首个 `await` 前有窗口，录音状态连续两次 notify
   会并发穿过 `isRunning` 守卫 → 双 `realtime.open` → 一次 close 整体退订 → 会话 0 字节（真机实测）。
   加 `_pendingStart` 同步互斥。
10. 扫描结果对桥上报的 `deviceKind=unknown` 做名字兜底识别（透传防御，保留）。

### Android 工程
11. **`MainActivity` 加 `System.loadLibrary("card_bridge")`**：此前安卓侧桥从未加载过
    （App 一直显示「此设备不支持连接录音卡」）；且 JNI_OnLoad 必须经 Java 加载才会触发。
12. **vendor btleplug Java 垫片**（`android/app/src/main/java/`，29 个文件 + README）：
    droidplug 运行时反射调用 `com.nonpolynomial.btleplug.android.impl.*`，缺类即崩。
13. **R8 keep 规则**：垫片只被 JNI 反射引用，静态分析视为死代码会被裁掉（`ClassNotFoundException` 实测）；
    `-keep com.nonpolynomial.btleplug.android.**` + `io.github.gedgygedgy.rust.**`。

### 构建链坑位（复现时必看）
- `rust/build-android.sh` 需 `env CXXFLAGS_aarch64-linux-android=-std=gnu++14 CXXFLAGS_AARCH64_LINUX_ANDROID=-std=gnu++14`
  （NDK 26 clang++ 默认 gnu++17，dyj-sdk vendored opencore-amr 用了 C++17 移除的 `register`）。
- gradle 会从 PATH 调 flutter：必须 `export PATH=<repo>/.work/tools/flutter-3.47.9/bin:$PATH`，
  否则 Homebrew flutter(3.38.5) 挂死 `pub get`。
- 改 Rust 后 gradle 的 `stripReleaseDebugSymbols` 中间产物可能不刷新（`stripped_native_libs`），
  必要时 `rm -rf app/build/app/intermediates/stripped_native_libs` 再构建；校验手段 = 对比
  jniLibs 与 APK 内 `.so` 的 md5。
- iOS 侧：工作区 watch 半成品使 flutter 工具链构建报 `WatchRecorderCore.o not found`（SPM 把本地包
  产物编进 `*-watchos`）；裸 xcodebuild 可过但会复用陈旧 Dart AOT，出包前必须
  `rm -rf app/build/ios/Build/Products/Release-iphoneos`。

## 四、Owner 真机验收步骤（晚些复验用）

前置：Jelly Star（或任意 Android 13+ arm64）已装本 PR 构建的 APK；Omi 开机在旁。
**注意：若之前做过 ring 下载，先重启 Omi 再测**（设备行为见第二节）。

1. 登录（新装机必走 OAuth；硬件页在登录墙内）。
2. 设置 → 第三方硬件联动 → **打开「Omi 随身录音器」开关**（重装后默认关）。
3. 顶栏胶囊「无设备」→ 连接录音卡 → 扫描 → 列表应直接出现「Omi 录音器 Omi」（过滤基线，不再显示未命名设备）。
4. 点连接 → 胶囊变绿点 + 电量（固件 3.0.21）。
5. 开「录音状态」开关 → 对着 Omi 连续说话 ≥ 2 分钟（VAD 门控：说话才发包，静默暂停属正常）。
6. 观察：状态块「已存 N 片」增长；每满 1 分钟切片自动本地转写。
7. 停录 → 尾片冲刷转写 → Timeline 出现**带转写文本的记录**（可能合并多片并生成摘要标题）。
8. 排障速查：`adb logcat -s card_bridge`（桥日志/panic 全在这）；「scan 超时（36s）」= 命令队列楔死
   （本次已修，若复现立即反馈）；「BLE start_scan failed」= 检查系统蓝牙与定位开关（Jelly Star 曾两个都关）。

## 五、遗留待办（按优先级）

1. **P1 · 连接优先级**：droidplug 增加 `requestConnectionPriority(HIGH)`（vendor patch 或上游 PR），
   验证 ~100 秒停流是否消失——这是长录音可用的前提。
2. **P1 · ring 同步与录音互斥**：录音中禁止触发 ring 下载；下载后实时流挂起问题向 Based Hardware
   求证（或给出「下载后自动重启设备」的产品话术）。
3. **P2 · 长下载移出 Dart 串行队列**（`download` 一次占队列最长 10 分钟）。
4. **P2 · 清理扫描检查点日志**：`unified_scan` 内 alog 埋点已排障完毕，可降噪保留关键错误。
5. **P3 · iOS 侧复验**：本次修复的 Rust 桥层问题同样在 iOS 存在（_serial 楔死、getseed panic），
   待 watch 构建问题解决后在 16 Pro 上复验同一闭环。

## 六、本 PR 不含的内容

工作区另有 watch 工作流未提交改动（`watch/**`、`WatchHardwareBridge.swift`、`watch_hardware_service.dart`、
`setting_sub_page.dart`、`pubspec.yaml` 等）——属于另一条进行中的工作线，**本 PR 未纳入**；
`device_store.dart` 仅挑取了扫描过滤相关的两个 hunk。
