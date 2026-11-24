/// 本地录音清单 —— 记录每条已同步录音的设备文件名、音频路径、转写文本。
///
/// 存储用 [JsonStore]（shared_preferences 上的 JSON），量级到几千条足够；
/// 音频文件本体在应用支持目录的 `recordings/` 下，清单只存路径。
library;

import '../../core/models/record.dart';
import '../../core/storage/storage.dart';

class RecordingItem {
  const RecordingItem({
    required this.deviceName,
    required this.apmPath,
    required this.wavPath,
    required this.transcript,
    required this.durationSecs,
    required this.recordedAt,
  });

  /// 设备上的文件名（如 `059F19DF.APM`），作为去重键。
  final String deviceName;
  final String apmPath;
  final String? wavPath;

  /// ASR 得到的清洗后文本；空串表示还没转写成功。
  final String transcript;
  final double durationSecs;
  final DateTime recordedAt;

  bool get transcribed => transcript.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'name': deviceName,
    'apm': apmPath,
    'wav': wavPath,
    'text': transcript,
    'dur': durationSecs,
    'at': recordedAt.toIso8601String(),
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
    );
  }

  /// 投影成界面用的 [RecordEvent]。
  ///
  /// 说话人：ASR 不含声纹分离，这里明确标「未区分」，**不编造 A/B 身份**
  /// （产品红线：推测归类必须保留原始映射，不断言真实身份）。
  RecordEvent get event {
    final text = transcript.trim();
    final now = DateTime.now();
    final day = DateTime(recordedAt.year, recordedAt.month, recordedAt.day);
    final today = DateTime(now.year, now.month, now.day);
    final offset = today.difference(day).inDays.clamp(0, 3650);
    final hh = recordedAt.hour.toString().padLeft(2, '0');
    final mm = recordedAt.minute.toString().padLeft(2, '0');
    final time = '$hh:$mm';

    final paragraphs = _splitParagraphs(text);
    final dialog = <TurnLine>[];
    for (var i = 0; i < paragraphs.length; i++) {
      dialog.add(TurnLine('—', paragraphs[i], '来源 $time'));
    }

    return RecordEvent(
      id: 'rec-${deviceName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}',
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

  Future<void> clear() async {
    final json = await _store();
    await json.remove('recordings');
  }
}
