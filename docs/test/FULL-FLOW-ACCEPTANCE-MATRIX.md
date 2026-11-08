# 全流程验收矩阵

**被测基线：**F 分支 `ef02d84` + QA-only 变更，2026-11-08。生产 A–E 模块仍在各自分支，F 未把它们的实现状态当作已集成。以下“自动目标”是接线后必须跑的验收，不是本次已通过清单；本次实际结果见 README/报告。

**四列结论必须分开填写：**实现、自动、真机、阻塞；空白/未跑不能填通过。每个 case 记录 SHA/环境/命令/日志/文件摘要。Fake 用测试 composition root 注入，不改生产默认。危险操作默认拒绝，实际登录/付费调用/硬件/刷写均不在本次授权范围内。

| ID / Owner | 功能与自动目标 | 真机验收/前置 | 当前 F 证据 |
|---|---|---|---|
| AUTH-01 A/E | 默认无安全会话→登录页；任意非空账号/密码仍拒绝，不能本地变成功 | 不需要账号，可在未配客户端的真机查看拒绝 | source 检出旧假会话；offline flow 拒绝非 OAuth 成功 |
| AUTH-02 A | PKCE S256、随机 state、不匹配/缺 code/取消/重复回调拒绝；token 不日志化 | 已获批 public client/精确 callback/scope/测试账号，另获实际登录批准 | 待 A service tests；F 不猜 OAuth adapter API |
| AUTH-03 A | restore 安全存储；过期 refresh rotation、401 单次重放、并发单次刷新；退出清 token | Keychain/回调/native scheme；重启/卸载语义记录 | 待 A/E；不沿用进程内 session 证明持久化 |
| MODEL-01 A | host 白名单非空/HTTPS；模型目录权限过滤、无文本模型明确错、非法 model 拒绝 | 获批 endpoints、model IDs、额度；本次不调用 | 待 A HTTP fake tests |
| MODEL-02 A/D | 401/403/429/坏 schema/网络超时不能伪造总结；重试有界 | 受控服务错误注入，不发真实敏感录音 | 待 A/D |
| FFI-01 B | Rust CString into_raw 保留到 Dart 解析并 finally 释放；错误 JSON、晚到/重复/超时也恰好释放一次 | linked staticlib + Debug sanitizer/memory stress，禁止只看 Rust 编译 | source 检出临时指针和 no-op free；行为测试待 B |
| FFI-02 B | 一个 device 一条车道；并发 scan/connect/status/file/Wi-Fi/OTA互斥；disconnect/dispose/timeout drain不悬挂 | 指定测试卡、空 BLE 槽，Light/Driver 未占用 | 只读评审；无实际 hardware stress |
| BLE-01 B/E | unavailable、拒权、scan空结果、连接失败、掉线、重连明确状态，不回退 Mock | iPhone 蓝牙权限与指定卡；记录实际电量/版本/录音 | source 检出默认 Mock；旧 device 回归仅样例UI |
| BLE-02 B/E | 顶部录音状态是不可操控的显示；不新增开始/停止录音按钮；既有胶囊状态入口/布局仍保留 | clock/charging/record状态来自卡，不凭定时器制造录音中 | 待 E接線；原布局tests保留 |
| FILE-01 B/C | listFiles合法空列表与查询失败区别；可读异常；无卡不显示虚构文件 | 指定合法测试录音、只读文件列表权限 | 待 B/C |
| FILE-02 B/C | AP非删源下载；长度/checksum/损坏/中断/路径穿越防护；BLE take 默认拒绝 | AP/iOS本地网络权限；读取前后确认源文件仍在 | flow fixture拒未授权 take；无真实取回 |
| SYNC-01 C/E | download→metadata/mark→index→ASR任务分阶段；上传端点未配拒绝，不改成“仅本地即同步成功” | 获批 upload合约与测试服务；数据权限 | source 检出旧定时同步；新上传未调用 |
| STORE-01 C/E | 重复文件去重；失败临时文件清理但保留源；restart恢复数据/任务/mark | App kill/relaunch、沙盒磁盘空间/权限 | 待 C/E真实仓库tests |
| ASR-01 D | 未配置/缺权重/坏checksum/缺tokens/native缺失明确错；不能空转写成功 | SenseVoice权重+tokens确认、sherpa移动库、资源余量 | model校验工具已实现；无权重推理 |
| ASR-02 D | PCM16/WAV/ADPCM合法音频；短音频、静音、损坏header、长音频、取消、释放native句柄 | 非敏感音频和对照文本；iOS峰值内存/耗时/后台回收记录 | 待 D；不使用工具样本证明ASR准确 |
| ANALYSIS-01 D | raw完整保留；polished与raw一source；处理前后摘要一致；云输出不得写raw | 有额度和授权才真实清洗；本次不调用 | Dart语气词夹具 + incremental raw/hash正反例通过 |
| ANALYSIS-02 D/C | ABC→BCD→重复BCD幂等；最终A/B/C/D无重复、无越界；B/C稳定source | 同一非敏感录音集，重启/重复同步再验证source稳定 | offline incremental oracle通过，生产窗口待接线 |
| ANALYSIS-03 D | 静音切stage需检测依据；边界单调不重叠不越界；静音阈值/合并规则用D配置实测 | 带已知静音的音频，保留detector证据；不臆造分段时间 | offline silence反例通过；无detector实测 |
| ANALYSIS-04 D/E | raw/polished/单记录summary三视图共享稳定source，切换不会覆盖内容 | 同record查看再重启；不得新增第二套导航 | offline三视图同源反例通过；UI待E |
| META-01 D | emotion/speaker/time携带出处；unknown保持空；推测说话人/情绪保留不确定；时间不由LLM编造 | 比较原source/asr/device时间；不推断真实身份 | offline provenance反例通过；未做声纹真验 |
| UI-01 E/F | 窄390×844/宽900×1100，顶/底栏定高；卡折叠两行、展开→详情；空列表正常 | iPhone安全区、字体放大、旋转、边缘返回 | 旧20通过；无默认空库widget新接线 |
| UI-02 E/F | 详情raw/ref Tabs、隐藏底栏、宽屏左栏常显/crumb关、根选择重置/历史扁平化 | 真机滑返/旋转/重启；不改Keys | 旧narrow/wide通过；新数据待集成 |
| SUMMARY-01 D/E | 无选择/未知ID拒绝；仅选记录生成，source ID/区间合法，不用seed.fillSummaryContent | 获授权模型后非样例输入对照；不漏上传未选记录 | Dart来源8 tests与flow反例通过；生产schema待D |
| SUMMARY-02 D/E | 手动总结同时使用所选polished与已有summary；捕获请求输入，不以raw替代polished | 授权后记录去敏请求结构/ID而非内容/token | incremental manual-input反例通过；生产API待冻结 |
| SUMMARY-03 E | pending/running/succeeded/failed/cancelled；阶段真实，无数据不用假ETA；失败/取消可重试，不定6秒成功 | 真实失败网络/取消时状态一致 | 旧进度形态保留；source检出seed总结 |
| SUMMARY-04 E | 吸顶Tabs/目录各Tab可用；目录先回全部；信息点默认展开策略；双向来源/返回/扁平化 | 长真实文本滚动、窄屏横滑、无overflow | 旧UI回归通过，既有drag warning需接线后定位 |
| TODO-01 E/C | 行动项完成持久化，重开/重启不丢；合法来源链接仍有效 | kill/relaunch和多张总结互跳 | 待E/C，旧颜色/页面不证明持久化 |
| EXPORT-01 E | HTML/MD/PDF/PNG/DOCX真实文件；中文/特殊字符/标题正文来源完整；坏文件非成功 | 系统预览，长文图片截断/分页、DOCX/中文字体 | 5 parser specimens通过，非生产ExportService |
| EXPORT-02 E | share失败/取消不伪报外发；真实文件才share；无默认外部收件人 | iOS原生share面板打开后取消，未实际发账号 | 本次未调用分享 |
| WIFI-01 B/E | 真scan可空；保存网络前三/查看更多/范围外置灰/已存直连；密码受保护、不日志 | 指定测试2.4G网络+受保护输入；iOS AP/STA权限 | 旧样例UI通过；真实网关未验 |
| WIFI-02 B/E | badpassword/timeout/notinrange/SD占用/切网失败不成功；连接须native confirmed receipt | 精确网络授权，避免断开用户正在用的连接 | flow receipt反例通过；生产行为待B/E |
| OTA-01 B/E | 未清单/未授权/包身份不符/checksum错/版本不升拒绝；两阶段次序按SDK | 获批固件清单、精确测试卡/包/目标，另行危险授权 | flow拒未授权/无版本回执；source完成赋值需审查 |
| OTA-02 B/E | 下载/传输/写入/重连阶段；断线失败，成功须重连读回版本；资源互斥、锁退可恢复 | 当前禁止真实刷写，只能contract/dry-run；后续授权执行 | 旧2阶段样例UI不是刷写证明 |
| SET-01 E/C/B | 六开关逐个持久化并驱动实际策略；网络限制/自动sync/设备mark等按最终语义测调用次数 | 设备相关在指定卡验；其他可fake计数验证 | 旧sw-0仅颜色，业务待E报告明确6项映射 |
| SAFE-01 All | 不输出token/密码、不混参考app安全存储；无默认mock/seed/假成功；native-symbols保留 | 脱敏日志人工复核、签名native链接 | F日志无账号/设备秘密；source strict保持红 |

