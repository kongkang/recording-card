/// 录音卡状态胶囊 + 弹层（main / 固件更新 / Wi-Fi 设置 三个视图）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/device/card_gateway.dart';
import '../core/store/agent_config_store.dart';
import '../core/store/device_store.dart';
import '../core/theme/rc_icons.dart';
import '../core/theme/tokens.dart';
import '../services/audio/phone_mic_service.dart';
import '../widgets/rc_switch.dart';

/// 弹层是否展示 Wi-Fi 配网行（随硬件能力 hasWifiConfig 门控）。
const bool showWifiRow = true;

/// 判断路由器 SSID 名称或错误信息是否涉及疑似 5GHz 频段（如 `KK2BY_5G`、`Home-5G`、`Office 5GHz`）。
bool isLikely5GhzSsid(String raw) {
  final normalized = raw.trim().toUpperCase().replaceAll(RegExp(r'[「」"“”]'), ' ');
  if (normalized.isEmpty) return false;
  return RegExp(r'(?:^|[_\-\s.])5G(?:HZ)?(?:$|[_\-\s.])').hasMatch(normalized) ||
      normalized.endsWith('5G') ||
      normalized.endsWith('5GHZ');
}

/// 电池图标：仅图形不显数字；<20% 红 / <40% 橙 / ≥40% 绿；充电时内部呼吸并叠加闪电。
class BatteryIcon extends StatefulWidget {
  const BatteryIcon({
    super.key,
    this.level = 0,
    this.scale = 1,
    this.charging = false,
  });
  final int level;
  final double scale;
  final bool charging;

  @override
  State<BatteryIcon> createState() => _BatteryIconState();
}

