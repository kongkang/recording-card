import Foundation
import Flutter

/// iCloud 云盘同步桥（`com.reai.recordingcard/icloud_sync`）。
///
/// 使用公开的 iCloud Documents 容器（`iCloud.com.reai.recordingcard`），
/// 在用户手动开启 iCloud 同步后，将音频、转录文本（Markdown）、硬件照片与视频
/// 通过 `NSFileCoordinator` 写入 `<UbiquityContainer>/Documents/{Audio,Transcripts,Photos,Videos}/`，
/// 让用户在系统「文件 → iCloud 云盘 → 录音卡」中可直接查看且卸载不丢失。
final class ICloudSyncBridge {
  static let shared = ICloudSyncBridge()

  private let channelName = "com.reai.recordingcard/icloud_sync"
  private let containerIdentifier = "iCloud.com.reai.recordingcard"
  private let ioQueue = DispatchQueue(
    label: "com.reai.recordingcard.icloud.io",
    qos: .utility
  )
  private var channel: FlutterMethodChannel?

  private init() {}

  func register(with messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = ch
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      ioQueue.async { [self] in
        let payload = self.buildStatusPayload()
        DispatchQueue.main.async { result(payload) }
      }
    case "syncFile":
      guard let args = call.arguments as? [String: Any],
            let sourcePath = args["sourcePath"] as? String,
            let relativePath = args["relativePath"] as? String else {
        result(["ok": false, "available": false, "error": "缺少文件路径参数"])
        return
      }
      ioQueue.async { [self] in
        let payload = self.syncFileToICloud(
          sourcePath: sourcePath,
          relativePath: relativePath
        )
        DispatchQueue.main.async { result(payload) }
      }
    case "syncText":
      guard let args = call.arguments as? [String: Any],
            let content = args["content"] as? String,
            let relativePath = args["relativePath"] as? String else {
        result(["ok": false, "available": false, "error": "缺少文本参数"])
        return
      }
      ioQueue.async { [self] in
        let payload = self.syncTextToICloud(
          content: content,
          relativePath: relativePath
        )
        DispatchQueue.main.async { result(payload) }
      }
    case "listStats":
      ioQueue.async { [self] in
        let payload = self.collectStats()
        DispatchQueue.main.async { result(payload) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func resolveDocumentsURL() -> (available: Bool, signedIn: Bool, docsURL: URL?, containerPath: String, error: String?) {
    let fm = FileManager.default
    let signedIn = fm.ubiquityIdentityToken != nil
    guard let containerURL = fm.url(forUbiquityContainerIdentifier: containerIdentifier) else {
      let msg = signedIn
        ? "iCloud 云盘容器未就绪，请在系统设置开启「iCloud 云盘 → 录音卡」"
        : "未登录 Apple 账户或未开启 iCloud 云盘"
      return (false, signedIn, nil, "", msg)
    }
    let docsURL = containerURL.appendingPathComponent("Documents", isDirectory: true)
    if !fm.fileExists(atPath: docsURL.path) {
      try? fm.createDirectory(at: docsURL, withIntermediateDirectories: true)
    }
    return (true, signedIn, docsURL, containerURL.path, nil)
  }

  private func sanitizeRelativePath(_ raw: String) -> String? {
    let parts = raw
      .split(separator: "/")
      .map(String.init)
      .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
    if parts.isEmpty { return nil }
    return parts.joined(separator: "/")
  }

  private func buildStatusPayload() -> [String: Any] {
    let resolved = resolveDocumentsURL()
    var out: [String: Any] = [
      "available": resolved.available,
      "signedIn": resolved.signedIn,
      "containerPath": resolved.containerPath,
    ]
    if let err = resolved.error {
      out["error"] = err
    }
    return out
  }

  private func syncFileToICloud(sourcePath: String, relativePath: String) -> [String: Any] {
    guard let cleanRel = sanitizeRelativePath(relativePath) else {
      return ["ok": false, "available": true, "error": "非法 iCloud 目标路径"]
    }
    let fm = FileManager.default
    let sourceURL = URL(fileURLWithPath: sourcePath)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir), !isDir.boolValue else {
      return ["ok": false, "available": true, "error": "本地源文件不存在"]
    }

    let resolved = resolveDocumentsURL()
    guard let docsURL = resolved.docsURL else {
      return [
        "ok": false,
        "available": false,
        "signedIn": resolved.signedIn,
        "error": resolved.error ?? "iCloud 不可用",
      ]
    }

    let destURL = docsURL.appendingPathComponent(cleanRel, isDirectory: false)
    let srcAttrs = try? fm.attributesOfItem(atPath: sourceURL.path)
    let srcSize = (srcAttrs?[.size] as? NSNumber)?.int64Value ?? -1
    let srcMod = srcAttrs?[.modificationDate] as? Date

    if fm.fileExists(atPath: destURL.path),
       let dstAttrs = try? fm.attributesOfItem(atPath: destURL.path) {
      let dstSize = (dstAttrs[.size] as? NSNumber)?.int64Value ?? -2
      let dstMod = dstAttrs[.modificationDate] as? Date
      if srcSize >= 0 && dstSize == srcSize {
        if let sMod = srcMod, let dMod = dstMod, dMod.timeIntervalSince(sMod) >= -1.0 {
          return ["ok": true, "available": true, "skipped": true, "path": destURL.path]
        }
      }
    }

    let parentURL = destURL.deletingLastPathComponent()
    do {
      try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
    } catch {
      return ["ok": false, "available": true, "error": "创建 iCloud 目录失败：\(error.localizedDescription)"]
    }

    var coordErr: NSError?
    var writeErr: Error?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(writingItemAt: destURL, options: .forReplacing, error: &coordErr) { targetURL in
      do {
        if fm.fileExists(atPath: targetURL.path) {
          try fm.removeItem(at: targetURL)
        }
        try fm.copyItem(at: sourceURL, to: targetURL)
      } catch {
        writeErr = error
      }
    }

    if let err = coordErr ?? writeErr {
      return ["ok": false, "available": true, "error": "写入 iCloud 失败：\(err.localizedDescription)"]
    }
    return ["ok": true, "available": true, "skipped": false, "path": destURL.path]
  }

  private func syncTextToICloud(content: String, relativePath: String) -> [String: Any] {
    guard let cleanRel = sanitizeRelativePath(relativePath) else {
      return ["ok": false, "available": true, "error": "非法 iCloud 目标路径"]
    }
    guard let data = content.data(using: .utf8) else {
      return ["ok": false, "available": true, "error": "文本编码失败"]
    }

    let fm = FileManager.default
    let resolved = resolveDocumentsURL()
    guard let docsURL = resolved.docsURL else {
      return [
        "ok": false,
        "available": false,
        "signedIn": resolved.signedIn,
        "error": resolved.error ?? "iCloud 不可用",
      ]
    }

    let destURL = docsURL.appendingPathComponent(cleanRel, isDirectory: false)
    if fm.fileExists(atPath: destURL.path),
       let existing = try? Data(contentsOf: destURL),
       existing == data {
      return ["ok": true, "available": true, "skipped": true, "path": destURL.path]
    }

    let parentURL = destURL.deletingLastPathComponent()
    do {
      try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
    } catch {
      return ["ok": false, "available": true, "error": "创建 iCloud 目录失败：\(error.localizedDescription)"]
    }

    var coordErr: NSError?
    var writeErr: Error?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(writingItemAt: destURL, options: .forReplacing, error: &coordErr) { targetURL in
      do {
        try data.write(to: targetURL, options: .atomic)
      } catch {
        writeErr = error
      }
    }

    if let err = coordErr ?? writeErr {
      return ["ok": false, "available": true, "error": "写入 iCloud 文本失败：\(err.localizedDescription)"]
    }
    return ["ok": true, "available": true, "skipped": false, "path": destURL.path]
  }

  private func collectStats() -> [String: Any] {
    let resolved = resolveDocumentsURL()
    guard let docsURL = resolved.docsURL else {
      return [
        "available": false,
        "signedIn": resolved.signedIn,
        "audio": 0,
        "transcripts": 0,
        "photos": 0,
        "videos": 0,
        "total": 0,
      ]
    }

    func countFiles(in subdir: String) -> Int {
      let dir = docsURL.appendingPathComponent(subdir, isDirectory: true)
      let fm = FileManager.default
      guard fm.fileExists(atPath: dir.path),
            let enumerator = fm.enumerator(
              at: dir,
              includingPropertiesForKeys: [.isRegularFileKey],
              options: [.skipsHiddenFiles]
            ) else {
        return 0
      }
      var count = 0
      for case let fileURL as URL in enumerator {
        let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
        if vals?.isRegularFile == true {
          count += 1
        }
      }
      return count
    }

    let audio = countFiles(in: "Audio")
    let transcripts = countFiles(in: "Transcripts")
    let photos = countFiles(in: "Photos")
    let videos = countFiles(in: "Videos")
    return [
      "available": true,
      "signedIn": resolved.signedIn,
      "audio": audio,
      "transcripts": transcripts,
      "photos": photos,
      "videos": videos,
      "total": audio + transcripts + photos + videos,
    ]
  }
}
