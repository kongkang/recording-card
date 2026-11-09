import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/store/app_backend.dart';
import 'package:recording_card/services/recordings/recording_repository.dart';
import 'package:recording_card/services/recordings/sync_coordinator.dart';
import 'package:recording_card/services/settings/settings_repository.dart';
import 'package:recording_card/services/transcription/transcription_service.dart';

import 'runtime_repair_test.dart' as fixture;
import 'progressive_sync_coordinator_test.dart' as sync_fixture;

void main() {
  late fixture.Harness h;
  setUp(() async {
    h = fixture.Harness(
      await Directory.systemTemp.createTemp('progressive-pipeline-'),
    );
    h.pipeline.policy = const RecordingPolicy(inferSpeakers: false);
  });
  tearDown(() async {
    await h.pipeline.dispose();
    await h.gateway.stream.close();
    await h.root.delete(recursive: true);
  });

  test('localOnly publishes raw now; legacy tearoff resumes cloud once without repeating ASR or overwriting snapshots', () async {
    await h.chunk(1);
    await h.chunk(2);
    await h.chunk(3);
    await h.pipeline.processPending(localOnly: true);
    final local = await h.repo.load();
    final snapshots = {
      for (final entry in local.metadata.entries.where(
        (e) => e.key.startsWith('asr:'),
      ))
        entry.key: entry.value,
    };
    expect(local.events, hasLength(3));
    expect(
      local.events.every((e) => e.originalTranscript == fixture.speech.text),
      isTrue,
    );
    expect(
      local.events.every((e) => e.transcriptionStatus == 'analysis_pending'),
      isTrue,
    );
    expect(h.asr.calls, 3);
    expect(h.cloud.prompts, isEmpty);
    await h.pipeline.processPending(localOnly: true);
    expect(h.asr.calls, 3);
    expect(h.cloud.prompts, isEmpty);

    final Future<void> Function() legacyTearoff = h.pipeline.processPending;
    await legacyTearoff();
    final processed = await h.repo.load();
    expect(h.cloud.prompts, isNotEmpty);
    expect(h.asr.calls, 3);
    expect(
      processed.events.every(
        (e) => e.originalTranscript == fixture.speech.text,
      ),
      isTrue,
    );
    for (final entry in snapshots.entries) {
      expect(processed.metadata[entry.key], entry.value);
    }
    final billed = h.cloud.prompts.length;
    await legacyTearoff();
    expect(h.cloud.prompts.length, billed);
  });

  test('localOnly applies to recovered discontinuity and silence stages, not just transcript polish', () async {
    h.pipeline.policy = const RecordingPolicy(
      autoClean: false,
      inferSpeakers: false,
    );
    await h.chunk(1, interrupted: true);
    await h.pipeline.processPending();
    h.pipeline.policy = const RecordingPolicy(inferSpeakers: false);
    await h.chunk(2, discontinuous: true, finalChunk: true);
    h.asr.result = const TranscriptionResult(
      text: '',
      audioDuration: Duration(seconds: 30),
      segments: [],
      vadVerified: true,
      vadSpeechRangesMs: [],
    );
    await h.pipeline.processPending(localOnly: true);
    final state = await h.repo.load();
    expect(h.cloud.prompts, isEmpty);
    expect(
      state.metadata.keys.any((k) => k.startsWith('pending-stage:')),
      isTrue,
    );
    expect(state.events.any((e) => e.status == 'silent'), isTrue);
  });

  test(
    'missing local model leaves every downloaded group saved and queued',
    () async {
      h.asr.fail = true;
      final log = <String>[];
      final gateway = sync_fixture.GroupGateway([
        sync_fixture.remote('one'),
        sync_fixture.remote('two'),
      ], log);
      var published = 0;
      final coordinator = SyncCoordinator(
        repository: h.repo,
        settingsRepository: SettingsRepository(directory: h.root),
        gateway: gateway,
        onImported: (_) async {
          await h.pipeline.publish();
          await h.pipeline.processPending(localOnly: true);
          published++;
        },
      );
      final result = await coordinator.sync('card');
      final state = await h.repo.load();
      expect(published, 2);
      expect(result.imports, hasLength(2));
      expect(
        state.events.every((e) => e.transcriptionStatus == 'waiting_model'),
        isTrue,
      );
      expect(state.events.every((e) => e.originalTranscript == null), isTrue);
      expect(h.cloud.prompts, isEmpty);
      for (final entry in state.index) {
        expect(
          await h.repo.verifyRecording(entry.key),
          RecordingIntegrity.valid,
        );
      }
      await coordinator.dispose();
    },
  );

  test('saved raw without ASR snapshot is never overwritten or reinferred by localOnly', () async {
    final event = await h.import();
    await h.repo.upsertEvent(event.copyWith(originalTranscript: '保留原文'));
    await h.pipeline.processPending(localOnly: true);
    final saved = (await h.repo.load()).events.single;
    expect(saved.originalTranscript, '保留原文');
    expect(saved.transcriptionStatus, 'analysis_failed');
    expect(saved.error, contains('ASR快照缺失'));
    expect(h.asr.calls, 0);
    expect(h.cloud.prompts, isEmpty);
  });
}
