import AVFoundation
import Foundation
import HealthKit
import WatchConnectivity
import WatchRecorderCore

struct ReceivedWatchSlice: Codable, Equatable, Identifiable, Sendable {
    var id: String { sliceId }
    let sliceId: String
    let sessionId: String
    let sliceIndex: Int
    let startAtMs: Int64
    let durationMs: Int64
    let marksOffsetMs: [Int64]
    let gapCount: Int
    let offlineRecorded: Bool
    let rawByteSize: Int64
    let wavByteSize: Int64
    let wavFileName: String
    let receivedAtMs: Int64
    let exportedToSharedInbox: Bool
}

@MainActor
final class PhoneWatchSessionController: NSObject, ObservableObject {
    static let shared = PhoneWatchSessionController()

    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var watchStatus = WatchStatusSnapshot()
    @Published private(set) var receivedSlices: [ReceivedWatchSlice] = []
    @Published private(set) var bannerMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isCommandBusy = false
    @Published private(set) var playingSliceId: String?

    private let healthStore = HKHealthStore()
    private let rootDirectory: URL
    nonisolated private let rawDirectory: URL
    private let wavDirectory: URL
    private let manifestURL: URL
    private var audioPlayer: AVAudioPlayer?
    private var watchTickTimer: Timer?

    override private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.rootDirectory = appSupport.appendingPathComponent("WatchCompanion", isDirectory: true)
        self.rawDirectory = rootDirectory.appendingPathComponent("raw_m4a", isDirectory: true)
        self.wavDirectory = rootDirectory.appendingPathComponent("wav_16k", isDirectory: true)
        self.manifestURL = rootDirectory.appendingPathComponent("received_slices.json", isDirectory: false)
        super.init()

