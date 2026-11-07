/// 应用核心状态机 —— 逐函数对应 prototype/index.html 全局状态与交互逻辑。
/// 设计真源：卡片两行折叠、勾选模式锁 Tab、生成 6s 进程、路由栈扁平化。
library;
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../data/seed.dart';
import '../models/record.dart';
import '../models/summary.dart';

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
  final List<RecordEvent> events;
  AppStore({List<RecordEvent>? events}) : events = events ?? seedEvents;

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

  RouteEntry? get stackTop => subStack.isEmpty ? null : subStack.last;
  RouteEntry? get stackPrev => subStack.length > 1 ? subStack[subStack.length - 2] : null;
  String get crumbDest => stackPrev == null ? 'Timeline' : (pageLabels[stackPrev!.type] ?? 'Timeline');
  bool get showPaneBackDetail => subStack.length > 1 && stackTop!.type == 'detail';
  bool get showPaneBackSum => subStack.length > 1 && stackTop!.type == 'sum';

  SummaryCard? summaryById(String id) => summaries.where((s) => s.id == id).firstOrNull;
  RecordEvent eventById(String id) => events.firstWhere((e) => e.id == id);
  List<SummaryCard> doneSummariesReferencing(String eventId) =>
      summaries.where((s) => s.state == SummaryState.done && s.srcIds.contains(eventId)).toList();

  // ── Timeline 渲染数据 ───────────────────────────────────
  List<FeedGroup> get feedGroups {
    final f = filter;
    final sums = summaries.where((s) => f == FeedFilter.all || f == FeedFilter.summary).toList();
    final evs = events.where((e) => f == FeedFilter.all || f == FeedFilter.event).toList();
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
      ..addAll(events.where((e) => inRange(e, r)).map((e) => e.id));
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
    final ids = events.where((e) => selIds.contains(e.id)).map((e) => e.id).toList();
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
    _genTimer = Timer.periodic(const Duration(milliseconds: GenConst.tickMs), (_) {
      // 用 tick 计数而非墙钟：进度完全由定时器驱动，测试虚拟时间下确定
      ticks++;
      final ms = ticks * GenConst.tickMs;
      final pc = math.min(100.0, ms / GenConst.totalMs * 100);
      card.progress = pc;
      if (pc >= 100) {
        _genTimer?.cancel();
        _genTimer = null;
        fillSummaryContent(card, events);
        _persist();
      }
      notifyListeners();
    });
  }

  int get _genMs {
    final card = pend;
    if (card == null || card.state != SummaryState.generating) return 0;
    return (card.progress / 100 * GenConst.totalMs).floor();
  }

  String genElapsedText() => '已生成 ${(_genMs / 1000).floor()} 秒';
  String genEtaText() =>
      '预计还需 ${math.max(0, ((GenConst.totalMs - _genMs) / 1000).ceil())} 秒';
  String genStepText() => GenConst.stepText(_genMs);

  @override
  void dispose() {
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
    summaries = [
      for (final j in (data['sums'] as List? ?? []))
        if (j is Map<String, dynamic>) SummaryCard.fromJson(j)
    ];
    subStack = [
      for (final e in (data['stack'] as List? ?? []))
        if (e is Map<String, dynamic> &&
            ((e['t'] == 'detail') ||
                (e['t'] == 'sum' && summaries.any((s) => s.id == e['id']))))
          RouteEntry(e['t'] as String, e['id'] as String)
    ];
    notifyListeners();
  }

  void _persist() {} // 持久化钩子：Stage 接 shared_preferences 时替换
}
