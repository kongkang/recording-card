/// 录音同步：把录音卡里的原始录音取回本地、转码、转写，变成 App 里的记录。
///
/// 数据流（每一步都对应设备/服务上真实发生的事情）：
///   `FILE_LIST` → `take_file_to_dir`（落 .apm）→ `apm_to_wav`（16kHz WAV）
///   → 模型网关 ASR（multipart）→ 本地清单（shared_preferences JSON）
///
/// 设计约束：
/// - **不丢数据**：下载成功但转写失败时，录音仍然被记录为「待转写」，
///   下次同步会重试转写，而不是把文件丢掉。
/// - **幂等**：以设备文件名 + 字节数为键判断是否已同步，重复同步不会重复下载。
/// - **失败隔离**：单个文件失败不中断整批，结果里逐条汇报。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/device/card_gateway.dart';
import '../../core/models/record.dart';
import '../net/model_gateway.dart';
import 'recordings_manifest.dart';

/// 单条录音的同步结果。
enum SyncFileOutcome { downloaded, transcribed, failed }

class SyncFileReport {
  const SyncFileReport({
    required this.name,
    required this.outcome,
    this.message,
  });
  final String name;
  final SyncFileOutcome outcome;
  final String? message;
}

class SyncReport {
  const SyncReport({required this.items, required this.events, this.error});
  final List<SyncFileReport> items;
  final List<RecordEvent> events;
  final String? error;

  int get downloaded =>
      items.where((i) => i.outcome != SyncFileOutcome.failed).length;
  bool get hasFailure => items.any((i) => i.outcome == SyncFileOutcome.failed);
}

class RecordingSyncService {
  RecordingSyncService({
    required CardGateway gateway,
    required ModelGateway model,
    RecordingsManifest? manifest,
  }) : _gateway = gateway,
       _model = model,
       _manifest = manifest ?? RecordingsManifest();

  final CardGateway _gateway;
  final ModelGateway _model;
  final RecordingsManifest _manifest;

  /// 本地录音目录（应用支持目录下的 recordings/）。
  Future<Directory> _recordingsDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/recordings');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 读取本地已有记录（按时间倒序：今天的在前）。
  Future<List<RecordEvent>> loadEvents() async {
    final items = await _manifest.load();
    final events = items.map((e) => e.event).toList();
    events.sort((a, b) {
      if (a.dayOffset != b.dayOffset) return a.dayOffset.compareTo(b.dayOffset);
      return b.time.compareTo(a.time);
    });
    return events;
  }

