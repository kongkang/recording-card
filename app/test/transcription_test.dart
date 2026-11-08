// 转写管线验收（TDD）—— 设置开关必须真正作用于结果，且任何开关都不丢原文。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/settings_store.dart';
import 'package:recording_card/services/transcription/transcription.dart';
import 'package:recording_card/services/transcription/transcription_pipeline.dart';

const _raw = '嗯……那个，今天先对齐一下排期。';
const _clean = '今天先对齐一下排期。';

SettingsStore _settings() => SettingsStore(store: InMemoryStore());

TranscriptResult _result() => const TranscriptResult(
      rawText: _raw,
      cleanText: _clean,
      turns: [
        TranscriptionTurn(speaker: 'A', text: _clean, startMs: 0, endMs: 1200),
      ],
      language: 'zh',
    );

void main() {
  test('自动转录关闭：不调用服务，返回 null', () async {
    final settings = _settings();
    addTearDown(settings.dispose);
    await settings.setValue('rc.set.trans.auto', false);
    final service = FakeTranscriptionService(result: _result());
    final pipeline = TranscriptionPipeline(service: service, settings: settings);

    final out = await pipeline.process(Uint8List.fromList([1, 2, 3]));

    expect(out, isNull);
    expect(service.callCount, 0);
  });

  test('自动转录开启：调用服务并透传音频/语言', () async {
    final settings = _settings();
    addTearDown(settings.dispose);
    final service = FakeTranscriptionService(result: _result());
    final pipeline = TranscriptionPipeline(service: service, settings: settings);

    final out = await pipeline.process(Uint8List.fromList([1, 2, 3, 4]),
        language: 'zh');

    expect(out, isNotNull);
    expect(out!.rawText, _raw);
    expect(out.cleanText, _clean);
    expect(out.turns.single.speaker, 'A');
    expect(service.callCount, 1);
    expect(service.lastAudioLength, 4);
    expect(service.lastLanguage, 'zh');
  });

  test('清洗关闭：cleanText 回填原文，不丢 raw', () async {
    final settings = _settings();
    addTearDown(settings.dispose);
    await settings.setValue('rc.set.trans.clean', false);
    final pipeline = TranscriptionPipeline(
        service: FakeTranscriptionService(result: _result()), settings: settings);

    final out = await pipeline.process(Uint8List.fromList([1]));

    expect(out!.rawText, _raw);
    expect(out.cleanText, _raw);
  });

  test('说话人关闭：turns 清空，raw/clean 保留', () async {
    final settings = _settings();
    addTearDown(settings.dispose);
    await settings.setValue('rc.set.trans.speaker', false);
    final pipeline = TranscriptionPipeline(
        service: FakeTranscriptionService(result: _result()), settings: settings);

    final out = await pipeline.process(Uint8List.fromList([1]));

    expect(out!.turns, isEmpty);
    expect(out.rawText, _raw);
    expect(out.cleanText, _clean);
  });

  test('服务异常向上抛，不伪造成功', () async {
    final settings = _settings();
    addTearDown(settings.dispose);
    final pipeline = TranscriptionPipeline(
      service: FakeTranscriptionService(
          error: const TranscriptionUnavailable('模型未安装')),
      settings: settings,
    );

    await expectLater(
      pipeline.process(Uint8List.fromList([1])),
      throwsA(isA<TranscriptionUnavailable>()),
    );
  });

  test('未注入结果时 Fake 抛 TranscriptionUnavailable', () async {
    final service = FakeTranscriptionService();
    await expectLater(
      service.transcribe(Uint8List.fromList([1])),
      throwsA(isA<TranscriptionUnavailable>()),
    );
  });
}
