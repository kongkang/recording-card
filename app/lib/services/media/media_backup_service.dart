/// 媒体与文本备份协调器：
///
/// 1. 硬件拍摄的照片与视频默认自动写入系统「照片」相册（受 `saveHardwareMediaToAlbum` 控制），
///    原件保留在 App 沙盒，并记录写入相册的 `localIdentifier` 防止重复导入；
/// 2. 未开启 iCloud 时，仅将转录文本（Markdown）写入 `Documents/转录文本/`，
///    让用户在 iOS「文件 → 我的 iPhone → 录音卡」查看，音频不暴露到「文件」App；
/// 3. 用户手动开启 iCloud 时，按所选范围（音频 + 转录文本 / 仅音频 / 仅转录文本）
///    将对应录音音频、转录文本以及硬件照片/视频同步到 `iCloud 云盘 → 录音卡`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/record.dart';
import '../../core/models/recording.dart';
import '../../core/store/agent_config_store.dart';
import '../photos/photo_library_service.dart';
import 'icloud_sync_service.dart';

class ExportedTranscriptFile {
  const ExportedTranscriptFile({
    required this.path,
    required this.relativePath,
    required this.content,
    required this.written,
  });

  final String path;
  final String relativePath;
  final String content;
  final bool written;
}

class MediaSyncReport {
  const MediaSyncReport({
    required this.localTranscriptsWritten,
    required this.albumSavedCount,
    required this.icloudUploadedCount,
    this.icloudError,
  });

  final int localTranscriptsWritten;
  final int albumSavedCount;
  final int icloudUploadedCount;
  final String? icloudError;
}

/// 将录音转写内容导出为可读 Markdown 并存放在 `Documents/转录文本/`（iOS「文件」可见）。
///
/// 严格只写 `.md` 文本，绝不把音频、图片、视频或模型写入 `Documents/`。
class LocalTranscriptExporter {
  LocalTranscriptExporter({Future<Directory> Function()? directoryOverride})
    : _directoryOverride = directoryOverride;

  final Future<Directory> Function()? _directoryOverride;

  Future<Directory> rootDir() async {
    if (_directoryOverride != null) {
      final dir = await _directoryOverride();
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/转录文本');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String dateFolderForMs(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      ms > 0 ? ms : DateTime.now().millisecondsSinceEpoch,
    );
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _clockTagForMs(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      ms > 0 ? ms : DateTime.now().millisecondsSinceEpoch,
    );
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$hh-$mm-$ss';
  }

