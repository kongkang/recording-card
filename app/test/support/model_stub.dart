/// 测试用的「模型网关」替身：**不伪造 [SummaryGenerator]**，而是用
/// `package:http/testing.dart` 的 MockClient 顶掉最外层 HTTP，
/// 让真实的 `AuthorizedHttpClient → ModelGateway → SummaryGenerator` 全部跑起来。
///
/// 这样做的好处（也是刻意选择）：
/// - 验证的是真实解析/容错路径（代码块围栏、前后废话、坏 JSON、幻觉 sourceId）；
/// - 请求体是真发出去的，可以断言模型名、messages 结构；
/// - 不依赖网络、不依赖平台通道。
///
/// 时间控制：`autoReply: false` 时请求会挂起，测试用 [SummaryModel.release]
/// 决定何时「模型返回」，这样能稳定断言生成中态（进度/已生成秒数/步骤）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/config/remote/model_gateway_config.dart';
import 'package:recording_card/core/storage/secure_store.dart';
import 'package:recording_card/services/ai/summary_generator.dart';
import 'package:recording_card/services/auth/oauth_client.dart';
import 'package:recording_card/services/auth/oauth_config.dart';
import 'package:recording_card/services/auth/oauth_token_store.dart';
import 'package:recording_card/services/net/authorized_http_client.dart';
import 'package:recording_card/services/net/model_gateway.dart';

/// 假后端地址（https，满足 ModelGatewayConfig 的 https 校验）。
const String kStubApiBase = 'https://stub.invalid';

/// 可用的 OAuth 配置（本文件只用到 client id / 端点占位，不发真实请求）。
const OAuthConfig kStubOAuthConfig = OAuthConfig(
  baseUrl: kStubApiBase,
  authUrl: '$kStubApiBase/oauth/authorize',
  tokenUrl: '$kStubApiBase/oauth/token',
  profileUrl: '$kStubApiBase/profile',
  revokeUrl: '$kStubApiBase/oauth/revoke',
  socialProvidersUrl: '$kStubApiBase/auth/social/providers',
  clientId: 'test-client',
  redirectUri: 'recording-card://callback',
  scope: '',
);

/// 模型网关配置（两个模型名都配齐 = 能力可用）。
const ModelGatewayConfig kStubModelConfig = ModelGatewayConfig(
  baseUrl: kStubApiBase,
  asrModel: 'asr-test',
  refineModel: 'refine-test',
);

/// 造一个「已登录」的 token store：直接往内存密钥库写一条未过期的 bundle，
/// 走真实的 [OAuthTokenStore.bootstrap] 恢复，不触发任何网络。
Future<OAuthTokenStore> buildSignedInTokenStore() async {
  final expires = DateTime.now().add(const Duration(hours: 1));
  final refreshExpires = DateTime.now().add(const Duration(days: 30));
  final secure = InMemorySecureStore({
    OAuthTokenStore.bundleKey: jsonEncode({
      'access_token': 'test-access-token',
      'refresh_token': 'test-refresh-token',
      'expires_at': expires.toIso8601String(),
      'refresh_expires_at': refreshExpires.toIso8601String(),
      'token_type': 'Bearer',
    }),
  });
  final store = OAuthTokenStore(
    secure: secure,
    client: OAuthClient(
      config: kStubOAuthConfig,
      httpClient: MockClient((_) async => http.Response('{}', 500)),
    ),
    config: kStubOAuthConfig,
  );
  await store.bootstrap();
  return store;
}

/// 造一个接入 MockClient 的 [ModelGateway]。
Future<ModelGateway> buildModelGateway(
  http.Client client, {
  ModelGatewayConfig config = kStubModelConfig,
}) async {
  final tokens = await buildSignedInTokenStore();
  return ModelGateway(
    client: AuthorizedHttpClient(tokenStore: tokens, httpClient: client),
    config: config,
    defaultTimeout: const Duration(seconds: 5),
  );
}

/// 可预测的模型后端：包住 MockClient + 真实的 [SummaryGenerator]。
///
/// - [content]：模型 `choices[0].message.content` 原文（可以是 JSON、代码块、废话、坏 JSON）
/// - [statusCode]：非 200 时模拟网关报错
/// - [autoReply]：false 时请求挂起，等 [release] 再返回（用来断言生成中态）
class SummaryModel {
  SummaryModel({
    this.content = kSummaryJson,
    this.statusCode = 200,
    this.autoReply = true,
  });

