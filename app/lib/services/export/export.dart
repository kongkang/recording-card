/// 总结导出能力 —— 对外统一入口。
///
/// 页面层只需要：
/// ```dart
/// import '../services/export/export.dart';
/// ```
/// 然后把 SummaryCard 转成 [ExportDocument]，调用 [ExportService.export]。
library;

export 'document_layout.dart'
    show DocBlock, DocBlockKind, buildDocBlocks, buildDocBlocksFromMarkdown, stripInlineMarkdown;
export 'document_renderer.dart' show DocumentPageOptions, DocumentRenderer, LongImageOptions;
export 'export_document.dart' show ExportDocument, ExportSection;
export 'export_exception.dart' show ExportException;
export 'export_naming.dart' show buildExportFileName, exportTimestamp, sanitizeFileNamePart;
export 'export_service.dart' show ExportFormat, ExportFormatInfo, ExportResult, ExportService;
export 'full_doc_exporter.dart' show FullDocExporter;
export 'image_exporter.dart' show ImageExporter;
export 'markdown_exporter.dart' show MarkdownExporter;
export 'pdf_assembler.dart' show PdfAssembler;
export 'pdf_exporter.dart' show PdfExporter;
export 'summary_export_mapper.dart' show exportDocumentFromSummary;
export 'word_exporter.dart' show WordExporter, WordFlavor;
