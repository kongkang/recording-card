# Handoff 开发计划 · 设计稿当前版对齐 + 下拉即时切片转写 + 连续空转写切片合并（2026-11-14）

> **交接对象**：新对话接手的开发 Agent / 工程师
> **生成时间**：2026-11-14 18:38 +08:00
> **目标**：将工作区最新更新的「当前版本设计稿（`prototype/current.html` & `prototype/verify.cjs`）」完整同步落地到 Flutter `app/`，并一次性实现 owner 新增的两项核心交互体验升级：**① Timeline 下拉刷新立即截断同步当前语音并本地转写最新内容**、**② 多个连续无转写内容的切片自动合并为一条展示（完整保留底层原始录音）**。

---

## 0. 新对话一键启动指令（可直接复制到新对话首轮）

```text
请先完整阅读以下文件恢复全部上下文，然后按计划在分支 `feat/photo-album-and-inline-summary`（或新建开发分支）逐阶段完成开发、测试、真机验证与 PR 合并：
1. `AGENTS.md`（重点看「设计稿双版本与发版快照开发规范」与「真实性红线」）
2. `docs/handoff/handoff-2026-11-14-app-sync-refresh-merge-plan.md`（本次完整对齐审计、6 大模块实施方案、文件级改动清单与测试用例）
3. 执行前先跑 `git status -sb`、`git log -n 5 --oneline` 与 `git diff --stat` 检查当前工作区进度：分支 `feat/photo-album-and-inline-summary` 上可能已包含 `prototype/` 设计稿改动或部分相册/总结同步代码（如 `record.dart` / `app_store.dart`），请在此基础上增量衔接开发，切勿盲目 `git checkout --` 覆盖已有进度。
```

---

## 1. 当前工程与分支基线快照（防止上下文丢失）

### 1.1 Git 与仓库现场
- **`master` / `origin/master` 最新提交**：`451897b`（`Merge pull request #55 from kongkang/fix/live-activity-layout-overflow`，当前 0 个 Open PR）。
- **当前检出分支**：`feat/photo-album-and-inline-summary`（基于 `451897b` 切出）。
- **工作区未提交改动（必须保留并一并纳入本次 PR）**：
  - `prototype/current.html`、`prototype/index.html`、`prototype/verify.cjs` 及 `prototype/screenshots/*.png` 已完成本轮「当前版本」相册与图文穿插总结设计升级，**Flutter `app/` 尚未同步实现**。
- **今日已合并进 `master` 的前置基线（无需重做）**：
  - `PR #48` / `#49`（`5d5843d` / `dd08fe9`）：四通道首页登录页（外脑 OVS + 微信 `wx6c2b7fb83b2833d2` + Apple + Google，审核通过前按钮保持展示但 `disabled`）及 `docs/AUTH-LOGIN.md`。
  - `PR #50` / `#52` / `#54`（`41ac34e` / `7f228fc` / `9125267`）：确立 `prototype/current.html`（当前版，零 `TBC`）+ `prototype/index.html`（目标版 `⊇ current.html`）+ `prototype/releases/vX.Y.Z.html` 双版本单服务规范。
  - `PR #51`（`f9327d7`）：修复 iOS 26+ `ModelManagerController` 在 Apple Background Assets 未配置时不回落外脑 CDN（`https://dl.wainao.chat/reai/models`）的问题，真机已验证三款本地模型（`sensevoice-small-int8` / `silero-vad` / `campplus-embedding`）全部下载校验通过。
  - `PR #53` / `#55`（`9f9b5fa` / `451897b`，版本号 `1.0.0+2026111404`）：自研等宽 7 段液晶数字字体 `app/ios/Shared/Fonts/RCLcdDigital-Regular.ttf`，修复 WidgetKit `TimeDataSource<Duration>` 无限水平撑开与扩展进程自定义字体注册问题（灵动岛紧凑态 `<60m` `MM:SS` / `≥60m` `HH:MM` + 闪烁冒号，展开态与锁屏 `HH:MM:SS` 固定宽度右对齐，owner 已在真机验收通过）。

### 1.2 构建、测试与真机环境（硬约束）
- **Flutter 工具链**：统一使用仓库内置 `/Users/kongkang/Developer/recording-card/.work/tools/flutter-3.47.9/bin/flutter`；**严禁设置 `PUB_HOSTED_URL` 镜像环境变量**。
- **测试基线**：
  - 原型校验：`node prototype/verify.cjs`（同时校验 `index.html` 与 `current.html`）。
  - Flutter 静态检查与单测：`cd app && /Users/kongkang/Developer/recording-card/.work/tools/flutter-3.47.9/bin/flutter analyze && /Users/kongkang/Developer/recording-card/.work/tools/flutter-3.47.9/bin/flutter test`（当前 `347/347` 全绿）。
- **物理真机**：`KK's 📱16pro`（UDID `00008140-000C4CE23862201C`，当前已装 `1.0.0+2026111404`；开发安装新包时递增 `app/pubspec.yaml` build 号如 `+2026111405`）。
- **核心架构红线（见 `AGENTS.md`）**：
  - **本地转写优先**（Silero VAD + SenseVoice + CAM++），音频切片与声纹特征仅留本机，绝不上传音频到云端，模型缺失或转写无内容时如实呈现、不编造文本。
  - **清洗内容优先展示，原始数据完整保留（低权重）**：合并空转写切片只能在视图投影层/聚合层完成，绝不可删除或破坏底层 `.WAV` 切片文件。
  - **测试锚点语义对齐**：Flutter 侧组件 `Key('<testid>')` 必须与 `prototype/verify.cjs` 的 `data-testid` 一一对应。

