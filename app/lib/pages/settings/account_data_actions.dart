/// 设置页共享的「清空本机全部数据」与「注销账号」确认与清理编排。
library;

import 'package:flutter/material.dart';

import '../../core/platform/crash_guard.dart';
import '../../core/store/device_store.dart';
import '../../core/theme/tokens.dart';
import '../../services/auth_service.dart';
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

/// 弹窗确认并执行「注销账号」全链路：
/// 1) 如实请求服务端 `DELETE /account`；
/// 2) 仅服务端明确受理（2xx）才直接清理并登出；
/// 3) 若服务端接口返回 404/405/501，绝不静默撒谎，提供公开注销页/邮箱指引与「仅清空本机数据并退出」兜底；
/// 4) 网络或 5xx 错误保持登录态并明确报错供重试。
Future<void> runDeleteAccountFlow(
  BuildContext context, {
  required AuthService? authService,
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
      key: const Key('delete-account-dialog'),
      title: const Text('注销账号？'),
      content: const Text(
        '注销不可恢复：将提交服务端在 15 天内彻底删除你的账号与云端处理数据，并立即清空本机全部录音、转写、总结、声纹与健康样本后退出登录。',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('delete-account-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('delete-account-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: c.danger,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('确认注销'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  if (authService == null || !authService.isSignedIn) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('delete-account-error-dialog'),
        title: const Text('无法提交注销请求'),
        content: const Text('当前未登录或未连接账号服务，请登录后再试。'),
        actions: <Widget>[
          TextButton(
            key: const Key('delete-account-error-ok'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return;
  }

  final result = await _withBusy(onBusyChanged, () async {
    await device?.stopAllRecordingsForSignOut();
    final res = await authService.requestRemoteAccountDeletion();
    if (res.remoteDeleted) {
      await wipe();
      await authService.completeLocalAccountCleanupAndSignOut();
    }
    return res;
  });

  if (result.remoteDeleted) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('账号注销申请已提交，本机数据已清空')),
      );
    return;
  }

  if (!context.mounted) return;

  if (result.endpointUnavailable) {
    final localFallback = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('delete-account-unavailable-dialog'),
        title: const Text('服务端在线注销接口部署中'),
        content: const Text(
          '服务端在线注销接口当前不可用。你可以先清空本机全部数据并退出登录，然后访问 '
          'https://ai-card.app.reai.com/support.html#delete-account '
          '或发送邮件至 privacy@reai.chat 完成服务端账号彻底删除（15 个工作日内处理）。',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('delete-account-unavailable-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('delete-account-local-fallback'),
            style: FilledButton.styleFrom(
              backgroundColor: c.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仅清空本机数据并退出'),
          ),
        ],
      ),
    );
    if (localFallback == true) {
      await _withBusy(onBusyChanged, () async {
        await wipe();
        await authService.completeLocalAccountCleanupAndSignOut();
      });
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('本机数据已清空并已退出登录')),
        );
    }
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('delete-account-error-dialog'),
      title: const Text('账号注销失败'),
      content: Text(result.errorMessage ?? '注销请求失败，请稍后重试'),
      actions: <Widget>[
        TextButton(
          key: const Key('delete-account-error-ok'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
