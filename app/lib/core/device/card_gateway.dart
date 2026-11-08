/// Recording-card SDK facade. Production failures are readable exceptions, never
/// null/seed-data success. MockCardGateway is explicit test injection only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

class CardGatewayException implements Exception {
  const CardGatewayException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class CardDevice {
  const CardDevice({required this.id, required this.name, this.rssi});
  factory CardDevice.fromJson(Map<String, dynamic> j) => CardDevice(
    id: _requiredString(j, 'id'),
    name: _requiredString(j, 'name'),
    rssi: (j['rssi'] as num?)?.toInt(),
  );
  final String id;
  final String name;
  final int? rssi;
}

class CardSnapshot {
  const CardSnapshot({
    required this.batteryLevel,
    required this.isCharging,
    required this.wifiOpen,
    required this.recording,
    required this.fwVersion,
    required this.wifiVersion,
    this.deviceId = '',
    this.versionCode = 0,
    this.wifiVersionCode,
    this.realtimeEnabled = false,
    this.wifiConnected = false,
    this.wifiSsid,
    this.recordingSession,
  });
  factory CardSnapshot.fromJson(Map<String, dynamic> j) {
    final battery = _map(j['battery']);
    final state = _map(j['state']);
    final info = _map(j['info']);
    final record = _map(j['record']);
    final wifi = _map(j['wifi']);
    return CardSnapshot(
      batteryLevel: (battery['level'] as num).toInt(),
      isCharging: battery['isCharging'] as bool,
      wifiOpen: state['wifiOpen'] as bool,
      // Actual RECORD_STATUS, not STATE_INFO's realtime preference.
      recording: record['isRecording'] as bool,
      fwVersion: _requiredString(info, 'version'),
      wifiVersion:
          wifi['version'] as String? ?? info['wifiVersion'] as String? ?? '',
      deviceId: _requiredString(info, 'deviceId'),
      versionCode: (info['versionCode'] as num).toInt(),
      wifiVersionCode:
          (wifi['versionCode'] as num?)?.toInt() ??
          (info['wifiVersionCode'] as num?)?.toInt(),
      realtimeEnabled: record['realtimeEnabled'] as bool,
      wifiConnected: wifi['connected'] as bool,
      wifiSsid: wifi['ssid'] as String?,
      recordingSession: record['session'] as String?,
    );
  }
  final int batteryLevel;
  final bool isCharging;
  final bool wifiOpen;
  final bool recording;
  final String fwVersion;
  final String wifiVersion;
  final String deviceId;
  final int versionCode;
  final int? wifiVersionCode;
  final bool realtimeEnabled;
  final bool wifiConnected;
  final String? wifiSsid;
  final String? recordingSession;
}

enum CardTransfer { ap, ble }

class CardFile {
  const CardFile({
    required this.name,
    this.size,
    this.createdAt,
    this.startAt,
    this.session,
    this.sequence,
    this.clockSynced,
    this.isDirectory = false,
    this.transport = CardTransfer.ap,
  });
  factory CardFile.fromJson(Map<String, dynamic> j) => CardFile(
    name: _requiredString(j, 'name'),
    size: (j['size'] as num?)?.toInt(),
    createdAt: (j['createdAt'] as num?)?.toInt(),
    startAt: (j['startAt'] as num?)?.toInt(),
    session: j['session'] as String?,
    sequence: (j['seq'] as num?)?.toInt(),
    clockSynced: j['synced'] as bool?,
    isDirectory: j['isDirectory'] as bool? ?? false,
    transport: j['transport'] == 'ble' ? CardTransfer.ble : CardTransfer.ap,
  );
  final String name;
  final int? size;

  /// Unix seconds. Only startAt + clockSynced==true is a reliable recording date.
  final int? createdAt;
  final int? startAt;
  final String? session;
  final int? sequence;
  final bool? clockSynced;
  final bool isDirectory;

