import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/device/card_gateway.dart';
import '../../core/models/record.dart';
import '../../core/models/summary.dart';
import '../../core/store/app_backend.dart';
import '../../core/store/app_store.dart';
import '../../core/store/device_store.dart';
import '../../core/store/service_backends.dart';
import '../../core/store/store_persistence.dart';
import '../auth_service.dart';
import '../model_gateway/model_gateway.dart';
import '../analysis/analysis_service.dart';
import '../analysis/stage_summary_service.dart';
import '../recordings/recording_repository.dart';
import '../recordings/sync_coordinator.dart';
import '../settings/settings_repository.dart';
import '../transcription/transcription_service.dart';
import '../transcription/bundled_vad_model.dart';
import 'card_download_adapter.dart';
import 'recording_pipeline.dart';
import 'runtime_config.dart';
import 'firmware_provider.dart';
import 'accessory_hotspot_session.dart';

class ProductionRuntime {
  ProductionRuntime._(
    this.auth,
    this.store,
    this.device,
    this.pipeline,
    this.sync,
    this.fastSync,
    this.gateway,
    this.backend,
    this.uploader,
  ) {
    auth.addListener(_authChanged);
  }
  final AuthService auth;
  final AppStore store;
  final DeviceStore device;
  final RecordingPipeline pipeline;
  final SyncCoordinator sync;
  final SyncCoordinator fastSync;
  final CardGateway gateway;
  final RuntimeAppBackend backend;
  final HttpRecordingUploader? uploader;
  bool _signedIn = false;
  bool _disposed = false;
  Future<void> _lifecycle = Future.value();

  void _authChanged() {
    final next = auth.isSignedIn;
    if (_signedIn && !next) {
      _lifecycle = _lifecycle.then((_) => suspend()).catchError((
        Object e,
      ) async {
        await pipeline.reportError('auth-lifecycle', e);
      });
    }
    _signedIn = next;
  }

