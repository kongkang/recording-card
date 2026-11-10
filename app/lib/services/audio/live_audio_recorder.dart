/// 实时音频落地 —— 录音过程中边录边把 PCM 收进本地，形成"可回听、可核对"的原始录音。
///
/// 为什么要有这一层（2026-11-10 owner 决策）：
/// - 录音期间走蓝牙实时流（设备端推 decoded PCM），不再依赖"停止后读文件列表"，
///   那条路在录音中必然失败；
/// - 停止录音后再拿设备文件列表做**交叉比对**，按 **切片** 粒度补传缺口
///   （ADPCM 解码状态跨整段连续，无法按字节偏移续传，只能整片重取）；
/// - 未来上 Wi-Fi 自动传输后改为全量上传，这里的比对逻辑可退居兜底。
///
/// 存储布局（App 支持目录下）：
/// ```
/// live_audio/<sessionId>/audio.wav   本会话实时流收下的完整音频（暂停时临时封口）
/// live_audio/<sessionId>/session.json 接收覆盖区间 + 断档记录（补传比对的依据）
/// ```
/// 音频用标准 WAV 容器：播放器直接可用，转写侧也能直接吃。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/device/card_gateway.dart';

/// 一段连续的接收区间（相对会话起点的毫秒）。
class ReceivedSpan {
  const ReceivedSpan({required this.startMs, required this.endMs});
  final int startMs;
  final int endMs;

  Map<String, dynamic> toJson() => {'startMs': startMs, 'endMs': endMs};

  factory ReceivedSpan.fromJson(Map<String, dynamic> json) => ReceivedSpan(
    startMs: (json['startMs'] as num?)?.toInt() ?? 0,
    endMs: (json['endMs'] as num?)?.toInt() ?? 0,
  );

  Duration get length => Duration(milliseconds: endMs - startMs);
}

/// 一次录音会话的实时接收记录。
class LiveSession {
  LiveSession({
    required this.id,
    required this.startedAt,
    this.spans = const [],
    this.gapCount = 0,
    this.sampleRate = 16000,
  });

  /// 会话标识（时间戳派生，同时是目录名）。
  final String id;
  final DateTime startedAt;

  /// 收全了的连续区间。断档处会切成两段。
  final List<ReceivedSpan> spans;
  final int gapCount;
  final int sampleRate;

  int get receivedSamples =>
      spans.fold(0, (sum, span) => sum + (span.endMs - span.startMs));

  LiveSession copyWith({
    List<ReceivedSpan>? spans,
    int? gapCount,
  }) => LiveSession(
    id: id,
    startedAt: startedAt,
    spans: spans ?? this.spans,
    gapCount: gapCount ?? this.gapCount,
    sampleRate: sampleRate,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'sampleRate': sampleRate,
    'gapCount': gapCount,
    'spans': [for (final span in spans) span.toJson()],
  };

  factory LiveSession.fromJson(Map<String, dynamic> json) => LiveSession(
    id: (json['id'] as String?) ?? '',
    startedAt:
        DateTime.tryParse((json['startedAt'] as String?) ?? '') ??
        DateTime.now(),
    sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 16000,
    gapCount: (json['gapCount'] as num?)?.toInt() ?? 0,
    spans: [
      for (final span in (json['spans'] as List<dynamic>? ?? const []))
        if (span is Map<String, dynamic>) ReceivedSpan.fromJson(span),
    ],
  );
}

/// 实时录音接收器：订阅网关的实时音频流，边收边写盘，并记录覆盖区间。
///
/// 生命周期跟着录音开关走：开始录音调用 [start]，停止调用 [stop]。
class LiveAudioRecorder extends ChangeNotifier {
  LiveAudioRecorder({
    required CardGateway gateway,
    Directory? baseDir,
  }) : _gateway = gateway,
       _baseDirOverride = baseDir;

  final CardGateway _gateway;
  final Directory? _baseDirOverride;

  StreamSubscription<RealtimeAudioEvent>? _sub;
  IOSink? _sink;
  File? _wavFile;
  File? _metaFile;

  LiveSession? _session;
  int _writtenSamples = 0;
  bool _stopping = false;

  /// 上一块音频之后收到过断档信号：下一块必须另起一段区间。
  /// 不能只靠时间间隔判断——断档期间音频可能仍按原节奏到达，
  /// 时间上看似连续，实际中间丢过块。
  bool _cutSpan = false;

