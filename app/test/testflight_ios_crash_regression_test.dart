/// TestFlight 崩溃反馈专项回归测试（2026-11-26）：
/// - Issue #1 (Build 2026112501, iPhone15,2): AppDelegate 覆盖 applicationDidReceiveMemoryWarning
///   调用 super 触发 `unrecognized selector sent to instance` SIGABRT。
/// - Issue #2 (Build 2026112101, Mac15,12): Apple Silicon Mac 兼容模式运行 iOS 包时弱链接
///   ActivityKit 符号解析为空地址，LiveActivityBridge.capabilitiesPayload 调用触发 0x0 SIGSEGV。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';

String _repoRoot() {
  final cwd = Directory.current.path;
  if (cwd.endsWith('/app') || cwd.endsWith(r'\app')) {
    return Directory.current.parent.path;
  }
  return cwd;
}

File _repoFile(String relPath) => File('${_repoRoot()}/$relPath');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TestFlight 崩溃回归：LiveActivityService 降级宿主兼容性', () {
    test('不支持 ActivityKit 的宿主（Mac 兼容模式/旧系统）查询与启停安全返回', () async {
      const channel = MethodChannel(
        'com.reai.recordingcard/live_activity_mac_guard_test',
      );
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            switch (call.method) {
              case 'capabilities':
                return <String, Object?>{
                  'supportsLiveActivities': false,
                  'supportsDynamicIsland': false,
                  'supportsActionButton': false,
                  'areActivitiesEnabled': false,
                  'deviceModel': 'Mac15,12',
                };
              case 'activeActivity':
                return <String, Object?>{'active': false};
              default:
                return null;
            }
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final service = LiveActivityService(channel: channel);
      final caps = await service.queryCapabilities();
      expect(caps.supportsLiveActivities, isFalse);
      expect(caps.supportsDynamicIsland, isFalse);
      expect(caps.supportsActionButton, isFalse);
      expect(caps.areActivitiesEnabled, isFalse);

      final active = await service.queryActiveActivity();
      expect(active.active, isFalse);
      expect(
        ActiveLiveActivityState.fromMap(const {'active': false}).active,
        isFalse,
      );

      await service.startRecordingActivity(
        startedAt: DateTime(2026, 11, 26, 12, 0),
      );
      await service.stopLocalRecordingActivity();
      expect(methods, [
        'capabilities',
        if (Platform.isIOS) 'activeActivity',
        'start',
        'stop',
      ]);
    });
  });

  group('TestFlight 崩溃回归：iOS 原生源码静态守卫', () {
    test('AppDelegate 不再覆盖 applicationDidReceiveMemoryWarning 调用 super', () {
      final source = _repoFile(
        'app/ios/Runner/AppDelegate.swift',
      ).readAsStringSync();
      expect(source, isNot(contains('super.applicationDidReceiveMemoryWarning')));
      expect(
        source,
        isNot(contains('override func applicationDidReceiveMemoryWarning')),
      );
      expect(source, contains('didReceiveMemoryWarningNotification'));
    });

    test('LiveActivityBridge 所有 ActivityKit 入口均经过运行期宿主守卫', () {
      final source = _repoFile(
        'app/ios/Runner/LiveActivityBridge.swift',
      ).readAsStringSync();
      expect(source, contains('isiOSAppOnMac'));
      expect(source, contains('isMacCatalystApp'));
      expect(source, contains('isActivityKitRuntimeAvailable'));

      final availabilityGuards = RegExp(
        r'if\s+#available\(iOS\s+16\.1,\s*\*\)([^\n]*)',
      ).allMatches(source).toList();
      expect(availabilityGuards.length, equals(5));
      for (final match in availabilityGuards) {
        expect(
          match.group(1),
          contains('Self.isActivityKitRuntimeAvailable()'),
          reason: '每个 ActivityKit iOS 16.1+ 入口必须同时检查运行期可用性: ${match.group(0)}',
        );
      }
    });

    test('AppleAssetPackBridge 在 Mac 兼容模式/Catalyst 下直接返回不可用', () {
      final source = _repoFile(
        'app/ios/Runner/AppleAssetPackBridge.swift',
      ).readAsStringSync();
      expect(source, contains('isiOSAppOnMac'));
      expect(source, contains('isMacCatalystApp'));
    });
  });
}
