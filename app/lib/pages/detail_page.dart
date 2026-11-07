/// 详情页 —— 「对话详情 / 原始数据 / 被引用总结 N」平级 tab（refs 仅 N>0 显示）。
library;
import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../widgets/store_scope.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.eventId, this.showPaneBack = false, this.backLabel});
  final String eventId;

  /// 宽屏双栏：面板内返回按钮（窄屏走顶栏面包屑）
  final bool showPaneBack;
  final String? backLabel;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  String _tab = 'dlg'; // dlg | raw | refs

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final RecordEvent e = store.eventById(widget.eventId);
    final refs = store.doneSummariesReferencing(widget.eventId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showPaneBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('pb-detail'),
              onPressed: store.goBack,
              icon: const Icon(Icons.chevron_left, size: 18),
              label: Text(widget.backLabel ?? '‹ 返回'),
              style: TextButton.styleFrom(
                  foregroundColor: RCColors.sec,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  textStyle: const TextStyle(fontSize: 13)),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.title,
                  key: const Key('dt-h3'),
                  style:
                      const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  Text(
                      '${_dayLabel(e)} ${e.time} · ${e.dur}',
                      key: const Key('dt-meta'),
                      style:
                          const TextStyle(fontSize: 12, color: RCColors.sec)),
                  Text('说话人 ${e.speakers}',
                      style:
                          const TextStyle(fontSize: 12, color: RCColors.sec)),
                  if (e.mark.isNotEmpty)
                    Text(e.mark,
                        style:
                            const TextStyle(fontSize: 12, color: RCColors.ink)),
                ],
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration:
              const BoxDecoration(border: Border(bottom: BorderSide(color: RCColors.sep))),
          child: Row(
            children: [
              _tabBtn('对话详情', 'dlg'),
              _tabBtn('原始数据', 'raw'),
              if (refs.isNotEmpty) _tabBtn('被引用总结 ${refs.length}', 'refs'),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 32),
            children: _buildTab(store, e, refs),
          ),
        ),
      ],
    );
  }

  String _dayLabel(RecordEvent e) {
    if (e.dayOffset == 0) return '今天';
    if (e.dayOffset == 1) return '昨天';
    final d = DateTime.now().subtract(Duration(days: e.dayOffset));
    const dow = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${d.month}月${d.day}日 ${dow[d.weekday - 1]}';
  }

  Widget _tabBtn(String label, String id) => Padding(
        padding: const EdgeInsets.only(right: 18),
        child: TextButton(
          key: Key('det-tab-$id'),
          onPressed: () => setState(() => _tab = id),
          style: TextButton.styleFrom(
            foregroundColor: _tab == id ? RCColors.label : RCColors.sec,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: _tab == id ? FontWeight.w700 : FontWeight.w500)),
        ),
      );

  List<Widget> _buildTab(AppStore store, RecordEvent e, List refs) {
    switch (_tab) {
      case 'dlg':
        return [
          for (final l in e.dialog)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: l.spk == 'B'
                          ? const Color(0xFFE8E8E4)
                          : const Color(0xFFDDE9DD),
                    ),
                    child: Text(l.spk,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('说话人 ${l.spk} · ${l.src.replaceFirst('来源 ', '')}',
                            style: const TextStyle(
                                fontSize: 11, color: RCColors.sec)),
                        const SizedBox(height: 3),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: RCColors.card,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: RCColors.sep),
                          ),
                          child: Text(l.text,
                              style: const TextStyle(
                                  fontSize: 14, height: 1.5)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ];
      case 'raw':
        return [
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Text(
                '原始转写保留语气词、停顿与静音；时间标注后段为清洗版对应位置。',
                style: TextStyle(fontSize: 12, color: RCColors.sec, height: 1.5)),
          ),
          for (final l in e.raw)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F6F2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${l.spk} · ${l.src}',
                        style: const TextStyle(
                            fontSize: 11, color: RCColors.sec)),
                    const SizedBox(height: 3),
                    Text(l.text,
                        style:
                            const TextStyle(fontSize: 14, height: 1.55)),
                  ],
                ),
              ),
            ),
        ];
      case 'refs':
        return [
          for (final r in refs)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton(
                key: Key('ref-${r.id}'),
                onPressed: () => store.openSum(r.id),
                style: OutlinedButton.styleFrom(
                  foregroundColor: RCColors.label,
                  side: const BorderSide(color: RCColors.sep),
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.all(14),
                  alignment: Alignment.centerLeft,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(r.title ?? '',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 4),
                    Text('${r.time} · 已选 ${r.srcIds.length} 片段',
                        style:
                            const TextStyle(fontSize: 12, color: RCColors.sec)),
                  ],
                ),
              ),
            ),
        ];
      default:
        return const [];
    }
  }
}
