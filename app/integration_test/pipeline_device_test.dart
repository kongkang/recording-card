// 真机全链路 E2E：取回设备上最小的一个 APM → 转码 → VAD 切片 → 本地 ASR
// → 声纹聚类 → 假云端润色/分段 → ready。
//
// 注意：`take_file_to_dir` 是移动语义，会把该文件从录音卡删除。因此只取
// **最小的一个**文件（`maxFiles: 1, smallestFirst: true`），避免批量消耗真实录音。
//
// 跑法（模型先经 USB 拷入应用容器，见 /tmp/run_pipeline_device.sh）：
//   flutter test integration_test/pipeline_device_test.dart -d <deviceId> \
//     --dart-define=RC_SPIKE_WAIT_FOR_MODELS=true
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/recording.dart';
import 'package:recording_card/core/platform/bluetooth_permission.dart';
import 'package:recording_card/services/analysis/chat_completion.dart';
import 'package:recording_card/services/polish/slice_polish_service.dart';
import 'package:recording_card/services/recordings/recording_pipeline.dart';
import 'package:recording_card/services/recordings/recording_store.dart';
import 'package:recording_card/services/segment/segment_build_service.dart';
import 'package:recording_card/services/transcribe/asr_models.dart';
import 'package:recording_card/services/transcribe/local_asr_service.dart';

void _log(String message) {
  // ignore: avoid_print
  print('[pipeline] $message');
}

/// 不连云端：把输入原样回传，验证本地链路与编排。
class _EchoChat implements ChatCompletion {
  @override
  Future<String> complete(
    List<ChatMessage> messages, {
    required String model,
    double temperature = 0.1,
    int maxTokens = 2048,
  }) async {
    final content = messages.last.content.trim();
    if (content.startsWith('[')) {
      final slices = jsonDecode(content) as List;
      return jsonEncode([
        for (final s in slices)
          {
            'id': s['id'],
            'turns': [
              for (final t in (s['turns'] as List))
                {
                  'src': [t['id']],
                  'startMs': t['startMs'],
                  'endMs': t['endMs'],
                  'speaker': t['speaker'],
                  'text': t['text'],
                },
            ],
            'boundary': 'none',
          },
      ]);
    }
    return jsonEncode({
      'title': '设备链路验证',
      'overview': '本地转写 / 润色 / 分段链路验证',
    });
  }
}

void _expectReady(RecordingFile file) {
  expect(file.stage, RecordingStage.ready, reason: '文件应处理完成');
  expect(file.durationMs, greaterThan(0));
  expect(file.slices, isNotEmpty, reason: 'VAD 应切出至少一片');
  expect(file.utterances, isNotEmpty, reason: '本地 ASR 应产出原始句');
  expect(file.turns, isNotEmpty, reason: '窗口润色应产出 turn');
  expect(file.segments, isNotEmpty, reason: '阶段总结应产出分段');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真机全链路：最小 APM → 本地转写 → 润色 → 分段', (tester) async {
    final gateway = RealCardGateway.maybe();
    expect(gateway, isNotNull, reason: '桥未就绪');
    final bridge = gateway!;

    // 先处理系统权限（每次重装 TCC 会重置）：把弹窗提前，避免和模型下载
    // / 扫描超时叠在一起。
    const permission = BluetoothPermission();
    final auth = await permission.request();
    _log('蓝牙授权：$auth');
    expect(auth.canScan, isTrue, reason: auth.hint ?? '蓝牙未授权');

    final installer = ModelInstaller();
    const waitForModels = bool.fromEnvironment('RC_SPIKE_WAIT_FOR_MODELS');
    if (waitForModels) {
      _log('等待模型拷贝（最多 10 分钟）…');
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      while (DateTime.now().isBefore(deadline)) {
        final asr = await installer.status(senseVoiceSpec);
        final emb = await installer.status(campplusEmbeddingSpec);
        if (asr.installed && emb.installed) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    final asrStatus = await installer.status(senseVoiceSpec);
    expect(asrStatus.installed, isTrue, reason: 'ASR 模型未安装');

    // 上一次会话可能还占着 BLE 链路：先尽力断开，再扫描
    try {
      await bridge.disconnect();
    } on Object {
      // 未连接是正常情况
    }
    final devices = await bridge.scan(timeoutMs: 15000);
    expect(devices, isNotEmpty, reason: '没扫到录音卡');
    final snapshot = await bridge.connect(devices.first.id);
    _log('已连接 ${devices.first.name}，电量 ${snapshot.batteryLevel}%');

    final support = await getApplicationSupportDirectory();
    final store = RecordingStore(
      root: Directory('${support.path}/rc-pipeline-device'),
    );
    final engine = LocalAsrService();
    final chat = _EchoChat();
    final pipeline = RecordingPipeline(
      gateway: bridge,
      store: store,
      engine: engine,
      models: InstalledSpeechModelProvider(installer),
      polish: SlicePolishService(chat: chat, model: 'echo'),
      segments: SegmentBuildService(chat: chat, model: 'echo'),
    );

    try {
      final watch = Stopwatch()..start();
      final report = await pipeline.sync(
        maxFiles: 1,
        smallestFirst: true,
        minFileSize: 200000,
        onProgress: (p) => _log('${p.stage.name}: ${p.text}'),
      );
      _log(
        '完成：downloaded=${report.downloaded} ready=${report.ready} '
        'failed=${report.failed} 用时 ${watch.elapsed}',
      );
      if (report.failures.isNotEmpty) _log('失败：${report.failures}');

      // 诊断：store 目录 + meta 内容（loadAll 为空时定位用）
      final root = await store.root();
      _log('store root=${root.path}');
      await for (final entity in root.list(recursive: true)) {
        _log('fs: ${entity.path}');
        if (entity is File && entity.path.endsWith('meta.json')) {
          final raw = await entity.readAsString();
          _log('meta bytes=${raw.length}');
          try {
            final parsed = RecordingFile.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
            _log(
              'meta ok: ${parsed.deviceName} stage=${parsed.stage.name} '
              'slices=${parsed.slices.length} utt=${parsed.utterances.length}',
            );
          } on Object catch (e) {
            _log('meta parse error: $e');
            _log('meta head: ${raw.length > 300 ? raw.substring(0, 300) : raw}');
          }
        }
      }
      final files = await store.loadAll(refresh: true);
      _log('loadAll=${files.length}');
      expect(files, isNotEmpty, reason: '应至少有一条本地录音');
      final file = files.first;
      _log(
        '文件 ${file.deviceName}：${file.durationMs}ms，'
        '${file.slices.length} 片，${file.utterances.length} 句，'
        '${file.turns.length} turn，${file.segments.length} 段，'
        '说话人数 ${file.segments.isEmpty ? 0 : file.segments.first.speakerCount}',
      );
      for (final s in file.segments.take(3)) {
        _log('分段：${s.title} · ${s.brief}');
      }
      _expectReady(file);
    } finally {
      await bridge.disconnect();
      await engine.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
