/// 设置 → 第三方数据接入 → 第三方 API 接入（全量扁平列表与单源极简配置页）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/store/app_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/external_data/external_connector.dart';
import '../../services/external_data/external_data_hub_store.dart';
import '../../services/external_data/getnote_sync_store.dart';
import '../../widgets/rc_switch.dart';
import '../../widgets/store_scope.dart';

/// 统一时间格式化：`YYYY-MM-DD HH:mm`。
String formatExternalEpoch(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final mm = dt.month.toString().padLeft(2, '0');
  final dd = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '${dt.year}-$mm-$dd $hh:$min';
}

/// Apple Settings 风格分组白卡（跟随主题深浅色）。
class ExternalApiSectionCard extends StatelessWidget {
  const ExternalApiSectionCard({super.key, required this.child, this.cardKey});

  final Widget child;
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Container(
      key: cardKey,
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.sep),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class ExternalApiHairlineDivider extends StatelessWidget {
  const ExternalApiHairlineDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: 16,
    endIndent: 16,
    color: context.rc.sep,
  );
}

/// 统一输入框：浅灰底无重描边 + 上方小字标题，兼顾深浅模式。
class ExternalApiLabeledField extends StatelessWidget {
  const ExternalApiLabeledField({
    super.key,
    required this.fieldKey,
    required this.label,
    required this.controller,
    this.hint,
    this.helperText,
    this.enabled = true,
    this.obscureText = false,
    this.suffixIcon,
    this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? helperText;
  final bool enabled;
  final bool obscureText;
  final Widget? suffixIcon;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: c.sec,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: fieldKey,
          controller: controller,
          enabled: enabled,
          obscureText: obscureText,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: onChanged,
          style: TextStyle(fontSize: 14, color: c.label),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 13.5, color: c.sec),
            isDense: true,
            filled: true,
            fillColor: c.bg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c.sep),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c.sep),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c.label, width: 1.2),
            ),
            suffixIcon: suffixIcon,
          ),
        ),
        if (helperText != null && helperText!.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            helperText!,
            style: TextStyle(fontSize: 11.5, height: 1.4, color: c.sec),
          ),
        ],
      ],
    );
  }
}

/// 等宽双按钮操作条（测试连接 + 立即同步），同步中下方展开「停止同步」。
class ExternalApiActionButtons extends StatelessWidget {
  const ExternalApiActionButtons({
    super.key,
    required this.testKey,
    required this.syncKey,
    this.cancelKey,
    required this.busy,
    required this.testing,
    required this.syncing,
    required this.cancelling,
    required this.syncLabel,
    required this.onTest,
    required this.onSync,
    this.onCancel,
  });

