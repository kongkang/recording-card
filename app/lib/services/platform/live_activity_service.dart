/// 灵动岛（ActivityKit）与 iPhone 侧边操作按钮（AppIntents）平台桥。
///
/// 硬件门控规则（以真实机型 identifier 为准）：
/// - `supportsDynamicIsland`：仅 iPhone 14 Pro / Pro Max、iPhone 15 全系、
///   iPhone 16 全系及更新机型为 true；iPhone 13 mini 等刘海屏机型为 false，
///   Setting 页不展示「灵动岛与操作按钮」入口。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LiveActivityCapabilities {
  const LiveActivityCapabilities({
    this.supportsLiveActivities = false,
    this.supportsDynamicIsland = false,
    this.supportsActionButton = false,
    this.areActivitiesEnabled = false,
  });

  final bool supportsLiveActivities;
  final bool supportsDynamicIsland;
  final bool supportsActionButton;
  final bool areActivitiesEnabled;

  factory LiveActivityCapabilities.fromMap(Map<Object?, Object?>? map) {
    if (map == null) return const LiveActivityCapabilities();
    return LiveActivityCapabilities(
      supportsLiveActivities: map['supportsLiveActivities'] == true,
      supportsDynamicIsland: map['supportsDynamicIsland'] == true,
      supportsActionButton: map['supportsActionButton'] == true,
      areActivitiesEnabled: map['areActivitiesEnabled'] == true,
    );
  }
}

class LiveActivityService {
  LiveActivityService({
    MethodChannel channel = const MethodChannel(
      'com.reai.recordingcard/live_activity',
    ),
    LiveActivityCapabilities? capabilitiesOverride,
  }) : _channel = channel,
       _capabilitiesOverride = capabilitiesOverride {
    if (_capabilitiesOverride == null) {
      _channel.setMethodCallHandler(_handleIncoming);
    }
  }

  final MethodChannel _channel;
  final LiveActivityCapabilities? _capabilitiesOverride;

  /// 当用户按下绑定的 iPhone 侧边操作按钮触发 AppIntent 时回调。
  VoidCallback? onActionButtonToggle;

  Future<void> _handleIncoming(MethodCall call) async {
    if (call.method == 'actionButtonToggle') {
      onActionButtonToggle?.call();
    }
  }

  Future<LiveActivityCapabilities> queryCapabilities() async {
    if (_capabilitiesOverride != null) return _capabilitiesOverride;
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'capabilities',
      );
      return LiveActivityCapabilities.fromMap(map);
    } on MissingPluginException {
      return const LiveActivityCapabilities();
    } on PlatformException {
      return const LiveActivityCapabilities();
    }
  }

  /// 启动/更新本机录音灵动岛实况卡片（图标固定为 App Logo，而非录音图标）。
  Future<void> startLocalRecordingActivity({
    required DateTime startedAt,
  }) async {
    try {
      await _channel.invokeMethod<void>('start', {
        'startedAtMs': startedAt.millisecondsSinceEpoch,
        'title': '录音卡',
        'subtitle': '本机录音运行中',
      });
    } on MissingPluginException {
      // unit test / non-iOS environment
    } on PlatformException catch (e) {
      debugPrint('[LiveActivityService] start failed: ${e.message}');
    }
  }

  /// 关闭灵动岛实况卡片。
  Future<void> stopLocalRecordingActivity() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // unit test / non-iOS environment
    } on PlatformException catch (e) {
      debugPrint('[LiveActivityService] stop failed: ${e.message}');
    }
  }
}
