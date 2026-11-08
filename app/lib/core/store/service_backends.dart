/// Verified integration adapters for C Recording/SettingsRepository,
/// C SyncCoordinator, D AnalysisService and B CardGateway. Object injection
/// keeps the E worktree compilable before the other commits are integrated.
library;

import 'dart:async';
import '../device/card_gateway.dart';
import '../models/record.dart';
import '../models/summary.dart';
import 'app_backend.dart';
import 'device_backend.dart';

class ServiceAppBackend implements AppBackend, CancelableAppBackend {
  ServiceAppBackend({
    required Object recordingRepository,
    required Object settingsRepository,
    required Object analysisService,
    this.applyRuntimePolicy,
    this.cancellationFactory,
  }) : _recordings = recordingRepository,
       _settings = settingsRepository,
       _analysis = analysisService;
  final dynamic _recordings, _settings, _analysis;

  /// Apply continuous recording via B and configure C/D task dispatch here.
  /// Never call setMarkEnabled: markImportant controls local mark policy only.
  final Future<void> Function(RecordingPolicy)? applyRuntimePolicy;

  /// Pass D CancellationToken.new; cancellation is cooperative, not a guarantee
  /// that a model HTTP request already sent stops billing on the server.
  final Object Function()? cancellationFactory;
  final Map<String, dynamic> _tokens = {};
  @override
  Future<List<RecordEvent>> loadEvents() async {
    final state = await _recordings.load();
    return (state.events as List).cast<RecordEvent>();
  }

  @override
  Future<void> applyPolicy(RecordingPolicy policy) async {
    if (applyRuntimePolicy == null) throw StateError('录音与转录任务策略执行器未配置');
    final state = await _settings.load();
    final next = state.settings.copyWith(
      continuousRecording: policy.continuousRecording,
      markImportant: policy.markImportant,
      autoTranscribe: policy.autoTranscribe,
      autoClean: policy.autoClean,
      inferSpeakers: policy.inferSpeakers,
      wifiOnlySync: policy.wifiOnlySync,
    );
    await applyRuntimePolicy!(policy);
    await _settings.save(next);
  }

  @override
  Future<SummaryCard> generateSummary(
    List<RecordEvent> events, {
    required SummaryCard target,
    required RecordingPolicy policy,
    required ProgressSink onProgress,
  }) async {
    final token = cancellationFactory?.call();
    if (token != null) _tokens[target.id] = token;
    void emit() {
      final data = target.toJson();
      final stage = data['stage'] as String?;
      const names = {
        'queued': '等待分析任务…',
        'preparing': '解析所选来源…',
        'generating': '模型正在生成…',
        'validating': '校验来源与结构…',
        'completed': '已完成',
        'failed': '生成失败',
        'cancelled': '已取消',
      };
      onProgress(
        TaskProgress(
          names[stage] ?? '分析服务处理中…',
          percent: stage == 'completed' ? 100 : null,
        ),
      );
    }

    emit();
    final timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => emit(),
    );
    try {
      final SummaryCard result = token == null
          ? await _analysis.generateSummary(events, target: target)
                as SummaryCard
          : await _analysis.generateSummary(
                  events,
                  target: target,
                  cancellation: token,
                )
                as SummaryCard;
      // Repository.update merges concurrent source/task mutations rather than
      // overwriting C's entire state with stale UI snapshots.
      await _recordings.update(
        (dynamic state) => state.copyWith(
          summaries: <SummaryCard>[
            ...(state.summaries as List).cast<SummaryCard>().where(
              (s) => s.id != result.id,
            ),
            result,
          ],
        ),
      );
      emit();
      return result;
    } finally {
      timer.cancel();
      _tokens.remove(target.id);
    }
  }

  @override
  Future<void> cancelSummary(String id) async {
    final token = _tokens[id];
    if (token == null) throw StateError('当前总结服务不支持取消已提交的请求');
    token.cancel();
  }
}

/// Firmware provider must bind exact B plans to the offered package. The UI
/// adapter does NOT choose the first discovered bootloader or fabricate a plan.
class FirmwareRelease {
  const FirmwareRelease({required this.offer, required this.install});
  final FirmwareOffer offer;
  final Future<void> Function(FirmwareConsent, ProgressSink) install;
}

class ServiceDeviceBackend implements DeviceBackend {
  ServiceDeviceBackend({
    required Object gateway,
    required Object settingsRepository,
    Object? syncCoordinator,
    this.firmwareProvider,
    this.recordedSeconds,
  }) : _gateway = gateway,
       _settings = settingsRepository,
       _sync = syncCoordinator;
  final dynamic _gateway, _settings, _sync;
  final Future<FirmwareRelease?> Function()? firmwareProvider;

