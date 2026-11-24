/// 第三方数据自动导入调度器接入：每小时检查开启「自动导入」的接入源。
library;

import '../../core/store/app_store.dart';
import '../schedule/task_schedule.dart';
import '../schedule/task_scheduler.dart';
import 'external_data_hub_store.dart';
import 'getnote_sync_store.dart';

class ExternalDataTaskIds {
  const ExternalDataTaskIds._();

  static const String hourlySync = 'extdata.hourly_sync';
  static const String handlerId = 'extdata_auto_sync';
}

List<ScheduledTaskDefinition> defaultExternalDataTasks() => [
  ScheduledTaskDefinition(
    id: ExternalDataTaskIds.hourlySync,
    name: '第三方数据自动导入',
    detail: '每小时检查开启自动导入的笔记、阅读与录音软件 API，存在新增或更新时自动翻页同步到本地时间轴。',
    enabled: true,
    schedule: TaskSchedule.interval(60),
    handlerId: ExternalDataTaskIds.handlerId,
    config: const {'intervalMinutes': 60},
  ),
];

void registerExternalDataSyncHandler({
  required TaskScheduler scheduler,
  required AppStore appStore,
  required GetNoteSyncStore getNoteStore,
  required ExternalDataHubStore externalHub,
}) {
  scheduler.registerHandler(ExternalDataTaskIds.handlerId, (invocation) async {
    var ranSources = 0;
    var totalAdded = 0;
    final errors = <String>[];

    final gnResult = await getNoteStore.runAutoCheckIfDue(
      appStore: appStore,
      now: invocation.now,
    );
    if (gnResult != null) {
      ranSources += 1;
      totalAdded += gnResult.added;
      if (!gnResult.ok && gnResult.error != null) {
        errors.add('得到大脑：${gnResult.error}');
      }
    }

    final hubResults = await externalHub.runAutoCheckIfDue(
      appStore: appStore,
      now: invocation.now,
    );
    for (final entry in hubResults.entries) {
      ranSources += 1;
      totalAdded += entry.value.added;
      if (!entry.value.ok && entry.value.error != null) {
        errors.add('${entry.key}：${entry.value.error}');
      }
    }

    if (ranSources == 0) {
      return const TaskHandlerResult(success: true, skipped: true);
    }

    return TaskHandlerResult(
      success: errors.isEmpty,
      error: errors.isEmpty ? null : errors.join('；'),
      output: {'ranSources': ranSources, 'added': totalAdded},
    );
  });
}
