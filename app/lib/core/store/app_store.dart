/// Single UI state source; preserves prototype selection and flattened routing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/record.dart';
import '../models/summary.dart';
import 'app_backend.dart';
import 'store_persistence.dart';
import '../../services/export/export_service.dart';

enum RootTab { timeline, setting }

enum FeedFilter { all, event, summary }

class RouteEntry {
  final String type;
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
  final List<Object> items;
  const FeedGroup(this.dayLabel, this.items);
}

class AppStore extends ChangeNotifier {
  AppStore({
    List<RecordEvent>? events,
    AppBackend? backend,
    StorePersistence? persistence,
    ExportService? exportService,
    DateTime Function()? clock,
    this.recordUpdates,
    this.retryRecordProcessing,
  }) : events = List.of(events ?? const []),
       backend = backend ?? const UnconfiguredAppBackend(),
       persistence = persistence ?? PreferencesStorePersistence(),
       exportService = exportService ?? ExportService(),
       _now = clock ?? DateTime.now;
  final DateTime Function() _now;
  final List<RecordEvent> events;
  final AppBackend backend;
  final StorePersistence persistence;
  final ExportService exportService;
  final Stream<List<RecordEvent>>? recordUpdates;
  final Future<void> Function()? retryRecordProcessing;
  StreamSubscription<List<RecordEvent>>? _recordSubscription;
  final Set<String> _activeGenerations = {};
  RecordingPolicy policy = const RecordingPolicy();
  RootTab rootTab = RootTab.timeline;
  FeedFilter filter = FeedFilter.all;
  bool tabsLocked = false;
  bool selMode = false;
  final Set<String> selIds = {};
  SummaryCard? pend;
  List<SummaryCard> summaries = [];
  String? openCardId;
  List<RouteEntry> subStack = [];
  bool loading = false;
  bool settingBusy = false;
  bool exporting = false;
  String? error;
  String? settingError;
  String? persistenceError;
  final Map<String, String> summaryErrors = {};
  final Map<String, TaskProgress> summaryTasks = {};
  final Map<String, Set<int>> _todos = {};
  final Map<String, Set<int>> _expandedPoints = {};
  final Map<String, String> _summaryTabs = {};
  final Map<String, String> _detailTabs = {};
  final Map<String, DateTime> _started = {};
  final Map<String, int> _runs = {};
  Timer? _clock;
  Future<void> _saveTail = Future.value();
  bool _disposed = false;
  static const pageLabels = {'sum': '总结', 'detail': '记录'};
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    _recordSubscription ??= recordUpdates?.listen(
      applyRecordUpdates,
      onError: (Object failure) {
        error = '录音处理失败：${_message(failure)}';
        _notify();
      },
    );
    loading = true;
    _notify();
    try {
      restoreState(await persistence.load());
    } catch (_) {
      persistenceError = '本机状态读取失败，请检查存储后重试';
    }
    try {
      await backend.applyPolicy(policy);
    } catch (_) {
      settingError = '录音策略尚未应用，连接服务后重试';
    }
    await reloadEvents();
  }

  Future<void> reloadEvents() async {
    loading = true;
    error = null;
    _notify();
    try {
      final loaded = await backend.loadEvents();
      events
        ..clear()
        ..addAll(loaded);
      selIds.removeWhere((id) => !events.any((e) => e.id == id));
      _validateRoutes();
      _persist();
    } catch (e) {
      error = '录音记录读取失败：${_message(e)}';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> retryRecords() async {
    if (loading || _disposed) return;
    loading = true;
    error = null;
    _notify();
    Object? failure;
    try {
      await retryRecordProcessing?.call();
    } catch (e) {
      failure = e;
    }
    await reloadEvents();
    if (failure != null) {
      error = '录音处理失败：${_message(failure)}';
      _notify();
    }
  }

  /// Sliding-window cleaned/event updates replace stable IDs rather than
  /// append duplicates; canonical raw storage remains C's responsibility.
  void applyRecordUpdates(List<RecordEvent> updates) {
    for (final update in updates) {
      final index = events.indexWhere((e) => e.id == update.id);
      if (index < 0) {
        events.add(update);
      } else {
        events[index] = update;
      }
    }
    _persist();
    _notify();
  }

  void go(RootTab tab) {
    rootTab = tab;
    subStack = [];
    _persist();
    _notify();
  }

  void navSub(RouteEntry e, {bool fresh = false}) {
    if (fresh) {
      subStack = [e];
    } else {
      final i = subStack.indexOf(e);
      subStack = i >= 0 ? subStack.sublist(0, i + 1) : [...subStack, e];
    }
    _persist();
    _notify();
  }

  void openDetail(String id, {bool fresh = false}) {
    if (eventOrNull(id) == null) {
      error = '来源记录不存在或尚未同步';
      _notify();
      return;
    }
    navSub(RouteEntry('detail', id), fresh: fresh);
  }

  void openSum(String id, {bool fresh = false}) {
    if (summaryById(id) == null) return;
    navSub(RouteEntry('sum', id), fresh: fresh);
  }

  void goBack() {
    if (subStack.length > 1) {
      subStack = subStack.sublist(0, subStack.length - 1);
      _persist();
      _notify();
    } else {
      go(RootTab.timeline);
    }
  }

  void onSubPopped() {
    if (subStack.isEmpty) return;
    subStack = subStack.sublist(0, subStack.length - 1);
    if (subStack.isEmpty) openCardId = null;
    _persist();
    _notify();
  }

  RouteEntry? get stackTop => subStack.lastOrNull;
  RouteEntry? get stackPrev =>
      subStack.length > 1 ? subStack[subStack.length - 2] : null;
  String get crumbDest => pageLabels[stackPrev?.type] ?? 'Timeline';
  bool get showPaneBackDetail =>
      subStack.length > 1 && stackTop?.type == 'detail';
  bool get showPaneBackSum => subStack.length > 1 && stackTop?.type == 'sum';
  SummaryCard? summaryById(String id) =>
      summaries.where((s) => s.id == id).firstOrNull;
  RecordEvent? eventOrNull(String id) =>
      events.where((e) => e.id == id).firstOrNull;
  RecordEvent eventById(String id) => events.firstWhere((e) => e.id == id);
  List<SummaryCard> doneSummariesReferencing(String id) => summaries
      .where((s) => s.state == SummaryState.done && s.srcIds.contains(id))
      .toList();
  List<FeedGroup> get feedGroups {
    final sums = summaries.where((s) => filter != FeedFilter.event).toList();
    final evs = events.where((e) => filter != FeedFilter.summary).toList();
    final offs = evs.map((e) => e.dayOffsetAt(_now())).toSet().toList()..sort();
    final groups = <FeedGroup>[];
    if (sums.isNotEmpty || evs.any((e) => e.dayOffsetAt(_now()) == 0)) {
      groups.add(
        FeedGroup(dayLabel(0), [
          ...sums,
          ...evs.where((e) => e.dayOffsetAt(_now()) == 0),
        ]),
      );
    }
    for (final off in offs.where((off) => off != 0)) {
      groups.add(
        FeedGroup(
          dayLabel(off),
          evs.where((e) => e.dayOffsetAt(_now()) == off).toList(),
        ),
      );
    }
    return groups;
  }

  void tapCard(String id, {required bool isSummary}) {
    if (selMode) {
      if (!isSummary) toggleSel(id);
      return;
    }
    if (isSummary && summaryById(id)?.state != SummaryState.done) {
      openSum(id);
      return;
    }
    openCardId = openCardId == id ? null : id;
    _persist();
    _notify();
  }

  void setFilter(FeedFilter f) {
    filter = f;
    _persist();
    _notify();
  }

  void startSummary() {
    if (selMode) return;
    selMode = true;
    selIds.clear();
    openCardId = null;
    pend = SummaryCard(
      id: 'act${_now().microsecondsSinceEpoch}',
      time: nowHM(),
    );
    summaries = [pend!, ...summaries];
    _lockTabs(true);
  }

  void cancelSummary() {
    selMode = false;
    summaries.removeWhere((s) => s.state == SummaryState.pending);
    pend = null;
    selIds.clear();
    openCardId = null;
    _lockTabs(false);
  }

  void _lockTabs(bool lock) {
    tabsLocked = lock;
    filter = lock ? FeedFilter.event : FeedFilter.all;
    _persist();
    _notify();
  }

  bool inRange(RecordEvent e, String r) {
    if (r == 'today') return e.dayOffsetAt(_now()) == 0;
    if (r == 'week') {
      return e.dayOffsetAt(_now()) >= 0 &&
          e.dayOffsetAt(_now()) <= (_now().weekday - 1);
    }
    final now = _now();
    final d = now.subtract(Duration(days: e.dayOffsetAt(now)));
    return d.month == now.month && d.year == now.year;
  }

  void selRange(String r) {
    selIds
      ..clear()
      ..addAll(events.where((e) => inRange(e, r)).map((e) => e.id));
    _persist();
    _notify();
  }

  void selNone() {
    selIds.clear();
    _persist();
    _notify();
  }

  void toggleSel(String id) {
    if (eventOrNull(id) == null) return;
    selIds.contains(id) ? selIds.remove(id) : selIds.add(id);
    _persist();
    _notify();
  }

  int get selCount => selIds.length;
  Future<void> genSummary() async {
    final selected = events.where((e) => selIds.contains(e.id)).toList();
    if (selected.isEmpty || pend == null) return;
    final card = pend!;
    card.srcIds = selected.map((e) => e.id).toList();
    selMode = false;
    selIds.clear();
    openCardId = card.id;
    _lockTabs(false);
    navSub(RouteEntry('sum', card.id));
    await _generate(card, selected);
  }

  Future<void> retrySummary(String id) async {
    final card = summaryById(id);
    if (card == null || !summaryErrors.containsKey(id)) return;
    if (_activeGenerations.contains(id)) {
      summaryErrors[id] = '上游请求仍在结束，请稍后重试';
      _notify();
      return;
    }
    final selected = events.where((e) => card.srcIds.contains(e.id)).toList();
    if (selected.length != card.srcIds.length) {
      summaryErrors[id] = '来源记录缺失，请先同步';
      _notify();
      return;
    }
    await _generate(card, selected);
  }

  Future<void> _generate(SummaryCard card, List<RecordEvent> selected) async {
    _activeGenerations.add(card.id);
    final run = (_runs[card.id] ?? 0) + 1;
    _runs[card.id] = run;
    card.state = SummaryState.generating;
    card.progress = 0;
    summaryErrors.remove(card.id);
    summaryTasks[card.id] = const TaskProgress('提交所选来源…');
    _started[card.id] = _now();
    _clock ??= Timer.periodic(const Duration(seconds: 1), (_) => _notify());
    _persist();
    _notify();
    try {
      final result = await backend.generateSummary(
        List.unmodifiable(selected),
        target: card,
        policy: policy,
        onProgress: (p) {
          if (_disposed || _runs[card.id] != run) return;
          summaryTasks[card.id] = p;
          card.progress = (p.percent ?? 0).clamp(0, 99).toDouble();
          _notify();
        },
      );
      if (_disposed || _runs[card.id] != run) return;
      final allowed = selected.map((e) => e.id).toSet();
      if (result.id != card.id ||
          result.state != SummaryState.done ||
          result.srcIds.length != allowed.length ||
          !result.srcIds.toSet().containsAll(allowed) ||
          result.points.any(
            (p) => p.sources.any((s) => !allowed.contains(s.eventId)),
          )) {
        throw StateError('总结返回了无效结果或非所选来源');
      }
      summaries[summaries.indexWhere((s) => s.id == card.id)] = result;
      if (pend?.id == card.id) pend = result;
      summaryTasks[card.id] = const TaskProgress('已完成', percent: 100);
    } catch (e) {
      if (_disposed || _runs[card.id] != run) return;
      summaryErrors[card.id] = '总结生成失败：${_message(e)}';
      summaryTasks[card.id] = const TaskProgress('生成失败');
      // Old and D's extended model both supported: sidecar is authoritative.
      final failed = SummaryState.values
          .where((s) => s.name == 'failed')
          .firstOrNull;
      card.state = failed ?? SummaryState.generating;
      card.srcIds = selected.map((e) => e.id).toList();
    } finally {
      _activeGenerations.remove(card.id);
      if (!_disposed && _runs[card.id] == run) {
        _started.remove(card.id);
        if (_started.isEmpty) {
          _clock?.cancel();
          _clock = null;
        }
        _persist();
        _notify();
      }
    }
  }

  Future<void> cancelGeneration(String id) async {
    _runs[id] = (_runs[id] ?? 0) + 1;
    _started.remove(id);
    summaryErrors[id] = '已停止等待；上游请求可能仍在处理';
    summaryTasks[id] = const TaskProgress('已请求取消');
    final card = summaryById(id);
    if (card != null) {
      card.state =
          SummaryState.values.where((s) => s.name == 'cancelled').firstOrNull ??
          SummaryState.generating;
    }
    if (backend is CancelableAppBackend) {
      try {
        await (backend as CancelableAppBackend).cancelSummary(id);
      } catch (_) {
        summaryErrors[id] = '已停止等待；当前服务无法取消已提交请求';
      }
    }
    if (_started.isEmpty) {
      _clock?.cancel();
      _clock = null;
    }
    _persist();
    _notify();
  }

  bool isGenerating(String id) => _started.containsKey(id);
  double? generationPercent(String id) => summaryTasks[id]?.percent;
  String genElapsedText([String? id]) {
    final start = _started[id ?? pend?.id];
    return '已生成 ${start == null ? 0 : _now().difference(start).inSeconds} 秒';
  }

  String genEtaText() => '预计时长未知';
  String genStepText([String? id]) =>
      summaryTasks[id ?? pend?.id]?.stage ?? '等待服务响应…';

  Future<void> toggleSetting(int index) async {
    if (settingBusy) return;
    final next = policy.toggled(index);
    settingBusy = true;
    settingError = null;
    _notify();
    try {
      await backend.applyPolicy(next);
      policy = next;
      await _persist();
    } catch (e) {
      settingError = '设置未生效：${_message(e)}';
    } finally {
      settingBusy = false;
      _notify();
    }
  }

  Set<int> todosDone(String id) =>
      Set.unmodifiable(_todos[id] ?? const <int>{});
  void toggleTodo(String id, int i) {
    final card = summaryById(id);
    if (card == null || i < 0 || i >= card.todos.length) return;
    final done = _todos.putIfAbsent(id, () => {});
    done.contains(i) ? done.remove(i) : done.add(i);
    _persist();
    _notify();
  }

  String summaryTab(String id) => _summaryTabs[id] ?? 'all';
  void setSummaryTab(String id, String tab) {
    _summaryTabs[id] = tab;
    _persist();
  }

  Set<int> pointsExpanded(String id) =>
      Set.of(_expandedPoints[id] ?? const <int>{});
  void setPointsExpanded(String id, Set<int> values) {
    _expandedPoints[id] = Set.of(values);
    _persist();
  }

  String detailTab(String id) => _detailTabs[id] ?? 'dlg';
  void setDetailTab(String id, String tab) {
    _detailTabs[id] = tab;
    _persist();
  }

  Future<ExportArtifact> exportSummary(
    String id,
    ExportFormat format, {
    bool share = true,
    RectOrigin? origin,
  }) async {
    if (exporting) throw StateError('导出任务正在运行');
    final card = summaryById(id);
    if (card == null || card.state != SummaryState.done) {
      throw StateError('总结尚未完成，无法导出');
    }
    final sources = card.srcIds.map(eventOrNull).toList();
    if (sources.any((e) => e == null)) throw StateError('来源记录缺失，无法导出完整内容');
    exporting = true;
    _notify();
    try {
      final artifact = await exportService.export(
        card,
        sources.cast<RecordEvent>(),
        format,
        completedTodos: todosDone(id),
      );
      if (share) await exportService.share(artifact, origin: origin);
      return artifact;
    } finally {
      exporting = false;
      _notify();
    }
  }

  Map<String, dynamic> exportState() => {
    'version': 2,
    'root': rootTab.name,
    'filter': filter.name,
    'stack': [
      for (final e in subStack) {'t': e.type, 'id': e.id},
    ],
    'sums': [
      for (final s in summaries) {...s.toJson(), '_state': s.state.name},
    ],
    'events': events.map(encodeDisplayRecord).toList(),
    'selMode': selMode,
    'selected': selIds.toList(),
    'pending': pend?.id,
    'openCard': openCardId,
    'policy': policy.toJson(),
    'errors': summaryErrors,
    'todos': {for (final e in _todos.entries) e.key: e.value.toList()},
    'points': {
      for (final e in _expandedPoints.entries) e.key: e.value.toList(),
    },
    'summaryTabs': _summaryTabs,
    'detailTabs': _detailTabs,
  };
  void restoreState(Map<String, dynamic>? data) {
    if (data == null) return;
    if (data['events'] is List) {
      events
        ..clear()
        ..addAll(
          (data['events'] as List).map(
            (e) => decodeDisplayRecord(Map<String, dynamic>.from(e as Map)),
          ),
        );
    }
    summaries = [
      for (final j in (data['sums'] as List? ?? []))
        SummaryCard.fromJson(Map<String, dynamic>.from(j as Map)),
    ];
    final rawSums = data['sums'] as List? ?? [];
    for (var i = 0; i < summaries.length; i++) {
      final stateName = rawSums[i]['_state'] as String? ?? 'done';
      summaries[i].state =
          SummaryState.values.where((s) => s.name == stateName).firstOrNull ??
          SummaryState.pending;
      if (stateName == 'generating') {
        summaryErrors[summaries[i].id] = '上次生成任务已中断，请重试';
      }
    }
    if (data['errors'] is Map) {
      summaryErrors.addAll(Map<String, String>.from(data['errors'] as Map));
    }
    subStack = [
      for (final e in (data['stack'] as List? ?? []))
        RouteEntry(e['t'] as String, e['id'] as String),
    ];
    policy = RecordingPolicy.fromJson(
      Map<String, dynamic>.from(data['policy'] as Map? ?? {}),
    );
    rootTab =
        RootTab.values.where((v) => v.name == data['root']).firstOrNull ??
        RootTab.timeline;
    filter =
        FeedFilter.values.where((v) => v.name == data['filter']).firstOrNull ??
        FeedFilter.all;
    selMode = data['selMode'] as bool? ?? false;
    tabsLocked = selMode;
    selIds
      ..clear()
      ..addAll((data['selected'] as List? ?? []).cast<String>());
    pend = summaryById(data['pending'] as String? ?? '');
    openCardId = data['openCard'] as String?;
    void sets(String key, Map<String, Set<int>> target) {
      final raw = data[key] as Map? ?? {};
      for (final e in raw.entries) {
        target[e.key as String] = (e.value as List).cast<int>().toSet();
      }
    }

    sets('todos', _todos);
    sets('points', _expandedPoints);
    _summaryTabs.addAll(
      Map<String, String>.from(data['summaryTabs'] as Map? ?? {}),
    );
    _detailTabs.addAll(
      Map<String, String>.from(data['detailTabs'] as Map? ?? {}),
    );
    _validateRoutes();
    _notify();
  }

  void _validateRoutes() {
    subStack.removeWhere(
      (e) => e.type == 'detail'
          ? eventOrNull(e.id) == null
          : e.type != 'sum' || summaryById(e.id) == null,
    );
  }

  Future<void> _persist() {
    // Deep copy now: each queued write owns its immutable snapshot.
    final state = jsonDecode(jsonEncode(exportState())) as Map<String, dynamic>;
    final previous = _saveTail;
    _saveTail = () async {
      await previous;
      try {
        await persistence.save(state);
        persistenceError = null;
      } catch (_) {
        persistenceError = '本机状态保存失败，重启后可能丢失更改';
        _notify();
      }
    }();
    return _saveTail;
  }

  Future<void> flushPersistence() => _saveTail;
  static String _message(Object error) =>
      error.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), '');
  @override
  void dispose() {
    _disposed = true;
    _clock?.cancel();
    _recordSubscription?.cancel();
    super.dispose();
  }
}

String nowHM() {
  final now = DateTime.now();
  return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
}

String dayLabel(int off) {
  if (off == 0) return '今天';
  if (off == 1) return '昨天';
  final d = DateTime.now().subtract(Duration(days: off));
  const dow = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return '${d.month}月${d.day}日 ${dow[d.weekday - 1]}';
}
