import AVFoundation
import Flutter
import Foundation
import UIKit

final class PhoneMicBridge {
  static let shared = PhoneMicBridge()

  private var channel: FlutterMethodChannel?
  private var engine = AVAudioEngine()
  private var engineObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?
  private var tapToken: UInt64 = 0
  private var running = false
  private var interrupted = false
  private let auxTapLock = NSLock()
  private var _auxiliaryBufferTap: ((AVAudioPCMBuffer) -> Void)?
  var isCapturing: Bool { running }
  var auxiliaryBufferTap: ((AVAudioPCMBuffer) -> Void)? {
    get {
      auxTapLock.lock()
      defer { auxTapLock.unlock() }
      return _auxiliaryBufferTap
    }
    set {
      auxTapLock.lock()
      _auxiliaryBufferTap = newValue
      auxTapLock.unlock()
    }
  }

  private init() {
    installObserver()
    installLifecycleAndSessionObservers()
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(
      name: "com.reai.recordingcard/phone_mic",
      binaryMessenger: messenger
    )
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = ch
  }

  private func installObserver() {
    if let engineObserver {
      NotificationCenter.default.removeObserver(engineObserver)
    }
    engineObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      guard let self, self.running else { return }
      DispatchQueue.main.async { [weak self] in
        self?.restartAfterConfigurationChange()
      }
    }
  }

  private func installLifecycleAndSessionObservers() {
    let center = NotificationCenter.default
    if let interruptionObserver { center.removeObserver(interruptionObserver) }
    if let routeChangeObserver { center.removeObserver(routeChangeObserver) }
    if let didBecomeActiveObserver { center.removeObserver(didBecomeActiveObserver) }

    interruptionObserver = center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      self?.handleAudioInterruption(notification)
    }

    routeChangeObserver = center.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      self?.handleRouteChange(notification)
    }

    didBecomeActiveObserver = center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.channel?.invokeMethod("appBecameActive", arguments: nil)
    }
  }

  private func handleAudioInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
      return
    }
    switch type {
    case .began:
      interrupted = true
    case .ended:
      let wasInterrupted = interrupted
      interrupted = false
      let rawOpts = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOpts).contains(.shouldResume)
      if running && (shouldResume || !engine.isRunning) {
        restartAfterConfigurationChange()
      }
      if wasInterrupted || shouldResume {
        channel?.invokeMethod("audioInterruptionEnded", arguments: ["shouldResume": shouldResume])
      }
    @unknown default:
      break
    }
  }

  private func handleRouteChange(_ notification: Notification) {
    guard running,
          let userInfo = notification.userInfo,
          let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
      return
    }
    if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable || reason == .categoryChange {
      if !engine.isRunning {
        restartAfterConfigurationChange()
      }
    }
  }

  private func restartAfterConfigurationChange() {
    guard running else { return }
    teardownEngine()
    engine = AVAudioEngine()
    installObserver()
    do {
      try startCapture()
    } catch let error as NSError {
      running = false
      let mapped = Self.mapStartError(error)
      channel?.invokeMethod("error", arguments: mapped.message)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(permissionText())
    case "request":
      requestPermission(result: result)
    case "start":
      do {
        try startCapture()
        result(nil)
      } catch let error as NSError {
        let mapped = Self.mapStartError(error)
        result(FlutterError(
          code: mapped.code,
          message: mapped.message,
          details: mapped.details
        ))
      }
    case "stop":
      stopCapture()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func isBackgroundSessionRestriction(_ error: NSError) -> Bool {
    let code = error.code
    return code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue
      || code == AVAudioSession.ErrorCode.cannotStartRecording.rawValue
      || code == AVAudioSession.ErrorCode.insufficientPriority.rawValue
  }

  private static func mapStartError(_ error: NSError) -> (code: String, message: String, details: [String: Any]) {
    let code = error.code
    let isActive = UIApplication.shared.applicationState == .active
    if code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue
      || code == AVAudioSession.ErrorCode.cannotStartRecording.rawValue
    {
      if !isActive {
        return (
          code: "phone_mic_background_restricted",
          message: "系统限制后台冷启动手机麦克风，轻点通知或切回前台将自动开启本机录音",
          details: ["osStatus": code, "retryableOnForeground": true]
        )
      }
      return (
        code: "phone_mic_audio_busy",
        message: "手机麦克风正被其他通话或语音应用占用，释放后将自动重试",
        details: ["osStatus": code, "retryableOnAudioFree": true]
      )
    }
    if code == AVAudioSession.ErrorCode.insufficientPriority.rawValue {
      return (
        code: "phone_mic_audio_busy",
        message: "当前音频通道被系统高优先级通话占用，结束后将自动重试",
        details: ["osStatus": code, "retryableOnAudioFree": true]
      )
    }
    if error.domain == "RCPhoneMic" {
      return (
        code: "phone_mic_start_failed",
        message: error.localizedDescription,
        details: ["osStatus": code]
      )
    }
    return (
      code: "phone_mic_start_failed",
      message: "本机录音暂时无法启动（系统音频状态 \(code)），请稍后重试",
      details: ["osStatus": code]
    )
  }

  private func permissionText() -> String {
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted:
      return "granted"
    case .undetermined:
      return "notDetermined"
    case .denied:
      return "denied"
    @unknown default:
      return "denied"
    }
  }

  private func requestPermission(result: @escaping FlutterResult) {
    let session = AVAudioSession.sharedInstance()
    switch session.recordPermission {
    case .granted:
      result("granted")
    case .denied:
      result("denied")
    case .undetermined:
      session.requestRecordPermission { granted in
        DispatchQueue.main.async {
          result(granted ? "granted" : "denied")
        }
      }
    @unknown default:
      result("denied")
    }
  }

  private func startCapture() throws {
    if running && engine.isRunning { return }
    var bgTask: UIBackgroundTaskIdentifier = .invalid
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "RCPhoneMicStart") {
      if bgTask != .invalid {
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
      }
    }
    defer {
      if bgTask != .invalid {
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
      }
    }

    teardownEngine()

    let session = AVAudioSession.sharedInstance()
    let primaryOptions: AVAudioSession.CategoryOptions = [
      .defaultToSpeaker,
      .allowBluetooth,
      .allowBluetoothA2DP,
      .mixWithOthers,
    ]
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: primaryOptions)
      try session.setActive(true)
    } catch let primaryError as NSError {
      if UIApplication.shared.applicationState == .active &&
          Self.isBackgroundSessionRestriction(primaryError)
      {
        // 前台音频路由自愈：若先前蓝牙 HFP/语音识别状态残留导致激活冲突，重置一次并退回内置麦克风路由
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        try session.setCategory(
          .playAndRecord,
          mode: .default,
          options: [.defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true)
      } else {
        throw primaryError
      }
    }

    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw NSError(
        domain: "RCPhoneMic",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "麦克风输入格式不可用"]
      )
    }
    guard let outFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16_000,
      channels: 1,
      interleaved: true
    ),
    let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
      throw NSError(
        domain: "RCPhoneMic",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "无法初始化本机录音重采样器"]
      )
    }

    targetFormat = outFormat
    converter = conv
    tapToken &+= 1
    let token = tapToken

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
      [weak self] buffer, _ in
      guard let self, self.tapToken == token else { return }
      self.auxiliaryBufferTap?(buffer)
      self.processBuffer(buffer)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch let startError as NSError {
      teardownEngine()
      if UIApplication.shared.applicationState == .active &&
          Self.isBackgroundSessionRestriction(startError)
      {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        try session.setCategory(
          .playAndRecord,
          mode: .default,
          options: [.defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true)
        engine = AVAudioEngine()
        installObserver()
        let retryInput = engine.inputNode
        let retryFmt = retryInput.inputFormat(forBus: 0)
        guard retryFmt.sampleRate > 0, retryFmt.channelCount > 0,
              let retryConv = AVAudioConverter(from: retryFmt, to: outFormat) else {
          throw startError
        }
        targetFormat = outFormat
        converter = retryConv
        tapToken &+= 1
        let retryToken = tapToken
        retryInput.installTap(onBus: 0, bufferSize: 4096, format: retryFmt) {
          [weak self] buffer, _ in
          guard let self, self.tapToken == retryToken else { return }
          self.auxiliaryBufferTap?(buffer)
          self.processBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
      } else {
        throw startError
      }
    }
    interrupted = false
    running = true
  }

  private func stopCapture() {
    running = false
    interrupted = false
    teardownEngine()
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
  }

  private func teardownEngine() {
    tapToken &+= 1
    engine.inputNode.removeTap(onBus: 0)
    if engine.isRunning {
      engine.stop()
    }
    converter?.reset()
    converter = nil
    targetFormat = nil
  }

  private func processBuffer(_ buffer: AVAudioPCMBuffer) {
    guard let converter, let targetFormat else { return }
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let estimatedFrames = AVAudioFrameCount(
      ceil(Double(buffer.frameLength) * ratio) + 64
    )
    guard let output = AVAudioPCMBuffer(
      pcmFormat: targetFormat,
      frameCapacity: max(256, estimatedFrames)
    ) else { return }

    var consumed = false
    var convError: NSError?
    let status = converter.convert(to: output, error: &convError) {
      _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return buffer
    }

    if let convError {
      DispatchQueue.main.async { [weak self] in
        self?.channel?.invokeMethod("error", arguments: convError.localizedDescription)
      }
      return
    }
    guard status != .error, output.frameLength > 0,
          let samples = output.int16ChannelData?.pointee else { return }

    let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
    let data = Data(bytes: samples, count: byteCount)
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("pcm", arguments: FlutterStandardTypedData(bytes: data))
    }
  }
}
