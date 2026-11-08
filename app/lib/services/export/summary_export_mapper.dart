/// 把业务模型 [SummaryCard] 映射成导出用的 [ExportDocument]。
///
/// 单独一层的原因：导出实现不依赖业务模型（见 export_document.dart 的说明），
/// 而模型演进只在映射处适配，导出器不受影响。
library;

import '../../core/models/summary.dart';
import 'export_document.dart';

ExportDocument exportDocumentFromSummary(SummaryCard card) {
  final sections = <ExportSection>[];

  if (card.structure.isNotEmpty) {
    sections.add(
      ExportSection(
        heading: '逻辑结构',
        bullets: [
          for (final branch in card.structure)
            branch.leaves.isEmpty
                ? branch.name
                : '${branch.name}：${branch.leaves.join('、')}',
        ],
      ),
    );
  }

  if (card.points.isNotEmpty) {
    sections.add(
      ExportSection(
        heading: '信息点',
        // bullets 只放来源引用，body 只放细节——避免 PDF 里同一标题重复出现两遍
        bullets: [
          for (final p in card.points)
            if (p.sources.isNotEmpty)
              '来源：${p.sources.map((s) => '${s.label} · ${s.range}').join('、')}',
        ],
        body: card.points.map((p) => '${p.title}\n${p.detail}').join('\n\n'),
      ),
    );
  }

  if (card.todos.isNotEmpty) {
    sections.add(
      ExportSection(heading: '行动项', bullets: card.todos, ordered: true),
    );
  }

  final srcDesc = card.srcDesc;
  if (srcDesc != null && srcDesc.trim().isNotEmpty) {
    sections.add(
      ExportSection(
        heading: '来源记录',
        bullets: srcDesc.split('；').where((s) => s.trim().isNotEmpty).toList(),
      ),
    );
  }

  return ExportDocument(
    title: card.title ?? '录音总结',
    meta: card.subDesc ?? '',
    overview: card.overview ?? '',
    sections: sections,
    markdown: card.markdown ?? '',
  );
}
