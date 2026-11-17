/// 旧版固件独立引导升级弹层（与正常设备状态胶囊弹窗完全解耦）。
///
/// 覆盖全闭环 UI：
/// 1. `prompt`：版本不兼容提示 + 一键「设置 Wi-Fi 并自动升级」；
/// 2. `scanningWifi` / `selectingWifi`：扫描并选择 Wi-Fi、填写密码、点「连接并自动升级」；
/// 3. `upgrading` / `reconnecting`：连接 Wi-Fi → 下载 → 静默安装 → 重启恢复蓝牙 → 自动连接蓝牙（期间防误触锁定）；
/// 4. `failed`：清晰展示错误并支持退回重设 Wi-Fi 或一键重试。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/rc_icons.dart';
import '../core/theme/tokens.dart';
import '../services/legacy_upgrade/legacy_upgrade_controller.dart';
import '../services/legacy_upgrade/legacy_upgrade_models.dart';

class LegacyUpgradeSheetOverlay extends StatefulWidget {
  const LegacyUpgradeSheetOverlay({super.key, required this.controller});

  final LegacyUpgradeController controller;

  @override
  State<LegacyUpgradeSheetOverlay> createState() =>
      _LegacyUpgradeSheetOverlayState();
}

class _LegacyUpgradeSheetOverlayState extends State<LegacyUpgradeSheetOverlay> {
  final _pwdCtrl = TextEditingController();
  bool _obscurePwd = true;
  String? _lastSyncedSsid;
  String? _lastSyncedPrefill;

