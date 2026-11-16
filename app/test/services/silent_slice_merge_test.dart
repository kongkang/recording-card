// 连续无语音切片自动折叠合并验收（M6）。
//
// 核心契约：
// 1. 仅在投影层（SegmentProjection）折叠同日连续无语音切片，绝不删除磁盘原始 .WAV；
// 2. [静音1, 静音2, 人声3, 静音4, 静音5] 投影为倒序 3 张卡：[合并(4~5), 人声3, 合并(1~2)]；
// 3. 锚定最早第一片 segment.id，新静音切片继续追加时主键恒定不跳变；
// 4. 物理打点 mark（如「单击重点 · 14:26」）受保护不被吞并，「流中断 N 次」自动累加；
// 5. 跨大时段（非同会话且间隔 > 5 分钟）不拼成虚假超长跨度；
// 6. 子切片关联照片自动聚合保留，详情页「原始数据」支持逐片点选切换回听。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';
import 'dart:typed_data';

import '../support/fake_gateway.dart';
import '../support/harness.dart';
import '../support/model_stub.dart';

class _NoopEngine implements SpeechEngine {
  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}
  @override
  Future<void> loadVad(String vadPath) async {}
  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [];
  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const AsrResult(
    text: '',
    tokens: [],
    timestampsMs: [],
    audioMs: 0,
  );
  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}
  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [];
  @override
  Future<void> dispose() async {}
}

class _NoopModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => null;
}

RecordingFile _silentSliceFile({
  required int seq,
  required int startAtMs,
  int durationMs = 60000,
  String session = 'SES_TODAY',
  String? wavPath,
  String? mark,
}) {
  final name = 'LIVE_${session}_${seq.toString().padLeft(4, '0')}.WAV';
  final path = wavPath ?? '/tmp/$name';
  return RecordingFile(
    deviceName: name,
    session: session,
    seq: seq,
    startAtMs: startAtMs,
    apmPath: path,
    wavPath: path,
    createdAtMs: startAtMs + durationMs,
    durationMs: durationMs,
    stage: RecordingStage.ready,
    segments: [
      SegmentRecord(
        id: 'seg-$name-0',
        sessionId: session,
        index: seq - 1,
        startAtMs: startAtMs,
        endAtMs: startAtMs + durationMs,
        title: '未识别到语音',
        brief: '本段未检测到有效人声，原始录音已保存在本机。',
        longText: '本段未检测到有效人声，原始录音已保存在本机，可在详情「原始数据」回听。',
        status: SegmentStatus.closed,
        mark: mark,
      ),
    ],
  );
}

RecordingFile _speechSliceFile({
  required int seq,
  required int startAtMs,
  int durationMs = 60000,
  String session = 'SES_TODAY',
  String text = '下午三点同步接口联调进展',
}) {
  final name = 'LIVE_${session}_${seq.toString().padLeft(4, '0')}.WAV';
  return RecordingFile(
    deviceName: name,
    session: session,
    seq: seq,
    startAtMs: startAtMs,
    apmPath: '/tmp/$name',
    wavPath: '/tmp/$name',
    createdAtMs: startAtMs + durationMs,
    durationMs: durationMs,
    stage: RecordingStage.ready,
    utterances: [
      RawUtterance(
        id: 'u-$seq',
        sliceId: '0000',
        startMs: 1000,
        endMs: 6000,
        text: text,
        speakerLabel: '说话人 1',
      ),
    ],
    segments: [
      SegmentRecord(
        id: 'seg-$name-0',
        sessionId: session,
        index: seq - 1,
        startAtMs: startAtMs,
        endAtMs: startAtMs + durationMs,
        title: text,
        brief: text,
        longText: '$text。',
        speakerLabels: const ['说话人 1'],
        speakerCount: 1,
        status: SegmentStatus.closed,
      ),
    ],
  );
}

