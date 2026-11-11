/// Timeline 页 —— 按日分组倒序；两行折叠卡；勾选模式（全选今日/本周/本月 + 底部操作栏）。
library;

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/models/recording.dart';
import '../core/models/summary.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../services/audio/recording_status.dart';
import '../widgets/recording_status_block.dart';
import '../widgets/selection_marker.dart';
import '../widgets/store_scope.dart';

class TimelinePage extends StatelessWidget {
  const TimelinePage({
    super.key,
    this.asLeftPane = false,
    this.recordingStatus,
  });

  /// 宽屏双栏时作为常显左栏
  final bool asLeftPane;

  /// 设备录音态状态块；null 时不展示（旧调用/测试兼容）
  final RecordingStatusController? recordingStatus;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final merged = recordingStatus == null
        ? store
        : Listenable.merge([store, recordingStatus!]);
    return ListenableBuilder(
      listenable: merged,
      builder: (context, _) {
        final groups = store.feedGroups;
        // 录音/同步状态块只出现在「全部/记录」的内容顶部：
        // 勾选总结时收起（总结源列表保持干净），切到「总结」Tab 也不显示。
        final showStatus = recordingStatus != null &&
            !store.selMode &&
            store.filter != FeedFilter.summary;
        // 设计稿只有一处顶部实时状态块（#live-status）：状态块已经在展示「正在录音 / 正在同步 / 正在转写」时，
        // 不再叠出第二条 _SyncBanner（「正在取回…」进度条），避免两块同步提示同时出现冲突。
        final statusBlockVisible =
            showStatus && recordingStatus!.phase != RecordingPhase.idle;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TabsBar(store: store),
            if (store.selMode) _RangeBar(store: store),
            if ((store.loading || store.syncStage != null) &&
                !statusBlockVisible)
              _SyncBanner(store: store),
            Expanded(
              // 下拉同步：从录音卡取回新录音（下载 + 转码 + 转写）
              child: RefreshIndicator(
                key: const Key('timeline-refresh'),
                onRefresh: () async {
                  final error = await store.syncRecordings();
                  if (error != null && context.mounted) {
                    if (error.contains('未连接录音卡')) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          duration: Duration(seconds: 2),
                          content: Text('已连接录音卡后再下拉取回'),
                        ),
                      );
                    } else if (error.contains('录音进行中')) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          duration: Duration(seconds: 2),
                          content: Text('正在录音中，每满 1 分钟自动转写保存'),
                        ),
                      );
                    }
                  }
                },
                child: groups.isEmpty
                    ? ListView(
                        key: const Key('timeline-empty'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        children: [
                          if (showStatus)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                              ),
                              child: RecordingStatusBlock(
                                controller: recordingStatus!,
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(top: 60),
                            child: Center(
                              child: Column(
                                children: [
                                  const Icon(
                                    Icons.mic_none,
                                    size: 36,
                                    color: RCColors.ax,
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    store.loadError ??
                                        (store.syncError ??
                                            _emptyText(
                                              store,
                                              deviceReady:
                                                  store.deviceConnected?.call() ??
                                                  true,
                                            )),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: RCColors.sec,
                                      fontSize: 14,
                                      height: 1.6,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(22, 4, 22, 32),
                        children: [
                          if (showStatus)
                            RecordingStatusBlock(
                              controller: recordingStatus!,
                            ),
                          for (final g in groups) ...[
                            Padding(
                              padding: const EdgeInsets.only(
                                top: 4,
                                bottom: 14,
                              ),
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
            ),
            if (store.selMode) _SelBar(store: store),
          ],
        );
      },
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
      return TextButton(
        key: Key('tab-$keyName'),
        onPressed: locked ? null : () => store.setFilter(f),
        style: TextButton.styleFrom(
          foregroundColor: on ? RCColors.label : RCColors.sec,
          disabledForegroundColor: RCColors.ax,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
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
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 2, 22, 0),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: RCColors.sep)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                tab('全部', FeedFilter.all, 'all'),
                const SizedBox(width: 18),
                tab('记录', FeedFilter.event, 'event'),
                const SizedBox(width: 18),
                tab('总结', FeedFilter.summary, 'summary'),
              ],
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
              if (store.selMode && !event.live)
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
                  borderRadius: BorderRadius.circular(12),
                  // 设计稿 .card 只有 margin-bottom，没有底板/边框/阴影：
                  // 事件是时间轴上的列表行，卡片形态只属于总结（.sumcard）。
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                        ),
                      ),
                      if (event.live ||
                          (event.note != null && event.note!.isNotEmpty)) ...[
                        const SizedBox(height: 6),
                        _EventNoteBadge(
                          text: event.live ? '整理中' : event.note!,
                          live: event.live,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        '${event.time} · ${event.dur}',
                        key: Key('when-${event.id}'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: RCColors.sec,
                        ),
                      ),
                      if (open) ...[
                        const SizedBox(height: 10),
                        Text(
                          event.longText,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, height: 1.55),
                        ),
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
                        if (!event.live) ...[
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
                    ],
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
    final locked = card.state != SummaryState.done;
    Widget inner;
    switch (card.state) {
      case SummaryState.pending:
        inner = Column(
          key: const Key('sumcard-pending'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '手动总结',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '${card.time} · 选择来源切片中',
              style: const TextStyle(fontSize: 12, color: RCColors.sec),
            ),
          ],
        );
      case SummaryState.generating:
        inner = Column(
          key: const Key('sumcard-generating'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '正在生成总结',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '${card.time} · 分析检查中',
              style: const TextStyle(fontSize: 12, color: RCColors.sec),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  key: const Key('sumcard-prog'),
                  value: card.progress / 100,
                  minHeight: 4,
                  backgroundColor: RCColors.sep,
                  valueColor: const AlwaysStoppedAnimation(RCColors.ok),
                ),
              ),
            ),
          ],
        );
      case SummaryState.failed:
        inner = Column(
          key: const Key('sumcard-failed'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '总结生成失败',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              card.error ?? '请稍后重试',
              style: const TextStyle(fontSize: 12, color: RCColors.sec),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const Key('sumcard-retry'),
                  onPressed: () => store.retryGeneration(card.id),
                  child: const Text('重试'),
                ),
                TextButton(
                  key: const Key('sumcard-dismiss'),
                  onPressed: () => store.dismissFailed(card.id),
                  child: const Text('放弃'),
                ),
              ],
            ),
          ],
        );
      case SummaryState.done:
        inner = Column(
          key: const Key('sumcard-done'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    card.title ?? '',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // 总结没有详情页：整张卡片可点，箭头只做「会进下一页」的提示
                const Icon(Icons.chevron_right, size: 16, color: RCColors.ax),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${card.time} · 已选 ${card.srcIds.length} 片段',
              style: const TextStyle(fontSize: 12, color: RCColors.sec),
            ),
          ],
        );
    }
    return Padding(
      key: Key('timeline-item-${card.id}'),
      padding: const EdgeInsets.only(bottom: 36),
      child: InkWell(
        key: Key('card-${card.id}'),
        onTap: locked ? null : () => store.tapCard(card.id, isSummary: true),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          key: Key('sumcard-${card.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          // 设计稿 .sumcard：只有总结才是卡片（底板 + 1px 分隔线边框 + 12 圆角）
          decoration: BoxDecoration(
            color: RCColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: RCColors.sep),
          ),
          child: inner,
        ),
      ),
    );
  }
}

