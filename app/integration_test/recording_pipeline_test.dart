// 真机录音链路探针：从录音卡取回一条真实录音，转成 WAV，并报告时长。
//
// 这是"从硬件到可转写音频"的完整证据：下载（BLE 分块）→ IMA ADPCM 解码 → WAV 封装。
// 只取第一条文件，避免把 176 条全拉下来（真机上 BLE 慢且耗电）。
//
// 跑法：flutter test integration_test/recording_pipeline_test.dart -d <deviceId>
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/platform/bluetooth_permission.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('取回一条真实录音并转成 WAV', (tester) async {
    final gateway = RealCardGateway.maybe();
    expect(gateway, isNotNull, reason: '桥未就绪');
    final bridge = gateway!;

    // 先确保蓝牙授权（首次安装会弹系统对话框，等用户点允许）
    const permission = BluetoothPermission();
    // ignore: avoid_print
    // 状态只用于诊断打印；真正触发系统授权对话框的是底层 CoreBluetooth 扫描
    // ignore: avoid_print
    print('[pipe] 蓝牙授权：${await permission.status()}');

    final devices = await bridge.scan(timeoutMs: 10000);
    expect(devices, isNotEmpty, reason: '没扫到卡：确认已开机、未被别的设备占用');
    final snapshot = await bridge.connect(devices.first.id);
    // ignore: avoid_print
    print('[pipe] 已连接 ${devices.first.name} 电量=${snapshot.batteryLevel}%');

    final files = await bridge.files();
    final apm = files.where((f) => f.name.toUpperCase().endsWith('.APM')).toList();
    // ignore: avoid_print
    print('[pipe] 设备文件 ${files.length} 个，其中 APM ${apm.length} 个');
    expect(apm, isNotEmpty, reason: '设备上应至少有 1 条录音');

    final dir = await getApplicationSupportDirectory();
    final target = apm.first;
    // ignore: avoid_print
    print('[pipe] 取回 ${target.name}（${target.size} 字节）…');
    final downloaded = await bridge.download(target.name, '${dir.path}/recordings');
    // ignore: avoid_print
    print('[pipe] 落盘 ${downloaded.path}（${downloaded.bytesWritten} 字节）');
    expect(downloaded.bytesWritten, greaterThan(0));

    final wavPath = '${downloaded.path}.wav';
    final audio = await bridge.transcode(downloaded.path, wavPath);
    // ignore: avoid_print
    print('[pipe] 转 WAV 完成：${audio.samples} 采样点，'
        '${audio.durationSecs.toStringAsFixed(1)} 秒');

    final wav = File(wavPath);
    expect(await wav.exists(), isTrue);
    final header = await wav.openRead(0, 12).first;
    // RIFF....WAVE
    expect(String.fromCharCodes(header.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(header.sublist(8, 12)), 'WAVE');
    expect(audio.durationSecs, greaterThan(0));

    await bridge.disconnect();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
