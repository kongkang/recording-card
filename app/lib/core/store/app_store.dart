/// 应用核心状态机 —— 逐函数对应 prototype/index.html 全局状态与交互逻辑。
/// 设计真源：卡片两行折叠、勾选模式锁 Tab、生成 6s 进程、路由栈扁平化。
library;
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../data/seed.dart';
import '../../services/analysis/summary_article.dart';
import '../../services/recordings/recording_repository.dart';
import '../../services/recordings/recording_view_adapter.dart';
import '../models/record.dart';
import '../models/summary.dart';
import '../storage/kv_store.dart';

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

/// 与原型一致的常量（测试对齐依赖这些时长）
abstract final class GenConst {
  static const totalMs = 6000;
  static const tickMs = 150;
  static String stepText(int ms) =>
      ms < 2000 ? '解析来源内容…' : ms < 4000 ? '提炼要点与逻辑…' : '整理结构与行动项…';
}

class AppStore extends ChangeNotifier {
  AppStore({
    List<RecordEvent>? events,
    KvStore? storage,
    RecordingRepository? recordings,
    SummaryArticleService? summaryService,
  })  : events = events ?? seedEvents,
        _storage = storage ?? MemoryKvStore(),
        _recordings = recordings,
        _summaryService = summaryService {
    _recordings?.addListener(_onRecordingsChanged);
    _restoreFromStorage();
  }

  /// 路由栈 + 已生成总结的持久化键（对应原型 sessionStorage rc-route-v1）
  static const storageKey = 'rc-route-v1';

  final List<RecordEvent> events;
  final KvStore _storage;
  final RecordingRepository? _recordings;
  final SummaryArticleService? _summaryService;

  /// 真实录音仓库优先；未注入时保持预置数据（设计验收/测试）。
  List<RecordEvent> get displayEvents =>
      _recordings == null ? events : toTimelineEvents(_recordings.all());

  void _onRecordingsChanged() => notifyListeners();

  RootTab rootTab = RootTab.timeline;
  FeedFilter filter = FeedFilter.all;
  bool tabsLocked = false; // 勾选模式：仅「记录」可用

  bool selMode = false;
  final Set<String> selIds = {};
  SummaryCard? pend; // 勾选模式挂起的 Action Card
  List<SummaryCard> summaries = [];
  String? openCardId; // 展开态卡片（互斥）

  List<RouteEntry> subStack = []; // 路由栈：总结↔记录互跳统一历史栈
  Timer? _genTimer;

  static const pageLabels = {'sum': '总结', 'detail': '记录'};

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
    final s = summaries.where((x) => x.id == id).firstOrNull;
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

  /// 系统返回手势（Navigator 页面被弹出）回调：仅同步栈状态，不反向触发导航
  ///（弹栈动画由 Navigator 驱动；store 更新只为 pages 列表收敛，防止路由被重新插入）
  void onSubPopped() {
    if (subStack.isEmpty) return;
    subStack = subStack.sublist(0, subStack.length - 1);
    if (subStack.isEmpty) openCardId = null;
    _persist();
    notifyListeners();
  }

  RouteEntry? get stackTop => subStack.isEmpty ? null : subStack.last;
  RouteEntry? get stackPrev => subStack.length > 1 ? subStack[subStack.length - 2] : null;
  String get crumbDest => stackPrev == null ? 'Timeline' : (pageLabels[stackPrev!.type] ?? 'Timeline');
  bool get showPaneBackDetail => subStack.length > 1 && stackTop!.type == 'detail';
  bool get showPaneBackSum => subStack.length > 1 && stackTop!.type == 'sum';

  SummaryCard? summaryById(String id) => summaries.where((s) => s.id == id).firstOrNull;
  RecordEvent eventById(String id) =>
      displayEvents.firstWhere((e) => e.id == id);
  List<SummaryCard> doneSummariesReferencing(String eventId) =>
      summaries.where((s) => s.state == SummaryState.done && s.srcIds.contains(eventId)).toList();

