import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/services/analysis/analysis_service.dart';
import 'package:recording_card/services/analysis/source_catalog.dart';
import 'package:recording_card/services/transcription/transcription_types.dart';

RecordEvent event({
  String id = 'new-record-42',
  String text = '实验温度升至三十度',
  List<TurnLine>? raw,
}) {
  final lines =
      raw ??
      [
        TurnLine('未知', text, '来源 08:10:00—08:10:15'),
        const TurnLine('未知', '下周复测，但日期尚未决定。', '来源 08:10:15—08:10:30'),
      ];
  return RecordEvent(
    id: id,
    dayOffset: 0,
    title: '温控实验',
    brief: '不应作为原始来源',
    longText: '不应泄露未选行',
    time: '08:10',
    dur: '30秒',
    speakers: '未知',
    mark: '',
    srcMap: '来源 08:10:00—08:10:30',
    dialog: lines,
    raw: lines,
  );
}

Map<String, dynamic> summaryData({
  String id = 'new-record-42',
  int rawIndex = 0,
  String title = '实验总结',
}) {
  final refs = [
    {'sourceId': id, 'rawIndex': rawIndex},
  ];
  return {
    'title': title,
    'overview': {'text': '实验观察温度变化，复测日期不确定。', 'sources': refs},
    'logic': [
      {
        'name': '观察与后续',
        'leaves': ['温度发生变化', '继续验证'],
        'sources': refs,
      },
    ],
    'points': [
      {'title': '温控观察', 'detail': '依据此次实验转写。', 'sources': refs},
    ],
    'todos': [
      {'text': '安排复测', 'sources': refs},
    ],
    'uncertainties': ['日期未定'],
  };
}

SummaryCard card([String id = 's-new']) => SummaryCard(id: id, time: '08:11');
Matcher analysisCode(String code) =>
    isA<AnalysisException>().having((e) => e.code, 'code', code);

