import AVFoundation
import CoreBluetooth
import Darwin
import Flutter
import Photos
import Speech
import UIKit
import UserNotifications

#if canImport(AppIntents)
import AppIntents
#endif
#if canImport(StoreKit)
import StoreKit
#endif

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
  private var appleAssetBridge: AppleAssetPackBridge?
  private var photoChannel: FlutterMethodChannel?

  private var centralManager: CBCentralManager?
  private var pendingResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 后台被 HealthKit 唤醒时，先挂上观察者，不等 Flutter 引擎。
    HealthSignalBridge.shared.bootstrap()
    #if canImport(AppIntents)
    if #available(iOS 16.0, *) {
      RecordingCardAppShortcuts.updateAppShortcutParameters()
    }
    #endif
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      Self.trimNativeMemory()
    }
    // FlutterAppDelegate / FlutterPluginAppLifeCycleDelegate 未实现可选委托方法
    // `applicationDidReceiveMemoryWarning:`，切勿覆盖并调用 super，否则内存告警会抛出
    // unrecognized selector 崩溃；统一由系统通知回调清理原生内存。
    NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { _ in
      Self.trimNativeMemory()
    }
    // UIScene 迁移：插件注册移至 didInitializeImplicitFlutterEngine
    //（scene 生命周期下 didFinishLaunching 早于隐式引擎初始化，直接注册失效）
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  static func trimNativeMemory() {
    URLCache.shared.removeAllCachedResponses()
    malloc_zone_pressure_relief(nil, 0)
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
    appleAssetBridge = AppleAssetPackBridge.register(with: engineBridge.pluginRegistry)

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
    if let watchRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCWatchHardware") {
      WatchHardwareBridge.shared.register(with: watchRegistrar.messenger())
    }
    // 健康通道与蓝牙共用同一 messenger：勿依赖可能为空的
    // registrar(forPlugin: "RCHealthSignal")，否则设置页一点开就 MissingPlugin 闪退。
    HealthSignalBridge.shared.register(messenger: registrar.messenger())
    ICloudSyncBridge.shared.register(with: registrar.messenger())
    RCStoreKitBridge.shared.register(with: registrar.messenger())
    if let speechRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCSystemSpeech") {
      SystemSpeechBridge.shared.register(with: speechRegistrar.messenger())
    }
    if let agentSpeechRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCAgentSpeech") {
      RCAgentSpeechBridge.shared.register(with: agentSpeechRegistrar.messenger())
    }
    if let localNotifRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCLocalNotifications") {
      LocalNotificationBridge.shared.register(with: localNotifRegistrar.messenger())
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(statusText())
    case "request":
      requestAuthorization(result: result)
    case "setKeepScreenOn":
      let args = call.arguments as? [String: Any]
      let enabled = (args?["enabled"] as? Bool) ?? false
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = enabled
        result(true)
      }
    case "trimMemory":
      Self.trimNativeMemory()
      result(true)
    case "bridgeSymbols":
      let cmdAddr = UInt64(rc_card_bridge_command_addr())
      let freeAddr = UInt64(rc_card_bridge_free_string_addr())
      let verAddr = UInt64(rc_card_bridge_version_addr())
      if cmdAddr != 0 && freeAddr != 0 && verAddr != 0 {
        result([
          "command": String(cmdAddr),
          "free": String(freeAddr),
          "version": String(verAddr),
        ])
      } else {
        result(nil)
      }

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
    // 授权探测用的 CBCentralManager 不能留着，避免与 Rust 侧 btleplug 争抢无线电导致通道被关闭。
    centralManager?.stopScan()
    centralManager = nil
    guard let result = pendingResult else { return }
    pendingResult = nil
    centralManager = nil
    result(statusText())
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    centralManager?.stopScan()
    centralManager = nil
    Self.trimNativeMemory()
    super.applicationDidEnterBackground(application)
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
    case "addStatus":
      let addSt = PHPhotoLibrary.authorizationStatus(for: .addOnly)
      let rwSt = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      if addSt == .authorized || rwSt == .authorized {
        result("granted")
      } else {
        result(Self.photoPermissionText(addSt))
      }
    case "requestAdd":
      let addSt = PHPhotoLibrary.authorizationStatus(for: .addOnly)
      let rwSt = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      if addSt == .authorized || rwSt == .authorized {
        result("granted")
      } else if addSt == .notDetermined {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { updated in
          DispatchQueue.main.async {
            result(Self.photoPermissionText(updated))
          }
        }
      } else {
        result(Self.photoPermissionText(addSt))
      }
    case "saveMediaToAlbum":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        result(["saved": false, "authorized": false, "error": "缺少媒体文件路径"])
        return
      }
      let mediaType = (args["mediaType"] as? String) ?? "photo"
      let capturedAtMs = (args["capturedAtMs"] as? NSNumber)?.int64Value
      let promptIfNeeded = (args["promptIfNeeded"] as? Bool) ?? true
      saveMediaToAlbum(
        path: path,
        mediaType: mediaType,
        capturedAtMs: capturedAtMs,
        promptIfNeeded: promptIfNeeded,
        result: result
      )
    case "importInWindows":
      guard let args = call.arguments as? [String: Any],
            let windows = args["windows"] as? [[String: Any]],
            let outputDir = args["outputDir"] as? String else {
        result(["authorized": false, "photos": []])
        return
      }
      let promptIfNeeded = (args["promptIfNeeded"] as? Bool) ?? false
      importPhotosInWindows(
        windows: windows,
        outputDir: outputDir,
        promptIfNeeded: promptIfNeeded,
        result: result
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func importPhotosInWindows(
    windows: [[String: Any]],
    outputDir: String,
    promptIfNeeded: Bool,
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
            autoreleasepool {
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
                  return
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
        }
        DispatchQueue.main.async {
          result(["authorized": true, "photos": exported])
        }
      }
    }

    let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if current == .notDetermined && promptIfNeeded {
      PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: proceed)
    } else {
      proceed(current)
    }
  }

  private func saveMediaToAlbum(
    path: String,
    mediaType: String,
    capturedAtMs: Int64?,
    promptIfNeeded: Bool,
    result: @escaping FlutterResult
  ) {
    guard FileManager.default.fileExists(atPath: path) else {
      result(["saved": false, "authorized": true, "error": "本地媒体文件不存在"])
      return
    }

    let proceed: (PHAuthorizationStatus) -> Void = { status in
      let allowed = (status == .authorized || status == .limited)
      guard allowed else {
        DispatchQueue.main.async {
          result(["saved": false, "authorized": false, "error": "未获得系统相册写入权限"])
        }
        return
      }

      DispatchQueue.global(qos: .userInitiated).async {
        let fileURL = URL(fileURLWithPath: path)
        var createdLocalId: String?
        PHPhotoLibrary.shared().performChanges({
          let request: PHAssetCreationRequest? = mediaType == "video"
            ? PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            : PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
          if let req = request {
            if let ms = capturedAtMs, ms > 0 {
              req.creationDate = Date(timeIntervalSince1970: Double(ms) / 1000.0)
            }
            createdLocalId = req.placeholderForCreatedAsset?.localIdentifier
          }
        }) { success, error in
          DispatchQueue.main.async {
            if success {
              result([
                "saved": true,
                "authorized": true,
                "localIdentifier": createdLocalId ?? "",
              ])
            } else {
              result([
                "saved": false,
                "authorized": true,
                "error": error?.localizedDescription ?? "写入系统相册失败",
              ])
            }
          }
        }
      }
    }

    let addSt = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    let rwSt = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if addSt == .authorized || rwSt == .authorized {
      proceed(.authorized)
    } else if addSt == .notDetermined && promptIfNeeded {
      PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: proceed)
    } else {
      proceed(addSt)
    }
  }
}

