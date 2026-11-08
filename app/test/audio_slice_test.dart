// 音频切片仓库 + 录音状态机验收 —— 测试先于实现，固定模块行为契约。
//
// 覆盖：切片 JSON 往返与容错、仓库去重 / 排序 / cursor / 重启恢复 / 损坏索引 /
// blob 读写、状态机全路径与 notify 次数。只依赖 KvStore 抽象 + 内存实现，
// 不触发平台通道（生产实现由 main.dart 注入）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/kv_store.dart';
import 'package:recording_card/services/audio/audio_slice.dart';
import 'package:recording_card/services/audio/audio_slice_repository.dart';
import 'package:recording_card/services/audio/recording_status.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

AudioSlice _slice({
  String id = 'slice-1',
  String sessionId = 'session-a',
  int seq = 0,
  int startMs = 0,
  int endMs = 1000,
  List<int> bytes = const [1, 2, 3],
  AudioSliceFormat format = AudioSliceFormat.adpcm,
  int? sampleRate = 16000,
  String? mark,
}) =>
    AudioSlice(
      id: id,
      sessionId: sessionId,
      seq: seq,
      startMs: startMs,
      endMs: endMs,
      bytes: _bytes(bytes),
      format: format,
      sampleRate: sampleRate,
      mark: mark,
    );

AudioSliceRepository _repo(KvStore kv, [AudioBlobStore? blobs]) =>
    AudioSliceRepository(index: kv, blobs: blobs ?? MemoryAudioBlobStore());

