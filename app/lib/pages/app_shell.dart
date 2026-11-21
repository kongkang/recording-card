/// 应用外壳 —— 窄屏（顶栏面包屑 + 底栏导航，子页隐藏底栏）与
/// 宽屏 ≥720px 双栏（左栏 Timeline 常显 + 右栏详情/空态，面包屑停用、面板内返回）。
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/device/card_gateway.dart';
import '../core/storage/storage.dart';
import '../core/store/agent_config_store.dart';
import '../core/store/app_store.dart';
import '../core/store/device_store.dart';
import '../core/store/settings_store.dart';
import '../core/theme/tokens.dart';
import '../services/agent/agent_chat_controller.dart';
import '../services/agent/hardware_agent_task_coordinator.dart';
import '../services/audio/live_audio_recorder.dart';
import '../services/audio/recording_status.dart';
import '../services/auth_service.dart';
import '../services/external_data/getnote_sync_store.dart';
import '../services/health/health_signal_controller.dart';
import '../services/memory/memory_search_scope.dart';
import '../services/memory/memory_search_service.dart';
import '../services/photos/photo_library_service.dart';
import '../services/transcribe/asr_models.dart';
import '../services/transcribe/local_asr_service.dart';
import '../services/transcribe/model_manager_controller.dart';
import '../services/transcribe/speech_engine.dart';
import '../services/transcribe/speech_models.dart';
import '../services/transcribe/system_speech_client.dart';
import '../widgets/legacy_upgrade_sheet.dart';
import '../widgets/os1_ai_space.dart';
import '../widgets/store_scope.dart';
import 'detail_page.dart';
import 'setting_page.dart';
import 'settings/setting_sub_page.dart';
import 'status_sheet.dart';
import 'summary_result_page.dart';
import 'timeline_page.dart';
import 'unclassified_photos_page.dart';

const _desktopCommands = MethodChannel('com.reai.recordingcard/desktop');

