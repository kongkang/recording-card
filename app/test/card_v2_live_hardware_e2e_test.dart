// 录音卡 V2（DYJV2_*）真实硬件端到端测试（受 RC_V2_LIVE_E2E=true 门控，默认 flutter test 跳过）：
//
// 覆盖：
// 1. RealCardGateway 加载 libcard_bridge.dylib 并扫描到真实 V2 录音卡；
// 2. 连续「重新扫描」稳定工作，不出现 Channel closed 死锁；
// 3. 连接 V2 读取电量/版本/存储快照，断连并二次重连同一硬件验证通道与外设表同步；
// 4. 若服务器存在新版主控固件，真实执行主控 Secure DFU（WriteWithoutResponse 队列 + 20ms 定时器）
//    与升级后自动扫描重连校验，最终释放蓝牙连接。
//
// 注意：严禁在本测试中调用 takeOldestFile / download / deleteFile 等会删除设备端录音文件的接口。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/platform/bluetooth_permission.dart';
import 'package:recording_card/core/store/device_store.dart';
import 'package:recording_card/services/audio/phone_mic_service.dart';
import 'package:recording_card/services/platform/live_activity_service.dart';
import 'package:recording_card/services/watch/watch_hardware_service.dart';

const bool _runLiveV2 = bool.fromEnvironment('RC_V2_LIVE_E2E');
const String _targetV2Name = String.fromEnvironment('RC_V2_TARGET_NAME');

CardDevice _findTargetV2(
  List<CardDevice> discovered, {
  required String phase,
}) {
  final v2List = discovered
      .where((d) => d.deviceKind == DeviceKind.cardV2)
      .toList(growable: false);
  if (_targetV2Name.isNotEmpty) {
    final hit = v2List.where((d) => d.name == _targetV2Name).firstOrNull;
    expect(
      hit,
      isNotNull,
      reason:
          '$phase 未发现指定目标卡 $_targetV2Name，当前 V2 列表=${v2List.map((e) => '${e.name}(${e.rssi})').toList()}',
    );
    return hit!;
  }
  expect(v2List, isNotEmpty, reason: '$phase 周围应能扫描到 DYJV2_* 录音卡');
  if (v2List.length > 1) {
    fail(
      '$phase 发现多台 V2 录音卡 ${v2List.map((e) => '${e.name}(${e.rssi})').toList()}，'
      '请通过 --dart-define=RC_V2_TARGET_NAME=DYJV2_xxx 显式指定目标设备，避免误刷旁人硬件',
    );
  }
  return v2List.first;
}

class _NoopPhoneMicBackend implements PhoneMicBackend {
  @override
  Future<PhoneMicPermission> checkPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<PhoneMicPermission> requestPermission() async =>
      PhoneMicPermission.granted;

  @override
  Future<void> startCapture(
    void Function(Uint8List pcmBytes) onData, {
    void Function(String message)? onError,
  }) async {}

  @override
  Future<void> stopCapture() async {}
}

class _TestLiveActivityService extends LiveActivityService {
  _TestLiveActivityService()
    : super(
        capabilitiesOverride: const LiveActivityCapabilities(
          supportsLiveActivities: false,
          supportsDynamicIsland: false,
          supportsActionButton: false,
          areActivitiesEnabled: false,
        ),
      );
}

