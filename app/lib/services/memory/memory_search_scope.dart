/// 把本机记忆检索服务注入设置页，避免逐层改路由构造函数。
library;

import 'package:flutter/widgets.dart';

import 'memory_search_service.dart';

class MemorySearchScope extends InheritedWidget {
  const MemorySearchScope({
    super.key,
    required this.service,
    required super.child,
  });

  final MemorySearchService? service;

  static MemorySearchService? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MemorySearchScope>()?.service;

  @override
  bool updateShouldNotify(MemorySearchScope oldWidget) =>
      service != oldWidget.service;
}
