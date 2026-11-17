/// OS1 对话 Agent 数据模型 —— 纯可跨 Isolate 传递的数据载体（无 Flutter/UI 依赖）。
library;

class AgentChatMessage {
  const AgentChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAtMs,
    this.reaction,
    this.viaVoice = false,
  });

  final String id;

  /// `'user'` | `'assistant'`
  final String role;
  final String text;
  final int createdAtMs;
  final String? reaction;
  final bool viaVoice;

  AgentChatMessage copyWith({
    String? id,
    String? role,
    String? text,
    int? createdAtMs,
    String? reaction,
    bool? viaVoice,
  }) => AgentChatMessage(
    id: id ?? this.id,
    role: role ?? this.role,
    text: text ?? this.text,
    createdAtMs: createdAtMs ?? this.createdAtMs,
    reaction: reaction ?? this.reaction,
    viaVoice: viaVoice ?? this.viaVoice,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'text': text,
    'at': createdAtMs,
    if (reaction != null && reaction!.isNotEmpty) 'react': reaction,
    if (viaVoice) 'voice': true,
  };

  factory AgentChatMessage.fromJson(Map<String, dynamic> j) => AgentChatMessage(
    id: '${j['id'] ?? ''}',
    role: j['role'] == 'user' ? 'user' : 'assistant',
    text: '${j['text'] ?? ''}',
    createdAtMs: (j['at'] as num?)?.toInt() ?? 0,
    reaction: j['react'] as String?,
    viaVoice: j['voice'] == true,
  );
}

/// 供后台 Worker Isolate 索引检索的轻量记录/总结/人物文档。
class AgentDocument {
  const AgentDocument({
    required this.id,
    required this.kind,
    required this.title,
    required this.timeLabel,
    required this.dayOffset,
    required this.timestampMs,
    this.speakers = '',
    this.summary = '',
    this.body = '',
    this.todos = const [],
  });

  /// `'record'` | `'summary'`
  final String kind;
  final String id;
  final String title;
  final String timeLabel;
  final int dayOffset;
  final int timestampMs;
  final String speakers;
  final String summary;
  final String body;
  final List<String> todos;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'time': timeLabel,
    'day': dayOffset,
    'ts': timestampMs,
    if (speakers.isNotEmpty) 'spk': speakers,
    if (summary.isNotEmpty) 'sum': summary,
    if (body.isNotEmpty) 'body': body,
    if (todos.isNotEmpty) 'todos': todos,
  };

  factory AgentDocument.fromJson(Map<String, dynamic> j) => AgentDocument(
    id: '${j['id'] ?? ''}',
    kind: '${j['kind'] ?? 'record'}',
    title: '${j['title'] ?? ''}',
    timeLabel: '${j['time'] ?? ''}',
    dayOffset: (j['day'] as num?)?.toInt() ?? 0,
    timestampMs: (j['ts'] as num?)?.toInt() ?? 0,
    speakers: '${j['spk'] ?? ''}',
    summary: '${j['sum'] ?? ''}',
    body: '${j['body'] ?? ''}',
    todos: [for (final t in (j['todos'] as List? ?? const [])) '$t'],
  );
}

class AgentSkillSummary {
  const AgentSkillSummary({
    required this.name,
    required this.description,
    required this.path,
  });

  final String name;
  final String description;
  final String path;
}

class AgentMcpEndpoint {
  const AgentMcpEndpoint({
    required this.id,
    required this.name,
    required this.url,
  });

  final String id;
  final String name;
  final String url;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url};

  factory AgentMcpEndpoint.fromJson(Map<String, dynamic> j) =>
      AgentMcpEndpoint(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        url: '${j['url'] ?? ''}',
      );
}

class AgentConfigSnapshot {
  const AgentConfigSnapshot({
    required this.model,
    required this.temperature,
    required this.agentPrompt,
    required this.enabledSkillRules,
    required this.webSearchEnabled,
    required this.recordSearchEnabled,
    required this.healthAccessEnabled,
    required this.customSearchApiUrl,
    required this.customSearchApiKey,
    required this.activeMcps,
    required this.agentDirPath,
    this.speakerLibrarySummary = '',
  });

  final String model;
  final double temperature;
  final String agentPrompt;
  final List<String> enabledSkillRules;
  final bool webSearchEnabled;
  final bool recordSearchEnabled;
  final bool healthAccessEnabled;
  final String customSearchApiUrl;
  final String customSearchApiKey;
  final List<AgentMcpEndpoint> activeMcps;
  final String agentDirPath;
  final String speakerLibrarySummary;

  Map<String, dynamic> toJson() => {
    'model': model,
    'temp': temperature,
    'prompt': agentPrompt,
    'rules': enabledSkillRules,
    'web': webSearchEnabled,
    'rec': recordSearchEnabled,
    'health': healthAccessEnabled,
    'sUrl': customSearchApiUrl,
    'sKey': customSearchApiKey,
    'mcps': [for (final m in activeMcps) m.toJson()],
    'dir': agentDirPath,
    'spkLib': speakerLibrarySummary,
  };

  factory AgentConfigSnapshot.fromJson(Map<String, dynamic> j) =>
      AgentConfigSnapshot(
        model: '${j['model'] ?? ''}',
        temperature: (j['temp'] as num?)?.toDouble() ?? 0.3,
        agentPrompt: '${j['prompt'] ?? ''}',
        enabledSkillRules: [
          for (final r in (j['rules'] as List? ?? const [])) '$r',
        ],
        webSearchEnabled: j['web'] != false,
        recordSearchEnabled: j['rec'] != false,
        healthAccessEnabled: j['health'] != false,
        customSearchApiUrl: '${j['sUrl'] ?? ''}',
        customSearchApiKey: '${j['sKey'] ?? ''}',
        activeMcps: [
          for (final m in (j['mcps'] as List? ?? const []))
            if (m is Map)
              AgentMcpEndpoint.fromJson(Map<String, dynamic>.from(m)),
        ],
        agentDirPath: '${j['dir'] ?? ''}',
        speakerLibrarySummary: '${j['spkLib'] ?? ''}',
      );
}
