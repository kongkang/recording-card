// 模型网关配置验收 —— 只接受 https + 显式模型 ID；不在客户端写死默认模型。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/config/model_gateway_config.dart';

void main() {
  test('https + 文本模型才算已配置', () {
    const config = ModelGatewayConfig(
      baseUrl: 'https://api.example.com/api/model-gateway/v1',
      textModel: 'text-1',
      asrModel: 'asr-1',
    );
    expect(config.isConfigured, isTrue);
    expect(config.modelsUri.toString(),
        'https://api.example.com/api/model-gateway/v1/models');
    expect(config.chatCompletionsUri.toString(),
        'https://api.example.com/api/model-gateway/v1/chat/completions');
  });

  test('http / 空模型 / 空 base 均未配置', () {
    expect(
        const ModelGatewayConfig(
          baseUrl: 'http://api.example.com',
          textModel: 't',
          asrModel: '',
        ).isConfigured,
        isFalse);
    expect(
        const ModelGatewayConfig(
          baseUrl: 'https://api.example.com',
          textModel: '',
          asrModel: '',
        ).isConfigured,
        isFalse);
    expect(
        const ModelGatewayConfig(
          baseUrl: '',
          textModel: 't',
          asrModel: '',
        ).isConfigured,
        isFalse);
  });

  test('尾部斜杠归一化', () {
    const config = ModelGatewayConfig(
      baseUrl: 'https://api.example.com/gw///',
      textModel: 't',
      asrModel: '',
    );
    expect(config.modelsUri.toString(), 'https://api.example.com/gw/models');
  });
}