/// 同步/装载提示条：阶段文案 + 真实进度（不做假动画）。
class _SyncBanner extends StatelessWidget {
  const _SyncBanner({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final text = store.syncStage != null ? store.syncText : '正在读取本地录音…';
    final progress = store.syncStage != null ? store.syncProgress : null;
    return Container(
      key: const Key('sync-banner'),
      margin: const EdgeInsets.fromLTRB(22, 0, 22, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: RCColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: RCColors.sep),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  key: const Key('sync-text'),
                  style: const TextStyle(fontSize: 12, color: RCColors.sec),
                ),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                key: const Key('sync-progress'),
                value: progress.clamp(0, 1),
                minHeight: 3,
                backgroundColor: RCColors.sep,
                valueColor: const AlwaysStoppedAnimation(RCColors.ok),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 分段状态小徽标：整理中 / 部分未润色 / 时间未校准。
class _EventNoteBadge extends StatelessWidget {
  const _EventNoteBadge({required this.text, required this.live});

  final String text;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: live ? const Color(0xFFFDF1EC) : const Color(0xFFF2F2EE),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (live) ...[
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: RCColors.danger,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              color: live ? RCColors.danger : RCColors.sec,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态文案：区分「没录音」「正在整理」「整理失败」「录了但没识别到语音」。
///
/// 关键：**失败的录音不能算"正在整理"**。否则一条永远处理不完的录音
/// 会让时间轴永远停在"正在整理"，用户既看不到失败原因，也等不到结果。
String _emptyText(AppStore store, {bool deviceReady = true}) {
  final files = store.recordingFiles;
  if (files.isEmpty) {
    return deviceReady
        ? '还没有录音\n下拉可从录音卡取回'
        : '还没有录音\n连上录音卡后下拉取回';
  }
  final pending = files.where((f) => f.stage != RecordingStage.ready).toList();
  if (pending.isEmpty) return '录音里没有识别到语音';
  // 只剩失败项：如实说失败，并带上第一条可读原因
  if (pending.every((f) => f.stage == RecordingStage.failed)) {
    // 没连卡时，这些只是等人来核对的历史残留，不该一打开就红着脸报错；
    // 连上卡之后才如实说"有 N 条没处理完"。
    if (!deviceReady) {
      return '还没有可显示的录音\n连上录音卡后可核对并重试';
    }
    final reason = pending.first.error;
    return reason == null || reason.isEmpty
        ? '有 ${pending.length} 条录音未能处理\n下拉可重试'
        : '有 ${pending.length} 条录音未能处理\n$reason';
  }
  // 还有真在跑的：才说正在整理
  if (pending.any((f) => f.stage != RecordingStage.failed)) {
    return '正在整理本地录音…\n完成后会出现在时间轴';
  }
  return '录音里没有识别到语音';
}
