/// 印象笔记 / Evernote Cloud API 连接器（原生 Apache Thrift `TBinaryProtocol` over HTTPS）。
///
/// 支持国际版 `www.evernote.com` 与国内版 `app.yinxiang.com`，通过
/// `NoteStore.findNotesMetadata` 无限翻页（`offset += count` 直至 `totalNotes`）+
/// `NoteStore.getNoteContent` 读取 ENML 正文并转为纯文本。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../external_connector.dart';
import '../external_http_helper.dart';

class EvernoteConnector extends ExternalDataConnector {
  EvernoteConnector({this.requestDelay = const Duration(milliseconds: 280)});

  final Duration requestDelay;

  @override
  String get id => 'evernote';

  @override
  String get name => '印象笔记 / Evernote';

  @override
  ExternalConnectorCategory get category => ExternalConnectorCategory.notes;

  @override
  String get protocolBadge => 'Thrift API';

  @override
  String get subtitle => '通过官方 Developer Token + Thrift NoteStore 分页同步全部笔记';

  @override
  String get setupGuide =>
      '印象笔记中国（app.yinxiang.com）或 Evernote（www.evernote.com）申请 Developer Token（形如 S=s1:U=...），'
      '会自动从 Token 提取分片 shard 路由到对应 NoteStore 端点；也可手动填写 NoteStore URL。';

  @override
  List<ExternalFieldSpec> get fields => const [
    ExternalFieldSpec(
      key: 'region',
      label: '服务区域',
      required: true,
      defaultValue: 'yinxiang',
      options: [
        ExternalFieldOption('yinxiang', '印象笔记（中国）'),
        ExternalFieldOption('evernote', 'Evernote（国际）'),
        ExternalFieldOption('custom', '自定义 NoteStore URL'),
      ],
    ),
    ExternalFieldSpec(
      key: 'developerToken',
      label: 'Developer Token',
      hint: 'S=s1:U=...:E=...:C=...',
      isSecret: true,
      required: true,
    ),
    ExternalFieldSpec(
      key: 'noteStoreUrl',
      label: 'NoteStore URL（选填）',
      hint: '留空自动从 Token 拼接 /shard/{shard}/notestore',
      required: false,
    ),
    ExternalFieldSpec(
      key: 'searchWords',
      label: '搜索语法过滤（选填）',
      hint: '例如 tag:会议，留空同步全部笔记',
      required: false,
    ),
  ];

  static String resolveNoteStoreUrl(Map<String, String> cfg) {
    final explicit = (cfg['noteStoreUrl'] ?? '').trim();
    if (explicit.isNotEmpty) return explicit;
    final region = cfg['region'] ?? 'yinxiang';
    if (region == 'custom') {
      throw const ExternalConnectorException('自定义区域请填写 NoteStore URL');
    }
    final token = (cfg['developerToken'] ?? '').trim();
    final shardMatch = RegExp(r'(?:^|:)S=([^:;]+)').firstMatch(token);
    if (shardMatch == null || shardMatch.group(1)!.trim().isEmpty) {
      throw const ExternalConnectorException(
        '无法从 Token 中解析分片 shard，请填写完整 Developer Token（含 S=sX）或手动填写 NoteStore URL',
      );
    }
    final shard = shardMatch.group(1)!.trim();
    final host = region == 'evernote'
        ? 'https://www.evernote.com'
        : 'https://app.yinxiang.com';
    return '$host/shard/$shard/notestore';
  }

  Future<EvernoteNotesMetadataList> _findNotesMetadata({
    required http.Client client,
    required String url,
    required String token,
    required int offset,
    required int maxNotes,
    String words = '',
  }) async {
    final reqBytes = EvernoteThriftCodec.encodeFindNotesMetadataCall(
      authToken: token,
      offset: offset,
      maxNotes: maxNotes,
      words: words,
    );
    final resp = await ExternalHttpHelper.sendWithRetry(
      requestDelay: requestDelay,
      serviceName: name,
      request: () => client.post(
        Uri.parse(url),
        headers: const {
          'Content-Type': 'application/x-thrift',
          'Accept': 'application/x-thrift',
          'User-Agent': 'RecordingCard/1.0; ThriftClient;',
        },
        body: reqBytes,
      ),
    );
    return EvernoteThriftCodec.decodeFindNotesMetadataReply(resp.bodyBytes);
  }

