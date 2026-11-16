/// 进程内任务调度器：到期判断、同任务互斥锁、上游输出、运行日志。
///
/// 调度器本身不关心清洗。调用方注册 [TaskHandler]，到点或手动触发时执行。
/// 同一任务的两次运行不会并行：运行中的锁会挡住下一次，锁超时则记失败并放行。
library;

import 'package:flutter/foundation.dart';

import '../../core/storage/storage.dart';
import 'task_schedule.dart';

class TaskScheduler extends ChangeNotifier {
  TaskScheduler({
    required JsonStore store,
    DateTime Function()? now,
    this.staleLock = const Duration(minutes: 20),
  }) : _json = store,
       _now = now ?? DateTime.now;

  static const storageKey = 'scheduled_tasks';
  static const int maxLogs = 20;

  final JsonStore _json;
  final DateTime Function() _now;
  final Duration staleLock;

  final Map<String, TaskHandler> _handlers = {};
  final Map<String, TaskRuntime> _runtime = {};
  final Set<String> _inFlight = {};

  List<ScheduledTaskDefinition> _tasks = [];
  bool _loaded = false;

  /// 周期被改写后通知外部（例如把短轮间隔同步回清洗周期）。
  /// [fromUser] 为 false 时是内部对齐，监听方不要再写回。
  void Function(ScheduledTaskDefinition task)? onScheduleChanged;

  List<ScheduledTaskDefinition> get tasks => List.unmodifiable(_tasks);

  bool get isLoaded => _loaded;

