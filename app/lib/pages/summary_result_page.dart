/// 总结结果页 —— 生成态（进度/已生成/预计还需/步骤/取消）与结果态（吸顶 Tab + 目录浮钮 + 信息点溯源 + 导出）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models/record.dart';
import '../core/models/summary.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../services/export/export.dart';
import '../widgets/photo_preview_sheet.dart';
import '../widgets/photo_thumbnail.dart';
import '../widgets/quick_speaker_sheet.dart';
import '../widgets/speaker_suggestion_banner.dart';
import '../widgets/store_scope.dart';

/// 吸顶 Tab 栏高度（原型 .stabs 行高 46）。
const double _kTabsH = 46;

class SummaryResultPage extends StatefulWidget {
  const SummaryResultPage({
    super.key,
    required this.summaryId,
    this.showPaneBack = false,
    this.onCancelGeneration,
    this.exportService,
  });

  final String summaryId;
  final bool showPaneBack;
  final VoidCallback? onCancelGeneration;
  final ExportService? exportService;

  @override
  State<SummaryResultPage> createState() => _SummaryResultPageState();
}

class _FullTextGroupData {
  const _FullTextGroupData({
    required this.resolvedSpeaker,
    required this.rawSpeaker,
    required this.firstTurnIndex,
    required this.sampleQuote,
    required this.joinedText,
  });

  final String resolvedSpeaker;
  final String rawSpeaker;
  final int firstTurnIndex;
  final String sampleQuote;
  final String joinedText;
}

class _FullTextEventSectionData {
  const _FullTextEventSectionData({
    required this.event,
    required this.groups,
    required this.fallback,
  });

  final RecordEvent event;
  final List<_FullTextGroupData> groups;
  final String fallback;
}

class _SummaryMemo {
  const _SummaryMemo({
    required this.key,
    required this.allPhotos,
    required this.leafMatches,
    required this.pointPhotos,
    required this.sourceEvents,
    required this.sourcePhotoCounts,
    required this.orderedSourceEvents,
    required this.mergedFullTextSections,
    required this.fullText,
    required this.subDescText,
  });

  final Object key;
  final List<_ContextualPhoto> allPhotos;
  final Map<String, _ContextualPhoto> leafMatches;
  final List<List<_ContextualPhoto>> pointPhotos;
  final List<RecordEvent> sourceEvents;
  final Map<String, int> sourcePhotoCounts;
  final List<RecordEvent> orderedSourceEvents;
  final List<_FullTextEventSectionData> mergedFullTextSections;
  final String fullText;
  final String subDescText;
}

class _SummaryResultPageState extends State<SummaryResultPage> {
  static final Map<String, Set<int>> _memoryCheckedTodos = <String, Set<int>>{};
  static String _prefsTodoKey(String cardId) => 'rc-sum-todos-$cardId';

  final _fallbackScroll = ScrollController();
  final _sectionKeys = <String, GlobalKey>{};
  final _captureKey = GlobalKey(debugLabel: 'sum-export-capture');
  _SummaryMemo? _memo;

  /// 结果态标题块（标题 + 统计行）的实测高度：目录钮的吸附位置由它决定。
  final _titleKey = GlobalKey();
  double _titleH = 76;

  String _tab = 'all'; // all | ov | map | pt | todo | ft | src
  final Map<int, bool> _ptOpen = {};
  final Set<int> _todosDone = {};
  String? _hydratedSummaryId;
  int _todoMutationVersion = 0;

  @override
  void initState() {
    super.initState();
    _hydrateTodosFromMemoryAndPrefs(widget.summaryId);
  }