---

## 2. 设计稿 vs Flutter `app/` 进度对齐全景审计

对照工作区最新的 `prototype/current.html` / `prototype/verify.cjs` 与 `app/` 代码（`451897b`），当前差异精确拆分为 **4 项设计稿待同步项（M1～M4）** + **2 项 owner 新增核心交互需求（M5～M6）** + **1 项原型双版本收口清理（M7）**：

| 编号 | 模块 | `prototype/current.html` 最新状态 | `app/` 当前状态（`451897b`） | 本次动作 |
| :--- | :--- | :--- | :--- | :--- |
| **M1** | **Timeline 总结卡图片计数位置** | 右侧仅保留 `›`；`含 N 张图片`（`sumpics-<id>`）并入左下 `.when` 行：`14:40 · 已选 1 片段 · 含 2 张图片` | `app/lib/pages/timeline_page.dart:930-946` 仍把 `sumpics-<id>` 放在右侧箭头正下方 | **同步修改 `app/`** |
| **M2** | **未归类图片卡片 + 双列正方形相册详情子页 (`#p-unc`) + 「不归类」忽略** | 卡片底部新增提示 + 右下角 `不归类`（`unc-dismiss-day-<off>`）；点击卡片进子路由 `unc`（`#p-unc`），双列 1:1 正方形网格（`unc-album-grid`），支持按时间最近一键 `归入·<记录>`、`▾` 选其他记录、单张/全部 `不归类`（`dismissed=true`），清零自动返回 | `timeline_page.dart:991` `_UnclassifiedPhotosCardView` 为静态不可点容器；`EventPhoto` 无 `dismissed` 字段；无 `unc` 子页面与路由 | **同步开发 `app/`** |
| **M3** | **记录详情页：紧凑照片卡 + 无套框被引用总结** | 对话流 `.dphoto` 改为左侧方形缩略图（点开大图弹层）+ 右侧信息与紧凑短按钮 `不属于本段`（宽度 40~100px 不拉伸）；`det-tab-refs` 列表外层无边框，单卡带 `›` 与 `含 N 张图片` | `detail_page.dart:499-579` 为 156px 全宽大图竖卡；`refs` 项无右箭头与图片计数；无照片大图与原话对照弹层 | **同步开发 `app/`** |
| **M4** | **总结结果页：正文自然穿插配图（无独立多媒体框）** | ① `sum-sub` 末尾追加 `· 含 N 张图片`；② 概览正文下自然穿插单张代表图（`sum-ov-inline-photo`）；③ 逻辑结构带图叶子显示线性图片图标（`mleaf-pic-<eid>-<pi>`，排除照片后自动退化为纯文字胶囊）；④ 信息点标题右侧显示线性图片图标（`pt-picico-<i>`），展开体内联配图（`pt-figs-<i>` / `sum-pt-photo-<eid>-<i>`）；⑤ 来源记录左下追加 `含 N 张图片`（`src-piccount-<id>`） | `summary_result_page.dart` 完全未接入图片关联展示（无 `sum-ov-inline-photo`、`mleaf-pic-*`、`pt-picico-*`、`pt-figs-*`、`src-piccount-*`） | **同步开发 `app/`** |
| **M5** | **【新增细节 1】Timeline 下拉刷新：立即同步当前语音并转写最新内容** | 无下拉刷新交互提示 | **痛点**：录音进行中下拉刷新时，`app_store.dart:364` 直接拦截返回并弹 SnackBar `'正在录音中，每满 1 分钟自动转写保存'`，缓冲区未满 60 秒的语音完全不切片不转写！未连卡时下拉也直接报错，不续跑本地待转写文件 | **新增核心实现（`app/` + 原型说明同步）** |
| **M6** | **【新增细节 2】多个连续无转写内容切片自动合并成一条** | 静态示例数据无空切片 | **痛点**：每 1 分钟产生一个独立 `LIVE_*` `RecordingFile`，静音 10 分钟会在 Timeline 刷出 10 张独立的 `实时切片 #N（未识别到人声）` 卡片 | **新增核心实现（`app/` + 原型同步）** |
| **M7** | **双版本原型细节卫生检查** | `current.html` 第 622/624 行残留未渲染但死代码的 `tbc-dream` / `daily` 分支；`#dyn-island` 尚未体现 `1.0.0+2026111404` 落地的右对齐 LCD 计时样式 | 灵动岛已是右对齐 7 段 LCD 数字；`TBC` 特性（睡前日记/做梦漫画/记忆图谱/长按物理键 A-B 推送）明确归属 `index.html` | **顺手对齐 `prototype/` 并保持 `verify.cjs` 全绿** |

> **明确不在本次开发范围的 `index.html` 目标版 `TBC` 特性**（未经 owner 晋升确认不得擅自开发进 `app/`）：
> 睡前日记与轻标注、夜间 `>5h` 做梦漫画与 Skill 提炼、声纹上下文呼语称呼推断与人物卡片、三元记忆图谱、长按物理键唤起灵动岛 Agent 与 A/B 双阶段推送。

---

## 3. 核心需求详细技术方案

### 3.1 【M5 · 重点】下拉刷新：立即同步当前语音，并转写最新内容

