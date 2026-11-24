/// OS1 后台 Worker Isolate 极简 Pi Agent Harness。
///
/// 设计哲学（借鉴 pi_agent_rust / ZeroClaw）：
/// - 检索索引（中文 bigram + 实义单字 + IDF）、SKILL.md 渐进加载、联网抓取解析、HTTP MCP、
///   上下文压缩与 session.jsonl 落盘全部运行在独立后台 Isolate，UI 主线程零阻塞；
/// - 模型请求、健康 SQLite 查询、配置变更通过端口桥回主 Isolate 复用现有 `ModelGateway`
///   （保留 OAuth Keychain 与 401 自动刷新）、`HealthSignalStore` 与 `AgentConfigStore`；
/// - 完全模型无关的 ReAct JSON 协议 + 纯自然语言强容错，最多 5 轮工具调用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../analysis/chat_completion.dart';
import 'agent_models.dart';
import 'mcp_client.dart';
import 'record_search_index.dart';
import 'skill_store.dart';
import 'web_search_client.dart';

typedef AgentCompleteFn = Future<String> Function(
  List<ChatMessage> messages, {
  required String model,
  double temperature,
  int maxTokens,
});

typedef AgentHealthQueryFn = Future<String> Function(Map<String, dynamic> args);

typedef AgentConfigPatchFn = Future<String> Function(Map<String, dynamic> patch);

typedef AgentRefreshSkillsFn = Future<void> Function();

class AgentTurnResult {
  const AgentTurnResult({
    required this.reply,
    this.reaction,
    this.error,
  });

  final String reply;
  final String? reaction;
  final String? error;
}

class AgentHarnessWorker {
  AgentHarnessWorker({
    required AgentCompleteFn complete,
    AgentHealthQueryFn? queryHealth,
    AgentConfigPatchFn? patchConfig,
    WebSearchClient? webSearchOverride,
    AgentMcpClient? mcpOverride,
    DateTime Function()? clock,
    bool inProcess = false,
  }) : _complete = complete,
       _queryHealth = queryHealth,
       _patchConfig = patchConfig,
       _webSearchOverride = webSearchOverride,
       _mcpOverride = mcpOverride,
       _clock = clock,
       _inProcess = inProcess;

  final AgentCompleteFn _complete;
  final AgentHealthQueryFn? _queryHealth;
  final AgentConfigPatchFn? _patchConfig;
  final WebSearchClient? _webSearchOverride;
  final AgentMcpClient? _mcpOverride;
  final DateTime Function()? _clock;
  final bool _inProcess;

  Isolate? _isolate;
  SendPort? _commandPort;
  ReceivePort? _responses;
  StreamSubscription<Object?>? _sub;
  Future<void>? _spawning;
  int _nextReqId = 1;
  bool _disposed = false;

  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<int, void Function(String reaction)> _reactionListeners = {};

  /// 若注入了测试用 Mock HTTP 客户端或显式指定 `inProcess`，则在当前 Isolate 异步运行；
  /// 生产路径默认 100% 运行在独立后台 Worker Isolate。
  _WorkerEngine? _inProcessFallback;

  bool get _useInProcess =>
      _inProcess || _webSearchOverride != null || _mcpOverride != null;

  Future<void> _ensureStarted() async {
    if (_disposed) throw StateError('AgentHarnessWorker已释放');
    if (_useInProcess) {
      _inProcessFallback ??= _WorkerEngine(
        complete: _complete,
        queryHealth: _queryHealth,
        patchConfig: _patchConfig,
        webSearch: _webSearchOverride,
        mcpClient: _mcpOverride,
        clock: _clock,
      );
      return;
    }
    if (_commandPort != null) return;
    if (_spawning != null) return _spawning;

    final ready = Completer<void>();
    _spawning = ready.future;
    final responses = ReceivePort();
    _responses = responses;

    try {
      final handshake = Completer<SendPort>();
      _sub = responses.listen((msg) {
        if (msg is! Map) return;
        final map = Map<String, dynamic>.from(msg);
        final type = '${map['type'] ?? ''}';
        if (type == 'ready' && !handshake.isCompleted) {
          final port = map['port'];
          if (port is SendPort) handshake.complete(port);
          return;
        }
        if (type == 'reaction') {
          final id = (map['id'] as num?)?.toInt() ?? 0;
          final react = '${map['reaction'] ?? ''}'.trim();
          if (react.isNotEmpty) {
            _reactionListeners[id]?.call(react);
          }
          return;
        }
        if (type == 'host_call') {
          unawaited(_handleHostCall(map));
          return;
        }
        if (type == 'reply') {
          final id = (map['id'] as num?)?.toInt() ?? 0;
          final completer = _pending.remove(id);
          _reactionListeners.remove(id);
          if (completer != null && !completer.isCompleted) {
            completer.complete(map);
          }
        }
      });

      _isolate = await Isolate.spawn(
        _workerIsolateEntry,
        responses.sendPort,
        debugName: 'os1-agent-harness',
      );
      _commandPort = await handshake.future.timeout(const Duration(seconds: 5));
      ready.complete();
    } catch (e, st) {
      await _resetIsolate();
      if (!ready.isCompleted) ready.completeError(e, st);
      rethrow;
    } finally {
      _spawning = null;
    }
  }

  Future<void> _handleHostCall(Map<String, dynamic> msg) async {
    final callId = (msg['callId'] as num?)?.toInt() ?? 0;
    final op = '${msg['op'] ?? ''}';
    final payload = msg['payload'] is Map
        ? Map<String, dynamic>.from(msg['payload'] as Map)
        : <String, dynamic>{};
    final replyPort = _commandPort;
    if (replyPort == null) return;

    try {
      Object? result;
      switch (op) {
        case 'complete':
          final rawMsgs = payload['messages'] as List? ?? const [];
          final messages = [
            for (final m in rawMsgs)
              if (m is Map)
                ChatMessage(
                  role: '${m['role'] ?? 'user'}',
                  content: '${m['content'] ?? ''}',
                ),
          ];
          result = await _complete(
            messages,
            model: '${payload['model'] ?? ''}',
            temperature: (payload['temperature'] as num?)?.toDouble() ?? 0.3,
            maxTokens: (payload['maxTokens'] as num?)?.toInt() ?? 2048,
          );
        case 'health':
          final fn = _queryHealth;
          result = fn == null
              ? jsonEncode({'ok': false, 'reason': '本机健康查询服务未挂载'})
              : await fn(payload);
        case 'config_patch':
          final fn = _patchConfig;
          result = fn == null
              ? jsonEncode({'ok': false, 'reason': '配置修改通道未挂载'})
              : await fn(payload);
        default:
          throw UnsupportedError('未知宿主能力调用：$op');
      }
      replyPort.send({
        'type': 'host_reply',
        'callId': callId,
        'ok': true,
        'result': result,
      });
    } on Object catch (e) {
      replyPort.send({
        'type': 'host_reply',
        'callId': callId,
        'ok': false,
        'error': '$e',
      });
    }
  }

