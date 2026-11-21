/// 分析层的最小文本补全接缝 —— 只依赖消息/模型/温度，不绑定具体网关实现。
/// 生产用 [ModelGatewayChatCompletion] 包住现有 ModelGateway，测试注入 Fake。
library;

import '../net/model_gateway.dart';
import '../net/model_provider_store.dart';

export '../net/model_gateway.dart' show ChatMessage;

abstract class ChatCompletion {
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  });
}

class ModelGatewayChatCompletion implements ChatCompletion {
  ModelGatewayChatCompletion(this._gateway, {this.scene = ModelScene.summary});

  final ModelGateway _gateway;
  final ModelScene scene;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) => _gateway.chat(
    messages,
    model: model,
    scene: scene,
    temperature: temperature,
    maxTokens: maxTokens,
  );
}
