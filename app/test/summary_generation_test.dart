// 手动总结云端生成验收（TDD）—— 选中分段 → SummaryArticleService →
// 结果页字段映射；失败进入 error 态可重试，不伪装成功。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/core/store/app_store.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/pages/app_shell.dart';
import 'package:recording_card/services/analysis/summary_article.dart';
import 'test_transitions.dart';

class FakeSummaryArticleService implements SummaryArticleService {
  SummaryArticle? result;
  Object? error;
  int calls = 0;
  List<SummaryArticleSource> lastSources = const [];

  @override
  Future<SummaryArticle> generate(List<SummaryArticleSource> sources) async {
    calls++;
    lastSources = sources;
    final failure = error;
    if (failure != null) throw failure;
    return result ??
        SummaryArticle(
          title: '云端总结标题',
          overview: '云端概览',
          sections: const [
            SummaryArticleSection(heading: '排期', body: '排期正文'),
          ],
          actionItems: const ['发出分工文档'],
          sourceIds: [for (final s in sources) s.recordingId],
        );
  }
}

Future<(AppStore, DeviceStore)> boot(
  WidgetTester tester, {
  SummaryArticleService? service,
}) async {
  final store = AppStore(summaryService: service);
  final device = DeviceStore();
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(device.dispose);
  addTearDown(store.dispose);
  await tester.pumpWidget(MaterialApp(
    theme: testTheme(),
    home: AppShell(store: store, device: device),
  ));
  await tester.pump();
  return (store, device);
}

Future<void> generate(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('summary-start')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('chip-week')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('generate-summary')));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(seconds: 7));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('云端生成：来源传给服务，结果字段映射到结果页', (tester) async {
    final service = FakeSummaryArticleService();
    final (store, _) = await boot(tester, service: service);
    await generate(tester);

    expect(service.calls, 1);
    expect(service.lastSources, hasLength(5));
    expect(service.lastSources.first.recordingId, isNotEmpty);
    expect(store.summaries.single.state, SummaryState.done);
    expect(find.text('云端总结标题'), findsOneWidget);
    expect(find.text('云端概览'), findsWidgets);
    expect(store.summaries.single.todos, ['发出分工文档']);
  });

  testWidgets('云端失败：进入 error 态并展示错误，可重试成功', (tester) async {
    final service = FakeSummaryArticleService()..error = Exception('网关不可用');
    final (store, _) = await boot(tester, service: service);
    await generate(tester);

    expect(store.summaries.single.state, SummaryState.error);
    expect(find.byKey(const Key('sum-error')), findsOneWidget);
    expect(find.textContaining('网关不可用'), findsOneWidget);

    service.error = null;
    await tester.tap(find.byKey(const Key('sum-retry')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.summaries.single.state, SummaryState.done);
    expect(find.text('云端总结标题'), findsOneWidget);
  });
}
