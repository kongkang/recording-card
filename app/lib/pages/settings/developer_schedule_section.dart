/// 开发者设置里的生效模型、定时任务和回放。不靠连点版本号才能打开。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/store/agent_config_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/net/model_provider_store.dart';
import '../../services/schedule/task_schedule.dart';
import '../../services/schedule/task_scheduler.dart';
import '../../widgets/store_scope.dart';

class DeveloperModelSection extends StatelessWidget {
  const DeveloperModelSection({super.key, required this.config});

  final AgentConfigStore config;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final providers = ModelProviderStore.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([config, providers]),
      builder: (context, _) {
        final provider = providers.activeProvider;
        final gatewayModel = config.gatewayModel.trim();
        final model = provider == ModelProvider.wainao
            ? gatewayModel
            : providers.profileFor(provider).modelFor(ModelScene.polish);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _DevLabel('当前生效的清洗模型'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.sep),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    !config.cloudEnabled
                        ? '请选择服务'
                        : model.isEmpty
                        ? '自动选择'
                        : model,
                    key: const Key('dev-effective-model'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: c.label,
                    ),
                  ),
                  if (config.cloudEnabled)
                    Text(
                      provider == ModelProvider.wainao
                          ? '来源：网关默认'
                          : provider.label,
                      key: const Key('dev-model-source'),
                      style: TextStyle(fontSize: 12.5, color: c.sec),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class DeveloperTaskSection extends StatelessWidget {
  const DeveloperTaskSection({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.maybeOf(context);
    final scheduler = store?.taskScheduler;
    if (scheduler == null) {
      return Text(
        '定时任务还没有挂到当前页面。正式启动后会在这里列出短轮、中轮和长轮。',
        key: const Key('dev-task-unmounted'),
        style: TextStyle(fontSize: 12, height: 1.45, color: context.rc.sec),
      );
    }
    return ListenableBuilder(
      listenable: scheduler,
      builder: (context, _) {
        final c = context.rc;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _DevLabel('定时任务'),
            Text(
              '每个任务单独计时。后一轮只读上一轮已经整理好的结果。'
              'iOS 挂起 App 后定时器会停，回到前台才会补跑；本版没有注册系统后台刷新。',
              style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
            ),
            const SizedBox(height: 8),
            for (final task in scheduler.tasks) ...[
              _TaskCard(scheduler: scheduler, task: task),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.scheduler, required this.task});

  final TaskScheduler scheduler;
  final ScheduledTaskDefinition task;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final runtime = scheduler.runtimeFor(task.id);
    final prompt = '${task.config['prompt'] ?? ''}'.trim();
    return Container(
      key: Key('dev-task-${task.id}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.sep),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.name,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: c.label,
                  ),
                ),
              ),
              Text(
                task.enabled ? '启用' : '关闭',
                style: TextStyle(fontSize: 12, color: c.sec),
              ),
              const SizedBox(width: 8),
              Switch(
                key: Key('dev-task-enabled-${task.id}'),
                value: task.enabled,
                onChanged: (value) =>
                    unawaited(scheduler.setEnabled(task.id, value)),
              ),
            ],
          ),
          Text(
            task.detail,
            style: TextStyle(fontSize: 12, height: 1.4, color: c.sec),
          ),
          const SizedBox(height: 6),
          Text(
            '周期 ${task.schedule.label}',
            key: Key('dev-task-interval-${task.id}'),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.label,
            ),
          ),
          if (task.inputFromTaskId != null)
            Text(
              '输入：${task.inputFromTaskId} 的上一轮输出',
              style: TextStyle(fontSize: 12, color: c.sec),
            ),
          Text(
            '上次 ${_formatTime(runtime.lastFinishedAtMs)} · 下次 ${_formatDue(runtime.nextDueAt)}',
            key: Key('dev-task-last-${task.id}'),
            style: TextStyle(fontSize: 12, color: c.sec),
          ),
          Text(
            '模型调用 ${runtime.totalModelCalls} 次'
            ' · 最近 ${runtime.lastModelCalls} 次'
            ' · 输入 ${runtime.lastInputChars} 字'
            ' · 输出 ${runtime.lastOutputChars} 字',
            key: Key('dev-task-calls-${task.id}'),
            style: TextStyle(fontSize: 12, height: 1.4, color: c.sec),
          ),
          if ((runtime.lastError ?? '').isNotEmpty)
            Text(
              runtime.lastError!,
              key: Key('dev-task-error-${task.id}'),
              style: TextStyle(fontSize: 12, height: 1.4, color: c.danger),
            ),
          if (prompt.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              prompt,
              key: Key('dev-task-prompt-${task.id}'),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.4, color: c.ink),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                key: Key('dev-task-edit-${task.id}'),
                onPressed: () => _edit(context),
                child: const Text('编辑周期'),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: Key('dev-task-run-${task.id}'),
                onPressed: runtime.running
                    ? null
                    : () => unawaited(
                        scheduler.runNow(task.id, reason: 'manual'),
                      ),
                child: Text(runtime.running ? '运行中' : '立即运行'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final saved = await showDialog<_TaskEdit>(
      context: context,
      builder: (_) => _TaskEditDialog(task: task),
    );
    if (saved == null) return;
    if (saved.cron.trim().isNotEmpty) {
      await scheduler.updateSchedule(
        task.id,
        TaskSchedule.cron(saved.cron, fallbackMinutes: saved.minutes),
      );
    } else {
      await scheduler.updateSchedule(
        task.id,
        TaskSchedule.interval(saved.minutes),
      );
    }
    if (saved.prompt != null) {
      await scheduler.updateConfig(task.id, {
        ...task.config,
        'prompt': saved.prompt,
      });
    }
  }
}

class _TaskEdit {
  const _TaskEdit({required this.minutes, required this.cron, this.prompt});