void main() {
  test(
    'non-seed record creates every result section and canonical sources',
    () async {
      String? prompt;
      final stages = <SummaryStage>[];
      final service = AnalysisService(
        gateway: CallbackAnalysisGateway((p, {model}) async {
          prompt = p;
          return jsonEncode(summaryData());
        }),
        onSummaryChanged: (c) => stages.add(c.stage),
      );
      final target = await service.generateSummary([event()], target: card());
      expect(target.state, SummaryState.done);
      expect(target.progress, 100);
      expect(target.overview, isNotEmpty);
      expect(target.structure, isNotEmpty);
      expect(target.points, isNotEmpty);
      expect(target.todos, isNotEmpty);
      expect(target.todoSources, hasLength(1));
      expect(target.sources.single.eventId, 'new-record-42');
      expect(target.sources.single.range, '08:10:00—08:10:15');
      expect(target.markdown, contains('## 逻辑结构'));
      expect(target.markdown, contains('[new-record-42]'));
      expect(prompt, contains('实验温度升至三十度'));
      expect(prompt, isNot(contains('e1')));
      expect(stages, [
        SummaryStage.preparing,
        SummaryStage.generating,
        SummaryStage.validating,
        SummaryStage.completed,
      ]);
    },
  );
  test(
    'different input is passed to gateway, never fixed e1 fallback',
    () async {
      final service = AnalysisService(
        gateway: CallbackAnalysisGateway((p, {model}) async {
          expect(p, contains('火星气象观测'));
          return jsonEncode(summaryData(id: 'mars', title: '火星观测结果'));
        }),
      );
      final target = await service.generateSummary([
        event(id: 'mars', text: '火星气象观测'),
      ], target: card());
      expect(target.title, '火星观测结果');
      expect(target.srcIds, ['mars']);
    },
  );
  test(
    'unselected record source is rejected and failure is persisted',
    () async {
      final target = card();
      final service = AnalysisService(
        gateway: CallbackAnalysisGateway(
          (p, {model}) async => jsonEncode(summaryData(id: 'unselected')),
        ),
      );
      await expectLater(
        service.generateSummary([event()], target: target),
        throwsA(analysisCode('source_invalid')),
      );
      expect(target.state, SummaryState.failed);
      expect(target.errorCode, 'source_invalid');
      expect(target.title, isNull);
      expect(SummaryCard.fromJson(target.toJson()).state, SummaryState.failed);
    },
  );
  test('out of bounds row cannot be cited', () async {
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => jsonEncode(summaryData(rawIndex: 12)),
      ),
    );
    await expectLater(
      service.generateSummary([event()], target: card()),
      throwsA(analysisCode('source_invalid')),
    );
  });
  test('model cannot generate free-form source time', () async {
    final data = summaryData();
    ((data['overview'] as Map)['sources'] as List).first['range'] =
        '18:00—19:00';
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway((p, {model}) async => jsonEncode(data)),
    );
    await expectLater(
      service.generateSummary([event()], target: card()),
      throwsA(analysisCode('source_invalid')),
    );
  });
  test('partial selection excludes unselected text and references', () async {
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway((p, {model}) async {
        expect(p, isNot(contains('下周复测')));
        expect(p, isNot(contains('不应泄露')));
        return jsonEncode(summaryData());
      }),
    );
    final result = await service.generateSummary(
      [event()],
      target: card(),
      selectedRawIndices: {
        'new-record-42': [0],
      },
    );
    expect(result.subDesc, contains('1个原始片段'));
    expect(
      () => SourceCatalog(
        [event()],
        selectedRawIndices: {
          'new-record-42': [0],
        },
      ).resolve({'sourceId': 'new-record-42', 'rawIndex': 1}),
      throwsA(analysisCode('source_invalid')),
    );
  });
  test('empty/duplicate selection rejects before network', () async {
    var calls = 0;
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway((p, {model}) async {
        calls++;
        return '{}';
      }),
    );
    await expectLater(
      service.generateSummary([], target: card()),
      throwsA(analysisCode('selection_invalid')),
    );
    await expectLater(
      service.generateSummary([event(), event()], target: card('second')),
      throwsA(analysisCode('selection_invalid')),
    );
    expect(calls, 0);
  });
  test('missing transcript and invalid raw time do not call network', () async {
    expect(
      () => SourceCatalog([event(raw: [])]),
      throwsA(analysisCode('transcript_missing')),
    );
    expect(
      () => SourceCatalog([
        event(raw: [const TurnLine('未知', 'x', '来源 07:00—07:01')]),
      ]),
      throwsA(analysisCode('source_invalid')),
    );
  });
  test('clock rollover preserves original source bounds', () {
    final e = RecordEvent(
      id: 'night',
      dayOffset: 0,
      title: '夜间',
      brief: '',
      longText: '',
      time: '23:59',
      dur: '2分',
      speakers: '未知',
      mark: '',
      srcMap: '来源 23:59:30—00:01:30',
      dialog: const [],
      raw: const [TurnLine('未知', '新的一天', '来源 00:00:00—00:00:15')],
    );
    expect(
      SourceCatalog([e]).resolve({'sourceId': 'night', 'rawIndex': 0}).range,
      '00:00:00—00:00:15',
    );
  });
  test('malformed schema is failure not success and queue recovers', () async {
    var count = 0;
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async =>
            ++count == 1 ? 'NOT JSON' : jsonEncode(summaryData()),
      ),
    );
    await expectLater(
      service.generateSummary([event()], target: card()),
      throwsA(analysisCode('schema_invalid')),
    );
    expect(
      (await service.generateSummary([event()], target: card('retry'))).state,
      SummaryState.done,
    );
  });
  test(
    'valid fenced JSON accepted; text chatter and missing todos rejected',
    () async {
      expect(parseStructuredResponse('```json\n{"x":1}\n```'), {'x': 1});
      expect(
        () => parseStructuredResponse('preface {"x":1}'),
        throwsA(analysisCode('schema_invalid')),
      );
      final data = summaryData()..remove('todos');
      final service = AnalysisService(
        gateway: CallbackAnalysisGateway(
          (p, {model}) async => jsonEncode(data),
        ),
      );
      await expectLater(
        service.generateSummary([event()], target: card()),
        throwsA(analysisCode('schema_invalid')),
      );
    },
  );
  test('real network adapter error is readable retryable failure', () async {
    final target = card();
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => throw StateError('private upstream detail'),
      ),
    );
    await expectLater(
      service.generateSummary([event()], target: target),
      throwsA(analysisCode('model_request_failed')),
    );
    expect(target.retryable, isTrue);
    expect(target.errorMessage, isNot(contains('private')));
  });
  test('cancellation after model response cannot succeed', () async {
    final gate = Completer<String>();
    final token = CancellationToken();
    final target = card();
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway((p, {model}) => gate.future),
    );
    final pending = service.generateSummary(
      [event()],
      target: target,
      cancellation: token,
    );
    final assertion = expectLater(pending, throwsA(isA<OperationCancelled>()));
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    gate.complete(jsonEncode(summaryData()));
    await assertion;
    expect(target.state, SummaryState.cancelled);
    expect(target.markdown, isNull);
  });
  test(
    'cleaning keeps raw immutable, all mapping, uncertain speakers and phases',
    () async {
      final e = event();
      final service = AnalysisService(
        gateway: CallbackAnalysisGateway(
          (p, {model}) async => jsonEncode({
            'turns': [
              {
                'rawIndex': 0,
                'text': '温度升到30度。',
                'speaker': 'A',
                'confidence': 0.8,
              },
              {
                'rawIndex': 1,
                'text': '复测日期未定。',
                'speaker': 'B',
                'confidence': 0.3,
              },
            ],
            'phases': [
              {
                'label': '实验后续',
                'rawIndices': [0, 1],
                'rationale': '时间相邻',
              },
            ],
            'uncertainties': ['角色推测不可靠'],
          }),
        ),
      );
      final cleaned = await service.cleanTranscript(e);
      expect(identical(cleaned.event.raw, e.raw), isTrue);
      expect(cleaned.event.raw.first.text, '实验温度升至三十度');
      expect(cleaned.event.dialog.first.spk, 'A（推测）');
      expect(cleaned.event.dialog[1].spk, '未知');
      expect(cleaned.mappings[1].rawIndex, 1);
      expect(cleaned.phases.single.rawIndices, [0, 1]);
      expect(cleaned.toJson()['uncertainties'], isNotEmpty);
    },
  );
  test('cleaning rejects reordered/removed original mapping', () async {
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => jsonEncode({
          'turns': [
            {'rawIndex': 1, 'text': 'x', 'speaker': 'unknown', 'confidence': 0},
            {'rawIndex': 0, 'text': 'y', 'speaker': 'unknown', 'confidence': 0},
          ],
          'phases': [],
          'uncertainties': [],
        }),
      ),
    );
    await expectLater(
      service.cleanTranscript(event()),
      throwsA(analysisCode('mapping_invalid')),
    );
  });
  test('existing summary cannot import unselected original sources', () async {
    final prior = card('prior')
      ..state = SummaryState.done
      ..srcIds = ['other'];
    final service = AnalysisService(
      gateway: CallbackAnalysisGateway(
        (p, {model}) async => throw StateError('must not call'),
      ),
    );
    await expectLater(
      service.generateSummary(
        [event()],
        target: card(),
        existingSummaries: [prior],
      ),
      throwsA(analysisCode('source_invalid')),
    );
  });
  test('summary legacy constructor and completed JSON remain compatible', () {
    final c = SummaryCard.fromJson({
      'id': 'old',
      'time': '09:00',
      'srcIds': ['old-e'],
      'title': '旧卡',
      'todos': [],
    });
    expect(c.state, SummaryState.done);
    expect(c.stage, SummaryStage.completed);
    expect(SummaryCard.fromJson(card().toJson()).state, SummaryState.pending);
  });
}
