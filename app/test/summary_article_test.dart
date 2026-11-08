// 手动总结文章服务验收（TDD）—— 全量来源入参、JSON（可带 fence）解析、
// sourceIds 白名单过滤、非 JSON / 空 sections / 缺失字段抛 AnalysisException。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/services/analysis/summary_article.dart';
import 'package:recording_card/services/model_gateway/model_gateway_client.dart';

const _sources = [
  SummaryArticleSource(
    recordingId: 'r1',
    title: '项目排期',
    cleanText: '周五前给出书面结论。',
  ),
  SummaryArticleSource(
    recordingId: 'r2',
    title: '客户沟通',
    cleanText: '客户希望延后一周交付。',
  ),
];

ModelGatewayClient _gateway(
  String content, {
  void Function(http.Request request)? onRequest,
}) => ModelGatewayClient(
  modelsUri: Uri.parse('https://api.example.com/v1/models'),
  chatCompletionsUri: Uri.parse('https://api.example.com/v1/chat/completions'),
  headers: () async => {'authorization': 'Bearer test'},
  client: MockClient((request) async {
    onRequest?.call(request);
    return http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'choices': [
            {
              'message': {'content': content},
            },
          ],
        }),
      ),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }),
);

String _articleJson({
  Object? title = '交付节奏与排期结论',
  Object? overview = '两次沟通都涉及交付时间与排期。',
  Object? sections = const [
    {'heading': '排期', 'body': '先做一版可验证的小方案。'},
    {'heading': '客户', 'body': '客户希望延后一周交付。'},
  ],
  Object? actionItems = const ['周五前给出书面结论'],
  Object? sourceIds = const ['r1', 'r2'],
}) => jsonEncode({
  'title': ?title,
  'overview': ?overview,
  'sections': ?sections,
  'actionItems': ?actionItems,
  'sourceIds': ?sourceIds,
});

void main() {
  test('请求包含全部来源，并要求 sourceIds 只能来自输入', () async {
    http.Request? captured;
    final service = CloudSummaryArticleService(
      gateway: _gateway(_articleJson(), onRequest: (r) => captured = r),
      model: 'text-1',
    );

    await service.generate(_sources);

    expect(captured, isNotNull);
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['model'], 'text-1');
    final messages = body['messages'] as List;
    final system =
        messages.firstWhere((m) => (m as Map)['role'] == 'system')['content']
            as String;
    final user =
        messages.firstWhere((m) => (m as Map)['role'] == 'user')['content']
            as String;

    expect(system, contains('JSON'));
    expect(system, contains('sourceIds'));

    final payload = jsonDecode(user) as Map<String, dynamic>;
    final sent = payload['sources'] as List;
    expect(sent, hasLength(2));
    expect(sent.map((s) => (s as Map)['recordingId']), ['r1', 'r2']);
    expect(sent.map((s) => (s as Map)['title']), ['项目排期', '客户沟通']);
    expect(sent.map((s) => (s as Map)['cleanText']), [
      '周五前给出书面结论。',
      '客户希望延后一周交付。',
    ]);
  });

  test('解析合法 JSON（Markdown fence 包裹）', () async {
    final service = CloudSummaryArticleService(
      gateway: _gateway('```json\n${_articleJson()}\n```'),
      model: 'text-1',
    );

    final article = await service.generate(_sources);

    expect(article.title, '交付节奏与排期结论');
    expect(article.overview, '两次沟通都涉及交付时间与排期。');
    expect(article.sections, hasLength(2));
    expect(article.sections.first.heading, '排期');
    expect(article.sections.first.body, '先做一版可验证的小方案。');
    expect(article.actionItems, ['周五前给出书面结论']);
    expect(article.sourceIds, ['r1', 'r2']);
  });

  test('sourceIds 过滤为输入集合：未知 id 剔除、重复去重、保持顺序', () async {
    final service = CloudSummaryArticleService(
      gateway: _gateway(
        _articleJson(sourceIds: const ['r2', 'ghost', 'r1', 'r2', 'r3']),
      ),
      model: 'text-1',
    );

    final article = await service.generate(_sources);

    expect(article.sourceIds, ['r2', 'r1']);
  });

  test('sourceIds 全部未知时返回空集合，不伪造', () async {
    final service = CloudSummaryArticleService(
      gateway: _gateway(_articleJson(sourceIds: const ['ghost'])),
      model: 'text-1',
    );

    final article = await service.generate(_sources);

    expect(article.sourceIds, isEmpty);
  });

  test('非 JSON 输出抛 AnalysisException', () async {
    final service = CloudSummaryArticleService(
      gateway: _gateway('抱歉，我无法总结这些录音。'),
      model: 'text-1',
    );

    await expectLater(
      service.generate(_sources),
      throwsA(isA<AnalysisException>()),
    );
  });

  test('空 sections 抛 AnalysisException', () async {
    final service = CloudSummaryArticleService(
      gateway: _gateway(_articleJson(sections: const [])),
      model: 'text-1',
    );

    await expectLater(
      service.generate(_sources),
      throwsA(isA<AnalysisException>()),
    );
  });

  test('sections 项缺少 heading/body 抛 AnalysisException', () async {
    final service = CloudSummaryArticleService(
      gateway: _gateway(
        _articleJson(
          sections: const [
            {'heading': '只有标题'},
          ],
        ),
      ),
      model: 'text-1',
    );

    await expectLater(
      service.generate(_sources),
      throwsA(isA<AnalysisException>()),
    );
  });

  test('缺失 sourceIds 抛 AnalysisException，不伪造', () async {
    final service = CloudSummaryArticleService(
      gateway: _gateway(_articleJson(sourceIds: null)),
      model: 'text-1',
    );

    await expectLater(
      service.generate(_sources),
      throwsA(isA<AnalysisException>()),
    );
  });

  test('没有来源时不请求模型，直接抛 AnalysisException', () async {
    var requested = false;
    final service = CloudSummaryArticleService(
      gateway: _gateway(_articleJson(), onRequest: (_) => requested = true),
      model: 'text-1',
    );

    await expectLater(
      service.generate(const []),
      throwsA(isA<AnalysisException>()),
    );
    expect(requested, isFalse);
  });
}
