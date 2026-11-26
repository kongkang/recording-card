/// Setting 页 —— 录音 / 转录与清洗 / 同步 三组开关 + 「关于录音卡」。
///
/// 设计真源：prototype/index.html `#p-setting`（组标题 12px 次要说色、分组卡片
/// 12 圆角 + 1px 分隔、开关 50×30、关于段落 13px/1.7）。
///
/// 结构要点：
/// - 状态在 [SettingsStore]（ChangeNotifier），持久化走 KeyValueStore，
///   页面重建/切 Tab 不再复位；
/// - 整行可点（行高 ≥ [RCDims.settingRow]），开关本身不自带手势，避免一次点击触发两次；
/// - 读屏：每行是一个 `Semantics(label: '<名称>开关', toggled: <开/关>, button: true)` 节点；
/// - 颜色全部取 `context.rc`（ThemeExtension 语义色），深色模式自动可读；
/// - 字体不写死 fontFamily（Android 无 SF Pro），字号不锁 textScaler，
///   文字全部可换行，系统字体放大 1.5× 不溢出。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../core/device/card_gateway.dart';
import '../core/platform/app_info.dart';
import '../core/platform/crash_guard.dart';
import '../core/storage/storage.dart';
import '../core/store/agent_config_store.dart';
import '../core/store/device_store.dart';
import '../core/store/membership_store.dart';
import '../core/store/settings_store.dart';
import '../core/store/ui_style_store.dart';
import '../core/theme/tokens.dart';
import '../services/auth_service.dart';
import '../services/external_data/external_data_hub_store.dart';
import '../services/external_data/getnote_sync_store.dart';
import '../services/health/health_signal_controller.dart';
import '../services/media/media_backup_service.dart';
import '../services/net/model_gateway.dart';
import '../services/net/model_provider_store.dart';
import '../services/photos/photo_library_service.dart';
import '../services/transcribe/asr_models.dart';
import '../services/transcribe/model_manager_controller.dart';
import '../widgets/rc_switch.dart';
import '../widgets/store_scope.dart';
import 'privacy_page.dart';
import 'settings/setting_sub_page.dart';
import 'styles/styled_chrome.dart';

class SettingPage extends StatefulWidget {
  /// [settings] / [agentConfig] 可选注入（调用方负责 `await store.load()`）。
  ///
  /// 不传时页面自建：先用内存实现渲染首帧（默认值即原型默认），再异步打开
  /// `PrefsStore` 并 load —— 这样「无参构造」在测试（无平台通道）和真机上都能用。
  const SettingPage({
    super.key,
    this.settings,
    this.device,
    this.modelManager,
    this.modelGateway,
    this.agentConfig,
    this.authService,
    this.photoLibrary,
    this.mediaBackup,
    this.healthSignals,
    this.getNoteStore,
    this.externalDataHub,
    this.supportsDynamicIsland = false,
    this.crashStore,
    this.uiStyle,
    this.membership,
    this.onClearAllLocalData,
  });

  final SettingsStore? settings;

  /// 设备与本机录音状态；供云端账号授权页在退出登录前检查并关闭录音。
  final DeviceStore? device;

  /// 本地转写模型管理；二级页「本地语音引擎」使用。
  final ModelManagerController? modelManager;

  /// 云端模型网关；供「云端模型设置」查看外脑默认端点、可用模型并刷新列表。
  final ModelGateway? modelGateway;

  /// Agent 与云端模型设置状态。
  final AgentConfigStore? agentConfig;

  /// 鉴权服务；用于展示外脑与第三方登录授权状态及退出登录。
  final AuthService? authService;

  /// 系统相册权限与对齐导入服务（默认走 PhotoKit 通道）。
  final PhotoLibraryService? photoLibrary;

  /// 媒体备份协调器（iCloud 同步与本机文件导出状态）。
  final MediaBackupService? mediaBackup;

  /// 本机健康与位置采集。未注入时设置行仍可进入，子页提示服务未装载。
  final HealthSignalController? healthSignals;

  /// 得到大脑 / Get 笔记 OpenAPI 同步控制器。
  final GetNoteSyncStore? getNoteStore;

  /// 其他第三方笔记、阅读与录音软件 API 接入控制中心。
  final ExternalDataHubStore? externalDataHub;

  /// 是否显示「灵动岛与操作按钮」（仅支持灵动岛机型显示）。
  final bool supportsDynamicIsland;

  /// 可选注入最近异常记录存储（测试用；生产默认读取 `PrefsStore`）。
  final KeyValueStore? crashStore;

