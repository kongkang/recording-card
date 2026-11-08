library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/record.dart';

abstract class StorePersistence {
  Future<Map<String, dynamic>?> load();
  Future<void> save(Map<String, dynamic> state);
}

/// Native preference writes are awaited and failure is surfaced to UI.
class PreferencesStorePersistence implements StorePersistence {
  PreferencesStorePersistence({this.key = 'recording-card.ui.v2'});
  final String key;
  @override
  Future<Map<String, dynamic>?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(key);
    if (text == null) return null;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  @override
  Future<void> save(Map<String, dynamic> state) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, jsonEncode(state))) {
      throw StateError('本机状态保存失败');
    }
  }
}

/// Explicit fixture storage, never selected by a production constructor.
class MemoryStorePersistence implements StorePersistence {
  Map<String, dynamic>? state;
  @override
  Future<Map<String, dynamic>?> load() async => state == null
      ? null
      : jsonDecode(jsonEncode(state)) as Map<String, dynamic>;
  @override
  Future<void> save(Map<String, dynamic> data) async =>
      state = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
}

// Compatibility codec while C owns RecordEvent.toJson/fromJson. Only display
// fields are cached here; source paths and transcription metadata stay in C's
// authoritative RecordingRepository. UI always reloads C on startup/sync.
Map<String, dynamic> encodeDisplayRecord(RecordEvent e) => {
  'id': e.id,
  'off': e.dayOffset,
  'title': e.title,
  'brief': e.brief,
  'long': e.longText,
  'time': e.time,
  'dur': e.dur,
  'spk': e.speakers,
  'mark': e.mark,
  'map': e.srcMap,
  'dlg': [
    for (final l in e.dialog) [l.spk, l.text, l.src],
  ],
  'raw': [
    for (final l in e.raw) [l.spk, l.text, l.src],
  ],
};
RecordEvent decodeDisplayRecord(Map<String, dynamic> j) => RecordEvent(
  id: j['id'] as String,
  dayOffset: j['off'] as int,
  title: j['title'] as String,
  brief: j['brief'] as String,
  longText: j['long'] as String,
  time: j['time'] as String,
  dur: j['dur'] as String,
  speakers: j['spk'] as String,
  mark: j['mark'] as String,
  srcMap: j['map'] as String,
  dialog: [
    for (final l in j['dlg'] as List)
      TurnLine(l[0] as String, l[1] as String, l[2] as String),
  ],
  raw: [
    for (final l in j['raw'] as List)
      TurnLine(l[0] as String, l[1] as String, l[2] as String),
  ],
);
