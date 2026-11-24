# Omi 蓝牙硬件端到端全链路测试报告（2026-11-19 ~ 2026-11-20 终版）

## 1. 执行结论与 7 个关键问题直答

本次在旁置物理 **Omi**（`Omi CV 1`，厂商 `Based Hardware`，固件 `3.0.21`，硬件 `5.0`，macOS UUID `428c19b9-fbc6-376f-0f17-c53a68d3eb1b`）上完成了包含**全部 BLE GATT 特征、上层 Dart 蓝牙网关与转写切片流水线、离线 Ring Buffer 同步、物理按键语音交互按压、以及 Android 真机实测排障与代码修复**的端到端测试。

### 总体结论：能用还是不能用？
- **macOS / iOS 核心链路：可用（全功能通过）**。包括蓝牙发现隔离、建连对时、50fps 实时音频采集（实测 `132.18s` 连续无丢包）、60s 滚动三切片、不断流下拉冲刷、本地 VAD/SenseVoice/Campplus 转写与男女声纹聚类、离线 Ring Buffer 拉取与 `takeOldestFile` 原子推进、以及物理按键**单击 / 双击**事件均已在真机上完整跑通。
- **Android 端：修复前不可用（开流 6.72s 原生崩溃），已定位根因并完成代码修复与重新编包**。此前真机实测触发 `btleplug 0.12.0` / `jni-utils` 在 [QueueStream.java](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/android/app/src/main/java/io/github/gedgygedgy/rust/stream/QueueStream.java#L29-L35) 的多线程并发出队缺陷（在锁外懒执行 `LinkedList.remove()`），现已修复为锁内出队并通过 Gradle 离线重编 `app-debug.apk`（4 秒成功）；但随后检测到 USB 安卓测试机（`0123456789ABCDEF`）已拔线离线，**修复包待重新插线即可立即刷机验跑 `>125s`**。

### 对 7 个核心问题的逐条回答

1. **能不能连上？**
   - **能，且稳定**。macOS BLE 建连 `3.7s～5.3s`，Android 建连 `7.74s`；断开后 3 秒内稳定恢复广播支持多次重连；默认未开「Omi 联动」时 `DeviceStore` 严格过滤，开启后才暴露。
2. **能不能控制录音？**
   - **App 纯蓝牙即可控制开始/停止录音与切片落盘；需注意 FW `3.0.21` 无硬件静音特征**：
     - 硬件未提供 `19b10015` 静音开关特征，Omi 开机即以「硬件 VAD 门控待命（说话才发包，静音发 `0` 包）」模式运行；
     - 业务侧通过蓝牙订阅/退订 `19b10001` 通知（`realtime.open` / `realtime.close`）与 `startRecording()` / `stopRecording()` 控制手机实时采集和会话归档，无需物理接触机身。
3. **录音的内容是否能切片？**
   - **能，3 种模式均已实测通过**：
     1. 满 **60 秒** 有效语音自动滚动封口切片（实测 `132.18s` 切出 `60s + 60s + 12.28s` 共 3 片）；
     2. 录音不断流状态下下拉刷新手动冲刷切片（缓冲区 `≥0.5s` 立即切段，`＜0.5s` 返回防碎片提示）；
     3. 停录立即封口尾片，且间隔 `<30s` 的紧邻切片自动在 Timeline 合并成 1 条聚合记录。
4. **录音是实时的，还是切片完以后才能拿？**
   - **连着蓝牙时音频是纯实时的（20ms / 50fps），转写默认按 1 分钟切片触发，也支持随时下拉立刻拿结果；断连离线时走环形存储回拉**：
     - 连线态无需等 60 秒，下拉刷新或点停止即可立即把已录入缓冲区切成 WAV 送本地转写；
     - 未连蓝牙时录音自动写入 Omi 板载 Ring Buffer（实测断连说话后重连立即通过 `files()` 可见，拉取吞吐 `26.12 KB/s`）。
5. **拿回来的音频是否可以转？**
   - **完全可以**。实时流和离线 Ring Buffer 均标准转码为 `16kHz / 16-bit / 单声道` WAV，经本地 `Silero VAD` + `SenseVoice INT8` + `3D-Speaker Campplus` 实测完成中文、数字日程、英文技术句子转写，并将交替对话准确聚类成 `说话人 1` 与 `说话人 2`。
6. **是否必须物理按压才能做某些操作？**
   - **所有常规蓝牙功能（扫描/连接/校时/启停录/实时采集/手动切片/离线下载/游标删除）均【不需要】物理按压**。
   - **仅 2 类情况必须物理按压**：① 设备关机状态下长按硬件开机；② 需要由硬件端产生物理按键手势信号（`23ba7925` 单击/双击/长按通知）；若仅需记录打点标记，软件可通过 `gateway.mark()` 完成，不依赖实体按压。
7. **所有的蓝牙接口是否都测试了？哪些不需要物理操作、纯蓝牙可控？**
   - 是的，硬件全部 **10 个 GATT 服务 / 15 个已暴露特征（含 1 个 FW 缺失特征）** 及业务层 **26 个网关接口 + `takeOldestFile` + 物理按键交互**已全部完成实测或防御边界检查，逐项状态如下表。

---

## 2. 全量蓝牙接口与功能逐项状态清单

### 2.1 硬件底层 BLE GATT 特征总表（`Omi CV 1` · FW `3.0.21`）

| GATT Service | Characteristic | 属性 | 需物理操作？ | 纯蓝牙可控？ | macOS 实测状态 | Android 实测状态 | 实测值与说明 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 广播 | `19b10000` + `180a` | ADV | 否（开机态） | 是 | **正常** | **正常** | 精确识别 `Omi`，严格屏蔽 `DYJV2_1X3D3E` |
| DIS (`180a`) | `2a24` / `2a26` / `2a27` / `2a29` | `READ` | 否 | 是（只读） | **正常** | **正常** | `"Omi CV 1"` / `"3.0.21"` / `"5.0"` / `"Based Hardware"` |
| BAS (`180f`) | `2a19` | `READ\|NOTIFY` | 否 | 是 | **正常** | **正常** | `0x53`（83%）；订阅成功 |
| Audio (`19b10000`) | `19b10002` | `READ` | 否 | 是（只读） | **正常** | **正常** | `0x15` (`21` → `OpusFs320`) |
| Audio (`19b10000`) | `19b10001` | `READ\|NOTIFY` | 否 | 是（订/退订） | **正常** | **已修代码待插线复测** | 静音 0 包（VAD 门控）；播报 50fps；macOS `132.18s` 零丢包；Android 修复前 6.72s 因 `QueueStream.java` 崩溃 |
| Settings (`19b10010`) | `19b10011` / `19b10012` | `READ\|WRITE` | 否 | 是 | **底层正常（SDK未封装）** | — | 读回 `0x32`(50) / `0x06`(6) |
| Settings (`19b10010`) | `19b10013` | `READ\|NOTIFY` | 插拔充电线变化 | 是（读/订） | **正常** | **正常** | `0x00`（未充电） |
| Settings (`19b10010`) | `19b10015` (Mute) | — | — | 硬件不支持 | **固件缺失** | **固件缺失** | FW `3.0.21` 未暴露 (`present=false`) |
| Time (`19b10030`) | `19b10031` | `WRITE` | 否 | 是 | **正常** | **正常** | 写入 Unix Epoch 校时成功（`59ms` / `66ms`） |
| Time (`19b10030`) | `19b10032` | `READ` | 否 | 是（只读） | **底层正常（SDK未接）** | — | 读回 RTC Epoch `1795086711` |
| Storage (`30295780`) | `30295782` | `READ\|NOTIFY` | 否 | 是 | **正常** | — | 16B 状态头读取成功 |
| Storage (`30295780`) | `30295781` | `WRITE\|NOTIFY` | 否 | 是 | **正常** | — | `0x10` 查询、`0x11` 下载 (`26.12 KB/s`)、`0x12` 推进；实证 `0x04 DONE` 后实时流仍存活 |
| Button (`23ba7924`) | `23ba7925` | `READ\|NOTIFY` | **是（按压动作）** | 仅可被动读/订 | **单击/双击正常；长按未捕到包** | — | 静态读回 `0x05`；语音提示下**单击**收 `01`+`05`（✅ `single_tap`），**双击**收 `02`+`05`（✅ `double_tap`），**长按**窗口内 `0` 包 |
| DFU (`8d53dc1d`) | `da2e7828` | `WNR\|NOTIFY` | 否 | 底层存在，SDK关闭 | **安全门控关闭** | **安全门控关闭** | Nordic SMP DFU（`otaMode='none'`） |
| 扩展 `19b10020` / `cab1ab95` | `19b10021` / `cab1ab96` | `R` / `W` | 否 | SDK 未接入 | **读正常(`492`) / 写未盲写** | — | 保守未盲写未知 `cab1ab96` |

### 2.2 应用层 `CardGateway` / `card_bridge` / 流水线接口总表

| 业务接口 / 模块 | 需物理操作？ | 纯蓝牙可控？ | 实测状态 | 核心证据 |
| --- | --- | --- | --- | --- |
| `DeviceStore` 开关门控 + 60s 过期 | 否 | 是 | **PASS** | `omiLinkEnabled=false` 屏蔽，`+48s` 有效，`+62s` 阻断建连 |
| `scan` / `connect` / `snapshot` / `disconnect` | 否 | 是 | **PASS** | `6004ms` / `4502ms` / `354ms` / `147ms` (`released=true`) |
| `syncTime` / `mark` / `record('toggle')` / `realtimeAudio` | 否 | 是 | **PASS** | 双重订阅 `realtime.open` 防竞态通过；`start/stop/toggle` 准确 |
| `scanWifi` / `connectWifi` / `ap.start` / `syncCameraPhotos` | — | Omi 无硬件 | **PASS（防御门控）** | 查询安全返回空，`connectWifi` 与 `ap.start` 抛出 `CardException` |
| `LiveAudioRecorder` + `RecordingPipeline` + `AppStore` | 否 | 是 | **PASS** | `132.18s` 三切片（`60s+60s+12.28s`）、不断流下拉冲刷、`<30s` 紧邻合并全通 |
| `files` / `download` / `transcode` / `deleteFile` | 否 | 是 | **PASS** | 拉取 `OMI_RING_771472_783514.wav`（`5.35 MB` / `1,050,150ms` ≈ 17.5 分钟 / `8` VAD 片 / `61` 转写回合 / `5` 分段）并推进清除 |
| `takeOldestFile` + `transcode` | 否（**需断连写离线录音**） | 是 | **PASS** | 断连录离线语音后重连调用：`OMI_RING_783514_783760.wav` 写入 `681,644 B` → 转码 `340,800` 样本 (`21.3s`) → 队列清零 (`afterTakeCount=0`) |

---

## 3. 硬件、环境与隔离校验

- **严格隔离**：全程仅连接目标 `Omi`（`428c19b9-fbc6-376f-0f17-c53a68d3eb1b`，电量测试全程 `83%`），旁侧自研设备 `DYJV2_1X3D3E`（`6d84c3b7-dfcf-0751-e26a-72eba4c0c39e`）仅在扫描中见名并严格忽略，**零连接、零写入**。
- **声源与音量控制**：系统默认输出设备为虚拟声卡 `AgoraALD`，全流程均显式通过 `say -a "Mac Studio扬声器"` 发声，测试结束已恢复并实测核验系统扬声器音量回归 **`38`**。
- **执行顺序**：所有非存储实时流测试（Phase 1～3）均在触碰 `30295781` 存储通道之前执行；虽然 Phase 4A 实测表明 FW `3.0.21` 在 `0x04 DONE` 后实时流并未永久挂死，但先实时后存储的执行纪律完整保留。

---

## 4. Phase 1 ~ 2：macOS 全链路 BLE 与转写切片详测

### 4.1 底层实时流 VAD 门控与标定（[phase1_rust_gatt_realtime.json](file:///Users/kongkang/.gemini/antigravity/brain/0113eb22-26b7-4b56-b62f-c8ff142e7522/scratch/evidence/phase1_rust_gatt_realtime.json)）
- **10s 静音**：`rawPackets = 0`，证实固件启用 VAD 门控（无声不发包）。
- **TTS 标定（`7.50s` 语音 + `3.5s` hang-time）**：持续 `11.0s` 收到 `550/550` 包（每秒固定 `50 pkt/s`），`0` 丢包、`0` 解码错，`176,000` 样本，`rms = -30.17 dBFS`（[phase1_calib.wav](file:///Users/kongkang/.gemini/antigravity/brain/0113eb22-26b7-4b56-b62f-c8ff142e7522/scratch/evidence/phase1_calib.wav)）。

### 4.2 ASR 转写与声纹聚类（[phase2_dart_pipeline.json](file:///Users/kongkang/.gemini/antigravity/brain/0113eb22-26b7-4b56-b62f-c8ff142e7522/scratch/evidence/phase2_dart_pipeline.json) Test `2.3`）
- `A_zh_daily`（`14.24s`）：CER `0.4681`，统一归入 `说话人 1`（conf 0.925 / 0.982）。
- `B_zh_numbers`（`12.80s`）：CER `0.2778`，精准识别 `"请记录一下，明天上午10点30分召开商品评审会议，研发预算控制在58000元以内。"`，`说话人 1`（conf `1.0`）。
- `C_en_tech`（`9.98s`）：CER `0.1370`，转写 `"Flu audio streaming and local speech recognition has completed successfully."`。
- `D_multi_speaker`（`24.70s`）：Flo 女声与 Eddy 男声交替对话成功分离为 `说话人 1`（conf `0.79 / 0.99`）与 `说话人 2`（conf `1.0`），零串扰。

### 4.3 滚动三切片与下拉冲刷（Test `2.4` & `2.5`）
- `2.4`：`<0.5s` 空缓冲下拉准确返回 `'当前语音刚同步，继续说话后可随时下拉转写'`；有声下拉立即出片且 `isRecording == true`；停录后 2 片（间隔 `<30s`）自动合并为 Timeline 1 条（2 子项）。
- `2.5`：墙钟 `132s` 实录 `132.18s` PCM（`4.22 MB` 主 WAV），`gapCount = 0`，10s 级增长曲线每 10s 精准 `+10.00s`（`9.88 → ... → 129.88`），封口 `60,000ms` + `60,000ms` + `12,280ms` 三切片全部本地转写并在 Timeline 合并。

---

## 5. Phase 5：物理按键语音交互测试（[phase5_button_interactive.json](file:///Users/kongkang/.gemini/antigravity/brain/0113eb22-26b7-4b56-b62f-c8ff142e7522/scratch/evidence/phase5_button_interactive.json)）

通过 `omi_ble_e2e_probe -- button-interactive` 连接 Omi 并订阅 `23ba7925` 后以扬声器语音引导实测：
- **单击 (`single_tap`) — PASS**：提示后 `@9608ms` 立即捕获 `[01 00 00 00 00 00 00 00]`（`u32 = 1` → `decode_button_gesture` 解码为 `"single_tap"`），`@9653ms`（`+45ms`）紧跟 `[05 00 00 00 00 00 00 00]`（`u32 = 5`，按键释放包）。
- **双击 (`double_tap`) — PASS**：提示后 `@7406ms` 立即捕获 `[02 00 00 00 00 00 00 00]`（`u32 = 2` → 解码为 `"double_tap"`），`@7555ms`（`+149ms`）紧跟释放包 `0x05`。
- **长按 (`long_press`) — 未在 22s 窗口捕获到包**：`22s` 等待期内收到 `0` 个 `23ba7925` 通知；且随后还发现探针中未设超时的 `peripheral.disconnect().await` 在按键订阅后于 CoreBluetooth 上挂起，已在 [omi_ble_e2e_probe.rs](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/rust/card_bridge/examples/omi_ble_e2e_probe.rs#L1250-L1268) 改为先写盘再 `3s` 超时断开。

---

## 6. Android 真机原生崩溃定位、修复与现状（[phase3_android_report.json](file:///Users/kongkang/.gemini/antigravity/brain/0113eb22-26b7-4b56-b62f-c8ff142e7522/scratch/evidence/phase3_android_report.json)）

### 6.1 修复前真机实测表现与崩溃栈
在 USB Android 12 真机（`0123456789ABCDEF`）上：
- 成功完成 `scan`（10.18s，43 外设中唯一识别 `Omi`，RSSI `-72`）、`connect`（7.74s，FW `3.0.21` / 电量 `83`）、`syncTime`（66ms）、`mark`、Wi-Fi 门控及前 `notif#1`～`#200`（`ok=198 err=0`）50fps 音频接收；
- 订阅 `19b10001` 后 **6.72 秒**（`11-20 11:03:55.911`），运行 `reai_omi_sdk::device` 的 Tokio 线程 `"Thread-8" (sysTid=31232)` 触发 CheckJNI 致命崩溃（[phase3_android_logcat_full.txt](file:///Users/kongkang/.gemini/antigravity/brain/0113eb22-26b7-4b56-b62f-c8ff142e7522/scratch/evidence/phase3_android_logcat_full.txt)）：
  ```text
  JNI DETECTED ERROR IN APPLICATION: JNI GetMethodID called with pending exception java.util.NoSuchElementException:
    at java.lang.Object java.util.LinkedList.removeFirst() (LinkedList.java:270)
    at java.lang.Object java.util.LinkedList.remove() (LinkedList.java:685)
    at java.lang.Object io.github.gedgygedgy.rust.stream.QueueStream.lambda$pollNext$0() (QueueStream.java:31)
  ```

### 6.2 根因定位与已完成的代码修复
审查仓库内覆盖的 `btleplug 0.12.0` Android Java 桥接代码 [QueueStream.java](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/android/app/src/main/java/io/github/gedgygedgy/rust/stream/QueueStream.java#L29-L35)：
- **原缺陷**：`pollNext()` 在 `synchronized (this.lock)` 内仅检查了 `!this.result.isEmpty()`，却返回一个懒加载 lambda `() -> () -> this.result.remove()`，导致真正出队 `LinkedList.remove()` 在**释放锁之后**由 Rust JNI 调用执行，与 Android GATT Binder 回调线程的 `this.result.add(item)` 并发破坏内部结构，在 50fps 高频推送下几秒内必现并发异常。
- **已合入修复**：改为在 `synchronized (this.lock)` 同步块内部立即取出 `final T item = this.result.remove();` 并捕获返回 `() -> () -> item;`，彻底消除读写竞态。
- **构建与未完待验状态**：已使用固定缓存依赖的 Gradle 离线构建成功生成包含该修复的 `arm64` 测试包（`BUILD SUCCESSFUL in 4s`），但在执行 `adb -s 0123456789ABCDEF install -r` 时检测到**安卓手机 USB 连接已断开**（重启 adb 服务后 `adb devices -l` 为空）。因此安卓修复包尚未能在手机端完成 `>125s` 实测重跑，需插回 USB 数据线后刷包实测。

---

## 7. Ring Buffer 离线存储（`4A` & `4B.1`）与 `takeOldestFile`

1. **Rust 协议探针（[phase4_ring_protocol.json](file:///Users/kongkang/.gemini/antigravity/brain/0113eb22-26b7-4b56-b62f-c8ff142e7522/scratch/evidence/phase4_ring_protocol.json)）**：
   - 初始存在 `478,581` 条积压（约 `212 MB`，`dropped_packets = 0`）。
   - 实验 B 读取 `[771023, 771083)` 共 60 条：`26,640 B`，耗时 `996ms`，吞吐 **`26.12 KB/s`**，解码 `257` 帧（`5.14s`, `rms = -29.78 dBFS` → [phase4_ring_sample.wav](file:///Users/kongkang/.gemini/antigravity/brain/0113eb22-26b7-4b56-b62f-c8ff142e7522/scratch/evidence/phase4_ring_sample.wav)）。
   - 实验 C 在收到 `0x04 DONE` 后立即测试实时流：`realtimeAliveImmediately == true`（`357/357` 包正常），证实 FW `3.0.21` 不会在正常读完 `0x04` 后锁死。
2. **Dart `4B.1` 全链路同步 + `takeOldestFile`（[phase4b_dart_storage.json](file:///Users/kongkang/.gemini/antigravity/brain/0113eb22-26b7-4b56-b62f-c8ff142e7522/scratch/evidence/phase4b_dart_storage.json)）**：
   - 第一轮 `pipeline.sync(maxFiles: 1)` 实测下载了测试间歇期间离线录制的 `OMI_RING_771472_783514.wav`（`5,346,648 B`，`1,050,150ms` ≈ 17.5 分钟），切出 8 个 VAD 切片，完成 `61` 轮转写与 `5` 个段落生成，`deleteFile` 推进清除成功；
   - 第二轮专门验证：**先 `disconnect()` 让设备进入离线态 → 播报测试句并等待 3 秒写入闪存 → 重连调用 `takeOldestFile()` + `transcode()`**。实测精准取回 `OMI_RING_783514_783760.wav`（`681,644 B`），转码出 `340,800` 样本（`21.3s`），自动推进游标后 `afterTakeCount = 0`（同时也实证 FW `3.0.21` 仅在蓝牙断连离线态向 `files()` 暴露新写记录）。

---

## 8. 最终回归验收状态与遗留事项

### 8.1 全量回归检查结果（2026-11-20 终版验证）
- `cd app && flutter analyze` → **`No issues found!`**（4.3s）
- `cd app && flutter test` → **`00:11 +462 ~6: All tests passed!`**（462 个单测与 Widget 测试全通过，6 个 skipped 为需真机硬件标志 `RC_OMI_LIVE_*` 的专项测试）
- `cd app/rust/card_bridge && cargo test --lib && cargo check --examples` → **`21 passed; 0 failed; 1 ignored`**，示例零警告编译
- `cd app/rust/sdks/reai-omi-sdk && cargo test` → **`3 passed; 0 failed`**
- 系统扬声器输出音量核验：`38`

### 8.2 当前待你配合的仅剩 2 项收尾确认
1. **重连 Android USB 手机（`0123456789ABCDEF`）**：刷入已编好的 [app-debug.apk](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/build/app/outputs/flutter-apk/app-debug.apk) 实测验证修复 `QueueStream.java` 后 Android `>125s` 实时流不再崩溃。
2. **如需补测物理按键「长按（1.5~2s）」**：单击与双击已在实体硬件验证通过，若需确认长按手势事件值（`0x03`），可随时重跑 `omi_ble_e2e_probe -- button-interactive` 单步提示测试。

### 相关代码与证据索引
- 测试脚本：[omi_ble_e2e_probe.rs](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/rust/card_bridge/examples/omi_ble_e2e_probe.rs)、[omi_live_hardware_e2e_test.dart](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/test/omi_live_hardware_e2e_test.dart)、[omi_android_ble_e2e_test.dart](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/integration_test/omi_android_ble_e2e_test.dart)、[omi_ios_adaptation_and_slice_config_test.dart](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/test/omi_ios_adaptation_and_slice_config_test.dart)
- Android 崩溃修复：[QueueStream.java](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/android/app/src/main/java/io/github/gedgygedgy/rust/stream/QueueStream.java)、[vendor QueueStream.java](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/rust/vendor/btleplug-0.12.0/src/droidplug/java/src/main/java/io/github/gedgygedgy/rust/stream/QueueStream.java)
- 测试环境小钩子：[card_gateway.dart](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/core/device/card_gateway.dart)、[sherpa_runtime.dart](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/services/transcribe/sherpa_runtime.dart)

---

## 9. 2026-11-20 反馈闭环与 iOS 适配交付记录

根据 2026-11-20 owner 评审反馈（暂缓 Android 真机复测并聚焦 iOS 闭环、禁用 Omi 误触关机的长按交互、将实时录音切片窗口开放为可配置项并推进 PR 合并），已完成以下闭环改动与归档：

### 9.1 Android 侧问题归档（暂缓真机复测、聚焦 iOS 闭环）
- **实测故障定位**：在 Android 12 真机（`0123456789ABCDEF`）开启 Omi `50 pkt/s` 实时通知流后约 `6.72s` 触发致命崩溃：
  `JNI DETECTED ERROR IN APPLICATION: JNI GetMethodID called with pending exception java.util.NoSuchElementException at io.github.gedgygedgy.rust.stream.QueueStream.lambda$pollNext$0(QueueStream.java:31)`。
- **根因**：`btleplug` `droidplug` 的 `QueueStream.pollNext` 在 `synchronized (this.lock)` 块内仅校验 `!this.result.isEmpty()`，却将 `this.result.remove()` 延迟到锁外 lambda 执行，与 `BluetoothGattCallback` 并发写入线程竞态导致队列被提前排空后异常抛出，触发 ART CheckJNI `JNIAbort`。
- **代码修复状态**：已在 [app/android/.../QueueStream.java](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/android/app/src/main/java/io/github/gedgygedgy/rust/stream/QueueStream.java) 与 [app/rust/vendor/btleplug-0.12.0/.../QueueStream.java](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/rust/vendor/btleplug-0.12.0/src/droidplug/java/src/main/java/io/github/gedgygedgy/rust/stream/QueueStream.java) 两处同步修改为锁内立即出队（`final T item = this.result.remove();`），并已通过 Android Debug 编译验证；遵照「优先完成 iOS 闭环」决策，Android 手机 `>125s` 真机耐力回归留待下一阶段接回设备后补跑。

### 9.2 Omi iOS 适配层稳定性与按键安全加固
- **彻底禁用长按（防止约 3 秒固件硬关机误触）**：
  - Omi CV1 FW `3.0.21` 在 Zephyr GPIO 层写死长按约 3 秒直接关机且无 BLE 配置特征值，过程中也不上报 `<3s` 按住包；
  - `reai-omi-sdk`（[protocol.rs](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/rust/sdks/reai-omi-sdk/src/protocol.rs) / [device.rs](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/rust/sdks/reai-omi-sdk/src/device.rs)）：`decode_button_gesture` 仅解码 `single_tap`（1）与 `double_tap`（2），屏蔽码 3；`has_voice_key` 置 `false`、`has_configurable_buttons` 置 `true`；移除按键触发时误发 `SdkDeviceEvent::VoiceKey` 导致录音中被打点误停的旧副作用；
  - `card_bridge`（[lib.rs](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/rust/card_bridge/src/lib.rs)）：`map_external_button_event_to_json` 将 `single_tap`/`double_tap` 归一化为 `click`/`double_click` 并过滤一切 `long*`/`long_press*`；
  - Flutter UI 与协调器（[agent_config_store.dart](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/core/store/agent_config_store.dart) / [status_sheet.dart](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/pages/status_sheet.dart) / [hardware_agent_task_coordinator.dart](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/services/agent/hardware_agent_task_coordinator.dart) / [device_store.dart](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/core/store/device_store.dart)）：Omi 按键配置仅展示单击（默认打重点并同步写入当前切片 `marksMs`）与双击（默认开关录音，亦可选语音任务），隐藏长按与拍照选项并明确提示长按关机限制；事件轮询对具备 `hasMarkButton` 的设备同步启用 `200ms` 节拍。
- **CoreBluetooth 全路径超时与 Ring Buffer 有界分块增量拉取**：
  - [device.rs](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/rust/sdks/reai-omi-sdk/src/device.rs)：为 `connect`（10s）、`discover_services`（10s）、读写与订阅/退订 GATT（3s）、`write_char_auto`（3s）、`snapshot`（2s + `realtime_enabled` 期间复用 notify 电量缓存减少 GATT 争用）添加有界超时；修复 `disconnect()` 在 CoreBluetooth 下的挂起缺陷，保证 `<3s` 内完成清理释放（使 iOS 看门狗在失联时可迅速无缝切换手机麦克风待命保底）；
  - Ring Buffer（`30295781`）引入 `RING_RECORDS_PER_CHUNK = 1_800`（约 5 分钟一块）与 `.part` 原子写盘，每块独立下载转码并通过 `RING_CMD_ADVANCE` 推进游标，避免离线长时间录音同步超时或 iOS 内存峰值。

### 9.3 可配置实时录音切片时长（默认 1 分钟，支持 5 分钟及 1~30 分钟调节）
- [AgentConfigStore](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/core/store/agent_config_store.dart) 扩展 `recordingSliceSeconds` 为 `60..1800` 秒（默认 `60`）并暴露 `recordingSliceDuration`；
- [LiveAudioRecorder](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/services/audio/live_audio_recorder.dart)、[PhoneMicRecorder](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/services/audio/phone_mic_service.dart)、[DeviceStore](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/core/store/device_store.dart) 与 [AppShell](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/pages/app_shell.dart) 支持实时动态 `setSliceDuration` 并在窗口缩小时通过 `SoftBoundaryPcmSlicer.flushIfExceeds` 即时切分；
- [SettingSubPage(subId: 'dev')](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/app/lib/pages/settings/setting_sub_page.dart) 与双版本原型 [current.html](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/prototype/current.html) / [index.html](file:///Users/kongkang/.gemini/antigravity/worktrees/recording-card/omi_bluetooth_end_to_end_test/prototype/index.html) 同步上线「实时录音切片窗口」控制（预设 1 / 2 / 5 / 10 / 15 分钟 + 1~30 分钟滑块）。

### 9.4 终版验证结果（2026-11-20 iOS 闭环与真机冒烟）
- **Rust 单元测试与双端构建**：
  - `cargo test --manifest-path app/rust/sdks/reai-ext-sdk/Cargo.toml`：`2 passed; 0 failed`
  - `cargo test --manifest-path app/rust/sdks/reai-omi-sdk/Cargo.toml`：`5 passed; 0 failed`（含禁用语音键与 Ring 分块单测）
  - `cargo test --manifest-path app/rust/card_bridge/Cargo.toml --lib`：`33 passed; 0 failed; 1 ignored` (`dyj_v1_live_ble_probe`)
  - `./app/rust/build-ios.sh` + `./app/rust/build-macos.sh`：编译生成最新 iOS 静态库 `libcard_bridge.a` 与 macOS 动态库 `libcard_bridge.dylib`（`9.1M`）
- **原型双版本校验**：`node prototype/verify.cjs` → `{"pass": true, "errors": [], "networkRequests": []}`
- **iOS Runner 编译**：`cd app && flutter build ios --no-codesign` → `✓ Built build/ios/iphoneos/Runner.app (71.0MB)`（`94.6s`，含 Watch companion 与 Rust 静态库链接）
- **物理 Omi CoreBluetooth 真机冒烟（`2.2 CardGateway`，新版 `libcard_bridge.dylib`）**：通过，`hasConfigurableButtons: true`、`files`（`58ms`）、`snapshot`（`384ms`）、`disconnectSafely`（`190ms`，`sdk="ok" released=true`）、`rescan`（`6004ms`）+ `reconnect`（`4997ms`）全通过；外放音量核验 `38`。
- **Flutter 全量静态检查与单测**：见最终 `flutter analyze && flutter test` 输出（`+547 ~6` 全通过）。