  /// 可选界面风格状态控制器（缺省通过 [UIStyleScope.maybeOf] 读取）。
  final UIStyleStore? uiStyle;

  /// 会员与本地月度额度状态（缺省通过 [MembershipScope.maybeOf] 读取）。
  final MembershipStore? membership;

  /// 清空本机全部用户数据的全量编排回调（由 `AppShell` 注入，空时回落内置清理）。
  final Future<void> Function()? onClearAllLocalData;

  @override
  State<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends State<SettingPage> {
  /// 是否自建 store（自建的要自己 dispose，注入的归调用方）。
  late final bool _ownsStore = widget.settings == null;
  late final bool _ownsAgent = widget.agentConfig == null;
  late final bool _ownsGetNoteStore =
      widget.getNoteStore == null &&
      Platform.environment.containsKey('FLUTTER_TEST');
  late final bool _ownsExternalDataHub =
      widget.externalDataHub == null &&
      Platform.environment.containsKey('FLUTTER_TEST');

  late SettingsStore _store;
  late AgentConfigStore _agent;
  late final GetNoteSyncStore _getNoteStore =
      widget.getNoteStore ??
      (_ownsGetNoteStore
          ? GetNoteSyncStore(
              secureStore: InMemorySecureStore(),
              prefsStore: InMemoryStore(),
            )
          : GetNoteSyncStore.instance);
  late final ExternalDataHubStore _externalDataHub =
      widget.externalDataHub ??
      (_ownsExternalDataHub
          ? ExternalDataHubStore(
              secureStore: InMemorySecureStore(),
              prefsStore: InMemoryStore(),
            )
          : ExternalDataHubStore.instance);
  String? _photoImportHint;
  String? _hwAlbumHint;
  CrashRecord? _lastCrash;
  int _versionTapCount = 0;
  DateTime? _lastVersionTapAt;

  /// 版本号只读一次（FutureBuilder 每帧重建不该重复走平台通道）。
  ///
  /// 版本来源：`core/platform/app_info.dart` 的 `appVersion()`——它内部用
  /// `package_info_plus` 读构建产物（版本名 + 构建号），失败降级为「未知版本」。
  late final Future<String> _version = appVersion();

  @override
  void initState() {
    super.initState();
    final injected = widget.settings;
    if (injected != null) {
      _store = injected..addListener(_onStoreChanged);
    } else {
      _store = SettingsStore(store: InMemoryStore())
        ..addListener(_onStoreChanged);
      unawaited(_openPersistentStore());
    }

    final injectedAgent = widget.agentConfig;
    if (injectedAgent != null) {
      _agent = injectedAgent..addListener(_onStoreChanged);
    } else {
      _agent = AgentConfigStore(store: InMemoryStore())
        ..addListener(_onStoreChanged);
      unawaited(_openPersistentAgentStore());
    }

    final mm = widget.modelManager;
    if (mm != null) {
      mm.addListener(_onStoreChanged);
      if (!mm.hasStatuses) {
        unawaited(mm.refresh());
      }
    }
    widget.authService?.addListener(_onStoreChanged);
    widget.device?.addListener(_onStoreChanged);
    widget.healthSignals?.addListener(_onStoreChanged);
    unawaited(_getNoteStore.load());
    unawaited(_externalDataHub.load());
    unawaited(_loadLastCrash());
  }

  @override
  void didUpdateWidget(SettingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device != widget.device) {
      oldWidget.device?.removeListener(_onStoreChanged);
      widget.device?.addListener(_onStoreChanged);
    }
    if (oldWidget.healthSignals != widget.healthSignals) {
      oldWidget.healthSignals?.removeListener(_onStoreChanged);
      widget.healthSignals?.addListener(_onStoreChanged);
    }
    if (oldWidget.crashStore != widget.crashStore) {
      unawaited(_loadLastCrash());
    }
  }

  Future<void> _loadLastCrash() async {
    try {
      final rec = await readLastCrash(store: widget.crashStore);
      if (mounted) {
        setState(() => _lastCrash = rec);
      }
    } on Object {
      // 无平台通道时静默忽略
    }
  }

  Future<void> _clearCrashRecord() async {
    try {
      await clearLastCrash(store: widget.crashStore);
    } on Object {
      // ignore
    }
    if (mounted) {
      setState(() => _lastCrash = null);
    }
  }