        try? FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: wavDirectory, withIntermediateDirectories: true)
        loadPersistedSlices()
        activateSession()
        startLocalClockInterpolation()
    }

    func wavURL(for slice: ReceivedWatchSlice) -> URL {
        wavDirectory.appendingPathComponent(slice.wavFileName, isDirectory: false)
    }

    /// 从手机直接开启手表录音：
    /// 1. 优先通过 `WCSession.sendMessage` 毫秒级触发（表端已打开时）；
    /// 2. 同步写入 `applicationContext` 并调用 `HKHealthStore().startWatchApp(toHandle:)` 远程冷唤醒手表录音。
    func startWatchRecording() {
        guard WCSession.isSupported() else {
            errorMessage = "当前设备不支持 WatchConnectivity"
            return
        }
        guard !isCommandBusy else { return }
        isCommandBusy = true
        errorMessage = nil
        bannerMessage = "正在唤醒 Apple Watch 开始录音…"

        let sessionId = Self.makeSessionId()
        let cmd = WatchControlCommand(action: .startRecording, sessionId: sessionId)
        let payload = cmd.toDictionary()
        let session = WCSession.default
        try? session.updateApplicationContext(payload)

        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] reply in
                Task { @MainActor in
                    if let next = WatchStatusSnapshot.fromDictionary(reply) {
                        self?.watchStatus = next
                    }
                    self?.bannerMessage = "手表已开始本地录音"
                    self?.isCommandBusy = false
                }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in
                    await self?.wakeWatchAppViaHealthKit()
                }
            })
        } else {
            Task {
                await wakeWatchAppViaHealthKit()
            }
        }
    }

    func stopWatchRecording() {
        sendCommand(WatchControlCommand(action: .stopRecording), successHint: "已下发停止手表录音并回传切片")
    }

    func markOnWatch() {
        sendCommand(WatchControlCommand(action: .addMark), successHint: "已通知手表打重点")
    }

    func requestWatchSync() {
        sendCommand(WatchControlCommand(action: .flushPending), successHint: "已请求手表推送全部待传切片")
    }

    func refreshWatchStatus() {
        sendCommand(WatchControlCommand(action: .requestStatus), successHint: nil)
    }

    func togglePlayback(for slice: ReceivedWatchSlice) {
        if playingSliceId == slice.sliceId {
            audioPlayer?.stop()
            audioPlayer = nil
            playingSliceId = nil
            return
        }

        let url = wavURL(for: slice)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "未找到本地音频文件：\(slice.wavFileName)"
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            audioPlayer = player
            playingSliceId = slice.sliceId
            errorMessage = nil
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
        }
    }

    func deleteSlice(_ slice: ReceivedWatchSlice) {
        if playingSliceId == slice.sliceId {
            audioPlayer?.stop()
            playingSliceId = nil
        }
        try? FileManager.default.removeItem(at: wavURL(for: slice))
        receivedSlices.removeAll { $0.sliceId == slice.sliceId }
        savePersistedSlices()
    }

    private func wakeWatchAppViaHealthKit() async {
        defer { isCommandBusy = false }
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "手表当前未在前台；请先点按表盘上的「录音卡」快捷图标或允许健康唤醒权限"
            return
        }
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        do {
            try await healthStore.startWatchApp(toHandle: config)
            bannerMessage = "已从手机远程唤醒手表并启动录音"
            errorMessage = nil
        } catch {
            errorMessage = "远程唤醒手表失败（请确认表盘已安装本应用）：\(error.localizedDescription)"
        }
    }

    private func sendCommand(_ cmd: WatchControlCommand, successHint: String?) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            errorMessage = "WatchConnectivity 尚未就绪，请稍后再试"
            return
        }
        errorMessage = nil
        let dict = cmd.toDictionary()
        try? session.updateApplicationContext(dict)

        if session.isReachable {
            session.sendMessage(dict, replyHandler: { [weak self] reply in
                Task { @MainActor in
                    if let next = WatchStatusSnapshot.fromDictionary(reply) {
                        self?.watchStatus = next
                    }
                    if let successHint {
                        self?.bannerMessage = successHint
                    }
                }
            }, errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.bannerMessage = "手表当前离线，已缓存指令待重连执行（\(error.localizedDescription)）"
                }
            })
        } else if let successHint {
            bannerMessage = "\(successHint)（手表暂不可达，已投递后台上下文）"
        }
    }

    private func activateSession() {
        guard WCSession.isSupported() else {
            errorMessage = "此 iPhone 不支持 Apple Watch 连接"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func startLocalClockInterpolation() {
        watchTickTimer?.invalidate()
        watchTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.watchStatus.isRecording,
                      let startedAtMs = self.watchStatus.recordingStartedAtMs else {
                    return
                }
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let computed = max(0, Int((nowMs - startedAtMs) / 1000))
                self.watchStatus = WatchStatusSnapshot(
                    isRecording: self.watchStatus.isRecording,
                    activeSessionId: self.watchStatus.activeSessionId,
                    recordingStartedAtMs: self.watchStatus.recordingStartedAtMs,
                    elapsedSec: computed,
                    currentSliceIndex: self.watchStatus.currentSliceIndex,
                    pendingSliceCount: self.watchStatus.pendingSliceCount,
                    syncedSliceCount: self.watchStatus.syncedSliceCount,
                    batteryPercent: self.watchStatus.batteryPercent,
                    isCharging: self.watchStatus.isCharging,
                    freeDiskBytes: self.watchStatus.freeDiskBytes,
                    keepAliveMode: self.watchStatus.keepAliveMode,
                    updatedAtMs: self.watchStatus.updatedAtMs,
                    lastError: self.watchStatus.lastError
                )
            }
        }
    }

    private func ingestTransferredRawFile(copiedRawURL: URL, metadata: [String: Any]) async {
        defer { try? FileManager.default.removeItem(at: copiedRawURL) }

        let descriptor = WatchSliceDescriptor.fromTransferMetadata(metadata) ?? WatchSliceDescriptor(
            sliceId: copiedRawURL.deletingPathExtension().lastPathComponent,
            sessionId: "watch-unknown",
            sliceIndex: 0,
            startAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            durationMs: 0,
            byteSize: 0,
            fileName: copiedRawURL.lastPathComponent
        )

        let wavName = descriptor.canonicalWavFileName
        let wavURL = wavDirectory.appendingPathComponent(wavName, isDirectory: false)
        do {
            let wavBytes = try AudioSliceTranscoder.transcodeTo16kMonoWav(
                sourceM4AURL: copiedRawURL,
                destinationWavURL: wavURL
            )
            let exported = AudioSliceTranscoder.copyToSharedWatchInboxIfAvailable(
                wavURL: wavURL,
                descriptor: descriptor
            )
            let entry = ReceivedWatchSlice(
                sliceId: descriptor.sliceId,
                sessionId: descriptor.sessionId,
                sliceIndex: descriptor.sliceIndex,
                startAtMs: descriptor.startAtMs,
                durationMs: descriptor.durationMs,
                marksOffsetMs: descriptor.marksOffsetMs,
                gapCount: descriptor.gapCount,
                offlineRecorded: descriptor.offlineRecorded,
                rawByteSize: descriptor.byteSize,
                wavByteSize: wavBytes,
                wavFileName: wavName,
                receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                exportedToSharedInbox: exported
            )
            if let idx = receivedSlices.firstIndex(where: { $0.sliceId == entry.sliceId }) {
                receivedSlices[idx] = entry
            } else {
                receivedSlices.insert(entry, at: 0)
                receivedSlices.sort { $0.startAtMs > $1.startAtMs }
            }
            savePersistedSlices()
            bannerMessage = "已本地接收手表第 \(descriptor.sliceIndex + 1) 片并转存 16kHz WAV"
            errorMessage = nil

            let ack = WatchControlCommand(action: .ackSlice, sliceId: descriptor.sliceId)
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(ack.toDictionary(), replyHandler: nil, errorHandler: nil)
            }
        } catch {
            errorMessage = "手表切片转码 WAV 失败：\(error.localizedDescription)"
        }
    }

    private func loadPersistedSlices() {
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([ReceivedWatchSlice].self, from: data) else {
            receivedSlices = []
            return
        }
        receivedSlices = decoded.sorted { $0.startAtMs > $1.startAtMs }
    }

    private func savePersistedSlices() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(receivedSlices) {
            try? data.write(to: manifestURL, options: [.atomic])
        }
    }

    private static func makeSessionId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "watch-\(formatter.string(from: Date()))"
    }
}

