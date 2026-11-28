/// 录音卡语音输入法轻量 IPC 契约（App Groups 共享容器 + Darwin 通知 + 128B 固定波形缓冲）。
///
/// 设计原则（防 Extension Jetsam 杀进程）：
/// - 键盘扩展仅发送「开始/结束时间戳」，零模型、零麦克风；
/// - 主应用仅回传 32 字节（0..255）实时波形电平 + 最终润色后文本；
/// - 不跨进程传输原始 PCM 字节流。
library;

import 'dart:async';

import 'package:flutter/services.dart';

enum VoiceKeyboardCommandType { start, stop, cancel }

class KeyboardTimestampCommand {
  const KeyboardTimestampCommand({
    required this.type,
    required this.timestampMs,
    this.sessionToken = '',
  });

  final VoiceKeyboardCommandType type;
  final int timestampMs;
  final String sessionToken;

  factory KeyboardTimestampCommand.fromMap(Map<Object?, Object?> raw) {
    final kindRaw = '${raw['type'] ?? ''}'.trim().toLowerCase();
    final type = switch (kindRaw) {
      'start' => VoiceKeyboardCommandType.start,
      'stop' => VoiceKeyboardCommandType.stop,
      _ => VoiceKeyboardCommandType.cancel,
    };
    return KeyboardTimestampCommand(
      type: type,
      timestampMs: (raw['timestampMs'] as num?)?.toInt() ?? 0,
      sessionToken: '${raw['sessionToken'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'timestampMs': timestampMs,
    'sessionToken': sessionToken,
  };
}

class KeyboardDictationResult {
  const KeyboardDictationResult({
    required this.status, // 'idle' | 'recording' | 'processing' | 'done' | 'error'
    required this.sessionToken,
    this.text = '',
    this.rawText = '',
    this.routeLabel = '',
    this.elapsedMs = 0,
    this.error = '',
  });

  final String status;
  final String sessionToken;
  final String text;
  final String rawText;
  final String routeLabel;
  final int elapsedMs;
  final String error;

  Map<String, dynamic> toJson() => {
    'status': status,
    'sessionToken': sessionToken,
    'text': text,
    'rawText': rawText,
    'routeLabel': routeLabel,
    'elapsedMs': elapsedMs,
    'error': error,
    'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
  };
}

/// 键盘通信传输层抽象。
abstract class VoiceKeyboardIpcTransport {
  Stream<KeyboardTimestampCommand> get commands;

  Future<void> publishWaveform({
    required bool active,
    required List<int> bars32,
    required int timestampMs,
  });

  Future<void> publishResult(KeyboardDictationResult result);
}

/// 通过 MethodChannel / EventChannel 对接 iOS `VoiceKeyboardIpcBridge.swift`。
class MethodChannelVoiceKeyboardIpc implements VoiceKeyboardIpcTransport {
  MethodChannelVoiceKeyboardIpc() {
    _sub = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is Map && !_controller.isClosed) {
          _controller.add(KeyboardTimestampCommand.fromMap(event));
        }
      },
      onError: (Object _) {
        // 忽略非键盘平台缺失通道
      },
    );
  }

  static const MethodChannel _channel = MethodChannel(
    'com.reai.recordingcard/voice_keyboard_ipc',
  );
  static const EventChannel _events = EventChannel(
    'com.reai.recordingcard/voice_keyboard_cmd',
  );

  final StreamController<KeyboardTimestampCommand> _controller =
      StreamController<KeyboardTimestampCommand>.broadcast();
  StreamSubscription<dynamic>? _sub;

  @override
  Stream<KeyboardTimestampCommand> get commands => _controller.stream;

  @override
  Future<void> publishWaveform({
    required bool active,
    required List<int> bars32,
    required int timestampMs,
  }) async {
    try {
      await _channel.invokeMethod<void>('publishWaveform', {
        'active': active,
        'bars': bars32,
        'timestampMs': timestampMs,
      });
    } on MissingPluginException {
      // 非 iOS 或测试环境忽略
    } on PlatformException {
      // ignore
    }
  }

  @override
  Future<void> publishResult(KeyboardDictationResult result) async {
    try {
      await _channel.invokeMethod<void>('publishResult', result.toJson());
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}

/// 内存测试桩：验证波形、状态流与最终润色回传。
class InMemoryVoiceKeyboardIpc implements VoiceKeyboardIpcTransport {
  final StreamController<KeyboardTimestampCommand> _cmdController =
      StreamController<KeyboardTimestampCommand>.broadcast();

  final List<({bool active, List<int> bars32, int timestampMs})> waveforms = [];
  final List<KeyboardDictationResult> results = [];

  @override
  Stream<KeyboardTimestampCommand> get commands => _cmdController.stream;

  void emitCommand(KeyboardTimestampCommand cmd) {
    _cmdController.add(cmd);
  }

  @override
  Future<void> publishWaveform({
    required bool active,
    required List<int> bars32,
    required int timestampMs,
  }) async {
    waveforms.add((
      active: active,
      bars32: List<int>.unmodifiable(bars32),
      timestampMs: timestampMs,
    ));
  }

  @override
  Future<void> publishResult(KeyboardDictationResult result) async {
    results.add(result);
  }

  Future<void> dispose() => _cmdController.close();
}
