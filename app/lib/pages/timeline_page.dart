/// Timeline 页 —— 按日分组倒序；两行折叠卡；勾选模式（全选今日/本周/本月 + 底部操作栏）。
library;

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/models/summary.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../widgets/selection_marker.dart';
import '../widgets/store_scope.dart';

class TimelinePage extends StatelessWidget {
  const TimelinePage({super.key, this.asLeftPane = false});

  /// 宽屏双栏时作为常显左栏
  final bool asLeftPane;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final groups = store.feedGroups;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TitleBar(store: store),
            _TabsBar(store: store),
            if (store.selMode) _RangeBar(store: store),
            if (store.loading)
              const LinearProgressIndicator(
                key: Key('records-loading'),
                minHeight: 2,
              ),
            if (store.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        store.error!,
                        key: const Key('records-error'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: RCColors.danger,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('records-retry'),
                      onPressed: store.retryRecords,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            if (store.persistenceError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Text(
                  store.persistenceError!,
                  style: const TextStyle(fontSize: 12, color: RCColors.danger),
                ),
              ),
            Expanded(
              child: groups.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          '该筛选下暂无内容。',
                          style: TextStyle(color: RCColors.sec, fontSize: 14),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
                      children: [
                        for (final g in groups) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 14),
                            child: Text(
                              g.dayLabel,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          for (final (i, item) in g.items.indexed)
                            _TimelineRail(
                              first: i == 0,
                              last: i == g.items.length - 1,
                              child: item is SummaryCard
                                  ? _SummaryCardView(card: item, store: store)
                                  : _EventCardView(
                                      event: item as RecordEvent,
                                      store: store,
                                    ),
                            ),
                        ],
                      ],
                    ),
            ),
            if (store.selMode) _SelBar(store: store),
          ],
        );
      },
    );
  }
}

/// 原型 .tl-head：左侧大标题 Timeline，右侧「总结」描边胶囊按钮。
class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Timeline',
              key: Key('timeline-title'),
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
                color: RCColors.label,
              ),
            ),
          ),
          // 原型 .btn-sum：透明底 + 深色描边胶囊
          OutlinedButton(
            key: const Key('summary-start'),
            onPressed: store.selMode ? null : store.startSummary,
            style: OutlinedButton.styleFrom(
              foregroundColor: RCColors.label,
              disabledForegroundColor: RCColors.ax,
              side: const BorderSide(color: RCColors.label),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(fontSize: 13),
            ),
            child: const Text('总结'),
          ),
        ],
      ),
    );
  }
}

class _TabsBar extends StatelessWidget {
  const _TabsBar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    Widget tab(String label, FeedFilter f, String keyName) {
      final locked = store.tabsLocked && f != FeedFilter.event;
      final on = store.filter == f;
      // 原型 .tabs button.on：当前项下方有短下划线，其余无。
      return Padding(
        padding: const EdgeInsets.only(right: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: Key('tab-$keyName'),
              onPressed: locked ? null : () => store.setFilter(f),
              style: TextButton.styleFrom(
                foregroundColor: on ? RCColors.label : RCColors.sec,
                disabledForegroundColor: RCColors.ax,
                padding: const EdgeInsets.symmetric(
                  horizontal: 2,
                  vertical: 8,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            Container(
              key: Key('tab-underline-$keyName'),
              height: 2,
              width: 26,
              margin: const EdgeInsets.only(bottom: 2),
              decoration: BoxDecoration(
                color: on ? RCColors.label : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 2, 22, 0),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: RCColors.sep)),
      ),
      child: Row(
        children: [
          tab('全部', FeedFilter.all, 'all'),
          tab('记录', FeedFilter.event, 'event'),
          tab('总结', FeedFilter.summary, 'summary'),
        ],
      ),
    );
  }
}

class _RangeBar extends StatelessWidget {
  const _RangeBar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, String r) => Padding(
      key: Key('chip-$r'),
      padding: const EdgeInsets.only(right: 8),
      child: OutlinedButton(
        onPressed: () => r == 'none' ? store.selNone() : store.selRange(r),
        style: OutlinedButton.styleFrom(
          foregroundColor: RCColors.ink,
          side: const BorderSide(color: RCColors.sep),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 13),
        ),
        child: Text(label),
      ),
    );

    return Container(
      key: const Key('rangebar'),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
      child: Row(
        children: [
          const Text('全选', style: TextStyle(fontSize: 13, color: RCColors.sec)),
          const SizedBox(width: 10),
          chip('今日', 'today'),
          chip('本周', 'week'),
          chip('本月', 'month'),
          chip('清除', 'none'),
        ],
      ),
    );
  }
}

