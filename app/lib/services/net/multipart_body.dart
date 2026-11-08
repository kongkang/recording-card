/// 手写 multipart/form-data 编码。
///
/// 为什么不用 `http.MultipartRequest`：给文件设置 `Content-Type` 需要
/// `package:http_parser` 的 `MediaType`，而本项目没有显式声明该依赖
/// （它是 http 的间接依赖，直接 import 会触发 `depend_on_referenced_packages`）。
/// 网关的 ASR 端点靠 filename + Content-Type 判断音频格式，这两样必须能控制，
/// 因此这里按 RFC 7578 直接拼装请求体：只依赖 `dart:convert`，行为可预期，
/// 也让「401 后重建请求」变得轻而易举（body 是纯字节，天生可重放）。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 已编码好的 multipart 请求体。
class MultipartBody {
  const MultipartBody({
    required this.bytes,
    required this.contentType,
    required this.boundary,
  });

  /// 完整请求体字节（可直接赋给 `http.Request.bodyBytes`）。
  final Uint8List bytes;

  /// 请求头 `Content-Type` 的完整值（含 boundary）。
  final String contentType;

  /// 本次使用的 boundary。
  final String boundary;
}

/// 构造 multipart 请求体：若干文本字段 + 一个文件字段。
///
/// - [fields] 文本字段（按插入顺序输出，UTF-8 编码，支持中文）；
/// - [fileField] 文件字段名（网关 ASR 要求 `file`）；
/// - [filename] 文件名（网关据此判断格式，如 `audio.wav`）；
/// - [mimeType] 文件 MIME；为空时按文件名后缀推断，仍未知则用
///   `application/octet-stream`。
///
/// CRLF 严格按 RFC 使用 `\r\n`（不少服务端解析器对此敏感）。
MultipartBody buildMultipartBody({
  required Map<String, String> fields,
  required String fileField,
  required List<int> fileBytes,
  required String filename,
  String? mimeType,
}) {
  final boundary = _newBoundary();
  final builder = BytesBuilder(copy: false);

  void writeText(String text) => builder.add(utf8.encode(text));

  for (final entry in fields.entries) {
    writeText('--$boundary\r\n');
    writeText('Content-Disposition: form-data; name="${_escape(entry.key)}"\r\n');
    writeText('\r\n');
    writeText(entry.value);
    writeText('\r\n');
  }

  writeText('--$boundary\r\n');
  writeText(
    'Content-Disposition: form-data; name="${_escape(fileField)}"; '
    'filename="${_escape(filename)}"\r\n',
  );
  writeText('Content-Type: ${mimeType ?? guessMimeType(filename)}\r\n');
  writeText('\r\n');
  builder.add(fileBytes);
  writeText('\r\n');
  writeText('--$boundary--\r\n');

  return MultipartBody(
    bytes: builder.takeBytes(),
    contentType: 'multipart/form-data; boundary=$boundary',
    boundary: boundary,
  );
}

/// 按文件名后缀推断音频 MIME（网关支持 wav/m4a/mp3/aac/flac）。
String guessMimeType(String filename) {
  final dot = filename.lastIndexOf('.');
  final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  switch (ext) {
    case 'wav':
      return 'audio/wav';
    case 'm4a':
      return 'audio/mp4';
    case 'mp3':
      return 'audio/mpeg';
    case 'aac':
      return 'audio/aac';
    case 'flac':
      return 'audio/flac';
    case 'ogg':
      return 'audio/ogg';
    case 'webm':
      return 'audio/webm';
    default:
      return 'application/octet-stream';
  }
}

/// 生成 boundary：固定前缀 + 随机十六进制，保证不与文件内容撞车。
String _newBoundary() {
  final rng = Random.secure();
  final suffix = List.generate(16, (_) => rng.nextInt(16).toRadixString(16))
      .join();
  return 'rc-boundary-$suffix';
}

/// 转义 `Content-Disposition` 里的引号与换行（防头部注入）。
String _escape(String value) =>
    value.replaceAll(RegExp(r'[\r\n]'), ' ').replaceAll('"', '%22');
