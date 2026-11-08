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
import '../core/store/settings_store.dart';
import '../core/theme/tokens.dart';
import '../services/transcribe/asr_models.dart';
import '../services/transcribe/model_manager_controller.dart';
import 'privacy_page.dart';

class SettingPage extends StatefulWidget {
  /// [settings] 可选注入（调用方负责 `await store.load()`）。
  ///
  /// 不传时页面自建：先用内存实现渲染首帧（默认值即原型默认），再异步打开
  /// `PrefsStore` 并 load —— 这样「无参构造」在测试（无平台通道）和真机上都能用。
  const SettingPage({super.key, this.settings, this.modelManager});

  final SettingsStore? settings;

  /// 本地转写模型管理；null 时不展示模型区块（旧测试/预览）。
  final ModelManagerController? modelManager;

  @override
  State<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends State<SettingPage> {
  /// 是否自建 store（自建的要自己 dispose，注入的归调用方）。
  late final bool _ownsStore = widget.settings == null;

  late SettingsStore _store;

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

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    if (_ownsStore) _store.dispose();
    super.dispose();
  }

  void _toggle(String key) => unawaited(_store.toggle(key));

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    var index = 0; // 开关的全局序号：测试锚点 sw-0 … sw-5
    return ColoredBox(
      // 自己的底色：深色主题下即使外层容器仍是浅色也不会出现「深底浅框」
      color: c.bg,
      child: ListView(
        key: const Key('setting-list'),
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 40),
        children: <Widget>[
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
              ],
            ),
          ],
          if (widget.modelManager != null)
            _ModelSection(controller: widget.modelManager!),
          _AboutSection(version: _version),
        ],
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
                    child: _RCSwitch(on: on),
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

/// 自绘开关（原型 `.sw`：50×30 轨道 + 24 圆点，150ms 过渡）。
///
/// 不自带手势（整行负责点击），只做视觉 + 状态动画；
/// `AnimatedContainer` 是本页的视觉锚点，深/浅色都由语义色决定。
class _RCSwitch extends StatelessWidget {
  const _RCSwitch({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 50,
      height: 30,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: on ? c.switchTrackOn : c.ax,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: c.switchThumb,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// 「关于录音卡」段落：说明文字 + 版本号 + 隐私政策入口。
///
/// 文案语义对齐原型：与设备保持蓝牙连接、边录边实时同步、自动转录整理为
/// 对话记录、内容仅保存在本机、未经确认不会上传。
class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.version});

  final Future<String> version;

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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '版本',
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

/// 「本地转写模型」区块：状态 / 下载 / 删除 / 进度。
///
/// 模型体积大（SenseVoice ~230MB），只在用户点「下载」时走网络；VAD 随包，
/// 首次安装时复制。地址未配置时明确提示，不假装可用。
class _ModelSection extends StatefulWidget {
  const _ModelSection({required this.controller});

  final ModelManagerController controller;

  @override
  State<_ModelSection> createState() => _ModelSectionState();
}

class _ModelSectionState extends State<_ModelSection> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _GroupTitle(text: '本地转写模型'),
            _GroupCard(
              children: [
                for (var i = 0; i < controller.specs.length; i++) ...[
                  if (i > 0) const _RowDivider(),
                  _row(context, controller.specs[i]),
                ],
                const _RowDivider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              controller.allReady
                                  ? '本地转写已就绪'
                                  : (controller.configured
                                      ? '本地模型未安装，无法转录'
                                      : '模型下载服务未配置'),
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: c.sec,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton(
                            key: const Key('model-install-all'),
                            onPressed:
                                controller.busy || !controller.configured
                                ? null
                                : () => unawaited(controller.installAll()),
                            child: Text(
                              controller.allReady ? '重新下载' : '下载',
                            ),
                          ),
                        ],
                      ),
                      if (controller.busy) ...[
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          value: controller.progress > 0 ? controller.progress : null,
                          minHeight: 4,
                          backgroundColor: c.sep,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          controller.text,
                          key: const Key('model-progress-text'),
                          style: TextStyle(fontSize: 12, color: c.sec),
                        ),
                      ],
                      if (controller.error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          controller.error!,
                          key: const Key('model-error'),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: c.danger,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, ModelSpec spec) {
    final c = context.rc;
    final status = widget.controller.statusFor(spec);
    final installed = status?.installed ?? false;
    return Padding(
      key: Key('model-row-${spec.id}'),
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spec.displayName,
                  style: TextStyle(fontSize: 15, height: 1.3, color: c.label),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_kindLabel(spec.kind)} · ${installed ? _bytes(status?.presentBytes ?? 0) : _expectedSize(spec)}',
                  style: TextStyle(fontSize: 12, color: c.sec),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (installed)
            TextButton(
              key: Key('model-delete-${spec.id}'),
              onPressed: widget.controller.busy
                  ? null
                  : () => unawaited(widget.controller.delete(spec)),
              child: const Text('删除'),
            )
          else
            Text(
              spec.bundled ? '随包' : '未安装',
              style: TextStyle(fontSize: 12, color: c.sec),
            ),
        ],
      ),
    );
  }

  static String _kindLabel(LocalModelKind kind) => switch (kind) {
    LocalModelKind.asr => '语音转写',
    LocalModelKind.vad => '语音活动检测',
    LocalModelKind.speakerSegmentation => '声纹分割',
    LocalModelKind.speakerEmbedding => '声纹识别',
  };

  static String _expectedSize(ModelSpec spec) {
    if (spec.id == sileroVadSpec.id) return '随包安装';
    if (spec.id == senseVoiceSpec.id) return '约 230MB';
    if (spec.id == campplusEmbeddingSpec.id) return '约 27MB';
    return spec.totalBytes > 0 ? _bytes(spec.totalBytes) : '未知大小';
  }

  static String _bytes(int bytes) {
    if (bytes <= 0) return '—';
    final mb = bytes / (1024 * 1024);
    return mb >= 100 ? '${mb.toStringAsFixed(0)}MB' : '${mb.toStringAsFixed(1)}MB';
  }
}
