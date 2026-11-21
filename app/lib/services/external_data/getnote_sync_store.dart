/// 得到大脑（Get 笔记）OpenAPI 凭据、导入偏好与增量同步控制器。
///
/// 凭据（Client ID + API Key）仅存于系统密钥库（[SecureStore] / iOS Keychain）；
/// 同步范围开关与统计摘要存于本地偏好（[KeyValueStore]）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/models/recording.dart';
import '../../core/storage/storage.dart';
import '../../core/store/app_store.dart';
import 'getnote_client.dart';
import 'getnote_converter.dart';

class GetNoteSyncResult {
  const GetNoteSyncResult({
    this.added = 0,
    this.skippedExisting = 0,
    this.skippedNonAudio = 0,
    this.hasMorePending = false,
    this.totalImported = 0,
    this.summaryText = '',
    this.error,
  });

  final int added;
  final int skippedExisting;
  final int skippedNonAudio;
  final bool hasMorePending;
  final int totalImported;
  final String summaryText;
  final String? error;

  bool get ok => error == null;
}

class GetNoteSyncStore extends ChangeNotifier {
  GetNoteSyncStore({
    SecureStore? secureStore,
    KeyValueStore? prefsStore,
    GetNoteClient? client,
  }) : _secure = secureStore ?? KeychainSecureStore(),
       _prefs = prefsStore,
       _client = client ?? GetNoteClient();

  static final GetNoteSyncStore instance = GetNoteSyncStore(
    secureStore: KeychainSecureStore(),
  );

  static const String _credsKey = 'rc_getnote_creds_v1';
  static const String _prefsKey = 'rc.extdata.getnote.v1';

  final SecureStore _secure;
  KeyValueStore? _prefs;
  final GetNoteClient _client;

  bool _loaded = false;
  Future<void>? _loading;

  String _clientId = '';
  String _apiKey = '';
  bool _importOtherNotes = false;
  bool _connectionVerified = false;
  int? _lastSyncAtMs;
  int _importedCount = 0;
  String? _lastSyncSummary;

  bool _testing = false;
  bool _syncing = false;
  String? _statusMessage;
  String? _errorMessage;
  int _syncProgressDone = 0;
  int _syncProgressTotal = 0;

  String get clientId => _clientId;
  String get apiKey => _apiKey;
  bool get hasCredentials =>
      _clientId.trim().isNotEmpty && _apiKey.trim().isNotEmpty;
  bool get importOtherNotes => _importOtherNotes;
  bool get connectionVerified => _connectionVerified;
  int? get lastSyncAtMs => _lastSyncAtMs;
  int get importedCount => _importedCount;
  String? get lastSyncSummary => _lastSyncSummary;

  bool get testing => _testing;
  bool get syncing => _syncing;
  String? get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  int get syncProgressDone => _syncProgressDone;
  int get syncProgressTotal => _syncProgressTotal;

  String get summaryStatusText {
    if (_syncing) return '同步中…';
    if (!hasCredentials) return '未配置';
    if (_importedCount > 0) return '已导入 $_importedCount 条';
    if (_connectionVerified) return '已连接';
    return '已配置';
  }