  final int minutes;
  final String cron;
  final String? prompt;
}

class _TaskEditDialog extends StatefulWidget {
  const _TaskEditDialog({required this.task});

  final ScheduledTaskDefinition task;

  @override
  State<_TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends State<_TaskEditDialog> {
  late final TextEditingController _minutes = TextEditingController(
    text: '${widget.task.schedule.everyMinutes}',
  );
  late final TextEditingController _cron = TextEditingController(
    text: widget.task.schedule.isCron ? (widget.task.schedule.cron ?? '') : '',
  );
  late final TextEditingController _prompt = TextEditingController(
    text: '${widget.task.config['prompt'] ?? ''}',
  );
  String? _error;

  @override
  void dispose() {
    _minutes.dispose();
    _cron.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _save() {
    final minutes = int.tryParse(_minutes.text.trim());
    if (minutes == null || minutes < 1) {
      setState(() => _error = '请输入大于 0 的分钟数');
      return;
    }
    final cron = _cron.text.trim();
    if (cron.isNotEmpty && CronExpression.tryParse(cron) == null) {
      setState(() => _error = 'cron 需要 5 段：分 时 日 月 周');
      return;
    }
    final hasPrompt = widget.task.config.containsKey('prompt');
    Navigator.of(context).pop(
      _TaskEdit(
        minutes: minutes,
        cron: cron,
        prompt: hasPrompt ? _prompt.text.trim() : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPrompt = widget.task.config.containsKey('prompt');
    return AlertDialog(
      title: Text('编辑${widget.task.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('间隔可以是任意分钟数。5 / 30 / 240 只是例子，不是仅有的选项。'),
            const SizedBox(height: 8),
            TextField(
              key: const Key('dev-task-edit-minutes'),
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '间隔（分钟，1–10080）'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('dev-task-edit-cron'),
              controller: _cron,
              decoration: const InputDecoration(
                labelText: 'cron（可选）',
                hintText: '*/30 * * * *',
              ),
            ),
            if (hasPrompt) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('dev-task-edit-prompt'),
                controller: _prompt,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(labelText: '这一轮的提示词'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: context.rc.danger, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('dev-task-edit-save'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class DeveloperReplaySection extends StatefulWidget {
  const DeveloperReplaySection({super.key});

  @override
  State<DeveloperReplaySection> createState() => _DeveloperReplaySectionState();
}

class _DeveloperReplaySectionState extends State<DeveloperReplaySection> {
  static const _presets = [1, 5, 10];
  int _minutes = 5;
  late final TextEditingController _custom = TextEditingController(text: '5');

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final store = StoreScope.maybeOf(context);
    if (store == null) return;
    final typed = int.tryParse(_custom.text.trim());
    final minutes = typed != null && typed > 0 ? typed : _minutes;
    await store.replayCleaning(windowMinutes: minutes);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final store = StoreScope.maybeOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _DevLabel('用已有录音回放清洗'),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.sep),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '清掉话题分段、滚动清洗结果、云端润色标题和润色对话，保留原始录音、本地转写和音频文件。'
                '然后按模拟窗口把已有转写重新送进清洗和分段。旧的 AI 结果不再显示。',
                style: TextStyle(fontSize: 12, height: 1.45, color: c.sec),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final minutes in _presets)
                    ChoiceChip(
                      key: Key('dev-replay-window-$minutes'),
                      label: Text('$minutes 分钟'),
                      selected: _minutes == minutes,
                      onSelected: (_) {
                        setState(() {
                          _minutes = minutes;
                          _custom.text = '$minutes';
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('dev-replay-window-input'),
                controller: _custom,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '模拟切片窗口（分钟，可自填）',
                ),
                onChanged: (value) {
                  final parsed = int.tryParse(value.trim());
                  if (parsed != null && parsed > 0) {
                    setState(() => _minutes = parsed);
                  }
                },
              ),
              const SizedBox(height: 12),
              if (store == null)
                Text(
                  '当前为独立预览环境，无法操作本地录音库。',
                  style: TextStyle(fontSize: 12, color: c.sec),
                )
              else
                ListenableBuilder(
                  listenable: store,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        key: const Key('dev-replay-run'),
                        onPressed: store.isReplaying
                            ? null
                            : () => unawaited(_run()),
                        icon: store.isReplaying
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.replay, size: 18),
                        label: Text(
                          store.isReplaying ? '正在回放…' : '清除 AI 整理并回放',
                        ),
                      ),
                      if (store.replayStatus.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          store.replayStatus,
                          key: const Key('dev-replay-status'),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: c.sec,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatTime(int? ms) {
  if (ms == null) return '尚未运行';
  final time = DateTime.fromMillisecondsSinceEpoch(ms);
  final month = time.month.toString().padLeft(2, '0');
  final day = time.day.toString().padLeft(2, '0');
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$month-$day $hour:$minute';
}

String _formatDue(DateTime? due) {
  if (due == null) return '未排期';
  final month = due.month.toString().padLeft(2, '0');
  final day = due.day.toString().padLeft(2, '0');
  final hour = due.hour.toString().padLeft(2, '0');
  final minute = due.minute.toString().padLeft(2, '0');
  return '$month-$day $hour:$minute';
}

class _DevLabel extends StatelessWidget {
  const _DevLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.rc.sec,
        ),
      ),
    );
  }
}
