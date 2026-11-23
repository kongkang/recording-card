# Visual Polish Log · 录音卡 5 套方案打磨记录

> 遵循 `huashu-design` v3.5.0 打磨环（`references/polish-loop.md`）：每次截屏并逐张审视原图，写出最伤的三处问题，修改后重截复核。

---

## Round 1 视觉审视记录（基于 `polish/round-1/`）

### 发现的跨方案共性瑕疵
1. **品牌图标 `app_icon.svg` 裁切失效（全部 5 版 + `index.html`）**：`app_icon.svg` 原文件自带 `width="1024" height="1024"` 属性，放进 `22×22` 顶栏容器时未重写宽高为 `100%`，导致只截出了左上角 `#FDFDFB` 浅底空白方块，标志性的「黑色硬件卡片 + 五根波形 + 右上红点」完全没显示出来。
2. **顶部 `.gallery-bar` 使用 `position: sticky` 遮挡展示板顶栏（`dir-1` / `dir-5` 截屏）**：在滚动或整板截图时，吸顶画廊条会压住 `方向一` / `方向五` 顶部徽章的一半高度。
3. **`index.html` 底部 `<iframe>` 在 `file://` 协议下呈现空白灰框**：浏览器在本地双击 `file://` 打开时对本地子帧隔离，导致预览台出现大片空白灰区。
4. **中文中点 ` · ` 残留**：各版展示板徽章与个别副标题残留 ` · ` 拼接符（`dir-1` 3 处、`dir-3` 6 处、`dir-5` 2 处）。

### 各方案专属结构与排印问题（逐屏最伤处）
- **方案一 `dir-1.html`（声波仪 Field Deck）**：
  - 窄列 `.fd-slot-head` 采用左右 `flex` 挤压布局，导致「对轨详情与声纹定名」「结构化总结与导出」「OS1 声波同频终端」发生孤字折行（如「导 / 出」）。
- **方案二 `dir-2.html`（昼夜声轴 Chronos Ribbon）**：
  - 1:1 视图左时间标尺列宽仅 `52px`（含右内边距 `10px`），导致「18分40秒」「9分12秒」末尾的「秒」字被挤到第二行；「2图」徽标也发生垂直折行。
- **方案三 `dir-3.html`（卷宗编辑部 Archival Folio）**：
  - **严重遮挡**：展示板左上角导语 `.af-lede` 下沿直接与下方 `p1` 手机上方标签「卷首 · 今日头版结论」重叠打架。
- **方案四 `dir-4.html`（暗房声场 Nocturne Studio）**：
  - **严重遮挡**：展示板左上角导语 `.ns-lede` 下沿直接与下方 `p1` 手机上方标签「OLED 暗房主控台」重叠打架。
- **方案五 `dir-5.html`（灵动叠卡 Liquid Folio）**：
  - 第 5 台手机底部文字滚到玻璃药丸导航下方时，药丸底色略偏透，高密度文本穿透影响文字辨识。

---

## Round 1 修复措施（已同步写入源码与生成脚本）
1. 在 `shared_engine.js` 与 `gen_index.py` 中清洗 `appIconSvg` 的固定 `1024` 宽高为 `width="100%" height="100%"` 并保留 `viewBox="0 0 1024 1024"`，让黑色录音卡波形 Logo 在所有顶栏锐利呈现。
2. 将 `common_builder.py` 中 `.gallery-bar` 从 `position: sticky` 改为自然文档流 `position: relative`，彻底消除滚动与截屏时的顶栏遮挡。
3. 修复 `dir-1` `.fd-slot-head` 为纵向堆叠排版，消除全部孤字换行。
4. 将 `dir-2` `.cr-time-col` 扩宽至 `64px` 并为时长与图数徽标增加 `white-space: nowrap`。
5. 大幅拉开 `dir-3`（`p1` 下移至 `y: 284px`，题签牌下移至 `y: 1264px`，画板增高至 `1810px`）与 `dir-4`（`p1` 下移至 `y: 294px`，规范卡下移至 `y: 1240px`，画板增高至 `1730px`）的顶部导语与首台手机间距，彻底消灭文字碰撞。
6. 提升 `dir-5` 悬浮玻璃药丸底栏不透明度（`0.94 / 0.86`），保证任何滚动状态下导航文字对比度清晰锐利。
7. 消除全部 5 套方案及 `index.html` 内的 ` · ` 拼接符（改用冒号、斜线或独立字段）。
8. 升级 `index.html` 底部预览台：内嵌高保真展示板交互预览图 + 实时参数拆解面板 + 一键直达完整交互展示板与 1:1 单机沉浸模式，彻底消灭 `file://` 下 `iframe` 灰框风险。

