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

  test('录音开启期间按切片窗口滚动产出 WAV，停录时冲刷未满一片的尾片', () async {
    final gw = FakeCardGateway();
    // 2.5 秒音频（16kHz）：切片窗口设 1 秒 → 录音中立刻吐出 2 片，stop() 再吐第 3 片（0.5s）
    gw.realtimeEvents.addAll([
      const RealtimeAudioEvent(kind: RealtimeAudioKind.open),
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _tone(16000)),
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _tone(16000)),
      RealtimeAudioEvent(kind: RealtimeAudioKind.audio, pcm: _tone(8000)),
    ]);
    final emitted = <LiveAudioSlice>[];
    final recorder = LiveAudioRecorder(
      gateway: gw,
      baseDir: tmp,
      sliceDuration: const Duration(seconds: 1),
      onSliceReady: emitted.add,
    );

    recorder.updateDeviceSessionId('1ABE9622');
    await recorder.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await recorder.pendingSliceWrites;

    // 关键验证：尚未调用 stop()（仍在录音中！），前两片 1 秒切片已经封口落盘并回调！
    expect(recorder.isRunning, isTrue);
    expect(emitted.length, 2, reason: '录音未停止时就必须按窗口吐出切片');
    expect(emitted[0].isFinal, isFalse);
    expect(emitted[0].sliceKey, 'LIVE_1ABE9622_0001.WAV');
    expect(emitted[0].durationMs, 1000);
    expect(parseWav(File(emitted[0].wavPath).readAsBytesSync()).frames, 16000);
    expect(emitted[1].sliceKey, 'LIVE_1ABE9622_0002.WAV');

    final session = await recorder.stop();
    expect(emitted.length, 3, reason: '停录应把剩余 0.5 秒尾片封口吐出');
    expect(emitted[2].isFinal, isTrue);
    expect(emitted[2].sliceKey, 'LIVE_1ABE9622_0003.WAV');
    expect(emitted[2].durationMs, 500);
    expect(parseWav(File(emitted[2].wavPath).readAsBytesSync()).frames, 8000);
    expect(session!.sliceKeys.length, 3);
  });

  test('coversCardFile：无断档覆盖的卡文件判跳过，离线/有断档文件保留补传', () {
    final start = DateTime.fromMillisecondsSinceEpoch(1794387754000);
    final cleanSession = LiveSession(
      id: 'live-1',
      startedAt: start,
      deviceSessionId: '1ABE9622',
      gapCount: 0,
      spans: const [ReceivedSpan(startMs: 0, endMs: 120000)],
    );
    // 同一会话且时间落在 [start-8s, end+8s] 内 → 已覆盖
    expect(
      cleanSession.coversCardFile(
        const CardFile(
          name: '3600E239.APM',
          size: 80000,
          session: '1ABE9622',
          startAtSec: 1794387753,
          createdAtSec: 1794387870,
        ),
      ),
      isTrue,
    );
    // 蓝牙断开后离线录的另一段 → 未覆盖，必须同步下载
    expect(
      cleanSession.coversCardFile(
        const CardFile(
          name: 'OFFLINE.APM',
          size: 80000,
          session: '9999AAAA',
          startAtSec: 1794390000,
          createdAtSec: 1794390300,
        ),
      ),
      isFalse,
    );
    // 实时流中间有断档 → 未完整覆盖，允许蓝牙补传完整文件
    final gapped = cleanSession.copyWith(gapCount: 1);
    expect(
      gapped.coversCardFile(
        const CardFile(
          name: '3600E239.APM',
          size: 80000,
          session: '1ABE9622',
          startAtSec: 1794387753,
          createdAtSec: 1794387870,
        ),
      ),
      isFalse,
    );
  });
}
