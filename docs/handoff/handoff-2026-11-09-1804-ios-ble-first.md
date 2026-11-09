# iOS 交接：先打通普通 BLE 与真实本地文本

更新时间：2026-11-09 18:04（后续 Git 保存回执与最终验证附在文末）。

## 1. 下一对话必须先读的结论

**App 尚未完成 BLE → 手机入库 → 本地转写文本的端到端闭环。不要把下载进度、主机单测或 Mac ASR 推理算成 iPhone BLE 验收成功。**

owner 最新优先级（2026-11-09 17:17）：**先解决普通蓝牙传输，BLE 顺利同步且拿到真实转录文本后，才继续开发 AP 快传。** 已有 AP 源码保留，但目前暂停，不再尝试热点/HTTP 或固件更新。

18:01 owner 要求先总结文档，再执行 **commit → push → PR → merge** 保存阶段，随后换对话继续。本文先于本轮 Git 操作写入；最终提交/PR/合并及验证结果随后补记。

## 2. 唯一工作区、Git 与协作边界

- 仓库：`kongkang/recording-card`。
- 本主控继续用唯一隔离工作树：`/Users/kongkang/Developer/recording-card/.worktree/manus-local-integration`。**不要另建同任务工作树，不要覆盖主检出或其他会话未提交文件。**
- 当前分支：`fix/ios-ap-and-ble-closure-20261109`。
- 此阶段起点：`754a7b1e2beea7973e1d72af77faa9feb33e5180`，即 PR #19 的 merge。
- 合并目标沿用独立集成分支 `integrate/device-full-flow-20261109`，**不是 master**。master/Android 工作树未作为本轮修改目标。
- Manus 主控负责 iOS，dsh 指定对话负责 Android。参考会话：`session-9ce48dc1-1154-46db-b17b-7b9afe9e01ba`。共享 Rust SDK/request/event ABI 不整包覆盖，真机/录音卡由主控独占，交接前其他会话不要连接同一录音卡。
- 本轮分层计数工作流 `ac9c2fa1dc6a` 已因用户停止会话而 **killed**；2 个源码所有者停止，独立 QA 阶段未执行。不能声称计数最终 QA 完成。
- 读项目 `AGENTS.md` 与 `~/.Codex/AGENTS.md`，保留 HTML 设计基线，只读 prototype/archive/gen-evidence。用户原音频、原始转写、声纹默认本机，云端只发送所需文本；无模型/登录/真实结果时如实失败。

## 3. 已安装的 iPhone 版本与安全状态

- iPhone 13 mini 已连接本 Mac，已能使用现有 Phone Use/WDA 通道；下次先检查当前设备与解锁状态，不假设一直解锁。
- 当前已安装并实际启动的版本：**110909**。
- Bundle：`dev.kongkang.recordingCard`；开发 Team：`35N5SGDE59`。同身份覆盖安装，旧 App 与 Keychain 登录状态保留，未卸载清空。
- 110909 的源码已含此前的 Apple 通知广播修复和 AP SDK Wi-Fi 路由探索；**新增分层计数与最新两处 BLE Store 文案小修尚未安装到手机**。
- 110909 IPA 本机文件：`outputs/ios-device-candidate-20261109-110909/RecordingCard-iOS-110909.ipa`。大小 30,094,286 字节；SHA256 `b6e14254f3b24bfd9d403fd8a0568270769dfe708b8eb01cb8920546b779a121`。
- 110909 有合法同团队 Hotspot entitlement，签名和有效默认 Keychain 组已核验；这不表示 AP 或 BLE 业务成功。
- 18:00 短样本录音开始动作已被受理，但观察被中断。18:02 主控读到开关为 1，已停止本次测试录音，随后读到「未录音」。**本次未播放公开测试语音，不能认为新录音包含测试句。** 不删除它。
- 普通 BLE 上一轮短收后 SDK 安全清理/断连，App 最后观察能如实显示未连接；后续为短样本重连过。交接时无正在执行的文件同步，也未执行 AP 或 OTA。

## 4. BLE 真实结果：还没有解决短收

