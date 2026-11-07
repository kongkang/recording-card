/// Setting 页 —— 录音转录配置开关（转录配置放 Setting，不放状态弹层）。
library;
import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';

class SettingPage extends StatefulWidget {
  const SettingPage({super.key});

  @override
  State<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends State<SettingPage> {
  final _switches = <String, bool>{
    '持续录音': true,
    '标记重要对话': true,
    '自动转录': true,
    '自动清洗口语': true,
    '说话人推测归类': true,
    '仅 Wi-Fi 同步': false,
  };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
      children: [
        const Text('录音',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        for (final e in _switches.entries.toList().asMap().entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(child: Text(e.value.key, style: const TextStyle(fontSize: 15))),
                GestureDetector(
                  key: Key('sw-${e.key}'),
                  onTap: () => setState(() => _switches[e.value.key] = !e.value.value),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 44,
                    height: 26,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: e.value.value ? RCColors.ok : RCColors.ax,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Align(
                      alignment: e.value.value
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
    );
  }
}
