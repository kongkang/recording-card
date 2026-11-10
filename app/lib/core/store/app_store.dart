/// 应用核心状态机 —— 时间轴数据、勾选式总结、生成进度、路由栈、会话持久化。
///
/// 与原型（prototype/index.html）保持一致的交互语义：卡片两行折叠、勾选模式锁 Tab、
/// 走"记录 → 勾选 → 生成 → 结果页"的主线，路由栈扁平化。
///
/// 与原型**不同**的地方（正式版）：生成不再是 6 秒假进度，而是真实的
/// 转写 + 大模型调用（[SummaryGenerator]）；录音数据来自真实设备同步
/// （[RecordingSyncService]）；导航栈与总结卡落 shared_preferences，冷启动恢复。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../data/seed.dart';
import '../../services/ai/summary_generator.dart';
import '../../services/audio/recording_status.dart';
import '../../services/recordings/recording_pipeline.dart';
import '../../services/recordings/recording_store.dart';
import '../../services/recordings/recordings_manifest.dart';
import '../../services/recordings/recording_sync_service.dart';
import '../../services/recordings/segment_projection.dart';
import '../models/record.dart';
import '../models/recording.dart';
import '../models/segment_view.dart';
import '../models/summary.dart';
import '../storage/storage.dart';

enum RootTab { timeline, setting }

enum FeedFilter { all, event, summary }

class RouteEntry {
  final String type; // 'sum' | 'detail'
  final String id;
  const RouteEntry(this.type, this.id);

  @override
  bool operator ==(Object other) =>
      other is RouteEntry && other.type == type && other.id == id;
  @override
  int get hashCode => Object.hash(type, id);
}

class FeedGroup {
  final String dayLabel;
  final List<Object> items; // SummaryCard | RecordEvent（按渲染顺序混排）
  const FeedGroup(this.dayLabel, this.items);
}

/// 生成过程的展示常量：仅用于文案与估算，不驱动真实工作。
abstract final class GenConst {
  /// 粗略估算：每条记录的转写+整理按 8 秒算，用于"预计还需"的提示。
  static const secondsPerSource = 8;
  static const minEstimateSeconds = 8;
}

class AppStore extends ChangeNotifier {
  AppStore({
    List<RecordEvent>? events,
    RecordingSyncService? recordings,
    SummaryGenerator? generator,
    JsonStore? jsonStore,
    bool loadPersistedState = true,
  }) : events = events ?? const [],
       _seedOverride = events,
       _recordings = recordings,
       _generator = generator,
       _json = jsonStore,
       _loadPersisted = loadPersistedState;

  /// 录音数据（真实设备同步进来的记录）。
  List<RecordEvent> events;

  /// 测试注入的固定数据集（非 null 时不做网络/设备加载）。
  final List<RecordEvent>? _seedOverride;

  RecordingSyncService? _recordings;
  RecordingPipeline? _pipeline;
  RecordingStore? _recordingStore;
  RecordingStatusController? _status;
  SummaryGenerator? _generator;
  JsonStore? _json;
  final bool _loadPersisted;

  /// 本地录音文件（含未完成/失败的，供空态与处理状态使用）。
  List<RecordingFile> recordingFiles = const [];

  /// 分段详情视图：Timeline 与详情页共用同一份 turns/utterances。
  Map<String, SegmentView> segmentViews = const {};

  bool loading = false;
  String? loadError;
  SyncStage? syncStage;
  double syncProgress = 0;
  String syncText = '';
  String? syncError;

  RootTab rootTab = RootTab.timeline;
  FeedFilter filter = FeedFilter.all;
  bool tabsLocked = false; // 勾选模式：仅「记录」可用

  bool selMode = false;
  final Set<String> selIds = {};
  SummaryCard? pend; // 勾选模式挂起的 Action Card
  List<SummaryCard> summaries = [];
  String? openCardId; // 展开态卡片（互斥）

  List<RouteEntry> subStack = []; // 路由栈：总结↔记录互跳统一历史栈

  /// 生成计时（真实墙钟，用于"已生成 N 秒"）
  Stopwatch? _genWatch;
  Timer? _genTicker;
  double _genProgress = 0;
  String _genStep = '';

  static const pageLabels = {'sum': '总结', 'detail': '记录'};

