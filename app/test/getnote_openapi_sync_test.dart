// 得到大脑 / Get 笔记官方 OpenAPI 第三方数据接入全链路验收：
//
// 1. GetNoteClient 请求头直传 Authorization（自动剥离误填的 Bearer 前缀）与 X-Client-ID，
//    支持 200/401/429 错误归一、cursor/next_cursor 分页、int64 id 回退、detail audio/turns 解析；
// 2. GetNoteSyncStore 默认仅导入录音/会议类笔记，跳过 plain_text/link 且不调 detail；
//    重复同步按 note_id 幂等跳过且不调 detail；开启「同时导入其他文字/链接笔记」后补齐短文本并保留碎片阈值豁免；
// 3. 写入 RecordingStore 并经 AppStore.refreshFromStore() 重载后完整留存，
//    SegmentProjection 不将外部导入记录与相邻蓝牙录音合并，collectSpeechGroups 自动跳过外部导入记录；
// 4. Setting →「第三方数据接入 → 得到大脑 / Get 笔记」界面完成测试连接、立即同步、时间轴与详情页展示及凭据清空。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/external_data/external_data_hub_store.dart';
import 'package:recording_card/services/external_data/external_data_scheduler.dart';
import 'package:recording_card/services/external_data/getnote_client.dart';
import 'package:recording_card/services/external_data/getnote_sync_store.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';
import 'package:recording_card/services/recordings/multi_track_reconciler.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/recordings/segment_projection.dart';
import 'package:recording_card/services/schedule/task_scheduler.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';
import 'package:recording_card/services/transcribe/slice_planner.dart';
import 'package:recording_card/services/transcribe/speech_engine.dart';
import 'package:recording_card/services/transcribe/speech_models.dart';
import 'package:recording_card/widgets/rc_switch.dart';

import 'support/fake_gateway.dart';
import 'support/model_stub.dart';
import 'support/test_transitions.dart';

class _TrackingLiveActivity extends LiveActivityService {
  _TrackingLiveActivity()
    : super(
        capabilitiesOverride: const LiveActivityCapabilities(
          supportsLiveActivities: false,
          supportsDynamicIsland: false,
          supportsActionButton: false,
          areActivitiesEnabled: false,
        ),
      );
}

class _StubPhoneMicBackend implements PhoneMicBackend {
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
  }) async {}

  @override
  Future<void> stopCapture() async {}
}

class _FakeEngine implements SpeechEngine {
  @override
  Future<void> load({
    required String modelPath,
    required String tokensPath,
    String language = 'auto',
    int numThreads = 2,
  }) async {}