#### 现状根因定位
1. `app/lib/pages/timeline_page.dart:67-84`：`RefreshIndicator.onRefresh` 调用 `store.syncRecordings()`。
2. `app/lib/core/store/app_store.dart:357-370`：当 `_isActivelyRecording == true`（无论是蓝牙硬件实时流录音 `LiveAudioRecorder`，还是手机麦克风独立录音 `PhoneMicRecorder`），`syncRecordings()` **直接提前返回** `'录音进行中，实时切片正自动入库'`，`timeline_page.dart:76-82` 弹出拒绝提示 `'正在录音中，每满 1 分钟自动转写保存'`。用户刚说完一段话想立刻下拉看转写文字时，被迫干等满 60 秒！
3. 当 `_isActivelyRecording == false` 且未连蓝牙录音卡（`_deviceReady == false`）时，`app_store.dart:371-375` 直接返回 `'未连接录音卡，连上后可下拉取回'`，哪怕本地磁盘已经有待转写/重试的录音文件（例如刚下载完本地语音模型），也不会触发本地重跑。

#### 目标交互与状态流转
用户无论处于以下哪种状态，在 Timeline（`全部` 或 `记录` Tab）手势下拉刷新时，都必须**立即执行有价值的同步与本地转写，并在转写落库刷新 UI 后再结束下拉转圈**：

1. **场景 A：正在录音中（硬件实时流 `hwRecording` 或本机麦克风 `phoneRecording`）**
   - **不断录即时切分（Immediate Non-Stopping Flush）**：
     - 保持底层蓝牙音频流 / 麦克风采集流不断开，总录音计时器（胶囊、灵动岛 Live Activity、顶部 `RecordingStatusBlock`）**连续不断、不归零**。
     - 若当前内存 PCM 缓冲区已累积有效音频 **≥ `0.5 秒`（`16000 Hz × 2 Bytes × 0.5s = 16,000 Bytes`）**：立即将当前已录缓冲封口写入 `LIVE_<session>_<seq>.WAV`（`isFinal: false`），同时将下一片的起点采样游标无缝推进到当前末尾（**零丢帧、零重叠、60 秒自动切片计时从本次手动截断时刻重新起算**）。
     - 若当前缓冲区不足 `0.5 秒`（例如刚切完片不到半秒内连续二次下拉）：不生成空碎切片，但依然等待正在排队中的 `_liveIngestTail` 转写任务跑完。
   - **立即触发本地转写并等待结果上屏**：
     - 封口产生的 `LiveAudioSlice` 经原有流式监听送入 `store.ingestLiveSlice(slice)`（Silero VAD → SenseVoice INT8 → CAM++ 声纹聚类 → 写入 `RecordingStore` → `refreshFromStore()` → 最近相册照片自动对齐）。
     - `store.syncRecordings()` 内部 `await _liveIngestTail`，确保 `RefreshIndicator` 在新切片转写完成并插入「今天」顶部第一条后再收起加载指示器！
     - 顶部状态块在转写期间平滑显示 `'正在同步当前语音并转写…'`，完成后自动恢复 `'正在录音'` / `'正在本机录音'`。
     - **彻底移除** `timeline_page.dart` 中旧的 `'正在录音中，每满 1 分钟自动转写保存'` 拦截提示；若缓冲 `<0.5s` 且无排队切片，轻提示 `'当前语音刚同步，继续说话后可随时下拉转写'`。

2. **场景 B：未在录音 + 已连接蓝牙硬件（`_deviceReady == true`）**
   - 先等待可能残留的 `_liveIngestTail` 收尾；
   - 立即执行 `_syncWithPipeline(pipeline)`：拉取卡内尚未同步的离线 `.APM` 文件（自动跳过已被实时流无断档覆盖的文件），并在本地完成切片、VAD、SenseVoice 转写与说话人推测；同时把本地处于非 `ready` 态的历史未完成条目一并续跑转写，对齐系统相册与点一机硬件照片。

3. **场景 C：未在录音 + 未连接蓝牙硬件（`_deviceReady == false`）**
   - 先检查本地 `RecordingStore` 是否存在待转写/重检的录音文件（例如此前模型未就绪排队的录音，或可重检的本地切片）：若有，立即在本地跑完转写并刷新 Timeline；若本地全部已转写完毕，再如实提示 `'本地语音已是最新；连接录音卡后下拉可同步卡内录音'`。

#### 具体代码改动设计（M5）
1. **`app/lib/services/audio/live_audio_recorder.dart`**：
   - 新增常量 `static const int minManualFlushBytes = sampleRate * bytesPerSample ~/ 2; // 0.5s = 16000 bytes`。
   - 新增公开方法 `Future<bool> flushActiveSlice()`：
     ```dart
     /// 手动下拉刷新时立即截断当前已缓冲音频并送入本地转写，不停止蓝牙流。
     /// 返回 true 表示本次成功切出一片新音频；false 表示当前缓冲不足 0.5 秒无需切片。
     Future<bool> flushActiveSlice() async {
       if (!isRunning || _stopping) return false;
       if (_slicePcm.length < minManualFlushBytes) {
         await _sliceWriteChain;
         return false;
       }
       _sealCurrentSlice(isFinal: false);
       await _sliceWriteChain;
       return true;
     }
     ```
     *检查点*：确认 `_sealCurrentSlice(isFinal: false)` 已会递增 `_sliceIndex`、更新 `_sliceStartSample = _totalSamples`、清空 `_slicePcm = BytesBuilder(copy: false)` 并通过 `_sliceController.add(slice)` 推送给 `AppShell`（无需重复调用 `ingestLiveSlice`，避免双入库！）。
