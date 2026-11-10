# AGENTS.md · 录音卡项目协作规则

给接手本项目的工程师与 AI 协作者。全局通用规范见用户级 `~/.Codex/AGENTS.md`，此处只写本项目特有约定。

## 当前阶段：语音转写 / 增量润色 / 分段总结（2026-11-08 起）

PR #7 已把正式版基线（真实 BLE 桥 + OAuth + 模型网关 + 真实总结 + 导出）合并进 master（`664211f`）。
本阶段在 `stage/asr-polish-timeline` 上实现「设备文件 → 本地切片 → 本地转写 → 云端窗口改写 → 话题分段 → 三处展示」，
完整计划见 `docs/handoff/handoff-2026-11-08-asr-polish-plan.md`（owner 已确认，2026-11-08）。

- `app/` 是 Flutter 工程（主交付物）。分层参考 reai_mobile_app：`lib/core`（config/models/theme/store）、`lib/services`、`lib/pages`、`lib/widgets`；测试在 `app/test/`。
- **验收基准 = `prototype/verify.cjs` 的 64 项检查**（2026-11-09 新增连接/录音/自动同步 7 项、2026-11-10 新增 feed 倒序与相册缩略图 2 项后实际 64；历史文档曾写 55/62 两种口径，以脚本 checks 为准）：Flutter 侧在 `app/test/` 建等价 widget/集成测试逐项对齐，命名与检查项一一对应。
- `prototype/` 降级为**设计参考真源（只读）**：还原有疑义以它和「设计基线」节为准，不再直接改它；如确需改设计，先与 owner 确认，并同步 `prototype/verify.cjs` 与 Flutter 测试。
- 本阶段硬约束：
  - **本地转写优先**（SenseVoice + Silero VAD）；云端只做润色与分段总结。模型缺失时音频入库排队，**不上传音频、不编造文本**。
  - 说话人由声纹聚类推测，展示「说话人 1 / 2（推测）」；低置信度「未区分」，**不断言真实身份**。
  - 音频切片、转写文本、声纹 embedding 默认只在本机；云端只上行润色/总结所需的文本。
  - V1 走文件拉取，**延迟 20~35 分钟是 BLE 3~8 KB/s 的物理上限**；不做实时流。界面用「正在录音」状态块如实区分已转写 / 处理中 / 等待处理。
  - 失败必须如实呈现（未连接、未登录、模型缺失、润色失败），不静默降级成编造内容。
- 推翻设计基线（下一节）前先与 owner 确认，不顺手改。

## 目录职责

- `app/`——Flutter 工程（主交付物）。分层参考 reai_mobile_app：`lib/core`（config / models / theme / store）、`lib/services`（transcribe / polish / segment / recordings / net）、`lib/pages`、`lib/widgets`；测试在 `app/test/`。
- `prototype/`——设计参考真源（**只读**）。单文件内联 CSS/JS，无构建、无外部资源、`file://` 可直接打开；其 `verify.cjs` 55 项是开发期验收需求清单。
- `docs/handoff/`——阶段交接文档（含开发期启动指令与 owner 硬约束）。
- `docs/SDK-CAPABILITY.md`——上游 SDK 能力对照（reai-card-sdk v0.0.6 @ 32a1b86，异步 Rust + btleplug，非 Flutter 插件）。
- `docs/gen-evidence/`——原型生成证据链（Flash prompt/output 留存、核验结果、旧版验收脚本）。**只读**。
- `archive/`——旧版原型与截图。**只读**，不作为当前结构的依据。

## 设计基线（2026-11-07 v3 打磨）

