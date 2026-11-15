import Flutter
import Foundation
import HealthKit
import WatchConnectivity
import WatchRecorderCore

/// 独立硬件级「Apple Watch」原生桥接：
/// - 在主工程 `Runner` 内激活 `WCSession.default`（同一套软件，`WKCompanionAppBundleIdentifier = com.reai.recordingcard`）；
/// - 向下与 `WatchSessionSyncEngine`（watchOS）双向同步录/停/打点指令与状态快照；
/// - 接收 `.m4a` 切片后立即在本地经 `WatchAudioSliceTranscoder` 转码为 `16kHz / 16-bit / Mono PCM WAV`，
///   写入持久化待入库队列，触发 `onWatchSliceReady` 给 Dart `AppStore.ingestLiveSlice`。
final class WatchHardwareBridge: NSObject, WCSessionDelegate {
    static let shared = WatchHardwareBridge()
    private static let channelName = "com.reai.recordingcard/watch"

    private var channel: FlutterMethodChannel?
    private let stateLock = NSLock()
    private let fileQueue = DispatchQueue(label: "com.reai.recordingcard.watch.files", qos: .userInitiated)
    private let healthStore = HKHealthStore()

    private var latestSnapshot: WatchStatusSnapshot?
    private var pendingSlices: [PendingWatchSlice] = []

    private struct PendingWatchSlice: Codable, Equatable {
        let sliceId: String
        let sessionId: String
        let sliceIndex: Int
        let startAtMs: Int64
        let durationMs: Int64
        let wavPath: String
        let gapCount: Int
        let isFinal: Bool
        let marksOffsetMs: [Int64]

        func toDictionary() -> [String: Any] {
            [
                "sliceId": sliceId,
                "sessionId": sessionId,
                "sliceIndex": sliceIndex,
                "startAtMs": NSNumber(value: startAtMs),
                "durationMs": NSNumber(value: durationMs),
                "wavPath": wavPath,
                "gapCount": gapCount,
                "isFinal": isFinal,
                "marksMs": marksOffsetMs.map { NSNumber(value: $0) },
            ]
        }
    }

    private override init() {
        super.init()
        loadPendingQueue()
    }

    func register(with messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        ch.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = ch
        activateSessionIfSupported()
    }

    func activateSessionIfSupported() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate !== self {
            session.delegate = self
        }
        if session.activationState != .activated {
            session.activate()
        }
        if let cached = WatchStatusSnapshot.fromDictionary(session.receivedApplicationContext) {
            stateLock.lock()
            latestSnapshot = cached
            stateLock.unlock()
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        activateSessionIfSupported()
        switch call.method {
        case "status":
            if WCSession.isSupported() && WCSession.default.isReachable {
                sendCommandToWatch(WatchControlCommand(action: .requestStatus), pushContext: false)
            }
            result(currentStatusDictionary())

        case "startRecording":
            let args = call.arguments as? [String: Any]
            let sessionId = args?["sessionId"] as? String
            startWatchRecording(sessionId: sessionId, result: result)

        case "stopRecording":
            let cmd = WatchControlCommand(action: .stopRecording)
            sendCommandToWatch(cmd, pushContext: true)
            result(currentStatusDictionary())

        case "addMark":
            let cmd = WatchControlCommand(action: .addMark)
            sendCommandToWatch(cmd, pushContext: false)
            result(true)

        case "flushPending":
            let cmd = WatchControlCommand(action: .flushPending)
            sendCommandToWatch(cmd, pushContext: false)
            emitPendingSlicesToDart()
            result(true)

        case "drainPendingSlices":
            result(snapshotPendingDictionaries())

        case "ackConsumedSlice":
            let args = call.arguments as? [String: Any]
            guard let sliceId = args?["sliceId"] as? String, !sliceId.isEmpty else {
                result(false)
                return
            }
            removePendingSlice(sliceId: sliceId)
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startWatchRecording(sessionId: String?, result: @escaping FlutterResult) {
        guard WCSession.isSupported() else {
            result(FlutterError(code: "watch_unsupported", message: "当前设备不支持 Apple Watch 协同", details: nil))
            return
        }
        let session = WCSession.default
        guard session.isPaired, session.isWatchAppInstalled else {
            result(FlutterError(code: "watch_not_ready", message: "未检测到已配对且已安装「录音卡手表」的 Apple Watch", details: nil))
            return
        }

        let cmd = WatchControlCommand(action: .startRecording, sessionId: sessionId)
        sendCommandToWatch(cmd, pushContext: true)

        if session.isReachable {
            result(currentStatusDictionary())
            return
        }

        // 手表处于后台/息屏不可直连态时，尝试通过 HealthKit 运动会话冷唤醒手表 App。
        guard HKHealthStore.isHealthDataAvailable() else {
            result(currentStatusDictionary())
            return
        }
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        healthStore.startWatchApp(with: config) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else {
                    result([:])
                    return
                }
                result(self.currentStatusDictionary())
            }
        }
    }

