import BackgroundAssets
import Flutter
import Foundation
import System

/// Apple-Hosted Background Assets 桥接：
/// - iOS 26+ 且配置了 `BAHasManagedAssetPacks` / `BAUsesAppleHosting` 时可用；
/// - 负责触发系统资源包下载、上报进度，并将文件原子复制到应用支持目录供 sherpa-onnx 使用。
final class AppleAssetPackBridge: NSObject, FlutterStreamHandler {
  private static let methodChannelName = "com.reai.recordingcard/apple_assets"
  private static let progressChannelName = "com.reai.recordingcard/apple_assets_progress"

  private var methodChannel: FlutterMethodChannel?
  private var progressChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?

  static func register(with registry: FlutterPluginRegistry) -> AppleAssetPackBridge? {
    guard let registrar = registry.registrar(forPlugin: "RCAppleAssetPackBridge") else {
      return nil
    }
    let bridge = AppleAssetPackBridge()
    let method = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    method.setMethodCallHandler { [weak bridge] call, result in
      bridge?.handle(call, result: result)
    }
    bridge.methodChannel = method

    let events = FlutterEventChannel(
      name: progressChannelName,
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(bridge)
    bridge.progressChannel = events
    return bridge
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(isAppleHostingAvailable())
    case "availablePackIds":
      fetchAvailablePackIds(result: result)
    case "installAssetPack":
      guard let args = call.arguments as? [String: Any],
            let packId = args["packId"] as? String,
            let files = args["files"] as? [[String: String]] else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少 packId 或 files 参数", details: nil))
        return
      }
      installAssetPack(packId: packId, files: files, result: result)
    case "removeAssetPack":
      guard let args = call.arguments as? [String: Any],
            let packId = args["packId"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少 packId 参数", details: nil))
        return
      }
      removeAssetPack(packId: packId, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func isAppleHostingAvailable() -> Bool {
    guard #available(iOS 26.0, *) else {
      return false
    }
    let info = Bundle.main.infoDictionary
    let hasManaged = (info?["BAHasManagedAssetPacks"] as? Bool) == true
    let usesAppleHosting = (info?["BAUsesAppleHosting"] as? Bool) == true
    return hasManaged && usesAppleHosting
  }

  private func fetchAvailablePackIds(result: @escaping FlutterResult) {
    guard #available(iOS 26.0, *), isAppleHostingAvailable() else {
      result([String]())
      return
    }
    Task {
      do {
        let ids: [String]
        if #available(iOS 27.0, *) {
          let manifest = try await AssetPackManager.shared.manifest
          ids = manifest.assetPacks.map(\.id)
        } else {
          let packs = try await AssetPackManager.shared.allAssetPacks
          ids = packs.map(\.id)
        }
        DispatchQueue.main.async {
          result(ids)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "MANIFEST_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  private func installAssetPack(
    packId: String,
    files: [[String: String]],
    result: @escaping FlutterResult
  ) {
    guard #available(iOS 26.0, *) else {
      result(FlutterError(
        code: "UNSUPPORTED_OS",
        message: "Apple-Hosted Background Assets 需要 iOS 26 及以上系统",
        details: nil
      ))
      return
    }
    guard isAppleHostingAvailable() else {
      result(FlutterError(
        code: "NOT_CONFIGURED",
        message: "宿主未启用 BAHasManagedAssetPacks / BAUsesAppleHosting",
        details: nil
      ))
      return
    }

    Task { [weak self] in
      await self?.performInstall(packId: packId, files: files, result: result)
    }
  }

  @available(iOS 26.0, *)
  private func performInstall(
    packId: String,
    files: [[String: String]],
    result: @escaping FlutterResult
  ) async {
    emitProgress(packId: packId, stage: "began", progress: 0.01)

    let progressTask = Task { [weak self] in
      for await update in AssetPackManager.shared.statusUpdates(forAssetPackWithID: packId) {
        switch update {
        case .began:
          self?.emitProgress(packId: packId, stage: "began", progress: 0.01)
        case .paused:
          self?.emitProgress(packId: packId, stage: "paused", progress: 0.0)
        case .downloading(_, let progress):
          self?.emitProgress(
            packId: packId,
            stage: "downloading",
            progress: progress.fractionCompleted
          )
        case .finished:
          self?.emitProgress(packId: packId, stage: "finished", progress: 1.0)
        case .failed(_, let error):
          self?.emitProgress(
            packId: packId,
            stage: "failed",
            progress: 0.0,
            error: error.localizedDescription
          )
        }
      }
    }

    defer {
      progressTask.cancel()
    }

    do {
      let pack: AssetPack
      if #available(iOS 27.0, *) {
        let manifest = try await AssetPackManager.shared.manifest
        guard let found = manifest.assetPack(withID: packId) else {
          throw ManagedBackgroundAssetsError.assetPackNotFound(withID: packId)
        }
        pack = found
      } else {
        pack = try await AssetPackManager.shared.assetPack(withID: packId)
      }

      if #available(iOS 26.4, *) {
        try await AssetPackManager.shared.ensureLocalAvailability(
          of: pack,
          requireLatestVersion: true
        )
      } else {
        try await AssetPackManager.shared.ensureLocalAvailability(of: pack)
      }

      emitProgress(packId: packId, stage: "copying", progress: 0.98)
      try materializeFiles(files)

      // 已复制到应用支持目录，清理托管缓存避免双倍占用存储空间
      try? await AssetPackManager.shared.remove(assetPackWithID: packId)

      DispatchQueue.main.async {
        result(true)
      }
    } catch let error as ManagedBackgroundAssetsError {
      let code: String
      switch error {
      case .assetPackNotFound:
        code = "ASSET_PACK_NOT_FOUND"
      default:
        code = "APPLE_ASSET_FAILED"
      }
      DispatchQueue.main.async {
        result(FlutterError(
          code: code,
          message: error.localizedDescription,
          details: nil
        ))
      }
    } catch {
      DispatchQueue.main.async {
        result(FlutterError(
          code: "APPLE_ASSET_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }

  @available(iOS 26.0, *)
  private func materializeFiles(_ files: [[String: String]]) throws {
    let fm = FileManager.default
    for entry in files {
      guard let assetPath = entry["assetPath"],
            let destPath = entry["destPath"],
            !assetPath.isEmpty,
            !destPath.isEmpty else {
        continue
      }
      let srcURL = try AssetPackManager.shared.url(for: FilePath(assetPath))
      let destURL = URL(fileURLWithPath: destPath)
      let parentURL = destURL.deletingLastPathComponent()
      if !fm.fileExists(atPath: parentURL.path) {
        try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)
      }
      let partURL = URL(fileURLWithPath: destPath + ".part")
      if fm.fileExists(atPath: partURL.path) {
        try fm.removeItem(at: partURL)
      }
      try fm.copyItem(at: srcURL, to: partURL)
      if fm.fileExists(atPath: destURL.path) {
        try fm.removeItem(at: destURL)
      }
      try fm.moveItem(at: partURL, to: destURL)
    }
  }

  private func removeAssetPack(packId: String, result: @escaping FlutterResult) {
    guard #available(iOS 26.0, *) else {
      result(nil)
      return
    }
    Task {
      try? await AssetPackManager.shared.remove(assetPackWithID: packId)
      DispatchQueue.main.async {
        result(nil)
      }
    }
  }

  private func emitProgress(
    packId: String,
    stage: String,
    progress: Double,
    error: String? = nil
  ) {
    DispatchQueue.main.async { [weak self] in
      var payload: [String: Any] = [
        "packId": packId,
        "stage": stage,
        "progress": progress,
      ]
      if let error {
        payload["error"] = error
      }
      self?.eventSink?(payload)
    }
  }
}