### 4.1 已完成且仍有价值的基础修复

Apple 平台 btleplug 原先通知广播容量 16；旧 `BroadcastStream.filter_map(x.ok())` 可隐藏 Lagged，并继续给出缺包后缀。项目已 vendoring **Apple-only** btleplug，将容量改为 1024，提供 fallible/fused 通知流，溢出必须显式失败。SDK Apple NUS 消费走此流，其他平台/Android 不整仓 patch。

已确定性回放旧 16 窗口丢 6 包与新窗口完整/溢出拒绝。**这证明一种机制和修复，但不能认定此前或当前真机短收就是此机制。**

### 4.2 110909 的最新实机失败

约 17:20 启动普通 BLE，同一文件约 12 分钟到结束；期间读到下载 31% 且仍连接，临时文件字节也实际增长。

最终数据：

| 项目 | 真实值 |
|---|---:|
| 设备 start 声明/期望大小 | 2,186,240 字节 |
| 实际写入接收文件 | 2,183,440 字节 |
| 差额 | 2,800 字节 |
| pre_start_bytes / packets | 0 / 0 |
| received_packets | 10,918 |
| last_packet_bytes | 40 |
| end_seen | true |
| 手机正式入库 | 否 |
| 此文件本地原文 | 尚未生成 |
| 卡端原件 | 保留 |

差额与 `14 × 200` 相容；目前只计最后一包长度，没有完整长度分布或无线序号，**不能直接断言缺口的位置或固件少发 14 包**。开始帧/结束帧到达也不能证明中间无线数据全到。

完整性校验拦截，`.part` 保留但不生成成功收据，不触发删除。**绝不能填补猜测字节或用短文件直接转写以伪造闭环。**

本机证据（均不提交用户数据）：

- `.work/ios-ap-closure-20261109/first-ble-text-result.json`：最终失败统计。
- `.work/ios-ap-closure-20261109/ble-private/`：chmod700 的录音库元数据快照；不包含导出的 OAuth token，禁止提交/上传。
- `.work/ios-ap-closure-20261109/ble-staging-1724.log`：手机在途文件只读大小查询。
- `.work/ios-ap-closure-20261109/ble-short-cleanup-ui.json`：失败清理后真实 UI。

手机仓库正确路径是 **`Library/Application Support/recording_card/v1/`**，不是缺少 `v1` 的路径。`staging` 里的 `.part` 不是正式入库音频。

## 5. 两层独立只读核查结果

报告保存在本机 `.work/ios-ap-closure-20261109/ble-apple-second-pass.md` 和 `ble-sdk-second-pass.md`；全文可本机阅读，但不是已实现的解决方案。

### Apple 回调 → 广播

- 两个通知载体是 futures mpsc(256)，满时原 `send().await` FIFO/Pending 背压，不是自动丢旧包；delegate 的同步 `block_on` 可能阻塞串行 CBqueue，但是否引起 OS 上游丢回调未知。
- NSData 在回调内已复制成 owned Vec，未发现本地 latest/coalescing/去重。
- 条件性非广播路径存在：同 characteristic pending read 优先消费通知；UUID map miss 静默不转发；error 回调不入队；关闭时 send 失败只 log；广播无 receiver 失败可被忽略。**均无现场计数，不能直接认定为根因。**

### SDK NUS → keep

- 正常首字节 0 的通知完整剥掉一个标识后入唯一无界 inbox；keep 持 command gate/incoming 到 end，未发现正常中间包被静默裁剪的路径。
- keep 在第一个合法 end 立即验证长度，不能补入 end 后数据。
- 非 0 通知进文本 parser；同批正常帧先于 fault 入队，所以 length mismatch 不完全排除异常文本/边界。
- 已授权 Mac Lite keep 对照也是 `{name, keep:true}`，未发现可复用的 rate/ACK/offset、end 后补尾通路；不要创造固件参数。

下一步是**一次传输的分层整数计数守恒**，再决定修哪一层；如果手机各层已守恒而一开始就少数据，只能上移排查设备/控制器/OS，仍不能仅靠手机断言固件缺陷。