2. **`app/lib/services/audio/phone_mic_service.dart` & `app/lib/core/store/device_store.dart`**：
   - 在 `PhoneMicRecorder` 新增同语义方法 `Future<bool> flushActiveSlice()`：
     - 当 `_running && !_disposed && _buffer.length >= 16000` 时，`final chunk = _buffer.takeBytes(); _scheduleFlush(chunk, isFinal: false); await _writeChain; return true;`。
     - *关键检查*：核对 `_scheduleFlush` 中 `_sliceStartedAtMs` 的推进逻辑——此前每满 60s 切片时 `_sliceStartedAtMs += chunkDurationMs`，手动提前在比如 23.4s 切分时，必须用 `chunk` 实际字节时长 `(chunk.length ~/ 2) * 1000 ~/ 16000` 精确推进 `_sliceStartedAtMs`，确保下一片的时间戳严丝合缝、绝不产生时间跳跃或重叠！
   - 在 `DeviceStore` 暴露 `Future<bool> flushPhoneRecordingSlice()` 转发给 `_phoneMicRecorder.flushActiveSlice()`。
3. **`app/lib/pages/app_shell.dart` & `app/lib/core/store/app_store.dart`**：
   - `AppStore` 新增回调字段：`Future<bool> Function()? flushActiveRecordingSlice;`（由 `AppShell` 注入：若 `_liveRecorder.isRunning` 调 `_liveRecorder.flushActiveSlice()`；若 `_deviceStore.phoneRecording` 调 `_deviceStore.flushPhoneRecordingSlice()`）。
   - 重构 `AppStore.syncRecordings()`：
     - 若 `_isActivelyRecording`：调用 `final flushed = await (flushActiveRecordingSlice?.call() ?? Future.value(false));`，紧接着 `await (_liveIngestTail ?? Future.value());`，再触发一次 `unawaited(syncPhotosAutomatically(recentOnly: true))`，返回 `null`（成功）或当 `!flushed` 时返回轻提示标识。
     - 若 `!_isActivelyRecording && !_deviceReady`：新增 `pipeline.transcribeLocalPendingOnly(onProgress: _onPipelineProgress)`（只处理本地已有 `wavPath` / `apmPath` 且 `stage != RecordingStage.ready` 的文件，不调用蓝牙网关 `listFiles`），有进展则刷新返回 `null`。
4. **`app/lib/pages/timeline_page.dart`**：
   - 更新 `RefreshIndicator`（补充 `key: const Key('timeline-refresh')` 便于 widget 测试 `tester.fling` 验证）的 `onRefresh` 回调：录音中下拉不再弹拦截提示，仅在真实错误或无设备无待处理音频时给出简洁诚实的 SnackBar。

---

### 3.2 【M6 · 重点】多个切片如果都是没有转写内容，合并成一条就好

#### 现状根因定位
1. `app/lib/services/recordings/recording_pipeline.dart:482-496`：每当一个实时切片（默认 60s，或下拉刷新切出的子切片）经 Silero VAD / SenseVoice 推理后 `utterances.isEmpty`，`_buildLocalSliceSegment` 会生成一个独立的 `SegmentRecord`：
   - `title: '实时切片 #$seqNo（未识别到人声）'`
   - `brief: '已保存 $secs 秒本地流式音频，本段未检测到清晰语音。'`
2. `app/lib/services/recordings/segment_projection.dart:21-36`：`SegmentProjection.build(files)` 将每个 `RecordingFile` 的每个 `SegmentRecord` **1:1 映射为一条 `RecordEvent`**。如果用户开着录音放在桌上安静办公 15 分钟，Timeline 会连排出现 15 条几乎一模一样的「未识别到人声」卡片，严重淹没有效对话！

#### 核心架构原则：投影层无损合并（Non-Destructive Projection Merge）
- **绝不在磁盘层拼接或删除单片的 `.WAV` / `RecordingFile`**：
  1. 保持每个 `LIVE_<session>_<seq>.WAV` 独立不可变，崩溃安全、零磁盘重写开销，且完整保留 `coversCardFile` 蓝牙去重索引与 `.dc_rechecked_v1` 重检能力。
  2. 严格遵守 `AGENTS.md` **「清洗内容优先展示，原始数据完整保留（低权重）」**：时间轴上干净折叠成一条，点进详情页「原始数据」Tab 仍可看到并逐段播放合并组内的每一个原始切片！

#### 精确合并判定规则（Merge Predicate）
在 `SegmentProjection.build(List<RecordingFile> files)` 中，先将所有已完成/可展示的单元按起始时间排序，定义某个单元 `v` 为**「可合并空转写切片（Silent Completed Slice）」**当且仅当同时满足：
1. `v.file.stage == RecordingStage.ready`（已完成转写；正在转写中的 `live` 条目不提前吞并，转写完确认无语音后自动并入）；
2. `v.turns.isEmpty && v.utterances.isEmpty`（既无润色对话，也无本地原始识别字词）；
3. `v.segment.status != SegmentStatus.live`；
4. **物理打点保护**：若用户在某一片按了硬件物理键打重点（`(v.segment.mark ?? '').trim().isNotEmpty` 且不是单纯的 `'流中断 X 次'`，例如包含 `'重点'` / `'Mark'`），该片单独保留不吞没（若只是 `'流中断 X 次'` 则可合并并在合并卡累加提示）。

**连续合并条件**：
- 在**同一自然日（相同 `dayOffset`）**内，按时间顺序**相邻且中间没有任何包含有效转写文本的片段隔开**的多个「可合并空转写切片」（`count >= 2`），且相邻两片间隔不超过合理阈值（如同一 `sessionId`，或相邻间隔 `<= 10 分钟`——避免上午 9 点一段静音和晚上 22 点一段静音虽然中间没说话却跨全天合成长达 13 小时的假跨度；若中间无任何其他记录但间隔很大，按间隔 `<= 10 分钟` 或同 `session` 聚合成组最自然准确，起止跨度也不会虚标！）：
  - **推荐精确条件**：同 `dayOffset` + 排序相邻（中间无有声记录）+（同 `sessionId` **或** 前一片 `endAtMs` 与后一片 `startAtMs` 间隔 `<= 5 分钟`）。这样同一次连续录音里的 2~N 个连续静音切片 100% 合并成一条，而上午和下午各自独立开启的两段静音不会跨半天拼出误导性的 `09:00—18:00` 时间窗（同时避免误吸走中间时段的系统相册照片！）。