/// 硬件按键 / Action Button 语音指令双路离线转写：
/// 优先尝试系统端侧识别（[SystemSpeechClient]，`language: 'auto'`）；
/// 若系统识别抛错或返回空文本，自动回退到本地 SenseVoice（`language: 'auto'`）。
/// 若用户已显式指定首选 SenseVoice，则先跑 SenseVoice，不可用或为空时回退系统识别。
Future<String> transcribeVoiceCommandWithDualFallback(
  Float32List samples, {
  int sampleRate = 16000,
  SystemSpeechClient? systemSpeech,
  SpeechEngine? localAsr,
  Future<SpeechEngine?> Function()? resolveLocalAsr,
  ModelInstaller? installer,
  SpeechModelProvider? modelProvider,
  bool preferSenseVoice = false,
}) async {
  if (samples.isEmpty) return '';

  Future<String> trySystem() async {
    final sys = systemSpeech ?? SystemSpeechClient();
    await sys.requestAuthorization();
    final res = await sys.transcribeSamples(
      samples,
      sampleRate: sampleRate,
      language: 'auto',
    );
    return res.text.trim();
  }

  Future<({bool attempted, String text})> trySenseVoice() async {
    String? modelPath;
    String? tokensPath;
    if (modelProvider != null) {
      final resolved = await modelProvider.resolve();
      if (resolved != null &&
          !resolved.usesSystemAsr &&
          resolved.asrModelPath.isNotEmpty &&
          resolved.tokensPath.isNotEmpty) {
        modelPath = resolved.asrModelPath;
        tokensPath = resolved.tokensPath;
      }
    }
    if ((modelPath == null || tokensPath == null) && installer != null) {
      final asr = await installer.status(senseVoiceSpec);
      if (asr.installed) {
        modelPath = await installer.resolve(senseVoiceSpec, 'model.int8.onnx');
        tokensPath = await installer.resolve(senseVoiceSpec, 'tokens.txt');
      }
    }
    if (modelPath == null ||
        modelPath.isEmpty ||
        tokensPath == null ||
        tokensPath.isEmpty) {
      return (attempted: false, text: '');
    }
    final engine =
        localAsr ?? (resolveLocalAsr != null ? await resolveLocalAsr() : null);
    if (engine == null) {
      return (attempted: false, text: '');
    }
    await engine.load(
      modelPath: modelPath,
      tokensPath: tokensPath,
      language: 'auto',
    );
    final res = await engine.transcribe(samples, sampleRate: sampleRate);
    return (attempted: true, text: res.text.trim());
  }

  if (preferSenseVoice) {
    Object? localErr;
    try {
      final local = await trySenseVoice();
      if (local.text.isNotEmpty) return local.text;
    } on Object catch (e) {
      localErr = e;
    }
    try {
      final sysText = await trySystem();
      if (sysText.isNotEmpty) return sysText;
    } on Object {
      if (localErr != null) Error.throwWithStackTrace(localErr, StackTrace.current);
      rethrow;
    }
    return '';
  }

  Object? sysErr;
  try {
    final sysText = await trySystem();
    if (sysText.isNotEmpty) return sysText;
  } on Object catch (e) {
    sysErr = e;
  }

  final local = await trySenseVoice();
  if (local.text.isNotEmpty) return local.text;
  if (!local.attempted && sysErr != null) {
    throw sysErr;
  }
  return '';
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.store,
    this.device,
    this.recordingStatus,
    this.modelManager,
    this.settings,
    this.agentConfig,
    this.liveAudio,
    this.authService,
    this.photoLibrary,
    this.healthSignals,
    this.getNoteStore,
    this.memorySearch,
    this.agentChat,
    this.hardwareAgentCoordinator,
    this.transcribeSamples,
    this.systemSpeech,
    this.fallbackLocalAsr,
    this.modelInstaller,
    this.lookupExistingTranscript,
    this.supportsDynamicIslandOverride,
    this.onDeviceCreated,
    this.clock,
    this.crashStore,
    this.accountHttpClient,
  });

  final AppStore store;
  final DeviceStore? device;
  final RecordingStatusController? recordingStatus;
  final ModelManagerController? modelManager;
  final SettingsStore? settings;
  final AgentConfigStore? agentConfig;
  final LiveAudioRecorder? liveAudio;
  final AuthService? authService;
  final PhotoLibraryService? photoLibrary;
  final HealthSignalController? healthSignals;
  final GetNoteSyncStore? getNoteStore;
  final MemorySearchService? memorySearch;
  final AgentChatController? agentChat;
  final HardwareAgentTaskCoordinator? hardwareAgentCoordinator;
  final SliceTranscribeFn? transcribeSamples;
  final SystemSpeechClient? systemSpeech;
  final SpeechEngine? fallbackLocalAsr;
  final ModelInstaller? modelInstaller;
  final TranscriptLookupFn? lookupExistingTranscript;
  final bool? supportsDynamicIslandOverride;
  final void Function(DeviceStore)? onDeviceCreated;
  final DateTime Function()? clock;
  final KeyValueStore? crashStore;
  final http.Client? accountHttpClient;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final DeviceStore _device = widget.device ?? DeviceStore();
  late final RecordingStatusController _recording =
      widget.recordingStatus ?? RecordingStatusController();
  late final AgentConfigStore _agentConfig =
      widget.agentConfig ?? AgentConfigStore(store: InMemoryStore());
  late final AgentChatController _agentChat =
      widget.agentChat ??
      AgentChatController(
        appStore: widget.store,
        agentConfig: _agentConfig,
        healthStore: widget.healthSignals?.store,
      );

  /// 实时音频接收器：录音期间边录边把 PCM 收进本地，按可配置窗口（默认 1 分钟）切片即刻送本地 ASR 转写落库。
  late final bool _ownsLiveAudio = widget.liveAudio == null;
  late final LiveAudioRecorder _liveAudio =
      widget.liveAudio ??
      LiveAudioRecorder(
        gateway: _device.gateway,
        sliceDuration: _agentConfig.recordingSliceDuration,
      );
  late final PhotoLibraryService _photoLib =
      widget.photoLibrary ?? const PhotoLibraryService();
  late final HardwareAgentTaskCoordinator _hwAgent;
  late final bool _ownsHwAgent = widget.hardwareAgentCoordinator == null;
  StreamSubscription<LiveAudioSlice>? _liveSliceSub;
  StreamSubscription<LiveAudioSlice>? _phoneSliceSub;
  StreamSubscription<LiveAudioSlice>? _watchSliceSub;
  SpeechEngine? _ownedFallbackAsr;
  late DateTime _lastCalendarDay = DateUtils.dateOnly(_now());
  bool _supportsDynamicIsland = false;
  bool _askedPhotoPermThisSession = false;
  late RootTab _lastRootTab = widget.store.rootTab;
  bool _ownsBleReconnectSyncCb = false;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  bool get _resolvedSupportsDynamicIsland =>
      widget.supportsDynamicIslandOverride ?? _supportsDynamicIsland;

  Future<String> _defaultTranscribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
  }) async {
    final preferSv = _agentConfig.preferredAsrEngine == 'sensevoice';
    if (widget.transcribeSamples != null) {
      if (widget.systemSpeech != null && !preferSv) {
        try {
          await widget.systemSpeech!.requestAuthorization();
          final sys = await widget.systemSpeech!.transcribeSamples(
            samples,
            sampleRate: sampleRate,
            language: 'auto',
          );
          if (sys.text.trim().isNotEmpty) return sys.text.trim();
        } on Object {
          // 系统识别失败时自动回退至本地 SenseVoice 回调
        }
      }
      return widget.transcribeSamples!(samples, sampleRate: sampleRate);
    }
    return transcribeVoiceCommandWithDualFallback(
      samples,
      sampleRate: sampleRate,
      systemSpeech: widget.systemSpeech,
      localAsr: widget.fallbackLocalAsr,
      resolveLocalAsr: () async => _ownedFallbackAsr ??= LocalAsrService(),
      installer: widget.modelInstaller ?? ModelInstaller(),
      preferSenseVoice: preferSv,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store.addListener(_onStoreTabChanged);
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      _desktopCommands.setMethodCallHandler(_onDesktopCommand);
    }
    if (widget.device == null) widget.onDeviceCreated?.call(_device);
    // 让 store 知道设备在不在：没连卡时下拉不要去取回录音，更不该报"整理中断"。
    // 已经有人显式接线时不覆盖（测试用假设备，外壳不该抢方向盘）。
    widget.store.deviceConnected ??= () => _device.isConnected;
    widget.store.deviceRecording ??= () =>
        _device.isRecording ||
        _device.isPhoneRecording ||
        _device.isWatchFallbackRecording;
    widget.store.flushActiveRecordingSlice ??= () async {
      if (_liveAudio.isRunning) {
        return _liveAudio.flushActiveSlice();
      }
      if (_device.isWatchFallbackRecording ||
          (_device.isConnected && _device.activeKind == DeviceKind.appleWatch)) {
        return _device.flushWatchRecordingSlice();
      }
      if (_device.isPhoneRecording) {
        return _device.flushPhoneRecordingSlice();
      }
      return false;
    };
    if (_device.onBleReconnectedNeedSync == null) {
      _ownsBleReconnectSyncCb = true;
      _device.onBleReconnectedNeedSync = (_) => widget.store.syncAfterBleReconnect(
        flushWatch: _device.flushWatchRecordingSlice,
        flushPhone: _device.flushPhoneRecordingSlice,
        pullBleFiles: _device.activeCapabilities.hasFileSync,
      );
    }
    widget.store.deviceHasCameraMedia ??= () =>
        _device.activeCapabilities.hasCameraMedia;
    widget.store.photoLibrary = _photoLib;
    widget.store.photoSyncEnabled ??= () => _agentConfig.photoLinkEnabled;
    widget.store.deviceGateway ??= () => _device.gateway;
    _device.attachAgentConfig(_agentConfig);
    _device.onHardwarePhotoCaptured ??= () {
      if (_agentConfig.photoLinkEnabled &&
          _device.isConnected &&
          _device.activeCapabilities.hasCameraMedia) {
        unawaited(widget.store.syncHardwareCameraPhotos(_device.gateway));
      }
    };
    _liveSliceSub = _liveAudio.slices.listen((slice) {
      unawaited(widget.store.ingestLiveSlice(slice));
    });
    _phoneSliceSub = _device.phoneAudioSlices.listen((slice) {
      unawaited(widget.store.ingestLiveSlice(slice));
    });
    _watchSliceSub = _device.watchAudioSlices.listen((slice) {
      unawaited(widget.store.ingestLiveSlice(slice));
    });
    if (_ownsLiveAudio) {
      _device.setRecordingSliceDuration(_agentConfig.recordingSliceDuration);
    }
    _device.setIslandEnabled(_agentConfig.islandEnabled);
    if (_agentConfig.watchLinkEnabled != _device.watchHardware.linkEnabled) {
      unawaited(_device.setWatchLinkEnabled(_agentConfig.watchLinkEnabled));
    }
    _agentConfig.addListener(_syncAgentIslandConfig);
    _hwAgent =
        widget.hardwareAgentCoordinator ??
        HardwareAgentTaskCoordinator(
          device: _device,
          agentConfig: _agentConfig,
          agentChat: _agentChat,
          liveAudio: _liveAudio,
          transcribeSamples: _defaultTranscribeSamples,
          lookupExistingTranscript: widget.lookupExistingTranscript,
        );
    _device.liveActivityService.onActionButtonAgent = () {
      unawaited(_hwAgent.handleIphoneAgentTrigger());
    };
    _device.liveActivityService.onActionButtonToggle = () {
      if (_agentConfig.iphoneActionButtonBehavior ==
          IphoneActionButtonBehavior.agentVoice) {
        unawaited(_hwAgent.handleIphoneAgentTrigger());
        return;
      }
      if (_device.isConnected) {
        unawaited(_device.toggleRecording());
      } else {
        unawaited(
          _device.togglePhoneRecording(
            islandEnabled: _agentConfig.islandEnabled,
          ),
        );
      }
    };
    if (widget.supportsDynamicIslandOverride == null) {
      unawaited(_loadLiveActivityCaps());
    }
    // Timeline 顶部状态块在录音期间一直显示计时：由外壳持有设备时钟
    _device.retainClock();
    _device.addListener(_syncRecordingStatus);
    _syncRecordingStatus();
    // 启动即核对一次蓝牙链路：连着卡就直接展示真实状态，没连就等用户点胶囊去扫描
    unawaited(_device.restoreLink());
  }

  Future<void> _loadLiveActivityCaps() async {
    final caps = await _device.liveActivityService.queryCapabilities();
    if (!mounted) return;
    if (_supportsDynamicIsland != caps.supportsDynamicIsland) {
      setState(() => _supportsDynamicIsland = caps.supportsDynamicIsland);
    }
  }

  /// 上一帧设备是否在录音：用来识别「刚停止录音」这个边沿，冲刷最后一段实时切片。
  bool _wasRecording = false;

  Future<void> _ensurePhotoPermissionOnRecordStart() async {
    if (!_agentConfig.photoLinkEnabled || _askedPhotoPermThisSession) return;
    final status = await _photoLib.checkPermission();
    if (status == PhotoPermissionState.notDetermined) {
      _askedPhotoPermThisSession = true;
      await _photoLib.requestPermission();
    } else if (status == PhotoPermissionState.granted) {
      _askedPhotoPermThisSession = true;
    }
  }

  void _syncAgentIslandConfig() {
    _device.setIslandEnabled(_agentConfig.islandEnabled);
    if (_agentConfig.watchLinkEnabled != _device.watchHardware.linkEnabled) {
      unawaited(_device.setWatchLinkEnabled(_agentConfig.watchLinkEnabled));
    }
    if (_ownsLiveAudio) {
      final dur = _agentConfig.recordingSliceDuration;
      _liveAudio.setSliceDuration(dur);
      _device.setRecordingSliceDuration(dur);
    }
    if (_agentConfig.omiLinkEnabled != _device.omiLinkEnabled ||
        _agentConfig.feishuLinkEnabled != _device.feishuLinkEnabled) {
      unawaited(
        _device.setExtHardwareEnabled(
          omi: _agentConfig.omiLinkEnabled,
          feishu: _agentConfig.feishuLinkEnabled,
        ),
      );
    }
  }

  /// 设备录音态 / 本机录音态 → 实时音频流切片 + Timeline 顶部状态块。
  ///
  /// 录音开启期间按固定窗口（默认 1 分钟）边录边存并本地转写落 Timeline；
  /// 停止录音只冲刷并转写本地尾片，**不再自动从录音卡拉取 `.APM` 文件**
  /// （蓝牙文件拉取仅作为离线录音或流断档时的手动补传通道）。
  void _syncRecordingStatus() {
    final hwRecording = _device.isRecording;
    final watchFailover = _device.isWatchFallbackRecording;
    final phoneRecording = _device.isPhoneRecording;
    final recording = hwRecording || watchFailover || phoneRecording;
    if (recording) {
      if (hwRecording && _device.activeCapabilities.realtimeAudio) {
        _liveAudio.updateDeviceSessionId(_device.recordSession);
        _liveAudio.updateSourceDeviceLabel(_device.activeRecordingDeviceLabel);
        if (!_liveAudio.isRunning) {
          unawaited(_liveAudio.start());
        }
      } else if (_liveAudio.isRunning) {
        // 硬件切换至本机录音或 Apple Watch 离线切片模式：停掉蓝牙实时流，保持状态块不中断
        unawaited(_liveAudio.stop());
      }
      if (!_wasRecording) {
        widget.store.onLiveRecordingStarted();
        _recording.startRecording();
        unawaited(_ensurePhotoPermissionOnRecordStart());
      } else {
        _recording.ensureRecording();
      }
      _recording.updateElapsed(
        hwRecording
            ? _device.recSeconds
            : (watchFailover
                  ? _device.watchFailoverRecSeconds
                  : _device.phoneRecSeconds),
      );
    } else if (_wasRecording) {
      _wasRecording = false;
      unawaited(_onRecordingStopped());
      return;
    } else if (_device.isPendingForegroundPhoneFailover &&
        _recording.phase != RecordingPhase.idle) {
      _recording.stopRecording();
    }
    _wasRecording = recording;
  }

  /// 停止录音后：关闭实时流并把最后一段未满 1 分钟的尾部切片封口、完成本地转写落库。
  /// 不再触发蓝牙文件拉取（`_autoSyncAfterRecording`）。
  Future<void> _onRecordingStopped() async {
    final hadLiveSamples =
        _liveAudio.isRunning && _liveAudio.recordedSeconds > 0;
    if (hadLiveSamples) {
      _recording.startSync(detail: '正在转写最后一段实时录音…');
    } else {
      _recording.stopRecording();
    }
    await _liveAudio.stop();
    final savedCount = await widget.store.finishLiveRecording();
    if (!mounted) return;
    if (!_device.isRecording &&
        !_device.isPhoneRecording &&
        !_device.isWatchFallbackRecording) {
      _recording.stopRecording();
      if (savedCount > 0 || hadLiveSamples) {
        _device.noteSyncFinished(manual: false);
      }
    }
    if (_device.consumePendingPostReconnectSync() && _device.isConnected) {
      unawaited(
        widget.store.syncAfterBleReconnect(
          flushWatch: _device.flushWatchRecordingSlice,
          flushPhone: _device.flushPhoneRecordingSlice,
          pullBleFiles: _device.activeCapabilities.hasFileSync,
        ),
      );
    }
  }

  Future<void> _onDesktopCommand(MethodCall call) async {
    if (call.method == 'openSettings') {
      widget.store.go(RootTab.setting);
    }
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) {
      _lastCalendarDay = DateUtils.dateOnly(_now());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _device.handleAppResumed();
      final today = DateUtils.dateOnly(_now());
      final diffDays = today.difference(_lastCalendarDay).inDays;
      if (diffDays != 0) {
        _lastCalendarDay = today;
        final elapsed = diffDays > 0 ? diffDays : 1;
        unawaited(widget.store.onCalendarDayRollover(daysElapsed: elapsed));
      }
      if (widget.store.rootTab == RootTab.timeline &&
          widget.store.pendingLocalAudioCount > 0) {
        unawaited(
          widget.store.transcribeAndOrganizePending(reason: 'view-resume'),
        );
      }
    }
  }

  void _onStoreTabChanged() {
    final cur = widget.store.rootTab;
    if (_lastRootTab != RootTab.timeline &&
        cur == RootTab.timeline &&
        widget.store.pendingLocalAudioCount > 0) {
      unawaited(widget.store.transcribeAndOrganizePending(reason: 'tab-view'));
    }
    _lastRootTab = cur;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.store.removeListener(_onStoreTabChanged);
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      _desktopCommands.setMethodCallHandler(null);
    }
    final fallbackAsr = _ownedFallbackAsr;
    if (fallbackAsr != null) {
      unawaited(fallbackAsr.dispose());
    }
    _agentConfig.removeListener(_syncAgentIslandConfig);
    _device.liveActivityService.onActionButtonAgent = null;
    _device.liveActivityService.onActionButtonToggle = null;
    if (_ownsBleReconnectSyncCb) {
      _device.onBleReconnectedNeedSync = null;
    }
    if (_ownsHwAgent) _hwAgent.dispose();
    _liveSliceSub?.cancel();
    _phoneSliceSub?.cancel();
    _watchSliceSub?.cancel();
    _device.removeListener(_syncRecordingStatus);
    if (widget.liveAudio == null) _liveAudio.dispose();
    _device.releaseClock();
    if (widget.device == null) _device.dispose();
    if (widget.recordingStatus == null) _recording.dispose();
    if (widget.agentChat == null) _agentChat.dispose();
    if (widget.agentConfig == null) _agentConfig.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MemorySearchScope(
      service: widget.memorySearch,
      child: StoreScope(
        store: widget.store,
        child: ListenableBuilder(
          listenable: widget.store,
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= RCDims.wideBreakpoint;
              return PopScope(
                // Android 物理返回键 / 手势：先退自管路由栈，栈空才交给系统退出
                canPop: false,
                onPopInvokedWithResult: (didPop, _) {
                  if (didPop) return;
                  final handled = widget.store.handleSystemBack();
                  if (!handled && mounted) {
                    // 栈已空：让系统退出 App（Android 期望行为）
                    SystemNavigator.pop();
                  }
                },
                child: Scaffold(
                  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                  body: Stack(
                    children: [
                      if (wide)
                        _WideLayout(
                          device: _device,
                          recordingStatus: _recording,
                          modelManager: widget.modelManager,
                          settings: widget.settings,
                          agentConfig: _agentConfig,
                          authService: widget.authService,
                          photoLibrary: _photoLib,
                          healthSignals: widget.healthSignals,
                          getNoteStore: widget.getNoteStore,
                          onOpenOs1: () => _agentChat.open(),
                          supportsDynamicIsland: _resolvedSupportsDynamicIsland,
                          crashStore: widget.crashStore,
                          accountHttpClient: widget.accountHttpClient,
                        )
                      else
                        _NarrowLayout(
                          device: _device,
                          recordingStatus: _recording,
                          modelManager: widget.modelManager,
                          settings: widget.settings,
                          agentConfig: _agentConfig,
                          authService: widget.authService,
                          photoLibrary: _photoLib,
                          healthSignals: widget.healthSignals,
                          getNoteStore: widget.getNoteStore,
                          onOpenOs1: () => _agentChat.open(),
                          supportsDynamicIsland: _resolvedSupportsDynamicIsland,
                          crashStore: widget.crashStore,
                          accountHttpClient: widget.accountHttpClient,
                        ),
                      ListenableBuilder(
                        listenable: _hwAgent,
                        builder: (context, _) {
                          final toastText = _hwAgent.lastButtonToast;
                          final text = _hwAgent.statusText;
                          if ((toastText == null || toastText.isEmpty) &&
                              (text == null || text.isEmpty)) {
                            return const SizedBox.shrink();
                          }
                          final topPad = MediaQuery.paddingOf(context).top + 10;
                          return Positioned(
                            top: topPad,
                            left: 16,
                            right: 16,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (toastText != null && toastText.isNotEmpty)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      bottom: (text != null && text.isNotEmpty)
                                          ? 8
                                          : 0,
                                    ),
                                    child: IgnorePointer(
                                      child: Container(
                                        key: const Key('hw-button-toast'),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xEB111827),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: const Color(0x4034D399),
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Color(0x30000000),
                                              blurRadius: 12,
                                              offset: Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.radio_button_checked_rounded,
                                              size: 14,
                                              color: Color(0xFF34D399),
                                            ),
                                            const SizedBox(width: 7),
                                            Flexible(
                                              child: Text(
                                                toastText,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                if (text != null && text.isNotEmpty)
                                  Center(
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        key: const Key('hw-agent-task-pill'),
                                        borderRadius: BorderRadius.circular(999),
                                        onTap: () {
                                          if (_hwAgent.phase ==
                                              HardwareAgentPhase.listening) {
                                            unawaited(
                                              _hwAgent.handleIphoneAgentTrigger(),
                                            );
                                          } else {
                                            _agentChat.open();
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: context.rc.isDark
                                                ? const Color(0xEB222228)
                                                : context.rc.label.withValues(
                                                    alpha: 0.92,
                                                  ),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x28000000),
                                                blurRadius: 12,
                                                offset: Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              SizedBox(
                                                width: 8,
                                                height: 8,
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color:
                                                        _hwAgent.phase ==
                                                            HardwareAgentPhase
                                                                .listening
                                                        ? context.rc.ok
                                                        : const Color(0xFF60A5FA),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                child: Text(
                                                  text,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                      ListenableBuilder(
                        listenable: _device,
                        builder: (context, _) {
                          final notice = _device.disconnectNotice;
                          if (notice == null ||
                              notice.isEmpty ||
                              _device.sheetOpen ||
                              _device.isConnected) {
                            return const SizedBox.shrink();
                          }
                          final c = context.rc;
                          final headerH = wide
                              ? RCDims.wideChrome
                              : RCDims.narrowHeader;
                          final topPad =
                              MediaQuery.paddingOf(context).top + headerH + 6;
                          return Positioned(
                            top: topPad,
                            left: 14,
                            right: 14,
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: const Key('ble-disconnect-toast'),
                                borderRadius: BorderRadius.circular(12),
                                onTap: _device.openSheet,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: c.isDark
                                        ? const Color(0xF025211A)
                                        : const Color(0xF5FFF8EB),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: c.warn.withValues(alpha: 0.45),
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x22000000),
                                        blurRadius: 10,
                                        offset: Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        _device.isPendingForegroundPhoneFailover
                                            ? Icons.mic_off_rounded
                                            : Icons.bluetooth_disabled_rounded,
                                        size: 16,
                                        color: c.warn,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          notice,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            height: 1.35,
                                            fontWeight: FontWeight.w500,
                                            color: c.label,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      GestureDetector(
                                        key: const Key('ble-disconnect-toast-close'),
                                        behavior: HitTestBehavior.opaque,
                                        onTap: _device.dismissDisconnectNotice,
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: Icon(
                                            Icons.close,
                                            size: 16,
                                            color: c.sec,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      ListenableBuilder(
                        listenable: _agentConfig,
                        builder: (context, _) => StatusSheetOverlay(
                          store: _device,
                          agentConfig: _agentConfig,
                          islandEnabled: _agentConfig.islandEnabled,
                        ),
                      ),
                      LegacyUpgradeSheetOverlay(
                        controller: _device.legacyUpgrade,
                      ),
                      Os1AiSpaceOverlay(controller: _agentChat),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 仅让当前可见的唯一主页面继承 Scaffold 的 PrimaryScrollController：
/// 避免 Offstage / 双栏同时挂载多个可滚动视图时 positions.length > 1，
/// 确保 iOS 点击状态栏（以及顶部标题区）回顶始终命中当前页。
Widget _withPrimaryScroll(
  ScrollController? controller, {
  required bool active,
  required Widget child,
}) {
  if (active && controller != null) {
    return PrimaryScrollController(
      controller: controller,
      scrollDirection: Axis.vertical,
      automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
      child: child,
    );
  }
  return PrimaryScrollController.none(child: child);
}

void _scrollActiveToTop(BuildContext context) {
  final ctrl = PrimaryScrollController.maybeOf(context);
  if (ctrl == null || ctrl.positions.length != 1) return;
  if (ctrl.position.pixels <= 0) return;
  ctrl.animateTo(
    0.0,
    duration: const Duration(milliseconds: 320),
    curve: Curves.easeOutCubic,
  );
}

/// 顶栏标题区：根页「录音卡」+ 胶囊；子页「‹ {返回目标}」（窄屏）
class _Header extends StatelessWidget {
  const _Header({
    required this.height,
    required this.wide,
    required this.device,
    this.topInset = 0,
  });
  final double height;

  /// 窄屏真机安全区：刘海高度并入顶栏背景，内容仍占下方 [height] 区域
  final double topInset;
  final bool wide;
  final DeviceStore device;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final store = StoreScope.of(context);
    final sub = store.subStack.isNotEmpty;
    return Container(
      key: const Key('app-header'),
      height: height,
      padding: EdgeInsets.fromLTRB(20, topInset, 20, 0),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(bottom: BorderSide(color: c.sep)),
      ),
      child: Row(
        children: [
          if (!wide && sub) ...[
            TextButton(
              key: const Key('crumb-back'),
              onPressed: store.goBack,
              style: TextButton.styleFrom(
                foregroundColor: c.label,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                children: [
                  const Icon(Icons.chevron_left, size: 18),
                  Text(
                    store.crumbDest,
                    key: const Key('crumb-dest'),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GestureDetector(
                key: const Key('header-tap-top'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _scrollActiveToTop(context),
                child: const SizedBox.expand(),
              ),
            ),
          ] else
            Expanded(
              child: GestureDetector(
                key: const Key('header-tap-top'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _scrollActiveToTop(context),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '录音卡',
                    key: const Key('app-title'),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: c.label,
                    ),
                  ),
                ),
              ),
            ),
          // 真实电量经 DeviceStore 刷新（refreshFromDevice），需监听设备状态重建胶囊
          ListenableBuilder(
            listenable: device,
            builder: (context, _) => HwCapsule(
              onTap: device.openSheet,
              level: device.battery,
              connected: device.isConnected,
              recording: device.isRecording,
              phoneRecording: device.isPhoneRecording,
              watchRecording: device.isWatchFallbackRecording,
              pendingFailover: device.isPendingForegroundPhoneFailover,
              charging: device.isCharging,
              reconnecting: device.isReconnecting,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.height,
    this.bottomInset = 0,
    required this.onOpenOs1,
  });
  final double height;

  /// 窄屏/宽屏真机安全区：home indicator 高度并入底栏背景，图标区仍占上方 [height]
  final double bottomInset;
  final VoidCallback onOpenOs1;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final store = StoreScope.of(context);
    Widget item(String label, RootTab tab, String keyName, IconData icon) {
      final on = store.rootTab == tab;
      final itemColor = on ? c.label : c.sec;
      return Expanded(
        child: InkWell(
          key: Key(keyName),
          onTap: () => store.go(tab),
          child: SizedBox(
            height: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 20, color: itemColor),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.15,
                        color: itemColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget sunriseItem() {
      return Expanded(
        child: GestureDetector(
          key: const Key('nav-ai-sunrise'),
          behavior: HitTestBehavior.opaque,
          onTap: onOpenOs1,
          child: SizedBox(
            height: double.infinity,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                Positioned(
                  top: -18,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        key: const Key('nav-ai-sunrise-orb'),
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const RadialGradient(
                            center: Alignment(-0.28, -0.44),
                            radius: 0.9,
                            colors: [
                              Color(0xFFFFB57A),
                              Color(0xFFEF653F),
                              Color(0xFFC5361B),
                            ],
                          ),
                          border: Border.all(color: c.bg, width: 3),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x61D94124),
                              blurRadius: 14,
                              offset: Offset(0, 5),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.all_inclusive_rounded,
                          size: 22,
                          color: Color(0xFFFFF6EE),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'OS1',
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          color: c.isDark
                              ? const Color(0xFFFF8A65)
                              : const Color(0xFFC5361B),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      key: const Key('bottom-nav'),
      height: height,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.sep)),
      ),
      alignment: Alignment.topCenter,
      child: Row(
        children: [
          item('Timeline', RootTab.timeline, 'nav-timeline', Icons.schedule),
          sunriseItem(),
          item(
            'Setting',
            RootTab.setting,
            'nav-setting',
            Icons.settings_outlined,
          ),
        ],
      ),
    );
  }
}

/// 栈顶页面部件；面板内返回按钮仅宽屏双栏使用（窄屏走顶栏面包屑）
Widget _stackTopPage(
  AppStore store, {
  required bool wide,
  required AgentConfigStore agentConfig,
  DeviceStore? device,
  ModelManagerController? modelManager,
  AuthService? authService,
  HealthSignalController? healthSignals,
  GetNoteSyncStore? getNoteStore,
}) {
  final top = store.stackTop;
  if (top == null) return const SizedBox.shrink();
  if (top.type == 'sum') {
    return SummaryResultPage(
      summaryId: top.id,
      showPaneBack: wide && store.showPaneBackSum,
      onCancelGeneration: () => store.cancelGeneratingSummary(top.id),
    );
  }
  if (top.type == 'unc') {
    return UnclassifiedPhotosPage(
      dayOffset: int.tryParse(top.id) ?? 0,
      showPaneBack: wide && store.showPaneBackUnc,
    );
  }
  if (top.type == 'setsub') {
    return SettingSubPage(
      subId: top.id,
      agentConfig: agentConfig,
      device: device,
      modelManager: modelManager,
      authService: authService,
      healthSignals: healthSignals,
      getNoteStore: getNoteStore,
      showPaneBack: wide && store.showPaneBackSetSub,
    );
  }
  return DetailPage(
    eventId: top.id,
    showPaneBack: wide && store.showPaneBackDetail,
    backLabel: '返回${AppStore.pageLabels[store.stackPrev?.type] ?? ''}',
  );
}

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({
    required this.device,
    required this.recordingStatus,
    required this.agentConfig,
    this.modelManager,
    this.settings,
    this.authService,
    this.photoLibrary,
    this.healthSignals,
    this.getNoteStore,
    required this.onOpenOs1,
    this.supportsDynamicIsland = false,
    this.crashStore,
    this.accountHttpClient,
  });
  final DeviceStore device;
  final RecordingStatusController recordingStatus;
  final ModelManagerController? modelManager;
  final SettingsStore? settings;
  final AgentConfigStore agentConfig;
  final AuthService? authService;
  final PhotoLibraryService? photoLibrary;
  final HealthSignalController? healthSignals;
  final GetNoteSyncStore? getNoteStore;
  final VoidCallback onOpenOs1;
  final bool supportsDynamicIsland;
  final KeyValueStore? crashStore;
  final http.Client? accountHttpClient;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final sub = store.subStack.isNotEmpty;
    final primaryScroll = PrimaryScrollController.maybeOf(context);
    // 真机安全区：刘海并入顶栏背景，home indicator 并入底栏背景
    // （widget 测试里 padding 为 0，高度与原型/断言一致）
    final insets = MediaQuery.paddingOf(context);
    return Column(
      children: [
        _Header(
          height: RCDims.narrowHeader + insets.top,
          topInset: insets.top,
          wide: false,
          device: device,
        ),
        Expanded(
          // 栈页走 Navigator pages：系统级 iOS 边缘滑动返回
          //（MaterialPage 在 iOS 用 Cupertino 转场自带返回手势），栈仍由 store 单一事实源驱动
          child: Navigator(
            pages: [
              MaterialPage(
                // 覆盖路由包 Offstage：与旧内联渲染语义一致（被盖页不进 hit test/find）
                child: _withPrimaryScroll(
                  primaryScroll,
                  active: store.subStack.isEmpty,
                  child: Offstage(
                    offstage: store.subStack.isNotEmpty,
                    child: switch (store.rootTab) {
                      RootTab.timeline => TimelinePage(
                        recordingStatus: recordingStatus,
                      ),
                      RootTab.setting => SettingPage(
                        device: device,
                        modelManager: modelManager,
                        settings: settings,
                        agentConfig: agentConfig,
                        authService: authService,
                        photoLibrary: photoLibrary,
                        healthSignals: healthSignals,
                        getNoteStore: getNoteStore,
                        supportsDynamicIsland: supportsDynamicIsland,
                        crashStore: crashStore,
                        accountHttpClient: accountHttpClient,
                      ),
                    },
                  ),
                ),
              ),
              for (final e in store.subStack)
                MaterialPage(
                  key: ValueKey('sub-${e.type}-${e.id}'),
                  child: _withPrimaryScroll(
                    primaryScroll,
                    active: e == store.subStack.last,
                    child: Offstage(
                      offstage: e != store.subStack.last,
                      child: _subPage(
                        store,
                        e,
                        agentConfig,
                        device,
                        modelManager,
                        authService,
                        healthSignals,
                        getNoteStore,
                      ),
                    ),
                  ),
                ),
            ],
            onDidRemovePage: (page) {
              // 手势/系统返回 → 页面被移除而 store 未收敛：同步栈状态。
              // store 主动驱动的移除（面包屑/扁平化）在页移除时栈已一致，此处守卫跳过
              final key = page.key;
              if (key is ValueKey<String>) {
                final last = store.subStack.lastOrNull;
                if (last != null &&
                    'sub-${last.type}-${last.id}' == key.value) {
                  store.onSubPopped();
                }
              }
            },
          ),
        ),
        // 子页隐藏底栏，经顶栏面包屑或边缘滑动返回；内容底部让出 home indicator
        if (!sub)
          _BottomNav(
            height: 56 + insets.bottom,
            bottomInset: insets.bottom,
            onOpenOs1: onOpenOs1,
          )
        else if (insets.bottom > 0)
          SizedBox(height: insets.bottom),
      ],
    );
  }

  /// 栈内条目对应的页面（Navigator 页面渲染用；宽屏右栏仍走 _stackTopPage）
  static Widget _subPage(
    AppStore store,
    RouteEntry e,
    AgentConfigStore agentConfig,
    DeviceStore device,
    ModelManagerController? modelManager,
    AuthService? authService,
    HealthSignalController? healthSignals,
    GetNoteSyncStore? getNoteStore,
  ) {
    if (e.type == 'sum') {
      return SummaryResultPage(
        summaryId: e.id,
        showPaneBack: false,
        onCancelGeneration: () => store.cancelGeneratingSummary(e.id),
      );
    }
    if (e.type == 'unc') {
      return UnclassifiedPhotosPage(
        dayOffset: int.tryParse(e.id) ?? 0,
        showPaneBack: false,
      );
    }
    if (e.type == 'setsub') {
      return SettingSubPage(
        subId: e.id,
        agentConfig: agentConfig,
        device: device,
        modelManager: modelManager,
        authService: authService,
        healthSignals: healthSignals,
        getNoteStore: getNoteStore,
        showPaneBack: false,
      );
    }
    return DetailPage(eventId: e.id, showPaneBack: false, backLabel: '');
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({
    required this.device,
    required this.recordingStatus,
    required this.agentConfig,
    this.modelManager,
    this.settings,
    this.authService,
    this.photoLibrary,
    this.healthSignals,
    this.getNoteStore,
    required this.onOpenOs1,
    this.supportsDynamicIsland = false,
    this.crashStore,
    this.accountHttpClient,
  });
  final DeviceStore device;
  final RecordingStatusController recordingStatus;
  final ModelManagerController? modelManager;
  final SettingsStore? settings;
  final AgentConfigStore agentConfig;
  final AuthService? authService;
  final PhotoLibraryService? photoLibrary;
  final HealthSignalController? healthSignals;
  final GetNoteSyncStore? getNoteStore;
  final VoidCallback onOpenOs1;
  final bool supportsDynamicIsland;
  final KeyValueStore? crashStore;
  final http.Client? accountHttpClient;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final store = StoreScope.of(context);
    final sub = store.subStack.isNotEmpty;
    final primaryScroll = PrimaryScrollController.maybeOf(context);
    // iPad / Android 15+ edge-to-edge 安全区：顶部状态栏并入顶栏，底部手势条并入底栏
    final insets = MediaQuery.paddingOf(context);
    return Column(
      children: [
        _Header(
          height: RCDims.wideChrome + insets.top,
          topInset: insets.top,
          wide: true,
          device: device,
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 380,
                child: _withPrimaryScroll(
                  primaryScroll,
                  active: !sub,
                  child: switch (store.rootTab) {
                    RootTab.timeline => TimelinePage(
                      asLeftPane: true,
                      recordingStatus: recordingStatus,
                    ),
                    RootTab.setting => SettingPage(
                      device: device,
                      modelManager: modelManager,
                      settings: settings,
                      agentConfig: agentConfig,
                      authService: authService,
                      photoLibrary: photoLibrary,
                      healthSignals: healthSignals,
                      getNoteStore: getNoteStore,
                      supportsDynamicIsland: supportsDynamicIsland,
                      crashStore: crashStore,
                      accountHttpClient: accountHttpClient,
                    ),
                  },
                ),
              ),
              Container(width: 1, color: c.sep),
              Expanded(
                child: _withPrimaryScroll(
                  primaryScroll,
                  active: sub,
                  child: sub
                      ? Material(
                          color: c.bg,
                          child: _stackTopPage(
                            store,
                            wide: true,
                            agentConfig: agentConfig,
                            device: device,
                            modelManager: modelManager,
                            authService: authService,
                            healthSignals: healthSignals,
                            getNoteStore: getNoteStore,
                          ),
                        )
                      : const _EmptyPane(),
                ),
              ),
            ],
          ),
        ),
        _BottomNav(
          height: RCDims.wideChrome + insets.bottom,
          bottomInset: insets.bottom,
          onOpenOs1: onOpenOs1,
        ),
      ],
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane();

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Center(
      key: const Key('empty-pane'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 40, color: c.ax),
          const SizedBox(height: 10),
          Text(
            '选择左侧记录查看详情',
            style: TextStyle(fontSize: 13, color: c.sec),
          ),
        ],
      ),
    );
  }
}
