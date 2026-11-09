/// 录音卡状态胶囊 + 弹层（main / 固件更新 / Wi-Fi 设置 三个视图）。
library;

import 'package:flutter/material.dart';

import '../core/store/device_store.dart';
import '../core/theme/tokens.dart';

enum CardTransferChoice { normal, fast }

/// 电池图标：仅图形不显数字；<20% 红 / <40% 橙 / ≥40% 绿
class BatteryIcon extends StatelessWidget {
  const BatteryIcon({
    super.key,
    this.level = DeviceStore.batteryLevel,
    this.scale = 1,
    this.known = true,
  });
  final int level;
  final double scale;
  final bool known;

  Color get _color => !known
      ? RCColors.ax
      : level < 20
      ? RCColors.danger
      : level < 40
      ? const Color(0xFFFF9500)
      : RCColors.ok;

  @override
  Widget build(BuildContext context) {
    // 原型 SVG 23×11：电池体 + 间隙 + 正极凸起（凸起独立于体外右侧，不叠在边框上）
    return SizedBox(
      width: 23 * scale,
      height: 11 * scale,
      child: Row(
        children: [
          Container(
            key: const Key('batt'),
            width: 19 * scale,
            height: 11 * scale,
            decoration: BoxDecoration(
              border: Border.all(color: _color, width: 1.3),
              borderRadius: BorderRadius.circular(3 * scale),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                key: const Key('batt-fill'),
                margin: EdgeInsets.all(1.6 * scale),
                width: ((19 * scale - 3.2 * scale - 2.6 * scale) * level / 100)
                    .clamp(1.5, 19 * scale),
                color: _color,
              ),
            ),
          ),
          SizedBox(width: 1.2 * scale),
          Container(
            width: 2 * scale,
            height: 4.5 * scale,
            decoration: BoxDecoration(
              color: _color,
              borderRadius: BorderRadius.circular(1 * scale),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶栏胶囊：绿点心跳 + 电池图标
class HwCapsule extends StatefulWidget {
  const HwCapsule({
    super.key,
    required this.onTap,
    required this.level,
    this.connected = false,
    this.batteryKnown = false,
  });
  final VoidCallback onTap;
  final int level;
  final bool connected;
  final bool batteryKnown;

  @override
  State<HwCapsule> createState() => _HwCapsuleState();
}

class _HwCapsuleState extends State<HwCapsule>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('hw-capsule'),
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: RCColors.sep),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: Tween(begin: 0.35, end: 1.0).animate(
                CurvedAnimation(parent: _pulse, curve: const Interval(0, 0.45)),
              ),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: widget.connected ? RCColors.ok : RCColors.ax,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 6),
            BatteryIcon(
              level: widget.level,
              scale: 0.9,
              known: widget.batteryKnown,
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹层宿主：backdrop + 底部卡片；固件更新中锁定不关闭。
class StatusSheetOverlay extends StatelessWidget {
  const StatusSheetOverlay({super.key, required this.store});
  final DeviceStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.sheetOpen) return const SizedBox.shrink();
        // 真机 home indicator：卡片底边让出安全区（测试环境 inset=0，行为不变）
        final bottomInset = MediaQuery.paddingOf(context).bottom;
        return Positioned.fill(
          key: const Key('sheet'),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: store.closeSheet, // 更新中由 store 拒绝
            child: Container(
              color: const Color(0x66000000),
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                onTap: () {},
                child: Container(
                  key: const Key('sheet-card'),
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 620),
                  margin: EdgeInsets.fromLTRB(10, 10, 10, 10 + bottomInset),
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                  decoration: BoxDecoration(
                    color: RCColors.card,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: SingleChildScrollView(
                    child: switch (store.view) {
                      DeviceView.main => _MainView(store: store),
                      DeviceView.upg => _FirmwareView(store: store),
                      DeviceView.wifi => _WifiView(store: store),
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
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    this.child,
    this.onTap,
    this.keyName,
    this.fillValue = false,
  });
  final String label;
  final Widget? child;
  final VoidCallback? onTap;
  final String? keyName;
  final bool fillValue;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: RCColors.ink),
          ),
          if (fillValue) const SizedBox(width: 12) else const Spacer(),
          // 行值统一右对齐单行：占满剩余宽 + 右对齐，过长整体缩排，不换行不溢出
          if (child != null)
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [child!],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return onTap == null
        ? row
        : InkWell(
            key: keyName != null ? Key(keyName!) : null,
            onTap: onTap,
            child: row,
          );
  }
}

class _MainView extends StatelessWidget {
  const _MainView({required this.store});
  final DeviceStore store;

  Future<void> _cancelSync(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消同步？'),
        content: const Text(
          '仅停止文件移动，登录、已保存音频与原文都会保留。将等待当前传输结束与热点清理完成，不会取消已开始的文本处理。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续同步'),
          ),
          TextButton(
            key: const Key('confirm-cancel-sync'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('取消同步'),
          ),
        ],
      ),
    );
    if (confirmed == true) await store.cancelSync();
  }

  Future<void> _prepareFastTransfer(BuildContext context) async {
    final start = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('录音卡快传'),
        content: const Text(
          'App 将调起系统加入录音卡热点确认，允许后会自动验证本地文件服务并开始快传，无需离开 App。此热点是临时本地数据连接，不需要 Internet，音频只保存到本机；手机联网可能暂时受影响。请保持 App 在前台，结束后自动清理热点连接。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消快传'),
          ),
          TextButton(
            key: const Key('start-fast-transfer'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续快传'),
          ),
        ],
      ),
    );
    if (start != true || !context.mounted) return;
    if (!await store.prepareFastTransfer()) return;
    if (context.mounted) {
      await store.syncNow(fast: true);
    } else {
      await store.cancelFastTransfer();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('dev-main'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: store.connected ? RCColors.ok : RCColors.ax,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '录音卡',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    store.connectionText,
                    style: TextStyle(fontSize: 12, color: RCColors.sec),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: store.connected ? const Color(0xFFE8F5EA) : RCColors.bg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                store.connected ? '已连接' : '未连接',
                style: TextStyle(
                  fontSize: 11,
                  color: store.connected ? RCColors.okInk : RCColors.sec,
                ),
              ),
            ),
          ],
        ),
        const Divider(height: 24, color: RCColors.sep),
        // 录音状态：红点 + 录音中 + 跳动时钟（定宽防抖动）
        _Row(
          label: '录音状态',
          fillValue: true,
          child: Container(
            key: const Key('recval'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  key: const Key('recording-dot'),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: store.isRecording && store.recordingKnown
                        ? RCColors.danger
                        : RCColors.ax,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(store.recordingText, style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
                Text(
                  store.recClockText,
                  key: const Key('rec-clock'),
                  softWrap: false, // 等宽数字单行，不折行
                  style: const TextStyle(
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: store.recordingBusy
                      ? '等待设备确认'
                      : store.isRecording
                      ? '停止录音'
                      : '开始录音',
                  child: Semantics(
                    label: '录音开关',
                    child: Switch.adaptive(
                      key: const Key('recording-switch'),
                      value: store.isRecording,
                      activeThumbColor: RCColors.danger,
                      onChanged: store.canControlRecording
                          ? (enabled) {
                              if (enabled) {
                                store.startRecording();
                              } else {
                                store.stopRecording();
                              }
                            }
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        _Row(
          label: '电量',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              BatteryIcon(level: store.battery, known: store.batteryKnown),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  store.batteryKnown
                      ? store.statusStale
                            ? '${store.batteryLevelText} · 上次读取'
                            : '${store.batteryLevelText} · 可录至 ${store.batteryEtaText}'
                      : '电量未知',
                  key: const Key('batt-eta'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        // 同步行：行内动作，图标三态（sync → 自转 → 对勾），成功后 10s 冷却
        _Row(
          keyName: 'sync-now',
          label: '同步',
          fillValue: true,
          onTap: store.syncNow,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                store.syncText,
                key: const Key('sync-txt'),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(width: 7),
              SizedBox(
                width: 16,
                height: 16,
                child: switch (store.syncState) {
                  SyncState.idle => const Icon(
                    Icons.sync,
                    key: Key('sync-ico-idle'),
                    size: 15,
                    color: RCColors.sec,
                  ),
                  SyncState.failed => const Icon(
                    Icons.error_outline,
                    key: Key('sync-ico-failed'),
                    size: 15,
                    color: RCColors.danger,
                  ),
                  SyncState.cancelled => const Icon(
                    Icons.pause_circle_outline,
                    key: Key('sync-ico-cancelled'),
                    size: 15,
                    color: RCColors.sec,
                  ),
                  SyncState.busy => const _SpinIcon(key: Key('sync-ico-busy')),
                  SyncState.done => Icon(
                    store.sourceRetained ? Icons.info_outline : Icons.check,
                    key: Key(
                      store.sourceRetained
                          ? 'sync-ico-source-retained'
                          : 'sync-ico-done',
                    ),
                    size: 16,
                    color: store.sourceRetained
                        ? const Color(0xFFB87500)
                        : RCColors.ok,
                  ),
                },
              ),
              PopupMenuButton<CardTransferChoice>(
                key: const Key('transfer-mode'),
                tooltip: '传输方式',
                enabled:
                    store.connected &&
                    !store.deviceBusy &&
                    store.syncState != SyncState.done,
                padding: EdgeInsets.zero,
                iconSize: 16,
                constraints: const BoxConstraints(minWidth: 170),
                icon: const Icon(Icons.more_horiz, color: RCColors.sec),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: CardTransferChoice.normal,
                    child: Text('普通 BLE 传输'),
                  ),
                  PopupMenuItem(
                    value: CardTransferChoice.fast,
                    child: Text('录音卡快传 · 系统确认加入'),
                  ),
                ],
                onSelected: (choice) {
                  if (choice == CardTransferChoice.fast) {
                    _prepareFastTransfer(context);
                  } else {
                    store.syncNow();
                  }
                },
              ),
              if (store.syncState == SyncState.busy &&
                  store.backend is CancelableSyncDeviceBackend)
                TextButton(
                  key: const Key('cancel-sync'),
                  onPressed: store.canCancelSync
                      ? () => _cancelSync(context)
                      : null,
                  style: TextButton.styleFrom(
                    foregroundColor: RCColors.ink,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  child: Text(store.syncCancelling ? '正在取消…' : '取消同步'),
                ),
            ],
          ),
        ),
        // › 仅用于进入二级页
        _Row(
          keyName: 'wifi-row',
          label: 'Wi-Fi',
          onTap: () => store.showView(DeviceView.wifi),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(store.wifiConfigText, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 5),
              const Icon(
                Icons.chevron_right,
                key: Key('rowchev-wifi'),
                size: 15,
                color: RCColors.ax,
              ),
            ],
          ),
        ),
        _Row(
          keyName: 'fw-update',
          label: '固件',
          onTap: () => store.showView(DeviceView.upg),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                store.fwValText,
                key: const Key('fw-val'),
                style: TextStyle(
                  fontSize: 13,
                  color: store.fwHasError
                      ? RCColors.danger
                      : store.offer?.valid == true || store.fwDone
                      ? RCColors.okInk
                      : RCColors.sec,
                ),
              ),
              const SizedBox(width: 5),
              const Icon(Icons.chevron_right, size: 15, color: RCColors.ax),
            ],
          ),
        ),
        if (store.devStateText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              store.devStateText,
              key: const Key('dev-state'),
              style: TextStyle(
                fontSize: 12,
                color: store.devStateIsError ? RCColors.danger : RCColors.sec,
              ),
            ),
          ),
        if (store.fastTransferPreparing ||
            store.fastTransferCancelling ||
            (store.fastTransferPrepared && store.syncState != SyncState.busy))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('cancel-fast-transfer'),
              onPressed: store.fastTransferCancelling
                  ? null
                  : store.cancelFastTransfer,
              child: Text(
                store.fastTransferCancelling ? '正在清理快传…' : '取消快传并清理热点',
              ),
            ),
          ),
        if (!store.connected) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('device-scan'),
                  onPressed: store.scanning || store.connecting
                      ? null
                      : store.scanDevices,
                  child: Text(store.scanning ? '正在扫描…' : '扫描录音卡'),
                ),
              ),
              if (store.lastDeviceId != null) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const Key('device-reconnect'),
                  onPressed: store.connecting ? null : store.reconnect,
                  child: const Text('重连'),
                ),
              ],
            ],
          ),
          for (final device in store.scannedDevices)
            TextButton(
              key: Key('device-connect-${device.id}'),
              onPressed: store.connecting
                  ? null
                  : () => store.connectDevice(device.id),
              child: Text(device.name),
            ),
        ],
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('sheet-close'),
            onPressed: store.closeSheet,
            style: FilledButton.styleFrom(
              backgroundColor: RCColors.label,
              foregroundColor: Colors.white,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('关闭'),
          ),
        ),
      ],
    );
  }
}

