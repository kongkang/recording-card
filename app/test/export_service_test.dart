// 导出服务验收（TDD）—— 5 种格式必须生成真实文件字节，分享走可替换的 ExportSharer。
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/models/summary.dart';
import 'package:recording_card/data/seed.dart';
import 'package:recording_card/services/export_service.dart';

class FakeSharer implements ExportSharer {
  final shared = <ExportArtifact>[];

  @override
  Future<void> share(ExportArtifact artifact) async {
    shared.add(artifact);
  }
}

SummaryCard buildCard() {
  final card = SummaryCard(id: 's1', time: '10:00')
    ..srcIds = const ['e1', 'e2', 'e3'];
  fillSummaryContent(card, seedEvents);
  return card;
}

void main() {
  testWidgets('markdown：真实 .md 字节', (tester) async {
    final sharer = FakeSharer();
    final service = ExportService(sharer: sharer);
    final artifact = await service.build(buildCard(), ExportFormat.markdown);

    expect(artifact.fileName, endsWith('.md'));
    expect(artifact.mimeType, 'text/markdown');
    expect(utf8.decode(artifact.bytes), contains('# 项目排期与客户反馈'));
    expect(sharer.shared, isEmpty);
  });

  testWidgets('完整文档：包含概览/信息点/行动项/来源', (tester) async {
    final artifact = await ExportService(sharer: FakeSharer())
        .build(buildCard(), ExportFormat.fullDoc);
    final text = utf8.decode(artifact.bytes);
    expect(artifact.fileName, endsWith('.txt'));
    expect(text, contains('概览'));
    expect(text, contains('信息点'));
    expect(text, contains('行动项'));
    expect(text, contains('来源记录'));
  });

  testWidgets('Word：合法 docx zip，document.xml 含标题', (tester) async {
    final artifact = await ExportService(sharer: FakeSharer())
        .build(buildCard(), ExportFormat.word);
    expect(artifact.fileName, endsWith('.docx'));
    expect(artifact.bytes.sublist(0, 2), [0x50, 0x4B]); // PK
    final archive = ZipDecoder().decodeBytes(artifact.bytes);
    final doc = archive.files.firstWhere((f) => f.name == 'word/document.xml');
    final xml = utf8.decode(doc.content as List<int>);
    expect(xml, contains('项目排期与客户反馈'));
    expect(xml, contains('<w:document'));
  });

  testWidgets('图片：PNG 签名', (tester) async {
    final artifact = await tester.runAsync(() => ExportService(sharer: FakeSharer())
        .build(buildCard(), ExportFormat.image));
    expect(artifact!.fileName, endsWith('.png'));
    expect(artifact.bytes.sublist(0, 8),
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  });

  testWidgets('PDF：%PDF 头 + 非空页', (tester) async {
    final artifact = await tester.runAsync(() => ExportService(sharer: FakeSharer())
        .build(buildCard(), ExportFormat.pdf));
    expect(artifact!.fileName, endsWith('.pdf'));
    expect(String.fromCharCodes(artifact.bytes.sublist(0, 4)), '%PDF');
    expect(artifact.bytes.length, greaterThan(1000));
  });

  testWidgets('share：把 artifact 交给 sharer', (tester) async {
    final sharer = FakeSharer();
    final service = ExportService(sharer: sharer);
    final artifact = await service.build(buildCard(), ExportFormat.markdown);
    await service.share(artifact);
    expect(sharer.shared.single, same(artifact));
  });
}
