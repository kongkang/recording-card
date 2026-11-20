/// Apple Watch 独立采集硬件协同服务。
///
/// 职责边界：
/// - Watch 作为与「录音卡 V2 / 点一机 V1 / 语音 AI 键盘 V2.1」并列的第 4 种采集硬件
///   （[DeviceKind.appleWatch]），通过 `WCSession` 原生通道 `com.reai.recordingcard/watch`
///   与 iPhone 端协同：手机控制开/停、表端同步状态/电量/本地排队切片、`.m4a` 在本机离线转码为
///   `16kHz / 16-bit / Mono PCM WAV` 后经 [audioSlices] 送入 `AppStore.ingestLiveSlice`。
/// - 仅在 Setting →「硬件设备联动 → Apple Watch 联动」开启后进入扫描与设备选单，
///   默认关闭以保持已有三硬件扫描体验完全不变。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/device/card_gateway.dart';
import '../audio/live_audio_recorder.dart';
import '../recordings/recording_store.dart';

/// iPhone 原生 `WatchHardwareBridge` 上报的 Apple Watch 状态快照。
@immutable
class WatchBridgeStatus {
  const WatchBridgeStatus({
    this.supported = false,
    this.paired = false,
    this.watchAppInstalled = false,
    this.complicationEnabled = false,
    this.reachable = false,
    this.linkLost = false,
    this.isRecording = false,
    this.sessionId,
    this.startedAtMs = 0,
    this.batteryLevel = -1,
    this.isCharging = false,
    this.pendingCount = 0,
    this.syncedCount = 0,
    this.elapsedSec = 0,
    this.lastContactAtMs = 0,
    this.snapshotUpdatedAtMs = 0,
    this.watchName = '我的手表',
    this.watchVersion = '',
    this.watchAppVersion = '',
    this.lastError,
  });

  factory WatchBridgeStatus.fromMap(Map<Object?, Object?> raw) {
    int readInt(String key, String? alt, {int fallback = 0}) {
      final v = raw[key] ?? (alt == null ? null : raw[alt]);
      return v is num ? v.toInt() : fallback;
    }

    String? readStr(String key, String? alt) {
      final v = raw[key] ?? (alt == null ? null : raw[alt]);
      if (v is String && v.trim().isNotEmpty) return v.trim();
      return null;
    }

    final rawName = readStr('watchName', null);
    final installed = raw['watchAppInstalled'] == true;
    return WatchBridgeStatus(
      supported: raw['supported'] == true,
      paired: raw['paired'] == true,
      watchAppInstalled: installed,
      complicationEnabled: raw['complicationEnabled'] is bool
          ? raw['complicationEnabled'] == true
          : installed,
      reachable: raw['reachable'] == true,
      linkLost: raw['linkLost'] == true,
      isRecording: raw['isRecording'] == true,
      sessionId: readStr('activeSessionId', 'sessionId'),
      startedAtMs: readInt('recordingStartedAtMs', 'startedAtMs'),
      batteryLevel: readInt('batteryPercent', 'batteryLevel', fallback: -1),
      isCharging: raw['isCharging'] == true,
      pendingCount: readInt('pendingSliceCount', 'pendingCount'),
      syncedCount: readInt('syncedSliceCount', 'syncedCount'),
      elapsedSec: readInt('elapsedSec', null),
      lastContactAtMs: readInt('lastWatchContactAtMs', 'lastContactAtMs'),
      snapshotUpdatedAtMs: readInt('snapshotUpdatedAtMs', 'updatedAtMs'),
      watchName: (rawName == null || rawName == 'Apple Watch')
          ? '我的手表'
          : rawName,
      watchVersion: readStr('watchVersion', null) ?? '',
      watchAppVersion: readStr('watchAppVersion', 'appVersion') ?? '',
      lastError: readStr('lastError', null),
    );
  }

  final bool supported;
  final bool paired;
  final bool watchAppInstalled;
  final bool complicationEnabled;
  final bool reachable;
  final bool linkLost;
  final bool isRecording;
  final String? sessionId;
  final int startedAtMs;

  /// -1 表示尚未回报电量；UI 严禁直接显示百分比数字，仅用于高中低三档分档。
  final int batteryLevel;
  final bool isCharging;
  final int pendingCount;
  final int syncedCount;
  final int elapsedSec;
  final int lastContactAtMs;
  final int snapshotUpdatedAtMs;
  final String watchName;
  final String watchVersion;
  final String watchAppVersion;
  final String? lastError;

