/// Setting switches apply real recording/task policy and persist in AppStore.
library;

import 'package:flutter/material.dart';

import '../core/store/app_backend.dart';
import '../core/theme/tokens.dart';
import '../widgets/store_scope.dart';

class SettingPage extends StatelessWidget {
  const SettingPage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
        children: [
          const Text(
            '录音',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          for (final (index, label) in RecordingPolicy.labels.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(label, style: const TextStyle(fontSize: 15)),
                  ),
                  Semantics(
                    label: label,
                    toggled: store.policy.values[index],
                    enabled: !store.settingBusy,
                    child: GestureDetector(
                      key: Key('sw-$index'),
                      onTap: store.settingBusy
                          ? null
                          : () => store.toggleSetting(index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 44,
                        height: 26,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: store.policy.values[index]
                              ? RCColors.ok
                              : RCColors.ax,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Align(
                          alignment: store.policy.values[index]
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            width: 22,
                            height: 22,
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
            ),
          if (store.settingBusy)
            const Text(
              '正在应用录音与任务策略…',
              style: TextStyle(fontSize: 12, color: RCColors.sec),
            ),
          if (store.settingError != null)
            Text(
              store.settingError!,
              key: const Key('setting-error'),
              style: const TextStyle(fontSize: 12, color: RCColors.danger),
            ),
          if (store.persistenceError != null)
            Text(
              store.persistenceError!,
              key: const Key('persistence-error'),
              style: const TextStyle(fontSize: 12, color: RCColors.danger),
            ),
        ],
      ),
    );
  }
}