  LegacyUpgradeController get ctrl => widget.controller;

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
  }

  void _syncPasswordFieldIfNeeded() {
    final ssid = ctrl.selectedSsid;
    final prefill = ctrl.prefilledPassword;
    if (ssid != _lastSyncedSsid || prefill != _lastSyncedPrefill) {
      _lastSyncedSsid = ssid;
      _lastSyncedPrefill = prefill;
      _pwdCtrl.text = prefill;
      _pwdCtrl.selection = TextSelection.collapsed(offset: prefill.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        if (!ctrl.isVisible) return const SizedBox.shrink();
        if (ctrl.step == LegacyUpgradeStep.selectingWifi) {
          _syncPasswordFieldIfNeeded();
        }
        final bottomInset = MediaQuery.paddingOf(context).bottom;
        final bottomKeyboard = MediaQuery.viewInsetsOf(context).bottom;
        return Positioned.fill(
          key: const Key('legacy-upg-sheet'),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: ctrl.isBusy ? null : () => unawaited(ctrl.dismiss()),
            child: Container(
              color: const Color(0x66000000),
              alignment: Alignment.bottomCenter,
              padding: EdgeInsets.only(bottom: bottomKeyboard),
              child: GestureDetector(
                onTap: () {},
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 620),
                  margin: EdgeInsets.fromLTRB(
                    10,
                    10,
                    10,
                    bottomKeyboard > 0 ? 10 : 10 + bottomInset,
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                  decoration: BoxDecoration(
                    color: RCColors.card,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: SingleChildScrollView(
                    primary: false,
                    child: switch (ctrl.step) {
                      LegacyUpgradeStep.prompt => _buildPrompt(),
                      LegacyUpgradeStep.scanningWifi => _buildScanningWifi(),
                      LegacyUpgradeStep.selectingWifi => _buildWifiSelect(),
                      LegacyUpgradeStep.upgrading ||
                      LegacyUpgradeStep.reconnecting => _buildProgress(),
                      LegacyUpgradeStep.failed => _buildFailed(),
                      LegacyUpgradeStep.hidden => const SizedBox.shrink(),
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(String title, {String? subtitle}) {
    final modelName = ctrl.mismatch?.device.modelLabel ?? '设备';
    final shortName = ctrl.mismatch?.device.shortName ?? '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: RCColors.sep.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: const RCIcon(
            RCIconKind.cloud,
            size: 18,
            color: RCColors.ink,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle ??
                    '$modelName${shortName.isEmpty ? '' : ' $shortName'}',
                style: const TextStyle(fontSize: 12, color: RCColors.sec),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPrompt() {
    final cur = ctrl.currentVersionLabel;
    final target = ctrl.targetVersionLabel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader('需要升级设备固件'),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: RCColors.bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前固件（$cur）与新版蓝牙协议不兼容，需要通过 Wi-Fi 自动升级至 $target。',
                style: const TextStyle(fontSize: 14, color: RCColors.ink),
              ),
              const SizedBox(height: 8),
              const Text(
                '• 下一步将扫描并配置 2.4GHz Wi-Fi 网络\n• 下载并静默安装完成后，会自动重新连接蓝牙',
                style: TextStyle(fontSize: 12, color: RCColors.sec, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('legacy-upg-start-wifi'),
          onPressed: () => unawaited(ctrl.beginWifiSetup()),
          style: FilledButton.styleFrom(
            backgroundColor: RCColors.label,
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
          child: const Text('设置 Wi-Fi 并自动升级'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('legacy-upg-cancel'),
          onPressed: () => unawaited(ctrl.dismiss()),
          style: OutlinedButton.styleFrom(
            foregroundColor: RCColors.ink,
            side: const BorderSide(color: RCColors.ax),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: const Text('暂不升级'),
        ),
      ],
    );
  }

  Widget _buildScanningWifi() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader('扫描附近 Wi-Fi', subtitle: '正在连接旧版控制通道…'),
        const SizedBox(height: 22),
        const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          ctrl.statusText.isEmpty ? '正在读取设备网络并扫描 Wi-Fi…' : ctrl.statusText,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: RCColors.sec),
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _buildWifiSelect() {
    final nets = ctrl.networks;
    final sel = ctrl.selectedNetwork;
    final selName = ctrl.selectedSsid ?? '';
    final alreadyConnected =
        selName.isNotEmpty && ctrl.isSsidAlreadyConnected(selName);
    final needPassword = (sel?.secure ?? true) && !alreadyConnected;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _buildHeader(
                '设置升级 Wi-Fi',
                subtitle: '当前 ${ctrl.currentVersionLabel} → 目标 ${ctrl.targetVersionLabel}',
              ),
            ),
            TextButton(
              key: const Key('legacy-upg-rescan-wifi'),
              onPressed: () => unawaited(ctrl.rescanWifi()),
              child: const Text('刷新', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (nets.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text(
              '未扫描到可用 Wi-Fi，请确认路由器在附近并点击右上角刷新',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: RCColors.sec),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.separated(
              shrinkWrap: true,
              primary: false,
              itemCount: nets.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: RCColors.sep),
              itemBuilder: (context, index) {
                final n = nets[index];
                final picked = n.ssid == selName;
                return InkWell(
                  key: Key('legacy-upg-wifi-${n.ssid}'),
                  onTap: () => unawaited(ctrl.selectSsid(n.ssid)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        Icon(
                          picked
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 18,
                          color: picked ? RCColors.ok : RCColors.ax,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            n.ssid,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight:
                                  picked ? FontWeight.w600 : FontWeight.w400,
                              color: RCColors.ink,
                            ),
                          ),
                        ),
                        if (n.connected)
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: RCColors.ok.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '已连接',
                              style: TextStyle(
                                fontSize: 11,
                                color: RCColors.ok,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (n.secure) ...[
                          const RCIcon(
                            RCIconKind.lock,
                            size: 12,
                            color: RCColors.sec,
                          ),
                          const SizedBox(width: 5),
                        ],
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 1; i <= 3; i++)
                              Container(
                                width: 3,
                                height: 3.0 + i * 3,
                                margin: const EdgeInsets.only(left: 2),
                                color: i <= n.signalLevel
                                    ? RCColors.ink
                                    : RCColors.ax,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        if (selName.isNotEmpty) ...[
          const SizedBox(height: 10),
          if (alreadyConnected)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '设备当前已连上「$selName」，留空密码可直接使用当前连接升级；如要切换或重输密码也可在下方填写。',
                style: const TextStyle(fontSize: 12, color: RCColors.sec),
              ),
            ),
          if (needPassword || alreadyConnected)
            TextField(
              key: const Key('legacy-upg-pwd-input'),
              controller: _pwdCtrl,
              obscureText: _obscurePwd,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: alreadyConnected ? '密码已保存（留空直接升级）' : '输入网络密码',
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: RCColors.ax),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: RCColors.ax),
                ),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscurePwd = !_obscurePwd),
                  icon: Icon(
                    _obscurePwd ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                    color: RCColors.sec,
                  ),
                ),
              ),
            ),
        ],
        if (ctrl.formError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              ctrl.formError!,
              key: const Key('legacy-upg-form-error'),
              style: const TextStyle(fontSize: 12, color: RCColors.danger),
            ),
          ),
        const SizedBox(height: 14),
        FilledButton(
          key: const Key('legacy-upg-connect-btn'),
          onPressed: selName.isEmpty
              ? null
              : () => unawaited(
                  ctrl.submitWifiAndUpgrade(
                    ssid: selName,
                    password: _pwdCtrl.text,
                  ),
                ),
          style: FilledButton.styleFrom(
            backgroundColor: RCColors.label,
            disabledBackgroundColor: RCColors.ax,
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
          child: Text(
            alreadyConnected && _pwdCtrl.text.trim().isEmpty
                ? '直接开始自动升级'
                : '连接并自动升级',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('legacy-upg-cancel'),
          onPressed: () => unawaited(ctrl.dismiss()),
          style: OutlinedButton.styleFrom(
            foregroundColor: RCColors.ink,
            side: const BorderSide(color: RCColors.ax),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _buildProgress() {
    final pct = (ctrl.progress * 100).round().clamp(0, 100);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(
          ctrl.step == LegacyUpgradeStep.reconnecting
              ? '正在自动连接蓝牙'
              : '正在自动升级固件',
          subtitle: '${ctrl.currentVersionLabel} → ${ctrl.targetVersionLabel}',
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            key: const Key('legacy-upg-progress'),
            value: ctrl.progress.clamp(0.02, 1.0),
            minHeight: 7,
            backgroundColor: RCColors.sep,
            valueColor: const AlwaysStoppedAnimation(RCColors.ok),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                ctrl.statusText,
                key: const Key('legacy-upg-status'),
                style: const TextStyle(fontSize: 13, color: RCColors.ink),
              ),
            ),
            Text(
              '$pct%',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: RCColors.sec,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          '升级与重启期间请保持设备电量充足并放在手机附近，完成后将自动连回蓝牙',
          style: TextStyle(fontSize: 12, color: RCColors.sec),
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _buildFailed() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader('自动升级未完成'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: RCColors.danger.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            ctrl.error ?? '操作失败，请重试',
            key: const Key('legacy-upg-error'),
            style: const TextStyle(fontSize: 13, color: RCColors.danger),
          ),
        ),
        const SizedBox(height: 14),
        FilledButton(
          key: const Key('legacy-upg-retry'),
          onPressed: () => unawaited(ctrl.retryFailedStep()),
          style: FilledButton.styleFrom(
            backgroundColor: RCColors.label,
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: const Text('重试升级'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('legacy-upg-back-wifi'),
          onPressed: () => unawaited(ctrl.backToWifiSelection()),
          style: OutlinedButton.styleFrom(
            foregroundColor: RCColors.ink,
            side: const BorderSide(color: RCColors.ax),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: const Text('返回重设 Wi-Fi'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('legacy-upg-cancel'),
          onPressed: () => unawaited(ctrl.dismiss()),
          child: const Text('关闭', style: TextStyle(color: RCColors.sec)),
        ),
      ],
    );
  }
}
