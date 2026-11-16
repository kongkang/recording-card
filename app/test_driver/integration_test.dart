// flutter drive 的标准 driver 入口：
// flutter drive --driver=test_driver/integration_test.dart --target=integration_test/<test>.dart
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
