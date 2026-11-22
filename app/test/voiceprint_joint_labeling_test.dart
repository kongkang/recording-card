// 声纹 × 语义联合识别、跨设备通道自适应、全库匹配、防误归并隔离与 UI 轻确认闭环测试。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/voiceprint_library_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/pages/detail_page.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/recordings/speaker_profile_store.dart';
import 'package:recording_card/services/voiceprint/joint_speaker_resolver.dart';
import 'package:recording_card/widgets/store_scope.dart';

import 'support/model_stub.dart';

List<double> _norm(List<double> v) {
  var sq = 0.0;
  for (final x in v) {
    sq += x * x;
  }
  final inv = sq <= 1e-12 ? 1.0 : 1.0 / math.sqrt(sq);
  return [for (final x in v) x * inv];
}

List<double> _basis(int idx, {int dim = 16}) => [
  for (var i = 0; i < dim; i++) i == idx ? 1.0 : 0.0,
];

List<double> _addWeighted(
  List<double> a,
  List<double> b,
  double wb,
) => _norm([
  for (var i = 0; i < math.min(a.length, b.length); i++) a[i] + b[i] * wb,
]);

void main() {
  test('1. 全库声纹扩展（>5 人）与遗留 matchFrequentOnly 对照', () {
    final vp = VoiceprintLibraryStore();
    vp.recordSelfSample(embedding: _basis(0), deviceLabel: '本机麦克风');

    const names = [
      '陈工',
      '林总',
      '赵姐',
      '周工',
      '黄老师',
      '徐总监',
      '郭经理',
      '何博士',
    ];
    for (var i = 0; i < names.length; i++) {
      vp.upsertPersonAndSample(
        name: names[i],
        embedding: _basis(i + 1),
        deviceLabel: '录音卡 V2',
        sourceLane: 'ble',
        preferFrequentSlot: true,
      );
    }

    // 5 置顶槽位已满，「郭经理」不在前 5 槽位中，但已在全部人物库中
    final guo = vp.findByName('郭经理');
    expect(guo, isNotNull);
    expect(guo!.isInFrequentSlot, isFalse);

    final probe = _basis(7); // 对应郭经理 (i=6 -> idx=7)
    final legacy = vp.matchFrequentOnly(probe);
    expect(legacy.confirmed?.name, isNot('郭经理'));

    final full = vp.matchAllProfiles(
      probe,
      deviceLabel: '录音卡 V2',
      sourceLane: 'ble',
      speechMs: 5000,
    );
    expect(full.scannedPersons, greaterThanOrEqualTo(9));
    expect(full.confirmed?.name, '郭经理');
    expect(full.margin, greaterThan(0.2));
  });

  test('2. 跨设备声纹冷启动通过「语义搭桥」自动确认并入库新通道质心，次日电话直出匹配', () {
    final vp = VoiceprintLibraryStore();
    vp.recordSelfSample(embedding: _basis(0), deviceLabel: '本机麦克风');

    final vChen = _norm([1.0, 0.25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    final vZhou = _norm([0, 0, 1.0, 0.2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

    vp.upsertPersonAndSample(
      name: '老陈',
      embedding: vChen,
      deviceLabel: '录音卡 V2',
      sourceLane: 'ble',
      preferFrequentSlot: true,
    );
    vp.upsertPersonAndSample(
      name: '小周',
      embedding: vZhou,
      deviceLabel: '录音卡 V2',
      sourceLane: 'ble',
      preferFrequentSlot: true,
    );

    // 模拟电话窄带频响偏移（系统性偏移落在第 12..14 维）
    final phoneBias = _norm([
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.0, 1.0, 0.5, 0,
    ]);
    List<double> phoneVec(List<double> clean) =>
        _addWeighted(clean, phoneBias, 1.05);

    for (final bgIdx in [5, 6, 7, 8]) {
      vp.observeChannelEmbedding(
        phoneVec(_basis(bgIdx)),
        deviceLabel: 'iPhone 电话窄带',
        sourceLane: 'phone',
      );
    }

    final vChenPhone = phoneVec(vChen);
    final vZhouPhone = phoneVec(vZhou);
    // 裸余弦已低于同设备高置信门槛
    expect(VoiceprintLibraryStore.cosineSimilarity(vChen, vChenPhone), lessThan(0.75));

    final bridgeRes = JointSpeakerResolver.resolveSession(
      session: 'ses-phone-1',
      speakerCentroids: {'说话人 1': vZhouPhone, '说话人 2': vChenPhone},
      speakerSpeechMs: const {'说话人 1': 4200, '说话人 2': 4500},
      semanticClues: const [
        SemanticSpeakerClue(
          speakerSlot: '说话人 2',
          candidateName: '老陈',
          confidence: 0.86,
          kind: SemanticClueKind.directVocative,
          evidence: '上句呼语「老陈，你点什么喝的？」后直接应答',
        ),
      ],
      voiceprintStore: vp,
      deviceLabel: 'iPhone 电话窄带',
      sourceLane: 'phone',
      sceneLabel: '客户电话沟通',
    );

    final confirmed = bridgeRes.autoConfirmed['说话人 2'];
    expect(confirmed, isNotNull);
    expect(confirmed!.personName, '老陈');
    expect(confirmed.source, SpeakerSuggestionSource.joint);
    expect(confirmed.shouldEnrollChannelCentroid, isTrue);

    // 将桥接确认的电话窄带子质心写入同一人物档案
    vp.upsertPersonAndSample(
      name: confirmed.personName,
      embedding: vChenPhone,
      deviceLabel: confirmed.deviceLabel,
      sourceLane: 'phone',
      sceneLabel: '客户电话沟通',
    );

    // 第二通电话无任何姓名呼语，纯声纹即可直接高置信确认「老陈」
    final directRes = JointSpeakerResolver.resolveSession(
      session: 'ses-phone-2',
      speakerCentroids: {'说话人 1': vZhouPhone, '说话人 2': vChenPhone},
      speakerSpeechMs: const {'说话人 1': 4000, '说话人 2': 4000},
      semanticClues: const [],
      voiceprintStore: vp,
      deviceLabel: 'iPhone 电话窄带',
      sourceLane: 'phone',
      sceneLabel: '次日跟进电话',
    );

    expect(directRes.autoConfirmed['说话人 2']?.personName, '老陈');
    expect(
      directRes.autoConfirmed['说话人 2']?.source,
      SpeakerSuggestionSource.voiceprint,
    );
  });

  test('3. 语义线索抗第三人称误伤与声纹-语义冲突降级保护', () {
    final thirdPartyClues = SemanticSpeakerClueExtractor.extractFromTurnLines(
      const [
        TurnLine('说话人 1', '你明天让老陈把合同顺便发过来。', '00:05'),
        TurnLine('说话人 2', '好的，我待会联系他。', '00:10'),
        TurnLine('说话人 1', '刚才张总说他下午不过来了。', '00:16'),
        TurnLine('说话人 2', '那我们改到明早。', '00:22'),
        TurnLine('说话人 1', '我不是王总，我是他助理。', '00:28'),
      ],
      knownNames: const {'老陈', '张总', '王总'},
    );
    expect(thirdPartyClues, isEmpty);

    final validClues = SemanticSpeakerClueExtractor.extractFromTurnLines(
      const [
        TurnLine('说话人 1', '大家好，我是林工，今天主要过下接口。', '00:05'),
        TurnLine('说话人 2', '老陈，你点什么喝的？', '00:12'),
        TurnLine('说话人 1', '冰美式少冰就行。', '00:16'),
      ],
      knownNames: const {'林工', '老陈'},
    );
    expect(
      validClues.any(
        (c) =>
            c.kind == SemanticClueKind.selfIntro &&
            c.speakerSlot == '说话人 1' &&
            c.candidateName == '林工',
      ),
      isTrue,
    );
    expect(
      validClues.any(
        (c) =>
            c.kind == SemanticClueKind.directVocative &&
            c.speakerSlot == '说话人 1' &&
            c.candidateName == '老陈',
      ),
      isTrue,
    );

    // 冲突保护：声纹疑似「阿杰」（非高置信绝对锁），但语义呼语强烈叫成「小周」→ 不得盲目自动确认，降级为带猜测建议
    final vp = VoiceprintLibraryStore();
    final vAJie = _basis(2);
    final vWeakAJie = _addWeighted(vAJie, _basis(9), 0.72); // cos ~ 0.81
    final vNoisyAJie = _addWeighted(vWeakAJie, _basis(10), 0.72); // cos < 0.74
    vp.upsertPersonAndSample(
      name: '阿杰',
      embedding: vAJie,
      deviceLabel: '录音卡 V2',
      sourceLane: 'ble',
    );
    vp.upsertPersonAndSample(
      name: '小周',
      embedding: _basis(4),
      deviceLabel: '录音卡 V2',
      sourceLane: 'ble',
    );

    final conflictRes = JointSpeakerResolver.resolveSession(
      session: 'ses-conflict',
      speakerCentroids: {'说话人 2': vNoisyAJie},
      speakerSpeechMs: const {'说话人 2': 4000},
      semanticClues: const [
        SemanticSpeakerClue(
          speakerSlot: '说话人 2',
          candidateName: '小周',
          confidence: 0.88,
          kind: SemanticClueKind.directVocative,
          evidence: '上句呼语「小周，你来看下」后直接应答',
        ),
      ],
      voiceprintStore: vp,
      deviceLabel: '录音卡 V2',
      sourceLane: 'ble',
    );
    expect(conflictRes.autoConfirmed.containsKey('说话人 2'), isFalse);
    expect(conflictRes.suggestions.containsKey('说话人 2'), isTrue);
  });

  test('4. 总结生成零向量上行约束与 speakerClues 自动入库对账', () async {
    const summaryWithClueJson = '''
{
  "title": "项目分工与确认",
  "overview": "明确了周总监负责后续客户推进。",
  "structure": [{"name": "分工", "leaves": ["客户跟进"]}],
  "points": [{"title": "对接确认", "detail": "确认了对接窗口。", "sources": ["ev-sum-1"]}],
  "todos": ["周总监本周完成客户回访"],
  "speakerClues": [
    {
      "eventId": "ev-sum-1",
      "slot": "说话人 2",
      "name": "周总监",
      "confidence": 0.85,
      "kind": "vocative",
      "evidence": "总结上下文指向周总监"
    }
  ]
}
''';
    final model = SummaryModel(content: summaryWithClueJson);
    const ev = RecordEvent(
      id: 'ev-sum-1',
      dayOffset: 0,
      title: '需求同步会',
      brief: '对齐本周客户跟进节奏',
      longText: '对齐本周客户跟进节奏',
      time: '15:00',
      dur: '3分10秒',
      speakers: '说话人 1（推测） / 说话人 2（推测）',
      mark: '',
      srcMap: '15:00—15:03',
      dialog: [
        TurnLine('说话人 1', '周总监，今天下午客户那边的方案就交给你推进了。', '15:00'),
        TurnLine('说话人 2', '没问题，我下午发邮件确认。', '15:01'),
      ],
      raw: [],
    );

    final store = AppStore(
      events: const [ev],
      generator: await model.generator(),
      loadPersistedState: false,
    );
    addTearDown(store.dispose);

    // 注入一条含特殊浮点标记（0.52631）的声纹样本，验证绝不外发任何向量数字
    store.voiceprintStore.upsertPersonAndSample(
      name: '陈工',
      embedding: _norm([0.52631, 0.85029, 0, 0, 0, 0, 0, 0]),
      deviceLabel: '录音卡 V2',
      sourceLane: 'ble',
      preferFrequentSlot: true,
    );

    store.startSummary();
    store.toggleSel(ev.id);
    store.genSummary();

    for (var i = 0; i < 60 && store.summaries.every((s) => s.state != SummaryState.done); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(model.requests, hasLength(1));
    final body = utf8.decode(model.requests.single.bodyBytes);
    expect(body, contains('陈工'));
    expect(body, isNot(contains('0.52631')));

    final pending = store.pendingSpeakerSuggestionsFor([ev.id]);
    expect(pending, hasLength(1));
    expect(pending.single.suggestion.speakerSlot, '说话人 2');
    expect(pending.single.suggestion.candidateName, '周总监');
  });

  testWidgets('5. UI 全闭环：1-Tap 轻确认 + 跨会话自动回填 + 一键撤销 + 单段解绑防污染', (
    tester,
  ) async {
    final tmpDir = Directory.systemTemp.createTempSync('rc-vp-joint-');
    addTearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    final recStore = RecordingStore(root: tmpDir);
    final profStore = SpeakerProfileStore(root: tmpDir);

    final vHost = _basis(1);
    final vZhang = _basis(3);

    final baseDay = DateTime(2026, 11, 22, 10, 0).millisecondsSinceEpoch;
    final histFile = RecordingFile(
      deviceName: 'REC_HIST_01',
      session: 'S-HIST',
      seq: 1,
      startAtMs: baseDay - 86400000,
      apmPath: '/tmp/rec_hist.apm',
      durationMs: 120000,
      createdAtMs: baseDay - 86400000 + 120000,
      stage: RecordingStage.ready,
      sourceLane: 'ble',
      sourceDeviceLabel: '录音卡 V2',
      slices: const [
        AudioSlice(
          id: 's0',
          index: 0,
          startMs: 0,
          endMs: 120000,
          wavPath: '',
          stage: SliceStage.polished,
        ),
      ],
      utterances: const [
        RawUtterance(
          id: 'uh1',
          sliceId: 's0',
          startMs: 0,
          endMs: 60000,
          text: '旧记录里暂时只按声纹标成了说话人 1。',
          speakerCluster: 0,
          speakerLabel: '说话人 1（推测）',
        ),
      ],
      turns: const [
        PolishedTurn(
          id: 'th1',
          startMs: 0,
          endMs: 60000,
          speakerLabel: '说话人 1（推测）',
          text: '旧记录里暂时只按声纹标成了说话人 1。',
          srcUtteranceIds: ['uh1'],
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg-hist',
          sessionId: 'S-HIST',
          index: 0,
          startAtMs: baseDay - 86400000,
          endAtMs: baseDay - 86400000 + 120000,
          title: '历史产品反馈',
          brief: '旧记录待自动回填',
          longText: '说话人 1：旧记录里暂时只按声纹标成了说话人 1。',
          speakerLabels: const ['说话人 1（推测）'],
          speakerCount: 1,
          status: SegmentStatus.closed,
          sliceIds: const ['s0'],
          turnIds: const ['th1'],
        ),
      ],
    );

    final nowFile = RecordingFile(
      deviceName: 'REC_NOW_02',
      session: 'S-NOW',
      seq: 2,
      startAtMs: baseDay,
      apmPath: '/tmp/rec_now.apm',
      durationMs: 120000,
      createdAtMs: baseDay + 120000,
      stage: RecordingStage.ready,
      sourceLane: 'ble',
      sourceDeviceLabel: '录音卡 V2',
      slices: const [
        AudioSlice(
          id: 'sn0',
          index: 0,
          startMs: 0,
          endMs: 120000,
          wavPath: '',
          stage: SliceStage.polished,
        ),
      ],
      utterances: const [
        RawUtterance(
          id: 'un1',
          sliceId: 'sn0',
          startMs: 0,
          endMs: 25000,
          text: '张总，这份预算表你帮忙看下。',
          speakerCluster: 0,
          speakerLabel: '说话人 1（推测）',
        ),
        RawUtterance(
          id: 'un2',
          sliceId: 'sn0',
          startMs: 26000,
          endMs: 90000,
          text: '好的，我现在马上核对。',
          speakerCluster: 1,
          speakerLabel: '说话人 2（推测）',
        ),
      ],
      turns: const [
        PolishedTurn(
          id: 'tn1',
          startMs: 0,
          endMs: 25000,
          speakerLabel: '说话人 1（推测）',
          text: '张总，这份预算表你帮忙看下。',
          srcUtteranceIds: ['un1'],
        ),
        PolishedTurn(
          id: 'tn2',
          startMs: 26000,
          endMs: 90000,
          speakerLabel: '说话人 2（推测）',
          text: '好的，我现在马上核对。',
          srcUtteranceIds: ['un2'],
        ),
      ],
      segments: [
        SegmentRecord(
          id: 'seg-now',
          sessionId: 'S-NOW',
          index: 0,
          startAtMs: baseDay,
          endAtMs: baseDay + 120000,
          title: '预算评审沟通',
          brief: '核对预算表',
          longText: '说话人 1：张总，这份预算表你帮忙看下。\n说话人 2：好的，我现在马上核对。',
          speakerLabels: const ['说话人 1（推测）', '说话人 2（推测）'],
          speakerCount: 2,
          status: SegmentStatus.closed,
          sliceIds: const ['sn0'],
          turnIds: const ['tn1', 'tn2'],
        ),
      ],
    );

    await tester.runAsync(() async {
      await recStore.save(histFile);
      await recStore.save(nowFile);
      await profStore.save(
        SpeakerProfileSet(
          session: 'S-HIST',
          deviceLabel: '录音卡 V2',
          profiles: [
            SpeakerProfile(index: 0, centroid: vZhang, speechMs: 60000),
          ],
        ),
      );
      await profStore.save(
        SpeakerProfileSet(
          session: 'S-NOW',
          deviceLabel: '录音卡 V2',
          profiles: [
            SpeakerProfile(index: 0, centroid: vHost, speechMs: 25000),
            SpeakerProfile(index: 1, centroid: vZhang, speechMs: 64000),
          ],
        ),
      );
    });

    final proj = SegmentProjection.build([histFile, nowFile]);
    final store = AppStore(events: const [], loadPersistedState: false);
    addTearDown(store.dispose);
    store.bindRecordingStoreForTest(recStore);
    store.recordingFiles = [histFile, nowFile];
    store.events = proj.events;
    store.segmentViews = proj.views;
    await tester.runAsync(
      () => store.reconcileVoiceprintsAndCluesForEvents(store.events),
    );

    final histEv = store.events.firstWhere((e) => e.id == 'seg-hist');
    final nowEv = store.events.firstWhere((e) => e.id == 'seg-now');

    await tester.pumpWidget(
      MaterialApp(
        theme: buildRCTheme(),
        home: StoreScope(
          store: store,
          child: Scaffold(body: DetailPage(eventId: nowEv.id)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 顶部出现「疑似张总」轻确认横幅，且气泡保留「疑似张总?」软提示
    expect(find.byKey(const Key('spk-suggest-bar')), findsOneWidget);
    expect(find.textContaining('疑似「张总」'), findsOneWidget);
    expect(find.textContaining('疑似张总?'), findsOneWidget);

    Future<void> pumpThroughIo(bool Function() done) async {
      for (var i = 0; i < 20 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    // 2. 1-Tap 确认「张总」 → 当前段落改名、声纹入库，并自动回填历史录音 histEv
    await tester.tap(find.byKey(Key('spk-suggest-confirm-${nowEv.id}-2')));
    await tester.pump();
    await pumpThroughIo(() => store.canUndoLastSpeakerNaming);

    expect(store.displaySpeaker(nowEv, '说话人 2'), '张总');
    expect(store.lastRetroSyncedEventCount, 1);
    expect(store.voiceprintStore.findByName('张总'), isNotNull);
    expect(store.pendingSpeakerSuggestionsFor([nowEv.id]), isEmpty);
    expect(store.displaySpeaker(histEv, '说话人 1'), '张总');
    expect(find.byKey(const Key('spk-suggest-bar')), findsNothing);

    // 3. 点击 SnackBar「撤销」一键回退整批自动同步
    expect(find.text('撤销'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(store.displaySpeaker(nowEv, '说话人 2'), '说话人 2（推测）');
    expect(store.displaySpeaker(histEv, '说话人 1'), '说话人 1（推测）');
    expect(find.byKey(const Key('spk-suggest-bar')), findsOneWidget);

    // 4. 再次确认后使用「本段不是他（解绑本段）」隔离误配片段，保留人物库与历史记录
    await tester.tap(find.byKey(Key('spk-suggest-confirm-${nowEv.id}-2')));
    await tester.pump();
    await pumpThroughIo(() => store.canUndoLastSpeakerNaming);
    expect(store.displaySpeaker(nowEv, '说话人 2'), '张总');
    expect(store.displaySpeaker(histEv, '说话人 1'), '张总');

    await tester.tap(find.byKey(Key('turn-who-${nowEv.id}-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qspk-detach-btn')), findsOneWidget);

    await tester.tap(find.byKey(const Key('qspk-detach-btn')));
    await tester.pumpAndSettle();

    expect(store.displaySpeaker(nowEv, '说话人 2'), '说话人 2（推测）');
    expect(store.displaySpeaker(histEv, '说话人 1'), '张总');
    expect(store.voiceprintStore.findByName('张总'), isNotNull);
  });
}
