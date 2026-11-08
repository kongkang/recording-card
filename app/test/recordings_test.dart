// 录音仓库 + 同步协调器验收（TDD）—— 覆盖仓库持久化/排序/容错，
// 以及同步的导入、去重跳过、单文件失败继续、仅 Wi-Fi 拦截与统计。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/kv_store.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/services/recordings/card_file_gateway.dart';
import 'package:recording_card/services/recordings/recording.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';
import 'package:recording_card/services/recordings/sync_coordinator.dart';

/// 构造测试录音；默认时间固定，便于断言顺序。
Recording _rec(
  String id, {
  String? remoteFileId,
  DateTime? at,
  int durationMs = 1000,
}) => Recording(
  id: id,
  title: '标题 $id',
  recordedAt: at ?? DateTime(2026, 11, 1, 9),
  durationMs: durationMs,
  remoteFileId: remoteFileId,
);

RemoteRecordingFile _file(
  String id, {
  String? name,
  DateTime? at,
  String? mark,
}) => RemoteRecordingFile(
  id: id,
  name: name ?? '$id.wav',
  sizeBytes: 1024,
  recordedAt: at ?? DateTime(2026, 11, 2, 10),
  mark: mark,
);

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// 内存网关：内容 map 即「录音卡文件系统」，可注入列表/下载错误。
class FakeCardFileGateway implements CardFileGateway {
  FakeCardFileGateway({
    List<RemoteRecordingFile>? files,
    Map<String, Uint8List>? contents,
  }) : files = [...?files],
       contents = {...?contents};

  final List<RemoteRecordingFile> files;
  final Map<String, Uint8List> contents;
  final Set<String> failingIds = {};
  Object? listError;
  int listCalls = 0;
  final List<String> downloaded = [];

  @override
  Future<List<RemoteRecordingFile>> listFiles() async {
    listCalls++;
    final error = listError;
    if (error != null) throw error;
    return List.of(files);
  }

  @override
  Future<Uint8List> download(String fileId) async {
    downloaded.add(fileId);
    if (failingIds.contains(fileId)) {
      throw Exception('下载失败 $fileId');
    }
    final bytes = contents[fileId];
    if (bytes == null) throw Exception('文件不存在 $fileId');
    return bytes;
  }

  @override
  Future<void> upload(String fileId, Uint8List bytes) async {
    contents[fileId] = bytes;
  }
}

/// 默认导入器：按远程文件生成录音，id 与 remoteFileId 稳定映射。
Future<Recording> _import(RemoteRecordingFile file, Uint8List bytes) async {
  return Recording(
    id: 'rec-${file.id}',
    title: file.name,
    recordedAt: file.recordedAt,
    durationMs: bytes.length * 100,
    remoteFileId: file.id,
    mark: file.mark,
  );
}