  WatchBridgeStatus copyWith({
    bool? supported,
    bool? paired,
    bool? watchAppInstalled,
    bool? complicationEnabled,
    bool? reachable,
    bool? linkLost,
    bool? isRecording,
    String? sessionId,
    bool clearSessionId = false,
    int? startedAtMs,
    int? batteryLevel,
    bool? isCharging,
    int? pendingCount,
    int? syncedCount,
    int? elapsedSec,
    int? lastContactAtMs,
    int? snapshotUpdatedAtMs,
    String? watchName,
    String? watchVersion,
    String? watchAppVersion,
    String? lastError,
    bool clearLastError = false,
  }) {
    return WatchBridgeStatus(
      supported: supported ?? this.supported,
      paired: paired ?? this.paired,
      watchAppInstalled: watchAppInstalled ?? this.watchAppInstalled,
      complicationEnabled: complicationEnabled ?? this.complicationEnabled,
      reachable: reachable ?? this.reachable,
      linkLost: linkLost ?? this.linkLost,
      isRecording: isRecording ?? this.isRecording,
      sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
      startedAtMs: startedAtMs ?? this.startedAtMs,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      isCharging: isCharging ?? this.isCharging,
      pendingCount: pendingCount ?? this.pendingCount,
      syncedCount: syncedCount ?? this.syncedCount,
      elapsedSec: elapsedSec ?? this.elapsedSec,
      lastContactAtMs: lastContactAtMs ?? this.lastContactAtMs,
      snapshotUpdatedAtMs: snapshotUpdatedAtMs ?? this.snapshotUpdatedAtMs,
      watchName: watchName ?? this.watchName,
      watchVersion: watchVersion ?? this.watchVersion,
      watchAppVersion: watchAppVersion ?? this.watchAppVersion,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }
}

/// 原生桥本地转码完成、等待送入 [AppStore.ingestLiveSlice] 的手表录音切片。
@immutable
class WatchPendingSlicePayload {
  const WatchPendingSlicePayload({
    required this.sliceId,
    required this.sessionId,
    required this.sliceIndex,
    required this.startAtMs,
    required this.durationMs,
    required this.wavPath,
    this.gapCount = 0,
    this.isFinal = false,
    this.offlineRecorded = true,
    this.marksMs = const [],
  });

  factory WatchPendingSlicePayload.fromMap(Map<Object?, Object?> raw) {
    int readInt(String key, {int fallback = 0}) {
      final v = raw[key];
      return v is num ? v.toInt() : fallback;
    }

    final rawMarks = raw['marksMs'] ?? raw['marksOffsetMs'];
    final marks = rawMarks is List
        ? List<int>.unmodifiable([
            for (final item in rawMarks)
              if (item is num) item.toInt(),
          ])
        : const <int>[];

    return WatchPendingSlicePayload(
      sliceId: '${raw['sliceId'] ?? ''}',
      sessionId: '${raw['sessionId'] ?? ''}',
      sliceIndex: readInt('sliceIndex'),
      startAtMs: readInt('startAtMs'),
      durationMs: readInt('durationMs'),
      wavPath: '${raw['wavPath'] ?? ''}',
      gapCount: readInt('gapCount'),
      isFinal: raw['isFinal'] == true,
      offlineRecorded: raw['offlineRecorded'] != false,
      marksMs: marks,
    );
  }

  final String sliceId;
  final String sessionId;
  final int sliceIndex;
  final int startAtMs;
  final int durationMs;
  final String wavPath;
  final int gapCount;
  final bool isFinal;
  final bool offlineRecorded;
  final List<int> marksMs;

  LiveAudioSlice toLiveAudioSlice() {
    final safeSession = sessionId.isNotEmpty ? sessionId : 'watch';
    final safeSliceId = sliceId.isNotEmpty
        ? sliceId
        : '${safeSession}_$sliceIndex';
    return LiveAudioSlice(
      sessionId: 'watch_$safeSession',
      deviceSessionId: safeSession,
      sliceIndex: sliceIndex,
      startAtMs: startAtMs,
      durationMs: durationMs,
      wavPath: wavPath,
      gapCount: gapCount,
      isFinal: isFinal,
      sliceKeyOverride: 'watch_$safeSliceId',
    );
  }
}

/// 已传回 iPhone 并完成 16kHz Mono PCM WAV 转码入库的手表切片历史记录（用于 Setting › Apple Watch 联动试听/导出/清理）。
@immutable
class WatchReceivedSliceRecord {
  const WatchReceivedSliceRecord({
    required this.sliceId,
    required this.sessionId,
    required this.sliceIndex,
    required this.startAtMs,
    required this.durationMs,
    required this.wavPath,
    this.offlineRecorded = true,
    this.marksMs = const [],
    this.fileSizeBytes = 0,
  });

  factory WatchReceivedSliceRecord.fromPayload(
    WatchPendingSlicePayload p, {
    int fileSizeBytes = 0,
  }) {
    final resolvedPath = RecordingStore.rebaseAppSupportPath(p.wavPath);
    var bytes = fileSizeBytes;
    if (bytes <= 0 && resolvedPath.isNotEmpty) {
      try {
        final f = File(resolvedPath);
        if (f.existsSync()) {
          bytes = f.lengthSync();
        }
      } on Object {
        bytes = 0;
      }
    }
    return WatchReceivedSliceRecord(
      sliceId: p.sliceId,
      sessionId: p.sessionId,
      sliceIndex: p.sliceIndex,
      startAtMs: p.startAtMs,
      durationMs: p.durationMs,
      wavPath: resolvedPath,
      offlineRecorded: p.offlineRecorded,
      marksMs: p.marksMs,
      fileSizeBytes: bytes,
    );
  }

