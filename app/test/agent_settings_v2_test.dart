// Setting V2 模型与智能体二级页 / 持久化 / SummaryGenerator 实时联动验收。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/ai/summary_generator.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

void main() {
  test('AgentConfigStore 持久化：模型/上下文模式/温度/预设/自定义提示词/Skills与自定义MCP冷启动完整恢复', () async {
    final backing = InMemoryStore();
    final first = AgentConfigStore(store: backing);
    addTearDown(first.dispose);
    await first.load();

    expect(first.cloudModel, 'deepseek-v3');
    expect(first.contextMode, 'full_day');
    expect(first.temperature, 0.2);
    expect(first.presetId, 'general');

    await first.setCloudModel('claude-3-7-sonnet');
    await first.setContextMode('scoped');
    await first.setTemperature(0.5);
    await first.selectPreset('meeting');
    expect(first.presetLabel, '深度会议');

    await first.savePrompt('summary', '请重点提炼阻塞风险与责任人截止时间。');
    expect(first.presetId, 'custom');
    expect(first.presetLabel, '自定义');

    await first.toggleExtension('skill-glossary'); // 默认 false → true
    await first.addCustomMcp(
      name: 'Notion 团队库',
      endpoint: 'https://mcp.example.com/sse',
    );

    final reopened = AgentConfigStore(store: backing);
    addTearDown(reopened.dispose);
    await reopened.load();

    expect(reopened.cloudModel, 'claude-3-7-sonnet');
    expect(reopened.contextMode, 'scoped');
    expect(reopened.temperature, 0.5);
    expect(reopened.presetId, 'custom');
    expect(reopened.promptFor('summary'), '请重点提炼阻塞风险与责任人截止时间。');
    expect(reopened.isExtensionOn('skill-glossary'), isTrue);
    expect(
      reopened.allExtensions.any((e) => e.title == 'Notion 团队库'),
      isTrue,
    );
  });

  test('AgentConfigStore 用户预设支持增改删并冷启动恢复', () async {
    final backing = InMemoryStore();
    final first = AgentConfigStore(store: backing);
    addTearDown(first.dispose);
    await first.load();

    final created = await first.addUserPreset(
      label: '产品评审',
      summaryPrompt: '聚焦需求边界与验收口径。',
      polishPrompt: '保留数字与负责人。',
      dreamPrompt: '归档待确认假设。',
    );
    expect(created, isNotNull);
    expect(first.presetId, created!.id);
    expect(first.presetLabel, '产品评审');
    expect(first.isUserPresetSelected, isTrue);

    await first.savePrompt('summary', '聚焦阻塞与验收。');
    expect(first.presetById(created.id)?.summaryPrompt, '聚焦阻塞与验收。');

    await first.renameUserPreset(created.id, '评审纪要');
    expect(first.presetLabel, '评审纪要');

    final reopened = AgentConfigStore(store: backing);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.userPresets.length, 1);
    expect(reopened.presetId, created.id);
    expect(reopened.presetLabel, '评审纪要');
    expect(reopened.promptFor('summary'), '聚焦阻塞与验收。');

    await reopened.deleteUserPreset(created.id);
    expect(reopened.userPresets, isEmpty);
    expect(reopened.presetId, 'general');
  });

  testWidgets('Setting 四个模型与智能体二级页：导航/修改/返回面包屑与父级摘要实时同步', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final model = SummaryModel();
    final agentConfig = AgentConfigStore(store: InMemoryStore());
    await agentConfig.load();
    final store = AppStore(
      events: seedEvents,
      generator: await model.generator(),
      loadPersistedState: false,
    );
    final device = DeviceStore(gateway: FakeCardGateway());
    addTearDown(agentConfig.dispose);
    addTearDown(store.dispose);
    addTearDown(device.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(
          store: store,
          device: device,
          agentConfig: agentConfig,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pump();

    expect(find.byKey(const Key('sv-cloud')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('sv-cloud'))).data,
      '已开启',
    );
    await agentConfig.setDeveloperMode(true);
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('sv-cloud'))).data,
      'deepseek-v3',
    );

    // 1) 云端模型设置二级页：切换模型 + 温度 → 返回后摘要实时变为 qwen-max
    await tester.tap(find.byKey(const Key('set-cloud-model')));
    await tester.pump();
    expect(find.byKey(const Key('setsub-title')), findsOneWidget);
    expect(find.byKey(const Key('crumb-back')), findsOneWidget);
    expect(find.text('Setting'), findsWidgets);

    await tester.tap(find.byKey(const Key('model-opt-qwen-max')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('temp-0.5')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('temp-0.5')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('sv-cloud'))).data,
      'qwen-max',
    );

    // 2) 预设风格与提示词二级页：切预设 + 编辑保存提示词 → 摘要变「自定义」
    await tester.tap(find.byKey(const Key('set-prompts')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('preset-todo')));
    await tester.pump();
    expect(agentConfig.presetId, 'todo');

    await tester.enterText(
      find.byKey(const Key('prompt-editor')),
      '按极简行动清单输出，优先列出负责人与时间点。',
    );
    await tester.ensureVisible(find.byKey(const Key('prompt-save')));
    await tester.tap(find.byKey(const Key('prompt-save')));
    await tester.pump();
    expect(find.byKey(const Key('prompt-saved-hint')), findsOneWidget);

    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('sv-preset'))).data, '自定义');

    // 3) 扩展能力二级页：仅保留真实 Skills/Tools，切换风险技能后摘要计数变化
    await tester.tap(find.byKey(const Key('set-extensions')));
    await tester.pump();
    expect(find.byKey(const Key('mcp-add-btn')), findsNothing);
    expect(find.text('个人知识库 MCP'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('sw-sk-risk')));
    await tester.tap(find.byKey(const Key('sw-sk-risk')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('sv-ext'))).data,
      contains('4 项'),
    );
  });

  test('SummaryGenerator 实时消费 AgentConfigStore：请求携带自定义模型、温度、提示词与已启用 Skills', () async {
    final requests = <http.Request>[];
    final gateway = await buildModelGateway(
      MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': kSummaryJson},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final agentConfig = AgentConfigStore(store: InMemoryStore());
    addTearDown(agentConfig.dispose);
    await agentConfig.load();

    await agentConfig.setDeveloperMode(true);
    await agentConfig.setCloudModel('claude-3-7-sonnet');
    await agentConfig.setTemperature(0.8);
    await agentConfig.savePrompt('summary', '【自定义纪要准则】必须逐条核对交付风险。');
    await agentConfig.toggleExtension('skill-glossary'); // 启用术语保护

    final generator = SummaryGenerator(
      gateway: gateway,
      agentConfig: agentConfig,
    );

    final draft = await generator.generate(seedEvents.take(2).toList());
    expect(draft.title, '项目排期与客户反馈');

    final req = requests.single;
    final payload = jsonDecode(req.body) as Map<String, dynamic>;
    expect(payload['model'], 'claude-3-7-sonnet');
    expect(payload['temperature'], 0.8);

    final messages = (payload['messages'] as List).cast<Map<String, dynamic>>();
    final sysContent = messages.first['content'] as String;
    expect(sysContent, contains('【自定义纪要准则】必须逐条核对交付风险。'));
    expect(sysContent, contains('对同音误识的专业术语、缩写与项目代号结合上下文做一致性对齐'));
    expect(sysContent, contains('"points"'), reason: '客户端自动追加严格 JSON schema 契约');
  });
}