- 顶栏即导航：首页「录音卡」+ 状态胶囊（绿点心跳 + 电量）；子页变「‹ Timeline」返回，顶栏吸顶。
- Timeline：按日分组倒序（今天→昨天→更早；同一天内按时间从晚到早排序，不依赖数据源数组顺序）；卡片折叠两行（标题 / 时间·时长），点击展开摘要与说话人、再次点击收起；展开态「详情」按钮进详情页。卡片正文不直接导航。 记录行标题右侧放相册缩略图：45px 正方形（与标题+时间同高），1 张单图、2~3 张层叠、超过 3 张第 4 层为带总数遮罩图；标题/时间单行省略号防遮挡。
- 总结：点「总结」Tab 立即定位「记录」并禁用其他 Tab；时间轴内勾选模式（全选今日 / 本周 / 本月）；底部操作栏两行（上行唯一计数，下行取消 / 生成）；生成在总结页内呈现明确状态（进度条 + 已生成/预计还需秒数 + 步骤），Action Card 同步进度且完成前锁定，取消则移除。
- 总结卡：生成后落在它所总结内容的最早一条记录之后（取来源记录里日偏移最大、同日时间最早的一条作锚点），不无条件堆在「今天」最上面；总结没有独立详情页，点整张卡直接进总结结果页，不再先展开再点「查看总结结果」。
- 总结结果页：内容标题 + 统计行；Tab 栏吸顶（滚动中持续可见，文字不换行、宽度不足时横向滑动），栏右端常驻「目录」浮钮（各 Tab 均可用，点开列表跳转段落；非「全部」Tab 点击目录项会先切回「全部」再滚动）；Tab 结构：全部 / 概览 / 逻辑结构 / 信息点 / 行动项 / 来源记录（「全部」不含 Markdown 原文）。信息点结构化（标题+细节+溯源链接，可展开）：「全部」里默认收起，切到「信息点」Tab 默认全部展开。页头右上「导出」模拟调起系统分享（完整文档 / Markdown / PDF / 图片 / Word）。
- 详情页：「对话详情 / 原始数据 / 被引用总结 N」平级 tab（被引用总结仅 N>0 显示）；手机宽度下子页隐藏底栏，经顶栏返回（真机另支持边缘滑动）。
- 宽屏自适应：≥720px 双栏，左栏 Timeline 常显供对照，右栏详情/空态；顶栏与底栏高度固定（宽屏 56px / 窄屏顶栏 52px），中间区域撑满；宽屏顶栏面包屑停用，嵌套时在面板内标题左侧显示「‹ 返回总结 / 记录」。
- 路由栈：总结↔来源互跳统一历史栈；跳向栈内已有页面即扁平化截断（防无限嵌套），返回弹栈至外层，回根 Tab 清空；窄屏用顶栏面包屑（‹ 总结/‹ 记录/‹ Timeline）。导航分两种来源：左栏列表点击 = 根级新选择（栈重置为单层，不叠返回按钮），面板内链接 = 压栈/扁平化；返回文案由页面注册表派生（sum=总结/detail=记录），不写页面配对硬编码。栈与已生成总结卡存 sessionStorage（同标签页刷新不丢，关页自动清），启动时恢复重建。
- 录音卡状态（胶囊弹层）：严格单行布局（行高加高）——录音状态（红点「录音中」+ 跳动时钟 h:mm:ss，定宽等宽字体防抖动）、电量（电池图标 + 高/中/低，不显示百分比 + 可录至时点保守估算）、同步（自动同步为主：行文案「自动同步 · 相对时间」，30 秒/1 分钟阶梯，之后按分钟，不精确到秒；用户点行 = 手动同步，成功显示「同步成功 · 刚刚」；不放旋转图标避免「一直在传」的焦虑）、Wi-Fi（已配置 · N 个网络；点击进二级页：已保存网络置顶——默认显示前 3 个、更多经「查看更多已保存」展开，扫描范围外的保存网络置灰不可选；分割线下为扫描到的可用网络，已保存且在范围内的点击直连无需密码，新网络点选输入并保存名称密码后连接；名称与密码存 localStorage 模拟（未来客户端存储），硬件端只保留最后一次连接的网络；列表仅显示 2.4GHz）、固件（仅待更新时显示「有可用更新」；两阶段：主控芯片 / Wi-Fi 芯片，版本对比只在更新页呈现，更新中「返回」禁用并提示勿退出）。同步 / Wi-Fi / 固件三行行内可点（右侧 ›），分别触发同步上传、Wi-Fi 设置页、固件更新；同步行图标三态：sync 环形箭头（灰态）→ 自转 loading（正在同步…）→ 绿色对勾（同步成功 · 刚刚），成功后 10 秒冷却禁点（防频繁同步耗电），到期恢复灰态 sync 图标；› 箭头仅用于进入二级页（Wi-Fi / 固件），不作为行内动作反馈。行值统一右对齐 flex 排版（icon 与文本垂直居中）。底部仅「关闭」。胶囊圆点：绿=正在录音（运行中，心跳）、橙=已连接但未录音（待机，电量真实）、灰空心=未连接；电池图标仅连接后显示（<20% 红 / <40% 橙 / ≥40% 绿，不显示数字）。转录配置放 Setting。
- 连接与录音流程（2026-11-09 定稿）：默认未连接——胶囊灰点、不显示电量；点开先「连接录音卡」并自动扫描，设备名按 DYJ 前缀过滤（非本系列不展示）、按 RSSI 从强到弱排序（越近越靠上）。连接成功后默认未录音；录音状态行右侧是开关，打开后红点 + 正计时，关闭用 220ms 过渡回「未录音」。设备约 5 分钟一个切片；每片传完并转写完成后作为「今天」第一条进入 Timeline。顶部「正在录音 · 未转录」状态块表示当前录音中、尚未转录的部分，不是可点记录；积压最多约 30 分钟，日常约 5 分钟一段。停止录音自动同步，顶部块切「正在同步」直到整理完成；勾选总结与「总结」Tab 隐藏该状态块（不可勾选、不参与计数）。手动同步行保留用于重试/补传。
- Tab：全部 / 记录 / 总结；总结结果：Markdown + 可交互 HTML 两种视图，均本地预置。
- 产品需求：连续录音默认不分段、偶尔 mark；清洗内容优先展示，原始数据完整保留（低权重）；推测归类必须保留原始映射，不断言真实身份。

