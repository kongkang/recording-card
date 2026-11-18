import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/services/agent/agent_chat_controller.dart';
import 'package:recording_card/services/agent/agent_harness_worker.dart';
import 'package:recording_card/services/agent/skill_store.dart';
import 'package:recording_card/services/agent/web_search_client.dart';
import 'package:recording_card/services/agent/mcp_client.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/health/health_signal_models.dart';
import 'package:recording_card/services/health/health_signal_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _QueuedChatCompletion implements ChatCompletion {
  _QueuedChatCompletion(this._handlers);

  final List<String Function(List<ChatMessage> msgs, double temp)> _handlers;
  final List<List<ChatMessage>> recordedCalls = [];
  int _idx = 0;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    recordedCalls.add(List<ChatMessage>.of(messages));
    if (_idx >= _handlers.length) {
      return jsonEncode({'react': '👌', 'reply': '好'});
    }
    return _handlers[_idx++](messages, temperature);
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  test('记录检索 + 健康查询 + SKILL.md 渐进加载与持久化 + 会话 JSONL 恢复', () async {
    final tempDir = await Directory.systemTemp.createTemp('rc-agent-harness-');
    addTearDown(() => tempDir.delete(recursive: true));

    final skillStore = AgentSkillStore(tempDir.path);
    await skillStore.saveSkill(
      name: 'weekly-brief',
      description: '周五汇报时自动提取负责人与截止日',
      body: '整理重点：\n1. 按部门列出负责人\n2. 高亮未定时间',
    );
    expect(
      await skillStore.readSandboxFile('../../../etc/passwd'),
      isNull,
      reason: '必须拦截路径穿越',
    );

    final healthStore = HealthSignalStore(
      factory: databaseFactoryFfi,
      path: () async => '${tempDir.path}/health.db',
    );
    addTearDown(healthStore.close);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await healthStore.upsertAll([
      HealthSignalSample(
        id: 'hr-1',
        type: 'heart_rate',
        startMs: nowMs - 10 * 60 * 1000,
        endMs: nowMs - 10 * 60 * 1000,
        valueNum: 96,
        unit: 'bpm',
        ingestedAtMs: nowMs,
      ),
    ]);

    final appStore = AppStore(
      events: [
        const RecordEvent(
          id: 'e1',
          dayOffset: 0,
          title: '午后项目方向讨论',
          brief: '决定先做可验证小方案，导出功能延后两周。',
          longText: '导出功能延后两周。',
          time: '14:20',
          dur: '18分40秒',
          speakers: '老陈 / 我',
          mark: '',
          srcMap: '来源 14:20—14:38',
          dialog: [
            TurnLine('说话人 1', '导出功能延后两周，周五前给方案。', '14:21'),
          ],
          raw: [],
        ),
      ],
      loadPersistedState: false,
    )..summaries = [
        SummaryCard(id: 's1', time: '15:00', state: SummaryState.done)
          ..title = '项目排期总结'
          ..overview = '先交付小方案'
          ..todos = ['周五前发送分工方案'],
      ];
    addTearDown(appStore.dispose);

    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load();
    await config.setHealthSignalEnabled(true);

    // 真实后台 Isolate Worker（无 HTTP Mock，强制走 Isolate.spawn 通道）
    final completion = _QueuedChatCompletion([
      (msgs, _) {
        expect(msgs.first.content, contains('weekly-brief'));
        return jsonEncode({
          'react': '👌 翻一下记录',
          'tool_calls': [
            {
              'name': 'search_records',
              'arguments': {'query': '导出'},
            },
            {
              'name': 'query_health',
              'arguments': {'type': 'heart_rate'},
            },
            {
              'name': 'read_skill',
              'arguments': {'name': 'weekly-brief'},
            },
          ],
        });
      },
      (msgs, _) {
        final toolMsg = msgs.last.content;
        expect(toolMsg, contains('导出功能延后两周'));
        expect(toolMsg, contains('96'));
        expect(toolMsg, contains('按部门列出负责人'));
        return jsonEncode({
          'react': '🫡 get',
          'reply': '下午讨论拍板把导出功能延后两周，周五前发分工方案；另外你十分钟前心率是 96 bpm。',
        });
      },
    ]);

    final ctrl = AgentChatController(
      appStore: appStore,
      agentConfig: config,
      healthStore: healthStore,
      completion: completion,
      agentDirResolver: () async => tempDir.path,
    );
    addTearDown(ctrl.dispose);

    await ctrl.sendMessage('下午聊了什么？顺便看看我心率');
    expect(ctrl.errorMessage, isNull);
    expect(ctrl.messages, hasLength(2));
    expect(ctrl.messages.first.reaction, '👌 翻一下记录');
    expect(ctrl.messages.last.text, contains('导出功能延后两周'));
    expect(ctrl.messages.last.text, contains('96 bpm'));

    // 冷却重建 Controller：必须从 session.jsonl 恢复历史记录
    final reloaded = AgentChatController(
      appStore: appStore,
      agentConfig: config,
      healthStore: healthStore,
      completion: completion,
      agentDirResolver: () async => tempDir.path,
    );
    addTearDown(reloaded.dispose);
    await reloaded.ensureInitialized();
    expect(reloaded.messages, hasLength(2));
    expect(reloaded.messages.last.text, contains('96 bpm'));
  });

  test('联网搜索双路回退 + web_fetch + MCP + Agent 自改配置 + 纯文本容错降级', () async {
    final tempDir = await Directory.systemTemp.createTemp('rc-agent-web-');
    addTearDown(() => tempDir.delete(recursive: true));

    final mockHttp = MockClient((req) async {
      http.Response utf8Resp(String body, String ct) => http.Response.bytes(
        utf8.encode(body),
        200,
        headers: {'content-type': '$ct; charset=utf-8'},
      );
      if (req.url.host == 'cn.bing.com') {
        return utf8Resp('<html><body></body></html>', 'text/html');
      }
      if (req.url.host == 'html.duckduckgo.com') {
        return utf8Resp(
          '<a class="result__a" href="https://example.com/news">最新 Flutter 版本发布</a>'
          '<span class="result__snippet">支持更快的后台 Isolate 通信</span>',
          'text/html',
        );
      }
      if (req.url.host == 'example.com') {
        return utf8Resp(
          '<html><body><script>evil()</script><p>Flutter 3.47 详情页正文。</p></body></html>',
          'text/html',
        );
      }
      if (req.url.host == 'mcp.example.com') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        if (body['method'] == 'tools/list') {
          return utf8Resp(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'tools': [
                  {'name': 'ping_team', 'description': '测试团队接口'},
                ],
              },
            }),
            'application/json',
          );
        }
        return utf8Resp(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': {
              'content': [
                {'type': 'text', 'text': 'MCP_PONG_OK'},
              ],
            },
          }),
          'application/json',
        );
      }
      return http.Response('not found', 404);
    });

    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load();
    await config.addCustomMcp(
      name: '团队扩展',
      endpoint: 'https://mcp.example.com/rpc',
    );
    final mcpId = config.customMcps.single.id;

    final appStore = AppStore(loadPersistedState: false);
    addTearDown(appStore.dispose);

    final completion = _QueuedChatCompletion([
      (_, _) => jsonEncode({
        'react': '🔎 查一下',
        'tool_calls': [
          {
            'name': 'web_search',
            'arguments': {'query': 'Flutter 新版本'},
          },
          {
            'name': 'web_fetch',
            'arguments': {'url': 'https://example.com/news'},
          },
          {
            'name': 'mcp:$mcpId:ping_team',
            'arguments': {'echo': 'hi'},
          },
          {
            'name': 'update_agent_settings',
            'arguments': {
              'temperature': 0.7,
              'agentPrompt': '简洁风：两句话内直给重点',
            },
          },
          {
            'name': 'save_skill',
            'arguments': {
              'name': 'concise-style',
              'description': '简练回复模板',
              'body': '优先给出结论',
            },
          },
        ],
      }),
      // 模型未包 JSON 直接回自然语言：容错直接透传回答
      (msgs, _) {
        final ctx = msgs.last.content;
        expect(ctx, contains('最新 Flutter 版本发布'));
        expect(ctx, contains('Flutter 3.47 详情页正文'));
        expect(ctx, contains('MCP_PONG_OK'));
        return '联网查到了 Flutter 3.47 更新，我也已经按你的要求切到简练模式啦。';
      },
    ]);

    late AgentChatController ctrl;
    final worker = AgentHarnessWorker(
      complete: completion.complete,
      webSearchOverride: WebSearchClient(client: mockHttp),
      mcpOverride: AgentMcpClient(client: mockHttp),
      patchConfig: (patch) async {
        if (patch['temperature'] is num) {
          await config.setTemperature((patch['temperature'] as num).toDouble());
        }
        if (patch['agentPrompt'] is String) {
          await config.setAgentPrompt(patch['agentPrompt'] as String);
        }
        return '{"ok":true}';
      },
    );
    ctrl = AgentChatController(
      appStore: appStore,
      agentConfig: config,
      completion: completion,
      worker: worker,
      agentDirResolver: () async => tempDir.path,
    );
    addTearDown(() async {
      await worker.dispose();
      ctrl.dispose();
    });

    await ctrl.sendMessage('帮我搜一下 Flutter 新版本并调成简练回复');
    expect(ctrl.errorMessage, isNull);
    expect(ctrl.messages.last.text, contains('Flutter 3.47 更新'));
    expect(config.temperature, 0.7);
    expect(config.agentPrompt, '简洁风：两句话内直给重点');
    expect(
      await AgentSkillStore(tempDir.path).readSkill('concise-style'),
      contains('优先给出结论'),
    );
  });

  test('关闭健康开关时如实反馈未开启，不编造健康数据', () async {
    final tempDir = await Directory.systemTemp.createTemp('rc-agent-truth-');
    addTearDown(() => tempDir.delete(recursive: true));
    final config = AgentConfigStore(store: InMemoryStore());
    addTearDown(config.dispose);
    await config.load(); // healthSignalEnabled 默认 false

    final appStore = AppStore(loadPersistedState: false);
    addTearDown(appStore.dispose);
    final healthStore = HealthSignalStore(
      factory: databaseFactoryFfi,
      path: () async => '${tempDir.path}/h.db',
    );
    addTearDown(healthStore.close);

    final completion = _QueuedChatCompletion([
      (_, _) => jsonEncode({
        'react': '👌',
        'tool_calls': [
          {'name': 'query_health', 'arguments': {}},
        ],
      }),
      (msgs, _) {
        expect(msgs.last.content, contains('开关当前未开启'));
        return '你还没打开本机健康采集开关，去设置开启后我就能帮你查心率和睡眠了。';
      },
    ]);

    final ctrl = AgentChatController(
      appStore: appStore,
      agentConfig: config,
      healthStore: healthStore,
      completion: completion,
      agentDirResolver: () async => tempDir.path,
    );
    addTearDown(ctrl.dispose);

    await ctrl.sendMessage('今天步数多少？');
    expect(ctrl.messages.last.text, contains('还没打开'));
  });
}