#### 合并后的数据结构与稳定性设计（极其关键）
1. **稳定主键（Anchor ID）策略**：
   - 合并后的 `RecordEvent.id` 固定取该连续静音组中**最早那一片（第 1 片）的 `segment.id`**（例如 `seg-LIVE_xxx_0001.WAV-0`）。
   - **为什么用最早一片做主键**：当实时录音持续静音时，第 1 分钟生成卡片 `id = seg-...0001-0`；第 2、3、4 分钟静音切片陆续落库时，合并卡的 `id` **保持不变**！这样：
     - 用户如果正展开或查看该卡片，不会因为 ID 跳变而闪退或收起；
     - `AppStore.eventPhotos[eventId]` 与路由栈 `RouteEntry('detail', id)` 保持稳定。
2. **扩展 `SegmentView`（`app/lib/core/models/segment_view.dart`）**：
   - 新增字段 `final List<SegmentView> mergedChildren;`（默认 `const []`；单条未合并时为空或仅自身，合并 `N >= 2` 条时按时间升序存放全部 `N` 个原始子 `SegmentView`）及便捷 getter `bool get isMergedSilent => mergedChildren.length > 1;`、`List<String> get allConstituentSegmentIds`。
   - 同时在 `SegmentProjectionResult` 新增 `final Map<String, String> mergedIdRedirect;`（将第 2..N 片的原始 `segId` 映射到锚点 `anchorId`）：
     - 在 `AppStore.photosForEvent(e)` 中，自动聚合 `anchorId` 及其所有 `mergedChildren` 原 `segId` 下挂载的照片，做到历史照片零丢失！
3. **合并卡片在 Timeline 的文案呈现（诚实、克制、信息清晰）**：
   - **单条无语音切片（`N == 1`）**：标题优化为 `'未识别到语音'`（或保留清晰简洁标题），时间行 `'14:02 · 1分0秒'`，展开态摘要 `'本段未检测到有效人声，原始录音已保存在本机，可在详情「原始数据」回听。'`。
   - **多条合并无语音切片（`N >= 2`）**：
     - `title`：`'未识别到语音（已合并 $N 段）'`
     - `time`：最早片起点 `'HH:mm'`（如 `'14:02'`）
     - `dur`：各片实际音频时长之和 `_formatDuration(sumDurationMs)`（如 `'5分0秒'`）
     - `srcMap`：`'来源 ${earliestHHmm}—${latestHHmm} · $N 个切片'`
     - `speakers`：`'无语音'`（展开态 meta 显示 `'未检测到人声'`）
     - `longText`：`'${earliestHHmm}—${latestHHmm} 连续 $N 个录音切片（共 ${_formatDuration(sumDurationMs)}）均未检测到有效人声，已自动折叠合并；全部原始音频均完整保留，可在详情「原始数据」逐片回听或清理。'`
4. **详情页（`app/lib/pages/detail_page.dart`）对合并切片的兼容**：
   - **「对话详情」Tab**：若 `lines.isEmpty`（无转写文本），展示清爽空态说明 `'本时段连续 $N 个切片未检测到有效人声，可在「原始数据」回听各切片原始录音'`（若该时段拍了照片，照片依然正常按时间戳展示在下方并支持标记「不属于本段」！）。
   - **「原始数据」Tab**：当 `view.isMergedSilent` 为 `true` 时，在吸顶播放器下方列出全部 `N` 个原始切片胶囊/行（如 `切片 1 · 14:02:00 (01:00)`、`切片 2 · 14:03:00 (01:00)`…，`Key('raw-merged-slice-$i')`），点击任一切片即可切换顶部 `RawAudioPlayer` 播放对应 `child.file.wavPath`！清理按钮支持清理当前选中或全部合并组原始音频。

---

## 4. 设计稿当前版（M1～M4 & M7）同步落地实施细则

严格对照 `prototype/current.html` 与 `prototype/verify.cjs` 的 DOM 结构和 `data-testid` 逐项还原：

### 4.1 M1 · Timeline 总结卡左下角图片数（`app/lib/pages/timeline_page.dart`）
- 修改 `_SummaryCardView.build`（约第 915~955 行）：
  - 右侧仅保留 `const Icon(Icons.chevron_right, size: 18, color: RCColors.sec)`，移除右侧 `Column` 下的 `sumpics-${card.id}`。
  - 左下统计行（`when`）在 `card.state == SummaryState.done` 时改为 `Text.rich` / `Row`：
    - 基础文案：`'${card.time} · 已选 ${card.srcIds.length} 片段'`
    - 当 `photoCount > 0` 时紧跟 `' · '` + 带 `Key('sumpics-${card.id}')` 的 `'含 $photoCount 张图片'`（颜色与原型 `.sumphotos` 一致）。