extension PhoneWatchSessionController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        let context = session.receivedApplicationContext
        let errorText = error?.localizedDescription
        Task { @MainActor in
            self.isPaired = paired
            self.isWatchAppInstalled = installed
            self.isReachable = reachable
            if let status = WatchStatusSnapshot.fromDictionary(context) {
                self.watchStatus = status
            }
            if let errorText {
                self.errorMessage = "WatchConnectivity 激活异常：\(errorText)"
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPaired = paired
            self.isWatchAppInstalled = installed
            self.isReachable = reachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if let next = WatchStatusSnapshot.fromDictionary(message) {
                self.watchStatus = next
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            if let next = WatchStatusSnapshot.fromDictionary(applicationContext) {
                self.watchStatus = next
            }
        }
    }

    /// 必须在回调返回前同步拷贝 `file.fileURL`，系统在回调退出后随时可能清理临时接收文件。
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let copyURL = rawDirectory.appendingPathComponent("incoming-\(UUID().uuidString).m4a", isDirectory: false)
        let metadata = file.metadata ?? [:]
        do {
            try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: copyURL.path) {
                try FileManager.default.removeItem(at: copyURL)
            }
            try FileManager.default.copyItem(at: file.fileURL, to: copyURL)
            Task { @MainActor in
                await self.ingestTransferredRawFile(copiedRawURL: copyURL, metadata: metadata)
            }
        } catch {
            let errText = error.localizedDescription
            Task { @MainActor in
                self.errorMessage = "拷贝手表传来的音频文件失败：\(errText)"
            }
        }
    }
}

extension PhoneWatchSessionController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playingSliceId = nil
            self.audioPlayer = nil
        }
    }
}