extension AppDelegate: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // 状态就绪不等于授权已决定：授权对话框点选后会再次回调，
    // 实际判定交给 pollAuthorization（见 requestAuthorization 的说明）。
  }
}

/// OS1 原生语音交互通道：发送端 SFSpeechRecognizer 实时听写 + 接收端 AVSpeechSynthesizer 本地播报。
final class RCAgentSpeechBridge: NSObject, AVSpeechSynthesizerDelegate {
  static let shared = RCAgentSpeechBridge()

  private var channel: FlutterMethodChannel?
  private let synthesizer = AVSpeechSynthesizer()
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var audioEngine: AVAudioEngine?
  private var listening = false
  private var speaking = false
  private var lastTranscript = ""
  private var finalizing = false
  private var listenGeneration: UInt64 = 0

  private override init() {
    super.init()
    synthesizer.delegate = self
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(
      name: "com.reai.recordingcard/agent_speech",
      binaryMessenger: messenger
    )
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = ch
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startListening":
      let args = call.arguments as? [String: Any] ?? [:]
      let localeId = args["locale"] as? String ?? "zh-CN"
      startListening(localeId: localeId, result: result)
    case "stopListening":
      stopListening(emitFinal: true)
      result(nil)
    case "speak":
      let args = call.arguments as? [String: Any] ?? [:]
      let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let localeId = args["locale"] as? String ?? "zh-CN"
      speak(text: text, localeId: localeId)
      result(nil)
    case "stopSpeaking":
      stopSpeaking()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startListening(localeId: String, result: @escaping FlutterResult) {
    stopSpeaking()
    stopListening(emitFinal: false)

    ensureSpeechAndMicPermissions { [weak self] granted, errorText in
      DispatchQueue.main.async {
        guard let self else {
          result(false)
          return
        }
        guard granted else {
          self.emitError(errorText ?? "需要允许语音识别与麦克风权限")
          result(false)
          return
        }
        do {
          try self.beginRecognition(localeId: localeId)
          result(true)
        } catch {
          self.stopListening(emitFinal: false)
          self.emitError("语音识别启动失败：\(error.localizedDescription)")
          result(false)
        }
      }
    }
  }

  private func ensureSpeechAndMicPermissions(
    done: @escaping (Bool, String?) -> Void
  ) {
    let proceedMic = {
      let session = AVAudioSession.sharedInstance()
      switch session.recordPermission {
      case .granted:
        done(true, nil)
      case .denied:
        done(false, "请在系统设置允许麦克风权限后再使用语音对话")
      case .undetermined:
        session.requestRecordPermission { ok in
          done(ok, ok ? nil : "需要麦克风权限才能进行语音对话")
        }
      @unknown default:
        done(false, "麦克风权限不可用")
      }
    }

    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      proceedMic()
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { status in
        if status == .authorized {
          proceedMic()
        } else {
          done(false, "请在系统设置允许语音识别权限后再使用语音对话")
        }
      }
    default:
      done(false, "请在系统设置允许语音识别权限后再使用语音对话")
    }
  }

