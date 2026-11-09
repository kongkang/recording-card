/// 自绘开关（原型 `.sw`：50×30 轨道 + 24 圆点，150ms 过渡）。
///
/// 与系统 Switch 的区别：轨道颜色跟随语义色（深色模式不刺眼），
/// 且不自带手势——由整行/外层负责点击，避免整行点击与开关点击打架。
library;

import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';

class RCSwitch extends StatelessWidget {
  const RCSwitch({super.key, required this.on, this.busy = false});

  final bool on;

  /// 命令进行中：保留当前位置，降低透明度，避免连点。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: busy ? 0.5 : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 50,
        height: 30,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: on ? c.switchTrackOn : c.ax,
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: c.switchThumb,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