  Future<String> _getNoteContent({
    required http.Client client,
    required String url,
    required String token,
    required String guid,
  }) async {
    final reqBytes = EvernoteThriftCodec.encodeGetNoteContentCall(
      authToken: token,
      guid: guid,
    );
    final resp = await ExternalHttpHelper.sendWithRetry(
      requestDelay: requestDelay,
      serviceName: name,
      request: () => client.post(
        Uri.parse(url),
        headers: const {
          'Content-Type': 'application/x-thrift',
          'Accept': 'application/x-thrift',
          'User-Agent': 'RecordingCard/1.0; ThriftClient;',
        },
        body: reqBytes,
      ),
    );
    return EvernoteThriftCodec.decodeGetNoteContentReply(resp.bodyBytes);
  }

  @override
  Future<ExternalTestResult> testConnection(
    Map<String, String> config, {
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final token = (cfg['developerToken'] ?? '').trim();
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写 Evernote / 印象笔记 Token');
    }
    final url = resolveNoteStoreUrl(cfg);
    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final res = await _findNotesMetadata(
        client: client,
        url: url,
        token: token,
        offset: 0,
        maxNotes: 1,
        words: cfg['searchWords'] ?? '',
      );
      final sample = res.notes.isNotEmpty ? res.notes.first.title : null;
      return ExternalTestResult(
        message: '连接成功（匹配 ${res.totalNotes} 条笔记）',
        countHint: res.totalNotes,
        sampleTitle: sample,
      );
    } finally {
      if (owned) client.close();
    }
  }

  @override
  Future<ExternalConnectorSyncReport> sync({
    required Map<String, String> config,
    required Set<String> existingDeviceNames,
    required Map<String, String> itemFingerprints,
    required Future<void> Function(
      List<ExternalRecordDraft> batch,
      Map<String, String> updatedFingerprints,
    )
    onBatch,
    required void Function(ExternalSyncProgress progress) onProgress,
    required bool Function() isCancelled,
    required bool incremental,
    DateTime? lastSyncAt,
    http.Client? httpClient,
  }) async {
    final cfg = resolveConfig(config);
    final token = (cfg['developerToken'] ?? '').trim();
    if (token.isEmpty) {
      throw const ExternalConnectorException('请先填写 Evernote / 印象笔记 Token');
    }
    final url = resolveNoteStoreUrl(cfg);
    final words = cfg['searchWords'] ?? '';

    final owned = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      const pageSize = 50;
      var offset = 0;
      var pageNum = 0;
      var fetched = 0;
      var skippedExisting = 0;
      var updated = 0;
      var consecutiveUnchanged = 0;
      var cancelled = false;
      var fullBackfill = true;

      while (true) {
        if (isCancelled()) {
          cancelled = true;
          fullBackfill = false;
          break;
        }
        pageNum += 1;
        onProgress(
          ExternalSyncProgress(
            page: pageNum,
            fetched: fetched,
            added: fetched,
            message: '正在拉取印象笔记第 $pageNum 页（offset=$offset）…',
          ),
        );
        final list = await _findNotesMetadata(
          client: client,
          url: url,
          token: token,
          offset: offset,
          maxNotes: pageSize,
          words: words,
        );
        if (list.notes.isEmpty) break;

        final batch = <ExternalRecordDraft>[];
        final nextFps = <String, String>{};
        var pageNew = 0;
        var pageOld = 0;

        for (final meta in list.notes) {
          if (isCancelled()) {
            cancelled = true;
            fullBackfill = false;
            break;
          }
          if (meta.guid.isEmpty) continue;
          final fp = '${meta.updatedMs}';
          final devName = deviceNameFor(meta.guid);
          final already = existingDeviceNames.contains(devName);
          if (already &&
              (itemFingerprints[meta.guid] == null ||
                  itemFingerprints[meta.guid] == fp)) {
            skippedExisting += 1;
            pageOld += 1;
            continue;
          }
          if (already) updated += 1;
          pageNew += 1;

          final rawEnml = await _getNoteContent(
            client: client,
            url: url,
            token: token,
            guid: meta.guid,
          );
          final content = ExternalHttpHelper.stripHtmlOrXml(rawEnml);
          final createdAt = meta.createdMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(meta.createdMs)
              : (meta.updatedMs > 0
                    ? DateTime.fromMillisecondsSinceEpoch(meta.updatedMs)
                    : DateTime.now());
          final updatedAt = meta.updatedMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(meta.updatedMs)
              : null;

          batch.add(
            ExternalRecordDraft(
              externalId: meta.guid,
              title: meta.title.trim().isNotEmpty ? meta.title.trim() : '印象笔记',
              content: content.isNotEmpty ? content : meta.title,
              createdAt: createdAt,
              updatedAt: updatedAt,
              fingerprint: fp,
            ),
          );
          nextFps[meta.guid] = fp;
          fetched += 1;
        }

        if (batch.isNotEmpty) {
          await onBatch(batch, nextFps);
        }
        if (cancelled) break;

        if (incremental && pageNew == 0 && pageOld > 0) {
          consecutiveUnchanged += 1;
          if (consecutiveUnchanged >= 2) break;
        } else if (pageNew > 0) {
          consecutiveUnchanged = 0;
        }

        offset += list.notes.length;
        if (offset >= list.totalNotes) break;
      }

      return ExternalConnectorSyncReport(
        pagesScanned: pageNum,
        fetched: fetched,
        skippedExisting: skippedExisting,
        updated: updated,
        cancelled: cancelled,
        completedFullBackfill: fullBackfill && !cancelled,
      );
    } finally {
      if (owned) client.close();
    }
  }
}

