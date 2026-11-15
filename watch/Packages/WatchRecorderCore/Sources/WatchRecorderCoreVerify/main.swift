#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation
import WatchRecorderCore

private func verify(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAILED: \(message)\n", stderr)
        exit(1)
    }
}

private func runAllChecks() throws {
    // 0. 统一套件 Bundle ID 校验（严禁退回独立手机端）
    verify(WatchConstants.appGroupId == "group.com.reai.recordingcard", "Unexpected appGroupId")
    verify(WatchConstants.companionBundleId == "com.reai.recordingcard", "companionBundleId must match com.reai.recordingcard")
    verify(WatchConstants.watchAppBundleId == "com.reai.recordingcard.watchkitapp", "watchAppBundleId mismatch")
    verify(WatchConstants.widgetsBundleId == "com.reai.recordingcard.watchkitapp.widgets", "widgetsBundleId mismatch")

    // 1. 协议编解码往返校验
    let cmd = WatchControlCommand(
        commandId: "cmd-001",
        action: .startRecording,
        requestedAtMs: 1_794_758_400_000,
        sessionId: "watch-20261115"
    )
    let cmdRoundTrip = WatchControlCommand.fromDictionary(cmd.toDictionary())
    verify(cmdRoundTrip == cmd, "WatchControlCommand dictionary round-trip mismatch")

    let status = WatchStatusSnapshot(
        isRecording: true,
        activeSessionId: "watch-20261115",
        recordingStartedAtMs: 1_794_758_400_000,
        elapsedSec: 125,
        currentSliceIndex: 2,
        pendingSliceCount: 3,
        syncedSliceCount: 7,
        batteryPercent: 86,
        isCharging: false,
        freeDiskBytes: 512_000_000,
        keepAliveMode: .workout,
        updatedAtMs: 1_794_758_525_000,
        lastError: nil
    )
    let statusRoundTrip = WatchStatusSnapshot.fromDictionary(status.toDictionary())
    verify(statusRoundTrip == status, "WatchStatusSnapshot dictionary round-trip mismatch")

    let slice = WatchSliceDescriptor(
        sliceId: "s-01",
        sessionId: "watch-20261115",
        sliceIndex: 1,
        startAtMs: 1_794_758_460_000,
        durationMs: 60_000,
        marksOffsetMs: [12_500, 48_900],
        gapCount: 0,
        offlineRecorded: true,
        byteSize: 245_760,
        fileName: "watch-20261115_0002.m4a",
        transferState: .pending
    )
    let sliceRoundTrip = WatchSliceDescriptor.fromTransferMetadata(slice.toTransferMetadata())
    verify(sliceRoundTrip == slice, "WatchSliceDescriptor metadata round-trip mismatch")
    verify(
        slice.canonicalWavFileName == "LIVE_WATCH_20261115_0002.WAV",
        "Unexpected canonical WAV file name: \(slice.canonicalWavFileName)"
    )

    // 2. 离线暂存、重连按序补推、失败回退与已同步清理
    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("watch-core-verify-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    let store = try WatchManifestStore(baseDirectory: tmpRoot)
    let s2 = WatchSliceDescriptor(
        sliceId: "s2",
        sessionId: "watch-abc",
        sliceIndex: 1,
        startAtMs: 2_000,
        durationMs: 60_000,
        offlineRecorded: true,
        byteSize: 128,
        fileName: "watch-abc_0002.m4a"
    )
    let s1 = WatchSliceDescriptor(
        sliceId: "s1",
        sessionId: "watch-abc",
        sliceIndex: 0,
        startAtMs: 1_000,
        durationMs: 60_000,
        offlineRecorded: true,
        byteSize: 128,
        fileName: "watch-abc_0001.m4a"
    )
    try Data([0x01, 0x02, 0x03]).write(to: store.fileURL(for: s1))
    try Data([0x04, 0x05, 0x06]).write(to: store.fileURL(for: s2))
    try store.registerSlice(s2)
    try store.registerSlice(s1)

    let pendingOrdered = store.pendingEntries()
    verify(pendingOrdered.map(\.sliceId) == ["s1", "s2"], "Pending queue must sort by startAtMs ascending")

    try store.markTransferring(sliceId: "s1")
    try store.markFailed(sliceId: "s1", error: "phone unreachable")
    verify(store.pendingCount() == 2, "Failed transfer must remain pending")
    verify(store.pendingEntries().first?.lastError == "phone unreachable", "Failure error must be persisted")

    try store.markSyncedAndDeleteLocalAudio(sliceId: "s1")
    verify(!FileManager.default.fileExists(atPath: store.fileURL(for: s1).path), "Synced audio must be deleted from watch storage")
    verify(store.pendingCount() == 1 && store.syncedCount() == 1, "Counts must reflect 1 pending and 1 synced")

    // 3. 异常重启孤儿音频恢复 & stale transferring 重置
    let orphanURL = store.recordingsDirectory.appendingPathComponent("watch-crash_0003.m4a")
    try Data([0xAA, 0xBB, 0xCC, 0xDD]).write(to: orphanURL)
    try store.markTransferring(sliceId: "s2")

    let reloaded = try WatchManifestStore(baseDirectory: tmpRoot)
    try reloaded.resetStaleTransferring(activeSliceIds: [])
    let recovered = try reloaded.recoverOrphanedAudioFiles()
    verify(recovered.count == 1 && recovered[0].fileName == "watch-crash_0003.m4a", "Orphaned audio file must be recovered")
    verify(reloaded.pendingCount() == 2, "Recovered + reset stale entries must both be pending")

    // 4. 44 字节 WAV 头校验
    let pcm = Data(repeating: 0x12, count: 3200)
    let wav = WavFileCodec.wrapPCM16Mono(pcm)
    verify(wav.count == 44 + 3200, "WAV length must be 44 + PCM length")
    let header = WavFileCodec.parseHeader(wav)
    verify(
        header == WavFileCodec.WavHeaderInfo(
            audioFormat: 1,
            channels: 1,
            sampleRate: 16_000,
            bitsPerSample: 16,
            dataByteCount: 3200
        ),
        "WAV header fields must match 16kHz 16-bit mono PCM"
    )

    // 5. 表盘扩展状态存储回读校验
    let suite = "group.com.reai.recordingcard.verify.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let compStore = ComplicationStateStore(defaults: defaults)
    let compState = ComplicationDisplayState(
        isRecording: true,
        startedAtMs: 1_794_758_400_000,
        pendingCount: 4,
        updatedAtMs: 1_794_758_500_000
    )
    compStore.save(compState)
    verify(compStore.load() == compState, "ComplicationStateStore round-trip mismatch")

    // 6. 音频重采样转码为 16kHz Mono PCM WAV 往返校验
#if canImport(AVFoundation)
    let transRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("watch-transcode-verify-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: transRoot) }
    try FileManager.default.createDirectory(at: transRoot, withIntermediateDirectories: true)

    let synthSrc = transRoot.appendingPathComponent("source_48k_stereo.wav")
    let synthDst = transRoot.appendingPathComponent("LIVE_WATCH_verify_0001.WAV")
    if let inFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    ),
       let pcmBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 24_000) {
        pcmBuf.frameLength = 24_000 // 0.5s
        do {
            let outFile = try AVAudioFile(
                forWriting: synthSrc,
                settings: inFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            try outFile.write(from: pcmBuf)
        }
        let durMs = try WatchAudioSliceTranscoder.transcodeTo16kMonoWav(
            sourceURL: synthSrc,
            destinationURL: synthDst
        )
        verify(durMs >= 450 && durMs <= 550, "Expected ~500ms transcoded duration, got \(durMs)ms")
        let outData = try Data(contentsOf: synthDst)
        let outHdr = WavFileCodec.parseHeader(outData)
        verify(
            outHdr != nil && outHdr!.audioFormat == 1 && outHdr!.channels == 1 && outHdr!.sampleRate == 16_000 && outHdr!.bitsPerSample == 16 && outHdr!.dataByteCount > 0,
            "Transcoded WAV header must be 16kHz 16-bit mono PCM with non-zero frames"
        )
    } else {
        verify(false, "Failed to allocate AVAudioPCMBuffer for transcoder check")
    }
    print("WatchRecorderCoreVerify: ALL 6 SUITES PASSED")
#else
    print("WatchRecorderCoreVerify: ALL 5 SUITES PASSED")
#endif
}

do {
    try runAllChecks()
} catch {
    fputs("FAILED with error: \(error)\n", stderr)
    exit(1)
}
