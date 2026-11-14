#if canImport(XCTest)
import XCTest
@testable import WatchRecorderCore

final class WatchRecorderCoreTests: XCTestCase {
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
            lastError: nil
        )
        XCTAssertEqual(WatchStatusSnapshot.fromDictionary(status.toDictionary()), status)

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

    func testWavHeaderEncoding() {
        let wav = WavFileCodec.wrapPCM16Mono(Data(repeating: 0x01, count: 640))
        let parsed = WavFileCodec.parseHeader(wav)
        XCTAssertEqual(parsed?.audioFormat, 1)
        XCTAssertEqual(parsed?.channels, 1)
        XCTAssertEqual(parsed?.sampleRate, 16_000)
        XCTAssertEqual(parsed?.bitsPerSample, 16)
        XCTAssertEqual(parsed?.dataByteCount, 640)
    }
}
#endif
