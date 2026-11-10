/// 录音卡硬件网关 —— 经 card_bridge（Rust FFI）把 reai-card-sdk 的能力暴露给 App。
///
/// 分层：
/// - [RealCardGateway]  桥符号可用时走真实 BLE（引用计数式单例）。
/// - [UnsupportedCardGateway]  桥不可用（模拟器/未链接）时的显式失败实现：
///   所有调用抛 [CardException.unavailable]，界面据此呈现"需要连接录音卡"，
///   不再回退到预置假数据（正式版不能把演示数据当真实设备状态展示）。
///
/// 设计要点（照参考工程踩坑经验）：
/// - **所有命令串行**：SDK 要求设备命令严格串行，这里用一个 Future 链做闸门，
///   避免 UI 连点导致 list_files / status 交错发帧。
/// - **流式协议**：桥回多条消息，`final:true` 收尾；OTA 这类长任务靠它推进度。
/// - **回调内存所有权**：桥交出的 JSON 指针须由 Dart 拷贝后调 free_string 释放。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 设备快照（battery/state/device_info/storage/record 的 Dart 投影）
class CardSnapshot {
  const CardSnapshot({
    required this.batteryLevel,
    required this.isCharging,
    required this.wifiOpen,
    required this.recording,
    required this.fwVersion,
    required this.fwVersionCode,
    required this.wifiVersion,
    required this.wifiVersionCode,
    required this.deviceName,
    required this.deviceId,
    this.storageTotalMb,
    this.storageFreeMb,
    this.realtimeEnabled = false,
    this.recordSession,
    this.recordErrorCode,
    this.recordReason,
  });

  factory CardSnapshot.fromJson(Map<String, dynamic> json) {
    final battery = _map(json['battery']);
    final state = _map(json['state']);
    final info = _map(json['info']);
    final storage = _map(json['storage']);
    // 录音状态只认 `record.isRecording`（RECORD_STATUS 查询的真实结果）。
    // 注意：`state.recordRealtimeEnabled` 是「实时流开关」不是「正在录音」，
    // 早前把它当录音标志用，导致设备侧按下开关开始录音后界面仍显示「未录音」。
    final recordStatus = json['record'] is Map<String, dynamic>
        ? json['record'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return CardSnapshot(
      batteryLevel: _int(battery['level']),
      isCharging: battery['isCharging'] == true,
      wifiOpen: state['wifiOpen'] == true,
      recording: recordStatus['isRecording'] == true,
      realtimeEnabled: recordStatus['realtimeEnabled'] == true,
      recordSession: recordStatus['session'] as String?,
      recordErrorCode: (recordStatus['error'] as num?)?.toInt(),
      recordReason: recordStatus['reason']?.toString(),
      fwVersion: (info['version'] as String?) ?? '',
      fwVersionCode: _int(info['versionCode']),
      wifiVersion: (info['wifiVersion'] as String?) ?? '',
      wifiVersionCode: _int(info['wifiVersionCode']),
      deviceName: (info['deviceName'] as String?) ?? '',
      deviceId: (info['deviceId'] as String?) ?? '',
      storageTotalMb: storage.isEmpty ? null : _int(storage['total']),
      storageFreeMb: storage.isEmpty ? null : _int(storage['free']),
    );
  }

  final int batteryLevel;
  final bool isCharging;
  final bool wifiOpen;
  final bool recording;
  final String fwVersion;
  final int fwVersionCode;
  final String wifiVersion;
  final int wifiVersionCode;
  final String deviceName;
  final String deviceId;
  final int? storageTotalMb;
  final int? storageFreeMb;

  /// 设备端实时流开关是否打开（**不是**"正在录音"，两者独立）。
  final bool realtimeEnabled;

  /// 本次录音的会话编号（主控 0.3.8 起设备回传；旧固件为 null）。
  final String? recordSession;

  /// 录音出错时固件回的错误码（此时 recording 为 false）。
  final int? recordErrorCode;

  /// 这次录音状态变化的来源：button / switch / app / auto …
  final String? recordReason;

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};

  static int _int(Object? value) => value is num ? value.toInt() : 0;
}

/// 扫描到的录音卡：`id` 用于 connect，`name` 是广播名（DYJ 前缀）。
class CardDevice {
  const CardDevice({required this.id, required this.name, this.rssi});
  final String id;
  final String name;
  final int? rssi;
}

