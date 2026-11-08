/// 应用外壳 —— 窄屏（顶栏面包屑 + 底栏导航，子页隐藏底栏）与
/// 宽屏 ≥720px 双栏（左栏 Timeline 常显 + 右栏详情/空态，面包屑停用、面板内返回）。
library;
import 'package:flutter/material.dart';

import '../core/store/app_store.dart';
import '../core/store/device_store.dart';
import '../core/theme/tokens.dart';
import '../widgets/store_scope.dart';
import 'detail_page.dart';
import 'setting_page.dart';
import 'status_sheet.dart';
import 'summary_result_page.dart';
import 'timeline_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.store, this.device, this.onDeviceCreated});
  final AppStore store;
  final DeviceStore? device;

  /// dev 驱动注册内部 DeviceStore 用（release 不传）
  final void Function(DeviceStore)? onDeviceCreated;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final DeviceStore _device = widget.device ?? DeviceStore();

  @override
  void initState() {
    super.initState();
    if (widget.device == null) widget.onDeviceCreated?.call(_device);
  }

  @override
  void dispose() {
    if (widget.device == null) _device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StoreScope(
      store: widget.store,
      child: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= RCDims.wideBreakpoint;
            return Scaffold(
              backgroundColor: RCColors.bg,
              body: Stack(
                children: [
                  if (wide) _WideLayout(device: _device) else _NarrowLayout(device: _device),
                  StatusSheetOverlay(store: _device),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 顶栏标题区：根页「录音卡」+ 胶囊；子页「‹ {返回目标}」（窄屏）
class _Header extends StatelessWidget {
  const _Header({required this.height, required this.wide, required this.device});
  final double height;
  final bool wide;
  final DeviceStore device;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final sub = store.subStack.isNotEmpty;
    return Container(
      key: const Key('app-header'),
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: RCColors.bg,
        border: Border(bottom: BorderSide(color: RCColors.sep)),
      ),
      child: Row(
        children: [
          if (!wide && sub)
            TextButton(
              key: const Key('crumb-back'),
              onPressed: store.goBack,
              style: TextButton.styleFrom(
                foregroundColor: RCColors.label,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(children: [
                const Icon(Icons.chevron_left, size: 18),
                Text(store.crumbDest,
                    key: const Key('crumb-dest'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ]),
            )
          else
            Text('录音卡',
                key: const Key('app-title'),
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const Spacer(),
          HwCapsule(onTap: device.openSheet),
        ],
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.height});
  final double height;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    Widget item(String label, RootTab tab, String keyName, IconData icon) {
      final on = store.rootTab == tab;
      return Expanded(
        child: InkWell(
          key: Key(keyName),
          onTap: () => store.go(tab),
          child: SizedBox(
            height: double.infinity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 20, color: on ? RCColors.label : RCColors.sec),
                const SizedBox(height: 3),
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        color: on ? RCColors.label : RCColors.sec)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      key: const Key('bottom-nav'),
      height: height,
      decoration: const BoxDecoration(
        color: RCColors.bg,
        border: Border(top: BorderSide(color: RCColors.sep)),
      ),
      child: Row(children: [
        item('Timeline', RootTab.timeline, 'nav-timeline', Icons.schedule),
        item('Setting', RootTab.setting, 'nav-setting', Icons.settings_outlined),
      ]),
    );
  }
}

/// 栈顶页面部件；面板内返回按钮仅宽屏双栏使用（窄屏走顶栏面包屑）
Widget _stackTopPage(AppStore store, {required bool wide}) {
  final top = store.stackTop;
  if (top == null) return const SizedBox.shrink();
  if (top.type == 'sum') {
    return SummaryResultPage(
        summaryId: top.id, showPaneBack: wide && store.showPaneBackSum);
  }
  return DetailPage(
      eventId: top.id,
      showPaneBack: wide && store.showPaneBackDetail,
      backLabel: '返回${AppStore.pageLabels[store.stackPrev?.type] ?? ''}');
}

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({required this.device});
  final DeviceStore device;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final sub = store.subStack.isNotEmpty;
    return Column(
      children: [
        _Header(height: RCDims.narrowHeader, wide: false, device: device),
        Expanded(
          child: sub
              ? _stackTopPage(store, wide: false)
              : switch (store.rootTab) {
                  RootTab.timeline => const TimelinePage(),
                  RootTab.setting => const SettingPage(),
                },
        ),
        // 子页隐藏底栏，经顶栏返回（真机另有边缘滑动返回）
        if (!sub) const _BottomNav(height: 56),
      ],
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.device});
  final DeviceStore device;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final sub = store.subStack.isNotEmpty;
    return Column(
      children: [
        _Header(height: RCDims.wideChrome, wide: true, device: device),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 380,
                child: TimelinePage(asLeftPane: true),
              ),
              Container(width: 1, color: RCColors.sep),
              Expanded(
                child: sub
                    ? Material(
                        color: RCColors.bg,
                        child: _stackTopPage(store, wide: true),
                      )
                    : const _EmptyPane(),
              ),
            ],
          ),
        ),
        const _BottomNav(height: 56),
      ],
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane();

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: Key('empty-pane'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 40, color: RCColors.ax),
          SizedBox(height: 10),
          Text('选择左侧记录查看详情',
              style: TextStyle(fontSize: 13, color: RCColors.sec)),
        ],
      ),
    );
  }
}
