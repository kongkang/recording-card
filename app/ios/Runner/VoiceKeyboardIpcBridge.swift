import Flutter
import Foundation

/// 录音卡语音输入法主应用侧 IPC 桥（App Group `group.com.reai.recordingcard` + Darwin 通知）：
/// - 接收键盘扩展写下的时间戳命令（`voice_keyboard_cmd.json` + `com.reai.recordingcard.kbd.cmd`）；
/// - 原子写入 128 字节固定波形缓冲（`voice_keyboard_wave.bin` + `com.reai.recordingcard.kbd.wave`）；
/// - 写入最终润色结果（`voice_keyboard_result.json` + `com.reai.recordingcard.kbd.result`）。
final class VoiceKeyboardIpcBridge: NSObject, FlutterStreamHandler {
  static let shared = VoiceKeyboardIpcBridge()

  static let appGroupId = "group.com.reai.recordingcard"
  static let darwinCmdNotification = "com.reai.recordingcard.kbd.cmd"
  static let darwinWaveNotification = "com.reai.recordingcard.kbd.wave"
  static let darwinResultNotification = "com.reai.recordingcard.kbd.result"

  private let methodChannelName = "com.reai.recordingcard/voice_keyboard_ipc"
  private let eventChannelName = "com.reai.recordingcard/voice_keyboard_cmd"
  private let ioQueue = DispatchQueue(
    label: "com.reai.recordingcard.voicekbd.ipc",
    qos: .userInteractive
  )

  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?
  private var observerRegistered = false
  private var waveSeq: UInt32 = 0
  private var lastHandledSeq: UInt64 = 0

  private override init() {
    super.init()
  }

  deinit {
    if observerRegistered {
      CFNotificationCenterRemoveEveryObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        Unmanaged.passUnretained(self).toOpaque()
      )
    }
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let mCh = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: messenger
    )
    mCh.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    methodChannel = mCh

    let eCh = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: messenger
    )
    eCh.setStreamHandler(self)
    eventChannel = eCh

    registerDarwinObserverIfNeeded()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    dispatchLatestCommandIfPresent()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func containerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId)
  }

  private func registerDarwinObserverIfNeeded() {
    guard !observerRegistered else { return }
    observerRegistered = true
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      center,
      observer,
      { _, obs, _, _, _ in
        guard let obs else { return }
        let bridge = Unmanaged<VoiceKeyboardIpcBridge>.fromOpaque(obs).takeUnretainedValue()
        bridge.dispatchLatestCommandIfPresent()
      },
      Self.darwinCmdNotification as CFString,
      nil,
      .deliverImmediately
    )
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "publishWaveform":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      let active = (args["active"] as? Bool) ?? false
      let rawBars = (args["bars"] as? [NSNumber]) ?? []
      let tsMs = (args["timestampMs"] as? NSNumber)?.uint64Value ?? 0
      ioQueue.async { [weak self] in
        self?.writeWaveformFrame(active: active, rawBars: rawBars, timestampMs: tsMs)
      }
      result(nil)

    case "publishResult":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      ioQueue.async { [weak self] in
        self?.writeResultJson(args)
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func dispatchLatestCommandIfPresent() {
    ioQueue.async { [weak self] in
      guard let self,
            let dir = self.containerURL() else { return }
      let cmdURL = dir.appendingPathComponent("voice_keyboard_cmd.json")
      guard let data = try? Data(contentsOf: cmdURL),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return
      }
      let seq = (obj["seq"] as? NSNumber)?.uint64Value ?? 0
      if seq > 0 && seq <= self.lastHandledSeq {
        return
      }
      if seq > 0 {
        self.lastHandledSeq = seq
      }
      DispatchQueue.main.async {
        self.eventSink?(obj)
      }
    }
  }

  /// 写入固定 128 字节波形帧：
  /// [0..3] "RCWV" | [4] version=1 | [5] active(0/1) | [6..7] reserved
  /// [8..11] seq(LE) | [12..19] timestampMs(LE) | [20..51] 32 bars uint8 | [52..127] zero pad
  private func writeWaveformFrame(active: Bool, rawBars: [NSNumber], timestampMs: UInt64) {
    guard let dir = containerURL() else { return }
    let fileURL = dir.appendingPathComponent("voice_keyboard_wave.bin")
    waveSeq &+= 1
    var bytes = [UInt8](repeating: 0, count: 128)
    bytes[0] = 0x52 // R
    bytes[1] = 0x43 // C
    bytes[2] = 0x57 // W
    bytes[3] = 0x56 // V
    bytes[4] = 1
    bytes[5] = active ? 1 : 0
    var seqLE = waveSeq.littleEndian
    withUnsafeBytes(of: &seqLE) { buf in
      for i in 0..<4 { bytes[8 + i] = buf[i] }
    }
    var tsLE = timestampMs.littleEndian
    withUnsafeBytes(of: &tsLE) { buf in
      for i in 0..<8 { bytes[12 + i] = buf[i] }
    }
    for i in 0..<min(32, rawBars.count) {
      let v = max(0, min(255, rawBars[i].intValue))
      bytes[20 + i] = UInt8(v)
    }
    let data = Data(bytes)
    try? data.write(to: fileURL, options: .atomic)
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(Self.darwinWaveNotification as CFString),
      nil,
      nil,
      true
    )
  }

  private func writeResultJson(_ payload: [String: Any]) {
    guard let dir = containerURL(),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
      return
    }
    let fileURL = dir.appendingPathComponent("voice_keyboard_result.json")
    try? data.write(to: fileURL, options: .atomic)
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(Self.darwinResultNotification as CFString),
      nil,
      nil,
      true
    )
  }
}
