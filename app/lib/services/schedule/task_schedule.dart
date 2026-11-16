/// 可复用的定时任务定义：间隔或 5 段 cron，不把 5 分钟 / 30 分钟 / 4 小时写成唯一选项。
library;

class CronExpression {
  CronExpression._({
    required this.minute,
    required this.hour,
    required this.dayOfMonth,
    required this.month,
    required this.dayOfWeek,
    required this.dayOfMonthAny,
    required this.dayOfWeekAny,
  });

  final Set<int> minute;
  final Set<int> hour;
  final Set<int> dayOfMonth;
  final Set<int> month;
  final Set<int> dayOfWeek;
  final bool dayOfMonthAny;
  final bool dayOfWeekAny;

  static CronExpression? tryParse(String raw) {
    final parts = raw.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return null;
    final minute = _parseField(parts[0], 0, 59);
    final hour = _parseField(parts[1], 0, 23);
    final dom = _parseField(parts[2], 1, 31);
    final month = _parseField(parts[3], 1, 12);
    final dow = _parseField(parts[4], 0, 7);
    if (minute == null ||
        hour == null ||
        dom == null ||
        month == null ||
        dow == null) {
      return null;
    }
    return CronExpression._(
      minute: minute,
      hour: hour,
      dayOfMonth: dom,
      month: month,
      dayOfWeek: {for (final d in dow) d == 7 ? 0 : d},
      dayOfMonthAny: parts[2] == '*',
      dayOfWeekAny: parts[4] == '*',
    );
  }

  /// 严格晚于 [from] 的下一次命中。搜不到时退回一天后，避免调用方空转。
  DateTime nextAfter(DateTime from) {
    var cursor = DateTime(
      from.year,
      from.month,
      from.day,
      from.hour,
      from.minute,
    ).add(const Duration(minutes: 1));
    final limit = cursor.add(const Duration(days: 370));
    while (cursor.isBefore(limit)) {
      if (matches(cursor)) return cursor;
      cursor = cursor.add(const Duration(minutes: 1));
    }
    return from.add(const Duration(days: 1));
  }

  bool matches(DateTime time) {
    if (!minute.contains(time.minute) ||
        !hour.contains(time.hour) ||
        !month.contains(time.month)) {
      return false;
    }
    final cronDow = time.weekday == DateTime.sunday ? 0 : time.weekday;
    final domOk = dayOfMonth.contains(time.day);
    final dowOk = dayOfWeek.contains(cronDow);
    if (dayOfMonthAny && dayOfWeekAny) return true;
    if (dayOfMonthAny) return dowOk;
    if (dayOfWeekAny) return domOk;
    return domOk || dowOk;
  }

  static Set<int>? _parseField(String token, int min, int max) {
    final values = <int>{};
    for (final part in token.split(',')) {
      if (part.isEmpty) return null;
      final stepSplit = part.split('/');
      if (stepSplit.length > 2) return null;
      final step = stepSplit.length == 2 ? int.tryParse(stepSplit[1]) : 1;
      if (step == null || step <= 0) return null;
      final range = stepSplit[0];
      final int start;
      final int end;
      if (range == '*') {
        start = min;
        end = max;
      } else if (range.contains('-')) {
        final bits = range.split('-');
        if (bits.length != 2) return null;
        final a = int.tryParse(bits[0]);
        final b = int.tryParse(bits[1]);
        if (a == null || b == null) return null;
        start = a;
        end = b;
      } else {
        final a = int.tryParse(range);
        if (a == null) return null;
        start = a;
        end = a;
      }
      if (start < min || end > max || start > end) return null;
      for (var v = start; v <= end; v += step) {
        values.add(v);
      }
    }
    if (values.isEmpty) return null;
    return values;
  }
}

/// 调度周期。`interval` 用任意正整数分钟；`cron` 用标准 5 段表达式。
class TaskSchedule {
  const TaskSchedule({
    required this.mode,
    required this.everyMinutes,
    this.cron,
  });

