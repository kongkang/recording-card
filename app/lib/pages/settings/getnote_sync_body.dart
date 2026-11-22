/// 设置 → 第三方数据接入 → Get 笔记（得到大脑）OpenAPI 配置与同步详情页。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/store/app_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/external_data/getnote_sync_store.dart';
import '../../widgets/store_scope.dart';
import 'external_data_hub_body.dart';

class GetNoteSyncBody extends StatefulWidget {
  const GetNoteSyncBody({super.key, required this.store, this.appStore});

  final GetNoteSyncStore store;
  final AppStore? appStore;

  @override
  State<GetNoteSyncBody> createState() => _GetNoteSyncBodyState();
}

class _GetNoteSyncBodyState extends State<GetNoteSyncBody> {
  final _clientIdCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  bool _showKey = false;
  bool _dirtyCreds = false;
  bool _seededFromStore = false;

  GetNoteSyncStore get _store => widget.store;

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
  }

  void _syncControllersFromStore() {
    if (_dirtyCreds && _seededFromStore) return;
    if (_store.hasCredentials ||
        _store.clientId.isNotEmpty ||
        _store.apiKey.isNotEmpty) {
      _clientIdCtrl.text = _store.clientId;
      _apiKeyCtrl.text = _store.apiKey;
      _seededFromStore = true;
    }
  }

  @override
  void didUpdateWidget(GetNoteSyncBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != _store) {
      oldWidget.store.removeListener(_onStoreChanged);
      _store.addListener(_onStoreChanged);
      _dirtyCreds = false;
      _seededFromStore = false;
      _syncControllersFromStore();
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _clientIdCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    _syncControllersFromStore();
    setState(() {});
  }

  Future<void> _handleAutoImportToggle(BuildContext context) async {
    final appStore = widget.appStore ?? StoreScope.maybeOf(context);
    if (_dirtyCreds &&
        _clientIdCtrl.text.trim().isNotEmpty &&
        _apiKeyCtrl.text.trim().isNotEmpty) {
      _dirtyCreds = false;
      await _store.saveCredentials(
        clientId: _clientIdCtrl.text,
        apiKey: _apiKeyCtrl.text,
      );
    }
    await _store.setAutoImport(!_store.autoImport, appStore: appStore);
  }

  Future<void> _handleTest() async {
    _dirtyCreds = false;
    await _store.testConnection(
      clientId: _clientIdCtrl.text,
      apiKey: _apiKeyCtrl.text,
    );
  }

  Future<void> _handleSync(BuildContext context) async {
    final appStore = widget.appStore ?? StoreScope.maybeOf(context);
    if (appStore == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('时间轴存储未装载，请从主界面进入后重试')),
      );
      return;
    }
    _dirtyCreds = false;
    await _store.syncNow(
      appStore: appStore,
      clientId: _clientIdCtrl.text,
      apiKey: _apiKeyCtrl.text,
    );
  }

  Future<void> _handleClear() async {
    _dirtyCreds = false;
    _seededFromStore = false;
    _clientIdCtrl.clear();
    _apiKeyCtrl.clear();
    await _store.clearAll();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final busy = _store.testing || _store.syncing;
    final connLabel = !_store.hasCredentials
        ? '未配置'
        : (_store.connectionVerified ? '已连接' : '待验证');
    final connColor = !_store.hasCredentials
        ? c.sec
        : (_store.connectionVerified ? c.okInk : c.label);
    final hasAnyCreds =
        _store.hasCredentials ||
        _clientIdCtrl.text.trim().isNotEmpty ||
        _apiKeyCtrl.text.trim().isNotEmpty;

    final syncBtnLabel = !_store.syncing
        ? '立即同步'
        : (_store.syncCurrentPage > 0
              ? '第 ${_store.syncCurrentPage} 页 · ${_store.syncFetchedTotal} 条'
              : '同步中…');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '通过 Get 笔记开放平台（openapi.biji.com）连续翻页同步笔记与录音纪要',
          style: TextStyle(fontSize: 13, height: 1.45, color: c.sec),
        ),
        const SizedBox(height: 14),
        ExternalApiSectionCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExternalApiLabeledField(
                  fieldKey: const Key('getnote-client-id-input'),
                  label: 'Client ID',
                  controller: _clientIdCtrl,
                  hint: 'cli_...',
                  enabled: !busy,
                  onChanged: (_) => setState(() => _dirtyCreds = true),
                ),
                const SizedBox(height: 12),
                ExternalApiLabeledField(
                  fieldKey: const Key('getnote-api-key-input'),
                  label: 'API Key',
                  controller: _apiKeyCtrl,
                  hint: 'gk_live_...',
                  enabled: !busy,
                  obscureText: !_showKey,
                  onChanged: (_) => setState(() => _dirtyCreds = true),
                  suffixIcon: IconButton(
                    tooltip: _showKey ? '隐藏 API Key' : '显示 API Key',
                    icon: Icon(
                      _showKey ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _showKey = !_showKey),
                  ),
                ),
                const SizedBox(height: 14),
                ExternalApiActionButtons(
                  testKey: const Key('getnote-test-btn'),
                  syncKey: const Key('getnote-sync-btn'),
                  cancelKey: const Key('getnote-cancel-btn'),
                  busy: busy,
                  testing: _store.testing,
                  syncing: _store.syncing,
                  cancelling: _store.cancelling,
                  syncLabel: syncBtnLabel,
                  onTest: () => unawaited(_handleTest()),
                  onSync: () => unawaited(_handleSync(context)),
                  onCancel: _store.cancelSync,
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
              ExternalApiSwitchTile(
                rowKey: const Key('getnote-import-other-row'),
                switchKey: const Key('getnote-import-other-switch'),
                title: '同时导入其他文字/链接笔记',
                subtitle: '关闭时仅同步录音与会议类笔记（推荐）；开启后一并导入文字、链接与图文笔记',
                semanticsLabel: '同时导入其他文字/链接笔记开关',
                value: _store.importOtherNotes,
                disabled: busy,
                switchBusy: busy,
                onTap: () => unawaited(
                  _store.setImportOtherNotes(!_store.importOtherNotes),
                ),
              ),
              const ExternalApiHairlineDivider(),
              ExternalApiSwitchTile(
                rowKey: const Key('getnote-auto-import-row'),
                switchKey: const Key('getnote-auto-import-switch'),
                title: '开启后自动导入（每小时检查）',
                subtitle:
                    '开启后每 ${_store.checkIntervalMinutes} 分钟自动检查新增笔记并连续翻页导入',
                semanticsLabel: '自动导入开关（每小时检查一次）',
                value: _store.autoImport,
                disabled: _store.testing,
                switchBusy: _store.testing,
                onTap: () => unawaited(_handleAutoImportToggle(context)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ExternalApiStatusCard(
          cardKey: const Key('getnote-status-card'),
          connLabel: connLabel,
          connColor: connColor,
          importedCount: _store.importedCount,
          lastSyncAtMs: _store.lastSyncAtMs,
          lastAutoCheckAtMs: _store.lastAutoCheckAtMs,
          syncing: _store.syncing,
          statusMessage: _store.statusMessage,
          lastSyncSummary: _store.lastSyncSummary,
          errorMessage: _store.errorMessage,
        ),
        if (hasAnyCreds) ...[
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              key: const Key('getnote-clear-btn'),
              onPressed: busy ? null : () => unawaited(_handleClear()),
              style: TextButton.styleFrom(foregroundColor: c.danger),
              child: const Text(
                '清除凭据',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
