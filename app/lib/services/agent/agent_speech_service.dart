/// OS1 原生语音通道（发送端系统 STT + 接收端系统 TTS），零额外模型包体积。
///
/// iOS：SFSpeechRecognizer + AVSpeechSynthesizer（注册在 AppDelegate.swift）。
/// Android：SpeechRecognizer + TextToSpeech（注册在 MainActivity.kt）。
/// 单测/桌面环境：优雅返回不可用提示或注入 Fake 实现。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AgentSpeechEvent {
  const AgentSpeechEvent({
    required this.kind,
    this.text = '',
    this.isFinal = false,
    this.level = 0.0,
    this.active = false,
    this.error,
  });

  /// `'transcript'` | `'level'` | `'listening'` | `'speaking'` | `'error'`
  final String kind;
  final String text;
  final bool isFinal;
  final double level;
  final bool active;
  final String? error;
}

abstract interface class AgentSpeechBackend {
  Stream<AgentSpeechEvent> get events;

  Future<bool> startListening({String locale = 'zh-CN'});

  Future<void> stopListening();

  Future<void> speak(String text, {String locale = 'zh-CN'});

  Future<void> stopSpeaking();

  void dispose();
}

class PlatformAgentSpeechBackend implements AgentSpeechBackend {
  PlatformAgentSpeechBackend({
    MethodChannel channel = const MethodChannel(
      'com.reai.recordingcard/agent_speech',
    ),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handleIncoming);
  }

  final MethodChannel _channel;
  final StreamController<AgentSpeechEvent> _events =
      StreamController<AgentSpeechEvent>.broadcast();

  @override
  Stream<AgentSpeechEvent> get events => _events.stream;

  Future<void> _handleIncoming(MethodCall call) async {
    if (_events.isClosed) return;
    final args = call.arguments;
    final map = args is Map ? Map<String, dynamic>.from(args) : const {};
    switch (call.method) {
      case 'onTranscript':
        _events.add(
          AgentSpeechEvent(
            kind: 'transcript',
            text: '${map['text'] ?? ''}',
            isFinal: map['isFinal'] == true,
          ),
        );
      case 'onSoundLevel':
        _events.add(
          AgentSpeechEvent(
            kind: 'level',
            level: ((map['level'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
          ),
        );
      case 'onListenState':
        _events.add(
          AgentSpeechEvent(
            kind: 'listening',
            active: map['listening'] == true,
          ),
        );
      case 'onSpeakState':
        _events.add(
          AgentSpeechEvent(
            kind: 'speaking',
            active: map['speaking'] == true,
          ),
        );
      case 'onSpeechError':
        _events.add(
          AgentSpeechEvent(
            kind: 'error',
            error: '${map['message'] ?? '语音交互暂不可用'}',
          ),
        );
    }
  }

  @override
  Future<bool> startListening({String locale = 'zh-CN'}) async {
    try {
      final ok = await _channel.invokeMethod<bool>('startListening', {
        'locale': locale,
      });
      return ok == true;
    } on MissingPluginException {
      if (!_events.isClosed) {
        _events.add(
          const AgentSpeechEvent(
            kind: 'error',
            error: '当前平台未挂载系统语音识别，请切到「轻聊」输入文字',
          ),
        );
      }
      return false;
    } on PlatformException catch (e) {
      if (!_events.isClosed) {
        _events.add(
          AgentSpeechEvent(
            kind: 'error',
            error: e.message ?? '无法启动语音识别',
          ),
        );
      }
      return false;
    }
  }

  @override
  Future<void> stopListening() async {
    try {
      await _channel.invokeMethod<void>('stopListening');
    } on MissingPluginException {
      // ignore in test environments
    } on PlatformException {
      // ignore
    }
  }

  @override
  Future<void> speak(String text, {String locale = 'zh-CN'}) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('speak', {
        'text': clean,
        'locale': locale,
      });
    } on MissingPluginException {
      // 桌面/单测无原生通道时静默跳过 TTS，保留文字展示
    } on PlatformException catch (e) {
      debugPrint('[agent_speech] TTS 播报失败: ${e.message}');
    }
  }

  @override
  Future<void> stopSpeaking() async {
    try {
      await _channel.invokeMethod<void>('stopSpeaking');
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }
}