  factory WatchReceivedSliceRecord.fromJson(Map<String, dynamic> j) =>
      WatchReceivedSliceRecord(
        sliceId: '${j['id'] ?? ''}',
        sessionId: '${j['ses'] ?? ''}',
        sliceIndex: (j['idx'] as num?)?.toInt() ?? 0,
        startAtMs: (j['at'] as num?)?.toInt() ?? 0,
        durationMs: (j['dur'] as num?)?.toInt() ?? 0,
        wavPath: RecordingStore.rebaseAppSupportPath('${j['wav'] ?? ''}'),
        offlineRecorded: j['off'] != false,
        marksMs: [
          for (final m in (j['mks'] as List? ?? const []))
            if (m is num) m.toInt(),
        ],
        fileSizeBytes: (j['sz'] as num?)?.toInt() ?? 0,
      );

  final String sliceId;
  final String sessionId;
  final int sliceIndex;
  final int startAtMs;
  final int durationMs;
  final String wavPath;
  final bool offlineRecorded;
  final List<int> marksMs;
  final int fileSizeBytes;

  String get fileName {
    final trimmed = wavPath.trim();
    if (trimmed.isEmpty) {
      final numStr = (sliceIndex + 1).toString().padLeft(3, '0');
      return 'WATCH_$numStr.WAV';
    }
    final sepIdx = trimmed.lastIndexOf('/');
    return sepIdx >= 0 ? trimmed.substring(sepIdx + 1) : trimmed;
  }

  Map<String, dynamic> toJson() => {
    'id': sliceId,
    'ses': sessionId,
    'idx': sliceIndex,
    'at': startAtMs,
    'dur': durationMs,
    'wav': wavPath,
    'off': offlineRecorded,
    if (marksMs.isNotEmpty) 'mks': marksMs,
    if (fileSizeBytes > 0) 'sz': fileSizeBytes,
  };
}

/// Apple Watch 平台通道抽象，便于 iOS `MethodChannel` 与测试注入双态切换。
abstract class WatchBridgeBackend {
  Future<WatchBridgeStatus> status();
  Future<WatchBridgeStatus> startRecording({String? sessionId});
  Future<WatchBridgeStatus> stopRecording({String? sessionId});
  Future<void> addMark({int? atMs});
  Future<WatchBridgeStatus> flushPending();
  Future<List<WatchPendingSlicePayload>> drainPendingSlices();
  Future<void> ackConsumedSlice(String sliceId);

  Stream<WatchBridgeStatus> get statusStream;
  Stream<WatchPendingSlicePayload> get sliceReadyStream;
  void dispose();
}

/// iOS `WatchHardwareBridge` (`com.reai.recordingcard/watch`) 的真实实现。
class MethodChannelWatchBackend implements WatchBridgeBackend {
  MethodChannelWatchBackend({
    MethodChannel channel = const MethodChannel('com.reai.recordingcard/watch'),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_handleCallback);
  }

  final MethodChannel _channel;
  final StreamController<WatchBridgeStatus> _statusController =
      StreamController<WatchBridgeStatus>.broadcast();
  final StreamController<WatchPendingSlicePayload> _sliceController =
      StreamController<WatchPendingSlicePayload>.broadcast();
  bool _disposed = false;

  Future<void> _handleCallback(MethodCall call) async {
    if (_disposed) return;
    final args = call.arguments;
    if (args is! Map) return;
    switch (call.method) {
      case 'onWatchStatusChanged':
        _statusController.add(WatchBridgeStatus.fromMap(args));
      case 'onWatchSliceReady':
        final payload = WatchPendingSlicePayload.fromMap(args);
        if (payload.sliceId.isNotEmpty && payload.wavPath.isNotEmpty) {
          _sliceController.add(payload);
        }
    }
  }

  @override
  Future<WatchBridgeStatus> status() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('status');
      if (raw == null) return const WatchBridgeStatus();
      return WatchBridgeStatus.fromMap(raw);
    } on MissingPluginException {
      return const WatchBridgeStatus();
    } on PlatformException {
      return const WatchBridgeStatus();
    }
  }

  @override
  Future<WatchBridgeStatus> startRecording({String? sessionId}) async {
    final raw = await _invokeStatus('startRecording', <String, Object?>{
      'sessionId': ?sessionId,
    });
    return raw;
  }

  @override
  Future<WatchBridgeStatus> stopRecording({String? sessionId}) async {
    final raw = await _invokeStatus('stopRecording', <String, Object?>{
      'sessionId': ?sessionId,
    });
    return raw;
  }

  @override
  Future<void> addMark({int? atMs}) async {
    try {
      await _channel.invokeMethod<void>('addMark', <String, Object?>{
        'atMs': ?atMs,
      });
    } on MissingPluginException {
      throw const CardException(CardErrorKind.unavailable, 'Apple Watch 协同不可用');
    } on PlatformException catch (e) {
      throw CardException(
        e.code == 'watch_unsupported' || e.code == 'watch_not_ready'
            ? CardErrorKind.disconnected
            : CardErrorKind.unknown,
        e.message ?? '手表打点失败',
      );
    }
  }

  @override
  Future<WatchBridgeStatus> flushPending() =>
      _invokeStatus('flushPending', null);

  @override
  Future<List<WatchPendingSlicePayload>> drainPendingSlices() async {
    try {
      final list = await _channel.invokeListMethod<Object?>('drainPendingSlices');
      if (list == null) return const [];
      return [
        for (final item in list)
          if (item is Map) WatchPendingSlicePayload.fromMap(item),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<void> ackConsumedSlice(String sliceId) async {
    try {
      await _channel.invokeMethod<void>('ackConsumedSlice', <String, Object?>{
        'sliceId': sliceId,
      });
    } on MissingPluginException {
      // 非 iOS / 测试环境忽略
    } on PlatformException {
      // 由下次 drain 幂等重试
    }
  }

  Future<WatchBridgeStatus> _invokeStatus(
    String method,
    Map<String, Object?>? args,
  ) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(method, args);
      if (raw == null) return const WatchBridgeStatus();
      return WatchBridgeStatus.fromMap(raw);
    } on MissingPluginException {
      throw const CardException(CardErrorKind.unavailable, 'Apple Watch 协同不可用');
    } on PlatformException catch (e) {
      throw CardException(
        e.code == 'watch_not_ready'
            ? CardErrorKind.disconnected
            : CardErrorKind.unknown,
        e.message ?? 'Apple Watch 操作失败',
      );
    }
  }

  @override
  Stream<WatchBridgeStatus> get statusStream => _statusController.stream;

  @override
  Stream<WatchPendingSlicePayload> get sliceReadyStream =>
      _sliceController.stream;

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    unawaited(_statusController.close());
    unawaited(_sliceController.close());
  }
}