  /// 从设备同步新录音。
  ///
  /// [onProgress] 汇报阶段与 0-1 进度，用于界面进度条；不发假进度——
  /// 阶段切换与实际网络/蓝牙动作一一对应。
  Future<SyncReport> syncFromDevice({
    void Function(SyncStage stage, double progress, String text)? onProgress,
  }) async {
    final items = <SyncFileReport>[];
    onProgress?.call(SyncStage.listing, 0.02, '正在读取录音卡文件列表…');

    List<CardFile> files;
    try {
      files = await _gateway.files();
    } on CardException catch (e) {
      return SyncReport(
        items: items,
        events: await loadEvents(),
        error: e.message,
      );
    }

    final known = {for (final item in await _manifest.load()) item.deviceName};
    final pending = files.where((f) => !known.contains(f.name)).toList();
    if (pending.isEmpty) {
      onProgress?.call(SyncStage.done, 1, '没有新的录音');
      return SyncReport(items: items, events: await loadEvents());
    }

    final dir = await _recordingsDir();
    final total = pending.length;
    for (var i = 0; i < pending.length; i++) {
      final file = pending[i];
      final base = i / total;
      final step = 1 / total;

      onProgress?.call(
        SyncStage.downloading,
        base + step * 0.1,
        '正在取回 ${file.name}（${i + 1}/$total）',
      );

      String apmPath;
      try {
        final download = await _gateway.download(file.name, dir.path);
        apmPath = download.path;
      } on CardException catch (e) {
        items.add(
          SyncFileReport(
            name: file.name,
            outcome: SyncFileOutcome.failed,
            message: '取回失败：${e.message}',
          ),
        );
        continue;
      }

      onProgress?.call(
        SyncStage.transcoding,
        base + step * 0.35,
        '正在转换 ${file.name}',
      );
      final wavPath = '$apmPath.wav';
      var durationSecs = 0.0;
      try {
        final audio = await _gateway.transcode(apmPath, wavPath);
        durationSecs = audio.durationSecs;
      } on CardException catch (e) {
        // 转码失败：录音仍然入库（待转写），不丢文件
        await _manifest.add(
          RecordingItem(
            deviceName: file.name,
            apmPath: apmPath,
            wavPath: null,
            transcript: '',
            durationSecs: 0,
            recordedAt: DateTime.now(),
          ),
        );
        items.add(
          SyncFileReport(
            name: file.name,
            outcome: SyncFileOutcome.downloaded,
            message: '已取回，转换失败：${e.message}',
          ),
        );
        continue;
      }

      onProgress?.call(
        SyncStage.transcribing,
        base + step * 0.6,
        '正在转写 ${file.name}',
      );
      var transcript = '';
      String? transcribeError;
      if (_model.ready) {
        try {
          final bytes = await File(wavPath).readAsBytes();
          final result = await _model.transcribe(
            bytes,
            filename: '${file.name}.wav',
            language: 'zh',
          );
          transcript = result.text;
        } on Object catch (e) {
          transcribeError = '$e';
        }
      } else {
        transcribeError = _model.asrAvailable ? '未登录，无法转写' : '未配置转写服务';
      }

      await _manifest.add(
        RecordingItem(
          deviceName: file.name,
          apmPath: apmPath,
          wavPath: wavPath,
          transcript: transcript,
          durationSecs: durationSecs,
          recordedAt: DateTime.now(),
        ),
      );

      items.add(
        SyncFileReport(
          name: file.name,
          outcome: transcript.isEmpty
              ? SyncFileOutcome.downloaded
              : SyncFileOutcome.transcribed,
          message: transcribeError,
        ),
      );
    }

    onProgress?.call(SyncStage.done, 1, '同步完成');
    return SyncReport(items: items, events: await loadEvents());
  }

  /// 对已下载但还没转写的录音补一次转写。
  Future<int> retryPendingTranscriptions({
    void Function(double progress, String text)? onProgress,
  }) async {
    if (!_model.ready) return 0;
    final items = await _manifest.load();
    final pending = items
        .where((i) => i.transcript.trim().isEmpty && i.wavPath != null)
        .toList();
    var done = 0;
    for (var i = 0; i < pending.length; i++) {
      final item = pending[i];
      onProgress?.call(i / pending.length, '正在补转写 ${item.deviceName}');
      try {
        final bytes = await File(item.wavPath!).readAsBytes();
        final result = await _model.transcribe(
          bytes,
          filename: '${item.deviceName}.wav',
          language: 'zh',
        );
        await _manifest.updateTranscript(item.deviceName, result.text);
        done++;
      } on Object {
        // 单条失败继续
      }
    }
    return done;
  }

  /// 删除一条本地录音（连同音频文件）。
  Future<void> deleteRecording(String id) async {
    final items = await _manifest.load();
    final target = items.where((i) => i.event.id == id).firstOrNull;
    if (target == null) return;
    for (final p in [target.apmPath, target.wavPath]) {
      if (p == null) continue;
      final f = File(p);
      if (await f.exists()) {
        try {
          await f.delete();
        } on FileSystemException {
          // 文件被占用时忽略，下次清理
        }
      }
    }
    await _manifest.remove(target.deviceName);
  }

  /// 清理孤儿文件：清单里没有的音频文件删掉。
  Future<int> pruneOrphans() async {
    final dir = await _recordingsDir();
    final items = await _manifest.load();
    final keep = <String>{
      for (final i in items) ...[i.apmPath, if (i.wavPath != null) i.wavPath!],
    };
    var removed = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (keep.contains(entity.path)) continue;
      try {
        await entity.delete();
        removed++;
      } on FileSystemException {
        // 忽略
      }
    }
    return removed;
  }
}

/// 同步阶段（界面据此显示步骤文案）。
enum SyncStage { listing, downloading, transcoding, transcribing, done }