class EvernoteNoteMetadata {
  const EvernoteNoteMetadata({
    required this.guid,
    required this.title,
    this.createdMs = 0,
    this.updatedMs = 0,
  });

  final String guid;
  final String title;
  final int createdMs;
  final int updatedMs;
}

class EvernoteNotesMetadataList {
  const EvernoteNotesMetadataList({
    required this.startIndex,
    required this.totalNotes,
    required this.notes,
  });

  final int startIndex;
  final int totalNotes;
  final List<EvernoteNoteMetadata> notes;
}

/// 精简自足的 Apache Thrift `TBinaryProtocol` 编解码器（严格兼容 EDAM NoteStore RPC）。
class EvernoteThriftCodec {
  const EvernoteThriftCodec._();

  static const int _versionMask = 0xffff0000;
  static const int _version1 = 0x80010000;
  static const int _typeCall = 1;
  static const int _typeReply = 2;
  static const int _typeException = 3;

  static const int tStop = 0;
  static const int tBool = 2;
  static const int tByte = 3;
  static const int tDouble = 4;
  static const int tI16 = 6;
  static const int tI32 = 8;
  static const int tI64 = 10;
  static const int tString = 11;
  static const int tStruct = 12;
  static const int tMap = 13;
  static const int tSet = 14;
  static const int tList = 15;

  static Uint8List encodeFindNotesMetadataCall({
    required String authToken,
    required int offset,
    required int maxNotes,
    String words = '',
  }) {
    final w = _ThriftWriter();
    w.writeMessageBegin('findNotesMetadata', _typeCall, 1);
    // 1: authenticationToken
    w.writeFieldBegin(tString, 1);
    w.writeString(authToken);
    // 2: NoteFilter
    w.writeFieldBegin(tStruct, 2);
    w.writeFieldBegin(tI32, 1); // order = 2 (UPDATED)
    w.writeI32(2);
    w.writeFieldBegin(tBool, 2); // ascending = false
    w.writeBool(false);
    if (words.trim().isNotEmpty) {
      w.writeFieldBegin(tString, 3);
      w.writeString(words.trim());
    }
    w.writeFieldStop();
    // 3: offset
    w.writeFieldBegin(tI32, 3);
    w.writeI32(offset);
    // 4: maxNotes
    w.writeFieldBegin(tI32, 4);
    w.writeI32(maxNotes);
    // 5: NotesMetadataResultSpec
    w.writeFieldBegin(tStruct, 5);
    w.writeFieldBegin(tBool, 1); // includeTitle
    w.writeBool(true);
    w.writeFieldBegin(tBool, 3); // includeCreated
    w.writeBool(true);
    w.writeFieldBegin(tBool, 4); // includeUpdated
    w.writeBool(true);
    w.writeFieldBegin(tBool, 7); // includeNotebookGuid
    w.writeBool(true);
    w.writeFieldStop();
    w.writeFieldStop();
    return w.toBytes();
  }

