library;

/// 开发期帧级自查驱动（仅 debug 构建使用，由 main.dart 注册，release 不参与编译路径）。
///
/// 用途：配合 VM service evaluate 在真机窗口内驱动关键状态并输出 PNG 截图，
/// 满足「动画/图标交付必须逐帧截图自查」的流程要求。不参与任何业务逻辑。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../store/app_store.dart';
import '../store/device_store.dart';
import '../../services/auth_service.dart';

class DevDriver {
  final GlobalKey shotKey;
  AppStore? store;
  DeviceStore? device;
  AuthService? auth;

  DevDriver(this.shotKey);

  /// 驱动到指定状态（post-frame 派发；空闲时主动请求帧，否则回调不触发）。
  String act(String action, String arg) {
    SchedulerBinding.instance.scheduleFrame();
    SchedulerBinding.instance.addPostFrameCallback((_) => _act(action, arg));
    return 'queued';
  }

  String _act(String action, String arg) {
    final s = store, d = device, a = auth;
    if (s == null || d == null || a == null) return 'not-ready';
    switch (action) {
      case 'login':
        a.signIn('kong', 'secret');
        return 'ok';
      case 'tapCard':
        s.tapCard(arg, isSummary: false);
        return 'ok';
      case 'detail':
        s.openDetail(arg, fresh: true);
        return 'ok';
      case 'selMode':
        s.startSummary();
        s.selRange('week');
        return 'ok';
      case 'gen':
        s.startSummary();
        s.selRange('week');
        s.genSummary();
        return 'ok';
      case 'back':
        s.goBack();
        return 'ok';
      case 'sheet':
        d.openSheet();
        return 'ok';
      case 'wifi':
        d.openSheet();
        d.showView(DeviceView.wifi);
        return 'ok';
      case 'fw':
        d.openSheet();
        d.showView(DeviceView.upg);
        d.startFwUpdate();
        return 'ok';
      case 'closeSheet':
        d.closeSheet();
        return 'ok';
      default:
        return 'unknown-action';
    }
  }

  /// 截图：[delayMs] 后取帧（用于抓中间态，如生成进度/扫描中）。
  Future<String> shot(String name, {int delayMs = 400}) async {
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    final boundary =
        shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return 'no-boundary';
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return 'no-bytes';
    final dir = Directory('/tmp/rc-shots')..createSync(recursive: true);
    final f = File('${dir.path}/$name.png');
    await f.writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
    return f.path;
  }
}
