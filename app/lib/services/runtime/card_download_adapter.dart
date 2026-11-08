import 'dart:convert';
import 'dart:io';

import '../../core/device/card_gateway.dart';
import '../../core/models/record.dart';
import '../recordings/recording_download_gateway.dart';
import '../recordings/recording_models.dart';

/// AP reads only. Never BLE take; SD metadata is untrusted and bounded.
class CardDownloadAdapter implements RecordingDownloadGateway {
  CardDownloadAdapter(this.gateway);
  final CardGateway gateway;
  bool _opened = false;
  bool _cancelled = false;
  bool _enabledWifi = false;
  @override
  bool get usesNetwork => true;
  @override
  Future<void> openSession(String deviceId) async {
    _cancelled = false;
    final status = await gateway.status();
    if (status.deviceId != deviceId) throw StateError('下载目标身份与已连接设备不一致');
    if (status.realtimeEnabled || status.recording) {
      throw StateError('请先停止实时传输和设备录音，再以非破坏AP路径同步');
    }
    _enabledWifi = !status.wifiOpen;
    if (_enabledWifi) await gateway.setWifiEnabled(true);
    _opened = true;
  }

  @override
  Future<void> closeSession(String deviceId) async {
    final restore = _enabledWifi;
    _opened = false;
    _enabledWifi = false;
    if (restore) await gateway.setWifiEnabled(false);
  }

  @override
  Future<List<RemoteRecording>> listRecordings(String deviceId) async {
    _check();
    final files = await gateway.listFiles();
    final byName = {
      for (final f in files)
        if (!f.isDirectory) f.name.toLowerCase(): f,
    };
    final result = <RemoteRecording>[];
    for (final f in files) {
      if (f.isDirectory ||
          f.size == null ||
          f.size! <= 0 ||
          !RegExp(
            r'\.(apm|adpcm|wav|pcm)$',
            caseSensitive: false,
          ).hasMatch(f.name)) {
        continue;
      }
      final stem = f.name.substring(0, f.name.lastIndexOf('.')).toLowerCase();
      final metadata = byName['$stem.txt'];
      final marks = byName['$stem.mrk'];
      for (final sidecar in [metadata, marks]) {
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
            'metadataName': metadata?.name,
            'markName': marks?.name,
          },
        ),
      );
    }
    return result;
  }

  void _check() {
    if (!_opened || _cancelled) throw const RecordingSyncCancelled();
  }

  Future<CardDownload> _download(
    String name,
    String directory,
    int size,
    RecordingProgress? progress,
  ) async {
    _check();
    final result = await gateway.downloadFile(
      name,
      directory: directory,
      expectedBytes: size,
      transport: CardTransfer.ap,
      allowDestructive: false,
      onProgress: (p) => progress?.call(p.done ?? 0, p.total),
    );
    if (result.sourceDeleted) throw StateError('网关错误报告删源，拒绝将其记为非破坏同步成功');
    _check();
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
    if (allowDestructive) throw StateError('本适配器禁止删源BLE take');
    _check();
    // Native SDK names downloaded files. Unique private attempts avoid collisions
    // after a previous audio success / sidecar failure without overwriting source.
    final parent = File(destinationPath).parent;
    await parent.create(recursive: true);
    final dir = await parent.createTemp('ap-');
    final audio = await _download(
      recording.name,
      dir.path,
      recording.sizeBytes,
      onProgress,
    );
    String? metadataPath, markPath;
    final metadataName = recording.metadata['metadataName'] as String?;
    final markName = recording.metadata['markName'] as String?;
    if (metadataName != null && (recording.metadataSizeBytes ?? 0) > 0) {
      metadataPath = await _download(
        metadataName,
        dir.path,
        recording.metadataSizeBytes!,
        null,
      ).then((file) => file.path);
    }
    final marks = <RecordMark>[];
    if (markName != null && (recording.markSizeBytes ?? 0) > 0) {
      markPath = await _download(
        markName,
        dir.path,
        recording.markSizeBytes!,
        null,
      ).then((file) => file.path);
      final file = File(markPath!);
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
  Future<void> cancelActive() async {
    _cancelled = true;
  }
}
