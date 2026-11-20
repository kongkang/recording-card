import AVFoundation
import FlutterMacOS
import Foundation

/// macOS 本机麦克风：与 iOS `PhoneMicBridge` 同一条通道，
/// 输出 16kHz / 16-bit / 单声道 PCM，供现有切片与转写管线直接使用。
final class PhoneMicBridge {
  static let shared = PhoneMicBridge()

  private var channel: FlutterMethodChannel?
  private var engine = AVAudioEngine()
  private var engineObserver: NSObjectProtocol?
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?
  private var tapToken: UInt64 = 0
  private var tapInstalled = false
  private var running = false

  private init() {
    installObserver()
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

  private func restartAfterConfigurationChange() {
    guard running else { return }
    teardownEngine()
    engine = AVAudioEngine()
    installObserver()
    do {
      try startCapture()
    } catch {
      running = false
      channel?.invokeMethod("error", arguments: "本机录音恢复失败：\(error.localizedDescription)")
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
      } catch {
        result(FlutterError(
          code: "phone_mic_start_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }
    case "stop":
      stopCapture()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func permissionText() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return "granted"
    case .notDetermined:
      return "notDetermined"
    case .denied, .restricted:
      return "denied"
    @unknown default:
      return "denied"
    }
  }

  private func requestPermission(result: @escaping FlutterResult) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      result("granted")
    case .denied, .restricted:
      result("denied")
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
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
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw NSError(
        domain: "RCPhoneMic",
        code: -3,
        userInfo: [NSLocalizedDescriptionKey: "没有麦克风权限"]
      )
    }
    teardownEngine()

    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
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
      self.processBuffer(buffer)
    }
    tapInstalled = true

    engine.prepare()
    try engine.start()
    running = true
  }

  private func stopCapture() {
    running = false
    teardownEngine()
  }

  private func teardownEngine() {
    tapToken &+= 1
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
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
    let status = converter.convert(to: output, error: &convError) { _, outStatus in
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
    guard status != .error, output.frameLength > 0 else { return }

    let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
    let data: Data
    if let samples = output.int16ChannelData?.pointee {
      data = Data(bytes: samples, count: byteCount)
    } else if let raw = output.audioBufferList.pointee.mBuffers.mData {
      data = Data(bytes: raw, count: byteCount)
    } else {
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("pcm", arguments: FlutterStandardTypedData(bytes: data))
    }
  }
}