void main() {
  group('RecordingRepository', () {
    test('upsert 后可读，持久化为单条 JSON 数组', () async {
      final kv = MemoryKvStore();
      final repo = RecordingRepository(kv);
      expect(repo.all(), isEmpty);

      await repo.upsert(_rec('a'));

      expect(repo.all().map((r) => r.id), ['a']);
      expect(repo.byId('a')?.title, '标题 a');
      final raw = kv.getString(RecordingRepository.storageKey);
      expect(raw, isNotNull);
      expect(jsonDecode(raw!), isA<List<dynamic>>());
      expect(jsonDecode(raw) as List<dynamic>, hasLength(1));
    });

    test('同 id upsert 覆盖而非新增', () async {
      final repo = RecordingRepository(MemoryKvStore());
      await repo.upsert(_rec('a', durationMs: 1000));
      await repo.upsert(_rec('a', durationMs: 2000));

      expect(repo.all(), hasLength(1));
      expect(repo.byId('a')?.durationMs, 2000);
    });

    test('remove 删除指定 id', () async {
      final repo = RecordingRepository(MemoryKvStore());
      await repo.upsert(_rec('a'));
      await repo.upsert(_rec('b'));

      await repo.remove('a');

      expect(repo.all().map((r) => r.id), ['b']);
      expect(repo.byId('a'), isNull);
    });

    test('all 按 recordedAt 倒序', () async {
      final repo = RecordingRepository(MemoryKvStore());
      await repo.upsert(_rec('old', at: DateTime(2026, 10, 1)));
      await repo.upsert(_rec('new', at: DateTime(2026, 11, 7, 18)));
      await repo.upsert(_rec('mid', at: DateTime(2026, 11, 3, 8)));

      expect(repo.all().map((r) => r.id), ['new', 'mid', 'old']);
    });

    test('重启后从同一 KvStore 恢复（含 turns / mark / 远程 id）', () async {
      final kv = MemoryKvStore();
      final first = RecordingRepository(kv);
      await first.upsert(
        Recording(
          id: 'a',
          title: '会议',
          recordedAt: DateTime(2026, 11, 6, 14, 20),
          durationMs: 1120000,
          rawTranscript: '原始',
          cleanTranscript: '清洗',
          mark: '重要',
          remoteFileId: 'f1',
          turns: const [
            SpeakerTurn(speaker: 'A', text: '你好', startMs: 0, endMs: 900),
          ],
        ),
      );

      final restored = RecordingRepository(kv);
      final rec = restored.byId('a');
      expect(rec, isNotNull);
      expect(rec!.title, '会议');
      expect(rec.recordedAt, DateTime(2026, 11, 6, 14, 20));
      expect(rec.durationMs, 1120000);
      expect(rec.mark, '重要');
      expect(rec.remoteFileId, 'f1');
      expect(rec.turns.single.speaker, 'A');
      expect(rec.turns.single.endMs, 900);
      expect(restored.containsRemote('f1'), isTrue);
      expect(restored.containsRemote('f2'), isFalse);
    });

    test('损坏 JSON 回落空列表且不抛，可继续写入', () async {
      final kv = MemoryKvStore({
        RecordingRepository.storageKey: '{不是合法 JSON',
      });

      final repo = RecordingRepository(kv);
      expect(repo.all(), isEmpty);

      await repo.upsert(_rec('a'));
      expect(repo.all().map((r) => r.id), ['a']);
    });

    test('JSON 非数组同样回落空列表', () {
      final kv = MemoryKvStore({
        RecordingRepository.storageKey: '{"a":1}',
      });
      expect(RecordingRepository(kv).all(), isEmpty);
    });

    test('replaceAll 整体替换并持久化', () async {
      final kv = MemoryKvStore();
      final repo = RecordingRepository(kv);
      await repo.upsert(_rec('old'));

      await repo.replaceAll([_rec('x'), _rec('y')]);

      expect(repo.all().map((r) => r.id), unorderedEquals(['x', 'y']));
      expect(RecordingRepository(kv).all(), hasLength(2));
    });

    test('fromJson 容错缺字段', () {
      final rec = Recording.fromJson({'id': 'x'});

      expect(rec.id, 'x');
      expect(rec.title, '');
      expect(rec.durationMs, 0);
      expect(rec.rawTranscript, isNull);
      expect(rec.cleanTranscript, isNull);
      expect(rec.mark, isNull);
      expect(rec.remoteFileId, isNull);
      expect(rec.turns, isEmpty);
      expect(rec.recordedAt, isA<DateTime>());
    });
  });

  group('SyncCoordinator', () {
    test('新文件全部导入：success + 统计正确 + 时间轴倒序', () async {
      final gateway = FakeCardFileGateway(
        files: [
          _file('f1', at: DateTime(2026, 11, 2, 9)),
          _file('f2', at: DateTime(2026, 11, 3, 9)),
        ],
        contents: {'f1': _bytes('aaa'), 'f2': _bytes('bbbb')},
      );
      final repo = RecordingRepository(MemoryKvStore());
      final settings = SettingsStore();
      addTearDown(settings.dispose);
      final sync = SyncCoordinator(
        gateway: gateway,
        repository: repo,
        settings: settings,
        importer: _import,
        isOnWifi: () => false,
      );

      final report = await sync.syncNow();

      expect(report.outcome, SyncOutcome.success);
      expect(report.imported, 2);
      expect(report.skipped, 0);
      expect(report.failed, 0);
      expect(report.errors, isEmpty);
      expect(gateway.downloaded, ['f1', 'f2']);
      expect(repo.all().map((r) => r.id), ['rec-f2', 'rec-f1']);
      expect(repo.byId('rec-f2')?.durationMs, 400);
    });

    test('已存在远程文件跳过，不重复下载', () async {
      final gateway = FakeCardFileGateway(
        files: [_file('f1'), _file('f2')],
        contents: {'f1': _bytes('a'), 'f2': _bytes('b')},
      );
      final repo = RecordingRepository(MemoryKvStore());
      await repo.upsert(_rec('rec-f1', remoteFileId: 'f1'));
      final settings = SettingsStore();
      addTearDown(settings.dispose);
      final sync = SyncCoordinator(
        gateway: gateway,
        repository: repo,
        settings: settings,
        importer: _import,
        isOnWifi: () => true,
      );

      final report = await sync.syncNow();

      expect(report.outcome, SyncOutcome.success);
      expect(report.imported, 1);
      expect(report.skipped, 1);
      expect(report.failed, 0);
      expect(gateway.downloaded, ['f2']);
      expect(repo.all(), hasLength(2));
    });

    test('单文件下载失败继续处理其他文件：partial + errors 记录', () async {
      final gateway = FakeCardFileGateway(
        files: [_file('f1'), _file('f2')],
        contents: {'f1': _bytes('a'), 'f2': _bytes('b')},
      )..failingIds.add('f1');
      final repo = RecordingRepository(MemoryKvStore());
      final settings = SettingsStore();
      addTearDown(settings.dispose);
      final sync = SyncCoordinator(
        gateway: gateway,
        repository: repo,
        settings: settings,
        importer: _import,
        isOnWifi: () => true,
      );

      final report = await sync.syncNow();

      expect(report.outcome, SyncOutcome.partial);
      expect(report.imported, 1);
      expect(report.skipped, 0);
      expect(report.failed, 1);
      expect(report.errors, hasLength(1));
      expect(report.errors.single, contains('f1'));
      expect(report.errors.single, contains('下载失败'));
      expect(repo.all().map((r) => r.id), ['rec-f2']);
      expect(gateway.downloaded, ['f1', 'f2']);
    });

    test('导入器抛错计入 failed，不中断后续文件', () async {
      final gateway = FakeCardFileGateway(
        files: [_file('f1'), _file('f2')],
        contents: {'f1': _bytes('a'), 'f2': _bytes('b')},
      );
      final repo = RecordingRepository(MemoryKvStore());
      final settings = SettingsStore();
      addTearDown(settings.dispose);
      final sync = SyncCoordinator(
        gateway: gateway,
        repository: repo,
        settings: settings,
        importer: (file, bytes) async {
          if (file.id == 'f1') throw Exception('转写失败');
          return _import(file, bytes);
        },
        isOnWifi: () => true,
      );

      final report = await sync.syncNow();

      expect(report.outcome, SyncOutcome.partial);
      expect(report.imported, 1);
      expect(report.failed, 1);
      expect(report.errors.single, contains('转写失败'));
      expect(repo.byId('rec-f1'), isNull);
      expect(repo.byId('rec-f2'), isNotNull);
    });

    test('全部文件失败：failed，无成功条目', () async {
      final gateway = FakeCardFileGateway(
        files: [_file('f1'), _file('f2')],
        contents: {'f1': _bytes('a'), 'f2': _bytes('b')},
      )..failingIds.addAll(['f1', 'f2']);
      final repo = RecordingRepository(MemoryKvStore());
      final settings = SettingsStore();
      addTearDown(settings.dispose);
      final sync = SyncCoordinator(
        gateway: gateway,
        repository: repo,
        settings: settings,
        importer: _import,
        isOnWifi: () => true,
      );

      final report = await sync.syncNow();

      expect(report.outcome, SyncOutcome.failed);
      expect(report.imported, 0);
      expect(report.skipped, 0);
      expect(report.failed, 2);
      expect(report.errors, hasLength(2));
      expect(repo.all(), isEmpty);
    });

    test('仅 Wi-Fi 同步且当前为蜂窝：blocked 且完全不调用网关', () async {
      final gateway = FakeCardFileGateway(
        files: [_file('f1')],
        contents: {'f1': _bytes('a')},
      );
      final repo = RecordingRepository(MemoryKvStore());
      final settings = SettingsStore()..toggle('仅 Wi-Fi 同步');
      addTearDown(settings.dispose);
      final sync = SyncCoordinator(
        gateway: gateway,
        repository: repo,
        settings: settings,
        importer: _import,
        isOnWifi: () => false,
      );

      final report = await sync.syncNow();

      expect(report.outcome, SyncOutcome.blocked);
      expect(report.imported, 0);
      expect(report.skipped, 0);
      expect(report.failed, 0);
      expect(report.message, isNotNull);
      expect(gateway.listCalls, 0);
      expect(gateway.downloaded, isEmpty);
      expect(repo.all(), isEmpty);
    });

    test('仅 Wi-Fi 同步且在 Wi-Fi：正常同步', () async {
      final gateway = FakeCardFileGateway(
        files: [_file('f1')],
        contents: {'f1': _bytes('a')},
      );
      final repo = RecordingRepository(MemoryKvStore());
      final settings = SettingsStore()..toggle('仅 Wi-Fi 同步');
      addTearDown(settings.dispose);
      final sync = SyncCoordinator(
        gateway: gateway,
        repository: repo,
        settings: settings,
        importer: _import,
        isOnWifi: () => true,
      );

      final report = await sync.syncNow();

      expect(report.outcome, SyncOutcome.success);
      expect(report.imported, 1);
      expect(gateway.listCalls, 1);
    });

    test('listFiles 抛错：failed 且 message 保留错误摘要', () async {
      final gateway = FakeCardFileGateway(
        files: [_file('f1')],
        contents: {'f1': _bytes('a')},
      )..listError = Exception('蓝牙连接已断开');
      final repo = RecordingRepository(MemoryKvStore());
      final settings = SettingsStore();
      addTearDown(settings.dispose);
      final sync = SyncCoordinator(
        gateway: gateway,
        repository: repo,
        settings: settings,
        importer: _import,
        isOnWifi: () => true,
      );

      final report = await sync.syncNow();

      expect(report.outcome, SyncOutcome.failed);
      expect(report.imported, 0);
      expect(report.errors, isEmpty);
      expect(report.message, contains('蓝牙连接已断开'));
      expect(repo.all(), isEmpty);
    });

    test('文件列表为空：success 且统计为零', () async {
      final gateway = FakeCardFileGateway();
      final repo = RecordingRepository(MemoryKvStore());
      final settings = SettingsStore();
      addTearDown(settings.dispose);
      final sync = SyncCoordinator(
        gateway: gateway,
        repository: repo,
        settings: settings,
        importer: _import,
        isOnWifi: () => true,
      );

      final report = await sync.syncNow();

      expect(report.outcome, SyncOutcome.success);
      expect(report.imported, 0);
      expect(report.skipped, 0);
      expect(report.failed, 0);
      expect(report.errors, isEmpty);
    });
  });
}