  static Uint8List encodeGetNoteContentCall({
    required String authToken,
    required String guid,
  }) {
    final w = _ThriftWriter();
    w.writeMessageBegin('getNoteContent', _typeCall, 2);
    w.writeFieldBegin(tString, 1);
    w.writeString(authToken);
    w.writeFieldBegin(tString, 2);
    w.writeString(guid);
    w.writeFieldStop();
    return w.toBytes();
  }

  /// 供测试或服务端模拟使用的成功应答编码器。
  static Uint8List encodeFindNotesMetadataReply(
    EvernoteNotesMetadataList result, {
    int seqId = 1,
  }) {
    final w = _ThriftWriter();
    w.writeMessageBegin('findNotesMetadata', _typeReply, seqId);
    w.writeFieldBegin(tStruct, 0);
    w.writeFieldBegin(tI32, 1);
    w.writeI32(result.startIndex);
    w.writeFieldBegin(tI32, 2);
    w.writeI32(result.totalNotes);
    w.writeFieldBegin(tList, 3);
    w.writeListBegin(tStruct, result.notes.length);
    for (final note in result.notes) {
      w.writeFieldBegin(tString, 1);
      w.writeString(note.guid);
      w.writeFieldBegin(tString, 2);
      w.writeString(note.title);
      w.writeFieldBegin(tI64, 4);
      w.writeI64(note.createdMs);
      w.writeFieldBegin(tI64, 5);
      w.writeI64(note.updatedMs);
      w.writeFieldStop();
    }
    w.writeFieldStop();
    w.writeFieldStop();
    return w.toBytes();
  }

  static Uint8List encodeGetNoteContentReply(
    String content, {
    int seqId = 2,
  }) {
    final w = _ThriftWriter();
    w.writeMessageBegin('getNoteContent', _typeReply, seqId);
    w.writeFieldBegin(tString, 0);
    w.writeString(content);
    w.writeFieldStop();
    return w.toBytes();
  }

  static EvernoteNotesMetadataList decodeFindNotesMetadataReply(
    Uint8List bytes,
  ) {
    final r = _ThriftReader(bytes);
    final msg = r.readMessageBegin();
    if (msg.type == _typeException) {
      throw _readApplicationException(r);
    }
    EvernoteNotesMetadataList? success;
    while (true) {
      final f = r.readFieldBegin();
      if (f.type == tStop) break;
      if (f.id == 0 && f.type == tStruct) {
        success = _readNotesMetadataList(r);
      } else if (f.id >= 1 && f.id <= 3 && f.type == tStruct) {
        throw _readEdamException(r, fieldId: f.id);
      } else {
        r.skip(f.type);
      }
    }
    if (success == null) {
      throw const ExternalConnectorException('印象笔记未返回笔记列表数据');
    }
    return success;
  }

  static String decodeGetNoteContentReply(Uint8List bytes) {
    final r = _ThriftReader(bytes);
    final msg = r.readMessageBegin();
    if (msg.type == _typeException) {
      throw _readApplicationException(r);
    }
    String? success;
    while (true) {
      final f = r.readFieldBegin();
      if (f.type == tStop) break;
      if (f.id == 0 && f.type == tString) {
        success = r.readString();
      } else if (f.id >= 1 && f.id <= 3 && f.type == tStruct) {
        throw _readEdamException(r, fieldId: f.id);
      } else {
        r.skip(f.type);
      }
    }
    return success ?? '';
  }

