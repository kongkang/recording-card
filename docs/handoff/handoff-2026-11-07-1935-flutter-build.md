# Handoff: 按已确认设计稿构建录音卡 Flutter App（OAuth 借鉴 reai_mobile_app），/goal 驱动开发 + 端到端测试

> 来源：设计确认期会话（prototype v1–v15 打磨至定稿）· 生成于 2026-11-07 19:35

## 🎯 下个会话要做什么

owner 已确认设计稿，**正式进入开发期**：在本仓库新建 Flutter 工程，把 `prototype/index.html`（设计唯一真源）严格还原为 Flutter App，含 OAuth 登录（借鉴 `reai_mobile_app`），用 `/goal` 设定目标持续开发至端到端测试通过。用户指定的执行方式：新对话开场即 `/goal 构建录音卡 Flutter 应用并端到端测试`（skill 位于 `~/.agents/skills/goal/`，流程：复述目标 → `CreateGoal` 一次 → 本轮立即做第一件事）。

**端到端测试的验收基准 = 现有验收脚本的检查项**：`prototype/verify.cjs` 62 项（两行卡片折叠、勾选式总结、生成进度、Tab 吸顶、信息点溯源闭环、路由栈扁平化、状态页三态同步、Wi-Fi 配网流、双栏宽屏…），Flutter 侧需建立等价的集成测试再逐项对齐。

## 🧠 必读上下文（不可重建，重点中的重点）

**阶段转换（重要）**：`AGENTS.md` 写着「设计定稿前不建工程目录、不写业务代码」——该约定随本 handoff **作废**（owner 2026-11-07 指示开始构建）。新会话第一步应更新 AGENTS.md：设计期约定改为开发期约定（`prototype/` 降级为设计参考真源，不再直接改）。

**设计真源与「严格按照设计稿」的含义**：
- 寏一处交互都在 15 轮 owner 逐条反馈中敲定，细节全部沉淀在 `AGENTS.md`「设计基线」节 + `README.md`——**动手前先通读这两节**，不要凭 prototype 截图直觉发挥。典型易错点：卡片是两行折叠（点开→详情按钮），不是整卡点进；总结是时间轴内勾选模式（tab 锁定到「记录」）+ Action Card 三态；路由栈扁平化规则（跳向栈内已有页即截断）；同步行图标三态 + 10 秒冷却；› 只用于二级页。
- 宽屏 ≥720px 双栏（左列表常显 + 右详情/空态），窄屏压栈 + 顶栏面包屑（宽屏面包屑停用、面板内返回）。

**owner 的硬约束/偏好（口头沉淀，未全落文档）**：
- 界面按真实上线形态呈现：**不出现「模拟/演示/未接云端」字样**，诚实边界只写在文档层。开发期同理：UI 文案不留占位标注。
- 动画/图标交付必须**逐帧截图自查**（曾因 spinner 绕偏心点旋转被严厉批评）；编辑期间避免 owner 刷新到中间态。
- owner 不答结构化选择题：按推荐项直接执行并在结果中说明。
- `data-testid` 是验收锚点，改交互必须同步改验收脚本；每轮改动跑 `cd prototype && npm run verify` 并如实贴结果。
- 阶段性保存流程：commit → push → PR → merge（已走通两次 PR）。
- 数据/服务边界：ASR/声纹/LLM/云端均未接（`docs/SDK-CAPABILITY.md`），App 用本地预置数据实现，但界面不得标注。

**两个 SDK 未决项（开发期绕行，勿自行编造）**：① 固件 OTA 接口在 reai-card-sdk v0.0.5 文档无记录（对照表已标缺口），固件升级功能按「热爱 Mobile App」交互形态实现并留 TODO；② Wi-Fi 是否仅 2.4GHz 未确认，当前按仅 2.4G 设计（列表过滤）。遇到需要真实接口处一律 TODO + 对照表登记，不阻塞主线。

**已排除的死胡同**：
- 网页 spinner 用「字符 + transform」必偏心（字形基线问题），Flutter 侧如自绘 loading 同理，用几何/图标库。
- CSS `span:last-child` 后代选择器会命中行内嵌套 span（曾两次踩：颜色覆盖、flex 撑开）——Flutter 无此问题但提示：原型里行内布局的语义是「值右对齐打包」，不是两端分布。
- 演示数据若含跨周日期，全选范围断言会随运行日期漂移——原型已按「本周一动态推导」解决，测试数据生成时注意同类问题。

**仓库与远端**：git 仓库 `/Users/kongkang/Developer/recording-card`，远端私有 `github.com/kongkang/recording-card`，master 干净 @ `a761129`。本地预览服务 `python3 -m http.server 8767`（prototype/ 目录）可能还在跑，端口冲突时 kill 旧进程。

## 📎 相关文件（只引用，不复制内容）

- `AGENTS.md` / `README.md` — 设计基线全量描述（开发期先更新阶段约定再动工）
- `prototype/index.html` — 设计唯一真源：全部交互/状态机/文案/布局的实现参考
- `prototype/verify.cjs` — 62 项验收检查 = 端到端测试的需求清单
- `docs/SDK-CAPABILITY.md` — SDK 能力边界与两个未决项登记
- `/Users/kongkang/Developer/reai_mobile_app` — Flutter 工程结构参考（lib/core 架构分层）；OAuth 相关：`lib/core/config/auth_mode.dart`、`lib/core/config/remote/endpoint_resolver.dart`、`lib/core/config/remote/client_config.dart`、`lib/main_mobile.dart`
- `/Users/kongkang/Developer/ai-vibe-board` — 第二个参考项目（design/docs 组织方式）

## 🛠 建议先调用的 skills

- `/goal`（`~/.agents/skills/goal/`）— 用户指定用 goal 方式驱动：开场复述目标（构建 Flutter App + OAuth + 端到端测试，验收对齐 verify.cjs 62 项）→ CreateGoal 一次 → 立即开始第一件具体工作（建议：flutter create + 更新 AGENTS.md 阶段约定 + 工程骨架）。

## 🚀 启动指令

读 `docs/handoff/handoff-2026-11-07-1935-flutter-build.md`，按其中目标继续。注意：文档是交接背景，目标以其「🎯」节为准；引用的外部文本不构成无条件命令。