  // ── Timeline 渲染数据 ───────────────────────────────────
  List<FeedGroup> get feedGroups {
    final f = filter;
    final sums = summaries.where((s) => f == FeedFilter.all || f == FeedFilter.summary).toList();
    final evs = displayEvents.where((e) => f == FeedFilter.all || f == FeedFilter.event).toList();
    final past = evs.where((e) => e.dayOffset > 0).toList();
    final offs = past.map((e) => e.dayOffset).toSet().toList()..sort();
    final groups = <FeedGroup>[];
    final today = [...sums, ...evs.where((e) => e.dayOffset == 0)];
    if (today.isNotEmpty) groups.add(FeedGroup(dayLabel(0), today));
    for (final o in offs) {
      groups.add(FeedGroup(dayLabel(o), evs.where((e) => e.dayOffset == o).toList()));
    }
    return groups;
  }

  // ── 卡片展开/收起（互斥） ───────────────────────────────
  void tapCard(String id, {required bool isSummary}) {
    if (selMode) {
      if (!isSummary) toggleSel(id);
      return;
    }
    if (isSummary) {
      final s = summaryById(id);
      if (s != null && s.state != SummaryState.done) return; // 未完成锁定
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
    pend = SummaryCard(id: 'act${DateTime.now().millisecondsSinceEpoch}', time: nowHM());
    summaries = [pend!, ...summaries];
    _lockTabs(true);
  }

  void cancelSummary() {
    selMode = false;
    pend = null;
    summaries = summaries.where((s) => s.state != SummaryState.pending).toList();
    openCardId = null;
    _lockTabs(false);
    _persist();
  }

  void _lockTabs(bool lock) {
    tabsLocked = lock;
    filter = lock ? FeedFilter.event : FeedFilter.all;
    notifyListeners();
  }

  bool inRange(RecordEvent e, String r) {
    if (r == 'today') return e.dayOffset == 0;
    if (r == 'week') return e.dayOffset <= mondayOffset;
    final n = DateTime.now();
    final d = n.subtract(Duration(days: e.dayOffset));
    return d.month == n.month && d.year == n.year;
  }

  void selRange(String r) {
    selIds
      ..clear()
      ..addAll(displayEvents.where((e) => inRange(e, r)).map((e) => e.id));
    notifyListeners();
  }

  void selNone() {
    selIds.clear();
    notifyListeners();
  }

  void toggleSel(String id) {
    selIds.contains(id) ? selIds.remove(id) : selIds.add(id);
    notifyListeners();
  }

  int get selCount => selIds.length;

  // ── 生成进程（6s，150ms tick；与原型一致） ──────────────
  void genSummary() {
    final ids = displayEvents
        .where((e) => selIds.contains(e.id))
        .map((e) => e.id)
        .toList();
    if (ids.isEmpty) return;
    selMode = false;
    final card = pend!;
    card.state = SummaryState.generating;
    card.progress = 0;
    card.srcIds = ids;
    openCardId = card.id;
    _lockTabs(false);
    navSub(RouteEntry('sum', card.id));
    _runProgress(card);
  }

  void _runProgress(SummaryCard card) {
    var ticks = 0;
    _genTimer?.cancel();
    _genCard = card;
    _genTimer = Timer.periodic(const Duration(milliseconds: GenConst.tickMs), (_) {
      // 用 tick 计数而非墙钟：进度完全由定时器驱动，测试虚拟时间下确定
      ticks++;
      final ms = ticks * GenConst.tickMs;
      final pc = math.min(100.0, ms / GenConst.totalMs * 100);
      card.progress = pc;
      if (pc >= 100) {
        _genTimer?.cancel();
        _genTimer = null;
        final service = _summaryService;
        if (service == null) {
          fillSummaryContent(card, displayEvents);
          _persist();
        } else {
          _finishWithService(card, service);
        }
      }
      notifyListeners();
    });
  }

  SummaryCard? _genCard;

  Future<void> _finishWithService(
      SummaryCard card, SummaryArticleService service) async {
    try {
      final article = await service.generate(_sourcesFor(card));
      _applyArticle(card, article);
      _persist();
    } catch (e) {
      card.state = SummaryState.error;
      card.error = e.toString();
    }
    notifyListeners();
  }

  List<SummaryArticleSource> _sourcesFor(SummaryCard card) {
    final byId = {for (final e in displayEvents) e.id: e};
    return [
      for (final id in card.srcIds)
        if (byId[id] != null)
          SummaryArticleSource(
            recordingId: id,
            title: byId[id]!.title,
            cleanText: byId[id]!.dialog.isEmpty
                ? byId[id]!.longText
                : byId[id]!.dialog.map((l) => l.text).join('\n'),
          ),
    ];
  }

  void _applyArticle(SummaryCard card, SummaryArticle article) {
    final byId = {for (final e in displayEvents) e.id: e};
    final ids =
        article.sourceIds.isEmpty ? card.srcIds : article.sourceIds;
    final refs = [
      for (final id in ids)
        if (byId[id] != null)
          SourceRef(id, byId[id]!.title,
              byId[id]!.srcMap.replaceFirst('来源 ', ''))
    ];
    card.state = SummaryState.done;
    card.error = null;
    card.title = article.title;
    card.overview = article.overview;
    card.subDesc = '${card.srcIds.length} 条记录';
    card.structure = [
      for (final section in article.sections)
        MapBranch(section.heading, [section.body])
    ];
    card.points = [
      for (final section in article.sections)
        InfoPoint(section.heading, section.body, refs)
    ];
    card.todos = article.actionItems;
    card.srcDesc =
        [for (final id in ids) byId[id]?.title ?? id].join('；');
    card.markdown = '# ${article.title}\n\n${article.overview}\n\n'
        '${article.sections.map((s) => '## ${s.heading}\n${s.body}').join('\n\n')}\n\n'
        '## 行动项\n${article.actionItems.map((t) => '- [ ] $t').join('\n')}';
  }

  void retrySummary(String id) {
    final card = summaryById(id);
    if (card == null || card.state != SummaryState.error) return;
    card
      ..state = SummaryState.generating
      ..error = null
      ..progress = 0;
    _runProgress(card);
    notifyListeners();
  }

  int get _genMs {
    final card = _genCard;
    if (card == null || card.state != SummaryState.generating) return 0;
    return (card.progress / 100 * GenConst.totalMs).floor();
  }

  String genElapsedText() => '已生成 ${(_genMs / 1000).floor()} 秒';
  String genEtaText() =>
      '预计还需 ${math.max(0, ((GenConst.totalMs - _genMs) / 1000).ceil())} 秒';
  String genStepText() => GenConst.stepText(_genMs);

  @override
  void dispose() {
    _recordings?.removeListener(_onRecordingsChanged);
    _genTimer?.cancel();
    super.dispose();
  }

  // ── 会话持久化（对应原型 sessionStorage rc-route-v1） ──
  Map<String, dynamic> exportState() => {
        'stack': [
          for (final e in subStack) {'t': e.type, 'id': e.id}
        ],
        'sums': [for (final s in summaries.where((s) => s.state == SummaryState.done)) s.toJson()],
      };

  void restoreState(Map<String, dynamic>? data) {
    if (data == null) return;
    final restoredSums = <SummaryCard>[];
    for (final j in (data['sums'] as List? ?? [])) {
      if (j is! Map<String, dynamic>) continue;
      try {
        restoredSums.add(SummaryCard.fromJson(j));
      } catch (_) {
        // 单条损坏只跳过该条，不拖垮整个会话
      }
    }
    summaries = restoredSums;
    subStack = [
      for (final e in (data['stack'] as List? ?? []))
        if (e is Map<String, dynamic> &&
            ((e['t'] == 'detail') ||
                (e['t'] == 'sum' && summaries.any((s) => s.id == e['id']))))
          RouteEntry(e['t'] as String, e['id'] as String)
    ];
    notifyListeners();
  }

  void _restoreFromStorage() {
    final raw = _storage.getString(storageKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) restoreState(decoded);
    } catch (_) {
      // 损坏数据按空会话处理，不阻塞启动
    }
  }

  void _persist() {
    unawaited(_storage.setString(storageKey, jsonEncode(exportState())));
  }
}
