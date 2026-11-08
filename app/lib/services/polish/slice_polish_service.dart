/// 增量滑动窗口润色 —— 以「切片」为单位，窗口 = 当前片 + 前 2 片。
///
/// 复用 `IncrementalRefineCoordinator` 的窗口/合并/失败回退逻辑，只把输出从
/// 「一段清洗文本」升级为「turn 列表」：每个 turn 保留绝对时间、说话人和
/// 可回溯的原始句 id，供「对话详情 / 原始数据」两处展示。
///
/// 边界：模型只允许改写窗口内切片；窗口外的 turn 由协调器冻结。云端返回的
/// 未知切片 id / 未知原始句 id / 越界时间 / 空文本都会被丢弃，缺失的切片回退
/// 到本地原文，不会出现"润色走完但内容丢了"。
library;

import 'dart:convert';

import '../../core/models/recording.dart';
import '../analysis/chat_completion.dart';
import '../analysis/incremental_refine.dart';

class PolishResult {
  const PolishResult({
    required this.applied,
    required this.stale,
    required this.polishedThroughSlice,
    this.error,
  });

  final bool applied;

  /// 有窗口失败并回退原文；界面应提示「部分内容未润色」。
  final bool stale;
  final int polishedThroughSlice;
  final Object? error;
}

class SlicePolishService {
  SlicePolishService({
    required ChatCompletion chat,
    required String model,
    this.windowSize = 3,
    this.temperature = 0.2,
    bool Function()? ready,
  }) : _refiner = CloudSliceRefiner(
         chat: chat,
         model: model,
         temperature: temperature,
       ),
       _ready = ready;

  final CloudSliceRefiner _refiner;
  final int windowSize;
  final double temperature;
  final bool Function()? _ready;

  bool get configured =>
      _refiner.model.trim().isNotEmpty && (_ready?.call() ?? true);

  /// 对一条录音做窗口润色；每完成一个窗口就通过 [save] 落盘。
  ///
  /// [save] 由调用方提供（通常是 `store.save(file)`），服务本身不持有存储。
  Future<PolishResult> polish(
    RecordingFile file, {
    required Future<void> Function() save,
  }) async {
    if (!configured) {
      return const PolishResult(applied: false, stale: false, polishedThroughSlice: -1);
    }
    if (file.slices.isEmpty || file.utterances.isEmpty) {
      return const PolishResult(applied: false, stale: false, polishedThroughSlice: -1);
    }

    final coordinator = IncrementalRefineCoordinator(
      refiner: _refiner,
      windowSize: windowSize,
    );
    var stale = false;
    Object? lastError;
    var through = -1;

    for (final slice in file.slices) {
      final turns = file.utterances
          .where((u) => u.sliceId == slice.id)
          .toList()
        ..sort((a, b) => a.startMs.compareTo(b.startMs));
      if (turns.isEmpty) {
        through = slice.index;
        continue;
      }
      final speakers = <String>{
        for (final t in turns)
          if ((t.speakerLabel ?? '').trim().isNotEmpty) t.speakerLabel!,
      };
      final input = RefineSegmentInput(
        id: slice.id,
        startMs: slice.startMs,
        endMs: slice.endMs,
        rawText: turns.map((t) => t.text).join(),
        speaker: speakers.isEmpty ? '未区分' : speakers.join(' / '),
        emotion: turns.first.emotion,
        turns: [
          for (final t in turns)
            RefineTurnInput(
              id: t.id,
              startMs: t.startMs,
              endMs: t.endMs,
              text: t.text,
              speaker: t.speakerLabel ?? '未区分',
              emotion: t.emotion,
            ),
        ],
      );

      final update = await coordinator.add(input);
      if (update.error != null) {
        stale = true;
        lastError = update.error;
      }
      through = slice.index;
      file.polishedThroughSlice = through;
      _apply(file, coordinator.segments, stale: stale);
      await save();
    }

    _apply(file, coordinator.segments, stale: stale);
    file.polishedThroughSlice = through;
    await save();
    return PolishResult(
      applied: true,
      stale: stale,
      polishedThroughSlice: through,
      error: lastError,
    );
  }

  /// 把协调器的 turn 投影到 [RecordingFile]（按时间排序、替换旧 turn）。
  static void _apply(
    RecordingFile file,
    List<RefinedSegment> segments, {
    required bool stale,
  }) {
    final turns = <PolishedTurn>[];
    for (final segment in segments) {
      for (final turn in segment.turns) {
        turns.add(
          PolishedTurn(
            id: turn.id,
            startMs: turn.startMs,
            endMs: turn.endMs,
            speakerLabel: turn.speaker,
            text: turn.text,
            srcUtteranceIds: turn.sourceTurnIds,
          ),
        );
      }
    }
    turns.sort((a, b) => a.startMs.compareTo(b.startMs));
    file
      ..turns = turns
      ..polishStale = stale;
  }
}

/// 切片级云端润色器。
class CloudSliceRefiner implements SegmentRefiner {
  CloudSliceRefiner({
    required this.chat,
    required this.model,
    this.temperature = 0.2,
  });

  final ChatCompletion chat;
  final String model;
  final double temperature;

