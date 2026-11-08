import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/analysis/incremental_refine.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';

class _FakeChat implements ChatCompletion {
  final List<String> userMessages = [];
  String Function(String userJson, int call)? respond;
  Object? error;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    final user = messages.last.content;
    userMessages.add(user);
    final e = error;
    if (e != null) throw e;
    return respond!(user, userMessages.length);
  }
}

String _cleanPayload(String userJson, int call) {
  final slices = jsonDecode(userJson) as List;
  return jsonEncode([
    for (final s in slices)
      {
        'id': s['id'],
        'turns': [
          for (final t in (s['turns'] as List))
            {
              'src': [t['id']],
              'startMs': t['startMs'],
              'endMs': t['endMs'],
              'speaker': t['speaker'],
              'text': (s['id'] == '0002' && call >= 4)
                  ? '修订：${t['text']}'
                  : '清洗：${t['text']}',
            },
        ],
        'boundary': s['id'] == '0002' && call >= 4 ? 'topic' : 'none',
      },
  ]);
}

String _sid(int i) => '${i + 1}'.padLeft(4, '0');

RecordingFile _file() {
  final base = DateTime.now().millisecondsSinceEpoch;
  return RecordingFile(
    deviceName: 'A.APM',
    session: 'S',
    seq: 1,
    startAtMs: base,
    apmPath: '/tmp/a.apm',
    createdAtMs: base,
    slices: [
      for (var i = 0; i < 4; i++)
        AudioSlice(
          id: _sid(i),
          index: i,
          startMs: i * 60000,
          endMs: (i + 1) * 60000,
          wavPath: '/tmp/$i.wav',
        ),
    ],
    utterances: [
      for (var i = 0; i < 4; i++)
        RawUtterance(
          id: '${_sid(i)}u0',
          sliceId: _sid(i),
          startMs: i * 60000 + 1000,
          endMs: i * 60000 + 4000,
          text: '原始${i + 1}',
          speakerLabel: i.isEven ? '说话人 1' : '说话人 2',
        ),
    ],
  );
}

void main() {
  test('窗口按 A / A+B / A+B+C / B+C+D 推进，结果落盘', () async {
    final chat = _FakeChat()..respond = _cleanPayload;
    final service = SlicePolishService(chat: chat, model: 'test-model');
    final file = _file();

    final result = await service.polish(file, save: () async {});

    expect(result.applied, isTrue);
    expect(result.stale, isFalse);
    expect(result.polishedThroughSlice, 3);
    expect(file.turns.length, 4);
    expect(file.turns.first.text, '清洗：原始1');

    final windows = [
      for (final m in chat.userMessages)
        [
          for (final s in jsonDecode(m) as List) s['id'],
        ],
    ];
    expect(windows, [
      ['0001'],
      ['0001', '0002'],
      ['0001', '0002', '0003'],
      ['0002', '0003', '0004'],
    ]);
  });

  test('窗口内允许修订：第 4 次窗口把 0002 改掉，0001 冻结', () async {
    final chat = _FakeChat()..respond = _cleanPayload;
    final service = SlicePolishService(chat: chat, model: 'test-model');
    final file = _file();

    await service.polish(file, save: () async {});

    final bySrc = {
      for (final t in file.turns) t.srcUtteranceIds.first: t,
    };
    expect(bySrc['0001u0']!.text, '清洗：原始1');
    expect(bySrc['0002u0']!.text, '修订：原始2');
    expect(bySrc['0003u0']!.text, '清洗：原始3');
  });

  test('云端失败：保留原文 turn、标记 stale，不丢内容', () async {
    final chat = _FakeChat()..error = const AnalysisException('网络失败');
    final service = SlicePolishService(chat: chat, model: 'test-model');
    final file = _file();

    final result = await service.polish(file, save: () async {});

    expect(result.applied, isTrue);
    expect(result.stale, isTrue);
    expect(file.polishStale, isTrue);
    expect(file.turns.length, 4);
    expect(file.turns.first.text, '原始1');
    expect(file.turns.first.speakerLabel, '说话人 1');
  });

  test('非法输出被丢弃：未知 src / 越界时间 / 注水文本回退原文', () async {
    final chat = _FakeChat()
      ..respond = (userJson, call) {
        final slices = jsonDecode(userJson) as List;
        final s = slices.last as Map;
        // 前三个窗口故意返回空数组（模拟模型漏项）→ 协调器回退原文；
        // 只有最后一个切片所在窗口返回一条有效 turn。
        if (s['id'] != '0004') return '[]';
        return jsonEncode([
          {
            'id': s['id'],
            'turns': [
              {
                'src': ['不存在的id'],
                'startMs': 0,
                'endMs': 1000,
                'speaker': '说话人 9',
                'text': '幻觉',
              },
              {
                'src': [((s['turns'] as List).first as Map)['id']],
                'startMs': 0,
                'endMs': 1000,
                'speaker': '说话人 9',
                'text': '有效文本',
              },
            ],
            'boundary': 'none',
          },
        ]);
      };
    final service = SlicePolishService(chat: chat, model: 'test-model');
    final file = _file();

    await service.polish(file, save: () async {});

    final turns = file.turns.where((t) => t.text == '有效文本').toList();
    expect(turns.length, 1);
    // 未知说话人回退到原始说话人（最后一片是说话人 2）
    expect(turns.single.speakerLabel, '说话人 2');
    expect(file.turns.any((t) => t.text == '幻觉'), isFalse);
  });

  test('未配置模型：不调用云端，返回 applied=false', () async {
    final chat = _FakeChat();
    final service = SlicePolishService(chat: chat, model: '');
    final file = _file();

    final result = await service.polish(file, save: () async {});

    expect(result.applied, isFalse);
    expect(chat.userMessages, isEmpty);
    expect(file.turns, isEmpty);
  });

  test('CloudSliceRefiner 解析 topic 边界', () async {
    final chat = _FakeChat()
      ..respond = (userJson, call) {
        final slices = jsonDecode(userJson) as List;
        final s = slices.first as Map;
        return jsonEncode([
          {
            'id': s['id'],
            'turns': [
              {
                'src': [((s['turns'] as List).first as Map)['id']],
                'startMs': 1000,
                'endMs': 4000,
                'speaker': '说话人 1',
                'text': '清洗后',
              },
            ],
            'boundary': 'topic',
          },
        ]);
      };
    final refiner = CloudSliceRefiner(chat: chat, model: 'test-model');
    final result = await refiner.refine([
      const RefineSegmentInput(
        id: '0001',
        startMs: 0,
        endMs: 60000,
        rawText: '原始',
        turns: [
          RefineTurnInput(
            id: '0001u0',
            startMs: 1000,
            endMs: 4000,
            text: '原始',
            speaker: '说话人 1',
          ),
        ],
      ),
    ]);
    expect(result.single.topicBoundary, isTrue);
    expect(result.single.turns.single.sourceTurnIds, ['0001u0']);
  });
}