  void attachServices({
    required RecordingSyncService recordings,
    required SummaryGenerator generator,
  }) {
    _recordings = recordings;
    _generator = generator;
  }

  /// 正式版装配：本地转写/润色/分段流水线 + v2 存储。
  ///
  /// 与 [attachServices] 二选一：旧链路（云端整文件 ASR）保留给旧测试；
  /// 有 pipeline 时优先走新链路。
  void attachPipeline({
    required RecordingPipeline pipeline,
    required RecordingStore store,
    required SummaryGenerator generator,
    RecordingStatusController? status,
  }) {
    _pipeline = pipeline;
    _recordingStore = store;
    _generator = generator;
    _status = status;
  }

  SegmentView? segmentViewFor(String segmentId) => segmentViews[segmentId];

  // ── 启动装载 ────────────────────────────────────────────
  /// 冷启动：恢复导航栈与历史总结卡，再拉本地录音清单。
  Future<void> init() async {
    if (_loadPersisted) {
      final store = await _jsonStore();
      final data = await store.read('route');
      restoreState(data);
    }
    if (_pipeline != null) {
      try {
        await _recordingStore!.migrateFromV1(RecordingsManifest());
      } on Object catch (e) {
        debugPrint('[store] v1 迁移失败（不阻塞启动）：$e');
      }
      await refreshFromStore();
      return;
    }
    await refreshEvents();
  }

  Future<JsonStore> _jsonStore() async {
    final existing = _json;
    if (existing != null) return existing;
    final created = JsonStore(store: await PrefsStore.open());
    _json = created;
    return created;
  }

  /// 从 v2 存储读取录音并投影成分段（正式版路径）。
  Future<void> refreshFromStore() async {
    final store = _recordingStore;
    if (store == null) return;
    loading = true;
    loadError = null;
    notifyListeners();
    try {
      final files = await store.loadAll(refresh: true);
      final projection = SegmentProjection.build(files);
      recordingFiles = files;
      events = projection.events;
      segmentViews = projection.views;
    } on Object catch (e) {
      loadError = '读取本地录音失败：$e';
    }
    loading = false;
    notifyListeners();
  }

  /// 重新读取本地录音清单（同步设备后调用）。
  Future<void> refreshEvents() async {
    if (_pipeline != null) {
      await refreshFromStore();
      return;
    }
    final override = _seedOverride;
    if (override != null) {
      events = [...override];
      notifyListeners();
      return;
    }
    final service = _recordings;
    if (service == null) {
      events = seedEvents; // 未装配服务（旧调用方/测试）时退回设计样例
      notifyListeners();
      return;
    }
    loading = true;
    loadError = null;
    notifyListeners();
    try {
      events = await service.loadEvents();
    } on Object catch (e) {
      loadError = '读取本地录音失败：$e';
    }
    loading = false;
    notifyListeners();
  }

  /// 从录音卡同步新录音（下载 + 转码 + 转写），完成后再刷新列表。
  Future<String?> syncRecordings() async {
    final pipeline = _pipeline;
    if (pipeline != null) return _syncWithPipeline(pipeline);
    final service = _recordings;
    if (service == null) {
      syncError = '录音同步未就绪，请稍后重试';
      notifyListeners();
      return syncError;
    }
    syncError = null;
    syncStage = SyncStage.listing;
    syncProgress = 0;
    syncText = '正在读取录音卡文件列表…';
    notifyListeners();
    try {
      final report = await service.syncFromDevice(
        onProgress: (stage, progress, text) {
          syncStage = stage;
          syncProgress = progress.clamp(0, 1);
          syncText = text;
          notifyListeners();
        },
      );
      events = report.events;
      if (report.error != null) {
        syncError = report.error;
        return report.error;
      }
      final failed = report.items
          .where((i) => i.outcome == SyncFileOutcome.failed)
          .toList();
      if (failed.isNotEmpty) {
        syncError = '${failed.length} 条录音同步失败：${failed.first.message ?? ''}';
      }
      // 顺手清理孤儿文件，避免本地目录无限增长
      unawaited(service.pruneOrphans());
      return syncError;
    } on Object catch (e) {
      syncError = '同步失败：$e';
      return syncError;
    } finally {
      syncStage = null;
      syncProgress = 0;
      syncText = '';
      notifyListeners();
    }
  }

