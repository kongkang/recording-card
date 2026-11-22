/// 第三方外部数据源接入统一契约与录音模型转换器。
library;

import 'package:http/http.dart' as http;

import '../../core/models/recording.dart';

enum ExternalConnectorCategory {
  notes('笔记与阅读软件（API）', '接入 Notion、语雀、Obsidian、flomo、微信读书、印象笔记、Readwise'),
  recorders('第三方录音软件（API）', '接入 Plaud、Limitless、Omi 云端、Fireflies.ai');

  const ExternalConnectorCategory(this.title, this.subtitle);

  final String title;
  final String subtitle;
}

class ExternalFieldOption {
  const ExternalFieldOption(this.value, this.label);

  final String value;
  final String label;
}

class ExternalFieldSpec {
  const ExternalFieldSpec({
    required this.key,
    required this.label,
    this.hint = '',
    this.isSecret = false,
    this.required = true,
    this.defaultValue = '',
    this.options = const [],
    this.isBoolean = false,
    this.helperText,
  });

  final String key;
  final String label;
  final String hint;
  final bool isSecret;
  final bool required;
  final String defaultValue;
  final List<ExternalFieldOption> options;
  final bool isBoolean;
  final String? helperText;
}

class ExternalConnectorException implements Exception {
  const ExternalConnectorException(
    this.message, {
    this.statusCode,
    this.apiCode,
  });

  final String message;
  final int? statusCode;
  final String? apiCode;

  @override
  String toString() => message;
}

class ExternalTurnDraft {
  const ExternalTurnDraft({
    required this.speaker,
    required this.text,
    this.startMs = 0,
    this.endMs = 0,
  });

  final String speaker;
  final String text;
  final int startMs;
  final int endMs;
}

class ExternalRecordDraft {
  const ExternalRecordDraft({
    required this.externalId,
    required this.title,
    required this.content,
    required this.createdAt,
    this.updatedAt,
    this.rawText = '',
    this.summary = '',
    this.durationSec = 0,
    this.tags = const [],
    this.turns = const [],
    this.fingerprint,
  });

  final String externalId;
  final String title;
  final String content;
  final String rawText;
  final String summary;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final double durationSec;
  final List<String> tags;
  final List<ExternalTurnDraft> turns;

  /// 用于判断远端条目是否发生更新（例如微信读书新增划线、Notion 页面被编辑）。
  final String? fingerprint;
}

class ExternalTestResult {
  const ExternalTestResult({
    required this.message,
    this.countHint,
    this.sampleTitle,
  });

  final String message;
  final int? countHint;
  final String? sampleTitle;
}

class ExternalSyncProgress {
  const ExternalSyncProgress({
    required this.page,
    required this.fetched,
    required this.added,
    this.message,
  });

  final int page;
  final int fetched;
  final int added;
  final String? message;
}

class ExternalConnectorSyncReport {
  const ExternalConnectorSyncReport({
    this.pagesScanned = 0,
    this.fetched = 0,
    this.skippedExisting = 0,
    this.updated = 0,
    this.cancelled = false,
    this.completedFullBackfill = true,
  });

  final int pagesScanned;
  final int fetched;
  final int skippedExisting;
  final int updated;
  final bool cancelled;
  final bool completedFullBackfill;
}

abstract class ExternalDataConnector {
  String get id;
  String get name;
  ExternalConnectorCategory get category;
  String get protocolBadge;
  String get subtitle;
  String get setupGuide;
  List<ExternalFieldSpec> get fields;

  String get devicePrefix =>
      '${RecordingFile.externalDevicePrefix}${id.toUpperCase()}_';

  String deviceNameFor(String externalId) =>
      '$devicePrefix${ExternalRecordConverter.normalizeSafeId(externalId)}';

  String eventIdFor(String externalId) =>
      'ext-$id-${ExternalRecordConverter.normalizeSafeId(externalId)}';

  Map<String, String> resolveConfig(Map<String, String> raw) {
    final out = <String, String>{};
    for (final f in fields) {
      final v = (raw[f.key] ?? '').trim();
      out[f.key] = v.isNotEmpty ? v : f.defaultValue;
    }
    for (final entry in raw.entries) {
      out.putIfAbsent(entry.key, () => entry.value.trim());
    }
    return out;
  }

