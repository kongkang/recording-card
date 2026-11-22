/// 第三方笔记、阅读与录音软件 API 接入配置、密钥存储与每小时自动同步控制中心。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/models/recording.dart';
import '../../core/storage/storage.dart';
import '../../core/store/app_store.dart';
import 'connectors/evernote_connector.dart';
import 'connectors/fireflies_connector.dart';
import 'connectors/flomo_connector.dart';
import 'connectors/limitless_connector.dart';
import 'connectors/notion_connector.dart';
import 'connectors/obsidian_connector.dart';
import 'connectors/omi_cloud_connector.dart';
import 'connectors/plaud_connector.dart';
import 'connectors/readwise_connector.dart';
import 'connectors/weread_connector.dart';
import 'connectors/yuque_connector.dart';
import 'external_connector.dart';

class ExternalSyncRunResult {
  const ExternalSyncRunResult({
    this.added = 0,
    this.skippedExisting = 0,
    this.updated = 0,
    this.pagesScanned = 0,
    this.cancelled = false,
    this.totalImported = 0,
    this.summaryText = '',
    this.error,
  });

  final int added;
  final int skippedExisting;
  final int updated;
  final int pagesScanned;
  final bool cancelled;
  final int totalImported;
  final String summaryText;
  final String? error;

  bool get ok => error == null;
}

class ExternalConnectorRuntimeState {
  ExternalConnectorRuntimeState();

  Map<String, String> config = <String, String>{};
  bool autoImport = false;
  int checkIntervalMinutes = 60;
  bool connectionVerified = false;
  int? lastSyncAtMs;
  int? lastAutoCheckAtMs;
  int importedCount = 0;
  String? lastSyncSummary;
  bool fullBackfillCompleted = false;
  Map<String, String> itemFingerprints = <String, String>{};

  bool testing = false;
  bool syncing = false;
  bool cancelling = false;
  bool cancelRequested = false;
  String? statusMessage;
  String? errorMessage;
  int syncCurrentPage = 0;
  int syncFetchedCount = 0;
}

class ExternalDataHubStore extends ChangeNotifier {
  ExternalDataHubStore({
    SecureStore? secureStore,
    KeyValueStore? prefsStore,
    List<ExternalDataConnector>? connectors,
    http.Client Function(String connectorId)? httpClientResolver,
  }) : _secure = secureStore ?? KeychainSecureStore(),
       _prefs = prefsStore,
       _connectors = connectors ?? buildDefaultConnectors(),
       _httpClientResolver = httpClientResolver;

  static final ExternalDataHubStore instance = ExternalDataHubStore(
    secureStore: KeychainSecureStore(),
  );

  static const String _credsKey = 'rc_extdata_creds_v1';
  static const String _prefsKey = 'rc.extdata.hub.v1';

  static List<ExternalDataConnector> buildDefaultConnectors({
    Duration? requestDelay,
  }) {
    if (requestDelay != null) {
      return [
        NotionConnector(requestDelay: requestDelay),
        YuqueConnector(requestDelay: requestDelay),
        ObsidianConnector(requestDelay: requestDelay),
        FlomoConnector(requestDelay: requestDelay),
        WeReadConnector(requestDelay: requestDelay),
        EvernoteConnector(requestDelay: requestDelay),
        ReadwiseConnector(requestDelay: requestDelay),
        PlaudConnector(requestDelay: requestDelay),
        LimitlessConnector(requestDelay: requestDelay),
        OmiCloudConnector(requestDelay: requestDelay),
        FirefliesConnector(requestDelay: requestDelay),
      ];
    }
    return [
      NotionConnector(),
      YuqueConnector(),
      ObsidianConnector(),
      FlomoConnector(),
      WeReadConnector(),
      EvernoteConnector(),
      ReadwiseConnector(),
      PlaudConnector(),
      LimitlessConnector(),
      OmiCloudConnector(),
      FirefliesConnector(),
    ];
  }

  final SecureStore _secure;
  KeyValueStore? _prefs;
  final List<ExternalDataConnector> _connectors;
  final http.Client Function(String connectorId)? _httpClientResolver;

  final Map<String, ExternalConnectorRuntimeState> _states = {};
  bool _loaded = false;
  Future<void>? _loading;

  List<ExternalDataConnector> get allConnectors =>
      List.unmodifiable(_connectors);