/// 可控假 Watch 后端（供单测与 widget 集成测试验证手表硬件全链路）。
class FakeWatchBridgeBackend implements WatchBridgeBackend {
  FakeWatchBridgeBackend({
    WatchBridgeStatus initialStatus = const WatchBridgeStatus(
      supported: true,
      paired: true,
      watchAppInstalled: true,
      complicationEnabled: true,
      reachable: true,
      batteryLevel: 82,
      watchVersion: '11.1',
    ),
    List<WatchPendingSlicePayload> initialPendingSlices = const [],
  }) : _status = initialStatus {
    _pending.addAll(initialPendingSlices);
  }

  WatchBridgeStatus _status;
  final List<WatchPendingSlicePayload> _pending = [];
  final List<String> ackedSliceIds = [];
  final List<int?> marks = [];
  int startCalls = 0;
  int stopCalls = 0;
  int flushCalls = 0;

  final StreamController<WatchBridgeStatus> _statusCtrl =
      StreamController<WatchBridgeStatus>.broadcast();
  final StreamController<WatchPendingSlicePayload> _sliceCtrl =
      StreamController<WatchPendingSlicePayload>.broadcast();
  bool _disposed = false;

  WatchBridgeStatus get currentStatus => _status;

  void emitStatus(WatchBridgeStatus next) {
    _status = next;
    if (!_disposed) _statusCtrl.add(next);
  }

