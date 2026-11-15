import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';

class _SummaryChat implements ChatCompletion {
  bool fail = false;
  int calls = 0;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    calls++;
    if (fail) throw Exception('注入总结失败');
    return jsonEncode({'title': '事件 $calls', 'overview': '概述 $calls'});
  }
}

RecordingFile _file({List<PolishedTurn>? turns, List<RawUtterance>? raws}) {
  final base = 1730000000000;
  return RecordingFile(
    deviceName: 'A.APM',
    session: 'S',
    seq: 1,
    startAtMs: base,
    apmPath: '/tmp/a.apm',
    createdAtMs: base,
    turns: turns ?? const [],
    utterances: raws ?? const [],
  );
}

PolishedTurn _turn(
  String id,
  int startMs,
  int endMs, {
  String speaker = '说话人 1',
  String text = '内容',
}) => PolishedTurn(
  id: id,
  startMs: startMs,
  endMs: endMs,
  speakerLabel: speaker,
  text: text,
  srcUtteranceIds: ['$id-u'],
);

void main() {
  test('30s 静音切事件：两段，时间/标题/turnIds 正确', () async {
    final chat = _SummaryChat();
    final service = SegmentBuildService(chat: chat, model: 'test-model');
    final file = _file(
      turns: [
        _turn('t0', 0, 1000, text: '第一段开头'),
        _turn('t1', 1000, 2000, text: '第一段结尾'),
        _turn('t2', 32000, 33000, speaker: '说话人 2', text: '第二段'),
      ],
    );

    final result = await service.build(file, save: () async {});

    expect(result.segments.length, 2);
    final first = result.segments.first;
    expect(first.title, '事件 1');
    expect(first.turnIds, ['t0', 't1']);
    expect(first.startAtMs, file.startAtMs);
    expect(first.endAtMs, file.startAtMs + 2000);
    expect(first.status, SegmentStatus.closed);
    expect(first.speakerCount, 1);
    final second = result.segments.last;
    expect(second.turnIds, ['t2']);
    expect(second.speakerLabels, ['说话人 2']);
    expect(result.fallback, isFalse);
  });

  test('<30s 停顿连续超 25 分钟默认不设时长上限，保持为 1 段', () async {
    final chat = _SummaryChat();
    final service = SegmentBuildService(chat: chat, model: 'test-model');
    final turns = [
      // 31 个 turn，每间隔 29s，共跨 ~15 分钟；再加到 60 个，共 ~29 分钟
      for (var i = 0; i < 60; i++)
        _turn('t$i', i * 29000, i * 29000 + 1000, text: '持续讨论 $i'),
    ];
    final file = _file(turns: turns);

    final result = await service.build(file, save: () async {});
    expect(result.segments.length, 1);
    expect(result.segments.single.turnIds.length, 60);
  });

  test('未配置云端：用原文兜底分段，不丢 turn', () async {
    final chat = _SummaryChat();
    final service = SegmentBuildService(chat: chat, model: '');
    final file = _file(
      turns: [
        _turn('t0', 0, 1000, text: '第一段内容'),
        _turn('t1', 31000, 32000, text: '第二段内容'),
      ],
    );

    final result = await service.build(file, save: () async {});
    expect(result.segments.length, 2);
    expect(result.fallback, isTrue);
    expect(result.segments.first.fallback, isTrue);
    expect(result.segments.first.title, contains('第一段'));
    expect(result.segments.first.longText, contains('第一段内容'));
    expect(chat.calls, 0);
  });

  test('云端失败：回退原文事件，仍产出分段', () async {
    final chat = _SummaryChat()..fail = true;
    final service = SegmentBuildService(chat: chat, model: 'test-model');
    final file = _file(turns: [_turn('t0', 0, 1000, text: '内容')]);

    final result = await service.build(file, save: () async {});
    expect(result.segments.length, 1);
    expect(result.fallback, isTrue);
    expect(result.error, isNotNull);
    expect(result.segments.single.turnIds, ['t0']);
  });

  test('显式指定单事件上限时按上限强制切段', () async {
    final chat = _SummaryChat();
    final service = SegmentBuildService(
      chat: chat,
      model: 'test-model',
      maxSegmentMs: 60000,
    );
    final turns = [
      for (var i = 0; i < 10; i++) _turn('t$i', i * 10000, i * 10000 + 1000),
    ];
    final file = _file(turns: turns);

    final result = await service.build(file, save: () async {});
    expect(result.segments.length, 2);
    expect(result.segments.first.turnIds.length, 6);
    expect(result.segments.last.turnIds.length, 4);
  });

  test('处理中可见 live 分段，完成后只剩 closed', () async {
    final chat = _SummaryChat();
    final service = SegmentBuildService(chat: chat, model: 'test-model');
    final file = _file(
      turns: [
        _turn('t0', 0, 1000),
        _turn('t1', 1000, 2000),
        _turn('t2', 40000, 41000),
      ],
    );
    var sawLive = false;
    await service.build(
      file,
      save: () async {
        if (file.segments.any((s) => s.status == SegmentStatus.live)) {
          sawLive = true;
        }
      },
    );
    expect(sawLive, isTrue);
    expect(file.segments, isNotEmpty);
    expect(file.segments.every((s) => s.status == SegmentStatus.closed), isTrue);
  });

  test('没有 turn 时返回空分段', () async {
    final service = SegmentBuildService(chat: _SummaryChat(), model: '');
    final result = await service.build(_file(), save: () async {});
    expect(result.segments, isEmpty);
  });
}
