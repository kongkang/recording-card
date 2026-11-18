/// 把多轮清洗登记成独立定时任务。
///
/// 短轮直接调用现有 [RollingCleanSegmentService] 所在的刷新路径，不改 `< 30s` 合并、
/// `30–59s` 声学拆段和 `≥ 1 分钟` 静音触发。中轮、长轮只消费上一轮已整理段落。
library;

import 'dart:async';

import '../../core/store/agent_config_store.dart';
import '../../core/store/app_store.dart';
import '../recordings/recording_pipeline.dart';
import 'cleaning_task_ids.dart';
import 'metered_chat.dart';
import 'organize_pass_service.dart';
import 'task_schedule.dart';
import 'task_scheduler.dart';

List<ScheduledTaskDefinition> defaultCleaningTasks({
  required int shortMinutes,
}) {
  return [
    ScheduledTaskDefinition(
      id: CleaningTaskIds.short,
      name: '短轮清洗',
      detail: '按间隔调用现有滚动清洗。这个间隔会同步成清洗周期，重叠策略仍用开发者设置里的段数或分钟。',
      enabled: true,
      schedule: TaskSchedule.interval(shortMinutes),
      handlerId: CleaningTaskIds.rollingHandler,
      config: const {
        'stage': 'short',
        'note': '实现是现有 RollingCleanSegmentService。语音组合并阈值没有改。',
      },
    ),
    ScheduledTaskDefinition(
      id: CleaningTaskIds.medium,
      name: '中轮整理',
      detail: '读取短轮已经整理好的段落再合并。默认关闭，打开后才会按间隔运行。',
      enabled: false,
      schedule: TaskSchedule.interval(30),
      inputFromTaskId: CleaningTaskIds.short,
      handlerId: CleaningTaskIds.organizeHandler,
      config: const {'stage': 'medium', 'prompt': CleaningTaskIds.mediumPrompt},
    ),
    ScheduledTaskDefinition(
      id: CleaningTaskIds.long,
      name: '长轮整理',
      detail: '读取中轮结果再合并成更少的长段。默认关闭。这里还不是完整的长会议算法。',
      enabled: false,
      schedule: TaskSchedule.interval(240),
      inputFromTaskId: CleaningTaskIds.medium,
      handlerId: CleaningTaskIds.organizeHandler,
      config: const {'stage': 'long', 'prompt': CleaningTaskIds.longPrompt},
    ),
  ];
}

void registerCleaningHandlers({
  required TaskScheduler scheduler,
  required AppStore store,
  required RecordingPipeline pipeline,
  required MeteredChatCompletion meter,
  required OrganizePassService organize,
  required AgentConfigStore agentConfig,
}) {
  scheduler.registerHandler(CleaningTaskIds.rollingHandler, (invocation) async {
    final before = meter.snapshot();
    final outcome = await store.evaluateTopicSegmentationAndRefresh(
      sessionJustEnded: invocation.reason == 'session-ended',
      wallClockNowMs: invocation.simulatedNowMs,
    );
    final delta = meter.snapshot().difference(before);
    final state = await pipeline.topicStore.load();
    final payload = OrganizedPayload.fromTopicState(state, stage: 'short');
    final error = outcome.error?.toString();
    return TaskHandlerResult(
      success: error == null,
      skipped: error == null && !outcome.changed,
      error: error,
      output: outcome.changed ? payload.toJson() : const {},
      modelCalls: delta.calls,
      inputChars: delta.inputChars,
      outputChars: delta.outputChars,
    );
  });

  scheduler.registerHandler(CleaningTaskIds.organizeHandler, (
    invocation,
  ) async {
    final stage = '${invocation.task.config['stage'] ?? invocation.task.id}';
    final prompt = '${invocation.task.config['prompt'] ?? ''}';
    final upstream = OrganizedPayload.parse(
      invocation.upstream?.payload,
      fallbackStage: stage,
    );
    var sections = upstream.sections;
    if (sections.isEmpty) {
      final state = await pipeline.topicStore.load();
      final fallbackStage = invocation.task.inputFromTaskId;
      sections = OrganizedPayload.fromTopicState(
        state,
        stage: stage,
        stageTaskId: fallbackStage == CleaningTaskIds.short
            ? null
            : fallbackStage,
      ).sections;
      if (sections.isEmpty) {
        sections = OrganizedPayload.fromTopicState(
          state,
          stage: 'short',
        ).sections;
      }
    }
    if (sections.isEmpty) {
      return const TaskHandlerResult(
        success: true,
        skipped: true,
        error: '上一轮还没有已整理段落',
      );
    }
    final overlapByMinutes = agentConfig.cleanOverlapMode == 'minutes';
    final result = await organize.merge(
      sections: sections,
      prompt: prompt,
      overlapSections: agentConfig.cleanOverlapParagraphs,
      overlapMinutes: agentConfig.cleanOverlapMinutes,
      overlapByMinutes: overlapByMinutes,
    );
    if (!result.ok) {
      return TaskHandlerResult(
        success: false,
        error: result.error,
        modelCalls: result.modelCalls,
        inputChars: result.inputChars,
        outputChars: result.outputChars,
      );
    }
    if (result.modelCalls > 0 || result.sections.isNotEmpty) {
      await writeStageOverlay(
        store: pipeline.topicStore,
        taskId: invocation.task.id,
        sections: result.sections,
        evaluatedAtMs: invocation.now.millisecondsSinceEpoch,
      );
      await store.refreshFromStore();
    }
    final payload = OrganizedPayload(stage: stage, sections: result.sections);
    return TaskHandlerResult(
      success: true,
      skipped: result.modelCalls == 0,
      output: payload.toJson(),
      modelCalls: result.modelCalls,
      inputChars: result.inputChars,
      outputChars: result.outputChars,
    );
  });
}

/// 短轮间隔与 [AgentConfigStore.cleanCycleMinutes] 双向对齐。
void bindCleaningCycle(TaskScheduler scheduler, AgentConfigStore config) {
  var lastCycle = config.cleanCycleMinutes;
  scheduler.onScheduleChanged = (task) {
    if (task.id != CleaningTaskIds.short || task.schedule.mode != 'interval') {
      return;
    }
    final minutes = task.schedule.everyMinutes;
    if (config.cleanCycleMinutes == minutes) return;
    lastCycle = minutes;
    unawaited(config.setCleanCycleMinutes(minutes));
  };
  config.addListener(() {
    final next = config.cleanCycleMinutes;
    if (next == lastCycle) return;
    lastCycle = next;
    final task = scheduler.taskById(CleaningTaskIds.short);
    if (task == null) return;
    if (task.schedule.mode == 'interval' &&
        task.schedule.everyMinutes == next) {
      return;
    }
    unawaited(
      scheduler.updateSchedule(
        CleaningTaskIds.short,
        TaskSchedule.interval(next),
        notifyHook: false,
      ),
    );
  });
}