  factory TaskSchedule.interval(int minutes) =>
      TaskSchedule(mode: 'interval', everyMinutes: normalizeMinutes(minutes));

  factory TaskSchedule.cron(String expression, {int fallbackMinutes = 60}) {
    return TaskSchedule(
      mode: 'cron',
      everyMinutes: normalizeMinutes(fallbackMinutes),
      cron: expression.trim(),
    );
  }

  static const int minMinutes = 1;
  static const int maxMinutes = 10080;

  final String mode;
  final int everyMinutes;
  final String? cron;

  static int normalizeMinutes(int minutes) {
    if (minutes < minMinutes) return minMinutes;
    if (minutes > maxMinutes) return maxMinutes;
    return minutes;
  }

  bool get isCron => mode == 'cron' && (cron?.trim().isNotEmpty ?? false);

  DateTime nextAfter(DateTime finishedAt) {
    if (isCron) {
      final parsed = CronExpression.tryParse(cron!.trim());
      if (parsed != null) return parsed.nextAfter(finishedAt);
    }
    return finishedAt.add(
      Duration(minutes: TaskSchedule.normalizeMinutes(everyMinutes)),
    );
  }

  String get label {
    if (isCron) return cron!.trim();
    return _formatMinutes(everyMinutes);
  }

  static String _formatMinutes(int minutes) {
    if (minutes < 60) return '$minutes 分钟';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h < 24) return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
    final d = h ~/ 24;
    final rh = h % 24;
    if (rh == 0 && m == 0) return '$d 天';
    return m == 0 ? '$d 天 $rh 小时' : '$d 天 $rh 小时 $m 分钟';
  }

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'every': everyMinutes,
    if (cron != null && cron!.trim().isNotEmpty) 'cron': cron,
  };

  factory TaskSchedule.fromJson(Map<String, dynamic> json) {
    final mode = json['mode'] == 'cron' ? 'cron' : 'interval';
    final every = (json['every'] as num?)?.toInt() ?? 10;
    final cron = json['cron'] as String?;
    if (mode == 'cron' && cron != null && cron.trim().isNotEmpty) {
      return TaskSchedule.cron(cron, fallbackMinutes: every);
    }
    return TaskSchedule.interval(every);
  }

  @override
  bool operator ==(Object other) =>
      other is TaskSchedule &&
      other.mode == mode &&
      other.everyMinutes == everyMinutes &&
      other.cron == cron;

  @override
  int get hashCode => Object.hash(mode, everyMinutes, cron);
}

class ScheduledTaskDefinition {
  const ScheduledTaskDefinition({
    required this.id,
    required this.name,
    required this.detail,
    required this.enabled,
    required this.schedule,
    required this.handlerId,
    this.inputFromTaskId,
    this.config = const {},
  });

  final String id;
  final String name;
  final String detail;
  final bool enabled;
  final TaskSchedule schedule;
  final String? inputFromTaskId;
  final String handlerId;
  final Map<String, dynamic> config;

