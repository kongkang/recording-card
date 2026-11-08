library;

import 'package:flutter/widgets.dart';

/// 勾选状态标记：包在事件卡外层，供测试统计勾选数（渲染上透明）。
class SelectionMarker extends StatelessWidget {
  const SelectionMarker({
    super.key,
    required this.checked,
    required this.child,
  });
  final bool checked;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
