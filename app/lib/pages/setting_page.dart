/// Setting 页 —— 录音转录配置开关（转录配置放 Setting，不放状态弹层）。
library;
import 'package:flutter/material.dart';

import '../core/store/settings_store.dart';
import '../core/theme/tokens.dart';

class SettingPage extends StatelessWidget {
  const SettingPage({super.key, required this.settings});

  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
        children: [
          const Text('录音',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          for (final (i, key) in settings.keys.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                      child: Text(key, style: const TextStyle(fontSize: 15))),
                  GestureDetector(
                    key: Key('sw-$i'),
                    onTap: () => settings.toggle(key),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 44,
                      height: 26,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: settings.valueOf(key) ? RCColors.ok : RCColors.ax,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Align(
                        alignment: settings.valueOf(key)
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: const BoxDecoration(
                              color: Colors.white, shape: BoxShape.circle),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
