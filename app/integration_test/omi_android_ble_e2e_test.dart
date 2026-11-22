library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/services/audio/live_audio_recorder.dart';
import 'package:recording_card/services/transcribe/wav_io.dart';

void _log(String msg) {
  debugPrint('[android-omi] $msg');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android real-device Omi BLE >125s E2E verification', (tester) async {
    final gateway = RealCardGateway.maybe();
    expect(gateway, isNotNull, reason: 'Android 真机应加载 libcard_bridge.so');
    final gw = gateway!;
    _log('bridgeVersion=${gw.bridgeVersion}');
    await Future<void>.delayed(const Duration(seconds: 2));

    final rootDir = await getApplicationSupportDirectory();
    final workDir = Directory('${rootDir.path}/omi_android_ble_e2e');
    if (await workDir.exists()) {
      await workDir.delete(recursive: true);
    }
    await workDir.create(recursive: true);

    var connected = false;
    var recording = false;
    LiveAudioRecorder? recorder;
    StreamSubscription<LiveAudioSlice>? sliceSub;

    try {
      // 1. 扫描并严格筛选 DeviceKind.omiCv1（绝不连接 DYJ*）
      final scanSw = Stopwatch()..start();
      final devices = await gw.scan(timeoutMs: 10000);
      scanSw.stop();
      _log(
        'SCAN_RESULT count=${devices.length} elapsedMs=${scanSw.elapsedMilliseconds} '
        'devices=${devices.map((d) => '${d.name}:${d.deviceKind.code}:rssi=${d.rssi}').join(',')}',
      );

      final omiList =
          devices.where((d) => d.deviceKind == DeviceKind.omiCv1).toList();
      expect(
        omiList,
        isNotEmpty,
        reason: 'Android BLE 扫描未发现 DeviceKind.omiCv1（禁止回退到 DYJ）',
      );
      final omi = omiList.first;

      // 2. 连接 Omi 并校验能力与 Snapshot
      final connSw = Stopwatch()..start();
      final snapOpt = await gw.connect(
        omi.id,
        name: omi.name,
        deviceKind: omi.deviceKind.code,
      );
      connSw.stop();
      connected = true;
      expect(snapOpt, isNotNull);
      final snap = await gw.snapshot();

      _log(
        'CONNECT_OK elapsedMs=${connSw.elapsedMilliseconds} '
        'name=${snap.deviceName} kind=${snap.effectiveKind.code} '
        'fw=${snap.fwVersion} bat=${snap.batteryLevel} charging=${snap.isCharging}',
      );
      expect(snap.effectiveKind, DeviceKind.omiCv1);
      final caps = snap.capabilities;
      expect(caps, isNotNull);
      expect(caps!.realtimeAudio, isTrue);
      expect(caps.hasWifiConfig, isFalse);
      expect(caps.hasRemoteRecordControl, isTrue);

      // 3. 基础命令与防御性门控
      final timeSyncSw = Stopwatch()..start();
      await gw.syncTime();
      timeSyncSw.stop();
      _log('SYNC_TIME_OK elapsedMs=${timeSyncSw.elapsedMilliseconds}');

      await gw.mark();
      _log('MARK_OK');

      expect(await gw.scanWifi(), isEmpty);
      await expectLater(
        gw.connectWifi('AndroidDummy', '12345678'),
        throwsA(isA<CardException>()),
      );
      _log('CAPABILITY_GATING_OK');

      // 4. 启动 >125s 实时录音流与 1 分钟滚动切片（重点观测 ~100s 是否断流）
      final liveDir = Directory('${workDir.path}/live');
      await liveDir.create(recursive: true);

      recorder = LiveAudioRecorder(
        gateway: gw,
        baseDir: liveDir,
        sliceDuration: const Duration(minutes: 1),
      );
      final sealedSlices = <Map<String, dynamic>>[];
      sliceSub = recorder.slices.listen((s) {
        final wavBytes = File(s.wavPath).readAsBytesSync();
        final wav = parseWav(wavBytes);
        final item = {
          'sliceIndex': s.sliceIndex,
          'sliceKey': s.sliceKey,
          'startAtMs': s.startAtMs,
          'durationMs': s.durationMs,
          'isFinal': s.isFinal,
          'wavBytes': wavBytes.length,
          'sampleRate': wav.sampleRate,
          'isMono16': wav.isMono16,
          'wavDurationMs': wav.durationMs,
        };
        sealedSlices.add(item);
        _log('SLICE_SEALED ${jsonEncode(item)}');
      });

      await gw.startRecording();
      recording = true;
      final snapRec = await gw.snapshot();
      expect(snapRec.recording, isTrue);

      await recorder.start();
      _log('RECORDING_STARTED targetWallSec=130');

      final telemetry = <Map<String, dynamic>>[];
      final wallSw = Stopwatch()..start();
      var prevRecordedSec = 0.0;
      var lastAdvanceWallSec = 0;
      var consecutiveZeroTicksAfterStart = 0;
      var maxConsecutiveZeroTicksAfterStart = 0;
      int? firstStallWallSec;

      for (var tick = 1; tick <= 13; tick++) {
        await Future<void>.delayed(const Duration(seconds: 10));
        final wallSec = wallSw.elapsed.inSeconds;
        final recordedSec = recorder.recordedSeconds;
        final deltaSec = recordedSec - prevRecordedSec;
        prevRecordedSec = recordedSec;

        if (deltaSec > 0.05) {
          lastAdvanceWallSec = wallSec;
          consecutiveZeroTicksAfterStart = 0;
        } else if (recordedSec > 1.0) {
          consecutiveZeroTicksAfterStart++;
          if (consecutiveZeroTicksAfterStart > maxConsecutiveZeroTicksAfterStart) {
            maxConsecutiveZeroTicksAfterStart = consecutiveZeroTicksAfterStart;
          }
          firstStallWallSec ??= wallSec;
        }

        final row = {
          'tick': tick,
          'wallSec': wallSec,
          'recordedSec': double.parse(recordedSec.toStringAsFixed(2)),
          'deltaSec': double.parse(deltaSec.toStringAsFixed(2)),
          'sealedSlices': recorder.session?.sliceKeys.length ?? 0,
          'gapCount': recorder.session?.gapCount ?? 0,
        };
        telemetry.add(row);
        _log('TELEMETRY ${jsonEncode(row)}');
      }

      // 再等 2 秒让尾包写完
      await Future<void>.delayed(const Duration(seconds: 2));
      wallSw.stop();

      final totalRecordedSec = recorder.recordedSeconds;
      final session = await recorder.stop();
      await gw.stopRecording();
      recording = false;
      await recorder.pendingSliceWrites;

      // 5. 断开连接校验
      final discSw = Stopwatch()..start();
      final report = await gw.disconnect();
      discSw.stop();
      connected = false;
      _log(
        'DISCONNECT_OK elapsedMs=${discSw.elapsedMilliseconds} '
        'released=${report.released} hadDevice=${report.hadDevice} detail=${report.detail}',
      );

      final summary = {
        'bridgeVersion': gw.bridgeVersion,
        'omiId': omi.id,
        'omiName': omi.name,
        'omiRssi': omi.rssi,
        'scanMs': scanSw.elapsedMilliseconds,
        'connectMs': connSw.elapsedMilliseconds,
        'fwVersion': snap.fwVersion,
        'batteryLevel': snap.batteryLevel,
        'isCharging': snap.isCharging,
        'wallSec': wallSw.elapsed.inSeconds,
        'totalRecordedSec': double.parse(totalRecordedSec.toStringAsFixed(2)),
        'lastAdvanceWallSec': lastAdvanceWallSec,
        'firstStallWallSec': firstStallWallSec,
        'maxConsecutiveZeroTicksAfterStart': maxConsecutiveZeroTicksAfterStart,
        'gapCount': session?.gapCount ?? 0,
        'sealedSlicesCount': sealedSlices.length,
        'sealedSlices': sealedSlices,
        'telemetry': telemetry,
        'disconnectReleased': report.released,
        'disconnectElapsedMs': discSw.elapsedMilliseconds,
      };
      _log('JSON_REPORT=${jsonEncode(summary)}');

      expect(totalRecordedSec, greaterThan(10.0), reason: 'Android Omi 实时流应收到清晰语音包');
      expect(sealedSlices, isNotEmpty, reason: 'Android 停止录音应冲刷封口至少 1 个 WAV 切片');
      expect(report.released, isTrue);
      // 检查是否突破 100s 长流（若此处失败说明 Android 侧确实在 100s 左右出现中断，需结合 logcat 定位）
      expect(
        lastAdvanceWallSec,
        greaterThanOrEqualTo(115),
        reason:
            'Android Omi 连续推流应持续突破 100s（actual lastAdvanceWallSec=$lastAdvanceWallSec, totalRecordedSec=${totalRecordedSec.toStringAsFixed(2)}s）',
      );
      _log('ANDROID_E2E_PASSED');
    } catch (e, st) {
      _log('ANDROID_E2E_ERROR $e\n$st');
      rethrow;
    } finally {
      await sliceSub?.cancel();
      recorder?.dispose();
      if (recording) {
        try {
          await gw.stopRecording();
        } on Object {
          // ignore cleanup errors
        }
      }
      if (connected) {
        try {
          await gw.disconnect();
        } on Object {
          // ignore cleanup errors
        }
      }
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
      _log('ANDROID_E2E_DONE');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
