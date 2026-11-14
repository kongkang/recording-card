import Foundation

/// 手表端本地持久化账本：支撑「离线暂存、重连补推、崩溃恢复、已传清理」。
public final class WatchManifestStore {
    private let lock = NSLock()
    private let fileManager: FileManager
    public let recordingsDirectory: URL
    public let manifestURL: URL
    private var entries: [WatchSliceDescriptor] = []

    public init(
        baseDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.recordingsDirectory = baseDirectory.appendingPathComponent("recordings", isDirectory: true)
        self.manifestURL = baseDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    public func fileURL(for descriptor: WatchSliceDescriptor) -> URL {
        recordingsDirectory.appendingPathComponent(descriptor.fileName, isDirectory: false)
    }

    public func allEntries() -> [WatchSliceDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return Self.sorted(entries)
    }

    public func pendingEntries() -> [WatchSliceDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return Self.sorted(entries.filter { $0.transferState != .synced })
    }

    public func pendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.transferState != .synced }.count
    }

    public func syncedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.transferState == .synced }.count
    }

    public func registerSlice(_ descriptor: WatchSliceDescriptor) throws {
        lock.lock()
        defer { lock.unlock() }
        if let idx = entries.firstIndex(where: { $0.sliceId == descriptor.sliceId }) {
            entries[idx] = descriptor
        } else {
            entries.append(descriptor)
        }
        try saveToDiskLocked()
    }

    public func markTransferring(sliceId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.sliceId == sliceId }) else { return }
        if entries[idx].transferState != .synced {
            entries[idx].transferState = .transferring
            entries[idx].lastError = nil
            try saveToDiskLocked()
        }
    }

    public func markFailed(sliceId: String, error: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.sliceId == sliceId }) else { return }
        if entries[idx].transferState != .synced {
            entries[idx].transferState = .pending
            entries[idx].lastError = error
            try saveToDiskLocked()
        }
    }

    /// 手机确认收到或 `transferFile` 成功后标记已同步，并删除手表本地音频文件以释放空间。
    public func markSyncedAndDeleteLocalAudio(sliceId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.sliceId == sliceId }) else { return }
        entries[idx].transferState = .synced
        entries[idx].lastError = nil
        let targetURL = recordingsDirectory.appendingPathComponent(entries[idx].fileName, isDirectory: false)
        if fileManager.fileExists(atPath: targetURL.path) {
            try? fileManager.removeItem(at: targetURL)
        }
        try saveToDiskLocked()
    }

    /// 进程重启后若有处于 `transferring` 但系统队列已不存在的记录，恢复为 `pending` 待重传。
    public func resetStaleTransferring(activeSliceIds: Set<String>) throws {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for idx in entries.indices {
            if entries[idx].transferState == .transferring,
               !activeSliceIds.contains(entries[idx].sliceId) {
                entries[idx].transferState = .pending
                changed = true
            }
        }
        if changed {
            try saveToDiskLocked()
        }
    }

    /// 扫描 `recordings/` 下异常退出遗留、尚未入账的非空 `.m4a` 文件并自动补入待传队列。
    @discardableResult
    public func recoverOrphanedAudioFiles() throws -> [WatchSliceDescriptor] {
        lock.lock()
        defer { lock.unlock() }

        let urls = (try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let knownFileNames = Set(entries.map(\.fileName))
        var recovered: [WatchSliceDescriptor] = []

        for url in urls where url.pathExtension.lowercased() == "m4a" {
            let name = url.lastPathComponent
            if knownFileNames.contains(name) { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let byteSize = Int64(values?.fileSize ?? 0)
            guard byteSize > 0 else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let createdAt = values?.creationDate ?? Date()
            let startAtMs = Int64(createdAt.timeIntervalSince1970 * 1000)
            let stem = url.deletingPathExtension().lastPathComponent
            let parsed = Self.parseFileStem(stem)
            let descriptor = WatchSliceDescriptor(
                sliceId: stem,
                sessionId: parsed.sessionId,
                sliceIndex: parsed.sliceIndex,
                startAtMs: startAtMs,
                durationMs: 0,
                marksOffsetMs: [],
                gapCount: 1,
                offlineRecorded: true,
                byteSize: byteSize,
                codec: "aac_m4a_16k_32k",
                fileName: name,
                transferState: .pending,
                lastError: nil
            )
            entries.append(descriptor)
            recovered.append(descriptor)
        }

        if !recovered.isEmpty {
            try saveToDiskLocked()
        }
        return recovered
    }

    /// 清理所有已同步条目对应的残余音频文件，并删除过旧的已同步账本记录（保留最近 `keepRecentSynced` 条）。
    public func pruneSyncedEntries(keepRecentSynced: Int = 50) throws {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries where entry.transferState == .synced {
            let url = recordingsDirectory.appendingPathComponent(entry.fileName, isDirectory: false)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        let unsynced = entries.filter { $0.transferState != .synced }
        let synced = entries
            .filter { $0.transferState == .synced }
            .sorted { $0.startAtMs > $1.startAtMs }
        let trimmedSynced = Array(synced.prefix(max(0, keepRecentSynced)))
        let next = unsynced + trimmedSynced
        if next.count != entries.count {
            entries = next
            try saveToDiskLocked()
        }
    }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([WatchSliceDescriptor].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func saveToDiskLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Self.sorted(entries))
        try data.write(to: manifestURL, options: [.atomic])
    }

    private static func sorted(_ list: [WatchSliceDescriptor]) -> [WatchSliceDescriptor] {
        list.sorted {
            if $0.startAtMs != $1.startAtMs {
                return $0.startAtMs < $1.startAtMs
            }
            if $0.sliceIndex != $1.sliceIndex {
                return $0.sliceIndex < $1.sliceIndex
            }
            return $0.sliceId < $1.sliceId
        }
    }

    private static func parseFileStem(_ stem: String) -> (sessionId: String, sliceIndex: Int) {
        let parts = stem.split(separator: "_")
        if parts.count >= 2, let last = parts.last, let idx = Int(last) {
            let session = parts.dropLast().joined(separator: "_")
            return (session.isEmpty ? stem : session, max(0, idx - 1))
        }
        return (stem, 0)
    }
}
