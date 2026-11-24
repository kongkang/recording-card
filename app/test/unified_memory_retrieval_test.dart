import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/agent/agent_chat_controller.dart';
import 'package:recording_card/services/agent/agent_harness_worker.dart';
import 'package:recording_card/services/agent/agent_models.dart';
import 'package:recording_card/services/agent/agent_speech_service.dart';
import 'package:recording_card/services/agent/hardware_agent_task_coordinator.dart';
import 'package:recording_card/services/agent/record_search_index.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/memory/local_memory_index.dart';
import 'package:recording_card/services/memory/memory_indexer.dart';
import 'package:recording_card/services/memory/memory_query.dart';
import 'package:recording_card/services/memory/memory_search_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_gateway.dart';

class _TestSpeechBackend implements AgentSpeechBackend {
  final StreamController<AgentSpeechEvent> _ctrl =
      StreamController<AgentSpeechEvent>.broadcast();

  bool speaking = false;
  final List<String> spokenTexts = [];

  @override
  Stream<AgentSpeechEvent> get events => _ctrl.stream;

  @override
  Future<bool> startListening({String locale = 'zh-CN'}) async => true;

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> speak(String text, {String locale = 'zh-CN'}) async {
    speaking = true;
    spokenTexts.add(text);
    _ctrl.add(const AgentSpeechEvent(kind: 'speaking', active: true));
  }

  void finishSpeaking() {
    speaking = false;
    _ctrl.add(const AgentSpeechEvent(kind: 'speaking', active: false));
  }

  @override
  Future<void> stopSpeaking() async {
    if (speaking) {
      speaking = false;
      _ctrl.add(const AgentSpeechEvent(kind: 'speaking', active: false));
    }
  }

  @override
  void dispose() {
    unawaited(_ctrl.close());
  }
}

class _TestPhoneMicBackend implements PhoneMicBackend {
  _TestPhoneMicBackend(this.chunksToEmit);

  final List<Uint8List> chunksToEmit;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<PhoneMicPermission> checkPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<PhoneMicPermission> requestPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcm16Mono16k) onPcm, {
    void Function(String error)? onError,
  }) async {
    startCalls++;
    for (final c in chunksToEmit) {
      onPcm(c);
    }
  }

  @override
  Future<void> stopCapture() async {
    stopCalls++;
  }
}

class _ErrorRealtimeGateway extends FakeCardGateway {
  _ErrorRealtimeGateway({required super.initialSnapshot});

  final StreamController<RealtimeAudioEvent> realtimeCtrl =
      StreamController<RealtimeAudioEvent>.broadcast();

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() {
    realtimeOpenCalls++;
    callLog.add('realtime.open');
    return realtimeCtrl.stream;
  }
}

CardSnapshot _dyjSnap({bool recording = false}) => CardSnapshot(
  batteryLevel: 85,
  isCharging: false,
  wifiOpen: true,
  recording: recording,
  fwVersion: '0.8.15',
  fwVersionCode: 815,
  wifiVersion: '',
  wifiVersionCode: 0,
  deviceName: 'DYJ_TEST',
  deviceId: 'dyj-test-1',
  deviceKind: DeviceKind.dyjV1,
  capabilities: HardwareCapabilities.dyjV1,
);