---

## Round 2 复检结果（基于 `polish/round-2/` 与 Playwright 实测）

- **自动指标（`dir-1.html` ~ `dir-5.html` 与 `index.html`）**：
  - `pageErrors = 0`、`consoleErrors = 0`
  - `brokenImgs = 0`、`relImgs = 0`（全量照片 base64 内嵌，断网双击可开）
  - `clipped = 0`、`overlaps = 0`、`narrowPhones = 0`、`smallTexts = 0`、`dotsCount = 0`
- **真实点击交互验证（全部 5 套均通过）**：
  - `liveClockTicked = true`（开/停录切换并验证计时器实时步进）
  - `speakerRenamed = true`（对话详情点击说话人弹出「为说话人命名」并联动刷新，支持切入「原始数据」）
  - `exportModalOpened = true`（总结行动项可勾选且「导出」系统分享弹层可正常开合）
  - `os1Replied = true`（OS1 切入「轻聊」点击快捷提问能读取本机记录并生成回复）
  - `singleModeWorked = true`（`展示板全景` 与 `1:1 单机沉浸体验` 双向无缝切换）
- **视觉复查结论**：`dir-3` 与 `dir-4` 左上角文字重叠已彻底消除，`dir-1` 与 `dir-5` 顶栏裁切已消除，所有顶栏 `app_icon.svg` 清晰显示黑卡波形与红点，`dir-2` 时间列不再折行，`index.html` 预览台清晰呈现 5 套展示板实景。

---

## v2 极简重构与验收记录（基于 `polish/v2-round-1/`）

### 减半重构内容（去说教、重留白、直达结果）
1. **移除说教与工程术语**：砍掉全部介绍型长句、方法论标签、`CAM++ / VAD / dBm / GB` 等底层硬件参数与冗长说明墙。
2. **精简页面结构与信息密度**：
   - `dir-1.html` ~ `dir-5.html` 展示板保留足够画布留白与 4 台实景设备布局（`主屏 / 细节与控制 / 总结 / OS1`），交互覆盖列表、详情（`对话` / `原文`）、总结（`结论` / `全文` / `来源` + 导出弹层）、`OS1` 问答与 `设备与设置`。
   - `index.html` 移除 3 列说明块与 7 列对比大表，重构为极简顶部方案切换 + 单屏焦点预览 + 5 卡片画廊索引（直接内嵌 `v2-round-1` 展示板压缩预览图，支持一键打开展示板或 `1:1` 单机体验）。

### `v2-round-1` Playwright 与视觉复检（`index.html` + `dir-1.html` ~ `dir-5.html`）
- **全部 6 个 HTML 自动化检查通过**：
  - `pageErrors = []`、`consoleErrors = []`
  - `brokenImgs = 0`、`relImgs = 0`
  - `clipped = 0`、`overlaps = 0`、`narrowPhones = 0`、`smallTexts = []`、`dotsCount = 0`
  - `dir-1` ~ `dir-5` 均包含 `4` 台手机视口，且 `liveClockTicked`、`speakerRenamed`、`rawTabOpened`、`exportModalOpened`、`os1Replied`、`singleModeWorked` 全部返回 `true`；`index.html` 切换预览 `previewSwitched = true`。
- **视觉实图复查**：已查阅 `polish/v2-round-1/dir-1-board.png` ~ `dir-5-board.png`、`dir-5-hero-1x.png` 与 `index-gallery.png`，确认版面留白充裕、无遮挡重叠、焦点预览图无多余灰边衬底。

---

## Apple Watch 六套风格联动设计打磨记录（基于 `polish/watch-round-1/` 与 `polish/watch-round-2/`）

