// 实时音频落地验收（owner 2026-11-10 决策）。
//
// 关键约定：
// - 录音期间走蓝牙实时流，逐块 PCM 落成标准 WAV（能直接播、能直接给转写）；
// - 断档是**证据**不是异常：收进 session.json 的 gapCount，界面要如实说"中间有 N 处中断"；
// - 音频被清理后只剩「原始录音已清理」，不假装能播。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

import 'support/fake_gateway.dart';

/// 造一块 16bit 单声道 PCM（正弦，便于确认不是静音）。
Uint8List _tone(int samples) {
  final bytes = Uint8List(samples * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    final v = (8000 * (i % 160 - 80) / 80).round();
    view.setInt16(i * 2, v, Endian.little);
  }
  return bytes;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('rc-live-audio-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('录音期间收下的实时流会落成可解析的 WAV，并记录断档次数', () async {
    final gw = FakeCardGateway();
    gw.realtimeEvents.addAll([
      const RealtimeAudioEvent(kind: RealtimeAudioKind.open),
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _tone(16000)),
      const RealtimeAudioEvent(kind: RealtimeAudioKind.gap, gapIndex: 1),
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _tone(16000)),
      const RealtimeAudioEvent(kind: RealtimeAudioKind.closed),
    ]);
    final recorder = LiveAudioRecorder(gateway: gw, baseDir: tmp);

    await recorder.start();
    // 让流把预置事件吐完
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final session = await recorder.stop();

    expect(session, isNotNull);
    expect(session!.gapCount, 1, reason: '断档要如实计数，不能静默吞掉');
    expect(gw.realtimeCloseCalls, 1, reason: '停止录音必须关实时开关');

    final path = await LiveAudioRecorder.audioPathOf(session.id, baseDir: tmp);
    expect(path, isNotNull);

    // WAV 头部必须按真实长度回填：能被现有解析器读出来
    final wav = parseWav(File(path!).readAsBytesSync());
    expect(wav.sampleRate, 16000);
    expect(wav.channels, 1);
    expect(wav.bitsPerSample, 16);
    // 两段各 16000 样本 = 32000 样本
    expect(wav.dataLength, 32000 * 2);

    // 元信息落盘：后面按切片比对补传要靠它
    final reread = await LiveAudioRecorder.readSession(session.id, baseDir: tmp);
    expect(reread, isNotNull);
    expect(reread!.spans.length, 2, reason: '断档处应切成两段接收区间');
  });

  test('清理本地音频后查不到文件，界面据此显示「原始录音已清理」', () async {
    final gw = FakeCardGateway();
    gw.realtimeEvents.add(
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _tone(8000)),
    );
    final recorder = LiveAudioRecorder(gateway: gw, baseDir: tmp);
    await recorder.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final session = await recorder.stop();

    expect(
      await LiveAudioRecorder.audioPathOf(session!.id, baseDir: tmp),
      isNotNull,
    );

    await LiveAudioRecorder.deleteSession(session.id, baseDir: tmp);
    expect(await LiveAudioRecorder.audioPathOf(session.id, baseDir: tmp), isNull);
    expect(await LiveAudioRecorder.listSessions(baseDir: tmp), isEmpty);
  });

  test('设备文件能绑定到实时会话；没有绑定则回落到最新会话', () async {
    final gw = FakeCardGateway();
    gw.realtimeEvents.add(
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _tone(4000)),
    );
    final recorder = LiveAudioRecorder(gateway: gw, baseDir: tmp);
    await recorder.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final session = await recorder.stop();

    await LiveAudioRecorder.bindFileToSession(
      '059F19DF.APM',
      session!.id,
      baseDir: tmp,
    );
    final bound = await LiveAudioRecorder.sessionForFile(
      '059F19DF.APM',
      baseDir: tmp,
    );
    expect(bound?.id, session.id);

    // 没登记的文件名：回落最新会话，宁可多给一段可回听
    final fallback = await LiveAudioRecorder.sessionForFile(
      'UNKNOWN.APM',
      baseDir: tmp,
    );
    expect(fallback?.id, session.id);
  });
}