  bool hasRequiredConfig(Map<String, String> raw) {
    final cfg = resolveConfig(raw);
    for (final f in fields) {
      if (f.required && (cfg[f.key] ?? '').trim().isEmpty) {
        return false;
      }
    }
    return true;
  }

  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  });

  /// 连续翻页同步远端数据，通过 [onBatch] 逐页/逐批落盘。
  Future<ExternalConnectorSyncReport> sync({
    required Map<String, String> config,
    required Set<String> existingDeviceNames,
    required Map<String, String> itemFingerprints,
    required Future<void> Function(
      List<ExternalRecordDraft> batch,
      Map<String, String> updatedFingerprints,
    )
    onBatch,
    required void Function(ExternalSyncProgress progress) onProgress,
    required bool Function() isCancelled,
    required bool incremental,
    DateTime? lastSyncAt,
    http.Client? httpClient,
  });
}

class ExternalRecordConverter {
  const ExternalRecordConverter._();

  static final RegExp _safeAsciiId = RegExp(r'^[A-Za-z0-9._-]+$');
  static final RegExp _explicitSpeakerLine = RegExp(
    r'^(说话人\s*\d+|发言人\s*\d+|Speaker\s*\d+)\s*[：:]\s*(.+)$',
    caseSensitive: false,
  );

  /// 规范化外部条目 ID 为稳定、无目录冲突的磁盘标识符。
  static String normalizeSafeId(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'empty';
    if (_safeAsciiId.hasMatch(trimmed) && trimmed.length <= 64) {
      return trimmed;
    }
    final hash = _fnv1a64Hex(trimmed);
    final slug = trimmed
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (slug.isEmpty) return 'id_$hash';
    final prefix = slug.length > 24 ? slug.substring(0, 24) : slug;
    return '${prefix}_$hash';
  }