  /// Listing channel; download still defaults to AP, not this channel.
  final CardTransfer transport;
}

class CardWifiNetwork {
  const CardWifiNetwork({
    required this.ssid,
    this.rssi,
    this.encryption,
    this.index = 0,
  });
  factory CardWifiNetwork.fromJson(Map<String, dynamic> j) => CardWifiNetwork(
    ssid: _requiredString(j, 'ssid'),
    rssi: (j['rssi'] as num?)?.toInt(),
    encryption: j['encryption'] as String?,
    index: (j['index'] as num?)?.toInt() ?? 0,
  );
  final String ssid;
  final int? rssi;
  final String? encryption;
  final int index;
}

class CardWifiCredential {
  const CardWifiCredential(this.ssid, {this.lastUsed});
  final String ssid;
  final int? lastUsed;
  // Password deliberately never returned/stored by this gateway. WIFI_CONNECT
  // persists credentials on card firmware after success; secure app storage is
  // the integrator's responsibility if a separate remember-password UI exists.
}

class CardDownload {
  const CardDownload({
    required this.path,
    required this.bytes,
    required this.originalName,
    required this.sourceDeleted,
    this.deviceName,
    this.recordedAt,
  });
  factory CardDownload.fromJson(Map<String, dynamic> j) => CardDownload(
    path: _requiredString(j, 'path'),
    bytes: (j['bytes'] as num).toInt(),
    originalName: _requiredString(j, 'originalName'),
    sourceDeleted: j['sourceDeleted'] as bool,
    deviceName: j['deviceName'] as String?,
    recordedAt: j['recordedAt'] == null
        ? null
        : DateTime.parse(j['recordedAt'] as String),
  );
  final String path;
  final int bytes;
  final String originalName;
  final bool sourceDeleted;
  final String? deviceName;
  final DateTime? recordedAt;
}

class CardProgress {
  const CardProgress(this.stage, {this.done, this.total});
  final String stage;
  final int? done;
  final int? total;
  double? get fraction =>
      done != null && total != null && total! > 0 ? done! / total! : null;
}

class CardAudioTask {
  const CardAudioTask({
    required this.taskId,
    required this.manifestPath,
    required this.chunkSeconds,
    required this.startedRecording,
  });
  factory CardAudioTask.fromJson(Map<String, dynamic> j) => CardAudioTask(
    taskId: _requiredString(j, 'taskId'),
    manifestPath: _requiredString(j, 'manifestPath'),
    chunkSeconds: (j['chunkSeconds'] as num).toInt(),
    startedRecording: j['startedRecording'] as bool,
  );
  final String taskId;
  final String manifestPath;
  final int chunkSeconds;
  final bool startedRecording;
}

class CardAudioChunk {
  const CardAudioChunk({
    required this.taskId,
    required this.path,
    required this.index,
    required this.samples,
    required this.receivedSampleOffset,
    required this.discontinuous,
    required this.droppedChunks,
    required this.isFinal,
    required this.interrupted,
  });
  factory CardAudioChunk.fromJson(Map<String, dynamic> j) => CardAudioChunk(
    taskId: _requiredString(j, 'taskId'),
    path: _requiredString(j, 'path'),
    index: (j['index'] as num).toInt(),
    samples: (j['samples'] as num).toInt(),
    receivedSampleOffset: (j['receivedSampleOffset'] as num).toInt(),
    discontinuous: j['discontinuous'] as bool,
    droppedChunks: (j['droppedChunks'] as num).toInt(),
    isFinal: j['isFinal'] as bool,
    interrupted: j['interrupted'] as bool,
  );
  final String taskId;

  /// Already flushed/atomically renamed 16kHz mono PCM16 WAV, not raw ADPCM.
  final String path;
  final int index;
  final int samples;

  /// Received sample count, not an absolute device timestamp after a gap.
  final int receivedSampleOffset;
  final bool discontinuous;
  final int droppedChunks;
  final bool isFinal;
  final bool interrupted;
}

class CardFirmwarePlan {
  const CardFirmwarePlan({
    required this.module,
    required this.transportId,
    required this.deviceId,
    required this.installedVersionCode,
    required this.targetVersionCode,
    required this.targetVersion,
    required this.packagePath,
    required this.sha256,
    this.dfuTargetId,
    this.chipModel,
  });

  /// 'main' or 'wifi'; perform stages sequentially with a fresh snapshot/plan.
  final String module;
  final String transportId;
  final String deviceId;
  final int installedVersionCode;
  final int targetVersionCode;
  final String targetVersion;
  final String packagePath;

  /// Trusted release configuration digest, not an untrusted file's self-hash.
  final String sha256;

  /// Exact bootloader identity preselected/confirmed, never first discovered.
  final String? dfuTargetId;