  @override
  void didUpdateWidget(covariant SummaryResultPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.summaryId != widget.summaryId) {
      _tab = 'all';
      _ptOpen.clear();
      _todosDone.clear();
      _hydratedSummaryId = null;
      _todoMutationVersion++;
      _memo = null;
      _hydrateTodosFromMemoryAndPrefs(widget.summaryId);
    }
  }

  _SummaryMemo _ensureMemo(AppStore store, SummaryCard card) {
    final key = (
      card.id,
      card.state,
      card.title,
      card.subDesc,
      card.srcIds.length,
      card.points.length,
      card.structure.length,
      identityHashCode(card),
      store.dataRevision,
    );
    final cached = _memo;
    if (cached != null && cached.key == key) return cached;

    final allPhotos = _ResultView._allActivePhotos(store, card);
    final leafMatches = _ResultView._leafPhotoMatches(card, allPhotos);
    final pointPhotos = [
      for (final pt in card.points) _ResultView._photosForPoint(store, pt),
    ];
    final sourceEvents = [
      for (final id in card.srcIds) ?store.eventByIdOrNull(id),
    ];
    final sourcePhotoCounts = <String, int>{
      for (final e in sourceEvents) e.id: store.activePhotosForEvent(e).length,
    };
    final orderedSourceEvents = sortEventsChronological(sourceEvents);
    final mergedFullTextSections =
        _ResultView._buildMergedFullTextSections(store, orderedSourceEvents);
    final fullText = card.resolvedFullText(
      sourceEvents,
      speakerResolver: store.displaySpeaker,
      turnSpeakerResolver: store.displayTurnSpeaker,
      preferResolvedTurns: store.hasTurnOverridesFor(sourceEvents),
      aliasTextTransformer: store.applySpeakerAliasesToText,
    );
    final subDescText = _ResultView._resolvedSubDesc(card, allPhotos.length);

    final built = _SummaryMemo(
      key: key,
      allPhotos: allPhotos,
      leafMatches: leafMatches,
      pointPhotos: pointPhotos,
      sourceEvents: sourceEvents,
      sourcePhotoCounts: sourcePhotoCounts,
      orderedSourceEvents: orderedSourceEvents,
      mergedFullTextSections: mergedFullTextSections,
      fullText: fullText,
      subDescText: subDescText,
    );
    _memo = built;
    return built;
  }

  void _hydrateTodosFromMemoryAndPrefs(String summaryId) {
    if (_memoryCheckedTodos.containsKey(summaryId)) {
      _todosDone
        ..clear()
        ..addAll(_memoryCheckedTodos[summaryId]!);
    }
    unawaited(_loadTodosFromPrefs(summaryId, _todoMutationVersion));
  }

  Future<void> _loadTodosFromPrefs(String summaryId, int versionAtStart) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _prefsTodoKey(summaryId);
      if (!prefs.containsKey(key)) return;
      final saved = prefs.getStringList(key) ?? const <String>[];
      if (!mounted ||
          widget.summaryId != summaryId ||
          _todoMutationVersion != versionAtStart) {
        return;
      }
      final parsed = <int>{
        for (final s in saved)
          if (int.tryParse(s) != null) int.parse(s),
      };
      final store = StoreScope.of(context);
      setState(() {
        // SharedPreferences 中显式保存的列表（含空列表 []）为权威状态，直接覆盖而非合并旧值
        _todosDone
          ..clear()
          ..addAll(parsed);
        _memoryCheckedTodos[summaryId] = Set<int>.from(_todosDone);
        final card = store.summaryById(summaryId);
        if (card != null) {
          card.checkedTodos = Set<int>.from(_todosDone);
        }
      });
    } on Object {
      // 无插件环境降级使用内存与 SummaryCard.checkedTodos
    }
  }

  void _syncTodosWithCard(SummaryCard card) {
    if (_memoryCheckedTodos.containsKey(card.id)) {
      final authoritative = _memoryCheckedTodos[card.id]!;
      _todosDone
        ..clear()
        ..addAll(authoritative);
      card.checkedTodos = Set<int>.from(authoritative);
      _hydratedSummaryId = card.id;
      return;
    }
    if (_hydratedSummaryId != card.id) {
      _hydratedSummaryId = card.id;
      _todosDone
        ..clear()
        ..addAll(card.checkedTodos);
    }
  }

  Set<int> checkedTodosFor(SummaryCard card) {
    _syncTodosWithCard(card);
    return _todosDone;
  }

  void _measureTitle() {
    final ctx = _titleKey.currentContext;
    if (!mounted || ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final h = box.size.height;
    if ((h - _titleH).abs() > 0.5) setState(() => _titleH = h);
  }

  @override
  void dispose() {
    _fallbackScroll.dispose();
    super.dispose();
  }

  void _setTab(String k) {
    final pointCount =
        StoreScope.of(context).summaryById(widget.summaryId)?.points.length ?? 0;
    setState(() {
      _tab = k;
      // 与原型一致：切 Tab 时重置全部信息点展开态（「信息点」默认全开，其余默认全收）
      _ptOpen
        ..clear()
        ..addAll({for (var i = 0; i < pointCount; i++) i: k == 'pt'});
    });
  }

  // 供子组件调用的公开变更入口（避免跨类调用受保护的 setState）
  void togglePoint(int i) =>
      setState(() => _ptOpen[i] = !(_ptOpen[i] ?? (_tab == 'pt')));

  void toggleTodo(int i, SummaryCard card) {
    setState(() {
      _todoMutationVersion++;
      _syncTodosWithCard(card);
      if (_todosDone.contains(i)) {
        _todosDone.remove(i);
      } else {
        _todosDone.add(i);
      }
      final snapshot = Set<int>.from(_todosDone);
      card.checkedTodos = snapshot;
      _memoryCheckedTodos[card.id] = snapshot;
      unawaited(_persistTodosToPrefs(card.id, snapshot));
    });
  }

  static Future<void> _persistTodosToPrefs(String cardId, Set<int> done) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sorted = done.toList()..sort();
      await prefs.setStringList(
        _prefsTodoKey(cardId),
        [for (final i in sorted) '$i'],
      );
    } on Object {
      // 无插件环境静默忽略
    }
  }

  void _cancelInFlight(AppStore store, SummaryCard card) {
    final customCancel = widget.onCancelGeneration;
    if (customCancel != null) {
      customCancel();
      return;
    }
    card.cancelled = true;
    store.cancelGeneratingSummary(card.id);
  }

  void _tocGo(String secId) {
    setState(() {
      _tab = 'all'; // 非「全部」时先切回「全部」再滚动
      _ptOpen.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _sectionKeys[secId]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          alignment: 0.1,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final rc = context.rc;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final card = store.summaryById(widget.summaryId);
        if (card == null) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showPaneBack)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('pb-sum'),
                  onPressed: store.goBack,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: Text(
                    '返回${AppStore.pageLabels[store.stackPrev?.type] ?? ''}',
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: rc.sec,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            if (card.state == SummaryState.generating)
              Expanded(
                child: _GenView(
                  store: store,
                  card: card,
                  onCancel: () => _cancelInFlight(store, card),
                ),
              )
            else if (card.state == SummaryState.done)
              Expanded(
                child: _ResultView(page: this, card: card),
              )
            else if (card.state == SummaryState.failed)
              Expanded(
                child: Center(
                  key: const Key('gen-failed'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.cloud_off_outlined,
                          size: 40,
                          color: rc.ax,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '总结没能生成',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: rc.label,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          card.error ?? '请稍后重试',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: rc.sec,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          key: const Key('gen-retry'),
                          onPressed: () => store.retryGeneration(card.id),
                          child: const Text('重试'),
                        ),
                        TextButton(
                          key: const Key('gen-dismiss'),
                          onPressed: () => store.dismissFailed(card.id),
                          child: const Text('放弃这次总结'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 生成态：进度条 + 已生成 X 秒 / 预计还需 Y 秒 + 当前步骤 + 取消按钮
class _GenView extends StatelessWidget {
  const _GenView({
    required this.store,
    required this.card,
    required this.onCancel,
  });

  final AppStore store;
  final SummaryCard card;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 6,
                child: LinearProgressIndicator(
                  key: const Key('gen-bar'),
                  value: card.progress / 100,
                  minHeight: 6,
                  backgroundColor: rc.sep,
                  valueColor: AlwaysStoppedAnimation(rc.ok),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  store.genElapsedText(),
                  key: const Key('gen-elapsed'),
                  style: TextStyle(fontSize: 13, color: rc.ink),
                ),
                Text(
                  store.genEtaText(),
                  key: const Key('gen-eta'),
                  style: TextStyle(fontSize: 13, color: rc.sec),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              store.genStepText(),
              key: const Key('gen-step'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: rc.label,
              ),
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.center,
              child: TextButton(
                key: const Key('gen-cancel'),
                onPressed: onCancel,
                style: TextButton.styleFrom(
                  foregroundColor: rc.sec,
                  textStyle: const TextStyle(fontSize: 13),
                ),
                child: const Text('取消生成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 结果态：标题 + 统计行 + 吸顶 Tab 栏 + 分节内容 + 目录浮钮 + 导出
class _ResultView extends StatelessWidget {
  const _ResultView({required this.page, required this.card});
  final _SummaryResultPageState page;
  final SummaryCard card;

  static const _tabs = [
    ('all', '全部'),
    ('ov', '概览'),
    ('map', '逻辑结构'),
    ('pt', '信息点'),
    ('todo', '行动项'),
    ('ft', '全文'),
    ('src', '来源记录'),
  ];

  static String _resolvedSubDesc(SummaryCard card, int photoCount) {
    final base = (card.subDesc ?? '')
        .replaceAll(RegExp(r'\s*·\s*含\s*\d+\s*张图片'), '')
        .trim();
    if (photoCount <= 0) return base;
    return base.isEmpty ? '含 $photoCount 张图片' : '$base · 含 $photoCount 张图片';
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final rc = context.rc;
    final memo = page._ensureMemo(store, card);
    final subDescText = memo.subDescText;
    // 每个 SummaryResultPageState 持有独立截图 GlobalKey，防止路由切换动画双实例挂载冲突
    _exportCaptureKey = page._captureKey;
    WidgetsBinding.instance.addPostFrameCallback((_) => page._measureTitle());
    final primaryCtrl = PrimaryScrollController.maybeOf(context);
    final scrollCtrl = primaryCtrl ?? page._fallbackScroll;
    return Stack(
      children: [
        RepaintBoundary(
          key: page._captureKey,
          child: CustomScrollView(
            key: const Key('sum-scroll'),
            primary: primaryCtrl != null,
            controller: primaryCtrl != null ? null : page._fallbackScroll,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  key: page._titleKey,
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              card.title ?? '',
                              key: const Key('sum-title'),
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: rc.label,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subDescText,
                              key: const Key('sum-sub'),
                              style: TextStyle(
                                fontSize: 12,
                                color: rc.sec,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _ExportButton(
                        card: card,
                        captureKey: page._captureKey,
                        exportService: page.widget.exportService,
                      ),
                    ],
                  ),
                ),
              ),
              // 吸顶 Tab 栏：滚动中持续可见
              SliverPersistentHeader(
                key: const Key('stickbar'),
                pinned: true,
                delegate: _StickyTabs(
                  tabs: _tabs,
                  current: page._tab,
                  onTap: page._setTab,
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  22,
                  6,
                  22,
                  RCDims.pageBottomPad,
                ),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _sections(context, store, memo),
                    ),
                    childCount: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
        // 目录浮钮：仅自身随滚动位移，不重建 CustomScrollView 与分节内容
        Positioned(
          top: 0,
          right: 8,
          child: AnimatedBuilder(
            animation: scrollCtrl,
            child: RepaintBoundary(child: _TocButton(onGo: page._tocGo)),
            builder: (context, child) {
              final offset = scrollCtrl.positions.length == 1
                  ? scrollCtrl.position.pixels
                  : 0.0;
              final natural = page._titleH + _kTabsH - offset + 10;
              final tocTop = math.max(_kTabsH + 10, natural);
              return Transform.translate(
                offset: Offset(0, tocTop),
                child: child,
              );
            },
          ),
        ),
      ],
    );
  }

  static List<_ContextualPhoto> _allActivePhotos(
    AppStore store,
    SummaryCard card,
  ) {
    final out = <_ContextualPhoto>[];
    final seen = <String>{};
    for (final id in card.srcIds) {
      if (!seen.add(id)) continue;
      final e = store.eventByIdOrNull(id);
      if (e == null) continue;
      for (final p in store.activePhotosForEvent(e)) {
        out.add((event: e, photo: p));
      }
    }
    return out;
  }

  static List<_ContextualPhoto> _photosForPoint(
    AppStore store,
    InfoPoint point,
  ) {
    final out = <_ContextualPhoto>[];
    final seen = <String>{};
    for (final s in point.sources) {
      final e = store.eventByIdOrNull(s.eventId);
      if (e == null) continue;
      final active = store.activePhotosForEvent(e);
      if (active.isEmpty) continue;
      final window = _parseClockWindow(s.range) ?? _parseClockWindow(e.srcMap);
      final List<EventPhoto> chosen;
      if (window == null) {
        chosen = active;
      } else {
        final hasAnyClock = active.any((p) => _clockSeconds(p.time) != null);
        if (!hasAnyClock) {
          chosen = active;
        } else {
          chosen = active
              .where((p) {
                final sec = _clockSeconds(p.time);
                return sec != null && _isClockInWindow(sec, window);
              })
              .toList();
        }
      }
      for (final p in chosen) {
        final key = '${e.id}:${p.id}';
        if (seen.add(key)) {
          out.add((event: e, photo: p));
        }
      }
    }
    return out;
  }

  static Map<String, _ContextualPhoto> _leafPhotoMatches(
    SummaryCard card,
    List<_ContextualPhoto> allPhotos,
  ) {
    final map = <String, _ContextualPhoto>{};
    if (allPhotos.isEmpty || card.structure.isEmpty) return map;

    // 收集每张活跃照片对应的语义锚文本（所属记录标题/摘要 + 关联信息点标题/细节）
    final anchors = <({
      _ContextualPhoto item,
      String corpus,
    })>[];
    for (final item in allPhotos) {
      final evWindow =
          _parseClockWindow('${item.event.time} · ${item.event.dur}') ??
          _parseClockWindow(item.event.srcMap);
      final pSec = _clockSeconds(item.photo.time);
      if (evWindow != null &&
          pSec != null &&
          !_isClockInWindow(pSec, evWindow)) {
        continue;
      }
      final buf = StringBuffer()
        ..write(item.event.title)
        ..write(' ')
        ..write(item.event.brief)
        ..write(' ')
        ..write(item.event.longText);
      for (final pt in card.points) {
        if (pt.sources.any((s) => s.eventId == item.event.id)) {
          buf
            ..write(' ')
            ..write(pt.title)
            ..write(' ')
            ..write(pt.detail);
        }
      }
      anchors.add((item: item, corpus: buf.toString()));
    }

    for (var bi = 0; bi < card.structure.length; bi++) {
      final b = card.structure[bi];
      for (var li = 0; li < b.leaves.length; li++) {
        final leaf = b.leaves[li];
        final probe = '${b.name} $leaf';
        _ContextualPhoto? best;
        var bestScore = 0;
        for (final a in anchors) {
          final score = _cjkBigramOverlap(probe, a.corpus);
          if (score > bestScore) {
            bestScore = score;
            best = a.item;
          }
        }
        if (best != null && bestScore >= 1) {
          map['$bi:$li'] = best;
        }
      }
    }
    return map;
  }

  static int _cjkBigramOverlap(String a, String b) {
    final cleanA = a.replaceAll(RegExp(r'[\s·，。、：；！？（）()\-—/]'), '');
    if (cleanA.length < 2) return 0;
    var hits = 0;
    for (var i = 0; i <= cleanA.length - 2; i++) {
      final gram = cleanA.substring(i, i + 2);
      if (b.contains(gram)) hits++;
    }
    return hits;
  }

  static (int, int)? _parseClockWindow(String raw) => parseSourceClockWindow(raw);

  static bool _isClockInWindow(int sec, (int, int) window) =>
      isClockSecondInWindow(sec, window);

  static int? _clockSeconds(String raw) {
    final m = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(raw);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!) ?? 0;
    final min = int.tryParse(m.group(2)!) ?? 0;
    final sec = int.tryParse(m.group(3) ?? '0') ?? 0;
    return h * 3600 + min * 60 + sec;
  }

  String _mindMapRootLabel(AppStore store, List<RecordEvent> sourceEvents) {
    final raw = (card.title ?? '').trim();
    if (raw.isEmpty) return '核心脉络';
    final resolved = store.applySpeakerAliasesToText(raw, sourceEvents).trim();
    if (resolved.isEmpty || resolved == '核心脉络') return '核心脉络';
    return '核心脉络 · $resolved';
  }

  List<Widget> _sections(
    BuildContext context,
    AppStore store,
    _SummaryMemo memo,
  ) {
    final rc = context.rc;
    bool show(String k) => page._tab == 'all' || page._tab == k;
    final allPhotos = memo.allPhotos;
    final leafMatches = memo.leafMatches;
    final sourceEvents = memo.sourceEvents;
    final orderedSourceEvents = memo.orderedSourceEvents;
    final fullText = memo.fullText;
    final doneSet = page.checkedTodosFor(card);
    final doneCount = doneSet
        .where((idx) => idx >= 0 && idx < card.todos.length)
        .length;

    return [
      if (show('ov') || show('ft'))
        SpeakerSuggestionBanner(
          store: store,
          eventIds: card.srcIds,
          margin: const EdgeInsets.only(bottom: 14),
        ),
      if (show('ov'))
        _section(context, 'sec-ov', '概览', [
          Text(
            store.applySpeakerAliasesToText(card.overview ?? '', sourceEvents),
            style: TextStyle(fontSize: 14, height: 1.6, color: rc.ink),
          ),
          if (allPhotos.isNotEmpty) ...[
            const SizedBox(height: 10),
            _InlineSummaryFigure(
              key: const Key('sum-ov-inline-photo'),
              item: allPhotos.first,
              onOpenDetail: () => store.openDetail(allPhotos.first.event.id),
            ),
          ],
        ]),
      if (show('map'))
        _section(context, 'sec-map', '逻辑结构', [
          _MapTree(
            rootLabel: _mindMapRootLabel(store, sourceEvents),
            branches: card.structure,
            leafPhotos: leafMatches,
            onOpenDetail: store.openDetail,
          ),
        ]),
      if (show('pt'))
        _section(context, 'sec-pt', '信息点', [
          for (var i = 0; i < card.points.length; i++)
            _PointTile(
              page: page,
              index: i,
              point: card.points[i],
              photos: memo.pointPhotos[i],
              sourceEvents: sourceEvents,
            ),
        ]),
      if (show('todo'))
        _section(context, 'sec-todo', '行动项', [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              '已完成 $doneCount / ${card.todos.length}',
              key: const Key('ix-done'),
              style: TextStyle(fontSize: 12, color: rc.sec),
            ),
          ),
          for (var i = 0; i < card.todos.length; i++)
            InkWell(
              key: Key('todo-$i'),
              onTap: () => page.toggleTodo(i, card),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      doneSet.contains(i)
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 20,
                      color: doneSet.contains(i) ? rc.ok : rc.ax,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        store.applySpeakerAliasesToText(
                          card.todos[i],
                          sourceEvents,
                        ),
                        style: TextStyle(fontSize: 14, color: rc.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ]),
      if (show('ft'))
        _section(context, 'sec-ft', '全文', [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'AI 智能优化版 · 保持原意并去除口水词与错别字（点击说话人可快捷命名）',
              style: TextStyle(fontSize: 12, color: rc.sec),
            ),
          ),
          Container(
            key: const Key('sum-fulltext-body'),
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: rc.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: rc.sep),
            ),
            child: _buildMergedFullTextContent(
              context,
              store,
              memo.mergedFullTextSections,
              multipleEvents: orderedSourceEvents.length > 1,
              fallbackText: fullText,
            ),
          ),
        ]),
      if (show('src'))
        _section(context, 'sec-src', '来源记录', [
          for (final id in card.srcIds)
            Builder(
              builder: (context) {
                final srcRc = context.rc;
                final e = store.eventByIdOrNull(id);
                if (e == null) return const SizedBox.shrink();
                final picCount = memo.sourcePhotoCounts[e.id] ?? 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: srcRc.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: srcRc.sep),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: Key('src-$id'),
                      onTap: () => store.openDetail(id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    e.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: srcRc.label,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: srcRc.ax,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '${_dayLabel(e.dayOffset)} ${e.time} · ${e.dur}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: srcRc.sec,
                                    ),
                                  ),
                                ),
                                if (picCount > 0) ...[
                                  Text(
                                    ' · ',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: srcRc.sec,
                                    ),
                                  ),
                                  Text(
                                    '含 $picCount 张图片',
                                    key: Key('src-piccount-$id'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: srcRc.sec,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ]),
    ];
  }

  static String _dayLabel(int off) {
    if (off == 0) return '今天';
    if (off == 1) return '昨天';
    final d = DateTime.now().subtract(Duration(days: off));
    const dow = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${d.month}月${d.day}日 ${dow[d.weekday - 1]}';
  }

  Widget _section(
    BuildContext context,
    String keyName,
    String title,
    List<Widget> children,
  ) {
    final rc = context.rc;
    final gk = page._sectionKeys.putIfAbsent(keyName, () => GlobalKey());
    return Container(
      key: Key(keyName),
      child: Column(
        key: gk,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 10),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: rc.label,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  static List<_FullTextEventSectionData> _buildMergedFullTextSections(
    AppStore store,
    List<RecordEvent> orderedEvents,
  ) {
    final sections = <_FullTextEventSectionData>[];
    for (final e in orderedEvents) {
      if (isSilentPlaceholderEvent(e)) continue;
      final turns = e.dialog.isNotEmpty ? e.dialog : e.raw;
      final groups = <_FullTextGroupData>[];

      String? curSpk;
      var curRaw = '';
      var curFirstIdx = 0;
      var curSample = '';
      var curText = '';

      void flushGroup() {
        if (curSpk == null || curText.trim().isEmpty) return;
        groups.add(
          _FullTextGroupData(
            resolvedSpeaker: curSpk,
            rawSpeaker: curRaw,
            firstTurnIndex: curFirstIdx,
            sampleQuote: curSample,
            joinedText: curText,
          ),
        );
      }

      for (var ti = 0; ti < turns.length; ti++) {
        final t = turns[ti];
        final cleaned = cleanSpokenFillers(t.text);
        if (cleaned.isEmpty) continue;
        final resolved = store
            .displayTurnSpeaker(e, ti, t.spk, includeGuessSuffix: false)
            .trim();
        final effective = resolved.isEmpty ? '未区分' : resolved;
        if (effective == curSpk) {
          curText = joinPolishedUtterances(curText, cleaned);
        } else {
          flushGroup();
          curSpk = effective;
          curRaw = t.spk;
          curFirstIdx = ti;
          curSample = t.text;
          curText = cleaned;
        }
      }
      flushGroup();

      final fallback = (e.longText.trim().isNotEmpty ? e.longText : e.brief)
          .trim();
      if (groups.isEmpty && fallback.isEmpty) continue;
      sections.add(
        _FullTextEventSectionData(
          event: e,
          groups: groups,
          fallback: fallback,
        ),
      );
    }
    return sections;
  }

  Widget _buildMergedFullTextContent(
    BuildContext context,
    AppStore store,
    List<_FullTextEventSectionData> sections, {
    required bool multipleEvents,
    required String fallbackText,
  }) {
    final rc = context.rc;
    if (sections.isEmpty) {
      final t = fallbackText.trim();
      return SelectableText(
        t.isNotEmpty ? t : '暂无可拼接的来源转写文本',
        style: TextStyle(
          fontSize: 14,
          height: 1.65,
          color: t.isNotEmpty ? rc.ink : rc.sec,
        ),
      );
    }

    final widgets = <Widget>[];
    for (final sec in sections) {
      final e = sec.event;
      final groups = sec.groups;

      if (multipleEvents) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              '【${e.time} · ${e.title}】',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: rc.sec,
              ),
            ),
          ),
        );
      }

      if (groups.isEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SelectableText(
              sec.fallback,
              style: TextStyle(
                fontSize: 14,
                height: 1.65,
                color: rc.ink,
              ),
            ),
          ),
        );
        continue;
      }

      for (var gi = 0; gi < groups.length; gi++) {
        final g = groups[gi];
        final canTap = g.rawSpeaker.trim() != '无语音';
        widgets.add(
          Padding(
            key: Key('sum-ft-group-${e.id}-$gi'),
            padding: EdgeInsets.only(bottom: gi == groups.length - 1 ? 4 : 10),
            child: Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 14,
                  height: 1.65,
                  color: rc.ink,
                ),
                children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: GestureDetector(
                        key: Key('sum-ft-who-${e.id}-$gi'),
                        onTap: canTap
                            ? () => showQuickSpeakerSheet(
                                context,
                                store: store,
                                event: e,
                                turnIndex: g.firstTurnIndex,
                                rawSpeaker: g.rawSpeaker,
                                sampleQuote: g.sampleQuote,
                              )
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: rc.bg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: rc.sep),
                          ),
                          child: Text(
                            () {
                              if (!canTap) return g.resolvedSpeaker;
                              final cand = store
                                  .pendingCandidateNameForEventSlot(
                                    e,
                                    g.rawSpeaker,
                                    turnIndex: g.firstTurnIndex,
                                  );
                              if (cand != null && cand.isNotEmpty) {
                                return '${g.resolvedSpeaker} · 疑似$cand?';
                              }
                              return g.resolvedSpeaker;
                            }(),
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: canTap ? rc.okInk : rc.sec,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  TextSpan(text: '：${g.joinedText}'),
                ],
              ),
            ),
          ),
        );
      }
    }

    if (widgets.isEmpty) {
      final t = fallbackText.trim();
      return SelectableText(
        t.isNotEmpty ? t : '暂无可拼接的来源转写文本',
        style: TextStyle(
          fontSize: 14,
          height: 1.65,
          color: t.isNotEmpty ? rc.ink : rc.sec,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

/// 导出按钮：专用 GlobalKey 作为 iPadOS 系统分享面板锚点（全部 4 种格式统一传递）。
class _ExportButton extends StatefulWidget {
  const _ExportButton({
    required this.card,
    this.captureKey,
    this.exportService,
  });

  final SummaryCard card;
  final GlobalKey? captureKey;
  final ExportService? exportService;

  @override
  State<_ExportButton> createState() => _ExportButtonState();
}

typedef _ExportPick = ({
  String label,
  ExportFormat format,
  TranscriptExportMode mode,
});

class _ExportButtonState extends State<_ExportButton> {
  final GlobalKey _shareButtonKey = GlobalKey(
    debugLabel: 'sum-export-btn-anchor',
  );
  bool _busy = false;

  static const _formats = <({
    String label,
    String desc,
    ExportFormat format,
    IconData icon,
  })>[
    (
      label: 'PDF',
      desc: 'A4 排版 · 含第一部分图文纪要与第二部分文字记录',
      format: ExportFormat.pdf,
      icon: Icons.picture_as_pdf_outlined,
    ),
    (
      label: 'Word 文档',
      desc: '.doc 文档 · Word / WPS / Pages 均可打开',
      format: ExportFormat.word,
      icon: Icons.description_outlined,
    ),
    (
      label: 'Markdown',
      desc: '纯文本标记 · 含场景图引用与完整记录',
      format: ExportFormat.markdown,
      icon: Icons.article_outlined,
    ),
    (
      label: '图片',
      desc: '完整长图 PNG · 图文纪要与文字记录一图输出',
      format: ExportFormat.image,
      icon: Icons.image_outlined,
    ),
  ];

  Rect? _computeShareOrigin() {
    final ctx = _shareButtonKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return KeyedSubtree(
      key: _shareButtonKey,
      child: TextButton(
        key: const Key('export-btn'),
        onPressed: _busy ? null : () => _open(context),
        style: TextButton.styleFrom(
          foregroundColor: rc.label,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          minimumSize: Size.zero,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        child: _busy
            ? const SizedBox(
                key: Key('export-busy'),
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('导出'),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final store = StoreScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final initialAnchorRect = _computeShareOrigin();
    var mode = TranscriptExportMode.aiOptimized;

    final picked = await showModalBottomSheet<_ExportPick>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: context.rc.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          return ListenableBuilder(
            listenable: store,
            builder: (sheetCtx, _) {
              final sheetRc = sheetCtx.rc;
              return SafeArea(
                top: false,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85,
                  ),
                  child: SingleChildScrollView(
                    key: const Key('export-sheet'),
                    primary: false,
                    padding: const EdgeInsets.fromLTRB(
                      16,
                      12,
                      16,
                      16 + RCDims.pageBottomPad,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '导出完整内容',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: sheetRc.label,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.pop(sheetCtx),
                              icon: Icon(
                                Icons.close,
                                size: 20,
                                color: sheetRc.sec,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '均含第一部分「图文纪要」与第二部分「文字记录」',
                          style: TextStyle(fontSize: 12, color: sheetRc.sec),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '文字记录版本',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: sheetRc.sec,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            for (final entry in const [
                              (
                                mode: TranscriptExportMode.aiOptimized,
                                key: Key('export-mode-ai'),
                                label: 'AI 智能优化版',
                              ),
                              (
                                mode: TranscriptExportMode.rawOriginal,
                                key: Key('export-mode-raw'),
                                label: '原文',
                              ),
                            ]) ...[
                              Expanded(
                                child: InkWell(
                                  key: entry.key,
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () =>
                                      setSheetState(() => mode = entry.mode),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: mode == entry.mode
                                          ? sheetRc.ok.withValues(alpha: 0.14)
                                          : sheetRc.bg,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: mode == entry.mode
                                            ? sheetRc.ok
                                            : sheetRc.sep,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      entry.label,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: mode == entry.mode
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: mode == entry.mode
                                            ? sheetRc.okInk
                                            : sheetRc.ink,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (entry.mode == TranscriptExportMode.aiOptimized)
                                const SizedBox(width: 8),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '选择导出格式',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: sheetRc.sec,
                          ),
                        ),
                        const SizedBox(height: 6),
                        for (final f in _formats)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Material(
                              color: sheetRc.bg,
                              borderRadius: BorderRadius.circular(10),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                key: Key('export-item-${f.label}'),
                                onTap: () => Navigator.pop(
                                  sheetCtx,
                                  (
                                    label: f.label,
                                    format: f.format,
                                    mode: mode,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        f.icon,
                                        size: 18,
                                        color: sheetRc.ink,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              f.label,
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                color: sheetRc.label,
                                              ),
                                            ),
                                            Text(
                                              f.desc,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: sheetRc.sec,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Icon(
                                        Icons.chevron_right,
                                        size: 18,
                                        color: sheetRc.sec,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
    if (picked == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final sourceEvents = [
        for (final id in widget.card.srcIds) ?store.eventByIdOrNull(id),
      ];
      final doc = exportDocumentFromSummary(
        widget.card,
        sourceEvents: sourceEvents,
        transcriptMode: picked.mode,
        photosResolver: (ev) => [
          for (final p in store.activePhotosForEvent(ev))
            ExportImageItem(
              path: p.path,
              caption: '${ev.title} · 现场照片（${p.time}）',
            ),
        ],
        speakerResolver: store.displaySpeaker,
        turnSpeakerResolver: store.displayTurnSpeaker,
        preferResolvedTurns: store.hasTurnOverridesFor(sourceEvents),
        aliasTextTransformer: store.applySpeakerAliasesToText,
      );
      final captureKey = picked.format == ExportFormat.image
          ? (widget.captureKey ?? captureKeyForExport())
          : null;
      final shareOrigin = _computeShareOrigin() ?? initialAnchorRect;
      final service = widget.exportService ?? ExportService();
      final result = await service.export(
        picked.format,
        doc,
        captureKey: captureKey,
        shareAnchorKey: _shareButtonKey,
        sharePositionOrigin: shareOrigin,
      );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              '已生成 ${picked.label}（${picked.mode.label}）· 调起系统分享：${result.path.split('/').last}',
              key: const Key('toast'),
            ),
            duration: const Duration(milliseconds: 2000),
          ),
        );
    } on Object catch (e) {
      final message = e is ExportException ? e.message : '导出失败：$e';
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message, key: const Key('toast-error')),
            duration: const Duration(seconds: 3),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 图片导出的截图锚点：由 `_ResultView` 提供（包住可滚动内容）。
GlobalKey? _exportCaptureKey;
GlobalKey? captureKeyForExport() => _exportCaptureKey;

/// 吸顶 Tab 栏：文字不换行，宽度不足时横向滑动；目录浮钮另钉于栏下内容区。
class _StickyTabs extends SliverPersistentHeaderDelegate {
  _StickyTabs({required this.tabs, required this.current, required this.onTap});

  final List<(String, String)> tabs;
  final String current;
  final void Function(String) onTap;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final rc = context.rc;
    return Container(
      key: const Key('stabs'),
      decoration: BoxDecoration(
        color: rc.bg,
        border: Border(bottom: BorderSide(color: rc.sep)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                key: const Key('stab-strip'),
                scrollDirection: Axis.horizontal,
                primary: false,
                child: Row(
                  children: [
                    for (final (k, label) in tabs)
                      Padding(
                        padding: const EdgeInsets.only(right: 18),
                        child: TextButton(
                          key: Key('stab-$k'),
                          onPressed: () => onTap(k),
                          style: TextButton.styleFrom(
                            foregroundColor: current == k ? rc.label : rc.sec,
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            label,
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: current == k
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  double get minExtent => 46;
  @override
  double get maxExtent => 46;
  @override
  bool shouldRebuild(_StickyTabs old) =>
      old.current != current || old.tabs != tabs;
}

typedef _ContextualPhoto = ({RecordEvent event, EventPhoto photo});

void _showInlinePhotoPreview(
  BuildContext context,
  _ContextualPhoto item,
  VoidCallback onOpenDetail,
) {
  final p = item.photo;
  final srcLabel = p.source == 'dyj_camera' ? '点一机抓拍' : '系统相册';
  String? quote;
  if (item.event.dialog.isNotEmpty) {
    final first = item.event.dialog.first;
    final store = StoreScope.of(context);
    quote = '${store.displaySpeaker(item.event, first.spk)}：${first.text}';
  }
  showPhotoPreviewSheet(
    context,
    photo: p,
    title: '${item.event.title} · ${p.time}',
    subtitle: srcLabel,
    quoteText: quote,
    onJumpToDialog: onOpenDetail,
  );
}

/// 穿插在概览或信息点正文中的自然插图：像段落补充一样融入阅读流，点击看大图或溯源原话。
class _InlineSummaryFigure extends StatelessWidget {
  const _InlineSummaryFigure({
    super.key,
    required this.item,
    required this.onOpenDetail,
  });

  final _ContextualPhoto item;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final p = item.photo;
    final srcLabel = p.source == 'dyj_camera' ? '点一机抓拍' : '系统相册';
    return Material(
      color: rc.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: rc.sep),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showInlinePhotoPreview(context, item, onOpenDetail),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: PhotoThumbnail(
                    path: p.path,
                    logicalWidth: 56,
                    source: p.source,
                    placeholderIconSize: 20,
                    placeholderColor: rc.sep,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.event.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: rc.label,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$srcLabel · ${p.time}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: rc.sec,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onOpenDetail,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Text(
                    '原话 ›',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: rc.okInk,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 逻辑结构：自适应标题根节点 + 分支 + 叶子（仅当真实语义命中现场图时附带图片图标）
class _MapTree extends StatelessWidget {
  const _MapTree({
    required this.rootLabel,
    required this.branches,
    this.leafPhotos = const {},
    required this.onOpenDetail,
  });

  final String rootLabel;
  final List<MapBranch> branches;
  final Map<String, _ContextualPhoto> leafPhotos;
  final void Function(String eventId) onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: rc.ok.withValues(alpha: rc.isDark ? 0.18 : 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            rootLabel,
            key: const Key('map-root-label'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: rc.okInk,
            ),
          ),
        ),
        const SizedBox(height: 10),
        for (var bi = 0; bi < branches.length; bi++)
          Padding(
            padding: const EdgeInsets.only(left: 10, bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(width: 2, height: 14, color: rc.ax),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        branches[bi].name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: rc.label,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (var li = 0; li < branches[bi].leaves.length; li++)
                        _buildLeafChip(
                          context,
                          branches[bi].leaves[li],
                          leafPhotos['$bi:$li'],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildLeafChip(
    BuildContext context,
    String leaf,
    _ContextualPhoto? match,
  ) {
    final rc = context.rc;
    if (match == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: rc.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: rc.sep),
        ),
        child: Text(
          leaf,
          style: TextStyle(fontSize: 12, color: rc.ink),
        ),
      );
    }
    return Material(
      color: rc.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: rc.sep),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('mleaf-pic-${match.event.id}-${match.photo.id}'),
        onTap: () => _showInlinePhotoPreview(
          context,
          match,
          () => onOpenDetail(match.event.id),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  leaf,
                  style: TextStyle(fontSize: 12, color: rc.ink),
                ),
              ),
              const SizedBox(width: 5),
              Icon(Icons.image_outlined, size: 13.5, color: rc.sec),
            ],
          ),
        ),
      ),
    );
  }
}

/// 信息点：标题（含关联图小标）+ 细节 + 正文内穿插配图 + 溯源链接（可展开收起）
class _PointTile extends StatelessWidget {
  const _PointTile({
    required this.page,
    required this.index,
    required this.point,
    this.photos = const [],
    this.sourceEvents = const [],
  });
  final _SummaryResultPageState page;
  final int index;
  final InfoPoint point;
  final List<_ContextualPhoto> photos;
  final List<RecordEvent> sourceEvents;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final rc = context.rc;
    final open = page._ptOpen[index] ?? (page._tab == 'pt');
    return Container(
      key: Key('pt-$index'),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: rc.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: rc.sep),
      ),
      child: Column(
        children: [
          InkWell(
            key: Key('pt-h-$index'),
            onTap: () => page.togglePoint(index),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      store.applySpeakerAliasesToText(
                        point.title,
                        sourceEvents,
                      ),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: rc.label,
                      ),
                    ),
                  ),
                  if (photos.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.image_outlined,
                      key: Key('pt-picico-$index'),
                      size: 15,
                      color: rc.sec,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: rc.sec,
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    store.applySpeakerAliasesToText(
                      point.detail,
                      sourceEvents,
                    ),
                    key: Key('pt-d-$index'),
                    style: TextStyle(fontSize: 13, height: 1.6, color: rc.ink),
                  ),
                  if (photos.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Column(
                      key: Key('pt-figs-$index'),
                      children: [
                        for (var pi = 0; pi < photos.length; pi++)
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: pi < photos.length - 1 ? 8 : 0,
                            ),
                            child: _InlineSummaryFigure(
                              key: Key(
                                'sum-pt-photo-${photos[pi].event.id}-${photos[pi].photo.id}',
                              ),
                              item: photos[pi],
                              onOpenDetail: () =>
                                  store.openDetail(photos[pi].event.id),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in point.sources)
                        OutlinedButton(
                          key: Key('srcchip-${s.eventId}-${s.range}'),
                          onPressed: () => store.openDetail(s.eventId),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: rc.okInk,
                            side: BorderSide(color: rc.ok),
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          child: Text('↗ ${s.label} · ${s.range}'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 目录浮钮 + 弹层列表
class _TocButton extends StatelessWidget {
  const _TocButton({this.onGo});
  final void Function(String secId)? onGo;

  static const _items = [
    ('sec-ov', '概览'),
    ('sec-map', '逻辑结构'),
    ('sec-pt', '信息点'),
    ('sec-todo', '行动项'),
    ('sec-ft', '全文'),
    ('sec-src', '来源记录'),
  ];

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return OutlinedButton(
      key: const Key('toc-btn'),
      onPressed: () => _open(context),
      style: OutlinedButton.styleFrom(
        backgroundColor: rc.bg,
        foregroundColor: rc.label,
        side: BorderSide(color: rc.sep),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: Size.zero,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: const Text('目录'),
    );
  }

  void _open(BuildContext context) {
    final rc = context.rc;
    final box = context.findRenderObject() as RenderBox;
    final pos = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(const Offset(0, 44)),
        box.localToGlobal(box.size.bottomRight(const Offset(0, 44))),
      ),
      Offset.zero & MediaQuery.of(context).size,
    );
    showMenu<String>(
      context: context,
      color: rc.card,
      position: pos,
      items: [
        for (final (id, label) in _items)
          PopupMenuItem(
            value: id,
            child: Text(
              label,
              key: Key('toc-item-$id'),
              style: TextStyle(color: rc.label),
            ),
          ),
      ],
    ).then((v) {
      if (v != null) onGo?.call(v);
    });
  }
}