  /// v2 流水线同步：真实进度来自下载/切片/转写/润色/分段。
  Future<String?> _syncWithPipeline(RecordingPipeline pipeline) async {
    if (pipeline.isBusy) {
      syncError = '处理已在进行中';
      notifyListeners();
      return syncError;
    }
    syncError = null;
    syncStage = SyncStage.listing;
    syncProgress = 0;
    syncText = '正在读取录音卡文件列表…';
    _status?.startSync(detail: syncText);
    notifyListeners();
    try {
      final report = await pipeline.sync(onProgress: _onPipelineProgress);
      await refreshFromStore();
      if (report.failed > 0) {
        syncError = '${report.failed} 条录音处理失败：${report.failures.first}';
      }
      return syncError;
    } on Object catch (e) {
      syncError = '同步失败：$e';
      return syncError;
    } finally {
      syncStage = null;
      syncProgress = 0;
      syncText = '';
      final error = syncError;
      if (error != null) {
        // 失败不静默：顶部状态块停在错误态，等下一次同步重试
        _status?.onError(error);
      } else {
        _status?.updateQueue(remaining: 0, active: false);
      }
      notifyListeners();
    }
  }

  /// 启动/切前台时继续处理本地未完成的录音（不访问设备）。
  Future<void> processPendingRecordings() async {
    final pipeline = _pipeline;
    if (pipeline == null || pipeline.isBusy) return;
    _status?.startSync(detail: '正在整理本地录音…');
    try {
      await pipeline.processPending(onProgress: _onPipelineProgress);
      await refreshFromStore();
    } on Object catch (e) {
      debugPrint('[store] 续跑失败：$e');
    } finally {
      _status?.updateQueue(remaining: 0, active: false);
    }
  }

  void _onPipelineProgress(PipelineProgress p) {
    syncStage = SyncStage.listing;
    syncProgress = p.progress;
    syncText = p.text;
    final total = p.sliceTotal ?? 0;
    final index = p.sliceIndex ?? 0;
    final remaining = total > 0 ? (total - index).clamp(0, total) : 0;
    if (p.stage == PipelineStage.done) {
      _status?.updateQueue(remaining: 0, active: false);
    } else {
      _status?.updateSync(p.text, remaining: remaining);
    }
    notifyListeners();
  }

  // ── 根导航 ──────────────────────────────────────────────
  void go(RootTab tab) {
    rootTab = tab;
    subStack = [];
    _persist();
    notifyListeners();
  }

  // ── 路由栈（历史扁平化） ────────────────────────────────
  void navSub(RouteEntry e, {bool fresh = false}) {
    if (fresh) {
      subStack = [e];
    } else {
      final i = subStack.indexWhere((x) => x == e);
      subStack = i >= 0 ? subStack.sublist(0, i + 1) : [...subStack, e];
    }
    _persist();
    notifyListeners();
  }

  void openDetail(String id, {bool fresh = false}) =>
      navSub(RouteEntry('detail', id), fresh: fresh);

  void openSum(String id, {bool fresh = false}) {
    final s = summaryById(id);
    if (s == null || s.state != SummaryState.done) return;
    navSub(RouteEntry('sum', id), fresh: fresh);
  }

  void goBack() {
    if (subStack.length > 1) {
      subStack = subStack.sublist(0, subStack.length - 1);
      _persist();
      notifyListeners();
    } else {
      go(RootTab.timeline);
    }
  }

  /// 系统返回手势（Navigator 页面被弹出）回调：仅同步栈状态，不反向触发导航。
  void onSubPopped() {
    if (subStack.isEmpty) return;
    subStack = subStack.sublist(0, subStack.length - 1);
    if (subStack.isEmpty) openCardId = null;
    _persist();
    notifyListeners();
  }

  /// Android 物理返回键 / iOS 边缘手势入口：栈里有页就退一页，否则交给系统。
  bool handleSystemBack() {
    if (subStack.isEmpty) return false;
    goBack();
    return true;
  }

  RouteEntry? get stackTop => subStack.isEmpty ? null : subStack.last;
  RouteEntry? get stackPrev =>
      subStack.length > 1 ? subStack[subStack.length - 2] : null;
  String get crumbDest => stackPrev == null
      ? 'Timeline'
      : (pageLabels[stackPrev!.type] ?? 'Timeline');
  bool get showPaneBackDetail =>
      subStack.length > 1 && stackTop!.type == 'detail';
  bool get showPaneBackSum => subStack.length > 1 && stackTop!.type == 'sum';