  static String _formatTimestamp(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      ms > 0 ? ms : DateTime.now().millisecondsSinceEpoch,
    );
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  static String _formatDuration(int durationMs) {
    if (durationMs <= 0) return '0 秒';
    final totalSec = (durationMs / 1000).round();
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) return '$h 小时 $m 分 $s 秒';
    if (m > 0) return '$m 分 $s 秒';
    return '$s 秒';
  }

  static String _sanitizeSegment(String raw, {String fallback = '录音记录'}) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return fallback;
    return cleaned.length > 36 ? cleaned.substring(0, 36).trim() : cleaned;
  }

  static String _shortId(String deviceName) {
    final cleaned = deviceName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (cleaned.isEmpty) return 'rec';
    return cleaned.length <= 16
        ? cleaned
        : cleaned.substring(cleaned.length - 16);
  }

  String _pickTitle(RecordingFile file) {
    for (final seg in file.segments) {
      final t = seg.title.trim();
      if (t.isNotEmpty) return t;
    }
    if (file.turns.isNotEmpty) {
      final first = file.turns.first.text.trim();
      if (first.isNotEmpty) {
        return first.length <= 20 ? first : '${first.substring(0, 20)}…';
      }
    }
    if (file.utterances.isNotEmpty) {
      final first = file.utterances.first.text.trim();
      if (first.isNotEmpty) {
        return first.length <= 20 ? first : '${first.substring(0, 20)}…';
      }
    }
    return '录音转录';
  }

  /// 渲染可读 Markdown；若没有任何有效转写文本则返回空串。
  String renderMarkdown(RecordingFile file) {
    final blocks = <String>[];
    final validSegs = file.segments
        .where(
          (s) =>
              s.longText.trim().isNotEmpty ||
              s.brief.trim().isNotEmpty ||
              s.title.trim().isNotEmpty,
        )
        .toList();

    if (file.turns.isNotEmpty) {
      final turnLines = <String>[];
      for (final t in file.turns) {
        final text = t.text.trim();
        if (text.isEmpty) continue;
        final who = t.speakerLabel.trim().isEmpty
            ? '未区分'
            : t.speakerLabel.trim();
        final absMs = (file.startAtMs > 0 ? file.startAtMs : file.createdAtMs) +
            t.startMs;
        final clock = _formatTimestamp(absMs).split(' ').last;
        turnLines.add('- **$who**（$clock）：$text');
      }
      if (turnLines.isNotEmpty) {
        blocks.add('## 对话转录\n\n${turnLines.join('\n')}');
      }
    } else if (file.utterances.isNotEmpty) {
      final rawLines = <String>[];
      for (final u in file.utterances) {
        final text = u.text.trim();
        if (text.isEmpty) continue;
        final who = (u.speakerLabel ?? '').trim();
        final prefix = who.isEmpty ? '' : '**$who**：';
        rawLines.add('- $prefix$text');
      }
      if (rawLines.isNotEmpty) {
        blocks.add('## 转录文本\n\n${rawLines.join('\n')}');
      }
    }

    if (validSegs.isNotEmpty) {
      final segLines = <String>[];
      for (final s in validSegs) {
        final title = s.title.trim().isEmpty ? '片段 ${s.index + 1}' : s.title.trim();
        final body = s.longText.trim().isNotEmpty
            ? s.longText.trim()
            : s.brief.trim();
        if (body.isEmpty) continue;
        segLines.add('### $title\n\n$body');
      }
      if (segLines.isNotEmpty) {
        blocks.insert(0, segLines.join('\n\n'));
      }
    }

    if (blocks.isEmpty) return '';

    final startMs = file.startAtMs > 0 ? file.startAtMs : file.createdAtMs;
    final title = _pickTitle(file);
    final header = <String>[
      '# $title',
      '',
      '- 记录时间：${_formatTimestamp(startMs)}',
      '- 录音时长：${_formatDuration(file.durationMs)}',
      if ((file.sourceDeviceLabel ?? '').trim().isNotEmpty)
        '- 来源设备：${file.sourceDeviceLabel!.trim()}',
      '',
    ].join('\n');

    return '$header\n${blocks.join('\n\n')}\n';
  }

  String relativePathFor(RecordingFile file) {
    final startMs = file.startAtMs > 0 ? file.startAtMs : file.createdAtMs;
    final date = dateFolderForMs(startMs);
    final clock = _clockTagForMs(startMs);
    final safeTitle = _sanitizeSegment(_pickTitle(file));
    final shortId = _shortId(file.deviceName);
    return '$date/${clock}_${safeTitle}_$shortId.md';
  }

  Future<ExportedTranscriptFile?> exportRecording(RecordingFile file) async {
    final content = renderMarkdown(file);
    if (content.trim().isEmpty) return null;

    final root = await rootDir();
    final rel = relativePathFor(file);
    final target = File('${root.path}/$rel');
    if (!await target.parent.exists()) {
      await target.parent.create(recursive: true);
    }

    if (await target.exists()) {
      try {
        final existing = await target.readAsString();
        if (existing == content) {
          return ExportedTranscriptFile(
            path: target.path,
            relativePath: rel,
            content: content,
            written: false,
          );
        }
      } on Object {
        // 读取异常则重写覆盖
      }
    }

    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(target.path);
    return ExportedTranscriptFile(
      path: target.path,
      relativePath: rel,
      content: content,
      written: true,
    );
  }

  Future<int> countExportedFiles() async {
    try {
      final root = await rootDir();
      if (!await root.exists()) return 0;
      var count = 0;
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
          count++;
        }
      }
      return count;
    } on Object {
      return 0;
    }
  }

  Future<void> clearAll() async {
    try {
      final root = await rootDir();
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          try {
            await entity.delete(recursive: true);
          } on FileSystemException {
            // 忽略占用文件
          }
        }
      }
    } on Object {
      // 无平台通道时忽略
    }
  }
}

