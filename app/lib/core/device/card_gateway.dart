/// 录音卡硬件网关接缝 —— 经 card_bridge（Rust FFI）接 reai-card-sdk 蓝牙真实数据。
///
/// 分层：
/// - [RealCardGateway]  桥符号可用时（staticlib 已链接 / 桌面 dylib 在侧）走真实 BLE。
/// - [MockCardGateway]  桥不可用（未链接、无适配器、无硬件）时的进程内回退，
///   保证无硬件也能完整体验；诚实边界只写在文档层，不出现在界面。
///
/// SDK 能力对照见 docs/SDK-CAPABILITY.md；桥实现见 app/rust/card_bridge。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// 设备快照（battery/state/device_info 的 Dart 投影）
class CardSnapshot {
  const CardSnapshot({
    required this.batteryLevel,
    required this.isCharging,
    required this.wifiOpen,
    required this.recording,
    required this.fwVersion,
    required this.wifiVersion,
  });

  factory CardSnapshot.fromJson(Map<String, dynamic> json) {
    final battery = (json['battery'] ?? const {}) as Map<String, dynamic>;
    final state = (json['state'] ?? const {}) as Map<String, dynamic>;
    final info = (json['info'] ?? const {}) as Map<String, dynamic>;
    return CardSnapshot(
      batteryLevel: (battery['level'] as num?)?.toInt() ?? 0,
      isCharging: battery['isCharging'] as bool? ?? false,
      wifiOpen: state['wifiOpen'] as bool? ?? false,
      recording: state['recordRealtimeEnabled'] as bool? ?? false,
      fwVersion: info['version'] as String? ?? '',
      wifiVersion: info['wifiVersion'] as String? ?? '',
    );
  }

  final int batteryLevel;
  final bool isCharging;
  final bool wifiOpen;
  final bool recording;
  final String fwVersion;
  final String wifiVersion;
}

abstract class CardGateway {
  /// 当前已连接设备的状态快照；不可用/未连接返回 null（调用方回退预置数据）。
  Future<CardSnapshot?> status();

  /// 扫描可连接设备（NUS）；默认无桥实现返回空列表。
  Future<List<String>> scan({int timeoutMs = 3000}) async => const [];

  /// 连接指定设备并返回快照；默认无桥实现返回 null。
  Future<CardSnapshot?> connect(String deviceId) async => null;

  /// 真实网关是否就绪（桥符号可解析）。
  bool get available => true;
}

/// 无桥回退：永远返回 null，DeviceStore 保持预置数据。
class MockCardGateway implements CardGateway {
  const MockCardGateway();

  @override
  Future<CardSnapshot?> status() async => null;

  @override
  Future<List<String>> scan({int timeoutMs = 3000}) async => const [];

  @override
  Future<CardSnapshot?> connect(String deviceId) async => null;

  @override
  bool get available => false;
}

// ── C ABI 镜像（app/rust/card_bridge/src/lib.rs）─────────────────────

// Native 侧签名（NativeCallable 与 asFunction 共用；Dart 调用形态见 _ScanDart 等）
typedef _CbNative = ffi.Void Function(ffi.UintPtr, ffi.Pointer<Utf8>);
typedef _ScanNative =
    ffi.Void Function(
      ffi.Uint32,
      ffi.Pointer<ffi.NativeFunction<_CbNative>>,
      ffi.UintPtr,
    );
typedef _ConnectNative =
    ffi.Void Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.NativeFunction<_CbNative>>,
      ffi.UintPtr,
    );
typedef _StatusNative =
    ffi.Void Function(ffi.Pointer<ffi.NativeFunction<_CbNative>>, ffi.UintPtr);

// Dart 侧签名（asFunction 显式标注）
typedef _ScanDart =
    void Function(int, ffi.Pointer<ffi.NativeFunction<_CbNative>>, int);
typedef _ConnectDart =
    void Function(
      ffi.Pointer<Utf8>,
      ffi.Pointer<ffi.NativeFunction<_CbNative>>,
      int,
    );