/// 设备上的录音文件。
///
/// SDK 的 `FileEntry` 除 name/size 外还带录音会话标记与时间：
/// - `start_at`：段开始时间（Unix 秒，来自同名 .txt 的 timestamp）
/// - `created_at`：FAT 修改时间（`.apm` 即切片结束时间）
/// - `session`/`seq`：主控 0.3.8+ 的会话号与段序号
/// - `synced`：设备时钟是否已同步（false 时时间不是真实日期）
class CardFile {
  const CardFile({
    required this.name,
    required this.size,
    this.index,
    this.createdAtSec,
    this.session,
    this.seq,
    this.startAtSec,
    this.synced,
  });

  factory CardFile.fromJson(Map<String, dynamic> json) => CardFile(
    name: (json['name'] as String?) ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    index: _intOrNull(json['index']),
    createdAtSec: _intOrNull(json['created_at'] ?? json['createdAt']),
    session: _stringOrNull(json['session']),
    seq: _intOrNull(json['seq']),
    startAtSec: _intOrNull(json['start_at'] ?? json['startAt']),
    synced: json['synced'] is bool ? json['synced'] as bool : null,
  );

  final String name;
  final int size;
  final int? index;

  /// Unix 秒；FAT 修改时间（结束时间）。
  final int? createdAtSec;

  /// 8 位十六进制会话号；旧固件为空。
  final String? session;

  /// 会话内段序号，从 1 递增。
  final int? seq;

  /// Unix 秒；段开始时间。优先用它做时间轴定位。
  final int? startAtSec;

  /// 设备时钟是否已同步；false 时 [startAtSec] 不是真实日期。
  final bool? synced;

  bool get isApm => name.toUpperCase().endsWith('.APM');

  bool get isTxt => name.toUpperCase().endsWith('.TXT');

  /// 录音起点；缺失 start_at 时无法可靠推算（等转码拿到时长后再算）。
  DateTime? get startTime => startAtSec == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(startAtSec! * 1000);

  DateTime? get fileModifiedTime => createdAtSec == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(createdAtSec! * 1000);

  static int? _intOrNull(Object? value) =>
      value is num ? value.toInt() : null;

  static String? _stringOrNull(Object? value) {
    if (value is! String) return null;
    final v = value.trim();
    return v.isEmpty ? null : v;
  }
}

/// 下载结果。
class CardDownload {
  const CardDownload({
    required this.path,
    required this.bytesWritten,
    required this.originalName,
  });
  factory CardDownload.fromJson(Map<String, dynamic> json) => CardDownload(
    path: (json['path'] as String?) ?? '',
    bytesWritten: (json['bytesWritten'] as num?)?.toInt() ?? 0,
    originalName: (json['originalName'] as String?) ?? '',
  );
  final String path;
  final int bytesWritten;
  final String originalName;
}

/// 设备扫描到的 Wi-Fi 网络。
class CardWifiNetwork {
  const CardWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.secured,
  });
  factory CardWifiNetwork.fromJson(Map<String, dynamic> json) =>
      CardWifiNetwork(
        ssid: (json['ssid'] as String?) ?? (json['name'] as String?) ?? '',
        rssi: (json['rssi'] as num?)?.toInt() ?? -100,
        secured: json['secured'] == true || json['lock'] == true,
      );
  final String ssid;
  final int rssi;
  final bool secured;
}

/// 设备端已保存的 Wi-Fi 凭据。
class CardWifiCredential {
  const CardWifiCredential({required this.ssid});
  factory CardWifiCredential.fromJson(Map<String, dynamic> json) =>
      CardWifiCredential(
        ssid: (json['ssid'] as String?) ?? (json['name'] as String?) ?? '',
      );
  final String ssid;
}

/// 同步上传状态。
class CardSyncStatus {
  const CardSyncStatus({
    required this.pending,
    required this.uploaded,
    required this.running,
    this.message,
  });
  factory CardSyncStatus.fromJson(Map<String, dynamic> json) => CardSyncStatus(
    pending: (json['pending'] as num?)?.toInt() ?? 0,
    uploaded: (json['uploaded'] as num?)?.toInt() ?? 0,
    running: json['running'] == true || json['state'] == 'running',
    message: json['message'] as String?,
  );
  final int pending;
  final int uploaded;
  final bool running;
  final String? message;
}

/// 服务器上的固件信息。
class CardOtaInfo {
  const CardOtaInfo({
    required this.version,
    required this.versionCode,
    required this.url,
  });
  factory CardOtaInfo.fromJson(Map<String, dynamic> json) => CardOtaInfo(
    version: (json['version'] as String?) ?? '',
    versionCode: (json['versionCode'] as num?)?.toInt() ?? 0,
    url: (json['url'] as String?) ?? '',
  );
  final String version;
  final int versionCode;
  final String url;

