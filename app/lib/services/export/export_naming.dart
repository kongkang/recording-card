/// 导出文件名规则 —— 纯 Dart，便于命令行验证。
///
/// 命名形态：`录音卡-<标题>-<格式标注?>-<yyyyMMdd-HHmm>.<扩展名>`
/// 例：`录音卡-项目排期与客户反馈-20261108-1930.pdf`
///     `录音卡-项目排期与客户反馈-完整文档-20261108-1930.pdf`
///
/// 规则要点：
/// - 保留中文（iOS/Android/macOS 文件系统都支持 UTF-8 文件名，中文可读性远好于拼音转写）；
/// - 去掉 `\ / : * ? " < > |` 与控制字符（Android 部分机型/分享目标会因此报错）；
/// - 空白（含全角空格、换行）折叠为 `-`，连续分隔符合并；
/// - 标题按「码点」截断，不会切坏 emoji 的代理对（切坏会产生非法文件名）。
library;

/// 导出文件统一前缀。
const String kExportFilePrefix = '录音卡';

/// 标题部分最大码点数，超出截断（避免撞上各系统 255 字节的文件名上限）。
const int kExportTitleMaxChars = 28;

/// 把任意文本变成可安全落盘的文件名片段。
///
/// [maxChars] 按 Unicode 码点计；[fallback] 在清洗后为空时使用。
String sanitizeFileNamePart(
  String raw, {
  int maxChars = kExportTitleMaxChars,
  String fallback = '总结',
}) {
  var s = raw;

  // 1) 控制字符（含换行、制表、NUL）→ 空格
  s = s.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ');

  // 2) 各系统/分享目标会拒绝的保留字符 → 空格
  s = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ');

  // 3) 各类空白（含全角空格 \u3000、不换行空格 \u00A0）折叠为单个 '-'
  s = s.replaceAll(RegExp(r'[\s\u00A0\u3000]+'), '-');

  // 4) 连续分隔符合并，去掉首尾分隔符与点（避免生成隐藏文件 / 以点结尾）
  s = s.replaceAll(RegExp(r'[-_]{2,}'), '-');
  s = s.replaceAll(RegExp(r'^[.\-\s]+'), '');
  s = s.replaceAll(RegExp(r'[.\-\s]+$'), '');

  // 5) 按码点截断（String.fromCharCodes 处理的是码点，代理对不会被切开）
  final runes = s.runes.toList(growable: false);
  if (runes.length > maxChars) {
    s = String.fromCharCodes(runes.take(maxChars));
    // 截断后可能又出现尾部 '-' 或 '.'，再清一次
    s = s.replaceAll(RegExp(r'[.\-\s]+$'), '');
  }

  return s.isEmpty ? fallback : s;
}

/// 生成文件名时间戳片段：`20261108-1930`。
String exportTimestamp(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  final y = time.year.toString().padLeft(4, '0');
  return '$y${two(time.month)}${two(time.day)}-${two(time.hour)}${two(time.minute)}';
}

/// 拼出最终文件名。
///
/// [extension] 不含点，如 `pdf` / `md` / `png` / `doc`；
/// [nameTag] 用于区分同一格式的不同产物语义（如「完整文档」），可为空。
String buildExportFileName({
  required String title,
  required DateTime time,
  required String extension,
  String? nameTag,
}) {
  final ext = extension.trim().replaceAll(RegExp(r'^\.+'), '');
  if (ext.isEmpty) {
    throw ArgumentError.value(extension, 'extension', '扩展名不能为空');
  }
  final parts = <String>[
    kExportFilePrefix,
    sanitizeFileNamePart(title),
    if (nameTag != null && nameTag.trim().isNotEmpty)
      sanitizeFileNamePart(nameTag, maxChars: 12, fallback: '导出'),
    exportTimestamp(time),
  ];
  return '${parts.join('-')}.$ext';
}