  @override
  Future<AsrResult> transcribe(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => AsrResult(
    text: '测试占位转写',
    tokens: const [],
    timestampsMs: const [],
    audioMs: samples.length * 1000 ~/ sampleRate,
  );

  @override
  Future<void> loadVad(String vadPath) async {}

  @override
  Future<List<SpeechSpan>> detectSpeech(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => [SpeechSpan(0, samples.length)];

  @override
  Future<void> loadSpeakerEmbedding(String modelPath) async {}

  @override
  Future<List<double>> embedSpeaker(
    Float32List samples, {
    int sampleRate = 16000,
  }) async => const [1, 0, 0];

  @override
  Future<void> dispose() async {}
}

class _FakeModels implements SpeechModelProvider {
  @override
  Future<SpeechModelPaths?> resolve() async => const SpeechModelPaths(
    asrModelPath: '/models/asr.onnx',
    tokensPath: '/models/tokens.txt',
    vadPath: '/models/vad.onnx',
    speakerEmbeddingPath: '/models/spk.onnx',
  );
}

class _NoopChat implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async => jsonEncode([]);
}

void main() {
  group('GetNoteClient OpenAPI', () {
    test('直传原始 Authorization 与 X-Client-ID，自动剥离 Bearer 前缀并支持分页与详情解析', () async {
      final seenRequests = <http.Request>[];
      final mockClient = MockClient((req) async {
        seenRequests.add(req);
        if (req.url.path == '/open/api/v1/resource/note/list') {
          final cursor = req.url.queryParameters['cursor'];
          if (cursor == null) {
            return http.Response(
              jsonEncode({
                'code': 0,
                'message': 'success',
                'data': {
                  'notes': [
                    {
                      'id': 1907975006118548200,
                      'title': '周会讨论',
                      'note_type': 'recorder_audio',
                      'content': '初步纪要',
                      'created_at': 1763712000,
                      'tags': [
                        {'name': '周会'},
                        '产品',
                      ],
                    },
                  ],
                  'pagination': {'has_more': true, 'next_cursor': 'cur_page_2'},
                  'total': 2,
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'code': 0,
              'message': 'success',
              'data': {
                'notes': [
                  {
                    'note_id': 'gn_page2',
                    'title': '网页摘录',
                    'note_type': 'link',
                    'content': '笔记评价',
                    'ref_content': '原文摘录片段',
                    'created_at': '2026-11-21T10:30:00Z',
                  },
                ],
                'has_more': false,
                'next_cursor': '0',
                'total': 2,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path == '/open/api/v1/resource/note/detail') {
          final id = req.url.queryParameters['id'];
          return http.Response(
            jsonEncode({
              'code': 0,
              'message': 'success',
              'data': {
                'id': 1907975006118548200,
                'note_id': id,
                'title': '周会讨论详情',
                'note_type': 'recorder_audio',
                'summary': '确定本周五前完成发布联调。',
                'content': '说话人 1：周三前把接口对通。\n说话人 2：没问题。',
                'created_at': '2026-11-21T09:15:00+08:00',
                'audio': {
                  'duration': 420.5,
                  'play_url': 'https://cdn.biji.com/audio/123.mp3',
                  'original': '那个……周三前把接口对通啊。行，没问题。',
                  'segments': [
                    {
                      'speaker': '说话人 1',
                      'text': '周三前把接口对通。',
                      'start_ms': 1500,
                      'end_ms': 4200,
                    },
                    {
                      'speaker': '说话人 2',
                      'text': '没问题。',
                      'start': 5.0,
                      'end': 7.5,
                    },
                  ],
                },
                'tags': ['产品'],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('not found', 404);
      });

      final client = GetNoteClient(
        httpClient: mockClient,
        requestDelay: Duration.zero,
      );

      final probe = await client.testConnection(
        clientId: ' cli_abc ',
        apiKey: 'Bearer gk_live_secret ',
      );
      expect(probe.noteCountHint, 2);
      expect(probe.sampleTitle, '周会讨论');
      expect(seenRequests.first.headers['Authorization'], 'gk_live_secret');
      expect(seenRequests.first.headers['X-Client-ID'], 'cli_abc');

      final p1 = await client.listNotes(
        clientId: 'cli_abc',
        apiKey: 'gk_live_secret',
      );
      expect(p1.hasMore, isTrue);
      expect(p1.nextCursor, 'cur_page_2');
      expect(p1.notes.single.noteId, '1907975006118548200');
      expect(p1.notes.single.tags, ['周会', '产品']);
      expect(p1.notes.single.isAudioOrMeeting, isTrue);

      final p2 = await client.listNotes(
        clientId: 'cli_abc',
        apiKey: 'gk_live_secret',
        cursor: p1.nextCursor,
      );
      expect(p2.hasMore, isFalse);
      expect(p2.nextCursor, isNull);
      expect(p2.notes.single.noteId, 'gn_page2');
      expect(p2.notes.single.isAudioOrMeeting, isFalse);

      final detail = await client.getNoteDetail(
        clientId: 'cli_abc',
        apiKey: 'gk_live_secret',
        noteId: '1907975006118548200',
      );
      expect(detail.audioDurationSec, 420.5);
      expect(detail.rawTranscript, '那个……周三前把接口对通啊。行，没问题。');
      expect(detail.summary, '确定本周五前完成发布联调。');
      expect(detail.turns, hasLength(2));
      expect(detail.turns[0].startMs, 1500);
      expect(detail.turns[0].endMs, 4200);
      expect(detail.turns[1].startMs, 5000);
      expect(detail.turns[1].endMs, 7500);
    });

    test('正确映射 401 鉴权失败与 429 限流错误', () async {
      final client401 = GetNoteClient(
        httpClient: MockClient((_) async => http.Response('{}', 401)),
        requestDelay: Duration.zero,
      );
      await expectLater(
        () => client401.testConnection(clientId: 'cli_1', apiKey: 'bad'),
        throwsA(
          isA<GetNoteApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', contains('鉴权失败')),
        ),
      );

      final client429 = GetNoteClient(
        httpClient: MockClient((_) async => http.Response('{}', 429)),
        requestDelay: Duration.zero,
      );
      await expectLater(
        () => client429.listNotes(clientId: 'cli_1', apiKey: 'key_1'),
        throwsA(
          isA<GetNoteApiException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having((e) => e.message, 'message', contains('限流')),
        ),
      );
    });
  });

  group('GetNoteSyncStore、去重落盘与投影隔离', () {
    test('默认仅导入录音/会议类、幂等跳过已导入、支持开关补齐短文本并持久化到 RecordingStore', () async {
      final now = DateTime.now();
      final detailCalls = <String>[];
      final mockClient = MockClient((req) async {
        if (req.url.path == '/open/api/v1/resource/note/list') {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'notes': [
                  {
                    'note_id': 'aud_1',
                    'title': '产品需求语音评审',
                    'note_type': 'recorder_audio',
                    'content': '本周锁定方案。',
                    'created_at': now.toIso8601String(),
                  },
                  {
                    'note_id': 'mtg_2',
                    'title': '客户复盘会议',
                    'note_type': 'meeting',
                    'content': '确认压测指标。',
                    'created_at': now
                        .subtract(const Duration(minutes: 2))
                        .toIso8601String(),
                  },
                  {
                    'note_id': 'txt_3',
                    'title': '短文本笔记',
                    'note_type': 'plain_text',
                    'content': 'Hi',
                    'created_at': now
                        .subtract(const Duration(minutes: 4))
                        .toIso8601String(),
                  },
                  {
                    'note_id': 'lnk_4',
                    'title': '外部链接摘录',
                    'note_type': 'link',
                    'content': '重点摘要',
                    'ref_content': '原始网页引用正文',
                    'created_at': now
                        .subtract(const Duration(minutes: 6))
                        .toIso8601String(),
                  },
                ],
                'has_more': false,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path == '/open/api/v1/resource/note/detail') {
          final id = req.url.queryParameters['id']!;
          detailCalls.add(id);
          final map = <String, Map<String, dynamic>>{
            'aud_1': {
              'note_id': 'aud_1',
              'title': '产品需求语音评审',
              'note_type': 'recorder_audio',
              'content': '说话人 1：锁定周五发版。\n说话人 2：同意。',
              'created_at': now.toIso8601String(),
              'audio': {'duration': 185, 'original': '锁定周五发版 同意'},
            },
            'mtg_2': {
              'note_id': 'mtg_2',
              'title': '客户复盘会议',
              'note_type': 'meeting',
              'content': '确认压测指标达标。',
              'created_at': now
                  .subtract(const Duration(minutes: 2))
                  .toIso8601String(),
              'audio': {'duration': 90, 'original': '确认压测指标达标'},
            },
            'txt_3': {
              'note_id': 'txt_3',
              'title': 'Hi',
              'note_type': 'plain_text',
              'content': 'Hi',
              'created_at': now
                  .subtract(const Duration(minutes: 4))
                  .toIso8601String(),
            },
            'lnk_4': {
              'note_id': 'lnk_4',
              'title': '外部链接摘录',
              'note_type': 'link',
              'content': '重点摘要',
              'ref_content': '原始网页引用正文',
              'created_at': now
                  .subtract(const Duration(minutes: 6))
                  .toIso8601String(),
            },
          };
          return http.Response(
            jsonEncode({'code': 0, 'data': map[id]}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });

      final tempRoot = await Directory.systemTemp.createTemp('rc-getnote-test-');
      addTearDown(() async {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      });
      final recStore = RecordingStore(
        root: Directory('${tempRoot.path}/recordings'),
        jsonStore: JsonStore(store: InMemoryStore()),
      );
      final pipeline = RecordingPipeline(
        gateway: FakeCardGateway(),
        store: recStore,
        engine: _FakeEngine(),
        models: _FakeModels(),
        liveAudioBaseDir: Directory('${tempRoot.path}/live'),
        polish: SlicePolishService(chat: _NoopChat(), model: 'test-model'),
        segments: SegmentBuildService(chat: _NoopChat(), model: 'test-model'),
      );
      final model = SummaryModel();
      final appStore = AppStore(
        recordings: null,
        generator: await model.generator(),
        jsonStore: JsonStore(store: InMemoryStore()),
        loadPersistedState: false,
      );
      addTearDown(appStore.dispose);
      appStore.attachPipeline(
        pipeline: pipeline,
        store: recStore,
        generator: await model.generator(),
      );

      // 放入一条紧邻同一时间的本地 BLE 蓝牙录音，验证不会与 GETNOTE_* 合并
      final bleFile = RecordingFile(
        deviceName: 'BLE_0001.APM',
        session: 'S1',
        seq: 1,
        startAtMs: now.subtract(const Duration(seconds: 5)).millisecondsSinceEpoch,
        apmPath: '/tmp/BLE_0001.APM',
        durationMs: 4000,
        stage: RecordingStage.ready,
        utterances: const [
          RawUtterance(
            id: 'u1',
            sliceId: '0001',
            startMs: 0,
            endMs: 3000,
            text: '本地蓝牙录音句。',
            speakerLabel: '说话人 1',
          ),
        ],
        segments: [
          SegmentRecord(
            id: 'seg-ble-1',
            sessionId: 'S1',
            index: 0,
            startAtMs: now
                .subtract(const Duration(seconds: 5))
                .millisecondsSinceEpoch,
            endAtMs: now.millisecondsSinceEpoch,
            title: '本地蓝牙讨论',
            brief: '本地蓝牙录音摘要',
            longText: '本地蓝牙录音句。',
            speakerLabels: const ['说话人 1'],
            speakerCount: 1,
            status: SegmentStatus.closed,
          ),
        ],
        createdAtMs: now.millisecondsSinceEpoch,
      );
      await recStore.save(bleFile);
      await appStore.refreshFromStore();

      final secureStore = InMemorySecureStore();
      final prefsStore = InMemoryStore();
      final syncStore = GetNoteSyncStore(
        secureStore: secureStore,
        prefsStore: prefsStore,
        client: GetNoteClient(
          httpClient: mockClient,
          requestDelay: Duration.zero,
        ),
      );
      addTearDown(syncStore.dispose);

      await syncStore.load();
      expect(syncStore.importOtherNotes, isFalse);

      // 首次同步：默认只拉取 aud_1 与 mtg_2，不触发 txt_3/lnk_4 的 detail 请求
      final r1 = await syncStore.syncNow(
        appStore: appStore,
        clientId: 'cli_demo',
        apiKey: 'gk_live_demo',
      );
      expect(r1.ok, isTrue);
      expect(r1.added, 2);
      expect(r1.skippedNonAudio, 2);
      expect(detailCalls, ['aud_1', 'mtg_2']);
      expect(syncStore.importedCount, 2);

      // 再次同步：全部已存在，不再调用 detail
      detailCalls.clear();
      final r2 = await syncStore.syncNow(appStore: appStore);
      expect(r2.added, 0);
      expect(r2.skippedExisting, 2);
      expect(detailCalls, isEmpty);

      // 打开「同时导入其他文字/链接笔记」后再同步：补齐 txt_3 与 lnk_4
      await syncStore.setImportOtherNotes(true);
      final r3 = await syncStore.syncNow(appStore: appStore);
      expect(r3.ok, isTrue);
      expect(r3.added, 2);
      expect(detailCalls, ['txt_3', 'lnk_4']);
      expect(syncStore.importedCount, 4);

      // 确认所有 4 条外部记录 + 1 条本地 BLE 录音都在磁盘重新加载后独立存在（未被合并）
      await appStore.refreshFromStore();
      expect(
        appStore.events.map((e) => e.id).toSet(),
        containsAll([
          'seg-ble-1',
          'getnote-aud_1',
          'getnote-mtg_2',
          'getnote-txt_3',
          'getnote-lnk_4',
        ]),
      );

      // 验证短文本导入记录不被静音/碎片过滤器误隐藏
      final shortEvent = appStore.events.firstWhere(
        (e) => e.id == 'getnote-txt_3',
      );
      expect(isFragmentRecord(shortEvent), isFalse);
      expect(
        appStore.feedGroups.expand((g) => g.items).whereType<RecordEvent>().any(
          (e) => e.id == 'getnote-txt_3',
        ),
        isTrue,
      );

      // 验证外部导入记录标记与来源文案
      final audEvent = appStore.events.firstWhere(
        (e) => e.id == 'getnote-aud_1',
      );
      expect(audEvent.srcMap, startsWith('来源 得到大脑 · '));
      expect(audEvent.speakers, '说话人 1 / 说话人 2');
      expect(audEvent.sourceDeviceLabel, '得到大脑');

      // 验证 collectSpeechGroups 只收集本地 BLE 录音，不把外部笔记送入滚动清洗切片
      final loadedFiles = await recStore.loadAll(refresh: true);
      final speechGroups = SegmentProjection.collectSpeechGroups(loadedFiles);
      expect(speechGroups.map((g) => g.anchorSegmentId).toList(), ['seg-ble-1']);

      // 验证多路比对服务不会拿外部导入笔记与并发 BLE 录音做隐藏或分叉配对
      final recon = await MultiTrackReconciler().reconcile(loadedFiles);
      expect(recon.hiddenSegmentIds, isEmpty);
      expect(recon.forkGroupBySegmentId, isEmpty);

      // 清空凭据后 SecureStore 内密钥彻底抹除
      await syncStore.clearAll();
      expect(secureStore.snapshot, isEmpty);
      expect(syncStore.hasCredentials, isFalse);
    });
  });

  group('Setting UI 端到端交互', () {
    testWidgets('从 Setting 进入得到大脑设置：测试连接 → 同步 → 时间轴与无音频详情页展示', (
      tester,
    ) async {
      final now = DateTime.now();
      final mockClient = MockClient((req) async {
        if (req.url.path == '/open/api/v1/resource/note/list') {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'notes': [
                  {
                    'note_id': 'gn_ui_1',
                    'title': '产品周会 Get 笔记',
                    'note_type': 'recorder_audio',
                    'content': '确定方案与节奏',
                    'created_at': now.toIso8601String(),
                  },
                  {
                    'note_id': 'gn_ui_2',
                    'title': '季度复盘会议',
                    'note_type': 'meeting',
                    'content': '复盘目标完成度',
                    'created_at': now
                        .subtract(const Duration(minutes: 10))
                        .toIso8601String(),
                  },
                  {
                    'note_id': 'gn_ui_3',
                    'title': '普通文字随手记',
                    'note_type': 'plain_text',
                    'content': '不该在默认关态导入的文字',
                    'created_at': now
                        .subtract(const Duration(minutes: 20))
                        .toIso8601String(),
                  },
                ],
                'has_more': false,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path == '/open/api/v1/resource/note/detail') {
          final id = req.url.queryParameters['id']!;
          if (id == 'gn_ui_1') {
            return http.Response(
              jsonEncode({
                'code': 0,
                'data': {
                  'note_id': 'gn_ui_1',
                  'title': '产品周会 Get 笔记',
                  'note_type': 'recorder_audio',
                  'content': '确定发布时间与验收项。',
                  'created_at': now.toIso8601String(),
                  'audio': {'duration': 300, 'original': '原始逐字稿：确定发布时间与验收项。'},
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'note_id': id,
                'title': '季度复盘会议',
                'note_type': 'meeting',
                'content': '复盘目标完成度。',
                'created_at': now
                    .subtract(const Duration(minutes: 10))
                    .toIso8601String(),
                'audio': {'duration': 180, 'original': '原始复盘记录。'},
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });

      final model = SummaryModel();
      final appStore = AppStore(
        events: const [],
        generator: await model.generator(),
        loadPersistedState: false,
      );
      final agentConfig = AgentConfigStore();
      final device = DeviceStore(
        gateway: FakeCardGateway(),
        liveActivityService: _TrackingLiveActivity(),
        phoneMicBackend: _StubPhoneMicBackend(),
      );
      final getNoteStore = GetNoteSyncStore(
        secureStore: InMemorySecureStore(),
        prefsStore: InMemoryStore(),
        client: GetNoteClient(
          httpClient: mockClient,
          requestDelay: Duration.zero,
        ),
      );

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(device.dispose);
      addTearDown(appStore.dispose);
      addTearDown(agentConfig.dispose);
      addTearDown(getNoteStore.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(
            store: appStore,
            device: device,
            agentConfig: agentConfig,
            getNoteStore: getNoteStore,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('nav-setting')));
      await tester.pump();

      await tester.scrollUntilVisible(
        find.byKey(const Key('set-ext-data')),
        220,
        scrollable: find.descendant(
          of: find.byKey(const Key('setting-list')),
          matching: find.byType(Scrollable),
        ).first,
      );
      expect(tester.widget<Text>(find.byKey(const Key('sv-extdata'))).data, '未配置');

      await tester.tap(find.byKey(const Key('set-ext-data')));
      await tester.pumpAndSettle();

      final scopeSwitch = tester.widget<RCSwitch>(
        find.byKey(const Key('getnote-import-other-switch')),
      );
      expect(scopeSwitch.on, isFalse);

      await tester.enterText(
        find.byKey(const Key('getnote-client-id-input')),
        'cli_test',
      );
      await tester.enterText(
        find.byKey(const Key('getnote-api-key-input')),
        'gk_live_test',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('getnote-test-btn')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('getnote-status-card')),
          matching: find.textContaining('已连接'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('getnote-sync-btn')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('getnote-status-card')),
          matching: find.textContaining('已导入 2 条'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('sv-extdata'))).data,
        '已导入 2 条',
      );

      await tester.tap(find.byKey(const Key('nav-timeline')));
      await tester.pumpAndSettle();
      expect(find.text('产品周会 Get 笔记'), findsOneWidget);
      expect(find.text('普通文字随手记'), findsNothing);

      // 展开后进入详情并切到「原始数据」：无本地 WAV 时不显示失效播放器
      await tester.tap(find.text('产品周会 Get 笔记'));
      await tester.pumpAndSettle();
      expect(
        appStore.eventByIdOrNull('getnote-gn_ui_1')?.srcMap,
        startsWith('来源 得到大脑 · '),
      );
      await tester.tap(find.byKey(const Key('detail-getnote-gn_ui_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dt-h3')), findsOneWidget);
      expect(find.text('确定发布时间与验收项。'), findsOneWidget);

      await tester.tap(find.byKey(const Key('det-tab-raw')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('raw-sticky-player')), findsNothing);
      expect(find.textContaining('原始逐字稿：确定发布时间与验收项。'), findsOneWidget);
    });

    testWidgets('自动导入开关可在 Get 笔记设置页切换并持久化', (tester) async {
      final model = SummaryModel();
      final appStore = AppStore(
        events: const [],
        generator: await model.generator(),
        loadPersistedState: false,
      );
      final agentConfig = AgentConfigStore();
      final device = DeviceStore(
        gateway: FakeCardGateway(),
        liveActivityService: _TrackingLiveActivity(),
        phoneMicBackend: _StubPhoneMicBackend(),
      );
      final getNoteStore = GetNoteSyncStore(
        secureStore: InMemorySecureStore(),
        prefsStore: InMemoryStore(),
        client: GetNoteClient(
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          requestDelay: Duration.zero,
        ),
      );

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(device.dispose);
      addTearDown(appStore.dispose);
      addTearDown(agentConfig.dispose);
      addTearDown(getNoteStore.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(
            store: appStore,
            device: device,
            agentConfig: agentConfig,
            getNoteStore: getNoteStore,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nav-setting')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('set-ext-data')),
        220,
        scrollable: find.descendant(
          of: find.byKey(const Key('setting-list')),
          matching: find.byType(Scrollable),
        ).first,
      );
      await tester.tap(find.byKey(const Key('set-ext-data')));
      await tester.pumpAndSettle();

      final autoSwitchFinder = find.byKey(const Key('getnote-auto-import-switch'));
      expect(tester.widget<RCSwitch>(autoSwitchFinder).on, isFalse);

      await tester.scrollUntilVisible(
        find.byKey(const Key('getnote-auto-import-row')),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const Key('getnote-auto-import-row')));
      await tester.pumpAndSettle();
      expect(tester.widget<RCSwitch>(autoSwitchFinder).on, isTrue);
      expect(getNoteStore.autoImport, isTrue);
    });
  });

  group('得到大脑 / Get 笔记无限翻页、退避重试与每小时自动检查', () {
    test('超过 50 条（125 条共 3 页）连续翻页全部导入，支持 data.cursor 与 pagination.next_cursor 回退', () async {
      final now = DateTime.now();
      final listPageSizes = <String?>[];
      final seenCursors = <String?>[];
      final detailFetched = <String>[];

      List<Map<String, dynamic>> makePage(int start, int count) => [
        for (var i = 0; i < count; i++)
          {
            'note_id': 'pg_${start + i}',
            'title': '笔记 ${start + i}',
            'note_type': 'recorder_audio',
            'content': '第 ${start + i} 条录音纪要内容',
            'created_at': now
                .subtract(Duration(minutes: start + i))
                .toIso8601String(),
          },
      ];

      final mockClient = MockClient((req) async {
        if (req.url.path == '/open/api/v1/resource/note/list') {
          final cur = req.url.queryParameters['cursor'];
          listPageSizes.add(req.url.queryParameters['page_size']);
          seenCursors.add(cur);
          if (cur == null) {
            return http.Response(
              jsonEncode({
                'code': 0,
                'data': {
                  'notes': makePage(1, 50),
                  // 模拟服务端 pagination.next_cursor 为空串但 data.cursor 非空的契约变体
                  'pagination': {'has_more': true, 'next_cursor': ''},
                  'cursor': 'cur_page_2',
                  'total': 125,
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          if (cur == 'cur_page_2') {
            return http.Response(
              jsonEncode({
                'code': 0,
                'data': {
                  'notes': makePage(51, 50),
                  'pagination': {'has_more': true, 'next_cursor': 'cur_page_3'},
                  'total': 125,
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'notes': makePage(101, 25),
                'pagination': {'has_more': false, 'next_cursor': '0'},
                'total': 125,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path == '/open/api/v1/resource/note/detail') {
          final id = req.url.queryParameters['id']!;
          detailFetched.add(id);
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'note_id': id,
                'title': '笔记 $id',
                'note_type': 'recorder_audio',
                'content': '详情正文 $id',
                'created_at': now.toIso8601String(),
                'audio': {'duration': 60, 'original': '原始逐字稿 $id'},
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });

      final model = SummaryModel();
      final appStore = AppStore(
        events: const [],
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(appStore.dispose);

      final syncStore = GetNoteSyncStore(
        secureStore: InMemorySecureStore(),
        prefsStore: InMemoryStore(),
        client: GetNoteClient(httpClient: mockClient, requestDelay: Duration.zero),
      );
      addTearDown(syncStore.dispose);

      final result = await syncStore.syncNow(
        appStore: appStore,
        clientId: 'cli_full',
        apiKey: 'gk_live_full',
      );
      expect(result.ok, isTrue);
      expect(result.pagesScanned, 3);
      expect(result.added, 125);
      expect(result.hasMorePending, isFalse);
      expect(syncStore.importedCount, 125);
      expect(syncStore.fullBackfillCompleted, isTrue);
      expect(detailFetched, hasLength(125));
      expect(seenCursors, [null, 'cur_page_2', 'cur_page_3']);
      expect(listPageSizes.toSet(), {'50'});
      expect(appStore.events.where((e) => e.id.startsWith('getnote-')), hasLength(125));
    });

    test('逐页落盘且中途 cancelSync 保留已导入数据，下次同步幂等补齐剩余', () async {
      final now = DateTime.now();
      late GetNoteSyncStore syncStore;
      var cancelledOnce = false;

      final mockClient = MockClient((req) async {
        if (req.url.path == '/open/api/v1/resource/note/list') {
          final cur = req.url.queryParameters['cursor'];
          if (cur == null) {
            return http.Response(
              jsonEncode({
                'code': 0,
                'data': {
                  'notes': [
                    for (var i = 1; i <= 3; i++)
                      {
                        'note_id': 'c_$i',
                        'title': '笔记 c_$i',
                        'note_type': 'recorder_audio',
                        'content': '内容 $i',
                        'created_at': now.toIso8601String(),
                      },
                  ],
                  'has_more': true,
                  'next_cursor': 'p2',
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          // 仅首次进入第 2 页列表请求时取消
          if (!cancelledOnce) {
            cancelledOnce = true;
            syncStore.cancelSync();
          }
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'notes': [
                  {
                    'note_id': 'c_4',
                    'title': '笔记 c_4',
                    'note_type': 'recorder_audio',
                    'content': '内容 4',
                    'created_at': now.toIso8601String(),
                  },
                ],
                'has_more': false,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path == '/open/api/v1/resource/note/detail') {
          final id = req.url.queryParameters['id']!;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'note_id': id,
                'title': '笔记 $id',
                'note_type': 'recorder_audio',
                'content': '正文 $id',
                'created_at': now.toIso8601String(),
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });

      final model = SummaryModel();
      final appStore = AppStore(
        events: const [],
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(appStore.dispose);

      syncStore = GetNoteSyncStore(
        secureStore: InMemorySecureStore(),
        prefsStore: InMemoryStore(),
        client: GetNoteClient(httpClient: mockClient, requestDelay: Duration.zero),
      );
      addTearDown(syncStore.dispose);

      final cancelledRes = await syncStore.syncNow(
        appStore: appStore,
        clientId: 'cli_c',
        apiKey: 'gk_live_c',
      );
      expect(cancelledRes.ok, isTrue);
      expect(cancelledRes.cancelled, isTrue);
      expect(cancelledRes.added, 3);
      expect(syncStore.importedCount, 3);
      expect(syncStore.fullBackfillCompleted, isFalse);

      // 再次同步不再取消，幂等跳过前 3 条并补齐第 4 条
      final resumedRes = await syncStore.syncNow(appStore: appStore);
      expect(resumedRes.ok, isTrue);
      expect(resumedRes.cancelled, isFalse);
      expect(resumedRes.added, 1);
      expect(resumedRes.skippedExisting, 3);
      expect(syncStore.importedCount, 4);
      expect(syncStore.fullBackfillCompleted, isTrue);
    });

    test('瞬态 429 自动重试后成功', () async {
      var calls = 0;
      final client = GetNoteClient(
        httpClient: MockClient((req) async {
          calls += 1;
          if (calls == 1) {
            return http.Response('{}', 429, headers: {'retry-after': '1'});
          }
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'notes': [
                  {
                    'note_id': 'retry_ok',
                    'title': '重试成功笔记',
                    'note_type': 'recorder_audio',
                    'content': '正文',
                    'created_at': DateTime.now().toIso8601String(),
                  },
                ],
                'has_more': false,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
        requestDelay: Duration.zero,
      );
      final probe = await client.testConnection(
        clientId: 'cli_r',
        apiKey: 'gk_live_r',
      );
      expect(calls, 2);
      expect(probe.sampleTitle, '重试成功笔记');
    });

    test('每小时自动检查与 TaskScheduler 联动：未满 60 分钟跳过，满 60 分钟自动拉取', () async {
      var listCalls = 0;
      final now = DateTime(2026, 11, 22, 10, 0);
      var clock = now;

      final mockClient = MockClient((req) async {
        if (req.url.path == '/open/api/v1/resource/note/list') {
          listCalls += 1;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'notes': [
                  {
                    'note_id': 'auto_$listCalls',
                    'title': '自动拉取 $listCalls',
                    'note_type': 'recorder_audio',
                    'content': '自动同步正文 $listCalls',
                    'created_at': clock.toIso8601String(),
                  },
                ],
                'has_more': false,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path == '/open/api/v1/resource/note/detail') {
          final id = req.url.queryParameters['id']!;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'note_id': id,
                'title': '自动拉取 $id',
                'note_type': 'recorder_audio',
                'content': '正文 $id',
                'created_at': clock.toIso8601String(),
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 404);
      });

      final model = SummaryModel();
      final appStore = AppStore(
        events: const [],
        generator: await model.generator(),
        loadPersistedState: false,
      );
      addTearDown(appStore.dispose);

      final syncStore = GetNoteSyncStore(
        secureStore: InMemorySecureStore(),
        prefsStore: InMemoryStore(),
        client: GetNoteClient(httpClient: mockClient, requestDelay: Duration.zero),
      );
      addTearDown(syncStore.dispose);
      await syncStore.saveCredentials(clientId: 'cli_a', apiKey: 'gk_live_a');
      await syncStore.setAutoImport(true);

      final hub = ExternalDataHubStore(
        secureStore: InMemorySecureStore(),
        prefsStore: InMemoryStore(),
        connectors: const [],
      );
      addTearDown(hub.dispose);

      final scheduler = TaskScheduler(
        store: JsonStore(store: InMemoryStore()),
        now: () => clock,
      );
      addTearDown(scheduler.dispose);
      await scheduler.load();
      registerExternalDataSyncHandler(
        scheduler: scheduler,
        appStore: appStore,
        getNoteStore: syncStore,
        externalHub: hub,
      );
      await scheduler.ensureTasks(defaultExternalDataTasks());

      // 第 1 次到期触发
      await scheduler.tick(now: clock);
      expect(syncStore.importedCount, 1);

      // 30 分钟后未满 60 分钟，不触发
      clock = clock.add(const Duration(minutes: 30));
      await scheduler.tick(now: clock);
      expect(syncStore.importedCount, 1);

      // 满 60 分钟后再次触发导入新条目
      clock = clock.add(const Duration(minutes: 30));
      await scheduler.tick(now: clock);
      expect(syncStore.importedCount, 2);
    });
  });
}
