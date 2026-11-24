/// 设置页共享的「清空本机全部数据」确认与清理编排。
library;

import 'package:flutter/material.dart';

import '../../core/platform/crash_guard.dart';
import '../../core/store/device_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/health/health_signal_controller.dart';
import '../../services/memory/memory_search_scope.dart';
import '../../widgets/store_scope.dart';

/// 构造不依赖跨 async gap `BuildContext` 的本机全量清理动作。
Future<void> Function() createLocalDataWipeAction(
  BuildContext context, {
  Future<void> Function()? onClearAllLocalData,
  DeviceStore? device,
  HealthSignalController? healthSignals,
}) {
  if (onClearAllLocalData != null) {
    return onClearAllLocalData;
  }
  final appStore = StoreScope.maybeOf(context);
  final memorySearch = MemorySearchScope.maybeOf(context);
  return () async {
    await device?.stopAllRecordingsForSignOut();
    await appStore?.clearAllLocalData();
    await healthSignals?.clearAllSamples();
    await memorySearch?.clearAll();
    await clearLastCrash();
  };
}

Future<T> _withBusy<T>(
  ValueChanged<bool>? onBusyChanged,
  Future<T> Function() work,
) async {
  onBusyChanged?.call(true);
  try {
    return await work();
  } finally {
    onBusyChanged?.call(false);
  }
}

/// 弹窗确认并清空本机全部用户数据（保留离线语音模型）。
Future<bool> runClearLocalDataFlow(
  BuildContext context, {
  Future<void> Function()? onClearAllLocalData,
  DeviceStore? device,
  HealthSignalController? healthSignals,
  ValueChanged<bool>? onBusyChanged,
}) async {
  final c = context.rc;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final wipe = createLocalDataWipeAction(
    context,
    onClearAllLocalData: onClearAllLocalData,
    device: device,
    healthSignals: healthSignals,
  );

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('clear-local-data-dialog'),
      title: const Text('清空本机全部数据？'),
      content: const Text(
        '将不可恢复地删除本机全部录音、转写文本、总结文档、关联照片记录、声纹标记、健康与位置样本及记忆索引（已下载的离线语音模型会保留）。',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('clear-local-data-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('clear-local-data-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: c.danger,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('确认清空'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  await _withBusy(onBusyChanged, wipe);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('本机数据已清空')));
  return true;
}
