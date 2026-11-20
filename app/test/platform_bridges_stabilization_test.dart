import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/platform/bluetooth_permission.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';

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

  group('1. Xcode / SPM multi-platform WatchRecorderCore build graph', () {
    test('Runner.xcodeproj avoids cross-platform WatchRecorderCore.o SPM collision and declares Watch companion bundle ID', () {
      final pbxproj = _repoFile('app/ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();

      // Must not link WatchRecorderCore via XCLocalSwiftPackageReference across iOS + watchOS targets
      expect(
        pbxproj.contains('XCLocalSwiftPackageReference "../../watch/Packages/WatchRecorderCore"'),
        isFalse,
        reason: 'Cross-platform local SPM object WatchRecorderCore.o breaks flutter build ios when BUILD_DIR is overridden',
      );
      expect(
        pbxproj.contains('productName = WatchRecorderCore;'),
        isFalse,
      );

      // Shared WatchRecorderCore sources must be compiled directly in native targets
      for (final src in const [
        'ComplicationStateStore.swift',
        'WatchAudioSliceTranscoder.swift',
        'WatchManifestStore.swift',
        'WatchProtocol.swift',
        'WavFileCodec.swift',
      ]) {
        expect(pbxproj, contains('$src in Sources'));
      }

      // RecordingCardWatchApp must expose INFOPLIST_KEY_WKCompanionAppBundleIdentifier for Flutter containsWatchCompanion
      expect(
        pbxproj,
        contains('INFOPLIST_KEY_WKCompanionAppBundleIdentifier = com.reai.recordingcard;'),
      );
    });
  });

  group('2. Apple Watch zero-loss .ackSlice deletion & App Review 2.5.4 / 5.1.3 compliance', () {
    test('WatchSessionSyncEngine defers local .m4a deletion until iPhone .ackSlice arrives', () {
      final syncEngine = _repoFile('watch/WatchApp/WatchSessionSyncEngine.swift').readAsStringSync();

      final didFinishStart = syncEngine.indexOf('didFinish fileTransfer: WCSessionFileTransfer');
      expect(didFinishStart, greaterThan(0));
      final didFinishBlock = syncEngine.substring(didFinishStart);

      expect(
        didFinishBlock.contains('markSyncedAndDeleteLocalAudio'),
        isFalse,
        reason: 'didFinish fileTransfer must NEVER delete local .m4a before iPhone WAV transcode ack',
      );
      expect(didFinishBlock, contains('markDeliveredPendingAck'));

      // .ackSlice handler must still delete local audio once iPhone confirms WAV transcode
      final ackStart = syncEngine.indexOf('case .ackSlice:');
      expect(ackStart, greaterThan(0));
      final ackBlock = syncEngine.substring(ackStart, didFinishStart);
      expect(ackBlock, contains('markSyncedAndDeleteLocalAudio'));
    });

    test('WatchHardwareBridge reads isFinal from metadata with false default and Dart preserves rolling vs final slices', () async {
      final bridgeSwift = _repoFile('app/ios/Runner/WatchHardwareBridge.swift').readAsStringSync();
      expect(bridgeSwift.contains('isFinal: true,'), isFalse);
      expect(bridgeSwift, contains('meta["isFinal"] as? Bool'));

      const watchChannel = MethodChannel('com.reai.recordingcard/watch_test_stabilization');
      final ackedIds = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(watchChannel, (call) async {
        switch (call.method) {
          case 'status':
            return <String, Object?>{
              'supported': true,
              'paired': true,
              'watchAppInstalled': true,
              'reachable': true,
            };
          case 'drainPendingSlices':
            return <Map<String, Object?>>[
              <String, Object?>{
                'sliceId': 'watch-s1_0001',
                'sessionId': 'watch-s1',
                'sliceIndex': 0,
                'startAtMs': 1700000000000,
                'durationMs': 60000,
                'wavPath': '/tmp/LIVE_WATCH_s1_0001.WAV',
                'gapCount': 0,
                // rolling 60s slice omits isFinal or passes false
              },
              <String, Object?>{
                'sliceId': 'watch-s1_0002',
                'sessionId': 'watch-s1',
                'sliceIndex': 1,
                'startAtMs': 1700000060000,
                'durationMs': 18000,
                'wavPath': '/tmp/LIVE_WATCH_s1_0002.WAV',
                'gapCount': 0,
                'isFinal': true,
              },
            ];
          case 'ackConsumedSlice':
            final args = call.arguments as Map<Object?, Object?>;
            ackedIds.add('${args['sliceId']}');
            return true;
          default:
            return null;
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(watchChannel, null);
      });

      final backend = MethodChannelWatchBackend(channel: watchChannel);
      final service = WatchHardwareService(backend: backend);
      addTearDown(service.dispose);

      final emitted = <LiveAudioSlice>[];
      final sub = service.audioSlices.listen(emitted.add);
      addTearDown(sub.cancel);

      await service.setLinkEnabled(true);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(2));
      expect(emitted[0].sliceIndex, 0);
      expect(emitted[0].isFinal, isFalse);
      expect(emitted[1].sliceIndex, 1);
      expect(emitted[1].isFinal, isTrue);
      expect(ackedIds, ['watch-s1_0001', 'watch-s1_0002']);
    });

    test('Watch keepalive, Info.plist, and entitlements remove fake HealthKit/mindfulness workout keepalive', () {
      final keepAliveSwift = _repoFile('watch/WatchApp/WatchRuntimeKeepAlive.swift').readAsStringSync();
      final watchPlist = _repoFile('watch/WatchApp/Info.plist').readAsStringSync();
      final watchEntitlements = _repoFile('watch/WatchApp/WatchApp.entitlements').readAsStringSync();

      expect(keepAliveSwift.contains('HKWorkoutSession'), isFalse);
      expect(keepAliveSwift.contains('import HealthKit'), isFalse);
      expect(keepAliveSwift.contains('WKExtendedRuntimeSession'), isFalse);

      expect(watchPlist.contains('workout-processing'), isFalse);
      expect(watchPlist.contains('mindfulness'), isFalse);
      expect(watchPlist.contains('NSHealthShareUsageDescription'), isFalse);
      expect(watchPlist.contains('NSHealthUpdateUsageDescription'), isFalse);
      expect(watchPlist, contains('<string>audio</string>'));

      expect(watchEntitlements.contains('com.apple.developer.healthkit'), isFalse);
    });
  });

  group('3. iOS PrivacyInfo.xcprivacy, TTS speaker routing & Info.plist UIBackgroundModes', () {
    test('PrivacyInfo.xcprivacy declares required API reasons and is in Runner Resources phase', () {
      final privacyFile = _repoFile('app/ios/Runner/PrivacyInfo.xcprivacy');
      expect(privacyFile.existsSync(), isTrue);
      final xml = privacyFile.readAsStringSync();

      expect(xml, contains('<key>NSPrivacyTracking</key>'));
      expect(xml, contains('<false/>'));
      for (final expected in const [
        'NSPrivacyAccessedAPICategoryUserDefaults',
        'CA92.1',
        'NSPrivacyAccessedAPICategoryFileTimestamp',
        'C617.1',
        'NSPrivacyAccessedAPICategoryDiskSpace',
        'E174.1',
        'NSPrivacyAccessedAPICategorySystemBootTime',
        '35F9.1',
      ]) {
        expect(xml, contains(expected));
      }

      final pbxproj = _repoFile('app/ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      expect(pbxproj, contains('PrivacyInfo.xcprivacy in Resources'));
    });

    test('RCAgentSpeechBridge.speak always configures playAndRecord + default mode + defaultToSpeaker even when PhoneMicBridge is capturing', () {
      final appDelegate = _repoFile('app/ios/Runner/AppDelegate.swift').readAsStringSync();
      final speakIdx = appDelegate.indexOf('private func speak(text: String, localeId: String)');
      final stopSpeakIdx = appDelegate.indexOf('private func stopSpeaking()', speakIdx);
      expect(speakIdx, greaterThan(0));
      expect(stopSpeakIdx, greaterThan(speakIdx));

      final speakBody = appDelegate.substring(speakIdx, stopSpeakIdx);
      expect(
        speakBody.contains('if !PhoneMicBridge.shared.isCapturing'),
        isFalse,
        reason: 'TTS speaker routing must be configured even while PhoneMicBridge is capturing',
      );
      expect(speakBody, contains('.playAndRecord'));
      expect(speakBody, contains('mode: .default'));
      expect(speakBody, contains('.defaultToSpeaker'));
      expect(speakBody, contains('.allowBluetooth'));
      expect(speakBody, contains('.allowBluetoothA2DP'));
      expect(speakBody, contains('.mixWithOthers'));
    });

    test('iOS Runner Info.plist removes unnecessary location background mode and HealthSignalBridge avoids crashy allowsBackgroundLocationUpdates', () {
      final plist = _repoFile('app/ios/Runner/Info.plist').readAsStringSync();
      final bgKeyIdx = plist.indexOf('<key>UIBackgroundModes</key>');
      expect(bgKeyIdx, greaterThan(0));
      final arrayEndIdx = plist.indexOf('</array>', bgKeyIdx);
      final bgSection = plist.substring(bgKeyIdx, arrayEndIdx);

      expect(bgSection, contains('<string>bluetooth-central</string>'));
      expect(bgSection, contains('<string>audio</string>'));
      expect(bgSection.contains('<string>location</string>'), isFalse);

      final healthBridge = _repoFile('app/ios/Runner/HealthSignalBridge.swift').readAsStringSync();
      expect(
        healthBridge.contains('locationManager.allowsBackgroundLocationUpdates = true'),
        isFalse,
        reason: 'Setting allowsBackgroundLocationUpdates=true without UIBackgroundModes:location throws NSInternalInconsistencyException',
      );
    });
  });

  group('4. Android release parity & BluetoothPermission channel contract', () {
    const bleChannel = MethodChannel('com.reai.recordingcard/bluetooth');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(bleChannel, null);
    });

    test('default const BluetoothPermission preserves non-mobile VM fallback', () async {
      const perm = BluetoothPermission();
      final status = await perm.status();
      final req = await perm.request();
      expect(status.canScan, isTrue);
      expect(req.canScan, isTrue);
    });

    test('BluetoothPermission invokes status, request, setKeepScreenOn, and setRecordingForeground and handles MissingPluginException', () async {
      final calls = <MethodCall>[];
      var statusReply = 'notDetermined';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(bleChannel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'status':
            return statusReply;
          case 'request':
            statusReply = 'granted';
            return 'granted';
          case 'setKeepScreenOn':
          case 'setRecordingForeground':
            return true;
          default:
            return null;
        }
      });

      const perm = BluetoothPermission(forceChannelForTesting: true);
      expect(await perm.status(), BluetoothAuthorization.notDetermined);
      expect(await perm.request(), BluetoothAuthorization.granted);
      expect(await perm.status(), BluetoothAuthorization.granted);
      await perm.setKeepScreenOn(true);
      await perm.setRecordingForeground(
        true,
        title: '录音卡',
        subtitle: '蓝牙录音中',
      );

      expect(
        calls.map((c) => c.method).toList(),
        ['status', 'request', 'status', 'setKeepScreenOn', 'setRecordingForeground'],
      );

      // MissingPluginException must safely fall back to BluetoothAuthorization.unknown
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(bleChannel, null);
      expect(await perm.status(), BluetoothAuthorization.unknown);
      expect(await perm.request(), BluetoothAuthorization.unknown);
      await perm.setRecordingForeground(false);
    });

    test('Android BLE permissions, PhoneMicBridge, RecordingForegroundService, TTS hardening, Cleartext config, and ABI filter are present', () {
      final bluetoothDart = _repoFile('app/lib/core/platform/bluetooth_permission.dart').readAsStringSync();
      expect(bluetoothDart, contains('Platform.isAndroid'));

      final mainKt = _repoFile('app/android/app/src/main/kotlin/com/reai/recordingcard/MainActivity.kt').readAsStringSync();
      expect(mainKt, contains('BLUETOOTH_SCAN'));
      expect(mainKt, contains('BLUETOOTH_CONNECT'));
      expect(mainKt, contains('ACCESS_FINE_LOCATION'));
      expect(mainKt, contains('"status"'));
      expect(mainKt, contains('"request"'));
      expect(mainKt, contains('"setRecordingForeground"'));
      expect(mainKt, contains('PhoneMicBridge'));
      expect(mainKt, contains('LANG_MISSING_DATA'));
      expect(mainKt, contains('LANG_NOT_SUPPORTED'));
      expect(mainKt, contains('onSpeechError'));

      final phoneMicKt = _repoFile('app/android/app/src/main/kotlin/com/reai/recordingcard/PhoneMicBridge.kt');
      expect(phoneMicKt.existsSync(), isTrue);
      final phoneMicSrc = phoneMicKt.readAsStringSync();
      expect(phoneMicSrc, contains('com.reai.recordingcard/phone_mic'));
      expect(phoneMicSrc, contains('AudioRecord'));
      expect(phoneMicSrc, contains('16000'));
      expect(phoneMicSrc, contains('ENCODING_PCM_16BIT'));

      final fgServiceKt = _repoFile('app/android/app/src/main/kotlin/com/reai/recordingcard/RecordingForegroundService.kt');
      expect(fgServiceKt.existsSync(), isTrue);

      final manifest = _repoFile('app/android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android.permission.FOREGROUND_SERVICE'));
      expect(manifest, contains('android.permission.FOREGROUND_SERVICE_MICROPHONE'));
      expect(manifest, contains('android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE'));
      expect(manifest, contains('android.permission.POST_NOTIFICATIONS'));
      expect(manifest, contains('.RecordingForegroundService'));
      expect(manifest, contains('connectedDevice|microphone'));
      expect(manifest, contains('@xml/network_security_config'));

      final netSecFile = _repoFile('app/android/app/src/main/res/xml/network_security_config.xml');
      expect(netSecFile.existsSync(), isTrue);
      final netSecXml = netSecFile.readAsStringSync();
      expect(netSecXml, contains('cleartextTrafficPermitted="false"'));
      expect(netSecXml, contains('<domain includeSubdomains="false">192.168.4.1</domain>'));
      expect(netSecXml, contains('<domain includeSubdomains="false">192.168.43.1</domain>'));

      final gradleKts = _repoFile('app/android/app/build.gradle.kts').readAsStringSync();
      expect(gradleKts, contains('RC_ANDROID_ALL_ABIS'));
      expect(gradleKts, contains('arm64-v8a'));
    });
  });
}