### 4.2 M2 · 未归类图片卡片升级 + 双列正方形相册详情页（`#p-unc`）
1. **模型与持久化（`app/lib/core/models/record.dart` & `app/lib/core/store/app_store.dart`）**：
   - `EventPhoto` 增加 `final bool dismissed;`（默认 `false`）：
     - `copyWith({bool? excluded, bool? dismissed})`
     - `toJson()` 增加 `if (dismissed) 'dm': true`；`fromJson` 读取 `dismissed: j['dm'] == true`。
   - `AppStore` 新增未归类图片管理方法：
     - `List<({String eventId, String eventTitle, int photoIndex, EventPhoto photo})> unclassifiedPhotosForDay(int dayOffset)`：筛选当日 `p.excluded && !p.dismissed` 的照片条目。
     - `void reassignUnclassifiedPhoto({required String fromEventId, required String photoId, required String toEventId})`：若 `fromEventId == toEventId`，将 `excluded: false, dismissed: false` 恢复回原记录；若归入同日另一条记录，从 `fromEventId` 移除并以 `excluded: false, dismissed: false` 插入 `toEventId`（按时间排序），持久化并 `notifyListeners()`；若当日未归类剩余 0 张且当前 `stackTop?.type == 'unc'`，自动调用 `goBack()`。
     - `void dismissUnclassifiedPhoto(String eventId, String photoId)`：将该张照片标记 `dismissed: true`；剩余 0 张且在 `unc` 页时自动 `goBack()`。
     - `void dismissUnclassifiedDay(int dayOffset)`：将该日所有 `excluded && !dismissed` 照片批量标记 `dismissed: true`；若在 `unc` 页则自动 `goBack()`。
     - `List<RecordEvent> candidateEventsForPhoto(int dayOffset, EventPhoto photo)`：返回当日所有非 `live` 的 `RecordEvent`，按与照片拍摄时刻的时间距离 `distToEvent` 升序排列（第 0 项即「时间最接近」推荐项）。
   - 路由栈接入 `unc`：
     - `AppStore.pageLabels` 增加 `'unc': '未归类图片'`。
     - 新增 `void openUncPage(int dayOffset, {bool fresh = true}) { if (selMode) return; navSub(RouteEntry('unc', '$dayOffset'), fresh: fresh); }` 及 `bool get showPaneBackUnc => subStack.length > 1 && stackTop?.type == 'unc';`。
2. **Timeline 未归类卡片重构（`app/lib/pages/timeline_page.dart` `_UnclassifiedPhotosCardView`）**：
   - 外层 `InkWell` / `GestureDetector`（`Key('card-unc-${card.dayOffset}')`），点击触发 `store.openUncPage(card.dayOffset, fresh: true)`。
   - 顶部行：左侧标题 `今日未归类图片` / `${card.dayLabelText}未归类图片` + 副标题 `已从对话流移出 · 共 ${card.photos.length} 张`，右侧 `PhotoThumbStack(key: Key('unc-pics-${card.dayOffset}'), ...)` + `›` 箭头。
   - 底部分割栏：左侧浅色提示 `点击查看双列相册或归类`，右侧紧凑按钮 `不归类`（`Key('unc-dismiss-day-${card.dayOffset}')`，点击调用 `store.dismissUnclassifiedDay(card.dayOffset)` 并阻止冒泡打开详情页）。
3. **新建子页 `app/lib/pages/unclassified_photos_page.dart` 并在 `app/lib/pages/app_shell.dart` 挂载**：
   - 根容器 `Key('p-unc')`，宽屏嵌套时左上展示 `Key('pb-unc')` 返回按钮，页头展示标题、副标题 `共 N 张 · 点击图片预览，可归入当日记录或标记不归类` 及右上按钮 `全部不归类`（`Key('unc-dismiss-all')`）。
   - 主体采用 `GridView.builder`（`Key('unc-album-grid')`，`crossAxisCount: 2`，`crossAxisSpacing: 12`，`mainAxisSpacing: 12`）：
     - 每个网格单元 `Key('unc-item-${item.eventId}-${item.photoIndex}')`：
       - 顶部 **1:1 正方形图片区**（`AspectRatio(aspectRatio: 1)`，`Key('unc-photo-${item.eventId}-${item.photoIndex}')`），右下角叠放半透明拍摄时间角标 `p.time`，点击弹出照片预览弹层 `showPhotoPreviewSheet(...)`。
       - 下方说明与操作栏：
         - 若当日有候选记录（`best = candidates.first`）：主按钮 `归入·${best.title}`（`Key('unc-reassign-${item.eventId}-${item.photoIndex}-${best.id}')`）；当 `candidates.length > 1` 时右侧紧邻 `▾` 按钮（`Key('unc-pick-${item.eventId}-${item.photoIndex}')`），点击弹出底部候选记录选择抽屉（第一项带 `时间最接近` 标签）。
         - 次按钮 `不归类`（`Key('unc-dismiss-${item.eventId}-${item.photoIndex}')`）。

### 4.3 M3 · 记录详情页精修与现场照片预览弹层（`app/lib/pages/detail_page.dart` + `app/lib/widgets/photo_preview_sheet.dart`）
1. **抽离通用组件 `app/lib/widgets/photo_preview_sheet.dart`（对应原型 `#photo-wrap`）**：
   - 展示照片标题 `照片 · ${photo.time}`、所属记录副标题、大图预览（真实本地文件 `Image.file` 或安全占位图）、关联时刻邻近原话摘录（若有），底部提供 `关闭` 与 `定位到原始对话流 ›`（`Key('pm-jump-dlg')`，在总结页或未归类页点开时一键 `store.openDetail(eventId)` 跳回对应对话流）。
2. **`detail_page.dart` 对话流照片卡片 `_inlinePhotoCard` 改为横向紧凑布局**：
   - 左侧 `68×68`（或 `72×72`）圆角正方形缩略图按钮（点击调起 `showPhotoPreviewSheet`）；
   - 右侧 `Expanded` 纵向排列：`照片 · ${p.time}`、来源说明（`系统相册` / `点一机抓拍`），以及左对齐紧凑短按钮 `不属于本段`（`Key('dphoto-exclude-${e.id}-$index')`，使用 `Align(alignment: Alignment.centerLeft, child: OutlinedButton/TextButton(...))`，严禁撑满整行，实测宽度保持在 `64~92px` 区间，对齐 `verify.cjs` `40 < width < 100` 断言）。