Uint8List _voicedPcm({int samples = 3200}) {
  final out = Uint8List(samples * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples; i++) {
    final v = (i % 32 < 16) ? 6000 : -6000;
    view.setInt16(i * 2, v, Endian.little);
  }
  return out;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  group('1. HardwareAgentTaskCoordinator & DYJ V1 Voice Loop', () {
    test(
      '1a. _handlePhotoRecognize parses production FFI {ok: true, data: {path}} and checks {ok: false}',
      () async {
        final dir = await Directory.systemTemp.createTemp('rc_umr_photo_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final photoFile = File('${dir.path}/REAL_DYJ_001.JPG');
        await photoFile.writeAsBytes([0xFF, 0xD8, 0xFF, 0xD9], flush: true);

        final cfg = AgentConfigStore(store: InMemoryStore());
        await cfg.load();
        final appStore = AppStore(loadPersistedState: false);
        final gw = FakeCardGateway(initialSnapshot: _dyjSnap());
        final dyjSpoken = <String>[];
        gw.onBridgeCommand = (kind, payload) async {
          if (kind == 'camera_capture_and_fetch') {
            return {
              'ok': true,
              'final': true,
              'data': {
                'name': 'REAL_DYJ_001.JPG',
                'path': photoFile.path,
                'bytes': 4,
              },
            };
          }
          if (kind == 'dyj_tts_speak') {
            dyjSpoken.add('${payload?['text'] ?? ''}');
            return {'supported': true, 'spoken': true};
          }
          return {'ok': true};
        };

        final device = DeviceStore(gateway: gw);
        await device.restoreLink();
        final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir);
        final speech = _TestSpeechBackend();
        final captured = <String?>[];
        final chat = AgentChatController(
          appStore: appStore,
          agentConfig: cfg,
          speech: speech,
          visionCompletion: (msgs, {String? model}) async {
            captured.add(msgs.last.imageDataUrl);
            return '画面里是一份会议纪要白板。';
          },
          agentDirResolver: () async => '',
        );

        final coord = HardwareAgentTaskCoordinator(
          device: device,
          agentConfig: cfg,
          agentChat: chat,
          liveAudio: liveAudio,
          tempDirResolver: () async => dir,
          postSettleDelay: Duration.zero,
          transientStatusDuration: Duration.zero,
          maxVoiceTaskDuration: Duration.zero,
          transcribeSamples: (s, {sampleRate = 16000}) async => '',
        );

        gw.pushButtonEvent(gesture: 'double_click', receivedAtMs: 1000);
        await device.pollEventsNow();
        await coord.idle;
        await Future<void>.delayed(Duration.zero);

        expect(captured, hasLength(1));
        expect(chat.messages.last.text, '画面里是一份会议纪要白板。');
        expect(dyjSpoken, contains('画面里是一份会议纪要白板。'));
        expect(speech.spokenTexts, isEmpty);

        // Explicit ok: false bridge error must fail honestly without crashing
        gw.onBridgeCommand = (kind, payload) async {
          if (kind == 'camera_capture_and_fetch') {
            return {'ok': false, 'error': '点一机存储卡忙'};
          }
          if (kind == 'dyj_tts_speak') {
            dyjSpoken.add('${payload?['text'] ?? ''}');
            return {'supported': true, 'spoken': true};
          }
          return {'ok': true};
        };
        gw.pushButtonEvent(gesture: 'double_click', receivedAtMs: 2000);
        await device.pollEventsNow();
        await coord.idle;
        await Future<void>.delayed(Duration.zero);
        expect(dyjSpoken.last, contains('拍照识别失败'));
        expect(speech.spokenTexts, isEmpty);

        coord.dispose();
        chat.dispose();
        liveAudio.dispose();
        device.dispose();
        cfg.dispose();
        appStore.dispose();
        speech.dispose();
      },
    );

    test(
      '1b. _startTempCapture automatically falls back to PhoneMicBackend when realtimeAudio fails asynchronously',
      () async {
        final dir = await Directory.systemTemp.createTemp('rc_umr_fallback_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final cfg = AgentConfigStore(store: InMemoryStore());
        await cfg.load();
        final appStore = AppStore(loadPersistedState: false);
        final gw = _ErrorRealtimeGateway(initialSnapshot: _dyjSnap(recording: false));
        final device = DeviceStore(gateway: gw);
        await device.restoreLink();
        final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir);
        final mic = _TestPhoneMicBackend([_voicedPcm(samples: 4800)]);
        final speech = _TestSpeechBackend();

        final prompts = <String>[];
        final worker = AgentHarnessWorker(
          complete: (msgs, {required model, temperature = 0.3, maxTokens = 2048}) async {
            prompts.add(msgs.last.content);
            return jsonEncode({'react': '👌', 'reply': '前天下午三点你在电影院看了黄金眼。'});
          },
          inProcess: true,
        );
        final chat = AgentChatController(
          appStore: appStore,
          agentConfig: cfg,
          speech: speech,
          completion: _SimpleCompletion((msgs) async {
            prompts.add(msgs.last.content);
            return jsonEncode({'react': '👌', 'reply': '前天下午三点你在电影院看了黄金眼。'});
          }),
          worker: worker,
          agentDirResolver: () async => '',
        );

        final coord = HardwareAgentTaskCoordinator(
          device: device,
          agentConfig: cfg,
          agentChat: chat,
          liveAudio: liveAudio,
          phoneMicBackendFactory: () => mic,
          postSettleDelay: Duration.zero,
          transientStatusDuration: Duration.zero,
          maxVoiceTaskDuration: Duration.zero,
          transcribeSamples: (s, {sampleRate = 16000}) async => '前天看的电影叫什么',
        );

        gw.pushButtonEvent(
          gesture: 'long_press_start',
          durationMs: 600,
          receivedAtMs: 3000,
        );
        await device.pollEventsNow();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Hardware realtime stream fails asynchronously before delivering any audio
        gw.realtimeCtrl.addError(
          const CardException(CardErrorKind.device, 'BLE notify busy'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(mic.startCalls, 1);

        gw.pushButtonEvent(
          gesture: 'long_press_end',
          durationMs: 1800,
          receivedAtMs: 4200,
        );
        await device.pollEventsNow();
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(mic.stopCalls, 1);
        expect(prompts.any((p) => p.contains('前天看的电影叫什么')), isTrue);
        expect(gw.dyjTtsSpokenTexts, contains('前天下午三点你在电影院看了黄金眼。'));
        expect(speech.spokenTexts, isEmpty);

        await gw.realtimeCtrl.close();
        coord.dispose();
        await worker.dispose();
        chat.dispose();
        liveAudio.dispose();
        device.dispose();
        cfg.dispose();
        appStore.dispose();
        speech.dispose();
      },
    );

    test(
      '1c. viaVoice system prompt enforces spoken Chinese without Markdown & strict TTS echo isolation',
      () async {
        final dir = await Directory.systemTemp.createTemp('rc_umr_voice_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        var nowMs = 2000;
        DateTime clock() => DateTime.fromMillisecondsSinceEpoch(nowMs);

        final cfg = AgentConfigStore(store: InMemoryStore());
        await cfg.load();
        final appStore = AppStore(loadPersistedState: false);
        final gw = FakeCardGateway(initialSnapshot: _dyjSnap(recording: true));
        final device = DeviceStore(gateway: gw);
        await device.restoreLink();
        final liveAudio = LiveAudioRecorder(gateway: gw, baseDir: dir, clock: clock);

        final speech = _TestSpeechBackend();
        String? capturedSystemPrompt;
        Future<String> fakeModel(
          List<ChatMessage> msgs, {
          required String model,
          double temperature = 0.3,
          int maxTokens = 2048,
        }) async {
          capturedSystemPrompt = msgs.first.content;
          return jsonEncode({
            'react': '👌',
            'reply': '### 查找结果\n- **前天 15:10** 在《电影院》记录里提到看了 007黄金眼',
          });
        }

        final worker = AgentHarnessWorker(complete: fakeModel, inProcess: true);
        final chat = AgentChatController(
          appStore: appStore,
          agentConfig: cfg,
          speech: speech,
          completion: _SimpleCompletion((m) => fakeModel(m, model: 'test')),
          worker: worker,
          agentDirResolver: () async => '',
          clock: clock,
        );

        final lookupStarts = <int>[];
        final coord = HardwareAgentTaskCoordinator(
          device: device,
          agentConfig: cfg,
          agentChat: chat,
          liveAudio: liveAudio,
          clock: clock,
          postSettleDelay: Duration.zero,
          transientStatusDuration: Duration.zero,
          maxVoiceTaskDuration: Duration.zero,
          lookupExistingTranscript: (startMs, endMs) async {
            lookupStarts.add(startMs);
            return '前天看了什么电影';
          },
          transcribeSamples: (s, {sampleRate = 16000}) async => '前天看了什么电影',
        );

        // Simulate active TTS playback when user presses button down at 2000ms,
        // and long_press_start arrives at 2600ms.
        await chat.speakText('上一段播报还没说完');
        expect(chat.isSpeaking, isTrue);

        nowMs = 2000;
        gw.pushButtonEvent(gesture: 'down', receivedAtMs: 2000);
        await device.pollEventsNow();
        await Future<void>.delayed(Duration.zero);

        nowMs = 2600;
        gw.pushButtonEvent(
          gesture: 'long_press_start',
          durationMs: 600,
          receivedAtMs: 2600,
        );
        await device.pollEventsNow();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        nowMs = 4000;
        gw.pushButtonEvent(
          gesture: 'long_press_end',
          durationMs: 2000,
          receivedAtMs: 4000,
        );
        await device.pollEventsNow();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(capturedSystemPrompt, isNotNull);
        expect(capturedSystemPrompt, contains('Markdown'));
        final spoken = gw.dyjTtsSpokenTexts.last;
        expect(spoken.contains('*'), isFalse);
        expect(spoken.contains('#'), isFalse);
        expect(spoken.contains('-'), isFalse);
        expect(speech.spokenTexts, ['上一段播报还没说完']);
        expect(lookupStarts.single, greaterThanOrEqualTo(2000));

        // Now simulate active phone TTS finishing at 4500ms; next voice query starting
        // at 4300ms (with preRoll) must clamp lookup startMs >= 4500ms (_lastTtsEndedAtMs)
        await chat.speakText('手机端测试播报');
        nowMs = 4500;
        speech.finishSpeaking();
        await Future<void>.delayed(Duration.zero);

        lookupStarts.clear();
        nowMs = 4600;
        gw.pushButtonEvent(gesture: 'down', receivedAtMs: 4300);
        gw.pushButtonEvent(
          gesture: 'long_press_start',
          durationMs: 300,
          receivedAtMs: 4600,
        );
        await device.pollEventsNow();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        nowMs = 5600;
        gw.pushButtonEvent(
          gesture: 'long_press_end',
          durationMs: 1300,
          receivedAtMs: 5600,
        );
        await device.pollEventsNow();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(lookupStarts.single, greaterThanOrEqualTo(4500));

        coord.dispose();
        await worker.dispose();
        chat.dispose();
        liveAudio.dispose();
        device.dispose();
        cfg.dispose();
        appStore.dispose();
        speech.dispose();
      },
    );
  });

  group('2. Incremental Dirty-Hash SQLite FTS5 & Passage Chunking', () {
    test(
      '2a. LocalMemoryIndex migrates v1->v2 and performs incremental diff sync without full-table wipe',
      () async {
        final dir = await Directory.systemTemp.createTemp('rc_umr_fts_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });
        final dbPath = '${dir.path}/memory_v1.db';

        // Seed a legacy v1 FTS5 database without content_hash column
        final v1Db = await databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) async {
              await db.execute('''
CREATE VIRTUAL TABLE memory_fts USING fts5(
  chunk_id UNINDEXED,
  kind UNINDEXED,
  source_id UNINDEXED,
  day_offset UNINDEXED,
  time_label UNINDEXED,
  title,
  body,
  search_text,
  tokenize = 'unicode61'
)''');
            },
          ),
        );
        await v1Db.close();

        var events = <RecordEvent>[
          _mkEvent(id: 'e1', dayOffset: 0, time: '09:00', text: '第一条记录讨论龙井绿茶'),
          _mkEvent(id: 'e2', dayOffset: 1, time: '14:00', text: '第二条记录讨论拿铁咖啡'),
        ];
        final index = LocalMemoryIndex(
          factory: databaseFactoryFfi,
          path: () async => dbPath,
        );
        final service = MemorySearchService(
          index: index,
          corpus: () => MemoryCorpus(events: events, summaries: const []),
        );
        addTearDown(service.close);

        await service.ask('龙井');

        final rawDb = await databaseFactoryFfi.openDatabase(dbPath);
        addTearDown(rawDb.close);
        final rows1 = await rawDb.rawQuery(
          'SELECT rowid, chunk_id, content_hash FROM memory_fts ORDER BY chunk_id',
        );
        expect(rows1, hasLength(2));
        expect('${rows1.first['content_hash'] ?? ''}', isNotEmpty);
        final e1RowIdBefore = rows1.firstWhere((r) => r['chunk_id'] == 'recording:e1')['rowid'];
        final e2RowIdBefore = rows1.firstWhere((r) => r['chunk_id'] == 'recording:e2')['rowid'];

        // Calling ask() again with unchanged corpus must NOT wipe/reinsert rows or run a transaction!
        final txBefore = index.debugSyncTransactions;
        await service.ask('拿铁');
        expect(index.debugSyncTransactions, txBefore);
        final rows2 = await rawDb.rawQuery(
          'SELECT rowid, chunk_id FROM memory_fts ORDER BY chunk_id',
        );
        expect(
          rows2.firstWhere((r) => r['chunk_id'] == 'recording:e1')['rowid'],
          e1RowIdBefore,
        );
        expect(
          rows2.firstWhere((r) => r['chunk_id'] == 'recording:e2')['rowid'],
          e2RowIdBefore,
        );

        // Updating ONLY e2 and adding e3 must keep e1's rowid untouched!
        events = [
          _mkEvent(id: 'e1', dayOffset: 0, time: '09:00', text: '第一条记录讨论龙井绿茶'),
          _mkEvent(id: 'e2', dayOffset: 1, time: '14:00', text: '第二条记录改为美式咖啡'),
          _mkEvent(id: 'e3', dayOffset: 2, time: '16:00', text: '第三条记录讨论乌龙茶'),
        ];
        await service.ask('美式咖啡');
        final rows3 = await rawDb.rawQuery(
          'SELECT rowid, chunk_id FROM memory_fts ORDER BY chunk_id',
        );
        expect(rows3, hasLength(3));
        expect(
          rows3.firstWhere((r) => r['chunk_id'] == 'recording:e1')['rowid'],
          e1RowIdBefore,
        );
        expect(await service.search('拿铁'), isEmpty);
        expect((await service.search('美式咖啡')).map((h) => h.sourceId), ['e2']);
      },
    );

    test(
      '2b. memory_indexer chunks 20,000+ char 2-hour meetings with overlap and indexes event.mark',
      () async {
        final dir = await Directory.systemTemp.createTemp('rc_umr_long_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final turns = <TurnLine>[
          const TurnLine('老陈', '会议第1分钟：我们先确认茶歇采购明前龙井。', '09:01'),
          for (var i = 2; i <= 220; i++)
            TurnLine(
              i.isEven ? '老陈' : '小李',
              '第$i分钟常规进度同步：客户端渲染帧率稳定，持续观察线上指标与日志流水细节第$i轮验证通过。',
              '09:${(i % 60).toString().padLeft(2, '0')}',
            ),
          const TurnLine('小李', '会议第120分钟收尾：最终拍板香港边缘节点下周扩容三倍。', '11:00'),
        ];
        final longEvent = RecordEvent(
          id: 'meeting-2h',
          dayOffset: 1,
          title: '双周架构评审长会',
          brief: '架构评审',
          longText: '架构评审纪要',
          time: '09:00',
          dur: '120分',
          speakers: '老陈 / 小李',
          mark: '重点打点：专项预算上限五十万',
          srcMap: '',
          dialog: turns,
          raw: const [],
        );

        final corpus = MemoryCorpus(events: [longEvent], summaries: const []);
        final chunks = buildMemoryChunks(corpus);
        expect(chunks.length, greaterThan(15));
        expect(chunks.every((c) => c.sourceId == 'meeting-2h'), isTrue);
        expect(chunks.any((c) => c.id.startsWith('recording:meeting-2h#')), isTrue);

        final index = LocalMemoryIndex(
          factory: databaseFactoryFfi,
          path: () async => '${dir.path}/long.db',
        );
        final service = MemorySearchService(index: index, corpus: () => corpus);
        addTearDown(service.close);
        await service.reindex();

        // Minute 1, Minute 120 (>10,000 chars), and event.mark are ALL searchable!
        final headHits = await service.search('明前龙井');
        expect(headHits, isNotEmpty);
        expect(headHits.first.sourceId, 'meeting-2h');

        final tailHits = await service.search('香港边缘节点');
        expect(tailHits, isNotEmpty);
        expect(tailHits.first.sourceId, 'meeting-2h');
        expect(tailHits.first.body, contains('香港边缘节点'));

        final markHits = await service.search('预算上限五十万');
        expect(markHits, isNotEmpty);
        expect(markHits.first.sourceId, 'meeting-2h');

        // Verify speakerResolver & deviceLabelResolver on MemoryCorpus
        final enriched = MemoryCorpus(
          events: [
            _mkEvent(
              id: 'dev-spk',
              dayOffset: 0,
              time: '10:30',
              text: '下周三走合同审批流程',
              speakers: '说话人 1',
            ),
          ],
          summaries: const [],
          speakerResolver: (event, rawSpk) =>
              rawSpk == '说话人 1' ? '张总监' : rawSpk,
          deviceLabelResolver: (event) => '点一机 V1',
        );
        await service.reindex(enriched);
        expect(
          (await service.search('张总监 合同')).map((h) => h.sourceId),
          ['dev-spk'],
        );
        expect(
          (await service.search('点一机 审批')).map((h) => h.sourceId),
          ['dev-spk'],
        );
      },
    );
  });

  group('3. Natural Chinese Temporal, Time-of-Day, Stopword & CJK Unigram+Bigram', () {
    test(
      '3a & 3b. parseMemoryQuery handles 大前天, N天前, time-of-day hourRange & strips conversational fillers',
      () async {
        final dir = await Directory.systemTemp.createTemp('rc_umr_query_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final dq = parseMemoryQuery('大前天聊了什么');
        expect(dq.window?.minOffset, 3);
        expect(dq.window?.maxOffset, 3);
        expect(dq.text, isEmpty);

        final nDaysCn = parseMemoryQuery('三天前说的预算');
        expect(nDaysCn.window?.minOffset, 3);
        expect(nDaysCn.window?.maxOffset, 3);
        expect(nDaysCn.text, '预算');

        final nDaysNum = parseMemoryQuery('帮我查一下5天前关于合同讲了什么');
        expect(nDaysNum.window?.minOffset, 5);
        expect(nDaysNum.window?.maxOffset, 5);
        expect(nDaysNum.text, '合同');

        final pm = parseMemoryQuery('前天下午聊了什么');
        expect(pm.window?.minOffset, 2);
        expect(pm.window?.maxOffset, 2);
        expect(pm.hourRange?.startHour, 12);
        expect(pm.hourRange?.endHour, 18);
        expect(pm.text, isEmpty);

        // Calendar-accurate Monday (2026-11-16 is Monday)
        final monday = DateTime(2026, 11, 16, 10, 0);
        expect(monday.weekday, DateTime.monday);
        final lastWeekOnMon = parseMemoryQuery('上周聊了什么', now: monday);
        expect(lastWeekOnMon.window?.minOffset, 1);
        expect(lastWeekOnMon.window?.maxOffset, 7);
        expect(lastWeekOnMon.text, isEmpty);

        final thisWeekOnMon = parseMemoryQuery('本周有哪些待办', now: monday);
        expect(thisWeekOnMon.window?.minOffset, 0);
        expect(thisWeekOnMon.window?.maxOffset, 0);
        expect(thisWeekOnMon.text, '待办');

        // Friday (2026-11-20 is Friday): 周三 -> 2 days ago, 今早 -> 0 + morning, 昨晚 -> 1 + evening
        final friday = DateTime(2026, 11, 20, 18, 0);
        final wedOnFri = parseMemoryQuery('星期三上午说了什么', now: friday);
        expect(wedOnFri.window?.minOffset, 2);
        expect(wedOnFri.window?.maxOffset, 2);
        expect(wedOnFri.hourRange?.name, 'forenoon');
        expect(wedOnFri.text, isEmpty);

        final lastNight = parseMemoryQuery('昨晚聊了什么', now: friday);
        expect(lastNight.window?.minOffset, 1);
        expect(lastNight.window?.maxOffset, 1);
        expect(lastNight.hourRange?.name, 'evening');
        expect(lastNight.text, isEmpty);

        final thisMorning = parseMemoryQuery('今早讲了什么', now: friday);
        expect(thisMorning.window?.minOffset, 0);
        expect(thisMorning.window?.maxOffset, 0);
        expect(thisMorning.hourRange?.name, 'morning');
        expect(thisMorning.text, isEmpty);

        final corpus = MemoryCorpus(
          events: [
            _mkEvent(id: 'am-rec', dayOffset: 2, time: '09:20', text: '早会同步接口联调'),
            _mkEvent(id: 'pm-rec', dayOffset: 2, time: '15:10', text: '下午跟客户聊续约折扣'),
          ],
          summaries: const [],
        );
        final index = LocalMemoryIndex(
          factory: databaseFactoryFfi,
          path: () async => '${dir.path}/tod.db',
        );
        final service = MemorySearchService(index: index, corpus: () => corpus);
        addTearDown(service.close);
        await service.reindex();

        final hits = await service.search('前天下午聊了什么');
        expect(hits.map((h) => h.sourceId), ['pm-rec']);
      },
    );

    test(
      '3c. CJK unigram+bigram + stop-char filter + 1-char ASCII + CJK Ext B+ match across both search engines',
      () async {
        final dir = await Directory.systemTemp.createTemp('rc_umr_cjk_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final corpus = MemoryCorpus(
          events: [
            _mkEvent(id: 'tea', dayOffset: 1, time: '16:00', text: '老陈推荐喝茶，说武夷岩茶很香'),
            _mkEvent(id: 'noise', dayOffset: 0, time: '10:00', text: '今天他说的话非常有道理'),
            _mkEvent(id: 'plan-b', dayOffset: 0, time: '11:00', text: '评审决定启用B方案，去3楼会议室'),
            _mkEvent(id: 'plan-a', dayOffset: 0, time: '11:30', text: '原定方案在一楼大厅展示'),
            _mkEvent(id: 'ext-b', dayOffset: 0, time: '12:15', text: '中午去吃了𠮷野家牛肉饭'),
          ],
          summaries: const [],
        );
        final index = LocalMemoryIndex(
          factory: databaseFactoryFfi,
          path: () async => '${dir.path}/cjk.db',
        );
        final service = MemorySearchService(index: index, corpus: () => corpus);
        addTearDown(service.close);
        await service.reindex();

        final teaHits = await service.search('陈总说的茶');
        expect(teaHits, isNotEmpty);
        expect(teaHits.first.sourceId, 'tea');
        expect(teaHits.map((h) => h.sourceId), isNot(contains('noise')));

        // Monday (2026-11-16): "上周老陈说的茶" -> window 1..7 + unigram/bigram match on 'tea' (dayOffset=1)!
        final monTeaHits = await service.search(
          '上周老陈说的茶',
          now: DateTime(2026, 11, 16, 9, 0),
        );
        expect(monTeaHits.map((h) => h.sourceId), ['tea']);

        final bHits = await service.search('B方案');
        expect(bHits.first.sourceId, 'plan-b');

        final floorHits = await service.search('3楼');
        expect(floorHits.first.sourceId, 'plan-b');

        final extHits = await service.search('𠮷野家');
        expect(extHits.map((h) => h.sourceId), ['ext-b']);

        // Also verify RecordSearchIndex parity
        final recIdx = RecordSearchIndex()
          ..replaceCorpus([
            for (final e in corpus.events)
              AgentDocument(
                id: e.id,
                kind: 'record',
                title: e.title,
                timeLabel: e.time,
                dayOffset: e.dayOffset,
                timestampMs: 1000,
                body: e.brief,
              ),
          ]);
        expect(recIdx.search(query: '陈总说的茶').first.doc.id, 'tea');
        expect(
          recIdx.search(query: '陈总说的茶').map((h) => h.doc.id),
          isNot(contains('noise')),
        );
        expect(recIdx.search(query: '3楼').first.doc.id, 'plan-b');
        expect(recIdx.search(query: '𠮷野家').first.doc.id, 'ext-b');
      },
    );
  });

  group('4. OS1 AgentChatController & AgentHarnessWorker Split-Brain Fixes', () {
    test(
      '4a-4d. Real timestampMs, SummaryCard dayOffset/speakers, mark, speaker suffix strip, IDF snippet, search_records ranges & get_record_detail pagination',
      () async {
        final dir = await Directory.systemTemp.createTemp('rc_umr_os1_');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final longBody = [
          '老陈：早上好，今天先对齐常规周报。',
          for (var i = 0; i < 140; i++)
            '小王：第$i条例行巡检流水正常，网关延迟保持在二十毫秒以内没有任何异常波动。',
          '老陈：在会议最后阶段确认《007黄金眼》包场定在下周五晚上八点，暗号是北极星。',
        ].join('\n');

        final appStore = AppStore(
          events: [
            _mkEvent(
              id: 'today-early',
              dayOffset: 0,
              time: '09:10',
              text: '早晨站会确认发布窗口',
              speakers: '孔康（机主本人）',
              mark: '重点打点：冻结主干分支',
            ),
            _mkEvent(
              id: 'today-late',
              dayOffset: 0,
              time: '17:45',
              text: '傍晚复盘线上监控曲线',
              speakers: '老陈（推测）',
            ),
            RecordEvent(
              id: 'old-long',
              dayOffset: 5,
              title: '五天前全员大会',
              brief: '常规周报与团建安排',
              longText: longBody,
              time: '15:20',
              dur: '90分',
              speakers: '老陈 / 小王',
              mark: '',
              srcMap: '',
              dialog: [TurnLine('老陈', longBody, '15:20')],
              raw: const [],
            ),
          ],
          loadPersistedState: false,
        )..summaries = [
            SummaryCard(id: 'sum-old', time: '20:00', state: SummaryState.done)
              ..title = '五天前大会总结'
              ..overview = '确认团建安排'
              ..srcIds = const ['old-long'],
          ];
        addTearDown(appStore.dispose);

        final cfg = AgentConfigStore(store: InMemoryStore());
        addTearDown(cfg.dispose);
        await cfg.load();

        String? seenSystemPrompt;
        final toolOutputs = <String>[];
        var step = 0;
        Future<String> fakeModel(
          List<ChatMessage> msgs, {
          required String model,
          double temperature = 0.3,
          int maxTokens = 2048,
        }) async {
          seenSystemPrompt ??= msgs.first.content;
          if (step == 0) {
            step++;
            return jsonEncode({
              'react': '🔎',
              'tool_calls': [
                // Today's records MUST NOT include 5-day-old summary! And 17:45 must rank before 09:10!
                {'name': 'search_records', 'arguments': {'dayOffset': 0}},
                // Speaker suffix stripping + mark search
                {
                  'name': 'search_records',
                  'arguments': {'speaker': '孔康（机主本人）', 'query': '冻结主干'},
                },
                // Range + afternoon filter + IDF snippet centering on 黄金眼
                {
                  'name': 'search_records',
                  'arguments': {
                    'minDayOffset': 4,
                    'maxDayOffset': 6,
                    'timeOfDay': 'afternoon',
                    'query': '老陈 黄金眼',
                  },
                },
                // Paginated detail read past 4,000 chars!
                {
                  'name': 'get_record_detail',
                  'arguments': {'id': 'old-long', 'offsetChars': 4000},
                },
              ],
            });
          }
          toolOutputs.add(msgs.last.content);
          return jsonEncode({'react': '👌', 'reply': '核对完毕，暗号是北极星。'});
        }

        final worker = AgentHarnessWorker(complete: fakeModel, inProcess: true);
        final ctrl = AgentChatController(
          appStore: appStore,
          agentConfig: cfg,
          completion: _SimpleCompletion((m) => fakeModel(m, model: 'test')),
          worker: worker,
          agentDirResolver: () async => dir.path,
          clock: () => DateTime(2026, 11, 20, 18, 30), // 周五
        );
        addTearDown(() async {
          await worker.dispose();
          ctrl.dispose();
        });

        await ctrl.sendMessage('核对今日与五天前记录');
        expect(ctrl.errorMessage, isNull);
        expect(seenSystemPrompt, contains('周'));
        expect(toolOutputs, hasLength(1));

        final rawJson = RegExp(r'\[.*\]', dotAll: true)
            .firstMatch(toolOutputs.single)!
            .group(0)!;
        final decodedCalls = jsonDecode(rawJson) as List<dynamic>;

        // Tool 0: dayOffset == 0 -> ['today-late', 'today-early'], NO 'sum-old'!
        final todayRes = jsonDecode(decodedCalls[0]['output'] as String) as Map<String, dynamic>;
        final todayIds = [
          for (final r in (todayRes['results'] as List)) '${r['id']}',
        ];
        expect(todayIds, ['today-late', 'today-early']);
        expect(todayIds, isNot(contains('sum-old')));

        // Tool 1: speaker '孔康（机主本人）' + mark '冻结主干'
        final markRes = jsonDecode(decodedCalls[1]['output'] as String) as Map<String, dynamic>;
        expect(markRes['count'], 1);
        expect((markRes['results'] as List).single['id'], 'today-early');

        // Tool 2: minDayOffset=4..6, afternoon, '老陈 黄金眼' -> snippet centers on 黄金眼!
        final rangeRes = jsonDecode(decodedCalls[2]['output'] as String) as Map<String, dynamic>;
        expect(rangeRes['count'], greaterThanOrEqualTo(1));
        final oldHit = (rangeRes['results'] as List).firstWhere(
          (r) => r['id'] == 'old-long',
        );
        expect('${oldHit['snippet']}', contains('黄金眼'));

        // Tool 3: get_record_detail(id: 'old-long', offsetChars: 4000) reaches tail!
        final detailRes = jsonDecode(decodedCalls[3]['output'] as String) as Map<String, dynamic>;
        expect(detailRes['ok'], isTrue);
        expect('${detailRes['body']}', contains('北极星'));

        // Unrelated AppStore UI ticks (selection toggle, filter switch) must NOT rebuild _collectDocuments
        final buildsBefore = ctrl.debugCollectDocumentsCount;
        appStore.toggleSel('today-early');
        appStore.setFilter(FeedFilter.event);
        await Future<void>.delayed(const Duration(milliseconds: 320));
        expect(ctrl.debugCollectDocumentsCount, buildsBefore);
      },
    );
  });
}

class _SimpleCompletion implements ChatCompletion {
  _SimpleCompletion(this._fn);
  final Future<String> Function(List<ChatMessage> messages) _fn;

  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) => _fn(messages);
}

RecordEvent _mkEvent({
  required String id,
  required int dayOffset,
  required String time,
  required String text,
  String speakers = '未区分',
  String mark = '',
}) {
  return RecordEvent(
    id: id,
    dayOffset: dayOffset,
    title: '记录-$id',
    brief: text,
    longText: text,
    time: time,
    dur: '5分',
    speakers: speakers,
    mark: mark,
    srcMap: '',
    dialog: [TurnLine(speakers, text, time)],
    raw: const [],
  );
}
