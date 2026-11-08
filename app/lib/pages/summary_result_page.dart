/// 总结结果页 —— 生成态（进度/已生成/预计还需/步骤）与结果态（吸顶 Tab + 目录浮钮 + 信息点溯源 + 导出）。
library;

import 'package:flutter/material.dart';

import '../core/models/summary.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../widgets/store_scope.dart';
import '../services/export/export_service.dart';

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
  String _tab = 'all'; // all | ov | map | pt | todo | src
  final Map<int, bool> _ptOpen = {};
  String? _loadedId;
  AppStore get store => StoreScope.of(context);
  Set<int> get _todosDone => store.todosDone(widget.summaryId);

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
        ..addAll({
          for (
            var i = 0;
            i < (store.summaryById(widget.summaryId)?.points.length ?? 0);
            i++
          )
            i: k == 'pt',
        });
      store.setSummaryTab(widget.summaryId, k);
      store.setPointsExpanded(
        widget.summaryId,
        _ptOpen.entries.where((e) => e.value).map((e) => e.key).toSet(),
      );
    });
  }

  // 供子组件调用的公开变更入口（避免跨类调用受保护的 setState）
  void togglePoint(int i) {
    setState(() => _ptOpen[i] = !(_ptOpen[i] ?? false));
    store.setPointsExpanded(
      widget.summaryId,
      _ptOpen.entries.where((e) => e.value).map((e) => e.key).toSet(),
    );
  }

  void toggleTodo(int i) => store.toggleTodo(widget.summaryId, i);

  void _tocGo(String secId) {
    setState(() => _tab = 'all');
    store.setSummaryTab(widget.summaryId, 'all'); // 非「全部」时先切回「全部」再滚动
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
        if (card == null) return const Center(child: Text('总结不存在或尚未恢复'));
        if (_loadedId != widget.summaryId) {
          _loadedId = widget.summaryId;
          _tab = store.summaryTab(widget.summaryId);
          _ptOpen
            ..clear()
            ..addAll({
              for (final i in store.pointsExpanded(widget.summaryId)) i: true,
            });
        }
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
            if (store.summaryErrors.containsKey(card.id))
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          store.summaryErrors[card.id]!,
                          key: const Key('gen-error'),
                          style: const TextStyle(
                            fontSize: 13,
                            color: RCColors.danger,
                          ),
                        ),
                        const SizedBox(height: 14),
                        OutlinedButton(
                          key: const Key('gen-retry'),
                          onPressed: () => store.retrySummary(card.id),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else if (card.state == SummaryState.generating)
              Expanded(
                child: _GenView(store: store, card: card),
              )
            else if (card.state == SummaryState.done)
              Expanded(
                child: _ResultView(page: this, card: card),
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
                  value: store.generationPercent(card.id) == null
                      ? null
                      : card.progress / 100,
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
                  store.genElapsedText(card.id),
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
              store.genStepText(card.id),
              key: const Key('gen-step'),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            TextButton(
              key: const Key('gen-cancel'),
              onPressed: () => store.cancelGeneration(card.id),
              child: const Text('取消'),
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
    // 原型 .tochold：目录钮归属内容区右上角（不占 tab 行），钉在吸顶栏下方
    return Stack(
      children: [
        CustomScrollView(
          key: const Key('sum-scroll'),
          controller: page._scroll,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
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
                    _ExportButton(summaryId: card.id),
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
        // 目录浮钮：吸顶栏（46px）正下方右侧 8px，压于内容之上（各 Tab 均可用）
        Positioned(top: 46, right: 8, child: _TocButton(onGo: page._tocGo)),
      ],
    );
  }

  List<Widget> _sections(BuildContext context, AppStore store) {
    bool show(String k) => page._tab == 'all' || page._tab == k;
    return [
      if (show('ov'))
        _section('sec-ov', '概览', [
          Text(
            card.overview ?? '',
            style: const TextStyle(fontSize: 14, height: 1.6),
          ),
        ]),
      if (show('map'))
        _section('sec-map', '逻辑结构', [_MapTree(branches: card.structure)]),
      if (show('pt'))
        _section('sec-pt', '信息点', [
          for (var i = 0; i < card.points.length; i++)
            _PointTile(page: page, index: i, point: card.points[i]),
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
                final e = store.eventOrNull(id);
                if (e == null) {
                  return Text(
                    '来源记录尚未同步：$id',
                    style: const TextStyle(color: RCColors.sec),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: OutlinedButton(
                    key: Key('src-$id'),
                    onPressed: () => store.openDetail(id),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: RCColors.label,
                      side: const BorderSide(color: RCColors.sep),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(14),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_dayLabel(e.dayOffset)} ${e.time} · ${e.dur}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: RCColors.sec,
                            ),
                          ),
                        ],
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

/// 导出按钮：菜单锚定在按钮自身位置；5 种格式 → 生成真实文件并打开系统分享
class _ExportButton extends StatelessWidget {
  const _ExportButton({required this.summaryId});
  final String summaryId;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: const Key('export-btn'),
      onPressed: StoreScope.of(context).exporting ? null : () => _open(context),
      style: TextButton.styleFrom(
        foregroundColor: RCColors.label,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: Size.zero,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: const Text('导出'),
    );
  }

  void _open(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final messenger = ScaffoldMessenger.of(context);
    final store = StoreScope.of(context);
    final box = context.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset.zero);
    final origin = RectOrigin(
      offset.dx,
      offset.dy,
      box.size.width,
      box.size.height,
    );
    showMenu<String>(
      context: context,
      // 页头右上锚定（导出按钮位于滚动流内，随内容滚动，菜单用固定位置防跑偏）
      position: RelativeRect.fromSize(
        Rect.fromLTWH(size.width - 186, 96, 170, 36),
        size,
      ),
      items: [
        for (final f in const ['完整文档', 'Markdown', 'PDF', '图片', 'Word 文档'])
          PopupMenuItem(
            value: f,
            child: Text(f, key: Key('export-item-$f')),
          ),
      ],
    ).then((f) async {
      if (f == null) return;
      const formats = {
        '完整文档': ExportFormat.html,
        'Markdown': ExportFormat.markdown,
        'PDF': ExportFormat.pdf,
        '图片': ExportFormat.png,
        'Word 文档': ExportFormat.docx,
      };
      String message;
      try {
        await store.exportSummary(summaryId, formats[f]!, origin: origin);
        message = '已打开系统分享 · $f';
      } catch (e) {
        message = '导出失败：${e.toString().replaceFirst('Bad state: ', '')}';
      }
      if (!messenger.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message, key: const Key('toast')),
            duration: const Duration(milliseconds: 1600),
          ),
        );
    });
  }
}

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

/// 逻辑结构：根节点 + 分支 + 叶子
class _MapTree extends StatelessWidget {
  const _MapTree({required this.branches});
  final List<MapBranch> branches;

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
        for (final b in branches)
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
                      b.name,
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
                      for (final leaf in b.leaves)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: RCColors.card,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: RCColors.sep),
                          ),
                          child: Text(
                            leaf,
                            style: const TextStyle(
                              fontSize: 12,
                              color: RCColors.ink,
                            ),
                          ),
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
}

/// 信息点：标题 + 细节 + 溯源链接（可展开收起）
class _PointTile extends StatelessWidget {
  const _PointTile({
    required this.page,
    required this.index,
    required this.point,
  });
  final _SummaryResultPageState page;
  final int index;
  final InfoPoint point;

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
