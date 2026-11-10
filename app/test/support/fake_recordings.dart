/// 录音同步的测试替身：只顶掉「设备下载 + 转码 + 转写」这条重链路，
/// 保留 [AppStore] 真实的阶段 / 进度 / 错误处理代码路径（同步提示条靠它渲染）。
///
/// 为什么用子类而不用接口：`RecordingSyncService` 是具体类（生产只有一个实现），
/// 为测试改 lib 抽接口不划算；子类只覆盖对外方法，行为可预期，
/// 底层 gateway 用 `UnsupportedCardGateway`（一旦漏覆盖就显式失败，而不是静默给假数据）。
library;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/core/models/record.dart';
import 'package:recording_card/services/net/model_gateway.dart';
import 'package:recording_card/services/recordings/recording_sync_service.dart';

import 'model_stub.dart';

class FakeRecordingSync extends RecordingSyncService {
  FakeRecordingSync._(
    this._localEvents,
    this._pending,
    this._error,
    ModelGateway model,
    this._callLog,
  ) : super(gateway: const UnsupportedCardGateway(), model: model);

  /// [result] 为同步后设备上取回的记录；为空表示「没有新录音」。
  static Future<FakeRecordingSync> create({
    List<RecordEvent> localEvents = const [],
    List<RecordEvent>? result,
    List<(SyncStage, double, String)> steps = const [
      (SyncStage.listing, 0.02, '正在读取录音卡文件列表…'),
      (SyncStage.downloading, 0.5, '正在取回 REC001.apm（1/1）'),
      (SyncStage.transcribing, 0.9, '正在转写 REC001.apm'),
      (SyncStage.done, 1, '同步完成'),
    ],
    Duration stepDelay = Duration.zero,
    String? error,
    List<String>? callLog,
  }) async {
    // 模型网关在这里只是构造参数占位：转写路径已被本替身接管，不会被调用。
    final model = await buildModelGateway(
      MockClient((_) async => http.Response('{}', 500)),
    );
    return FakeRecordingSync._(
      [...localEvents],
      result == null
          ? null
          : _PendingSync(
              result: [...result],
              steps: steps,
              stepDelay: stepDelay,
              error: error,
            ),
      error,
      model,
      callLog,
    );
  }

  final List<RecordEvent> _localEvents;
  final _PendingSync? _pending;

  /// 没有新录音时也要能表达「同步失败」（例如设备未连接）。
  final String? _error;

  /// 与网关共用的调用日志，用来断言「先关实时流、再开始同步」的时序。
  final List<String>? _callLog;

  /// 本替身收到的 syncFromDevice 调用次数。
  int syncCalls = 0;

  @override
  Future<List<RecordEvent>> loadEvents() async => [..._localEvents];

  @override
  Future<SyncReport> syncFromDevice({
    void Function(SyncStage stage, double progress, String text)? onProgress,
  }) async {
    syncCalls++;
    _callLog?.add('sync');
    final pending = _pending;
    if (pending == null) {
      onProgress?.call(SyncStage.done, 1, '没有新的录音');
      return SyncReport(
        items: const [],
        events: [..._localEvents],
        error: _error,
      );
    }
    for (final (stage, progress, text) in pending.steps) {
      onProgress?.call(stage, progress, text);
      if (pending.stepDelay > Duration.zero) {
        await Future<void>.delayed(pending.stepDelay);
      }
    }
    _localEvents
      ..clear()
      ..addAll(pending.result);
    return SyncReport(
      items: [
        for (final e in pending.result)
          SyncFileReport(name: '${e.id}.apm', outcome: SyncFileOutcome.transcribed),
      ],
      events: [..._localEvents],
      error: pending.error,
    );
  }

  @override
  Future<int> pruneOrphans() async => 0;
}

class _PendingSync {
  _PendingSync({
    required this.result,
    required this.steps,
    required this.stepDelay,
    required this.error,
  });

  final List<RecordEvent> result;
  final List<(SyncStage, double, String)> steps;
  final Duration stepDelay;
  final String? error;
}
