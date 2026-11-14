import Combine
import Foundation
import HealthKit
import WatchConnectivity
import WatchKit
import WatchRecorderCore
import WidgetKit

/// 手表端总控枢纽：串联本地采集、垂腕保活、`WCSession` 指令/文件队列、以及表盘复杂功能同步。
@MainActor
final class WatchSessionSyncEngine: NSObject, ObservableObject {
    static let shared = WatchSessionSyncEngine()

    @Published private(set) var snapshot = WatchStatusSnapshot()
    @Published private(set) var slices: [WatchSliceDescriptor] = []
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var isCompanionInstalled = true
    @Published private(set) var lastSyncNote: String?

    let keepAlive = WatchRuntimeKeepAlive()
    let captureEngine: WatchAudioCaptureEngine
    private let manifestStore: WatchManifestStore
    private let complicationStore = ComplicationStateStore()
    private var lastHandledCommandId: String?
    private var cancellables: Set<AnyCancellable> = []

    override private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let rootDir = appSupport.appendingPathComponent("WatchRecorder", isDirectory: true)
        do {
            self.manifestStore = try WatchManifestStore(baseDirectory: rootDir)
        } catch {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("WatchRecorderFallback", isDirectory: true)
            self.manifestStore = try! WatchManifestStore(baseDirectory: fallback)
        }
        self.captureEngine = WatchAudioCaptureEngine(manifestStore: self.manifestStore)
        super.init()

        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        self.captureEngine.isPhoneReachableProvider = { [weak self] in
            self?.isPhoneReachable ?? false
        }
        self.captureEngine.onSliceSealed = { [weak self] descriptor in
            self?.handleSealedSlice(descriptor)
        }
        self.captureEngine.onRecordingStateChanged = { [weak self] in
            self?.refreshSnapshotAndBroadcast(pushContext: true)
        }
        self.keepAlive.$mode
            .sink { [weak self] _ in
                self?.refreshSnapshotAndBroadcast(pushContext: false)
            }
            .store(in: &cancellables)