  Future<void> suspend() async {
    try {
      await Future.wait([
        backend.cancelAllAndDrain(),
        sync.cancel(),
        fastSync.cancel(),
        pipeline.suspend(),
      ]);
      await Future.wait([sync.drained, fastSync.drained]);
    } finally {
      // DeviceBackend finally guarantees native disconnect even if flush fails.
      await device.disconnect();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    auth.removeListener(_authChanged);
    try {
      await _lifecycle;
      await suspend();
    } finally {
      try {
        await pipeline.dispose();
      } finally {
        await sync.drained;
        await fastSync.drained;
        await sync.dispose();
        await fastSync.dispose();
        uploader?.dispose();
        store.dispose();
        device.dispose();
        auth.dispose();
      }
    }
  }

  static Future<ProductionRuntime> create() async {
    final support = await getApplicationSupportDirectory();
    final recordings = RecordingRepository(
      directory: Directory('${support.path}/recording_card/v1'),
    );
    final settings = SettingsRepository(
      directory: Directory('${support.path}/recording_card/settings'),
    );
    final auth = AuthService();
    final gateway = RealCardGateway.maybe() ?? const UnavailableCardGateway();
    late final RecordingPipeline pipeline;
    late final LocalOnlyAnalysisGateway modelGateway;
    final hotspot = AccessoryHotspotSession(
      gateway,
      networkProbe: AccessoryHotspotSession.probeNativeNetwork,
      sdkFileProbe: gateway.probeAccessPointFiles,
      beforeWifiOpen: () async {
        // Do not cancel existing text/ASR jobs. The active session blocks new
        // cloud calls while already-started work drains before switching Wi-Fi.
        await pipeline.drained;
        await modelGateway.drained;
      },
    );
    modelGateway = LocalOnlyAnalysisGateway(
      AuthorizedAnalysisGateway(
        ModelGateway(auth: auth),
        sessionEpoch: () => auth.authorizedClient.tokenStore.userIdentityEpoch,
      ),
      localOnly: () => hotspot.active,
    );
    final analysis = AnalysisService(
      gateway: modelGateway,
      rebuildCleanEvent:
          (
            source, {
            required brief,
            required longText,
            required speakers,
            required dialog,
          }) => source.copyWith(
            brief: brief,
            longText: longText,
            speakers: speakers,
            dialog: dialog,
            cleanedTranscript: longText,
          ),
    );
    final modelDirectory = Directory('${support.path}/recording_card/models');
    if (RuntimeConfig.vadUrl.isEmpty &&
        RuntimeConfig.vadSha256.isEmpty &&
        RuntimeConfig.vadSize == 0) {
      await BundledVadModel.ensureReady(modelDirectory);
    }
    final asr = TranscriptionService(
      models: const RuntimeConfig().models(modelDirectory),
    );
    pipeline = RecordingPipeline(
      gateway: gateway,
      repository: recordings,
      asr: asr,
      analysis: analysis,
      analysisGateway: modelGateway,
    );
    final uploader =
        RuntimeConfig.uploadContractApproved &&
            RuntimeConfig.uploadBearerApproved
        ? HttpRecordingUploader(
            endpoint: RuntimeConfig.uploadUrl.isEmpty
                ? null
                : Uri.parse(RuntimeConfig.uploadUrl),
            // Bearer may only be sent to both explicit upload and OAuth trusted hosts.
            allowedHosts: RuntimeConfig.hosts(RuntimeConfig.uploadHosts)
                .intersection(auth.config.trustedHosts.toSet()),
            authorizationHeaders: () async {
              final token = await auth.authorizedClient.tokenStore
                  .getValidAccessToken();
              if (!auth.isSignedIn || token == null) {
                throw const AuthRequiredException();
              }
              return {'Authorization': 'Bearer $token'};
            },
          )
        : null;
    final sync = SyncCoordinator(
      repository: recordings,
      settingsRepository: settings,
      gateway: CardDownloadAdapter(
        gateway,
        cancelTransfer: gateway.cancelFileTransfer,
      ),
      uploader: uploader,
      onImported: (_) async {
        await pipeline.publish();
        if (pipeline.policy.autoTranscribe) await pipeline.processPending();
      },
    );
    final fastDownload = CardDownloadAdapter(
      gateway,
      transport: CardTransfer.ap,
      hotspotSession: hotspot,
      cancelTransfer: gateway.cancelFileTransfer,
    );
    final fastSync = SyncCoordinator(
      repository: recordings,
      settingsRepository: settings,
      gateway: fastDownload,
      onImported: (_) async {
        await pipeline.publish();
        if (pipeline.policy.autoTranscribe) {
          await pipeline.processPending(localOnly: true);
        }
      },
    );
    final backend = RuntimeAppBackend(
      recordingRepository: recordings,
      settingsRepository: settings,
      analysisService: analysis,
      pipeline: pipeline,
      localOnly: () => hotspot.active,
    );
    final store = AppStore(
      backend: backend,
      persistence: RepositoryUiPersistence(recordings),
      recordUpdates: pipeline.changes,
      retryRecordProcessing: () =>
          pipeline.processPending(localOnly: hotspot.active),
    );
    final stored = await settings.load();
    store.policy = RecordingPolicy.fromJson(stored.settings.toJson());
    pipeline.policy = store.policy;
    final firmware = FirmwareProvider(gateway);
    final serviceDevice = ServiceDeviceBackend(
      gateway: gateway,
      settingsRepository: settings,
      syncCoordinator: sync,
      fastSyncCoordinator: fastSync,
      firmwareProvider: firmware.offer,
      hotspotSession: hotspot,
    );
    final deviceBackend = RuntimeDeviceBackend(
      serviceDevice,
      pipeline,
      gateway,
    );
    final device = DeviceStore(
      backend: deviceBackend,
      policy: () => store.policy,
      firmwareStatusMessage: () => firmware.lastCheck?.message,
      fastTransferActive: () => hotspot.active,
      onSynced: () async {
        await store.reloadEvents();
        if (store.policy.autoTranscribe) {
          unawaited(
            pipeline
                .processPending(localOnly: fastDownload.wifiSessionActive)
                .catchError(
                  (Object e) => pipeline.reportError('sync-processing', e),
                ),
          );
        }
      },
    );
    await pipeline.recoverCaptureFiles(); // no device or model request
    return ProductionRuntime._(
      auth,
      store,
      device,
      pipeline,
      sync,
      fastSync,
      gateway,
      backend,
      uploader,
    );
  }
}

/// Covers queued legacy pipeline work as well as manual summaries. Checking at
/// the call boundary prevents stale localOnly arguments from issuing cloud work.
/// Already-submitted requests finish naturally before the card AP is powered.
class LocalOnlyAnalysisGateway implements AnalysisGateway {
  LocalOnlyAnalysisGateway(this.delegate, {required this.localOnly});
  final AnalysisGateway delegate;
  final bool Function() localOnly;
  final Set<Future<String>> _pending = {};

