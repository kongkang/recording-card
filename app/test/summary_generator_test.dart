// 总结生成解析契约 —— 走真实的 SummaryGenerator（HTTP 层用 MockClient 顶掉），
// 验证模型输出的四种真实形态：正常 JSON / ```json 代码块 / 坏 JSON / 幻觉 sourceId。
//
// 这里的断言对着「用户能看到的结果」而不是实现细节：
// 结构化字段被正确填进去、幻觉来源不会变成一条假的溯源链接、
// 解析不出来时给可读的中文原因而不是编造内容。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/config/remote/model_gateway_config.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/services/ai/summary_generator.dart';
import 'package:recording_card/services/net/api_exception.dart';

import 'support/model_stub.dart';

void main() {
  test('正常 JSON：标题/概览/结构/信息点/行动项/ Markdown 全部落到草稿里', () async {
    final model = SummaryModel();
    final generator = await model.generator();

    final draft = await generator.generate(seedEvents.take(3).toList());

    expect(draft.title, '项目排期与客户反馈');
    expect(draft.overview, contains('本周五条记录'));
    expect(draft.structure.length, 3);
    expect(draft.structure.first.name, '排期与分工');
    expect(draft.structure.first.leaves, contains('周五前书面结论'));
    expect(draft.points.length, 4);
    expect(draft.points.first.title, '排期偏紧，先移除低优先级功能');
    expect(draft.todos, ['发出分工文档', '跟进客户加载速度问题', '准备周五书面结论']);
    // 「全部」视图展示的是结构化内容，Markdown 只是导出用的原文
    expect(draft.markdown, contains('# 项目排期与客户反馈'));
    expect(draft.markdown, contains('## 概览'));
  });

  test('溯源链接来自真实记录：标签用记录标题，范围用时间·时长', () async {
    final model = SummaryModel();
    final generator = await model.generator();
    final draft = await generator.generate(seedEvents.take(3).toList());

    final ref = draft.points.first.sources.single;
    expect(ref.eventId, 'e1');
    expect(ref.label, '午后项目方向讨论');
    expect(ref.range, '14:20 · 18分40秒');
  });

  test('真实请求：带上配置的模型名、system+user 两条消息、Bearer 鉴权', () async {
    final model = SummaryModel();
    final generator = await model.generator();
    await generator.generate(seedEvents.take(2).toList());

    final request = model.requests.single;
    expect(request.url.path, '/api/model-gateway/v1/chat/completions');
    expect(request.headers['Authorization'], 'Bearer test-access-token');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['model'], 'refine-test');
    expect(body['stream'], isFalse);
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages.first['role'], 'system');
    expect(messages.last['role'], 'user');
    // 用户消息里必须带记录 id 与转写原文，模型才能给出可溯源的 sources
    expect(messages.last['content'], contains('[e1]'));
    expect(messages.last['content'], contains('午后项目方向讨论'));
  });

  test('```json 代码块 + 前后废话仍能解析出来', () async {
    final model = SummaryModel(content: fencedSummaryJson());
    final generator = await model.generator();

    final draft = await generator.generate(seedEvents.take(3).toList());
    expect(draft.title, '项目排期与客户反馈');
    expect(draft.points.length, 4);
  });

  test('坏 JSON（括号不配对）→ 抛可读错误，不产出半截内容', () async {
    final model = SummaryModel(content: kMalformedJson);
    final generator = await model.generator();

    await expectLater(
      generator.generate(seedEvents.take(2).toList()),
      throwsA(
        isA<SummaryGenerationException>().having(
          (e) => e.message,
          'message',
          '总结结果解析失败，请重试',
        ),
      ),
    );
  });

  test('完全不含 JSON → 抛「格式异常」，不假装成功', () async {
    final model = SummaryModel(content: kNotJson);
    final generator = await model.generator();

    await expectLater(
      generator.generate(seedEvents.take(2).toList()),
      throwsA(
        isA<SummaryGenerationException>().having(
          (e) => e.message,
          'message',
          '总结结果格式异常，请重试',
        ),
      ),
    );
  });

  test('幻觉 sourceId 被丢弃：不存在的记录不会变成溯源链接', () async {
    final model = SummaryModel(content: kHallucinatedJson);
    final generator = await model.generator();

    final draft = await generator.generate(seedEvents.take(3).toList());
    expect(draft.points.length, 2);
    // 前面那个信息点的两个来源 id 都不存在 → 溯源列表为空（但信息点本身保留）
    expect(draft.points.first.title, '编出来的信息点');
    expect(draft.points.first.sources, isEmpty);
    // 真实 id 保留
    expect(draft.points.last.sources.single.eventId, 'e1');
  });

  test('网关报错（HTTP 503）→ 抛带服务端原因的异常，不产出任何内容', () async {
    final model = SummaryModel(statusCode: 503);
    final generator = await model.generator();

    await expectLater(
      generator.generate(seedEvents.take(2).toList()),
      throwsA(
        isA<ApiHttpException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.message, 'message', contains('模型暂时不可用'))
            .having((e) => e.isRetryable, 'isRetryable', isTrue),
      ),
    );
  });

  group('前置条件（不满足就不发请求）', () {
    test('没有可用记录 → 「没有可总结的记录」', () async {
      final model = SummaryModel();
      final generator = await model.generator();
      await expectLater(
        generator.generate(const []),
        throwsA(
          isA<SummaryGenerationException>().having(
            (e) => e.message,
            'message',
            '没有可总结的记录',
          ),
        ),
      );
      expect(model.requests, isEmpty);
    });

    test('未配置总结模型 → 「未配置总结服务，暂时无法生成」', () async {
      expect(
        (await SummaryModel().generator()).ready,
        isTrue,
        reason: '正常路径要求配置 + 登录态都在',
      );

      final unconfigured = await buildModelGateway(
        MockClient((_) async => http.Response('{}', 500)),
        // refineModel 为空 = 能力不可用（等价于没传 --dart-define=RC_MODEL_REFINE）
        config: const ModelGatewayConfig(
          baseUrl: kStubApiBase,
          asrModel: 'asr-test',
          refineModel: '',
        ),
      );
      final generator = SummaryGenerator(gateway: unconfigured);
      expect(generator.configured, isFalse);
      await expectLater(
        generator.generate(seedEvents.take(1).toList()),
        throwsA(
          isA<SummaryGenerationException>().having(
            (e) => e.message,
            'message',
            '未配置总结服务，暂时无法生成',
          ),
        ),
      );
    });
  });
}
