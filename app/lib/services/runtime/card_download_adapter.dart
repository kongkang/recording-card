import 'dart:convert';
import 'dart:io';

import '../../core/device/card_gateway.dart';
import '../../core/models/record.dart';
import '../recordings/recording_download_gateway.dart';
import '../recordings/recording_models.dart';

/// V1 completed-file pull. BLE is normal; AP is explicit fast transfer only.
/// Neither transport may delete while downloading. SD metadata is untrusted.
class CardDownloadAdapter
    implements
        RecordingDownloadGateway,
        RecordingSourceCommitGateway,
        RecordingSourceReceiptGateway {
  CardDownloadAdapter(
    this.gateway, {
    this.transport = CardTransfer.ble,
    this.confirmSource,
    this.cancelTransfer,
    this.restoreWifiAfterSession = false,
  });
  final CardGateway gateway;
  final CardTransfer transport;
  final bool restoreWifiAfterSession;
  final RecordingSourceCommit? confirmSource;
  final Future<void> Function()? cancelTransfer;
  String? _deviceId;
  String? _activeRecordingSession;
  final Map<String, List<CardDownload>> _receipts = {};
  bool _opened = false;
  bool _cancelled = false;
  bool _enabledWifi = false;
  @override
  bool get usesNetwork => false;
  @override
  Future<void> openSession(String deviceId) async {
    if (_opened) throw StateError('下载会话正在进行');
    _cancelled = false;
    _deviceId = deviceId;
    final status = await gateway.status();
    if (status.deviceId != deviceId) throw StateError('下载目标身份与已连接设备不一致');
    if (status.realtimeEnabled) {
      throw StateError('设备实时传输已开启，不能与文件拉取混流；请显式关闭实时传输');
    }
    _activeRecordingSession = status.recording ? status.recordingSession : null;
    if (transport == CardTransfer.ap) {
      if (status.recording) {
        throw StateError('快传需要设备停止录音；请使用录音开关停止后重试，不会暗中停录');
      }
      _enabledWifi = !status.wifiOpen;
      if (_enabledWifi) await gateway.setWifiEnabled(true);
    } else if (status.wifiOpen) {
      throw StateError('Wi-Fi芯片正在占用存储，请关闭快传后使用普通BLE传输');
    }
    if (_cancelled) throw const RecordingSyncCancelled();
    _opened = true;
  }

  @override
  Future<void> closeSession(String deviceId) async {
    final restore = _enabledWifi || restoreWifiAfterSession;
    _opened = false;
    _enabledWifi = false;
    _deviceId = null;
    _activeRecordingSession = null;
    if (restore) await gateway.setWifiEnabled(false);
  }

  @override
  Future<List<RemoteRecording>> listRecordings(String deviceId) async {
    _check(deviceId);
    final files = await gateway.listFiles();
    final byName = {
      for (final f in files)
        if (!f.isDirectory) f.name.toLowerCase(): f,
    };
    final result = <RemoteRecording>[];
    for (final f in files) {
      if (f.isDirectory ||
          (_activeRecordingSession != null &&
              f.session == _activeRecordingSession) ||
          f.size == null ||
          f.size! <= 0 ||
          !RegExp(
            r'\.(apm|adpcm|wav|pcm)$',
            caseSensitive: false,
          ).hasMatch(f.name)) {
        continue;
      }
      _validateName(f.name);
      final stem = f.name.substring(0, f.name.lastIndexOf('.')).toLowerCase();
      final metadata = byName['$stem.txt'];
      final marks = byName['$stem.mrk'];
      for (final sidecar in [metadata, marks]) {
        if (sidecar != null) _validateName(sidecar.name);
        if (sidecar != null &&
            (sidecar.size == null ||
                sidecar.size! < 0 ||
                sidecar.size! > 256 * 1024)) {
          throw StateError('设备侧车大小无效或超限');
        }
      }
      result.add(
        RemoteRecording(
          fileId: '${f.session ?? ''}:${f.sequence ?? ''}:${f.name}',
          name: f.name,
          sizeBytes: f.size!,
          recordedAt: f.clockSynced == true && f.startAt != null
              ? DateTime.fromMillisecondsSinceEpoch(f.startAt! * 1000)
              : null,
          metadataSizeBytes: metadata?.size,
          markSizeBytes: marks?.size,
          metadata: {
            'session': f.session,
            'sequence': f.sequence,
            'clockSynced': f.clockSynced,
            'identityReliable': f.session != null && f.sequence != null,
            'metadataName': metadata?.name,
            'markName': marks?.name,
          },
        ),
      );
    }
    return result;
  }

  void _check([String? deviceId]) {
    if (_cancelled) throw const RecordingSyncCancelled();
    if (!_opened) throw StateError('文件下载会话未打开');
    if (deviceId != null && _deviceId != deviceId) {
      throw StateError('下载目标身份与会话设备不一致');
    }
  }

  void _validateName(String name) {
    if (name.isEmpty ||
        name.length > 255 ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        name == '.' ||
        name == '..') {
      throw const FormatException('设备文件名不安全');
    }
  }

  Future<CardDownload> _download(
    String name,
    String directory,
    int size,
    RecordingProgress? progress,
  ) async {
    _check();
    _validateName(name);
    final result = await gateway.downloadFilePreservingSource(
      name,
      directory: directory,
      expectedDeviceId: _deviceId!,
      expectedBytes: size,
      transport: transport,
      onProgress: (p) => progress?.call(p.done ?? 0, p.total),
    );
    if (result.sourceDeleted) throw StateError('下载协议提前删源，无法保证入库后删源；拒绝报告移动成功');
    _check();
    final local = File(result.path);
    final root = await Directory(directory).resolveSymbolicLinks();
    if (!await local.exists() ||
        !(await local.resolveSymbolicLinks()).startsWith('$root/') ||
        result.bytes != size ||
        await local.length() != size) {
      throw StateError('下载文件路径或大小校验失败；保留设备源文件');
    }
    return result;
  }

  @override
  Future<DownloadedRecording> downloadRecording(
    String deviceId,
    RemoteRecording recording, {
    required String destinationPath,
    required bool allowDestructive,
    RecordingProgress? onProgress,
  }) async {
    if (allowDestructive) throw StateError('本适配器禁止提前删源BLE take');
    _check(deviceId);
    // Native SDK names downloaded files. Unique private attempts avoid collisions
    // after a previous audio success / sidecar failure without overwriting source.
    final parent = File(destinationPath).parent;
    await parent.create(recursive: true);
    final dir = await parent.createTemp('${transport.name}-');
    final audio = await _download(
      recording.name,
      dir.path,
      recording.sizeBytes,
      onProgress,
    );
    final receipts = <CardDownload>[audio];
    String? metadataPath, markPath;
    final metadataName = recording.metadata['metadataName'] as String?;
    final markName = recording.metadata['markName'] as String?;
    if (metadataName != null && recording.metadataSizeBytes != null) {
      final metadata = await _download(
        metadataName,
        dir.path,
        recording.metadataSizeBytes!,
        null,
      );
      metadataPath = metadata.path;
      receipts.add(metadata);
    }
    final marks = <RecordMark>[];
    if (markName != null && recording.markSizeBytes != null) {
      final mark = await _download(
        markName,
        dir.path,
        recording.markSizeBytes!,
        null,
      );
      markPath = mark.path;
      receipts.add(mark);
      final file = File(markPath);
      if (await file.length() > 256 * 1024) {
        throw const FormatException('MRK sidecar too large');
      }
      final offsets = <int>{};
      for (final line
          in utf8
              .decode(await file.readAsBytes(), allowMalformed: true)
              .split('\n')) {
        final text = line.trim();
        if (text.isEmpty) continue;
        final seconds = RegExp(r'^\d{1,10}$').hasMatch(text)
            ? int.tryParse(text)
            : null;
        if (seconds == null ||
            seconds > 2147483647 ||
            (recording.durationMs != null &&
                seconds > recording.durationMs! ~/ 1000)) {
          throw const FormatException(
            'Invalid MRK seconds offset; raw sidecar retained',
          );
        }
        offsets.add(seconds);
      }
      final sorted = offsets.toList()..sort();
      marks.addAll(sorted.map((s) => RecordMark(offsetMs: s * 1000)));
    }
    _receipts[recording.fileId] = receipts;
    return DownloadedRecording(
      audioPath: audio.path,
      metadataPath: metadataPath,
      markPath: markPath,
      recordedAt: recording.recordedAt ?? audio.recordedAt,
      durationMs: recording.durationMs,
      marks: marks,
    );
  }

  @override
  bool hasPendingSourceReceipt(String deviceId, RemoteRecording recording) =>
      confirmSource != null ||
      (_receipts[recording.fileId]?.isNotEmpty == true &&
          _receipts[recording.fileId]!.every(
            (d) =>
                d.deviceId == deviceId &&
                d.downloadId != null &&
                d.sha256 != null,
          ));

  @override
  Future<bool> confirmImportedRecording(
    String deviceId,
    RemoteRecording recording,
    RecordingSourceReceipt receipt,
  ) async {
    _check(deviceId);
    if (receipt.sizeBytes != recording.sizeBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(receipt.contentHash)) {
      throw StateError('本机入库回执与设备文件不一致，保留源文件');
    }
    final confirm = confirmSource;
    if (confirm != null) return confirm(deviceId, recording, receipt);
    final downloads = _receipts[recording.fileId];
    if (downloads == null ||
        downloads.isEmpty ||
        downloads.any(
          (d) =>
              d.downloadId == null ||
              d.sha256 == null ||
              d.deviceId != deviceId,
        )) {
      return false;
    } // no Native receipt: safe copy, source remains on card
    final audio = downloads.first;
    if (audio.bytes != receipt.sizeBytes ||
        audio.sha256 != receipt.contentHash) {
      throw StateError('Native保源收据与最终入库音频不一致，禁止删源');
    }
    // Confirm paired sidecars first and audio last. Every asset is already
    // durable and verified by the repository; no delete runs during download.
    for (final download in downloads.reversed.toList()) {
      _check(deviceId);
      final verifiedPath = identical(download, audio)
          ? receipt.audioPath
          : download.originalName.toLowerCase().endsWith('.mrk')
          ? receipt.markPath
          : receipt.metadataPath;
      if (verifiedPath == null) throw StateError('已下载侧车尚未完整入库，禁止删源');
      try {
        await gateway.confirmDeleteFile(
          download,
          repositoryCommitted: true,
          verifiedPath: verifiedPath,
        );
      } on CardGatewayException catch (error) {
        if (error.code == 'source_retained') {
          // Durable import succeeded. Native truthfully cannot acknowledge a
          // deletion; leave receipts and source intact for explicit later retry.
          return false;
        }
        if (error.code == 'receipt' || error.code == 'identity') {
          _receipts.remove(
            recording.fileId,
          ); // next retry obtains a fresh receipt
        }
        rethrow;
      }
      downloads.remove(download); // already confirmed sidecars aren't repeated
    }
    _receipts.remove(recording.fileId);
    return true;
  }

  @override
  Future<void> cancelActive() async {
    _cancelled = true;
    await cancelTransfer?.call();
  }
}
