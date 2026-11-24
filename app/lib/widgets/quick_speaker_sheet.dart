/// 轻量「为说话人命名」弹窗 —— 从详情页发言标签、总结全文点击直达，
/// 替代旧版长列表式全量标记，支持声纹弱推测/上下文提示、最近使用 5 个名称、
/// 「记住这个声纹」与「同改其余 xxx 处」双勾选及跳转声纹管理。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';

Future<void> showQuickSpeakerSheet(
  BuildContext context, {
  required AppStore store,
  required RecordEvent event,
  required int turnIndex,
  required String rawSpeaker,
  String? sampleQuote,
  VoidCallback? onManageVoiceprints,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) => _QuickSpeakerSheet(
      store: store,
      event: event,
      turnIndex: turnIndex,
      rawSpeaker: rawSpeaker,
      sampleQuote: sampleQuote,
      onManageVoiceprints: onManageVoiceprints,
    ),
  );
}

class _QuickSpeakerSheet extends StatefulWidget {
  const _QuickSpeakerSheet({
    required this.store,
    required this.event,
    required this.turnIndex,
    required this.rawSpeaker,
    this.sampleQuote,
    this.onManageVoiceprints,
  });

  final AppStore store;
  final RecordEvent event;
  final int turnIndex;
  final String rawSpeaker;
  final String? sampleQuote;
  final VoidCallback? onManageVoiceprints;

  @override
  State<_QuickSpeakerSheet> createState() => _QuickSpeakerSheetState();
}

