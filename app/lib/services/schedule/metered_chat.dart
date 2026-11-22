/// 给已有 [ChatCompletion] 计数。调度器用调用前后的差值记这一次任务的模型调用，
/// 不改各清洗服务自己的请求内容。
library;

import '../analysis/chat_completion.dart';

class ChatMeterSnapshot {
  const ChatMeterSnapshot({
    required this.calls,
    required this.inputChars,
    required this.outputChars,
  });

  final int calls;
  final int inputChars;
  final int outputChars;

  ChatMeterSnapshot difference(ChatMeterSnapshot before) => ChatMeterSnapshot(
    calls: calls - before.calls,
    inputChars: inputChars - before.inputChars,
    outputChars: outputChars - before.outputChars,
  );
}

class MeteredChatCompletion implements ChatCompletion {
  MeteredChatCompletion(this.inner) : _counter = _ChatMeterCounter();

  MeteredChatCompletion._(this.inner, this._counter);

  /// Trace multiple scene-specific routes in the same recording cleanup run.
  MeteredChatCompletion withInner(ChatCompletion inner) =>
      MeteredChatCompletion._(inner, _counter);

  final ChatCompletion inner;
  final _ChatMeterCounter _counter;

  ChatMeterSnapshot snapshot() => ChatMeterSnapshot(
    calls: _counter.calls,
    inputChars: _counter.inputChars,
    outputChars: _counter.outputChars,
  );

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    _counter.calls += 1;
    _counter.inputChars += messages.fold<int>(
      0,
      (sum, message) => sum + message.content.length,
    );
    final output = await inner.complete(
      messages,
      model: model,
      temperature: temperature,
      maxTokens: maxTokens,
    );
    _counter.outputChars += output.length;
    return output;
  }
}

class _ChatMeterCounter {
  int calls = 0;
  int inputChars = 0;
  int outputChars = 0;
}