  Future<Map<String, dynamic>> _sendCommand(
    String op,
    Map<String, dynamic> payload, {
    void Function(String reaction)? onReaction,
  }) async {
    await _ensureStarted();
    final port = _commandPort;
    if (port == null) throw StateError('Worker 端口未就绪');
    final id = _nextReqId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    if (onReaction != null) {
      _reactionListeners[id] = onReaction;
    }
    port.send({'type': 'cmd', 'id': id, 'op': op, 'payload': payload});
    return completer.future;
  }

  Future<void> syncCorpus(List<AgentDocument> docs) async {
    if (_disposed) return;
    await _ensureStarted();
    if (_useInProcess) {
      _inProcessFallback!.syncCorpus(docs);
      return;
    }
    await _sendCommand('sync_corpus', {
      'docs': [for (final d in docs) d.toJson()],
    });
  }

  Future<List<AgentChatMessage>> loadSession(String agentDirPath) async {
    if (_disposed || agentDirPath.trim().isEmpty) return const [];
    await _ensureStarted();
    if (_useInProcess) {
      return _inProcessFallback!.loadSession(agentDirPath);
    }
    final res = await _sendCommand('load_session', {'dir': agentDirPath});
    final list = res['messages'] as List? ?? const [];
    return [
      for (final m in list)
        if (m is Map) AgentChatMessage.fromJson(Map<String, dynamic>.from(m)),
    ];
  }

  Future<List<AgentChatSession>> listSessions(String agentDirPath) async {
    if (_disposed || agentDirPath.trim().isEmpty) return const [];
    await _ensureStarted();
    if (_useInProcess) {
      return _inProcessFallback!.listSessions(agentDirPath);
    }
    final res = await _sendCommand('list_sessions', {'dir': agentDirPath});
    final list = res['sessions'] as List? ?? const [];
    return [
      for (final s in list)
        if (s is Map) AgentChatSession.fromJson(Map<String, dynamic>.from(s)),
    ];
  }

  Future<AgentSessionPage> loadSessionPage(
    String agentDirPath, {
    required String sessionId,
    int? beforeIndex,
    int limit = 20,
  }) async {
    if (_disposed || agentDirPath.trim().isEmpty) {
      return AgentSessionPage(
        sessionId: sessionId,
        messages: const [],
        totalCount: 0,
        startIndex: 0,
      );
    }
    await _ensureStarted();
    if (_useInProcess) {
      return _inProcessFallback!.loadSessionPage(
        agentDirPath,
        sessionId: sessionId,
        beforeIndex: beforeIndex,
        limit: limit,
      );
    }
    final res = await _sendCommand('load_session_page', {
      'dir': agentDirPath,
      'sessionId': sessionId,
      'beforeIndex': ?beforeIndex,
      'limit': limit,
    });
    final list = res['messages'] as List? ?? const [];
    return AgentSessionPage(
      sessionId: '${res['sessionId'] ?? sessionId}',
      messages: [
        for (final m in list)
          if (m is Map) AgentChatMessage.fromJson(Map<String, dynamic>.from(m)),
      ],
      totalCount: (res['totalCount'] as num?)?.toInt() ?? 0,
      startIndex: (res['startIndex'] as num?)?.toInt() ?? 0,
    );
  }

  Future<AgentChatSession?> appendSessionMessages(
    String agentDirPath, {
    required String sessionId,
    required List<AgentChatMessage> messages,
  }) async {
    if (_disposed || agentDirPath.trim().isEmpty || messages.isEmpty) {
      return null;
    }
    await _ensureStarted();
    if (_useInProcess) {
      return _inProcessFallback!.appendSessionMessages(
        agentDirPath,
        sessionId: sessionId,
        messages: messages,
      );
    }
    final res = await _sendCommand('append_session_messages', {
      'dir': agentDirPath,
      'sessionId': sessionId,
      'messages': [for (final m in messages) m.toJson()],
    });
    final raw = res['session'];
    if (raw is Map) {
      return AgentChatSession.fromJson(Map<String, dynamic>.from(raw));
    }
    return null;
  }

  Future<void> deleteSession(String agentDirPath, String sessionId) async {
    if (_disposed || agentDirPath.trim().isEmpty) return;
    await _ensureStarted();
    if (_useInProcess) {
      await _inProcessFallback!.deleteSession(agentDirPath, sessionId);
      return;
    }
    await _sendCommand('delete_session', {
      'dir': agentDirPath,
      'sessionId': sessionId,
    });
  }

  Future<void> clearSession(String agentDirPath, {String? sessionId}) async {
    if (_disposed) return;
    await _ensureStarted();
    if (_useInProcess) {
      await _inProcessFallback!.clearSession(
        agentDirPath,
        sessionId: sessionId,
      );
      return;
    }
    await _sendCommand('clear_session', {
      'dir': agentDirPath,
      'sessionId': ?sessionId,
    });
  }

  Future<AgentTurnResult> runTurn({
    required String userText,
    required List<AgentChatMessage> history,
    required AgentConfigSnapshot config,
    String? sessionId,
    String? userMsgId,
    int? userCreatedAtMs,
    bool viaVoice = false,
    int? nowMs,
    void Function(String reaction)? onReaction,
  }) async {
    await _ensureStarted();
    final effectiveNowMs =
        nowMs ?? (_clock ?? DateTime.now)().millisecondsSinceEpoch;
    if (_useInProcess) {
      return _inProcessFallback!.runTurn(
        userText: userText,
        history: history,
        config: config,
        sessionId: sessionId,
        userMsgId: userMsgId,
        userCreatedAtMs: userCreatedAtMs,
        viaVoice: viaVoice,
        nowMs: effectiveNowMs,
        onReaction: onReaction,
      );
    }
    final res = await _sendCommand(
      'run_turn',
      {
        'text': userText,
        'viaVoice': viaVoice,
        'sessionId': ?sessionId,
        'userMsgId': ?userMsgId,
        'userCreatedAtMs': ?userCreatedAtMs,
        'nowMs': effectiveNowMs,
        'history': [for (final m in history) m.toJson()],
        'config': config.toJson(),
      },
      onReaction: onReaction,
    );
    if (res['ok'] != true) {
      return AgentTurnResult(
        reply: '',
        error: '${res['error'] ?? '助手请求未完成'}',
      );
    }
    return AgentTurnResult(
      reply: '${res['reply'] ?? ''}',
      reaction: res['reaction'] as String?,
    );
  }

  Future<void> _resetIsolate() async {
    await _sub?.cancel();
    _sub = null;
    _responses?.close();
    _responses = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commandPort = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('Worker Isolate 已重置'));
      }
    }
    _pending.clear();
    _reactionListeners.clear();
  }

  /// App 进入后台时挂起 Worker Isolate 释放检索索引内存，不标记 [_disposed]，
  /// 下次前台会话按需自动重建。
  Future<void> suspendForBackground() async {
    if (_disposed || _pending.isNotEmpty || _spawning != null) return;
    _inProcessFallback?.close();
    _inProcessFallback = null;
    if (_isolate != null || _commandPort != null) {
      await _resetIsolate();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _inProcessFallback?.close();
    _inProcessFallback = null;
    await _resetIsolate();
  }

  /// 对语音播报文本做零 Markdown 净化，确保系统 TTS 朗读丝滑自然。
  static String cleanVoiceReplyText(String raw) =>
      _WorkerEngine._sanitizeReply(raw, viaVoice: true);
}