/// 几何自绘 loading（绕中心旋转，不用字符/基线图形防偏心）
class _SpinIcon extends StatefulWidget {
  const _SpinIcon({super.key});
  @override
  State<_SpinIcon> createState() => _SpinIconState();
}

class _SpinIconState extends State<_SpinIcon>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _c,
    child: const Icon(Icons.sync, size: 15, color: RCColors.ink),
  );
}

class _FirmwareView extends StatelessWidget {
  const _FirmwareView({required this.store});
  final DeviceStore store;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('dev-upg'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '固件更新',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        _Row(
          label: '主控芯片',
          child: Text(
            store.mainVersionText,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        _Row(
          label: 'Wi-Fi 芯片',
          child: Text(
            store.wifiVersionText,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            store.offer?.notes ?? '固件清单未就绪，无法开始更新',
            style: TextStyle(fontSize: 12, color: RCColors.sec, height: 1.7),
          ),
        ),
        if (store.fwUpdating)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '更新期间请保持设备连接，切勿退出本页或关闭手机屏幕。',
              key: const Key('upg-warn'),
              style: const TextStyle(fontSize: 12, color: RCColors.danger),
            ),
          ),
        if (store.fwUpdating) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              key: const Key('upg-bar'),
              value: store.fwPercent == null ? null : store.fwProgress / 100,
              minHeight: 5,
              backgroundColor: RCColors.sep,
              valueColor: const AlwaysStoppedAnimation(RCColors.ok),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                store.fwStageText,
                key: const Key('upg-stage'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                store.fwPctText,
                style: const TextStyle(fontSize: 12, color: RCColors.sec),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            store.fwStateText,
            key: const Key('upg-state'),
            style: const TextStyle(fontSize: 12, color: RCColors.sec),
          ),
        ],
        if (!store.fwUpdating && store.fwStateText.isNotEmpty)
          Text(
            store.fwStateText,
            key: const Key('upg-state'),
            style: TextStyle(
              fontSize: 12,
              color: store.fwHasError ? RCColors.danger : RCColors.sec,
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('upg-btn'),
            onPressed:
                store.deviceBusy ||
                    !store.connected ||
                    store.offer?.valid != true ||
                    store.offer?.deviceId != store.deviceIdentity
                ? null
                : () => _confirmFirmware(context, store),
            style: FilledButton.styleFrom(
              backgroundColor: RCColors.label,
              disabledBackgroundColor: RCColors.ax,
              foregroundColor: Colors.white,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('开始更新'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            key: const Key('upg-back'),
            onPressed: store.fwUpdating
                ? null
                : () => store.showView(DeviceView.main),
            style: OutlinedButton.styleFrom(
              foregroundColor: RCColors.ink,
              disabledForegroundColor: RCColors.ax,
              side: const BorderSide(color: RCColors.ax),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('返回'),
          ),
        ),
      ],
    );
  }
}

