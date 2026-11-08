/// 本地录音清单 —— 记录每条已同步录音的设备文件名、音频路径、转写文本。
///
/// 存储用 [JsonStore]（shared_preferences 上的 JSON），量级到几千条足够；
/// 音频文件本体在应用支持目录的 `recordings/` 下，清单只存路径。
library;

import '../../core/models/record.dart';
import '../../core/storage/storage.dart';

/// 分段转写结果（原始 + 清洗 + 说话人/情绪），落清单供时间轴/详情/原始数据三处展示。
class RecordingSegment {
  const RecordingSegment({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.rawText,
    required this.cleanText,
    this.speaker,
    this.emotion,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String rawText;
  final String cleanText;
  final String? speaker;
  final String? emotion;

  Map<String, dynamic> toJson() => {
        'id': id,
        'startMs': startMs,
        'endMs': endMs,
        'raw': rawText,
        'clean': cleanText,
        'speaker': speaker,
        'emotion': emotion,
      };

  static RecordingSegment? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    return RecordingSegment(
      id: id,
      startMs: (j['startMs'] as num?)?.toInt() ?? 0,
      endMs: (j['endMs'] as num?)?.toInt() ?? 0,
      rawText: (j['raw'] as String?) ?? '',
      cleanText: (j['clean'] as String?) ?? '',
      speaker: j['speaker'] as String?,
      emotion: j['emotion'] as String?,
    );
  }
}

/// 阶段总结事件（长静音切段后的标题/概览）。
class RecordingEventSummary {
  const RecordingEventSummary({
    required this.title,
    required this.overview,
    required this.startMs,
    required this.endMs,
    required this.segmentIds,
  });

  final String title;
  final String overview;
  final int startMs;
  final int endMs;
  final List<String> segmentIds;

  Map<String, dynamic> toJson() => {
        'title': title,
        'overview': overview,
        'startMs': startMs,
        'endMs': endMs,
        'segmentIds': segmentIds,
      };

  static RecordingEventSummary? fromJson(Map<String, dynamic> j) {
    final title = j['title'];
    if (title is! String) return null;
    return RecordingEventSummary(
      title: title,
      overview: (j['overview'] as String?) ?? '',
      startMs: (j['startMs'] as num?)?.toInt() ?? 0,
      endMs: (j['endMs'] as num?)?.toInt() ?? 0,
      segmentIds: [
        for (final s in (j['segmentIds'] as List? ?? const []))
          if (s is String) s
      ],
    );
  }
}

class RecordingItem {
  const RecordingItem({
    required this.deviceName,
    required this.apmPath,
    required this.wavPath,
    required this.transcript,
    required this.durationSecs,
    required this.recordedAt,
    this.segments = const [],
    this.events = const [],
  });

  /// 设备上的文件名（如 `059F19DF.APM`），作为去重键。
  final String deviceName;
  final String apmPath;
  final String? wavPath;

  /// ASR 得到的清洗后文本；空串表示还没转写成功。
  final String transcript;
  final double durationSecs;
  final DateTime recordedAt;

  /// 分段结果；为空表示旧版整文件转写（向后兼容）。
  final List<RecordingSegment> segments;

  /// 阶段总结事件；为空则不展示事件级标题/概览。
  final List<RecordingEventSummary> events;

  bool get transcribed => transcript.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'name': deviceName,
    'apm': apmPath,
    'wav': wavPath,
    'text': transcript,
    'dur': durationSecs,
    'at': recordedAt.toIso8601String(),
    'segments': [for (final s in segments) s.toJson()],
    'events': [for (final e in events) e.toJson()],
  };

