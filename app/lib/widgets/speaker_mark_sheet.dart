/// 说话人标记面板：支持从记录详情、导出面板按声纹簇绑定称呼或恢复推测状态，
/// 保存后同步联动对话详情、Timeline、总结结果（全文/行动项）与所有导出格式。
library;

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';

/// 快捷身份预设标签。
const List<String> _kSpeakerPresets = ['我', '对方', '客户', '同事', '主持人'];

/// 弹出说话人标记底部面板；返回 true 表示用户点击了保存。
Future<bool> showSpeakerMarkSheet(
  BuildContext context, {
  required AppStore store,
  required List<RecordEvent> events,
  String? initialSlot,
}) async {
  final entries = store.speakerEntriesForEvents(events);
  final saved = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: context.rc.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (ctx) => _SpeakerMarkSheetBody(
      store: store,
      entries: entries,
      initialSlot: initialSlot,
    ),
  );
  return saved ?? false;
}

class _SpeakerMarkSheetBody extends StatefulWidget {
  const _SpeakerMarkSheetBody({
    required this.store,
    required this.entries,
    this.initialSlot,
  });

  final AppStore store;
  final List<
    ({
      String slot,
      String currentAlias,
      String sampleQuote,
      List<RecordEvent> events,
    })
  >
  entries;
  final String? initialSlot;

  @override
  State<_SpeakerMarkSheetBody> createState() => _SpeakerMarkSheetBodyState();
}

class _SpeakerMarkSheetBodyState extends State<_SpeakerMarkSheetBody> {
  late final List<TextEditingController> _controllers = [
    for (final entry in widget.entries)
      TextEditingController(text: entry.currentAlias),
  ];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    for (var i = 0; i < widget.entries.length; i++) {
      final entry = widget.entries[i];
      widget.store.setSpeakerAliasForEvents(
        entry.events,
        entry.slot,
        _controllers[i].text,
      );
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final maxH = MediaQuery.sizeOf(context).height * 0.82;

    return SafeArea(
      key: const Key('speaker-mark-sheet'),
      child: Padding(
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: rc.sep,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '标记说话人',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: rc.label,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '确认后的称呼会同步到对话详情、总结与导出内容；未标记的声纹簇仍保留「（推测）」标识。',
                      style: TextStyle(fontSize: 12, height: 1.45, color: rc.sec),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (widget.entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '当前记录暂无可标记的说话人簇。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: rc.sec),
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    primary: false,
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < widget.entries.length; i++) ...[
                          _SpeakerFieldCard(
                            index: i,
                            slot: widget.entries[i].slot,
                            sampleQuote: widget.entries[i].sampleQuote,
                            controller: _controllers[i],
                            highlighted:
                                widget.initialSlot == widget.entries[i].slot,
                          ),
                          if (i < widget.entries.length - 1)
                            const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('speaker-cancel-btn'),
                        onPressed: () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: rc.label,
                          side: BorderSide(color: rc.sep),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        key: const Key('speaker-save-btn'),
                        onPressed: widget.entries.isEmpty
                            ? () => Navigator.of(context).pop(false)
                            : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: rc.label,
                          foregroundColor: rc.card,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('保存并同步'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeakerFieldCard extends StatelessWidget {
  const _SpeakerFieldCard({
    required this.index,
    required this.slot,
    required this.sampleQuote,
    required this.controller,
    this.highlighted = false,
  });

  final int index;
  final String slot;
  final String sampleQuote;
  final TextEditingController controller;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rc.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: highlighted ? rc.label : rc.sep,
          width: highlighted ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '原声纹簇：$slot（推测）',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: rc.sec,
                ),
              ),
              const Spacer(),
              InkWell(
                key: Key('speaker-clear-$index'),
                onTap: () => controller.clear(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Text(
                    '恢复默认',
                    style: TextStyle(fontSize: 11.5, color: rc.sec),
                  ),
                ),
              ),
            ],
          ),
          if (sampleQuote.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '「$sampleQuote」',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: rc.ink),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            key: Key('speaker-input-$index'),
            controller: controller,
            autofocus: highlighted,
            textInputAction: TextInputAction.done,
            style: TextStyle(fontSize: 14, color: rc.label),
            decoration: InputDecoration(
              isDense: true,
              hintText: '输入称呼（如：我、老陈、客户），留空则恢复推测',
              hintStyle: TextStyle(fontSize: 13, color: rc.ax),
              filled: true,
              fillColor: rc.card,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: rc.sep),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: rc.sep),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preset in _kSpeakerPresets)
                ActionChip(
                  key: Key('speaker-preset-$index-$preset'),
                  label: Text(
                    preset,
                    style: TextStyle(fontSize: 11.5, color: rc.ink),
                  ),
                  backgroundColor: rc.card,
                  side: BorderSide(color: rc.sep),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onPressed: () {
                    controller.text = preset;
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
