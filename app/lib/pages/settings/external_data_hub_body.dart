/// 设置 → 第三方数据接入（笔记与阅读软件 / 第三方录音软件 API 配置、无限翻页同步与每小时自动导入）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/store/app_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/external_data/external_connector.dart';
import '../../services/external_data/external_data_hub_store.dart';
import '../../widgets/rc_switch.dart';
import '../../widgets/store_scope.dart';

class ExternalDataHubBody extends StatefulWidget {
  const ExternalDataHubBody({
    super.key,
    required this.store,
    required this.category,
    this.appStore,
  });

  final ExternalDataHubStore store;
  final ExternalConnectorCategory category;
  final AppStore? appStore;

  @override
  State<ExternalDataHubBody> createState() => _ExternalDataHubBodyState();
}

class _ExternalDataHubBodyState extends State<ExternalDataHubBody> {
  final Map<String, Map<String, TextEditingController>> _ctrls = {};
  final Map<String, bool> _dirty = {};
  final Map<String, bool> _seeded = {};
  final Map<String, Map<String, bool>> _showSecret = {};
  final Set<String> _expanded = {};
  bool _checkingAll = false;

  ExternalDataHubStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    final list = _store.connectorsFor(widget.category);
    if (list.isNotEmpty) {
      // 默认展开第一个或已有配置的接入源
      var anyConfigured = false;
      for (final c in list) {
        if (_store.hasRequiredConfig(c.id)) {
          _expanded.add(c.id);
          anyConfigured = true;
        }
      }
      if (!anyConfigured) {
        _expanded.add(list.first.id);
      }
    }
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
  void didUpdateWidget(ExternalDataHubBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != _store) {
      oldWidget.store.removeListener(_onStoreChanged);
      _store.addListener(_onStoreChanged);
      _dirty.clear();
      _seeded.clear();
      _syncControllersFromStore();
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    for (final map in _ctrls.values) {
      for (final ctrl in map.values) {
        ctrl.dispose();
      }
    }
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    _syncControllersFromStore();
    setState(() {});
  }

  TextEditingController _ctrlFor(String connectorId, ExternalFieldSpec field) {
    final byField = _ctrls.putIfAbsent(connectorId, () => {});
    return byField.putIfAbsent(field.key, () {
      final stored = _store.stateFor(connectorId).config[field.key] ?? '';
      return TextEditingController(
        text: stored.isNotEmpty ? stored : field.defaultValue,
      );
    });
  }

  void _syncControllersFromStore() {
    for (final c in _store.connectorsFor(widget.category)) {
      if ((_dirty[c.id] ?? false) && (_seeded[c.id] ?? false)) continue;
      final cfg = _store.stateFor(c.id).config;
      if (cfg.isNotEmpty) {
        for (final f in c.fields) {
          if (f.options.isNotEmpty || f.isBoolean) continue;
          final ctrl = _ctrlFor(c.id, f);
          final val = cfg[f.key] ?? f.defaultValue;
          if (ctrl.text != val) ctrl.text = val;
        }
        _seeded[c.id] = true;
      }
    }
  }

  Map<String, String> _collectConfig(ExternalDataConnector c) {
    final current = Map<String, String>.from(_store.stateFor(c.id).config);
    for (final f in c.fields) {
      if (f.options.isNotEmpty || f.isBoolean) {
        final v = (current[f.key] ?? '').trim();
        current[f.key] = v.isNotEmpty ? v : f.defaultValue;
      } else {
        current[f.key] = _ctrlFor(c.id, f).text.trim();
      }
    }
    return current;
  }

  Future<void> _setFieldChoice(
    ExternalDataConnector c,
    String key,
    String value,
  ) async {
    final next = _collectConfig(c);
    next[key] = value;
    await _store.saveConfig(c.id, next);
  }

  Future<void> _handleTest(ExternalDataConnector c) async {
    _dirty[c.id] = false;
    await _store.testConnection(c.id, pendingConfig: _collectConfig(c));
  }

