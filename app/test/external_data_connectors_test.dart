// 第三方笔记、阅读与录音软件 API 接入全链路验收：
//
// 1. 7 款笔记/阅读连接器（Notion、语雀、Obsidian、flomo、微信读书、印象笔记 Thrift、Readwise）
//    与 4 款录音软件连接器（Plaud、Limitless、Omi 云端、Fireflies.ai）全部支持真实协议与无限翻页；
// 2. ExternalDataHubStore 仅将密钥存于 SecureStore（不落明文偏好），支持各源 importedCount 隔离、
//    指纹更新检测、单源故障隔离与 TaskScheduler 每小时自动检查调度；
// 3. Setting →「笔记与阅读软件（API）」/「第三方录音软件（API）」Widget 端到端配置、自动导入开关、
//    手动同步、时间轴及详情页无音频状态展示。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/storage/storage.dart';
import 'package:recording_card/core/store/agent_config_store.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/external_data/connectors/evernote_connector.dart';
import 'package:recording_card/services/external_data/connectors/fireflies_connector.dart';
import 'package:recording_card/services/external_data/connectors/flomo_connector.dart';
import 'package:recording_card/services/external_data/connectors/limitless_connector.dart';
import 'package:recording_card/services/external_data/connectors/notion_connector.dart';
import 'package:recording_card/services/external_data/connectors/obsidian_connector.dart';
import 'package:recording_card/services/external_data/connectors/omi_cloud_connector.dart';
import 'package:recording_card/services/external_data/connectors/plaud_connector.dart';
import 'package:recording_card/services/external_data/connectors/readwise_connector.dart';
import 'package:recording_card/services/external_data/connectors/weread_connector.dart';
import 'package:recording_card/services/external_data/connectors/yuque_connector.dart';
import 'package:recording_card/services/external_data/external_connector.dart';
import 'package:recording_card/services/external_data/external_data_hub_store.dart';
import 'package:recording_card/services/external_data/external_data_scheduler.dart';
import 'package:recording_card/services/external_data/getnote_client.dart';
import 'package:recording_card/services/external_data/getnote_sync_store.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/schedule/task_scheduler.dart';
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

http.Response _jsonResp(
  Object body, [
  int status = 200,
  Map<String, String>? headers,
]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    ...?headers,
  },
);

Future<AppStore> _newAppStore() async {
  final model = SummaryModel();
  return AppStore(
    events: const [],
    generator: await model.generator(),
    loadPersistedState: false,
  );
}

ExternalDataHubStore _singleHub(
  ExternalDataConnector connector,
  http.Client mockClient, {
  InMemorySecureStore? secure,
  InMemoryStore? prefs,
}) {
  return ExternalDataHubStore(
    secureStore: secure ?? InMemorySecureStore(),
    prefsStore: prefs ?? InMemoryStore(),
    connectors: [connector],
    httpClientResolver: (_) => mockClient,
  );
}

