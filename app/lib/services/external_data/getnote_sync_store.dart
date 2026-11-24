/// 得到大脑（Get 笔记）OpenAPI 凭据、导入偏好与增量同步控制器。
///
/// 凭据（Client ID + API Key）仅存于系统密钥库（[SecureStore] / iOS Keychain）；
/// 同步范围开关与统计摘要存于本地偏好（[KeyValueStore]）。
library;

import 'dart:async';
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
    this.pagesScanned = 0,
    this.hasMorePending = false,
    this.cancelled = false,
    this.totalImported = 0,
    this.summaryText = '',
    this.error,
  });

  final int added;
  final int skippedExisting;
  final int skippedNonAudio;
  final int pagesScanned;
  final bool hasMorePending;
  final bool cancelled;
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
  bool _autoImport = false;
  int _checkIntervalMinutes = 60;
  bool _connectionVerified = false;
  int? _lastSyncAtMs;
  int? _lastAutoCheckAtMs;
  int _importedCount = 0;
  String? _lastSyncSummary;
  bool _fullBackfillCompleted = false;

  bool _testing = false;
  bool _syncing = false;
  bool _cancelling = false;
  bool _cancelRequested = false;
  String? _statusMessage;
  String? _errorMessage;
  int _syncProgressDone = 0;
  int _syncProgressTotal = 0;
  int _syncCurrentPage = 0;
  int _syncFetchedTotal = 0;

  String get clientId => _clientId;
  String get apiKey => _apiKey;
  bool get hasCredentials =>
      _clientId.trim().isNotEmpty && _apiKey.trim().isNotEmpty;
  bool get importOtherNotes => _importOtherNotes;
  bool get autoImport => _autoImport;
  int get checkIntervalMinutes => _checkIntervalMinutes;
  bool get connectionVerified => _connectionVerified;
  int? get lastSyncAtMs => _lastSyncAtMs;
  int? get lastAutoCheckAtMs => _lastAutoCheckAtMs;
  int get importedCount => _importedCount;
  String? get lastSyncSummary => _lastSyncSummary;
  bool get fullBackfillCompleted => _fullBackfillCompleted;

  bool get testing => _testing;
  bool get syncing => _syncing;
  bool get cancelling => _cancelling;
  String? get statusMessage => _statusMessage;
  String? get errorMessage => _errorMessage;
  int get syncProgressDone => _syncProgressDone;
  int get syncProgressTotal => _syncProgressTotal;
  int get syncCurrentPage => _syncCurrentPage;
  int get syncFetchedTotal => _syncFetchedTotal;

  String get summaryStatusText {
    if (_syncing) return '同步中…';
    if (!hasCredentials) return '未配置';
    if (_autoImport) {
      return _importedCount > 0 ? '自动同步 · 已导入 $_importedCount 条' : '自动同步已开启';
    }
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
          _autoImport = m['autoImport'] == true;
          final interval = (m['checkIntervalMinutes'] as num?)?.toInt();
          if (interval != null && interval > 0) {
            _checkIntervalMinutes = interval.clamp(1, 1440);
          }
          _connectionVerified = m['connectionVerified'] == true;
          _lastSyncAtMs = (m['lastSyncAtMs'] as num?)?.toInt();
          _lastAutoCheckAtMs = (m['lastAutoCheckAtMs'] as num?)?.toInt();
          _fullBackfillCompleted = m['fullBackfillCompleted'] == true;
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
          'autoImport': _autoImport,
          'checkIntervalMinutes': _checkIntervalMinutes,
          'connectionVerified': _connectionVerified,
          'fullBackfillCompleted': _fullBackfillCompleted,
          if (_lastSyncAtMs != null) 'lastSyncAtMs': _lastSyncAtMs,
          if (_lastAutoCheckAtMs != null)
            'lastAutoCheckAtMs': _lastAutoCheckAtMs,
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
      _fullBackfillCompleted = false;
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
    if (value) {
      // 允许文字/链接笔记后需重新全量回溯一次，确保历史非录音笔记也被补齐
      _fullBackfillCompleted = false;
    }
    await _savePrefs();
    notifyListeners();
  }

  Future<void> setAutoImport(bool value, {AppStore? appStore}) async {
    await load();
    if (_autoImport == value) return;
    _autoImport = value;
    await _savePrefs();
    notifyListeners();
    if (value && hasCredentials && appStore != null && !_syncing) {
      unawaited(syncNow(appStore: appStore, isAutoCheck: true));
    }
  }

  void cancelSync() {
    if (!_syncing || _cancelRequested) return;
    _cancelRequested = true;
    _cancelling = true;
    _statusMessage = '正在停止同步，已导入内容会保留…';
    notifyListeners();
  }

  bool shouldAutoCheck(DateTime now) {
    if (!_autoImport || !hasCredentials || _syncing) return false;
    final lastMs = _lastAutoCheckAtMs ?? _lastSyncAtMs;
    if (lastMs == null) return true;
    final elapsed = now.difference(DateTime.fromMillisecondsSinceEpoch(lastMs));
    return elapsed >= Duration(minutes: _checkIntervalMinutes);
  }

  Future<GetNoteSyncResult?> runAutoCheckIfDue({
    required AppStore appStore,
    DateTime? now,
    bool force = false,
  }) async {
    await load();
    final clock = now ?? DateTime.now();
    if (!_autoImport || !hasCredentials) return null;
    if (!force && !shouldAutoCheck(clock)) return null;
    final result = await syncNow(appStore: appStore, isAutoCheck: true);
    _lastAutoCheckAtMs = clock.millisecondsSinceEpoch;
    await _savePrefs();
    notifyListeners();
    return result;
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
    int? maxPages,
    int? maxNewDetails,
    bool isAutoCheck = false,
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
    _cancelling = false;
    _cancelRequested = false;
    _errorMessage = null;
    _statusMessage = '正在拉取得到大脑笔记列表…';
    _syncProgressDone = 0;
    _syncProgressTotal = 0;
    _syncCurrentPage = 0;
    _syncFetchedTotal = 0;
    notifyListeners();

    const pageSize = 50;

    try {
      final existing = await appStore.existingExternalDeviceNames(
        prefix: RecordingFile.getNoteDevicePrefix,
      );
      final seenInRun = <String>{...existing};
      final visitedCursors = <String>{};
      var addedTotal = 0;
      var skippedExisting = 0;
      var skippedNonAudio = 0;
      var consecutiveAllExistingPages = 0;
      var consecutiveEmptyPages = 0;
      var hitCapOrCancelled = false;
      var hasMorePending = false;
      String? cursor;

      for (
        var pageIdx = 0;
        maxPages == null || pageIdx < maxPages;
        pageIdx++
      ) {
        if (_cancelRequested) {
          hitCapOrCancelled = true;
          break;
        }
        _syncCurrentPage = pageIdx + 1;
        _statusMessage =
            '正在拉取第 $_syncCurrentPage 页列表（已新增 $addedTotal 条）…';
        notifyListeners();

        final page = await _client.listNotes(
          clientId: _clientId,
          apiKey: _apiKey,
          pageSize: pageSize,
          cursor: cursor,
        );

        final pagePending = <GetNoteSummary>[];
        var pageNewCount = 0;
        var pageExistingCount = 0;
        for (final note in page.notes) {
          if (note.noteId.isEmpty) continue;
          if (!_importOtherNotes && !note.isAudioOrMeeting) {
            skippedNonAudio++;
            continue;
          }
          final devName = '${RecordingFile.getNoteDevicePrefix}${note.noteId}';
          if (seenInRun.contains(devName)) {
            skippedExisting++;
            pageExistingCount++;
            continue;
          }
          seenInRun.add(devName);
          if (maxNewDetails != null &&
              _syncFetchedTotal + pagePending.length >= maxNewDetails) {
            hasMorePending = true;
            hitCapOrCancelled = true;
            break;
          }
          pageNewCount++;
          pagePending.add(note);
        }

        if (pagePending.isNotEmpty) {
          final batch = <RecordingFile>[];
          final pageTotalHint =
              page.total ?? (_importedCount + pagePending.length);
          for (var i = 0; i < pagePending.length; i++) {
            if (_cancelRequested) {
              hitCapOrCancelled = true;
              break;
            }
            final summary = pagePending[i];
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
              batch.add(file);
            }
            _syncFetchedTotal += 1;
            _syncProgressDone = _syncFetchedTotal;
            _syncProgressTotal = pageTotalHint > _syncFetchedTotal
                ? pageTotalHint
                : _syncFetchedTotal;
            _statusMessage =
                '正在导入第 $_syncCurrentPage 页（已新增 ${addedTotal + batch.length} 条）…';
            notifyListeners();

            if (batch.length >= 10) {
              addedTotal += await appStore.ingestExternalRecordings(
                List<RecordingFile>.from(batch),
              );
              batch.clear();
              _importedCount = (await appStore.existingExternalDeviceNames(
                prefix: RecordingFile.getNoteDevicePrefix,
              )).length;
              notifyListeners();
            }
          }
          if (batch.isNotEmpty) {
            addedTotal += await appStore.ingestExternalRecordings(batch);
            _importedCount = (await appStore.existingExternalDeviceNames(
              prefix: RecordingFile.getNoteDevicePrefix,
            )).length;
            notifyListeners();
          }
        }

        if (hitCapOrCancelled || _cancelRequested) {
          if (page.hasMore) hasMorePending = true;
          break;
        }

        if (page.notes.isEmpty) {
          consecutiveEmptyPages++;
          if (consecutiveEmptyPages >= 3) break;
        } else {
          consecutiveEmptyPages = 0;
        }

        if (isAutoCheck && _fullBackfillCompleted) {
          if (pageNewCount == 0 && pageExistingCount > 0) {
            consecutiveAllExistingPages++;
            if (consecutiveAllExistingPages >= 2) break;
          } else if (pageNewCount > 0) {
            consecutiveAllExistingPages = 0;
          }
        }

        if (!page.hasMore ||
            page.nextCursor == null ||
            page.nextCursor == cursor) {
          break;
        }
        if (!visitedCursors.add(page.nextCursor!)) {
          // 防服务端重复返回相同游标导致无限翻页
          break;
        }
        cursor = page.nextCursor;
        if (maxPages != null && pageIdx + 1 >= maxPages) {
          hasMorePending = true;
          hitCapOrCancelled = true;
          break;
        }
      }

      final latestExisting = await appStore.existingExternalDeviceNames(
        prefix: RecordingFile.getNoteDevicePrefix,
      );
      _importedCount = latestExisting.length;
      _connectionVerified = true;
      _lastSyncAtMs = DateTime.now().millisecondsSinceEpoch;
      if (isAutoCheck) {
        _lastAutoCheckAtMs = _lastSyncAtMs;
      }
      if (!hitCapOrCancelled && !_cancelRequested) {
        _fullBackfillCompleted = true;
      }

      final parts = <String>[
        '共扫描 $_syncCurrentPage 页',
        '本次新增 $addedTotal 条',
        '跳过已导入 $skippedExisting 条',
        if (skippedNonAudio > 0) '过滤非录音文字笔记 $skippedNonAudio 条',
      ];
      final summaryText = _cancelRequested
          ? '已停止（${parts.join('，')}）'
          : parts.join('，') +
                (hasMorePending ? '（还有更多历史笔记，可再次同步）' : '');
      _lastSyncSummary = summaryText;
      _statusMessage = summaryText;
      _errorMessage = null;
      await _savePrefs();

      return GetNoteSyncResult(
        added: addedTotal,
        skippedExisting: skippedExisting,
        skippedNonAudio: skippedNonAudio,
        pagesScanned: _syncCurrentPage,
        hasMorePending: hasMorePending,
        cancelled: _cancelRequested,
        totalImported: _importedCount,
        summaryText: summaryText,
      );
    } on GetNoteApiException catch (e) {
      try {
        _importedCount = (await appStore.existingExternalDeviceNames(
          prefix: RecordingFile.getNoteDevicePrefix,
        )).length;
      } on Object {
        // 忽略中断后计数刷新异常
      }
      _errorMessage = e.message;
      _statusMessage = null;
      await _savePrefs();
      return GetNoteSyncResult(
        totalImported: _importedCount,
        error: e.message,
      );
    } on Object catch (e) {
      try {
        _importedCount = (await appStore.existingExternalDeviceNames(
          prefix: RecordingFile.getNoteDevicePrefix,
        )).length;
      } on Object {
        // 忽略中断后计数刷新异常
      }
      final msg = '同步得到大脑笔记失败：$e';
      _errorMessage = msg;
      _statusMessage = null;
      await _savePrefs();
      return GetNoteSyncResult(totalImported: _importedCount, error: msg);
    } finally {
      _syncing = false;
      _cancelling = false;
      _cancelRequested = false;
      _syncProgressDone = 0;
      _syncProgressTotal = 0;
      notifyListeners();
    }
  }

  Future<void> clearAll() async {
    _clientId = '';
    _apiKey = '';
    _importOtherNotes = false;
    _autoImport = false;
    _checkIntervalMinutes = 60;
    _connectionVerified = false;
    _lastSyncAtMs = null;
    _lastAutoCheckAtMs = null;
    _importedCount = 0;
    _lastSyncSummary = null;
    _fullBackfillCompleted = false;
    _statusMessage = null;
    _errorMessage = null;
    _syncProgressDone = 0;
    _syncProgressTotal = 0;
    _syncCurrentPage = 0;
    _syncFetchedTotal = 0;
    _cancelling = false;
    _cancelRequested = false;
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