  ScheduledTaskDefinition? taskById(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  TaskRuntime runtimeFor(String id) =>
      _runtime.putIfAbsent(id, () => TaskRuntime(taskId: id));

  void registerHandler(String handlerId, TaskHandler handler) {
    _handlers[handlerId] = handler;
  }

  Future<void> load() async {
    final data = await _json.read(storageKey);
    _tasks = [];
    _runtime.clear();
    if (data != null) {
      final rawTasks = data['tasks'];
      if (rawTasks is List) {
        for (final item in rawTasks) {
          final map = _asMap(item);
          if (map == null) continue;
          final task = ScheduledTaskDefinition.fromJson(map);
          if (task.id.isEmpty) continue;
          _tasks.add(task);
          _runtime.putIfAbsent(task.id, () => TaskRuntime(taskId: task.id));
        }
      }
      final rawRuntime = data['runtime'];
      if (rawRuntime is Map) {
        for (final entry in rawRuntime.entries) {
          final map = _asMap(entry.value);
          if (map == null) continue;
          final id = '${entry.key}';
          _runtime[id] = TaskRuntime.fromJson(id, map);
        }
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 缺哪个内置任务就补哪个。已存在的任务保留用户改过的间隔、开关和提示词。
  Future<void> ensureTasks(List<ScheduledTaskDefinition> defaults) async {
    var changed = false;
    for (final seed in defaults) {
      if (_tasks.any((task) => task.id == seed.id)) continue;
      _tasks.add(seed);
      _runtime.putIfAbsent(seed.id, () => TaskRuntime(taskId: seed.id));
      changed = true;
    }
    if (changed) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final index = _indexOf(id);
    if (index < 0 || _tasks[index].enabled == enabled) return;
    _tasks[index] = _tasks[index].copyWith(enabled: enabled);
    await _persist();
    notifyListeners();
  }

  Future<void> updateSchedule(
    String id,
    TaskSchedule schedule, {
    bool notifyHook = true,
  }) async {
    final index = _indexOf(id);
    if (index < 0) return;
    final current = _tasks[index];
    if (current.schedule == schedule) return;
    _tasks[index] = current.copyWith(schedule: schedule);
    final runtime = _runtime[id];
    final finishedMs = runtime?.lastFinishedAtMs;
    if (runtime != null && finishedMs != null) {
      runtime.nextDueAt = schedule.nextAfter(
        DateTime.fromMillisecondsSinceEpoch(finishedMs),
      );
    }
    await _persist();
    notifyListeners();
    if (notifyHook) onScheduleChanged?.call(_tasks[index]);
  }

  Future<void> updateConfig(String id, Map<String, dynamic> config) async {
    final index = _indexOf(id);
    if (index < 0) return;
    _tasks[index] = _tasks[index].copyWith(config: config);
    await _persist();
    notifyListeners();
  }

  Future<void> discardOutputs(Iterable<String> ids) async {
    var changed = false;
    for (final id in ids) {
      final runtime = _runtime[id];
      if (runtime == null || runtime.lastOutput == null) continue;
      runtime.lastOutput = null;
      changed = true;
    }
    if (!changed) return;
    await _persist();
    notifyListeners();
  }

  /// 跑所有已到期且启用的任务。未启用的任务不会跑。
  Future<void> tick({DateTime? now, String reason = 'interval'}) async {
    final clock = now ?? _now();
    _releaseStaleLocks(clock);
    final pending = <ScheduledTaskDefinition>[
      for (final task in _tasks)
        if (task.enabled && !_isLocked(task.id, clock) && _isDue(task, clock))
          task,
    ];
    pending.sort((a, b) => _depth(a).compareTo(_depth(b)));
    for (final task in pending) {
      await _run(task, clock, reason: reason);
    }
  }

  /// 不等周期，立刻跑一次。`onlyIfEnabled` 时关闭的任务直接返回。
  Future<TaskRunLogEntry?> runNow(
    String id, {
    String reason = 'manual',
    bool onlyIfEnabled = false,
    int? simulatedNowMs,
    DateTime? now,
  }) async {
    final task = taskById(id);
    if (task == null) return null;
    if (onlyIfEnabled && !task.enabled) return null;
    final clock = now ?? _now();
    _releaseStaleLocks(clock);
    return _run(
      task,
      clock,
      reason: reason,
      simulatedNowMs: simulatedNowMs,
      quietWhenLocked: false,
    );
  }

  @visibleForTesting
  void debugLock(String id, {required DateTime since}) {
    final runtime = runtimeFor(id);
    runtime.running = true;
    runtime.runningSinceMs = since.millisecondsSinceEpoch;
  }

  Future<TaskRunLogEntry?> _run(
    ScheduledTaskDefinition task,
    DateTime clock, {
    required String reason,
    int? simulatedNowMs,
    bool quietWhenLocked = true,
  }) async {
    if (_inFlight.contains(task.id) || _isLocked(task.id, clock)) {
      if (quietWhenLocked) return null;
      return _recordLockSkip(task, clock, reason);
    }
    _inFlight.add(task.id);
    final runtime = runtimeFor(task.id);
    runtime.running = true;
    runtime.runningSinceMs = clock.millisecondsSinceEpoch;
    runtime.lastStartedAtMs = clock.millisecondsSinceEpoch;
    notifyListeners();
    await _persist();

    TaskHandlerResult result;
    try {
      final handler = _handlers[task.handlerId];
      if (handler == null) {
        result = TaskHandlerResult.failure('未注册处理器 ${task.handlerId}');
      } else {
        final upstreamId = task.inputFromTaskId;
        result = await handler(
          TaskInvocation(
            task: task,
            upstream: upstreamId == null
                ? null
                : _runtime[upstreamId]?.lastOutput,
            now: clock,
            reason: reason,
            simulatedNowMs: simulatedNowMs,
          ),
        );
      }
    } catch (e) {
      result = TaskHandlerResult.failure('$e');
    } finally {
      _inFlight.remove(task.id);
    }

    final finished = _now();
    runtime.running = false;
    runtime.runningSinceMs = null;
    runtime.lastFinishedAtMs = finished.millisecondsSinceEpoch;
    runtime.lastSuccess = result.success;
    runtime.lastError = result.success && !result.skipped ? null : result.error;
    runtime.lastModelCalls = result.modelCalls;
    runtime.lastInputChars = result.inputChars;
    runtime.lastOutputChars = result.outputChars;
    runtime.totalModelCalls += result.modelCalls;
    runtime.nextDueAt = task.schedule.nextAfter(finished);
    if (result.success && !result.skipped && result.output.isNotEmpty) {
      final chars = result.outputChars > 0
          ? result.outputChars
          : _payloadChars(result.output);
      runtime.lastOutput = TaskOutputSnapshot(
        taskId: task.id,
        producedAtMs: finished.millisecondsSinceEpoch,
        payload: result.output,
        charSize: chars,
      );
      if (runtime.lastOutputChars == 0) runtime.lastOutputChars = chars;
    }
    final entry = TaskRunLogEntry(
      startedAtMs: clock.millisecondsSinceEpoch,
      finishedAtMs: finished.millisecondsSinceEpoch,
      success: result.success,
      skipped: result.skipped,
      modelCalls: result.modelCalls,
      inputChars: result.inputChars,
      outputChars: runtime.lastOutputChars,
      reason: reason,
      error: result.error,
    );
    runtime.logs = [
      entry,
      ...runtime.logs,
    ].take(maxLogs).toList(growable: false);
    await _persist();
    notifyListeners();
    return entry;
  }

  TaskRunLogEntry _recordLockSkip(
    ScheduledTaskDefinition task,
    DateTime clock,
    String reason,
  ) {
    final runtime = runtimeFor(task.id);
    const message = '同一任务正在运行，本次已跳过';
    final entry = TaskRunLogEntry(
      startedAtMs: clock.millisecondsSinceEpoch,
      finishedAtMs: clock.millisecondsSinceEpoch,
      success: false,
      skipped: true,
      modelCalls: 0,
      inputChars: 0,
      outputChars: 0,
      reason: reason,
      error: message,
    );
    runtime.lastError = message;
    runtime.lastSuccess = false;
    runtime.logs = [
      entry,
      ...runtime.logs,
    ].take(maxLogs).toList(growable: false);
    notifyListeners();
    return entry;
  }

  void _releaseStaleLocks(DateTime now) {
    for (final runtime in _runtime.values) {
      if (!runtime.running || _inFlight.contains(runtime.taskId)) continue;
      final since = runtime.runningSinceMs;
      if (since == null) {
        runtime.running = false;
        continue;
      }
      final age = now.difference(DateTime.fromMillisecondsSinceEpoch(since));
      if (age < staleLock) continue;
      runtime.running = false;
      runtime.runningSinceMs = null;
      runtime.lastSuccess = false;
      runtime.lastError = '上次运行锁已超时，已释放';
      final entry = TaskRunLogEntry(
        startedAtMs: since,
        finishedAtMs: now.millisecondsSinceEpoch,
        success: false,
        skipped: false,
        modelCalls: 0,
        inputChars: 0,
        outputChars: 0,
        reason: 'lock-timeout',
        error: runtime.lastError,
      );
      runtime.logs = [
        entry,
        ...runtime.logs,
      ].take(maxLogs).toList(growable: false);
    }
  }

  bool _isDue(ScheduledTaskDefinition task, DateTime now) {
    final due = _runtime[task.id]?.nextDueAt;
    if (due == null) return true;
    return !now.isBefore(due);
  }

  bool _isLocked(String id, DateTime now) {
    if (_inFlight.contains(id)) return true;
    final runtime = _runtime[id];
    if (runtime == null || !runtime.running) return false;
    final since = runtime.runningSinceMs;
    if (since == null) return true;
    final age = now.difference(DateTime.fromMillisecondsSinceEpoch(since));
    return age < staleLock;
  }

  int _depth(ScheduledTaskDefinition task, [Set<String>? seen]) {
    final stack = seen ?? <String>{};
    if (!stack.add(task.id)) return 0;
    final upstreamId = task.inputFromTaskId;
    if (upstreamId == null) return 0;
    final parent = taskById(upstreamId);
    if (parent == null) return 0;
    return 1 + _depth(parent, stack);
  }

  int _indexOf(String id) {
    for (var i = 0; i < _tasks.length; i++) {
      if (_tasks[i].id == id) return i;
    }
    return -1;
  }

  Future<void> _persist() {
    return _json.write(storageKey, {
      'tasks': [for (final task in _tasks) task.toJson()],
      'runtime': {
        for (final entry in _runtime.entries) entry.key: entry.value.toJson(),
      },
    });
  }

  static int _payloadChars(Map<String, dynamic> payload) {
    var count = 0;
    void walk(Object? value) {
      if (value is String) {
        count += value.length;
      } else if (value is Map) {
        for (final item in value.values) {
          walk(item);
        }
      } else if (value is List) {
        for (final item in value) {
          walk(item);
        }
      }
    }

    walk(payload);
    return count;
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }
}