void main() {
  int todayEpochMs(int hour, int minute, [int second = 0]) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, hour, minute, second)
        .millisecondsSinceEpoch;
  }

  test('[静音1, 静音2, 人声3, 静音4, 静音5] 被中间人声自然截断为前后两张合并卡 + 中间人声卡', () {
    final t0 = todayEpochMs(9, 0);
    final files = [
      _silentSliceFile(seq: 1, startAtMs: t0, mark: '流中断 1 次'),
      _silentSliceFile(seq: 2, startAtMs: t0 + 60000, mark: '流中断 2 次'),
      _speechSliceFile(seq: 3, startAtMs: t0 + 120000),
      _silentSliceFile(seq: 4, startAtMs: t0 + 180000),
      _silentSliceFile(seq: 5, startAtMs: t0 + 240000),
    ];

    final res = SegmentProjection.build(files);
    expect(res.events.length, 3, reason: '前后两段连续静音分别折叠，绝不跨越中间人声合并');

    // Timeline 倒序：最新在前 -> [合并(4~5), 人声3, 合并(1~2)]
    final latestMerged = res.events[0];
    final middleSpeech = res.events[1];
    final earliestMerged = res.events[2];

    expect(latestMerged.id, 'seg-LIVE_SES_TODAY_0004.WAV-0');
    expect(latestMerged.title, '未识别到语音');
    expect(latestMerged.dur, '2分');
    expect(latestMerged.speakers, '无语音');
    expect(latestMerged.mergedSliceCount, 2);

    expect(middleSpeech.title, '下午三点同步接口联调进展');

    expect(earliestMerged.id, 'seg-LIVE_SES_TODAY_0001.WAV-0');
    expect(earliestMerged.title, '未识别到语音');
    expect(earliestMerged.mark, '流中断 3 次', reason: '子切片流断档次数如实累加');
  });

  test('锚点 ID 稳定性：第 3 片无语音追加时，合并卡主键保持第一片 ID 不跳变', () {
    final t0 = todayEpochMs(8, 10);
    final s1 = _silentSliceFile(seq: 1, startAtMs: t0);
    final s2 = _silentSliceFile(seq: 2, startAtMs: t0 + 60000);
    final s3 = _silentSliceFile(seq: 3, startAtMs: t0 + 120000);

    final two = SegmentProjection.build([s1, s2]);
    expect(two.events.single.id, 'seg-LIVE_SES_TODAY_0001.WAV-0');
    expect(two.events.single.title, '未识别到语音');

    final three = SegmentProjection.build([s1, s2, s3]);
    expect(three.events.single.id, 'seg-LIVE_SES_TODAY_0001.WAV-0');
    expect(three.events.single.title, '未识别到语音');
    expect(three.events.single.dur, '3分');
    expect(three.mergedIdRedirects['seg-LIVE_SES_TODAY_0002.WAV-0'],
        'seg-LIVE_SES_TODAY_0001.WAV-0');
    expect(three.mergedIdRedirects['seg-LIVE_SES_TODAY_0003.WAV-0'],
        'seg-LIVE_SES_TODAY_0001.WAV-0');
  });

  test('物理打点保护与跨大时段隔离：带硬件重点标记或早晚跨会话大间隔切片绝不误合并', () {
    final tMorning = todayEpochMs(8, 0);
    final tNight = todayEpochMs(11, 30);

    final marked = _silentSliceFile(
      seq: 2,
      startAtMs: tMorning + 60000,
      mark: '单击重点 · 08:01',
    );
    final resMarked = SegmentProjection.build([
      _silentSliceFile(seq: 1, startAtMs: tMorning),
      marked,
      _silentSliceFile(seq: 3, startAtMs: tMorning + 120000),
    ]);
    expect(resMarked.events.length, 3, reason: '中间带物理键重点打点的切片不得被吞并');
    expect(resMarked.events[1].mark, '单击重点 · 08:01');

    // 不同会话且相隔数小时的两片静音：各自独立展示为「未识别到语音」
    final resGap = SegmentProjection.build([
      _silentSliceFile(seq: 1, startAtMs: tMorning, session: 'MORNING'),
      _silentSliceFile(seq: 1, startAtMs: tNight, session: 'LATE_MORNING'),
    ]);
    expect(resGap.events.length, 2, reason: '相隔数小时的不同会话静音绝不拼成超长假跨度');
    expect(resGap.events.first.title, '未识别到语音');
  });

  testWidgets('合并卡保留全部子切片关联照片，且详情「原始数据」可逐片点选切换原始 WAV 音频', (
    tester,
  ) async {
    late Directory root;
    late String wav1;
    late String wav2;
    late RecordingFile f1;
    late RecordingFile f2;
    late AppStore store;
    final gateway = FakeCardGateway();

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('rc-merge-ui-');
      wav1 = '${root.path}/s1.wav';
      wav2 = '${root.path}/s2.wav';
      await File(wav1).writeAsBytes(encodeWav(Float32List(16000)), flush: true);
      await File(wav2).writeAsBytes(encodeWav(Float32List(32000)), flush: true);

      final t0 = todayEpochMs(7, 30);
      final recStore = RecordingStore(root: Directory('${root.path}/store'));
      f1 = _silentSliceFile(
        seq: 1,
        startAtMs: t0,
        durationMs: 1000,
        wavPath: wav1,
      );
      f2 = _silentSliceFile(
        seq: 2,
        startAtMs: t0 + 1000,
        durationMs: 2000,
        wavPath: wav2,
      );
      await recStore.save(f1);
      await recStore.save(f2);

      final pipeline = RecordingPipeline(
        gateway: gateway,
        store: recStore,
        engine: _NoopEngine(),
        models: _NoopModels(),
      );
      store = AppStore(loadPersistedState: false)
        ..attachPipeline(
          pipeline: pipeline,
          store: recStore,
          generator: await SummaryModel().generator(),
        );
      store.photoSyncEnabled = () => false;
      await store.refreshFromStore();
    });
    addTearDown(() async {
      await gateway.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    // 模拟在合并前第 2 个子切片下已经挂了一张拍照记录：合并后必须完整保留！
    store.eventPhotos = {
      'seg-${f2.deviceName}-0': const [
        EventPhoto(
          id: 'p_child_2',
          time: '07:30:01',
          path: '',
          source: 'system_album',
        ),
      ],
    };

    expect(store.events.length, 1);
    final mergedEvent = store.events.single;
    expect(mergedEvent.title, '未识别到语音');
    expect(store.activePhotosForEvent(mergedEvent).single.id, 'p_child_2');

    await pumpShell(tester, store: store);
    expect(find.text('未识别到语音'), findsOneWidget);

    // 展开卡片进入详情页
    await tester.tap(find.byKey(Key('card-${mergedEvent.id}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(Key('detail-${mergedEvent.id}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('detail-silent-empty')), findsOneWidget);
    expect(find.byKey(Key('dphoto-${mergedEvent.id}-0')), findsOneWidget);

    // 切到「原始数据」Tab：两个子切片均列出且可点选切换播放器音频源
    await tester.tap(find.byKey(const Key('det-tab-raw')));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.byKey(const Key('raw-sticky-player')), findsOneWidget);
    expect(find.byKey(const Key('raw-merged-slice-0')), findsOneWidget);
    expect(find.byKey(const Key('raw-merged-slice-1')), findsOneWidget);

    var wav1Exists = false;
    var wav2Exists = false;
    await tester.runAsync(() async {
      wav1Exists = await File(wav1).exists();
      wav2Exists = await File(wav2).exists();
    });
    expect(wav1Exists, isTrue, reason: '原始音频文件完整保留绝不物理删除');
    expect(wav2Exists, isTrue);

    await tester.tap(find.byKey(const Key('raw-merged-slice-1')));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text(f2.deviceName), findsWidgets);
  });
}