void _workerIsolateEntry(SendPort mainPort) {
  final incoming = ReceivePort();
  mainPort.send({'type': 'ready', 'port': incoming.sendPort});

  final hostPending = <int, Completer<Object?>>{};
  var nextCallId = 1;

  Future<Object?> callHost(String op, Map<String, dynamic> payload) {
    final callId = nextCallId++;
    final completer = Completer<Object?>();
    hostPending[callId] = completer;
    mainPort.send({
      'type': 'host_call',
      'callId': callId,
      'op': op,
      'payload': payload,
    });
    return completer.future;
  }

  final engine = _WorkerEngine(
    complete: (
      messages, {
      required model,
      temperature = 0.3,
      maxTokens = 2048,
    }) async {
      final res = await callHost('complete', {
        'messages': [for (final m in messages) m.toJson()],
        'model': model,
        'temperature': temperature,
        'maxTokens': maxTokens,
      });
      return '${res ?? ''}';
    },
    queryHealth: (args) async {
      final res = await callHost('health', args);
      return '${res ?? '{}'}';
    },
    patchConfig: (patch) async {
      final res = await callHost('config_patch', patch);
      return '${res ?? '{}'}';
    },
  );

  incoming.listen((raw) async {
    if (raw is! Map) return;
    final msg = Map<String, dynamic>.from(raw);
    final type = '${msg['type'] ?? ''}';
    if (type == 'host_reply') {
      final callId = (msg['callId'] as num?)?.toInt() ?? 0;
      final c = hostPending.remove(callId);
      if (c == null || c.isCompleted) return;
      if (msg['ok'] == true) {
        c.complete(msg['result']);
      } else {
        c.completeError(StateError('${msg['error'] ?? '宿主调用失败'}'));
      }
      return;
    }
    if (type != 'cmd') return;
    final id = (msg['id'] as num?)?.toInt() ?? 0;
    final op = '${msg['op'] ?? ''}';
    final payload = msg['payload'] is Map
        ? Map<String, dynamic>.from(msg['payload'] as Map)
        : <String, dynamic>{};

    try {
      switch (op) {
        case 'sync_corpus':
          final rawDocs = payload['docs'] as List? ?? const [];
          engine.syncCorpus([
            for (final d in rawDocs)
              if (d is Map)
                AgentDocument.fromJson(Map<String, dynamic>.from(d)),
          ]);
          mainPort.send({'type': 'reply', 'id': id, 'ok': true});
        case 'load_session':
          final loaded = await engine.loadSession('${payload['dir'] ?? ''}');
          mainPort.send({
            'type': 'reply',
            'id': id,
            'ok': true,
            'messages': [for (final m in loaded) m.toJson()],
          });
        case 'list_sessions':
          final list = await engine.listSessions('${payload['dir'] ?? ''}');
          mainPort.send({
            'type': 'reply',
            'id': id,
            'ok': true,
            'sessions': [for (final s in list) s.toJson()],
          });
        case 'load_session_page':
          final page = await engine.loadSessionPage(
            '${payload['dir'] ?? ''}',
            sessionId: '${payload['sessionId'] ?? ''}',
            beforeIndex: (payload['beforeIndex'] as num?)?.toInt(),
            limit: (payload['limit'] as num?)?.toInt() ?? 20,
          );
          mainPort.send({
            'type': 'reply',
            'id': id,
            'ok': true,
            'sessionId': page.sessionId,
            'totalCount': page.totalCount,
            'startIndex': page.startIndex,
            'messages': [for (final m in page.messages) m.toJson()],
          });
        case 'append_session_messages':
          final rawMsgs = payload['messages'] as List? ?? const [];
          final session = await engine.appendSessionMessages(
            '${payload['dir'] ?? ''}',
            sessionId: '${payload['sessionId'] ?? ''}',
            messages: [
              for (final m in rawMsgs)
                if (m is Map)
                  AgentChatMessage.fromJson(Map<String, dynamic>.from(m)),
            ],
          );
          mainPort.send({
            'type': 'reply',
            'id': id,
            'ok': true,
            if (session != null) 'session': session.toJson(),
          });
        case 'delete_session':
          await engine.deleteSession(
            '${payload['dir'] ?? ''}',
            '${payload['sessionId'] ?? ''}',
          );
          mainPort.send({'type': 'reply', 'id': id, 'ok': true});
        case 'clear_session':
          await engine.clearSession(
            '${payload['dir'] ?? ''}',
            sessionId: payload['sessionId'] as String?,
          );
          mainPort.send({'type': 'reply', 'id': id, 'ok': true});
        case 'run_turn':
          final cfgMap = payload['config'] is Map
              ? Map<String, dynamic>.from(payload['config'] as Map)
              : <String, dynamic>{};
          final rawHist = payload['history'] as List? ?? const [];
          final res = await engine.runTurn(
            userText: '${payload['text'] ?? ''}',
            sessionId: payload['sessionId'] as String?,
            userMsgId: payload['userMsgId'] as String?,
            userCreatedAtMs: (payload['userCreatedAtMs'] as num?)?.toInt(),
            viaVoice: payload['viaVoice'] == true,
            nowMs: (payload['nowMs'] as num?)?.toInt(),
            history: [
              for (final m in rawHist)
                if (m is Map)
                  AgentChatMessage.fromJson(Map<String, dynamic>.from(m)),
            ],
            config: AgentConfigSnapshot.fromJson(cfgMap),
            onReaction: (react) {
              mainPort.send({'type': 'reaction', 'id': id, 'reaction': react});
            },
          );
          if (res.error != null) {
            mainPort.send({
              'type': 'reply',
              'id': id,
              'ok': false,
              'error': res.error,
            });
          } else {
            mainPort.send({
              'type': 'reply',
              'id': id,
              'ok': true,
              'reply': res.reply,
              if (res.reaction != null) 'reaction': res.reaction,
            });
          }
        default:
          mainPort.send({
            'type': 'reply',
            'id': id,
            'ok': false,
            'error': '未知指令：$op',
          });
      }
    } on Object catch (e) {
      mainPort.send({
        'type': 'reply',
        'id': id,
        'ok': false,
        'error': '$e',
      });
    }
  });
}

class _WorkerEngine {
  _WorkerEngine({
    required AgentCompleteFn complete,
    AgentHealthQueryFn? queryHealth,
    AgentConfigPatchFn? patchConfig,
    WebSearchClient? webSearch,
    AgentMcpClient? mcpClient,
    DateTime Function()? clock,
  }) : _complete = complete,
       _queryHealth = queryHealth,
       _patchConfig = patchConfig,
       _webSearch = webSearch ?? WebSearchClient(),
       _mcpClient = mcpClient ?? AgentMcpClient(),
       _clock = clock ?? DateTime.now;

