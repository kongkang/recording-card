/// 录音同步协调器 —— 列表→去重→下载→导入→落库；单文件失败不中断。
/// 仅 Wi-Fi 同步开关在进入网关前拦截。
library;

import 'dart:typed_data';

import '../../core/store/settings_store.dart';
import 'card_file_gateway.dart';
import 'recording.dart';
import 'recording_repository.dart';

typedef RecordingImporter = Future<Recording> Function(
    RemoteRecordingFile file, Uint8List bytes);

enum SyncOutcome { success, blocked, partial, failed }

class SyncReport {
  const SyncReport({
    required this.outcome,
    this.imported = 0,
    this.skipped = 0,
    this.failed = 0,
    this.message,
    this.errors = const [],
  });

  final SyncOutcome outcome;
  final int imported;
  final int skipped;
  final int failed;
  final String? message;
  final List<String> errors;
}

class SyncCoordinator {
  SyncCoordinator({
    required this.gateway,
    required this.repository,
    required this.settings,
    required this.importer,
    required this.isOnWifi,
  });

  static const wifiOnlyKey = '仅 Wi-Fi 同步';

  final CardFileGateway gateway;
  final RecordingRepository repository;
  final SettingsStore settings;
  final RecordingImporter importer;
  final bool Function() isOnWifi;

  Future<SyncReport> syncNow() async {
    if (settings.valueOf(wifiOnlyKey) && !isOnWifi()) {
      return const SyncReport(
        outcome: SyncOutcome.blocked,
        message: '已开启仅 Wi-Fi 同步，当前网络不可用',
      );
    }

    final List<RemoteRecordingFile> files;
    try {
      files = await gateway.listFiles();
    } catch (e) {
      return SyncReport(
        outcome: SyncOutcome.failed,
        message: '拉取录音列表失败: $e',
      );
    }

    var imported = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];

    for (final file in files) {
      if (repository.containsRemote(file.id)) {
        skipped++;
        continue;
      }
      try {
        final bytes = await gateway.download(file.id);
        final recording = await importer(file, bytes);
        await repository.upsert(recording);
        imported++;
      } catch (e) {
        failed++;
        errors.add('${file.id}: $e');
      }
    }

    final outcome = switch ((imported, failed)) {
      (_, 0) => SyncOutcome.success,
      (0, _) => SyncOutcome.failed,
      _ => SyncOutcome.partial,
    };
    return SyncReport(
      outcome: outcome,
      imported: imported,
      skipped: skipped,
      failed: failed,
      errors: List.unmodifiable(errors),
    );
  }
}
