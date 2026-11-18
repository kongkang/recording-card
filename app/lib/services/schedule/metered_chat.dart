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
  MeteredChatCompletion(this.inner);

  final ChatCompletion inner;
  int _calls = 0;
  int _inputChars = 0;
  int _outputChars = 0;

  ChatMeterSnapshot snapshot() => ChatMeterSnapshot(
    calls: _calls,
    inputChars: _inputChars,
    outputChars: _outputChars,
  );

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    _calls += 1;
    _inputChars += messages.fold<int>(
      0,
      (sum, message) => sum + message.content.length,
    );
    final output = await inner.complete(
      messages,
      model: model,
      temperature: temperature,
      maxTokens: maxTokens,
    );
    _outputChars += output.length;
    return output;
  }
}