  Future<void> get drained => Future.wait(
    _pending.map(
      (request) =>
          request.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ),
  ).then((_) {});

  @override
  Future<String> complete(String prompt, {String? model}) {
    if (localOnly()) {
      return Future.error(
        const AnalysisException(
          'local_only',
          '快传期间保留原文，等待联网后润色或分析',
          retryable: true,
        ),
      );
    }
    final request = delegate.complete(prompt, model: model);
    _pending.add(request);
    return request.whenComplete(() {
      _pending.remove(request);
    });
  }
}

/// Repository is the authoritative UI state as well as the recording store.
/// This avoids two incompatible snapshot codecs and preserves C/D metadata.
class RepositoryUiPersistence implements StorePersistence {
  RepositoryUiPersistence(this.repository);
  final RecordingRepository repository;
  @override
  Future<Map<String, dynamic>?> load() async {
    final state = await repository.load();
    return (state.metadata['ui'] as Map?)?.cast<String, dynamic>();
  }

  @override
  Future<void> save(Map<String, dynamic> state) async {
    await repository.update(
      (current) =>
          current.copyWith(metadata: {...current.metadata, 'ui': state}),
    );
  }
}

class RuntimeAppBackend extends ServiceAppBackend {
  RuntimeAppBackend({
    required super.recordingRepository,
    required super.settingsRepository,
    required super.analysisService,
    required this.pipeline,
    this.localOnly,
  }) : _analysis = analysisService,
       _repository = recordingRepository,
       super(
         applyRuntimePolicy: pipeline.apply,
         cancellationFactory: CancellationToken.new,
       );
  final RecordingPipeline pipeline;
  final AnalysisService _analysis;
  final bool Function()? localOnly;
  final RecordingRepository _repository;
  final Map<String, CancellationToken> _cancellations = {};
  final Map<String, Completer<void>> _drains = {};
  @override
  Future<void> applyPolicy(RecordingPolicy policy) async {
    await super.applyPolicy(policy);
    if (policy.autoTranscribe) {
      unawaited(
        pipeline
            .processPending(localOnly: localOnly?.call() ?? false)
            .catchError(
              (Object e) => pipeline.reportError('policy-pending', e),
            ),
      );
    }
  }

  Future<void> cancelAllAndDrain() async {
    for (final token in List.of(_cancellations.values)) {
      token.cancel();
    }
    await Future.wait(_drains.values.map((c) => c.future));
  }

  @override
  Future<SummaryCard> generateSummary(
    List<RecordEvent> events, {
    required SummaryCard target,
    required RecordingPolicy policy,
    required ProgressSink onProgress,
  }) async {
    if (localOnly?.call() == true) {
      throw StateError('快传使用临时本地连接，请结束快传后联网生成总结');
    }
    final token = CancellationToken();
    _cancellations[target.id] = token;
    _drains[target.id] = Completer<void>();
    onProgress(const TaskProgress('校验所选来源并请求授权模型…'));
    try {
      final ids = events.map((e) => e.id).toSet();
      final prior = (await _repository.load()).summaries
          .where(
            (s) =>
                s.state == SummaryState.done &&
                s.id != target.id &&
                s.srcIds.every(ids.contains),
          )
          .toList();
      final result = await _analysis.generateSummary(
        events,
        target: target,
        cancellation: token,
        existingSummaries: prior,
        existingStageSummaries: await _stageContext(events),
      );
      await _repository.update(
        (s) => s.copyWith(
          summaries: [...s.summaries.where((s) => s.id != result.id), result],
        ),
      );
      onProgress(const TaskProgress('已完成', percent: 100));
      return result;
    } finally {
      _cancellations.remove(target.id);
      _drains.remove(target.id)?.complete();
    }
  }

