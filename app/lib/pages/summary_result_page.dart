/// 总结结果页 —— 生成态（进度/已生成/预计还需/步骤）与结果态（吸顶 Tab + 目录浮钮 + 信息点溯源 + 导出）。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/models/summary.dart';
import '../core/store/app_store.dart';
import '../services/export/export.dart';
import '../core/theme/tokens.dart';
import '../widgets/store_scope.dart';

/// 吸顶 Tab 栏高度（原型 .stabs 行高 46）。
const double _kTabsH = 46;

class SummaryResultPage extends StatefulWidget {
  const SummaryResultPage({
    super.key,
    required this.summaryId,
    this.showPaneBack = false,
  });
  final String summaryId;
  final bool showPaneBack;

  @override
  State<SummaryResultPage> createState() => _SummaryResultPageState();
}

class _SummaryResultPageState extends State<SummaryResultPage> {
  final _scroll = ScrollController();
  final _sectionKeys = <String, GlobalKey>{};

  /// 结果态标题块（标题 + 统计行）的实测高度：目录钮的吸附位置由它决定。
  final _titleKey = GlobalKey();
  double _titleH = 76;

  void _measureTitle() {
    final ctx = _titleKey.currentContext;
    if (!mounted || ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final h = box.size.height;
    if ((h - _titleH).abs() > 0.5) setState(() => _titleH = h);
  }

  String _tab = 'all'; // all | ov | map | pt | todo | src
  final Map<int, bool> _ptOpen = {};
  final Set<int> _todosDone = {};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _setTab(String k) {
    setState(() {
      _tab = k;
      // 与原型一致：切 Tab 时重置信息点展开态（「信息点」默认全开，其余默认全收）
      _ptOpen
        ..clear()
        ..addAll({for (var i = 0; i < 4; i++) i: k == 'pt'});
    });
  }

  // 供子组件调用的公开变更入口（避免跨类调用受保护的 setState）
  void togglePoint(int i) =>
      setState(() => _ptOpen[i] = !(_ptOpen[i] ?? false));

  void toggleTodo(int i) => setState(
    () => _todosDone.contains(i) ? _todosDone.remove(i) : _todosDone.add(i),
  );

  void _tocGo(String secId) {
    setState(() => _tab = 'all'); // 非「全部」时先切回「全部」再滚动
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
                    foregroundColor: RCColors.sec,
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
                child: _GenView(store: store, card: card),
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
                        const Icon(
                          Icons.cloud_off_outlined,
                          size: 40,
                          color: RCColors.ax,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '总结没能生成',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          card.error ?? '请稍后重试',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 13,
                            color: RCColors.sec,
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

/// 生成态：进度条 + 已生成 X 秒 / 预计还需 Y 秒 + 当前步骤
class _GenView extends StatelessWidget {
  const _GenView({required this.store, required this.card});
  final AppStore store;
  final SummaryCard card;

  @override
  Widget build(BuildContext context) {
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
                  backgroundColor: RCColors.sep,
                  valueColor: const AlwaysStoppedAnimation(RCColors.ok),
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
                  style: const TextStyle(fontSize: 13, color: RCColors.ink),
                ),
                Text(
                  store.genEtaText(),
                  key: const Key('gen-eta'),
                  style: const TextStyle(fontSize: 13, color: RCColors.sec),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              store.genStepText(),
              key: const Key('gen-step'),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
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
    ('src', '来源记录'),
  ];

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    // 图片导出的截图锚点：每次构建复用同一个 GlobalKey（同屏只有一个结果页）
    _exportCaptureKey ??= GlobalKey(debugLabel: 'sum-export-capture');
    WidgetsBinding.instance.addPostFrameCallback((_) => page._measureTitle());
    // 原型 .stickbar + .tochold：目录钮是内容区里的 sticky 元素——未滚动时压在
    // 「概览」这一行右侧，向上滚动到与 Tab 栏同一卡点时跟 Tab 一起钉住
    // （距 Tab 栏下沿 10px），而不是永远钉在屏幕同一位置去盖住 Tab。
    return AnimatedBuilder(
      animation: page._scroll,
      builder: (context, _) {
        final offset = page._scroll.hasClients
            ? page._scroll.position.pixels
            : 0.0;
        final natural = page._titleH + _kTabsH - offset + 10;
        final tocTop = math.max(_kTabsH + 10, natural);
        return Stack(
          children: [
            RepaintBoundary(
              key: _exportCaptureKey,
              child: CustomScrollView(
                key: const Key('sum-scroll'),
                controller: page._scroll,
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
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  card.subDesc ?? '',
                                  key: const Key('sum-sub'),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: RCColors.sec,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _ExportButton(card: card),
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
                    padding: const EdgeInsets.fromLTRB(22, 6, 22, 96),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _sections(context, store),
                        ),
                        childCount: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 目录浮钮：随内容滚动，撞到吸顶栏下沿后与 Tab 栏同点吸附（各 Tab 均可用）
            Positioned(
              top: tocTop,
              right: 8,
              child: _TocButton(onGo: page._tocGo),
            ),
          ],
        );
      },
    );
  }

  List<_ContextualPhoto> _allActivePhotos(AppStore store) {
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
      final window = _parseClockWindow(s.range);
      final matched = window == null
          ? active
          : active
                .where((p) {
                  final sec = _clockSeconds(p.time);
                  return sec != null && sec >= window.$1 && sec <= window.$2;
                })
                .toList();
      final chosen = matched.isNotEmpty ? matched : [active.first];
      for (final p in chosen) {
        final key = '${e.id}:${p.id}';
        if (seen.add(key)) {
          out.add((event: e, photo: p));
        }
      }
    }
    return out;
  }

  Map<String, _ContextualPhoto> _leafPhotoMatches(
    AppStore store,
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
    if (map.isEmpty && card.structure.first.leaves.isNotEmpty) {
      map['0:0'] = allPhotos.first;
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

  static (int, int)? _parseClockWindow(String raw) {
    final matches = RegExp(
      r'(\d{1,2}):(\d{2})(?::(\d{2}))?',
    ).allMatches(raw).toList();
    if (matches.length < 2) return null;
    int toSec(RegExpMatch m, {required bool end}) {
      final h = int.tryParse(m.group(1)!) ?? 0;
      final min = int.tryParse(m.group(2)!) ?? 0;
      final sec = m.group(3) != null
          ? (int.tryParse(m.group(3)!) ?? 0)
          : (end ? 59 : 0);
      return h * 3600 + min * 60 + sec;
    }

    return (toSec(matches[0], end: false), toSec(matches[1], end: true));
  }

  static int? _clockSeconds(String raw) {
    final m = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(raw);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!) ?? 0;
    final min = int.tryParse(m.group(2)!) ?? 0;
    final sec = int.tryParse(m.group(3) ?? '0') ?? 0;
    return h * 3600 + min * 60 + sec;
  }

  List<Widget> _sections(BuildContext context, AppStore store) {
    bool show(String k) => page._tab == 'all' || page._tab == k;
    final allPhotos = _allActivePhotos(store);
    final leafMatches = _leafPhotoMatches(store, allPhotos);
    return [
      if (show('ov'))
        _section('sec-ov', '概览', [
          Text(
            card.overview ?? '',
            style: const TextStyle(fontSize: 14, height: 1.6),
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
        _section('sec-map', '逻辑结构', [
          _MapTree(
            branches: card.structure,
            leafPhotos: leafMatches,
            onOpenDetail: store.openDetail,
          ),
        ]),
      if (show('pt'))
        _section('sec-pt', '信息点', [
          for (var i = 0; i < card.points.length; i++)
            _PointTile(
              page: page,
              index: i,
              point: card.points[i],
              photos: _photosForPoint(store, card.points[i]),
            ),
        ]),
      if (show('todo'))
        _section('sec-todo', '行动项', [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              '已完成 ${page._todosDone.length} / ${card.todos.length}',
              key: const Key('ix-done'),
              style: const TextStyle(fontSize: 12, color: RCColors.sec),
            ),
          ),
          for (var i = 0; i < card.todos.length; i++)
            InkWell(
              key: Key('todo-$i'),
              onTap: () => page.toggleTodo(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      page._todosDone.contains(i)
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 20,
                      color: page._todosDone.contains(i)
                          ? RCColors.ok
                          : RCColors.ax,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        card.todos[i],
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ]),
      if (show('src'))
        _section('sec-src', '来源记录', [
          for (final id in card.srcIds)
            Builder(
              builder: (context) {
                final e = store.eventByIdOrNull(id);
                if (e == null) return const SizedBox.shrink();
                final picCount = store.activePhotosForEvent(e).length;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: RCColors.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: RCColors.sep),
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
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: RCColors.ax,
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
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: RCColors.sec,
                                    ),
                                  ),
                                ),
                                if (picCount > 0) ...[
                                  const Text(
                                    ' · ',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: RCColors.sec,
                                    ),
                                  ),
                                  Text(
                                    '含 $picCount 张图片',
                                    key: Key('src-piccount-$id'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: RCColors.sec,
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

  Widget _section(String keyName, String title, List<Widget> children) {
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
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// 导出按钮：菜单锚定在按钮自身位置；5 种格式 → 模拟调起系统分享
class _ExportButton extends StatefulWidget {
  const _ExportButton({required this.card});

  final SummaryCard card;

  @override
  State<_ExportButton> createState() => _ExportButtonState();
}

class _ExportButtonState extends State<_ExportButton> {
  bool _busy = false;

  static const _formats = <String, ExportFormat>{
    '完整文档': ExportFormat.fullDoc,
    'Markdown': ExportFormat.markdown,
    'PDF': ExportFormat.pdf,
    '图片': ExportFormat.image,
    'Word 文档': ExportFormat.word,
  };

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: const Key('export-btn'),
      onPressed: _busy ? null : () => _open(context),
      style: TextButton.styleFrom(
        foregroundColor: RCColors.label,
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
    );
  }

  Future<void> _open(BuildContext context) async {
    final size = MediaQuery.of(context).size;
    final messenger = ScaffoldMessenger.of(context);
    final chosen = await showMenu<String>(
      context: context,
      // 页头右上锚定（导出按钮位于滚动流内，随内容滚动，菜单用固定位置防跑偏）
      position: RelativeRect.fromSize(
        Rect.fromLTWH(size.width - 186, 96, 170, 36),
        size,
      ),
      items: [
        for (final f in _formats.keys)
          PopupMenuItem(
            value: f,
            child: Text(f, key: Key('export-item-$f')),
          ),
      ],
    );
    if (chosen == null) return;
    final format = _formats[chosen]!;

    setState(() => _busy = true);
    try {
      final doc = exportDocumentFromSummary(widget.card);
      // 图片导出用页面根锚点截屏；其它格式不需要
      final captureKey = format == ExportFormat.image
          ? captureKeyForExport()
          : null;
      final result = await ExportService().export(
        format,
        doc,
        captureKey: captureKey,
      );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              '已导出 ${result.path.split('/').last}',
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
    return Container(
      key: const Key('stabs'),
      decoration: const BoxDecoration(
        color: RCColors.bg,
        border: Border(bottom: BorderSide(color: RCColors.sep)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            Expanded(
              // SingleChildScrollView 非懒加载：全部 Tab 常驻树内，窄屏溢出横向滑动
              child: SingleChildScrollView(
                key: const Key('stab-strip'),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (k, label) in tabs)
                      Padding(
                        padding: const EdgeInsets.only(right: 18),
                        child: TextButton(
                          key: Key('stab-$k'),
                          onPressed: () => onTap(k),
                          style: TextButton.styleFrom(
                            foregroundColor: current == k
                                ? RCColors.label
                                : RCColors.sec,
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
  final hasFile = p.path.isNotEmpty && File(p.path).existsSync();
  final srcLabel = p.source == 'dyj_camera' ? '点一机抓拍' : '系统相册';
  showDialog<void>(
    context: context,
    builder: (ctx) {
      return Dialog(
        backgroundColor: RCColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: hasFile
                  ? Image.file(File(p.path), fit: BoxFit.cover)
                  : const ColoredBox(
                      color: Color(0xFFEAEAE4),
                      child: Center(
                        child: Icon(
                          Icons.photo_outlined,
                          size: 44,
                          color: RCColors.sec,
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${item.event.title} · ${p.time}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          srcLabel,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: RCColors.sec,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      onOpenDetail();
                    },
                    child: const Text('查看原话 ›'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
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
    final p = item.photo;
    final hasFile = p.path.isNotEmpty && File(p.path).existsSync();
    final srcLabel = p.source == 'dyj_camera' ? '点一机抓拍' : '系统相册';
    return Material(
      color: RCColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: RCColors.sep),
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
                  child: hasFile
                      ? Image.file(File(p.path), fit: BoxFit.cover)
                      : ColoredBox(
                          color: const Color(0xFFEAEAE4),
                          child: Center(
                            child: Icon(
                              p.source == 'dyj_camera'
                                  ? Icons.photo_camera_outlined
                                  : Icons.photo_outlined,
                              size: 20,
                              color: RCColors.sec,
                            ),
                          ),
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
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$srcLabel · ${p.time}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: RCColors.sec,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onOpenDetail,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Text(
                    '原话 ›',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: RCColors.okInk,
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

/// 逻辑结构：根节点 + 分支 + 叶子（有关联现场图时在叶子旁自然附带图片图标）
class _MapTree extends StatelessWidget {
  const _MapTree({
    required this.branches,
    this.leafPhotos = const {},
    required this.onOpenDetail,
  });

  final List<MapBranch> branches;
  final Map<String, _ContextualPhoto> leafPhotos;
  final void Function(String eventId) onOpenDetail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFEAF3EA),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '会议要点',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
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
                    Container(width: 2, height: 14, color: RCColors.ax),
                    const SizedBox(width: 8),
                    Text(
                      branches[bi].name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
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
    if (match == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: RCColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: RCColors.sep),
        ),
        child: Text(
          leaf,
          style: const TextStyle(fontSize: 12, color: RCColors.ink),
        ),
      );
    }
    return Material(
      color: RCColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: RCColors.sep),
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
                  style: const TextStyle(fontSize: 12, color: RCColors.ink),
                ),
              ),
              const SizedBox(width: 5),
              const Icon(Icons.image_outlined, size: 13.5, color: RCColors.sec),
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
  });
  final _SummaryResultPageState page;
  final int index;
  final InfoPoint point;
  final List<_ContextualPhoto> photos;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final open = page._ptOpen[index] ?? false;
    return Container(
      key: Key('pt-$index'),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: RCColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RCColors.sep),
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
                      point.title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (photos.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.image_outlined,
                      key: Key('pt-picico-$index'),
                      size: 15,
                      color: RCColors.sec,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: RCColors.sec,
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
                    point.detail,
                    key: Key('pt-d-$index'),
                    style: const TextStyle(fontSize: 13, height: 1.6),
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
                            foregroundColor: RCColors.okInk,
                            side: const BorderSide(color: RCColors.ok),
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
    ('sec-src', '来源记录'),
  ];

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      key: const Key('toc-btn'),
      onPressed: () => _open(context),
      style: OutlinedButton.styleFrom(
        backgroundColor: RCColors.bg,
        foregroundColor: RCColors.label,
        side: const BorderSide(color: RCColors.sep),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: Size.zero,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: const Text('目录'),
    );
  }

  void _open(BuildContext context) {
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
      position: pos,
      items: [
        for (final (id, label) in _items)
          PopupMenuItem(
            value: id,
            child: Text(label, key: Key('toc-item-$id')),
          ),
      ],
    ).then((v) {
      if (v != null) onGo?.call(v);
    });
  }
}