typedef _StatusDart =
    void Function(ffi.Pointer<ffi.NativeFunction<_CbNative>>, int);

/// FFI 真实网关：绑定 card_bridge 的 C ABI。
///
/// 回调经 [ffi.NativeCallable.listener] 跨线程投递（Rust worker 线程 → Dart）；
/// 以自增 ticket 为 user_data 分派等待中的 Completer。
class RealCardGateway implements CardGateway {
  RealCardGateway._(ffi.DynamicLibrary lib)
    : _scanFn = lib
          .lookup<ffi.NativeFunction<_ScanNative>>('card_bridge_scan')
          .asFunction(),
      _connectFn = lib
          .lookup<ffi.NativeFunction<_ConnectNative>>('card_bridge_connect')
          .asFunction(),
      _statusFn = lib
          .lookup<ffi.NativeFunction<_StatusNative>>('card_bridge_status')
          .asFunction() {
    _callable = ffi.NativeCallable<_CbNative>.listener(_onEvent);
    _available = true;
  }

  static RealCardGateway? _instance;

  /// 桥符号存在则返回实例，否则 null（调用方回退 Mock）。
  static RealCardGateway? maybe() {
    if (_instance != null) return _instance;
    ffi.DynamicLibrary lib;
    try {
      lib = ffi.DynamicLibrary.process(); // staticlib 链入 App（iOS/桌面 release）
    } catch (_) {
      try {
        lib = ffi.DynamicLibrary.open('libcard_bridge.dylib'); // 桌面开发
      } catch (_) {
        return null; // 桥未链接：走 Mock 回退
      }
    }
    try {
      _instance = RealCardGateway._(lib);
      return _instance;
    } catch (_) {
      return null;
    }
  }

  final _ScanDart _scanFn;
  final _ConnectDart _connectFn;
  final _StatusDart _statusFn;
  late final ffi.NativeCallable<_CbNative> _callable;

  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _ticket = 0;

  bool _available = false;
  @override
  bool get available => _available;

  @override
  Future<CardSnapshot?> status() {
    return _request((cb, ud) => _statusFn(cb, ud));
  }

  /// 扫描并连接指定设备（scan→find→connect→快照）；成功后 status() 可用。
  @override
  Future<CardSnapshot?> connect(String deviceId) {
    final ptr = deviceId.toNativeUtf8();
    try {
      return _request((cb, ud) => _connectFn(ptr, cb, ud));
    } finally {
      malloc.free(ptr);
    }
  }

  /// 扫描 NUS 设备，返回可连接的设备 id 列表。
  @override
  Future<List<String>> scan({int timeoutMs = 3000}) async {
    final json = await _call((cb, ud) => _scanFn(timeoutMs, cb, ud));
    if (json['ok'] != true) return const [];
    return (json['data'] as List<dynamic>? ?? const [])
        .map((d) => (d as Map<String, dynamic>)['id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  Future<CardSnapshot?> _request(
    void Function(ffi.Pointer<ffi.NativeFunction<_CbNative>>, int) invoke,
  ) async {
    final json = await _call(invoke);
    if (json['ok'] != true) return null; // 未连接/超时/无适配器 → 调用方回退
    return CardSnapshot.fromJson(
      (json['data'] ?? const {}) as Map<String, dynamic>,
    );
  }

  Future<Map<String, dynamic>> _call(
    void Function(ffi.Pointer<ffi.NativeFunction<_CbNative>>, int) invoke,
  ) {
    final ticket = ++_ticket;
    final completer = _pending[ticket] = Completer<Map<String, dynamic>>();
    invoke(_callable.nativeFunction, ticket);
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pending.remove(ticket);
        return const {'ok': false, 'error': 'timeout'};
      },
    );
  }

  void _onEvent(int ticket, ffi.Pointer<Utf8> json) {
    final completer = _pending.remove(ticket);
    if (completer == null || completer.isCompleted) return;
    try {
      completer.complete(
        jsonDecode(json.toDartString()) as Map<String, dynamic>,
      );
    } catch (_) {
      completer.complete(const {'ok': false, 'error': 'bad json'});
    }
  }
}