DeviceStore _makeStore(RealCardGateway gateway, Directory tmpDir) {
  return DeviceStore(
    gateway: gateway,
    autoStart: false,
    permission: const BluetoothPermission(),
    phoneMicBackend: _NoopPhoneMicBackend(),
    liveActivityService: _TestLiveActivityService(),
    watchHardware: WatchHardwareService(
      backend: FakeWatchBridgeBackend(),
      historyFilePath:
          '${tmpDir.path}/watch_hist_${DateTime.now().microsecondsSinceEpoch}.json',
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '录音卡 V2 真机 E2E：扫描、重新扫描、连接、断连重连与主控 DFU 固件升级',
    () async {
      final gateway = RealCardGateway.maybe();
      expect(
        gateway,
        isNotNull,
        reason: '请通过 --dart-define=RC_CARD_BRIDGE_LIB=... 传入 libcard_bridge.dylib',
      );
      final gw = gateway!;
      final tmpDir = await Directory.systemTemp.createTemp('rc_v2_e2e_');
      final store = _makeStore(gw, tmpDir);

      try {
        // 1) 首次扫描发现 V2 录音卡
        await store.startScan();
        expect(
          store.linkError,
          isNull,
          reason: '首次扫描不应报错：${store.linkError}',
        );
        var v2 = _findTargetV2(store.discovered, phase: '首次扫描');

        // 2) 模拟用户手动点「重新扫描」
        await store.startScan(userInitiated: true);
        expect(
          store.linkError,
          isNull,
          reason: '重新扫描不应报错：${store.linkError}',
        );
        v2 = _findTargetV2(store.discovered, phase: '重新扫描');

        // 3) 建连与快照校验（绝不取走/删除 SD 卡录音）
        await store.connectTo(v2);
        expect(store.isConnected, isTrue, reason: store.linkError ?? 'V2 建连失败');
        expect(store.connectedName, v2.name);
        expect(store.activeKind, DeviceKind.cardV2);
        expect(store.fwVersion, isNotEmpty);
        expect(store.fwVersionCode, greaterThan(0));
        expect(store.battery, greaterThan(0));
        expect(store.storageTotalMb, greaterThan(0));
        // ignore: avoid_print
        print(
          '[V2 E2E] 已连接 ${store.connectedName}: '
          'main=${store.fwVersion}(${store.fwVersionCode}), '
          'wifi=${store.wifiVersion}(${store.wifiVersionCode}), '
          'batt=${store.battery}%, storageFree=${store.storageFreeMb}/${store.storageTotalMb}MB',
        );

        // 4) 主动断开后在同一 Adapter 上立即再次扫描并重连
        await store.disconnectSafely();
        expect(store.isConnected, isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 500));
        await store.startScan(userInitiated: true);
        expect(store.linkError, isNull);
        final v2Again = _findTargetV2(store.discovered, phase: '断连后重扫');
        await store.connectTo(v2Again);
        expect(store.isConnected, isTrue, reason: store.linkError ?? '二次重连失败');
        expect(store.connectedName, v2.name);

        // 5) 检查服务器版本并按需执行真实固件升级
        await store.checkFirmware();
        expect(
          store.fwStage,
          isNot(FwStage.failed),
          reason: '检查固件更新失败：${store.fwError}',
        );
        // ignore: avoid_print
        print(
          '[V2 E2E] 固件对比: main=${store.mainVersionCompare}, '
          'wifi=${store.wifiVersionCompare}, '
          'mainNeeds=${store.mainNeedsUpdate}, wifiNeeds=${store.wifiNeedsUpdate}',
        );

        if (store.mainNeedsUpdate) {
          var lastStage = '';
          var lastBucket = -1;
          void onProgress() {
            final bucket = (store.fwProgress ~/ 10) * 10;
            if (store.fwStageText != lastStage || bucket != lastBucket) {
              lastStage = store.fwStageText;
              lastBucket = bucket;
              // ignore: avoid_print
              print(
                '[V2 E2E][OTA] ${store.fwStage.name} ${store.fwPctText} '
                '${store.fwStageText} | ${store.fwStateText}',
              );
            }
          }

          store.addListener(onProgress);
          try {
            await store.startFwUpdate();
          } finally {
            store.removeListener(onProgress);
          }

          // 若阶段 2 因附近无已配网 2.4GHz Wi-Fi 路由器报错，主控阶段 1 仍必须已成功并完成蓝牙重连
          if (store.fwStage == FwStage.failed) {
            // ignore: avoid_print
            print('[V2 E2E] 升级停在阶段 2 提示：${store.fwError}');
            expect(
              store.fwError ?? '',
              anyOf(
                contains('Wi-Fi'),
                contains('wifi'),
              ),
              reason: '非 Wi-Fi 配网原因的升级失败不可接受：${store.fwError}',
            );
          } else {
            expect(store.fwStage, FwStage.done);
          }

          expect(store.isConnected, isTrue, reason: '主控 DFU 重启后必须自动重连成功');
          expect(
            store.connectedName,
            v2.name,
            reason: '主控 DFU 重启后必须准确回连同一张目标卡 ${v2.name}',
          );
          await store.checkFirmware();
          expect(
            store.mainNeedsUpdate,
            isFalse,
            reason:
                '主控固件应已升级到最新，当前=${store.fwVersion}(${store.fwVersionCode})',
          );
          // ignore: avoid_print
          print(
            '[V2 E2E] 升级后校验完成: main=${store.fwVersion}(${store.fwVersionCode}), '
            'wifi=${store.wifiVersion}(${store.wifiVersionCode})',
          );
        }
      } finally {
        await store.disconnectSafely();
        store.dispose();
        await tmpDir.delete(recursive: true);
      }
    },
    skip: !_runLiveV2 ? '需连接真实录音卡 V2，传入 --dart-define=RC_V2_LIVE_E2E=true 运行' : null,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