  static String _fnv1a64Hex(String input) {
    var hash = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final unit in input.codeUnits) {
      hash = ((hash ^ BigInt.from(unit)) * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static RecordingFile? toRecordingFile(
    ExternalDataConnector connector,
    ExternalRecordDraft draft,
  ) {
    final rawId = draft.externalId.trim();
    if (rawId.isEmpty) return null;

    final title = draft.title.trim();
    final content = draft.content.trim();
    final rawText = draft.rawText.trim();
    final summaryText = draft.summary.trim();

    if (title.isEmpty &&
        content.isEmpty &&
        rawText.isEmpty &&
        summaryText.isEmpty &&
        draft.turns.isEmpty) {
      return null;
    }

    final startAtMs = draft.createdAt.millisecondsSinceEpoch;
    final durationMs = (draft.durationSec * 1000).round().clamp(0, 1 << 30);
    final body = content.isNotEmpty
        ? content
        : (summaryText.isNotEmpty ? summaryText : rawText);

    final turns = _buildTurns(connector.id, draft, body);
    final utterances = _buildUtterances(connector.id, rawText, turns);

    final speakerLabels = <String>[];
    for (final t in turns) {
      final spk = t.speakerLabel.trim();
      if (spk.isEmpty || spk == '未区分' || speakerLabels.contains(spk)) continue;
      speakerLabels.add(spk);
    }

    final resolvedTitle = title.isNotEmpty
        ? title
        : _firstSentence(
            body.isNotEmpty ? body : rawText,
            fallback: '${connector.name} 笔记',
          );
    final resolvedBrief = _previewText(
      summaryText.isNotEmpty ? summaryText : body,
      fallback: resolvedTitle,
    );
    final resolvedLongText = body.isNotEmpty
        ? body
        : (rawText.isNotEmpty ? rawText : resolvedTitle);

    final uniqueTags = <String>[];
    for (final t in draft.tags) {
      final cleaned = t.trim();
      if (cleaned.isNotEmpty && !uniqueTags.contains(cleaned)) {
        uniqueTags.add(cleaned);
      }
    }
    if (!uniqueTags.contains(connector.name)) {
      uniqueTags.add(connector.name);
    }

    final deviceName = connector.deviceNameFor(rawId);
    final eventId = connector.eventIdFor(rawId);

    final segment = SegmentRecord(
      id: eventId,
      sessionId: connector.id,
      index: 0,
      startAtMs: startAtMs,
      endAtMs: startAtMs + durationMs,
      title: resolvedTitle,
      brief: resolvedBrief,
      longText: resolvedLongText,
      speakerLabels: speakerLabels,
      speakerCount: speakerLabels.length,
      tags: uniqueTags,
      status: SegmentStatus.closed,
      sliceIds: const [],
      turnIds: [for (final t in turns) t.id],
      summary: resolvedBrief,
    );

    return RecordingFile(
      deviceName: deviceName,
      session: connector.id,
      seq: 1,
      startAtMs: startAtMs,
      timeSynced: true,
      apmPath: '',
      wavPath: null,
      durationMs: durationMs,
      stage: RecordingStage.ready,
      slices: const [],
      utterances: utterances,
      turns: turns,
      segments: [segment],
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      sourceDeviceLabel: connector.name,
    );
  }

  static List<PolishedTurn> _buildTurns(
    String providerId,
    ExternalRecordDraft draft,
    String body,
  ) {
    if (draft.turns.isNotEmpty) {
      return [
        for (var i = 0; i < draft.turns.length; i++)
          () {
            final t = draft.turns[i];
            final start = t.startMs.clamp(0, 1 << 30);
            final end = t.endMs >= start ? t.endMs.clamp(0, 1 << 30) : start;
            return PolishedTurn(
              id: '$providerId-t-$i',
              startMs: start,
              endMs: end,
              speakerLabel: t.speaker.trim().isEmpty
                  ? '未区分'
                  : t.speaker.trim(),
              text: t.text.trim(),
              srcUtteranceIds: const [],
            );
          }(),
      ];
    }

    final lines = body
        .split(RegExp(r'\n+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];

    return [
      for (var i = 0; i < lines.length; i++)
        () {
          final line = lines[i];
          final m = _explicitSpeakerLine.firstMatch(line);
          final spk = m != null ? m.group(1)!.trim() : '未区分';
          final text = m != null ? m.group(2)!.trim() : line;
          return PolishedTurn(
            id: '$providerId-t-$i',
            startMs: 0,
            endMs: 0,
            speakerLabel: spk.isEmpty ? '未区分' : spk,
            text: text,
            srcUtteranceIds: const [],
          );
        }(),
    ];
  }

  static List<RawUtterance> _buildUtterances(
    String providerId,
    String rawText,
    List<PolishedTurn> turns,
  ) {
    if (rawText.isNotEmpty) {
      final paras = rawText
          .split(RegExp(r'\n+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return [
        for (var i = 0; i < paras.length; i++)
          () {
            final line = paras[i];
            final m = _explicitSpeakerLine.firstMatch(line);
            final spk = m != null ? m.group(1)!.trim() : '未区分';
            final text = m != null ? m.group(2)!.trim() : line;
            return RawUtterance(
              id: '$providerId-u-$i',
              sliceId: '0001',
              startMs: 0,
              endMs: 0,
              text: text,
              speakerLabel: spk.isEmpty ? '未区分' : spk,
            );
          }(),
      ];
    }

    return [
      for (var i = 0; i < turns.length; i++)
        RawUtterance(
          id: '$providerId-u-$i',
          sliceId: '0001',
          startMs: turns[i].startMs,
          endMs: turns[i].endMs,
          text: turns[i].text,
          speakerLabel: turns[i].speakerLabel,
        ),
    ];
  }

  static String _stripLightMarkdown(String input) {
    return input
        .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
        .replaceAll('**', '')
        .replaceAll('__', '')
        .replaceAll('`', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _firstSentence(String raw, {required String fallback}) {
    final cleaned = _stripLightMarkdown(raw);
    if (cleaned.isEmpty) return fallback;
    final head = cleaned.split(RegExp(r'[。！？!?]')).first.trim();
    final pick = head.isNotEmpty ? head : cleaned;
    return pick.length <= 24 ? pick : '${pick.substring(0, 24)}…';
  }

  static String _previewText(String raw, {required String fallback}) {
    final cleaned = _stripLightMarkdown(raw);
    if (cleaned.isEmpty) return fallback;
    return cleaned.length <= 80 ? cleaned : '${cleaned.substring(0, 80)}…';
  }
}