class _QuickSpeakerSheetState extends State<_QuickSpeakerSheet> {
  late final TextEditingController _ctrl;
  late bool _rememberVoiceprint;
  late bool _applyBatch;
  late final int _otherCount;
  late final String? _hintName;
  late final String? _hintReason;
  late final bool _isAlreadyNamed;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final curDisplay = widget.store.displayTurnSpeaker(
      widget.event,
      widget.turnIndex,
      widget.rawSpeaker,
      includeGuessSuffix: false,
    );
    final isGeneric =
        curDisplay == '未区分' ||
        curDisplay.startsWith('说话人 ') ||
        curDisplay == '无语音';
    _isAlreadyNamed = !isGeneric;
    _ctrl = TextEditingController(text: isGeneric ? '' : curDisplay);
    _hintName = widget.store.speakerHintFor(
      widget.event,
      widget.turnIndex,
      widget.rawSpeaker,
    );
    _hintReason = widget.store.speakerSuggestionReasonFor(
      widget.event,
      widget.turnIndex,
      widget.rawSpeaker,
    );
    _otherCount = widget.store.countOtherMatchingTurns(
      widget.event,
      widget.turnIndex,
      widget.rawSpeaker,
    );
    _rememberVoiceprint = true;
    _applyBatch = _otherCount > 0;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    final result = await widget.store.applyQuickSpeakerNaming(
      event: widget.event,
      turnIndex: widget.turnIndex,
      rawSpeaker: widget.rawSpeaker,
      newName: name,
      rememberVoiceprint: _rememberVoiceprint,
      applyToOtherMatching: _otherCount > 0 && _applyBatch,
    );
    final savedName = _ctrl.text.trim();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final retroCount = widget.store.lastRetroSyncedEventCount;
    Navigator.of(context).pop();
    if (retroCount > 0) {
      messenger?.clearSnackBars();
      messenger?.showSnackBar(
        SnackBar(
          content: Text('已命名「$savedName」，并自动同步历史 $retroCount 条录音'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: widget.store.undoLastSpeakerNaming,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (result.frequentFull) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('已存入全库声纹识别（前 5 核心槽位已满，仍会跨记录自动识别）'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rc = context.rc;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final recentNames = widget.store.voiceprintStore.recentNames;
    final quote = (widget.sampleQuote ?? '').trim();
    final slotLabel = widget.store.displaySpeaker(
      widget.event,
      widget.rawSpeaker,
    );

    return Material(
      key: const Key('spk-quick-sheet'),
      color: rc.card,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          bottomInset + safeBottom + RCDims.pageBottomPad,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: rc.sep,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '为说话人命名',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: rc.label,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '当前标记：$slotLabel',
                        style: TextStyle(fontSize: 12, color: rc.sec),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  key: const Key('qspk-manage-vp-btn'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    if (widget.onManageVoiceprints != null) {
                      widget.onManageVoiceprints!();
                    } else {
                      widget.store.openSettingSub('voiceprint', fresh: false);
                    }
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: rc.okInk,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    '声纹管理 ›',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (quote.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: rc.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: rc.sep),
                ),
                child: Text(
                  '「$quote」',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: rc.sec,
                    height: 1.45,
                  ),
                ),
              ),
            ],
            if (_hintName != null && _hintName.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                key: const Key('qspk-fuzzy-hint'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: rc.ok.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: rc.ok.withValues(alpha: 0.28)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_outlined, size: 15, color: rc.okInk),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '可能为：$_hintName',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: rc.okInk,
                            ),
                          ),
                          if (_hintReason != null &&
                              _hintReason.trim().isNotEmpty) ...[
                            const SizedBox(height: 1),
                            Text(
                              _hintReason.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: rc.sec,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    TextButton(
                      key: const Key('qspk-apply-hint'),
                      onPressed: () {
                        setState(() {
                          _ctrl.text = _hintName;
                          _ctrl.selection = TextSelection.fromPosition(
                            TextPosition(offset: _ctrl.text.length),
                          );
                        });
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: rc.okInk,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        '填入',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const Key('qspk-name-inp'),
              controller: _ctrl,
              autofocus: false,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => unawaited(_submit()),
              decoration: InputDecoration(
                hintText: '输入姓名或称呼（如：老陈、张伟）',
                filled: true,
                fillColor: rc.bg,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: rc.sep),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: rc.sep),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: rc.label),
                ),
              ),
            ),
            if (recentNames.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '最近使用',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: rc.sec,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                key: const Key('qspk-recent-list'),
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < recentNames.length; i++)
                    ActionChip(
                      key: Key('qspk-recent-$i'),
                      label: Text(
                        recentNames[i],
                        style: TextStyle(fontSize: 12, color: rc.label),
                      ),
                      backgroundColor: rc.bg,
                      side: BorderSide(color: rc.sep),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        setState(() {
                          _ctrl.text = recentNames[i];
                          _ctrl.selection = TextSelection.fromPosition(
                            TextPosition(offset: _ctrl.text.length),
                          );
                        });
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            CheckboxListTile(
              key: const Key('qspk-chk-remember'),
              value: _rememberVoiceprint,
              onChanged: (v) =>
                  setState(() => _rememberVoiceprint = v ?? true),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                '记住声纹特征并跨记录自动识别（多设备自适应）',
                style: TextStyle(fontSize: 13, color: rc.ink),
              ),
            ),
            CheckboxListTile(
              key: const Key('qspk-chk-batch'),
              value: _otherCount > 0 ? _applyBatch : false,
              onChanged: _otherCount > 0
                  ? (v) => setState(() => _applyBatch = v ?? false)
                  : null,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                _otherCount > 0
                    ? '同改其余 $_otherCount 处同声纹发言'
                    : '同改其余 0 处（仅当前句）',
                key: const Key('qspk-other-cnt'),
                style: TextStyle(
                  fontSize: 13,
                  color: _otherCount > 0 ? rc.ink : rc.sec,
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (_isAlreadyNamed) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: const Key('qspk-detach-btn'),
                  onPressed: _saving
                      ? null
                      : () {
                          final messenger = ScaffoldMessenger.maybeOf(context);
                          widget.store.detachSpeakerForEvent(
                            event: widget.event,
                            turnIndex: widget.turnIndex,
                            rawSpeaker: widget.rawSpeaker,
                          );
                          Navigator.of(context).pop();
                          messenger?.clearSnackBars();
                          messenger?.showSnackBar(
                            SnackBar(
                              content: const Text('已解绑本段说话人，已隔离防污染声纹库'),
                              action: SnackBarAction(
                                label: '撤销',
                                onPressed: widget.store.undoLastSpeakerNaming,
                              ),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: rc.danger,
                    side: BorderSide(color: rc.danger.withValues(alpha: 0.35)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    '本段不是他（解绑本段）',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('qspk-cancel-btn'),
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: rc.ink,
                      side: BorderSide(color: rc.sep),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const Key('qspk-save-btn'),
                    onPressed: _ctrl.text.trim().isEmpty || _saving
                        ? null
                        : () => unawaited(_submit()),
                    style: FilledButton.styleFrom(
                      backgroundColor: rc.label,
                      foregroundColor: rc.card,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('确定'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
