/// sherpa-onnx 原生库绑定初始化（跨平台差异集中在这里）。
///
/// 背景：`sherpa_onnx` 1.13.x 的 iOS 加载器写死了
/// `sherpa_onnx.framework/sherpa_onnx`，但 `sherpa_onnx_ios` pod 实际产出的是
/// `SherpaOnnxC.framework/SherpaOnnxC`。直接调用包的 `initBindings()` 会在
/// iOS 上 dlopen 失败。这里绕过它的路径拼装，显式绑定真实 framework。
///
/// 版本钉死 1.13.3；升级 sherpa 时先验证上游是否已修正 iOS 路径，
/// 修了就可以删掉这个 shim（届时 `initBindings()` 直接可用）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
// ignore: implementation_imports
import 'package:sherpa_onnx/src/sherpa_onnx_bindings.dart' as bindings;

bool _initialized = false;

/// 初始化原生绑定；可重复调用（幂等，按 isolate 计）。
///
/// [nativeLibraryPath] 仅桌面平台使用，iOS 忽略。
void initSherpaBindings([String? nativeLibraryPath]) {
  if (_initialized) return;
  if (Platform.isIOS) {
    DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open('SherpaOnnxC.framework/SherpaOnnxC');
    } on Object {
      // 框架已随 App 链接时，进程符号表里也能找到
      lib = DynamicLibrary.process();
    }
    bindings.SherpaOnnxBindings.init(lib);
  } else {
    sherpa.initBindings(nativeLibraryPath);
  }
  _initialized = true;
}