  SummaryCard? summaryById(String id) =>
      summaries.where((s) => s.id == id).firstOrNull;

  /// 按 id 找记录；找不到返回 null（历史栈里残留的失效 id 不该让页面红屏）。
  RecordEvent? eventByIdOrNull(String id) {
    for (final e in events) {
      if (e.id == id) return e;
    }
    return null;
  }

  RecordEvent? eventByIdOrNullOrFallback(String id) =>
      eventByIdOrNull(id) ?? (events.isEmpty ? null : events.first);

  List<SummaryCard> doneSummariesReferencing(String eventId) => summaries
      .where((s) => s.state == SummaryState.done && s.srcIds.contains(eventId))
      .toList();

  // ── Timeline 渲染数据 ───────────────────────────────────
  List<FeedGroup> get feedGroups {
    final f = filter;
    final sums = summaries
        .where((s) => f == FeedFilter.all || f == FeedFilter.summary)
        .toList();
    final evs = events
        .where((e) => f == FeedFilter.all || f == FeedFilter.event)
        .toList();

    // 先按天放记录（0=今天，其余=过去 N 天），再把总结卡插到它覆盖内容的
    // 最后一条记录之后——总结卡应该出现在「被总结的那段时间」下面，而不是
    // 无条件堆在今天最上面。
    final byDay = <int, List<Object>>{0: []};
    for (final e in evs) {
      (byDay[e.dayOffset] ??= []).add(e);
    }
    // feed 是倒序：同一天内必须按时间从晚到早排，不能依赖 events 的原始顺序。
    // 此时列表里只有记录（总结卡还没插入），可以安全按 time 排序。
    for (final list in byDay.values) {
      list.sort((a, b) {
        final ea = a as RecordEvent;
        final eb = b as RecordEvent;
        return _minutesOfDay(eb.time).compareTo(_minutesOfDay(ea.time));
      });
    }
    final unanchored = <SummaryCard>[];
    for (final s in sums) {
      final anchor = _oldestSource(s);
      final list = anchor == null ? null : byDay[anchor.dayOffset];
      if (anchor == null || list == null) {
        unanchored.add(s);
        continue;
      }
      var at = list.indexWhere(
        (x) => x is RecordEvent && x.id == anchor.id,
      );
      at = at < 0 ? list.length : at + 1;
      // 同一锚点已插入的总结卡之后，保持 summaries 的先后顺序
      while (at < list.length && list[at] is SummaryCard) {
        at++;
      }
      list.insert(at, s);
    }
    // 找不到来源（或「总结」Tab 只显示总结）时退回今天顶部
    byDay[0]!.insertAll(0, unanchored);

    final days = byDay.keys.where((d) => byDay[d]!.isNotEmpty).toList()
      ..sort();
    return [for (final d in days) FeedGroup(dayLabel(d), byDay[d]!)];
  }

  /// 总结卡的时间轴锚点：覆盖记录里最早的一条（日偏移最大、同日时间最早）。
  ///
  /// 时间轴是倒序展示的，插在这条记录之后 = 视觉上正好落在这段内容的下方。
  /// pending 卡还没有 srcIds，用当前勾选集推导，生成中的卡也保持在原位。
  RecordEvent? _oldestSource(SummaryCard s) {
    final ids = s.srcIds.isNotEmpty
        ? s.srcIds
        : (s.state == SummaryState.pending ? selIds.toList() : const <String>[]);
    RecordEvent? oldest;
    for (final id in ids) {
      final e = eventByIdOrNull(id);
      if (e == null || e.live) continue;
      if (oldest == null ||
          e.dayOffset > oldest.dayOffset ||
          (e.dayOffset == oldest.dayOffset &&
              _minutesOfDay(e.time) < _minutesOfDay(oldest.time))) {
        oldest = e;
      }
    }
    return oldest;
  }

  static int _minutesOfDay(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return 0;
    return (int.tryParse(parts[0]) ?? 0) * 60 +
        (int.tryParse(parts[1]) ?? 0);
  }

