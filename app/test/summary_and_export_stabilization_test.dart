/// Summary Engine, Result UX & Export Stabilization TDD Suite.
///
/// Covers:
/// 1. SummaryGenerator:
///    - Drops redundant LLM `"fullText"` from schema contract while accepting optional `json['fullText']` & falling back to `stitchPolishedFullText`.
///    - Never drops `dialog` when `dialog.length > 6000` and avoids duplicating `longText` + `dialog`.
///    - Skips silent placeholder events (`无语音` / `未识别到语音` with empty dialog/raw) and throws clean `SummaryGenerationException` when all selected events are silent.
///    - Hierarchical Map-Reduce for large selections (`>16,000` chars across 20+ recordings & single large recording), preserving facts/numbers/`[记录id]` with smooth progress `0.10 -> 0.70 -> 0.75 -> 0.95`.
///    - Concise small-recording prompt instruction scaling depth to input length.
/// 2. SummaryResultPage:
///    - Dark Mode (`buildRCDarkTheme()`): zero static `RCColors.*` / white-on-white / dark-on-black text.
///    - InfoPoint tab (`stab-pt`) expands ALL 5+ points (fixes `i < 4` hardcoded loop).
///    - Photo time-window matching via `SourceRef.range` / `_parseClockWindow` & removal of fake `0:0` mind-map leaf fallback.
///    - Persists checked todos across navigation/rebuilds & uses adaptive mind-map root (`card.title` or `'核心脉络'`).
///    - Supports canceling in-flight summary generation (`Key('gen-cancel')` + optional `onCancelGeneration`).
/// 3. Export Services & iPad Crash Fix:
///    - Fixes duplicate transcript bug in `TranscriptExportMode.aiOptimized` (outputs each event's cleaned dialogue once, falling back to `card.fullText` only when `orderedEvents` is empty).
///    - Fixes Markdown sandbox path leak (never writes `/var/mobile/...` or `/Users/...` absolute paths).
///    - Streams PDF page rendering without 40-page truncation cliff & caps `LongImageOptions` memory safely.
///    - Anchors iPadOS share sheet (`sharePositionOrigin`) to the `导出` header button for ALL 4 export formats.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/theme/tokens.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/summary_result_page.dart';
import 'package:recording_card/services/ai/summary_generator.dart';
import 'package:recording_card/services/export/export.dart';
import 'package:recording_card/widgets/store_scope.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/model_stub.dart';

const String _kTinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGMwOR75HxkzkC4AAOFIJTGNUj/yAAAAAElFTkSuQmCC';

(int, int) _readPngDimensions(Uint8List png) {
  // PNG header (8B) + IHDR length (4B) + 'IHDR' (4B) + width (4B BE) + height (4B BE)
  final bd = ByteData.sublistView(png);
  return (bd.getUint32(16, Endian.big), bd.getUint32(20, Endian.big));
}

