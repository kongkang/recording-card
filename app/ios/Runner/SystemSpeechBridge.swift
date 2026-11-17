import AVFoundation
import CoreMedia
import Flutter
import Foundation
import Speech

/// iOS 系统语音转写桥接：
/// - iOS 26+（Xcode 26+ SDK）优先使用纯端侧 `SpeechAnalyzer` + `SpeechTranscriber`；
/// - 若新机尚未预置 `SpeechTranscriber` 语言资产，后台静默触发 `AssetInventory` 拉取的同时，
///   当次转写自动用已内置的 `DictationTranscriber`（或纯端侧 `SFSpeechRecognizer`）即时完成；
/// - 严格禁止回落 Apple 云端服务器（仅使用本地离线能力，无可用端侧能力时明确报错）。
final class SystemSpeechBridge: NSObject {
  static let shared = SystemSpeechBridge()
  private static let channelName = "com.reai.recordingcard/system_speech"

  private var channel: FlutterMethodChannel?
  private let warmupLock = NSLock()
  private var warmingLocales = Set<String>()

  private override init() {
    super.init()
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = ch
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result([
        "platform": "ios",
        "osMajorVersion": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        "supportsModernSystemAsr": isModernSystemAsrSupported(),
        "authStatus": Self.authStatusText(SFSpeechRecognizer.authorizationStatus()),
      ])

    case "requestAuthorization":
      let current = SFSpeechRecognizer.authorizationStatus()
      if current == .notDetermined {
        SFSpeechRecognizer.requestAuthorization { updated in
          DispatchQueue.main.async {
            result(Self.authStatusText(updated))
          }
        }
      } else {
        result(Self.authStatusText(current))
      }

    case "transcribeWav":
      guard let args = call.arguments as? [String: Any],
            let wavPath = args["wavPath"] as? String,
            !wavPath.isEmpty else {
        result(
          FlutterError(
            code: "INVALID_ARGS",
            message: "缺少 wavPath 参数",
            details: nil
          )
        )
        return
      }
      let language = (args["language"] as? String) ?? "auto"
      let url = URL(fileURLWithPath: wavPath)
      guard FileManager.default.fileExists(atPath: url.path) else {
        result(
          FlutterError(
            code: "FILE_NOT_FOUND",
            message: "音频文件不存在：\(wavPath)",
            details: nil
          )
        )
        return
      }
      let auth = SFSpeechRecognizer.authorizationStatus()
      if auth == .denied || auth == .restricted {
        result(
          FlutterError(
            code: "PERMISSION_DENIED",
            message: "未开启系统语音识别权限，请在系统设置中开启或切换 SenseVoice 增强模型",
            details: nil
          )
        )
        return
      }

      Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }
        do {
          let payload = try await self.transcribeFile(
            url: url,
            localeId: Self.resolveLocaleId(language)
          )
          DispatchQueue.main.async {
            result(payload)
          }
        } catch {
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "SYSTEM_ASR_FAILED",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func isModernSystemAsrSupported() -> Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return true
    }
    #endif
    return false
  }

  private static func authStatusText(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "denied"
    }
  }

  private static func resolveLocaleId(_ language: String) -> String {
    switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "en", "en-us", "en_us":
      return "en-US"
    case "yue", "zh-hk", "zh_hk":
      return "yue-CN"
    case "zh-tw", "zh_tw":
      return "zh-TW"
    default:
      return "zh-CN"
    }
  }

  private func transcribeFile(url: URL, localeId: String) async throws -> [String: Any] {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      return try await transcribeWithSpeechAnalyzer(url: url, localeId: localeId)
    }
    #endif
    return try await transcribeViaOnDeviceSFSpeech(url: url, localeId: localeId)
  }

  #if compiler(>=6.2)
  @available(iOS 26.0, *)
  private func transcribeWithSpeechAnalyzer(
    url: URL,
    localeId: String
  ) async throws -> [String: Any] {
    let targetLocale = Locale(identifier: localeId)

    // 1. 优先使用系统已预置的高精度 SpeechTranscriber
    if let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: targetLocale)
        ?? (await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)) {
      let bcp47 = speechLocale.identifier(.bcp47)
      let installed = await SpeechTranscriber.installedLocales
      if installed.contains(where: { $0.identifier(.bcp47) == bcp47 }) {
        let transcriber = SpeechTranscriber(
          locale: speechLocale,
          transcriptionOptions: [],
          reportingOptions: [],
          attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let readerTask = Task {
          var combined = AttributedString()
          for try await item in transcriber.results where item.isFinal {
            combined.append(item.text)
          }
          return combined
        }
        do {
          let audioFile = try AVAudioFile(forReading: url)
          if let lastTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastTime)
          } else {
            await analyzer.cancelAndFinishNow()
          }
          let attributed = try await readerTask.value
          let parsed = Self.extractTokensAndTimestamps(from: attributed)
          return [
            "text": parsed.text,
            "tokens": parsed.tokens,
            "timestampsMs": parsed.timestampsMs,
            "lang": bcp47,
          ]
        } catch {
          readerTask.cancel()
          await analyzer.cancelAndFinishNow()
          throw error
        }
      } else {
        // 资产尚未在系统预置：后台静默拉取供后续片段使用，当次立刻走内置垫底
        scheduleSpeechTranscriberAssetInstall(locale: speechLocale, key: bcp47)
      }
    }

    // 2. 瞬态垫底：使用已内置的 DictationTranscriber
    if let dictLocale = await DictationTranscriber.supportedLocale(equivalentTo: targetLocale)
        ?? (await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)) {
      let dictBcp47 = dictLocale.identifier(.bcp47)
      let dictInstalled = await DictationTranscriber.installedLocales
      if dictInstalled.contains(where: { $0.identifier(.bcp47) == dictBcp47 }) {
        let transcriber = DictationTranscriber(
          locale: dictLocale,
          contentHints: [],
          transcriptionOptions: [],
          reportingOptions: [],
          attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let readerTask = Task {
          var combined = AttributedString()
          for try await item in transcriber.results where item.isFinal {
            combined.append(item.text)
          }
          return combined
        }
        do {
          let audioFile = try AVAudioFile(forReading: url)
          if let lastTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastTime)
          } else {
            await analyzer.cancelAndFinishNow()
          }
          let attributed = try await readerTask.value
          let parsed = Self.extractTokensAndTimestamps(from: attributed)
          return [
            "text": parsed.text,
            "tokens": parsed.tokens,
            "timestampsMs": parsed.timestampsMs,
            "lang": dictBcp47,
          ]
        } catch {
          readerTask.cancel()
          await analyzer.cancelAndFinishNow()
          throw error
        }
      }
    }

    // 3. 若两者本地包均未预置，尝试纯端侧 SFSpeechRecognizer（绝不走云端）
    return try await transcribeViaOnDeviceSFSpeech(url: url, localeId: localeId)
  }

  @available(iOS 26.0, *)
  private func scheduleSpeechTranscriberAssetInstall(locale: Locale, key: String) {
    warmupLock.lock()
    let shouldStart = warmingLocales.insert(key).inserted
    warmupLock.unlock()
    guard shouldStart else { return }

    Task.detached(priority: .utility) { [weak self] in
      defer {
        if let self {
          self.warmupLock.lock()
          self.warmingLocales.remove(key)
          self.warmupLock.unlock()
        }
      }
      let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
      )
      if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try? await request.downloadAndInstall()
      }
    }
  }

  private static func extractTokensAndTimestamps(
    from attributed: AttributedString
  ) -> (text: String, tokens: [String], timestampsMs: [Int]) {
    let fullText = String(attributed.characters)
    if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ("", [], [])
    }

    var tokens: [String] = []
    var timestampsMs: [Int] = []
    var hasAnyTimestamp = false
    var lastTimestampMs = 0

    for run in attributed.runs {
      let piece = String(attributed[run.range].characters)
      if piece.isEmpty { continue }
      let chars = Array(piece)
      if let timeRange = run.audioTimeRange,
         timeRange.start.isValid,
         timeRange.duration.isValid {
        let startSec = CMTimeGetSeconds(timeRange.start)
        let durSec = CMTimeGetSeconds(timeRange.duration)
        if startSec.isFinite && durSec.isFinite {
          hasAnyTimestamp = true
          let startMs = max(0, Int((startSec * 1000.0).rounded()))
          let durMs = max(0, Int((durSec * 1000.0).rounded()))
          for (idx, ch) in chars.enumerated() {
            let offsetMs = chars.count <= 1 ? 0 : (durMs * idx) / chars.count
            let ts = startMs + offsetMs
            tokens.append(String(ch))
            timestampsMs.append(ts)
            lastTimestampMs = ts
          }
          continue
        }
      }
      for ch in chars {
        tokens.append(String(ch))
        timestampsMs.append(lastTimestampMs)
      }
    }

    if !hasAnyTimestamp {
      return (fullText, [], [])
    }
    return (fullText, tokens, timestampsMs)
  }
  #endif

  /// 纯端侧 SFSpeechRecognizer 兜底（强制 `requiresOnDeviceRecognition = true`，绝不上云）。
  private func transcribeViaOnDeviceSFSpeech(
    url: URL,
    localeId: String
  ) async throws -> [String: Any] {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
        ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
      throw NSError(
        domain: "RCSystemSpeech",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "当前语言暂不支持系统语音识别"]
      )
    }
    guard recognizer.isAvailable else {
      throw NSError(
        domain: "RCSystemSpeech",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "系统语音识别服务暂不可用"]
      )
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw NSError(
        domain: "RCSystemSpeech",
        code: -3,
        userInfo: [NSLocalizedDescriptionKey: "当前系统未就绪离线语音包，请下载 SenseVoice 增强模型"]
      )
    }

    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false

    return try await withCheckedThrowingContinuation { continuation in
      let lock = NSLock()
      var resumed = false
      var task: SFSpeechRecognitionTask?

      func finish(_ outcome: Result<[String: Any], Error>) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        guard shouldResume else { return }
        switch outcome {
        case .success(let payload):
          continuation.resume(returning: payload)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }

      task = recognizer.recognitionTask(with: request) { result, error in
        if let error {
          let nsErr = error as NSError
          // 1110 = No speech detected（静音片段正常返回空文本）
          if nsErr.code == 1110 {
            task = nil
            finish(.success([
              "text": "",
              "tokens": [String](),
              "timestampsMs": [Int](),
              "lang": recognizer.locale.identifier,
            ]))
            return
          }
          task = nil
          finish(.failure(error))
          return
        }
        guard let result else { return }
        if result.isFinal {
          let text = result.bestTranscription.formattedString
          let parsed = Self.extractTokensFromSegments(
            text: text,
            segments: result.bestTranscription.segments
          )
          task = nil
          finish(.success([
            "text": text,
            "tokens": parsed.tokens,
            "timestampsMs": parsed.timestampsMs,
            "lang": recognizer.locale.identifier,
          ]))
        }
      }
      _ = task
    }
  }

  private static func extractTokensFromSegments(
    text: String,
    segments: [SFTranscriptionSegment]
  ) -> (tokens: [String], timestampsMs: [Int]) {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || segments.isEmpty {
      return ([], [])
    }

    var charTimestamps = Array(repeating: -1, count: text.count)
    let indices = Array(text.indices)

    for seg in segments {
      guard let swiftRange = Range(seg.substringRange, in: text) else { continue }
      let matchingPositions = indices.enumerated().compactMap { offset, idx -> Int? in
        (idx >= swiftRange.lowerBound && idx < swiftRange.upperBound) ? offset : nil
      }
      guard !matchingPositions.isEmpty else { continue }
      let startMs = max(0, Int((seg.timestamp * 1000.0).rounded()))
      let durMs = max(0, Int((seg.duration * 1000.0).rounded()))
      for (i, pos) in matchingPositions.enumerated() {
        let offsetMs = matchingPositions.count <= 1 ? 0 : (durMs * i) / matchingPositions.count
        charTimestamps[pos] = startMs + offsetMs
      }
    }

    var tokens: [String] = []
    var timestampsMs: [Int] = []
    var lastMs = 0
    for (idx, ch) in text.enumerated() {
      tokens.append(String(ch))
      let ts = charTimestamps[idx] >= 0 ? charTimestamps[idx] : lastMs
      timestampsMs.append(ts)
      lastMs = ts
    }
    return (tokens, timestampsMs)
  }
}