3. **`detail_page.dart`「被引用总结」Tab（`det-tab-refs`）**：
   - 确认外层无多余边框套框；每张引用总结卡片（`Key('ref-${r.id}')`）首行左标题 + 右 `›` 箭头，次行展示 `'${r.time} · 已选 ${r.srcIds.length} 片段${picCount > 0 ? ' · 含 $picCount 张图片' : ''}'`。

### 4.4 M4 · 总结结果页图文自然穿插（`app/lib/pages/summary_result_page.dart` & `app/lib/core/models/summary.dart`）
1. **模型向后兼容扩展（`app/lib/core/models/summary.dart`）**：
   - 支持逻辑结构叶子节点可选关联来源记录照片（既兼容现有 `List<String> leaves` JSON，也支持通过时间窗自动把 `card.srcIds` 中的有效照片关联到对应 `InfoPoint` 与 `MapBranch` 叶子上）：
     - 新增辅助方法（放在 `AppStore` 或独立 helper `summary_photo_matcher.dart`）：
       - `List<SummaryPhotoRef> activePhotosForSummary(SummaryCard card)`：汇总 `card.srcIds` 下所有 `!excluded` 的 `EventPhoto`（含 `eventId`、`photoIndex`、`photo`、`eventTitle`、匹配的 `pointIndex`）。
       - `List<SummaryPhotoRef> photosForInfoPoint(SummaryCard card, int pointIndex)`：解析 `InfoPoint.sources` 中的 `SourceRef(eventId, label, range)` 时间段（如 `"13:06—13:10"`），匹配落在该时间窗（含 ±1 分钟容差）内且 `!excluded` 的照片；若某条单段切片总结未写细分时间窗但该来源记录本身只有这一段且含图，按事件时间窗自然归属。
       - 逻辑结构叶子匹配：若 `MapLeaf` 显式携带 `(eventId, photoIndex)` 或叶子关键词与某带图 `InfoPoint` 同源，且对应照片当前 `!excluded`，则标记为可点击带图叶子。
2. **`summary_result_page.dart` 五处 UI 对齐**：
   - **统计副标题（`Key('sum-sub')`）**：当 `allPics.isNotEmpty` 且原 `subDesc` 未含 `'张图片'` 时，动态展示 `'${card.subDesc} · 含 ${allPics.length} 张图片'`（若用户在详情页排除了照片，返回总结页时计数实时同步减少！）。
   - **概览（`sec-ov`）**：不设独立多媒体模块框；当 `allPics.isNotEmpty` 时，在概览段落正下方自然穿插首张代表图卡片（`Key('sum-ov-inline-photo')`），展示图片 + 底栏 `'${lead.photo.time} · ${lead.eventTitle}'` + `'查看原话 ›'`，点击打开 `PhotoPreviewSheet`。
   - **逻辑结构（`sec-map`）**：关联了有效未排除照片的叶子渲染为带线性图片小图标 `Icons.image_outlined`（14px）的可点胶囊（`Key('mleaf-pic-${ref.eventId}-${ref.photoIndex}')`），点击后若当前在 `all` Tab 且匹配到 `pointIdx >= 0` 则自动展开该信息点并平滑滚动居中，否则打开 `PhotoPreviewSheet`；一旦对应照片被排除，自动退化为普通纯文字胶囊。
   - **信息点（`sec-pt`）**：
     - 标题行右侧：若 `pointPhotos.isNotEmpty`，在折叠箭头 `▾` 左侧展示线性图片图标（`Key('pt-picico-$i')`）；无图信息点绝不渲染该图标。
     - 展开内容区：在详情文字下方、溯源胶囊上方渲染内联配图列表（外层 `Key('pt-figs-$i')`，单张 `Key('sum-pt-photo-${p.eventId}-${p.photoIndex}')`），点击打开 `PhotoPreviewSheet`（可一键跳回原始对话流）。
   - **来源记录（`sec-src`）**：每张来源卡片（`Key('src-$id')`）首行左标题 + 右 `›`，次行 `'${_dayLabel(e.dayOffset)} ${e.time} · ${e.dur}'`，当该记录有效照片数 `pc > 0` 时追加 `' · '` + `Key('src-piccount-$id')` 的 `'含 $pc 张图片'`。

### 4.5 M7 · 双版本原型（`prototype/current.html` & `prototype/index.html`）小幅对齐检查
- 检查 `prototype/current.html`：确保零 `.tbc-badge` 渲染，并根据需要补充「连续空转写切片自动合并 / 下拉刷新即时截断转写」的交互说明或状态演示，同步到 `prototype/index.html`（保证 `index.html ⊇ current.html`），运行 `node prototype/verify.cjs` 确保全部断言与 `current.html` 校验 100% 通过。

---

## 5. 分阶段执行顺序与文件级清单

建议在新对话中按以下 **4 个清晰阶段（单分支多 commit，最终合并 1 个干净 PR）** 推进：

