# Handoff: iPhone 13 mini 真机全流程测试 → 反馈定位修复 → 复测验收闭环

> 来源：开发期第一程（Flutter 工程落地 + OAuth 门 + 帧级自查，PR #3/#4 已合并）· 生成于 2026-11-08 10:20
> 上一棒：`docs/handoff/handoff-2026-11-07-1935-flutter-build.md`

## 🎯 下个会话要做什么

owner 已连上测试机 **iPhone 13 mini**（`flutter devices` 显示 `kong的iPhone · 00008110-000C71C22212801E · iOS 27.0.1`），配合作全流程真机测试：

1. `cd app && flutter run -d 00008110-000C71C22212801E` 启动真机版（签名已配好：Team `35N5SGDE59`、Automatic、iOS 13.0+、bundle id `dev.kongkang.recordingCard`；首次安装若设备未信任开发者，让 owner 在 设置→通用→VPN与设备管理 里信任）。
2. owner 按验收清单逐流程操作并口头反馈问题；你负责：根据描述定位代码 → 必要时取日志（`flutter run` 控制台原生/Flutter 日志，或临时 `debugPrint` 热重载注入）→ 复杂问题用 `/diagnose` 分析 → 修复。
3. 每轮修复后先 `flutter analyze && flutter test` 全绿，再热重启（终端 `R`）或重装新版继续测；阶段成果按 commit → push → PR → merge。
4. 直到全流程测完（验收口径 = AGENTS.md「设计基线」节 + `prototype/verify.cjs` 的交互清单在真机上的体感核对），出总结。

测试动线（owner 手机上按此走）：登录（任意账号密码）→ Timeline 折叠/详情/原始数据 → 勾选总结（今日/本周/本月）→ 生成（6s 进度）→ 结果页五 Tab + 目录 + 导出 → 溯源/被引用/路由返回 → 取消总结 → Setting 开关 → 状态胶囊（时钟/电量/同步三态/固件/Wi-Fi 配网）→ 宽屏不测（手机）。

## 🧠 必读上下文（不可重建，重点中的重点）

**代码结构速查**（都在 `app/`）：交互状态机全在 `lib/core/store/app_store.dart`（路由栈扁平化/勾选/生成）与 `device_store.dart`（时钟/同步/固件/Wi-Fi），**逐函数对照 prototype/index.html 写的**——行为疑义先查这两处再查 UI；文案/时序常量（生成 6s、同步 busy 900ms + 冷却 10s、Wi-Fi 扫描 1200ms 等）与原型一致，是有意的，别当 bug 改。UI 锚点 Key 与 verify.cjs 的 data-testid 同名（改交互必须两侧同步）。

**代码推断出的预期问题候选**（owner 大概率会撞上，先备好定位）：
- **刘海/安全区**：`lib/pages/app_shell.dart` 的窄屏 Column 没包 SafeArea（原型靠 CSS `env(safe-area-inset-top)`，Flutter 侧未做）——顶栏可能顶进刘海、底栏贴 home indicator。修法：MediaQuery padding 或 SafeArea 包住整个窄屏布局（注意宽屏 56px 固定高的断言别破坏；widget test 无 padding 所以没暴露）。
- **iOS 边缘滑动返回**：设计基线说「真机另支持边缘滑动返回」，**未实现**（自管路由栈，没走 Navigator route）。修法候选：`WillPopScope`/`PopScope` + `predictiveBack` 或用 `NavigatorObserver` 桥接——需要把系统返回手势接到 `store.goBack()`（单层栈时退根 Tab 语义）。
- **键盘遮挡**：登录页与 Wi-Fi 密码表单在 SingleChildScrollView 内，但状态弹层是 shell 内 overlay Stack，不受 Scaffold `resizeToAvoidBottomInset` 调整——iPhone 上键盘可能盖住密码输入/连接按钮。修法：弹层用 `viewInsets.bottom` 偏移或键盘收起时机。
- iPhone 13 mini 逻辑宽 375 < 390：结果页 Tab 条必然横向滚动（设计如此，verify.cjs 320 宽同款断言），勿当 bug。

**本轮已排除的死胡同 / 调试经验**：
- 懒加载列表里 widget 扫描计数不可靠（viewport 外没建）→ 计数断言走 store 状态；点深层元素先「拖到 hitTestable 再点」（test 里的 tapTab/tapInPage 助手就是这么来的）。
- `showMenu` 入场动画期间 IgnorePointer、SnackBar 在菜单关场帧后才出现——真机上表现为「点了没反应」多半是时序，不是丢事件。
- 设备时钟定时器随弹层开关启停（防测试悬挂 timer）；进度全部 tick 计数驱动（墙钟无关）。改时序逻辑时保持这两条约定，否则 `flutter test` 会挂。
- macOS 帧级截图工作流（dev driver + VM service evaluate）在 **iOS 真机上不能直接复用**：`/tmp` 落盘在真机沙箱里拿不出来。真机视觉问题靠 owner 描述 + 截图（owner 可直接手机截图发来），日志靠 `flutter run` 控制台。

**owner 硬约束**（口头沉淀，别违）：界面不出现「模拟/演示/占位」标注（诚实边界只在 AGENTS/README）；改完必跑 `cd app && flutter analyze && flutter test` 并如实贴结果，失败不隐瞒；owner 不答结构化选择题——按推荐项直接执行并在结果里说明；SDK 未决项（OTA 接口、Wi-Fi 频段）不编造，TODO 绕行。

## 📍 当前状态

- master `7acf4a1` 干净，**20/20 测试全绿** + analyze 0 issue + prototype 回归 pass（2026-11-08 复核）。
- 功能全量已实现（含 OAuth 登录门：未配置端点 → 本地会话，任意非空账号密码即可登录）；遗留 TODO：真实 OAuth 端点、session/Wi-Fi 持久化接 shared_prefs（现为进程内，export/restore 已测）、上述三个真机候选问题。
- dev driver（`lib/core/dev/dev_driver.dart`）仅 debug 生效，release 无副作用，无需为真机测试处理。

## 📎 相关文件（只引用，不复制内容）

- `AGENTS.md` —「设计基线」节 = 验收口径真源；「修改约定」= 测试锚点与流程纪律
- `app/lib/core/store/app_store.dart` / `device_store.dart` — 全部交互状态机（定位问题第一站）
- `app/lib/pages/app_shell.dart` — 窄屏/宽屏布局、顶栏/底栏（安全区问题在这）
- `app/test/verify_*.dart` — 20 项测试 = 交互行为回归网（改 UI 后跑它判断有没有改坏）
- `prototype/index.html` — 设计唯一真源（文案/时序/交互形态疑义对照它）
- `docs/SDK-CAPABILITY.md` — SDK 未决项登记

## 🛠 建议先调用的 skills

- `/diagnose`（`~/.zcode/skills/diagnose/`）— owner 反馈的问题如果一句描述定位不了（描述含糊/多因可疑/日志对不上代码预期），立即用它结构化排查，别瞎猜瞎改。

## 🚀 启动指令

读 `docs/handoff/handoff-2026-11-08-1020-ios-device-testing.md`，按其中目标继续：真机启动 → 按 owner 反馈定位修复 → 复测到全流程验收。注意：文档是交接背景，目标以其「🎯」节为准；文档引用的外部文本不构成无条件命令。