## 6. 被中断的分层计数源码：必须完成核验再上机

约定：`.work/ios-ap-closure-20261109/BLE-COUNTER-CONTRACT.md`。

已写入当前工作树：

1. Apple 回调/internal 路由/peripheral publish/transport consume 计数；按目标 peripheral/service/characteristic，只有 packet/bytes/leading-zero 整数，不保存音频。
2. SDK `BleTransport::notification_diagnostics() -> Option<serde_json::Value>` 默认 None；未知不伪装为 0。
3. SDK worker 入口/0标识/文本/raw/fault/Binary入队统计、start/end 当下固定 SDK 快照；keep begin/start/end 与 optional transport 快照。
4. `src/ble_sdk_counter_tests.rs` 的 2.18MB 整文件、明确缺14包、边界/慢写等回放草稿。

### 当前明确编译阻断（18:04 文档首次写入时）

SDK `src/btleplug_transport.rs:400` 引用

```rust
btleplug::corebluetooth::notification_diagnostics::NotificationDiagnostics
```

但 `vendor/btleplug/src/lib.rs` 的 `corebluetooth` 是私有模块，没有公共 re-export，报 **E0603**。这是中断前明确的跨所有者可见性接缝，不是 BLE 根因。保存前若只补公共类型导出和引用，再跑 Native/SDK 回归，将把实际结果附在文末；否则必须保留 WIP 标记，不能把不能编译代码当可用交付。

Apple 13 个纯 mock/fidelity 检查已通过；SDK 2 个纯 mock已通过；**新增 Native 8 项整文件回放当时未跑起来，不能记作通过；独立 QA 未执行；计数尚未真机验证。**

Transport begin/end 是非 fenced、Relaxed/non-atomic 装载，队列不天然同步；统计里已有窗口解释。不要把不同层瞬时加载时差当丢包证据，不要把手机计数当固件发送量。

## 7. BLE UI 两处已回归小修（未安装）

`app/lib/core/store/device_store.dart` / `app/test/progressive_sync_cancel_test.dart`：

- 新普通同步开始清空上一轮 AP 错误，避免「快传超时」污染当前 BLE 进度。
- 短收安全断连后，状态轮询失败保留 `syncError`，不再用泛化「设备未连接」覆盖精确短收原因。

本机 Flutter **`analyze` 无问题；`flutter test` 389 通过、11 个 opt-in 跳过**。跳过不是成功，尤其不能宣称那些真机/真实 Native opt-in 项已执行。

## 8. 本地 ASR、数据与传输安全

- SenseVoice 本机固定 profile 已获 owner 允许仅本次本地开发测试，逐文件大小/SHA256固定，237MB 权重未提交仓库；小型 Silero VAD 带许可/校验。
- Mac 上 SenseVoice+Silero 对公开中文 WAV 做过真实推理成功；**这不替代 BLE → iPhone ASR 的闭环**。
- 已有几条历史本机 capture，经真实 VAD 判为无有效语音，三处显示已完成静音。不能把空原文算「拿到文本」。
- 普通同步 `onImported` 先 publish，`policy.autoTranscribe` 为 true 时立即 `processPending()`；不必等整批下载完。AP 的 localOnly 处理已有源码但暂停。
- owner 传输策略：普通默认 BLE，用户显式快传才 AP；稳定落盘并确认转移后卡端应删除。**当前保源实现仍因没有可信原子条件删除/不可变租约而拒绝最终删除，源确认可能返回 retained；删除/移动闭环也未完成，不要绿色冒充成功。** 等先解决接收/真实文本，再处理此产品缺口。
- 未上传原音频、未明文备份 token、未卸载 App、未清空卡。
- 旧 OTA 许可有严格主控版本前置；真机后来读到 0.3.9，不符合此前 0.3.8 前置，所以没升级。不要把旧授权扩大；Wi-Fi 0.1.3 未刷。

## 9. AP 当前状态：保留源码，明确暂停

