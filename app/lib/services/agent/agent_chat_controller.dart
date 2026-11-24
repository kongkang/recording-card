/// OS1 AI 空间统一控制器 —— 协调 UI 双模式（沉浸通话 / 轻聊）、后台 Worker Isolate、
/// 语料实时同步、系统 STT/TTS 与配置热更新。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import '../../core/store/agent_config_store.dart';
import '../../core/store/app_store.dart';
import '../analysis/chat_completion.dart';
import '../health/health_signal_models.dart';
import '../health/health_signal_rows.dart';
import '../health/health_signal_store.dart';
import '../memory/memory_query.dart';
import '../net/model_gateway.dart';
import '../net/model_provider_store.dart';
import 'agent_harness_worker.dart';
import 'agent_models.dart';
import 'agent_speech_service.dart';

enum Os1Mode { her, chat }

class AgentChatController extends ChangeNotifier {
  AgentChatController({
    required AppStore appStore,
    required AgentConfigStore agentConfig,
    ModelGateway? gateway,
    ChatCompletion? completion,
    Future<String> Function(List<ChatMessage> messages, {String? model})?
    visionCompletion,
    HealthSignalStore? healthStore,
    AgentSpeechBackend? speech,
    AgentHarnessWorker? worker,
    Future<String> Function()? agentDirResolver,
    DateTime Function()? clock,
    int historyPageSize = 20,
  }) : _appStore = appStore,
       _agentConfig = agentConfig,
       _gateway = gateway,
       _completion = completion,
       _visionCompletion = visionCompletion,
       _healthStore = healthStore,
       _speech = speech ?? PlatformAgentSpeechBackend(),
       _ownsSpeech = speech == null,
       _agentDirResolver = agentDirResolver,
       _clock = clock ?? DateTime.now,
       _historyPageSize = math.max(1, historyPageSize) {
    _worker =
        worker ??
        AgentHarnessWorker(
          complete: _completeOnHost,
          queryHealth: _queryHealthOnHost,
          patchConfig: _patchConfigOnHost,
          clock: _clock,
        );
    _ownsWorker = worker == null;
    _speechSub = _speech.events.listen(_handleSpeechEvent);
    _appStore.addListener(_scheduleCorpusSync);
    _agentConfig.addListener(_onConfigChanged);
  }

  static const String _defaultHerHeadline =
      '我听着呢，随时按下方麦克风说话，或切到「轻聊」打字问我。';

  final AppStore _appStore;
  final AgentConfigStore _agentConfig;
  final ModelGateway? _gateway;
  final ChatCompletion? _completion;
  final Future<String> Function(List<ChatMessage> messages, {String? model})?
  _visionCompletion;
  final HealthSignalStore? _healthStore;
  final AgentSpeechBackend _speech;
  final bool _ownsSpeech;
  final Future<String> Function()? _agentDirResolver;
  final DateTime Function() _clock;
  final int _historyPageSize;
  late final AgentHarnessWorker _worker;
  late final bool _ownsWorker;

  StreamSubscription<AgentSpeechEvent>? _speechSub;
  Timer? _corpusDebounce;
  bool _disposed = false;
  bool _initialized = false;
  Future<void>? _initFuture;
  String _agentDirPath = '';
  String _lastStoreStamp = '';
  String _lastCorpusDigest = '';
  int _sessionSeq = 0;
  int _sessionEpoch = 0;
  bool _explicitNewSession = false;
  final Map<String, List<AgentChatMessage>> _memorySessions = {};

  /// 供测试验证无关 AppStore 通知（如折叠卡片、切换 Tab）不会重复重建全文语料。
  int debugCollectDocumentsCount = 0;

  bool isOpen = false;
  Os1Mode mode = Os1Mode.her;
  bool isBusy = false;
  bool isListening = false;
  bool isSpeaking = false;
  double voiceEnergy = 0.28;
  String partialSpeech = '';
  String? errorMessage;

  late String activeSessionId = _newSessionId();
  List<AgentChatSession> sessions = const [];
  List<AgentChatMessage> messages = const [];
  int _loadedStartIndex = 0;
  int totalMessageCount = 0;
  bool isLoadingOlder = false;
  bool justStartedNewSession = false;
  String herHeadline = _defaultHerHeadline;
  String herSubline = '可查历史录音总结、本机健康状态，也能联网帮你查最新信息';

  bool get hasMoreOlderMessages => _loadedStartIndex > 0;

  DateTime now() => _clock();

  String _newSessionId() => 's-${_clock().millisecondsSinceEpoch}-${++_sessionSeq}';