  private func beginRecognition(localeId: String) throws {
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
      ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    guard let recognizer, recognizer.isAvailable else {
      throw NSError(
        domain: "RCAgentSpeech",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "当前设备系统语音识别暂不可用"]
      )
    }

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    speechRecognizer = recognizer
    recognitionRequest = req
    lastTranscript = ""
    finalizing = false

    if PhoneMicBridge.shared.isCapturing {
      // 本机正在后台保底/独立录音：共享输入 Tap，不打断正在采集的切片流水线
      PhoneMicBridge.shared.auxiliaryBufferTap = { [weak self, weak req] buffer in
        req?.append(buffer)
        self?.emitAudioLevel(buffer)
      }
    } else {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .measurement,
        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers, .mixWithOthers]
      )
      try session.setActive(true)

      let engine = AVAudioEngine()
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      input.installTap(onBus: 0, bufferSize: 1024, format: format) {
        [weak self, weak req] buffer, _ in
        req?.append(buffer)
        self?.emitAudioLevel(buffer)
      }
      engine.prepare()
      try engine.start()
      audioEngine = engine
    }

    listening = true
    listenGeneration &+= 1
    let gen = listenGeneration
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onListenState", arguments: ["listening": true])
    }

    recognitionTask = recognizer.recognitionTask(with: req) { [weak self] res, err in
      DispatchQueue.main.async {
        guard let self, self.listenGeneration == gen else { return }
        if let res {
          let text = res.bestTranscription.formattedString
          self.lastTranscript = text
          let isFinal = res.isFinal
          self.channel?.invokeMethod("onTranscript", arguments: [
            "text": text,
            "isFinal": isFinal,
          ])
          if isFinal {
            self.stopListening(emitFinal: false)
          }
        } else if let err, !self.finalizing, self.listening {
          self.stopListening(emitFinal: false)
          self.emitError("未能听清语音：\(err.localizedDescription)")
        }
      }
    }
  }

  private func stopListening(emitFinal: Bool) {
    finalizing = true
    listenGeneration &+= 1
    let wasListening = listening
    let captured = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    listening = false

    PhoneMicBridge.shared.auxiliaryBufferTap = nil
    if let engine = audioEngine {
      engine.inputNode.removeTap(onBus: 0)
      if engine.isRunning { engine.stop() }
      audioEngine = nil
    }
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    recognitionTask?.cancel()
    recognitionTask = nil

    if wasListening {
      if !PhoneMicBridge.shared.isCapturing {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
          .playAndRecord,
          mode: .default,
          options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
        )
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if emitFinal && !captured.isEmpty {
          self.channel?.invokeMethod("onTranscript", arguments: [
            "text": captured,
            "isFinal": true,
          ])
        }
        self.channel?.invokeMethod("onListenState", arguments: ["listening": false])
      }
    }
  }

  private func speak(text: String, localeId: String) {
    guard !text.isEmpty else { return }
    if listening {
      stopListening(emitFinal: false)
    }
    stopSpeaking()
    // 即使本机麦克风正在采集（PhoneMicBridge.shared.isCapturing == true），也必须确保
    // AVAudioSession 处于 .playAndRecord + mode: .default + .defaultToSpeaker，
    // 避免此前 SFSpeechRecognizer 留下的 .measurement 模式导致 TTS 从听筒极小声输出。
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(
      .playAndRecord,
      mode: .default,
      options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
    )
    try? session.setActive(true)

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: localeId)
      ?? AVSpeechSynthesisVoice(language: "zh-CN")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    speaking = true
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onSpeakState", arguments: ["speaking": true])
    }
    synthesizer.speak(utterance)
  }

  private func stopSpeaking() {
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    if speaking {
      speaking = false
      DispatchQueue.main.async { [weak self] in
        self?.channel?.invokeMethod("onSpeakState", arguments: ["speaking": false])
      }
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    speaking = false
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onSpeakState", arguments: ["speaking": false])
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    speaking = false
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onSpeakState", arguments: ["speaking": false])
    }
  }

  private func emitAudioLevel(_ buffer: AVAudioPCMBuffer) {
    guard let ptr = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
    let count = Int(buffer.frameLength)
    var sum: Float = 0
    for i in stride(from: 0, to: count, by: 4) {
      let s = ptr[i]
      sum += s * s
    }
    let rms = sqrt(sum / Float(max(1, count / 4)))
    let level = min(1.0, max(0.0, Double(rms * 8.0)))
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onSoundLevel", arguments: ["level": level])
    }
  }

  private func emitError(_ message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("onSpeechError", arguments: ["message": message])
    }
  }
}