### 交付范围与最新 Watch 规范对齐
1. **默认版双端手表原型升级（`watch/prototype/index.html`）**：对齐 `prototype/current.html` 暖白编辑风纸感主题（`#FAFAF8` 纸基 / 暖灰细线 / 朱红停止滑条与琥珀打点徽章），保留纯本地零外链与 1:1 `WatchMainView` / `RecordingCardComplication` 红线约束。
2. **Watch 6 套风格专页与手机方案联动（`design-demos/watch.html` + `dir-1..5.html?mode=watch` + `index.html`）**：
   - 覆盖 **默认静纸**、**1. 声波仪（Braun Field）**、**2. 昼夜声轴（Chronos）**、**3. 卷宗（Folio）**、**4. 暗房（Nocturne）**、**5. 灵动卡片（Air）** 共 6 套表端风格；每套配「录音中（敲击打点 + 哑光平铺右滑停录 + 底部单圈 60s 与待传队列）/ 待机表盘（AOD 息屏切换 + 一键开录）/ watchOS 11 四家族复杂组件」三表同台与底部 6 卡实机对比画廊。
   - 坚守最新手表硬约束：顶部无 App 名称（仅显示连接态 + 三档文字电量）、非按钮双击表壳打点、无百分比与「已充满」、无「运动保活 / 模拟 / 演示 / GPS·心率」、无 ` · ` 空格间隔符。

### `watch-round-1` 视觉审视与修复措施
1. **`dir-1..5.html?mode=watch` 下手机展板未彻底隐藏（`dir-2-watch.png`、`dir-5-watch.png`）**：`.gallery-bar` 样式中的 `#stage-wrap { display: flex; }` 优先级高于原生 `[hidden]`，导致切换至 `Apple Watch` 模式时手机四联屏仍暴露在手表展台上方。已在 `common_builder.py` 增加 `#stage-wrap[hidden], #watch-stage-wrap[hidden] { display: none !important; }` 并在 `verify_watch_demos.mjs` 中强制校验 `offsetParent === null`。
2. **表盘小表盘与角落组件配色细节（`watch-gallery-*.png`）**：右下角 `.rcw-subdial .bat-s` 原先统一硬编码绿色 `#2DC653`，已在 `watch_styles.css` 与 `watch_engine.js` 为 `dir1..dir5` 补齐主题专属电量环与字体色（`#A3B86C` / `#60A5FA` / `#D9C7AE` / `#F5A623` / `#6CD4B9`），并在 `.rcw-comp-corner` 内加入随主题变化（圆弧 / 矩形角标）的 SVG 进度描边。
3. **Chronos 左侧分时标尺与 6 卡缩略容器边距**：将 `.rcw-chrono-rail` 微调至 `left: 8px; top: 42px; bottom: 48px;` 避开圆角斜边，并微调 `.rcw-mini-stage` 为 `scale(0.75)` 与 `margin-bottom: -75px` 使 6 卡底部更均衡；测试微服务器补充 `/favicon.ico -> 204` 消除 404 控制台噪点。

### `watch-round-2` 复检结果（Playwright 与视觉实图均通过）
- **`verify_watch_demos.mjs watch-round-2`（退出码 `0`）**：
  - `pageErrors = []`、`consoleErrors = []`、`brokenImgs = 0`、`relImgs = 0`、`dotsCount = 0`、`hasBanned = false`、`hasBattPct = false`、`oledOverflows = 0`。
  - 交互校验全部为 `true`：`liveClockTicked`、`doubleKnockMarked`、`aodToggled`、`slideToStopWorked`、`queueOpenedAndFlushed`、`complicationToggled`。
  - 6 套风格表盘 OLED 溢出均为 `0`（`dir1..dir5: 0`）；`dir-1..5.html?mode=watch` 下 `stage-wrap` 均完全隐藏且三表渲染完整（`dir-1..dir-5: true`）。
- **视觉实图复查**：已查阅 `polish/watch-round-2/` 下 `dir-2-watch.png`、`dir-5-watch.png`、`watch-gallery-default.png`、`watch-gallery-dir1.png`、`watch-gallery-grid.png` 与 `watch-proto-dual.png`，确认切换手表模式后画面居中干爽、各风格硬件特征（Braun 12 格 LED、Chronos 左标尺、Folio 暖纸、Nocturne 声谱、Air 顶部流光）清晰可辨、无裁切溢出。
- **手机端与默认原版手表静态回归校验**：
  - `verify_demos.mjs v2-round-1`：6 份手机展示页全部零回归（`pageErrors = []`、`consoleErrors = []`、`clipped = 0`、`overlaps = 0`、`dotsCount = 0`，全部交互通过）。
  - `WATCH_PROTO_STATIC_ONLY=1 node watch/prototype/verify.mjs`：50/51 静态项通过，唯一失败项为基线既有的 `Phone current.html has NC confirm pill (nc-btn) with health item`（`prototype/current.html` 本次未改动）。



