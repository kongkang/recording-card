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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config/remote/model_gateway_config.dart';
import '../core/device/card_gateway.dart';
import '../core/platform/app_info.dart';
import '../core/platform/crash_guard.dart';
import '../core/storage/storage.dart';
import '../core/store/agent_config_store.dart';
import '../core/store/device_store.dart';
import '../core/store/settings_store.dart';
import '../core/theme/tokens.dart';
import '../services/auth_service.dart';
import '../services/health/health_signal_controller.dart';
import '../services/memory/memory_search_scope.dart';
import '../services/photos/photo_library_service.dart';
import '../services/transcribe/asr_models.dart';
import '../services/transcribe/model_manager_controller.dart';
import '../widgets/rc_switch.dart';
import '../widgets/store_scope.dart';
import 'privacy_page.dart';
import 'settings/setting_sub_page.dart';

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
    this.agentConfig,
    this.authService,
    this.photoLibrary,
    this.healthSignals,
    this.supportsDynamicIsland = false,
    this.crashStore,
    this.accountHttpClient,
    this.apiBaseOverride,
  });

  final SettingsStore? settings;

  /// 设备与本机录音状态；供云端账号授权页在退出登录前检查并关闭录音。
  final DeviceStore? device;

  /// 本地转写模型管理；二级页「本地语音引擎」使用。
  final ModelManagerController? modelManager;

  /// Agent 与云端模型设置状态。
  final AgentConfigStore? agentConfig;

  /// 鉴权服务；用于展示外脑与第三方登录授权状态及退出登录。
  final AuthService? authService;

  /// 系统相册权限与对齐导入服务（默认走 PhotoKit 通道）。
  final PhotoLibraryService? photoLibrary;

  /// 本机健康与位置采集。未注入时设置行仍可进入，子页提示服务未装载。
  final HealthSignalController? healthSignals;

  /// 是否显示「灵动岛与操作按钮」（仅支持灵动岛机型显示）。
  final bool supportsDynamicIsland;

  /// 可选注入最近异常记录存储（测试用；生产默认读取 `PrefsStore`）。
  final KeyValueStore? crashStore;

  /// 可选注入 HTTP 客户端（测试验证 `DELETE /api/account` 用）。
  final http.Client? accountHttpClient;

  /// 可选覆盖 API 基址（测试或特殊网关用；为空时取 `agentConfig.customApiBase` 或环境默认网关）。
  final String? apiBaseOverride;

  @override
  State<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends State<SettingPage> {
  /// 是否自建 store（自建的要自己 dispose，注入的归调用方）。
  late final bool _ownsStore = widget.settings == null;
  late final bool _ownsAgent = widget.agentConfig == null;

  late SettingsStore _store;
  late AgentConfigStore _agent;
  String? _photoImportHint;
  CrashRecord? _lastCrash;
  bool _deletingAccount = false;
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

  String _resolvedApiBase() {
    final explicit = widget.apiBaseOverride?.trim() ?? '';
    if (explicit.isNotEmpty) {
      return explicit.endsWith('/')
          ? explicit.substring(0, explicit.length - 1)
          : explicit;
    }
    final custom = _agent.customApiBase.trim();
    if (custom.isNotEmpty) {
      return custom.endsWith('/')
          ? custom.substring(0, custom.length - 1)
          : custom;
    }
    return ModelGatewayConfig.fromEnvironment().baseUrl ??
        'https://block2-api.wainao.chat';
  }

  Future<void> _wipeLocalAccountAndData(BuildContext context) async {
    final appStore = StoreScope.maybeOf(context);
    final memSearch = MemorySearchScope.maybeOf(context);
    try {
      await widget.device?.stopAllRecordingsForSignOut();
    } on Object {
      // 忽略设备断开时停止录音异常
    }
    try {
      await appStore?.wipeAllLocalData();
    } on Object {
      // 忽略本地目录清理异常
    }
    try {
      await memSearch?.close();
    } on Object {
      // 忽略索引关闭异常
    }
    try {
      await widget.healthSignals?.store.close();
    } on Object {
      // 忽略健康库关闭异常
    }
    final isFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');
    if (!isFlutterTest) {
      try {
        final supportDir = await getApplicationSupportDirectory();
        for (final dbName in const [
          'memory_index.db',
          'memory_index.db-wal',
          'memory_index.db-shm',
          'health_signals.db',
          'health_signals.db-wal',
          'health_signals.db-shm',
        ]) {
          final f = File('${supportDir.path}/$dbName');
          if (await f.exists()) {
            await f.delete();
          }
        }
      } on Object {
        // 无原生文件系统路径通道时忽略
      }
    }
    try {
      await _store.resetAll();
      await _agent.resetAll();
      await clearLastCrash(store: widget.crashStore);
    } on Object {
      // 忽略内存偏好清理异常
    }
    if (!isFlutterTest) {
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.clear();
      } on Object {
        // 无平台通道时忽略
      }
    }
    try {
      widget.authService?.signOut();
      await widget.authService?.apiClient.tokenStore.clear();
    } on Object {
      // 忽略令牌清理异常
    }
    if (mounted) {
      setState(() => _lastCrash = null);
    }
  }

  Future<void> _openAccountDeletionFlow(BuildContext context) async {
    if (_deletingAccount) return;
    final auth = widget.authService;
    final signedIn = auth != null && auth.isSignedIn;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('account-delete-confirm-dialog'),
        title: const Text('确认注销账号？'),
        content: Text(
          signedIn
              ? '确认后将向服务端发送账号注销请求（DELETE /api/account），并在服务端确认后永久清除本机登录凭据、录音切片、转写记录、声纹库与本地索引，此操作不可恢复。'
              : '当前未登录云端账号。确认后将永久清空本机全部录音切片、转写记录、声纹库、本地索引与设置；如需注销历史云端账号，请登录后操作或联系 privacy@reai.chat。',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('account-delete-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('account-delete-confirm-btn'),
            style: FilledButton.styleFrom(
              backgroundColor: ctx.rc.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(signedIn ? '确认注销' : '清空本机数据'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    if (!signedIn) {
      await _wipeLocalAccountAndData(context);
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('已清空本机全部数据；如需人工协助注销云端账号请联系 privacy@reai.chat'),
        ),
      );
      return;
    }
    await _executeCloudAccountDeletion(context, auth);
  }

  Future<void> _executeCloudAccountDeletion(
    BuildContext context,
    AuthService auth,
  ) async {
    if (_deletingAccount) return;
    setState(() => _deletingAccount = true);
    final injectedClient = widget.accountHttpClient;
    final client = injectedClient ?? http.Client();
    String? failureReason;
    try {
      final baseUrl = _resolvedApiBase();
      final uri = Uri.parse('$baseUrl/api/account');
      var token = await auth.apiClient.tokenStore.getValidAccessToken();
      var resp = await client
          .delete(
            uri,
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 401) {
        token = await auth.apiClient.tokenStore.refresh();
        resp = await client
            .delete(
              uri,
              headers: <String, String>{
                'Authorization': 'Bearer $token',
                'Accept': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 15));
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (context.mounted) {
          await _wipeLocalAccountAndData(context);
        }
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('账号已注销，本机凭据与数据已全部清除')),
          );
        }
        return;
      }
      failureReason = '服务端返回 HTTP ${resp.statusCode}，云端账号尚未完成注销';
    } on TimeoutException {
      failureReason = '请求超时，未能确认云端账号是否已注销';
    } on Object catch (e) {
      failureReason = '网络或鉴权异常（$e），云端账号尚未完成注销';
    } finally {
      if (injectedClient == null) {
        client.close();
      }
      if (mounted) {
        setState(() => _deletingAccount = false);
      }
    }

    if (!context.mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('account-delete-error-dialog'),
        title: const Text('云端账号注销未完成'),
        content: Text(
          '$failureReason。\n\n'
          '为保障您的数据权利，本应用绝不在服务端未确认成功时假装已注销。'
          '您可以点击「重试」再次发起请求，或先「仅清空本机并退出」，并发送邮件至 privacy@reai.chat 由团队协助完成云端账号注销。',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('account-delete-error-cancel'),
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
          OutlinedButton(
            key: const Key('account-delete-local-only'),
            onPressed: () => Navigator.of(ctx).pop('local'),
            child: const Text('仅清空本机并退出'),
          ),
          FilledButton(
            key: const Key('account-delete-retry'),
            onPressed: () => Navigator.of(ctx).pop('retry'),
            child: const Text('重试'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (action == 'retry') {
      await _executeCloudAccountDeletion(context, auth);
    } else if (action == 'local') {
      await _wipeLocalAccountAndData(context);
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('已清除本机凭据与数据；云端账号注销请联系 privacy@reai.chat'),
        ),
      );
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
        (dev.activeKind == DeviceKind.getSeedGsc10 ||
            dev.activeKind == DeviceKind.omiCv1 ||
            dev.activeKind == DeviceKind.feishuD3200)) {
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
          authService: widget.authService,
          healthSignals: widget.healthSignals,
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

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    var index = 0; // 开关的全局序号：测试锚点 sw-0 … sw-5
    final mm = widget.modelManager;
    final localVal = mm == null ? '本地离线' : mm.settingSummaryLabel;
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
    return ColoredBox(
      // 自己的底色：深色主题下即使外层容器仍是浅色也不会出现「深底浅框」
      color: c.bg,
      child: SingleChildScrollView(
        key: const Key('setting-list'),
        padding: const EdgeInsets.fromLTRB(22, 8, 22, RCDims.pageBottomPad),
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
                _navRow(
                  context,
                  keyName: 'set-cloud-model',
                  label: '云端模型设置',
                  value: _agent.cloudStatusSummary,
                  valueKey: const Key('sv-cloud'),
                  onTap: () => _openSub(context, 'cloud'),
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
                const _RowDivider(),
                _navRow(
                  context,
                  keyName: 'set-developer',
                  label: '开发者设置',
                  value: _agent.developerCleanSummary,
                  valueKey: const Key('sv-developer'),
                  onTap: () => _openSub(context, 'dev'),
                ),
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
                const _RowDivider(),
                _navRow(
                  context,
                  keyName: 'set-ext-hw',
                  label: '第三方硬件联动',
                  value: _extHwSummaryText(),
                  valueKey: const Key('sv-exthw'),
                  onTap: () => _openSub(context, 'exthw'),
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
                  for (var i = 0; i < group.items.length; i++)
                    if (i == 0)
                      _switchRow(context, index++, group.items[i])
                    else ...<Widget>[
                      const _RowDivider(),
                      _switchRow(context, index++, group.items[i]),
                    ],
                  if (group.title == '录音') ...<Widget>[
                    const _RowDivider(),
                    _photoAutoSyncRow(context),
                  ],
                ],
              ),
            ],
            _AboutSection(
              version: _version,
              developerMode: _agent.developerMode,
              onVersionTap: _handleVersionTap,
              lastCrash: _lastCrash,
              onClearCrash: _clearCrashRecord,
              deletingAccount: _deletingAccount,
              onDeleteAccount: () => unawaited(_openAccountDeletionFlow(context)),
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

  /// 拍照数据自动对齐开关行（独立锚点 `set-photo-import` / `sw-photo-sync`，不占用 `sw-0..sw-5`）。
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, height: 1.4, color: context.rc.sec),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.sep),
        borderRadius: BorderRadius.circular(12),
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
    this.deletingAccount = false,
    this.onDeleteAccount,
  });

  final Future<String> version;
  final bool developerMode;
  final VoidCallback? onVersionTap;
  final CrashRecord? lastCrash;
  final VoidCallback? onClearCrash;
  final bool deletingAccount;
  final VoidCallback? onDeleteAccount;

  static const String _body =
      '录音卡与设备保持蓝牙连接，录音内容边录边实时同步到手机，'
      '自动转录并整理为对话记录。内容仅保存在本机，未经确认不会上传。';

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
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
            ),
          ),
        ),
        Container(
          key: const Key('setting-about'),
          decoration: BoxDecoration(
            color: c.card,
            border: Border.all(color: c.sep),
            borderRadius: BorderRadius.circular(12),
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
              const _RowDivider(),
              Semantics(
                container: true,
                button: true,
                enabled: !deletingAccount,
                label: '注销账号',
                onTap: deletingAccount ? null : onDeleteAccount,
                child: ExcludeSemantics(
                  child: GestureDetector(
                    key: const Key('account-delete-entry'),
                    behavior: HitTestBehavior.opaque,
                    onTap: deletingAccount ? null : onDeleteAccount,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                deletingAccount ? '正在注销账号…' : '注销账号',
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.3,
                                  color: c.danger,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (deletingAccount)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            else
                              Icon(
                                Icons.chevron_right,
                                size: 20,
                                color: c.sec,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