  static const _systemPrompt = '''
你是录音整理助手。输入是 JSON 数组，每项是一个音频切片：
{"id":"0001","startMs":0,"endMs":60000,"turns":[{"id":"0001u0","startMs":100,"endMs":3000,"text":"...","speaker":"说话人 1","emotion":"NEUTRAL"}]}

请对每个切片做口语清洗：去掉语气词/重复/停顿词，补标点，按语义把相邻 turn 合并或用更自然的书面语改写。
硬性要求：
1. 只依据输入文本，不编造原文没有的事实、身份或数字。
2. 每个输出 turn 必须给 src（引用的输入 turn id 列表），src 只能来自同一个切片的输入。
3. 保留说话人标签（说话人 1/2 或 未区分），不要创造新说话人。
4. 时间 startMs/endMs 用输入 turn 的时间范围，必须落在该切片内且 endMs > startMs。
5. 如果切片末尾出现明显的话题切换，boundary 设为 "topic"，否则 "none"。
6. 只输出 JSON 数组，每项 {"id":"切片id","turns":[{"src":["输入turnId"],"startMs":0,"endMs":1000,"speaker":"说话人 1","text":"..."}],"boundary":"none"}。
不要输出 Markdown、代码块或任何解释。''';

  @override
  Future<List<RefinedSegment>> refine(List<RefineSegmentInput> window) async {
    if (window.isEmpty) return const [];
    final content = await chat.complete(
      [
        const ChatMessage(role: 'system', content: _systemPrompt),
        ChatMessage(role: 'user', content: jsonEncode(_payload(window))),
      ],
      model: model,
      temperature: temperature,
      maxTokens: 3000,
    );
    return _parse(content, window);
  }

  List<Map<String, Object?>> _payload(List<RefineSegmentInput> window) => [
    for (final s in window)
      {
        'id': s.id,
        'startMs': s.startMs,
        'endMs': s.endMs,
        'turns': [
          for (final t in s.turns)
            {
              'id': t.id,
              'startMs': t.startMs,
              'endMs': t.endMs,
              'text': t.text,
              if (t.speaker != null) 'speaker': t.speaker,
              if (t.emotion != null) 'emotion': t.emotion,
            },
        ],
      },
  ];

  List<RefinedSegment> _parse(
    String content,
    List<RefineSegmentInput> window,
  ) {
    final start = content.indexOf('[');
    final end = content.lastIndexOf(']');
    if (start < 0 || end <= start) {
      throw const AnalysisException('模型未返回 JSON 数组');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(content.substring(start, end + 1));
    } on FormatException {
      throw const AnalysisException('润色结果不是合法 JSON');
    }
    if (decoded is! List) {
      throw const AnalysisException('润色结果不是数组');
    }

    final byId = {for (final s in window) s.id: s};
    final out = <RefinedSegment>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final id = item['id'];
      if (id is! String || !byId.containsKey(id)) continue;
      final source = byId[id]!;
      final turns = _parseTurns(item['turns'], source);
      if (turns.isEmpty) continue;
      final speakers = <String>{for (final t in turns) t.speaker};
      out.add(
        RefinedSegment(
          id: id,
          cleanText: turns.map((t) => t.text).join('\n'),
          speaker: speakers.join(' / '),
          emotion: source.emotion,
          turns: turns,
          topicBoundary: '${item['boundary'] ?? ''}'.toLowerCase() == 'topic',
        ),
      );
    }
    if (out.isEmpty) {
      throw const AnalysisException('模型返回没有有效切片');
    }
    return out;
  }

  List<RefinedTurn> _parseTurns(Object? raw, RefineSegmentInput source) {
    if (raw is! List) return const [];
    final sourceById = {for (final t in source.turns) t.id: t};
    final knownSpeakers = <String>{
      for (final t in source.turns)
        if ((t.speaker ?? '').trim().isNotEmpty) t.speaker!,
      '未区分',
    };
    final out = <RefinedTurn>[];
    var index = 0;
    for (final item in raw) {
      if (item is! Map) continue;
      final text = '${item['text'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      final src = <String>[
        for (final s in (item['src'] as List? ?? const []))
          if (sourceById.containsKey('$s')) '$s',
      ];
      if (src.isEmpty) continue;
      var startMs = (item['startMs'] as num?)?.toInt() ??
          sourceById[src.first]!.startMs;
      var endMs = (item['endMs'] as num?)?.toInt() ??
          sourceById[src.last]!.endMs;
      startMs = startMs
          .clamp(source.startMs - 2000, source.endMs + 2000)
          .toInt();
      endMs = endMs
          .clamp(source.startMs - 2000, source.endMs + 2000)
          .toInt();
      if (endMs <= startMs) {
        startMs = sourceById[src.first]!.startMs;
        endMs = sourceById[src.last]!.endMs;
      }
      if (endMs <= startMs) continue;

      final sourceChars = src.fold<int>(
        0,
        (a, id) => a + sourceById[id]!.text.length,
      );
      if (text.length > sourceChars * 3 + 40) continue; // 明显注水/幻觉

      final rawSpeaker = '${item['speaker'] ?? ''}'.trim();
      final fallbackSpeaker = sourceById[src.first]!.speaker ?? '未区分';
      final speaker = knownSpeakers.contains(rawSpeaker) && rawSpeaker.isNotEmpty
          ? rawSpeaker
          : fallbackSpeaker;

      out.add(
        RefinedTurn(
          id: '${source.id}t$index',
          startMs: startMs,
          endMs: endMs,
          speaker: speaker,
          text: text,
          sourceTurnIds: List.unmodifiable(src),
        ),
      );
      index++;
    }
    return out;
  }
}
