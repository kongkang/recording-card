/// 导出失败异常 —— 所有导出链路上的失败都以此类型抛出，message 为可直接展示给用户的中文文案。
///
/// 设计约束：
/// - 不做静默降级或吞异常，调用方拿到异常后统一提示，不猜测内部细节；
/// - [cause] / [stackTrace] 保留原始错误，便于日志排查（不拼进 message，避免给用户看堆栈）。
library;

class ExportException implements Exception {
  const ExportException(this.message, {this.cause, this.stackTrace});

  /// 面向用户的中文错误文案。
  final String message;

  /// 原始异常（可为空）；用于日志，不展示给用户。
  final Object? cause;

  /// 原始堆栈（可为空）。
  final StackTrace? stackTrace;

  @override
  String toString() =>
      cause == null ? 'ExportException: $message' : 'ExportException: $message（原因：$cause）';
}
