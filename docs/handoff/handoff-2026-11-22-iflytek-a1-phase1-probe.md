# 讯飞智能录音笔 A1 · Phase 1 全量实测评估与换机续测手册（2026-11-22）

- **状态**：Phase 1 四态实机摸底全部闭环，**Gate 1 乐观通过**；只读诊断探针与 `btsnoop_hci.log` 解析工具已自测全绿（**本分支仅含调研工具与实测文档，不含任何业务代码修改，暂不合并**）。
- **基线提交**：`master @ 52eb2c8`
- **分支 / PR**：`feat/iflytek-a1-phase1-probe` · Draft PR #116
- **目标硬件**：讯飞智能录音笔 A1（主控：炬芯 Actions ATS2837 + Zephyr RTOS 固件；实机 `讯飞录音笔A1_11E0`）

---

## 一、Phase 1 实机四态对照总表（2026-11-22 01:15~10:24 CST）

宿主机环境：macOS（蓝牙控制器 `BCM_4364B0`，`38:F9:D3:51:2D:6E`，`State: On`）。

| 测试场景 | USB 枚举（`VID:PID` / 描述） | 外部存储（U 盘） | BLE 广播 (`讯飞录音笔A1_11E0`) | 经典蓝牙可发现态 |
|---|---|---|---|---|
| **1. 脱线开机（蓝灯常亮）**<br>*(10:01~10:09)* | 无 | 无 | ✅ **在线**（`RSSI -50 dBm`，mfd `0x3332` + 14B = ASCII `"2303051401437265"`） | ❌ **未广播**（Inquiry 见 `0c-cd-b4-b5-90-ba` 经 SDP 核验为旁侧 `我的Z6X Pro` 投影仪） |
| **2. 开机 + 插 USB-C（无官方软件）**<br>*(10:11~10:12)* | ✅ `0x10d7:0xb00b`（`Actions / MSC Sample / ZEPHYR USB DISK`，USB 2.0 High-Speed 480Mb/s，`Serial: 0.01`，100 mA） | ✅ 挂载 **15.63 GB MS-DOS FAT32**（`/Volumes/NO NAME`，`disk2`） | ✅ **同时在线**（`RSSI -49 dBm`） | — |
| **3. 彻底关机 + 插 USB-C（无官方软件）**<br>*(10:15~10:16)* | ✅ **自动唤醒**并枚举 `0x10d7:0xb00b`（`Actions / MSC Sample / ZEPHYR USB DISK`） | ✅ 挂载 **15.63 GB MS-DOS FAT32**（`/Volumes/NO NAME`，`disk2`） | ✅ **同步唤醒在线**（`RSSI -63 dBm`） | — |
| **4. 插 USB-C + 运行官方「讯飞听见」**<br>*(01:15~01:17)* | ✅ 切换为 **`0x10d7:0xb00a`**（`Actions / CDC ACM`，`Serial: 00.01`，Interface 0 `AppleUSBACMControl` + Interface 1 `AppleUSBACMData`，`/dev/tty.usbmodem00_011` 被 PID `59072` 独占） | ❌ **无 MSC 接口** / `/Volumes/` 无外部卷 | ❌ **射频静默**（BLE 广播关闭） | ❌ 未广播 |

---

## 二、BLE 广播、GATT 全量拓扑与 8 秒握手看门狗实证

### 2.1 BLE 广播载荷实测
- **Local / Advertisement Name**：`讯飞录音笔A1_11E0`（UTF-8 hex：`e8 ae af e9 a3 9e e5 bd 95 e9 9f b3 e7 ac 94 41 31 5f 31 31 45 30`；剥离尾号 `11E0`）。
- **Manufacturer Data**：Company ID `0x3332`（小端字节 `"23"`）+ 负载 `30 33 30 35 31 34 30 31 34 33 37 32 36 35`（ASCII `"03051401437265"`）→ 拼接为完整 16 字符 ASCII 串 **`"2303051401437265"`**（疑似批次/固件/SN 编码）。
- **广播声明 Service UUIDs**（芯片 SDK 模板广播头）：`0x180D`（HRS）、`0x180F`（BAS）、`0x1805`（CTS）。

### 2.2 GATT 实际服务与特征表（`dump` 实测）

CoreBluetooth 实测建连后自动协商大 MTU：**`maximumWriteValueLength(.withoutResponse) = 244 B`**、**`maximumWriteValueLength(.withResponse) = 512 B`**（`btleplug` 静态读 `mtu()` 报默认值 `23`）。**实际 GATT 表内无标准 BAS（`0x180F`）与 DIS（`0x180A`）**，仅暴露以下 2 个私有服务：