  /// Exact AP ota_status chipModel for Wi-Fi package binding.
  final String? chipModel;
  Map<String, dynamic> toJson() => {
    'module': module,
    'transportId': transportId,
    'deviceId': deviceId,
    'installedVersionCode': installedVersionCode,
    'targetVersionCode': targetVersionCode,
    'targetVersion': targetVersion,
    'packagePath': packagePath,
    'sha256': sha256,
    'dfuTargetId': dfuTargetId,
    'chipModel': chipModel,
  };
}

/// Defaults reject unavailable capabilities, allowing focused test doubles to
/// extend this class without manufacturing successful hardware results.
abstract class CardGateway {
  const CardGateway();
  bool get available => false;
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  Stream<CardAudioChunk> get audioChunks => events
      .where((e) => e['kind'] == 'audioChunk')
      .map(CardAudioChunk.fromJson);
  Never _unsupported() =>
      throw const CardGatewayException('unavailable', '设备桥未配置或当前网关不支持此操作');
  Future<List<CardDevice>> scan({int timeoutMs = 3000}) async => _unsupported();
  Future<CardSnapshot> connect(String id) async => _unsupported();
  Future<void> disconnect() async => _unsupported();
  Future<CardSnapshot> status() async => _unsupported();
  Future<List<CardFile>> listFiles({String? folder}) async => _unsupported();
  Future<CardDownload> downloadFile(
    String name, {
    required String directory,
    int? expectedBytes,
    CardTransfer transport = CardTransfer.ap,
    bool allowDestructive = false,
    void Function(CardProgress)? onProgress,
  }) async => _unsupported();
  Future<String> convertAudio(
    String source, {
    required String destination,
    String format = 'apm',
  }) async => _unsupported();
  Future<void> setWifiEnabled(bool enabled) async => _unsupported();
  Future<Map<String, dynamic>> wifiStatus() async => _unsupported();
  Future<Map<String, dynamic>> wifiOtaStatus() async => _unsupported();
  Future<Map<String, dynamic>> apOtaStatus() async => _unsupported();
  Future<CardAudioTask> startAudioCapture({
    required String taskId,
    required String directory,
    int chunkSeconds = 30,
    bool startRecordingIfIdle = false,
  }) async => _unsupported();
  Future<Map<String, dynamic>> stopAudioCapture(
    String taskId, {
    bool stopOwnedRecording = false,
  }) async => _unsupported();
  Future<Map<String, dynamic>> audioCaptureStatus() async => _unsupported();
  Future<List<CardWifiNetwork>> scanWifi() async => _unsupported();
  Future<Map<String, dynamic>> connectWifi(
    String ssid,
    String password,
  ) async => _unsupported();
  Future<void> disconnectWifi() async => _unsupported();
  Future<List<CardWifiCredential>> listWifiCredentials() async =>
      _unsupported();
  Future<void> deleteWifiCredential(String ssid) async => _unsupported();
  Future<Map<String, dynamic>> setRecording(bool enabled) async =>
      _unsupported();
  Future<void> setRealtimeEnabled(bool enabled) async => _unsupported();
  Future<Map<String, dynamic>> recordMark() async => _unsupported();
  Future<Map<String, dynamic>> controlBindings() async => _unsupported();
  Future<void> setMarkEnabled(
    bool enabled, {
    String input = 'btn_single',
    required String expectedAction,
    required bool userConfirmed,
  }) async => _unsupported();
  Future<List<Map<String, dynamic>>> checkFirmware({
    required String apiBaseUrl,
    required List<String> allowedHosts,
  }) async => _unsupported();
  Future<Map<String, dynamic>> checkWifiOta({
    required String apiBaseUrl,
    required List<String> allowedHosts,
  }) async => _unsupported();
  Future<Map<String, dynamic>> updateFirmware(
    CardFirmwarePlan plan, {
    required bool userConfirmed,
    void Function(CardProgress)? onProgress,
  }) async => _unsupported();
  Future<void> openWifiSettings() async => _unsupported();
}

/// Never choose automatically in production. Empty fixture status rejects rather
/// than returning null and preserving UI seed values.
class MockCardGateway extends CardGateway {
  const MockCardGateway({
    this.snapshot,
    this.devices = const [],
    this.files = const [],
  });
  final CardSnapshot? snapshot;
  final List<CardDevice> devices;
  final List<CardFile> files;
  @override
  bool get available => true;
  @override
  Future<CardSnapshot> status() async =>
      snapshot ?? (throw const CardGatewayException('fixture', '测试设备快照未注入'));
  @override
  Future<List<CardDevice>> scan({int timeoutMs = 3000}) async => devices;
  @override
  Future<CardSnapshot> connect(String id) async {
    if (!devices.any((d) => d.id == id)) {
      throw const CardGatewayException('notFound', '测试设备不存在');
    }
    return status();
  }