  Future<void> _handleSync(BuildContext context, ExternalDataConnector c) async {
    final appStore = widget.appStore ?? StoreScope.maybeOf(context);
    if (appStore == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('时间轴存储未装载，请从主界面进入后重试')),
      );
      return;
    }
    _dirty[c.id] = false;
    await _store.syncConnector(
      c.id,
      appStore: appStore,
      pendingConfig: _collectConfig(c),
    );
  }

  Future<void> _handleAutoToggle(
    BuildContext context,
    ExternalDataConnector c,
  ) async {
    final appStore = widget.appStore ?? StoreScope.maybeOf(context);
    if (_dirty[c.id] == true) {
      _dirty[c.id] = false;
      await _store.saveConfig(c.id, _collectConfig(c));
    }
    final current = _store.stateFor(c.id).autoImport;
    await _store.setAutoImport(c.id, !current, appStore: appStore);
  }

  Future<void> _handleClear(ExternalDataConnector c) async {
    _dirty[c.id] = false;
    _seeded[c.id] = false;
    for (final f in c.fields) {
      if (f.options.isNotEmpty || f.isBoolean) continue;
      _ctrlFor(c.id, f).text = f.defaultValue;
    }
    await _store.clearConnector(c.id);
  }

  Future<void> _handleCheckAllDue(BuildContext context) async {
    final appStore = widget.appStore ?? StoreScope.maybeOf(context);
    if (appStore == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('时间轴存储未装载，请从主界面进入后重试')),
      );
      return;
    }
    setState(() => _checkingAll = true);
    try {
      final results = await _store.runAutoCheckIfDue(
        appStore: appStore,
        category: widget.category,
        force: true,
      );
      if (!context.mounted) return;
      final msg = results.isEmpty
          ? '当前分类下暂无已配置且开启自动导入的接入源'
          : '已检查 ${results.length} 个开启自动导入的接入源';
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _checkingAll = false);
    }
  }

  String _formatEpoch(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-$mm-$dd $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final connectors = _store.connectorsFor(widget.category);
    final autoCount = _store.autoEnabledCount(widget.category);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${widget.category.subtitle}。所有接口均支持持续翻页拉取全部历史数据，'
          '密钥仅保存在本机系统密钥库（Keychain）。',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: c.sec),
        ),
        const SizedBox(height: 12),
        Container(
          key: Key('ext-auto-overview-${widget.category.name}'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.sep),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '每小时自动检查与导入',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: c.label,
                      ),
                    ),
                  ),
                  Text(
                    '已开启 $autoCount 项',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: autoCount > 0 ? c.ok : c.sec,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '在任意接入源开启「自动导入」后，系统会每 60 分钟自动检查一次新增或变更记录并翻页同步。',
                style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                key: Key('ext-check-all-${widget.category.name}'),
                onPressed: _checkingAll
                    ? null
                    : () => unawaited(_handleCheckAllDue(context)),
                child: Text(_checkingAll ? '正在检查…' : '立即检查已开启源'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final conn in connectors) ...[
          _buildConnectorCard(context, conn),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildConnectorCard(
    BuildContext context,
    ExternalDataConnector conn,
  ) {
    final c = context.rc;
    final st = _store.stateFor(conn.id);
    final isExpanded = _expanded.contains(conn.id);
    final busy = st.testing || st.syncing;
    final hasConfig = _store.hasRequiredConfig(conn.id);
    final connLabel = !hasConfig
        ? '未配置'
        : (st.connectionVerified ? '已连接' : '待验证');
    final connColor = !hasConfig
        ? c.sec
        : (st.connectionVerified ? c.ok : c.ink);
    final statusBadge = _store.statusTextFor(conn.id);
    final cfgResolved = _store.resolvedConfigFor(conn.id);

    return Container(
      key: Key('ext-conn-${conn.id}'),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.sep),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: Key('ext-conn-toggle-${conn.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expanded.remove(conn.id);
                } else {
                  _expanded.add(conn.id);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              conn.name,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: c.label,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: c.bg,
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(color: c.sep),
                              ),
                              child: Text(
                                conn.protocolBadge,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: c.sec,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          conn.subtitle,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: c.sec,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        statusBadge,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: st.autoImport || st.importedCount > 0
                              ? c.ok
                              : c.sec,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: c.sec,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded) ...[
            Divider(height: 1, color: c.sep),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    conn.setupGuide,
                    style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
                  ),
                  const SizedBox(height: 10),
                  for (final f in conn.fields) ...[
                    _buildFieldInput(context, conn, f, cfgResolved, busy),
                    const SizedBox(height: 10),
                  ],
                  GestureDetector(
                    key: Key('ext-auto-row-${conn.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: st.testing
                        ? null
                        : () => unawaited(_handleAutoToggle(context, conn)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '开启后自动导入（每小时检查）',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: c.label,
                                  ),
                                ),
                                Text(
                                  '每 ${st.checkIntervalMinutes} 分钟检查更新并全量翻页补齐',
                                  style: TextStyle(fontSize: 11.5, color: c.sec),
                                ),
                              ],
                            ),
                          ),
                          ExcludeSemantics(
                            child: RCSwitch(
                              key: Key('ext-auto-${conn.id}'),
                              on: st.autoImport,
                              busy: st.testing,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton(
                        key: Key('ext-test-${conn.id}'),
                        onPressed: busy
                            ? null
                            : () => unawaited(_handleTest(conn)),
                        child: Text(st.testing ? '测试中…' : '测试连接'),
                      ),
                      FilledButton(
                        key: Key('ext-sync-${conn.id}'),
                        onPressed: busy
                            ? null
                            : () => unawaited(_handleSync(context, conn)),
                        child: Text(
                          !st.syncing
                              ? '立即同步'
                              : (st.syncCurrentPage > 0
                                    ? '第 ${st.syncCurrentPage} 页 · ${st.syncFetchedCount} 条…'
                                    : '同步中…'),
                        ),
                      ),
                      if (st.syncing)
                        OutlinedButton(
                          key: Key('ext-cancel-${conn.id}'),
                          onPressed: st.cancelling
                              ? null
                              : () => _store.cancelSync(conn.id),
                          child: Text(st.cancelling ? '正在停止…' : '停止同步'),
                        ),
                      if (hasConfig || st.config.isNotEmpty)
                        TextButton(
                          key: Key('ext-clear-${conn.id}'),
                          onPressed: busy
                              ? null
                              : () => unawaited(_handleClear(conn)),
                          style: TextButton.styleFrom(
                            foregroundColor: c.danger,
                          ),
                          child: const Text('清除配置'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    key: Key('ext-status-${conn.id}'),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: c.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.sep),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '连接状态：$connLabel',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: connColor,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '已导入 ${st.importedCount} 条',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: c.label,
                              ),
                            ),
                          ],
                        ),
                        if (st.lastSyncAtMs != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            '上次同步：${_formatEpoch(st.lastSyncAtMs!)}',
                            style: TextStyle(fontSize: 11.5, color: c.sec),
                          ),
                        ],
                        if (st.lastAutoCheckAtMs != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            '上次自动检查：${_formatEpoch(st.lastAutoCheckAtMs!)}',
                            style: TextStyle(fontSize: 11.5, color: c.sec),
                          ),
                        ],
                        if (st.syncing && st.statusMessage != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            st.statusMessage!,
                            style: TextStyle(
                              fontSize: 12,
                              color: c.ink,
                              height: 1.35,
                            ),
                          ),
                        ] else if (st.statusMessage != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            st.statusMessage!,
                            style: TextStyle(
                              fontSize: 12,
                              color: c.ok,
                              height: 1.35,
                            ),
                          ),
                        ] else if (st.lastSyncSummary != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            st.lastSyncSummary!,
                            style: TextStyle(
                              fontSize: 12,
                              color: c.sec,
                              height: 1.35,
                            ),
                          ),
                        ],
                        if (st.errorMessage != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            st.errorMessage!,
                            style: TextStyle(
                              fontSize: 12,
                              color: c.danger,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFieldInput(
    BuildContext context,
    ExternalDataConnector conn,
    ExternalFieldSpec f,
    Map<String, String> cfgResolved,
    bool busy,
  ) {
    final c = context.rc;
    if (f.options.isNotEmpty) {
      final current = cfgResolved[f.key] ?? f.defaultValue;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            f.label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.label,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final opt in f.options)
                ChoiceChip(
                  key: Key('ext-opt-${conn.id}-${f.key}-${opt.value}'),
                  label: Text(opt.label),
                  selected: current == opt.value,
                  onSelected: busy
                      ? null
                      : (_) => unawaited(_setFieldChoice(conn, f.key, opt.value)),
                ),
            ],
          ),
        ],
      );
    }

    if (f.isBoolean) {
      final current = (cfgResolved[f.key] ?? f.defaultValue) == 'true';
      return GestureDetector(
        key: Key('ext-bool-row-${conn.id}-${f.key}'),
        behavior: HitTestBehavior.opaque,
        onTap: busy
            ? null
            : () => unawaited(
                _setFieldChoice(conn, f.key, current ? 'false' : 'true'),
              ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.label,
                      ),
                    ),
                    if (f.helperText != null)
                      Text(
                        f.helperText!,
                        style: TextStyle(fontSize: 11.5, color: c.sec),
                      ),
                  ],
                ),
              ),
              ExcludeSemantics(
                child: RCSwitch(
                  key: Key('ext-bool-${conn.id}-${f.key}'),
                  on: current,
                  busy: busy,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final show = _showSecret[conn.id]?[f.key] ?? false;
    return TextField(
      key: Key('ext-field-${conn.id}-${f.key}'),
      controller: _ctrlFor(conn.id, f),
      enabled: !busy,
      obscureText: f.isSecret && !show,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: (_) => _dirty[conn.id] = true,
      decoration: InputDecoration(
        labelText: f.label,
        hintText: f.hint,
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: f.isSecret
            ? IconButton(
                tooltip: show ? '隐藏' : '显示',
                icon: Icon(
                  show ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () {
                  setState(() {
                    _showSecret.putIfAbsent(conn.id, () => {})[f.key] = !show;
                  });
                },
              )
            : null,
      ),
    );
  }
}
