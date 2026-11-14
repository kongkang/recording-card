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

import 'package:flutter/material.dart';

import '../core/platform/app_info.dart';
import '../core/storage/storage.dart';
import '../core/store/agent_config_store.dart';
import '../core/store/device_store.dart';
import '../core/store/settings_store.dart';
import '../core/theme/tokens.dart';
import '../services/auth_service.dart';
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
    this.supportsDynamicIsland = false,
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

  /// 是否显示「灵动岛与操作按钮」（仅支持灵动岛机型显示）。
  final bool supportsDynamicIsland;

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
    widget.authService?.removeListener(_onStoreChanged);
    widget.modelManager?.removeListener(_onStoreChanged);
    _store.removeListener(_onStoreChanged);
    if (_ownsStore) _store.dispose();
    _agent.removeListener(_onStoreChanged);
    if (_ownsAgent) _agent.dispose();
    super.dispose();
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
    final localVal = mm == null
        ? '3 个端侧模型'
        : (mm.allReady ? '已就绪 · 3 项' : '待补齐');
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
                  value: '已启用 ${_agent.enabledExtensionCount} 项',
                  valueKey: const Key('sv-ext'),
                  onTap: () => _openSub(context, 'ext'),
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
    final subtitle =
        _photoImportHint ?? (on ? '已开启 · 每分钟随切片自动对齐' : '已关闭');
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
  });

  final Future<String> version;
  final bool developerMode;
  final VoidCallback? onVersionTap;

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