  Future<void> ensureInitialized({bool syncCorpus = true}) async {
    if (_disposed) return;
    if (!_initialized) {
      _initFuture ??= _runInitialLoad();
      await _initFuture;
    }
    if (_disposed) return;
    if (syncCorpus) {
      await _syncCorpusNow();
    } else {
      unawaited(_syncCorpusNow());
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _runInitialLoad() async {
    final epoch = _sessionEpoch;
    _agentDirPath = await _resolveAgentDir();
    if (_disposed) return;
    if (_agentDirPath.isNotEmpty) {
      try {
        final list = await _worker.listSessions(_agentDirPath);
        if (_disposed) return;
        sessions = list;
        if (list.isNotEmpty &&
            !_explicitNewSession &&
            messages.isEmpty &&
            epoch == _sessionEpoch) {
          final page = await _worker.loadSessionPage(
            _agentDirPath,
            sessionId: list.first.id,
            limit: _historyPageSize,
          );
          if (_disposed || _explicitNewSession || epoch != _sessionEpoch) {
            _initialized = true;
            return;
          }
          if (page.messages.isNotEmpty) {
            activeSessionId = list.first.id;
            messages = page.messages;
            _loadedStartIndex = page.startIndex;
            totalMessageCount = page.totalCount;
            final lastHer = page.messages
                .where((m) => m.role == 'assistant')
                .lastOrNull;
            if (lastHer != null && lastHer.text.isNotEmpty) {
              herHeadline = lastHer.text;
            }
          }
        }
      } on Object {
        // 读取旧会话失败不阻断打开界面
      }
    }
    _initialized = true;
  }

  Future<String> _resolveAgentDir() async {
    final custom = _agentDirResolver;
    if (custom != null) return custom();
    try {
      final dir = await getApplicationSupportDirectory();
      return '${dir.path}/agent';
    } on Object {
      return '';
    }
  }

  void open({Os1Mode? initialMode}) {
    if (initialMode != null) mode = initialMode;
    isOpen = true;
    errorMessage = null;
    notifyListeners();
    unawaited(ensureInitialized());
  }

  void close() {
    isOpen = false;
    if (isListening) {
      unawaited(_speech.stopListening());
      isListening = false;
    }
    if (isSpeaking) {
      unawaited(_speech.stopSpeaking());
      isSpeaking = false;
    }
    partialSpeech = '';
    voiceEnergy = 0.28;
    notifyListeners();
  }

  void setMode(Os1Mode next) {
    if (mode == next) return;
    if (next == Os1Mode.chat && isListening) {
      unawaited(_speech.stopListening());
      isListening = false;
    }
    mode = next;
    errorMessage = null;
    notifyListeners();
  }

  /// 开启新对话：保留当前上下文到历史对话列表，切到干净新会话。
  void startNewSession() {
    if (_disposed || isBusy) return;
    final hadMessages = messages.isNotEmpty;
    _sessionEpoch++;
    _explicitNewSession = true;
    activeSessionId = _newSessionId();
    messages = const [];
    _loadedStartIndex = 0;
    totalMessageCount = 0;
    isLoadingOlder = false;
    errorMessage = null;
    justStartedNewSession = hadMessages;
    herHeadline = '已开启新对话，原来的对话已存入历史。';
    notifyListeners();
  }

  /// 切换到指定历史会话并加载最新一页消息，支持直接继续对话。
  Future<void> switchSession(String sessionId) async {
    if (_disposed || isBusy) return;
    if (sessionId == activeSessionId && !justStartedNewSession) return;
    await ensureInitialized();
    if (_disposed || isBusy) return;
    _explicitNewSession = false;
    justStartedNewSession = false;
    errorMessage = null;
    isLoadingOlder = false;
    final epoch = ++_sessionEpoch;
    activeSessionId = sessionId;

    late final AgentSessionPage page;
    if (_agentDirPath.isNotEmpty) {
      page = await _worker.loadSessionPage(
        _agentDirPath,
        sessionId: sessionId,
        limit: _historyPageSize,
      );
    } else {
      final all = _memorySessions[sessionId] ?? const <AgentChatMessage>[];
      final total = all.length;
      final start = (total - _historyPageSize).clamp(0, total);
      page = AgentSessionPage(
        sessionId: sessionId,
        messages: all.sublist(start, total),
        totalCount: total,
        startIndex: start,
      );
    }
    if (_disposed || epoch != _sessionEpoch) return;
    messages = page.messages;
    _loadedStartIndex = page.startIndex;
    totalMessageCount = page.totalCount;
    final lastHer = page.messages
        .where((m) => m.role == 'assistant')
        .lastOrNull;
    herHeadline = (lastHer != null && lastHer.text.isNotEmpty)
        ? lastHer.text
        : _defaultHerHeadline;
    notifyListeners();
  }

  /// 向上翻看历史记录时按页加载更早消息。
  Future<void> loadOlderMessages() async {
    if (_disposed || isLoadingOlder || !hasMoreOlderMessages) return;
    final targetSessionId = activeSessionId;
    final beforeIndex = _loadedStartIndex;
    final epoch = _sessionEpoch;
    isLoadingOlder = true;
    notifyListeners();

    try {
      late final AgentSessionPage page;
      if (_agentDirPath.isNotEmpty) {
        page = await _worker.loadSessionPage(
          _agentDirPath,
          sessionId: targetSessionId,
          beforeIndex: beforeIndex,
          limit: _historyPageSize,
        );
      } else {
        final all =
            _memorySessions[targetSessionId] ?? const <AgentChatMessage>[];
        final total = all.length;
        final end = beforeIndex.clamp(0, total);
        final start = (end - _historyPageSize).clamp(0, end);
        page = AgentSessionPage(
          sessionId: targetSessionId,
          messages: all.sublist(start, end),
          totalCount: total,
          startIndex: start,
        );
      }
      if (_disposed ||
          epoch != _sessionEpoch ||
          activeSessionId != targetSessionId) {
        return;
      }
      if (_loadedStartIndex == beforeIndex && page.messages.isNotEmpty) {
        messages = [...page.messages, ...messages];
      }
      _loadedStartIndex = page.startIndex;
      totalMessageCount = math.max(totalMessageCount, page.totalCount);
    } finally {
      if (!_disposed && epoch == _sessionEpoch) {
        isLoadingOlder = false;
        notifyListeners();
      }
    }
  }

  /// 删除指定会话（若为当前会话则同步重置为空白新会话）。
  Future<void> deleteSession(String sessionId) async {
    if (_disposed || (isBusy && sessionId == activeSessionId)) return;
    await ensureInitialized();
    if (_disposed) return;

    sessions = [
      for (final s in sessions)
        if (s.id != sessionId) s,
    ];
    _memorySessions.remove(sessionId);

    if (_agentDirPath.isNotEmpty) {
      await _worker.deleteSession(_agentDirPath, sessionId);
      if (_disposed) return;
    }

    if (sessionId == activeSessionId) {
      _sessionEpoch++;
      _explicitNewSession = true;
      activeSessionId = _newSessionId();
      messages = const [];
      _loadedStartIndex = 0;
      totalMessageCount = 0;
      isLoadingOlder = false;
      justStartedNewSession = false;
      errorMessage = null;
      herHeadline = '会话已清空，我们可以重新聊起。';
    }
    notifyListeners();
  }

  /// 刷新历史会话目录（供打开抽屉时对齐后台落盘结果）。
  Future<void> refreshSessions() async {
    if (_disposed) return;
    await ensureInitialized();
    if (_disposed) return;
    if (_agentDirPath.isNotEmpty) {
      final list = await _worker.listSessions(_agentDirPath);
      if (_disposed) return;
      sessions = list;
      notifyListeners();
    }
  }

  Future<void> clearHistory() => deleteSession(activeSessionId);

  Future<void> toggleListening() async {
    if (isBusy) return;
    if (isSpeaking) {
      await _speech.stopSpeaking();
      isSpeaking = false;
    }
    if (isListening) {
      await _speech.stopListening();
      isListening = false;
      final pending = partialSpeech.trim();
      partialSpeech = '';
      voiceEnergy = 0.35;
      notifyListeners();
      if (pending.isNotEmpty) {
        await sendMessage(
          pending,
          viaVoice: true,
          speakReply: mode == Os1Mode.her,
        );
      }
      return;
    }

    errorMessage = null;
    partialSpeech = '';
    final ok = await _speech.startListening(locale: 'zh-CN');
    if (_disposed) return;
    isListening = ok;
    if (ok) {
      voiceEnergy = 0.72;
      if (mode == Os1Mode.her) {
        herHeadline = '我在听，说完轻点麦克风发给我…';
      }
    }
    notifyListeners();
  }

  Future<void> speakText(String text) async {
    final clean = AgentHarnessWorker.cleanVoiceReplyText(text);
    if (clean.isEmpty) return;
    await _speech.stopSpeaking();
    isSpeaking = true;
    voiceEnergy = 0.85;
    notifyListeners();
    await _speech.speak(clean, locale: 'zh-CN');
  }

  Future<void> interruptSpeech() async {
    if (!isSpeaking) return;
    await _speech.stopSpeaking();
    isSpeaking = false;
    voiceEnergy = 0.30;
    notifyListeners();
  }

  void _handleSpeechEvent(AgentSpeechEvent ev) {
    if (_disposed) return;
    switch (ev.kind) {
      case 'transcript':
        partialSpeech = ev.text;
        if (mode == Os1Mode.her && ev.text.trim().isNotEmpty) {
          herHeadline = ev.text.trim();
        }
        if (ev.isFinal && isListening) {
          isListening = false;
          final finalText = ev.text.trim();
          partialSpeech = '';
          notifyListeners();
          if (finalText.isNotEmpty) {
            unawaited(
              sendMessage(
                finalText,
                viaVoice: true,
                speakReply: mode == Os1Mode.her,
              ),
            );
          }
          return;
        }
        notifyListeners();
      case 'level':
        voiceEnergy = (0.35 + ev.level * 0.65).clamp(0.28, 1.0);
        notifyListeners();
      case 'listening':
        isListening = ev.active;
        if (!ev.active) voiceEnergy = 0.32;
        notifyListeners();
      case 'speaking':
        isSpeaking = ev.active;
        voiceEnergy = ev.active ? 0.82 : 0.30;
        notifyListeners();
      case 'error':
        isListening = false;
        errorMessage = ev.error;
        if (mode == Os1Mode.her && ev.error != null) {
          herHeadline = ev.error!;
        }
        notifyListeners();
    }
  }

  void _recordSessionMessage(String sessionId, AgentChatMessage msg) {
    if (_agentDirPath.isEmpty) {
      final list = _memorySessions.putIfAbsent(
        sessionId,
        () => <AgentChatMessage>[],
      );
      final idx = list.indexWhere((m) => m.id == msg.id);
      if (idx >= 0) {
        list[idx] = msg;
      } else {
        list.add(msg);
      }
    }
    final nextCount = _agentDirPath.isEmpty
        ? (_memorySessions[sessionId]?.length ?? totalMessageCount)
        : totalMessageCount;
    final updated = List<AgentChatSession>.of(sessions);
    final sIdx = updated.indexWhere((s) => s.id == sessionId);
    final previewText = AgentChatSession.summarizeText(msg.text, maxChars: 60);
    final ts = msg.createdAtMs > 0
        ? msg.createdAtMs
        : _clock().millisecondsSinceEpoch;
    if (sIdx >= 0) {
      final prev = updated[sIdx];
      final nextTitle =
          (prev.title.trim().isNotEmpty && prev.title != '新对话')
          ? prev.title
          : AgentChatSession.deriveTitle([msg]);
      updated[sIdx] = prev.copyWith(
        title: nextTitle,
        preview: previewText.isNotEmpty ? previewText : prev.preview,
        updatedAtMs: ts >= prev.updatedAtMs ? ts : prev.updatedAtMs,
        messageCount: math.max(prev.messageCount, nextCount),
      );
    } else {
      updated.add(
        AgentChatSession(
          id: sessionId,
          title: AgentChatSession.deriveTitle([msg]),
          preview: previewText,
          createdAtMs: ts,
          updatedAtMs: ts,
          messageCount: math.max(1, nextCount),
        ),
      );
    }
    updated.sort((a, b) {
      final byUpd = b.updatedAtMs.compareTo(a.updatedAtMs);
      if (byUpd != 0) return byUpd;
      return b.createdAtMs.compareTo(a.createdAtMs);
    });
    sessions = updated;
  }

  void _updateMemoryReaction(String sessionId, String msgId, String react) {
    final list = _memorySessions[sessionId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == msgId);
    if (idx >= 0) {
      list[idx] = list[idx].copyWith(reaction: react);
    }
  }

  Future<void> sendMessage(
    String rawText, {
    bool viaVoice = false,
    bool speakReply = false,
    bool speakError = false,
  }) async {
    final text = rawText.trim();
    if (text.isEmpty || isBusy || _disposed) return;

    final gateError = _preflightCheck();
    if (gateError != null) {
      errorMessage = gateError;
      if (mode == Os1Mode.her) herHeadline = gateError;
      notifyListeners();
      if (speakError) unawaited(speakText(gateError));
      return;
    }

    await ensureInitialized();
    if (_disposed) return;

    final targetSessionId = activeSessionId;
    justStartedNewSession = false;
    _explicitNewSession = false;
    final nowMs = _clock().millisecondsSinceEpoch;
    final userMsgId = 'u-$nowMs-${messages.length}';
    final userMsg = AgentChatMessage(
      id: userMsgId,
      role: 'user',
      text: text,
      createdAtMs: nowMs,
      viaVoice: viaVoice,
    );
    final prevHistory = List<AgentChatMessage>.of(messages);
    messages = [...messages, userMsg];
    totalMessageCount += 1;
    _recordSessionMessage(targetSessionId, userMsg);
    isBusy = true;
    errorMessage = null;
    if (mode == Os1Mode.her) {
      herHeadline = '让我想想，顺手帮你翻一下记录…';
      voiceEnergy = 0.62;
    }
    notifyListeners();

    try {
      final result = await _worker.runTurn(
        userText: text,
        history: prevHistory,
        config: _buildConfigSnapshot(),
        sessionId: targetSessionId,
        userMsgId: userMsgId,
        userCreatedAtMs: nowMs,
        viaVoice: viaVoice,
        nowMs: nowMs,
        onReaction: (react) {
          if (_disposed) return;
          messages = [
            for (final m in messages)
              if (m.id == userMsgId) m.copyWith(reaction: react) else m,
          ];
          _updateMemoryReaction(targetSessionId, userMsgId, react);
          notifyListeners();
        },
      );
      if (_disposed) return;

      if (result.error != null) {
        errorMessage = _friendlyError(result.error!);
        if (mode == Os1Mode.her) {
          herHeadline = errorMessage!;
          voiceEnergy = 0.30;
        }
        if (speakError && errorMessage != null && errorMessage!.isNotEmpty) {
          unawaited(speakText(errorMessage!));
        }
      } else {
        final reply = result.reply.trim();
        final react = result.reaction;
        if (react != null && react.isNotEmpty) {
          messages = [
            for (final m in messages)
              if (m.id == userMsgId) m.copyWith(reaction: react) else m,
          ];
          _updateMemoryReaction(targetSessionId, userMsgId, react);
        }
        final replyAt = _clock().millisecondsSinceEpoch;
        final assistantMsg = AgentChatMessage(
          id: 'a-$replyAt-${messages.length}',
          role: 'assistant',
          text: reply,
          createdAtMs: replyAt,
        );
        messages = [...messages, assistantMsg];
        totalMessageCount += 1;
        _recordSessionMessage(targetSessionId, assistantMsg);
        if (mode == Os1Mode.her) {
          herHeadline = reply;
        }
        if (speakReply && reply.isNotEmpty) {
          unawaited(speakText(reply));
        }
      }
    } on Object catch (e) {
      if (_disposed) return;
      errorMessage = _friendlyError('$e');
      if (mode == Os1Mode.her) herHeadline = errorMessage!;
      if (speakError && errorMessage != null && errorMessage!.isNotEmpty) {
        unawaited(speakText(errorMessage!));
      }
    } finally {
      if (!_disposed) {
        isBusy = false;
        if (!isSpeaking && !isListening) voiceEnergy = 0.30;
        notifyListeners();
      }
    }
  }

  /// 发送硬件抓拍照片给多模态视觉模型识别，并按需语音播报结果或错误。
  Future<void> sendPhotoRecognitionMessage({
    required Uint8List jpegBytes,
    String prompt = '请识别这张照片里的主要内容，用简洁自然的中文直接告诉我重点。',
    bool speakReply = true,
    bool speakError = true,
  }) async {
    if (jpegBytes.isEmpty || isBusy || _disposed) return;

    final gateError = _visionPreflightCheck();
    if (gateError != null) {
      errorMessage = gateError;
      if (mode == Os1Mode.her) herHeadline = gateError;
      notifyListeners();
      if (speakError) unawaited(speakText(gateError));
      return;
    }

    await ensureInitialized(syncCorpus: false);
    if (_disposed) return;

    final targetSessionId = activeSessionId;
    justStartedNewSession = false;
    _explicitNewSession = false;
    final nowMs = _clock().millisecondsSinceEpoch;
    final userMsg = AgentChatMessage(
      id: 'u-$nowMs-${messages.length}',
      role: 'user',
      text: '📷 [拍照识别] $prompt',
      createdAtMs: nowMs,
      viaVoice: true,
    );
    messages = [...messages, userMsg];
    totalMessageCount += 1;
    _recordSessionMessage(targetSessionId, userMsg);
    isBusy = true;
    errorMessage = null;
    if (mode == Os1Mode.her) {
      herHeadline = '让我仔细看看刚才拍下的画面…';
      voiceEnergy = 0.62;
    }
    notifyListeners();

    try {
      final dataUrl = 'data:image/jpeg;base64,${base64Encode(jpegBytes)}';
      final visionMsgs = [
        ChatMessage.system(
          '你是用户的随身视觉助手。请直接、准确、简洁地描述或解答用户拍摄的画面内容，适合语音播报，不要使用任何 Markdown 符号（如 *、#、-）。',
        ),
        ChatMessage.userWithImage(prompt, imageDataUrl: dataUrl),
      ];
      final rawReply = _visionCompletion != null
          ? await _visionCompletion(visionMsgs, model: _resolveVisionModel())
          : await _gateway!.chat(
              visionMsgs,
              model: _resolveVisionModel(),
              scene: ModelScene.vision,
              temperature: 0.2,
              maxTokens: 1024,
              timeout: const Duration(seconds: 60),
            );
      if (_disposed) return;
      final reply = AgentHarnessWorker.cleanVoiceReplyText(rawReply);
      final replyAt = _clock().millisecondsSinceEpoch;
      final assistantMsg = AgentChatMessage(
        id: 'a-$replyAt-${messages.length}',
        role: 'assistant',
        text: reply,
        createdAtMs: replyAt,
      );
      messages = [...messages, assistantMsg];
      totalMessageCount += 1;
      _recordSessionMessage(targetSessionId, assistantMsg);
      if (_agentDirPath.isNotEmpty) {
        try {
          await _worker.appendSessionMessages(
            _agentDirPath,
            sessionId: targetSessionId,
            messages: [userMsg, assistantMsg],
          );
        } on Object {
          // 落盘失败不阻断回复展示
        }
      }
      if (mode == Os1Mode.her && reply.isNotEmpty) {
        herHeadline = reply;
      }
      if (speakReply && reply.isNotEmpty) {
        unawaited(speakText(reply));
      }
    } on Object catch (e) {
      if (_disposed) return;
      if (_agentDirPath.isNotEmpty) {
        try {
          await _worker.appendSessionMessages(
            _agentDirPath,
            sessionId: targetSessionId,
            messages: [userMsg],
          );
        } on Object {
          // 忽略异常
        }
      }
      errorMessage = _friendlyError('$e');
      if (mode == Os1Mode.her) herHeadline = errorMessage!;
      if (speakError && errorMessage != null && errorMessage!.isNotEmpty) {
        unawaited(speakText(errorMessage!));
      }
    } finally {
      if (!_disposed) {
        isBusy = false;
        if (!isSpeaking && !isListening) voiceEnergy = 0.30;
        notifyListeners();
      }
    }
  }

  String? _visionPreflightCheck() {
    if (_visionCompletion != null) return null;
    return _preflightCheck(scene: ModelScene.vision);
  }

  String? _resolveVisionModel() {
    final vm = _gateway?.modelFor(ModelScene.vision).trim() ?? '';
    if (vm.isNotEmpty) return vm;
    final tm = _resolveModel().trim();
    return tm.isNotEmpty ? tm : null;
  }

  String? _preflightCheck({ModelScene scene = ModelScene.agent}) {
    if (_completion != null) return null;
    final gw = _gateway;
    if (gw == null) return '对话服务尚未初始化，请稍后再试';
    if (!_agentConfig.cloudEnabled || !gw.isCloudEnabled) {
      return '请先在设置中选择模型服务';
    }
    if (!gw.chatAvailableFor(scene)) {
      return '尚未配置对话模型端点，请检查模型设置或后端配置';
    }
    if (!gw.readyFor(scene)) {
      return '尚未登录云端账号，请前往「Setting → 云端账号授权」登录后再试';
    }
    return null;
  }

  String _friendlyError(String raw) {
    final lower = raw.toLowerCase();
    if (_gateway?.usesExternalProvider != true &&
        (lower.contains('401') || lower.contains('未登录'))) {
      return '云端登录已失效，请前往「Setting → 云端账号授权」重新登录';
    }
    return raw.replaceFirst(RegExp(r'^Bad state:\s*'), '');
  }

  AgentConfigSnapshot _buildConfigSnapshot() {
    final resolvedModel = _resolveModel();
    final vpNames = _appStore.voiceprintStore.allPersons
        .where((p) => p.name.trim().isNotEmpty)
        .map((p) => p.isSelf ? '${p.name}（机主本人）' : p.name)
        .toList();
    final mcps = [
      for (final item in _agentConfig.customMcps)
        if (_agentConfig.isExtensionOn(item.id) &&
            item.subtitle.trim().isNotEmpty)
          AgentMcpEndpoint(
            id: item.id,
            name: item.title,
            url: item.subtitle.trim(),
          ),
    ];
    return AgentConfigSnapshot(
      model: resolvedModel,
      temperature: _agentConfig.developerMode ? _agentConfig.temperature : 0.35,
      agentPrompt: _agentConfig.agentPrompt,
      enabledSkillRules: _agentConfig.enabledSkillRules,
      webSearchEnabled: _agentConfig.agentWebSearchEnabled,
      recordSearchEnabled: _agentConfig.agentRecordSearchEnabled,
      healthAccessEnabled: _agentConfig.agentHealthAccessEnabled,
      customSearchApiUrl: _agentConfig.customSearchApiUrl,
      customSearchApiKey: _agentConfig.customSearchApiKey,
      activeMcps: mcps,
      agentDirPath: _agentDirPath,
      speakerLibrarySummary: vpNames.join('、'),
    );
  }

  String _resolveModel() {
    if (_agentConfig.developerMode &&
        _agentConfig.userPickedCloudModel &&
        _agentConfig.cloudModel.trim().isNotEmpty) {
      return _agentConfig.cloudModel.trim();
    }
    final gwModel = _gateway?.modelFor(ModelScene.agent).trim() ?? '';
    if (gwModel.isNotEmpty) return gwModel;
    return _agentConfig.cloudModel.trim();
  }

  Future<String> _completeOnHost(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.3,
    int maxTokens = 2048,
  }) async {
    final comp = _completion;
    if (comp != null) {
      return comp.complete(
        messages,
        model: model,
        temperature: temperature,
        maxTokens: maxTokens,
      );
    }
    final gw = _gateway;
    if (gw == null) throw StateError('未配置模型网关');
    return gw.chat(
      messages,
      model: model.trim().isEmpty ? null : model.trim(),
      scene: ModelScene.agent,
      temperature: temperature,
      maxTokens: maxTokens,
      timeout: const Duration(seconds: 60),
    );
  }

  Future<String> _queryHealthOnHost(Map<String, dynamic> args) async {
    if (!_agentConfig.healthSignalEnabled) {
      return jsonEncode({
        'ok': false,
        'enabled': false,
        'reason': '本机「定位与健康信号」开关当前未开启，暂时没有采集健康与位置数据',
      });
    }
    final hs = _healthStore;
    if (hs == null) {
      return jsonEncode({'ok': false, 'reason': '本机健康库尚未就绪'});
    }
    final hours = ((args['since_hours'] as num?)?.toDouble() ?? 24).clamp(
      1.0,
      720.0,
    );
    final limit = ((args['limit'] as num?)?.toInt() ?? 40).clamp(1, 200);
    final type = (args['type'] as String?)?.trim();
    final nowMs = _clock().millisecondsSinceEpoch;
    final startMs = nowMs - (hours * 3600 * 1000).round();

    final samples = await hs.query(
      HealthSignalQuery(
        startMs: startMs,
        endMs: nowMs + 1,
        type: (type == null || type.isEmpty) ? null : type,
        limit: limit,
        ascending: false,
      ),
    );
    if (samples.isEmpty) {
      return jsonEncode({
        'ok': true,
        'enabled': true,
        'count': 0,
        'summary': '最近 ${hours.round()} 小时暂无匹配的本机健康或位置样本',
      });
    }
    final rows = buildHealthSignalRows(samples).take(24).toList();
    return jsonEncode({
      'ok': true,
      'enabled': true,
      'count': samples.length,
      'rows': [
        for (final r in rows)
          {
            'time': r.timeLabel,
            'kind': r.kind,
            'metric': r.metric,
            'meta': r.meta,
          },
      ],
      'samples': [
        for (final s in samples.take(20))
          {
            'type': s.type,
            'label': healthTypeLabel(s.type),
            'startMs': s.startMs,
            'valueNum': s.valueNum,
            'valueText': s.valueText,
            'unit': s.unit,
          },
      ],
    });
  }

  Future<String> _patchConfigOnHost(Map<String, dynamic> patch) async {
    final updated = <String>[];
    if (patch['temperature'] is num) {
      await _agentConfig.setTemperature(
        (patch['temperature'] as num).toDouble(),
      );
      updated.add('temperature');
    }
    if (patch['agentPrompt'] is String &&
        (patch['agentPrompt'] as String).trim().isNotEmpty) {
      await _agentConfig.setAgentPrompt(patch['agentPrompt'] as String);
      updated.add('agentPrompt');
    }
    if (patch['webSearchEnabled'] is bool) {
      await _agentConfig.setAgentWebSearchEnabled(
        patch['webSearchEnabled'] as bool,
      );
      updated.add('webSearchEnabled');
    }
    if (patch['recordSearchEnabled'] is bool) {
      await _agentConfig.setAgentRecordSearchEnabled(
        patch['recordSearchEnabled'] as bool,
      );
      updated.add('recordSearchEnabled');
    }
    if (patch['healthAccessEnabled'] is bool) {
      await _agentConfig.setAgentHealthAccessEnabled(
        patch['healthAccessEnabled'] as bool,
      );
      updated.add('healthAccessEnabled');
    }
    final rawMcp = patch['customMcp'];
    if (rawMcp is Map) {
      final name = '${rawMcp['name'] ?? ''}'.trim();
      final endpoint = '${rawMcp['endpoint'] ?? rawMcp['url'] ?? ''}'.trim();
      if (name.isNotEmpty && endpoint.isNotEmpty) {
        await _agentConfig.addCustomMcp(name: name, endpoint: endpoint);
        updated.add('customMcp($name)');
      }
    }
    return jsonEncode({'ok': true, 'updated': updated});
  }

  void _onConfigChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  void _scheduleCorpusSync() {
    if (_disposed || !_initialized) return;
    // 快速比对语料签名：展开卡片、切换 Tab、勾选进度等无关通知直接短路，不触发全量遍历
    if (_computeStoreStamp() == _lastStoreStamp) return;
    _corpusDebounce?.cancel();
    _corpusDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!_disposed) unawaited(_syncCorpusNow());
    });
  }

  bool _hasNoIndexableContent() {
    final hasEvent = _appStore.events.any((e) => !e.live);
    if (hasEvent) return false;
    final hasSummary = _appStore.summaries.any(
      (s) => s.state == SummaryState.done,
    );
    return !hasSummary;
  }

  String _computeStoreStamp() {
    final buf = StringBuffer();
    for (final e in _appStore.events) {
      if (e.live) continue;
      buf
        ..write(e.id)
        ..write(':')
        ..write(e.dayOffset)
        ..write(':')
        ..write(e.time)
        ..write(':')
        ..write(e.title)
        ..write(':')
        ..write(e.brief.length)
        ..write(':')
        ..write(e.longText.length)
        ..write(':')
        ..write(e.mark)
        ..write(':')
        ..write(e.dialog.length)
        ..write(':')
        ..write(e.raw.length)
        ..write(':')
        ..write(_appStore.displaySpeakersSummary(e));
      if (_appStore.hasTurnOverridesFor([e])) {
        final turns = e.dialog.isNotEmpty ? e.dialog : e.raw;
        for (var i = 0; i < turns.length; i++) {
          buf
            ..write('/')
            ..write(_appStore.displayTurnSpeaker(e, i, turns[i].spk));
        }
      }
      buf.write(';');
    }
    buf.write('|');
    for (final s in _appStore.summaries) {
      if (s.state != SummaryState.done) continue;
      buf
        ..write(s.id)
        ..write(':')
        ..write(s.time)
        ..write(':')
        ..write(s.title ?? '')
        ..write(':')
        ..write(s.overview?.length ?? 0)
        ..write(':')
        ..write(s.points.length)
        ..write(':')
        ..write(s.todos.length)
        ..write(':')
        ..write(s.fullText.length)
        ..write(':')
        ..write(s.srcIds.join('+'))
        ..write(';');
    }
    buf.write('|');
    for (final p in _appStore.voiceprintStore.allPersons) {
      buf
        ..write(p.id)
        ..write(':')
        ..write(p.name)
        ..write(':')
        ..write(p.isSelf ? '1' : '0')
        ..write(',');
    }
    return buf.toString();
  }

  Future<void> _syncCorpusNow() async {
    final stamp = _computeStoreStamp();
    if (stamp == _lastStoreStamp) return;

    // 首次初始化且语料为空时无需为了同步空数组而提前拉起 Worker Isolate（避免拍照识别等路径被 Isolate 启动拖慢）
    if (_lastCorpusDigest.isEmpty && _hasNoIndexableContent()) {
      _lastStoreStamp = stamp;
      _lastCorpusDigest = '0|';
      return;
    }

    final docs = _collectDocuments();
    _lastStoreStamp = stamp;
    final digest =
        '${docs.length}|${docs.map((d) => '${d.id}:${d.dayOffset}:${d.timestampMs}:${d.speakers}:${d.body.length}:${d.summary.length}').join(',')}';
    if (digest == _lastCorpusDigest) return;
    _lastCorpusDigest = digest;
    try {
      await _worker.syncCorpus(docs);
    } on Object {
      // 忽略释放竞态
    }
  }

  List<AgentDocument> _collectDocuments() {
    debugCollectDocumentsCount += 1;
    final now = _clock();
    final eventsById = <String, RecordEvent>{
      for (final e in _appStore.events) e.id: e,
    };
    final out = <AgentDocument>[];

    for (final e in _appStore.events) {
      if (e.live) continue;
      final turns = e.dialog.isNotEmpty ? e.dialog : e.raw;
      final markText = e.mark.trim();
      final dialogBody = turns.isNotEmpty
          ? [
              for (var i = 0; i < turns.length; i++)
                '${_appStore.displayTurnSpeaker(e, i, turns[i].spk)}：${turns[i].text}',
            ].join('\n')
          : e.longText;
      final bodyParts = <String>[
        if (markText.isNotEmpty) '重点标记：$markText',
        if (dialogBody.trim().isNotEmpty) dialogBody.trim(),
      ];
      final sumParts = <String>[
        if (markText.isNotEmpty) '重点标记：$markText',
        if (e.brief.trim().isNotEmpty) e.brief.trim(),
      ];
      final spks = _appStore.displaySpeakersSummary(e);
      out.add(
        AgentDocument(
          id: e.id,
          kind: 'record',
          title: e.title,
          timeLabel: '${_dayText(e.dayOffset)} ${e.time}'.trim(),
          dayOffset: e.dayOffset,
          timestampMs: _computeTimestampMs(now, e.dayOffset, e.time),
          speakers: spks,
          summary: sumParts.join(' · '),
          body: bodyParts.join('\n'),
        ),
      );
    }

    for (final s in _appStore.summaries) {
      if (s.state != SummaryState.done) continue;
      final sumDay = _summaryDayOffset(s, eventsById);
      final sumSpeakers = _summarySpeakers(s, eventsById);
      final pts = [
        for (final p in s.points) '${p.title}：${p.detail}',
      ].join('\n');
      out.add(
        AgentDocument(
          id: s.id,
          kind: 'summary',
          title: s.title ?? '要点总结',
          timeLabel: '${_dayText(sumDay)} ${s.time}'.trim(),
          dayOffset: sumDay,
          timestampMs: _computeTimestampMs(now, sumDay, s.time) + 1,
          speakers: sumSpeakers,
          summary: s.overview ?? '',
          body: [
            if ((s.overview ?? '').isNotEmpty) s.overview!,
            if (pts.isNotEmpty) pts,
            if (s.fullText.trim().isNotEmpty) s.fullText.trim(),
          ].join('\n\n'),
          todos: s.todos,
        ),
      );
    }
    return out;
  }

  int _summaryDayOffset(
    SummaryCard summary,
    Map<String, RecordEvent> eventsById,
  ) {
    var best = 1 << 30;
    for (final id in summary.srcIds) {
      final ev = eventsById[id];
      if (ev != null && ev.dayOffset < best) best = ev.dayOffset;
    }
    return best == 1 << 30 ? 0 : best;
  }

  String _summarySpeakers(
    SummaryCard summary,
    Map<String, RecordEvent> eventsById,
  ) {
    final names = <String>{};
    for (final id in summary.srcIds) {
      final ev = eventsById[id];
      if (ev == null) continue;
      final raw = _appStore.displaySpeakersSummary(ev);
      for (final part in raw.split('/')) {
        final t = part.trim();
        if (t.isNotEmpty && t != '未区分' && t != '无语音') {
          names.add(t);
        }
      }
    }
    return names.join(' / ');
  }

  static int _computeTimestampMs(DateTime now, int dayOffset, String hhmm) {
    final mins = parseClockMinutes(hhmm) ?? 0;
    final h = mins ~/ 60;
    final m = mins % 60;
    return DateTime(
      now.year,
      now.month,
      now.day - dayOffset,
      h,
      m,
    ).millisecondsSinceEpoch;
  }

  static String _dayText(int offset) => switch (offset) {
    0 => '今天',
    1 => '昨天',
    2 => '前天',
    _ => '$offset天前',
  };

  @override
  void dispose() {
    _disposed = true;
    _corpusDebounce?.cancel();
    _appStore.removeListener(_scheduleCorpusSync);
    _agentConfig.removeListener(_onConfigChanged);
    unawaited(_speechSub?.cancel());
    if (_ownsSpeech) _speech.dispose();
    if (_ownsWorker) unawaited(_worker.dispose());
    super.dispose();
  }
}
