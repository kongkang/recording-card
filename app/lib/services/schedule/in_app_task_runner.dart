/// App 进程还活着时检查到期任务。
///
/// iOS 会在离开前台后很快挂起进程，挂起期间 [Timer] 不会响。本仓库没有
/// BGTaskScheduler / BGAppRefresh 的既有接法，这里不另声明后台刷新：
/// 系统调度既不能保证按用户填的间隔执行，最短间隔也远长于开发期要验证的周期。
/// 当前可靠路径是：前台按固定节奏检查到期任务，回到前台时立刻补检查一次。
/// 第一版用于开着 App，或重新回到前台之后的真机验证。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'task_scheduler.dart';

class InAppTaskRunner with WidgetsBindingObserver {
  InAppTaskRunner(
    this.scheduler, {
    this.pollEvery = const Duration(seconds: 30),
  });

  final TaskScheduler scheduler;
  final Duration pollEvery;
  Timer? _timer;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(pollEvery, (_) {
      unawaited(scheduler.tick(reason: 'interval'));
    });
    unawaited(scheduler.tick(reason: 'interval'));
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(scheduler.tick(reason: 'foreground'));
    }
  }
}