class _SelBar extends StatelessWidget {
  const _SelBar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('sumbar'),
      decoration: const BoxDecoration(
        color: RCColors.bg,
        border: Border(top: BorderSide(color: RCColors.sep)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '已选 ${store.selCount} 项',
                key: const Key('sel-count'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const Text(
                '勾选要总结的记录',
                style: TextStyle(fontSize: 12, color: RCColors.sec),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('cancel-summary'),
                  onPressed: store.cancelSummary,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: RCColors.ink,
                    side: const BorderSide(color: RCColors.ax),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('generate-summary'),
                  onPressed: store.selCount == 0 ? null : store.genSummary,
                  style: FilledButton.styleFrom(
                    backgroundColor: RCColors.label,
                    disabledBackgroundColor: RCColors.ax,
                    foregroundColor: Colors.white,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  child: const Text('生成总结'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 时间轴轨道：左侧 1px 竖线 + 10×10 轴点（原型 .tl-item/.tl-node）。
/// 首项线从点下方起、末项线到点上方止、单项无线，跨项距连续成轨。
class _TimelineRail extends StatelessWidget {
  const _TimelineRail({
    required this.first,
    required this.last,
    required this.child,
  });
  final bool first;
  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final only = first && last;
    // 懒加载列表给无限高约束，IntrinsicHeight 先按卡片定高再让轨道拉伸成线
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 10,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (!only)
                  Positioned(
                    left: 4.5,
                    top: first ? 9.0 : 0,
                    bottom: last ? null : 0,
                    height: last ? 9.0 : null,
                    width: 1,
                    child: ColoredBox(color: RCColors.sep),
                  ),
                Positioned(
                  left: 0,
                  top: 8,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: RCColors.bg,
                      border: Border.all(color: RCColors.ax, width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 两行折叠事件卡：标题 / 时间·时长；点开显示 long 摘要 + 说话人 + 详情按钮。
class _EventCardView extends StatelessWidget {
  const _EventCardView({required this.event, required this.store});
  final RecordEvent event;
  final AppStore store;

  String? get processingLabel => switch (event.transcriptionStatus) {
    'waiting_model' => '原音频已保存 · 等待本机模型',
    'queued' => '原音频已保存 · 等待处理',
    'running' => event.originalTranscript == null ? '正在本机转写' : '原文已保存 · 正在润色',
    'cancelled' => '处理已取消 · 原音频与原文保留',
    'analysis_failed' => '原文已保存 · 润色或分析失败',
    'analysis_pending' => '原文已保存 · 等待联网润色或分析',
    'failed' => '处理失败 · 原音频保留',
    'no_speech' => '未识别到可用文本',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final open = store.openCardId == event.id;
    final picked = store.selMode && store.selIds.contains(event.id);
    return Padding(
      key: Key('timeline-item-${event.id}'),
      padding: const EdgeInsets.only(bottom: 36),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SelectionMarker(
          checked: picked,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (store.selMode)
                GestureDetector(
                  key: Key('selbox-${event.id}'),
                  onTap: () => store.toggleSel(event.id),
                  child: Container(
                    margin: const EdgeInsets.only(top: 2, right: 10),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: picked ? RCColors.ok : RCColors.ax,
                        width: 1.6,
                      ),
                      color: picked ? RCColors.ok : Colors.transparent,
                    ),
                    child: picked
                        ? const Icon(Icons.check, size: 15, color: Colors.white)
                        : null,
                  ),
                ),
              Expanded(
                child: InkWell(
                  key: Key('card-${event.id}'),
                  onTap: () => store.tapCard(event.id, isSummary: false),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: RCColors.card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: open ? RCColors.sep : const Color(0x00000000),
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x14000000),
                          blurRadius: 10,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${event.time} · ${event.dur}',
                          key: Key('when-${event.id}'),
                          style: const TextStyle(
                            fontSize: 13,
                            color: RCColors.sec,
                          ),
                        ),
                        if (processingLabel != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            processingLabel!,
                            key: Key('processing-${event.id}'),
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  event.transcriptionStatus == 'failed' ||
                                      event.transcriptionStatus ==
                                          'analysis_failed'
                                  ? RCColors.danger
                                  : RCColors.sec,
                            ),
                          ),
                        ],
                        if (open) ...[
                          const SizedBox(height: 10),
                          Text(
                            event.longText.isEmpty
                                ? (event.status == 'silent'
                                      ? '本地转写完成，未检测到有效语音；原始音频已保留'
                                      : '原始音频已保存，等待本机转写')
                                : event.longText,
                            style: const TextStyle(fontSize: 14, height: 1.55),
                          ),
                          if (event.error != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              event.error!,
                              key: Key('processing-error-${event.id}'),
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: RCColors.danger,
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 6,
                            children: [
                              Text(
                                '说话人 ${event.speakers}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: RCColors.sec,
                                ),
                              ),
                              if (event.mark.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF0F0EC),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    event.mark,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: RCColors.ink,
                                    ),
                                  ),
                                ),
                              Text(
                                event.srcMap,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: RCColors.sec,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: OutlinedButton(
                              key: Key('detail-${event.id}'),
                              onPressed: () =>
                                  store.openDetail(event.id, fresh: true),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: RCColors.label,
                                side: const BorderSide(color: RCColors.ax),
                                shape: const StadiumBorder(),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(fontSize: 13),
                              ),
                              child: const Text('详情'),
                            ),
                          ),
                        ],
                      ],
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

/// 总结 Action Card：pending / generating（进度）/ done（查看结果入口）。
class _SummaryCardView extends StatelessWidget {
  const _SummaryCardView({required this.card, required this.store});
  final SummaryCard card;
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final failed = store.summaryErrors[card.id];
    final locked = card.state != SummaryState.done && failed == null;
    final open = store.openCardId == card.id && !locked;
    Widget inner;
    if (failed != null) {
      inner = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '总结未完成',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            failed,
            style: const TextStyle(fontSize: 13, color: RCColors.danger),
          ),
          TextButton(
            key: Key('retry-${card.id}'),
            onPressed: () => store.retrySummary(card.id),
            child: const Text('重试'),
          ),
        ],
      );
    } else {
      switch (card.state.name) {
        case 'pending':
          inner = Column(
            key: const Key('sumcard-pending'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '手动总结',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${card.time} · 选择来源切片中',
                style: const TextStyle(fontSize: 13, color: RCColors.sec),
              ),
            ],
          );
        case 'generating':
          inner = Column(
            key: const Key('sumcard-generating'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '正在生成总结',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '${card.time} · 分析检查中',
                style: const TextStyle(fontSize: 13, color: RCColors.sec),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  height: 4,
                  child: LinearProgressIndicator(
                    key: const Key('sumcard-prog'),
                    value: store.generationPercent(card.id) == null
                        ? null
                        : card.progress / 100,
                    minHeight: 4,
                    backgroundColor: RCColors.sep,
                    valueColor: const AlwaysStoppedAnimation(RCColors.ok),
                  ),
                ),
              ),
            ],
          );
        case 'done':
          inner = Column(
            key: const Key('sumcard-done'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                card.title ?? '',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${card.time} · 已选 ${card.srcIds.length} 片段',
                style: const TextStyle(fontSize: 13, color: RCColors.sec),
              ),
              if (open) ...[
                const SizedBox(height: 10),
                Text(
                  card.subDesc ?? '',
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    key: const Key('open-sum'),
                    onPressed: () => store.openSum(card.id, fresh: true),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: RCColors.label,
                      side: const BorderSide(color: RCColors.ax),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    child: const Text('查看总结结果'),
                  ),
                ),
              ],
            ],
          );
        default:
          inner = Text(
            '总结任务：${card.state.name}',
            style: const TextStyle(color: RCColors.sec),
          );
      }
    }
    return Padding(
      key: Key('timeline-item-${card.id}'),
      padding: const EdgeInsets.only(bottom: 36),
      child: InkWell(
        key: Key('card-${card.id}'),
        onTap: locked ? null : () => store.tapCard(card.id, isSummary: true),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: RCColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: open
                  ? RCColors.sep
                  : locked
                  ? const Color(0xFFF2F2EE)
                  : const Color(0x00000000),
              width: locked && !open ? 1 : 1,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: inner,
        ),
      ),
    );
  }
}