| Service UUID | 归属 | Characteristic UUID | 属性（Properties） | 描述符 / 只读结果 / 备注 |
|---|---|---|---|---|
| `001120a0-2233-4455-6677-889912345678` | **讯飞 A1 私有业务服务** | `001120a1-2233-4455-6677-889912345678` | `WRITE_WITHOUT_RESPONSE` | 含 `0x2902` |
| 同上 | 同上 | `001120a2-2233-4455-6677-889912345678` | `WRITE` | 无描述符 |
| 同上 | 同上 | **`001120a3-2233-4455-6677-889912345678`** | `WRITE_WITHOUT_RESPONSE \| NOTIFY` | 含 CCCD `0x2902`；**主通知通道，已实测上推明文 JSON** |
| 同上 | 同上 | `001120a4-2233-4455-6677-889912345678` | `WRITE_WITHOUT_RESPONSE \| NOTIFY` | 缺 `0x2902` 描述符；直接订阅报 `The attribute could not be found.` |
| `e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1` | **Actions 炬芯 OTA 服务** | `e49a25e0-f69a-11e8-8eb2-f2801f1b9fd1` | `READ \| WRITE_WITHOUT_RESPONSE` | 只读返回 `Reading is not permitted.` |
| 同上 | 同上 | `e49a28e1-f69a-11e8-8eb2-f2801f1b9fd1` | `READ \| NOTIFY` | 含 `0x2902`；只读返回 `Reading is not permitted.` |

### 2.3 明文 JSON 协议与 8 秒握手超时踢断实证

三次独立只读连接订阅 `001120a3`（主机不发送任何写指令）均出现完全一致的精确时间轴：
- **`listen` #1（60s）**：`+7898ms` 在 `001120a3` 收到 `len=25`：`7b 22 6f 70 74 22 3a 36 31 30 30 39 2c 22 6f 70 74 4e 75 6d 22 3a 30 7d 00` → **`{"opt":61009,"optNum":0}\0`**；
- **`listen` #2（120s）**：`+7915ms` 收到完全一致的 25 字节明文 JSON；
- **Swift `CoreBluetooth` 连接态复核**：`+8007ms` 收到 `{"opt":61009,"optNum":0}\0`，随后 **`+8177ms`（170ms 后）设备主动断开 BLE 连接**（`CBErrorDomain Code=7: "The specified device has disconnected from us."`）。

**协议推论**：
1. 私有控制信道采用 **无加密、`\0` 结尾的明文 JSON（`{"opt":<int>,"optNum":<int>,...}\0`）**；
2. 建连后固件启动 **8 秒握手看门狗**：若未在 8 秒内下发合法握手包，发送 `opt: 61009` 后踢断连接（因此纯只读监听无法捕获 8 秒后的物理键状态上报，需在 Phase 2 抓包取得握手帧后测试）；
3. 结合 U 盘内 `.cache/.dat` 日志中的 `clean userId` / `5min timeout`，握手帧极可能包含 `userId` 字段。

---

## 三、FAT32 存储目录与双轨音频编码实锤

在无官方软件介入的 USB 挂载态（`/Volumes/NO NAME`，`MS-DOS FAT32`，`15,634,268,160 B`），根目录直接存放成对、无加密的录音文件：

| 文件示例 | 大小（Bytes） | 实测格式与结构结论 |
|---|---:|---|
| `2026_11_21_13_12_55.wav`<br>`2026_11_21_17_14_02.wav` | `460,800,044`<br>`460,800,044` | 满 **4.000 小时**（`14,400 s` × `32,000 B/s` + `44 B`）自动切分分段；原生无加密 **16kHz / 16-bit LE / Mono PCM** |
| `2026_11_21_13_12_55.sbc`<br>`2026_11_21_17_14_02.sbc` | `230,400,000`<br>`230,400,000` | 与 `.wav` 严格成对，**精确 1/2 压缩率（`16 KB/s`）** |
| `2026_11_22_10_05_24.wav`<br>`2026_11_22_10_05_24.sbc` | `292,908`<br>`146,432` | 本次 10:05 短录测试样本；`.sbc` 恰好 `1,144 × 128 B` 整帧；`.wav` 实际 PCM `292,864 B`（`9.152 s`） |
| `2026_11_22_10_08_35.wav`<br>`2026_11_22_10_08_35.sbc` | `390,188`<br>`195,072` | 本次 10:08 短录测试样本；`.sbc` 恰好 `1,524 × 128 B` 整帧 |
| `.cache/.dat` | `120,224` | 3,757 条 × 32 B 定长日志（记录 `start adv`、`ble Connected`、`clean userId`、`reason 19`、`5min timeout`、`satrt rec key`、`close rec key`、`usb drawout`、`key poweroff`） |