  // ── 卡片展开/收起（互斥） ───────────────────────────────
  void tapCard(String id, {required bool isSummary}) {
    if (selMode) {
      if (!isSummary) toggleSel(id);
      return;
    }
    if (isSummary) {
      final s = summaryById(id);
      if (s == null || s.state != SummaryState.done) return; // 未完成/失败锁定
      // 总结没有「详情」可展开：点卡片直接进总结结果页
      openSum(id, fresh: true);
      return;
    }
    openCardId = openCardId == id ? null : id;
    notifyListeners();
  }

  void setFilter(FeedFilter f) {
    filter = f;
    notifyListeners();
  }

  // ── 勾选式总结 ─────────────────────────────────────────
  void startSummary() {
    selMode = true;
    selIds.clear();
    openCardId = null;
    pend = SummaryCard(
      id: 'act${DateTime.now().millisecondsSinceEpoch}',
      time: nowHM(),
    );
    summaries = [pend!, ...summaries];
    _lockTabs(true);
  }

  void cancelSummary() {
    selMode = false;
    pend = null;
    // 取消只丢弃挂起的草稿卡，历史已完成的总结卡必须保留
    summaries = summaries
        .where((s) => s.state != SummaryState.pending)
        .toList();
    openCardId = null;
    _lockTabs(false);
  }

  void _lockTabs(bool lock) {
    tabsLocked = lock;
    filter = lock ? FeedFilter.event : FeedFilter.all;
    notifyListeners();
  }

  bool inRange(RecordEvent e, String r) {
    if (e.live) return false; // 整理中的分段未定稿，不参与总结勾选
    if (r == 'today') return e.dayOffset == 0;
    if (r == 'week') return e.dayOffset <= mondayOffset;
    final n = DateTime.now();
    final d = n.subtract(Duration(days: e.dayOffset));
    return d.month == n.month && d.year == n.year;
  }

  void selRange(String r) {
    selIds
      ..clear()
      ..addAll(events.where((e) => inRange(e, r)).map((e) => e.id));
    notifyListeners();
  }

  void selNone() {
    selIds.clear();
    notifyListeners();
  }

  void toggleSel(String id) {
    final event = eventByIdOrNull(id);
    if (event != null && event.live) return;
    selIds.contains(id) ? selIds.remove(id) : selIds.add(id);
    notifyListeners();
  }

  int get selCount => selIds.length;

  // ── 生成总结（真实链路） ────────────────────────────────
  /// 开始生成：卡片进入 generating，页面立即跳转到总结页展示进度。
  ///
  /// 真正的转写+大模型调用在后台跑；失败会落到 failed 态并给出可读原因，
  /// 用户可以重试或取消——不会出现"进度走完但内容是编的"。
  void genSummary() {
    final picked = events.where((e) => selIds.contains(e.id)).toList();
    if (picked.isEmpty) return;
    selMode = false;
    final card = pend;
    if (card == null) return;
    card
      ..state = SummaryState.generating
      ..progress = 0
      ..srcIds = picked.map((e) => e.id).toList()
      ..error = null;
    openCardId = card.id;
    _lockTabs(false);
    navSub(RouteEntry('sum', card.id));
    _runGeneration(card, picked);
  }