void main() {
  group('7 款笔记与阅读软件连接器（无限翻页与真实协议）', () {
    test('Notion：Notion-Version 鉴权、search 两页共 80 篇与 block 分页解析', () async {
      final now = DateTime.now();
      final mockClient = MockClient((req) async {
        expect(req.headers['Notion-Version'], NotionConnector.notionVersion);
        expect(req.headers['Authorization'], 'Bearer ntn_secret_1');
        if (req.url.path == '/v1/users/me') {
          return _jsonResp({'object': 'user', 'name': 'RecordingBot'}, 200);
        }
        if (req.url.path == '/v1/search') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final cursor = body['start_cursor'] as String?;
          final start = cursor == null ? 1 : 61;
          final count = cursor == null ? 60 : 20;
          return _jsonResp({
              'results': [
                for (var i = 0; i < count; i++)
                  {
                    'id': 'page_${start + i}',
                    'created_time': now.toIso8601String(),
                    'last_edited_time': now.toIso8601String(),
                    'url': 'https://www.notion.so/page_${start + i}',
                    'properties': {
                      'Name': {
                        'type': 'title',
                        'title': [
                          {'plain_text': 'Notion 笔记 ${start + i}'},
                        ],
                      },
                      'Tags': {
                        'type': 'multi_select',
                        'multi_select': [
                          {'name': '知识库'},
                        ],
                      },
                    },
                  },
              ],
              'has_more': cursor == null,
              'next_cursor': cursor == null ? 'n_p2' : null,
            }, 200);
        }
        if (req.url.path.endsWith('/children')) {
          final bCur = req.url.queryParameters['start_cursor'];
          return _jsonResp({
              'results': [
                {
                  'type': bCur == null ? 'heading_2' : 'paragraph',
                  bCur == null ? 'heading_2' : 'paragraph': {
                    'rich_text': [
                      {
                        'plain_text': bCur == null ? '第一段小标题' : '第二页 Block 正文',
                      },
                    ],
                  },
                },
              ],
              'has_more': bCur == null,
              'next_cursor': bCur == null ? 'blk_2' : null,
            }, 200);
        }
        return http.Response('{}', 404);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        NotionConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('notion', {'apiToken': 'Bearer ntn_secret_1'});
      expect(await hub.testConnection('notion'), isTrue);
      expect(hub.stateFor('notion').statusMessage, contains('RecordingBot'));

      final res = await hub.syncConnector('notion', appStore: appStore);
      expect(res.ok, isTrue);
      expect(res.pagesScanned, 2);
      expect(res.added, 80);
      expect(hub.stateFor('notion').importedCount, 80);
      final ev = appStore.eventByIdOrNull('ext-notion-page_1')!;
      expect(ev.title, 'Notion 笔记 1');
      expect(ev.longText, contains('第一段小标题'));
      expect(ev.longText, contains('第二页 Block 正文'));
      expect(ev.srcMap, startsWith('来源 Notion · '));
    });

    test('语雀：X-Auth-Token 鉴权、repo/docs Offset 无限翻页（115 篇）', () async {
      final now = DateTime.now();
      final mockClient = MockClient((req) async {
        expect(req.headers['X-Auth-Token'], 'yq_tok_1');
        if (req.url.path == '/api/v2/user') {
          return _jsonResp({
              'data': {'login': 'alice', 'name': 'Alice', 'books_count': 1},
            }, 200);
        }
        if (req.url.path == '/api/v2/users/alice/repos') {
          return _jsonResp({
              'data': [
                {
                  'id': 1,
                  'slug': 'work',
                  'namespace': 'alice/work',
                  'name': '工作笔记',
                },
              ],
            }, 200);
        }
        if (req.url.path == '/api/v2/repos/alice/work/docs') {
          final offset = int.parse(req.url.queryParameters['offset'] ?? '0');
          final count = offset == 0 ? 100 : 15;
          return _jsonResp({
              'meta': {'total': 115},
              'data': [
                for (var i = 0; i < count; i++)
                  {
                    'id': offset + i + 1,
                    'slug': 'doc_${offset + i + 1}',
                    'title': '语雀文档 ${offset + i + 1}',
                    'created_at': now.toIso8601String(),
                    'updated_at': now.toIso8601String(),
                  },
              ],
            }, 200);
        }
        if (req.url.path.startsWith('/api/v2/repos/alice/work/docs/')) {
          final slug = req.url.pathSegments.last;
          return _jsonResp({
              'data': {
                'id': slug,
                'slug': slug,
                'title': '语雀详情 $slug',
                'body': '# 标题\n正文内容 $slug',
                'created_at': now.toIso8601String(),
                'updated_at': now.toIso8601String(),
              },
            }, 200);
        }
        return http.Response('{}', 404);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        YuqueConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('yuque', {'token': 'yq_tok_1'});
      expect(await hub.testConnection('yuque'), isTrue);
      final res = await hub.syncConnector('yuque', appStore: appStore);
      expect(res.ok, isTrue);
      expect(res.added, 115);
      expect(res.pagesScanned, 2);
      expect(hub.stateFor('yuque').importedCount, 115);
    });

    test('Obsidian：Local REST API 递归遍历目录、中文路径安全落盘与 mtime 变更更新', () async {
      var mtime = 1763712000000;
      var bodyText = '第一版 Vault 笔记';
      final mockClient = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer obs_key');
        if (req.url.path == '/vault/') {
          return _jsonResp({
              'files': ['Daily/', 'Inbox.md'],
            }, 200);
        }
        if (req.url.path == '/vault/Daily/') {
          return _jsonResp({
              'files': ['2026-11-22 复盘.md'],
            }, 200);
        }
        if (req.url.path == '/vault/Inbox.md') {
          return _jsonResp({
              'content': '收件箱内容',
              'tags': ['inbox'],
              'frontmatter': {'title': '收件箱'},
              'stat': {'ctime': 1763710000000, 'mtime': 1763710000000},
              'size': 12,
            }, 200);
        }
        if (Uri.decodeComponent(req.url.path) == '/vault/Daily/2026-11-22 复盘.md') {
          return _jsonResp({
              'content': bodyText,
              'tags': ['daily'],
              'frontmatter': {'title': '今日复盘'},
              'stat': {'ctime': mtime, 'mtime': mtime},
              'size': bodyText.length,
            }, 200);
        }
        return http.Response('{}', 404);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        ObsidianConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('obsidian', {'apiKey': 'obs_key'});
      expect(await hub.testConnection('obsidian'), isTrue);

      final r1 = await hub.syncConnector('obsidian', appStore: appStore);
      expect(r1.ok, isTrue);
      expect(r1.added, 2);
      expect(hub.stateFor('obsidian').importedCount, 2);

      // 二次同步无变化跳过
      final r2 = await hub.syncConnector('obsidian', appStore: appStore);
      expect(r2.added, 0);
      expect(r2.skippedExisting, 2);

      // 笔记修改后（mtime 变化）自动更新内容且去重计数仍为 2
      mtime += 5000;
      bodyText = '第二版 Vault 笔记已更新';
      final r3 = await hub.syncConnector('obsidian', appStore: appStore);
      expect(r3.updated, 1);
      expect(hub.stateFor('obsidian').importedCount, 2);
      final updatedEvent = appStore.events.firstWhere((e) => e.title == '今日复盘');
      expect(updatedEvent.longText, contains('第二版 Vault 笔记已更新'));
    });

    test('flomo：支持官方 MCP（memo_search 翻页 + memo_batch_get）与 REST 模式', () async {
      final now = DateTime.now();
      // 1) MCP 模式
      final mcpClient = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer flomo_mcp_tok');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final method = body['method'];
        if (method == 'initialize') {
          return _jsonResp({'jsonrpc': '2.0', 'id': body['id'], 'result': {}}, 200,
             {'mcp-session-id': 'sess-1'});
        }
        if (method == 'tools/list') {
          return _jsonResp({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'tools': [
                  {'name': 'memo_search'},
                  {'name': 'memo_batch_get'},
                ],
              },
            }, 200);
        }
        final params = body['params'] as Map<String, dynamic>;
        if (params['name'] == 'memo_search') {
          final args = params['arguments'] as Map<String, dynamic>;
          final cur = args['cursor'];
          if (cur == null) {
            return _jsonResp({
                'jsonrpc': '2.0',
                'id': body['id'],
                'result': {
                  'nextCursor': 'fm_p2',
                  'hasMore': true,
                  'memos': [
                    {
                      'slug': 'm1',
                      'content': '<p>#灵感 第一页 flomo</p>',
                      'created_at': now.toIso8601String(),
                    },
                  ],
                },
              }, 200);
          }
          return _jsonResp({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'hasMore': false,
                'content': [
                  {
                    'type': 'text',
                    'text': jsonEncode({
                      'memos': [
                        {
                          'slug': 'm2',
                          'content': '第二页 flomo #复盘',
                          'created_at': now
                              .subtract(const Duration(minutes: 5))
                              .toIso8601String(),
                        },
                      ],
                    }),
                  },
                ],
              },
            }, 200);
        }
        return http.Response('{}', 404);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final mcpHub = _singleHub(
        FlomoConnector(requestDelay: Duration.zero),
        mcpClient,
      );
      addTearDown(mcpHub.dispose);
      await mcpHub.saveConfig('flomo', {
        'mode': 'mcp',
        'token': 'flomo_mcp_tok',
      });
      expect(await mcpHub.testConnection('flomo'), isTrue);
      final mcpRes = await mcpHub.syncConnector('flomo', appStore: appStore);
      expect(mcpRes.ok, isTrue);
      expect(mcpRes.pagesScanned, 2);
      expect(mcpRes.added, 2);

      // 2) REST 模式翻页
      var restPage = 0;
      final restClient = MockClient((req) async {
        restPage += 1;
        if (restPage == 1) {
          return _jsonResp({
              'data': [
                for (var i = 0; i < 200; i++)
                  {
                    'slug': 'r_$i',
                    'content': 'REST 笔记 $i',
                    'updated_at': (1763712000 - i * 10),
                  },
              ],
            }, 200);
        }
        return _jsonResp({
            'data': [
              {
                'slug': 'r_200',
                'content': 'REST 第 2 页笔记',
                'updated_at': 1763700000,
              },
            ],
          }, 200);
      });
      final restHub = _singleHub(
        FlomoConnector(requestDelay: Duration.zero),
        restClient,
      );
      addTearDown(restHub.dispose);
      await restHub.saveConfig('flomo', {
        'mode': 'rest',
        'token': 'flomo_rest_tok',
      });
      final restRes = await restHub.syncConnector('flomo', appStore: appStore);
      expect(restRes.ok, isTrue);
      expect(restRes.pagesScanned, 2);
      expect(restRes.added, 201);
    });

    test('微信读书：Cookie 鉴权、划线与想法整合、新增划线增量更新及 -2012 过期报错', () async {
      var bookmarkCount = 1;
      var expired = false;
      final mockClient = MockClient((req) async {
        if (expired) {
          return _jsonResp({'errcode': -2012, 'errmsg': 'not login'}, 200);
        }
        if (req.url.path == '/user/notebooks') {
          return _jsonResp({
              'books': [
                {
                  'bookId': 'wr_b1',
                  'sort': 1763712000,
                  'bookmarkCount': bookmarkCount,
                  'noteCount': 1,
                  'reviewCount': 1,
                  'book': {
                    'bookId': 'wr_b1',
                    'title': '深入理解系统',
                    'author': '张三',
                    'category': '技术',
                  },
                },
              ],
            }, 200);
        }
        if (req.url.path == '/book/bookmarklist') {
          return _jsonResp({
              'chapters': [
                {'chapterUid': 1, 'title': '第一章 基础'},
              ],
              'updated': [
                {
                  'chapterUid': 1,
                  'markText': '好记性不如烂笔头',
                  'createTime': 1763712000,
                },
                if (bookmarkCount > 1)
                  {
                    'chapterUid': 1,
                    'markText': '第二条新增划线',
                    'createTime': 1763712500,
                  },
              ],
            }, 200);
        }
        if (req.url.path == '/review/list') {
          return _jsonResp({
              'reviews': [
                {
                  'review': {
                    'abstract': '原句摘录',
                    'content': '这条写得非常透彻',
                    'createTime': 1763712100,
                  },
                },
              ],
            }, 200);
        }
        return http.Response('{}', 404);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        WeReadConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('weread', {'cookie': 'wr_vid=1; wr_skey=abc'});
      expect(await hub.testConnection('weread'), isTrue);
      final r1 = await hub.syncConnector('weread', appStore: appStore);
      expect(r1.added, 1);
      expect(appStore.eventByIdOrNull('ext-weread-wr_b1')!.longText, contains('这条写得非常透彻'));

      // 新增划线后自动检测更新
      bookmarkCount = 2;
      final r2 = await hub.syncConnector('weread', appStore: appStore);
      expect(r2.updated, 1);
      expect(appStore.eventByIdOrNull('ext-weread-wr_b1')!.longText, contains('第二条新增划线'));

      // Cookie 过期返回明确中文提示
      expired = true;
      expect(await hub.testConnection('weread'), isFalse);
      expect(hub.stateFor('weread').errorMessage, contains('Cookie'));
    });

    test('印象笔记 / Evernote：真实 Thrift 二进制帧翻页（60 条）、ENML 转纯文本与 shard 路由', () async {
      final token = 'S=s1:U=test:E=999:C=1';
      expect(
        EvernoteConnector.resolveNoteStoreUrl({
          'region': 'yinxiang',
          'developerToken': token,
        }),
        'https://app.yinxiang.com/shard/s1/notestore',
      );

      final mockClient = MockClient.streaming((req, bodyStream) async {
        final reqBytes = Uint8List.fromList(await bodyStream.toBytes());
        final reqText = utf8.decode(reqBytes, allowMalformed: true);
        if (reqText.contains('findNotesMetadata')) {
          // 从二进制载荷中读出 offset=0 或 50（I32 field 3）
          final isFirst = !reqText.contains('note_guid_1') &&
              ByteData.sublistView(reqBytes).getInt32(reqBytes.length - 20) == 0;
          // 更稳妥：检查是否已出现过第一次调用；直接按字节查找 field id 3 (0x08 0x00 0x03)
          var offsetVal = 0;
          for (var i = 0; i + 6 < reqBytes.length; i++) {
            if (reqBytes[i] == EvernoteThriftCodec.tI32 &&
                reqBytes[i + 1] == 0 &&
                reqBytes[i + 2] == 3) {
              offsetVal = ByteData.sublistView(reqBytes).getInt32(i + 3, Endian.big);
              break;
            }
          }
          // 注意 NoteFilter 内部没有 field 3 (words 未传)，故第一个 i32 field 3 就是 offset
          final start = isFirst ? offsetVal : offsetVal;
          final count = start == 0 ? 50 : 10;
          final reply = EvernoteThriftCodec.encodeFindNotesMetadataReply(
            EvernoteNotesMetadataList(
              startIndex: start,
              totalNotes: 60,
              notes: [
                for (var i = 0; i < count; i++)
                  EvernoteNoteMetadata(
                    guid: 'en_guid_${start + i + 1}',
                    title: '印象笔记 ${start + i + 1}',
                    createdMs: 1763712000000 + (start + i) * 1000,
                    updatedMs: 1763712000000 + (start + i) * 1000,
                  ),
              ],
            ),
          );
          return http.StreamedResponse(Stream.value(reply), 200);
        }
        final reply = EvernoteThriftCodec.encodeGetNoteContentReply(
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">'
          '<en-note><p>重要记录</p><div><en-todo checked="true"/>完成接口联调</div></en-note>',
        );
        return http.StreamedResponse(Stream.value(reply), 200);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        EvernoteConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('evernote', {
        'region': 'yinxiang',
        'developerToken': token,
      });
      expect(await hub.testConnection('evernote'), isTrue);
      expect(hub.stateFor('evernote').statusMessage, contains('60'));

      final res = await hub.syncConnector('evernote', appStore: appStore);
      expect(res.ok, isTrue);
      expect(res.pagesScanned, 2);
      expect(res.added, 60);
      final ev = appStore.eventByIdOrNull('ext-evernote-en_guid_1')!;
      expect(ev.longText, contains('重要记录'));
      expect(ev.longText, contains('[x] 完成接口联调'));
    });

    test('Readwise：Token Auth 校验与 export nextPageCursor 两页全量导出', () async {
      final mockClient = MockClient((req) async {
        expect(req.headers['Authorization'], 'Token rw_tok_1');
        if (req.url.path == '/api/v2/auth/') {
          return http.Response('', 204);
        }
        if (req.url.path == '/api/v2/export/') {
          final cur = req.url.queryParameters['pageCursor'];
          if (cur == null) {
            return _jsonResp({
                'nextPageCursor': 'rw_p2',
                'results': [
                  {
                    'user_book_id': 101,
                    'title': 'Clean Architecture',
                    'author': 'Robert Martin',
                    'category': 'books',
                    'source': 'kindle',
                    'highlights': [
                      {
                        'id': 1,
                        'text': 'Architecture is about intent.',
                        'note': '核心观点',
                        'highlighted_at': DateTime.now().toIso8601String(),
                      },
                    ],
                  },
                ],
              }, 200);
          }
          return _jsonResp({
              'nextPageCursor': null,
              'results': [
                {
                  'user_book_id': 102,
                  'title': 'Designing Data-Intensive Applications',
                  'author': 'Martin Kleppmann',
                  'highlights': [
                    {
                      'id': 2,
                      'text': 'Reliability, scalability, maintainability.',
                      'highlighted_at': DateTime.now().toIso8601String(),
                    },
                  ],
                },
              ],
            }, 200);
        }
        return http.Response('{}', 404);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        ReadwiseConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('readwise', {'accessToken': 'rw_tok_1'});
      expect(await hub.testConnection('readwise'), isTrue);
      final res = await hub.syncConnector('readwise', appStore: appStore);
      expect(res.ok, isTrue);
      expect(res.pagesScanned, 2);
      expect(res.added, 2);
    });
  });

  group('4 款第三方录音软件连接器（无限翻页与逐字稿解析）', () {
    test('Plaud：API 模式两页 65 条录音全量同步与摘要/说话人逐字稿解析', () async {
      final mockClient = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer plaud_tok');
        if (req.url.path == '/file/simple/web') {
          final skip = int.parse(req.url.queryParameters['skip'] ?? '0');
          final limit = int.parse(req.url.queryParameters['limit'] ?? '50');
          if (limit == 1) {
            return _jsonResp({
                'code': 200,
                'data': {
                  'total': 65,
                  'list': [
                    {'file_id': 'pl_1', 'title': 'Plaud 样例录音'},
                  ],
                },
              }, 200);
          }
          final count = skip == 0 ? 50 : 15;
          return _jsonResp({
              'code': 200,
              'data': {
                'total': 65,
                'has_more': skip == 0,
                'list': [
                  for (var i = 0; i < count; i++)
                    {
                      'file_id': 'pl_${skip + i + 1}',
                      'title': 'Plaud 录音 ${skip + i + 1}',
                      'duration': 600,
                      'start_time': 1763712000 + (skip + i) * 60,
                    },
                ],
              },
            }, 200);
        }
        if (req.url.path.startsWith('/file/detail/')) {
          final id = req.url.pathSegments.last;
          return _jsonResp({
              'code': 200,
              'data': {
                'file_id': id,
                'title': 'Plaud 详情 $id',
                'duration': 600,
                'start_time': 1763712000,
                'summary': {
                  'overview': '讨论项目排期',
                  'key_points': ['确定发布时间'],
                },
                'transcript': {
                  'segments': [
                    {
                      'speaker': 'Speaker 1',
                      'start_time': 0.5,
                      'end_time': 3.2,
                      'text': '我们来看一下本周排期。',
                    },
                  ],
                },
              },
            }, 200);
        }
        return http.Response('{}', 404);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        PlaudConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('plaud', {
        'mode': 'api',
        'region': 'global',
        'accessToken': 'plaud_tok',
      });
      expect(await hub.testConnection('plaud'), isTrue);
      final res = await hub.syncConnector('plaud', appStore: appStore);
      expect(res.ok, isTrue);
      expect(res.pagesScanned, 2);
      expect(res.added, 65);
      final ev = appStore.eventByIdOrNull('ext-plaud-pl_1')!;
      expect(ev.brief, contains('讨论项目排期'));
      expect(ev.dialog.first.spk, 'Speaker 1');
      expect(ev.srcMap, startsWith('来源 Plaud · '));
    });

    test('Limitless：X-API-Key 与 meta.lifelogs.nextCursor 多页同步', () async {
      final now = DateTime.now();
      final mockClient = MockClient((req) async {
        expect(req.headers['X-API-Key'], 'lim_key');
        final cur = req.url.queryParameters['cursor'];
        final limit = req.url.queryParameters['limit'];
        if (limit == '1') {
          return _jsonResp({
              'lifelogs': [
                {'id': 'l1', 'title': 'Limitless 早会', 'startTime': now.toIso8601String()},
              ],
            }, 200);
        }
        return _jsonResp({
            'lifelogs': [
              {
                'id': cur == null ? 'lim_1' : 'lim_2',
                'title': cur == null ? 'Limitless 记录 1' : 'Limitless 记录 2',
                'startTime': now.toIso8601String(),
                'endTime': now.add(const Duration(minutes: 10)).toIso8601String(),
                'contents': [
                  {
                    'speakerName': 'Alice',
                    'content': '确认方案细节',
                    'startOffsetMs': 0,
                    'endOffsetMs': 3000,
                  },
                ],
              },
            ],
            'meta': {
              'lifelogs': {
                'nextCursor': cur == null ? 'lim_p2' : null,
              },
            },
          }, 200);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        LimitlessConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('limitless', {'apiKey': 'lim_key'});
      expect(await hub.testConnection('limitless'), isTrue);
      final res = await hub.syncConnector('limitless', appStore: appStore);
      expect(res.ok, isTrue);
      expect(res.pagesScanned, 2);
      expect(res.added, 2);
    });

    test('Omi 云端：Bearer Token 与 conversations offset 两页共 60 条同步', () async {
      final now = DateTime.now();
      final mockClient = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer omi_dev_1');
        final limit = int.parse(req.url.queryParameters['limit'] ?? '50');
        final offset = int.parse(req.url.queryParameters['offset'] ?? '0');
        final count = limit == 1 ? 1 : (offset == 0 ? 50 : 10);
        return _jsonResp([
            for (var i = 0; i < count; i++)
              {
                'id': 'omi_${offset + i + 1}',
                'started_at': now.toIso8601String(),
                'finished_at': now.add(const Duration(minutes: 5)).toIso8601String(),
                'structured': {
                  'title': 'Omi 对话 ${offset + i + 1}',
                  'overview': '概览内容',
                  'category': 'work',
                },
                'transcript_segments': [
                  {'text': '你好', 'speaker': 'SPEAKER_0', 'start': 0.0, 'end': 1.2},
                ],
              },
          ], 200);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        OmiCloudConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('omi_cloud', {'apiKey': 'omi_dev_1'});
      expect(await hub.testConnection('omi_cloud'), isTrue);
      final res = await hub.syncConnector('omi_cloud', appStore: appStore);
      expect(res.ok, isTrue);
      expect(res.pagesScanned, 2);
      expect(res.added, 60);
    });

    test('Fireflies.ai：GraphQL transcripts(limit, skip) 两页共 55 条同步', () async {
      final mockClient = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer ff_key');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final query = '${body['query']}';
        if (query.contains('user')) {
          return _jsonResp({
              'data': {
                'user': {'user_id': 'u1', 'name': 'Bob'},
              },
            }, 200);
        }
        final vars = body['variables'] as Map<String, dynamic>;
        final skip = (vars['skip'] as num).toInt();
        final count = skip == 0 ? 50 : 5;
        return _jsonResp({
            'data': {
              'transcripts': [
                for (var i = 0; i < count; i++)
                  {
                    'id': 'ff_${skip + i + 1}',
                    'title': 'Fireflies 会议 ${skip + i + 1}',
                    'date': 1763712000000,
                    'duration': 15,
                    'summary': {
                      'overview': '会议纪要概述',
                      'action_items': '1. 提交 PR',
                    },
                    'sentences': [
                      {
                        'speaker_name': 'Bob',
                        'text': '下周三上线',
                        'start_time': 1.0,
                        'end_time': 4.0,
                      },
                    ],
                  },
              ],
            },
          }, 200);
      });

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);
      final hub = _singleHub(
        FirefliesConnector(requestDelay: Duration.zero),
        mockClient,
      );
      addTearDown(hub.dispose);

      await hub.saveConfig('fireflies', {'apiKey': 'ff_key'});
      expect(await hub.testConnection('fireflies'), isTrue);
      final res = await hub.syncConnector('fireflies', appStore: appStore);
      expect(res.ok, isTrue);
      expect(res.pagesScanned, 2);
      expect(res.added, 55);
    });
  });

  group('ExternalDataHubStore 密钥隔离、多源互不干扰与每小时自动检查调度', () {
    test('密钥只写 SecureStore，各源计数独立，单源失败不阻断他源，clearAll 彻底抹除', () async {
      final secure = InMemorySecureStore();
      final prefs = InMemoryStore();
      final now = DateTime(2026, 11, 22, 12, 0);
      var clock = now;

      final notionClient = MockClient((req) async {
        if (req.url.path == '/v1/search') {
          return _jsonResp({
              'results': [
                {
                  'id': 'n_1',
                  'created_time': clock.toIso8601String(),
                  'last_edited_time': clock.toIso8601String(),
                  'properties': {
                    'Name': {
                      'type': 'title',
                      'title': [
                        {'plain_text': 'Notion 单源条'},
                      ],
                    },
                  },
                },
              ],
              'has_more': false,
            }, 200);
        }
        return _jsonResp({'results': [], 'has_more': false}, 200);
      });
      final failPlaudClient = MockClient((_) async => http.Response('{}', 401));

      final hub = ExternalDataHubStore(
        secureStore: secure,
        prefsStore: prefs,
        connectors: [
          NotionConnector(requestDelay: Duration.zero),
          PlaudConnector(requestDelay: Duration.zero),
        ],
        httpClientResolver: (id) => id == 'notion' ? notionClient : failPlaudClient,
      );
      addTearDown(hub.dispose);

      final appStore = await _newAppStore();
      addTearDown(appStore.dispose);

      await hub.saveConfig('notion', {'apiToken': 'secret_notion_xyz'});
      await hub.saveConfig('plaud', {
        'mode': 'api',
        'region': 'global',
        'accessToken': 'bad_plaud_tok',
      });

      // 校验密钥未出现在 KeyValueStore 明文中
      final rawPrefs = await prefs.getString('rc.extdata.hub.v1');
      expect(rawPrefs, isNot(contains('secret_notion_xyz')));
      expect(rawPrefs, isNot(contains('bad_plaud_tok')));
      expect(secure.snapshot.values.join(','), contains('secret_notion_xyz'));

      await hub.setAutoImport('notion', true);
      await hub.setAutoImport('plaud', true);

      final getNoteStore = GetNoteSyncStore(
        secureStore: InMemorySecureStore(),
        prefsStore: InMemoryStore(),
        client: GetNoteClient(
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          requestDelay: Duration.zero,
        ),
      );
      addTearDown(getNoteStore.dispose);

      final scheduler = TaskScheduler(
        store: JsonStore(store: InMemoryStore()),
        now: () => clock,
      );
      addTearDown(scheduler.dispose);
      await scheduler.load();
      registerExternalDataSyncHandler(
        scheduler: scheduler,
        appStore: appStore,
        getNoteStore: getNoteStore,
        externalHub: hub,
      );
      await scheduler.ensureTasks(defaultExternalDataTasks());

      final log = await scheduler.runNow(ExternalDataTaskIds.hourlySync);
      expect(log!.success, isFalse); // 因为 plaud 401
      expect(hub.stateFor('notion').importedCount, 1);
      expect(hub.stateFor('plaud').importedCount, 0);
      expect(hub.stateFor('plaud').errorMessage, contains('鉴权失败'));

      // 清理全部凭据
      await hub.clearAll();
      expect(secure.snapshot, isEmpty);
      expect(hub.hasRequiredConfig('notion'), isFalse);
    });
  });

  group('Setting UI 端到端交互（笔记软件与录音软件接入页）', () {
    testWidgets('从 Setting 进入笔记软件（Notion）与录音软件（Plaud）完成配置、自动导入开关与同步', (
      tester,
    ) async {
      final now = DateTime.now();
      final notionMock = MockClient((req) async {
        if (req.url.path == '/v1/users/me') {
          return _jsonResp({'name': 'TestBot'}, 200);
        }
        if (req.url.path == '/v1/search') {
          return _jsonResp({
              'results': [
                {
                  'id': 'ui_n1',
                  'created_time': now.toIso8601String(),
                  'last_edited_time': now.toIso8601String(),
                  'properties': {
                    'Name': {
                      'type': 'title',
                      'title': [
                        {'plain_text': 'Notion 设计评审笔记'},
                      ],
                    },
                  },
                },
              ],
              'has_more': false,
            }, 200);
        }
        return _jsonResp({
            'results': [
              {
                'type': 'paragraph',
                'paragraph': {
                  'rich_text': [
                    {'plain_text': 'Notion 同步正文内容。'},
                  ],
                },
              },
            ],
            'has_more': false,
          }, 200);
      });
      final plaudMock = MockClient((req) async {
        if (req.url.path == '/file/simple/web') {
          return _jsonResp({
              'code': 200,
              'data': {
                'total': 1,
                'has_more': false,
                'list': [
                  {
                    'file_id': 'ui_p1',
                    'title': 'Plaud 客户沟通录音',
                    'duration': 180,
                    'start_time': now.millisecondsSinceEpoch ~/ 1000,
                  },
                ],
              },
            }, 200);
        }
        return _jsonResp({
            'code': 200,
            'data': {
              'file_id': 'ui_p1',
              'title': 'Plaud 客户沟通录音',
              'duration': 180,
              'start_time': now.millisecondsSinceEpoch ~/ 1000,
              'summary': {'overview': '对齐了 API 同步方案。'},
              'transcript': {
                'segments': [
                  {'speaker': 'Speaker 1', 'text': '下周开始联调。'},
                ],
              },
            },
          }, 200);
      });

      final appStore = await _newAppStore();
      final agentConfig = AgentConfigStore();
      final device = DeviceStore(
        gateway: FakeCardGateway(),
        liveActivityService: _TrackingLiveActivity(),
        phoneMicBackend: _StubPhoneMicBackend(),
      );
      final getNoteStore = GetNoteSyncStore(
        secureStore: InMemorySecureStore(),
        prefsStore: InMemoryStore(),
      );
      final externalHub = ExternalDataHubStore(
        secureStore: InMemorySecureStore(),
        prefsStore: InMemoryStore(),
        connectors: ExternalDataHubStore.buildDefaultConnectors(
          requestDelay: Duration.zero,
        ),
        httpClientResolver: (id) => id == 'plaud' ? plaudMock : notionMock,
      );

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(device.dispose);
      addTearDown(appStore.dispose);
      addTearDown(agentConfig.dispose);
      addTearDown(getNoteStore.dispose);
      addTearDown(externalHub.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: AppShell(
            store: appStore,
            device: device,
            agentConfig: agentConfig,
            getNoteStore: getNoteStore,
            externalDataHub: externalHub,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nav-setting')));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('set-ext-notes')),
        220,
        scrollable: find.descendant(
          of: find.byKey(const Key('setting-list')),
          matching: find.byType(Scrollable),
        ).first,
      );
      expect(tester.widget<Text>(find.byKey(const Key('sv-extnotes'))).data, '未配置');
      expect(
        tester.widget<Text>(find.byKey(const Key('sv-extrecorders'))).data,
        '未配置',
      );

      // 1) 笔记与阅读软件（API）
      await tester.tap(find.byKey(const Key('set-ext-notes')));
      await tester.pumpAndSettle();
      for (final id in const [
        'notion',
        'yuque',
        'obsidian',
        'flomo',
        'weread',
        'evernote',
        'readwise',
      ]) {
        expect(find.byKey(Key('ext-conn-$id')), findsOneWidget);
      }

      await tester.enterText(
        find.byKey(const Key('ext-field-notion-apiToken')),
        'ntn_ui_token',
      );
      await tester.tap(find.byKey(const Key('ext-test-notion')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('ext-status-notion')),
          matching: find.textContaining('已连接'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('ext-sync-notion')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('ext-status-notion')),
          matching: find.textContaining('已导入 1 条'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('sv-extnotes'))).data,
        '已导入 1 条',
      );

      // 2) 第三方录音软件（API）
      await tester.scrollUntilVisible(
        find.byKey(const Key('set-ext-recorders')),
        220,
        scrollable: find.descendant(
          of: find.byKey(const Key('setting-list')),
          matching: find.byType(Scrollable),
        ).first,
      );
      await tester.tap(find.byKey(const Key('set-ext-recorders')));
      await tester.pumpAndSettle();
      for (final id in const ['plaud', 'limitless', 'omi_cloud', 'fireflies']) {
        expect(find.byKey(Key('ext-conn-$id')), findsOneWidget);
      }

      await tester.enterText(
        find.byKey(const Key('ext-field-plaud-accessToken')),
        'plaud_ui_tok',
      );
      await tester.ensureVisible(find.byKey(const Key('ext-auto-row-plaud')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ext-auto-row-plaud')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('ext-status-plaud')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<RCSwitch>(find.byKey(const Key('ext-auto-plaud'))).on,
        isTrue,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('ext-status-plaud')),
          matching: find.textContaining('已导入 1 条'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('sv-extrecorders'))).data,
        '自动 1 源 · 已导入 1 条',
      );

      // 3) 时间轴与详情验证
      await tester.tap(find.byKey(const Key('nav-timeline')));
      await tester.pumpAndSettle();
      expect(find.text('Notion 设计评审笔记'), findsOneWidget);
      expect(find.text('Plaud 客户沟通录音'), findsOneWidget);

      await tester.tap(find.text('Plaud 客户沟通录音'));
      await tester.pumpAndSettle();
      expect(
        appStore.eventByIdOrNull('ext-plaud-ui_p1')?.srcMap,
        startsWith('来源 Plaud · '),
      );
      await tester.tap(find.byKey(const Key('detail-ext-plaud-ui_p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('det-tab-raw')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('raw-sticky-player')), findsNothing);
    });
  });
}