Future<void> _confirmFirmware(BuildContext context, DeviceStore store) async {
  final offer = store.offer;
  if (offer == null || !offer.valid || !store.connected) {
    await store
        .startFwUpdate(); // fail-closed; no package => no hardware action
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认固件更新'),
      content: SingleChildScrollView(
        child: Text(
          '设备：${offer.deviceId}\n固件包：${offer.packageId}\n主控：${offer.targetMainVersion}\nWi-Fi：${offer.targetWifiVersion}\n校验值：${offer.checksum}\n更新将写入固件，请确认包和目标设备。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('fw-confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('确认更新'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  await store.startFwUpdate(
    consent: FirmwareConsent(
      packageId: offer.packageId,
      deviceId: offer.deviceId,
      checksum: offer.checksum,
    ),
  );
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.strength});
  final int strength;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: Key('sig-$strength'),
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 3; i++)
          Container(
            width: 3,
            height: 3.0 + i * 3,
            margin: const EdgeInsets.only(left: 2),
            color: i <= strength ? RCColors.ink : RCColors.ax,
          ),
      ],
    );
  }
}

class _WifiView extends StatefulWidget {
  const _WifiView({required this.store});
  final DeviceStore store;

  @override
  State<_WifiView> createState() => _WifiViewState();
}

