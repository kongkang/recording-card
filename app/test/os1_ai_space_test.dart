import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/agent/agent_chat_controller.dart';
import 'package:recording_card/services/agent/agent_harness_worker.dart';
import 'package:recording_card/services/agent/agent_speech_service.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';

import 'support/fake_gateway.dart';
import 'support/test_transitions.dart';

class _FakeSpeechBackend implements AgentSpeechBackend {
  final StreamController<AgentSpeechEvent> _ctrl =
      StreamController<AgentSpeechEvent>.broadcast();

  bool listening = false;
  bool speaking = false;
  final List<String> spokenTexts = [];
  int stopSpeakCalls = 0;

  @override
  Stream<AgentSpeechEvent> get events => _ctrl.stream;

  @override
  Future<bool> startListening({String locale = 'zh-CN'}) async {
    listening = true;
    _ctrl.add(const AgentSpeechEvent(kind: 'listening', active: true));
    return true;
  }

  void emitFinalSpeech(String text) {
    _ctrl.add(AgentSpeechEvent(kind: 'transcript', text: text, isFinal: true));
  }

  @override
  Future<void> stopListening() async {
    listening = false;
    _ctrl.add(const AgentSpeechEvent(kind: 'listening', active: false));
  }

  @override
  Future<void> speak(String text, {String locale = 'zh-CN'}) async {
    speaking = true;
    spokenTexts.add(text);
    _ctrl.add(const AgentSpeechEvent(kind: 'speaking', active: true));
  }

  @override
  Future<void> stopSpeaking() async {
    stopSpeakCalls++;
    if (speaking) {
      speaking = false;
      _ctrl.add(const AgentSpeechEvent(kind: 'speaking', active: false));
    }
  }

  @override
  void dispose() {
    unawaited(_ctrl.close());
  }
}

class _DelayedFakeCompletion implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return jsonEncode({
      'react': '🫡 get',
      'reply': '午后讨论里你们把导出功能延后两周了，先做小方案稳妥很多。',
    });
  }
}