  static EvernoteNotesMetadataList _readNotesMetadataList(_ThriftReader r) {
    var startIndex = 0;
    var totalNotes = 0;
    var notes = <EvernoteNoteMetadata>[];
    while (true) {
      final f = r.readFieldBegin();
      if (f.type == tStop) break;
      if (f.id == 1 && f.type == tI32) {
        startIndex = r.readI32();
      } else if (f.id == 2 && f.type == tI32) {
        totalNotes = r.readI32();
      } else if (f.id == 3 && f.type == tList) {
        final list = r.readListBegin();
        notes = <EvernoteNoteMetadata>[];
        for (var i = 0; i < list.size; i++) {
          if (list.elemType == tStruct) {
            notes.add(_readNoteMetadata(r));
          } else {
            r.skip(list.elemType);
          }
        }
      } else {
        r.skip(f.type);
      }
    }
    return EvernoteNotesMetadataList(
      startIndex: startIndex,
      totalNotes: totalNotes,
      notes: notes,
    );
  }

  static EvernoteNoteMetadata _readNoteMetadata(_ThriftReader r) {
    var guid = '';
    var title = '';
    var created = 0;
    var updated = 0;
    while (true) {
      final f = r.readFieldBegin();
      if (f.type == tStop) break;
      if (f.id == 1 && f.type == tString) {
        guid = r.readString();
      } else if (f.id == 2 && f.type == tString) {
        title = r.readString();
      } else if (f.id == 4 && f.type == tI64) {
        created = r.readI64();
      } else if (f.id == 5 && f.type == tI64) {
        updated = r.readI64();
      } else {
        r.skip(f.type);
      }
    }
    return EvernoteNoteMetadata(
      guid: guid,
      title: title,
      createdMs: created,
      updatedMs: updated,
    );
  }

  static ExternalConnectorException _readApplicationException(_ThriftReader r) {
    var message = 'Evernote Thrift 调用异常';
    while (true) {
      final f = r.readFieldBegin();
      if (f.type == tStop) break;
      if (f.id == 1 && f.type == tString) {
        message = r.readString();
      } else {
        r.skip(f.type);
      }
    }
    return ExternalConnectorException(message);
  }

  static ExternalConnectorException _readEdamException(
    _ThriftReader r, {
    required int fieldId,
  }) {
    var errorCode = 0;
    var paramOrMsg = '';
    var rateLimitSec = 0;
    while (true) {
      final f = r.readFieldBegin();
      if (f.type == tStop) break;
      if (f.id == 1 && f.type == tI32) {
        errorCode = r.readI32();
      } else if (f.id == 2 && f.type == tString) {
        paramOrMsg = r.readString();
      } else if (f.id == 3 && f.type == tI32) {
        rateLimitSec = r.readI32();
      } else {
        r.skip(f.type);
      }
    }
    if (fieldId == 1) {
      final isAuth = errorCode == 3 || errorCode == 8 || errorCode == 9;
      return ExternalConnectorException(
        isAuth
            ? '印象笔记 / Evernote Token 无效或已过期（code=$errorCode）'
            : '印象笔记参数错误（code=$errorCode, $paramOrMsg）',
        statusCode: isAuth ? 401 : null,
        apiCode: '$errorCode',
      );
    }
    if (fieldId == 2 && rateLimitSec > 0) {
      return ExternalConnectorException(
        '触发印象笔记 API 限流，请于 $rateLimitSec 秒后重试',
        statusCode: 429,
        apiCode: '$errorCode',
      );
    }
    return ExternalConnectorException(
      paramOrMsg.isNotEmpty ? '印象笔记服务异常：$paramOrMsg' : '印象笔记服务异常（code=$errorCode）',
      apiCode: '$errorCode',
    );
  }
}

class _ThriftWriter {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  void writeMessageBegin(String name, int type, int seqId) {
    writeI32(EvernoteThriftCodec._version1 | type);
    writeString(name);
    writeI32(seqId);
  }

  void writeFieldBegin(int type, int id) {
    writeByte(type);
    writeI16(id);
  }

  void writeFieldStop() => writeByte(EvernoteThriftCodec.tStop);

