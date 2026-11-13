import CoreBluetooth
import Flutter
import Photos
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
  private var photoChannel: FlutterMethodChannel?

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

    if let photoRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCPhotoLibrary") {
      let pChannel = FlutterMethodChannel(
        name: "com.reai.recordingcard/photos",
        binaryMessenger: photoRegistrar.messenger()
      )
      pChannel.setMethodCallHandler { [weak self] call, result in
        self?.handlePhotos(call, result: result)
      }
      photoChannel = pChannel
    }

    if let micRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCPhoneMic") {
      PhoneMicBridge.shared.register(with: micRegistrar.messenger())
    }
    if let islandRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCLiveActivity") {
      LiveActivityBridge.shared.register(with: islandRegistrar.messenger())
    }
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

  // MARK: - 系统相册录音时段对齐导入（PhotoKit）

  private static func photoPermissionText(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .authorized, .limited:
      return "granted"
    case .notDetermined:
      return "notDetermined"
    case .denied, .restricted:
      return "denied"
    @unknown default:
      return "denied"
    }
  }

  private func handlePhotos(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      result(Self.photoPermissionText(st))
    case "request":
      let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      if current == .notDetermined {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { updated in
          DispatchQueue.main.async {
            result(Self.photoPermissionText(updated))
          }
        }
      } else {
        result(Self.photoPermissionText(current))
      }
    case "importInWindows":
      guard let args = call.arguments as? [String: Any],
            let windows = args["windows"] as? [[String: Any]],
            let outputDir = args["outputDir"] as? String else {
        result(["authorized": false, "photos": []])
        return
      }
      importPhotosInWindows(windows: windows, outputDir: outputDir, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func importPhotosInWindows(
    windows: [[String: Any]],
    outputDir: String,
    result: @escaping FlutterResult
  ) {
    let proceed: (PHAuthorizationStatus) -> Void = { status in
      let allowed = (status == .authorized || status == .limited)
      guard allowed else {
        DispatchQueue.main.async {
          result(["authorized": false, "photos": []])
        }
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        var exported: [[String: Any]] = []
        let imageManager = PHImageManager.default()
        let reqOpts = PHImageRequestOptions()
        reqOpts.isSynchronous = true
        reqOpts.deliveryMode = .highQualityFormat
        reqOpts.isNetworkAccessAllowed = false

        for win in windows {
          guard let eventId = win["eventId"] as? String,
                let startMs = (win["startMs"] as? NSNumber)?.doubleValue,
                let endMs = (win["endMs"] as? NSNumber)?.doubleValue,
                endMs >= startMs else {
            continue
          }
          // 留 5 秒快门时间容差
          let startDate = Date(timeIntervalSince1970: (startMs - 5000.0) / 1000.0)
          let endDate = Date(timeIntervalSince1970: (endMs + 5000.0) / 1000.0)
          let fetchOpts = PHFetchOptions()
          fetchOpts.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            startDate as NSDate,
            endDate as NSDate
          )
          fetchOpts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
          let assets = PHAsset.fetchAssets(with: .image, options: fetchOpts)
          let limit = min(assets.count, 12)
          for idx in 0..<limit {
            let asset = assets.object(at: idx)
            let safeId = asset.localIdentifier
              .replacingOccurrences(of: "/", with: "_")
              .replacingOccurrences(of: ":", with: "_")
            let filePath = (outputDir as NSString).appendingPathComponent("album_\(safeId).jpg")
            if !fm.fileExists(atPath: filePath) {
              var wrote = false
              imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 1280, height: 1280),
                contentMode: .aspectFit,
                options: reqOpts
              ) { image, _ in
                if let img = image, let data = img.jpegData(compressionQuality: 0.82) {
                  try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
                  wrote = true
                }
              }
              if !wrote && !fm.fileExists(atPath: filePath) {
                continue
              }
            }
            let capturedMs = Int64((asset.creationDate?.timeIntervalSince1970 ?? (startMs / 1000.0)) * 1000.0)
            exported.append([
              "id": "alb_\(safeId)",
              "eventId": eventId,
              "path": filePath,
              "capturedAtMs": capturedMs,
              "source": "system_album",
            ])
          }
        }
        DispatchQueue.main.async {
          result(["authorized": true, "photos": exported])
        }
      }
    }

    let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if current == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: proceed)
    } else {
      proceed(current)
    }
  }
}

extension AppDelegate: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // 状态就绪不等于授权已决定：授权对话框点选后会再次回调，
    // 实际判定交给 pollAuthorization（见 requestAuthorization 的说明）。
  }
}


