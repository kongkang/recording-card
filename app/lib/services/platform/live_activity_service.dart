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

  VoidCallback? _onActionButtonToggle;
  VoidCallback? _onActionButtonAgent;
  bool _pendingActionToggle = false;
  bool _pendingActionAgent = false;

  /// 当用户按下绑定的 iPhone 侧边操作按钮触发「切换录音」AppIntent 时回调。
  VoidCallback? get onActionButtonToggle => _onActionButtonToggle;
  set onActionButtonToggle(VoidCallback? callback) {
    _onActionButtonToggle = callback;
    if (callback != null && _pendingActionToggle) {
      _pendingActionToggle = false;
      callback();
    }
  }

  /// 当用户触发「向 Agent 发送语音任务」AppIntent 时回调。
  VoidCallback? get onActionButtonAgent => _onActionButtonAgent;
  set onActionButtonAgent(VoidCallback? callback) {
    _onActionButtonAgent = callback;
    if (callback != null && _pendingActionAgent) {
      _pendingActionAgent = false;
      callback();
    }
  }

  Future<void> _handleIncoming(MethodCall call) async {
    if (call.method == 'actionButtonToggle') {
      final cb = _onActionButtonToggle;
      if (cb != null) {
        cb();
      } else {
        _pendingActionToggle = true;
      }
    } else if (call.method == 'actionButtonAgent') {
      final cb = _onActionButtonAgent;
      if (cb != null) {
        cb();
      } else {
        _pendingActionAgent = true;
      }
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

  /// 启动/更新录音灵动岛与锁屏实况卡片（图标固定为 App Logo，而非麦克风图标）。
  Future<void> startRecordingActivity({
    required DateTime startedAt,
    String title = '录音卡',
    String subtitle = '本机录音运行中',
  }) async {
    try {
      await _channel.invokeMethod<void>('start', {
        'startedAtMs': startedAt.millisecondsSinceEpoch,
        'title': title,
        'subtitle': subtitle,
      });
    } on MissingPluginException {
      // unit test / non-iOS environment
    } on PlatformException catch (e) {
      debugPrint('[LiveActivityService] start failed: ${e.message}');
    }
  }

  /// 启动/更新本机录音灵动岛与锁屏实况卡片。
  Future<void> startLocalRecordingActivity({
    required DateTime startedAt,
  }) => startRecordingActivity(
    startedAt: startedAt,
    title: '录音卡',
    subtitle: '本机录音运行中',
  );

  /// 启动/更新蓝牙硬件录音灵动岛与锁屏实况卡片。
  Future<void> startHardwareRecordingActivity({
    required DateTime startedAt,
    required String deviceLabel,
  }) => startRecordingActivity(
    startedAt: startedAt,
    title: '录音卡',
    subtitle: '$deviceLabel · 蓝牙录音中',
  );

  /// 启动/更新蓝牙意外断连后的本机自动保底录音实况卡片。
  Future<void> startFailoverRecordingActivity({
    required DateTime startedAt,
  }) => startRecordingActivity(
    startedAt: startedAt,
    title: '录音卡',
    subtitle: '蓝牙断连 · 本机保底录音中',
  );

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