  bool isNewerThan(int installedVersionCode) =>
      versionCode > installedVersionCode;
}

/// 长任务进度（OTA 等）。
class CardProgress {
  const CardProgress({
    required this.stage,
    required this.percent,
    required this.text,
    this.version,
    this.sent,
    this.total,
  });
  factory CardProgress.fromJson(Map<String, dynamic> json) => CardProgress(
    stage: (json['stage'] as String?) ?? '',
    percent: (json['percent'] as num?)?.toInt() ?? 0,
    text: (json['text'] as String?) ?? '',
    version: json['version'] as String?,
    sent: (json['sent'] as num?)?.toInt(),
    total: (json['total'] as num?)?.toInt(),
  );
  final String stage;
  final int percent;
  final String text;
  final String? version;
  final int? sent;
  final int? total;
}

/// 实时音频流的一个事件：PCM 数据块，或一次"断档"标记。
///
/// 断档是**证据**不是错误：BLE 积压被丢弃时 SDK 会标记 discontinuous，
/// 我们要把它留给后面的"按切片比对补传"用，而不是悄悄丢掉。
class RealtimeAudioEvent {
  const RealtimeAudioEvent({
    required this.kind,
    this.pcm,
    this.sampleRate = 16000,
    this.receivedSamples = 0,
    this.gapIndex = 0,
  });

  final RealtimeAudioKind kind;

  /// 16bit 单声道小端 PCM 字节（仅 [RealtimeAudioKind.audio] 有值，其余为 null）。
  final Uint8List? pcm;
  final int sampleRate;

  /// 截至本事件累计收到的样本数（含断档之前的）。
  final int receivedSamples;
  final int gapIndex;
}

enum RealtimeAudioKind { open, audio, gap, closed }

/// 一次事件拉取的结果：序号 + 自上次以来新到的事件。
class DeviceEventBatch {
  const DeviceEventBatch({required this.seq, required this.events});
  const DeviceEventBatch.empty(this.seq) : events = const [];

  final int seq;
  final List<Map<String, dynamic>> events;

  /// 其中属于录音状态变化的那些（设备侧拨杆/按键触发）。
  Iterable<Map<String, dynamic>> get recordEvents =>
      events.where((e) => e['event']?['kind'] == 'record');
}


/// 长任务终态。
class CardOtaResult {
  const CardOtaResult({
    required this.module,
    required this.upToDate,
    this.version,
  });
  factory CardOtaResult.fromJson(Map<String, dynamic> json) => CardOtaResult(
    module: (json['module'] as String?) ?? '',
    upToDate: json['upToDate'] == true,
    version: json['version'] as String?,
  );
  final String module;
  final bool upToDate;
  final String? version;
}

/// 转码结果（设备 .apm → WAV）。
class CardAudio {
  const CardAudio({
    required this.path,
    required this.samples,
    required this.durationSecs,
  });
  factory CardAudio.fromJson(Map<String, dynamic> json) => CardAudio(
    path: (json['path'] as String?) ?? '',
    samples: (json['samples'] as num?)?.toInt() ?? 0,
    durationSecs: (json['durationSecs'] as num?)?.toDouble() ?? 0,
  );
  final String path;
  final int samples;
  final double durationSecs;
}

/// 网关错误的分类 —— 界面据此给不同文案，不把"卡没开机"和"桥没链上"混为一谈。
enum CardErrorKind {
  /// 桥不可用（模拟器 / 未链接静态库）
  unavailable,

  /// 未连接（或连接已断开）
  disconnected,

  /// 设备明确返回业务错误（固件 code/msg）
  device,

  /// 超时
  timeout,

  /// 其他
  unknown,
}

class CardException implements Exception {
  const CardException(this.kind, this.message);
  final CardErrorKind kind;
  final String message;

  CardException.unavailable([String? message])
    : this(CardErrorKind.unavailable, message ?? '此设备不支持连接录音卡');
  CardException.disconnected([String? message])
    : this(CardErrorKind.disconnected, message ?? '录音卡未连接');
  CardException.timeout([String? message])
    : this(CardErrorKind.timeout, message ?? '操作超时，请重试');

  @override
  String toString() => 'CardException($kind): $message';
}

abstract class CardGateway {
  /// 真实桥是否就绪。
  bool get available;

  Future<List<CardDevice>> scan({int timeoutMs = 6000});
  Future<CardSnapshot> connect(String deviceId);
  Future<void> disconnect();
  Future<CardSnapshot> snapshot();

  Future<void> record(String action); // start | stop | toggle