  void simulateWristToggleRecording(bool recording, {String? sessionId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    emitStatus(
      _status.copyWith(
        isRecording: recording,
        sessionId: recording
            ? (sessionId ?? _status.sessionId ?? 'watch-$now')
            : null,
        clearSessionId: !recording,
        startedAtMs: recording ? now : 0,
      ),
    );
  }

  void simulateBattery(int level, {bool charging = false}) {
    emitStatus(_status.copyWith(batteryLevel: level, isCharging: charging));
  }

  void simulateReachable(bool reachable) {
    emitStatus(
      _status.copyWith(
        reachable: reachable,
        linkLost: reachable ? false : _status.linkLost,
      ),
    );
  }

  void simulateUnexpectedDisconnect() {
    emitStatus(_status.copyWith(reachable: false, linkLost: true));
  }

  void pushReadySlice(WatchPendingSlicePayload payload, {bool notifyStream = true}) {
    _pending.add(payload);
    emitStatus(_status.copyWith(pendingCount: _pending.length));
    if (notifyStream && !_disposed) {
      _sliceCtrl.add(payload);
    }
  }

  @override
  Future<WatchBridgeStatus> status() async => _status;

  @override
  Future<WatchBridgeStatus> startRecording({String? sessionId}) async {
    startCalls += 1;
    if (!_status.supported || !_status.paired || !_status.watchAppInstalled) {
      throw const CardException(
        CardErrorKind.disconnected,
        '未检测到已配对且已安装「录音卡」的 Apple Watch',
      );
    }
    final sid = sessionId ?? 'watch-${DateTime.now().millisecondsSinceEpoch}';
    emitStatus(
      _status.copyWith(
        isRecording: true,
        sessionId: sid,
        startedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return _status;
  }

  @override
  Future<WatchBridgeStatus> stopRecording({String? sessionId}) async {
    stopCalls += 1;
    emitStatus(_status.copyWith(isRecording: false, clearSessionId: true));
    return _status;
  }

  @override
  Future<void> addMark({int? atMs}) async {
    marks.add(atMs);
  }

  @override
  Future<WatchBridgeStatus> flushPending() async {
    flushCalls += 1;
    return _status;
  }

  @override
  Future<List<WatchPendingSlicePayload>> drainPendingSlices() async =>
      List<WatchPendingSlicePayload>.of(_pending);

  @override
  Future<void> ackConsumedSlice(String sliceId) async {
    ackedSliceIds.add(sliceId);
    _pending.removeWhere((p) => p.sliceId == sliceId);
    emitStatus(_status.copyWith(pendingCount: _pending.length));
  }

  @override
  Stream<WatchBridgeStatus> get statusStream => _statusCtrl.stream;

  @override
  Stream<WatchPendingSlicePayload> get sliceReadyStream => _sliceCtrl.stream;

  @override
  void dispose() {
    _disposed = true;
    unawaited(_statusCtrl.close());
    unawaited(_sliceCtrl.close());
  }
}

/// 协调 iOS `WatchHardwareBridge`、设置联动开关与 `DeviceStore` / `AppStore` 切片入库的业务服务。
class WatchHardwareService extends ChangeNotifier {
  WatchHardwareService({
    WatchBridgeBackend? backend,
    String? historyFilePath,
  }) : _backend = backend ?? MethodChannelWatchBackend(),
       _historyFilePath = historyFilePath {
    _loadHistorySync();
    _statusSub = _backend.statusStream.listen(_handleStatusPush);
    _sliceSub = _backend.sliceReadyStream.listen(_handleSlicePush);
  }

  static const String watchDeviceId = 'apple_watch_paired';

  final WatchBridgeBackend _backend;
  final String? _historyFilePath;
  late final StreamSubscription<WatchBridgeStatus> _statusSub;
  late final StreamSubscription<WatchPendingSlicePayload> _sliceSub;

  final StreamController<LiveAudioSlice> _audioSlicesCtrl =
      StreamController<LiveAudioSlice>.broadcast();
  final Set<String> _deliveredSliceIds = <String>{};
  final List<WatchReceivedSliceRecord> _receivedSlices = [];

  bool _linkEnabled = false;
  bool _connectedAsHardware = false;
  WatchBridgeStatus _status = const WatchBridgeStatus();

  static const Duration outOfRangeTimeout = Duration(seconds: 150);

  int _eventSeq = 0;
  final List<({int seq, Map<String, dynamic> event})> _eventQueue = [];
  bool _pendingUnexpectedDisconnect = false;
  DateTime? _lastWatchActivityAt;
  bool _outOfRangeDisconnected = false;
  bool _disposed = false;

  bool get linkEnabled => _linkEnabled;
  bool get isConnectedAsHardware => _connectedAsHardware;
  bool get isOutOfRangeDisconnected => _outOfRangeDisconnected;
  WatchBridgeStatus get currentStatus => _status;
  Stream<LiveAudioSlice> get audioSlices => _audioSlicesCtrl.stream;
  List<WatchReceivedSliceRecord> get receivedSlices =>
      List.unmodifiable(_receivedSlices);

  /// 开启联动且系统已支持并配对 Apple Watch 时进入扫描列表与一键连接。
  bool get availableForScan =>
      _linkEnabled && _status.supported && _status.paired;

  /// 表盘端侧已具备安装与联动开关即可视为就绪展示给扫描。
  CardDevice? get asCardDevice {
    if (!availableForScan) return null;
    return CardDevice(
      id: watchDeviceId,
      name: _status.watchName.isNotEmpty ? _status.watchName : 'Apple Watch',
      rssi: _status.reachable ? -36 : -62,
      kind: DeviceKind.appleWatch,
      displayModel: 'Apple Watch',
      capabilities: HardwareCapabilities.appleWatch,
    );
  }

  Future<void> setLinkEnabled(bool enabled) async {
    if (_linkEnabled == enabled && !_disposed) {
      if (enabled) await refreshStatus();
      return;
    }
    _linkEnabled = enabled;
    notifyListeners();
    if (enabled) {
      await refreshStatus();
      await drainPendingSlices();
    } else {
      _connectedAsHardware = false;
    }
  }

  Future<WatchBridgeStatus> refreshStatus() async {
    final s = await _backend.status();
    if (!_disposed) {
      _applyStatus(s, fromPush: false);
    }
    return _status;
  }

  Future<CardSnapshot> connectHardware() async {
    final s = await refreshStatus();
    if (!s.supported) {
      throw const CardException(CardErrorKind.unavailable, '当前设备不支持 Apple Watch 协同');
    }
    if (!s.paired) {
      throw const CardException(CardErrorKind.disconnected, '未检测到已配对的 Apple Watch');
    }
    if (!s.watchAppInstalled) {
      throw const CardException(
        CardErrorKind.disconnected,
        '请先在 Apple Watch 上安装「录音卡」手表应用',
      );
    }
    if (s.linkLost) {
      throw const CardException(
        CardErrorKind.disconnected,
        'Apple Watch 通信中断，已由本机保底录音接力',
      );
    }
    if (_outOfRangeDisconnected && !s.reachable) {
      final hasRecentContact = s.lastContactAtMs > 0 &&
          DateTime.now().millisecondsSinceEpoch - s.lastContactAtMs <
              outOfRangeTimeout.inMilliseconds;
      if (!hasRecentContact) {
        throw const CardException(
          CardErrorKind.disconnected,
          'Apple Watch 超出通信距离，已由本机保底录音接力',
        );
      }
    }
    _connectedAsHardware = true;
    _pendingUnexpectedDisconnect = false;
    _outOfRangeDisconnected = false;
    _lastWatchActivityAt = DateTime.now();
    _eventQueue.clear();
    notifyListeners();
    unawaited(drainPendingSlices());
    return toSnapshot();
  }

  Future<CardDisconnectReport> disconnectHardware() async {
    _connectedAsHardware = false;
    _pendingUnexpectedDisconnect = false;
    notifyListeners();
    return const CardDisconnectReport(
      released: true,
      hadDevice: true,
      detail: 'apple_watch_disconnected',
    );
  }

  CardSnapshot toSnapshot() {
    final s = _status;
    return CardSnapshot(
      batteryLevel: s.batteryLevel > 0 ? s.batteryLevel : 0,
      hasBattery: s.batteryLevel > 0,
      isCharging: s.isCharging,
      wifiOpen: false,
      recording: s.isRecording,
      realtimeEnabled: false,
      recordSession: s.sessionId,
      fwVersion: s.watchVersion.isNotEmpty ? 'watchOS ${s.watchVersion}' : 'watchOS',
      fwVersionCode: 100,
      wifiVersion: '',
      wifiVersionCode: 0,
      deviceName: s.watchName,
      deviceId: watchDeviceId,
      deviceKind: DeviceKind.appleWatch,
      displayModel: 'Apple Watch',
      capabilities: HardwareCapabilities.appleWatch,
    );
  }

  Future<CardSnapshot> startRecording({String? sessionId}) async {
    _lastWatchActivityAt = DateTime.now();
    _outOfRangeDisconnected = false;
    final s = await _backend.startRecording(sessionId: sessionId);
    _applyStatus(s, fromPush: false);
    return toSnapshot();
  }

  Future<CardSnapshot> stopRecording({String? sessionId}) async {
    final s = await _backend.stopRecording(sessionId: sessionId);
    _applyStatus(s, fromPush: false);
    return toSnapshot();
  }

  Future<void> addMark({int? atMs}) => _backend.addMark(atMs: atMs);

  /// 请求手表端立刻冲刷本地队列，并将手机端收到的 `.wav` 切片全部送入管线。
  Future<int> flushAndDrain() async {
    try {
      final s = await _backend.flushPending();
      _applyStatus(s, fromPush: false);
    } on CardException {
      // 即使手表当前离线，也把手机端已接收待入库的本地切片先消化掉
    } on Object {
      // 避免底层桥返回值异常导致调用方崩溃
    }
    return drainPendingSlices();
  }

  /// 看门狗判定手表在录音期间是否长时间彻底失联（>150s 无心跳、无切片、且不可直连）。
  bool checkOutOfRangeIfNeeded(WatchBridgeStatus s) {
    if (s.reachable) {
      _outOfRangeDisconnected = false;
      _lastWatchActivityAt = DateTime.now();
      return false;
    }
    if (!s.isRecording) {
      return false;
    }
    final last = _lastWatchActivityAt;
    if (last == null) {
      return false;
    }
    if (DateTime.now().difference(last) > outOfRangeTimeout) {
      _outOfRangeDisconnected = true;
      return true;
    }
    return false;
  }

  Future<int> drainPendingSlices() async {
    if (!_linkEnabled) return 0;
    final list = await _backend.drainPendingSlices();
    var count = 0;
    for (final p in list) {
      if (await _emitSlice(p)) {
        count += 1;
      }
    }
    return count;
  }

  DeviceEventBatch pullEvents({int after = 0}) {
    final items = [
      for (final e in _eventQueue)
        if (e.seq > after) e.event,
    ];
    return DeviceEventBatch(seq: _eventSeq, events: items);
  }

  bool consumeUnexpectedDisconnect() {
    if (!_pendingUnexpectedDisconnect) return false;
    _pendingUnexpectedDisconnect = false;
    return true;
  }

  void _handleStatusPush(WatchBridgeStatus s) {
    if (_disposed) return;
    _applyStatus(s, fromPush: true);
    if (_linkEnabled && s.pendingCount > 0) {
      unawaited(drainPendingSlices());
    }
  }

  void _handleSlicePush(WatchPendingSlicePayload p) {
    if (_disposed || !_linkEnabled) return;
    unawaited(_emitSlice(p));
  }

  Future<bool> _emitSlice(WatchPendingSlicePayload p) async {
    if (_disposed || p.sliceId.isEmpty || p.wavPath.isEmpty) return false;
    if (!_deliveredSliceIds.add(p.sliceId)) return false;
    _lastWatchActivityAt = DateTime.now();
    _outOfRangeDisconnected = false;
    final record = WatchReceivedSliceRecord.fromPayload(p);
    _receivedSlices.removeWhere((r) => r.sliceId == record.sliceId);
    _receivedSlices.insert(0, record);
    if (_receivedSlices.length > 50) {
      _receivedSlices.removeRange(50, _receivedSlices.length);
    }
    _persistHistorySync();
    _audioSlicesCtrl.add(p.toLiveAudioSlice());
    await _backend.ackConsumedSlice(p.sliceId);
    if (!_disposed) {
      notifyListeners();
    }
    return true;
  }

  /// 从 Setting › Apple Watch 联动页删除一条已接收切片记录。
  Future<void> deleteReceivedSlice(String sliceId) async {
    final before = _receivedSlices.length;
    _receivedSlices.removeWhere((r) => r.sliceId == sliceId);
    if (_receivedSlices.length != before) {
      _persistHistorySync();
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void _loadHistorySync() {
    final path = _historyFilePath;
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final rec = WatchReceivedSliceRecord.fromJson(item);
            if (rec.sliceId.isNotEmpty) {
              _receivedSlices.add(rec);
            }
          }
        }
      }
    } on Object {
      // 损坏历史不阻塞正常使用
    }
  }

  void _persistHistorySync() {
    final path = _historyFilePath;
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(
        jsonEncode([for (final r in _receivedSlices) r.toJson()]),
        flush: true,
      );
      tmp.renameSync(path);
    } on Object {
      // 忽略落盘异常，保留内存态
    }
  }