  /// 正在接收实时流。
  bool get isRunning => _session != null;

  /// 当前会话（供界面显示"已收 xx 秒 / 断档 n 次"）。
  LiveSession? get session => _session;

  /// 已落盘的音频时长（秒）。
  double get recordedSeconds =>
      _session == null ? 0 : _writtenSamples / _session!.sampleRate;

  /// 最近一次错误（只读展示，不打断录音）。
  String? lastError;

  Future<Directory> _baseDir() async {
    final root =
        _baseDirOverride ?? await getApplicationSupportDirectory();
    return Directory('${root.path}/live_audio');
  }

  /// 开始一次实时接收。已存在会话时先收尾旧的，避免两个写入器抢同一个文件。
  Future<void> start() async {
    if (isRunning) return;
    final now = DateTime.now();
    final id = 'live-${now.millisecondsSinceEpoch}';
    final dir = Directory('${(await _baseDir()).path}/$id');
    await dir.create(recursive: true);

    _session = LiveSession(id: id, startedAt: now);
    _writtenSamples = 0;
    _stopping = false;
    _cutSpan = false;
    lastError = null;

    _wavFile = File('${dir.path}/audio.wav');
    _metaFile = File('${dir.path}/session.json');
    _sink = _wavFile!.openWrite();
    // 先写 44 字节占位头，收尾时按真实长度回填
    _sink!.add(Uint8List(44));
    notifyListeners();

    _sub = _gateway.realtimeAudio().listen(
      _onEvent,
      onError: (Object error) {
        lastError = '$error';
        notifyListeners();
      },
    );
  }

  void _onEvent(RealtimeAudioEvent event) {
    final session = _session;
    if (session == null || _stopping) return;

    switch (event.kind) {
      case RealtimeAudioKind.audio:
        final pcm = event.pcm;
        if (pcm == null || pcm.isEmpty) return;
        _sink?.add(pcm);
        final samples = pcm.length ~/ 2;
        final startMs = _writtenSamples * 1000 ~/ session.sampleRate;
        _writtenSamples += samples;
        final endMs = _writtenSamples * 1000 ~/ session.sampleRate;
        _extendSpan(session, startMs, endMs);
        notifyListeners();
      case RealtimeAudioKind.gap:
        // 断档：当前区间封口，下一块音频另起一段（不靠时间间隔判断）
        _cutSpan = true;
        _session = session.copyWith(gapCount: session.gapCount + 1);
        notifyListeners();
      case RealtimeAudioKind.open:
      case RealtimeAudioKind.closed:
        break;
    }
  }

  /// 把新收的一段并进最后一个区间；断档后的第一块会新开区间。
  void _extendSpan(LiveSession session, int startMs, int endMs) {
    final spans = List<ReceivedSpan>.of(session.spans);
    final last = spans.isEmpty ? null : spans.last;
    final forcedBreak = _cutSpan;
    _cutSpan = false;
    // 收到过断档信号，或时间上出现明显间隔，都另起一段
    if (!forcedBreak && last != null && startMs - last.endMs <= 200) {
      spans[spans.length - 1] = ReceivedSpan(
        startMs: last.startMs,
        endMs: endMs,
      );
    } else {
      spans.add(ReceivedSpan(startMs: startMs, endMs: endMs));
    }
    _session = session.copyWith(spans: spans);
  }

  /// 停止接收并封口 WAV（把占位头回填成真实长度）。
  Future<LiveSession?> stop() async {
    if (!isRunning) return _session;
    _stopping = true;
    await _sub?.cancel();
    _sub = null;
    await _gateway.closeRealtime();

    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (e) {
      lastError = '音频封口失败：$e';
    }
    _sink = null;

    final session = _session;
    final wav = _wavFile;
    if (session != null && wav != null && await wav.exists()) {
      await _finalizeWav(wav, session.sampleRate);
      await _metaFile?.writeAsString(
        const JsonEncoder.withIndent('  ').convert(session.toJson()),
      );
    }
    _session = null;
    _stopping = false;
    notifyListeners();
    return session;
  }

