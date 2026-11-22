/// 设置 → 第三方数据接入 → 得到大脑 / Get 笔记 OpenAPI 配置与手动同步面板。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/store/app_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/external_data/getnote_sync_store.dart';
import '../../widgets/rc_switch.dart';
import '../../widgets/store_scope.dart';

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
    final busy = _store.testing || _store.syncing;
    final connLabel = !_store.hasCredentials
        ? '未配置'
        : (_store.connectionVerified ? '已连接' : '待验证');
    final connColor = !_store.hasCredentials
        ? c.sec
        : (_store.connectionVerified ? c.ok : c.ink);
    final hasAnyCreds =
        _store.hasCredentials ||
        _clientIdCtrl.text.trim().isNotEmpty ||
        _apiKeyCtrl.text.trim().isNotEmpty;

    final syncBtnLabel = !_store.syncing
        ? '立即同步'
        : (_store.syncCurrentPage > 0
              ? '第 ${_store.syncCurrentPage} 页 · 已处理 ${_store.syncFetchedTotal} 条…'
              : '同步中…');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '通过官方 Get 笔记（得到大脑）OpenAPI（openapi.biji.com）连续翻页拉取全部笔记到本机时间轴，'
          '每页同步后实时落盘并按 note_id 幂等去重；支持开启每小时自动检查与导入。'
          '请在 biji.com/openapi 申请应用获取 Client ID 与 API Key；凭据仅保存在本机系统密钥库（Keychain）。',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: c.sec),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.sep),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('getnote-client-id-input'),
                controller: _clientIdCtrl,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() => _dirtyCreds = true),
                decoration: const InputDecoration(
                  labelText: 'Client ID',
                  hintText: 'cli_...',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('getnote-api-key-input'),
                controller: _apiKeyCtrl,
                enabled: !busy,
                obscureText: !_showKey,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() => _dirtyCreds = true),
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: 'gk_live_...',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _showKey ? '隐藏 API Key' : '显示 API Key',
                    icon: Icon(
                      _showKey ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _showKey = !_showKey),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton(
                    key: const Key('getnote-test-btn'),
                    onPressed: busy ? null : () => unawaited(_handleTest()),
                    child: Text(_store.testing ? '测试中…' : '测试连接'),
                  ),
                  FilledButton(
                    key: const Key('getnote-sync-btn'),
                    onPressed: busy
                        ? null
                        : () => unawaited(_handleSync(context)),
                    child: Text(syncBtnLabel),
                  ),
                  if (_store.syncing)
                    OutlinedButton(
                      key: const Key('getnote-cancel-btn'),
                      onPressed: _store.cancelling ? null : _store.cancelSync,
                      child: Text(_store.cancelling ? '正在停止…' : '停止同步'),
                    ),
                  if (hasAnyCreds)
                    TextButton(
                      key: const Key('getnote-clear-btn'),
                      onPressed: busy ? null : () => unawaited(_handleClear()),
                      style: TextButton.styleFrom(foregroundColor: c.danger),
                      child: const Text('清除凭据'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.sep),
          ),
          child: Semantics(
            container: true,
            button: true,
            toggled: _store.importOtherNotes,
            label: '同时导入其他文字/链接笔记开关',
            onTap: busy
                ? null
                : () => unawaited(
                    _store.setImportOtherNotes(!_store.importOtherNotes),
                  ),
            child: GestureDetector(
              key: const Key('getnote-import-other-row'),
              behavior: HitTestBehavior.opaque,
              onTap: busy
                  ? null
                  : () => unawaited(
                      _store.setImportOtherNotes(!_store.importOtherNotes),
                    ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '同时导入其他文字/链接笔记',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: c.label,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '关闭时仅同步录音与会议类笔记（推荐）；开启后一并导入文字、链接与图文笔记',
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
                        key: const Key('getnote-import-other-switch'),
                        on: _store.importOtherNotes,
                        busy: busy,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.sep),
          ),
          child: Semantics(
            container: true,
            button: true,
            toggled: _store.autoImport,
            label: '自动导入开关（每小时检查一次）',
            onTap: _store.testing
                ? null
                : () => unawaited(_handleAutoImportToggle(context)),
            child: GestureDetector(
              key: const Key('getnote-auto-import-row'),
              behavior: HitTestBehavior.opaque,
              onTap: _store.testing
                  ? null
                  : () => unawaited(_handleAutoImportToggle(context)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '开启后自动导入（每小时检查）',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: c.label,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '开启后每 ${_store.checkIntervalMinutes} 分钟自动检查新增笔记并连续翻页导入，'
                            '回到前台时如已到期也会立即补检',
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
                        key: const Key('getnote-auto-import-switch'),
                        on: _store.autoImport,
                        busy: _store.testing,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          key: const Key('getnote-status-card'),
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
                  Text(
                    '连接状态：$connLabel',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: connColor,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '已导入 ${_store.importedCount} 条',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.label,
                    ),
                  ),
                ],
              ),
              if (_store.lastSyncAtMs != null) ...[
                const SizedBox(height: 4),
                Text(
                  '上次同步：${_formatEpoch(_store.lastSyncAtMs!)}',
                  style: TextStyle(fontSize: 12, color: c.sec),
                ),
              ],
              if (_store.lastAutoCheckAtMs != null) ...[
                const SizedBox(height: 2),
                Text(
                  '上次自动检查：${_formatEpoch(_store.lastAutoCheckAtMs!)}',
                  style: TextStyle(fontSize: 12, color: c.sec),
                ),
              ],
              if (_store.syncing && _store.statusMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  _store.statusMessage!,
                  style: TextStyle(fontSize: 12.5, color: c.ink, height: 1.4),
                ),
              ] else if (_store.statusMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  _store.statusMessage!,
                  style: TextStyle(fontSize: 12.5, color: c.ok, height: 1.4),
                ),
              ] else if (_store.lastSyncSummary != null) ...[
                const SizedBox(height: 4),
                Text(
                  _store.lastSyncSummary!,
                  style: TextStyle(fontSize: 12.5, color: c.sec, height: 1.4),
                ),
              ],
              if (_store.errorMessage != null) ...[
                const SizedBox(height: 6),
                Text(
                  _store.errorMessage!,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: c.danger,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
