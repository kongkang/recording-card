/// 把业务模型 [SummaryCard] 与关联 [RecordEvent] 映射成完整两部分导出用的 [ExportDocument]：
/// - 第一部分：图文纪要（概览与关键现场图 / 逻辑结构 / 信息点与配图 / 行动项 / 来源记录）
/// - 第二部分：文字记录（默认 AI 智能优化版，可选原文；联动确认后的说话人标记）
library;

import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import 'export_document.dart';

ExportDocument exportDocumentFromSummary(
  SummaryCard card, {
  List<RecordEvent> sourceEvents = const [],
  TranscriptExportMode transcriptMode = TranscriptExportMode.aiOptimized,
  List<ExportImageItem> Function(RecordEvent event)? photosResolver,
  String Function(RecordEvent event, String rawSpeaker)? speakerResolver,
  String Function(RecordEvent event, int turnIndex, String rawSpeaker)?
  turnSpeakerResolver,
  bool preferResolvedTurns = false,
  String Function(String text, List<RecordEvent> events)? aliasTextTransformer,
}) {
  final orderedEvents = sortEventsChronological(sourceEvents);
  final eventsById = {for (final e in orderedEvents) e.id: e};

  String transformText(String raw) =>
      aliasTextTransformer?.call(raw, orderedEvents) ?? raw;

  String resolveSpk(RecordEvent event, String rawSpk, [int? turnIndex]) =>
      (turnIndex != null
          ? turnSpeakerResolver?.call(event, turnIndex, rawSpk)
          : null) ??
      speakerResolver?.call(event, rawSpk) ??
      (rawSpk.trim().startsWith('说话人') || rawSpk.trim() == '未区分'
          ? rawSpk.trim()
          : '说话人 ${rawSpk.trim()}（推测）');

  List<ExportImageItem> photosForEvent(RecordEvent event) {
    if (photosResolver != null) return photosResolver(event);
    return [
      for (final p in event.photos)
        if (!p.excluded)
          ExportImageItem(
            path: p.path,
            caption: '${event.title} · 现场照片（${p.time}）',
          ),
    ];
  }

  final allScenePhotos = <ExportImageItem>[
    for (final e in orderedEvents) ...photosForEvent(e),
  ];

  final sections = <ExportSection>[
    const ExportSection(heading: '第一部分：图文纪要', isPartHeader: true),
  ];

  final overviewText = transformText((card.overview ?? '').trim());
  if (overviewText.isNotEmpty || allScenePhotos.isNotEmpty) {
    sections.add(
      ExportSection(
        heading: '概览',
        body: overviewText.isEmpty ? null : overviewText,
        images: allScenePhotos.take(4).toList(growable: false),
      ),
    );
  }

  if (card.structure.isNotEmpty) {
    sections.add(
      ExportSection(
        heading: '逻辑结构',
        bullets: [
          for (final branch in card.structure)
            transformText(
              branch.leaves.isEmpty
                  ? branch.name
                  : '${branch.name}：${branch.leaves.join('、')}',
            ),
        ],
      ),
    );
  }

  if (card.points.isNotEmpty) {
    final pointImages = <ExportImageItem>[];
    final seenImgKeys = <String>{};
    for (final p in card.points) {
      for (final s in p.sources) {
        final ev = eventsById[s.eventId];
        if (ev == null) continue;
        for (final img in photosForEvent(ev)) {
          final k = '${img.path}|${img.caption}';
          if (seenImgKeys.add(k)) pointImages.add(img);
        }
      }
    }
    sections.add(
      ExportSection(
        heading: '信息点',
        bullets: [
          for (final p in card.points)
            if (p.sources.isNotEmpty)
              '来源：${p.sources.map((s) => '${s.label} · ${s.range}').join('、')}',
        ],
        body: card.points
            .map((p) => transformText('${p.title}\n${p.detail}'))
            .join('\n\n'),
        images: pointImages,
      ),
    );
  }

  if (card.todos.isNotEmpty) {
    sections.add(
      ExportSection(
        heading: '行动项',
        bullets: [for (final t in card.todos) transformText(t)],
        ordered: true,
      ),
    );
  }

  final srcDesc = card.srcDesc;
  if (srcDesc != null && srcDesc.trim().isNotEmpty) {
    sections.add(
      ExportSection(
        heading: '来源记录',
        bullets: srcDesc.split('；').where((s) => s.trim().isNotEmpty).toList(),
      ),
    );
  }

  sections.add(
    ExportSection(
      heading: '第二部分：文字记录（${transcriptMode.label}）',
      isPartHeader: true,
    ),
  );

  if (transcriptMode == TranscriptExportMode.aiOptimized) {
    var addedAnyEventTranscript = false;
    for (final e in orderedEvents) {
      final eventImages = photosForEvent(e);
      if (isSilentPlaceholderEvent(e) && eventImages.isEmpty) continue;
      final turns = e.dialog.isNotEmpty ? e.dialog : e.raw;
      final turnLines = <String>[
        for (var ti = 0; ti < turns.length; ti++)
          if (cleanSpokenFillers(turns[ti].text).isNotEmpty)
            '${turns[ti].src.replaceFirst('来源 ', '').trim()} · ${resolveSpk(e, turns[ti].spk, ti)}：${transformText(cleanSpokenFillers(turns[ti].text))}',
      ];
      final fallback = isSilentPlaceholderEvent(e)
          ? ''
          : transformText(
              (e.longText.trim().isNotEmpty ? e.longText : e.brief).trim(),
            );
      final bodyText = turnLines.isNotEmpty ? turnLines.join('\n') : fallback;
      if (bodyText.isEmpty && eventImages.isEmpty) continue;
      if (bodyText.isNotEmpty) addedAnyEventTranscript = true;
      sections.add(
        ExportSection(
          heading: '${e.time} · ${e.title}（${e.dur}）',
          body: bodyText.isEmpty ? null : bodyText,
          images: eventImages,
        ),
      );
    }
    // 仅当 orderedEvents 为空（或无可用事件文本）时回退输出 card.fullText，避免同一批对话重复导出两遍
    if (!addedAnyEventTranscript) {
      final resolvedFull = card.resolvedFullText(
        orderedEvents,
        speakerResolver: speakerResolver,
        turnSpeakerResolver: turnSpeakerResolver,
        preferResolvedTurns: preferResolvedTurns,
        aliasTextTransformer: aliasTextTransformer,
      );
      if (resolvedFull.isNotEmpty) {
        sections.add(
          ExportSection(
            heading: '全文（AI 智能优化版）',
            body: resolvedFull,
          ),
        );
      }
    }
  } else {
    if (orderedEvents.isEmpty && card.fullText.trim().isNotEmpty) {
      sections.add(
        ExportSection(
          heading: '原始文字记录',
          body: card.resolvedFullText(
            orderedEvents,
            speakerResolver: speakerResolver,
            turnSpeakerResolver: turnSpeakerResolver,
            preferResolvedTurns: preferResolvedTurns,
            aliasTextTransformer: aliasTextTransformer,
          ),
        ),
      );
    }
    for (final e in orderedEvents) {
      final eventImages = photosForEvent(e);
      if (isSilentPlaceholderEvent(e) && eventImages.isEmpty) continue;
      final rawTurns = e.raw;
      final lines = <String>[];
      if (rawTurns.isNotEmpty) {
        for (var ti = 0; ti < rawTurns.length; ti++) {
          final t = rawTurns[ti];
          lines.add('${t.src} · ${resolveSpk(e, t.spk, ti)}：${t.text}');
        }
      } else if (e.dialog.isNotEmpty) {
        lines.add('（该记录无独立未润色原文，以下为本地转写内容）');
        for (var ti = 0; ti < e.dialog.length; ti++) {
          final t = e.dialog[ti];
          lines.add('${t.src} · ${resolveSpk(e, t.spk, ti)}：${t.text}');
        }
      } else if (!isSilentPlaceholderEvent(e)) {
        final fallback = (e.longText.trim().isNotEmpty ? e.longText : e.brief)
            .trim();
        if (fallback.isNotEmpty) lines.add(fallback);
      }
      if (lines.isEmpty && eventImages.isEmpty) continue;
      sections.add(
        ExportSection(
          heading: '${e.time} · ${e.title}（${e.dur}）',
          body: lines.isEmpty ? null : lines.join('\n'),
          images: eventImages,
        ),
      );
    }
  }

  return ExportDocument(
    title: card.title ?? '录音总结',
    meta: card.subDesc ?? '',
    overview: overviewText,
    sections: sections,
    markdown: card.markdown ?? '',
    transcriptMode: transcriptMode,
    overviewImages: allScenePhotos.take(4).toList(growable: false),
  );
}