### 编码与固件细节实锤
1. **`.wav`（原生兼容 SenseVoice，但含固件头大小瑕疵）**：
   - `xxd` 实测标准 `RIFF/WAVE/fmt /data` 16kHz 16-bit 单声道头；
   - **重要兼容注意**：`2026_11_22_10_05_24.wav` 的 `RIFF` chunk size 写入 `0x00027048`（`159,816`），而 `data` chunk size 写入 `0x00047824`（`292,900`），导致 `afinfo` 误判时长为 `4.993250 sec`（实际 PCM `292,864 B` = `9.152 s`）。后续做桌面端 U 盘导入或校准 `.wav` 时，必须按实际 `data` 块 / 文件总长减去头偏移计算音频长度并修正 RIFF 头。
2. **`.sbc`（无加密标准蓝牙 SIG SBC 帧）**：
   - `xxd` 检查偏移 `0x00`、`0x80 (128)`、`0x100 (256)` 均以 **`9c 35 1d <crc>`** 起始：
     - `0x9C`：标准蓝牙 SBC Syncword；
     - `0x35`：`00`（16kHz）| `11`（16 blocks）| `01`（Dual Channel）| `0`（Loudness）| `1`（8 subbands）；
     - `0x1D`：Bitpool = 29（固定 **128 字节/帧**，对应 128 采样 / 8 ms，恰好是 256 B PCM 的 `1/2`）。

---

## 四、Gate 1 结论与当前能力问答

1. **Gate 1（传输通道判定）：乐观通过**
   - 脱线态仅广播 BLE GATT，不依赖经典蓝牙 SDP/SPP，且支持 `244 B / 512 B` 大 MTU 与明文 JSON 控制帧；配合无加密 `.sbc`（`16 KB/s`）与 `.wav`，iOS / Android / macOS 均可通过统一 `btleplug` 接入，无 MFi 硬件墙阻断。
2. **关于「蓝牙持续推流 / 自动切片 / 蓝牙开关录音」的现状答复**：
   - **实时推流与远程开关录音**：目前因缺少 8 秒握手命令尚无法保活触发，需在 Phase 2 抓包确认官方 App 是否支持 BLE 实时推 `.sbc` 流及远程启停 `opt` 指令；
   - **自动切片**：硬件本地每满 **4 小时**切一个文件；若 Phase 2 确认支持 BLE 实时流，App 侧可直接做 **1 分钟滚动切片 + 本地 SenseVoice 转写**；若仅支持离线同步，则需确认是否可对录制中的 `.sbc` 做偏移增量拉取，否则在停录后整段取回。
3. **桌面端保底方案**：即使云端鉴权（如握手 `userId`）后续遇到锁死，A1 在 Mac 上无需官方客户端即可稳定挂载 15.63 GB FAT32 U 盘并直出无加密 16kHz WAV，具备 100% 开放的桌面端有线快速导入能力。

---

## 五、换电脑 + 自动化 Android 续测清单（Phase 2 / Gate 2）

在新机器检出本分支后，即可依托自动化 Android（`adb` + `btsnoop_hci.log`）一次性跑通剩余协议验证：

```bash
git fetch origin
git checkout -b feat/iflytek-a1-phase1-probe origin/feat/iflytek-a1-phase1-probe
```

1. **已完成（Phase 1 已打钩）**：
   - [x] USB 双态对照（`0x10d7:0xb00a CDC ACM` vs `0x10d7:0xb00b FAT32 U盘`）
   - [x] BLE 广播、MTU（`244/512 B`）与完整 GATT 表（`001120a0..a4` + `e49a25f8`）
   - [x] 8 秒握手超时看门狗与明文 JSON（`{"opt":61009,"optNum":0}\0`）验证
   - [x] 本地 `.wav`（16kHz Mono PCM + 头尺寸瑕疵）与 `.sbc`（128B/帧 标准 SBC）编码实锤
