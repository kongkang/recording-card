import Foundation
import UIKit

/// 录音卡语音输入法键盘扩展：
/// - 零麦克风采集、零本地模型加载，严格控制在 iOS Keyboard Extension ~30-60MB 安全线以下；
/// - 仅通过 App Group (`group.com.reai.recordingcard`) + Darwin 通知与主应用共享「起止时间戳」，
///   读取 128B 波形帧实时渲染，并在收到润色结果后调用 `textDocumentProxy.insertText` 上屏。
final class KeyboardViewController: UIInputViewController {
  private static let appGroupId = "group.com.reai.recordingcard"
  private static let darwinCmdNotification = "com.reai.recordingcard.kbd.cmd"
  private static let darwinWaveNotification = "com.reai.recordingcard.kbd.wave"
  private static let darwinResultNotification = "com.reai.recordingcard.kbd.result"

  private let statusLabel = UILabel()
  private let waveformView = WaveformView()
  private let recordButton = UIButton(type: .system)
  private let nextKeyboardButton = UIButton(type: .system)
  private let backspaceButton = UIButton(type: .system)

  private var isRecording = false
  private var sessionSeq: UInt64 = 0
  private var activeToken = ""

  override func viewDidLoad() {
    super.viewDidLoad()
    buildUI()
    registerDarwinObservers()
  }

