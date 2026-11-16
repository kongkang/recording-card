/// 本次 4 项修复的综合验收：
/// 1. 滚动条与点击顶部回顶：垂直列表带 CupertinoScrollbar 且仅滚动时显示（横向条无滚动条）；
///    即使挂载了 StatusSheetOverlay，PrimaryScrollController 仍仅命中当前可见页，点击顶栏平滑回顶。
/// 2. 总结新增「全文」：stab-ft / toc-item-sec-ft / sec-ft，按时间先后拼接并清洗口水词。
/// 3. 标记说话人全局联动 + 4 种纯格式完整两段式导出（图文纪要 + AI 智能优化版/原文，无「完整文档」）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/pages/detail_page.dart';
import 'package:recording_card/pages/timeline_page.dart';
import 'package:recording_card/services/export/export.dart';

import 'support/harness.dart';
import 'support/model_stub.dart';

const String _kTestPng4x4Base64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGMwOR75HxkzkC4AAOFIJTGNUj/yAAAAAElFTkSuQmCC';

void _writeTestPngSync(String path) {
  File(path).writeAsBytesSync(base64Decode(_kTestPng4x4Base64), flush: true);
}

void main() {
  testWidgets(
    '1. 垂直滚动带系统自动隐藏滚动条、横向不带滚动条；点击顶部回顶精确命中当前活动页',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        // 使用较矮视口确保 Timeline 可滚动，验证回顶与滚动条隔离。
        final h = await pumpShell(tester, size: const Size(390, 440));

      // Timeline 垂直滚动区受 RCScrollBehavior 注入 CupertinoScrollbar（thumbVisibility 默认隐藏、滚动时显）
      final tlScrollbar = tester.widget<CupertinoScrollbar>(
        find
            .descendant(
              of: find.byType(TimelinePage),
              matching: find.byType(CupertinoScrollbar),
            )
            .first,
      );
      expect(tlScrollbar.thumbVisibility, isFalse);

      // 向下滚动 Timeline，确认 PrimaryScrollController 仅对应唯一活动滚动位置并能回顶
      final tlScrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(RefreshIndicator),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tlScrollable.position.maxScrollExtent, greaterThan(40));
      tlScrollable.position.jumpTo(tlScrollable.position.maxScrollExtent);
      await tester.pump();
      expect(tlScrollable.position.pixels, greaterThan(20));

      await tester.tap(find.byKey(const Key('header-tap-top')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(tlScrollable.position.pixels, 0.0);

      // 打开长记录详情，再次验证子页滚动条与点击顶栏空白回顶、且不会抛出多 Position 断言
      await tester.tap(find.byKey(const Key('card-e1')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('detail-e1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('detail-e1')));
      await tester.pump();
      final dtScrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(DetailPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(dtScrollable.position.maxScrollExtent, greaterThan(20));
      dtScrollable.position.jumpTo(dtScrollable.position.maxScrollExtent);
      await tester.pump();
      expect(dtScrollable.position.pixels, greaterThan(10));
      await tester.tap(find.byKey(const Key('header-tap-top')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(dtScrollable.position.pixels, 0.0);

      // 切去总结结果页，验证横向 Tab strip 不套垂直 CupertinoScrollbar
      await tester.tap(find.byKey(const Key('crumb-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await generateWeekSummary(tester, h.model);
      expect(
        find.descendant(
          of: find.byKey(const Key('stab-strip')),
          matching: find.byType(CupertinoScrollbar),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('stab-strip')),
          matching: find.byType(Scrollbar),
        ),
        findsNothing,
      );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('2. 总结结果页提供「全文」Tab、目录跳转及拼接润色正文展示', (tester) async {
    final h = await pumpShell(tester);
    await generateWeekSummary(tester, h.model);

    expect(find.byKey(const Key('stab-ft')), findsOneWidget);
    expect(find.byKey(const Key('sec-ft')), findsOneWidget);

    await tapTab(tester, const Key('stab-ft'));
    expect(find.byKey(const Key('sec-ft')), findsOneWidget);
    expect(find.byKey(const Key('sec-ov')), findsNothing);
    expect(find.byKey(const Key('sum-fulltext-body')), findsOneWidget);
    expect(find.byKey(const Key('sum-mark-speaker-btn')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('sum-fulltext-body')),
        matching: find.textContaining('【13:05 · 客户回访要点】'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('sum-fulltext-body')),
        matching: find.textContaining('【14:20 · 午后项目方向讨论】'),
      ),
      findsOneWidget,
    );
    // e2 首段由「说话人 B（推测）」聚合为 sum-ft-group-e2-0 段落展示
    expect(find.byKey(const Key('sum-ft-group-e2-0')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('sum-ft-group-e2-0')),
        matching: find.textContaining('偏慢'),
      ),
      findsOneWidget,
    );

    // 目录菜单中也含「全文」项，点击可切回全部并定位
    await tester.tap(find.byKey(const Key('toc-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('toc-item-sec-ft')), findsOneWidget);
    await tester.tap(find.byKey(const Key('toc-item-sec-ft')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byKey(const Key('sec-ft')), findsOneWidget);
    expect(find.byKey(const Key('sec-ov')), findsOneWidget);
  });

  testWidgets('3. 极简说话人命名弹窗跨对话详情 / 总结全文同步，未标簇保持「推测」，原始数据保留原始簇标签', (
    tester,
  ) async {
    final model = SummaryModel();
    final store = AppStore(
      events: seedEvents,
      generator: await model.generator(),
      loadPersistedState: false,
    );
    await pumpShell(tester, store: store, model: model);

    // 进 e1 详情点击说话人弹出极简「为说话人命名」弹层
    await tester.tap(find.byKey(const Key('card-e1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('detail-e1')));
    await tester.pump();

    expect(find.byKey(const Key('mark-speaker-btn')), findsOneWidget);
    await tester.tap(find.byKey(const Key('turn-spk-0')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('spk-quick-sheet')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('qspk-name-inp')), '老陈');
    await tester.pump();
    await tester.tap(find.byKey(const Key('qspk-save-btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('spk-quick-sheet')), findsNothing);

    // 对话详情已改为「老陈」，而未标记的 B 依然保留「推测」后缀
    expect(find.textContaining('老陈'), findsWidgets);
    expect(find.textContaining('说话人 B（推测）'), findsWidgets);

    // 切到「原始数据」仍保留底层簇标识映射
    await tester.tap(find.byKey(const Key('det-tab-raw')));
    await tester.pump();
    expect(find.byKey(const Key('raw-utt-0')), findsOneWidget);
    expect(find.textContaining('说话人 A（已标：老陈）'), findsWidgets);

    // 返回并生成总结：「全文」与概览/信息点中也同步替换成「老陈」
    await tester.tap(find.byKey(const Key('crumb-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await generateWeekSummary(tester, model);

    await tapTab(tester, const Key('stab-ft'));
    expect(
      find.descendant(
        of: find.byKey(const Key('sum-fulltext-body')),
        matching: find.textContaining('老陈'),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('sum-fulltext-body')),
        matching: find.textContaining('说话人 B（推测）'),
      ),
      findsWidgets,
    );
  });

  testWidgets('4. 导出区分格式且固定含两部分：默认「AI 智能优化版」、可切「原文」、四格式落盘完整无「完整文档」', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('rc-export-two-part-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final imgPath = '${dir.path}/scene.png';
    _writeTestPngSync(imgPath);

    final model = SummaryModel();
    final store = AppStore(
      events: seedEvents,
      generator: await model.generator(),
      loadPersistedState: false,
    );
    store.eventPhotos['e1'] = [
      EventPhoto(
        id: 'p-scene',
        path: imgPath,
        time: '14:25:00',
        source: 'system_album',
      ),
    ];
    await pumpShell(tester, store: store, model: model);
    await generateWeekSummary(tester, model);

    // 校验导出 Sheet：默认选中 AI 智能优化版、支持切换原文、移除复杂标记按钮、只有 4 种格式
    await tester.tap(find.byKey(const Key('export-btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const Key('export-sheet')), findsOneWidget);
    expect(find.text('完整文档'), findsNothing);
    expect(find.byKey(const Key('export-mode-ai')), findsOneWidget);
    expect(find.byKey(const Key('export-mode-raw')), findsOneWidget);
    expect(find.byKey(const Key('export-mark-speaker-btn')), findsNothing);
    expect(find.byKey(const Key('sum-mark-speaker-btn')), findsNothing);
    for (final f in ['PDF', 'Word 文档', 'Markdown', '图片']) {
      expect(find.byKey(Key('export-item-$f')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('export-mode-raw')));
    await tester.pump();
    Navigator.of(tester.element(find.byKey(const Key('export-sheet')))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // 标记说话人后验证四种真实导出器产物（图文纪要 + 文字记录两大部分）
    final sumCard = store.summaries.firstWhere((s) => s.state == SummaryState.done);
    final srcEvents = [
      for (final id in sumCard.srcIds) ?store.eventByIdOrNull(id),
    ];
    store.setSpeakerAliasForEvents(srcEvents, 'A', '老陈');
    List<ExportImageItem> resolvePhotos(RecordEvent ev) => [
          for (final p in store.activePhotosForEvent(ev))
            ExportImageItem(path: p.path, caption: '${ev.title}（${p.time}）'),
        ];

    final aiDoc = exportDocumentFromSummary(
      sumCard,
      sourceEvents: srcEvents,
      transcriptMode: TranscriptExportMode.aiOptimized,
      photosResolver: resolvePhotos,
      speakerResolver: store.displaySpeaker,
      aliasTextTransformer: store.applySpeakerAliasesToText,
    );
    final rawDoc = exportDocumentFromSummary(
      sumCard,
      sourceEvents: srcEvents,
      transcriptMode: TranscriptExportMode.rawOriginal,
      photosResolver: resolvePhotos,
      speakerResolver: store.displaySpeaker,
      aliasTextTransformer: store.applySpeakerAliasesToText,
    );

    expect(aiDoc.hasTwoPartStructure, isTrue);
    final aiBlocks = buildDocBlocks(aiDoc);
    expect(aiBlocks.any((b) => b.text.contains('第一部分：图文纪要')), isTrue);
    expect(aiBlocks.any((b) => b.text.contains('第二部分：文字记录')), isTrue);
    expect(aiBlocks.any((b) => b.text.contains('老陈')), isTrue);
    expect(aiBlocks.any((b) => b.kind == DocBlockKind.image), isTrue);

    await tester.runAsync(() async {
      final mdAi = await const MarkdownExporter().write(aiDoc, '${dir.path}/out_ai.md');
      final mdAiText = await File(mdAi).readAsString(encoding: utf8);
      expect(mdAiText, contains('第一部分：图文纪要'));
      expect(mdAiText, contains('第二部分：文字记录'));
      expect(mdAiText, contains('AI 智能优化版'));
      expect(mdAiText, contains('老陈'));

      final mdRaw = await const MarkdownExporter().write(rawDoc, '${dir.path}/out_raw.md');
      final mdRawText = await File(mdRaw).readAsString(encoding: utf8);
      expect(mdRawText, contains('原文'));
      expect(mdRawText, contains('静音约2分钟'));
      expect(mdRawText, contains('老陈'));

      final docPath = await const WordExporter(flavor: WordFlavor.html).write(
        aiDoc,
        '${dir.path}/out.doc',
      );
      final docHtml = await File(docPath).readAsString(encoding: utf8);
      expect(docHtml, contains('第一部分：图文纪要'));
      expect(docHtml, contains('第二部分：文字记录'));
      expect(docHtml, contains('data:image/png;base64,'));

      final pdfPath = await const PdfExporter().write(
        aiDoc,
        '${dir.path}/out.pdf',
      );
      final pngPath = await const ImageExporter().write(
        aiDoc,
        '${dir.path}/out.png',
      );
      final pdfBytes = await File(pdfPath).readAsBytes();
      final pngBytes = await File(pngPath).readAsBytes();
      expect(utf8.decode(pdfBytes.take(5).toList(), allowMalformed: true), '%PDF-');
      expect(pngBytes.length, greaterThan(1000));
      expect(pngBytes.take(4).toList(), [0x89, 0x50, 0x4E, 0x47]);
    });
  });
}