  Future<void> _runGeneration(
    SummaryCard card,
    List<RecordEvent> sources,
  ) async {
    _genProgress = 0;
    _genStep = '解析来源内容…';
    _genWatch = Stopwatch()..start();
    _genTicker?.cancel();
    // 每 500ms 刷新一次"已生成 N 秒"，只做展示计时，不伪造阶段推进
    _genTicker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      notifyListeners();
    });
    card.progress = 0;
    notifyListeners();

    final generator = _generator;
    try {
      if (generator == null) {
        throw const SummaryGenerationException('总结服务未就绪');
      }
      final draft = await generator.generate(
        sources,
        onProgress: (progress, step) {
          _genProgress = progress.clamp(0, 1);
          _genStep = step;
          card.progress = _genProgress * 100;
          notifyListeners();
        },
      );
      card
        ..state = SummaryState.done
        ..progress = 100
        ..error = null
        ..title = draft.title
        ..overview = draft.overview
        ..structure = draft.structure
        ..points = draft.points
        ..todos = draft.todos
        ..markdown = draft.markdown
        ..subDesc = _describeSources(sources)
        ..srcDesc = sources
            .map((e) => '${dayLabel(e.dayOffset)} ${e.time} ${e.title}')
            .join('；');
      _persist();
    } on Object catch (e) {
      final message = e is SummaryGenerationException ? e.message : '生成失败：$e';
      // 失败不产出任何内容：卡片停在 failed，页面展示原因与重试入口
      card
        ..state = SummaryState.failed
        ..error = message
        ..progress = 100;
    } finally {
      _genTicker?.cancel();
      _genTicker = null;
      _genWatch?.stop();
      notifyListeners();
    }
  }

  /// 失败后重试：复用同一张卡。
  void retryGeneration(String summaryId) {
    final card = summaryById(summaryId);
    if (card == null || card.state != SummaryState.failed) return;
    final sources = <RecordEvent>[];
    for (final id in card.srcIds) {
      final e = eventByIdOrNull(id);
      if (e != null) sources.add(e);
    }
    if (sources.isEmpty) return;
    card
      ..state = SummaryState.generating
      ..error = null
      ..progress = 0;
    notifyListeners();
    _runGeneration(card, sources);
  }

  /// 放弃失败的总结卡。
  void dismissFailed(String summaryId) {
    summaries = [
      for (final s in summaries)
        if (!(s.id == summaryId && s.state == SummaryState.failed)) s,
    ];
    if (openCardId == summaryId) openCardId = null;
    if (subStack.isNotEmpty && stackTop?.id == summaryId) {
      subStack = subStack.sublist(0, subStack.length - 1);
    }
    _persist();
    notifyListeners();
  }

  static String _describeSources(List<RecordEvent> sources) {
    if (sources.isEmpty) return '';
    final days = sources.map((e) => e.dayOffset).toSet().toList()..sort();
    if (days.length == 1) {
      final times = sources.map((e) => e.time).toList()..sort();
      return '${dayLabel(days.first)} ${times.first}–${times.last} · ${sources.length} 条记录';
    }
    return '跨 ${dayLabel(days.last)} 至 ${dayLabel(days.first)} · ${sources.length} 条记录';
  }

  // 生成进度文案（真实计时 + 估算）
  int get genElapsedSeconds => _genWatch?.elapsed.inSeconds ?? 0;
  String genElapsedText() => '已生成 $genElapsedSeconds 秒';
  String genEtaText() {
    final card = stackTop == null ? null : summaryById(stackTop!.id);
    final count = math.max(1, card?.srcIds.length ?? 1);
    final estimate = math.max(
      GenConst.minEstimateSeconds,
      count * GenConst.secondsPerSource,
    );
    final remain = math.max(0, estimate - genElapsedSeconds);
    return '预计还需 $remain 秒';
  }

  String genStepText() => _genStep.isEmpty ? '解析来源内容…' : _genStep;

  @override
  void dispose() {
    _genTicker?.cancel();
    super.dispose();
  }

  // ── 会话持久化（对应原型 sessionStorage rc-route-v1） ──
  Map<String, dynamic> exportState() => {
    'stack': [
      for (final e in subStack) {'t': e.type, 'id': e.id},
    ],
    'sums': [
      for (final s in summaries.where((s) => s.state == SummaryState.done))
        s.toJson(),
    ],
  };

  void restoreState(Map<String, dynamic>? data) {
    if (data == null) return;
    summaries = [
      for (final j in (data['sums'] as List? ?? []))
        if (j is Map<String, dynamic>) SummaryCard.fromJson(j),
    ];
    subStack = [
      for (final e in (data['stack'] as List? ?? []))
        if (e is Map<String, dynamic> &&
            ((e['t'] == 'detail') ||
                (e['t'] == 'sum' && summaries.any((s) => s.id == e['id']))))
          RouteEntry(e['t'] as String, e['id'] as String),
    ];
    notifyListeners();
  }

  /// 落盘：导航栈 + 已完成的总结卡。写失败不影响交互（下次再写）。
  void _persist() {
    if (!_loadPersisted) return;
    unawaited(() async {
      try {
        final store = await _jsonStore();
        await store.write('route', exportState());
      } on Object catch (e) {
        debugPrint('[store] 会话持久化失败：$e');
      }
    }());
  }
}