  /// 明确开始录音（RECORD_START）。比 toggle 可靠：不依赖 App 与设备状态一致。
  Future<void> startRecording();

  /// 明确停止录音（RECORD_STOP）。设备本就没在录时属于正常情况，不报错。
  Future<void> stopRecording();

  /// 打开实时音频流（录音期间边录边收 PCM）。
  Stream<RealtimeAudioEvent> realtimeAudio();

  /// 关闭实时音频流。幂等：没开也能调。
  Future<void> closeRealtime();

  /// 拉取设备主动推送的事件增量（不访问设备，只读本地队列）。
  ///
  /// 拨杆/按键改变录音状态时，设备自己会推上来；靠这个接口才能在毫秒级跟上，
  /// 而不是等轮询周期。
  Future<DeviceEventBatch> pullEvents({int after = 0});
  Future<void> mark();

  Future<List<CardFile>> files();
  Future<CardDownload> download(String name, String dir);
  Future<void> deleteFile(String name);

  /// 把设备落地文件（.apm）转成 WAV（16kHz/16bit 单声道），供 ASR 上传。
  Future<CardAudio> transcode(String apmPath, String wavPath);

  Future<List<CardWifiNetwork>> scanWifi();
  Future<void> connectWifi(String ssid, String password);
  Future<void> openWifi();
  Future<void> closeWifi();
  Future<List<CardWifiCredential>> wifiCredentials();
  Future<void> forgetWifi(String ssid);

  Future<void> startSync();
  Future<CardSyncStatus> syncStatus();
  Future<void> setUploadUrl(String url);

  Future<CardOtaInfo> otaInfo(String module); // main | wifi
  Stream<CardProgress> otaMain();
  Stream<CardProgress> otaWifi();

  Future<void> syncTime();

  /// 释放资源（进程退出/测试收尾）。
  Future<void> dispose();
}

// ── C ABI 镜像 ──────────────────────────────────────────────

typedef _CbNative = ffi.Void Function(ffi.UintPtr, ffi.Pointer<Utf8>);
typedef _CommandNative =
    ffi.Void Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.NativeFunction<_CbNative>>,
      ffi.UintPtr,
    );
typedef _CommandDart =
    void Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.NativeFunction<_CbNative>>,
      int,
    );
typedef _FreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeDart = void Function(ffi.Pointer<Utf8>);
typedef _VersionNative = ffi.Pointer<Utf8> Function();
typedef _VersionDart = ffi.Pointer<Utf8> Function();

/// FFI 真实网关。
class RealCardGateway implements CardGateway {
  RealCardGateway._(ffi.DynamicLibrary lib)
    : _command = lib
          .lookup<ffi.NativeFunction<_CommandNative>>('card_bridge_command')
          .asFunction(),
      _free = lib
          .lookup<ffi.NativeFunction<_FreeNative>>('card_bridge_free_string')
          .asFunction(),
      _version = lib
          .lookup<ffi.NativeFunction<_VersionNative>>('card_bridge_version')
          .asFunction() {
    _callable = ffi.NativeCallable<_CbNative>.listener(_onEvent);
  }

  static RealCardGateway? _instance;

  /// 桥符号存在则返回单例，否则 null。
  static RealCardGateway? maybe() {
    if (_instance != null) return _instance;
    ffi.DynamicLibrary lib;
    try {
      lib = ffi.DynamicLibrary.process();
    } catch (_) {
      try {
        lib = ffi.DynamicLibrary.open('libcard_bridge.dylib');
      } catch (_) {
        return null;
      }
    }
    try {
      _instance = RealCardGateway._(lib);
      return _instance;
    } catch (_) {
      return null;
    }
  }

  final _CommandDart _command;
  final _FreeDart _free;
  final _VersionDart _version;
  late final ffi.NativeCallable<_CbNative> _callable;

  final Map<int, StreamController<Map<String, dynamic>>> _pending = {};
  int _ticket = 0;

  /// 命令串行闸：SDK 要求设备命令严格串行。
  Future<void> _queue = Future<void>.value();

  @override
  bool get available => true;

  /// 桥版本串（含 SDK 版本），用于「关于」页与排障。
  String get bridgeVersion {
    final ptr = _version();
    if (ptr == ffi.nullptr) return '';
    // version 返回的是 Rust 侧静态 CString，不归 Dart 释放
    return ptr.toDartString();
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _queue;
    _queue = () async {
      await previous;
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }();
    return completer.future;
  }

  // ── 命令通道 ──

