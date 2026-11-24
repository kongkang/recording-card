#if canImport(XCTest)
#if canImport(AVFoundation)
import AVFoundation
#endif
import XCTest
@testable import WatchRecorderCore

final class WatchRecorderCoreTests: XCTestCase {
    func testBundleConstantsMatchUnifiedRecordingCardApp() {
        XCTAssertEqual(WatchConstants.appGroupId, "group.com.reai.recordingcard")
        XCTAssertEqual(WatchConstants.companionBundleId, "com.reai.recordingcard")
        XCTAssertEqual(WatchConstants.watchAppBundleId, "com.reai.recordingcard.watchkitapp")
        XCTAssertEqual(WatchConstants.widgetsBundleId, "com.reai.recordingcard.watchkitapp.widgets")
    }

    func testProtocolRoundTrips() {
        let cmd = WatchControlCommand(
            commandId: "cmd-test",
            action: .addMark,
            requestedAtMs: 1_794_758_400_123,
            sessionId: "watch-s1"
        )
        XCTAssertEqual(WatchControlCommand.fromDictionary(cmd.toDictionary()), cmd)

        let status = WatchStatusSnapshot(
            isRecording: true,
            activeSessionId: "watch-s1",
            recordingStartedAtMs: 1_794_758_400_000,
            elapsedSec: 42,
            currentSliceIndex: 0,
            pendingSliceCount: 2,
            syncedSliceCount: 5,
            batteryPercent: 91,
            isCharging: true,
            freeDiskBytes: 1024 * 1024 * 200,
            keepAliveMode: .extended,
            updatedAtMs: 1_794_758_442_000,
            lastError: nil,
            appVersion: "1.0.0 (2026111815)"
        )
        XCTAssertEqual(WatchStatusSnapshot.fromDictionary(status.toDictionary()), status)
        XCTAssertEqual(status.toDictionary()["appVersion"] as? String, "1.0.0 (2026111815)")

        let slice = WatchSliceDescriptor(
            sliceId: "slice-1",
            sessionId: "watch-s1",
            sliceIndex: 0,
            startAtMs: 1_794_758_400_000,
            durationMs: 60_000,
            marksOffsetMs: [4500, 31_000],
            gapCount: 1,
            offlineRecorded: true,
            byteSize: 240_000,
            fileName: "watch-s1_0001.m4a",
            transferState: .pending
        )
        XCTAssertEqual(WatchSliceDescriptor.fromTransferMetadata(slice.toTransferMetadata()), slice)
        XCTAssertEqual(slice.canonicalWavFileName, "LIVE_WATCH_s1_0001.WAV")
    }

    func testManifestOfflineQueueAndOrphanRecovery() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-xctest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try WatchManifestStore(baseDirectory: dir)
        let second = WatchSliceDescriptor(
            sliceId: "id-2",
            sessionId: "watch-demo",
            sliceIndex: 1,
            startAtMs: 20_000,
            durationMs: 60_000,
            byteSize: 10,
            fileName: "watch-demo_0002.m4a"
        )
        let first = WatchSliceDescriptor(
            sliceId: "id-1",
            sessionId: "watch-demo",
            sliceIndex: 0,
            startAtMs: 10_000,
            durationMs: 60_000,
            byteSize: 10,
            fileName: "watch-demo_0001.m4a"
        )
        try Data([1, 2]).write(to: store.fileURL(for: first))
        try Data([3, 4]).write(to: store.fileURL(for: second))
        try store.registerSlice(second)
        try store.registerSlice(first)

