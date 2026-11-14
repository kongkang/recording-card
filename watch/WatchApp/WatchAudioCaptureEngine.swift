import AVFoundation
import Foundation
import WatchRecorderCore

/// 手表端本地音频采集与 60s Ping-Pong 无缝滚动切片器。
/// - 输出 16kHz / Mono / 32kbps AAC (.m4a)，约 240 KB/分钟；
/// - 每封口一片立即通过 `onSliceSealed` 入账并投递 `WatchConnectivity`，断连时静默留在手表本地；
/// - 标记（Mark）严格以「相对当前录音起点的毫秒」记录，不混入本地墙钟偏移误差。
@MainActor
final class WatchAudioCaptureEngine: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var currentSessionId: String?
    @Published private(set) var recordingStartedAtMs: Int64?
    @Published private(set) var elapsedSec: Int = 0
    @Published private(set) var currentSliceIndex: Int = 0
    @Published private(set) var lastError: String?

    var onSliceSealed: ((WatchSliceDescriptor) -> Void)?
    var onRecordingStateChanged: (() -> Void)?
    var isPhoneReachableProvider: (() -> Bool)?

    private let manifestStore: WatchManifestStore
    private var currentRecorder: AVAudioRecorder?
    private var prewarmedRecorder: AVAudioRecorder?
    private var prewarmedSliceIndex: Int?
    private var prewarmedFileName: String?
    private var prewarmedURL: URL?

    private var currentSliceFileName: String?
    private var currentSliceURL: URL?
    private var currentSliceStartAtMs: Int64 = 0
    private var currentSliceMarksOffsetMs: [Int64] = []
    private var currentSliceGaps: Int = 0
    private var currentSliceRecordedOffline = false

    private var tickTimer: Timer?
    private var sliceElapsedSec: TimeInterval = 0
    private var interruptedWhileRecording = false
    private var interruptionObserver: NSObjectProtocol?

    init(manifestStore: WatchManifestStore) {
        self.manifestStore = manifestStore
        super.init()
        installInterruptionObserver()
    }

    deinit {
        tickTimer?.invalidate()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    static func freeDiskBytes() -> Int64 {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    func requestMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    func startRecording(sessionIdOverride: String? = nil) async -> Bool {
        if isRecording {
            return true
        }
        lastError = nil

        let granted = await requestMicPermission()
        guard granted else {
            lastError = "请在手表「设置 → 隐私与安全性 → 麦克风」中允许录音权限"
            onRecordingStateChanged?()
            return false
        }

        try? manifestStore.pruneSyncedEntries(keepRecentSynced: 30)
        if Self.freeDiskBytes() < WatchConstants.minFreeBytes {
            lastError = "手表可用空间不足 20 MB，请先靠近手机同步已录切片"
            onRecordingStateChanged?()
            return false
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default, options: [])
            try audioSession.setActive(true)
        } catch {
            lastError = "无法激活手表麦克风会话：\(error.localizedDescription)"
            onRecordingStateChanged?()
            return false
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sessionId = sessionIdOverride ?? Self.makeSessionId(nowMs: nowMs)
        currentSessionId = sessionId
        recordingStartedAtMs = nowMs
        elapsedSec = 0
        currentSliceIndex = 0
        currentSliceMarksOffsetMs = []
        currentSliceGaps = 0
        currentSliceRecordedOffline = !(isPhoneReachableProvider?() ?? false)
        interruptedWhileRecording = false

        do {
            try startSliceRecorder(index: 0, startAtMs: nowMs, usePrewarmed: false)
        } catch {
            lastError = "启动录音器失败：\(error.localizedDescription)"
            cleanupRecorders()
            currentSessionId = nil
            recordingStartedAtMs = nil
            onRecordingStateChanged?()
            return false
        }

        isRecording = true
        startTickTimer()
        onRecordingStateChanged?()
        return true
    }

    func stopRecording() {
        guard isRecording || currentRecorder != nil else { return }
        tickTimer?.invalidate()
        tickTimer = nil
        interruptedWhileRecording = false

        sealCurrentRecorder(durationOverrideMs: nil)
        cleanupPrewarmed()
        isRecording = false
        currentSessionId = nil
        recordingStartedAtMs = nil
        elapsedSec = 0
        currentSliceIndex = 0

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        onRecordingStateChanged?()
    }

    /// 打重点：严格记录相对录音会话起点（或切片起点）的毫秒偏移。
    @discardableResult
    func addMark() -> Int64? {
        guard isRecording else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let originMs = recordingStartedAtMs ?? currentSliceStartAtMs
        let offsetMs = max(0, nowMs - originMs)
        currentSliceMarksOffsetMs.append(offsetMs)
        return offsetMs
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        sliceElapsedSec = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.onSecondTick()
            }
        }
        tickTimer = timer
    }

    private func onSecondTick() {
        guard isRecording else { return }
        if let startedAtMs = recordingStartedAtMs {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            elapsedSec = max(0, Int((nowMs - startedAtMs) / 1000))
        } else {
            elapsedSec += 1
        }
        sliceElapsedSec += 1

        if !(isPhoneReachableProvider?() ?? false) {
            currentSliceRecordedOffline = true
        }

        if Self.freeDiskBytes() < WatchConstants.minFreeBytes {
            lastError = "手表存储空间低于 20 MB，已自动封口并停止录音"
            stopRecording()
            return
        }

        let prewarmAt = WatchConstants.sliceDurationSeconds - WatchConstants.prewarmLeadSeconds
        if sliceElapsedSec >= prewarmAt && prewarmedRecorder == nil {
            prepareNextSliceRecorder(nextIndex: currentSliceIndex + 1)
        }

        if sliceElapsedSec >= WatchConstants.sliceDurationSeconds {
            rotateToNextSlice()
        } else {
            onRecordingStateChanged?()
        }
    }

    private func rotateToNextSlice() {
        guard isRecording else { return }
        let nextIndex = currentSliceIndex + 1
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        sealCurrentRecorder(durationOverrideMs: nil)
        sliceElapsedSec = 0
        currentSliceIndex = nextIndex
        currentSliceMarksOffsetMs = []
        currentSliceGaps = 0
        currentSliceRecordedOffline = !(isPhoneReachableProvider?() ?? false)

        do {
            try startSliceRecorder(index: nextIndex, startAtMs: nowMs, usePrewarmed: true)
        } catch {
            lastError = "切片轮转失败：\(error.localizedDescription)"
            stopRecording()
            return
        }
        onRecordingStateChanged?()
    }

    private func prepareNextSliceRecorder(nextIndex: Int) {
        guard let sessionId = currentSessionId else { return }
        let fileName = Self.sliceFileName(sessionId: sessionId, index: nextIndex)
        let url = manifestStore.recordingsDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard let recorder = try? AVAudioRecorder(url: url, settings: Self.aacSettings()) else {
            return
        }
        if recorder.prepareToRecord() {
            prewarmedRecorder = recorder
            prewarmedSliceIndex = nextIndex
            prewarmedFileName = fileName
            prewarmedURL = url
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func startSliceRecorder(index: Int, startAtMs: Int64, usePrewarmed: Bool) throws {
        guard let sessionId = currentSessionId else { return }
        let recorder: AVAudioRecorder
        let fileName: String
        let url: URL

        if usePrewarmed,
           let prewarmed = prewarmedRecorder,
           prewarmedSliceIndex == index,
           let pName = prewarmedFileName,
           let pURL = prewarmedURL {
            recorder = prewarmed
            fileName = pName
            url = pURL
            prewarmedRecorder = nil
            prewarmedSliceIndex = nil
            prewarmedFileName = nil
            prewarmedURL = nil
        } else {
            cleanupPrewarmed()
            fileName = Self.sliceFileName(sessionId: sessionId, index: index)
            url = manifestStore.recordingsDirectory.appendingPathComponent(fileName, isDirectory: false)
            recorder = try AVAudioRecorder(url: url, settings: Self.aacSettings())
            recorder.prepareToRecord()
        }

        guard recorder.record() else {
            throw NSError(
                domain: "RCWatchAudio",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioRecorder.record() 返回 false"]
            )
        }

        currentRecorder = recorder
        currentSliceFileName = fileName
        currentSliceURL = url
        currentSliceStartAtMs = startAtMs
    }

    private func sealCurrentRecorder(durationOverrideMs: Int64?) {
        guard let recorder = currentRecorder else { return }
        recorder.stop()
        currentRecorder = nil

        guard let sessionId = currentSessionId,
              let fileName = currentSliceFileName,
              let url = currentSliceURL else {
            return
        }

        currentSliceFileName = nil
        currentSliceURL = nil

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard byteSize > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let durationMs = durationOverrideMs ?? max(500, nowMs - currentSliceStartAtMs)
        let sliceId = url.deletingPathExtension().lastPathComponent
        let descriptor = WatchSliceDescriptor(
            sliceId: sliceId,
            sessionId: sessionId,
            sliceIndex: currentSliceIndex,
            startAtMs: currentSliceStartAtMs,
            durationMs: durationMs,
            marksOffsetMs: currentSliceMarksOffsetMs,
            gapCount: currentSliceGaps,
            offlineRecorded: currentSliceRecordedOffline || !(isPhoneReachableProvider?() ?? false),
            byteSize: byteSize,
            codec: "aac_m4a_16k_32k",
            fileName: fileName,
            transferState: .pending,
            lastError: nil
        )

        do {
            try manifestStore.registerSlice(descriptor)
            onSliceSealed?(descriptor)
        } catch {
            lastError = "本地账本落盘失败：\(error.localizedDescription)"
        }
    }

    private func cleanupPrewarmed() {
        prewarmedRecorder?.stop()
        if let url = prewarmedURL {
            try? FileManager.default.removeItem(at: url)
        }
        prewarmedRecorder = nil
        prewarmedSliceIndex = nil
        prewarmedFileName = nil
        prewarmedURL = nil
    }

    private func cleanupRecorders() {
        currentRecorder?.stop()
        currentRecorder = nil
        cleanupPrewarmed()
    }

    private func installInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let optionsValue = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue
            Task { @MainActor in
                self?.handleAudioInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
    }

    private func handleAudioInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        switch type {
        case .began:
            guard isRecording else { return }
            interruptedWhileRecording = true
            sealCurrentRecorder(durationOverrideMs: nil)
            cleanupPrewarmed()
            currentSliceGaps += 1
        case .ended:
            guard isRecording && interruptedWhileRecording else { return }
            interruptedWhileRecording = false
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            if options.contains(.shouldResume) || true {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.record, mode: .default, options: [])
                    try session.setActive(true)
                    currentSliceIndex += 1
                    currentSliceMarksOffsetMs = []
                    sliceElapsedSec = 0
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    try startSliceRecorder(index: currentSliceIndex, startAtMs: nowMs, usePrewarmed: false)
                } catch {
                    lastError = "系统中断后恢复录音失败：\(error.localizedDescription)"
                    stopRecording()
                }
            }
        @unknown default:
            break
        }
    }

    private static func aacSettings() -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: WatchConstants.watchSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: WatchConstants.watchBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
    }

    private static func makeSessionId(nowMs: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "watch-\(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0)))"
    }

    private static func sliceFileName(sessionId: String, index: Int) -> String {
        let seq = String(format: "%04d", index + 1)
        return "\(sessionId)_\(seq).m4a"
    }
}