  /// Bind only a verified recording duration/sample clock. Null => unknown.
  final int? Function(CardSnapshot)? recordedSeconds;
  String? _transportId;
  FirmwareRelease? _release;
  @override
  bool get available => _gateway.available as bool;
  @override
  Future<List<DeviceChoice>> scan() async {
    final devices = await _gateway.scan() as List;
    return [
      for (final d in devices)
        d is String
            ? DeviceChoice(d, d)
            : DeviceChoice(d.id as String, d.name as String),
    ];
  }

  DeviceReading _reading(CardSnapshot snapshot) {
    String? identity, wifi;
    try {
      identity = (snapshot as dynamic).deviceId as String?;
    } on NoSuchMethodError {
      /* old isolated model */
    }
    try {
      if ((snapshot as dynamic).wifiConnected == true) {
        wifi = (snapshot as dynamic).wifiSsid as String?;
      }
    } on NoSuchMethodError {
      /* unknown Wi-Fi state remains unknown */
    }
    return DeviceReading(
      snapshot,
      id: _transportId,
      targetId: identity,
      recordedSeconds: recordedSeconds?.call(snapshot),
      connectedWifi: wifi,
    );
  }

  @override
  Future<DeviceReading> connect(String id) async {
    final snapshot = await _gateway.connect(id) as CardSnapshot;
    _transportId = id;
    return _reading(snapshot);
  }

  @override
  Future<DeviceReading> status() async =>
      _reading(await _gateway.status() as CardSnapshot);
  @override
  Future<void> disconnect() async {
    await _gateway.disconnect();
    _transportId = null;
  }

  @override
  Future<void> sync(RecordingPolicy policy, ProgressSink onProgress) async {
    if (_sync == null) throw StateError('同步上传服务未配置');
    if (_transportId == null) throw StateError('未连接录音卡');
    final state = await _settings.load();
    final next = state.settings.copyWith(wifiOnlySync: policy.wifiOnlySync);
    await _settings.save(next);
    final subscription = (_sync.changes as Stream).listen((dynamic task) {
      onProgress(
        TaskProgress(
          '同步 · ${task.stage}',
          percent: task.progress == null
              ? null
              : (task.progress as num).toDouble() * 100,
        ),
      );
    });
    try {
      final snapshot = await status();
      final id = snapshot.targetId;
      if (id == null || id.isEmpty) throw StateError('设备未返回可验证身份');
      await _sync.syncAndUpload(id);
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<List<SavedWifi>> savedWifi() async {
    final state = await _settings.load();
    return [
      for (final network in state.networks as List)
        SavedWifi(network.ssid as String),
    ];
  }

  @override
  Future<List<WifiNet>> scanWifi() async {
    await _gateway.setWifiEnabled(true);
    final networks = await _gateway.scanWifi() as List;
    return [
      for (final net in networks)
        WifiNet(
          net.ssid as String,
          ((net.rssi as int?) ?? -100) > -60
              ? 3
              : ((net.rssi as int?) ?? -100) > -80
              ? 2
              : 1,
          lock:
              (net.encryption as String?)?.toLowerCase() != 'open' &&
              (net.encryption as String?)?.toLowerCase() != 'none',
        ),
    ];
  }

  @override
  Future<void> connectSavedWifi(String name) async {
    final state = await _settings.load();
    final network = (state.networks as List)
        .where((dynamic n) => n.ssid == name)
        .firstOrNull;
    if (network == null) throw StateError('网络未保存，请重新输入密码');
    final credential = await _settings.readWifiCredential(network.id);
    await _gateway.connectWifi(credential.ssid, credential.password);
  }

  @override
  Future<void> joinWifi(String name, String password) async {
    await _gateway.connectWifi(name, password);
    final snapshot = await status();
    if (snapshot.connectedWifi != name) throw StateError('设备尚未确认连接到该网络');
    await _settings.saveWifiNetwork(ssid: name, password: password);
  }

  @override
  Future<FirmwareOffer?> firmwareOffer() async {
    if (firmwareProvider == null) throw StateError('可信固件清单与精确包配置未提供');
    _release = await firmwareProvider!();
    return _release?.offer;
  }

  @override
  Future<void> updateFirmware(
    FirmwareOffer offer,
    FirmwareConsent consent,
    ProgressSink onProgress,
  ) async {
    final release = _release;
    if (release == null ||
        release.offer.packageId != offer.packageId ||
        release.offer.checksum != consent.checksum ||
        release.offer.deviceId != consent.deviceId ||
        release.offer.packageId != consent.packageId) {
      throw StateError('固件包或目标授权已变化，请重新检查并确认');
    }
    await release.install(consent, onProgress);
  }
}
