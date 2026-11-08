import CoreBluetooth
import Flutter
import UIKit

/// 蓝牙授权桥：让 Dart 侧能在扫描前主动申请权限并知道真实状态。
///
/// 为什么需要：Rust SDK 底层用 btleplug → CoreBluetooth，第一次创建
/// `CBCentralManager` 时系统才弹「允许使用蓝牙」对话框。这个弹窗会**阻塞扫描**，
/// 用户如果在别处（例如锁屏 / 后台）错过它，扫描就会一直等不到结果。
/// 所以在 Dart 侧点击扫描之前，先用这里同步一次授权状态；未授权就主动发起申请，
/// 并把状态回传给界面提示用户。
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var bluetoothChannel: FlutterMethodChannel?

  private var centralManager: CBCentralManager?
  private var pendingResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // UIScene 迁移：插件注册移至 didInitializeImplicitFlutterEngine
    //（scene 生命周期下 didFinishLaunching 早于隐式引擎初始化，直接注册失效）
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCBluetoothAuth") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.reai.recordingcard/bluetooth",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    bluetoothChannel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(statusText())
    case "request":
      requestAuthorization(result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 授权状态字符串，与 Dart 侧 `BluetoothAuthorization` 一一对应。
  private func statusText() -> String {
    switch CBManager.authorization {
    case .allowedAlways: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
  }

  /// 主动触发系统授权对话框。
  ///
  /// iOS 的坑：创建 `CBCentralManager` 后 `centralManagerDidUpdateState` 会**先**回调一次
  /// （此时 authorization 仍是 notDetermined），用户在对话框点「允许/不允许」之后
  /// 才会再次回调。所以不能第一次回调就返回，必须轮询到状态不再是 notDetermined，
  /// 或者等到超时（用户可能一直不点）。
  private func requestAuthorization(result: @escaping FlutterResult) {
    if CBManager.authorization != .notDetermined {
      result(statusText())
      return
    }
    if pendingResult != nil {
      result(statusText())
      return
    }
    pendingResult = result
    centralManager = CBCentralManager(delegate: self, queue: nil, options: nil)
    pollAuthorization(deadline: Date().addingTimeInterval(30))
  }

  /// 轮询授权状态直到确定（或超时）。
  private func pollAuthorization(deadline: Date) {
    if CBManager.authorization != .notDetermined {
      flushPending()
      return
    }
    if Date() >= deadline {
      flushPending()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.pollAuthorization(deadline: deadline)
    }
  }

  private func flushPending() {
    guard let result = pendingResult else { return }
    pendingResult = nil
    result(statusText())
  }
}

extension AppDelegate: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // 状态就绪不等于授权已决定：授权对话框点选后会再次回调，
    // 实际判定交给 pollAuthorization（见 requestAuthorization 的说明）。
  }
}