RecordingStatusController _controller() {
  final controller = RecordingStatusController();
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  group('AudioSlice JSON', () {
    test('往返保留全部字段，bytes 以 base64 编码', () {
      final slice = _slice(
        id: 's-42',
        sessionId: 'sess-9',
        seq: 7,
        startMs: 1200,
        endMs: 3600,
        bytes: const [0, 1, 127, 255],
        format: AudioSliceFormat.pcm16,
        sampleRate: 48000,
        mark: '决策点',
      );

      final json = slice.toJson();
      expect(json['bytes'], base64Encode(slice.bytes));
      expect(json['format'], 'pcm16');
      expect(json['sampleRate'], 48000);

      final restored = AudioSlice.fromJson(json);
      expect(restored.id, 's-42');
      expect(restored.sessionId, 'sess-9');
      expect(restored.seq, 7);
      expect(restored.startMs, 1200);
      expect(restored.endMs, 3600);
      expect(restored.bytes, [0, 1, 127, 255]);
      expect(restored.format, AudioSliceFormat.pcm16);
      expect(restored.sampleRate, 48000);
      expect(restored.mark, '决策点');
      expect(restored.durationMs, 2400);
    });

    test('缺字段回落默认值，坏类型不抛异常', () {
      final empty = AudioSlice.fromJson(const <String, dynamic>{});
      expect(empty.id, isEmpty);
      expect(empty.sessionId, isEmpty);
      expect(empty.seq, 0);
      expect(empty.startMs, 0);
      expect(empty.endMs, 0);
      expect(empty.bytes, isEmpty);
      expect(empty.format, AudioSliceFormat.adpcm);
      expect(empty.sampleRate, isNull);
      expect(empty.mark, isNull);

      final broken = AudioSlice.fromJson(<String, dynamic>{
        'id': 42,
        'sessionId': null,
        'seq': '7',
        'startMs': 1500.9,
        'endMs': true,
        'sampleRate': 'fast',
        'mark': 99,
      });
      expect(broken.id, isEmpty);
      expect(broken.sessionId, isEmpty);
      expect(broken.seq, 0);
      expect(broken.startMs, 1500, reason: '整型字段接受 num 并截断小数');
      expect(broken.endMs, 0);
      expect(broken.sampleRate, isNull);
      expect(broken.mark, isNull);
    });

    test('损坏 base64 回落空字节；未知格式回落 adpcm；格式名大小写容错', () {
      final corrupt = AudioSlice.fromJson(<String, dynamic>{
        'id': 'x',
        'bytes': '***not-base64***',
      });
      expect(corrupt.bytes, isEmpty);

      expect(
        AudioSlice.fromJson(<String, dynamic>{'format': 'WAV'}).format,
        AudioSliceFormat.wav,
      );
      expect(
        AudioSlice.fromJson(<String, dynamic>{'format': 'opus'}).format,
        AudioSliceFormat.adpcm,
      );
      expect(
        AudioSlice.fromJson(<String, dynamic>{'format': 3}).format,
        AudioSliceFormat.adpcm,
      );
    });

    test('bytes 不可变：构造时防御性拷贝，外部改动不影响切片', () {
      final source = _bytes(const [1, 2, 3]);
      final slice = AudioSlice(
        id: 'immutable',
        sessionId: 's',
        seq: 0,
        startMs: 0,
        endMs: 10,
        bytes: source,
      );

      source[0] = 9;
      expect(slice.bytes, [1, 2, 3]);
      expect(() => slice.bytes[0] = 9, throwsUnsupportedError);
    });

    test('空 mark 归一为 null', () {
      final slice = AudioSlice.fromJson(<String, dynamic>{
        'id': 'x',
        'mark': '',
      });
      expect(slice.mark, isNull);
    });
  });

  group('MemoryAudioBlobStore', () {
    test('写入 / 读取 / 覆盖 / 删除', () async {
      final store = MemoryAudioBlobStore();
      expect(await store.read('missing'), isNull);

      await store.write('a', _bytes(const [1, 2, 3]));
      expect(await store.read('a'), [1, 2, 3]);

      await store.write('a', _bytes(const [7]));
      expect(await store.read('a'), [7]);

      await store.delete('a');
      expect(await store.read('a'), isNull);
    });

    test('读写均为拷贝，外部缓冲改动不串音', () async {
      final store = MemoryAudioBlobStore();
      final source = _bytes(const [1, 2]);
      await store.write('a', source);
      source[0] = 9;
      expect(await store.read('a'), [1, 2]);

      final read = (await store.read('a'))!;
      read[0] = 7;
      expect(await store.read('a'), [1, 2]);
    });
  });

  group('AudioSliceRepository · 写入与去重', () {
    test('add 保存 blob 与索引，重复 id 返回 false 且不覆盖 blob', () async {
      final kv = MemoryKvStore();
      final blobs = MemoryAudioBlobStore();
      final repo = _repo(kv, blobs);

      expect(await repo.add(_slice(id: 'a', bytes: const [1, 2, 3])), isTrue);
      expect(repo.all().map((s) => s.id), ['a']);
      expect(await blobs.read('a'), [1, 2, 3]);
      expect(kv.getString(AudioSliceRepository.storageKey), isNotNull);

      expect(await repo.add(_slice(id: 'a', bytes: const [9, 9, 9])), isFalse);
      expect(repo.all(), hasLength(1));
      expect(await blobs.read('a'), [1, 2, 3],
          reason: '重复切片不得改写已有音频');
    });

    test('sessionId + seq 去重，同 seq 不同会话可共存', () async {
      final blobs = MemoryAudioBlobStore();
      final repo = _repo(MemoryKvStore(), blobs);

      expect(await repo.add(_slice(id: 'a', sessionId: 's1', seq: 0)), isTrue);
      expect(await repo.add(_slice(id: 'b', sessionId: 's1', seq: 0)), isFalse);
      expect(await repo.add(_slice(id: 'c', sessionId: 's1', seq: 1)), isTrue);
      expect(await repo.add(_slice(id: 'd', sessionId: 's2', seq: 0)), isTrue);
      expect(await repo.add(_slice(id: 'e', sessionId: 's2', seq: 2)), isTrue);

      expect(repo.all(), hasLength(4));
      expect(await blobs.read('b'), isNull, reason: '被拒切片不落 blob');
    });

    test('空 id 拒绝写入', () async {
      final repo = _repo(MemoryKvStore());
      expect(await repo.add(_slice(id: '')), isFalse);
      expect(repo.all(), isEmpty);
    });

    test('索引只写元数据 + 长度 + hash，不写音频本体', () async {
      final kv = MemoryKvStore();
      final repo = _repo(kv);
      const payload = [1, 2, 3, 250];
      await repo.add(_slice(mark: '重点', bytes: payload));

      final raw = kv.getString(AudioSliceRepository.storageKey)!;
      final decoded = jsonDecode(raw) as List<dynamic>;
      final meta = decoded.single as Map<String, dynamic>;
      expect(meta.containsKey('bytes'), isFalse);
      expect(meta['byteLength'], payload.length);
      expect(meta['hash'], sha256.convert(payload).toString());
      expect(meta['mark'], '重点');
      expect(raw, isNot(contains(base64Encode(payload))));
    });
  });

  group('AudioSliceRepository · 排序与 cursor', () {
    test('all 按 startMs 升序，cursor 为最后一条 id', () async {
      final repo = _repo(MemoryKvStore());
      expect(repo.cursor, isNull);

      await repo.add(_slice(id: 'late', seq: 2, startMs: 3000, endMs: 4000));
      await repo.add(_slice(id: 'early', seq: 0, startMs: 1000, endMs: 2000));
      await repo.add(_slice(id: 'mid', seq: 1, startMs: 2000, endMs: 3000));

      expect(repo.all().map((s) => s.id), ['early', 'mid', 'late']);
      expect(repo.cursor, 'late');

      // 重复写入不改变排序 / 游标
      await repo.add(_slice(id: 'mid', startMs: 2000));
      expect(repo.all().map((s) => s.id), ['early', 'mid', 'late']);
      expect(repo.cursor, 'late');
    });

    test('startMs 相同按 seq / id 稳定排序', () async {
      final repo = _repo(MemoryKvStore());
      await repo.add(_slice(
          id: 'b', sessionId: 's-b', seq: 1, startMs: 100, endMs: 200));
      await repo.add(_slice(
          id: 'a', sessionId: 's-a', seq: 1, startMs: 100, endMs: 200));
      await repo.add(_slice(
          id: 'c', sessionId: 's-c', seq: 0, startMs: 100, endMs: 200));

      expect(repo.all().map((s) => s.id), ['c', 'a', 'b']);
    });
  });

  group('AudioSliceRepository · 持久化', () {
    test('重启恢复元数据，音频仍可从 blob store 读取', () async {
      final kv = MemoryKvStore();
      final blobs = MemoryAudioBlobStore();
      final repo = _repo(kv, blobs);

      await repo.add(_slice(
        id: 'a',
        startMs: 100,
        endMs: 600,
        bytes: const [1, 2],
        format: AudioSliceFormat.wav,
        sampleRate: 48000,
        mark: '决策',
      ));

      final restored = _repo(kv, blobs);
      final slice = restored.all().single;
      expect(slice.id, 'a');
      expect(slice.startMs, 100);
      expect(slice.endMs, 600);
      expect(slice.format, AudioSliceFormat.wav);
      expect(slice.sampleRate, 48000);
      expect(slice.mark, '决策');
      expect(slice.bytes, isEmpty, reason: '索引不保存音频本体');
      expect(await blobs.read('a'), [1, 2]);
      expect(restored.cursor, 'a');
    });

    test('重启后仍按 id / sessionId+seq 去重', () async {
      final kv = MemoryKvStore();
      final blobs = MemoryAudioBlobStore();
      await _repo(kv, blobs).add(_slice(id: 'a', sessionId: 's', seq: 0));

      final restored = _repo(kv, blobs);
      expect(await restored.add(_slice(id: 'a', sessionId: 's', seq: 9)), isFalse);
      expect(
        await restored.add(_slice(id: 'b', sessionId: 's', seq: 0)),
        isFalse,
        reason: 'sessionId+seq 索引随元数据恢复',
      );
      expect(await restored.add(_slice(id: 'c', sessionId: 's', seq: 1)), isTrue);
      expect(restored.all(), hasLength(2));
    });

    test('损坏索引回落空仓库，且可继续写入', () async {
      final kv = MemoryKvStore({
        AudioSliceRepository.storageKey: '{not-json',
      });
      final repo = _repo(kv);
      expect(repo.all(), isEmpty);
      expect(repo.cursor, isNull);

      expect(await repo.add(_slice(id: 'after')), isTrue);
      expect(_repo(kv).all().map((s) => s.id), ['after']);
    });

    test('索引不是列表 / 非法条目被忽略', () async {
      final notList = MemoryKvStore({
        AudioSliceRepository.storageKey: '{"slices":[]}',
      });
      expect(_repo(notList).all(), isEmpty);

      final kv = MemoryKvStore({
        AudioSliceRepository.storageKey: jsonEncode(<Object?>[
          42,
          'nope',
          null,
          <String, dynamic>{'sessionId': 's', 'seq': 0},
          <String, dynamic>{
            'id': 'ok',
            'sessionId': 's',
            'seq': 1,
            'startMs': 10,
            'endMs': 20,
            'format': 'wav',
          },
        ]),
      });
      final repo = _repo(kv);
      expect(repo.all().map((s) => s.id), ['ok']);
      expect(repo.all().single.format, AudioSliceFormat.wav);
      expect(repo.all().single.bytes, isEmpty);
    });

    test('clear 清空索引与 blob，重启后仍为空', () async {
      final kv = MemoryKvStore();
      final blobs = MemoryAudioBlobStore();
      final repo = _repo(kv, blobs);
      await repo.add(_slice(id: 'a'));
      await repo.add(_slice(id: 'b', seq: 1));

      await repo.clear();
      expect(repo.all(), isEmpty);
      expect(repo.cursor, isNull);
      expect(await blobs.read('a'), isNull);
      expect(await blobs.read('b'), isNull);
      expect(kv.getString(AudioSliceRepository.storageKey), isNull);
      expect(_repo(kv, blobs).all(), isEmpty);
    });
  });

  group('RecordingStatusController', () {
    test('初始为 idle，无错误、无待处理切片', () {
      final controller = _controller();
      expect(controller.phase, RecordingPhase.idle);
      expect(controller.pendingSlices, 0);
      expect(controller.lastError, isNull);
      expect(controller.isRecording, isFalse);
      expect(controller.isTranscribing, isFalse);
    });

    test('start → recording；重复 start 不重复通知', () {
      final controller = _controller();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.startRecording();
      expect(controller.phase, RecordingPhase.recording);
      expect(controller.isRecording, isTrue);
      expect(notified, 1);

      controller.startRecording();
      expect(controller.phase, RecordingPhase.recording);
      expect(notified, 1, reason: '状态未变化不通知');
    });

    test('recording 下切片计数；非 recording 下切片被忽略', () {
      final controller = _controller();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.startRecording();
      notified = 0;

      controller.onSliceReceived();
      controller.onSliceReceived();
      expect(controller.pendingSlices, 2);
      expect(notified, 2);

      controller.onTranscriptionStarted();
      expect(controller.phase, RecordingPhase.transcribing);
      expect(notified, 3);

      controller.onSliceReceived();
      expect(controller.pendingSlices, 2, reason: '转录中不再累计新切片');
      expect(notified, 3);

      controller.stopRecording();
      expect(controller.phase, RecordingPhase.idle);
      expect(controller.pendingSlices, 0);
      expect(notified, 4);

      controller.onSliceReceived();
      expect(controller.pendingSlices, 0);
      expect(notified, 4);
    });

    test('转录完成：>0 保持 transcribing，==0 回 recording', () {
      final controller = _controller();
      controller.startRecording();
      controller.onSliceReceived();
      controller.onSliceReceived();
      controller.onTranscriptionStarted();

      var notified = 0;
      controller.addListener(() => notified++);

      controller.onTranscriptionCompleted();
      expect(controller.phase, RecordingPhase.transcribing);
      expect(controller.pendingSlices, 1);
      expect(notified, 1);

      controller.onTranscriptionCompleted();
      expect(controller.phase, RecordingPhase.recording);
      expect(controller.pendingSlices, 0);
      expect(notified, 2);

      controller.onTranscriptionCompleted();
      expect(controller.phase, RecordingPhase.recording,
          reason: '已完成数超出待处理数时保持录音态');
      expect(controller.pendingSlices, 0, reason: 'pending 不为负');
      expect(notified, 2);
    });

    test('录音中 stop 后转录完成回 idle，不出现负计数', () {
      final controller = _controller();
      controller.startRecording();
      controller.onSliceReceived();
      controller.onTranscriptionStarted();
      expect(controller.phase, RecordingPhase.transcribing);

      controller.stopRecording();
      expect(controller.phase, RecordingPhase.idle);
      expect(controller.pendingSlices, 0);

      var notified = 0;
      controller.addListener(() => notified++);
      controller.onTranscriptionCompleted();
      expect(controller.phase, RecordingPhase.idle);
      expect(controller.pendingSlices, 0);
      expect(notified, 0);
    });

    test('onError 保留信息与 pending；stop 后保留错误，start 清空', () {
      final controller = _controller();
      controller.startRecording();
      controller.onSliceReceived();

      var notified = 0;
      controller.addListener(() => notified++);

      controller.onError(StateError('boom'));
      expect(controller.phase, RecordingPhase.error);
      expect(controller.lastError, contains('boom'));
      expect(controller.pendingSlices, 1);
      expect(notified, 1);

      controller.onError(StateError('boom'));
      expect(notified, 1, reason: '同样的错误重复上报不重复通知');

      controller.onError('upload failed');
      expect(controller.lastError, 'upload failed');
      expect(notified, 2);

      controller.stopRecording();
      expect(controller.phase, RecordingPhase.idle);
      expect(controller.pendingSlices, 0);
      expect(controller.lastError, 'upload failed');
      expect(notified, 3);

      controller.startRecording();
      expect(controller.phase, RecordingPhase.recording);
      expect(controller.lastError, isNull, reason: '新会话清理旧错误');
      expect(notified, 4);
    });

    test('error 态忽略切片；stop 后可重新开始并恢复计数', () {
      final controller = _controller();
      controller.startRecording();
      controller.onError('x');
      controller.onSliceReceived();
      expect(controller.pendingSlices, 0);

      controller.stopRecording();
      controller.startRecording();
      controller.onSliceReceived();
      expect(controller.phase, RecordingPhase.recording);
      expect(controller.pendingSlices, 1);
    });

    test('全路径 notify 次数精确', () {
      final controller = _controller();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.startRecording(); // 1
      controller.onSliceReceived(); // 2
      controller.onSliceReceived(); // 3
      controller.onTranscriptionStarted(); // 4
      controller.onTranscriptionCompleted(); // 5
      controller.onTranscriptionCompleted(); // 6
      controller.onTranscriptionCompleted(); // 状态不变
      controller.stopRecording(); // 7
      controller.stopRecording(); // 状态不变
      controller.onSliceReceived(); // 非录音态忽略
      controller.onError('x'); // 8
      controller.onError('x'); // 状态不变
      controller.onError('y'); // 9
      controller.startRecording(); // 10
      controller.startRecording(); // 状态不变
      controller.stopRecording(); // 11

      expect(notified, 11);
      expect(controller.phase, RecordingPhase.idle);
      expect(controller.pendingSlices, 0);
    });
  });
}