  /// 打开一条命令通道，返回该 ticket 的流。
  Stream<Map<String, dynamic>> _open(
    String kind, [
    Map<String, dynamic>? payload,
    Duration? timeout,
  ]) {
    final ticket = ++_ticket;
    final controller = StreamController<Map<String, dynamic>>();
    _pending[ticket] = controller;

    Timer? timer;
    if (timeout != null) {
      timer = Timer(timeout, () {
        final c = _pending.remove(ticket);
        if (c != null && !c.isClosed) {
          c.addError(CardException.timeout('$kind 超时（${timeout.inSeconds}s）'));
          c.close();
        }
      });
    }
    controller.onCancel = () {
      timer?.cancel();
      _pending.remove(ticket);
    };

    final kindPtr = kind.toNativeUtf8();
    final payloadPtr = (payload == null || payload.isEmpty)
        ? ffi.nullptr
        : jsonEncode(payload).toNativeUtf8();
    try {
      _command(kindPtr, payloadPtr, _callable.nativeFunction, ticket);
    } catch (e) {
      _pending.remove(ticket);
      timer?.cancel();
      controller
        ..addError(CardException(CardErrorKind.unknown, '调用桥失败：$e'))
        ..close();
    } finally {
      malloc.free(kindPtr);
      if (payloadPtr != ffi.nullptr) malloc.free(payloadPtr);
    }

    // 终态到达时关掉计时器
    return controller.stream.transform(
      StreamTransformer<
        Map<String, dynamic>,
        Map<String, dynamic>
      >.fromHandlers(
        handleDone: (sink) {
          timer?.cancel();
          sink.close();
        },
      ),
    );
  }