class MediaBackupService extends ChangeNotifier {
  MediaBackupService({
    required AgentConfigStore agentConfig,
    PhotoLibraryService photoLibrary = const PhotoLibraryService(),
    ICloudSyncService icloudSync = const ICloudSyncService(),
    LocalTranscriptExporter? transcriptExporter,
    Future<Directory> Function()? indexDirOverride,
  }) : _agentConfig = agentConfig,
       _photoLibrary = photoLibrary,
       _icloudSync = icloudSync,
       _transcriptExporter = transcriptExporter ?? LocalTranscriptExporter(),
       _indexDirOverride = indexDirOverride;

  final AgentConfigStore _agentConfig;
  PhotoLibraryService _photoLibrary;
  final ICloudSyncService _icloudSync;
  final LocalTranscriptExporter _transcriptExporter;
  final Future<Directory> Function()? _indexDirOverride;

  bool _loaded = false;
  bool _disposed = false;
  Future<MediaSyncReport>? _inFlightSync;
  Future<void>? _loadFuture;

  final Map<String, String> _albumSavedIds = <String, String>{};
  final Set<String> _exportedAlbumAssetIds = <String>{};
  final Map<String, String> _icloudFingerprints = <String, String>{};

  int? lastICloudSyncAtMs;
  int lastICloudSyncedFiles = 0;
  String? lastICloudError;
  int localTranscriptCount = 0;
  ICloudStats? lastICloudStats;

  bool get isSyncRunning => _inFlightSync != null;
  ICloudSyncService get icloudSync => _icloudSync;
  LocalTranscriptExporter get transcriptExporter => _transcriptExporter;

  void updatePhotoLibrary(PhotoLibraryService service) {
    _photoLibrary = service;
  }

  static String normalizeAlbumAssetId(String localIdentifier) {
    final safe = localIdentifier
        .replaceAll('/', '_')
        .replaceAll(':', '_');
    return 'alb_$safe';
  }

  bool isOwnExportedAlbumPhotoId(String photoId) =>
      _exportedAlbumAssetIds.contains(photoId);

  bool hasSavedToAlbum(String mediaKey) => _albumSavedIds.containsKey(mediaKey);

  Future<File> _indexFile() async {
    final dir = _indexDirOverride != null
        ? await _indexDirOverride()
        : await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/media_backup_index.json');
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    if (_loadFuture != null) {
      await _loadFuture;
      return;
    }
    _loadFuture = _doLoad();
    await _loadFuture;
  }

