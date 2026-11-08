/// 增量滑动窗口润色 —— 每来一个新切片，只把最近 N 段（默认 3）送云端，
/// 返回结果按 id 合并；云端输出不可信时回退原文，绝不丢段。
library;

import 'dart:async';
import 'dart:convert';

import 'chat_completion.dart';

class RefineSegmentInput {
  const RefineSegmentInput({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.rawText,
    this.speaker,
    this.emotion,
  });

  final String id;
  final int startMs;
  final int endMs;
  final String rawText;
  final String? speaker;
  final String? emotion;
}

class RefinedSegment {
  const RefinedSegment({
    required this.id,
    required this.cleanText,
    this.speaker,
    this.emotion,
  });

  final String id;
  final String cleanText;
  final String? speaker;
  final String? emotion;
}

abstract class SegmentRefiner {
  Future<List<RefinedSegment>> refine(List<RefineSegmentInput> window);
}

class AnalysisException implements Exception {
  const AnalysisException(this.message);

  final String message;

  @override
  String toString() => 'AnalysisException: $message';
}

class RefineUpdate {
  const RefineUpdate({
    required this.all,
    required this.changed,
    required this.windowStartIndex,
    this.error,
  });

  /// 全部段（按输入顺序），已合并本次窗口结果。
  final List<RefinedSegment> all;

  /// 本次新增或文本/说话人/情绪发生变化的段。
  final List<RefinedSegment> changed;

  /// 本次窗口在全部输入中的起始下标。
  final int windowStartIndex;

  /// 云端失败时的异常；失败时 changed 只含回退原文的新段。
  final Object? error;
}

class IncrementalRefineCoordinator {
  IncrementalRefineCoordinator({
    required this.refiner,
    this.windowSize = 3,
  }) : assert(windowSize > 0, 'windowSize 必须为正');

  final SegmentRefiner refiner;
  final int windowSize;

  final List<RefineSegmentInput> _inputs = [];
  final Map<String, RefinedSegment> _refined = {};
  Future<void> _tail = Future.value();

  List<RefinedSegment> get segments => [
        for (final input in _inputs)
          if (_refined[input.id] != null) _refined[input.id]!
      ];

  List<RefineSegmentInput> get window {
    final start = _inputs.length > windowSize ? _inputs.length - windowSize : 0;
    return List.unmodifiable(_inputs.sublist(start));
  }

  /// 串行执行：并发 add 也按调用顺序推进窗口。
  Future<RefineUpdate> add(RefineSegmentInput input) {
    final result = _tail.then((_) => _run(input));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<RefineUpdate> _run(RefineSegmentInput input) async {
    _inputs.add(input);
    final start = _inputs.length > windowSize ? _inputs.length - windowSize : 0;
    final currentWindow = _inputs.sublist(start);

    List<RefinedSegment> returned = const [];
    Object? error;
    try {
      returned = await refiner.refine(List.unmodifiable(currentWindow));
    } catch (e) {
      error = e;
    }

    final returnedById = <String, RefinedSegment>{};
    final windowIds = {for (final s in currentWindow) s.id};
    for (final segment in returned) {
      if (!windowIds.contains(segment.id)) continue; // 幻觉 ID 忽略
      if (segment.cleanText.trim().isEmpty) continue;
      returnedById[segment.id] = segment;
    }

    final changed = <RefinedSegment>[];
    for (final source in currentWindow) {
      final next = returnedById[source.id];
      final previous = _refined[source.id];
      final resolved = next ??
          previous ??
          RefinedSegment(
            id: source.id,
            cleanText: source.rawText,
            speaker: source.speaker,
            emotion: source.emotion,
          );
      _refined[source.id] = resolved;
      if (previous == null ||
          previous.cleanText != resolved.cleanText ||
          previous.speaker != resolved.speaker ||
          previous.emotion != resolved.emotion) {
        changed.add(resolved);
      }
    }

    return RefineUpdate(
      all: List.unmodifiable(segments),
      changed: List.unmodifiable(changed),
      windowStartIndex: start,
      error: error,
    );
  }
}

/// 云端润色：OpenAI-compatible chat，输入/输出都是 JSON 数组；
/// 只接受回传原 id，缺失由协调器回退原文。
class CloudSegmentRefiner implements SegmentRefiner {
  CloudSegmentRefiner({
    required this.chat,
    required this.model,
    this.temperature = 0.1,
  });

  final ChatCompletion chat;
  final String model;
  final double temperature;

  static const _systemPrompt = '''
你是录音整理助手。输入是 JSON 数组，每项包含 id、startMs、endMs、rawText、speaker、emotion。
请只做口语清洗（去语气词、重复、停顿词，补标点），保留原意与说话人推测。
输出必须是 JSON 数组，每项 {"id": "...", "cleanText": "...", "speaker": "...", "emotion": "..."}。
必须原样保留所有输入 id，不得新增、删除、合并 id；不要输出 Markdown 或解释。''';

  @override
  Future<List<RefinedSegment>> refine(List<RefineSegmentInput> window) async {
    if (window.isEmpty) return const [];
    final content = await chat.complete(
      [
        const ChatMessage(role: 'system', content: _systemPrompt),
        ChatMessage(
          role: 'user',
          content: jsonEncode([
            for (final s in window)
              {
                'id': s.id,
                'startMs': s.startMs,
                'endMs': s.endMs,
                'rawText': s.rawText,
                'speaker': s.speaker,
                'emotion': s.emotion,
              }
          ]),
        ),
      ],
      model: model,
      temperature: temperature,
    );
    return _parse(content);
  }

  List<RefinedSegment> _parse(String content) {
    final start = content.indexOf('[');
    final end = content.lastIndexOf(']');
    if (start < 0 || end <= start) {
      throw const AnalysisException('模型未返回 JSON 数组');
    }
    final decoded = jsonDecode(content.substring(start, end + 1));
    if (decoded is! List) {
      throw const AnalysisException('模型返回不是数组');
    }
    final out = <RefinedSegment>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final id = item['id'];
      final clean = item['cleanText'];
      if (id is! String || id.isEmpty || clean is! String || clean.trim().isEmpty) {
        continue;
      }
      out.add(RefinedSegment(
        id: id,
        cleanText: clean.trim(),
        speaker: item['speaker'] as String?,
        emotion: item['emotion'] as String?,
      ));
    }
    if (out.isEmpty) {
      throw const AnalysisException('模型返回没有有效分段');
    }
    return out;
  }
}
