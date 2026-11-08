/// 录音卡状态胶囊 + 弹层（main / 固件更新 / Wi-Fi 设置 三个视图）。
library;

import 'package:flutter/material.dart';

import '../core/store/device_store.dart';
import '../core/theme/tokens.dart';

/// 电池图标：仅图形不显数字；<20% 红 / <40% 橙 / ≥40% 绿
class BatteryIcon extends StatelessWidget {
  const BatteryIcon({
    super.key,
    this.level = 0,
    this.scale = 1,
  });
  final int level;
  final double scale;

  // 电量未知（未连接/未回报）显示中性灰，不假装"电量低"
  Color get _color => level <= 0
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
    this.connected = true,
  });
  final VoidCallback onTap;
  final int level;

  /// 没连设备时只显示灰点：点击进入扫描连接流程，而不是假装已连接。
  final bool connected;

  @override
  State<HwCapsule> createState() => _HwCapsuleState();
}

class _HwCapsuleState extends State<HwCapsule>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    // 控制器必须在 initState 建好：未连接时不渲染呼吸动画，
    // 若留到 dispose 里惰性创建会去查已失活的祖先 State。
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.connected) _pulse.repeat();
  }

  @override
  void didUpdateWidget(HwCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.connected && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!widget.connected && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

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
            if (widget.connected)
              FadeTransition(
                opacity: Tween(begin: 0.35, end: 1.0).animate(
                  CurvedAnimation(
                    parent: _pulse,
                    curve: const Interval(0, 0.45),
                  ),
                ),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: RCColors.ok,
                    shape: BoxShape.circle,
                  ),
                ),
              )
            else
              Container(
                key: const Key('capsule-off'),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: RCColors.ax, width: 1.4),
                ),
              ),
            if (widget.connected) ...[
              const SizedBox(width: 6),
              BatteryIcon(level: widget.level, scale: 0.9),
            ],
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
  const _Row({required this.label, this.child, this.onTap, this.keyName});
  final String label;
  final Widget? child;
  final VoidCallback? onTap;
  final String? keyName;

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
          const Spacer(),
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

  @override
  Widget build(BuildContext context) {
    if (!store.isConnected) return _ConnectView(store: store);
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
              decoration: const BoxDecoration(
                color: RCColors.ok,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '录音卡',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    '已连接 · 蓝牙',
                    style: TextStyle(fontSize: 12, color: RCColors.sec),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5EA),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                '已连接',
                style: TextStyle(fontSize: 11, color: RCColors.okInk),
              ),
            ),
          ],
        ),
        const Divider(height: 24, color: RCColors.sep),
        // 录音状态：红点 + 录音中 + 跳动时钟（定宽防抖动）
        _Row(
          label: '录音状态',
          child: Container(
            key: const Key('recval'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: RCColors.danger,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                const Text('录音中', style: TextStyle(fontSize: 13)),
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
              ],
            ),
          ),
        ),
        _Row(
          label: '电量',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              BatteryIcon(level: store.battery),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${store.batteryLevelText} · 可录至 ${store.batteryEtaText}',
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
                  SyncState.busy => const _SpinIcon(key: Key('sync-ico-busy')),
                  SyncState.done => const Icon(
                    Icons.check,
                    key: Key('sync-ico-done'),
                    size: 16,
                    color: RCColors.ok,
                  ),
                },
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
              Text(
                '已配置 · ${store.wifiCountShown} 个网络',
                style: const TextStyle(fontSize: 13),
              ),
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
                style: const TextStyle(fontSize: 13, color: RCColors.okInk),
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
              style: const TextStyle(fontSize: 12, color: RCColors.okInk),
            ),
          ),
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

/// 未连接视图：搜索并连接附近的录音卡。
///
/// 顶栏胶囊在未连接时点开直接进这里——扫描是进入动作，不是藏在二级页里的开关。
class _ConnectView extends StatelessWidget {
  const _ConnectView({required this.store});
  final DeviceStore store;

  @override
  Widget build(BuildContext context) {
    final busy = store.isLinkBusy;
    return Column(
      key: const Key('dev-connect'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: RCColors.ax, width: 1.4),
              ),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '录音卡',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    '未连接 · 蓝牙',
                    style: TextStyle(fontSize: 12, color: RCColors.sec),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0EC),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                '未连接',
                key: Key('dev-link-chip'),
                style: TextStyle(fontSize: 11, color: RCColors.sec),
              ),
            ),
          ],
        ),
        const Divider(height: 24, color: RCColors.sep),
        if (store.linkState == LinkState.scanning)
          Row(
            key: const Key('dev-scan-state'),
            children: const [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text('正在搜索附近的录音卡…', style: TextStyle(fontSize: 13)),
            ],
          )
        else if (store.linkState == LinkState.connecting)
          Row(
            key: const Key('dev-connecting-state'),
            children: const [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text('正在连接录音卡…', style: TextStyle(fontSize: 13)),
            ],
          )
        else if (store.linkError != null)
          Column(
            key: const Key('dev-scan-empty'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                store.linkError!,
                style: const TextStyle(fontSize: 13, color: RCColors.ink),
              ),
              const SizedBox(height: 4),
              const Text(
                '请确认录音卡已开机，并放在手机附近',
                style: TextStyle(fontSize: 12, color: RCColors.sec),
              ),
            ],
          )
        else
          const Text(
            '选择要连接的录音卡',
            key: Key('dev-pick-hint'),
            style: TextStyle(fontSize: 13, color: RCColors.sec),
          ),
        for (final device in store.discovered) ...[
          const SizedBox(height: 10),
          InkWell(
            key: Key('dev-item-${device.id}'),
            onTap: busy ? null : () => store.connectTo(device),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: RCColors.sep),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      device.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Text(
                    '连接',
                    style: TextStyle(fontSize: 12, color: RCColors.okInk),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, size: 15, color: RCColors.ax),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton(
          key: const Key('dev-rescan'),
          onPressed: busy ? null : () => store.startScan(),
          style: OutlinedButton.styleFrom(
            foregroundColor: RCColors.label,
            side: const BorderSide(color: RCColors.ax),
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(vertical: 11),
          ),
          child: const Text('重新扫描'),
        ),
        const SizedBox(height: 8),
        FilledButton(
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
            store.mainVersionCompare,
            key: const Key('fw-main-ver'),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        _Row(
          label: 'Wi-Fi 芯片',
          child: Text(
            store.wifiVersionCompare,
            key: const Key('fw-wifi-ver'),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        if (store.fwError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              store.fwError!,
              key: const Key('fw-error'),
              style: const TextStyle(
                fontSize: 12,
                color: RCColors.danger,
                height: 1.6,
              ),
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
              value: store.fwProgress / 100,
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
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('upg-btn'),
            onPressed: store.fwUpdating ? null : store.startFwUpdate,
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
        // 连接/密码错误就地展示（用户改密码即可重试，不靠一闪而过的提示）
        if (store.wifiError != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                store.wifiError!,
                key: const Key('wifi-error'),
                style: const TextStyle(fontSize: 12, color: RCColors.danger),
              ),
            ),
          ),
        if (!store.wifiScanDone)
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
          '录音卡仅支持 2.4GHz 网络，此处只显示 2.4GHz 接入点',
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
                  onPressed: () => store.wifiJoinNew(_pwdCtrl.text),
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