  ScheduledTaskDefinition copyWith({
    String? name,
    String? detail,
    bool? enabled,
    TaskSchedule? schedule,
    String? inputFromTaskId,
    bool clearInput = false,
    String? handlerId,
    Map<String, dynamic>? config,
  }) {
    return ScheduledTaskDefinition(
      id: id,
      name: name ?? this.name,
      detail: detail ?? this.detail,
      enabled: enabled ?? this.enabled,
      schedule: schedule ?? this.schedule,
      inputFromTaskId: clearInput
          ? null
          : (inputFromTaskId ?? this.inputFromTaskId),
      handlerId: handlerId ?? this.handlerId,
      config: config ?? this.config,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'detail': detail,
    'enabled': enabled,
    'schedule': schedule.toJson(),
    'handler': handlerId,
    if (inputFromTaskId != null) 'inputFrom': inputFromTaskId,
    if (config.isNotEmpty) 'config': config,
  };

  factory ScheduledTaskDefinition.fromJson(Map<String, dynamic> json) {
    final rawConfig = json['config'];
    return ScheduledTaskDefinition(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      detail: '${json['detail'] ?? ''}',
      enabled: json['enabled'] != false,
      schedule: json['schedule'] is Map<String, dynamic>
          ? TaskSchedule.fromJson(json['schedule'] as Map<String, dynamic>)
          : json['schedule'] is Map
          ? TaskSchedule.fromJson(
              Map<String, dynamic>.from(json['schedule'] as Map),
            )
          : TaskSchedule.interval(10),
      handlerId: '${json['handler'] ?? ''}',
      inputFromTaskId: json['inputFrom'] as String?,
      config: rawConfig is Map<String, dynamic>
          ? Map<String, dynamic>.from(rawConfig)
          : rawConfig is Map
          ? Map<String, dynamic>.from(rawConfig)
          : const {},
    );
  }
}

class TaskOutputSnapshot {
  const TaskOutputSnapshot({
    required this.taskId,
    required this.producedAtMs,
    required this.payload,
    required this.charSize,
  });

  final String taskId;
  final int producedAtMs;
  final Map<String, dynamic> payload;
  final int charSize;

  Map<String, dynamic> toJson() => {
    'task': taskId,
    'at': producedAtMs,
    'chars': charSize,
    'payload': payload,
  };

  factory TaskOutputSnapshot.fromJson(Map<String, dynamic> json) {
    final raw = json['payload'];
    return TaskOutputSnapshot(
      taskId: '${json['task'] ?? ''}',
      producedAtMs: (json['at'] as num?)?.toInt() ?? 0,
      charSize: (json['chars'] as num?)?.toInt() ?? 0,
      payload: raw is Map<String, dynamic>
          ? Map<String, dynamic>.from(raw)
          : raw is Map
          ? Map<String, dynamic>.from(raw)
          : const {},
    );
  }
}

class TaskRunLogEntry {
  const TaskRunLogEntry({
    required this.startedAtMs,
    required this.finishedAtMs,
    required this.success,
    required this.skipped,
    required this.modelCalls,
    required this.inputChars,
    required this.outputChars,
    required this.reason,
    this.error,
  });

  final int startedAtMs;
  final int finishedAtMs;
  final bool success;
  final bool skipped;
  final int modelCalls;
  final int inputChars;
  final int outputChars;
  final String reason;
  final String? error;

  Map<String, dynamic> toJson() => {
    's': startedAtMs,
    'f': finishedAtMs,
    'ok': success,
    if (skipped) 'skip': true,
    'calls': modelCalls,
    'in': inputChars,
    'out': outputChars,
    'reason': reason,
    if (error != null && error!.isNotEmpty) 'err': error,
  };

  factory TaskRunLogEntry.fromJson(Map<String, dynamic> json) =>
      TaskRunLogEntry(
        startedAtMs: (json['s'] as num?)?.toInt() ?? 0,
        finishedAtMs: (json['f'] as num?)?.toInt() ?? 0,
        success: json['ok'] == true,
        skipped: json['skip'] == true,
        modelCalls: (json['calls'] as num?)?.toInt() ?? 0,
        inputChars: (json['in'] as num?)?.toInt() ?? 0,
        outputChars: (json['out'] as num?)?.toInt() ?? 0,
        reason: '${json['reason'] ?? ''}',
        error: json['err'] as String?,
      );
}

class TaskRuntime {
  TaskRuntime({required this.taskId});

  final String taskId;
  bool running = false;
  int? runningSinceMs;
  int? lastStartedAtMs;
  int? lastFinishedAtMs;
  DateTime? nextDueAt;
  bool? lastSuccess;
  String? lastError;
  int totalModelCalls = 0;
  int lastModelCalls = 0;
  int lastInputChars = 0;
  int lastOutputChars = 0;
  TaskOutputSnapshot? lastOutput;
  List<TaskRunLogEntry> logs = const [];