  List<ExternalDataConnector> connectorsFor(
    ExternalConnectorCategory category,
  ) => [
    for (final c in _connectors)
      if (c.category == category) c,
  ];

  ExternalDataConnector? connectorById(String id) {
    for (final c in _connectors) {
      if (c.id == id) return c;
    }
    return null;
  }

  ExternalConnectorRuntimeState stateFor(String id) =>
      _states.putIfAbsent(id, ExternalConnectorRuntimeState.new);

  Map<String, String> resolvedConfigFor(String id) {
    final c = connectorById(id);
    final raw = stateFor(id).config;
    return c == null ? Map<String, String>.from(raw) : c.resolveConfig(raw);
  }

  bool hasRequiredConfig(String id) {
    final c = connectorById(id);
    if (c == null) return false;
    return c.hasRequiredConfig(stateFor(id).config);
  }

  String statusTextFor(String id) {
    final st = stateFor(id);
    if (st.syncing) return '同步中…';
    if (!hasRequiredConfig(id)) return '未配置';
    if (st.autoImport) {
      return st.importedCount > 0 ? '自动 · 已导入 ${st.importedCount} 条' : '自动同步已开启';
    }
    if (st.importedCount > 0) return '已导入 ${st.importedCount} 条';
    if (st.connectionVerified) return '已连接';
    return '已配置';
  }

  String categorySummaryText(ExternalConnectorCategory category) {
    final list = connectorsFor(category);
    var anySyncing = false;
    var configuredCount = 0;
    var autoCount = 0;
    var totalImported = 0;
    for (final c in list) {
      final st = stateFor(c.id);
      if (st.syncing) anySyncing = true;
      if (hasRequiredConfig(c.id)) configuredCount += 1;
      if (st.autoImport) autoCount += 1;
      totalImported += st.importedCount;
    }
    if (anySyncing) return '同步中…';
    if (totalImported > 0 && autoCount > 0) {
      return '自动 $autoCount 源 · 已导入 $totalImported 条';
    }
    if (totalImported > 0) return '已导入 $totalImported 条';
    if (autoCount > 0) return '自动同步 $autoCount 源';
    if (configuredCount > 0) return '已配置 $configuredCount 项';
    return '未配置';
  }