class _BatteryIconState extends State<BatteryIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.charging) {
      _breathe.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(BatteryIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.charging && !_breathe.isAnimating) {
      _breathe.repeat(reverse: true);
    } else if (!widget.charging && _breathe.isAnimating) {
      _breathe.stop();
      _breathe.value = 1.0;
    }
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  // 电量未知（未连接/未回报）显示中性灰，不假装"电量低"
  Color _color(RCColorScheme c) {
    if (widget.charging && widget.level <= 0) return c.ok;
    return widget.level <= 0
        ? c.ax
        : widget.level < 20
        ? c.danger
        : widget.level < 40
        ? c.warn
        : c.ok;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final col = _color(c);
    final s = widget.scale;
    final maxFillWidth = 19 * s - 3.2 * s - 2.6 * s;
    final rawWidth = widget.charging && widget.level <= 0
        ? maxFillWidth * 0.55
        : (maxFillWidth * widget.level / 100);
    final fillWidth = rawWidth.clamp(1.5, maxFillWidth);
    final opacityAnim = widget.charging
        ? Tween<double>(begin: 0.35, end: 1.0).animate(
            CurvedAnimation(parent: _breathe, curve: Curves.easeInOut),
          )
        : const AlwaysStoppedAnimation<double>(1.0);

    // 原型 SVG 23×11：电池体 + 间隙 + 正极凸起；充电中内部填充呼吸 + 居中闪电覆盖。
    return SizedBox(
      width: 23 * s,
      height: 11 * s,
      child: Row(
        children: [
          Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Container(
                key: const Key('batt'),
                width: 19 * s,
                height: 11 * s,
                decoration: BoxDecoration(
                  border: Border.all(color: col, width: 1.3),
                  borderRadius: BorderRadius.circular(3 * s),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FadeTransition(
                    opacity: opacityAnim,
                    child: Container(
                      key: const Key('batt-fill'),
                      margin: EdgeInsets.all(1.6 * s),
                      width: fillWidth,
                      decoration: BoxDecoration(
                        color: col,
                        borderRadius: BorderRadius.circular(1 * s),
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.charging)
                RCIcon(
                  RCIconKind.bolt,
                  key: const Key('batt-bolt'),
                  size: 10.5 * s,
                  color: c.label,
                ),
            ],
          ),
          SizedBox(width: 1.2 * s),
          Container(
            width: 2 * s,
            height: 4.5 * s,
            decoration: BoxDecoration(
              color: col,
              borderRadius: BorderRadius.circular(1 * s),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶栏胶囊：圆点状态 + 电量；没连设备时电量位置改显「无设备」文字（或「本机录音」）。
///
/// 圆点语义（2026-11-10 owner 定稿）：绿=正在录音（心跳）；橙=已连接但未录音
/// （待机，说明卡在、电量为真）；蓝=掉线后自动重连中（只试一次）；
/// 灰空心=未连接（不出电量，改显「无设备」）。
class HwCapsule extends StatefulWidget {
  const HwCapsule({
    super.key,
    required this.onTap,
    required this.level,
    this.connected = true,
    this.recording = false,
    this.reconnecting = false,
    this.charging = false,
    this.phoneRecording = false,
    this.watchRecording = false,
    this.pendingFailover = false,
  });
  final VoidCallback onTap;
  final int level;

  /// 没连设备时只显示灰点 + 「无设备」：点击进入扫描连接流程，而不是假装已连接。
  final bool connected;

  /// 是否正在录音：只有录音中才绿点心跳；已连接待机是橙点。
  final bool recording;

  /// 看门狗判掉线后正在自动重连：蓝点 + 「连接中…」。
  final bool reconnecting;

  /// 设备是否正在充电。
  final bool charging;

  /// 本机麦克风是否在录音（无硬件也可独立运行）。
  final bool phoneRecording;

  /// Apple Watch 是否正在进行断连保底录音。
  final bool watchRecording;

  /// 蓝牙断开后本机保底因后台受限挂起待恢复。
  final bool pendingFailover;

  @override
  State<HwCapsule> createState() => _HwCapsuleState();
}

class _HwCapsuleState extends State<HwCapsule>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  bool get _isRunning =>
      (widget.connected && widget.recording) ||
      (!widget.connected &&
          !widget.reconnecting &&
          (widget.phoneRecording || widget.watchRecording));

  @override
  void initState() {
    super.initState();
    // 控制器必须在 initState 建好：未连接时不渲染呼吸动画，
    // 若留到 dispose 里惰性创建会去查已失活的祖先 State。
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (_isRunning) _pulse.repeat();
  }

  @override
  void didUpdateWidget(HwCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    final running = _isRunning;
    if (running && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!running && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _dot(RCColorScheme r, {bool forceOk = false, Color? colorOverride}) {
    return Container(
      key: const Key('capsule-dot'),
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        // 蓝=掉线自动重连中；绿=正在运行（录音中/本机/手表录音）；橙=已连接待机/待接力
        color:
            colorOverride ??
            (widget.reconnecting
                ? r.info
                : ((forceOk || widget.recording) ? r.ok : r.warn)),
        shape: BoxShape.circle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = context.rc;
    // 重连中也算"有条链路在手"，只是数据暂时不可信
    final linked = widget.connected || widget.reconnecting;
    final watchRec = !linked && widget.watchRecording;
    final localRec = !linked && !watchRec && widget.phoneRecording;
    final pendingRec = !linked && !watchRec && !localRec && widget.pendingFailover;
    return Semantics(
      label: linked
          ? (widget.reconnecting
                ? '录音卡状态：连接中'
                : (widget.recording ? '录音卡状态：已连接，录音中' : '录音卡状态：已连接，未录音'))
          : (watchRec
                ? '录音卡状态：手表保底录音中'
                : (localRec
                      ? '录音卡状态：本机录音中'
                      : (pendingRec ? '录音卡状态：待恢复保底录音' : '录音卡状态：无设备'))),
      button: true,
      child: InkWell(
        key: const Key('hw-capsule'),
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            border: Border.all(color: r.sep),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (linked)
                widget.recording && widget.connected
                    ? FadeTransition(
                        opacity: Tween(begin: 0.35, end: 1.0).animate(
                          CurvedAnimation(
                            parent: _pulse,
                            curve: const Interval(0, 0.45),
                          ),
                        ),
                        child: _dot(r),
                      )
                    : _dot(r)
              else if (watchRec || localRec)
                FadeTransition(
                  opacity: Tween(begin: 0.35, end: 1.0).animate(
                    CurvedAnimation(
                      parent: _pulse,
                      curve: const Interval(0, 0.45),
                    ),
                  ),
                  child: _dot(r, forceOk: true),
                )
              else if (pendingRec)
                _dot(r, colorOverride: r.warn)
              else
                Container(
                  key: const Key('capsule-off'),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: r.ax, width: 1.4),
                  ),
                ),
              const SizedBox(width: 6),
              if (widget.reconnecting)
                Text(
                  '连接中…',
                  key: const Key('capsule-retry'),
                  style: TextStyle(fontSize: 12, color: r.sec),
                )
              else if (widget.connected)
                BatteryIcon(
                  level: widget.level,
                  scale: 0.9,
                  charging: widget.charging,
                )
              else if (watchRec)
                Text(
                  '手表录音',
                  key: const Key('capsule-watch-rec'),
                  style: TextStyle(fontSize: 12, color: r.label),
                )
              else if (localRec)
                Text(
                  '本机录音',
                  key: const Key('capsule-phone-rec'),
                  style: TextStyle(fontSize: 12, color: r.label),
                )
              else if (pendingRec)
                Text(
                  '待接力',
                  key: const Key('capsule-failover-pending'),
                  style: TextStyle(
                    fontSize: 12,
                    color: r.warn,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                Text(
                  '无设备',
                  key: const Key('capsule-nodata'),
                  style: TextStyle(fontSize: 12, color: r.sec),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹层宿主：backdrop + 底部卡片；固件更新中锁定不关闭。
class StatusSheetOverlay extends StatefulWidget {
  const StatusSheetOverlay({
    super.key,
    required this.store,
    this.agentConfig,
    this.islandEnabled = true,
  });
  final DeviceStore store;
  final AgentConfigStore? agentConfig;
  final bool islandEnabled;

  @override
  State<StatusSheetOverlay> createState() => _StatusSheetOverlayState();
}

class _StatusSheetOverlayState extends State<StatusSheetOverlay>
    with WidgetsBindingObserver {
  DeviceStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.markSheetAttached();
  }

  @override
  void didUpdateWidget(StatusSheetOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.markSheetDetached();
      widget.store.markSheetAttached();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      store.handleAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 宿主要没了：只把"弹层已关闭"这件事登记下去，不在这里触发重建。
    // 直接调用会修改 store 并在 dispose 期间发通知，属于 build 期改状态。
    store.markSheetDetached();
    super.dispose();
  }

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
                    color: context.rc.card,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: SingleChildScrollView(
                    primary: false,
                    child: switch (store.view) {
                      DeviceView.main => _MainView(
                        store: store,
                        agentConfig: widget.agentConfig,
                        islandEnabled: widget.islandEnabled,
                      ),
                      DeviceView.upg => _FirmwareView(
                        store: store,
                        islandEnabled: widget.islandEnabled,
                      ),
                      DeviceView.wifi => _WifiView(store: store),
                      DeviceView.btn => _ButtonConfigView(
                        store: store,
                        agentConfig: widget.agentConfig,
                      ),
                      DeviceView.more =>
                        store.isConnected
                            ? _MoreView(store: store)
                            : _ConnectView(
                                store: store,
                                islandEnabled: widget.islandEnabled,
                              ),
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
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(fontSize: 14, color: context.rc.ink),
            ),
          ),
          const SizedBox(width: 12),
          // 行值统一右对齐单行：占满剩余宽 + 右对齐。
          // 不再用 FittedBox 整体缩排——那会把右侧文字缩到将就看不清；
          // 放不下时按行尾省略，保持与左侧标签同一字号。
          if (child != null)
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: child!,
              ),
            ),
        ],
      ),
    );
    return onTap == null
        ? (keyName != null
              ? KeyedSubtree(key: Key(keyName!), child: row)
              : row)
        : InkWell(
            key: keyName != null ? Key(keyName!) : null,
            onTap: onTap,
            child: row,
          );
  }
}

Future<void> _togglePhoneRecordingWithPermission(
  BuildContext context,
  DeviceStore store, {
  required bool islandEnabled,
}) async {
  if (store.isPhoneRecording) {
    await store.stopPhoneRecording();
    return;
  }
  var perm = await store.checkPhoneMicPermission();
  if (perm == PhoneMicPermission.notDetermined) {
    perm = await store.requestPhoneMicPermission();
  }
  if (perm != PhoneMicPermission.granted) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('mic-perm-dialog'),
        title: const Text('需要麦克风权限'),
        content: const Text('使用手机「本机录音」需开启系统麦克风权限，请前往系统设置允许后重试。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return;
  }
  await store.startPhoneRecording(islandEnabled: islandEnabled);
}

/// 共用的手机「本机录音」行：无硬件时也可独立使用；开启期间同步驱动灵动岛。
class _PhoneRecRow extends StatelessWidget {
  const _PhoneRecRow({
    required this.store,
    required this.islandEnabled,
  });

  final DeviceStore store;
  final bool islandEnabled;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final on = store.isPhoneRecording;
    final busy = store.phoneRecordingBusy;
    return Column(
      key: const Key('phone-rec-row'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Row(
          label: '本机录音',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: busy
                    ? Text(
                        '处理中…',
                        style: TextStyle(fontSize: 13, color: c.sec),
                      )
                    : on
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: c.danger,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              store.isFailoverPhoneRecording
                                  ? '本机保底录音中'
                                  : '本机录音中',
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: TextStyle(fontSize: 13, color: c.label),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            store.phoneRecClockText,
                            key: const Key('phone-rec-clock'),
                            softWrap: false,
                            style: TextStyle(
                              fontSize: 13,
                              color: c.label,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        '使用手机麦克风',
                        style: TextStyle(fontSize: 13, color: c.sec),
                      ),
              ),
              const SizedBox(width: 10),
              Semantics(
                label: '本机录音开关',
                toggled: on,
                button: true,
                enabled: !busy,
                child: GestureDetector(
                  key: const Key('phone-rec-toggle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(
                    _togglePhoneRecordingWithPermission(
                      context,
                      store,
                      islandEnabled: islandEnabled,
                    ),
                  ),
                  child: RCSwitch(on: on, busy: busy),
                ),
              ),
            ],
          ),
        ),
        if (store.phoneRecordingError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              store.phoneRecordingError!,
              key: const Key('phone-rec-error'),
              style: TextStyle(fontSize: 12, color: c.danger),
            ),
          ),
      ],
    );
  }
}

class _MainView extends StatelessWidget {
  const _MainView({
    required this.store,
    this.agentConfig,
    this.islandEnabled = true,
  });
  final DeviceStore store;
  final AgentConfigStore? agentConfig;
  final bool islandEnabled;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    if (!store.isConnected) {
      return _ConnectView(store: store, islandEnabled: islandEnabled);
    }
    return Column(
      key: const Key('dev-main'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  key: const Key('dev-dot'),
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    // 绿=录音中，橙=已连接待机
                    color: store.isRecording ? c.ok : c.warn,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                DeviceKindBadge(
                  key: const Key('dev-header-kind'),
                  kind: store.activeKind,
                  label: store.activeModelLabel,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    store.connectedDisplayName,
                    key: const Key('dev-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: c.label,
                    ),
                  ),
                ),
                Semantics(
                  button: true,
                  label: '断开连接',
                  child: GestureDetector(
                    key: const Key('dev-disconnect'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _confirmDisconnect(context, store),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: RCIcon(
                        RCIconKind.disconnect,
                        size: 18,
                        color: c.sec,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Row(
                children: [
                  RCIcon(
                    RCIconKind.bluetooth,
                    key: const Key('dev-bt-icon'),
                    size: 12,
                    color: c.sec,
                  ),
                  if (store.deviceSubtitleText.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        store.deviceSubtitleText,
                        key: const Key('dev-subtitle'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: c.sec,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        Divider(height: 24, color: c.sep),
        // 录音状态：关闭时显示「未录音」+ 开关；打开后红点 + 录音中 + 正计时。
        // 开关本身就是入口，避免再去别处找「开始录音」。
        _Row(
          label: '录音状态',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 文本部分可压缩（录音中 + 计时可能很长），开关固定宽度不缩
              Flexible(
                child: AnimatedSwitcher(
                key: const Key('recval'),
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    sizeFactor: animation,
                    axis: Axis.horizontal,
                    child: child,
                  ),
                ),
                child: store.recordingBusy
                    // 命令在跑：这里必须给出可见反馈。蓝牙被占时这一等可能十几秒，
                    // 只在开关上做 50% 半透明肉眼看不出，用户会以为点坏了。
                    ? Text(
                        '处理中…',
                        key: const ValueKey('rec-busy'),
                        style: TextStyle(fontSize: 14, color: c.sec),
                      )
                    : store.isRecording
                    ? Row(
                        key: const ValueKey('rec-on'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: c.danger,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          // 「录音中 00:00:00」放不下时省略「录音中」，计时优先保住
                          Flexible(
                            child: Text(
                              '录音中',
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: TextStyle(fontSize: 14, color: c.label),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            store.recClockText,
                            key: const Key('rec-clock'),
                            softWrap: false, // 等宽数字单行，不折行
                            style: TextStyle(
                              fontSize: 14,
                              color: c.label,
                              fontFeatures: const [FontFeature.tabularFigures()],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        '未录音',
                        key: const ValueKey('rec-off'),
                        style: TextStyle(fontSize: 14, color: c.sec),
                      ),
                ),
              ),
              const SizedBox(width: 10),
              if (store.activeCapabilities.hasRemoteRecordControl)
                Semantics(
                  label: '录音开关',
                  toggled: store.isRecording,
                  button: true,
                  // 自绘开关必须自己声明启用状态：不声明的话系统（读屏/自动化）
                  // 会把它当成"不可用"，与它实际可点的事实矛盾。
                  enabled: !store.recordingBusy,
                  child: GestureDetector(
                    key: const Key('rec-toggle'),
                    behavior: HitTestBehavior.opaque,
                    // 忙时也保留手势：点击由 store 给出「请稍候」的可见反馈，
                    // 而不是把点击静默吞掉。
                    onTap: store.toggleRecording,
                    child: RCSwitch(
                      on: store.isRecording,
                      busy: store.recordingBusy,
                    ),
                  ),
                )
              else
                Container(
                  key: const Key('rec-physical-only'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: c.isDark
                        ? const Color(0xFF242428)
                        : const Color(0xFFF0F0EC),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '机身按键控录',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.sec,
                    ),
                  ),
                ),
            ],
          ),
        ),
        _Row(
          label: '电量',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              BatteryIcon(level: store.battery, charging: store.isCharging),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  store.activeCapabilities.hasOnboardStorage
                      ? '${store.batteryLevelText} · 可录至 ${store.batteryEtaText}'
                      : store.batteryLevelText,
                  key: const Key('batt-eta'),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(fontSize: 14, color: c.label),
                ),
              ),
            ],
          ),
        ),
        // 已连蓝牙硬件时不展示独立「本机录音」行（硬件录音期间本机自动进入零功耗待命保底，意外断连自动接力）
        // 同步行：仅具备本地存储/文件补传能力的设备展示（如录音卡 V2、点一机 V1；键盘 V2.1 隐藏）
        if (store.activeCapabilities.hasFileSync)
          _Row(
            keyName: 'sync-now',
            label: '同步',
            onTap: store.syncNow,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    store.syncText,
                    key: const Key('sync-txt'),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(fontSize: 14, color: c.label),
                  ),
                ),
                const SizedBox(width: 7),
                SizedBox(
                  width: 16,
                  height: 16,
                  child: switch (store.syncState) {
                    SyncState.idle => RCIcon(
                      RCIconKind.sync,
                      key: const Key('sync-ico-idle'),
                      size: 15,
                      color: c.sec,
                    ),
                    SyncState.busy => const _SpinIcon(key: Key('sync-ico-busy')),
                    SyncState.done => RCIcon(
                      RCIconKind.check,
                      key: const Key('sync-ico-done'),
                      size: 15,
                      color: c.ok,
                    ),
                  },
                ),
              ],
            ),
          ),
        if (showWifiRow && store.activeCapabilities.hasWifiConfig)
          _Row(
            keyName: 'wifi-row',
            label: 'Wi-Fi',
            onTap: () => store.showView(DeviceView.wifi),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    '已配置 · ${store.wifiCountShown} 个网络',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(fontSize: 14, color: c.label),
                  ),
                ),
                const SizedBox(width: 5),
                RCIcon(
                  RCIconKind.chevronRight,
                  key: const Key('rowchev-wifi'),
                  size: 15,
                  color: c.ax,
                ),
              ],
            ),
          ),
        if (store.activeCapabilities.hasOta)
          _Row(
            keyName: 'fw-update',
            label: '固件',
            onTap: () => store.showView(DeviceView.upg),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    store.fwValText,
                    key: const Key('fw-val'),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 14,
                      color: store.fwValText == '正在检查…'
                          ? c.sec
                          : (store.fwStage == FwStage.failed
                                ? c.danger
                                : c.okInk),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                RCIcon(RCIconKind.chevronRight, size: 15, color: c.ax),
              ],
            ),
          ),
        if (store.activeCapabilities.hasConfigurableButtons &&
            agentConfig != null)
          ListenableBuilder(
            listenable: agentConfig!,
            builder: (context, _) => _Row(
              keyName: 'btn-config',
              label: '按键行为设置',
              onTap: () => store.showView(DeviceView.btn),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      agentConfig!.buttonConfiguredLabel(
                        hasConfigurableSwitch:
                            store.activeCapabilities.hasConfigurableSwitch,
                        kind: store.activeKind,
                      ),
                      key: const Key('btn-config-val'),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(fontSize: 14, color: c.label),
                    ),
                  ),
                  const SizedBox(width: 5),
                  RCIcon(
                    RCIconKind.chevronRight,
                    size: 15,
                    color: c.ax,
                  ),
                ],
              ),
            ),
          ),
        if (store.activeCapabilities.hasMoreDeviceActions)
          _Row(
            keyName: 'more-row',
            label: '更多',
            onTap: () => store.showView(DeviceView.more),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RCIcon(
                  RCIconKind.chevronRight,
                  key: const Key('rowchev-more'),
                  size: 15,
                  color: c.ax,
                ),
              ],
            ),
          ),
        if (store.devStateText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              store.devStateText,
              key: const Key('dev-state'),
              style: TextStyle(fontSize: 12, color: c.okInk),
            ),
          ),
        // 录音失败就地展示：弹层盖住整个屏幕，SnackBar 在它下面根本看不见。
        if (store.recordingError != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              store.recordingError!,
              key: const Key('rec-error'),
              style: TextStyle(fontSize: 12, color: c.danger),
            ),
          ),
        if (store.syncError != null && store.syncError!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              store.syncError!,
              key: const Key('sync-error'),
              style: TextStyle(fontSize: 12, color: c.sec),
            ),
          ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('sheet-close'),
            onPressed: store.closeSheet,
            style: FilledButton.styleFrom(
              backgroundColor: c.label,
              foregroundColor: c.onLabel,
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

/// 断开连接前的确认与收尾。
///
/// 顺序很重要：先停录音 → 关实时流 → 停同步 → 断开链路。
/// 直接在录音/传输中途断开会留下半截会话，下一次连接容易出现状态错乱。
Future<void> _confirmDisconnect(BuildContext context, DeviceStore store) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('断开与录音卡的连接？'),
      content: const Text('断开后将停止录音与同步，需要时可在弹层里重新连接。'),
      actions: [
        TextButton(
          key: const Key('disconnect-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('disconnect-confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: ctx.rc.danger,
            foregroundColor: Colors.white,
          ),
          child: const Text('断开连接'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await store.disconnectSafely();
}

String _scanFailureHint(String error) {
  if (error.contains('蓝牙扫描通道异常中断') ||
      error.contains('蓝牙通道') ||
      error.contains('Channel closed')) {
    return '请先开关一次手机蓝牙，或把录音卡关机再开机后重试';
  }
  if (error.contains('蓝牙模块没有载入') || error.contains('不支持连接录音卡')) {
    return '重装当前安装包无法恢复，请安装包含蓝牙桥的真机版本';
  }
  return '请确认录音卡已开机，并放在手机附近';
}

/// 未连接视图：搜索并连接附近的录音卡，并支持无硬件独立开启「本机录音」。
class _ConnectView extends StatelessWidget {
  const _ConnectView({
    required this.store,
    this.islandEnabled = true,
  });
  final DeviceStore store;
  final bool islandEnabled;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final busy = store.isLinkBusy;
    final scanOrConnectBusy =
        store.linkState == LinkState.scanning ||
        store.linkState == LinkState.connecting;
    final bleExpired = store.isBleScanExpired;
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
                color: (store.isPhoneRecording || store.isWatchFallbackRecording)
                    ? c.ok
                    : (store.isPendingForegroundPhoneFailover ? c.warn : null),
                border:
                    (store.isPhoneRecording ||
                        store.isWatchFallbackRecording ||
                        store.isPendingForegroundPhoneFailover)
                    ? null
                    : Border.all(color: c.ax, width: 1.4),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '录音卡',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: c.label,
                    ),
                  ),
                  Row(
                    children: [
                      RCIcon(
                        RCIconKind.bluetooth,
                        size: 12,
                        color: c.sec,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '待连接硬件',
                        style: TextStyle(fontSize: 12, color: c.sec),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c.isDark
                    ? const Color(0xFF242428)
                    : const Color(0xFFF0F0EC),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '未连接',
                key: const Key('dev-link-chip'),
                style: TextStyle(fontSize: 11, color: c.sec),
              ),
            ),
          ],
        ),
        if (store.disconnectNotice != null &&
            store.disconnectNotice!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            key: const Key('ble-disconnect-banner'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: c.isDark
                  ? const Color(0xFF262016)
                  : const Color(0xFFFFF7E6),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.warn.withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  store.disconnectNotice!,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    color: c.label,
                  ),
                ),
                if (store.isBackgroundReconnectArmed) ...[
                  const SizedBox(height: 3),
                  Text(
                    '后台自动重连已开启，设备回到附近将自动恢复并合并数据',
                    style: TextStyle(fontSize: 11.5, color: c.sec),
                  ),
                ],
              ],
            ),
          ),
        ],
        Divider(height: 20, color: c.sep),
        if (store.isWatchFallbackRecording)
          _Row(
            keyName: 'watch-failover-row',
            label: '手表保底',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: c.danger,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          'Apple Watch 接力录音中',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(fontSize: 13, color: c.label),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        store.watchFailoverClockText,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 13,
                          color: c.label,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  key: const Key('watch-failover-toggle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(store.stopWatchFailoverRecording()),
                  child: const RCSwitch(on: true, busy: false),
                ),
              ],
            ),
          )
        else
          _PhoneRecRow(store: store, islandEnabled: islandEnabled),
        if (store.isPendingForegroundPhoneFailover &&
            !store.isPhoneRecording &&
            !store.isWatchFallbackRecording) ...[
          const SizedBox(height: 8),
          Container(
            key: const Key('phone-failover-pending-banner'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: c.isDark
                  ? const Color(0xFF1F242D)
                  : const Color(0xFFF3F6FC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: c.sep),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '蓝牙断开时因系统后台限制未直接启用手机麦克风',
                  style: TextStyle(fontSize: 12, color: c.sec),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  key: const Key('phone-failover-resume-btn'),
                  onPressed: store.phoneRecordingBusy
                      ? null
                      : () => unawaited(
                          store.startPhoneRecording(
                            forFailover: true,
                            islandEnabled: islandEnabled,
                          ),
                        ),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.label,
                    foregroundColor: c.onLabel,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                  ),
                  child: const Text(
                    '立即开启本机保底录音',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
        Divider(height: 18, color: c.sep),
        Text(
          '连接录音卡',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: c.label,
          ),
        ),
        const SizedBox(height: 4),
        if (store.linkState == LinkState.scanning)
          Row(
            key: const Key('dev-scan-state'),
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '正在通过蓝牙扫描附近的录音卡…',
                  style: TextStyle(fontSize: 13, color: c.ink),
                ),
              ),
            ],
          )
        else if (store.linkState == LinkState.connecting)
          Row(
            key: const Key('dev-connecting-state'),
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                '正在连接录音卡…',
                style: TextStyle(fontSize: 13, color: c.ink),
              ),
            ],
          )
        else if (store.linkState == LinkState.reconnecting)
          Row(
            key: const Key('dev-reconnecting-state'),
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '正在重连录音卡…',
                  style: TextStyle(fontSize: 13, color: c.ink),
                ),
              ),
            ],
          )
        else if (bleExpired)
          Text(
            '蓝牙设备列表已过期，请重新扫描',
            key: const Key('dev-scan-expired-hint'),
            style: TextStyle(
              fontSize: 13,
              color: c.isDark ? c.warn : const Color(0xFF8A5A10),
              fontWeight: FontWeight.w500,
            ),
          )
        else if (store.linkError != null)
          Column(
            key: const Key('dev-scan-empty'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                store.linkError!,
                style: TextStyle(fontSize: 13, color: c.ink),
              ),
              const SizedBox(height: 4),
              Text(
                _scanFailureHint(store.linkError!),
                style: TextStyle(fontSize: 12, color: c.sec),
              ),
            ],
          )
        else
          Text(
            '选择要连接的录音卡（按信号强弱排序）',
            key: const Key('dev-pick-hint'),
            style: TextStyle(fontSize: 13, color: c.sec),
          ),
        for (final device in store.discovered) ...[
          const SizedBox(height: 10),
          _ConnectDeviceTile(
            device: device,
            expired: store.isDeviceScanExpired(device),
            busy: busy,
            onTap: () => store.connectTo(device),
          ),
        ],
        const SizedBox(height: 16),
        if (bleExpired) ...[
          FilledButton(
            key: const Key('dev-rescan'),
            onPressed: scanOrConnectBusy
                ? null
                : () => store.startScan(userInitiated: true),
            style: FilledButton.styleFrom(
              backgroundColor: c.label,
              foregroundColor: c.onLabel,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('重新扫描'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('sheet-close'),
            onPressed: store.closeSheet,
            style: OutlinedButton.styleFrom(
              foregroundColor: c.label,
              side: BorderSide(color: c.ax),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: const Text('关闭'),
          ),
        ] else ...[
          OutlinedButton(
            key: const Key('dev-rescan'),
            onPressed: scanOrConnectBusy
                ? null
                : () => store.startScan(userInitiated: true),
            style: OutlinedButton.styleFrom(
              foregroundColor: c.label,
              side: BorderSide(color: c.ax),
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
              backgroundColor: c.label,
              foregroundColor: c.onLabel,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text('关闭'),
          ),
        ],
      ],
    );
  }
}