  final Key testKey;
  final Key syncKey;
  final Key? cancelKey;
  final bool busy;
  final bool testing;
  final bool syncing;
  final bool cancelling;
  final String syncLabel;
  final VoidCallback onTest;
  final VoidCallback onSync;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 44,
                child: OutlinedButton(
                  key: testKey,
                  onPressed: busy ? null : onTest,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.label,
                    side: BorderSide(color: c.sep),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: Text(
                    testing ? '测试中…' : '测试连接',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 44,
                child: FilledButton(
                  key: syncKey,
                  onPressed: busy ? null : onSync,
                  style: FilledButton.styleFrom(
                    backgroundColor: c.label,
                    foregroundColor: c.onLabel,
                    disabledBackgroundColor: c.ax,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: Text(
                    syncLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (syncing && onCancel != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: OutlinedButton(
              key: cancelKey,
              onPressed: cancelling ? null : onCancel,
              style: OutlinedButton.styleFrom(
                foregroundColor: c.label,
                side: BorderSide(color: c.sep),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                cancelling ? '正在停止…' : '停止同步',
                style: const TextStyle(fontSize: 13.5),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 单行开关设置项（整行可点击）。
class ExternalApiSwitchTile extends StatelessWidget {
  const ExternalApiSwitchTile({
    super.key,
    required this.rowKey,
    required this.switchKey,
    required this.title,
    required this.subtitle,
    required this.value,
    this.semanticsLabel,
    this.disabled = false,
    this.switchBusy = false,
    required this.onTap,
  });

  final Key rowKey;
  final Key switchKey;
  final String title;
  final String subtitle;
  final bool value;
  final String? semanticsLabel;
  final bool disabled;
  final bool switchBusy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Semantics(
      container: true,
      button: true,
      toggled: value,
      label: semanticsLabel ?? title,
      onTap: disabled ? null : onTap,
      child: GestureDetector(
        key: rowKey,
        behavior: HitTestBehavior.opaque,
        onTap: disabled ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                        color: c.label,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: c.sec,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ExcludeSemantics(
                child: RCSwitch(
                  key: switchKey,
                  on: value,
                  busy: switchBusy,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 键值信息状卡片（连接状态、已导入条数、同步时间与结果提示）。
class ExternalApiStatusCard extends StatelessWidget {
  const ExternalApiStatusCard({
    super.key,
    required this.cardKey,
    required this.connLabel,
    required this.connColor,
    required this.importedCount,
    this.lastSyncAtMs,
    this.lastAutoCheckAtMs,
    this.syncing = false,
    this.statusMessage,
    this.lastSyncSummary,
    this.errorMessage,
  });

  final Key cardKey;
  final String connLabel;
  final Color connColor;
  final int importedCount;
  final int? lastSyncAtMs;
  final int? lastAutoCheckAtMs;
  final bool syncing;
  final String? statusMessage;
  final String? lastSyncSummary;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final noteText = syncing
        ? statusMessage
        : (statusMessage ?? lastSyncSummary);
    final noteColor = syncing
        ? c.ink
        : (statusMessage != null ? c.okInk : c.sec);

    return ExternalApiSectionCard(
      cardKey: cardKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _kvRow(
            context,
            label: '连接状态',
            value: connLabel,
            valueColor: connColor,
            boldValue: true,
          ),
          const ExternalApiHairlineDivider(),
          _kvRow(
            context,
            label: '已导入',
            value: '已导入 $importedCount 条',
            valueColor: c.label,
            boldValue: true,
          ),
          if (lastSyncAtMs != null) ...[
            const ExternalApiHairlineDivider(),
            _kvRow(
              context,
              label: '上次同步',
              value: formatExternalEpoch(lastSyncAtMs!),
              valueColor: c.sec,
            ),
          ],
          if (lastAutoCheckAtMs != null) ...[
            const ExternalApiHairlineDivider(),
            _kvRow(
              context,
              label: '上次自动检查',
              value: formatExternalEpoch(lastAutoCheckAtMs!),
              valueColor: c.sec,
            ),
          ],
          if (noteText != null && noteText.trim().isNotEmpty) ...[
            const ExternalApiHairlineDivider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Text(
                noteText,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: noteColor),
              ),
            ),
          ],
          if (errorMessage != null && errorMessage!.trim().isNotEmpty) ...[
            const ExternalApiHairlineDivider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Text(
                errorMessage!,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: c.danger),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kvRow(
    BuildContext context, {
    required String label,
    required String value,
    required Color valueColor,
    bool boldValue = false,
  }) {
    final c = context.rc;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Text(label, style: TextStyle(fontSize: 13.5, color: c.sec)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: boldValue ? FontWeight.w600 : FontWeight.w400,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「第三方 API 接入」扁平列表：无二次分组，直接列出 Get 笔记与 11 款笔记/阅读/录音 API。
class ExternalApiListBody extends StatefulWidget {
  const ExternalApiListBody({
    super.key,
    required this.getNoteStore,
    required this.hubStore,
    this.appStore,
    this.onOpenSub,
  });

  final GetNoteSyncStore getNoteStore;
  final ExternalDataHubStore hubStore;
  final AppStore? appStore;
  final ValueChanged<String>? onOpenSub;

  @override
  State<ExternalApiListBody> createState() => _ExternalApiListBodyState();
}

class _ExternalApiListBodyState extends State<ExternalApiListBody> {
  bool _checkingAll = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAll());
  }

  Future<void> _loadAll() async {
    await Future.wait([widget.getNoteStore.load(), widget.hubStore.load()]);
  }

  void _openItem(BuildContext context, String subId) {
    final appStore = widget.appStore ?? StoreScope.maybeOf(context);
    if (appStore != null) {
      appStore.openSettingSub(subId, fresh: false);
      return;
    }
    widget.onOpenSub?.call(subId);
  }

  Future<void> _checkAllDue(BuildContext context) async {
    final appStore = widget.appStore ?? StoreScope.maybeOf(context);
    if (appStore == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('时间轴存储未装载，请从主界面进入后重试')),
      );
      return;
    }
    setState(() => _checkingAll = true);
    try {
      var ran = 0;
      final gnRes = await widget.getNoteStore.runAutoCheckIfDue(
        appStore: appStore,
        force: true,
      );
      if (gnRes != null) ran += 1;
      final hubRes = await widget.hubStore.runAutoCheckIfDue(
        appStore: appStore,
        force: true,
      );
      ran += hubRes.length;
      if (!context.mounted) return;
      final msg = ran == 0 ? '暂无已配置且开启自动导入的数据源' : '已完成 $ran 项自动导入源检查';
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _checkingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.getNoteStore, widget.hubStore]),
      builder: (context, _) {
        final gn = widget.getNoteStore;
        final hub = widget.hubStore;
        final connectors = hub.allConnectors;
        final autoCount = hub.totalAutoEnabledCount(getNoteStore: gn);

        final gnActive = gn.autoImport || gn.importedCount > 0 || gn.connectionVerified;
        final gnDotColor = gn.syncing
            ? c.info
            : (gn.autoImport || gn.importedCount > 0 || gn.connectionVerified
                  ? c.ok
                  : (gn.hasCredentials ? c.warn : null));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExternalApiSectionCard(
              cardKey: const Key('ext-api-list-card'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _apiListRow(
                    context,
                    rowKey: const Key('ext-api-row-getnote'),
                    valueKey: const Key('ext-api-val-getnote'),
                    title: 'Get 笔记',
                    value: ExternalDataHubStore.getNoteCompactStatusText(gn),
                    dotColor: gnDotColor,
                    highlightValue: gnActive || gn.syncing,
                    onTap: () => _openItem(context, 'extdata'),
                  ),
                  for (final conn in connectors) ...[
                    const ExternalApiHairlineDivider(),
                    Builder(
                      builder: (context) {
                        final st = hub.stateFor(conn.id);
                        final hasCfg = hub.hasRequiredConfig(conn.id);
                        final isActive =
                            st.autoImport ||
                            st.importedCount > 0 ||
                            st.connectionVerified;
                        final dotColor = st.syncing
                            ? c.info
                            : (isActive ? c.ok : (hasCfg ? c.warn : null));
                        return _apiListRow(
                          context,
                          rowKey: Key('ext-api-row-${conn.id}'),
                          valueKey: Key('ext-api-val-${conn.id}'),
                          title: conn.name,
                          value: hub.compactStatusTextFor(conn.id),
                          dotColor: dotColor,
                          highlightValue: isActive || st.syncing,
                          onTap: () => _openItem(context, 'extapi:${conn.id}'),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      autoCount > 0
                          ? '已开启 $autoCount 项每小时自动检查与导入'
                          : '支持全量翻页导入与每小时自动检查，凭据仅存本机密钥库',
                      style: TextStyle(fontSize: 12, color: c.sec),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const Key('ext-check-all'),
                    onPressed: _checkingAll
                        ? null
                        : () => unawaited(_checkAllDue(context)),
                    style: TextButton.styleFrom(
                      foregroundColor: c.label,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: Text(_checkingAll ? '检查中…' : '立即检查'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _apiListRow(
    BuildContext context, {
    required Key rowKey,
    required Key valueKey,
    required String title,
    required String value,
    required Color? dotColor,
    required bool highlightValue,
    required VoidCallback onTap,
  }) {
    final c = context.rc;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: rowKey,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: RCDims.settingRow),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                if (dotColor != null) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: c.label,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    value,
                    key: valueKey,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: highlightValue
                          ? FontWeight.w500
                          : FontWeight.w400,
                      color: highlightValue ? c.okInk : c.sec,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: c.ax),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个第三方 API 接入源的极简配置详情页（与 Get 笔记共享完全一致的视觉规范）。
class ExternalConnectorDetailBody extends StatefulWidget {
  const ExternalConnectorDetailBody({
    super.key,
    required this.store,
    required this.connectorId,
    this.appStore,
  });

  final ExternalDataHubStore store;
  final String connectorId;
  final AppStore? appStore;

  @override
  State<ExternalConnectorDetailBody> createState() =>
      _ExternalConnectorDetailBodyState();
}

class _ExternalConnectorDetailBodyState
    extends State<ExternalConnectorDetailBody> {
  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, bool> _showSecret = {};
  bool _dirty = false;
  bool _seeded = false;

  ExternalDataHubStore get _store => widget.store;
  ExternalDataConnector? get _conn => _store.connectorById(widget.connectorId);

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    _syncControllersFromStore();
    unawaited(_loadStore());
  }

  Future<void> _loadStore() async {
    await _store.load();
    if (!mounted) return;
    _syncControllersFromStore();
    setState(() {});
  }

  @override
  void didUpdateWidget(ExternalConnectorDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != _store ||
        oldWidget.connectorId != widget.connectorId) {
      oldWidget.store.removeListener(_onStoreChanged);
      _store.addListener(_onStoreChanged);
      _disposeControllers();
      _showSecret.clear();
      _dirty = false;
      _seeded = false;
      _syncControllersFromStore();
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _disposeControllers();
    super.dispose();
  }

  void _disposeControllers() {
    for (final ctrl in _ctrls.values) {
      ctrl.dispose();
    }
    _ctrls.clear();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    _syncControllersFromStore();
    setState(() {});
  }

  TextEditingController _ctrlFor(ExternalFieldSpec field) {
    return _ctrls.putIfAbsent(field.key, () {
      final stored = _store.stateFor(widget.connectorId).config[field.key] ?? '';
      return TextEditingController(
        text: stored.isNotEmpty ? stored : field.defaultValue,
      );
    });
  }

  void _syncControllersFromStore() {
    final conn = _conn;
    if (conn == null) return;
    if (_dirty && _seeded) return;
    final cfg = _store.stateFor(conn.id).config;
    if (cfg.isNotEmpty) {
      for (final f in conn.fields) {
        if (f.options.isNotEmpty || f.isBoolean) continue;
        final ctrl = _ctrlFor(f);
        final val = cfg[f.key] ?? f.defaultValue;
        if (ctrl.text != val) ctrl.text = val;
      }
      _seeded = true;
    }
  }

  Map<String, String> _collectConfig(ExternalDataConnector conn) {
    final current = Map<String, String>.from(_store.stateFor(conn.id).config);
    for (final f in conn.fields) {
      if (f.options.isNotEmpty || f.isBoolean) {
        final v = (current[f.key] ?? '').trim();
        current[f.key] = v.isNotEmpty ? v : f.defaultValue;
      } else {
        current[f.key] = _ctrlFor(f).text.trim();
      }
    }
    return current;
  }

  Future<void> _setFieldChoice(
    ExternalDataConnector conn,
    String key,
    String value,
  ) async {
    final next = _collectConfig(conn);
    next[key] = value;
    await _store.saveConfig(conn.id, next);
  }

  Future<void> _handleTest(ExternalDataConnector conn) async {
    _dirty = false;
    await _store.testConnection(conn.id, pendingConfig: _collectConfig(conn));
  }

  Future<void> _handleSync(
    BuildContext context,
    ExternalDataConnector conn,
  ) async {
    final appStore = widget.appStore ?? StoreScope.maybeOf(context);
    if (appStore == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('时间轴存储未装载，请从主界面进入后重试')),
      );
      return;
    }
    _dirty = false;
    await _store.syncConnector(
      conn.id,
      appStore: appStore,
      pendingConfig: _collectConfig(conn),
    );
  }

  Future<void> _handleAutoToggle(
    BuildContext context,
    ExternalDataConnector conn,
  ) async {
    final appStore = widget.appStore ?? StoreScope.maybeOf(context);
    if (_dirty) {
      _dirty = false;
      await _store.saveConfig(conn.id, _collectConfig(conn));
    }
    final current = _store.stateFor(conn.id).autoImport;
    await _store.setAutoImport(conn.id, !current, appStore: appStore);
  }

  Future<void> _handleClear(ExternalDataConnector conn) async {
    _dirty = false;
    _seeded = false;
    for (final f in conn.fields) {
      if (f.options.isNotEmpty || f.isBoolean) continue;
      _ctrlFor(f).text = f.defaultValue;
    }
    await _store.clearConnector(conn.id);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final conn = _conn;
    if (conn == null) {
      return Text('未找到接入源配置', style: TextStyle(color: c.sec));
    }

    final st = _store.stateFor(conn.id);
    final busy = st.testing || st.syncing;
    final hasConfig = _store.hasRequiredConfig(conn.id);
    final cfgResolved = _store.resolvedConfigFor(conn.id);
    final connLabel = !hasConfig
        ? '未配置'
        : (st.connectionVerified ? '已连接' : '待验证');
    final connColor = !hasConfig
        ? c.sec
        : (st.connectionVerified ? c.okInk : c.label);

    final nonBoolFields = [
      for (final f in conn.fields)
        if (!f.isBoolean) f,
    ];
    final boolFields = [
      for (final f in conn.fields)
        if (f.isBoolean) f,
    ];

    final syncLabel = !st.syncing
        ? '立即同步'
        : (st.syncCurrentPage > 0
              ? '第 ${st.syncCurrentPage} 页 · ${st.syncFetchedCount} 条'
              : '同步中…');

    return Column(
      key: Key('ext-conn-${conn.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          conn.subtitle,
          style: TextStyle(fontSize: 13, height: 1.45, color: c.sec),
        ),
        const SizedBox(height: 14),
        ExternalApiSectionCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final f in nonBoolFields) ...[
                  if (f.options.isNotEmpty)
                    _buildSegmentedField(context, conn, f, cfgResolved, busy)
                  else
                    _buildTextField(conn, f, busy),
                  const SizedBox(height: 12),
                ],
                ExternalApiActionButtons(
                  testKey: Key('ext-test-${conn.id}'),
                  syncKey: Key('ext-sync-${conn.id}'),
                  cancelKey: Key('ext-cancel-${conn.id}'),
                  busy: busy,
                  testing: st.testing,
                  syncing: st.syncing,
                  cancelling: st.cancelling,
                  syncLabel: syncLabel,
                  onTest: () => unawaited(_handleTest(conn)),
                  onSync: () => unawaited(_handleSync(context, conn)),
                  onCancel: () => _store.cancelSync(conn.id),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        ExternalApiSectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final f in boolFields) ...[
                ExternalApiSwitchTile(
                  rowKey: Key('ext-bool-row-${conn.id}-${f.key}'),
                  switchKey: Key('ext-bool-${conn.id}-${f.key}'),
                  title: f.label,
                  subtitle: f.helperText ?? '同步范围选项',
                  value: (cfgResolved[f.key] ?? f.defaultValue) == 'true',
                  disabled: busy,
                  switchBusy: busy,
                  onTap: () {
                    final cur =
                        (cfgResolved[f.key] ?? f.defaultValue) == 'true';
                    unawaited(
                      _setFieldChoice(conn, f.key, cur ? 'false' : 'true'),
                    );
                  },
                ),
                const ExternalApiHairlineDivider(),
              ],
              ExternalApiSwitchTile(
                rowKey: Key('ext-auto-row-${conn.id}'),
                switchKey: Key('ext-auto-${conn.id}'),
                title: '开启后自动导入（每小时检查）',
                subtitle: '每 ${st.checkIntervalMinutes} 分钟检查新增与变更并全量翻页补齐',
                value: st.autoImport,
                disabled: st.testing,
                switchBusy: st.testing,
                onTap: () => unawaited(_handleAutoToggle(context, conn)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ExternalApiStatusCard(
          cardKey: Key('ext-status-${conn.id}'),
          connLabel: connLabel,
          connColor: connColor,
          importedCount: st.importedCount,
          lastSyncAtMs: st.lastSyncAtMs,
          lastAutoCheckAtMs: st.lastAutoCheckAtMs,
          syncing: st.syncing,
          statusMessage: st.statusMessage,
          lastSyncSummary: st.lastSyncSummary,
          errorMessage: st.errorMessage,
        ),
        if (hasConfig || st.config.isNotEmpty) ...[
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              key: Key('ext-clear-${conn.id}'),
              onPressed: busy ? null : () => unawaited(_handleClear(conn)),
              style: TextButton.styleFrom(foregroundColor: c.danger),
              child: const Text(
                '清除配置',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSegmentedField(
    BuildContext context,
    ExternalDataConnector conn,
    ExternalFieldSpec f,
    Map<String, String> cfgResolved,
    bool busy,
  ) {
    final c = context.rc;
    final current = cfgResolved[f.key] ?? f.defaultValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          f.label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: c.sec,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.sep),
          ),
          child: Row(
            children: [
              for (final opt in f.options)
                Expanded(
                  child: GestureDetector(
                    key: Key('ext-opt-${conn.id}-${f.key}-${opt.value}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: busy
                        ? null
                        : () => unawaited(
                            _setFieldChoice(conn, f.key, opt.value),
                          ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      padding: const EdgeInsets.symmetric(
                        vertical: 7,
                        horizontal: 8,
                      ),
                      decoration: BoxDecoration(
                        color: current == opt.value
                            ? c.label
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        opt.label,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: current == opt.value ? c.onLabel : c.ink,
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

  Widget _buildTextField(
    ExternalDataConnector conn,
    ExternalFieldSpec f,
    bool busy,
  ) {
    final show = _showSecret[f.key] ?? false;
    return ExternalApiLabeledField(
      fieldKey: Key('ext-field-${conn.id}-${f.key}'),
      label: f.label,
      controller: _ctrlFor(f),
      hint: f.hint,
      helperText: f.helperText,
      enabled: !busy,
      obscureText: f.isSecret && !show,
      onChanged: (_) => _dirty = true,
      suffixIcon: f.isSecret
          ? IconButton(
              tooltip: show ? '隐藏' : '显示',
              icon: Icon(
                show ? Icons.visibility_off : Icons.visibility,
                size: 18,
              ),
              onPressed: () {
                setState(() => _showSecret[f.key] = !show);
              },
            )
          : null,
    );
  }
}