### Stage 1：底层核心能力 —— 下拉即时切分转写（M5）+ 连续静音切片合并（M6）
- 修改文件：
  - `app/lib/services/audio/live_audio_recorder.dart`（新增 `flushActiveSlice()`）
  - `app/lib/services/audio/phone_mic_service.dart`（新增 `flushActiveSlice()` 并精确对齐 `_sliceStartedAtMs`）
  - `app/lib/core/store/device_store.dart`（暴露 `flushPhoneRecordingSlice()`）
  - `app/lib/services/recordings/recording_pipeline.dart`（新增纯本地待处理续跑入口，优化单条空切片文案）
  - `app/lib/core/models/segment_view.dart`（新增 `mergedChildren` / `isMergedSilent`）
  - `app/lib/services/recordings/segment_projection.dart`（实现连续空转写切片无损聚合与稳定锚点 ID）
  - `app/lib/core/store/app_store.dart`（接入 `flushActiveRecordingSlice`、重构 `syncRecordings()`、照片跨合并子片聚合）
  - `app/lib/pages/app_shell.dart`（绑定 `flushActiveRecordingSlice` 回调）
- 新增单测：
  - `app/test/services/pull_to_refresh_live_flush_test.dart`
  - `app/test/services/silent_slice_merge_test.dart`

### Stage 2：未归类双列正方形相册页与详情页精修（M1 + M2 + M3）
- 修改 / 新增文件：
  - `app/lib/core/models/record.dart`（`EventPhoto.dismissed` 序列化兼容）
  - `app/lib/widgets/photo_preview_sheet.dart`（新建现场照片预览与原话跳转弹层）
  - `app/lib/pages/unclassified_photos_page.dart`（新建 `#p-unc` 双列 1:1 正方形相册页 + 候选记录抽屉）
  - `app/lib/pages/timeline_page.dart`（总结卡左下图片数 `sumpics-*`、未归类卡右下 `不归类` `unc-dismiss-day-*` 与点击进 `unc` 页、下拉刷新体验收口）
  - `app/lib/pages/detail_page.dart`（紧凑横向照片卡、`不属于本段` 短按钮、被引用总结无外框 + 图片数、合并静音切片的 `原始数据` 多切片回放切换）
  - `app/lib/pages/app_shell.dart`（挂载 `RouteEntry('unc', ...)` 双栏/单栏自适应渲染）
- 新增 / 更新 Widget 测试：
  - `app/test/unclassified_photos_page_test.dart`
  - 更新现有 Timeline / Detail 照片相关测试对齐新 `Key` 位置

### Stage 3：总结结果页正文自然穿插配图（M4）+ 原型同步校验（M7）
- 修改文件：
  - `app/lib/core/models/summary.dart`（可选图片引用扩展，100% 兼容旧缓存 JSON）
  - `app/lib/pages/summary_result_page.dart`（`sum-sub` 图片数、`sum-ov-inline-photo`、`mleaf-pic-*`、`pt-picico-*`、`pt-figs-*`、`src-piccount-*`）
  - `prototype/current.html`、`prototype/index.html`、`prototype/verify.cjs`（确认工作区设计更新与最新交互说明一致）
- 新增 Widget 测试：
  - `app/test/summary_inline_photos_test.dart`

### Stage 4：全量验收、真机安装与 PR 合并
1. 运行原型双版本自动化验收：
   ```bash
   node prototype/verify.cjs
   ```
2. 运行 Flutter 全量静态分析与单元/组件测试：
   ```bash
   cd app && /Users/kongkang/Developer/recording-card/.work/tools/flutter-3.47.9/bin/flutter analyze && /Users/kongkang/Developer/recording-card/.work/tools/flutter-3.47.9/bin/flutter test
   ```
3. 递增 `app/pubspec.yaml` build 号（如 `1.0.0+2026111405`），构建 Release/Debug 安装到 `KK's 📱16pro`（`00008140-000C4CE23862201C`）实测：
   - 开启录音说话 15 秒 → Timeline 下拉刷新 → 验证不断录立即切出第 1 片并转写出文字；
   - 保持安静连续切出 2~3 片无语音切片 → 验证 Timeline 自动合并为 1 条「未识别到语音（已合并 N 段）」，且点进「原始数据」仍能看到全部原始切片；
   - 验证照片标记「不属于本段」→ Timeline「今日未归类图片」点进双列正方形相册归类 / 不归类 → 总结结果页概览、逻辑图标、信息点与来源记录配图联动。
4. 提交分支 `feat/photo-album-and-inline-summary` → 推送创建 PR → 检查全绿后合并进 `master`。

---

## 6. 必测边界条件清单（Acceptance Checklist）

- [ ] **录音中快速连拉两次刷新**：第 1 次切走缓冲并转写；0.2 秒内第 2 次下拉因缓冲 `< 0.5s` 不产生 0 秒空文件，也不报错崩溃。
- [ ] **下拉截断后的时间轴连续性**：手动在第 22 秒下拉切片后，下一片自动 60 秒切片的 `startAtMs` 精确从 `+22,000ms` 起算，详情页句级时间戳与照片时间窗对齐无偏移。
- [ ] **静音合并遇上中间插话**：`[静音1, 静音2, 说话3, 静音4, 静音5]` 必须投影为 **3 条记录**：`[合并静音(4~5), 说话3, 合并静音(1~2)]`（倒序展示），绝不能跨过中间有声片段把前后两段静音错合在一起。
- [ ] **静音合并稳定性**：实时录音连续产生第 2、3 片静音时，合并卡锚点 `id` 不变，已挂载在任一子切片上的系统相册照片完整显示在合并卡上。
- [ ] **照片排除全局联动**：在详情页点击某张照片「不属于本段」后，外侧记录缩略图减少、总结卡左下 `含 N 张图片` 减少、总结结果页对应逻辑节点图标退化为纯文字、未归类双列相册增加 1 张；点击「不归类」后未归类卡片清零收起且刷新不反弹。
