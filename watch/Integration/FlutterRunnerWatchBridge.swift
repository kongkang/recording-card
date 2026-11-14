import AVFoundation
import Flutter
import Foundation
import HealthKit
import WatchConnectivity

/// 预置给主端 `app/ios/Runner` 的桥接模板：
/// 后续将 `watch/` 合入主端统一分发时，只需把 `WatchApp` 嵌入 `Runner`，
/// 并在 `AppDelegate.didInitializeImplicitFlutterEngine` 注册本类即可直接把手表切片喂入 `LiveAudioSlice` 管线。
@available(iOS 16.0, *)
final class FlutterRunnerWatchBridge: NSObject, WCSessionDelegate {
    static let shared = FlutterRunnerWatchBridge()
    static let sharedInboxGroupId = "group.com.reai.recordingcard"

    private var channel: FlutterMethodChannel?
    private let healthStore = HKHealthStore()

    func register(with messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(
            name: "com.reai.recordingcard/watch",
            binaryMessenger: messenger
        )
        ch.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = ch

        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "watchStatus":
            let session = WCSession.isSupported() ? WCSession.default : nil
            result([
                "supported": WCSession.isSupported(),
                "paired": session?.isPaired ?? false,
                "installed": session?.isWatchAppInstalled ?? false,
                "reachable": session?.isReachable ?? false,
            ])
        case "startWatchRecording":
            let payload: [String: Any] = [
                "type": "rc.watch.command",
                "commandId": UUID().uuidString,
                "action": "startRecording",
                "requestedAtMs": NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000)),
            ]
            if WCSession.isSupported() {
                try? WCSession.default.updateApplicationContext(payload)
                if WCSession.default.isReachable {
                    WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
                }
            }
            let config = HKWorkoutConfiguration()
            config.activityType = .mindAndBody
            config.locationType = .indoor
            Task {
                do {
                    try await healthStore.startWatchApp(toHandle: config)
                    await MainActor.run { result(true) }
                } catch {
                    await MainActor.run {
                        result(FlutterError(code: "watch_wake_failed", message: error.localizedDescription, details: nil))
                    }
                }
            }
        case "stopWatchRecording":
            let payload: [String: Any] = [
                "type": "rc.watch.command",
                "commandId": UUID().uuidString,
                "action": "stopRecording",
                "requestedAtMs": NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000)),
            ]
            if WCSession.isSupported() {
                try? WCSession.default.updateApplicationContext(payload)
                if WCSession.default.isReachable {
                    WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
                }
            }
            result(true)
        case "listSharedInboxFiles":
            result(listSharedInboxWavPaths())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func listSharedInboxWavPaths() -> [String] {
        guard let groupRoot = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.sharedInboxGroupId
        ) else {
            return []
        }
        let inbox = groupRoot.appendingPathComponent("watch_inbox", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.uppercased() == "WAV" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(\.path)
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("watch_bridge_inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(file.fileURL.lastPathComponent, isDirectory: false)
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: file.fileURL, to: dst)

        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("onWatchFileReceived", arguments: [
                "path": dst.path,
                "metadata": file.metadata ?? [:],
            ])
        }
    }
}
