// 连续无语音切片自动折叠合并验收（M6）。
//
// 核心契约（2026-11-17）：
// 1. 无有效人声切片不进 Timeline/总结来源（磁盘 .WAV 仍保留）；
// 2. [静音1, 静音2, 人声3, 静音4, 静音5] 投影仅保留人声卡；
// 3. 连续静音仍在投影层折叠到锚点 ID，供照片等归属重定向；
// 4. 物理打点 mark（如「单击重点 · 14:26」）受保护仍可展示；
// 5. 跨大时段静音不拼成虚假超长跨度，且同样不展示；
// 6. 详情若从其它入口打开，仍可查看折叠后的原始分片。
library;

import 'dart:io';

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

  test('[静音1, 静音2, 人声3, 静音4, 静音5] 仅展示中间人声卡，静音不进 Timeline', () {
    final t0 = todayEpochMs(9, 0);
    final files = [
      _silentSliceFile(seq: 1, startAtMs: t0, mark: '流中断 1 次'),
      _silentSliceFile(seq: 2, startAtMs: t0 + 60000, mark: '流中断 2 次'),
      _speechSliceFile(seq: 3, startAtMs: t0 + 120000),
      _silentSliceFile(seq: 4, startAtMs: t0 + 180000),
      _silentSliceFile(seq: 5, startAtMs: t0 + 240000),
    ];

    final res = SegmentProjection.build(files);
    expect(res.events.length, 1, reason: '无语音切片不展示，只留有内容的人声卡');
    expect(res.events.single.title, '下午三点同步接口联调进展');
    expect(res.mergedIdRedirects['seg-LIVE_SES_TODAY_0002.WAV-0'],
        'seg-LIVE_SES_TODAY_0001.WAV-0');
    expect(res.mergedIdRedirects['seg-LIVE_SES_TODAY_0005.WAV-0'],
        'seg-LIVE_SES_TODAY_0004.WAV-0');
  });

  test('锚点 ID 稳定性：连续静音不进 feed，但 redirects 锚定第一片', () {
    final t0 = todayEpochMs(8, 10);
    final s1 = _silentSliceFile(seq: 1, startAtMs: t0);
    final s2 = _silentSliceFile(seq: 2, startAtMs: t0 + 60000);
    final s3 = _silentSliceFile(seq: 3, startAtMs: t0 + 120000);

    final two = SegmentProjection.build([s1, s2]);
    expect(two.events, isEmpty);
    expect(two.views.containsKey('seg-LIVE_SES_TODAY_0001.WAV-0'), isTrue);
    expect(two.mergedIdRedirects['seg-LIVE_SES_TODAY_0002.WAV-0'],
        'seg-LIVE_SES_TODAY_0001.WAV-0');

    final three = SegmentProjection.build([s1, s2, s3]);
    expect(three.events, isEmpty);
    expect(three.mergedIdRedirects['seg-LIVE_SES_TODAY_0002.WAV-0'],
        'seg-LIVE_SES_TODAY_0001.WAV-0');
    expect(three.mergedIdRedirects['seg-LIVE_SES_TODAY_0003.WAV-0'],
        'seg-LIVE_SES_TODAY_0001.WAV-0');
  });

  test('物理打点保护与跨大时段隔离：带硬件重点标记仍可展示；纯静音不展示', () {
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
    expect(resMarked.events.length, 1, reason: '仅保留带物理键重点打点的切片');
    expect(resMarked.events.single.mark, '单击重点 · 08:01');

    final resGap = SegmentProjection.build([
      _silentSliceFile(seq: 1, startAtMs: tMorning, session: 'MORNING'),
      _silentSliceFile(seq: 1, startAtMs: tNight, session: 'LATE_MORNING'),
    ]);
    expect(resGap.events, isEmpty, reason: '纯静音跨会话也不展示');
  });

  testWidgets('无语音不进 Timeline，但照片归属 redirects 与原始 WAV 仍保留', (
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

    // 无语音切片不进 Timeline，但 redirects / 照片归属仍锚定第一片。
    expect(store.events, isEmpty);
    final proj = SegmentProjection.build([f1, f2]);
    expect(proj.events, isEmpty);
    expect(proj.mergedIdRedirects['seg-${f2.deviceName}-0'], 'seg-${f1.deviceName}-0');
    expect(proj.views['seg-${f1.deviceName}-0']?.isMergedSilent, isTrue);

    var wav1Exists = false;
    var wav2Exists = false;
    await tester.runAsync(() async {
      wav1Exists = await File(wav1).exists();
      wav2Exists = await File(wav2).exists();
    });
    expect(wav1Exists, isTrue, reason: '原始音频文件完整保留绝不物理删除');
    expect(wav2Exists, isTrue);

    await pumpShell(tester, store: store);
    expect(find.textContaining('未识别到语音'), findsNothing);
  });
}
