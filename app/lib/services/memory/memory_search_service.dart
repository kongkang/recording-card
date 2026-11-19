/// 本机检索，以及把命中片段交给云端模型生成回答。
///
/// 检索始终在手机上完成。没有命中时不调用模型，也不编造内容。
library;

import 'local_memory_index.dart';
import 'memory_chunk.dart';
import 'memory_indexer.dart';
import 'memory_query.dart';

class MemoryChatTurn {
  const MemoryChatTurn({required this.role, required this.content});

  final String role;
  final String content;
}

typedef MemoryChat = Future<String> Function(List<MemoryChatTurn> turns);

class MemoryAnswer {
  const MemoryAnswer({
    required this.hits,
    required this.text,
    required this.fromModel,
  });

  final List<MemoryHit> hits;
  final String text;
  final bool fromModel;
}

class MemorySearchService {
  MemorySearchService({
    required LocalMemoryIndex index,
    required MemoryCorpus Function() corpus,
    MemoryChat? chat,
  }) : _index = index,
       _corpus = corpus,
       _chat = chat;

  final LocalMemoryIndex _index;
  final MemoryCorpus Function() _corpus;
  final MemoryChat? _chat;

  Future<void> reindex([MemoryCorpus? corpus]) {
    return _index.replaceAll(buildMemoryChunks(corpus ?? _corpus()));
  }

  Future<List<MemoryHit>> search(String query, {int limit = 8}) async {
    final parsed = parseMemoryQuery(query);
    final window = parsed.window;
    if (parsed.text.isEmpty && window == null) return const [];
    return _searchIndexed(parsed, limit: limit);
  }

  Future<MemoryAnswer> ask(String query) async {
    final parsed = parseMemoryQuery(query.trim());
    if (parsed.text.isEmpty && parsed.window == null) {
      return const MemoryAnswer(hits: [], text: '请输入要查找的内容。', fromModel: false);
    }
    await reindex();
    final hits = await _searchIndexed(parsed);
    if (hits.isEmpty) {
      return const MemoryAnswer(
        hits: [],
        text: '本机没有找到相关记录。',
        fromModel: false,
      );
    }
    final chat = _chat;
    if (chat == null) {
      return MemoryAnswer(
        hits: hits,
        text: '已在本机找到 ${hits.length} 条相关记录。当前未连接云端模型，下面是原文片段。',
        fromModel: false,
      );
    }
    try {
      final text = (await chat(
        buildMemoryAnswerMessages(query.trim(), hits),
      )).trim();
      if (text.isEmpty) {
        return MemoryAnswer(
          hits: hits,
          text: '云端回答失败：模型没有返回内容。',
          fromModel: false,
        );
      }
      return MemoryAnswer(hits: hits, text: text, fromModel: true);
    } catch (error) {
      final message = '$error'.replaceFirst(RegExp(r'^Exception:\s*'), '');
      return MemoryAnswer(
        hits: hits,
        text: '已在本机找到相关记录，但云端回答失败：$message',
        fromModel: false,
      );
    }
  }

  Future<void> close() => _index.close();

  Future<List<MemoryHit>> _searchIndexed(
    ParsedMemoryQuery parsed, {
    int limit = 8,
  }) async {
    final minDay = parsed.window?.minOffset;
    final maxDay = parsed.window?.maxOffset;
    if (parsed.text.isEmpty) {
      return _index.search(minDay: minDay, maxDay: maxDay, limit: limit);
    }
    final phrase = ftsPhraseExpression(parsed.text);
    if (phrase != null) {
      final exact = await _index.search(
        match: phrase,
        minDay: minDay,
        maxDay: maxDay,
        limit: limit,
      );
      if (exact.isNotEmpty) return exact;
    }
    final relaxed = ftsRelaxedExpression(parsed.text);
    if (relaxed == null) return const [];
    return _index.search(
      match: relaxed,
      minDay: minDay,
      maxDay: maxDay,
      limit: limit,
    );
  }
}

List<MemoryChatTurn> buildMemoryAnswerMessages(
  String query,
  List<MemoryHit> hits,
) {
  final blocks = <String>[
    for (var i = 0; i < hits.length; i++)
      '[${i + 1}] ${hits[i].dayLabel} ${hits[i].timeLabel} · ${hits[i].title}\n${hits[i].body}',
  ];
  return [
    const MemoryChatTurn(
      role: 'system',
      content:
          '你是录音卡的本机记忆助手。只能根据给出的记录片段回答问题。'
          '片段里没有的事实不要编造。用一两句中文回答，并点明来源标题。',
    ),
    MemoryChatTurn(
      role: 'user',
      content: '问题：$query\n\n记录片段：\n${blocks.join('\n\n')}',
    ),
  ];
}