  void _applyStatus(WatchBridgeStatus next, {required bool fromPush}) {
    final prev = _status;
    _status = next;

    final hasFreshSignal = !next.linkLost &&
        (next.reachable ||
            (next.lastContactAtMs > 0 &&
                next.lastContactAtMs > prev.lastContactAtMs) ||
            (next.snapshotUpdatedAtMs > 0 &&
                next.snapshotUpdatedAtMs > prev.snapshotUpdatedAtMs) ||
            next.elapsedSec > prev.elapsedSec ||
            next.syncedCount > prev.syncedCount ||
            next.pendingCount != prev.pendingCount ||
            (fromPush &&
                (next.batteryLevel != prev.batteryLevel ||
                    next.isCharging != prev.isCharging ||
                    next.isRecording != prev.isRecording)));
    if (hasFreshSignal) {
      _lastWatchActivityAt = DateTime.now();
      _outOfRangeDisconnected = false;
    }

    if (_connectedAsHardware && fromPush) {
      if (prev.isRecording != next.isRecording) {
        final hasFault = !next.isRecording &&
            next.lastError != null &&
            next.lastError!.trim().isNotEmpty;
        _pushEvent(<String, dynamic>{
          'kind': 'record',
          'status': <String, dynamic>{
            'isRecording': next.isRecording,
            if (next.sessionId != null) 'session': next.sessionId,
            if (hasFault) 'errorMessage': next.lastError!.trim(),
          },
        });
      }
      if (prev.batteryLevel != next.batteryLevel ||
          prev.isCharging != next.isCharging) {
        _pushEvent(<String, dynamic>{
          'kind': 'power',
          'battery': <String, dynamic>{
            'level': next.batteryLevel,
            'isCharging': next.isCharging,
          },
        });
      }
      final isBrokenLink =
          !next.paired || !next.watchAppInstalled || next.linkLost;
      final wasBrokenLink =
          !prev.paired || !prev.watchAppInstalled || prev.linkLost;
      if (isBrokenLink && !wasBrokenLink) {
        _pendingUnexpectedDisconnect = true;
        if (next.linkLost) {
          _outOfRangeDisconnected = true;
        }
        _pushEvent(const <String, dynamic>{'kind': 'disconnected'});
      }
    }
    notifyListeners();
  }

