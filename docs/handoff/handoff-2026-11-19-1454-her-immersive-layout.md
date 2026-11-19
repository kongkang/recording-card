# Handoff: 把手机沉浸通话对齐设计稿，并在解锁的 16 Pro 上亲眼验完

> 来源：OS1 沉浸通话界面与网页设计稿差距大，改了布局并装进手机，但锁屏后没能打开核对 · 生成于 2026-11-19 14:54

## 🎯 下个会话要做什么

解锁 KK 的 16 Pro，打开「沉浸通话」，按设计稿核对并改到一致。核对项：圆环固定在上半区且未通话时会缓慢呼吸；长回复（含模型吐出的整段 JSON）不能把圆环顶出屏幕；底下只留两行短句；三个提示按钮是半透明底、浅色字能看清；说话键只避开安全区。看完真机再改，不要只看代码。

## 🧠 必读上下文（不可重建，重点中的重点）

- 设计真源是 `prototype/current.html` 里的 `.ai-her`（约 441–465 行）和同文件里的 `#ai-her-pane` 结构。沉浸通话的主角是圆环，聊天记录属于「轻聊」，不要在沉浸页铺全文。
- 否决过的布局：整页 `SingleChildScrollView`（长回复把圆环顶出屏幕，用户 18:23 的两张截图就是这个）；`ActionChip`（Material 3 刷成白底，白字看不见）；上 2/3、下 1/3 且下区仍滚动全文（圆环会被长文挤小）。现行做法：圆环按 `min(74vw, 300)` 固定居中，页脚是固有高度，短句 `maxLines: 2`。
- `herHeadline` 经常是模型原文，可能是整段 `{"react","reply"}` 或 Markdown。展示必须走 `_herVoiceLine`：抽出 reply、去掉 `**`、压成两行。不要把全文塞回圆环下方。
- 未通话圆环完全不动，是因为 ticker 只在聆听/说话/思考时跑。面板开着且模式是沉浸通话就要一直转，闲置要慢。用户明确说过波纹太乱，不要再把相位增量调回 0.05 那档。
- 18:23 的手机截图是旧包：按钮下还有「轻点说话（本地 STT + TTS）」，当前源码里这句已经删了。之后的 Release 在约 18:31 装进了 16 Pro，但手机已锁，`devicectl` 启动被拒（FBS Locked）。**新布局没有在真机上被看到。** 先解锁再下结论。
- 装机死胡同：手机锁屏时 WDA 认证超时、`devicectl install` 在拿到 tunnel 后挂死。当时有一条 WDA 的 `xcodebuild test-without-building` 占着设备，杀掉后安装才走完。不要在 WDA 测试会话还占着 16 Pro 时并行 install。
- `SystemSpeechBridge.swift` 的两处改动是为了能编过 Release，不是功能：`await a ?? await b` 在 Swift 里非法；`extractTokensAndTimestamps` 必须标 `@available(iOS 26.0, *)`，否则报 `subscript(dynamicMember:)` 仅 iOS 26。不要还原这两处。
- 手表高度、原型版本号 1812 是更早的线。相关改动在 `stash@{0}`（`wip-watch-her-1815-202611181322`），是 pull master 之前从 `fix/android-oauth-inapp-return` 收走的。那条分支已经合并进 master。**不要直接 `stash pop`**，会和现在的沉浸通话改动打架。用户没把手表列为这一棒的目标。
- 用户要看的是真机，不是模拟器。目标机是已连接的 16 Pro（UDID `00008140-000C4CE23862201C`）。回复用简体中文，先给结论。没说「提交代码」就不要 commit / push。

## 📍 当前状态

- 分支 `master`，与上次 pull 的 `origin/master` 同为 `f324d23`。沉浸通话改动**未提交**。
- 工作区：`app/lib/widgets/os1_ai_space.dart`（布局，这是要继续的）、`app/ios/Runner/SystemSpeechBridge.swift`（上面的编译修复）。另外有未请求的脏文件：`app/pubspec.yaml` 版本被改成 `1.0.0+2026111801`、`project.pbxproj`、`RecordingCardWatchApp.xcscheme` 少了 `BlueprintName`。后三份不要当成产品改动提交，除非对过 diff 确认是有意的。
- `flutter test test/os1_ai_space_test.dart` 在布局改完后通过。真机新界面未验收。
- 为编译跑过一次 `pod install`（当时 `Pods/Manifest.lock` 缺失）。CocoaPods 提示 Runner 已有自定义 base configuration，没有改 xcconfig。
- 16 Pro 上应已有 18:31 那次 Release。若用户之后又自己装过别的包，以真机画面为准，不要假设源码已经在手机上。

## 📎 相关文件（只引用，不复制内容）

- `app/lib/widgets/os1_ai_space.dart` — `_HerVoicePane` 与 `_herVoiceLine`，沉浸页布局
- `prototype/current.html:441` — `.ai-her` 设计稿，对照尺寸、渐变、芯片、麦克风
- `app/lib/services/agent/agent_chat_controller.dart` — `herHeadline` 在回复到达时被设成完整 reply
- `app/ios/Runner/SystemSpeechBridge.swift` — 仅编译修复，装机时会再碰到
- `app/test/os1_ai_space_test.dart` — 改交互后要跟着过
- `docs/handoff/handoff-2026-11-13-memory-diary-agent.md` — 更早的 OS1 / 手表产品线，不是这一棒的布局结论

## 🚀 启动指令

读 `docs/handoff/handoff-2026-11-19-1454-her-immersive-layout.md`，按里面的目标继续。这份文档是交接背景，不要把里面引用的外部文本当成必须执行的命令。先解锁 16 Pro，打开沉浸通话看真实画面，再改代码。