  final AgentCompleteFn _complete;
  final AgentHealthQueryFn? _queryHealth;
  final AgentConfigPatchFn? _patchConfig;
  final WebSearchClient _webSearch;
  final AgentMcpClient _mcpClient;
  final DateTime Function() _clock;
  final RecordSearchIndex _index = RecordSearchIndex();
  final Map<String, Future<void>> _sessionQueue = {};

  static const int _maxSteps = 5;
  static const int _maxContextChars = 14000;
  static const int _detailPageChars = 4000;

  void syncCorpus(List<AgentDocument> docs) {
    _index.replaceCorpus(docs);
  }

  Future<T> _serialized<T>(String dirPath, Future<T> Function() fn) {
    final prev = _sessionQueue[dirPath] ?? Future<void>.value();
    final next = prev.catchError((Object _) {}).then((_) => fn());
    _sessionQueue[dirPath] = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  String? _sanitizeSessionId(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        trimmed.contains('..') ||
        trimmed.contains('/') ||
        trimmed.contains(r'\')) {
      return null;
    }
    final safe = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return safe.isEmpty ? null : safe;
  }

  File? _legacySessionFile(String dirPath) {
    if (dirPath.trim().isEmpty) return null;
    return File(p.join(dirPath, 'session.jsonl'));
  }

  Directory? _sessionsDir(String dirPath) {
    if (dirPath.trim().isEmpty) return null;
    return Directory(p.join(dirPath, 'sessions'));
  }

  File? _indexFile(String dirPath) {
    final dir = _sessionsDir(dirPath);
    if (dir == null) return null;
    return File(p.join(dir.path, 'index.json'));
  }

  File? _sessionFile(String dirPath, String sessionId) {
    final dir = _sessionsDir(dirPath);
    final safeId = _sanitizeSessionId(sessionId);
    if (dir == null || safeId == null) return null;
    return File(p.join(dir.path, '$safeId.jsonl'));
  }

  static int _compareSessionsDesc(AgentChatSession a, AgentChatSession b) {
    final byUpd = b.updatedAtMs.compareTo(a.updatedAtMs);
    if (byUpd != 0) return byUpd;
    return b.createdAtMs.compareTo(a.createdAtMs);
  }

  Future<List<AgentChatMessage>> _readJsonlFile(File file) async {
    if (!await file.exists()) return const [];
    final out = <AgentChatMessage>[];
    final lines = await file.readAsLines();
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map) {
          out.add(AgentChatMessage.fromJson(Map<String, dynamic>.from(decoded)));
        }
      } on Object {
        // 单行损坏跳过，不破坏其余历史
      }
    }
    return out;
  }

  AgentChatSession _buildSessionMeta(
    String id,
    List<AgentChatMessage> msgs, {
    AgentChatSession? existing,
  }) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var firstTs = 0;
    var lastTs = 0;
    for (final m in msgs) {
      if (m.createdAtMs > 0) {
        if (firstTs == 0) firstTs = m.createdAtMs;
        if (m.createdAtMs > lastTs) lastTs = m.createdAtMs;
      }
    }
    final created = (existing != null && existing.createdAtMs > 0)
        ? existing.createdAtMs
        : (firstTs > 0 ? firstTs : nowMs);
    var updated = lastTs > 0 ? lastTs : nowMs;
    if (existing != null && existing.updatedAtMs > updated) {
      updated = existing.updatedAtMs;
    }
    final existingTitle = existing?.title.trim() ?? '';
    final title = (existingTitle.isNotEmpty && existingTitle != '新对话')
        ? existingTitle
        : AgentChatSession.deriveTitle(msgs);
    final derivedPreview = AgentChatSession.derivePreview(msgs);
    final preview = derivedPreview.isNotEmpty
        ? derivedPreview
        : (existing?.preview ?? '');
    return AgentChatSession(
      id: id,
      title: title,
      preview: preview,
      createdAtMs: created,
      updatedAtMs: updated,
      messageCount: (existing?.messageCount ?? 0) + msgs.length,
    );
  }

  Future<List<AgentChatSession>?> _tryReadIndexRaw(String dirPath) async {
    final idxFile = _indexFile(dirPath);
    if (idxFile == null || !await idxFile.exists()) return null;
    try {
      final decoded = jsonDecode(await idxFile.readAsString());
      final rawList = decoded is Map ? decoded['sessions'] : decoded;
      if (rawList is! List) return null;
      final out = <AgentChatSession>[];
      for (final item in rawList) {
        if (item is Map) {
          final s = AgentChatSession.fromJson(Map<String, dynamic>.from(item));
          if (s.id.isNotEmpty) out.add(s);
        }
      }
      out.sort(_compareSessionsDesc);
      return out;
    } on Object {
      return null;
    }
  }

  Future<void> _writeIndexFile(
    String dirPath,
    List<AgentChatSession> sessions,
  ) async {
    final idxFile = _indexFile(dirPath);
    if (idxFile == null) return;
    await idxFile.parent.create(recursive: true);
    final sorted = List<AgentChatSession>.of(sessions)
      ..sort(_compareSessionsDesc);
    await idxFile.writeAsString(
      jsonEncode({
        'version': 1,
        'sessions': [for (final s in sorted) s.toJson()],
      }),
      flush: true,
    );
  }

  Future<List<AgentChatSession>> _rebuildIndexFromDisk(String dirPath) async {
    final dir = _sessionsDir(dirPath);
    if (dir == null || !await dir.exists()) return <AgentChatSession>[];
    final out = <AgentChatSession>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      final id = p.basenameWithoutExtension(entity.path);
      if (id.isEmpty) continue;
      final msgs = await _readJsonlFile(entity);
      if (msgs.isEmpty) continue;
      out.add(_buildSessionMeta(id, msgs));
    }
    out.sort(_compareSessionsDesc);
    await _writeIndexFile(dirPath, out);
    return out;
  }

  Future<void> _migrateLegacyIfNeeded(String dirPath) async {
    final legacy = _legacySessionFile(dirPath);
    if (legacy == null || !await legacy.exists()) return;
    final msgs = await _readJsonlFile(legacy);
    if (msgs.isEmpty) {
      await legacy.delete();
      return;
    }
    final firstTs = msgs.first.createdAtMs;
    final fallbackMs = DateTime.now().millisecondsSinceEpoch;
    final baseId = 's-${firstTs > 0 ? firstTs : fallbackMs}-legacy';
    var targetId = baseId;
    var suffix = 1;
    while (await _sessionFile(dirPath, targetId)!.exists()) {
      targetId = '$baseId-${suffix++}';
    }
    final targetFile = _sessionFile(dirPath, targetId)!;
    await targetFile.parent.create(recursive: true);
    final buf = StringBuffer();
    for (final m in msgs) {
      buf.writeln(jsonEncode(m.toJson()));
    }
    await targetFile.writeAsString(buf.toString(), flush: true);

    final existingIdx = await _tryReadIndexRaw(dirPath);
    if (existingIdx != null) {
      final next = List<AgentChatSession>.of(existingIdx)
        ..add(_buildSessionMeta(targetId, msgs));
      await _writeIndexFile(dirPath, next);
    } else {
      await _rebuildIndexFromDisk(dirPath);
    }
    await legacy.delete();
  }

  Future<List<AgentChatSession>> _readOrRebuildIndex(String dirPath) async {
    await _migrateLegacyIfNeeded(dirPath);
    final existing = await _tryReadIndexRaw(dirPath);
    if (existing != null) return existing;
    return _rebuildIndexFromDisk(dirPath);
  }

  Future<List<AgentChatSession>> listSessions(String dirPath) async {
    if (dirPath.trim().isEmpty) return const [];
    return _serialized(dirPath, () => _readOrRebuildIndex(dirPath));
  }

  Future<AgentSessionPage> loadSessionPage(
    String dirPath, {
    required String sessionId,
    int? beforeIndex,
    int limit = 20,
  }) async {
    if (dirPath.trim().isEmpty) {
      return AgentSessionPage(
        sessionId: sessionId,
        messages: const [],
        totalCount: 0,
        startIndex: 0,
      );
    }
    return _serialized(dirPath, () async {
      await _migrateLegacyIfNeeded(dirPath);
      final safeId = _sanitizeSessionId(sessionId);
      if (safeId == null) {
        return AgentSessionPage(
          sessionId: sessionId,
          messages: const [],
          totalCount: 0,
          startIndex: 0,
        );
      }
      final file = _sessionFile(dirPath, safeId);
      final all = file == null
          ? const <AgentChatMessage>[]
          : await _readJsonlFile(file);
      final total = all.length;
      final effectiveLimit = limit < 1 ? 20 : limit;
      final end = beforeIndex == null ? total : beforeIndex.clamp(0, total);
      final start = (end - effectiveLimit).clamp(0, end);
      return AgentSessionPage(
        sessionId: safeId,
        messages: all.sublist(start, end),
        totalCount: total,
        startIndex: start,
      );
    });
  }

  Future<AgentChatSession?> appendSessionMessages(
    String dirPath, {
    required String sessionId,
    required List<AgentChatMessage> messages,
  }) async {
    if (dirPath.trim().isEmpty || messages.isEmpty) return null;
    final safeId = _sanitizeSessionId(sessionId);
    if (safeId == null) return null;
    return _serialized(dirPath, () async {
      final list = List<AgentChatSession>.of(
        await _readOrRebuildIndex(dirPath),
      );
      final file = _sessionFile(dirPath, safeId)!;
      final existingIdx = list.indexWhere((s) => s.id == safeId);
      AgentChatSession? existing =
          existingIdx >= 0 ? list[existingIdx] : null;
      if (existing == null && await file.exists()) {
        final prevMsgs = await _readJsonlFile(file);
        if (prevMsgs.isNotEmpty) {
          existing = _buildSessionMeta(safeId, prevMsgs);
        }
      }
      await file.parent.create(recursive: true);
      final buf = StringBuffer();
      for (final m in messages) {
        buf.writeln(jsonEncode(m.toJson()));
      }
      await file.writeAsString(
        buf.toString(),
        mode: FileMode.append,
        flush: true,
      );
      final updated = _buildSessionMeta(safeId, messages, existing: existing);
      if (existingIdx >= 0) {
        list[existingIdx] = updated;
      } else {
        list.add(updated);
      }
      await _writeIndexFile(dirPath, list);
      return updated;
    });
  }

  Future<void> deleteSession(String dirPath, String sessionId) async {
    if (dirPath.trim().isEmpty) return;
    final safeId = _sanitizeSessionId(sessionId);
    if (safeId == null) return;
    await _serialized(dirPath, () async {
      final list = List<AgentChatSession>.of(
        await _readOrRebuildIndex(dirPath),
      );
      final file = _sessionFile(dirPath, safeId);
      if (file != null && await file.exists()) {
        await file.delete();
      }
      list.removeWhere((s) => s.id == safeId);
      await _writeIndexFile(dirPath, list);
    });
  }

  Future<List<AgentChatMessage>> loadSession(String dirPath) async {
    if (dirPath.trim().isEmpty) return const [];
    return _serialized(dirPath, () async {
      final list = await _readOrRebuildIndex(dirPath);
      if (list.isEmpty) return const [];
      final file = _sessionFile(dirPath, list.first.id);
      if (file == null) return const [];
      return _readJsonlFile(file);
    });
  }

  Future<void> clearSession(String dirPath, {String? sessionId}) async {
    if (dirPath.trim().isEmpty) return;
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      await deleteSession(dirPath, sessionId);
      return;
    }
    await _serialized(dirPath, () async {
      final legacy = _legacySessionFile(dirPath);
      if (legacy != null && await legacy.exists()) {
        await legacy.delete();
      }
      final dir = _sessionsDir(dirPath);
      if (dir != null && await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
  }

  static int _resolveAssistantTimestamp(int? userCreatedAtMs) {
    final replyNow = DateTime.now().millisecondsSinceEpoch;
    if (userCreatedAtMs != null &&
        userCreatedAtMs > 0 &&
        (replyNow < userCreatedAtMs || replyNow - userCreatedAtMs > 600000)) {
      return userCreatedAtMs + 1;
    }
    return replyNow;
  }

  Future<AgentTurnResult> runTurn({
    required String userText,
    required List<AgentChatMessage> history,
    required AgentConfigSnapshot config,
    String? sessionId,
    String? userMsgId,
    int? userCreatedAtMs,
    bool viaVoice = false,
    int? nowMs,
    void Function(String reaction)? onReaction,
  }) async {
    final cleanUser = userText.trim();
    if (cleanUser.isEmpty) {
      return const AgentTurnResult(reply: '', error: '请输入你想说的话');
    }

    final skillStore = AgentSkillStore(config.agentDirPath);
    await skillStore.ensureRoot();

    final turnNow = nowMs != null
        ? DateTime.fromMillisecondsSinceEpoch(nowMs)
        : _clock();
    final tsMs = turnNow.millisecondsSinceEpoch;
    final targetSessionId = _sanitizeSessionId(sessionId ?? '') ?? 's-$tsMs';
    final effectiveUserId = (userMsgId != null && userMsgId.trim().isNotEmpty)
        ? userMsgId.trim()
        : 'u-$tsMs';
    final effectiveUserAt =
        (userCreatedAtMs != null && userCreatedAtMs > 0)
            ? userCreatedAtMs
            : tsMs;
    final userMsg = AgentChatMessage(
      id: effectiveUserId,
      role: 'user',
      text: cleanUser,
      createdAtMs: effectiveUserAt,
      viaVoice: viaVoice,
    );

    final skills = await skillStore.listSkills();
    final mcpTools = await _discoverMcpTools(config);
    final systemPrompt = _buildSystemPrompt(
      config: config,
      skills: skills,
      mcpTools: mcpTools,
      now: turnNow,
      viaVoice: viaVoice,
    );

    final messages = <ChatMessage>[
      ChatMessage.system(systemPrompt),
      ..._recentHistoryMessages(history),
      ChatMessage.user(cleanUser),
    ];

    String? firstReaction;
    try {
      for (var step = 0; step < _maxSteps; step++) {
        final compacted = _compactMessages(messages);
        final raw = await _complete(
          compacted,
          model: config.model,
          temperature: config.temperature,
          maxTokens: 2048,
        );
        final parsed = parseModelStep(raw);
        final react = parsed.reaction;
        if (firstReaction == null && react != null && react.isNotEmpty) {
          firstReaction = react;
          onReaction?.call(react);
        }

        if (parsed.toolCalls.isEmpty) {
          final finalReply = _sanitizeReply(
            parsed.reply.isNotEmpty ? parsed.reply : raw,
            viaVoice: viaVoice,
          );
          final reactedUser =
              (firstReaction != null && firstReaction.isNotEmpty)
                  ? userMsg.copyWith(reaction: firstReaction)
                  : userMsg;
          if (finalReply.isEmpty) {
            await appendSessionMessages(
              config.agentDirPath,
              sessionId: targetSessionId,
              messages: [reactedUser],
            );
            return AgentTurnResult(
              reply: '',
              reaction: firstReaction,
              error: '模型返回了空内容，请重试',
            );
          }
          final assistantAt = _resolveAssistantTimestamp(userCreatedAtMs);
          await appendSessionMessages(
            config.agentDirPath,
            sessionId: targetSessionId,
            messages: [
              reactedUser,
              AgentChatMessage(
                id: 'a-$assistantAt',
                role: 'assistant',
                text: finalReply,
                createdAtMs: assistantAt,
              ),
            ],
          );
          return AgentTurnResult(reply: finalReply, reaction: firstReaction);
        }

        messages.add(ChatMessage.assistant(raw));
        final results = <Map<String, dynamic>>[];
        for (final call in parsed.toolCalls.take(8)) {
          final output = await _executeTool(
            call.name,
            call.arguments,
            config: config,
            skillStore: skillStore,
            mcpTools: mcpTools,
            now: turnNow,
          );
          results.add({'tool': call.name, 'output': output});
        }
        messages.add(
          ChatMessage.user(
            '工具执行结果（仅作推理事实依据，不要向用户暴露工具名或JSON格式）：\n'
            '${jsonEncode(results)}\n'
            '请基于以上真实结果继续调用工具或直接输出最终 {"react": "...", "reply": "..."}。',
          ),
        );
      }

      // 超过最大轮数时做最后一次强制收口
      messages.add(
        const ChatMessage.user(
          '已获取上述信息，请不再调用工具，直接基于已有依据用 {"react": "...", "reply": "..."} 回答用户。',
        ),
      );
      final raw = await _complete(
        _compactMessages(messages),
        model: config.model,
        temperature: config.temperature,
        maxTokens: 2048,
      );
      final parsed = parseModelStep(raw);
      final finalReply = _sanitizeReply(
        parsed.reply.isNotEmpty ? parsed.reply : raw,
        viaVoice: viaVoice,
      );
      final finalReact = firstReaction ?? parsed.reaction;
      final reactedUser = (finalReact != null && finalReact.isNotEmpty)
          ? userMsg.copyWith(reaction: finalReact)
          : userMsg;
      if (finalReply.isEmpty) {
        await appendSessionMessages(
          config.agentDirPath,
          sessionId: targetSessionId,
          messages: [reactedUser],
        );
        return AgentTurnResult(
          reply: '',
          reaction: finalReact,
          error: '模型返回了空内容，请重试',
        );
      }
      final assistantAt = _resolveAssistantTimestamp(userCreatedAtMs);
      await appendSessionMessages(
        config.agentDirPath,
        sessionId: targetSessionId,
        messages: [
          reactedUser,
          AgentChatMessage(
            id: 'a-$assistantAt',
            role: 'assistant',
            text: finalReply,
            createdAtMs: assistantAt,
          ),
        ],
      );
      return AgentTurnResult(reply: finalReply, reaction: finalReact);
    } on Object catch (e) {
      try {
        final reactedUser =
            (firstReaction != null && firstReaction.isNotEmpty)
                ? userMsg.copyWith(reaction: firstReaction)
                : userMsg;
        await appendSessionMessages(
          config.agentDirPath,
          sessionId: targetSessionId,
          messages: [reactedUser],
        );
      } on Object {
        // 忽略落盘异常，保留原始错误返回
      }
      return AgentTurnResult(
        reply: '',
        reaction: firstReaction,
        error: '$e',
      );
    }
  }

  Future<List<AgentMcpToolSpec>> _discoverMcpTools(
    AgentConfigSnapshot config,
  ) async {
    if (config.activeMcps.isEmpty) return const [];
    final out = <AgentMcpToolSpec>[];
    for (final mcp in config.activeMcps) {
      try {
        final list = await _mcpClient.listTools(
          endpointId: mcp.id,
          endpointName: mcp.name,
          endpointUrl: mcp.url,
        );
        out.addAll(list);
      } on Object {
        // 单个外部 MCP 超时或不可用不影响其他工具
      }
    }
    return out;
  }

  String _buildSystemPrompt({
    required AgentConfigSnapshot config,
    required List<AgentSkillSummary> skills,
    required List<AgentMcpToolSpec> mcpTools,
    required DateTime now,
    required bool viaVoice,
  }) {
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final wd = weekdays[(now.weekday - 1).clamp(0, 6)];
    final nowText =
        '${now.year}-${_two(now.month)}-${_two(now.day)} $wd '
        '${_two(now.hour)}:${_two(now.minute)}';
    final buf = StringBuffer()
      ..writeln(config.agentPrompt)
      ..writeln()
      ..writeln('当前本机时间：$nowText')
      ..writeln('本地已索引记录与总结条数：${_index.length} 条');
    if (config.speakerLibrarySummary.isNotEmpty) {
      buf.writeln('已认识的声纹人物库：${config.speakerLibrarySummary}');
    }
    if (config.enabledSkillRules.isNotEmpty) {
      buf.writeln('\n已启用系统整理规则：');
      for (final r in config.enabledSkillRules) {
        buf.writeln('- $r');
      }
    }
    if (skills.isNotEmpty) {
      buf.writeln('\n本地技能库（SKILL.md 摘要，需要时可调用 read_skill 加载全文）：');
      for (final s in skills) {
        buf.writeln('- ${s.name}：${s.description}（路径 ${s.path}）');
      }
    }

    buf.writeln('\n你可以使用以下工具（未启用的能力不要编造结果）：');
    if (config.recordSearchEnabled) {
      buf.writeln(
        '- search_records(query?, speaker?, dayOffset?, minDayOffset?, maxDayOffset?, timeOfDay?, kind?, limit?)：检索历史录音转写与总结卡（kind 可选 record|summary；dayOffset 0=今天 1=昨天 2=前天，也可用 minDayOffset..maxDayOffset 查日期区间；timeOfDay 可选 morning|forenoon|noon|afternoon|evening）。',
      );
      buf.writeln(
        '- get_record_detail(id, offsetChars?)：查看指定录音或总结卡的完整对话正文与待办（单次返回最多 $_detailPageChars 字；若 hasMore=true，可传 offsetChars=nextOffsetChars 继续向后分页读取全文）。',
      );
    }
    if (config.healthAccessEnabled) {
      buf.writeln(
        '- query_health(type?, since_hours?, limit?)：查询本机已采集的健康指标（如 heart_rate、step_count、sleep_analysis、location 等）。',
      );
    }
    if (config.webSearchEnabled) {
      buf.writeln(
        '- web_search(query, limit?)：联网搜索最新公开资料、电影/事实/百科/天气/新闻等。',
      );
      buf.writeln('- web_fetch(url)：读取指定 https:// 网页的正文内容。');
    }
    buf.writeln(
      '- read_skill(name) / save_skill(name, description, body)：读取或沉淀本地 SKILL.md 技能，供未来对话持续复用。',
    );
    buf.writeln(
      '- read_file(path) / write_file(path, content)：读写 Agent 私有沙盒文件（如 notes/memo.md）。',
    );
    buf.writeln(
      '- get_agent_settings() / update_agent_settings(patch)：查看或动态调整自身参数（temperature、agentPrompt、webSearchEnabled、recordSearchEnabled、healthAccessEnabled、customMcp：{name,endpoint}）。',
    );
    for (final mt in mcpTools) {
      buf.writeln(
        '- mcp:${mt.endpointId}:${mt.name}（${mt.endpointName}）：${mt.description}',
      );
    }

    if (viaVoice) {
      buf.writeln('''
语音播报输出约束（当前通过硬件语音按键/通话触发，回复将由系统 TTS 直接朗读）：
- 用自然、口语化的简短中文直接给出答案（控制在 2～3 句短句内）；
- 若依据历史录音或总结回答，自然点明发生时间与来源记录标题；
- 严禁使用任何 Markdown 格式符号（零 *、零 #、零 -、零反引号与列表符号），全部用连贯短句表达。''');
    }

    buf.writeln('''
输出格式约定（严格遵守）：
1. 需要调用工具时，仅输出 JSON 对象：
   {"react": "简短中文微反应（如 👌 查一下）", "tool_calls": [{"name": "工具名", "arguments": {...}}]}
2. 已有足够依据可以直接回复用户时，仅输出 JSON 对象：
   {"react": "简短情绪/确认标签（2-8字，可带1个emoji）", "reply": "直接给用户看的自然回复"}
3. 若问题不需要查工具（例如日常问候或情绪回应），直接走第 2 条输出 reply。
4. 禁止在 reply 里输出“思考过程”“调用工具”等技术实现字样。''');
    return buf.toString();
  }

  Future<String> _executeTool(
    String name,
    Map<String, dynamic> args, {
    required AgentConfigSnapshot config,
    required AgentSkillStore skillStore,
    required List<AgentMcpToolSpec> mcpTools,
    required DateTime now,
  }) async {
    try {
      switch (name) {
        case 'search_records':
          if (!config.recordSearchEnabled) {
            return jsonEncode({'ok': false, 'reason': '用户已在设置中关闭历史记录检索权限'});
          }
          final hits = _index.search(
            query: args['query'] as String?,
            speaker: args['speaker'] as String?,
            dayOffset: (args['dayOffset'] as num?)?.toInt(),
            minDayOffset: (args['minDayOffset'] as num?)?.toInt(),
            maxDayOffset: (args['maxDayOffset'] as num?)?.toInt(),
            timeOfDay: args['timeOfDay'] as String?,
            kind: args['kind'] as String?,
            limit: ((args['limit'] as num?)?.toInt() ?? 6).clamp(1, 12),
            now: now,
          );
          return jsonEncode({
            'ok': true,
            'count': hits.length,
            'results': [
              for (final h in hits)
                {
                  'id': h.doc.id,
                  'kind': h.doc.kind,
                  'title': h.doc.title,
                  'time': h.doc.timeLabel,
                  'dayOffset': h.doc.dayOffset,
                  'speakers': h.doc.speakers,
                  'snippet': h.snippet,
                },
            ],
          });

        case 'get_record_detail':
          if (!config.recordSearchEnabled) {
            return jsonEncode({'ok': false, 'reason': '用户已在设置中关闭历史记录检索权限'});
          }
          final id = '${args['id'] ?? ''}'.trim();
          final doc = _index.getById(id);
          if (doc == null) {
            return jsonEncode({'ok': false, 'reason': '未找到 id=$id 的记录'});
          }
          final totalChars = doc.body.length;
          final rawOffset = (args['offsetChars'] as num?)?.toInt() ?? 0;
          final start = RecordSearchIndex.safeAlignStart(
            doc.body,
            rawOffset.clamp(0, totalChars),
          );
          final end = RecordSearchIndex.safeAlignEnd(
            doc.body,
            (start + _detailPageChars).clamp(start, totalChars),
          );
          final hasMore = end < totalChars;
          final slice = doc.body.substring(start, end);
          final body = hasMore
              ? '$slice\n...(后略，共 $totalChars 字，可传 offsetChars=$end 继续读取后续内容)'
              : slice;
          return jsonEncode({
            'ok': true,
            'id': doc.id,
            'kind': doc.kind,
            'title': doc.title,
            'time': doc.timeLabel,
            'dayOffset': doc.dayOffset,
            'speakers': doc.speakers,
            'summary': doc.summary,
            'todos': doc.todos,
            'offsetChars': start,
            'totalChars': totalChars,
            'hasMore': hasMore,
            if (hasMore) 'nextOffsetChars': end,
            'body': body,
          });

        case 'query_health':
          if (!config.healthAccessEnabled) {
            return jsonEncode({'ok': false, 'reason': '用户已在设置中关闭 Agent 健康读取权限'});
          }
          final fn = _queryHealth;
          if (fn == null) {
            return jsonEncode({'ok': false, 'reason': '健康存储未挂载'});
          }
          return await fn(args);

        case 'web_search':
          if (!config.webSearchEnabled) {
            return jsonEncode({'ok': false, 'reason': '用户已在设置中关闭联网搜索权限'});
          }
          final q = '${args['query'] ?? ''}'.trim();
          final limit = ((args['limit'] as num?)?.toInt() ?? 5).clamp(1, 8);
          final results = await _webSearch.search(
            q,
            limit: limit,
            customApiUrl: config.customSearchApiUrl,
            customApiKey: config.customSearchApiKey,
          );
          return jsonEncode({
            'ok': true,
            'query': q,
            'results': [for (final r in results) r.toJson()],
          });

        case 'web_fetch':
          if (!config.webSearchEnabled) {
            return jsonEncode({'ok': false, 'reason': '用户已在设置中关闭联网搜索权限'});
          }
          final url = '${args['url'] ?? ''}'.trim();
          final text = await _webSearch.fetchPage(url);
          return jsonEncode({'ok': true, 'url': url, 'content': text});

        case 'read_skill':
          final target = '${args['name'] ?? ''}'.trim();
          final content = await skillStore.readSkill(target);
          return jsonEncode(
            content == null
                ? {'ok': false, 'reason': '未找到名为 $target 的技能'}
                : {'ok': true, 'content': content},
          );

        case 'save_skill':
          final saved = await skillStore.saveSkill(
            name: '${args['name'] ?? ''}',
            description: '${args['description'] ?? ''}',
            body: '${args['body'] ?? ''}',
          );
          return jsonEncode(
            saved == null
                ? {'ok': false, 'reason': '技能名称与内容不能为空'}
                : {'ok': true, 'path': saved.path, 'name': saved.name},
          );

        case 'read_file':
          final rel = '${args['path'] ?? ''}'.trim();
          final content = await skillStore.readSandboxFile(rel);
          return jsonEncode(
            content == null
                ? {'ok': false, 'reason': '文件不存在或路径越界'}
                : {'ok': true, 'path': rel, 'content': content},
          );

        case 'write_file':
          final rel = '${args['path'] ?? ''}'.trim();
          final content = '${args['content'] ?? ''}';
          final written = await skillStore.writeSandboxFile(rel, content);
          return jsonEncode(
            written == null
                ? {'ok': false, 'reason': '路径不合法，仅允许写入 Agent 沙盒相对路径'}
                : {'ok': true, 'path': written},
          );

        case 'get_agent_settings':
          return jsonEncode({
            'ok': true,
            'model': config.model,
            'temperature': config.temperature,
            'agentPrompt': config.agentPrompt,
            'webSearchEnabled': config.webSearchEnabled,
            'recordSearchEnabled': config.recordSearchEnabled,
            'healthAccessEnabled': config.healthAccessEnabled,
            'mcps': [for (final m in config.activeMcps) m.toJson()],
          });

        case 'update_agent_settings':
          final fn = _patchConfig;
          if (fn == null) {
            return jsonEncode({'ok': false, 'reason': '配置修改接口未挂载'});
          }
          return await fn(args);

        default:
          if (name.startsWith('mcp:')) {
            for (final mt in mcpTools) {
              if ('mcp:${mt.endpointId}:${mt.name}' == name || mt.name == name) {
                final text = await _mcpClient.callTool(
                  endpointUrl: mt.endpointUrl,
                  toolName: mt.name,
                  arguments: args,
                );
                return jsonEncode({'ok': true, 'output': text});
              }
            }
          }
          return jsonEncode({'ok': false, 'reason': '未知工具：$name'});
      }
    } on Object catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }

  List<ChatMessage> _recentHistoryMessages(List<AgentChatMessage> history) {
    final recent = history.length > 16
        ? history.sublist(history.length - 16)
        : history;
    return [
      for (final m in recent)
        if (m.role == 'user')
          ChatMessage.user(m.text)
        else
          ChatMessage.assistant(m.text),
    ];
  }

  List<ChatMessage> _compactMessages(List<ChatMessage> source) {
    var total = source.fold<int>(0, (sum, m) => sum + m.content.length);
    if (total <= _maxContextChars || source.length <= 3) return source;
    final out = List<ChatMessage>.of(source);
    // 优先保留 system(0) 与最后 3 条消息，裁剪中间过长历史/工具输出
    for (var i = 1; i < out.length - 3 && total > _maxContextChars; i++) {
      final cur = out[i];
      if (cur.content.length > 500) {
        final trimmed = '${cur.content.substring(0, 320)}…(早期内容已压缩)';
        total -= (cur.content.length - trimmed.length);
        out[i] = ChatMessage(role: cur.role, content: trimmed);
      }
    }
    return out;
  }

  static _ParsedModelStep parseModelStep(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const _ParsedModelStep(reply: '', toolCalls: []);
    }
    final jsonStr = _extractJsonObject(trimmed);
    if (jsonStr == null) {
      return _ParsedModelStep(reply: trimmed, toolCalls: const []);
    }
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) {
        return _ParsedModelStep(reply: trimmed, toolCalls: const []);
      }
      final react = (decoded['react'] as String?)?.trim();
      final reply = '${decoded['reply'] ?? ''}'.trim();
      final rawCalls = decoded['tool_calls'];
      final calls = <_ParsedToolCall>[];
      if (rawCalls is List) {
        for (final item in rawCalls) {
          if (item is! Map) continue;
          final name = '${item['name'] ?? ''}'.trim();
          if (name.isEmpty) continue;
          final rawArgs = item['arguments'];
          final args = rawArgs is Map
              ? Map<String, dynamic>.from(rawArgs)
              : <String, dynamic>{};
          calls.add(_ParsedToolCall(name: name, arguments: args));
        }
      }
      if (calls.isNotEmpty) {
        return _ParsedModelStep(
          reaction: react,
          reply: reply,
          toolCalls: calls,
        );
      }
      if (reply.isNotEmpty) {
        return _ParsedModelStep(
          reaction: react,
          reply: reply,
          toolCalls: const [],
        );
      }
      return _ParsedModelStep(
        reaction: react,
        reply: trimmed,
        toolCalls: const [],
      );
    } on FormatException {
      return _ParsedModelStep(reply: trimmed, toolCalls: const []);
    }
  }

  static String? _extractJsonObject(String text) {
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    final candidate = fence?.group(1)?.trim() ?? text;
    final start = candidate.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = start; i < candidate.length; i++) {
      final ch = candidate[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (ch == r'\') {
          esc = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') {
        inStr = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return candidate.substring(start, i + 1);
      }
    }
    return null;
  }

  static String _sanitizeReply(String raw, {bool viaVoice = false}) {
    var s = raw.trim();
    s = s.replaceAll('思考过程', '思路');
    s = s.replaceAll('调用工具', '核对资料');
    if (!viaVoice) return s;

    // 语音模式下彻底去除 Markdown 符号（* / # / - / 链接 / 代码框），避免 TTS 生硬念出符号
    s = s.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (m) => m.group(1) ?? '',
    );
    s = s.replaceAll(RegExp(r'(?<=\d)\s*-\s*(?=\d)'), '到');
    final lines = <String>[];
    for (final rawLine in s.split(RegExp(r'\r?\n'))) {
      var line = rawLine.trim();
      if (line.isEmpty) continue;
      final wasHeading = line.startsWith('#');
      line = line.replaceFirst(RegExp(r'^[#>\s]+'), '');
      line = line.replaceFirst(RegExp(r'^[-*•·]+\s*'), '');
      line = line.replaceAll(RegExp(r'[*#`~]'), '');
      line = line.replaceAll('-', ' ');
      line = line.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (line.isEmpty) continue;
      if (wasHeading && !RegExp(r'[。！？!?：:；;，,]$').hasMatch(line)) {
        line = '$line：';
      }
      lines.add(line);
    }
    if (lines.isEmpty) return '';
    final out = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      final cur = lines[i];
      out.write(cur);
      if (i + 1 < lines.length &&
          !RegExp(r'[。！？!?：:；;，,]$').hasMatch(cur)) {
        out.write('，');
      }
    }
    return out.toString().trim();
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  void close() {
    _webSearch.close();
    _mcpClient.close();
  }
}

class _ParsedToolCall {
  const _ParsedToolCall({required this.name, required this.arguments});
  final String name;
  final Map<String, dynamic> arguments;
}

class _ParsedModelStep {
  const _ParsedModelStep({
    this.reaction,
    required this.reply,
    required this.toolCalls,
  });

  final String? reaction;
  final String reply;
  final List<_ParsedToolCall> toolCalls;
}