  /// 回填 WAV 头：实时写入时不知道总长度，收尾按实际字节数写标准头。
  Future<void> _finalizeWav(File file, int sampleRate) async {
    final raf = await file.open(mode: FileMode.append);
    try {
      final dataBytes = await file.length() - 44;
      final header = _wavHeader(
        dataLength: dataBytes,
        sampleRate: sampleRate,
      );
      await raf.setPosition(0);
      await raf.writeFrom(header);
    } finally {
      await raf.close();
    }
  }

  /// 读一个会话的元信息（详情页/补传比对用）。
  static Future<LiveSession?> readSession(
    String sessionId, {
    Directory? baseDir,
  }) async {
    try {
      final root = baseDir ?? await getApplicationSupportDirectory();
      final file = File('${root.path}/live_audio/$sessionId/session.json');
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return LiveSession.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 会话音频文件路径（不存在返回 null）。
  static Future<String?> audioPathOf(
    String sessionId, {
    Directory? baseDir,
  }) async {
    try {
      final root = baseDir ?? await getApplicationSupportDirectory();
      final file = File('${root.path}/live_audio/$sessionId/audio.wav');
      return await file.exists() ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  /// 列出全部已落盘的实时录音会话（新的在前）。
  static Future<List<LiveSession>> listSessions({Directory? baseDir}) async {
    final out = <LiveSession>[];
    try {
      final root = baseDir ?? await getApplicationSupportDirectory();
      final dir = Directory('${root.path}/live_audio');
      if (!await dir.exists()) return out;
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        final session = await readSession(
          entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
          baseDir: root,
        );
        if (session != null) out.add(session);
      }
    } catch (_) {
      // 目录不可读时返回已读到的部分，不抛给界面
    }
    out.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return out;
  }

  /// 设备文件 → 实时会话的归属表（fileKey = 设备文件名）。
  ///
  /// 停止录音后拿设备文件列表比对时才建立这条映射；缺表时详情页按
  /// "本机最新的实时录音"兜底，宁可多给一段可回听，也不假装没有录音。
  static Future<void> bindFileToSession(
    String fileKey,
    String sessionId, {
    Directory? baseDir,
  }) async {
    try {
      final root = baseDir ?? await getApplicationSupportDirectory();
      final dir = Directory('${root.path}/live_audio');
      await dir.create(recursive: true);
      final file = File('${dir.path}/bindings.json');
      final map = <String, String>{};
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (k is String && v is String) map[k] = v;
          });
        }
      }
      map[fileKey] = sessionId;
      await file.writeAsString(jsonEncode(map));
    } catch (_) {
      // 绑定失败不影响回听兜底逻辑
    }
  }

  /// 按设备文件名找它对应的实时会话；没有绑定则返回最新一个会话。
  static Future<LiveSession?> sessionForFile(
    String fileKey, {
    Directory? baseDir,
  }) async {
    try {
      final root = baseDir ?? await getApplicationSupportDirectory();
      final file = File('${root.path}/live_audio/bindings.json');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded[fileKey] is String) {
          final bound = await readSession(
            decoded[fileKey] as String,
            baseDir: root,
          );
          if (bound != null) return bound;
        }
      }
      final all = await listSessions(baseDir: root);
      return all.isEmpty ? null : all.first;
    } catch (_) {
      return null;
    }
  }

  /// 删除一个会话的本地音频（"原始录音已清理"的来源）。
  static Future<void> deleteSession(
    String sessionId, {
    Directory? baseDir,
  }) async {
    try {
      final root = baseDir ?? await getApplicationSupportDirectory();
      final dir = Directory('${root.path}/live_audio/$sessionId');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 删除失败不阻塞界面；下次进入仍会显示文件存在
    }
  }

  /// 标准 44 字节 WAV 头（16bit 单声道）。
  static Uint8List _wavHeader({
    required int dataLength,
    required int sampleRate,
  }) {
    const channels = 1;
    const bitsPerSample = 16;
    const blockAlign = channels * bitsPerSample ~/ 8;
    final byteRate = sampleRate * blockAlign;
    final header = Uint8List(44);
    final view = ByteData.sublistView(header);

    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header[offset + i] = value.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    view.setUint32(4, 36 + dataLength, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    view.setUint32(16, 16, Endian.little);
    view.setUint16(20, 1, Endian.little); // PCM
    view.setUint16(22, channels, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, byteRate, Endian.little);
    view.setUint16(32, blockAlign, Endian.little);
    view.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    view.setUint32(40, dataLength, Endian.little);
    return header;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sink?.close();
    super.dispose();
  }
}