int _countOccurrences(String haystack, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var index = 0;
  while (true) {
    final found = haystack.indexOf(needle, index);
    if (found < 0) break;
    count++;
    index = found + needle.length;
  }
  return count;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('1. SummaryGenerator Speed, Reliability & Multi-Scale Map-Reduce', () {
    test('drops "fullText" from LLM schema contract while falling back to stitchPolishedFullText & accepting optional fullText', () async {
      final requests = <http.Request>[];
      const conciseJson = '''
{
  "title": "排期与回访结论",
  "overview": "明确了排期缩减与性能优化两项动作。",
  "structure": [{"name": "核心决议", "leaves": ["缩减首版范围", "优化列表加载"]}],
  "points": [{"title": "优先收敛范围", "detail": "移除两个低优先级功能。", "sources": ["e1"]}],
  "todos": ["周五前提交书面结论"]
}
''';
      final gateway = await buildModelGateway(
        MockClient((req) async {
          requests.add(req);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': conciseJson},
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final generator = SummaryGenerator(gateway: gateway);
      final draft = await generator.generate([seedEvents[0], seedEvents[1]]);

      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
      final sysPrompt = messages.first['content'] as String;

      // Schema contract must NOT ask the LLM to regenerate fullText!
      expect(sysPrompt, isNot(contains('"fullText"')));
      // Yet draft.fullText must still be stitched cleanly from ordered events:
      expect(draft.fullText, contains('【13:05 · 客户回访要点】'));
      expect(draft.fullText, contains('【14:20 · 午后项目方向讨论】'));

      // Optional fullText in mock JSON is still honored if provided:
      final mockWithFt = SummaryModel();
      final draftWithFt = await (await mockWithFt.generator()).generate(
        seedEvents.take(2).toList(),
      );
      expect(draftWithFt.fullText, contains('说话人 B（推测）'));
    });

    test('never drops dialog > 6000 chars and does not send duplicate longText + dialog', () async {
      final requests = <http.Request>[];
      final gateway = await buildModelGateway(
        MockClient((req) async {
          requests.add(req);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': jsonEncode({
                        'title': '长对话测试',
                        'overview': '预算敲定为380万元。',
                        'structure': [
                          {'name': '预算', 'leaves': ['380万元上限']}
                        ],
                        'points': [
                          {
                            'title': '预算上限确认',
                            'detail': '尾部确认为380万元整。',
                            'sources': ['e_long_dlg'],
                          }
                        ],
                        'todos': [],
                      }),
                    },
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final generator = SummaryGenerator(gateway: gateway);

      // 1) Event with > 6,500 chars of speaker-attributed dialogue + raw stitched longText
      final turns = <TurnLine>[
        for (var i = 0; i < 170; i++)
          TurnLine(
            i.isEven ? 'A' : 'B',
            '第${i + 1}轮方案评审细节讨论，核对模块接口吞吐指标与灰度回滚策略确保上线质量稳定可靠。',
            '来源 10:00—10:30',
          ),
        const TurnLine('B', '尾部关键结论：二期预算上限锁定为380万元整，周三前签字。', '来源 10:30—10:31'),
      ];
      final rawStitchedLong = turns.map((t) => t.text).join('\n');
      final longDialogEvent = RecordEvent(
        id: 'e_long_dlg',
        dayOffset: 0,
        title: '二期预算评审长会议',
        brief: '围绕二期接口指标与预算上限进行评审。',
        longText: rawStitchedLong,
        time: '10:00',
        dur: '31分00秒',
        speakers: 'A / B',
        mark: '',
        srcMap: '来源 10:00—10:31',
        dialog: turns,
        raw: const [],
      );

      final totalDialogLen = turns.map((t) => '${t.spk}：${t.text}').join('\n').length;
      expect(totalDialogLen, greaterThan(6000));

      await generator.generate([longDialogEvent]);

      final sentUserContents = requests
          .map((r) => ((jsonDecode(r.body)['messages'] as List).last['content'] as String))
          .join('\n');

      // Must include speaker-attributed tail turn even though dialog.length > 6000!
      expect(sentUserContents, contains('B：尾部关键结论：二期预算上限锁定为380万元整，周三前签字。'));
      // Must NOT duplicate every turn twice (once via longText and once via dialog)!
      expect(
        _countOccurrences(sentUserContents, '尾部关键结论：二期预算上限锁定为380万元整，周三前签字。'),
        1,
      );
      // Distinct brief is preserved alongside speaker-attributed dialog:
      expect(sentUserContents, contains('围绕二期接口指标与预算上限进行评审。'));
    });

    test('skips silent placeholder events and throws clean SummaryGenerationException when all selected are silent', () async {
      final requests = <http.Request>[];
      final gateway = await buildModelGateway(
        MockClient((req) async {
          requests.add(req);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': kSummaryJson},
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final generator = SummaryGenerator(gateway: gateway);

      const silent1 = RecordEvent(
        id: 'sil_1',
        dayOffset: 0,
        title: '未识别到语音',
        brief: '这段时间没有识别到人声，原始录音仍保留在本机。',
        longText: '这段时间没有识别到人声，原始录音仍保留在本机，可在详情「原始数据」回听。',
        time: '08:00',
        dur: '5分00秒',
        speakers: '无语音',
        mark: '',
        srcMap: '来源 08:00—08:05',
        dialog: [],
        raw: [],
      );
      const silent2 = RecordEvent(
        id: 'sil_2',
        dayOffset: 0,
        title: '静音片段',
        brief: '',
        longText: '',
        time: '08:10',
        dur: '3分00秒',
        speakers: '无语音',
        mark: '',
        srcMap: '来源 08:10—08:13',
        dialog: [],
        raw: [],
      );

      // All silent -> clean Chinese exception, 0 network calls!
      await expectLater(
        generator.generate(const [silent1, silent2]),
        throwsA(
          isA<SummaryGenerationException>().having(
            (e) => e.message,
            'message',
            '所选记录均为静音片段，暂无可总结的语音内容',
          ),
        ),
      );
      expect(requests, isEmpty);

      // Mixed silent + speech -> skips silent placeholders cleanly
      await generator.generate([silent1, seedEvents.first]);
      expect(requests, hasLength(1));
      final userText =
          ((jsonDecode(requests.single.body)['messages'] as List).last['content'] as String);
      expect(userText, isNot(contains('[sil_1]')));
      expect(userText, isNot(contains('没有识别到人声')));
      expect(userText, contains('[e1]'));
    });

    test('Hierarchical Map-Reduce chunks >16,000-char selections (24 recordings & single huge recording) with smooth progress', () async {
      final requests = <http.Request>[];
      final gateway = await buildModelGateway(
        MockClient((req) async {
          requests.add(req);
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final msgs = (body['messages'] as List).cast<Map<String, dynamic>>();
          final sys = msgs.first['content'] as String;
          final usr = msgs.last['content'] as String;

          final isFinalReduce = sys.contains('"structure"') && sys.contains('"points"');
          if (!isFinalReduce) {
            // Map step: extract [rec_XX] IDs and key markers from this batch
            final ids = RegExp(r'\[(rec_\d+|mega_1)\]')
                .allMatches(usr)
                .map((m) => m.group(1)!)
                .toSet()
                .toList();
            final hasContractAmount = usr.contains('合同金额520万');
            final hasDeadline = usr.contains('12月18日交付');
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'choices': [
                    {
                      'message': {
                        'role': 'assistant',
                        'content': [
                          for (final id in ids) '[$id] 批次事实摘要',
                          if (hasContractAmount) '关键金额：合同金额520万（说话人A承诺）',
                          if (hasDeadline) '关键节点：12月18日交付上线',
                        ].join('\n'),
                      },
                    },
                  ],
                }),
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }

          // Final Reduce step: verify Map digests preserved facts from early & late batches!
          expect(usr, contains('合同金额520万'));
          expect(usr, contains('12月18日交付'));
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': jsonEncode({
                        'title': '全月24条跨周度总结',
                        'overview': '汇总合同金额520万与12月18日交付里程碑。',
                        'structure': [
                          {
                            'name': '商务与交付',
                            'leaves': ['合同金额520万', '12月18日交付']
                          }
                        ],
                        'points': [
                          {
                            'title': '商务签约确认',
                            'detail': '敲定合同金额520万。',
                            'sources': ['rec_01'],
                          },
                          {
                            'title': '最终交付节点',
                            'detail': '锁定12月18日交付。',
                            'sources': ['rec_24'],
                          },
                        ],
                        'todos': ['跟进12月18日交付验收'],
                      }),
                    },
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final generator = SummaryGenerator(gateway: gateway);
      final manyEvents = <RecordEvent>[
        for (var i = 1; i <= 24; i++)
          RecordEvent(
            id: 'rec_${i.toString().padLeft(2, '0')}',
            dayOffset: 24 - i,
            title: '第$i次专题推进会',
            brief: '推进第$i阶段工作项。',
            longText: '',
            time: '14:${(i % 50).toString().padLeft(2, '0')}',
            dur: '12分00秒',
            speakers: 'A / B',
            mark: '',
            srcMap: '',
            dialog: [
              for (var j = 0; j < 18; j++)
                TurnLine(
                  j.isEven ? 'A' : 'B',
                  '第$i场第${j + 1}段详细纪要内容，围绕产研联调排期、客户试用反馈、法务条款审阅展开深入核对'
                  '${i == 1 && j == 0 ? '，正式确认合同金额520万' : ''}'
                  '${i == 24 && j == 17 ? '，最终拍板12月18日交付' : ''}。',
                  '14:00—14:12',
                ),
            ],
            raw: const [],
          ),
      ];

      final progressLog = <(double, String)>[];
      final draft = await generator.generate(
        manyEvents,
        onProgress: (p, s) => progressLog.add((p, s)),
      );

      expect(draft.title, '全月24条跨周度总结');
      expect(draft.points.first.sources.single.eventId, 'rec_01');
      expect(draft.points.last.sources.single.eventId, 'rec_24');
      // Must have run multiple ~12k-char Map batches + 1 Reduce call (not 1 giant prompt):
      expect(requests.length, greaterThanOrEqualTo(3));
      for (var i = 0; i < requests.length - 1; i++) {
        final usr =
            ((jsonDecode(requests[i].body)['messages'] as List).last['content'] as String);
        expect(usr.length, lessThanOrEqualTo(14500));
      }
      // Progress values must advance smoothly through Map (0.10..0.70) and Reduce (0.75..0.95..1.0):
      final progresses = progressLog.map((e) => e.$1).toList();
      for (var i = 1; i < progresses.length; i++) {
        expect(progresses[i], greaterThanOrEqualTo(progresses[i - 1]));
      }
      expect(progresses.any((p) => p >= 0.10 && p <= 0.70), isTrue);
      expect(progresses.any((p) => p >= 0.75 && p <= 0.95), isTrue);
      expect(progresses.last, 1.0);

      // Single huge recording > 16,000 chars is also split into ~12k Map chunks keeping [mega_1]!
      requests.clear();
      final megaEvent = RecordEvent(
        id: 'mega_1',
        dayOffset: 0,
        title: '两小时全员架构评审',
        brief: '超长单条录音。',
        longText: '',
        time: '09:00',
        dur: '120分00秒',
        speakers: 'A / B',
        mark: '',
        srcMap: '来源 09:00—11:00',
        dialog: [
          const TurnLine('A', '开场确认合同金额520万。', '09:00—09:01'),
          for (var k = 0; k < 460; k++)
            TurnLine(
              k.isEven ? 'A' : 'B',
              '架构讨论第${k + 1}节：网关限流、离线转写队列水位锁、端侧向量检索分块与容灾演练指标验证。',
              '09:01—10:59',
            ),
          const TurnLine('B', '收尾锁定12月18日交付。', '10:59—11:00'),
        ],
        raw: const [],
      );
      await generator.generate([megaEvent]);
      expect(requests.length, greaterThanOrEqualTo(3));
      for (var i = 0; i < requests.length - 1; i++) {
        final usr =
            ((jsonDecode(requests[i].body)['messages'] as List).last['content'] as String);
        expect(usr, contains('[mega_1]'));
        expect(usr.length, lessThanOrEqualTo(14500));
      }
    });

    test('Concise Small-Recording Prompt instructs scaling depth to input length', () async {
      final model = SummaryModel();
      final generator = await model.generator();
      const shortMemo = RecordEvent(
        id: 'e_memo',
        dayOffset: 0,
        title: '十秒口头备忘',
        brief: '下午三点取西装。',
        longText: '下午三点取西装。',
        time: '11:20',
        dur: '10秒',
        speakers: 'A',
        mark: '',
        srcMap: '来源 11:20—11:20',
        dialog: [TurnLine('A', '明天下午三点记得去干洗店取西装。', '11:20—11:20')],
        raw: [],
      );
      await generator.generate(const [shortMemo]);
      final body = jsonDecode(model.requests.single.body) as Map<String, dynamic>;
      final sysPrompt =
          ((body['messages'] as List).first as Map<String, dynamic>)['content'] as String;
      // Prompt must explicitly instruct scaling depth to input length for short memos
      expect(
        sysPrompt,
        allOf(
          contains('1 句'),
          anyOf(contains('篇幅'), contains('长短'), contains('简短')),
        ),
      );
    });
  });

  group('2. SummaryResultPage Dark Mode, InfoPoints, Photo Window, Todos & Cancel', () {
    testWidgets('Dark Mode renders zero hardcoded light RCColors on SummaryResultPage & ExportSheet', (
      tester,
    ) async {
      final store = AppStore(events: seedEvents, loadPersistedState: false);
      store.eventPhotos['e1'] = const [
        EventPhoto(
          id: 'p_dark',
          path: '/nonexistent/dark_photo.jpg',
          time: '14:22:00',
          source: 'dyj_camera',
        ),
      ];
      final card = SummaryCard(id: 'sum_dark', time: '15:00', state: SummaryState.done)
        ..srcIds = ['e1', 'e2']
        ..title = '深色模式验收纪要'
        ..subDesc = '今天 13:05–14:20 · 2 条记录'
        ..overview = '验证深色模式下所有标题、正文、卡片与浮层均使用语义色。'
        ..structure = const [
          MapBranch('视觉规范', ['杜绝白底白字', '杜绝黑底黑字']),
        ]
        ..points = const [
          InfoPoint(
            '语义色全覆盖',
            '所有文本与容器跟随 RCColorScheme.dark。',
            [SourceRef('e1', '午后项目方向讨论', '14:20 · 18分40秒')],
          ),
        ]
        ..todos = const ['检查深色导出面板']
        ..fullText = '说话人 A：深色模式清晰可读。';
      store.summaries = [card];

      await tester.pumpWidget(
        StoreScope(
          store: store,
          child: MaterialApp(
            theme: buildRCTheme(),
            darkTheme: buildRCDarkTheme(),
            themeMode: ThemeMode.dark,
            home: const Scaffold(
              body: SummaryResultPage(summaryId: 'sum_dark', showPaneBack: true),
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify no Material/Container inside SummaryResultPage uses hardcoded light bg/card/chip colors
      final forbiddenDarkBgColors = <Color>{
        RCColors.bg, // 0xFFFAFAF8
        RCColors.card, // 0xFFFFFFFF
        const Color(0xFFEAF3EA),
        const Color(0xFFEAEAE4),
      };
      final forbiddenDarkTextColors = <Color>{
        RCColors.label, // 0xFF1D1D1F
        RCColors.ink, // 0xFF3C3C43
      };

      for (final mat in tester.widgetList<Material>(
        find.descendant(
          of: find.byType(SummaryResultPage),
          matching: find.byType(Material),
        ),
      )) {
        if (mat.color != null) {
          expect(
            forbiddenDarkBgColors.contains(mat.color),
            isFalse,
            reason: 'Material used light-mode color ${mat.color} in Dark Mode',
          );
        }
      }

      for (final container in tester.widgetList<Container>(
        find.descendant(
          of: find.byType(SummaryResultPage),
          matching: find.byType(Container),
        ),
      )) {
        final dec = container.decoration;
        if (dec is BoxDecoration && dec.color != null) {
          expect(
            forbiddenDarkBgColors.contains(dec.color),
            isFalse,
            reason: 'Container BoxDecoration used light-mode color ${dec.color} in Dark Mode',
          );
        }
      }

      for (final txt in tester.widgetList<Text>(
        find.descendant(
          of: find.byType(SummaryResultPage),
          matching: find.byType(Text),
        ),
      )) {
        final c = txt.style?.color;
        if (c != null) {
          expect(
            forbiddenDarkTextColors.contains(c),
            isFalse,
            reason: 'Text "${txt.data}" used dark-on-dark color $c in Dark Mode',
          );
        }
      }

      // Open Export Sheet in Dark Mode and verify sheet surface is dark too
      await tester.tap(find.byKey(const Key('export-btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('export-sheet')), findsOneWidget);
      for (final txt in tester.widgetList<Text>(
        find.descendant(
          of: find.byKey(const Key('export-sheet')),
          matching: find.byType(Text),
        ),
      )) {
        final c = txt.style?.color;
        if (c != null) {
          expect(
            forbiddenDarkTextColors.contains(c),
            isFalse,
            reason: 'Export sheet text "${txt.data}" used dark-on-dark color $c',
          );
        }
      }
      Navigator.of(tester.element(find.byKey(const Key('export-sheet')))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('switching to 信息点 (stab-pt) expands ALL 6+ InfoPoints (fixes i < 4 bug)', (
      tester,
    ) async {
      final store = AppStore(events: seedEvents, loadPersistedState: false);
      final card = SummaryCard(id: 'sum_6pts', time: '16:00', state: SummaryState.done)
        ..srcIds = ['e1']
        ..title = '六项信息点展开测试'
        ..overview = '测试超过 4 条信息点时切换 Tab 全部默认展开。'
        ..structure = const [MapBranch('分组', ['要点'])]
        ..points = [
          for (var i = 0; i < 6; i++)
            InfoPoint(
              '第 ${i + 1} 条关键信息点',
              '第 ${i + 1} 条信息点的完整展开详情正文。',
              const [SourceRef('e1', '午后项目方向讨论', '14:20 · 18分40秒')],
            ),
        ]
        ..todos = const [];
      store.summaries = [card];

      await tester.pumpWidget(
        StoreScope(
          store: store,
          child: MaterialApp(
            theme: buildRCTheme(),
            home: const Scaffold(body: SummaryResultPage(summaryId: 'sum_6pts')),
          ),
        ),
      );
      await tester.pump();

      // On 'all' tab, all 6 points default collapsed
      for (var i = 0; i < 6; i++) {
        expect(find.byKey(Key('pt-d-$i')), findsNothing);
      }

      // Switch to 'pt' tab -> ALL 6 points must expand (including index 4 and 5!)
      await tester.tap(find.byKey(const Key('stab-pt')));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        expect(
          find.byKey(Key('pt-d-$i')),
          findsOneWidget,
          reason: 'Point index $i must be expanded on stab-pt',
        );
      }
    });

    testWidgets('Photo time-window matching filters out-of-window photos & mind-map removes fake 0:0 fallback', (
      tester,
    ) async {
      final model = SummaryModel(
        content: jsonEncode({
          'title': '季度预算审批',
          'overview': '讨论服务器扩容预算。',
          'structure': [
            {
              'name': '云端机房升级',
              'leaves': ['智算集群部署']
            }
          ],
          'points': [
            {
              'title': '季度成本核定',
              'detail': '核定年度支出总额。',
              'sources': ['e_win'],
            }
          ],
          'todos': [],
        }),
      );
      const eventUnrelated = RecordEvent(
        id: 'e_coffee',
        dayOffset: 0,
        title: '早间茶水间闲聊',
        brief: '顺手拍了咖啡豆包装。',
        longText: '顺手拍了咖啡豆包装。',
        time: '09:10',
        dur: '5分00秒',
        speakers: 'A',
        mark: '',
        srcMap: '来源 09:10—09:15',
        dialog: [TurnLine('A', '今天这款手冲豆子风味不错。', '09:10—09:15')],
        raw: [],
      );
      const eventWin = RecordEvent(
        id: 'e_win',
        dayOffset: 0,
        title: '算力讨论简记',
        brief: '简短核对排期。',
        longText: '简短核对排期。',
        time: '14:20',
        dur: '15分00秒',
        speakers: 'A',
        mark: '',
        srcMap: '来源 14:20—14:35',
        dialog: [TurnLine('A', '下午把报价单核对完。', '14:20—14:35')],
        raw: [],
      );
      final generator = await model.generator();
      final store = AppStore(
        events: const [eventUnrelated, eventWin],
        generator: generator,
        loadPersistedState: false,
      );
      // e_coffee has p_coffee (unrelated to mind-map '云资源采购 / GPU节点扩容');
      // e_win has p_in inside 14:20..14:35 and p_out at 17:45 (outside window!)
      store.eventPhotos['e_coffee'] = const [
        EventPhoto(
          id: 'p_coffee',
          path: '/nonexistent/coffee.jpg',
          time: '09:12:00',
          source: 'dyj_camera',
        ),
      ];
      store.eventPhotos['e_win'] = const [
        EventPhoto(
          id: 'p_out',
          path: '/nonexistent/out_window.jpg',
          time: '17:45:00',
          source: 'system_album',
        ),
        EventPhoto(
          id: 'p_in',
          path: '/nonexistent/in_window.jpg',
          time: '14:28:30',
          source: 'dyj_camera',
        ),
      ];

      await pumpShell(tester, store: store, model: model);
      await tester.tap(find.byKey(const Key('summary-start')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('chip-today')));
      await tester.pump();
      await tapGenerate(tester);
      await finishGeneration(tester, model);

      // 1) ZERO lexical overlap across all photos (map.isEmpty == true) -> NO fake 0:0 fallback!
      expect(find.byKey(const Key('mleaf-pic-e_coffee-p_coffee')), findsNothing);
      expect(find.byKey(const Key('mleaf-pic-e_win-p_in')), findsNothing);
      expect(find.byKey(const Key('mleaf-pic-e_win-p_out')), findsNothing);

      // 2) Expand InfoPoint 0 -> matches ONLY p_in (14:28:30 within 14:20..14:35), NOT p_out (17:45:00)!
      await tester.tap(find.byKey(const Key('stab-pt')));
      await tester.pump();
      expect(find.byKey(const Key('sum-pt-photo-e_win-p_in')), findsOneWidget);
      expect(find.byKey(const Key('sum-pt-photo-e_win-p_out')), findsNothing);
    });

    testWidgets('persists checked todos across source navigation/rebuilds & uses adaptive mind-map root', (
      tester,
    ) async {
      final h = await pumpShell(tester);
      await generateWeekSummary(tester, h.model);

      // Adaptive mind-map root uses concise card.title ('核心脉络 · 项目排期与客户反馈') instead of hardcoded '会议要点'
      expect(find.text('会议要点'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('sec-map')),
          matching: find.textContaining('项目排期与客户反馈'),
        ),
        findsOneWidget,
      );

      // Check todo-0 and todo-2
      await tapTab(tester, const Key('stab-todo'));
      expect(tester.widget<Text>(find.byKey(const Key('ix-done'))).data, '已完成 0 / 3');
      await tester.tap(find.byKey(const Key('todo-0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('todo-2')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('ix-done'))).data, '已完成 2 / 3');

      // Navigate to source detail (unmounting SummaryResultPage) and navigate back
      await tapTab(tester, const Key('stab-src'));
      await tapInScroll(tester, find.byKey(const Key('src-e1')));
      expect(find.byKey(const Key('dt-h3')), findsOneWidget);

      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tapTab(tester, const Key('stab-todo'));
      expect(
        tester.widget<Text>(find.byKey(const Key('ix-done'))).data,
        '已完成 2 / 3',
        reason: 'Checked todos must persist across route navigation & widget remounts',
      );

      // Also verify empty title falls back to '核心脉络'
      final fallbackCard = SummaryCard(id: 'sum_empty_title', time: '12:00', state: SummaryState.done)
        ..title = ''
        ..structure = const [MapBranch('分支', ['叶子'])];
      h.store.summaries = [fallbackCard, ...h.store.summaries];
      h.store.openSum('sum_empty_title', fresh: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.descendant(
          of: find.byKey(const Key('sec-map')),
          matching: find.text('核心脉络'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('supports canceling in-flight summary generation cleanly', (tester) async {
      final model = SummaryModel(autoReply: false);
      final h = await pumpShell(tester, model: model);
      await startWeekSummary(tester);
      await tapGenerate(tester);

      expect(find.byKey(const Key('gen-bar')), findsOneWidget);
      expect(find.byKey(const Key('gen-cancel')), findsOneWidget);

      // Tap cancel while in-flight -> removes generating card and returns to Timeline
      await tester.tap(find.byKey(const Key('gen-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('gen-bar')), findsNothing);
      expect(h.store.summaries, isEmpty);
      expect(find.byKey(const Key('nav-timeline')), findsOneWidget);

      // Release pending HTTP mock so background future settles without re-adding canceled card
      model.release();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(h.store.summaries, isEmpty);

      // Also verify explicit onCancelGeneration callback prop on SummaryResultPage
      var customCancelCalled = false;
      final genCard = SummaryCard(
        id: 'sum_custom_cancel',
        time: '16:10',
        state: SummaryState.generating,
      )..progress = 35;
      h.store.summaries = [genCard];
      await tester.pumpWidget(
        StoreScope(
          store: h.store,
          child: MaterialApp(
            theme: buildRCTheme(),
            home: Scaffold(
              body: SummaryResultPage(
                summaryId: 'sum_custom_cancel',
                onCancelGeneration: () => customCancelCalled = true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('gen-cancel')));
      await tester.pump();
      expect(customCancelCalled, isTrue);
    });
  });

  group('3. Export Bugs, Memory Safety & iPadOS Share Sheet Anchor', () {
    test('fixes duplicate transcript bug in TranscriptExportMode.aiOptimized & preserves empty-events fullText fallback', () {
      final card = SummaryCard(id: 'sum_dup', time: '15:00', state: SummaryState.done)
        ..srcIds = ['e1', 'e2']
        ..title = '去重导出测试'
        ..overview = '测试第二部分文字记录不重复输出两遍。'
        ..fullText = stitchPolishedFullText([seedEvents[0], seedEvents[1]]);

      final docWithEvents = exportDocumentFromSummary(
        card,
        sourceEvents: [seedEvents[0], seedEvents[1]],
        transcriptMode: TranscriptExportMode.aiOptimized,
      );
      final md = MarkdownExporter.buildMarkdownContent(docWithEvents);
      final blocksText = buildDocBlocks(docWithEvents).map((b) => b.text).join('\n');

      // Each cleaned turn must appear strictly ONCE (not duplicated under 全文 + per-event section!)
      expect(_countOccurrences(md, '这版排期偏紧，特别是测试阶段。'), 1);
      expect(_countOccurrences(md, '新界面反馈整体清爽，列表页打开偏慢。'), 1);
      expect(_countOccurrences(blocksText, '这版排期偏紧，特别是测试阶段。'), 1);
      expect(
        docWithEvents.sections.where((s) => s.heading == '全文（AI 智能优化版）'),
        isEmpty,
      );

      // Fallback when sourceEvents is empty: still outputs card.fullText!
      final docFallback = exportDocumentFromSummary(
        card,
        sourceEvents: const [],
        transcriptMode: TranscriptExportMode.aiOptimized,
      );
      final mdFallback = MarkdownExporter.buildMarkdownContent(docFallback);
      expect(mdFallback, contains('这版排期偏紧，特别是测试阶段。'));
    });

    test('fixes Markdown sandbox path leak (never writes /var/mobile or /Users absolute paths)', () {
      const doc = ExportDocument(
        title: '沙盒路径脱敏测试',
        sections: [
          ExportSection(heading: '第一部分：图文纪要', isPartHeader: true),
          ExportSection(
            heading: '概览',
            body: '现场白板记录。',
            images: [
              ExportImageItem(
                path: '/var/mobile/Containers/Data/Application/9F8A-1234/Documents/photos/whiteboard_01.jpg',
                caption: '午后讨论 · 现场照片（14:22）',
              ),
              ExportImageItem(
                path: '/Users/kongkang/Library/Developer/CoreSimulator/Devices/ABCD/data/slide_02.png',
                caption: '架构图（14:30）',
              ),
            ],
          ),
        ],
      );

      final md = MarkdownExporter.buildMarkdownContent(doc);
      expect(md, isNot(contains('/var/mobile')));
      expect(md, isNot(contains('/Users/')));
      expect(md, isNot(contains('Containers/Data/Application')));
      expect(
        md,
        anyOf(
          contains('images/whiteboard_01.jpg'),
          contains('[现场图片：午后讨论 · 现场照片（14:22）]'),
        ),
      );
    });

    testWidgets('streams >40 PDF pages without 40-page truncation cliff & caps LongImageOptions memory safely', (
      tester,
    ) async {
      // 1) LongImageOptions default must cap height & memory safely for low-RAM mobile GPUs
      const defaultLongOpts = LongImageOptions();
      expect(defaultLongOpts.maxPixelHeight, lessThanOrEqualTo(16384));

      // Build a large document (~45+ A4 pages)
      final longParagraph = List.generate(
        28,
        (idx) => '第${idx + 1}段完整会议对话记录：围绕多端同步一致性、离线语音切片能量谷底检测、声纹聚类阈值标定展开详细复盘。',
      ).join('\n');
      final largeDoc = ExportDocument(
        title: '超长周度全景复盘（45页压力测试）',
        meta: '跨 11月1日 至 11月19日 · 48 条记录',
        sections: [
          const ExportSection(heading: '第一部分：图文纪要', isPartHeader: true),
          const ExportSection(heading: '概览', body: '覆盖全月核心技术评审与客户交付跟进。'),
          const ExportSection(heading: '第二部分：文字记录（AI 智能优化版）', isPartHeader: true),
          for (var s = 1; s <= 48; s++)
            ExportSection(
              heading: '10:${(s % 60).toString().padLeft(2, '0')} · 专题讨论第 $s 场（25分00秒）',
              body: '$longParagraph\n尾部锚点标记：SECTION_END_$s',
            ),
        ],
      );

      final tempDir = Directory.systemTemp.createTempSync('rc-pdf-stream-test-');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      await tester.runAsync(() async {
        // 2) Streaming PDF export must exceed 40 pages without truncating at page 40!
        final pdfPath = '${tempDir.path}/large_45p.pdf';
        await const PdfExporter().write(largeDoc, pdfPath);
        final pdfBytes = await File(pdfPath).readAsBytes();
        final pdfLatin = latin1.decode(pdfBytes, allowInvalid: true);
        final counts = RegExp(r'/Count\s+(\d+)')
            .allMatches(pdfLatin)
            .map((m) => int.tryParse(m.group(1)!) ?? 0)
            .toList();
        final maxPageCount = counts.isEmpty ? 0 : counts.reduce((a, b) => a > b ? a : b);
        expect(
          maxPageCount,
          greaterThan(40),
          reason: 'PDF must render >40 pages without silent 40-page truncation cliff',
        );

        // 3) Long image render on the same 45-page doc must stay within safe RGBA memory budget
        final longPng = await const DocumentRenderer().renderLongImagePng(largeDoc);
        final (w, h) = _readPngDimensions(longPng);
        expect(h, lessThanOrEqualTo(16384));
        final uncompressedRgbaBytes = w * h * 4;
        expect(
          uncompressedRgbaBytes,
          lessThanOrEqualTo(40 * 1024 * 1024),
          reason: 'Uncompressed RGBA bitmap ($w x $h = $uncompressedRgbaBytes B) must not OOM low-RAM devices',
        );
      });
    });

    testWidgets('anchors iPadOS sharePositionOrigin to 导出 button for ALL 4 export formats', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync('rc-ipad-share-test-');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final imgFile = File('${tempDir.path}/cam.png')
        ..writeAsBytesSync(base64Decode(_kTinyPngBase64), flush: true);

      final capturedShares = <ShareParams>[];

      final store = AppStore(events: seedEvents, loadPersistedState: false);
      store.eventPhotos['e1'] = [
        EventPhoto(
          id: 'p_ipad',
          path: imgFile.path,
          time: '14:22:00',
          source: 'dyj_camera',
        ),
      ];
      final card = SummaryCard(id: 'sum_ipad', time: '15:00', state: SummaryState.done)
        ..srcIds = ['e1']
        ..title = 'iPad分享锚点验收'
        ..overview = '四种格式都必须携带导出按钮锚点坐标。'
        ..structure = const [MapBranch('导出', ['四格式全覆盖'])]
        ..points = const [
          InfoPoint('iPad防崩', '提供非空 sharePositionOrigin。', [
            SourceRef('e1', '午后项目方向讨论', '14:20 · 18分40秒'),
          ]),
        ]
        ..todos = const ['验证PDF/Word/Markdown/图片'];
      store.summaries = [card];

      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      Completer<ShareParams>? shareWaiter;
      final exportService = ExportService(
        outputDirectoryProvider: () async => Directory('${tempDir.path}/exports'),
        shareLauncher: (params) async {
          capturedShares.add(params);
          final w = shareWaiter;
          if (w != null && !w.isCompleted) {
            w.complete(params);
          }
          return ShareResult.unavailable;
        },
      );
      await tester.pumpWidget(
        StoreScope(
          store: store,
          child: MaterialApp(
            theme: buildRCTheme(),
            home: Scaffold(
              body: SummaryResultPage(
                summaryId: 'sum_ipad',
                exportService: exportService,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final exportBtnRect = tester.getRect(find.byKey(const Key('export-btn')));
      expect(exportBtnRect.width, greaterThan(0));
      expect(exportBtnRect.height, greaterThan(0));

      for (final formatLabel in ['Markdown', 'Word 文档', 'PDF', '图片']) {
        capturedShares.clear();
        shareWaiter = Completer<ShareParams>();
        await tester.tap(find.byKey(const Key('export-btn')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final itemFinder = find.byKey(Key('export-item-$formatLabel'));
        await tester.ensureVisible(itemFinder);
        await tester.pump();
        await tester.tap(itemFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        for (var step = 0; step < 300 && !shareWaiter.isCompleted; step++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
        await tester.pump(const Duration(seconds: 3));

        expect(
          capturedShares,
          hasLength(1),
          reason: 'ShareLauncher must be invoked for $formatLabel',
        );
        final origin = capturedShares.single.sharePositionOrigin;
        expect(
          origin,
          isNotNull,
          reason: '$formatLabel must pass non-null sharePositionOrigin for iPadOS popover',
        );
        expect(origin!.width, closeTo(exportBtnRect.width, 1.0));
        expect(origin.height, closeTo(exportBtnRect.height, 1.0));
        expect(origin.left, closeTo(exportBtnRect.left, 1.0));
        expect(origin.top, closeTo(exportBtnRect.top, 1.0));
      }
    });
  });
}
