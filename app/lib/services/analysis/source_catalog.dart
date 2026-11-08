import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import 'analysis_gateway.dart';

class SourceCatalog {
  final Map<String, RecordEvent> events;
  final Map<String, List<SourceRef>> _refs = {};
  final Map<String, Set<int>> _selected = {};
  SourceCatalog(
    List<RecordEvent> selected, {
    Map<String, List<int>>? selectedRawIndices,
  }) : events = {for (final e in selected) e.id: e} {
    if (selected.isEmpty ||
        events.length != selected.length ||
        selected.any((e) => e.id.trim().isEmpty)) {
      throw const AnalysisException('selection_invalid', '请选择唯一且有效的录音记录');
    }
    if (selectedRawIndices != null &&
        selectedRawIndices.keys.any((id) => !events.containsKey(id))) {
      throw const AnalysisException('selection_invalid', '选段包含未选录音');
    }
    for (final e in selected) {
      if (e.raw.isEmpty || e.raw.every((line) => line.text.trim().isEmpty)) {
        throw const AnalysisException(
          'transcript_missing',
          '所选记录尚无原始转写，请先完成本地ASR',
        );
      }
      final indices =
          selectedRawIndices?[e.id] ?? List.generate(e.raw.length, (i) => i);
      if (indices.isEmpty ||
          indices.toSet().length != indices.length ||
          indices.any((i) => i < 0 || i >= e.raw.length)) {
        throw const AnalysisException('selection_invalid', '选段索引为空、重复或越界');
      }
      _selected[e.id] = indices.toSet();
      final bounds = _clockRange(e.srcMap);
      if (bounds == null) {
        throw const AnalysisException('source_invalid', '所选录音缺少可校验来源时间范围');
      }
      // Build all indices, but validate only selected rows and never disclose
      // unselected rows in prompt. Resolve enforces the same whitelist.
      _refs[e.id] = [
        for (var i = 0; i < e.raw.length; i++)
          _selected[e.id]!.contains(i)
              ? _fromLine(e, e.raw[i], bounds)
              : SourceRef(e.id, e.title, ''),
      ];
    }
  }
  int selectedCount(String id) => _selected[id]!.length;
  int get totalSelectedRows =>
      _selected.values.fold(0, (n, values) => n + values.length);

  SourceRef _fromLine(RecordEvent event, TurnLine line, (int, int) bounds) {
    final rawPart = line.src.split(RegExp('[｜|]')).first;
    final span = _clockRange(rawPart);
    if (span == null) {
      throw const AnalysisException('source_invalid', '原始转写缺少时间范围');
    }
    var start = span.$1;
    if (bounds.$2 >= 86400 && start < bounds.$1) {
      start += 86400;
    }
    final duration = span.$2 - span.$1;
    if (start < bounds.$1 || start + duration > bounds.$2) {
      throw const AnalysisException('source_invalid', '原始转写时间超出所选录音范围');
    }
    final label = rawPart.trim().replaceFirst(RegExp(r'^来源\s*'), '');
    return SourceRef(event.id, event.title, label);
  }

  SourceRef resolve(dynamic data) {
    final m = requiredMap(data, 'source');
    final id = m['sourceId'];
    final index = m['rawIndex'];
    if (id is! String ||
        !events.containsKey(id) ||
        index is! int ||
        !_selected[id]!.contains(index)) {
      throw const AnalysisException('source_invalid', '模型引用了未选记录或未选原始行');
    }
    if (m.keys.any((k) => k != 'sourceId' && k != 'rawIndex')) {
      throw const AnalysisException(
        'source_invalid',
        '来源只允许sourceId/rawIndex，不能生成时间或标签',
      );
    }
    return _refs[id]![index];
  }

  List<SourceRef> resolveList(dynamic value) => [
    for (final s in requiredList(value, 'sources')) resolve(s),
  ];

  List<Map<String, dynamic>> get promptRecords => [
    for (final e in events.values)
      {
        'sourceId': e.id, 'title': e.title,
        'raw': [
          for (var i = 0; i < e.raw.length; i++)
            if (_selected[e.id]!.contains(i))
              {
                'rawIndex': i,
                'text': e.raw[i].text,
                'range': _refs[e.id]![i].range,
                'speakerHint': e.raw[i].spk,
                'speakerHintUnverified': true,
              },
        ],
        // Use only cleaned rows with an EXACT source-range match; no unselected
        // context from brief/longText or loosely grouped dialogue can leak in.
        'cleaned': [
          for (final line in e.dialog)
            if (_selected[e.id]!.any(
              (i) =>
                  line.src
                      .split(RegExp('[｜|]'))
                      .first
                      .trim()
                      .replaceFirst(RegExp(r'^来源\s*'), '') ==
                  _refs[e.id]![i].range,
            ))
              {'text': line.text, 'range': line.src, 'speakerHint': line.spk},
        ],
      },
  ];

  static (int, int)? _clockRange(String label) {
    final match = RegExp(
      r'(\d{1,2}:\d{2}(?::\d{2})?)\s*[—–-]\s*(\d{1,2}:\d{2}(?::\d{2})?)',
    ).firstMatch(label);
    if (match == null) {
      return null;
    }
    int? seconds(String text) {
      final p = text.split(':').map(int.parse).toList();
      if (p[0] > 23 || p[1] > 59 || (p.length == 3 && p[2] > 59)) {
        return null;
      }
      return p[0] * 3600 + p[1] * 60 + (p.length == 3 ? p[2] : 0);
    }

    final start = seconds(match.group(1)!);
    var end = seconds(match.group(2)!);
    if (start == null || end == null) {
      return null;
    }
    if (end < start) {
      end += 86400;
    }
    return (start, end);
  }
}