  @override
  Future<void> disconnect() async {}
  @override
  Future<List<CardFile>> listFiles({String? folder}) async => files;
}

class UnavailableCardGateway extends CardGateway {
  const UnavailableCardGateway();
}

typedef _CallbackNative = ffi.Void Function(ffi.UintPtr, ffi.Pointer<Utf8>);
typedef _RequestNative = ffi.Void Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.NativeFunction<_CallbackNative>>,
  ffi.UintPtr,
);
typedef _RequestDart = void Function(
  ffi.Pointer<Utf8>,
  ffi.Pointer<ffi.NativeFunction<_CallbackNative>>,
  int,
);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _FreeDart = void Function(ffi.Pointer<Utf8>);
typedef _RegisterNative = ffi.Void Function(
  ffi.Pointer<ffi.NativeFunction<_CallbackNative>>,
);
typedef _RegisterDart = void Function(
  ffi.Pointer<ffi.NativeFunction<_CallbackNative>>,
);

class _Pending {
  _Pending(this.completer, this.onProgress);
  final Completer<dynamic> completer;
  final void Function(CardProgress)? onProgress;
}

class RealCardGateway extends CardGateway {
  RealCardGateway._(ffi.DynamicLibrary lib)
    : _request = lib.lookupFunction<_RequestNative, _RequestDart>(
        'card_bridge_request',
      ),
      _free = lib.lookupFunction<_FreeNative, _FreeDart>(
        'card_bridge_free_string',
      ),
      _register = lib.lookupFunction<_RegisterNative, _RegisterDart>(
        'card_bridge_set_event_callback',
      ) {
    _listener = ffi.NativeCallable<_CallbackNative>.listener(_onEvent);
    _listener.keepIsolateAlive = false;
    _register(_listener.nativeFunction);
  }
  static RealCardGateway? _instance;

  /// Null means not linked, NOT permission granted/connected/hardware verified.
  static RealCardGateway? maybe() {
    if (_instance != null) return _instance;
    final candidates = <ffi.DynamicLibrary>[];
    try {
      candidates.add(ffi.DynamicLibrary.process());
    } catch (_) {
      /* try dynamic library */
    }
    try {
      candidates.add(
        ffi.DynamicLibrary.open(
          Platform.isAndroid || Platform.isLinux
              ? 'libcard_bridge.so'
              : Platform.isWindows
              ? 'card_bridge.dll'
              : 'libcard_bridge.dylib',
        ),
      );
    } catch (_) {
      /* no native bridge */
    }
    for (final lib in candidates) {
      try {
        return _instance = RealCardGateway._(lib);
      } catch (_) {
        /* missing symbols */
      }
    }
    return null;
  }