class _ConnectDeviceTile extends StatelessWidget {
  const _ConnectDeviceTile({
    required this.device,
    required this.expired,
    required this.busy,
    required this.onTap,
  });

  final CardDevice device;
  final bool expired;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final disabled = busy || expired;
    return Semantics(
      button: true,
      enabled: !disabled,
      child: InkWell(
        key: Key('dev-item-${device.id}'),
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: expired
                ? (c.isDark
                      ? const Color(0xFF202024)
                      : const Color(0xFFF5F5F2))
                : null,
            border: Border.all(color: c.sep),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Opacity(
            opacity: expired ? 0.55 : 1.0,
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      DeviceKindBadge(
                        key: Key('dev-kind-${device.id}'),
                        kind: device.deviceKind,
                        label: device.modelLabel,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          device.shortName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.label,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _SignalBars(strength: DeviceStore.signalOf(device.rssi)),
                const SizedBox(width: 10),
                if (expired)
                  Text(
                    '已过期',
                    key: Key('dev-expired-${device.id}'),
                    style: TextStyle(fontSize: 12, color: c.sec),
                  )
                else ...[
                  Text(
                    '连接',
                    style: TextStyle(fontSize: 12, color: c.okInk),
                  ),
                  const SizedBox(width: 4),
                  RCIcon(
                    RCIconKind.chevronRight,
                    size: 15,
                    color: c.ax,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
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
    child: RCIcon(RCIconKind.sync, size: 15, color: context.rc.ink),
  );
}

class _FirmwareView extends StatelessWidget {
  const _FirmwareView({
    required this.store,
    this.islandEnabled = true,
  });
  final DeviceStore store;
  final bool islandEnabled;

  Future<void> _onStartPressed(BuildContext context) async {
    if (!store.isRecording) {
      await store.startFwUpdate(islandEnabled: islandEnabled);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('ota-rec-confirm-dialog'),
        title: const Text('当前正在录音，开始更新会导致录音停止'),
        content: const Text(
          '升级期间硬件录音将暂停并重启。确认后将自动切换到手机「本机录音」无缝接力，'
          '待硬件升级重连后自动关闭本机录音，确保录音数据不断。',
        ),
        actions: [
          TextButton(
            key: const Key('ota-rec-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('ota-rec-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: ctx.rc.label,
              foregroundColor: ctx.rc.onLabel,
            ),
            child: const Text('继续更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    var perm = await store.checkPhoneMicPermission();
    if (perm == PhoneMicPermission.notDetermined) {
      perm = await store.requestPhoneMicPermission();
    }
    if (perm != PhoneMicPermission.granted) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('ota-mic-perm-dialog'),
          title: const Text('需要开启麦克风权限'),
          content: const Text(
            '硬件升级重连期间需使用手机麦克风进行「本机录音」接力以防数据中断，'
            '请先允许「录音卡」访问麦克风后再重试更新。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    await store.startFwUpdate(
      allowStopRecordingAndHandover: true,
      islandEnabled: islandEnabled,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Column(
      key: const Key('dev-upg'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '固件更新',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: c.label,
          ),
        ),
        const SizedBox(height: 6),
        _Row(
          label: store.activeCapabilities.hasSingleOta ? '系统固件' : '主控芯片',
          child: Text(
            store.mainVersionCompare,
            key: const Key('fw-main-ver'),
            style: TextStyle(fontSize: 13, color: c.label),
          ),
        ),
        if (store.activeCapabilities.hasDualChipOta)
          _Row(
            label: 'Wi-Fi 芯片',
            child: Text(
              store.wifiVersionCompare,
              key: const Key('fw-wifi-ver'),
              style: TextStyle(fontSize: 13, color: c.label),
            ),
          ),
        if (store.fwError != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  store.fwError!,
                  key: const Key('fw-error'),
                  style: TextStyle(
                    fontSize: 12,
                    color: c.danger,
                    height: 1.6,
                  ),
                ),
                if (!store.fwUpdating &&
                    store.fwError!.contains('Wi-Fi') &&
                    store.activeCapabilities.hasWifiConfig)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('upg-goto-wifi'),
                      onPressed: () => store.showView(DeviceView.wifi),
                      style: TextButton.styleFrom(
                        foregroundColor: c.ink,
                        padding: const EdgeInsets.only(top: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('去设置 Wi-Fi ›'),
                    ),
                  ),
              ],
            ),
          ),
        if (store.fwUpdating)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '更新期间请保持设备连接，切勿退出本页或关闭手机屏幕。',
              key: const Key('upg-warn'),
              style: TextStyle(fontSize: 12, color: c.danger),
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
              backgroundColor: c.sep,
              valueColor: AlwaysStoppedAnimation(c.ok),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                store.fwStageText,
                key: const Key('upg-stage'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.label,
                ),
              ),
              Text(
                store.fwPctText,
                style: TextStyle(fontSize: 12, color: c.sec),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            store.fwStateText,
            key: const Key('upg-state'),
            style: TextStyle(fontSize: 12, color: c.sec),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('upg-btn'),
            onPressed: (store.fwUpdating ||
                    store.fwStage == FwStage.checking ||
                    !store.fwAvailable)
                ? null
                : () => unawaited(_onStartPressed(context)),
            style: FilledButton.styleFrom(
              backgroundColor: c.label,
              disabledBackgroundColor: c.ax,
              foregroundColor: c.onLabel,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: Text(
              store.fwStage == FwStage.checking
                  ? '正在检查更新…'
                  : store.fwAvailable
                  ? '开始更新'
                  : '已是最新',
            ),
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
              foregroundColor: c.ink,
              disabledForegroundColor: c.ax,
              side: BorderSide(color: c.ax),
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
    final c = context.rc;
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
            color: i <= strength ? c.ink : c.ax,
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
    final c = context.rc;
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
              icon: RCIcon(
                RCIconKind.chevronLeft,
                size: 18,
                color: c.ink,
              ),
              color: c.ink,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            ),
            const SizedBox(width: 4),
            Text(
              'Wi-Fi 设置',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: c.label,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '已保存',
            style: TextStyle(fontSize: 12, color: c.sec),
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
                        color: inRange ? c.label : c.sec,
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
                      style: TextStyle(fontSize: 12, color: c.sec),
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
                foregroundColor: c.sec,
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
        Divider(height: 18, color: c.sep),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '可用网络',
            style: TextStyle(fontSize: 12, color: c.sec),
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            store.wifiStateText,
            key: const Key('wstate'),
            style: TextStyle(fontSize: 12, color: c.sec),
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
                style: TextStyle(fontSize: 12, color: c.danger),
              ),
            ),
          ),
        if (store.wifiError != null &&
            (isLikely5GhzSsid(store.wifiJoinName) ||
                isLikely5GhzSsid(store.wifiSelName ?? '') ||
                isLikely5GhzSsid(store.wifiError!)))
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '当前硬件仅支持 2.4GHz Wi-Fi，请改用非 5G 频段路由或 2.4GHz 热点',
                key: const Key('wifi-5g-hint'),
                style: TextStyle(fontSize: 11.5, color: c.warn),
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
            _availRow(c, store, r),
            if (store.wifiSelName == r.name) _joinForm(c, store, r),
          ],
        const SizedBox(height: 8),
        Text(
          '录音卡仅支持 2.4GHz 网络，此处只显示 2.4GHz 接入点',
          style: TextStyle(fontSize: 11, color: c.sec),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: store.wifiScan,
            style: OutlinedButton.styleFrom(
              foregroundColor: c.ink,
              side: BorderSide(color: c.ax),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 11),
            ),
            child: const Text('重新扫描'),
          ),
        ),
      ],
    );
  }