  deinit {
    CFNotificationCenterRemoveEveryObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque()
    )
  }

  private func buildUI() {
    view.backgroundColor = .secondarySystemBackground

    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.textColor = .secondaryLabel
    statusLabel.textAlignment = .center
    statusLabel.text = "点击开始使用录音卡语音输入"
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    waveformView.translatesAutoresizingMaskIntoConstraints = false

    recordButton.setTitle("开始语音输入", for: .normal)
    recordButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    recordButton.backgroundColor = UIColor(red: 0.14, green: 0.50, blue: 0.95, alpha: 1.0)
    recordButton.setTitleColor(.white, for: .normal)
    recordButton.layer.cornerRadius = 22
    recordButton.addTarget(self, action: #selector(toggleDictation), for: .touchUpInside)
    recordButton.translatesAutoresizingMaskIntoConstraints = false

    nextKeyboardButton.setTitle("🌐", for: .normal)
    nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
    nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false

    backspaceButton.setTitle("⌫", for: .normal)
    backspaceButton.addTarget(self, action: #selector(onBackspace), for: .touchUpInside)
    backspaceButton.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(statusLabel)
    view.addSubview(waveformView)
    view.addSubview(recordButton)
    view.addSubview(nextKeyboardButton)
    view.addSubview(backspaceButton)

    NSLayoutConstraint.activate([
      view.heightAnchor.constraint(equalToConstant: 210),

      statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

      waveformView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
      waveformView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      waveformView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      waveformView.heightAnchor.constraint(equalToConstant: 56),

      recordButton.topAnchor.constraint(equalTo: waveformView.bottomAnchor, constant: 18),
      recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      recordButton.widthAnchor.constraint(equalToConstant: 196),
      recordButton.heightAnchor.constraint(equalToConstant: 44),

      nextKeyboardButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      nextKeyboardButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
      nextKeyboardButton.widthAnchor.constraint(equalToConstant: 44),
      nextKeyboardButton.heightAnchor.constraint(equalToConstant: 44),

      backspaceButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      backspaceButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
      backspaceButton.widthAnchor.constraint(equalToConstant: 44),
      backspaceButton.heightAnchor.constraint(equalToConstant: 44),
    ])
  }

  @objc private func onBackspace() {
    textDocumentProxy.deleteBackward()
  }

  @objc private func toggleDictation() {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    if !isRecording {
      isRecording = true
      activeToken = UUID().uuidString
      recordButton.setTitle("完成并转写润色", for: .normal)
      recordButton.backgroundColor = UIColor.systemRed
      statusLabel.text = "正在同步录音卡音频…"
      waveformView.isRecordingActive = true
      sendTimestampCommand(type: "start", timestampMs: nowMs, token: activeToken)
    } else {
      isRecording = false
      recordButton.setTitle("开始语音输入", for: .normal)
      recordButton.backgroundColor = UIColor(red: 0.14, green: 0.50, blue: 0.95, alpha: 1.0)
      statusLabel.text = "正在切段转写与极速润色…"
      waveformView.isRecordingActive = false
      sendTimestampCommand(type: "stop", timestampMs: nowMs, token: activeToken)
    }
  }

  private func sendTimestampCommand(type: String, timestampMs: Int64, token: String) {
    guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else {
      statusLabel.text = "未开启 App Group 共享容器"
      return
    }
    sessionSeq += 1
    let payload: [String: Any] = [
      "seq": sessionSeq,
      "type": type,
      "timestampMs": timestampMs,
      "sessionToken": token,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
    let cmdURL = dir.appendingPathComponent("voice_keyboard_cmd.json")
    try? data.write(to: cmdURL, options: .atomic)
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(Self.darwinCmdNotification as CFString),
      nil,
      nil,
      true
    )
  }

  private func registerDarwinObservers() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      center,
      observer,
      { _, obs, _, _, _ in
        guard let obs else { return }
        let vc = Unmanaged<KeyboardViewController>.fromOpaque(obs).takeUnretainedValue()
        vc.readWaveformFrame()
      },
      Self.darwinWaveNotification as CFString,
      nil,
      .deliverImmediately
    )
    CFNotificationCenterAddObserver(
      center,
      observer,
      { _, obs, _, _, _ in
        guard let obs else { return }
        let vc = Unmanaged<KeyboardViewController>.fromOpaque(obs).takeUnretainedValue()
        vc.readResultPayload()
      },
      Self.darwinResultNotification as CFString,
      nil,
      .deliverImmediately
    )
  }

  private func readWaveformFrame() {
    guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else {
      return
    }
    let fileURL = dir.appendingPathComponent("voice_keyboard_wave.bin")
    guard let data = try? Data(contentsOf: fileURL), data.count >= 52 else { return }
    let active = data[5] == 1
    let bars = Array(data[20..<52])
    DispatchQueue.main.async { [weak self] in
      self?.waveformView.isRecordingActive = active
      self?.waveformView.bars = bars
    }
  }

  private func readResultPayload() {
    guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else {
      return
    }
    let fileURL = dir.appendingPathComponent("voice_keyboard_result.json")
    guard let data = try? Data(contentsOf: fileURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }
    let status = (obj["status"] as? String) ?? ""
    let token = (obj["sessionToken"] as? String) ?? ""
    let text = (obj["text"] as? String) ?? ""
    let err = (obj["error"] as? String) ?? ""
    let routeLabel = (obj["routeLabel"] as? String) ?? ""
    let elapsedMs = (obj["elapsedMs"] as? NSNumber)?.intValue ?? 0

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      switch status {
      case "recording":
        self.statusLabel.text = "录音卡实时波形已连接…"
      case "processing":
        self.statusLabel.text = "正在找气口转写并润色…"
      case "done":
        if !text.isEmpty, token.isEmpty || token == self.activeToken {
          self.textDocumentProxy.insertText(text)
          self.activeToken = ""
        }
        self.statusLabel.text = routeLabel.isEmpty
          ? "已上屏（\(elapsedMs)ms）"
          : "已上屏 · \(routeLabel)（\(elapsedMs)ms）"
      case "error":
        self.isRecording = false
        self.recordButton.setTitle("开始语音输入", for: .normal)
        self.recordButton.backgroundColor = UIColor(red: 0.14, green: 0.50, blue: 0.95, alpha: 1.0)
        self.waveformView.isRecordingActive = false
        self.statusLabel.text = err.isEmpty ? "语音输入失败" : err
      default:
        break
      }
    }
  }
}