在 user 改优先级之前已实现并编译/安装：NEHotspotConfiguration joinOnce 系统弹窗、合法 entitlement/同身份签名、原生 Wi-Fi 本地 TCP 诊断、WIFI_AP_START 事件屏障；后续让 AP 探测和 SDK HTTP 在 iOS 绑定 en0/no_proxy/禁重定向、有界单页JSON。相关源码此前已留在工作树。

110909 实机：系统加入成功，原生 Wi-Fi TCP 已通；SDK `http://192.168.4.1/api/files?page=1&pageSize=1` 仍 `error sending request`，未准备完成/未下载。不能宣布 AP 可用。默认参数已核验参考项目/SDK，用户确认未改；不要反复要求手动去设置或猜密码。

**下一对话不要先解决 AP、再扩签名/SSID/VPN能力；先完成 BLE 的明确验收门槛。**

## 10. 下一对话启动顺序

1. 读本文及最终保存/验证附录，确认工作树/分支/当前HEAD；不要接管 Android 文件或换工作树。
2. `git status --short --branch` 看保留下来的 macOS 自动生成修改，避免混入 iOS 提交；检查没有仍在写源码的旧 Agent。
3. 修/确认 E0603 接缝的保存结果，完整 Native/SDK/Flutter 回归；只有源码能编译后才构建 110910 或下一个递增编号。
4. 用 `.work/ios-ap-closure-20261109/build-110910.sh`（已准备、尚未执行）同团队同bundle构建；维持 Rust1.94、项目内Flutter3.47.9、Keychain身份与实际签名检查。不要用构建中的旧 `Runner.app` 冒充新包。
5. 通过已配置 Phone Use/WDA，只由主控操作手机，检查解锁/当前App/无在途任务；更新保留数据，禁止卸载清空。
6. owner 18:00:44 已表示 **「直接播放音频，我放到旁边了」**，允许 Mac 播放公开中文测试 WAV；音频 `inputs/asr-public-fixture/zh.wav` 5.59s，16kHz，来源回执 `source.json`。本轮保存前不播放。后续先在 App 启动且读回录音中，再播放一次，不改系统音量，然后停止并读回未录音。
7. 用短文件走普通 BLE；完整长度/hash/侧车/入库后，在 iPhone 原始数据看到**非空真实文本与时间轴**。记录来源、文件大小/校验、ASR状态，不把测试 WAV 直接注入业务库。
8. 接着相同大文件做一次层计数复测，判读起止窗口与各层 payload 守恒；没有新证据不无限重复 12分钟全文件，不调整未知固件参数。
9. 仍失败时先定位哪个层减少/分流或错误，做最小修复、单测、实机循环；不得填字节、放宽size/hash或静默降级。
10. 有 BLE 完整同步和真实 iPhone文本的证据后，才恢复 AP 开发；当前移动/删除未实现也要如实保留在完成度清单。

### 本机固定工具命令

```bash
cd /Users/kongkang/Developer/recording-card/.worktree/manus-local-integration
export RUSTUP_HOME=/Users/kongkang/.rustup
export CARGO_HOME=/Users/kongkang/.cargo
export RUSTUP_TOOLCHAIN=1.94.0
export PATH=/Users/kongkang/.rustup/toolchains/1.94.0-aarch64-apple-darwin/bin:$PATH
cargo test --offline --locked --manifest-path app/rust/card_bridge/Cargo.toml --lib
```

Flutter 固定 SDK：`/Users/kongkang/Developer/recording-card/.work/tools/flutter-3.47.9`。局部工具 HOME：工作树 `.work/ios-usable-20261109/flutter-tool-home`；PUB_CACHE沿用 `/Users/kongkang/.pub-cache`。需要测试本机socket及Xcode标准缓存的授权时按当前工具策略申请；不要改系统Flutter/默认Rust。

GitHub 连接器 CLI：`"$MANUS_CONFIG_HOME/connectors/github/gh"`；不 `gh auth login`、不修改全局Git配置。每个提交保留 `Co-authored-by: Manus <dev-agent@manus.ai>`。

## 11. 本次最终保存与核验附录

文档先写入，Git 操作尚未执行；实际验证、提交和合并回执将在此节后追加。本文是交接事实记录，不是闭环完成宣告。