  /// 模型返回的正文（可在 release 前改写，模拟「重试后这次成功了」）。
  String content;
  int statusCode;
  bool autoReply;

  /// 收到的请求（断言真实发链路用：模型名、messages、鉴权头）。
  final List<http.Request> requests = <http.Request>[];

  final Completer<void> _gate = Completer<void>();

  bool get released => _gate.isCompleted;

  /// 放行挂起的请求（autoReply: false 时用）。
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  late final Future<SummaryGenerator> _generator = _build();

  /// 真实 [SummaryGenerator]（同一个实例复用，保证多次调用共享这个假后端）。
  Future<SummaryGenerator> generator() => _generator;

  /// 直接拿 AppStore 注入用：`AppStore(generator: await model.summaryGenerator())`。
  Future<SummaryGenerator> summaryGenerator() => _generator;

  Future<SummaryGenerator> _build() async {
    final client = MockClient((request) async {
      requests.add(request);
      if (!autoReply) await _gate.future;
      if (statusCode != 200) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'error': {'code': 'stub_error', 'message': '模型暂时不可用'},
            }),
          ),
          statusCode,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': content},
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final gateway = await buildModelGateway(client);
    return SummaryGenerator(gateway: gateway);
  }
}

/// 正常总结 JSON：标题沿用原型断言「项目排期与客户反馈」，4 个信息点
/// （对应 UI 的 pt-0…pt-3），来源全部指向真实记录 id。
const String kSummaryJson = '''
{
  "title": "项目排期与客户反馈",
  "overview": "本次总结覆盖本周五条记录，围绕项目排期、客户反馈与待办备忘梳理出核心结论。",
  "structure": [
    {"name": "排期与分工", "leaves": ["移除低优先级功能", "先做可验证小方案", "周五前书面结论"]},
    {"name": "客户反馈", "leaves": ["界面清爽获认可", "列表加载偏慢", "筛选记住上次选择"]},
    {"name": "待定决策", "leaves": ["小方案是否包含导出功能"]}
  ],
  "points": [
    {"title": "排期偏紧，先移除低优先级功能", "detail": "讨论中对比了测试阶段排期与资源投入，决定缩小首版范围。", "sources": ["e1"]},
    {"title": "客户对界面整体满意，加载速度是明确不满点", "detail": "回访中客户反馈新界面清爽，但列表页打开偏慢。", "sources": ["e2"]},
    {"title": "分工与书面结论在周五前落地", "detail": "B 认领整理分工并在周五前给出书面结论。", "sources": ["e4"]},
    {"title": "测试环境需在明早确认就绪", "detail": "晨间口头计划中标记为重点跟进事项。", "sources": ["e3"]}
  ],
  "todos": ["发出分工文档", "跟进客户加载速度问题", "准备周五书面结论"],
  "fullText": "【13:05 · 客户回访要点】\\n说话人 B（推测）：新界面反馈整体清爽，但列表页打开偏慢；筛选希望能记住上次选择条件。\\n说话人 A（推测）：速度问题和建议都已记录，下版本专项优化。\\n\\n【14:20 · 午后项目方向讨论】\\n说话人 A（推测）：这版排期偏紧，特别是测试阶段，建议先做一版可验证的小方案。\\n说话人 B（推测）：同意，先移除两个低优先级功能，我下午整理分工并在周五前给出书面结论。"
}
''';

/// 幻觉 sourceId：points[0] 引用了一条不存在的记录（应被丢弃），
/// points[1] 引用的 e1 真实存在（应保留）。
const String kHallucinatedJson = '''
{
  "title": "幻觉来源测试",
  "overview": "模型给出了一条不存在的记录 id。",
  "structure": [{"name": "分组", "leaves": ["要点"]}],
  "points": [
    {"title": "编出来的信息点", "detail": "来源 id 不存在", "sources": ["e404", "幽灵记录"]},
    {"title": "真实信息点", "detail": "来源 id 存在", "sources": ["e1"]}
  ],
  "todos": []
}
''';

/// 代码块围栏包裹 + 前后废话（模型常见输出形态）。
String fencedSummaryJson() => '''
好的，以下是整理结果：
```json
${kSummaryJson.trim()}
```
以上内容仅依据原文整理。''';

/// 有花括号但语法坏掉的 JSON（jsonDecode 抛 FormatException 那条路径）。
const String kMalformedJson = '{"title": "坏 JSON", "points": [},]}';

/// 完全不包含 JSON 的回复（抽不出对象那条路径）。
const String kNotJson = '抱歉，我无法完成这次整理。';