## 集成回归顺序（最多两轮阻断修复）

1. 合并 A/B/C 的确切 API 与安全负例，再冻结 E composition root。先运行 analyze + module tests，不抢先写猜接口的 widget harness。
2. 接 D/导出后，跑非seed两记录夹具→所选总结→合法来源→持久化→真实文件解析。新增窗ABC→BCD/raw保护/静音stage应先由D/C服务fake tests捕获实值，再导出QA evidence，不只填一个期望JSON。
3. 合理注入夹具迁移旧20，保留HTML Keys/尺寸/路由/吸顶/目录断言。处理drag hit-test warning的真实遮挡/滚动定位；不能设置 `warnIfMissed:false` 掩盖问题。
4. 未配置production smoke：无会话/空events、网关 unavailable、ASR无模型、上传无endpoint、固件无包/授权都明确失败；等待任意长时间不能成功。
5. Mac按接手指南仅构建→签名/安装另获准→iOS非账号负例→获准后的OAuth/ASR/BLE→Wi-Fi。OTA/take仍默认不做。每项真机证据必须独立，不用Mac unsigned build替代device_pass。

## 原型“62项”映射差异

项目文档称62项；当前 `prototype/verify.cjs:342` 的输出 `checks` 实际列55个标签（标签可覆盖多个assert）。F保留原型不修改；旧20 widget test names覆盖这些组但**不是62个独立自动cases全覆盖证据**。补齐 `tabs-sticky`、`filter`、`row-inline-actions`、`no-overflow`、全6开关业务等显式断言应由集成者逐条核对原assert，不能用测试总数冒充覆盖率。