    private func sendCommandToWatch(_ command: WatchControlCommand, pushContext: Bool) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let payload = command.toDictionary()
        if pushContext {
            try? session.updateApplicationContext(payload)
        }
        if session.isReachable {
            session.sendMessage(
                payload,
                replyHandler: { [weak self] reply in
                    self?.ingestStatusDictionary(reply)
                },
                errorHandler: nil
            )
        }
    }

    private func sendSliceAckToWatch(sliceId: String, sessionId: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let ack = WatchControlCommand(action: .ackSlice, sessionId: sessionId, sliceId: sliceId).toDictionary()
        if session.isReachable {
            session.sendMessage(ack, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(ack)
        }
    }

    private func currentStatusDictionary() -> [String: Any] {
        let supported = WCSession.isSupported()
        let session = supported ? WCSession.default : nil
        stateLock.lock()
        let snap = latestSnapshot
        let localPending = pendingSlices.count
        stateLock.unlock()

        var out: [String: Any] = [
            "supported": supported,
            "paired": session?.isPaired ?? false,
            "watchAppInstalled": session?.isWatchAppInstalled ?? false,
            "reachable": session?.isReachable ?? false,
            "isRecording": snap?.isRecording ?? false,
            "elapsedSec": snap?.elapsedSec ?? 0,
            "currentSliceIndex": snap?.currentSliceIndex ?? 0,
            "pendingSliceCount": (snap?.pendingSliceCount ?? 0) + localPending,
            "syncedSliceCount": snap?.syncedSliceCount ?? 0,
            "batteryPercent": snap?.batteryPercent ?? -1,
            "isCharging": snap?.isCharging ?? false,
            "freeDiskBytes": NSNumber(value: snap?.freeDiskBytes ?? 0),
        ]
        if let activeSessionId = snap?.activeSessionId {
            out["activeSessionId"] = activeSessionId
        }
        if let startedAtMs = snap?.recordingStartedAtMs {
            out["recordingStartedAtMs"] = NSNumber(value: startedAtMs)
        }
        if let lastError = snap?.lastError {
            out["lastError"] = lastError
        }
        return out
    }

    private func ingestStatusDictionary(_ dict: [String: Any]) {
        guard let snap = WatchStatusSnapshot.fromDictionary(dict) else { return }
        stateLock.lock()
        let shouldAccept = (latestSnapshot == nil) || (snap.updatedAtMs >= (latestSnapshot?.updatedAtMs ?? 0))
        if shouldAccept {
            latestSnapshot = snap
        }
        stateLock.unlock()
        if shouldAccept {
            emitStatusChanged()
        }
    }

    private func emitStatusChanged() {
        let payload = currentStatusDictionary()
        DispatchQueue.main.async { [weak self] in
            self?.channel?.invokeMethod("onWatchStatusChanged", arguments: payload)
        }
    }

    private func emitPendingSlicesToDart() {
        let items = snapshotPendingDictionaries()
        guard !items.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for item in items {
                self?.channel?.invokeMethod("onWatchSliceReady", arguments: item)
            }
        }
    }

    // MARK: - 切片落盘与待入库持久化队列

    private static func slicesDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("watch_slices", isDirectory: true)
    }

    private static func queueManifestURL() -> URL {
        slicesDirectoryURL().appendingPathComponent("pending_ingest.json", isDirectory: false)
    }

    private func loadPendingQueue() {
        let url = Self.queueManifestURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PendingWatchSlice].self, from: data) else {
            return
        }
        let existing = decoded.filter { FileManager.default.fileExists(atPath: $0.wavPath) }
        stateLock.lock()
        pendingSlices = existing
        stateLock.unlock()
        if existing.count != decoded.count {
            persistPendingQueueLockedOrUnlocked()
        }
    }

    private func snapshotPendingDictionaries() -> [[String: Any]] {
        stateLock.lock()
        let copy = pendingSlices.sorted { $0.startAtMs < $1.startAtMs }
        stateLock.unlock()
        return copy.map { $0.toDictionary() }
    }

    private func upsertPendingSlice(_ slice: PendingWatchSlice) {
        stateLock.lock()
        if let idx = pendingSlices.firstIndex(where: { $0.sliceId == slice.sliceId }) {
            pendingSlices[idx] = slice
        } else {
            pendingSlices.append(slice)
            pendingSlices.sort { $0.startAtMs < $1.startAtMs }
        }
        let encoded = try? JSONEncoder().encode(pendingSlices)
        stateLock.unlock()

        writePendingData(encoded)
    }

    private func removePendingSlice(sliceId: String) {
        stateLock.lock()
        pendingSlices.removeAll { $0.sliceId == sliceId }
        let encoded = try? JSONEncoder().encode(pendingSlices)
        stateLock.unlock()

        writePendingData(encoded)
        emitStatusChanged()
    }

    private func persistPendingQueueLockedOrUnlocked() {
        stateLock.lock()
        let encoded = try? JSONEncoder().encode(pendingSlices)
        stateLock.unlock()
        writePendingData(encoded)
    }

    private func writePendingData(_ data: Data?) {
        guard let data else { return }
        let dir = Self.slicesDirectoryURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.queueManifestURL(), options: [.atomic])
    }

    // MARK: - WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if let snap = WatchStatusSnapshot.fromDictionary(session.receivedApplicationContext) {
            ingestStatusDictionary(snap.toDictionary())
        } else {
            emitStatusChanged()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        emitStatusChanged()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        emitStatusChanged()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        emitStatusChanged()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            sendCommandToWatch(WatchControlCommand(action: .requestStatus), pushContext: false)
        }
        emitStatusChanged()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        ingestStatusDictionary(message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        ingestStatusDictionary(message)
        replyHandler(currentStatusDictionary())
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingestStatusDictionary(applicationContext)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let fm = FileManager.default
        let rootDir = Self.slicesDirectoryURL()
        let stagingDir = rootDir.appendingPathComponent("staging", isDirectory: true)
        try? fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let meta = file.metadata ?? [:]
        let parsed = WatchSliceDescriptor.fromTransferMetadata(meta)
        let sliceId = parsed?.sliceId ?? UUID().uuidString
        let sessionId = parsed?.sessionId ?? "watch-unknown"
        let sliceIndex = parsed?.sliceIndex ?? 0
        let startAtMs = parsed?.startAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let declaredDurationMs = parsed?.durationMs ?? 0
        let marksOffsetMs = parsed?.marksOffsetMs ?? []
        let gapCount = parsed?.gapCount ?? 0
        let wavName = parsed?.canonicalWavFileName ?? WavFileCodec.liveWatchWavFileName(
            sessionId: sessionId,
            sliceIndex: sliceIndex
        )

        // WCSession 在回调返回后即清理临时 file.fileURL，必须同步拷贝至 staging 目录。
        let stagedName = "\(sliceId)_\(file.fileURL.lastPathComponent)"
        let stagedURL = stagingDir.appendingPathComponent(stagedName, isDirectory: false)
        do {
            if fm.fileExists(atPath: stagedURL.path) {
                try fm.removeItem(at: stagedURL)
            }
            try fm.copyItem(at: file.fileURL, to: stagedURL)
        } catch {
            return
        }

        let wavURL = rootDir.appendingPathComponent(wavName, isDirectory: false)
        fileQueue.async { [weak self] in
            defer { try? fm.removeItem(at: stagedURL) }
            do {
                let transcodedMs = try WatchAudioSliceTranscoder.transcodeTo16kMonoWav(
                    sourceURL: stagedURL,
                    destinationURL: wavURL
                )
                let durationMs = declaredDurationMs > 0 ? declaredDurationMs : transcodedMs
                let entry = PendingWatchSlice(
                    sliceId: sliceId,
                    sessionId: sessionId,
                    sliceIndex: sliceIndex,
                    startAtMs: startAtMs,
                    durationMs: max(1, durationMs),
                    wavPath: wavURL.path,
                    gapCount: gapCount,
                    isFinal: true,
                    marksOffsetMs: marksOffsetMs
                )
                self?.upsertPendingSlice(entry)
                self?.sendSliceAckToWatch(sliceId: sliceId, sessionId: sessionId)
                let payload = entry.toDictionary()
                DispatchQueue.main.async {
                    self?.channel?.invokeMethod("onWatchSliceReady", arguments: payload)
                }
                self?.emitStatusChanged()
            } catch {
                // 转码失败时保留上下文错误信息供界面提示，不写入损坏 WAV。
                self?.emitStatusChanged()
            }
        }
    }
}