  /// 单次命令：等第一条终态消息。
  Future<Map<String, dynamic>> _once(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 20),
  ]) {
    return _serial(() async {
      final json = await _open(kind, payload, timeout).first;
      if (json['ok'] != true) {
        throw _error(kind, json['error']?.toString());
      }
      return json;
    });
  }

  /// 流式命令：进度逐条推，终态收尾。
  Stream<CardProgress> _progress(
    String kind,
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  ) async* {
    final controller = StreamController<Map<String, dynamic>>();
    final ticket = ++_ticket;
    _pending[ticket] = controller;

    final kindPtr = kind.toNativeUtf8();
    final payloadPtr = (payload == null || payload.isEmpty)
        ? ffi.nullptr
        : jsonEncode(payload).toNativeUtf8();
    try {
      _command(kindPtr, payloadPtr, _callable.nativeFunction, ticket);
    } finally {
      malloc.free(kindPtr);
      if (payloadPtr != ffi.nullptr) malloc.free(payloadPtr);
    }

    await for (final json in controller.stream) {
      if (json['ok'] != true) {
        throw _error(kind, json['error']?.toString());
      }
      if (json['final'] == true) {
        onFinal?.call((json['data'] as Map<String, dynamic>?) ?? const {});
        return;
      }
      final p = json['progress'];
      if (p is Map<String, dynamic>) yield CardProgress.fromJson(p);
    }
  }

  CardException _error(String kind, String? message) {
    final text = message ?? '未知错误';
    final lower = text.toLowerCase();
    if (lower.contains('disconnect') || text.contains('未连接')) {
      return CardException.disconnected(text);
    }
    if (lower.contains('timeout') || text.contains('超时')) {
      return CardException.timeout(text);
    }
    return CardException(CardErrorKind.device, _friendlyDeviceError(text));
  }

  /// 把设备回的错误码翻成人话。
  ///
  /// 固件出错时只回一个 `code`，直接抛给用户就是「code -2」这种看不懂的东西。
  /// 这里统一附上设备原码（排障要），但先说清楚发生了什么、该怎么办。
  ///
  /// **注意**：SDK 与固件文档里都没有设备错误码表，`-1/-2/-3` 的确切含义未知。
  /// 所以这里只说"设备拒绝了这条命令 + 原码"，不猜具体原因（以前那句
  /// 「请确认存储卡已插好、设备未在传输文件」是没有依据的推测话术）。
  static String _friendlyDeviceError(String raw) {
    final match = RegExp(r'code[:\s]*(-?\d+)').firstMatch(raw);
    final code = match == null ? null : int.tryParse(match.group(1)!);
    if (code == null) return raw;
    final suffix = '（设备错误码 $code）';
    return switch (code) {
      -1 => '录音卡拒绝了这条命令，请重连后重试$suffix',
      -2 => '录音卡拒绝了这条命令$suffix',
      -3 => '录音卡当前状态不允许该操作，请稍后重试$suffix',
      _ => '录音卡返回错误$suffix',
    };
  }

  /// 最近一次设备错误附带的诊断详情（null = 没有）。
  static Map<String, dynamic>? lastDeviceErrorDetail;

  void _onEvent(int ticket, ffi.Pointer<Utf8> json) {
    StreamController<Map<String, dynamic>>? controller;
    try {
      final text = json.toDartString();
      controller = _pending[ticket];
      if (controller == null) return;
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final detail = decoded['detail'];
      if (detail is Map<String, dynamic>) {
        lastDeviceErrorDetail = detail;
        debugPrint('[card] 设备错误详情：$detail');
      }
      if (!controller.isClosed) controller.add(decoded);
      if (decoded['final'] == true) {
        _pending.remove(ticket);
        if (!controller.isClosed) controller.close();
      }
    } catch (e) {
      if (controller != null && !controller.isClosed) {
        controller.addError(CardException(CardErrorKind.unknown, '桥回包解析失败：$e'));
        _pending.remove(ticket);
        controller.close();
      }
    } finally {
      _free(json);
    }
  }

  // ── 具体能力 ──

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) async {
    // 扫描窗口之外还要算上设备管理器初始化与首次蓝牙授权弹窗的等待，
    // 所以这里给足余量（iPone 上首次授权是阻塞式对话框）。
    final json = await _once('scan', {
      'timeoutMs': timeoutMs,
    }, Duration(milliseconds: timeoutMs + 30000));
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map((d) {
          return CardDevice(
            id: (d['id'] as String?) ?? '',
            name: (d['name'] as String?) ?? '录音卡',
            rssi: (d['rssi'] as num?)?.toInt(),
          );
        })
        .where((d) => d.id.isNotEmpty)
        .toList();
  }

  @override
  Future<CardSnapshot> connect(String deviceId) async {
    final json = await _once('connect', {
      'id': deviceId,
    }, const Duration(seconds: 30));
    return CardSnapshot.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> disconnect() => _once('disconnect');

  @override
  Future<CardSnapshot> snapshot() async {
    final json = await _once('snapshot');
    return CardSnapshot.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> record(String action) => _once('record', {'action': action});

  @override
  Future<void> startRecording() => _once('record.start');

  @override
  Future<void> stopRecording() async {
    try {
      await _once('record.stop');
    } on CardException catch (e) {
      // 设备本就没在录：固件回「当前没有录音在进行」，这是正常情况
      if (e.message.contains('没有录音')) return;
      rethrow;
    }
  }

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() {
    // 实时流长连接：不设单次超时，靠 closeRealtime() 收尾；
    // 这里不走 _serial 串行闸——实时流只读，不占用设备命令队列。
    final controller = StreamController<RealtimeAudioEvent>();
    final ticket = ++_ticket;
    _pending[ticket] = StreamController<Map<String, dynamic>>();

    void emit(Map<String, dynamic> json) {
      final progress = json['progress'];
      if (progress is! Map<String, dynamic>) {
        if (json['final'] == true) {
          controller.add(
            const RealtimeAudioEvent(kind: RealtimeAudioKind.closed),
          );
        }
        return;
      }
      final state = progress['state']?.toString();
      final received =
          (progress['receivedSamples'] as num?)?.toInt() ?? 0;
      if (state == 'audio') {
        final b64 = progress['pcm']?.toString() ?? '';
        controller.add(
          RealtimeAudioEvent(
            kind: RealtimeAudioKind.audio,
            pcm: base64Decode(b64),
            sampleRate: (progress['sampleRate'] as num?)?.toInt() ?? 16000,
            receivedSamples: received,
          ),
        );
      } else if (state == 'gap') {
        controller.add(
          RealtimeAudioEvent(
            kind: RealtimeAudioKind.gap,
            receivedSamples: received,
            gapIndex: (progress['gapIndex'] as num?)?.toInt() ?? 0,
          ),
        );
      } else if (state == 'open') {
        controller.add(
          const RealtimeAudioEvent(kind: RealtimeAudioKind.open),
        );
      }
    }

    // 复用一个转发器把桥消息送进 stream，终态时收尾
    final inner = _pending[ticket]!;
    inner.stream.listen(
      emit,
      onError: (Object e) {
        if (!controller.isClosed) controller.addError(e);
      },
      onDone: () {
        _pending.remove(ticket);
        if (!controller.isClosed) controller.close();
      },
    );

    final kindPtr = 'realtime.open'.toNativeUtf8();
    try {
      _command(kindPtr, ffi.nullptr, _callable.nativeFunction, ticket);
    } finally {
      malloc.free(kindPtr);
    }
    return controller.stream;
  }

  @override
  Future<void> closeRealtime() async {
    try {
      await _once('realtime.close', const {}, const Duration(seconds: 10));
    } on CardException {
      // 收尾失败不影响录音本身：下次开始录音会重置开关
    }
  }

  @override
  Future<DeviceEventBatch> pullEvents({int after = 0}) async {
    final json = await _once(
      'events.pull',
      {'after': after},
      const Duration(seconds: 5),
    );
    final data = (json['data'] as Map<String, dynamic>?) ?? const {};
    final events = [
      for (final item in (data['events'] as List<dynamic>? ?? const []))
        if (item is Map<String, dynamic>) item,
    ];
    return DeviceEventBatch(
      seq: (data['seq'] as num?)?.toInt() ?? after,
      events: events,
    );
  }

  @override
  Future<void> mark() => _once('mark');

  @override
  Future<List<CardFile>> files() async {
    final json = await _once('files', null, const Duration(seconds: 40));
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(CardFile.fromJson)
        .toList();
  }

  @override
  Future<CardDownload> download(String name, String dir) async {
    final json = await _once('download', {
      'name': name,
      'dir': dir,
    }, const Duration(minutes: 10));
    return CardDownload.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> deleteFile(String name) => _once('deleteFile', {'name': name});

  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) async {
    final json = await _once('transcode', {
      'apm': apmPath,
      'wav': wavPath,
    }, const Duration(minutes: 2));
    return CardAudio.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<List<CardWifiNetwork>> scanWifi() async {
    final json = await _once('wifi.scan', null, const Duration(seconds: 40));
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(CardWifiNetwork.fromJson)
        .toList();
  }

  @override
  Future<void> connectWifi(String ssid, String password) => _once(
    'wifi.connect',
    {'ssid': ssid, 'password': password},
    const Duration(seconds: 40),
  );

  @override
  Future<void> openWifi() => _once('wifi.open');

  @override
  Future<void> closeWifi() => _once('wifi.close');

  @override
  Future<List<CardWifiCredential>> wifiCredentials() async {
    final json = await _once('wifi.credentials');
    final list = (json['data'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(CardWifiCredential.fromJson)
        .toList();
  }

  @override
  Future<void> forgetWifi(String ssid) => _once('wifi.forget', {'ssid': ssid});

  @override
  Future<void> startSync() => _once('sync.start');

  @override
  Future<CardSyncStatus> syncStatus() async {
    final json = await _once('sync.status');
    return CardSyncStatus.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Future<void> setUploadUrl(String url) => _once('upload.setUrl', {'url': url});

  @override
  Future<CardOtaInfo> otaInfo(String module) async {
    final json = await _once('ota.info', {
      'mod': module,
    }, const Duration(seconds: 30));
    return CardOtaInfo.fromJson(
      (json['data'] as Map<String, dynamic>?) ?? const {},
    );
  }

  @override
  Stream<CardProgress> otaMain() => _progress('ota.main', null, null);

  @override
  Stream<CardProgress> otaWifi() => _progress('ota.wifi', null, null);

  @override
  Future<void> syncTime() => _once('time.sync');

  @override
  Future<void> dispose() async {
    for (final c in _pending.values) {
      if (!c.isClosed) await c.close();
    }
    _pending.clear();
  }
}

/// 桥不可用时的实现：所有能力显式失败，绝不返回假数据。
class UnsupportedCardGateway implements CardGateway {
  const UnsupportedCardGateway();

  @override
  bool get available => false;

  Never _fail() => throw CardException.unavailable();

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) async => _fail();
  @override
  Future<CardSnapshot> connect(String deviceId) async => _fail();
  @override
  Future<void> disconnect() async => _fail();
  @override
  Future<CardSnapshot> snapshot() async => _fail();
  @override
  Future<void> record(String action) async => _fail();

  @override
  Future<void> startRecording() async => _fail();

  @override
  Future<void> stopRecording() async => _fail();

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() =>
      Stream<RealtimeAudioEvent>.error(CardException.unavailable());

  @override
  Future<void> closeRealtime() async {}

  @override
  Future<DeviceEventBatch> pullEvents({int after = 0}) async =>
      DeviceEventBatch.empty(after);
  @override
  Future<void> mark() async => _fail();
  @override
  Future<List<CardFile>> files() async => _fail();
  @override
  Future<CardDownload> download(String name, String dir) async => _fail();
  @override
  Future<void> deleteFile(String name) async => _fail();
  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) async => _fail();
  @override
  Future<List<CardWifiNetwork>> scanWifi() async => _fail();
  @override
  Future<void> connectWifi(String ssid, String password) async => _fail();
  @override
  Future<void> openWifi() async => _fail();
  @override
  Future<void> closeWifi() async => _fail();
  @override
  Future<List<CardWifiCredential>> wifiCredentials() async => _fail();
  @override
  Future<void> forgetWifi(String ssid) async => _fail();
  @override
  Future<void> startSync() async => _fail();
  @override
  Future<CardSyncStatus> syncStatus() async => _fail();
  @override
  Future<void> setUploadUrl(String url) async => _fail();
  @override
  Future<CardOtaInfo> otaInfo(String module) async => _fail();
  @override
  Stream<CardProgress> otaMain() => Stream.error(CardException.unavailable());
  @override
  Stream<CardProgress> otaWifi() => Stream.error(CardException.unavailable());
  @override
  Future<void> syncTime() async => _fail();
  @override
  Future<void> dispose() async {}
}

/// 生产环境取网关：桥可用用真实实现，否则显式不支持。
CardGateway realOrUnsupported() =>
    RealCardGateway.maybe() ?? const UnsupportedCardGateway();

/// 命令转发网关：每条 BLE 命令"发出"和"返回"都回调一次 [onActivity]。
///
/// 用途只有一个——给状态机的看门狗提供"最近一次真实蓝牙传输"的时刻：
/// 正在同步/轮询/读状态时不该再额外发心跳探测，而应顺延。
/// 不改变任何命令语义，异常与返回值原样透传。
class ActivityGateway implements CardGateway {
  ActivityGateway(this._inner, this.onActivity);

  final CardGateway _inner;
  final void Function() onActivity;

  Future<T> _run<T>(Future<T> Function() action) async {
    onActivity();
    try {
      return await action();
    } finally {
      onActivity();
    }
  }

  Stream<T> _pipe<T>(Stream<T> source) async* {
    onActivity();
    try {
      yield* source;
    } finally {
      onActivity();
    }
  }

  @override
  bool get available => _inner.available;

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) =>
      _run(() => _inner.scan(timeoutMs: timeoutMs));

  @override
  Future<CardSnapshot> connect(String deviceId) =>
      _run(() => _inner.connect(deviceId));

  @override
  Future<void> disconnect() => _run(_inner.disconnect);

  @override
  Future<CardSnapshot> snapshot() => _run(_inner.snapshot);

  @override
  Future<void> record(String action) => _run(() => _inner.record(action));

  @override
  Future<void> startRecording() => _run(_inner.startRecording);

  @override
  Future<void> stopRecording() => _run(_inner.stopRecording);

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() {
    onActivity();
    return _inner.realtimeAudio();
  }

  @override
  Future<void> closeRealtime() => _run(_inner.closeRealtime);

  @override
  Future<DeviceEventBatch> pullEvents({int after = 0}) =>
      _inner.pullEvents(after: after);

  @override
  Future<void> mark() => _run(_inner.mark);

  @override
  Future<List<CardFile>> files() => _run(_inner.files);

  @override
  Future<CardDownload> download(String name, String dir) =>
      _run(() => _inner.download(name, dir));

  @override
  Future<void> deleteFile(String name) => _run(() => _inner.deleteFile(name));

  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) =>
      _run(() => _inner.transcode(apmPath, wavPath));

  @override
  Future<List<CardWifiNetwork>> scanWifi() => _run(_inner.scanWifi);

  @override
  Future<void> connectWifi(String ssid, String password) =>
      _run(() => _inner.connectWifi(ssid, password));

  @override
  Future<void> openWifi() => _run(_inner.openWifi);

  @override
  Future<void> closeWifi() => _run(_inner.closeWifi);

  @override
  Future<List<CardWifiCredential>> wifiCredentials() =>
      _run(_inner.wifiCredentials);

  @override
  Future<void> forgetWifi(String ssid) => _run(() => _inner.forgetWifi(ssid));

  @override
  Future<void> startSync() => _run(_inner.startSync);

  @override
  Future<CardSyncStatus> syncStatus() => _run(_inner.syncStatus);

  @override
  Future<void> setUploadUrl(String url) => _run(() => _inner.setUploadUrl(url));

  @override
  Future<CardOtaInfo> otaInfo(String module) =>
      _run(() => _inner.otaInfo(module));

  @override
  Stream<CardProgress> otaMain() => _pipe(_inner.otaMain());

  @override
  Stream<CardProgress> otaWifi() => _pipe(_inner.otaWifi());

  @override
  Future<void> syncTime() => _run(_inner.syncTime);

  @override
  Future<void> dispose() => _inner.dispose();
}
