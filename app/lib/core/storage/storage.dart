/// 本地持久化层统一出口。
///
/// 其他模块只 import 这一个文件：`import 'package:recording_card/core/storage/storage.dart';`
library;

export 'json_store.dart';
export 'key_value_store.dart';
export 'secure_store.dart';