/// 本地系统通知桥：蓝牙意外断连、自动切换 Watch/手机接力、后台受限待点开接力、重连成功提醒。
final class LocalNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
  static let shared = LocalNotificationBridge()

  private var channel: FlutterMethodChannel?

  private override init() {
    super.init()
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(
      name: "com.reai.recordingcard/local_notifications",
      binaryMessenger: messenger
    )
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = ch
    let center = UNUserNotificationCenter.current()
    if center.delegate == nil {
      center.delegate = self
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermission":
      UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound, .badge]
      ) { granted, _ in
        DispatchQueue.main.async {
          result(granted ? "granted" : "denied")
        }
      }
    case "notify":
      let args = call.arguments as? [String: Any] ?? [:]
      let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let reqId = (id?.isEmpty == false) ? id! : "rc_device_alert"
      let title = (args["title"] as? String) ?? "录音卡"
      let body = (args["body"] as? String) ?? ""
      let urgent = (args["urgent"] as? Bool) ?? false
      let center = UNUserNotificationCenter.current()
      if center.delegate == nil {
        center.delegate = self
      }
      center.getNotificationSettings { settings in
        let auth = settings.authorizationStatus
        guard auth == .authorized || auth == .provisional || auth == .ephemeral else {
          DispatchQueue.main.async { result(false) }
          return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if #available(iOS 15.0, *) {
          content.interruptionLevel = urgent ? .timeSensitive : .active
        }
        let req = UNNotificationRequest(identifier: reqId, content: content, trigger: nil)
        center.add(req) { err in
          DispatchQueue.main.async {
            result(err == nil)
          }
        }
      }
    case "cancel":
      let args = call.arguments as? [String: Any] ?? [:]
      let id = (args["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let reqId = (id?.isEmpty == false) ? id! : "rc_device_alert"
      let center = UNUserNotificationCenter.current()
      center.removePendingNotificationRequests(withIdentifiers: [reqId])
      center.removeDeliveredNotifications(withIdentifiers: [reqId])
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound, .list])
    } else {
      completionHandler([.alert, .sound])
    }
  }
}