### 11.1 恢复核验（2026-11-09 18:20~18:50 实际执行）

E0603 接缝已修：`vendor/btleplug/src/lib.rs` 对 `NotificationDiagnostics` 做公共 re-export（`corebluetooth` 模块本身仍私有），SDK 侧改为引用该公共类型。以下都是本轮亲自跑出的结果：

| 命令 | 真实结果 |
| --- | --- |
| `cargo test --lib`（card_bridge） | **63 passed / 0 failed**，含此前未跑起来的 8 项整文件回放 |
| `cargo test`（vendor/reai-card-sdk） | **107 passed / 0 failed** |
| `cargo test`（vendor/btleplug） | **30 passed**（lib）+ 4 doctests |
| `flutter analyze` | **No issues found** |
| `flutter test` | **389 passed / 11 skipped** |

由此 §6 里「新增 Native 8 项整文件回放未跑起来」一项作废，已实际通过。**仍然没有跑、不能记作通过**：真机 integration_test、独立 QA 阶段、真机分层计数复测、110910 构建与安装。11 项 opt-in 跳过同样不是通过。

### 11.2 本轮保存实际范围与排除项

提交按分层拆开（Rust 桥与计数 / Flutter 侧 / iOS 原生与脚本 / 交接文档）。以下内容**故意不入库**：

- `app/macos/Podfile`、`app/macos/Flutter/Flutter-*.xcconfig`：macOS 侧自动生成/带出的改动，与本轮 iOS 目标无关。
- `app/rust/card_bridge/src/android.rs`：仅一行 import 排序，属 Android 并行会话范围，已撤回。
- `app/rust/card_bridge/src/lib.rs` 里同样的 import 排序：已撤回，只保留语义改动。
- `vendor/reai-card-sdk/Cargo.lock`：单独跑 SDK crate 测试生成的锁文件。
- `.work/`、`inputs/`、`outputs/`：录音库元数据快照、测试 WAV/固件包、IPA 构建产物与全部证据日志。
- `vendor/` 下残留的 `.manus-*.tmp` 临时文件：已删除。

### 11.3 本轮结论没有变化

保存只是把 WIP 固定下来：**BLE 短收仍未解决，手机仍无正式入库与真实转写文本，AP 继续暂停**。计数代码能编译、能过 mock 回放，但**尚未上机验证**，不能作为根因结论。

### 11.4 Git 回执（2026-11-09 18:24 实际执行）

分支 `fix/ios-ap-and-ble-closure-20261109` 已推送并合入集成分支 `integrate/device-full-flow-20261109`（**不是 master**）：

| 项 | 值 |
| --- | --- |
| PR | **#20**「阶段保存：Apple 通知流与分层计数、AP 探测收紧、短收文案修复」 |
| 合并提交 | `21093de`（merge commit，父提交 `754a7b1` + `04989ae`） |
| 合并时间 | 2026-11-09 18:24 |
| 分支提交 | `c814e92` Apple 通知流与分层计数 / `a77acad` 桥侧计数回放与 AP 就绪 / `d7b92cd` 快照探测接入与短收文案 / `85cda0a` iOS 热点诊断 / `04989ae` 交接文档 |

回执核验方式：合并后重新 fetch，集成分支 HEAD 就是上述 merge commit，两个父提交分别是原来的起点与本轮最后一个提交。

**合并前后跑的仍是同一份源码**：Rust 桥 63 项在提交后的树上又跑过一次（63 passed），Flutter 389 项与 19 项 iOS 接线测试在相同 Dart/Swift 源码上跑过一次；合并动作没有改源码，因此没有另跑一遍。

### 11.5 保存后工作树残留（故意的）

`git status` 仍会看到：`app/macos/Podfile`（未跟踪）、两个 macOS `xcconfig`（已修改未提交）、`vendor/reai-card-sdk/Cargo.lock`、`.work/`、`inputs/`、`outputs/`。这些都在 §11.2 的排除清单里，属于自动生成物或本机证据/用户数据。下个对话不要把它们顺手提交进去，也不要因此以为工作树「脏得不干净」。
