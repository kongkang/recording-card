/// AppStore 注入 —— InheritedNotifier，避免引第三方依赖。
library;

import 'package:flutter/widgets.dart';

import '../core/store/app_store.dart';

class StoreScope extends InheritedNotifier<AppStore> {
  const StoreScope({super.key, required AppStore store, required super.child})
    : super(notifier: store);

  static AppStore of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoreScope>()!.notifier!;
}
