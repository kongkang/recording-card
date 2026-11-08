class AppSettings {
  final bool continuousRecording;
  final bool markImportant;
  final bool autoTranscribe;
  final bool autoClean;
  final bool inferSpeakers;
  final bool wifiOnlySync;
  const AppSettings({
    this.continuousRecording = true,
    this.markImportant = true,
    this.autoTranscribe = true,
    this.autoClean = true,
    this.inferSpeakers = true,
    this.wifiOnlySync = false,
  });
  static const switchKeys = [
    'continuousRecording',
    'markImportant',
    'autoTranscribe',
    'autoClean',
    'inferSpeakers',
    'wifiOnlySync',
  ];
  static const switchLabels = [
    '持续录音',
    '标记重要对话',
    '自动转录',
    '自动清洗口语',
    '说话人推测归类',
    '仅 Wi-Fi 同步',
  ];
  Map<String, dynamic> toJson() => {
    'continuousRecording': continuousRecording,
    'markImportant': markImportant,
    'autoTranscribe': autoTranscribe,
    'autoClean': autoClean,
    'inferSpeakers': inferSpeakers,
    'wifiOnlySync': wifiOnlySync,
  };
  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    continuousRecording: json['continuousRecording'] as bool? ?? true,
    markImportant: json['markImportant'] as bool? ?? true,
    autoTranscribe: json['autoTranscribe'] as bool? ?? true,
    autoClean: json['autoClean'] as bool? ?? true,
    inferSpeakers: json['inferSpeakers'] as bool? ?? true,
    wifiOnlySync: json['wifiOnlySync'] as bool? ?? false,
  );
  AppSettings copyWith({
    bool? continuousRecording,
    bool? markImportant,
    bool? autoTranscribe,
    bool? autoClean,
    bool? inferSpeakers,
    bool? wifiOnlySync,
  }) => AppSettings(
    continuousRecording: continuousRecording ?? this.continuousRecording,
    markImportant: markImportant ?? this.markImportant,
    autoTranscribe: autoTranscribe ?? this.autoTranscribe,
    autoClean: autoClean ?? this.autoClean,
    inferSpeakers: inferSpeakers ?? this.inferSpeakers,
    wifiOnlySync: wifiOnlySync ?? this.wifiOnlySync,
  );
  AppSettings withSwitch(String keyOrLabel, bool enabled) {
    var key = keyOrLabel;
    final labelIndex = switchLabels.indexOf(keyOrLabel);
    if (labelIndex >= 0) key = switchKeys[labelIndex];
    if (!switchKeys.contains(key)) {
      throw ArgumentError('Unknown settings switch');
    }
    return AppSettings.fromJson({...toJson(), key: enabled});
  }

  Map<String, bool> get switchesByLabel => {
    for (var i = 0; i < switchKeys.length; i++)
      switchLabels[i]: toJson()[switchKeys[i]] as bool,
  };
}

class SavedWifiNetwork {
  final String id;
  final String ssid;
  final DateTime updatedAt;
  const SavedWifiNetwork({
    required this.id,
    required this.ssid,
    required this.updatedAt,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'ssid': ssid,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory SavedWifiNetwork.fromJson(Map<String, dynamic> json) =>
      SavedWifiNetwork(
        id: json['id'] as String,
        ssid: json['ssid'] as String,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}

class WifiCredential {
  final String ssid;
  final String password;
  const WifiCredential({required this.ssid, required this.password});
  @override
  String toString() => 'WifiCredential(<redacted>)';
}

class SettingsSnapshot {
  final AppSettings settings;
  final List<SavedWifiNetwork> networks;
  SettingsSnapshot({
    this.settings = const AppSettings(),
    List<SavedWifiNetwork> networks = const [],
  }) : networks = List.unmodifiable(networks);
  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'settings': settings.toJson(),
    'networks': networks.map((network) => network.toJson()).toList(),
  };
  factory SettingsSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported settings schema');
    }
    return SettingsSnapshot(
      settings: AppSettings.fromJson(
        Map<String, dynamic>.from(json['settings'] as Map),
      ),
      networks: [
        for (final n in json['networks'] as List)
          SavedWifiNetwork.fromJson(Map<String, dynamic>.from(n as Map)),
      ],
    );
  }
}