class _WifiViewState extends State<_WifiView> {
  final _pwdCtrl = TextEditingController();

  @override
  void dispose() {
    _pwdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final shown = store.wifiMore
        ? store.wifiSaved
        : store.wifiSaved.take(3).toList();
    return Column(
      key: const Key('dev-wifi'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('wifi-back'),
              onPressed: () => store.showView(DeviceView.main),
              icon: const Icon(Icons.chevron_left, size: 22),
              color: RCColors.ink,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            ),
            const SizedBox(width: 4),
            const Text(
              'Wi-Fi 设置',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '已保存',
            style: TextStyle(fontSize: 12, color: RCColors.sec),
          ),
        ),
        for (final w in shown)
          () {
            final inRange = store.wifiScanDone && store.wifiInRange(w.name);
            final joining = store.wifiJoining && store.wifiJoinName == w.name;
            return InkWell(
              key: Key('wsaved-${w.name}'),
              onTap: inRange ? () => store.wifiConnectSaved(w.name) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  children: [
                    Text(
                      w.name,
                      style: TextStyle(
                        fontSize: 14,
                        color: inRange ? RCColors.label : RCColors.sec,
                      ),
                    ),
                    if (store.wifiLast == w.name) ...[
                      const SizedBox(width: 6),
                      const _Chip('已连接'),
                    ],
                    const Spacer(),
                    Text(
                      joining
                          ? '正在连接…'
                          : store.wifiScanDone
                          ? (inRange ? '' : '不在范围内')
                          : '—',
                      style: const TextStyle(fontSize: 12, color: RCColors.sec),
                    ),
                    if (inRange) ...[
                      const SizedBox(width: 6),
                      _SignalBars(strength: 2),
                    ],
                  ],
                ),
              ),
            );
          }(),
        if (store.wifiSaved.length > 3)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('wmore'),
              onPressed: store.wifiMoreToggle,
              style: TextButton.styleFrom(
                foregroundColor: RCColors.sec,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                minimumSize: Size.zero,
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: Text(
                store.wifiMore
                    ? '收起已保存'
                    : '查看更多已保存（${store.wifiSaved.length - 3}）',
              ),
            ),
          ),
        const Divider(height: 18, color: RCColors.sep),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '可用网络',
            style: TextStyle(fontSize: 12, color: RCColors.sec),
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            store.wifiStateText,
            key: const Key('wstate'),
            style: const TextStyle(fontSize: 12, color: RCColors.sec),
          ),
        ),
        if (store.wifiScanning)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          for (final r in store.wifiScanRes) ...[
            _availRow(store, r),
            if (store.wifiSelName == r.name) _joinForm(store, r),
          ],
        const SizedBox(height: 8),
        const Text(
          '录音卡仅支持 2.4GHz 网络；网络频段以设备扫描结果为准',
          style: TextStyle(fontSize: 11, color: RCColors.sec),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: store.wifiScan,
            style: OutlinedButton.styleFrom(
              foregroundColor: RCColors.ink,
              side: const BorderSide(color: RCColors.ax),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: const Text('重新扫描'),
          ),
        ),
      ],
    );
  }

  Widget _availRow(DeviceStore store, WifiNet r) {
    final saved = store.wifiSaved.any((s) => s.name == r.name);
    final joining = store.wifiJoining && store.wifiJoinName == r.name;
    if (joining) {
      return Padding(
        key: Key('witem-${r.name}'),
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Text(r.name, style: const TextStyle(fontSize: 14)),
            const Spacer(),
            const Text(
              '正在连接…',
              style: TextStyle(fontSize: 12, color: RCColors.sec),
            ),
          ],
        ),
      );
    }
    return InkWell(
      key: Key('witem-${r.name}'),
      onTap: saved
          ? () => store.wifiConnectSaved(r.name)
          : () => store.wifiPick(r.name),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Text(r.name, style: const TextStyle(fontSize: 14)),
            if (saved) ...[
              const SizedBox(width: 6),
              const _Chip('已保存', subtle: true),
            ],
            const Spacer(),
            if (r.lock) ...[
              const Icon(Icons.lock, size: 12, color: RCColors.sec),
              const SizedBox(width: 5),
            ],
            _SignalBars(strength: r.signal),
          ],
        ),
      ),
    );
  }

  Widget _joinForm(DeviceStore store, WifiNet r) {
    final verifying = store.wifiJoining && store.wifiJoinName == r.name;
    return Padding(
      key: Key('wform-${r.name}'),
      padding: const EdgeInsets.only(left: 12, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r.name,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          if (verifying)
            const Text(
              '正在验证连接可行性…',
              style: TextStyle(fontSize: 12, color: RCColors.sec),
            )
          else ...[
            SizedBox(
              height: 36,
              child: TextField(
                key: const Key('wifi-pwd'),
                controller: _pwdCtrl,
                obscureText: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: '输入网络密码',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: RCColors.sep),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton(
                  key: const Key('wifi-cancel'),
                  onPressed: store.wifiCancelPick,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: RCColors.ink,
                    side: const BorderSide(color: RCColors.ax),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                  ),
                  child: const Text('取消', style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  key: const Key('wifi-connect'),
                  onPressed: () async {
                    final pwd = _pwdCtrl.text;
                    _pwdCtrl.clear();
                    await store.wifiJoinNew(pwd);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: RCColors.label,
                    foregroundColor: Colors.white,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                  ),
                  child: const Text('连接', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, {this.subtle = false});
  final String label;
  final bool subtle;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: subtle ? const Color(0xFFF0F0EC) : const Color(0xFFE8F5EA),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10,
        color: subtle ? RCColors.ink : RCColors.okInk,
      ),
    ),
  );
}