  Future<KeyValueStore> _ensurePrefs() async {
    final existing = _prefs;
    if (existing != null) return existing;
    try {
      final opened = await PrefsStore.open();
      _prefs = opened;
      return opened;
    } on Object {
      final mem = InMemoryStore();
      _prefs = mem;
      return mem;
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    final pending = _loading ??= _loadInternal();
    try {
      await pending;
    } finally {
      if (identical(_loading, pending)) _loading = null;
    }
  }

  Future<void> _loadInternal() async {
    try {
      final creds = await _secure.readJson(_credsKey);
      if (creds != null) {
        _clientId = '${creds['clientId'] ?? ''}'.trim();
        _apiKey = GetNoteClient.normalizeApiKey('${creds['apiKey'] ?? ''}');
      }
    } on Object catch (e) {
      debugPrint('[getnote] 读取密钥库失败，按未配置处理: $e');
    }

    try {
      final prefs = await _ensurePrefs();
      final raw = await prefs.getString(_prefsKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final m = Map<String, dynamic>.from(decoded);
          _importOtherNotes = m['importOtherNotes'] == true;
          _connectionVerified = m['connectionVerified'] == true;
          _lastSyncAtMs = (m['lastSyncAtMs'] as num?)?.toInt();
          _importedCount = ((m['importedCount'] as num?)?.toInt() ?? 0).clamp(
            0,
            1 << 30,
          );
          final summary = m['lastSyncSummary'] as String?;
          _lastSyncSummary = (summary != null && summary.trim().isNotEmpty)
              ? summary.trim()
              : null;
        }
      }
    } on Object catch (e) {
      debugPrint('[getnote] 读取同步偏好失败: $e');
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await _ensurePrefs();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'importOtherNotes': _importOtherNotes,
          'connectionVerified': _connectionVerified,
          if (_lastSyncAtMs != null) 'lastSyncAtMs': _lastSyncAtMs,
          'importedCount': _importedCount,
          if (_lastSyncSummary != null) 'lastSyncSummary': _lastSyncSummary,
        }),
      );
    } on Object catch (e) {
      debugPrint('[getnote] 写入同步偏好失败: $e');
    }
  }

  Future<void> saveCredentials({
    required String clientId,
    required String apiKey,
  }) async {
    await load();
    final nextCid = clientId.trim();
    final nextKey = GetNoteClient.normalizeApiKey(apiKey);
    final changed = nextCid != _clientId || nextKey != _apiKey;
    _clientId = nextCid;
    _apiKey = nextKey;
    if (changed) {
      _connectionVerified = false;
    }
    try {
      if (hasCredentials) {
        await _secure.writeJson(_credsKey, {
          'clientId': _clientId,
          'apiKey': _apiKey,
        });
      } else {
        await _secure.delete(_credsKey);
      }
    } on Object catch (e) {
      debugPrint('[getnote] 保存密钥库失败: $e');
    }
    if (changed) {
      await _savePrefs();
    }
    notifyListeners();
  }

  Future<void> setImportOtherNotes(bool value) async {
    await load();
    if (_importOtherNotes == value) return;
    _importOtherNotes = value;
    await _savePrefs();
    notifyListeners();
  }

  Future<bool> testConnection({String? clientId, String? apiKey}) async {
    await load();
    if (clientId != null || apiKey != null) {
      await saveCredentials(
        clientId: clientId ?? _clientId,
        apiKey: apiKey ?? _apiKey,
      );
    }
    if (!hasCredentials) {
      _errorMessage = '请先填写 Client ID 与 API Key';
      _statusMessage = null;
      _connectionVerified = false;
      notifyListeners();
      return false;
    }

    _testing = true;
    _errorMessage = null;
    _statusMessage = '正在连接得到大脑 OpenAPI…';
    notifyListeners();

    try {
      final res = await _client.testConnection(
        clientId: _clientId,
        apiKey: _apiKey,
      );
      _connectionVerified = true;
      _errorMessage = null;
      _statusMessage = res.sampleTitle != null && res.sampleTitle!.isNotEmpty
          ? '连接成功（最近笔记：《${res.sampleTitle}》）'
          : '连接成功，OpenAPI 鉴权有效';
      await _savePrefs();
      return true;
    } on GetNoteApiException catch (e) {
      _connectionVerified = false;
      _errorMessage = e.message;
      _statusMessage = null;
      await _savePrefs();
      return false;
    } on Object catch (e) {
      _connectionVerified = false;
      _errorMessage = '测试连接失败：$e';
      _statusMessage = null;
      await _savePrefs();
      return false;
    } finally {
      _testing = false;
      notifyListeners();
    }
  }

  Future<GetNoteSyncResult> syncNow({
    required AppStore appStore,
    String? clientId,
    String? apiKey,
    int maxPages = 10,
    int maxNewDetails = 50,
  }) async {
    await load();
    if (clientId != null || apiKey != null) {
      await saveCredentials(
        clientId: clientId ?? _clientId,
        apiKey: apiKey ?? _apiKey,
      );
    }
    if (!hasCredentials) {
      const msg = '请先填写 Client ID 与 API Key';
      _errorMessage = msg;
      _statusMessage = null;
      notifyListeners();
      return const GetNoteSyncResult(error: msg);
    }

    if (_syncing) {
      return GetNoteSyncResult(
        totalImported: _importedCount,
        summaryText: _lastSyncSummary ?? '正在同步中，请稍候…',
      );
    }

    _syncing = true;
    _errorMessage = null;
    _statusMessage = '正在拉取得到大脑笔记列表…';
    _syncProgressDone = 0;
    _syncProgressTotal = 0;
    notifyListeners();

    try {
      final existing = await appStore.existingExternalDeviceNames();
      final seenInRun = <String>{...existing};
      final toFetch = <GetNoteSummary>[];
      var skippedExisting = 0;
      var skippedNonAudio = 0;
      var hasMorePending = false;
      String? cursor;

      for (var pageIdx = 0; pageIdx < maxPages; pageIdx++) {
        final page = await _client.listNotes(
          clientId: _clientId,
          apiKey: _apiKey,
          pageSize: 50,
          cursor: cursor,
        );

        for (final note in page.notes) {
          if (note.noteId.isEmpty) continue;
          if (!_importOtherNotes && !note.isAudioOrMeeting) {
            skippedNonAudio++;
            continue;
          }
          final devName = '${RecordingFile.getNoteDevicePrefix}${note.noteId}';
          if (seenInRun.contains(devName)) {
            skippedExisting++;
            continue;
          }
          seenInRun.add(devName);
          if (toFetch.length >= maxNewDetails) {
            hasMorePending = true;
            break;
          }
          toFetch.add(note);
        }

        if (hasMorePending) break;
        if (!page.hasMore ||
            page.nextCursor == null ||
            page.nextCursor == cursor) {
          break;
        }
        cursor = page.nextCursor;
        if (pageIdx + 1 >= maxPages) {
          hasMorePending = true;
        }
      }

      final converted = <RecordingFile>[];
      if (toFetch.isNotEmpty) {
        _syncProgressTotal = toFetch.length;
        _syncProgressDone = 0;
        _statusMessage = '正在导入 0/${toFetch.length} 条笔记…';
        notifyListeners();

        for (var i = 0; i < toFetch.length; i++) {
          final summary = toFetch[i];
          final detail = await _client.getNoteDetail(
            clientId: _clientId,
            apiKey: _apiKey,
            noteId: summary.noteId,
          );
          final file = GetNoteConverter.toRecordingFile(
            detail,
            fallback: summary,
          );
          if (file != null) {
            converted.add(file);
          }
          _syncProgressDone = i + 1;
          _statusMessage = '正在导入 ${i + 1}/${toFetch.length} 条笔记…';
          notifyListeners();
        }
      }

      final added = converted.isEmpty
          ? 0
          : await appStore.ingestExternalRecordings(converted);
      final latestExisting = await appStore.existingExternalDeviceNames();
      _importedCount = latestExisting.length;
      _connectionVerified = true;
      _lastSyncAtMs = DateTime.now().millisecondsSinceEpoch;

      final parts = <String>[
        '本次新增 $added 条',
        '跳过已导入 $skippedExisting 条',
        if (skippedNonAudio > 0) '过滤非录音文字笔记 $skippedNonAudio 条',
      ];
      final summaryText =
          parts.join('，') +
          (hasMorePending ? '（还有更多历史笔记，可再次点击同步）' : '');
      _lastSyncSummary = summaryText;
      _statusMessage = summaryText;
      _errorMessage = null;
      await _savePrefs();

      return GetNoteSyncResult(
        added: added,
        skippedExisting: skippedExisting,
        skippedNonAudio: skippedNonAudio,
        hasMorePending: hasMorePending,
        totalImported: _importedCount,
        summaryText: summaryText,
      );
    } on GetNoteApiException catch (e) {
      _errorMessage = e.message;
      _statusMessage = null;
      return GetNoteSyncResult(
        totalImported: _importedCount,
        error: e.message,
      );
    } on Object catch (e) {
      final msg = '同步得到大脑笔记失败：$e';
      _errorMessage = msg;
      _statusMessage = null;
      return GetNoteSyncResult(totalImported: _importedCount, error: msg);
    } finally {
      _syncing = false;
      _syncProgressDone = 0;
      _syncProgressTotal = 0;
      notifyListeners();
    }
  }

  Future<void> clearAll() async {
    _clientId = '';
    _apiKey = '';
    _importOtherNotes = false;
    _connectionVerified = false;
    _lastSyncAtMs = null;
    _importedCount = 0;
    _lastSyncSummary = null;
    _statusMessage = null;
    _errorMessage = null;
    _syncProgressDone = 0;
    _syncProgressTotal = 0;
    try {
      await _secure.delete(_credsKey);
    } on Object catch (e) {
      debugPrint('[getnote] 清理密钥库失败: $e');
    }
    try {
      final prefs = await _ensurePrefs();
      await prefs.remove(_prefsKey);
    } on Object catch (e) {
      debugPrint('[getnote] 清理同步偏好失败: $e');
    }
    notifyListeners();
  }
}