/// 原生 StoreKit 2 内购与订阅桥接：商品查询、发起购买、恢复购买、监听续订/退款并管理订阅。
final class RCStoreKitBridge {
  static let shared = RCStoreKitBridge()

  private var channel: FlutterMethodChannel?
  #if canImport(StoreKit)
  private var cachedProducts: [String: Any] = [:]
  private var updatesTask: Task<Void, Never>?
  #endif

  private init() {}

  func register(with messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(
      name: "com.reai.recordingcard/storekit",
      binaryMessenger: messenger
    )
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = ch
    startObservingUpdatesIfNeeded()
  }

  private func startObservingUpdatesIfNeeded() {
    #if canImport(StoreKit)
    guard updatesTask == nil else { return }
    if #available(iOS 15.0, *) {
      updatesTask = Task.detached(priority: .background) { [weak self] in
        for await verification in Transaction.updates {
          guard let self else { break }
          if case .verified(let tx) = verification {
            await tx.finish()
            await MainActor.run {
              self.channel?.invokeMethod("onEntitlementsUpdated", arguments: nil)
            }
          }
        }
      }
    }
    #endif
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    #if canImport(StoreKit)
    guard #available(iOS 15.0, *) else {
      result(unavailablePayload(for: call.method, message: "需要 iOS 15.0 及以上系统版本"))
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "loadProducts":
      let ids = args["productIds"] as? [String] ?? []
      Task { @MainActor [weak self] in
        guard let self else {
          result(["products": []])
          return
        }
        result(await self.loadProducts(ids: ids))
      }
    case "currentEntitlements":
      Task { @MainActor [weak self] in
        guard let self else {
          result(["entitlements": []])
          return
        }
        let entries = await self.collectCurrentEntitlements()
        result(["entitlements": entries])
      }
    case "purchase":
      let productId = (args["productId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      Task { @MainActor [weak self] in
        guard let self else {
          result(["status": "error", "message": "StoreKit 服务未就绪"])
          return
        }
        result(await self.purchaseProduct(productId: productId))
      }
    case "restorePurchases":
      Task { @MainActor [weak self] in
        guard let self else {
          result(["status": "error", "message": "StoreKit 服务未就绪"])
          return
        }
        result(await self.restorePurchases())
      }
    case "manageSubscriptions":
      Task { @MainActor [weak self] in
        guard let self else {
          result(false)
          return
        }
        result(await self.showManageSubscriptions())
      }
    default:
      result(FlutterMethodNotImplemented)
    }
    #else
    result(unavailablePayload(for: call.method, message: "当前平台未链接 StoreKit"))
    #endif
  }

  private func unavailablePayload(for method: String, message: String) -> Any {
    switch method {
    case "loadProducts":
      return ["products": [], "error": message]
    case "currentEntitlements":
      return ["entitlements": []]
    case "purchase", "restorePurchases":
      return ["status": "unavailable", "message": message]
    case "manageSubscriptions":
      return false
    default:
      return FlutterMethodNotImplemented
    }
  }

  #if canImport(StoreKit)
  @available(iOS 15.0, *)
  @MainActor
  private func loadProducts(ids: [String]) async -> [String: Any] {
    guard !ids.isEmpty else { return ["products": []] }
    do {
      let products = try await Product.products(for: Set(ids))
      var list: [[String: Any]] = []
      for product in products {
        cachedProducts[product.id] = product
        list.append(productDict(product))
      }
      return ["products": list]
    } catch {
      return ["products": [], "error": error.localizedDescription]
    }
  }

  @available(iOS 15.0, *)
  private func productDict(_ p: Product) -> [String: Any] {
    let typeString: String
    switch p.type {
    case .consumable:
      typeString = "consumable"
    case .nonConsumable:
      typeString = "nonConsumable"
    case .autoRenewable:
      typeString = "autoRenewable"
    case .nonRenewable:
      typeString = "nonRenewable"
    default:
      typeString = "unknown"
    }
    return [
      "id": p.id,
      "displayName": p.displayName,
      "description": p.description,
      "displayPrice": p.displayPrice,
      "price": NSDecimalNumber(decimal: p.price).doubleValue,
      "currencyCode": p.priceFormatStyle.currencyCode,
      "type": typeString,
    ]
  }

  @available(iOS 15.0, *)
  private func collectCurrentEntitlements() async -> [[String: Any]] {
    var entries: [[String: Any]] = []
    for await verification in Transaction.currentEntitlements {
      guard case .verified(let tx) = verification else { continue }
      if tx.revocationDate != nil { continue }
      var entry: [String: Any] = [
        "productId": tx.productID,
        "transactionId": String(tx.id),
        "originalTransactionId": String(tx.originalID),
        "isUpgraded": tx.isUpgraded,
      ]
      if let exp = tx.expirationDate {
        entry["expirationDateMs"] = Int64(exp.timeIntervalSince1970 * 1000)
      }
      entries.append(entry)
    }
    return entries
  }

  @available(iOS 15.0, *)
  @MainActor
  private func purchaseProduct(productId: String) async -> [String: Any] {
    guard !productId.isEmpty else {
      return ["status": "unavailable", "message": "无效的商品编号"]
    }
    do {
      var product = cachedProducts[productId] as? Product
      if product == nil {
        let fetched = try await Product.products(for: [productId])
        if let first = fetched.first {
          cachedProducts[first.id] = first
          product = first
        }
      }
      guard let targetProduct = product else {
        return [
          "status": "unavailable",
          "message": "App Store 暂未返回该商品（请确认已在 App Store Connect 生效并登录 Sandbox/Apple 账号）",
        ]
      }
      let purchaseResult = try await targetProduct.purchase()
      switch purchaseResult {
      case .success(.verified(let tx)):
        await tx.finish()
        var payload: [String: Any] = [
          "status": "purchased",
          "productId": tx.productID,
          "transactionId": String(tx.id),
          "originalTransactionId": String(tx.originalID),
        ]
        if let exp = tx.expirationDate {
          payload["expirationDateMs"] = Int64(exp.timeIntervalSince1970 * 1000)
        }
        return payload
      case .success(.unverified(_, let err)):
        return ["status": "unverified", "message": err.localizedDescription]
      case .userCancelled:
        return ["status": "cancelled"]
      case .pending:
        return ["status": "pending", "message": "等待家长批准或 Apple 付款确认"]
      @unknown default:
        return ["status": "error", "message": "未知购买状态"]
      }
    } catch {
      return ["status": "error", "message": error.localizedDescription]
    }
  }

  @available(iOS 15.0, *)
  @MainActor
  private func restorePurchases() async -> [String: Any] {
    do {
      try await AppStore.sync()
      let entries = await collectCurrentEntitlements()
      return ["status": "restored", "entitlements": entries]
    } catch {
      return ["status": "error", "message": error.localizedDescription]
    }
  }

  @available(iOS 15.0, *)
  @MainActor
  private func showManageSubscriptions() async -> Bool {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
      return false
    }
    do {
      try await AppStore.showManageSubscriptions(in: scene)
      return true
    } catch {
      return false
    }
  }
  #endif
}