2. **下一轮自动化 Android 待办（一次性全抓全测）**：
   - [ ] 开启 Android 开发者选项 `btsnoop_hci.log`（或 `adb bugreport` 拉取），用「讯飞听见」App 连续完成 6 步动作：建连握手 → 静置 10s → App 远程启停/实时转写（若有）→ 机身按键启停 → 拉取文件列表与同步刚才那段测试录音 → 删除该单条测试文件；
   - [ ] 用 [parse_btsnoop_hci.py](../../scripts/parse_btsnoop_hci.py) 一键导出全部 `001120a1`/`a2`/`a3`/`a4` ATT 明文 JSON（含 `opt` 字典表）；
   - [ ] **回答 5 个 Gate 2 决策问题**：
     1. 握手 JSON 中的 `userId`/签名是否涉及云端动态挑战锁（Level A/B vs Level C）？
     2. 是否存在 BLE 远程开始/停止录音 `opt` 命令（决定 `hasRemoteRecordControl`）？
     3. 是否存在 BLE 实时音频流推包（决定 `realtimeAudio` 与 1 分钟自动切片）？
     4. 离线文件列表、断点偏移下载与单删的 `opt` 命令与流控格式是什么（是否直接传 `.sbc` 帧）？
     5. 是否在握手后支持机身按物理键向 `001120a3` 实时推送录音状态/电量事件？
   - [ ] 在 [iflytek_a1_probe.rs](../../app/rust/card_bridge/examples/iflytek_a1_probe.rs) 补齐最小握手与拉取闭环验证后，冻结 `SdkCapabilities` 并按第四节（原 Phase 3 蓝图）正式开发 `reai-iflytek-sdk`、`card_bridge`、Flutter 门控、`ext_sdk_hardware_test.dart` 及 `prototype` 双版本同步。

---

## 六、Phase 3 正式接入预研蓝图（已核对代码落点）

待 Gate 2 冻结后按以下模块推进（均沿用 `reai-ext-sdk` 体系，开关默认关闭）：
- `app/rust/sdks/reai-iflytek-sdk/`：`IflytekSdkDriver`（`iflytek_a1`）+ `IflytekSession` + `MemLink` 抓包夹具单测；
- `app/rust/sdks/reai-ext-sdk/src/audio.rs`：按需接入**零 C/CMake 依赖的纯 Rust SBC 解码器**（将实锤的 16kHz / 128 B/帧 `.sbc` 转为 16kHz Mono PCM WAV；WAV 直通需校正 `RIFF`/`data` 头长度）；
- `app/rust/card_bridge/{Cargo.toml,src/capabilities.rs,src/lib.rs}`：注册 `DeviceKind::IflytekA1`；
- `app/lib/core/device/card_gateway.dart`、`agent_config_store.dart`、`device_store.dart`、`main.dart`、`app_shell.dart`、`setting_page.dart`、`setting_sub_page.dart`、`rc_icons.dart`、`status_sheet.dart`：按冻结能力位门控裁剪；
- `app/test/ext_sdk_hardware_test.dart`、`prototype/{current.html,index.html,verify.cjs}`、`docs/{SDK-CAPABILITY.md,MULTI-DEVICE-ARCHITECTURE.md}`：测试、双版本原型与文档同步。

---

## 七、本分支验证记录（2026-11-22 10:24 CST 最新）

| 检查项 | 命令 | 实测结果 |
|---|---|---|
| 探针内置单元测试 | `RUST_MIN_STACK=16777216 CARGO_INCREMENTAL=0 cargo test --manifest-path app/rust/card_bridge/Cargo.toml --example iflytek_a1_probe` | **`5 passed; 0 failed`**（含 `manufacturerDataAscii` 解码与已知讯飞/炬芯 UUID 识别） |
| `card_bridge` 既有单测 | `RUST_MIN_STACK=16777216 CARGO_INCREMENTAL=0 cargo test --manifest-path app/rust/card_bridge/Cargo.toml` | **`43 passed; 0 failed; 1 ignored`**（`dyj_v1_live_ble_probe` 需物理 `DYJ_*`） |
| `btsnoop` 解析器自测 | `python3 scripts/parse_btsnoop_hci.py --self-test` | **`OK`**（3 条合成帧：2 ATT + 1 动态 L2CAP/RFCOMM） |
| 实机 USB 只读冒烟 | `cargo run --manifest-path app/rust/card_bridge/Cargo.toml --example iflytek_a1_probe -- usb` | **`exit 0`**（10:24 测时线已拔除返回空；此前 10:11/10:16 同命令均检出 `0x10d7:0xb00b` + `/Volumes/NO NAME`） |
| 实机 BLE 扫描冒烟 | `cargo run --manifest-path app/rust/card_bridge/Cargo.toml --example iflytek_a1_probe -- scan --secs 4` | **`exit 0`**（检出 `讯飞录音笔A1_11E0` `rssi=-51`、`shortId="11E0"`、`manufacturerDataAscii["0x3332"]="2303051401437265"`） |