## 真实性红线（2026-11-08 起：全链路转真实，预置数据退役）

owner 明确要求「做正式发布版，所有问题都要解决」，旧口径（业务数据一律用本地预置示例）**已作废**，改为：

- **硬件**：经 `app/rust/card_bridge`（C ABI，`card_bridge_command` 单一入口）接 reai-card-sdk v0.0.6 真实 BLE——扫描/连接/电量/固件版本/存储/录音控制/打点/文件列表与下载/AP→WAV 转码/Wi-Fi 扫描与凭据/同步上传/两阶段 OTA。桥不可用（模拟器）时**显式失败**，不回退预置假数据。
- **转写与总结**：真实调用后端模型网关（`RC_API_BASE` 默认 `https://block2-api.wainao.chat`；ASR `/api/model-gateway/v1/audio/transcriptions`，总结 `/chat/completions`），鉴权走真实 OAuth2（PKCE S256 + 系统浏览器授权 + Keychain 存 token）。未配置/未登录时给出**明确错误并可重试**，绝不展示编造内容。
- **仍未接**：声纹/说话人分离（ASR 不返回，界面按「未区分」呈现，不编造 A/B 身份）。本阶段 P2 起改为本地聚类推测，展示仍必须标「推测」。
- 界面仍按真实上线形态呈现，不出现「模拟/演示/未接云端」标注；但真实失败（未连接、未登录、服务不可用）必须如实提示。
- 交互视图只允许预置安全内容，不执行任意 HTML/脚本（WebView 场景禁用，Flutter 侧用原生组件还原）。

## 修改约定

- Flutter 侧测试锚点用 `Key('data-testid 同名')`：`prototype/verify.cjs` 的 `data-testid` 是需求语义，App 与测试两侧改名必须同步。
- 验收流程顺序与页面导航强相关（如：详情页内先看原始数据再返回），改交互流时同步改测试。
- Flutter 改完必跑 `cd app && flutter analyze && flutter test`，结果如实贴出；失败不隐瞒。
- 真机验证：`flutter test integration_test/hardware_probe_test.dart -d <deviceId>`（硬件在环探针）、`flutter test integration_test/recording_pipeline_test.dart -d <deviceId>`（取回→转 WAV）与 `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/ui_flow_test.dart -d <deviceId>`（界面动线 + 截图，产物在 /tmp/rc-shots）。
- 本地转写全链路（会移动设备文件，只取一个）：`flutter test integration_test/pipeline_device_test.dart -d <deviceId> --dart-define=RC_SPIKE_WAIT_FOR_MODELS=true`；开发期模型用 `devicectl` 拷到应用容器 `Library/Application Support/models/`（见 `docs/ASR-PIPELINE.md` §6）。重装后 iOS TCC 会重置，首次需在真机点「允许蓝牙 / 允许本地网络」。
- 本地 ASR 模型开发期 sideload：SenseVoice 取自 `~/Library/Application Support/reai-vibe-board/models/sensevoice-int8/`，VAD 取自 `reai_mobile_app/assets/models/silero_vad.onnx`；生产必须走 `RC_MODEL_MANIFEST`/`RC_MODEL_BASE` 下载，**不把 237MB 模型提交进仓库**。
- 转写/润色的时间语义一律用「相对录音起点的毫秒」存储，展示时再叠加设备 `start_at`；不用本地墙钟推算设备时间。
- Rust 桥构建必须用 rustup 工具链（`app/rust/build-ios.sh` 已固定 1.94.0）：本机 PATH 里 Homebrew 的 rustc 会遮住 rustup，而它没有 iOS std。
- SDK 未决项（固件 OTA 接口、Wi-Fi 是否仅 2.4GHz）不编造：按设计稿交互实现 + 代码 `TODO` + `docs/SDK-CAPABILITY.md` 对照表登记，不阻塞主线。
- 阶段性保存：commit → push → PR → merge。
- OAuth 借鉴 reai_mobile_app：`lib/core/config/auth_mode.dart`、`lib/core/config/remote/endpoint_resolver.dart`、`lib/core/config/remote/client_config.dart`、`lib/main_mobile.dart`；登录 UI 按真实上线形态做，凭据/端点配置走 `--dart-define`。