  Future<void> _doLoad() async {
    try {
      final file = await _indexFile();
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map<String, dynamic>) {
          final album = raw['albumSavedIds'];
          if (album is Map) {
            _albumSavedIds.clear();
            _exportedAlbumAssetIds.clear();
            for (final entry in album.entries) {
              final k = '${entry.key}';
              final v = '${entry.value}';
              _albumSavedIds[k] = v;
              if (v.isNotEmpty) {
                _exportedAlbumAssetIds.add(normalizeAlbumAssetId(v));
              }
            }
          }
          final exported = raw['exportedAlbumAssetIds'];
          if (exported is List) {
            for (final id in exported) {
              if (id is String && id.isNotEmpty) {
                _exportedAlbumAssetIds.add(id);
              }
            }
          }
          final fp = raw['icloudFingerprints'];
          if (fp is Map) {
            _icloudFingerprints.clear();
            for (final entry in fp.entries) {
              _icloudFingerprints['${entry.key}'] = '${entry.value}';
            }
          }
          if (raw['lastICloudSyncAtMs'] is num) {
            lastICloudSyncAtMs = (raw['lastICloudSyncAtMs'] as num).toInt();
          }
          if (raw['lastICloudSyncedFiles'] is num) {
            lastICloudSyncedFiles =
                (raw['lastICloudSyncedFiles'] as num).toInt();
          }
          if (raw['lastICloudError'] is String) {
            lastICloudError = raw['lastICloudError'] as String;
          }
        }
      }
      localTranscriptCount = await _transcriptExporter.countExportedFiles();
      _loaded = true;
    } on Object catch (e) {
      debugPrint('[media_backup] 加载索引失败：$e');
      _loaded = true;
    } finally {
      _loadFuture = null;
    }
  }

  Future<void> _saveIndex() async {
    try {
      final file = await _indexFile();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'albumSavedIds': _albumSavedIds,
          'exportedAlbumAssetIds': _exportedAlbumAssetIds.toList(),
          'icloudFingerprints': _icloudFingerprints,
          if (lastICloudSyncAtMs != null)
            'lastICloudSyncAtMs': lastICloudSyncAtMs,
          'lastICloudSyncedFiles': lastICloudSyncedFiles,
          if (lastICloudError != null && lastICloudError!.isNotEmpty)
            'lastICloudError': lastICloudError,
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } on Object catch (e) {
      debugPrint('[media_backup] 保存索引失败：$e');
    }
  }

  static String _safeFileName(String raw) {
    final base = raw.split(RegExp(r'[/\\]')).last.trim();
    final cleaned = base.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), '_');
    return cleaned.isEmpty ? 'media_${DateTime.now().millisecondsSinceEpoch}' : cleaned;
  }

  static String inferMediaTypeFromPath(String nameOrPath) {
    final low = nameOrPath.trim().toLowerCase();
    if (low.endsWith('.mp4') || low.endsWith('.mov')) return 'video';
    return 'photo';
  }

  /// 备份单条硬件相机媒体（照片/视频）：
  /// - 默认写入系统相册（受 `saveHardwareMediaToAlbum` 控制，去重防反复写入）；
  /// - 若用户手动开启了 iCloud 同步，则同步备份到 `iCloud 云盘 → 录音卡/{Photos,Videos}/YYYY-MM-DD/`。
  Future<({bool savedToAlbum, bool syncedToICloud})> backupHardwareMediaItem({
    required String name,
    required String path,
    String? mediaType,
    int? capturedAtMs,
    bool promptAlbumPermission = true,
  }) async {
    if (_disposed || path.trim().isEmpty) {
      return (savedToAlbum: false, syncedToICloud: false);
    }
    final file = File(path);
    if (!await file.exists()) {
      return (savedToAlbum: false, syncedToICloud: false);
    }
    await ensureLoaded();

    final resolvedType =
        (mediaType == 'video' || mediaType == 'photo')
            ? mediaType!
            : inferMediaTypeFromPath(name.isNotEmpty ? name : path);
    final mediaKey = 'dyj_${_safeFileName(name.isNotEmpty ? name : path)}';
    var savedToAlbum = false;
    var syncedToICloud = false;
    var indexDirty = false;

    if (_agentConfig.saveHardwareMediaToAlbum &&
        !_albumSavedIds.containsKey(mediaKey)) {
      final res = await _photoLibrary.saveMediaToAlbum(
        path: path,
        mediaType: resolvedType,
        capturedAtMs: capturedAtMs,
        promptIfNeeded: promptAlbumPermission,
      );
      if (res.saved) {
        final localId = res.localIdentifier ?? '';
        _albumSavedIds[mediaKey] = localId;
        if (localId.isNotEmpty) {
          _exportedAlbumAssetIds.add(normalizeAlbumAssetId(localId));
        }
        savedToAlbum = true;
        indexDirty = true;
      }
    }

    if (_agentConfig.icloudSyncEnabled && !_agentConfig.localOnlyMode) {
      final ts = capturedAtMs ?? DateTime.now().millisecondsSinceEpoch;
      final folder = resolvedType == 'video' ? 'Videos' : 'Photos';
      final rel =
          '$folder/${LocalTranscriptExporter.dateFolderForMs(ts)}/${_safeFileName(name.isNotEmpty ? name : path)}';
      final uploaded = await _syncFileWithFingerprint(file, rel);
      if (uploaded) {
        syncedToICloud = true;
        indexDirty = true;
      }
    }

    if (indexDirty) {
      await _saveIndex();
      if (!_disposed) notifyListeners();
    }
    return (savedToAlbum: savedToAlbum, syncedToICloud: syncedToICloud);
  }

  /// 导出单条录音的转录文本到本机「文件 → 我的 iPhone → 录音卡」，并在开启 iCloud 时按范围同步。
  Future<({bool localExported, bool icloudTextSynced, bool icloudAudioSynced})>
  backupRecording(RecordingFile file) async {
    if (_disposed) {
      return (
        localExported: false,
        icloudTextSynced: false,
        icloudAudioSynced: false,
      );
    }
    await ensureLoaded();

    var localExported = false;
    var icloudTextSynced = false;
    var icloudAudioSynced = false;
    var indexDirty = false;

    ExportedTranscriptFile? exported;
    try {
      exported = await _transcriptExporter.exportRecording(file);
      if (exported != null && exported.written) {
        localExported = true;
        localTranscriptCount = await _transcriptExporter.countExportedFiles();
      }
    } on Object catch (e) {
      debugPrint('[media_backup] 导出本机转录文本失败：$e');
    }

    if (_agentConfig.icloudSyncEnabled && !_agentConfig.localOnlyMode) {
      final scope = _agentConfig.icloudSyncScope;
      if (scope.includesText && exported != null) {
        final rel = 'Transcripts/${exported.relativePath}';
        final fp = '${exported.content.length}:${exported.content.hashCode}';
        if (_icloudFingerprints[rel] != fp) {
          final res = await _icloudSync.syncText(
            content: exported.content,
            relativePath: rel,
          );
          if (res.ok) {
            _icloudFingerprints[rel] = fp;
            icloudTextSynced = true;
            indexDirty = true;
          } else if (res.error != null) {
            lastICloudError = res.error;
            indexDirty = true;
          }
        }
      }

      if (scope.includesAudio) {
        final audioFile = await _resolveBestAudioFile(file);
        if (audioFile != null) {
          final startMs =
              file.startAtMs > 0 ? file.startAtMs : file.createdAtMs;
          final date = LocalTranscriptExporter.dateFolderForMs(startMs);
          final rel = 'Audio/$date/${_audioExportFileName(file, audioFile)}';
          final uploaded = await _syncFileWithFingerprint(audioFile, rel);
          if (uploaded) {
            icloudAudioSynced = true;
            indexDirty = true;
          }
        }
      }
    }

    if (indexDirty) {
      lastICloudSyncAtMs = DateTime.now().millisecondsSinceEpoch;
      await _saveIndex();
      if (!_disposed) notifyListeners();
    } else if (localExported && !_disposed) {
      notifyListeners();
    }
    return (
      localExported: localExported,
      icloudTextSynced: icloudTextSynced,
      icloudAudioSynced: icloudAudioSynced,
    );
  }

  Future<File?> _resolveBestAudioFile(RecordingFile file) async {
    final wav = file.wavPath;
    if (wav != null && wav.isNotEmpty) {
      final f = File(wav);
      if (await f.exists()) return f;
    }
    if (file.apmPath.isNotEmpty) {
      final f = File(file.apmPath);
      if (await f.exists()) return f;
    }
    return null;
  }

  String _audioExportFileName(RecordingFile file, File audioFile) {
    final ext = audioFile.path.toLowerCase().endsWith('.amr')
        ? '.amr'
        : (audioFile.path.toLowerCase().endsWith('.apm') ? '.apm' : '.wav');
    final rawBase = file.deviceName.trim().isNotEmpty
        ? _safeFileName(file.deviceName)
        : _safeFileName(audioFile.path);
    final stripped = rawBase.replaceFirst(RegExp(r'\.(wav|apm|amr)$', caseSensitive: false), '');
    return '$stripped$ext';
  }

  Future<bool> _syncFileWithFingerprint(File file, String relativePath) async {
    try {
      final stat = await file.stat();
      if (stat.size <= 0) return false;
      final fp = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
      if (_icloudFingerprints[relativePath] == fp) {
        return false;
      }
      final res = await _icloudSync.syncFile(
        sourcePath: file.path,
        relativePath: relativePath,
      );
      if (res.ok) {
        _icloudFingerprints[relativePath] = fp;
        lastICloudError = null;
        return true;
      }
      lastICloudError = res.error ?? '写入 iCloud 失败';
      return false;
    } on Object catch (e) {
      lastICloudError = '$e';
      return false;
    }
  }

  /// 全量整理并同步：
  /// - 所有录音导出本机 `.md` 文本到「文件 → 我的 iPhone → 录音卡」；
  /// - 补写未入相册的硬件照片与视频到系统相册（若相册开关开启）；
  /// - 若开启 iCloud 且非仅本机模式，按配置范围同步音频 / 文本及硬件照片视频到 iCloud 云盘。
  Future<MediaSyncReport> syncAllNow({
    required List<RecordingFile> recordings,
    Iterable<EventPhoto> hardwarePhotos = const <EventPhoto>[],
    String? photosDirPath,
    bool promptAlbumPermission = false,
  }) async {
    if (_disposed) {
      return const MediaSyncReport(
        localTranscriptsWritten: 0,
        albumSavedCount: 0,
        icloudUploadedCount: 0,
      );
    }
    final active = _inFlightSync;
    if (active != null) {
      return active;
    }

    final future = _runSyncAllNow(
      recordings: recordings,
      hardwarePhotos: hardwarePhotos,
      photosDirPath: photosDirPath,
      promptAlbumPermission: promptAlbumPermission,
    );
    _inFlightSync = future;
    notifyListeners();
    try {
      return await future;
    } finally {
      if (identical(_inFlightSync, future)) {
        _inFlightSync = null;
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<MediaSyncReport> _runSyncAllNow({
    required List<RecordingFile> recordings,
    required Iterable<EventPhoto> hardwarePhotos,
    String? photosDirPath,
    required bool promptAlbumPermission,
  }) async {
    await ensureLoaded();

    var localWritten = 0;
    var albumSaved = 0;
    var icloudUploaded = 0;
    String? icloudErr;

    final icloudActive =
        _agentConfig.icloudSyncEnabled && !_agentConfig.localOnlyMode;
    if (icloudActive) {
      final st = await _icloudSync.checkStatus();
      if (!st.available) {
        icloudErr = st.error ?? 'iCloud 云盘当前不可用';
        lastICloudError = icloudErr;
      }
    }

    final canPushICloud = icloudActive && icloudErr == null;
    final scope = _agentConfig.icloudSyncScope;

    for (final rec in recordings) {
      ExportedTranscriptFile? exported;
      try {
        exported = await _transcriptExporter.exportRecording(rec);
        if (exported != null && exported.written) localWritten++;
      } on Object {
        // 单条失败继续
      }
      if (canPushICloud) {
        if (scope.includesText && exported != null) {
          final rel = 'Transcripts/${exported.relativePath}';
          final fp = '${exported.content.length}:${exported.content.hashCode}';
          if (_icloudFingerprints[rel] != fp) {
            final res = await _icloudSync.syncText(
              content: exported.content,
              relativePath: rel,
            );
            if (res.ok) {
              _icloudFingerprints[rel] = fp;
              if (!res.skipped) icloudUploaded++;
            } else {
              icloudErr ??= res.error;
            }
          }
        }
        if (scope.includesAudio) {
          final audioFile = await _resolveBestAudioFile(rec);
          if (audioFile != null) {
            final startMs = rec.startAtMs > 0 ? rec.startAtMs : rec.createdAtMs;
            final date = LocalTranscriptExporter.dateFolderForMs(startMs);
            final rel = 'Audio/$date/${_audioExportFileName(rec, audioFile)}';
            if (await _syncFileWithFingerprint(audioFile, rel)) {
              icloudUploaded++;
            }
          }
        }
      }
    }

    // 汇总硬件照片/视频（先收集带明确时间戳的事件照片，再扫 photosDir 下尚未覆盖的 dyj 媒体）
    final seenPaths = <String>{};
    for (final p in hardwarePhotos) {
      if (p.source != 'dyj_camera' || p.path.trim().isEmpty) continue;
      seenPaths.add(p.path);
      final name =
          p.id.startsWith('dyj_') ? p.id.substring(4) : _safeFileName(p.path);
      final res = await _handleMediaInFullSync(
        name: name,
        path: p.path,
        capturedAtMs: p.capturedAtMs,
        promptAlbumPermission: promptAlbumPermission,
        pushICloud: canPushICloud,
      );
      if (res.savedToAlbum) albumSaved++;
      if (res.syncedToICloud) icloudUploaded++;
    }

    String? resolvedDirPath = photosDirPath;
    if (resolvedDirPath == null) {
      try {
        resolvedDirPath = (await _photoLibrary.photosDirectory()).path;
      } on Object {
        resolvedDirPath = null;
      }
    }
    if (resolvedDirPath != null && resolvedDirPath.isNotEmpty) {
      final dir = Directory(resolvedDirPath);
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          if (seenPaths.contains(entity.path)) continue;
          final baseName = _safeFileName(entity.path);
          if (baseName.startsWith('album_')) continue;
          final low = baseName.toLowerCase();
          if (!low.endsWith('.jpg') &&
              !low.endsWith('.jpeg') &&
              !low.endsWith('.mp4') &&
              !low.endsWith('.mov')) {
            continue;
          }
          final stat = await entity.stat();
          final res = await _handleMediaInFullSync(
            name: baseName,
            path: entity.path,
            capturedAtMs: stat.modified.millisecondsSinceEpoch,
            promptAlbumPermission: promptAlbumPermission,
            pushICloud: canPushICloud,
          );
          if (res.savedToAlbum) albumSaved++;
          if (res.syncedToICloud) icloudUploaded++;
        }
      }
    }

    localTranscriptCount = await _transcriptExporter.countExportedFiles();
    if (canPushICloud) {
      lastICloudSyncAtMs = DateTime.now().millisecondsSinceEpoch;
      lastICloudSyncedFiles = icloudUploaded;
      lastICloudError = icloudErr;
      lastICloudStats = await _icloudSync.listStats();
    }
    await _saveIndex();

    return MediaSyncReport(
      localTranscriptsWritten: localWritten,
      albumSavedCount: albumSaved,
      icloudUploadedCount: icloudUploaded,
      icloudError: icloudErr ?? lastICloudError,
    );
  }

  Future<({bool savedToAlbum, bool syncedToICloud})> _handleMediaInFullSync({
    required String name,
    required String path,
    required int? capturedAtMs,
    required bool promptAlbumPermission,
    required bool pushICloud,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      return (savedToAlbum: false, syncedToICloud: false);
    }
    final mediaType = inferMediaTypeFromPath(name);
    final mediaKey = 'dyj_${_safeFileName(name)}';
    var savedToAlbum = false;
    var syncedToICloud = false;

    if (_agentConfig.saveHardwareMediaToAlbum &&
        !_albumSavedIds.containsKey(mediaKey)) {
      final res = await _photoLibrary.saveMediaToAlbum(
        path: path,
        mediaType: mediaType,
        capturedAtMs: capturedAtMs,
        promptIfNeeded: promptAlbumPermission,
      );
      if (res.saved) {
        final localId = res.localIdentifier ?? '';
        _albumSavedIds[mediaKey] = localId;
        if (localId.isNotEmpty) {
          _exportedAlbumAssetIds.add(normalizeAlbumAssetId(localId));
        }
        savedToAlbum = true;
      }
    }

    if (pushICloud) {
      final ts = capturedAtMs ?? DateTime.now().millisecondsSinceEpoch;
      final folder = mediaType == 'video' ? 'Videos' : 'Photos';
      final rel =
          '$folder/${LocalTranscriptExporter.dateFolderForMs(ts)}/${_safeFileName(name)}';
      if (await _syncFileWithFingerprint(file, rel)) {
        syncedToICloud = true;
      }
    }

    return (savedToAlbum: savedToAlbum, syncedToICloud: syncedToICloud);
  }

  /// 清空本机导出的转录文本与备份索引（不删系统相册照片，也不删 iCloud 已有备份）。
  Future<void> clearLocalExports() async {
    await _transcriptExporter.clearAll();
    _albumSavedIds.clear();
    _exportedAlbumAssetIds.clear();
    _icloudFingerprints.clear();
    lastICloudSyncAtMs = null;
    lastICloudSyncedFiles = 0;
    lastICloudError = null;
    localTranscriptCount = 0;
    try {
      final file = await _indexFile();
      if (await file.exists()) await file.delete();
    } on Object {
      // 忽略索引删除异常
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