  void writeListBegin(int elemType, int size) {
    writeByte(elemType);
    writeI32(size);
  }

  void writeBool(bool v) => writeByte(v ? 1 : 0);

  void writeByte(int v) => _buf.addByte(v & 0xff);

  void writeI16(int v) {
    final bd = ByteData(2)..setInt16(0, v, Endian.big);
    _buf.add(bd.buffer.asUint8List());
  }

  void writeI32(int v) {
    final bd = ByteData(4)..setInt32(0, v, Endian.big);
    _buf.add(bd.buffer.asUint8List());
  }

  void writeI64(int v) {
    final bd = ByteData(8)..setInt64(0, v, Endian.big);
    _buf.add(bd.buffer.asUint8List());
  }

  void writeString(String s) {
    final encoded = utf8.encode(s);
    writeI32(encoded.length);
    _buf.add(encoded);
  }

  Uint8List toBytes() => _buf.toBytes();
}

class _ThriftReader {
  _ThriftReader(this._bytes) : _bd = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _bd;
  int _pos = 0;

  ({String name, int type, int seqId}) readMessageBegin() {
    final size = readI32();
    if (size < 0) {
      final version = size & EvernoteThriftCodec._versionMask;
      if (version != EvernoteThriftCodec._version1) {
        throw const ExternalConnectorException('Thrift 协议版本不兼容');
      }
      final name = readString();
      final seqId = readI32();
      return (name: name, type: size & 0xff, seqId: seqId);
    }
    final nameBytes = readExact(size);
    final type = readByte();
    final seqId = readI32();
    return (name: utf8.decode(nameBytes), type: type, seqId: seqId);
  }

  ({int type, int id}) readFieldBegin() {
    final type = readByte();
    if (type == EvernoteThriftCodec.tStop) return (type: type, id: 0);
    final id = readI16();
    return (type: type, id: id);
  }

  ({int elemType, int size}) readListBegin() {
    final elemType = readByte();
    final size = readI32();
    return (elemType: elemType, size: size);
  }

  int readByte() {
    _ensure(1);
    return _bytes[_pos++];
  }

  int readI16() {
    _ensure(2);
    final v = _bd.getInt16(_pos, Endian.big);
    _pos += 2;
    return v;
  }

  int readI32() {
    _ensure(4);
    final v = _bd.getInt32(_pos, Endian.big);
    _pos += 4;
    return v;
  }

  int readI64() {
    _ensure(8);
    final v = _bd.getInt64(_pos, Endian.big);
    _pos += 8;
    return v;
  }

  String readString() {
    final len = readI32();
    if (len <= 0) return '';
    return utf8.decode(readExact(len), allowMalformed: true);
  }

  Uint8List readExact(int len) {
    _ensure(len);
    final slice = Uint8List.sublistView(_bytes, _pos, _pos + len);
    _pos += len;
    return slice;
  }

  void _ensure(int count) {
    if (_pos + count > _bytes.length) {
      throw const ExternalConnectorException('Thrift 响应报文截断或格式错误');
    }
  }

  void skip(int type) {
    switch (type) {
      case EvernoteThriftCodec.tBool:
      case EvernoteThriftCodec.tByte:
        readExact(1);
      case EvernoteThriftCodec.tI16:
        readExact(2);
      case EvernoteThriftCodec.tI32:
        readExact(4);
      case EvernoteThriftCodec.tI64:
      case EvernoteThriftCodec.tDouble:
        readExact(8);
      case EvernoteThriftCodec.tString:
        readString();
      case EvernoteThriftCodec.tStruct:
        while (true) {
          final f = readFieldBegin();
          if (f.type == EvernoteThriftCodec.tStop) break;
          skip(f.type);
        }
      case EvernoteThriftCodec.tMap:
        final kt = readByte();
        final vt = readByte();
        final sz = readI32();
        for (var i = 0; i < sz; i++) {
          skip(kt);
          skip(vt);
        }
      case EvernoteThriftCodec.tSet:
      case EvernoteThriftCodec.tList:
        final l = readListBegin();
        for (var i = 0; i < l.size; i++) {
          skip(l.elemType);
        }
    }
  }
}