  /// Explicit library injection for host FFI ownership/contract tests.
  static RealCardGateway forLibrary(ffi.DynamicLibrary library) =>
      RealCardGateway._(library);
  static const _platform = MethodChannel('recording_card/card_native');
  final _RequestDart _request;
  final _FreeDart _free;
  final _RegisterDart _register;
  late final ffi.NativeCallable<_CallbackNative> _listener;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final Map<int, _Pending> _pending = {};
  int _ticket = 0;
  bool _androidInitialized = false;
  @override
  bool get available => true;
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<dynamic> _call(
    String operation, [
    Map<String, dynamic> arguments = const {},
    Duration timeout = const Duration(seconds: 90),
    void Function(CardProgress)? onProgress,
  ]) async {
    if (Platform.isAndroid &&
        !_androidInitialized &&
        operation != 'convertAudio') {
      try {
        await _platform.invokeMethod<void>('initialize');
        _androidInitialized = true;
      } on PlatformException {
        throw const CardGatewayException('platform', 'Android蓝牙桥初始化或权限请求失败');
      }
    }
    final ticket = ++_ticket;
    final completer = Completer<dynamic>();
    _pending[ticket] = _Pending(completer, onProgress);
    final input = jsonEncode({'op': operation, ...arguments}).toNativeUtf8();
    try {
      _request(input, _listener.nativeFunction, ticket);
    } catch (e) {
      _pending.remove(ticket);
      rethrow;
    } finally {
      malloc.free(input);
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(ticket);
        throw CardGatewayException('timeout', '$operation响应超时；请等待设备任务停止后重连');
      },
    );
  }

  void _onEvent(int ticket, ffi.Pointer<Utf8> ptr) {
    // Always consume/free even if the ticket timed out or wasn't registered.
    // NativeCallable.listener is asynchronous: Rust retains memory until here.
    try {
      final envelope = _map(jsonDecode(ptr.toDartString()));
      final event = envelope['event'];
      if (event != null) {
        final data = _map(event);
        _events.add(data);
        if (data['kind'] == 'progress') {
          try {
            _pending[ticket]?.onProgress?.call(
              CardProgress(
                data['stage'] as String,
                done: (data['done'] as num?)?.toInt(),
                total: (data['total'] as num?)?.toInt(),
              ),
            );
          } catch (_) {
            /* A UI observer cannot change native task outcome. */
          }
        }
        return;
      }
      final pending = _pending.remove(ticket);
      if (pending == null || pending.completer.isCompleted) return;
      if (envelope['ok'] == true) {
        pending.completer.complete(envelope['data']);
      } else {
        pending.completer.completeError(
          CardGatewayException(
            envelope['code'] as String? ?? 'native',
            envelope['error'] as String? ?? '设备操作失败',
          ),
        );
      }
    } catch (e, st) {
      final pending = _pending.remove(ticket);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(
          const CardGatewayException('protocol', '设备桥响应格式无效'),
          st,
        );
      }
      // Progress callbacks must not throw across the native boundary.
    } finally {
      _free(ptr);
    }
  }

  // Process-lifetime singleton listener: intentionally never close while Rust
  // might deliver late callbacks. keepIsolateAlive=false lets the app exit.
  // Disconnect aborts native event pumps; recreating listeners per request is unsafe.
  @override
  Future<List<CardDevice>> scan({int timeoutMs = 3000}) async =>
      (await _call('scan', {'timeoutMs': timeoutMs}) as List)
          .map((j) => CardDevice.fromJson(_map(j)))
          .toList();
  @override
  Future<CardSnapshot> connect(String id) async =>
      CardSnapshot.fromJson(_map(await _call('connect', {'id': id})));
  @override
  Future<void> disconnect() async {
    await _call('disconnect');
  }

  @override
  Future<CardSnapshot> status() async =>
      CardSnapshot.fromJson(_map(await _call('status')));
  @override
  Future<List<CardFile>> listFiles({String? folder}) async =>
      (await _call('listFiles', {'folder': folder}) as List)
          .map((j) => CardFile.fromJson(_map(j)))
          .toList();
  @override
  Future<CardDownload> downloadFile(
    String name, {
    required String directory,
    int? expectedBytes,
    CardTransfer transport = CardTransfer.ap,
    bool allowDestructive = false,
    void Function(CardProgress)? onProgress,
  }) async {
    if (transport == CardTransfer.ble && !allowDestructive) {
      throw const CardGatewayException(
        'destructive',
        'BLE take成功会删除设备源文件；请明确授权allowDestructive或加入卡热点使用AP下载',
      );
    }
    return CardDownload.fromJson(
      _map(
        await _call(
          'downloadFile',
          {
            'name': name,
            'directory': directory,
            'expectedBytes': expectedBytes,
            'transport': transport.name,
            'allowDestructive': allowDestructive,
          },
          const Duration(seconds: 330),
          onProgress,
        ),
      ),
    );
  }

  @override
  Future<String> convertAudio(
    String source, {
    required String destination,
    String format = 'apm',
  }) async => _requiredString(
    _map(
      await _call('convertAudio', {
        'source': source,
        'destination': destination,
        'format': format,
      }, const Duration(seconds: 150)),
    ),
    'path',
  );
  @override
  Future<void> setWifiEnabled(bool enabled) async {
    await _call('setWifiEnabled', {'enabled': enabled});
  }

  @override
  Future<CardAudioTask> startAudioCapture({
    required String taskId,
    required String directory,
    int chunkSeconds = 30,
    bool startRecordingIfIdle = false,
  }) async => CardAudioTask.fromJson(
    _map(
      await _call('startAudioCapture', {
        'taskId': taskId,
        'directory': directory,
        'chunkSeconds': chunkSeconds,
        'startRecordingIfIdle': startRecordingIfIdle,
      }),
    ),
  );
  @override
  Future<Map<String, dynamic>> stopAudioCapture(
    String taskId, {
    bool stopOwnedRecording = false,
  }) async => _map(
    await _call('stopAudioCapture', {
      'taskId': taskId,
      'stopOwnedRecording': stopOwnedRecording,
    }),
  );
  @override
  Future<Map<String, dynamic>> audioCaptureStatus() async =>
      _map(await _call('audioCaptureStatus'));

  @override
  Future<Map<String, dynamic>> wifiStatus() async =>
      _map(await _call('wifiStatus'));
  @override
  Future<Map<String, dynamic>> wifiOtaStatus() async =>
      _map(await _call('wifiOtaStatus'));
  @override
  Future<Map<String, dynamic>> apOtaStatus() async =>
      _map(await _call('apOtaStatus'));
  @override
  Future<List<CardWifiNetwork>> scanWifi() async =>
      (await _call('scanWifi') as List)
          .map((j) => CardWifiNetwork.fromJson(_map(j)))
          .toList();
  @override
  Future<Map<String, dynamic>> connectWifi(
    String ssid,
    String password,
  ) async =>
      _map(await _call('connectWifi', {'ssid': ssid, 'password': password}));
  @override
  Future<void> disconnectWifi() async {
    await _call('disconnectWifi');
  }

  @override
  Future<List<CardWifiCredential>> listWifiCredentials() async =>
      (await _call('listWifiCredentials') as List).map((j) {
        final m = _map(j);
        return CardWifiCredential(
          _requiredString(m, 'ssid'),
          lastUsed: (m['lastUsed'] as num?)?.toInt(),
        );
      }).toList();
  @override
  Future<void> deleteWifiCredential(String ssid) async {
    await _call('deleteWifiCredential', {'ssid': ssid});
  }

  @override
  Future<Map<String, dynamic>> setRecording(bool enabled) async =>
      _map(await _call('setRecording', {'enabled': enabled}));
  @override
  Future<void> setRealtimeEnabled(bool enabled) async {
    await _call('setRealtimeEnabled', {'enabled': enabled});
  }

  @override
  Future<Map<String, dynamic>> recordMark() async =>
      _map(await _call('recordMark'));
  @override
  Future<Map<String, dynamic>> controlBindings() async =>
      _map(await _call('controlBindings'));
  @override
  Future<void> setMarkEnabled(
    bool enabled, {
    String input = 'btn_single',
    required String expectedAction,
    required bool userConfirmed,
  }) async {
    if (!userConfirmed) {
      throw const CardGatewayException('confirmation', '改变mark硬件输入绑定需要用户确认');
    }
    await _call('setMarkEnabled', {
      'enabled': enabled,
      'input': input,
      'expectedAction': expectedAction,
      'userConfirmed': userConfirmed,
    });
  }

  @override
  Future<List<Map<String, dynamic>>> checkFirmware({
    required String apiBaseUrl,
    required List<String> allowedHosts,
  }) async => (await _call('checkFirmware', {
    'apiBaseUrl': apiBaseUrl,
    'allowedHosts': allowedHosts,
  }) as List).map(_map).toList();
  @override
  Future<Map<String, dynamic>> checkWifiOta({
    required String apiBaseUrl,
    required List<String> allowedHosts,
  }) async => _map(
    await _call('checkWifiOta', {
      'apiBaseUrl': apiBaseUrl,
      'allowedHosts': allowedHosts,
    }),
  );
  @override
  Future<Map<String, dynamic>> updateFirmware(
    CardFirmwarePlan plan, {
    required bool userConfirmed,
    void Function(CardProgress)? onProgress,
  }) async {
    if (!userConfirmed) {
      throw const CardGatewayException('confirmation', '固件更新需要确认设备、版本和精确固件包');
    }
    return _map(
      await _call(
        'firmwareUpdate',
        {...plan.toJson(), 'userConfirmed': true},
        const Duration(seconds: 630),
        onProgress,
      ),
    );
  }

  @override
  Future<void> openWifiSettings() async {
    if (!Platform.isAndroid) {
      throw const CardGatewayException(
        'platform',
        '请在iOS系统设置中手动加入录音卡热点；应用不会自动切换网络',
      );
    }
    await _platform.invokeMethod<void>('openWifiSettings');
  }
}

Map<String, dynamic> _map(dynamic value) {
  if (value is! Map) {
    throw const CardGatewayException('protocol', '设备返回的数据不是对象');
  }
  return Map<String, dynamic>.from(value);
}

String _requiredString(Map<String, dynamic> j, String key) {
  final value = j[key];
  if (value is! String || value.isEmpty) {
    throw CardGatewayException('protocol', '设备响应缺少$key');
  }
  return value;
}