        recoverLocalStorageOnLaunch()
        activateWatchSession()
        refreshSnapshotAndBroadcast(pushContext: false)
    }

    func toggleRecording() {
        if captureEngine.isRecording {
            stopRecording()
        } else {
            Task {
                await startRecording(workoutConfig: nil, sessionIdOverride: nil)
            }
        }
    }

    func startRecording(workoutConfig: HKWorkoutConfiguration? = nil, sessionIdOverride: String? = nil) async {
        keepAlive.start(configuration: workoutConfig)
        let started = await captureEngine.startRecording(sessionIdOverride: sessionIdOverride)
        if !started {
            keepAlive.stop()
        } else {
            lastSyncNote = isPhoneReachable ? "录音中 · 切片将实时本地推回手机" : "离线录音中 · 切片先存手表"
        }
        refreshSnapshotAndBroadcast(pushContext: true)
    }

    func stopRecording() {
        captureEngine.stopRecording()
        keepAlive.stop()
        flushPendingTransfers()
        refreshSnapshotAndBroadcast(pushContext: true)
    }

    func addMark() {
        if let offset = captureEngine.addMark() {
            WKInterfaceDevice.current().play(.click)
            let secs = offset / 1000
            lastSyncNote = "已打重点 @ \(secs)s"
            refreshSnapshotAndBroadcast(pushContext: false)
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "rcwatch" else { return }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "action" })?
            .value
            ?? "toggle"
        switch action {
        case "start":
            Task { await startRecording(workoutConfig: nil, sessionIdOverride: nil) }
        case "stop":
            stopRecording()
        default:
            toggleRecording()
        }
    }

    func flushPendingTransfers() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let activeSliceIds = Set(
            session.outstandingFileTransfers.compactMap { transfer in
                transfer.file.metadata?["sliceId"] as? String
            }
        )
        try? manifestStore.resetStaleTransferring(activeSliceIds: activeSliceIds)

        let pending = manifestStore.pendingEntries()
        var queued = 0
        for item in pending where item.transferState == .pending {
            let fileURL = manifestStore.fileURL(for: item)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                try? manifestStore.markSyncedAndDeleteLocalAudio(sliceId: item.sliceId)
                continue
            }
            _ = session.transferFile(fileURL, metadata: item.toTransferMetadata())
            try? manifestStore.markTransferring(sliceId: item.sliceId)
            queued += 1
        }
        if queued > 0 {
            lastSyncNote = "已入队向手机本地传送 \(queued) 段切片"
        }
        reloadSlicesAndSnapshot()
    }

    private func recoverLocalStorageOnLaunch() {
        let activeSliceIds: Set<String>
        if WCSession.isSupported() && WCSession.default.activationState == .activated {
            activeSliceIds = Set(
                WCSession.default.outstandingFileTransfers.compactMap {
                    $0.file.metadata?["sliceId"] as? String
                }
            )
        } else {
            activeSliceIds = []
        }
        try? manifestStore.resetStaleTransferring(activeSliceIds: activeSliceIds)
        let recovered = (try? manifestStore.recoverOrphanedAudioFiles()) ?? []
        if !recovered.isEmpty {
            lastSyncNote = "启动恢复了 \(recovered.count) 段未传录音"
        }
        slices = manifestStore.allEntries()
    }

    private func activateWatchSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func handleSealedSlice(_ descriptor: WatchSliceDescriptor) {
        slices = manifestStore.allEntries()
        flushPendingTransfers()
        refreshSnapshotAndBroadcast(pushContext: true)
    }

    private func reloadSlicesAndSnapshot() {
        slices = manifestStore.allEntries()
        refreshSnapshotAndBroadcast(pushContext: false)
    }

    private func refreshSnapshotAndBroadcast(pushContext: Bool) {
        let device = WKInterfaceDevice.current()
        let rawBattery = device.batteryLevel
        let batteryPercent = rawBattery >= 0 ? Int((rawBattery * 100).rounded()) : -1
        let isCharging = device.batteryState == .charging || device.batteryState == .full

        let pendingCount = manifestStore.pendingCount()
        let syncedCount = manifestStore.syncedCount()
        let nextSnapshot = WatchStatusSnapshot(
            isRecording: captureEngine.isRecording,
            activeSessionId: captureEngine.currentSessionId,
            recordingStartedAtMs: captureEngine.recordingStartedAtMs,
            elapsedSec: captureEngine.elapsedSec,
            currentSliceIndex: captureEngine.currentSliceIndex,
            pendingSliceCount: pendingCount,
            syncedSliceCount: syncedCount,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            freeDiskBytes: WatchAudioCaptureEngine.freeDiskBytes(),
            keepAliveMode: captureEngine.isRecording ? keepAlive.mode : .idle,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            lastError: captureEngine.lastError ?? keepAlive.lastWarning
        )
        snapshot = nextSnapshot
        slices = manifestStore.allEntries()

        complicationStore.save(
            ComplicationDisplayState(
                isRecording: nextSnapshot.isRecording,
                startedAtMs: nextSnapshot.recordingStartedAtMs,
                pendingCount: nextSnapshot.pendingSliceCount,
                updatedAtMs: nextSnapshot.updatedAtMs
            )
        )
        WidgetCenter.shared.reloadAllTimelines()

        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let payload = nextSnapshot.toDictionary()
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        if pushContext {
            try? WCSession.default.updateApplicationContext(payload)
        }
    }

    private func handleIncomingDictionary(_ dict: [String: Any]) {
        guard let cmd = WatchControlCommand.fromDictionary(dict) else { return }
        if cmd.commandId == lastHandledCommandId { return }
        lastHandledCommandId = cmd.commandId

        switch cmd.action {
        case .startRecording:
            Task {
                await startRecording(workoutConfig: nil, sessionIdOverride: cmd.sessionId)
            }
        case .stopRecording:
            stopRecording()
        case .addMark:
            addMark()
        case .requestStatus:
            refreshSnapshotAndBroadcast(pushContext: true)
        case .flushPending:
            flushPendingTransfers()
        case .ackSlice:
            if let sliceId = cmd.sliceId {
                try? manifestStore.markSyncedAndDeleteLocalAudio(sliceId: sliceId)
                reloadSlicesAndSnapshot()
            }
        }
    }
}

extension WatchSessionSyncEngine: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let reachable = session.isReachable
        let installed = session.isCompanionAppInstalled
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.isPhoneReachable = reachable
            self.isCompanionInstalled = installed
            self.handleIncomingDictionary(context)
            if activationState == .activated {
                self.flushPendingTransfers()
                self.refreshSnapshotAndBroadcast(pushContext: true)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
            if reachable {
                self.flushPendingTransfers()
            }
            self.refreshSnapshotAndBroadcast(pushContext: false)
        }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        let installed = session.isCompanionAppInstalled
        Task { @MainActor in
            self.isCompanionInstalled = installed
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.handleIncomingDictionary(message)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            self.handleIncomingDictionary(message)
            replyHandler(self.snapshot.toDictionary())
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.handleIncomingDictionary(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        let sliceId = fileTransfer.file.metadata?["sliceId"] as? String
        let errorText = error?.localizedDescription
        Task { @MainActor in
            guard let sliceId else { return }
            if let errorText {
                try? self.manifestStore.markFailed(sliceId: sliceId, error: errorText)
                self.lastSyncNote = "传送失败，稍后自动重试：\(errorText)"
            } else {
                try? self.manifestStore.markSyncedAndDeleteLocalAudio(sliceId: sliceId)
                self.lastSyncNote = "已本地送达手机并清理缓存"
            }
            self.reloadSlicesAndSnapshot()
        }
    }
}