  /// 自建路径：打开 shared_preferences 并读回已保存的值。
  ///
  /// 失败（如 widget 测试没有平台通道）只打日志并保留内存实现：
  /// 本次运行内开关照样能切，只是不落盘。
  Future<void> _openPersistentStore() async {
    // 用户可能在存储就绪前就点了开关：把这些改动搬到持久化实现上，避免回退
    final carried = <String, bool>{
      for (final key in _store.touchedKeys) key: _store.value(key),
    };
    SettingsStore next;
    try {
      next = SettingsStore(store: await PrefsStore.open());
      await next.load();
      for (final e in carried.entries) {
        await next.setValue(e.key, e.value);
      }
    } catch (e) {
      debugPrint('[setting] 打开本地存储失败，本次运行设置不落盘: $e');
      return;
    }
    if (!mounted) {
      next.dispose();
      return;
    }
    setState(() {
      _store.removeListener(_onStoreChanged);
      _store.dispose();
      _store = next..addListener(_onStoreChanged);
    });
  }

  Future<void> _openPersistentAgentStore() async {
    AgentConfigStore next;
    try {
      next = AgentConfigStore(store: await PrefsStore.open());
      await next.load();
    } catch (_) {
      return;
    }
    if (!mounted) {
      next.dispose();
      return;
    }
    setState(() {
      _agent.removeListener(_onStoreChanged);
      _agent.dispose();
      _agent = next..addListener(_onStoreChanged);
    });
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.healthSignals?.removeListener(_onStoreChanged);
    widget.device?.removeListener(_onStoreChanged);
    widget.authService?.removeListener(_onStoreChanged);
    widget.modelManager?.removeListener(_onStoreChanged);
    _store.removeListener(_onStoreChanged);
    if (_ownsStore) _store.dispose();
    _agent.removeListener(_onStoreChanged);
    if (_ownsAgent) _agent.dispose();
    if (_ownsGetNoteStore) _getNoteStore.dispose();
    if (_ownsExternalDataHub) _externalDataHub.dispose();
    super.dispose();
  }

  String _watchSummaryText() {
    if (!_agent.watchLinkEnabled) return '未开启';
    final dev = widget.device;
    if (dev != null) {
      if (dev.isConnected && dev.activeKind == DeviceKind.appleWatch) {
        return '已连接';
      }
      if (dev.watchHardware.currentStatus.paired) {
        return '已配对';
      }
    }
    return '已开启';
  }

  String _extHwSummaryText() {
    final count = _agent.enabledExtHardwareCount;
    if (count == 0) return '未开启';
    final dev = widget.device;
    if (dev != null &&
        dev.isConnected &&
        (dev.activeKind == DeviceKind.omiCv1 ||
            dev.activeKind == DeviceKind.feishuD3200 ||
            dev.activeKind == DeviceKind.iflytekA1)) {
      return '已连接 ${dev.activeKind.displayModel}';
    }
    return '已开启 $count 款';
  }

  String _healthSummaryText() {
    final signals = widget.healthSignals;
    if (signals == null || !_agent.healthSignalEnabled) return '已关闭';
    return '已开启 · ${signals.sampleCount} 条';
  }

  void _toggle(String key) => unawaited(_store.toggle(key));