  int autoEnabledCount(ExternalConnectorCategory category) {
    var count = 0;
    for (final c in connectorsFor(category)) {
      if (stateFor(c.id).autoImport) count += 1;
    }
    return count;
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
    final secretsById = <String, Map<String, String>>{};
    try {
      final rawCreds = await _secure.readJson(_credsKey);
      if (rawCreds != null) {
        for (final entry in rawCreds.entries) {
          if (entry.value is Map) {
            secretsById[entry.key] = {
              for (final kv in (entry.value as Map).entries)
                '${kv.key}': '${kv.value ?? ''}'.trim(),
            };
          }
        }
      }
    } on Object catch (e) {
      debugPrint('[extdata] 读取第三方密钥库失败: $e');
    }

    try {
      final prefs = await _ensurePrefs();
      final raw = await prefs.getString(_prefsKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.value is! Map) continue;
            final id = '${entry.key}';
            final m = Map<String, dynamic>.from(entry.value as Map);
            final st = stateFor(id);
            final cfg = <String, String>{};
            if (m['config'] is Map) {
              for (final kv in (m['config'] as Map).entries) {
                cfg['${kv.key}'] = '${kv.value ?? ''}'.trim();
              }
            }
            if (secretsById[id] != null) {
              cfg.addAll(secretsById[id]!);
            }
            st.config = cfg;
            st.autoImport = m['autoImport'] == true;
            final interval = (m['checkIntervalMinutes'] as num?)?.toInt();
            if (interval != null && interval > 0) {
              st.checkIntervalMinutes = interval.clamp(1, 1440);
            }
            st.connectionVerified = m['connectionVerified'] == true;
            st.lastSyncAtMs = (m['lastSyncAtMs'] as num?)?.toInt();
            st.lastAutoCheckAtMs = (m['lastAutoCheckAtMs'] as num?)?.toInt();
            st.importedCount = ((m['importedCount'] as num?)?.toInt() ?? 0)
                .clamp(0, 1 << 30);
            final summary = m['lastSyncSummary'] as String?;
            st.lastSyncSummary = (summary != null && summary.trim().isNotEmpty)
                ? summary.trim()
                : null;
            st.fullBackfillCompleted = m['fullBackfillCompleted'] == true;
            if (m['fingerprints'] is Map) {
              st.itemFingerprints = {
                for (final fp in (m['fingerprints'] as Map).entries)
                  '${fp.key}': '${fp.value ?? ''}',
              };
            }
          }
        }
      } else {
        for (final entry in secretsById.entries) {
          stateFor(entry.key).config.addAll(entry.value);
        }
      }
    } on Object catch (e) {
      debugPrint('[extdata] 读取第三方配置偏好失败: $e');
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> _saveSecrets() async {
    final payload = <String, dynamic>{};
    for (final c in _connectors) {
      final st = stateFor(c.id);
      final secrets = <String, String>{};
      for (final f in c.fields) {
        if (!f.isSecret) continue;
        final val = (st.config[f.key] ?? '').trim();
        if (val.isNotEmpty) secrets[f.key] = val;
      }
      if (secrets.isNotEmpty) payload[c.id] = secrets;
    }
    try {
      if (payload.isEmpty) {
        await _secure.delete(_credsKey);
      } else {
        await _secure.writeJson(_credsKey, payload);
      }
    } on Object catch (e) {
      debugPrint('[extdata] 保存第三方密钥库失败: $e');
    }
  }

  Future<void> _savePrefs() async {
    final payload = <String, dynamic>{};
    for (final entry in _states.entries) {
      final id = entry.key;
      final st = entry.value;
      final c = connectorById(id);
      final secretKeys = {
        if (c != null)
          for (final f in c.fields)
            if (f.isSecret) f.key,
      };
      final nonSecretConfig = <String, String>{
        for (final kv in st.config.entries)
          if (!secretKeys.contains(kv.key) && kv.value.trim().isNotEmpty)
            kv.key: kv.value.trim(),
      };
      payload[id] = {
        if (nonSecretConfig.isNotEmpty) 'config': nonSecretConfig,
        'autoImport': st.autoImport,
        'checkIntervalMinutes': st.checkIntervalMinutes,
        'connectionVerified': st.connectionVerified,
        if (st.lastSyncAtMs != null) 'lastSyncAtMs': st.lastSyncAtMs,
        if (st.lastAutoCheckAtMs != null)
          'lastAutoCheckAtMs': st.lastAutoCheckAtMs,
        'importedCount': st.importedCount,
        if (st.lastSyncSummary != null) 'lastSyncSummary': st.lastSyncSummary,
        'fullBackfillCompleted': st.fullBackfillCompleted,
        if (st.itemFingerprints.isNotEmpty) 'fingerprints': st.itemFingerprints,
      };
    }
    try {
      final prefs = await _ensurePrefs();
      await prefs.setString(_prefsKey, jsonEncode(payload));
    } on Object catch (e) {
      debugPrint('[extdata] 写入第三方配置偏好失败: $e');
    }
  }

  Future<void> saveConfig(String id, Map<String, String> values) async {
    await load();
    final c = connectorById(id);
    if (c == null) return;
    final st = stateFor(id);
    final normalized = <String, String>{};
    for (final kv in values.entries) {
      final val = kv.value.trim();
      if (val.isNotEmpty) normalized[kv.key] = val;
    }
    final changed = !mapEquals(st.config, normalized);
    st.config = normalized;
    if (changed) {
      st.connectionVerified = false;
      st.fullBackfillCompleted = false;
      await _saveSecrets();
      await _savePrefs();
      notifyListeners();
    }
  }

  Future<void> setAutoImport(
    String id,
    bool enabled, {
    AppStore? appStore,
  }) async {
    await load();
    final st = stateFor(id);
    if (st.autoImport == enabled) return;
    st.autoImport = enabled;
    await _savePrefs();
    notifyListeners();
    if (enabled &&
        hasRequiredConfig(id) &&
        appStore != null &&
        !st.syncing) {
      unawaited(syncConnector(id, appStore: appStore, isAutoCheck: true));
    }
  }

  Future<bool> testConnection(
    String id, {
    Map<String, String>? pendingConfig,
  }) async {
    await load();
    final c = connectorById(id);
    if (c == null) return false;
    if (pendingConfig != null) {
      await saveConfig(id, pendingConfig);
    }
    final st = stateFor(id);
    if (!hasRequiredConfig(id)) {
      st.errorMessage = '请先填写完整的必填接入参数';
      st.statusMessage = null;
      st.connectionVerified = false;
      notifyListeners();
      return false;
    }

    st.testing = true;
    st.errorMessage = null;
    st.statusMessage = '正在连接 ${c.name}…';
    notifyListeners();

    try {
      final res = await c.testConnection(
        c.resolveConfig(st.config),
        httpClient: _httpClientResolver?.call(id),
      );
      st.connectionVerified = true;
      st.errorMessage = null;
      st.statusMessage = res.message;
      await _savePrefs();
      return true;
    } on ExternalConnectorException catch (e) {
      st.connectionVerified = false;
      st.errorMessage = e.message;
      st.statusMessage = null;
      await _savePrefs();
      return false;
    } on Object catch (e) {
      st.connectionVerified = false;
      st.errorMessage = '测试连接失败：$e';
      st.statusMessage = null;
      await _savePrefs();
      return false;
    } finally {
      st.testing = false;
      notifyListeners();
    }
  }

  void cancelSync(String id) {
    final st = stateFor(id);
    if (!st.syncing || st.cancelRequested) return;
    st.cancelRequested = true;
    st.cancelling = true;
    st.statusMessage = '正在停止同步，已导入内容会保留…';
    notifyListeners();
  }

  Future<ExternalSyncRunResult> syncConnector(
    String id, {
    required AppStore appStore,
    Map<String, String>? pendingConfig,
    bool isAutoCheck = false,
  }) async {
    await load();
    final c = connectorById(id);
    if (c == null) {
      return const ExternalSyncRunResult(error: '未知接入源');
    }
    if (pendingConfig != null) {
      await saveConfig(id, pendingConfig);
    }
    final st = stateFor(id);
    if (!hasRequiredConfig(id)) {
      const msg = '请先填写完整的必填接入参数';
      st.errorMessage = msg;
      st.statusMessage = null;
      notifyListeners();
      return const ExternalSyncRunResult(error: msg);
    }
    if (st.syncing) {
      return ExternalSyncRunResult(
        totalImported: st.importedCount,
        summaryText: st.lastSyncSummary ?? '正在同步中，请稍候…',
      );
    }

    st.syncing = true;
    st.cancelling = false;
    st.cancelRequested = false;
    st.errorMessage = null;
    st.syncCurrentPage = 0;
    st.syncFetchedCount = 0;
    st.statusMessage = '正在连接 ${c.name} 并连续翻页拉取…';
    notifyListeners();

    var batchIngested = 0;
    try {
      final existing = <String>{
        ...await appStore.existingExternalDeviceNames(prefix: c.devicePrefix),
      };
      final runFingerprints = Map<String, String>.from(st.itemFingerprints);
      final report = await c.sync(
        config: c.resolveConfig(st.config),
        existingDeviceNames: existing,
        itemFingerprints: runFingerprints,
        incremental: isAutoCheck && st.fullBackfillCompleted,
        lastSyncAt: st.lastSyncAtMs != null
            ? DateTime.fromMillisecondsSinceEpoch(st.lastSyncAtMs!)
            : null,
        httpClient: _httpClientResolver?.call(id),
        isCancelled: () => st.cancelRequested,
        onProgress: (p) {
          st.syncCurrentPage = p.page;
          st.syncFetchedCount = p.fetched;
          if (p.message != null && p.message!.isNotEmpty) {
            st.statusMessage = p.message;
          }
          notifyListeners();
        },
        onBatch: (drafts, nextFingerprints) async {
          final files = <RecordingFile>[
            for (final d in drafts)
              ?ExternalRecordConverter.toRecordingFile(c, d),
          ];
          if (files.isNotEmpty) {
            batchIngested += await appStore.ingestExternalRecordings(files);
            for (final file in files) {
              existing.add(file.deviceName);
            }
          }
          runFingerprints.addAll(nextFingerprints);
          st.itemFingerprints.addAll(nextFingerprints);
          st.importedCount = (await appStore.existingExternalDeviceNames(
            prefix: c.devicePrefix,
          )).length;
          notifyListeners();
        },
      );

      final latestExisting = await appStore.existingExternalDeviceNames(
        prefix: c.devicePrefix,
      );
      st.importedCount = latestExisting.length;
      st.connectionVerified = true;
      st.lastSyncAtMs = DateTime.now().millisecondsSinceEpoch;
      if (isAutoCheck) {
        st.lastAutoCheckAtMs = st.lastSyncAtMs;
      }
      if (report.completedFullBackfill && !report.cancelled) {
        st.fullBackfillCompleted = true;
      }

      final newAdded = (batchIngested - report.updated).clamp(0, batchIngested);
      final parts = <String>[
        '共扫描 ${report.pagesScanned} 页',
        '本次新增 $newAdded 条',
        if (report.updated > 0) '更新 ${report.updated} 条',
        '跳过已导入 ${report.skippedExisting} 条',
      ];
      final summaryText = report.cancelled
          ? '已停止（${parts.join('，')}）'
          : parts.join('，');
      st.lastSyncSummary = summaryText;
      st.statusMessage = summaryText;
      st.errorMessage = null;
      await _savePrefs();

      return ExternalSyncRunResult(
        added: batchIngested,
        skippedExisting: report.skippedExisting,
        updated: report.updated,
        pagesScanned: report.pagesScanned,
        cancelled: report.cancelled,
        totalImported: st.importedCount,
        summaryText: summaryText,
      );
    } on ExternalConnectorException catch (e) {
      await _refreshCountSafely(c, st, appStore);
      st.errorMessage = e.message;
      st.statusMessage = null;
      await _savePrefs();
      return ExternalSyncRunResult(
        added: batchIngested,
        totalImported: st.importedCount,
        error: e.message,
      );
    } on Object catch (e) {
      await _refreshCountSafely(c, st, appStore);
      final msg = '同步 ${c.name} 失败：$e';
      st.errorMessage = msg;
      st.statusMessage = null;
      await _savePrefs();
      return ExternalSyncRunResult(
        added: batchIngested,
        totalImported: st.importedCount,
        error: msg,
      );
    } finally {
      st.syncing = false;
      st.cancelling = false;
      st.cancelRequested = false;
      notifyListeners();
    }
  }

  Future<void> _refreshCountSafely(
    ExternalDataConnector c,
    ExternalConnectorRuntimeState st,
    AppStore appStore,
  ) async {
    try {
      st.importedCount = (await appStore.existingExternalDeviceNames(
        prefix: c.devicePrefix,
      )).length;
    } on Object {
      // 忽略计数刷新失败
    }
  }

  bool shouldAutoCheck(String id, DateTime now) {
    final st = stateFor(id);
    if (!st.autoImport || !hasRequiredConfig(id) || st.syncing) return false;
    final lastMs = st.lastAutoCheckAtMs ?? st.lastSyncAtMs;
    if (lastMs == null) return true;
    final elapsed = now.difference(DateTime.fromMillisecondsSinceEpoch(lastMs));
    return elapsed >= Duration(minutes: st.checkIntervalMinutes);
  }

  Future<Map<String, ExternalSyncRunResult>> runAutoCheckIfDue({
    required AppStore appStore,
    ExternalConnectorCategory? category,
    DateTime? now,
    bool force = false,
  }) async {
    await load();
    final clock = now ?? DateTime.now();
    final results = <String, ExternalSyncRunResult>{};
    for (final c in _connectors) {
      if (category != null && c.category != category) continue;
      final st = stateFor(c.id);
      if (!st.autoImport || !hasRequiredConfig(c.id)) continue;
      if (!force && !shouldAutoCheck(c.id, clock)) continue;
      final res = await syncConnector(
        c.id,
        appStore: appStore,
        isAutoCheck: true,
      );
      st.lastAutoCheckAtMs = clock.millisecondsSinceEpoch;
      await _savePrefs();
      results[c.id] = res;
    }
    if (results.isNotEmpty) {
      notifyListeners();
    }
    return results;
  }

  Future<void> clearConnector(String id) async {
    await load();
    _states[id] = ExternalConnectorRuntimeState();
    await _saveSecrets();
    await _savePrefs();
    notifyListeners();
  }

  Future<void> clearAll() async {
    _states.clear();
    try {
      await _secure.delete(_credsKey);
    } on Object catch (e) {
      debugPrint('[extdata] 清理第三方密钥库失败: $e');
    }
    try {
      final prefs = await _ensurePrefs();
      await prefs.remove(_prefsKey);
    } on Object catch (e) {
      debugPrint('[extdata] 清理第三方配置偏好失败: $e');
    }
    notifyListeners();
  }
}