  Widget _availRow(RCColorScheme c, DeviceStore store, WifiNet r) {
    final saved = store.wifiSaved.any((s) => s.name == r.name);
    final joining = store.wifiJoining && store.wifiJoinName == r.name;
    if (joining) {
      return Padding(
        key: Key('witem-${r.name}'),
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Text(r.name, style: TextStyle(fontSize: 14, color: c.label)),
            const Spacer(),
            Text(
              '正在连接…',
              style: TextStyle(fontSize: 12, color: c.sec),
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
            Text(r.name, style: TextStyle(fontSize: 14, color: c.label)),
            if (saved) ...[
              const SizedBox(width: 6),
              const _Chip('已保存', subtle: true),
            ],
            const Spacer(),
            if (r.lock) ...[
              RCIcon(RCIconKind.lock, size: 12, color: c.sec),
              const SizedBox(width: 5),
            ],
            _SignalBars(strength: r.signal),
          ],
        ),
      ),
    );
  }

  Widget _joinForm(RCColorScheme c, DeviceStore store, WifiNet r) {
    final verifying = store.wifiJoining && store.wifiJoinName == r.name;
    final warn5g = store.wifiError == null && isLikely5GhzSsid(r.name);
    return Padding(
      key: Key('wform-${r.name}'),
      padding: const EdgeInsets.only(left: 12, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r.name,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: c.label,
            ),
          ),
          if (warn5g) ...[
            const SizedBox(height: 4),
            Text(
              '提示：SSID 疑似 5GHz 频段；硬件仅支持 2.4GHz Wi-Fi，请确认该热点的 2.4GHz 广播已开启',
              key: const Key('wifi-5g-hint'),
              style: TextStyle(fontSize: 11.5, color: c.warn),
            ),
          ],
          const SizedBox(height: 6),
          if (verifying)
            Text(
              '正在验证连接可行性…',
              style: TextStyle(fontSize: 12, color: c.sec),
            )
          else ...[
            SizedBox(
              height: 36,
              child: TextField(
                key: const Key('wifi-pwd'),
                controller: _pwdCtrl,
                obscureText: true,
                style: TextStyle(fontSize: 14, color: c.label),
                decoration: InputDecoration(
                  hintText: '输入网络密码',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.sep),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.sep),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.label),
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
                    foregroundColor: c.ink,
                    side: BorderSide(color: c.ax),
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
                    backgroundColor: c.label,
                    foregroundColor: c.onLabel,
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

class _ButtonConfigView extends StatelessWidget {
  const _ButtonConfigView({required this.store, this.agentConfig});

  final DeviceStore store;
  final AgentConfigStore? agentConfig;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final config = agentConfig;
    final isCardControl = store.activeCapabilities.hasConfigurableSwitch;
    return Column(
      key: const Key('btn-config-view'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('btn-cfg-back'),
              onPressed: () => store.showView(DeviceView.main),
              icon: RCIcon(
                RCIconKind.chevronLeft,
                size: 18,
                color: c.ink,
              ),
              color: c.ink,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            ),
            const SizedBox(width: 4),
            Text(
              '按键行为设置',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: c.label,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isCardControl
              ? '配置录音卡物理按键与侧边拨杆触发的动作，修改后自动同步到硬件；若软件蓝牙开关与拨杆状态不一致，以软件蓝牙开关为准。'
              : (store.activeKind == DeviceKind.omiCv1
                    ? '配置 Omi 录音器物理按键动作。因固件写死长按约 3 秒直接关机且蓝牙不可改，已禁用长按交互以防误触关机；推荐将双击设为「语音任务」（双击开始说话、再双击发送）。'
                    : '配置点一机 V1 物理按键触发的动作；未开启持续录音时触发「语音任务」将自动开启临时录音并在完成后关闭。'),
          style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
        ),
        const SizedBox(height: 12),
        if (config == null)
          Text(
            '暂无按键配置上下文',
            style: TextStyle(fontSize: 13, color: c.sec),
          )
        else
          ListenableBuilder(
            listenable: Listenable.merge([config, store]),
            builder: (context, _) {
              final rc = context.rc;
              final err = store.cardControlsError;
              final isOmi = store.activeKind == DeviceKind.omiCv1;
              final nonCardActions = isOmi
                  ? HardwareButtonAction.dyjButtonOptions
                        .where((a) => a != HardwareButtonAction.photoRecognize)
                        .toList(growable: false)
                  : HardwareButtonAction.dyjButtonOptions;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isCardControl && store.cardControlsSyncing)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '正在同步硬件按键设置…',
                            style: TextStyle(fontSize: 12, color: rc.sec),
                          ),
                        ],
                      ),
                    ),
                  if (isCardControl && err != null && err.isNotEmpty)
                    Container(
                      key: const Key('btn-cfg-error'),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: rc.danger.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: rc.danger.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        err,
                        style: TextStyle(fontSize: 12, color: rc.danger),
                      ),
                    ),
                  if (isCardControl) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '物理按钮',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: rc.sec,
                        ),
                      ),
                    ),
                    _gestureSection(
                      rc: rc,
                      key: const Key('btn-cfg-click'),
                      gesture: 'click',
                      title: '单击',
                      actions: HardwareButtonAction.cardButtonOptions,
                      current: config.cardClickAction,
                      onPick: (a) => unawaited(
                        store.applyCardControlAction(config, 'click', a),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _gestureSection(
                      rc: rc,
                      key: const Key('btn-cfg-double'),
                      gesture: 'double_click',
                      title: '双击',
                      actions: HardwareButtonAction.cardButtonOptions,
                      current: config.cardDoubleClickAction,
                      onPick: (a) => unawaited(
                        store.applyCardControlAction(
                          config,
                          'double_click',
                          a,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _gestureSection(
                      rc: rc,
                      key: const Key('btn-cfg-long'),
                      gesture: 'long_press',
                      title: '长按',
                      actions: HardwareButtonAction.cardButtonOptions,
                      current: config.cardLongPressAction,
                      onPick: (a) => unawaited(
                        store.applyCardControlAction(config, 'long_press', a),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '侧边拨杆',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: rc.sec,
                        ),
                      ),
                    ),
                    _gestureSection(
                      rc: rc,
                      key: const Key('btn-cfg-switch_on'),
                      gesture: 'switch_on',
                      title: '拨杆打开',
                      actions: HardwareButtonAction.cardSwitchOptions,
                      current: config.cardSwitchOnAction,
                      onPick: (a) => unawaited(
                        store.applyCardControlAction(config, 'switch_on', a),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _gestureSection(
                      rc: rc,
                      key: const Key('btn-cfg-switch_off'),
                      gesture: 'switch_off',
                      title: '拨杆关闭',
                      actions: HardwareButtonAction.cardSwitchOptions,
                      current: config.cardSwitchOffAction,
                      onPick: (a) => unawaited(
                        store.applyCardControlAction(config, 'switch_off', a),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      key: const Key('btn-cfg-reset-default'),
                      onPressed: store.cardControlsSyncing
                          ? null
                          : () => unawaited(
                              store.resetCardControlsToDefaults(config),
                            ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: rc.ink,
                        side: BorderSide(color: rc.sep),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Text(
                        '恢复默认按键行为',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ] else ...[
                    _gestureSection(
                      rc: rc,
                      key: const Key('btn-cfg-click'),
                      gesture: 'click',
                      title: '单击',
                      actions: nonCardActions,
                      current: isOmi
                          ? config.omiClickAction
                          : config.dyjClickAction,
                      onPick: (a) => unawaited(
                        isOmi
                            ? config.setOmiButtonAction('click', a)
                            : config.setDyjButtonAction('click', a),
                      ),
                    ),
                    if (!isOmi) ...[
                      const SizedBox(height: 12),
                      _gestureSection(
                        rc: rc,
                        key: const Key('btn-cfg-long'),
                        gesture: 'long_press',
                        title: '长按',
                        actions: nonCardActions,
                        current: config.dyjLongPressAction,
                        onPick: (a) => unawaited(
                          config.setDyjButtonAction('long_press', a),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _gestureSection(
                      rc: rc,
                      key: const Key('btn-cfg-double'),
                      gesture: 'double_click',
                      title: '双击',
                      actions: nonCardActions,
                      current: isOmi
                          ? config.omiDoubleClickAction
                          : config.dyjDoubleClickAction,
                      onPick: (a) => unawaited(
                        isOmi
                            ? config.setOmiButtonAction('double_click', a)
                            : config.setDyjButtonAction('double_click', a),
                      ),
                    ),
                    if (isOmi) ...[
                      const SizedBox(height: 12),
                      Container(
                        key: const Key('btn-cfg-omi-no-long'),
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: rc.isDark ? const Color(0xFF222226) : rc.bg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: rc.sep),
                        ),
                        child: Text(
                          '不支持长按：Omi 硬件长按约 3 秒将直接触发关机',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: rc.sec,
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _gestureSection({
    required RCColorScheme rc,
    required Key key,
    required String gesture,
    required String title,
    required List<HardwareButtonAction> actions,
    required HardwareButtonAction current,
    required ValueChanged<HardwareButtonAction> onPick,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: rc.isDark ? const Color(0xFF222226) : rc.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: rc.sep),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: rc.label,
                ),
              ),
              const Spacer(),
              Text(
                current.shortLabel,
                style: TextStyle(fontSize: 12, color: rc.sec),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final act in actions)
                InkWell(
                  key: Key('btn-cfg-$gesture-${act.code}'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onPick(act),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: current == act ? rc.label : rc.card,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: current == act ? rc.label : rc.sep,
                      ),
                    ),
                    child: Text(
                      act.shortLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: current == act ? rc.onLabel : rc.ink,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MoreView extends StatelessWidget {
  const _MoreView({required this.store});

  final DeviceStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final caps = store.activeCapabilities;
    final busy = store.devicePowerBusy;
    final err = store.devicePowerError;
    return Column(
      key: const Key('more-view'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('more-back'),
              onPressed: busy ? null : () => store.showView(DeviceView.main),
              icon: RCIcon(
                RCIconKind.chevronLeft,
                size: 18,
                color: c.ink,
              ),
              color: c.ink,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            ),
            const SizedBox(width: 4),
            Text(
              '更多',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: c.label,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '管理已连接硬件的重启与电源操作。',
          style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
        ),
        if (err != null && err.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            err,
            key: const Key('more-power-error'),
            style: TextStyle(fontSize: 12, color: c.danger),
          ),
        ],
        if (caps.hasDeviceRestart) ...[
          const SizedBox(height: 12),
          _PowerActionCard(
            rc: c,
            title: '重启设备',
            description: '重新启动硬件以恢复异常录音状态，重启后将自动尝试重新连接。',
            buttonKey: const Key('more-restart-btn'),
            buttonLabel: busy ? '正在执行…' : '重启设备',
            onPressed: busy ? null : () => _confirmRestart(context, store),
          ),
        ],
        if (caps.hasDeviceShutdown) ...[
          const SizedBox(height: 10),
          _PowerActionCard(
            rc: c,
            title: '关机',
            description: '关闭硬件电源并断开蓝牙连接，下次使用需通过机身按键开机。',
            buttonKey: const Key('more-shutdown-btn'),
            buttonLabel: busy ? '正在执行…' : '关机',
            danger: true,
            onPressed: busy ? null : () => _confirmShutdown(context, store),
          ),
        ],
      ],
    );
  }
}

class _PowerActionCard extends StatelessWidget {
  const _PowerActionCard({
    required this.rc,
    required this.title,
    required this.description,
    required this.buttonKey,
    required this.buttonLabel,
    required this.onPressed,
    this.danger = false,
  });

  final RCColorScheme rc;
  final String title;
  final String description;
  final Key buttonKey;
  final String buttonLabel;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rc.isDark ? const Color(0xFF222226) : rc.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: rc.sep),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: rc.label,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: TextStyle(fontSize: 12, height: 1.45, color: rc.sec),
          ),
          const SizedBox(height: 10),
          if (danger)
            OutlinedButton(
              key: buttonKey,
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: rc.danger,
                side: BorderSide(color: rc.danger.withValues(alpha: 0.45)),
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
              child: Text(buttonLabel),
            )
          else
            FilledButton(
              key: buttonKey,
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: rc.label,
                foregroundColor: rc.onLabel,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(vertical: 11),
              ),
              child: Text(buttonLabel),
            ),
        ],
      ),
    );
  }
}

Future<bool> _confirmPowerDialog(
  BuildContext context, {
  required String title,
  required String content,
  required Key cancelKey,
  required Key confirmKey,
  required String confirmLabel,
  bool danger = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final rc = ctx.rc;
      return AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            key: cancelKey,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: confirmKey,
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: danger ? rc.danger : rc.label,
              foregroundColor: danger ? Colors.white : rc.onLabel,
            ),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return ok == true;
}

Future<void> _confirmRestart(BuildContext context, DeviceStore store) async {
  final ok = await _confirmPowerDialog(
    context,
    title: '重启硬件设备？',
    content: '重启将暂时中断当前蓝牙连接与录音（约数秒），完成后将自动尝试重新连接。',
    cancelKey: const Key('restart-cancel'),
    confirmKey: const Key('restart-confirm'),
    confirmLabel: '重启设备',
  );
  if (!ok) return;
  await store.restartDevice();
}

Future<void> _confirmShutdown(BuildContext context, DeviceStore store) async {
  final ok = await _confirmPowerDialog(
    context,
    title: '关闭硬件电源？',
    content: '关机后将停止录音并断开蓝牙连接，再次使用需手动按机身按键开机。',
    cancelKey: const Key('shutdown-cancel'),
    confirmKey: const Key('shutdown-confirm'),
    confirmLabel: '确认关机',
    danger: true,
  );
  if (!ok) return;
  await store.shutdownDevice();
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, {this.subtle = false});
  final String label;
  final bool subtle;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: subtle
            ? (c.isDark ? const Color(0xFF242428) : const Color(0xFFF0F0EC))
            : (c.isDark
                  ? c.ok.withValues(alpha: 0.16)
                  : const Color(0xFFE8F5EA)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: subtle ? c.ink : c.okInk,
        ),
      ),
    );
  }
}