  void _openSub(BuildContext context, String subId) {
    final appStore = StoreScope.maybeOf(context);
    if (appStore != null) {
      appStore.openSettingSub(subId);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingSubPage(
          subId: subId,
          agentConfig: _agent,
          device: widget.device,
          modelManager: widget.modelManager,
          modelGateway: widget.modelGateway,
          authService: widget.authService,
          healthSignals: widget.healthSignals,
          mediaBackup: widget.mediaBackup,
          getNoteStore: _getNoteStore,
          externalDataHub: _externalDataHub,
          uiStyle: widget.uiStyle ?? UIStyleScope.maybeOf(context),
          membership: widget.membership ?? MembershipScope.maybeOf(context),
          onClearAllLocalData: widget.onClearAllLocalData,
          standalone: true,
        ),
      ),
    );
  }

  void _handleVersionTap() {
    final now = DateTime.now();
    if (_lastVersionTapAt != null &&
        now.difference(_lastVersionTapAt!).inMilliseconds > 1600) {
      _versionTapCount = 0;
    }
    _lastVersionTapAt = now;
    _versionTapCount += 1;
    if (_versionTapCount >= 7) {
      _versionTapCount = 0;
      final next = !_agent.developerMode;
      unawaited(_agent.setDeveloperMode(next));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(next ? '已开启开发者模式' : '已关闭开发者模式'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _togglePhotoSync(BuildContext context) async {
    if (_agent.photoLinkEnabled) {
      if (mounted) {
        setState(() => _photoImportHint = null);
      }
      await _agent.setPhotoLinkEnabled(false);
      return;
    }

    final photoLib = widget.photoLibrary ?? const PhotoLibraryService();
    var status = await photoLib.checkPermission();
    if (status != PhotoPermissionState.granted) {
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('photo-perm-dialog'),
          title: const Text('开启系统相册访问权限'),
          content: const Text(
            '开启后将在每分钟录音切片入库及停录时，在本地自动匹配该时段照片，无需手动导入，原始照片不上传云端。',
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('photo-perm-cancel'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('photo-perm-grant'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('前往授权'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      status = await photoLib.requestPermission();
      if (status != PhotoPermissionState.granted) {
        if (!mounted) return;
        setState(() => _photoImportHint = '未获得相册权限');
        return;
      }
    }

    if (mounted) {
      setState(() => _photoImportHint = null);
    }
    await _agent.setPhotoLinkEnabled(true);
    if (!context.mounted) return;
    final appStore = StoreScope.maybeOf(context);
    if (appStore == null) return;
    appStore.photoLibrary = photoLib;
    final added = await appStore.syncPhotosAutomatically(recentOnly: false);
    if (!mounted) return;
    if (added > 0) {
      setState(() {
        _photoImportHint = '已开启 · 已自动对齐 $added 张照片';
      });
    }
  }

  Future<void> _toggleHwAlbumSave(BuildContext context) async {
    if (_agent.saveHardwareMediaToAlbum) {
      if (mounted) {
        setState(() => _hwAlbumHint = null);
      }
      await _agent.setSaveHardwareMediaToAlbum(false);
      return;
    }

    final photoLib = widget.photoLibrary ?? const PhotoLibraryService();
    var status = await photoLib.checkAddPermission();
    if (status != PhotoPermissionState.granted) {
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('hw-album-perm-dialog'),
          title: const Text('允许存入系统相册'),
          content: const Text(
            '开启后，点一机等硬件拍摄的照片与视频会自动保存到系统「照片」相册，防止卸载 App 后数据丢失。',
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('hw-album-perm-cancel'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('hw-album-perm-grant'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('前往授权'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      status = await photoLib.requestAddPermission();
      if (status != PhotoPermissionState.granted) {
        if (!mounted) return;
        setState(() => _hwAlbumHint = '未获得相册写入权限');
        return;
      }
    }

    if (mounted) {
      setState(() => _hwAlbumHint = null);
    }
    await _agent.setSaveHardwareMediaToAlbum(true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    var index = 0; // 开关的全局序号：测试锚点 sw-0 … sw-5
    final mm = widget.modelManager;
    final localVal = switch (mm?.effectiveAsrMode) {
      'system' => '系统转写',
      'sensevoice' => '增强转写',
      'pending' => '待下载',
      _ => '本地离线',
    };
    final voiceVal = mm == null
        ? '本地聚类'
        : (mm.statusFor(campplusEmbeddingSpec)?.installed == true
              ? '已就绪'
              : '待安装');
    final auth = widget.authService;
    final authVal = auth == null
        ? '外脑 OAuth'
        : (auth.isSignedIn
              ? (auth.session?.account.isNotEmpty == true
                    ? auth.session!.account
                    : '已授权')
              : '未登录');
    final styleStore = widget.uiStyle ?? UIStyleScope.maybeOf(context);
    final memStore = widget.membership ?? MembershipScope.maybeOf(context);
    final activeStyleName =
        styleStore?.activeDescriptor.name ??
        UIStyleDescriptor.byId(RCUIStyleId.warmPaper).name;
    return ColoredBox(
      // 自己的底色：深色主题下即使外层容器仍是浅色也不会出现「深底浅框」
      color: c.bg,
      child: SingleChildScrollView(
        key: const Key('setting-list'),
        padding: EdgeInsets.fromLTRB(
          22,
          8,
          22,
          styledListBottomPadding(
            context.rcStyle.styleId,
            bottomInset: MediaQuery.paddingOf(context).bottom,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _GroupTitle(text: '账号与云端鉴权'),
            _GroupCard(
              children: <Widget>[
                _navRow(
                  context,
                  keyName: 'set-auth-entry',
                  label: '云端账号授权',
                  value: authVal,
                  valueKey: const Key('sv-auth'),
                  onTap: () => _openSub(context, 'login'),
                ),
                const _RowDivider(),
                if (memStore != null)
                  ListenableBuilder(
                    listenable: memStore,
                    builder: (context, _) => _navRow(
                      context,
                      keyName: 'set-membership',
                      label: '会员与订阅',
                      value: memStore.settingRowSummary(),
                      valueKey: const Key('sv-membership'),
                      onTap: () => _openSub(context, 'membership'),
                    ),
                  )
                else
                  _navRow(
                    context,
                    keyName: 'set-membership',
                    label: '会员与订阅',
                    value: '免费版',
                    valueKey: const Key('sv-membership'),
                    onTap: () => _openSub(context, 'membership'),
                  ),
              ],
            ),
            const _GroupTitle(text: '界面外观'),
            _GroupCard(
              children: <Widget>[
                if (styleStore != null)
                  ListenableBuilder(
                    listenable: styleStore,
                    builder: (context, _) => _navRow(
                      context,
                      keyName: 'set-ui-style',
                      label: '界面风格',
                      value: styleStore.activeDescriptor.name,
                      valueKey: const Key('sv-ui-style'),
                      onTap: () => _openSub(context, 'style'),
                    ),
                  )
                else
                  _navRow(
                    context,
                    keyName: 'set-ui-style',
                    label: '界面风格',
                    value: activeStyleName,
                    valueKey: const Key('sv-ui-style'),
                    onTap: () => _openSub(context, 'style'),
                  ),
              ],
            ),
            const _GroupTitle(text: '模型与智能体'),
            _GroupCard(
              children: <Widget>[
                _navRow(
                  context,
                  keyName: 'set-local-model',
                  label: '本地语音引擎',
                  value: localVal,
                  valueKey: const Key('sv-local'),
                  onTap: () => _openSub(context, 'local'),
                ),
                const _RowDivider(),
                ListenableBuilder(
                  listenable: ModelProviderStore.instance,
                  builder: (context, _) => _navRow(
                    context,
                    keyName: 'set-cloud-model',
                    label: '云端模型设置',
                    value: _agent.cloudEnabled
                        ? ModelProviderStore.instance.activeProvider.label
                        : '请选择服务',
                    valueKey: const Key('sv-cloud'),
                    onTap: () => _openSub(context, 'cloud'),
                  ),
                ),
                const _RowDivider(),
                _navRow(
                  context,
                  keyName: 'set-prompts',
                  label: '预设风格与提示词',
                  value: _agent.presetLabel,
                  valueKey: const Key('sv-preset'),
                  onTap: () => _openSub(context, 'prompts'),
                ),
                const _RowDivider(),
                _navRow(
                  context,
                  keyName: 'set-voiceprint',
                  label: '声纹识别',
                  value: voiceVal,
                  valueKey: const Key('sv-voiceprint'),
                  onTap: () => _openSub(context, 'voiceprint'),
                ),
                const _RowDivider(),
                _navRow(
                  context,
                  keyName: 'set-extensions',
                  label: '扩展能力',
                  value: '已勾选 ${_agent.enabledExtensionCount} 项',
                  valueKey: const Key('sv-ext'),
                  onTap: () => _openSub(context, 'ext'),
                ),
                const _RowDivider(),
                _navRow(
                  context,
                  keyName: 'set-memory-search',
                  label: '本机记忆检索',
                  value: '仅本机',
                  valueKey: const Key('sv-memory'),
                  onTap: () => _openSub(context, 'mem'),
                ),
                if (_agent.developerMode) ...<Widget>[
                  const _RowDivider(),
                  _navRow(
                    context,
                    keyName: 'set-developer',
                    label: '开发者设置',
                    value: _agent.developerCleanSummary,
                    valueKey: const Key('sv-developer'),
                    onTap: () => _openSub(context, 'dev'),
                  ),
                ],
                if (widget.supportsDynamicIsland) ...<Widget>[
                  const _RowDivider(),
                  _navRow(
                    context,
                    keyName: 'set-dynamic-island',
                    label: '灵动岛与操作按钮',
                    value: _agent.islandEnabled ? '已开启' : '已关闭',
                    valueKey: const Key('sv-island'),
                    onTap: () => _openSub(context, 'island'),
                  ),
                ],
              ],
            ),
            const _GroupTitle(text: '硬件设备联动'),
            _GroupCard(
              children: <Widget>[
                _navRow(
                  context,
                  keyName: 'set-apple-watch',
                  label: 'Apple Watch 联动',
                  value: _watchSummaryText(),
                  valueKey: const Key('sv-watch'),
                  onTap: () => _openSub(context, 'watch'),
                ),
              ],
            ),
            const _GroupTitle(text: '第三方数据接入'),
            _GroupCard(
              children: <Widget>[
                _navRow(
                  context,
                  keyName: 'set-ext-hw',
                  label: '第三方硬件 SDK',
                  value: _extHwSummaryText(),
                  valueKey: const Key('sv-exthw'),
                  onTap: () => _openSub(context, 'exthw'),
                ),
                const _RowDivider(),
                ListenableBuilder(
                  listenable: Listenable.merge([
                    _getNoteStore,
                    _externalDataHub,
                  ]),
                  builder: (context, _) => _navRow(
                    context,
                    keyName: 'set-ext-api',
                    label: '第三方 API 接入',
                    value: _externalDataHub.unifiedSummaryText(
                      getNoteStore: _getNoteStore,
                    ),
                    valueKey: const Key('sv-extapi'),
                    onTap: () => _openSub(context, 'extapi'),
                  ),
                ),
              ],
            ),
            const _GroupTitle(text: '行为与健康信号'),
            _GroupCard(
              children: <Widget>[
                _navRow(
                  context,
                  keyName: 'set-health-location',
                  label: '定位与健康采集',
                  value: _healthSummaryText(),
                  valueKey: const Key('sv-health'),
                  onTap: () => _openSub(context, 'health'),
                ),
              ],
            ),
            for (final group in SettingsStore.groups) ...<Widget>[
              _GroupTitle(text: group.title),
              _GroupCard(
                children: <Widget>[
                  if (group.title == '同步') ...<Widget>[
                    _localOnlyModeRow(context),
                    const _RowDivider(),
                  ],
                  for (var i = 0; i < group.items.length; i++)
                    if (i == 0)
                      _switchRow(context, index++, group.items[i])
                    else ...<Widget>[
                      const _RowDivider(),
                      _switchRow(context, index++, group.items[i]),
                    ],
                  if (group.title == '同步') ...<Widget>[
                    const _RowDivider(),
                    _photoAutoSyncRow(context),
                    const _RowDivider(),
                    _hardwareAlbumSaveRow(context),
                    const _RowDivider(),
                    _navRow(
                      context,
                      keyName: 'set-icloud-sync',
                      label: 'iCloud 同步与本机文件',
                      value: _agent.icloudSyncSummary,
                      valueKey: const Key('sv-icloud-sync'),
                      onTap: () => _openSub(context, 'icloud'),
                    ),
                  ],
                  if (group.title == '转录与清洗') ...<Widget>[
                    const _RowDivider(),
                    _transcribeCycleRow(context),
                  ],
                ],
              ),
            ],
            const _GroupTitle(text: '数据管理'),
            _GroupCard(
              children: <Widget>[
                _navRow(
                  context,
                  keyName: 'set-data-management',
                  label: '数据管理',
                  value: '清空本机数据',
                  valueKey: const Key('sv-data-management'),
                  onTap: () => _openSub(context, 'data'),
                ),
              ],
            ),
            _AboutSection(
              version: _version,
              developerMode: _agent.developerMode,
              onVersionTap: _handleVersionTap,
              lastCrash: _lastCrash,
              onClearCrash: _clearCrashRecord,
            ),
          ],
        ),
      ),
    );
  }

  Widget _navRow(
    BuildContext context, {
    required String keyName,
    required String label,
    required String value,
    Key? valueKey,
    required VoidCallback onTap,
  }) {
    final c = context.rc;
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          key: Key(keyName),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: RCDims.settingRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.3,
                        color: c.label,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      value,
                      key: valueKey,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 13, color: c.sec),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 18, color: c.ax),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 批量转写与整理周期行（独立锚点 `set-transcribe-cycle`，不占用 `sw-0..sw-5`）。
  Widget _transcribeCycleRow(BuildContext context) {
    final c = context.rc;
    return Semantics(
      container: true,
      button: true,
      label: '批量转写与整理周期',
      onTap: () => unawaited(_showTranscribeCycleSheet(context)),
      child: ExcludeSemantics(
        child: GestureDetector(
          key: const Key('set-transcribe-cycle'),
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_showTranscribeCycleSheet(context)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: RCDims.settingRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '批量转写与整理周期',
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.3,
                            color: c.label,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '切片先静默存盘，到达周期或查看时统一转写归拢',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: c.sec,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _agent.transcribeCycleLabel,
                    key: const Key('sv-transcribe-cycle'),
                    style: TextStyle(fontSize: 13, color: c.sec),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 18, color: c.ax),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTranscribeCycleSheet(BuildContext context) async {
    const options = <(int minutes, String title, String subtitle)>[
      (15, '每 15 分钟（推荐）', '平衡电耗与信息及时性，查看或停录时也会立即补齐'),
      (30, '每 30 分钟', '减少唤醒频次，适合长时间连续办公/会议'),
      (60, '每 60 分钟', '最大程度节省电量，主要在查看或停录时汇总整理'),
    ];
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: context.rc.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) {
        final c = sheetCtx.rc;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '批量转写与整理周期',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: c.label,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '录音期间切片静默存盘，避免 1 分钟碎片；到达周期、切回查看或停止录音时统一转写并按活动归拢。',
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: c.sec),
                ),
                const SizedBox(height: 12),
                for (final opt in options)
                  ListTile(
                    key: Key('cycle-opt-${opt.$1}'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    title: Text(
                      opt.$2,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: _agent.transcribeCycleMinutes == opt.$1
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: c.label,
                      ),
                    ),
                    subtitle: Text(
                      opt.$3,
                      style: TextStyle(fontSize: 12, color: c.sec),
                    ),
                    trailing: _agent.transcribeCycleMinutes == opt.$1
                        ? Icon(Icons.check_circle, color: sheetCtx.rc.ok)
                        : null,
                    onTap: () => Navigator.of(sheetCtx).pop(opt.$1),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null) return;
    await _agent.setTranscribeCycleMinutes(picked);
    if (!context.mounted) return;
    final appStore = StoreScope.maybeOf(context);
    if (appStore != null) {
      appStore.transcribeCycleMinutes = picked;
    }
  }

  /// 拍照数据自动对齐开关行（独立锚点 `set-photo-import` / `sw-photo-sync`，不占用 `sw-0..sw-5`）。
  Widget _localOnlyModeRow(BuildContext context) {
    final c = context.rc;
    final on = _agent.localOnlyMode;
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      enabled: true,
      label: '仅本机模式开关',
      onTap: () => unawaited(_agent.setLocalOnlyMode(!on)),
      child: ExcludeSemantics(
        child: GestureDetector(
          key: const Key('set-privacy-lock-row'),
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_agent.setLocalOnlyMode(!on)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: RCDims.settingRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '仅本机模式',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.3,
                        color: c.label,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    key: const Key('sw-privacy-lock'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => unawaited(_agent.setLocalOnlyMode(!on)),
                    child: RCSwitch(on: on),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _photoAutoSyncRow(BuildContext context) {
    final c = context.rc;
    final on = _agent.photoLinkEnabled;
    final subtitle = _photoImportHint ?? (on ? '已开启 · 每分钟随切片自动对齐' : '已关闭');
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      enabled: true,
      label: '关联录音期间相册照片开关',
      onTap: () => unawaited(_togglePhotoSync(context)),
      child: ExcludeSemantics(
        child: GestureDetector(
          key: const Key('set-photo-import'),
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_togglePhotoSync(context)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: RCDims.settingRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '关联录音期间相册照片',
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.3,
                            color: c.label,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          key: const Key('sv-photo-import'),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: c.sec,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  KeyedSubtree(
                    key: const Key('sw-photo-sync'),
                    child: RCSwitch(on: on),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hardwareAlbumSaveRow(BuildContext context) {
    final c = context.rc;
    final on = _agent.saveHardwareMediaToAlbum;
    final subtitle =
        _hwAlbumHint ?? (on ? '已开启 · 点一机拍照与录像默认存入系统相册' : '已关闭 · 仅保存在 App 内');
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      enabled: true,
      label: '硬件照片与视频存入系统相册开关',
      onTap: () => unawaited(_toggleHwAlbumSave(context)),
      child: ExcludeSemantics(
        child: GestureDetector(
          key: const Key('set-hw-album-save'),
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_toggleHwAlbumSave(context)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: RCDims.settingRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '硬件照片与视频存入系统相册',
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.3,
                            color: c.label,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          key: const Key('sv-hw-album-save'),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: c.sec,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  KeyedSubtree(
                    key: const Key('sw-hw-album-save'),
                    child: RCSwitch(on: on),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 一行开关：整行可点 + 读屏开关语义。
  Widget _switchRow(BuildContext context, int index, SettingsSwitchItem item) {
    final c = context.rc;
    final on = _store.value(item.key);
    return Semantics(
      container: true,
      button: true,
      toggled: on,
      // 自绘开关不带系统语义，启用状态必须显式声明：
      // 不声明时读屏/自动化会把整行当成"不可用"，而它其实点得动。
      enabled: true,
      label: item.semanticLabel,
      onTap: () => _toggle(item.key),
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggle(item.key),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: RCDims.settingRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: <Widget>[
                  // Flexible + 可换行：字体放大时不挤压、不溢出
                  Expanded(
                    child: Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.3,
                        color: c.label,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 测试锚点：Key('sw-0')…Key('sw-5')，包裹开关视觉（AnimatedContainer），
                  // 保持与旧实现一致的「keyed 祖先 + AnimatedContainer 后代」结构
                  KeyedSubtree(
                    key: Key('sw-$index'),
                    child: RCSwitch(on: on),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 分组标题（原型 `.set-title`）。
class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = context.rcStyle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: context.rc.sec,
          fontFamilyFallback: s.serifTitles
              ? rcSerifFontFallback
              : rcFontFallback,
        ),
      ),
    );
  }
}

/// 分组卡片容器（原型 `.set-group`）。
class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final s = context.rcStyle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: c.card,
        border: s.styleId == RCUIStyleId.air ? null : Border.all(color: c.sep),
        borderRadius: BorderRadius.circular(s.cardRadius),
        boxShadow: s.cardShadow,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(height: 1, thickness: 1, color: context.rc.sep);
  }
}

/// 「关于录音卡」段落：说明文字 + 版本号 + 隐私政策入口。
///
/// 文案语义对齐原型：与设备保持蓝牙连接、边录边实时同步、自动转录整理为
/// 对话记录、内容仅保存在本机、未经确认不会上传。
class _AboutSection extends StatelessWidget {
  const _AboutSection({
    required this.version,
    this.developerMode = false,
    this.onVersionTap,
    this.lastCrash,
    this.onClearCrash,
  });

  final Future<String> version;
  final bool developerMode;
  final VoidCallback? onVersionTap;
  final CrashRecord? lastCrash;
  final VoidCallback? onClearCrash;

  static const String _body =
      '录音卡与设备保持蓝牙连接，录音内容边录边实时同步到手机，'
      '自动转录并整理为对话记录。内容仅保存在本机，未经确认不会上传。';

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final s = context.rcStyle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 24, 2, 8),
          child: Text(
            '关于录音卡',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: c.label,
              fontFamilyFallback: s.serifTitles
                  ? rcSerifFontFallback
                  : rcFontFallback,
            ),
          ),
        ),
        Container(
          key: const Key('setting-about'),
          decoration: BoxDecoration(
            color: c.card,
            border: s.styleId == RCUIStyleId.air
                ? null
                : Border.all(color: c.sep),
            borderRadius: BorderRadius.circular(s.cardRadius),
            boxShadow: s.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Text(
                  _body,
                  style: TextStyle(fontSize: 13, height: 1.7, color: c.sec),
                ),
              ),
              const _RowDivider(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onVersionTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          developerMode ? '版本（开发者）' : '版本',
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.3,
                            color: c.label,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: FutureBuilder<String>(
                          future: version,
                          builder: (context, snap) {
                            final text = snap.data ?? '读取中…';
                            return Text(
                              text,
                              key: const Key('setting-version'),
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.3,
                                color: c.sec,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (lastCrash != null) ...<Widget>[
                const _RowDivider(),
                Padding(
                  key: const Key('setting-last-crash'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '最近异常诊断',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: c.label,
                              ),
                            ),
                          ),
                          if (onClearCrash != null)
                            TextButton(
                              key: const Key('setting-last-crash-clear'),
                              onPressed: onClearCrash,
                              style: TextButton.styleFrom(
                                foregroundColor: c.sec,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                '已了解',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        lastCrash!.summary,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: c.sec,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const _RowDivider(),
              _PrivacyEntry(color: c),
            ],
          ),
        ),
      ],
    );
  }
}

/// 隐私政策入口（点进 PrivacyPage）。
class _PrivacyEntry extends StatelessWidget {
  const _PrivacyEntry({required this.color});

  final RCColorScheme color;

  void _open(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const PrivacyPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      label: '隐私政策',
      // 读屏双击走语义动作；视觉点击走下面的 GestureDetector，两者互不重复触发
      onTap: () => _open(context),
      child: ExcludeSemantics(
        child: GestureDetector(
          key: const Key('privacy-entry'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(context),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '隐私政策',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        color: color.label,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right, size: 20, color: color.sec),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
