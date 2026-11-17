import AVFoundation
import CoreBluetooth
import Flutter
import Photos
import Speech
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
    if let healthRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCHealthSignal") {
      HealthSignalBridge.shared.register(messenger: healthRegistrar.messenger())
    }
    if let speechRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCSystemSpeech") {
      SystemSpeechBridge.shared.register(with: speechRegistrar.messenger())
    }
    if let agentSpeechRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "RCAgentSpeech") {
      RCAgentSpeechBridge.shared.register(with: agentSpeechRegistrar.messenger())
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
    if current == .notDetermined && promptIfNeeded {
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
        options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
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
    stopSpeaking()
    if !PhoneMicBridge.shared.isCapturing {
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
      )
      try? session.setActive(true)
    }

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