  Map<String, dynamic> toJson() => {
    'running': running,
    if (runningSinceMs != null) 'since': runningSinceMs,
    if (lastStartedAtMs != null) 'started': lastStartedAtMs,
    if (lastFinishedAtMs != null) 'finished': lastFinishedAtMs,
    if (nextDueAt != null) 'due': nextDueAt!.millisecondsSinceEpoch,
    if (lastSuccess != null) 'ok': lastSuccess,
    if (lastError != null && lastError!.isNotEmpty) 'err': lastError,
    'calls': totalModelCalls,
    'lastCalls': lastModelCalls,
    'lastIn': lastInputChars,
    'lastOut': lastOutputChars,
    if (lastOutput != null) 'output': lastOutput!.toJson(),
    if (logs.isNotEmpty) 'logs': [for (final log in logs) log.toJson()],
  };

  factory TaskRuntime.fromJson(String taskId, Map<String, dynamic> json) {
    final rt = TaskRuntime(taskId: taskId)
      ..running = json['running'] == true
      ..runningSinceMs = (json['since'] as num?)?.toInt()
      ..lastStartedAtMs = (json['started'] as num?)?.toInt()
      ..lastFinishedAtMs = (json['finished'] as num?)?.toInt()
      ..lastSuccess = json['ok'] is bool ? json['ok'] as bool : null
      ..lastError = json['err'] as String?
      ..totalModelCalls = (json['calls'] as num?)?.toInt() ?? 0
      ..lastModelCalls = (json['lastCalls'] as num?)?.toInt() ?? 0
      ..lastInputChars = (json['lastIn'] as num?)?.toInt() ?? 0
      ..lastOutputChars = (json['lastOut'] as num?)?.toInt() ?? 0;
    final due = (json['due'] as num?)?.toInt();
    if (due != null && due > 0) {
      rt.nextDueAt = DateTime.fromMillisecondsSinceEpoch(due);
    }
    final rawOut = json['output'];
    if (rawOut is Map<String, dynamic>) {
      rt.lastOutput = TaskOutputSnapshot.fromJson(rawOut);
    } else if (rawOut is Map) {
      rt.lastOutput = TaskOutputSnapshot.fromJson(
        Map<String, dynamic>.from(rawOut),
      );
    }
    final rawLogs = json['logs'];
    if (rawLogs is List) {
      rt.logs = [
        for (final item in rawLogs)
          if (item is Map<String, dynamic>)
            TaskRunLogEntry.fromJson(item)
          else if (item is Map)
            TaskRunLogEntry.fromJson(Map<String, dynamic>.from(item)),
      ];
    }
    return rt;
  }
}

class TaskInvocation {
  const TaskInvocation({
    required this.task,
    required this.now,
    required this.reason,
    this.upstream,
    this.simulatedNowMs,
  });

  final ScheduledTaskDefinition task;
  final TaskOutputSnapshot? upstream;
  final DateTime now;
  final String reason;
  final int? simulatedNowMs;
}

class TaskHandlerResult {
  const TaskHandlerResult({
    required this.success,
    this.skipped = false,
    this.error,
    this.output = const {},
    this.modelCalls = 0,
    this.inputChars = 0,
    this.outputChars = 0,
  });

  const TaskHandlerResult.failure(String message)
    : success = false,
      skipped = false,
      error = message,
      output = const {},
      modelCalls = 0,
      inputChars = 0,
      outputChars = 0;

  final bool success;
  final bool skipped;
  final String? error;
  final Map<String, dynamic> output;
  final int modelCalls;
  final int inputChars;
  final int outputChars;
}

typedef TaskHandler = Future<TaskHandlerResult> Function(
  TaskInvocation invocation,
);