void main() {
  testWidgets('底栏三按钮含居中 OS1 + 沉浸通话 STT/TTS 闭环 + 轻聊收发与关闭不阻塞', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    await agentConfig.load();
    final store = AppStore(events: seedEvents, loadPersistedState: false);
    final device = DeviceStore(gateway: FakeCardGateway());
    final speech = _FakeSpeechBackend();
    final completion = _DelayedFakeCompletion();
    final worker = AgentHarnessWorker(
      complete: completion.complete,
      inProcess: true,
    );
    final chatCtrl = AgentChatController(
      appStore: store,
      agentConfig: agentConfig,
      speech: speech,
      completion: completion,
      worker: worker,
      agentDirResolver: () async => '',
    );
    addTearDown(() async {
      await worker.dispose();
      chatCtrl.dispose();
      agentConfig.dispose();
      store.dispose();
      device.dispose();
      speech.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(
          store: store,
          device: device,
          agentConfig: agentConfig,
          agentChat: chatCtrl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1) 首页底栏包含 Timeline / OS1 / Setting，且居中日出圆钮向上凸起
    expect(find.byKey(const Key('nav-timeline')), findsOneWidget);
    expect(find.byKey(const Key('nav-ai-sunrise')), findsOneWidget);
    expect(find.byKey(const Key('nav-setting')), findsOneWidget);
    final navTop = tester.getTopLeft(find.byKey(const Key('bottom-nav'))).dy;
    final orbTop = tester
        .getTopLeft(find.byKey(const Key('nav-ai-sunrise-orb')))
        .dy;
    expect(navTop - orbTop >= 14, isTrue);

    // 2) 点击 OS1 打开全屏 AI 空间（默认进入沉浸通话 + 声波圆环）
    await tester.tap(find.byKey(const Key('nav-ai-sunrise')));
    await tester.pump();
    expect(find.byKey(const Key('ai-space')), findsOneWidget);
    expect(find.byKey(const Key('ai-her-pane')), findsOneWidget);
    expect(find.byKey(const Key('ai-her-canvas')), findsOneWidget);

    // 点提示按钮等于说了一句：选项先收起，这句话留在对话区滚动。
    await tester.tap(find.byKey(const Key('ai-her-prompt-mood')));
    await tester.pump();
    expect(find.byKey(const Key('ai-her-prompt-mood')), findsNothing);
    expect(find.textContaining('今天聊了哪些重点'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2400));
    await tester.tap(find.byKey(const Key('ai-her-stage')));
    await tester.pump();

    // 3) 沉浸通话语音闭环：点麦克风 → 系统 STT 给出最终识别文本 → Agent 回复 → 本地 TTS 自动播报
    await tester.tap(find.byKey(const Key('ai-her-talk-btn')));
    await tester.pump();
    expect(speech.listening, isTrue);

    speech.emitFinalSpeech('下午那场讨论聊了什么？');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.textContaining('导出功能延后两周'), findsWidgets);
    expect(speech.spokenTexts.last, contains('导出功能延后两周'));
    expect(speech.speaking, isTrue);

    // 播报中轻触圆环打断 TTS
    await tester.tap(find.byKey(const Key('ai-her-stage')));
    await tester.pump();
    expect(speech.stopSpeakCalls, greaterThanOrEqualTo(1));
    expect(speech.speaking, isFalse);

    // 4) 切到轻聊：发文字、看极简三点等待态（不含思考过程/调用工具）、收回复并带反应徽章
    await tester.tap(find.byKey(const Key('ai-mode-chat')));
    await tester.pump();
    expect(find.byKey(const Key('ai-chat-pane')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('ai-chat-input')),
      '帮我再确认一下分工方案',
    );
    await tester.tap(find.byKey(const Key('ai-chat-send')));
    await tester.pump();
    expect(find.byKey(const Key('ai-typing-bubble')), findsOneWidget);
    expect(find.textContaining('思考过程'), findsNothing);
    expect(find.textContaining('调用工具'), findsNothing);

    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const Key('ai-typing-bubble')), findsNothing);
    expect(find.textContaining('🫡 get'), findsWidgets);

    // 5) 收起面板后动画全部停止，pumpAndSettle 顺利收敛
    await tester.tap(find.byKey(const Key('ai-space-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-space')), findsNothing);
  });

  testWidgets('OS1 设置项联动 + 关闭云端如实报错不编造 + 清空会话', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final agentConfig = AgentConfigStore(store: InMemoryStore());
    await agentConfig.load();
    final store = AppStore(events: seedEvents, loadPersistedState: false);
    final device = DeviceStore(gateway: FakeCardGateway());
    final speech = _FakeSpeechBackend();
    final completion = _DelayedFakeCompletion();
    final worker = AgentHarnessWorker(
      complete: completion.complete,
      inProcess: true,
    );
    final chatCtrl = AgentChatController(
      appStore: store,
      agentConfig: agentConfig,
      speech: speech,
      completion: completion,
      worker: worker,
      agentDirResolver: () async => '',
    );
    addTearDown(() async {
      await worker.dispose();
      chatCtrl.dispose();
      agentConfig.dispose();
      store.dispose();
      device.dispose();
      speech.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: AppShell(
          store: store,
          device: device,
          agentConfig: agentConfig,
          agentChat: chatCtrl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1) Setting → 预设风格与提示词：保存 OS1 对话助手提示词
    await tester.tap(find.byKey(const Key('nav-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('set-prompts')));
    await tester.pumpAndSettle();
    final promptsScroll = find
        .descendant(
          of: find.byKey(const Key('setsub-scroll-prompts')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('agent-prompt-save')),
      220,
      scrollable: promptsScroll,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('agent-prompt-editor')),
      '先给结论，不超过三句话',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-prompt-save')));
    await tester.pump();
    expect(agentConfig.agentPrompt, '先给结论，不超过三句话');

    // 返回 Setting → 扩展能力：切换 OS1 对话工具权限与自定义搜索接口
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('set-extensions')));
    await tester.pumpAndSettle();
    final extScroll = find
        .descendant(
          of: find.byKey(const Key('setsub-scroll-ext')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('sw-agent-health')),
      220,
      scrollable: extScroll,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sw-agent-health')));
    await tester.pump();
    expect(agentConfig.agentHealthAccessEnabled, isFalse);

    await tester.scrollUntilVisible(
      find.byKey(const Key('agent-search-save')),
      220,
      scrollable: extScroll,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('agent-search-url-input')),
      'https://api.tavily.com/search',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-search-save')));
    await tester.pump();
    expect(agentConfig.customSearchApiUrl, 'https://api.tavily.com/search');

    // 2) 未传 gateway / cloudEnabled=false 时如实报错，不编造回复；打开并发送后可清空会话
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('nav-ai-sunrise')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-mode-chat')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-quick-1')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(chatCtrl.messages.length, greaterThanOrEqualTo(2));

    await tester.tap(find.byKey(const Key('ai-chat-clear')));
    await tester.pump();
    expect(chatCtrl.messages, isEmpty);

    await agentConfig.setCloudEnabled(false);
    final noCloudCtrl = AgentChatController(
      appStore: store,
      agentConfig: agentConfig,
      speech: speech,
      worker: worker,
      agentDirResolver: () async => '',
    );
    addTearDown(noCloudCtrl.dispose);
    await noCloudCtrl.sendMessage('测试未初始化网关提示');
    expect(noCloudCtrl.messages, isEmpty);
    expect(noCloudCtrl.errorMessage, isNotNull);
  });
}
