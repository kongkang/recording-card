library;

import '../models/record.dart';
import '../models/summary.dart';

/// UI orchestration seam. Integration supplies C's repository and D's analysis;
/// no production fallback creates events or summaries.
class TaskProgress {
  const TaskProgress(this.stage, {this.percent});
  final String stage;
  final double? percent;
}

typedef ProgressSink = void Function(TaskProgress progress);

class RecordingPolicy {
  const RecordingPolicy({
    this.continuousRecording = true,
    this.markImportant = true,
    this.autoTranscribe = true,
    this.autoClean = true,
    this.inferSpeakers = true,
    this.wifiOnlySync = false,
  });
  final bool continuousRecording;
  final bool markImportant;
  final bool autoTranscribe;
  final bool autoClean;
  final bool inferSpeakers;
  final bool wifiOnlySync;
  static const labels = [
    '持续录音',
    '标记重要对话',
    '自动转录',
    '自动清洗口语',
    '说话人推测归类',
    '仅 Wi-Fi 同步',
  ];
  Map<String, bool> toJson() => {
    'continuousRecording': continuousRecording,
    'markImportant': markImportant,
    'autoTranscribe': autoTranscribe,
    'autoClean': autoClean,
    'inferSpeakers': inferSpeakers,
    'wifiOnlySync': wifiOnlySync,
  };
  factory RecordingPolicy.fromJson(Map<String, dynamic> j) => RecordingPolicy(
    continuousRecording: j['continuousRecording'] as bool? ?? true,
    markImportant: j['markImportant'] as bool? ?? true,
    autoTranscribe: j['autoTranscribe'] as bool? ?? true,
    autoClean: j['autoClean'] as bool? ?? true,
    inferSpeakers: j['inferSpeakers'] as bool? ?? true,
    wifiOnlySync: j['wifiOnlySync'] as bool? ?? false,
  );
  List<bool> get values => toJson().values.toList();
  RecordingPolicy toggled(int index) {
    final j = toJson();
    final key = j.keys.elementAt(index);
    j[key] = !j[key]!;
    return RecordingPolicy.fromJson(j);
  }
}

abstract class AppBackend {
  Future<List<RecordEvent>> loadEvents();
  Future<SummaryCard> generateSummary(
    List<RecordEvent> events, {
    required SummaryCard target,
    required RecordingPolicy policy,
    required ProgressSink onProgress,
  });

  /// Must actually apply C task/recording policy; markImportant is local mark
  /// interpretation, never permission to rewrite a hardware button binding.
  Future<void> applyPolicy(RecordingPolicy policy);
}

class CallbackAppBackend implements AppBackend {
  CallbackAppBackend({
    required this.load,
    required this.generate,
    required this.apply,
  });
  final Future<List<RecordEvent>> Function() load;
  final Future<SummaryCard> Function(
    List<RecordEvent>,
    SummaryCard,
    RecordingPolicy,
    ProgressSink,
  )
  generate;
  final Future<void> Function(RecordingPolicy) apply;
  @override
  Future<List<RecordEvent>> loadEvents() => load();
  @override
  Future<SummaryCard> generateSummary(
    List<RecordEvent> events, {
    required SummaryCard target,
    required RecordingPolicy policy,
    required ProgressSink onProgress,
  }) => generate(events, target, policy, onProgress);
  @override
  Future<void> applyPolicy(RecordingPolicy policy) => apply(policy);
}

class UnconfiguredAppBackend implements AppBackend {
  const UnconfiguredAppBackend();
  Never _missing(String service) =>
      throw StateError('$service服务未配置，请检查应用配置后重试');
  @override
  Future<List<RecordEvent>> loadEvents() async => _missing('录音仓库');
  @override
  Future<SummaryCard> generateSummary(
    List<RecordEvent> events, {
    required SummaryCard target,
    required RecordingPolicy policy,
    required ProgressSink onProgress,
  }) async => _missing('总结');
  @override
  Future<void> applyPolicy(RecordingPolicy policy) async => _missing('录音策略');
}

abstract class CancelableAppBackend {
  Future<void> cancelSummary(String id);
}