  Future<List<StageSummaryContext>> _stageContext(
    List<RecordEvent> events,
  ) async {
    final state = await _repository.load();
    final selected = {for (final e in events) e.id: e};
    final contexts = <StageSummaryContext>[];
    for (final entry in state.metadata.entries.where(
      (e) => e.key.startsWith('stage:'),
    )) {
      final j = (entry.value as Map).cast<String, dynamic>();
      final boundary = state.metadata['pending-stage:${j['id']}'] as Map?;
      final ids = ((boundary?['chunkIds'] ?? j['sourceChunkIds']) as List)
          .cast<String>();
      if (ids.isEmpty || !ids.every(selected.containsKey)) continue;
      // Current producer chunks may contain multiple raw rows. Expand stage
      // sources to stable row aliases, never invent a canonical rawIndex.
      final mapping = <String, int>{};
      final sourceIds = <String, String>{};
      for (final id in ids) {
        for (var i = 0; i < selected[id]!.raw.length; i++) {
          final alias = '$id:raw:$i';
          mapping[alias] = i;
          sourceIds[alias] = id;
        }
      }
      contexts.add(
        StageSummaryContext(
          summary: StageEvent(
            id: j['id'] as String,
            recordId: j['recordId'] as String,
            revision: j['revision'] as int,
            overview: j['overview'] as String,
            points: (j['points'] as List).cast<String>(),
            todos: (j['todos'] as List).cast<String>(),
            sourceChunkIds: mapping.keys.toList(),
            uncertainties: (j['uncertainties'] as List).cast<String>(),
          ),
          chunkRawIndices: mapping,
          chunkSourceIds: sourceIds,
        ),
      );
    }
    return contexts;
  }

  @override
  Future<void> cancelSummary(String id) async {
    _cancellations[id]?.cancel();
  }
}

class RuntimeDeviceBackend
    implements
        DeviceBackend,
        RecordingDeviceBackend,
        FileTransferDeviceBackend,
        CancelableSyncDeviceBackend {
  RuntimeDeviceBackend(this.delegate, this.pipeline, this.gateway);
  final ServiceDeviceBackend delegate;
  final RecordingPipeline pipeline;
  final CardGateway gateway;
  @override
  DeviceSyncOutcome? get lastSyncOutcome => delegate.lastSyncOutcome;
  @override
  Future<void> prepareFastTransfer() => delegate.prepareFastTransfer();
  @override
  Future<void> cancelFastTransfer() => delegate.cancelFastTransfer();
  @override
  Future<void> cancelSync() => delegate.cancelSync();
  @override
  Future<void> fastSync(RecordingPolicy policy, ProgressSink onProgress) =>
      delegate.fastSync(policy, onProgress);
  @override
  bool get available => delegate.available;
  @override
  Future<List<DeviceChoice>> scan() => delegate.scan();
  @override
  Future<DeviceReading> connect(String id) async {
    final reading = await delegate.connect(id);
    // A real connection remains real even when ASR model/analysis config fails.
    try {
      await pipeline.connected(reading.snapshot);
    } catch (e) {
      await pipeline.reportError('connected-pipeline', e);
    }
    return reading;
  }

  @override
  Future<void> disconnect() async {
    try {
      await pipeline.disconnected();
    } finally {
      await delegate.disconnect();
    }
  }

  @override
  Future<DeviceReading> status() => delegate.status();

  @override
  Future<DeviceReading> startRecording() => delegate.startRecording();

  @override
  Future<DeviceReading> stopRecording() => delegate.stopRecording();

  @override
  Future<void> sync(RecordingPolicy policy, ProgressSink onProgress) async {
    // The adapter owns BLE/AP arbitration. Status reads and ordinary BLE import
    // must never start real-time capture or silently stop the user's recording.
    await delegate.sync(policy, onProgress);
  }

  @override
  Future<List<SavedWifi>> savedWifi() => delegate.savedWifi();
  @override
  Future<List<WifiNet>> scanWifi() => delegate.scanWifi();

  @override
  Future<void> connectSavedWifi(String name) => delegate.connectSavedWifi(name);
  @override
  Future<void> joinWifi(String name, String password) =>
      delegate.joinWifi(name, password);
  @override
  Future<FirmwareOffer?> firmwareOffer() => delegate.firmwareOffer();
  @override
  Future<void> updateFirmware(
    FirmwareOffer offer,
    FirmwareConsent consent,
    ProgressSink onProgress,
  ) async {
    await pipeline.stopCapture();
    await delegate.updateFirmware(offer, consent, onProgress);
  }
}