  void _pushEvent(Map<String, dynamic> event) {
    _eventSeq += 1;
    _eventQueue.add((seq: _eventSeq, event: <String, dynamic>{'event': event}));
    if (_eventQueue.length > 64) {
      _eventQueue.removeAt(0);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_statusSub.cancel());
    unawaited(_sliceSub.cancel());
    unawaited(_audioSlicesCtrl.close());
    _backend.dispose();
    super.dispose();
  }
}

/// 组合 BLE 硬件网关与 [WatchHardwareService]，使 Apple Watch 作为第 4 种独立硬件
/// 走同一套扫描 / 连接 / 录音 / 同步 / 断连保底状态机。
class WatchCompositeCardGateway implements CardGateway {
  WatchCompositeCardGateway({
    required this.bleGateway,
    required this.watchService,
  });

  final CardGateway bleGateway;
  final WatchHardwareService watchService;

  bool get _watchActive => watchService.isConnectedAsHardware;

  @override
  bool get available => bleGateway.available || watchService.availableForScan;

  @override
  Future<List<CardDevice>> scan({int timeoutMs = 6000}) async {
    final result = <CardDevice>[];
    if (watchService.linkEnabled) {
      await watchService.refreshStatus();
      final watchDev = watchService.asCardDevice;
      if (watchDev != null) {
        result.add(watchDev);
      }
    }
    if (bleGateway.available) {
      final bleDevices = await bleGateway.scan(timeoutMs: timeoutMs);
      result.addAll(bleDevices);
    } else if (result.isEmpty) {
      return bleGateway.scan(timeoutMs: timeoutMs);
    }
    return result;
  }

  @override
  Future<CardSnapshot?> connect(
    String deviceId, {
    String? name,
    String? deviceKind,
  }) async {
    final isWatch =
        deviceId == WatchHardwareService.watchDeviceId ||
        deviceKind == DeviceKind.appleWatch.code;
    if (isWatch) {
      if (!watchService.linkEnabled) {
        throw const CardException(
          CardErrorKind.unavailable,
          '请在 Setting → Apple Watch 联动中开启手表联动',
        );
      }
      return watchService.connectHardware();
    }
    if (_watchActive) {
      await watchService.disconnectHardware();
    }
    return bleGateway.connect(deviceId, name: name, deviceKind: deviceKind);
  }

  @override
  Future<CardDisconnectReport> disconnect() {
    if (_watchActive) return watchService.disconnectHardware();
    return bleGateway.disconnect();
  }

