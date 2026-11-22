/// 声纹与语义线索轻确认横幅 —— 展示“说话人 N → 疑似称呼”待确认卡片，支持 1-Tap 确认 / 全部确认 / 改名 / 忽略。
library;

import 'package:flutter/material.dart';

import '../core/models/record.dart';
import '../core/store/app_store.dart';
import '../core/store/voiceprint_library_store.dart';
import '../core/theme/tokens.dart';
import 'quick_speaker_sheet.dart';

class SpeakerSuggestionBanner extends StatelessWidget {
  const SpeakerSuggestionBanner({
    super.key,
    required this.store,
    required this.eventIds,
    this.margin = const EdgeInsets.only(bottom: 12),
  });

  final AppStore store;
  final List<String> eventIds;
  final EdgeInsetsGeometry margin;

  static String _slotToken(String slot) {
    final m = RegExp(r'(\d+)$').firstMatch(slot.trim());
    return m != null ? m.group(1)! : slot.trim();
  }

  static int _firstTurnIndexForSlot(RecordEvent event, String slot) {
    final turns = event.dialog.isNotEmpty ? event.dialog : event.raw;
    final cleanSlot = AppStore.normalizeSpeakerSlot(slot);
    for (var i = 0; i < turns.length; i++) {
      if (AppStore.normalizeSpeakerSlot(turns[i].spk) == cleanSlot) {
        return i;
      }
    }
    return 0;
  }

  static String _sourceBadgeText(SpeakerSuggestionSource source) {
    switch (source) {
      case SpeakerSuggestionSource.joint:
        return '声纹+语义';
      case SpeakerSuggestionSource.voiceprint:
        return '声纹匹配';
      case SpeakerSuggestionSource.semantic:
        return '对话线索';
    }
  }

  Future<void> _confirmSingle(
    BuildContext context,
    ({
      RecordEvent event,
      SpeakerCandidateSuggestion suggestion,
      String sampleQuote,
    })
    item,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final res = await store.confirmSpeakerSuggestion(
      event: item.event,
      suggestion: item.suggestion,
    );
    if (!res.saved || messenger == null) return;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          res.retroSyncedCount > 0
              ? '已确认「${item.suggestion.candidateName}」，并自动同步历史 ${res.retroSyncedCount} 条录音'
              : '已确认「${item.suggestion.candidateName}」，后续同声纹将自动标记',
        ),
        action: res.retroSyncedCount > 0
            ? SnackBarAction(
                label: '撤销',
                onPressed: store.undoLastSpeakerNaming,
              )
            : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _confirmAll(
    BuildContext context,
    List<
      ({
        RecordEvent event,
        SpeakerCandidateSuggestion suggestion,
        String sampleQuote,
      })
    >
    items,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final res = await store.confirmAllSpeakerSuggestions(items);
    if (res.confirmedCount <= 0 || messenger == null) return;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          res.retroSyncedCount > 0
              ? '已确认 ${res.confirmedCount} 位说话人，并自动同步历史 ${res.retroSyncedCount} 条录音'
              : '已全部确认 ${res.confirmedCount} 位说话人，声纹已入库',
        ),
        action: res.retroSyncedCount > 0
            ? SnackBarAction(
                label: '撤销',
                onPressed: store.undoLastSpeakerNaming,
              )
            : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, store.voiceprintStore]),
      builder: (context, _) {
        final items = store.pendingSpeakerSuggestionsFor(eventIds);
        if (items.isEmpty) return const SizedBox.shrink();

        final rc = context.rc;
        return Container(
          key: const Key('spk-suggest-bar'),
          margin: margin,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: rc.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: rc.okInk.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 15, color: rc.okInk),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '识别到 ${items.length} 位待确认说话人',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: rc.label,
                      ),
                    ),
                  ),
                  if (items.length >= 2)
                    GestureDetector(
                      key: const Key('spk-suggest-confirm-all'),
                      onTap: () => _confirmAll(context, items),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: rc.okInk,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          '全部确认',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Divider(height: 1, thickness: 0.5, color: rc.sep),
                  ),
                _SuggestionRow(
                  rc: rc,
                  item: items[i],
                  slotToken: _slotToken(items[i].suggestion.speakerSlot),
                  sourceBadge: _sourceBadgeText(items[i].suggestion.source),
                  onConfirm: () => _confirmSingle(context, items[i]),
                  onEdit: () => showQuickSpeakerSheet(
                    context,
                    store: store,
                    event: items[i].event,
                    turnIndex: _firstTurnIndexForSlot(
                      items[i].event,
                      items[i].suggestion.speakerSlot,
                    ),
                    rawSpeaker: items[i].suggestion.speakerSlot,
                    sampleQuote: items[i].sampleQuote,
                  ),
                  onDismiss: () => store.dismissSpeakerSuggestion(
                    event: items[i].event,
                    suggestion: items[i].suggestion,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.rc,
    required this.item,
    required this.slotToken,
    required this.sourceBadge,
    required this.onConfirm,
    required this.onEdit,
    required this.onDismiss,
  });

  final RCColorScheme rc;
  final ({
    RecordEvent event,
    SpeakerCandidateSuggestion suggestion,
    String sampleQuote,
  })
  item;
  final String slotToken;
  final String sourceBadge;
  final VoidCallback onConfirm;
  final VoidCallback onEdit;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final sug = item.suggestion;
    final eid = item.event.id;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '${sug.speakerSlot} → 疑似「${sug.candidateName}」',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: rc.label,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: rc.bg,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: rc.sep),
                    ),
                    child: Text(
                      sourceBadge,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: rc.sec,
                      ),
                    ),
                  ),
                ],
              ),
              if (sug.reason.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  sug.reason.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: rc.sec),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          key: Key('spk-suggest-confirm-$eid-$slotToken'),
          onTap: onConfirm,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: rc.okInk.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: rc.okInk.withValues(alpha: 0.35)),
            ),
            child: Text(
              '确认',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: rc.okInk,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          key: Key('spk-suggest-edit-$eid-$slotToken'),
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: Text(
              '改名',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: rc.sec,
              ),
            ),
          ),
        ),
        GestureDetector(
          key: Key('spk-suggest-dismiss-$eid-$slotToken'),
          onTap: onDismiss,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.close_rounded, size: 15, color: rc.sec),
          ),
        ),
      ],
    );
  }
}
