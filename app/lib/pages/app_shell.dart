/// 应用外壳 —— 窄屏（顶栏面包屑 + 底栏导航，子页隐藏底栏）与
/// 宽屏 ≥720px 双栏（左栏 Timeline 常显 + 右栏详情/空态，面包屑停用、面板内返回）。
library;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/storage/storage.dart';
import '../core/store/agent_config_store.dart';
import '../core/store/app_store.dart';
import '../core/store/device_store.dart';
import '../core/store/settings_store.dart';
import '../core/theme/tokens.dart';
import '../services/audio/live_audio_recorder.dart';
import '../services/audio/recording_status.dart';
import '../services/auth_service.dart';
import '../services/photos/photo_library_service.dart';
import '../services/transcribe/model_manager_controller.dart';
import '../widgets/store_scope.dart';
import 'detail_page.dart';
import 'setting_page.dart';
import 'settings/setting_sub_page.dart';
import 'status_sheet.dart';
import 'summary_result_page.dart';
import 'timeline_page.dart';
import 'unclassified_photos_page.dart';

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
    this.supportsDynamicIslandOverride,
    this.onDeviceCreated,
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
  final bool? supportsDynamicIslandOverride;
  final void Function(DeviceStore)? onDeviceCreated;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final DeviceStore _device = widget.device ?? DeviceStore();
  late final RecordingStatusController _recording =
      widget.recordingStatus ?? RecordingStatusController();
  late final AgentConfigStore _agentConfig =
      widget.agentConfig ?? AgentConfigStore(store: InMemoryStore());

  /// 实时音频接收器：录音期间边录边把 PCM 收进本地，每满 1 分钟切片即刻送本地 ASR 转写落库。
  late final LiveAudioRecorder _liveAudio =
      widget.liveAudio ?? LiveAudioRecorder(gateway: _device.gateway);
  late final PhotoLibraryService _photoLib =
      widget.photoLibrary ?? const PhotoLibraryService();
  StreamSubscription<LiveAudioSlice>? _liveSliceSub;
  StreamSubscription<LiveAudioSlice>? _phoneSliceSub;
  bool _supportsDynamicIsland = false;
  bool _askedPhotoPermThisSession = false;

  bool get _resolvedSupportsDynamicIsland =>
      widget.supportsDynamicIslandOverride ?? _supportsDynamicIsland;

  @override
  void initState() {
    super.initState();
    if (widget.device == null) widget.onDeviceCreated?.call(_device);
    // 让 store 知道设备在不在：没连卡时下拉不要去取回录音，更不该报"整理中断"。
    // 已经有人显式接线时不覆盖（测试用假设备，外壳不该抢方向盘）。
    widget.store.deviceConnected ??= () => _device.isConnected;
    widget.store.deviceRecording ??=
        () => _device.isRecording || _device.isPhoneRecording;
    widget.store.flushActiveRecordingSlice ??= () async {
      if (_liveAudio.isRunning) {
        return _liveAudio.flushActiveSlice();
      }
      if (_device.isPhoneRecording) {
        return _device.flushPhoneRecordingSlice();
      }
      return false;
    };
    widget.store.deviceHasCameraMedia ??=
        () => _device.activeCapabilities.hasCameraMedia;
    widget.store.photoLibrary = _photoLib;
    widget.store.photoSyncEnabled ??= () => _agentConfig.photoLinkEnabled;
    widget.store.deviceGateway ??= () => _device.gateway;
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
    _device.setIslandEnabled(_agentConfig.islandEnabled);
    _agentConfig.addListener(_syncAgentIslandConfig);
    _device.liveActivityService.onActionButtonToggle = () {
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
  }

  /// 设备录音态 / 本机录音态 → 实时音频流切片 + Timeline 顶部状态块。
  ///
  /// 录音开启期间按固定窗口（默认 1 分钟）边录边存并本地转写落 Timeline；
  /// 停止录音只冲刷并转写本地尾片，**不再自动从录音卡拉取 `.APM` 文件**
  /// （蓝牙文件拉取仅作为离线录音或流断档时的手动补传通道）。
  void _syncRecordingStatus() {
    final hwRecording = _device.isRecording;
    final phoneRecording = _device.isPhoneRecording;
    final recording = hwRecording || phoneRecording;
    if (recording) {
      if (hwRecording) {
        _liveAudio.updateDeviceSessionId(_device.recordSession);
        if (!_liveAudio.isRunning) {
          unawaited(_liveAudio.start());
        }
      } else if (_liveAudio.isRunning) {
        // 硬件切换至本机录音（如断连自动保底 / OTA 交接）：停掉蓝牙实时流，保持状态块不中断
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
        hwRecording ? _device.recSeconds : _device.phoneRecSeconds,
      );
    } else if (_wasRecording) {
      _wasRecording = false;
      unawaited(_onRecordingStopped());
      return;
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
    if (!_device.isRecording && !_device.isPhoneRecording) {
      _recording.stopRecording();
      if (savedCount > 0 || hadLiveSamples) {
        _device.noteSyncFinished(manual: false);
      }
    }
  }

  @override
  void dispose() {
    _agentConfig.removeListener(_syncAgentIslandConfig);
    _device.liveActivityService.onActionButtonToggle = null;
    _liveSliceSub?.cancel();
    _phoneSliceSub?.cancel();
    _device.removeListener(_syncRecordingStatus);
    if (widget.liveAudio == null) _liveAudio.dispose();
    _device.releaseClock();
    if (widget.device == null) _device.dispose();
    if (widget.recordingStatus == null) _recording.dispose();
    if (widget.agentConfig == null) _agentConfig.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StoreScope(
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
                        supportsDynamicIsland: _resolvedSupportsDynamicIsland,
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
                        supportsDynamicIsland: _resolvedSupportsDynamicIsland,
                      ),
                    ListenableBuilder(
                      listenable: _agentConfig,
                      builder: (context, _) => StatusSheetOverlay(
                        store: _device,
                        islandEnabled: _agentConfig.islandEnabled,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
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
    final store = StoreScope.of(context);
    final sub = store.subStack.isNotEmpty;
    return Container(
      key: const Key('app-header'),
      height: height,
      padding: EdgeInsets.fromLTRB(20, topInset, 20, 0),
      decoration: const BoxDecoration(
        color: RCColors.bg,
        border: Border(bottom: BorderSide(color: RCColors.sep)),
      ),
      child: Row(
        children: [
          if (!wide && sub)
            TextButton(
              key: const Key('crumb-back'),
              onPressed: store.goBack,
              style: TextButton.styleFrom(
                foregroundColor: RCColors.label,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(children: [
                const Icon(Icons.chevron_left, size: 18),
                Text(store.crumbDest,
                    key: const Key('crumb-dest'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ]),
            )
          else
            Text('录音卡',
                key: const Key('app-title'),
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const Spacer(),
          // 真实电量经 DeviceStore 刷新（refreshFromDevice），需监听设备状态重建胶囊
          ListenableBuilder(
            listenable: device,
            builder: (context, _) => HwCapsule(
              onTap: device.openSheet,
              level: device.battery,
              connected: device.isConnected,
              recording: device.isRecording,
              phoneRecording: device.isPhoneRecording,
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
  const _BottomNav({required this.height, this.bottomInset = 0});
  final double height;

  /// 窄屏真机安全区：home indicator 高度并入底栏背景，图标区仍占上方 [height]
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    Widget item(String label, RootTab tab, String keyName, IconData icon) {
      final on = store.rootTab == tab;
      return Expanded(
        child: InkWell(
          key: Key(keyName),
          onTap: () => store.go(tab),
          child: SizedBox(
            height: double.infinity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 20, color: on ? RCColors.label : RCColors.sec),
                const SizedBox(height: 3),
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        color: on ? RCColors.label : RCColors.sec)),
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
      decoration: const BoxDecoration(
        color: RCColors.bg,
        border: Border(top: BorderSide(color: RCColors.sep)),
      ),
      alignment: Alignment.topCenter,
      child: Row(children: [
        item('Timeline', RootTab.timeline, 'nav-timeline', Icons.schedule),
        item('Setting', RootTab.setting, 'nav-setting', Icons.settings_outlined),
      ]),
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
}) {
  final top = store.stackTop;
  if (top == null) return const SizedBox.shrink();
  if (top.type == 'sum') {
    return SummaryResultPage(
      summaryId: top.id,
      showPaneBack: wide && store.showPaneBackSum,
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
    this.supportsDynamicIsland = false,
  });
  final DeviceStore device;
  final RecordingStatusController recordingStatus;
  final ModelManagerController? modelManager;
  final SettingsStore? settings;
  final AgentConfigStore agentConfig;
  final AuthService? authService;
  final PhotoLibraryService? photoLibrary;
  final bool supportsDynamicIsland;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final sub = store.subStack.isNotEmpty;
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
                child: Offstage(
                  offstage: store.subStack.isNotEmpty,
                  child: switch (store.rootTab) {
                    RootTab.timeline =>
                      TimelinePage(recordingStatus: recordingStatus),
                    RootTab.setting => SettingPage(
                      device: device,
                      modelManager: modelManager,
                      settings: settings,
                      agentConfig: agentConfig,
                      authService: authService,
                      photoLibrary: photoLibrary,
                      supportsDynamicIsland: supportsDynamicIsland,
                    ),
                  },
                ),
              ),
              for (final e in store.subStack)
                MaterialPage(
                  key: ValueKey('sub-${e.type}-${e.id}'),
                  child: Offstage(
                    offstage: e != store.subStack.last,
                    child: _subPage(
                      e,
                      agentConfig,
                      device,
                      modelManager,
                      authService,
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
                if (last != null && 'sub-${last.type}-${last.id}' == key.value) {
                  store.onSubPopped();
                }
              }
            },
          ),
        ),
        // 子页隐藏底栏，经顶栏面包屑或边缘滑动返回；内容底部让出 home indicator
        if (!sub)
          _BottomNav(height: 56 + insets.bottom, bottomInset: insets.bottom)
        else if (insets.bottom > 0)
          SizedBox(height: insets.bottom),
      ],
    );
  }

  /// 栈内条目对应的页面（Navigator 页面渲染用；宽屏右栏仍走 _stackTopPage）
  static Widget _subPage(
    RouteEntry e,
    AgentConfigStore agentConfig,
    DeviceStore device,
    ModelManagerController? modelManager,
    AuthService? authService,
  ) {
    if (e.type == 'sum') {
      return SummaryResultPage(summaryId: e.id, showPaneBack: false);
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
    this.supportsDynamicIsland = false,
  });
  final DeviceStore device;
  final RecordingStatusController recordingStatus;
  final ModelManagerController? modelManager;
  final SettingsStore? settings;
  final AgentConfigStore agentConfig;
  final AuthService? authService;
  final PhotoLibraryService? photoLibrary;
  final bool supportsDynamicIsland;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final sub = store.subStack.isNotEmpty;
    return Column(
      children: [
        _Header(height: RCDims.wideChrome, wide: true, device: device),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 380,
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
                    supportsDynamicIsland: supportsDynamicIsland,
                  ),
                },
              ),
              Container(width: 1, color: RCColors.sep),
              Expanded(
                child: sub
                    ? Material(
                        color: RCColors.bg,
                        child: _stackTopPage(
                          store,
                          wide: true,
                          agentConfig: agentConfig,
                          device: device,
                          modelManager: modelManager,
                          authService: authService,
                        ),
                      )
                    : const _EmptyPane(),
              ),
            ],
          ),
        ),
        const _BottomNav(height: 56),
      ],
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane();

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: Key('empty-pane'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 40, color: RCColors.ax),
          SizedBox(height: 10),
          Text('选择左侧记录查看详情',
              style: TextStyle(fontSize: 13, color: RCColors.sec)),
        ],
      ),
    );
  }
}
