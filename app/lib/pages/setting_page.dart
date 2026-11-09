/// Setting switches apply real recording/task policy and persist in AppStore.
library;

import 'package:flutter/material.dart';

import '../core/store/app_backend.dart';
import '../core/store/app_store.dart';
import '../core/theme/tokens.dart';
import '../widgets/store_scope.dart';

/// 设置页：与原型 `#p-setting` 对齐——分组小标题 + 描边卡片 + 组内分隔线，
/// 末尾「关于录音卡」说明。开关索引与 `RecordingPolicy.labels` 一一对应。
class SettingPage extends StatelessWidget {
  const SettingPage({super.key});

  static const _groups = <(String, List<int>)>[
    ('录音', [0, 1]),
    ('转录与清洗', [2, 3, 4]),
    ('同步', [5]),
  ];

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 32),
        children: [
          for (final (title, indexes) in _groups) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
              child: Text(
                title,
                key: Key('set-title-$title'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: RCColors.sec,
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: RCColors.card,
                border: Border.all(color: RCColors.sep),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  for (final (i, index) in indexes.indexed) ...[
                    if (i > 0)
                      const Divider(height: 1, color: RCColors.sep),
                    _SwitchRow(store: store, index: index),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 26),
          const Text(
            '关于录音卡',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            '录音卡与设备保持蓝牙连接，录音内容边录边实时同步到手机，'
            '自动转录并整理为对话记录。内容仅保存在本机，未经确认不会上传。版本 1.0.0',
            key: Key('set-about'),
            style: TextStyle(fontSize: 13, height: 1.7, color: RCColors.sec),
          ),
          if (store.settingBusy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '正在应用录音与任务策略…',
                style: TextStyle(fontSize: 12, color: RCColors.sec),
              ),
            ),
          if (store.settingError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                store.settingError!,
                key: const Key('setting-error'),
                style: const TextStyle(fontSize: 12, color: RCColors.danger),
              ),
            ),
          if (store.persistenceError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                store.persistenceError!,
                key: const Key('persistence-error'),
                style: const TextStyle(fontSize: 12, color: RCColors.danger),
              ),
            ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.store, required this.index});
  final AppStore store;
  final int index;

  @override
  Widget build(BuildContext context) {
    final label = RecordingPolicy.labels[index];
    final on = store.policy.values[index];
    final busy = store.settingBusy;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 15)),
          ),
          Semantics(
            label: label,
            toggled: on,
            enabled: !busy,
            child: GestureDetector(
              key: Key('sw-$index'),
              onTap: busy ? null : () => store.toggleSetting(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                // 原型 .sw：50×30，开启态用近黑 var(--label)，关闭态半透明灰
                width: 50,
                height: 30,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: on ? RCColors.label : RCColors.ax,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Align(
                  alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