  @override
  Future<CardSnapshot> snapshot() async {
    if (_watchActive) {
      final s = await watchService.refreshStatus();
      if (!s.paired || !s.watchAppInstalled || s.linkLost) {
        throw const CardException(CardErrorKind.disconnected, 'Apple Watch 未就绪');
      }
      if (watchService.checkOutOfRangeIfNeeded(s)) {
        throw const CardException(
          CardErrorKind.disconnected,
          'Apple Watch 超出通信距离或已关机',
        );
      }
      return watchService.toSnapshot();
    }
    return bleGateway.snapshot();
  }

  @override
  Future<void> record(String action) async {
    if (_watchActive) {
      if (action == 'start') {
        await watchService.startRecording();
      } else if (action == 'stop') {
        await watchService.stopRecording();
      } else {
        if (watchService.currentStatus.isRecording) {
          await watchService.stopRecording();
        } else {
          await watchService.startRecording();
        }
      }
      return;
    }
    return bleGateway.record(action);
  }

  @override
  Future<void> startRecording({int? durationSecs}) async {
    if (_watchActive) {
      await watchService.startRecording();
      return;
    }
    return bleGateway.startRecording(durationSecs: durationSecs);
  }

  @override
  Future<void> stopRecording() async {
    if (_watchActive) {
      await watchService.stopRecording();
      return;
    }
    return bleGateway.stopRecording();
  }

  @override
  Stream<RealtimeAudioEvent> realtimeAudio() {
    if (_watchActive) return const Stream<RealtimeAudioEvent>.empty();
    return bleGateway.realtimeAudio();
  }

  @override
  Future<void> closeRealtime() async {
    if (_watchActive) return;
    return bleGateway.closeRealtime();
  }

  @override
  Future<DeviceEventBatch> pullEvents({int after = 0}) async {
    if (_watchActive) return watchService.pullEvents(after: after);
    return bleGateway.pullEvents(after: after);
  }

  @override
  Future<void> mark() async {
    if (_watchActive) {
      await watchService.addMark();
      return;
    }
    return bleGateway.mark();
  }

  @override
  Future<List<CardFile>> files() {
    if (_watchActive) return Future<List<CardFile>>.value(const []);
    return bleGateway.files();
  }

  @override
  Future<CardDownload> download(String name, String dir) =>
      bleGateway.download(name, dir);

  @override
  Future<CardDownload> takeOldestFile(String dir) =>
      bleGateway.takeOldestFile(dir);

  @override
  Future<void> deleteFile(String name) => bleGateway.deleteFile(name);

  @override
  Future<CardAudio> transcode(String apmPath, String wavPath) =>
      bleGateway.transcode(apmPath, wavPath);

  @override
  Future<List<CameraSyncItem>> syncCameraPhotos(
    String dir, {
    String? serverOrigin,
  }) => _watchActive
      ? Future<List<CameraSyncItem>>.value(const [])
      : bleGateway.syncCameraPhotos(dir, serverOrigin: serverOrigin);

  @override
  Future<List<CardWifiNetwork>> scanWifi() => _watchActive
      ? Future<List<CardWifiNetwork>>.value(const [])
      : bleGateway.scanWifi();

  @override
  Future<void> connectWifi(String ssid, String password) => _watchActive
      ? Future<void>.value()
      : bleGateway.connectWifi(ssid, password);

  @override
  Future<void> openWifi() =>
      _watchActive ? Future<void>.value() : bleGateway.openWifi();

  @override
  Future<void> closeWifi() =>
      _watchActive ? Future<void>.value() : bleGateway.closeWifi();

  @override
  Future<List<CardWifiCredential>> wifiCredentials({bool passive = false}) =>
      _watchActive
      ? Future<List<CardWifiCredential>>.value(const [])
      : bleGateway.wifiCredentials(passive: passive);

  @override
  Future<void> forgetWifi(String ssid) =>
      _watchActive ? Future<void>.value() : bleGateway.forgetWifi(ssid);

  @override
  Future<void> startSync() async {
    if (_watchActive) {
      await watchService.flushAndDrain();
      return;
    }
    return bleGateway.startSync();
  }

  @override
  Future<CardSyncStatus> syncStatus() async {
    if (_watchActive) {
      final s = watchService.currentStatus;
      return CardSyncStatus(
        pending: s.pendingCount,
        uploaded: s.syncedCount,
        running: false,
      );
    }
    return bleGateway.syncStatus();
  }

  @override
  Future<void> setUploadUrl(String url) =>
      _watchActive ? Future<void>.value() : bleGateway.setUploadUrl(url);

  @override
  Future<CardOtaInfo> otaInfo(String module) => bleGateway.otaInfo(module);

  @override
  Stream<CardProgress> otaMain() => bleGateway.otaMain();

  @override
  Stream<CardProgress> otaWifi({bool? restoreWifiOpen}) =>
      bleGateway.otaWifi(restoreWifiOpen: restoreWifiOpen);

  @override
  Future<void> syncTime() =>
      _watchActive ? Future<void>.value() : bleGateway.syncTime();

  @override
  Future<Map<String, dynamic>> invokeBridgeCommand(
    String kind, [
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 30),
  ]) => bleGateway.invokeBridgeCommand(kind, payload, timeout);

  @override
  Stream<CardProgress> invokeBridgeStream(
    String kind, [
    Map<String, dynamic>? payload,
    void Function(Map<String, dynamic>)? onFinal,
  ]) => bleGateway.invokeBridgeStream(kind, payload, onFinal);

  @override
  Future<void> dispose() => bleGateway.dispose();
}