        XCTAssertEqual(store.pendingEntries().map(\.sliceId), ["id-1", "id-2"])
        try store.markDeliveredPendingAck(sliceId: "id-1", nowMs: 10_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: first).path))
        XCTAssertEqual(store.pendingCount(), 2)
        XCTAssertEqual(store.syncedCount(), 0)
        try store.markSyncedAndDeleteLocalAudio(sliceId: "id-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: first).path))
        XCTAssertEqual(store.pendingCount(), 1)
        XCTAssertEqual(store.syncedCount(), 1)

        let orphan = store.recordingsDirectory.appendingPathComponent("watch-demo_0003.m4a")
        try Data([5, 6, 7]).write(to: orphan)
        let recovered = try store.recoverOrphanedAudioFiles()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(store.pendingCount(), 2)
    }

    func testWatchUIStyleProtocolAndComplicationPersistence() {
        XCTAssertEqual(
            WatchUIStyle.allCases.map(\.rawValue),
            ["default", "braun_field", "chronos", "folio", "nocturne", "air"]
        )
        XCTAssertEqual(WatchUIStyle.fromRawOrDefault(nil), .warmPaper)
        XCTAssertEqual(WatchUIStyle.fromRawOrDefault(" unknown "), .warmPaper)
        XCTAssertEqual(WatchUIStyle.fromRawOrDefault(" nocturne "), .nocturne)

        let styleCmd = WatchControlCommand(
            commandId: "cmd-style-1",
            action: .setStyle,
            requestedAtMs: 1_794_758_500_000,
            styleId: WatchUIStyle.nocturne.rawValue
        )
        XCTAssertEqual(WatchControlCommand.fromDictionary(styleCmd.toDictionary()), styleCmd)

        let suite = "rc.watch.style.xctest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ComplicationStateStore(defaults: defaults, suiteName: suite)
        XCTAssertEqual(store.loadStyle(), .warmPaper)

        store.saveStyle(.braunField)
        XCTAssertEqual(store.loadStyle(), .braunField)

        let compState = ComplicationDisplayState(
            isRecording: true,
            startedAtMs: 1_794_758_400_000,
            pendingCount: 3,
            uiStyleId: WatchUIStyle.folio.rawValue,
            updatedAtMs: 1_794_758_460_000
        )
        store.save(compState)
        let loaded = store.load()
        XCTAssertEqual(loaded, compState)
        XCTAssertEqual(loaded.uiStyle, .folio)
    }

    func testWavHeaderEncoding() {
        let wav = WavFileCodec.wrapPCM16Mono(Data(repeating: 0x01, count: 640))
        let parsed = WavFileCodec.parseHeader(wav)
        XCTAssertEqual(parsed?.audioFormat, 1)
        XCTAssertEqual(parsed?.channels, 1)
        XCTAssertEqual(parsed?.sampleRate, 16_000)
        XCTAssertEqual(parsed?.bitsPerSample, 16)
        XCTAssertEqual(parsed?.dataByteCount, 640)
    }

#if canImport(AVFoundation)
    func testTranscodeTo16kMonoWavRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-transcode-xctest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let srcURL = tmpDir.appendingPathComponent("input_48k_stereo.wav")
        let dstURL = tmpDir.appendingPathComponent("output_16k_mono.wav")

        guard let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ),
              let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 24_000) else {
            XCTFail("Failed to allocate synthetic audio buffer")
            return
        }
        buffer.frameLength = 24_000 // 500ms
        do {
            let writer = try AVAudioFile(
                forWriting: srcURL,
                settings: inFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            try writer.write(from: buffer)
        }

        let durationMs = try WatchAudioSliceTranscoder.transcodeTo16kMonoWav(
            sourceURL: srcURL,
            destinationURL: dstURL
        )
        XCTAssertGreaterThanOrEqual(durationMs, 450)
        let data = try Data(contentsOf: dstURL)
        let hdr = WavFileCodec.parseHeader(data)
        XCTAssertEqual(hdr?.audioFormat, 1)
        XCTAssertEqual(hdr?.channels, 1)
        XCTAssertEqual(hdr?.sampleRate, 16_000)
        XCTAssertEqual(hdr?.bitsPerSample, 16)
        XCTAssertGreaterThan(hdr?.dataByteCount ?? 0, 0)
    }
#endif
}
#endif