  static RecordingItem? fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    final apm = j['apm'];
    if (name is! String || apm is! String) return null;
    return RecordingItem(
      deviceName: name,
      apmPath: apm,
      wavPath: j['wav'] as String?,
      transcript: (j['text'] as String?) ?? '',
      durationSecs: (j['dur'] as num?)?.toDouble() ?? 0,
      recordedAt:
          DateTime.tryParse((j['at'] as String?) ?? '') ?? DateTime.now(),
      segments: [
        for (final s in (j['segments'] as List? ?? const []))
          if (s is Map<String, dynamic>) ?RecordingSegment.fromJson(s)
      ],
      events: [
        for (final e in (j['events'] as List? ?? const []))
          if (e is Map<String, dynamic>) ?RecordingEventSummary.fromJson(e)
      ],
    );
  }

  /// 投影成界面用的 [RecordEvent]。
  ///
  /// 有分段时：对话用 cleanText、原始数据用 rawText、标题/概览用事件总结；
  /// 无分段时保持旧版整文件行为。
  /// 说话人：ASR 不含声纹分离，这里明确标「未区分」，**不编造 A/B 身份**
  /// （产品红线：推测归类必须保留原始映射，不断言真实身份）。
  RecordEvent get event {
    final now = DateTime.now();
    final day = DateTime(recordedAt.year, recordedAt.month, recordedAt.day);
    final today = DateTime(now.year, now.month, now.day);
    final offset = today.difference(day).inDays.clamp(0, 3650);
    final time = _hm(recordedAt);

    if (segments.isNotEmpty) {
      return _eventFromSegments(offset, time);
    }

    final text = transcript.trim();
    final paragraphs = _splitParagraphs(text);
    final dialog = <TurnLine>[];
    for (var i = 0; i < paragraphs.length; i++) {
      dialog.add(TurnLine('—', paragraphs[i], '来源 $time'));
    }

    return RecordEvent(
      id: _eventId,
      dayOffset: offset,
      title: _titleOf(text, time),
      brief: _briefOf(text),
      longText: paragraphs.join('\n'),
      time: time,
      dur: _durationText(durationSecs),
      speakers: paragraphs.isEmpty ? '' : '未区分',
      mark: '',
      srcMap: paragraphs.isEmpty ? '' : '来源 $time',
      dialog: dialog,
      raw: paragraphs.isEmpty ? const [] : [TurnLine('—', text, '原始转写 $time')],
    );
  }

  /// Timeline 用的投影：有阶段事件时一条事件一张卡；否则整条录音一张卡。
  List<RecordEvent> get timelineEvents {
    if (events.isEmpty) return [event];
    final byId = {for (final s in segments) s.id: s};
    final out = <RecordEvent>[];
    for (var i = 0; i < events.length; i++) {
      final summary = events[i];
      final subset = <RecordingSegment>[];
      for (final id in summary.segmentIds) {
        final s = byId[id];
        if (s != null) subset.add(s);
      }
      if (subset.isEmpty) {
        subset.addAll(segments.where(
            (s) => s.startMs >= summary.startMs && s.endMs <= summary.endMs));
      }
      if (subset.isEmpty) continue;
      final offset = _dayOffset();
      out.add(_buildEvent(
        id: '$_eventId-e$i',
        offset: offset,
        time: _hm(recordedAt.add(Duration(milliseconds: summary.startMs))),
        segs: subset,
        title: summary.title,
        overview: summary.overview,
        durationMs: summary.endMs - summary.startMs,
      ));
    }
    return out.isEmpty ? [event] : out;
  }

  RecordEvent _eventFromSegments(int offset, String time) {
    final eventTitle = events.isEmpty ? '' : events.first.title.trim();
    final overviews = [
      for (final e in events)
        if (e.overview.trim().isNotEmpty) e.overview.trim()
    ];
    return _buildEvent(
      id: _eventId,
      offset: offset,
      time: time,
      segs: segments,
      title: eventTitle,
      overview: overviews.isEmpty ? '' : overviews.join('\n'),
      durationMs: (durationSecs * 1000).round(),
    );
  }

  RecordEvent _buildEvent({
    required String id,
    required int offset,
    required String time,
    required List<RecordingSegment> segs,
    required String title,
    required String overview,
    required int durationMs,
  }) {
    final dialog = <TurnLine>[];
    final raw = <TurnLine>[];
    final speakerLabels = <String>{};
    for (final s in segs) {
      final speaker = _speakerOf(s);
      if (speaker != '未区分') speakerLabels.add(speaker);
      final range = _rangeLabel(recordedAt, s.startMs, s.endMs);
      final clean = s.cleanText.trim();
      if (clean.isNotEmpty) {
        dialog.add(TurnLine(speaker, clean, range));
      }
      final rawText = s.rawText.trim();
      if (rawText.isNotEmpty) {
        raw.add(TurnLine(
          speaker,
          rawText,
          '原始转写 ${_clockAt(recordedAt, s.startMs)}—${_clockAt(recordedAt, s.endMs)}',
        ));
      }
    }
    final cleanText = dialog.map((d) => d.text).join('\n');
    final first = segs.first;
    final last = segs.last;
    final resolvedTitle = title.trim().isEmpty ? _titleOf(cleanText, time) : title;
    final resolvedBrief =
        overview.trim().isEmpty ? _briefOf(cleanText) : overview.trim();
    return RecordEvent(
      id: id,
      dayOffset: offset,
      title: resolvedTitle,
      brief: resolvedBrief,
      longText: overview.trim().isEmpty ? cleanText : overview.trim(),
      time: time,
      dur: durationMs > 0 ? _durationText(durationMs / 1000) : _durationText(durationSecs),
      speakers: speakerLabels.isEmpty ? '未区分' : speakerLabels.join(' / '),
      mark: '',
      srcMap: _rangeLabel(recordedAt, first.startMs, last.endMs),
      dialog: dialog,
      raw: raw,
    );
  }

  int _dayOffset() {
    final now = DateTime.now();
    final day = DateTime(recordedAt.year, recordedAt.month, recordedAt.day);
    final today = DateTime(now.year, now.month, now.day);
    return today.difference(day).inDays.clamp(0, 3650);
  }

  String get _eventId =>
      'rec-${deviceName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}';

  static String _speakerOf(RecordingSegment s) {
    final value = s.speaker?.trim();
    return value == null || value.isEmpty ? '未区分' : value;
  }

  static String _hm(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

  static String _clockAt(DateTime base, int offsetMs) =>
      _hm(base.add(Duration(milliseconds: offsetMs)));

  static String _rangeLabel(DateTime base, int startMs, int endMs) =>
      '来源 ${_clockAt(base, startMs)}—${_clockAt(base, endMs)}';

  static String _titleOf(String text, String fallback) {
    if (text.isEmpty) return fallback;
    final firstLine = text.split(RegExp(r'[\n。！？!?]')).first.trim();
    if (firstLine.isEmpty) return fallback;
    return firstLine.length <= 18
        ? firstLine
        : '${firstLine.substring(0, 18)}…';
  }

  static String _briefOf(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '尚未转写';
    return flat.length <= 48 ? flat : '${flat.substring(0, 48)}…';
  }

  static List<String> _splitParagraphs(String text) {
    if (text.trim().isEmpty) return const [];
    return text
        .split(RegExp(r'\n+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static String _durationText(double secs) {
    if (secs <= 0) return '—';
    final total = secs.round();
    final m = total ~/ 60;
    final s = total % 60;
    if (m == 0) return '$s秒';
    return s == 0 ? '$m分' : '$m分$s秒';
  }
}

class RecordingsManifest {
  RecordingsManifest({JsonStore? store}) : _json = store;

  JsonStore? _json;

  Future<JsonStore> _store() async {
    final existing = _json;
    if (existing != null) return existing;
    final created = JsonStore(store: await PrefsStore.open());
    _json = created;
    return created;
  }

  Future<List<RecordingItem>> load() async {
    final json = await _store();
    final data = await json.read('recordings');
    final list = (data?['items'] as List?) ?? const [];
    final items = <RecordingItem>[];
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      final item = RecordingItem.fromJson(raw);
      if (item != null) items.add(item);
    }
    return items;
  }

  Future<void> _saveAll(List<RecordingItem> items) async {
    final json = await _store();
    await json.write('recordings', {
      'items': [for (final i in items) i.toJson()],
    });
  }

  /// 新增或覆盖同设备文件名的一条。
  Future<void> add(RecordingItem item) async {
    final items = await load();
    final next = [...items.where((i) => i.deviceName != item.deviceName), item];
    await _saveAll(next);
  }

  Future<void> updateTranscript(String deviceName, String transcript) async {
    final items = await load();
    final next = [
      for (final i in items)
        if (i.deviceName == deviceName)
          RecordingItem(
            deviceName: i.deviceName,
            apmPath: i.apmPath,
            wavPath: i.wavPath,
            transcript: transcript,
            durationSecs: i.durationSecs,
            recordedAt: i.recordedAt,
          )
        else
          i,
    ];
    await _saveAll(next);
  }

  Future<void> remove(String deviceName) async {
    final items = await load();
    await _saveAll([...items.where((i) => i.deviceName != deviceName)]);
  }
}
