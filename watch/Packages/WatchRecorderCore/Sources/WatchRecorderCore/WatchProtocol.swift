import Foundation

public enum WatchConstants {
    public static let appGroupId = "group.com.reai.recordingcard"
    public static let companionBundleId = "com.reai.recordingcard"
    public static let watchAppBundleId = "com.reai.recordingcard.watchkitapp"
    public static let widgetsBundleId = "com.reai.recordingcard.watchkitapp.widgets"
    public static let toggleUrlScheme = "rcwatch://record?action=toggle"
    public static let startUrlScheme = "rcwatch://record?action=start"
    public static let stopUrlScheme = "rcwatch://record?action=stop"
    public static let sliceDurationSeconds: TimeInterval = 60
    public static let prewarmLeadSeconds: TimeInterval = 5
    public static let minFreeBytes: Int64 = 20 * 1024 * 1024
    public static let watchSampleRate: Double = 16_000
    public static let watchBitRate: Int = 32_000
    public static let uiStyleKey = "uiStyleId"
}

/// 手机与 Apple Watch 共用的 6 套界面风格真源。
///
/// 线协议 ID 与 Flutter `RCUIStyleId` 严格一一对应：
/// - `default`     ：静纸声录（Warm Paper）
/// - `braun_field` ：声波仪（Braun Field）
/// - `chronos`     ：昼夜声轴（Chronos）
/// - `folio`       ：卷宗（Folio）
/// - `nocturne`    ：暗房（Nocturne）
/// - `air`         ：灵动卡片（Air）
public enum WatchUIStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case warmPaper = "default"
    case braunField = "braun_field"
    case chronos = "chronos"
    case folio = "folio"
    case nocturne = "nocturne"
    case air = "air"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .warmPaper: return "静纸声录"
        case .braunField: return "声波仪"
        case .chronos: return "昼夜声轴"
        case .folio: return "卷宗"
        case .nocturne: return "暗房"
        case .air: return "灵动卡片"
        }
    }

    public var englishName: String {
        switch self {
        case .warmPaper: return "Warm Paper"
        case .braunField: return "Braun Field"
        case .chronos: return "Chronos"
        case .folio: return "Folio"
        case .nocturne: return "Nocturne"
        case .air: return "Air"
        }
    }

    public static func fromRawOrDefault(_ raw: String?) -> WatchUIStyle {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return WatchUIStyle(rawValue: trimmed) ?? .warmPaper
    }
}

public enum WatchCommandAction: String, Codable, Sendable, CaseIterable {
    case startRecording
    case stopRecording
    case addMark
    case requestStatus
    case flushPending
    case ackSlice
    case setStyle
}

/// 手机 ⇄ 手表双向控制指令（可经 `sendMessage` 实时发送，也可经 `applicationContext` 传递）。
public struct WatchControlCommand: Codable, Equatable, Sendable {
    public static let messageType = "rc.watch.command"

    public let commandId: String
    public let action: WatchCommandAction
    public let requestedAtMs: Int64
    public let sessionId: String?
    public let sliceId: String?
    public let styleId: String?

    public init(
        commandId: String = UUID().uuidString,
        action: WatchCommandAction,
        requestedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        sessionId: String? = nil,
        sliceId: String? = nil,
        styleId: String? = nil
    ) {
        self.commandId = commandId
        self.action = action
        self.requestedAtMs = requestedAtMs
        self.sessionId = sessionId
        self.sliceId = sliceId
        self.styleId = styleId
    }

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": Self.messageType,
            "commandId": commandId,
            "action": action.rawValue,
            "requestedAtMs": NSNumber(value: requestedAtMs),
        ]
        if let sessionId, !sessionId.isEmpty {
            dict["sessionId"] = sessionId
        }
        if let sliceId, !sliceId.isEmpty {
            dict["sliceId"] = sliceId
        }
        if let styleId, !styleId.isEmpty {
            dict["styleId"] = styleId
        }
        return dict
    }

    public static func fromDictionary(_ dict: [String: Any]) -> WatchControlCommand? {
        guard (dict["type"] as? String) == Self.messageType,
              let commandId = dict["commandId"] as? String,
              !commandId.isEmpty,
              let rawAction = dict["action"] as? String,
              let action = WatchCommandAction(rawValue: rawAction) else {
            return nil
        }
        let requestedAtMs = (dict["requestedAtMs"] as? NSNumber)?.int64Value ?? 0
        let sessionId = dict["sessionId"] as? String
        let sliceId = dict["sliceId"] as? String
        let styleId = dict["styleId"] as? String
        return WatchControlCommand(
            commandId: commandId,
            action: action,
            requestedAtMs: requestedAtMs,
            sessionId: sessionId,
            sliceId: sliceId,
            styleId: styleId
        )
    }
}

public enum WatchKeepAliveMode: String, Codable, Sendable {
    case idle
    case workout
    case extended
    case audioBackground = "audio-bg"
}

/// 手表当前实时状态快照：由手表推送到手机界面，同时供表盘扩展共享状态参考。
public struct WatchStatusSnapshot: Codable, Equatable, Sendable {
    public static let messageType = "rc.watch.status"

    public let isRecording: Bool
    public let activeSessionId: String?
    public let recordingStartedAtMs: Int64?
    public let elapsedSec: Int
    public let currentSliceIndex: Int
    public let pendingSliceCount: Int
    public let syncedSliceCount: Int
    public let batteryPercent: Int
    public let isCharging: Bool
    public let freeDiskBytes: Int64
    public let keepAliveMode: WatchKeepAliveMode
    public let updatedAtMs: Int64
    public let lastError: String?
    /// 手表 App 构建版本，形如 `1.0.0 (2026111815)`，供手机端联动状态展示。
    public let appVersion: String

    public init(
        isRecording: Bool = false,
        activeSessionId: String? = nil,
        recordingStartedAtMs: Int64? = nil,
        elapsedSec: Int = 0,
        currentSliceIndex: Int = 0,
        pendingSliceCount: Int = 0,
        syncedSliceCount: Int = 0,
        batteryPercent: Int = -1,
        isCharging: Bool = false,
        freeDiskBytes: Int64 = 0,
        keepAliveMode: WatchKeepAliveMode = .idle,
        updatedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        lastError: String? = nil,
        appVersion: String = ""
    ) {
        self.isRecording = isRecording
        self.activeSessionId = activeSessionId
        self.recordingStartedAtMs = recordingStartedAtMs
        self.elapsedSec = elapsedSec
        self.currentSliceIndex = currentSliceIndex
        self.pendingSliceCount = pendingSliceCount
        self.syncedSliceCount = syncedSliceCount
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.freeDiskBytes = freeDiskBytes
        self.keepAliveMode = keepAliveMode
        self.updatedAtMs = updatedAtMs
        self.lastError = lastError
        self.appVersion = appVersion
    }

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": Self.messageType,
            "isRecording": isRecording,
            "elapsedSec": elapsedSec,
            "currentSliceIndex": currentSliceIndex,
            "pendingSliceCount": pendingSliceCount,
            "syncedSliceCount": syncedSliceCount,
            "batteryPercent": batteryPercent,
            "isCharging": isCharging,
            "freeDiskBytes": NSNumber(value: freeDiskBytes),
            "keepAliveMode": keepAliveMode.rawValue,
            "updatedAtMs": NSNumber(value: updatedAtMs),
        ]
        if let activeSessionId, !activeSessionId.isEmpty {
            dict["activeSessionId"] = activeSessionId
        }
        if let recordingStartedAtMs {
            dict["recordingStartedAtMs"] = NSNumber(value: recordingStartedAtMs)
        }
        if let lastError, !lastError.isEmpty {
            dict["lastError"] = lastError
        }
        if !appVersion.isEmpty {
            dict["appVersion"] = appVersion
        }
        return dict
    }

    public static func fromDictionary(_ dict: [String: Any]) -> WatchStatusSnapshot? {
        guard (dict["type"] as? String) == Self.messageType else {
            return nil
        }
        let isRecording = (dict["isRecording"] as? Bool) ?? false
        let activeSessionId = dict["activeSessionId"] as? String
        let recordingStartedAtMs = (dict["recordingStartedAtMs"] as? NSNumber)?.int64Value
        let elapsedSec = (dict["elapsedSec"] as? NSNumber)?.intValue ?? 0
        let currentSliceIndex = (dict["currentSliceIndex"] as? NSNumber)?.intValue ?? 0
        let pendingSliceCount = (dict["pendingSliceCount"] as? NSNumber)?.intValue ?? 0
        let syncedSliceCount = (dict["syncedSliceCount"] as? NSNumber)?.intValue ?? 0
        let batteryPercent = (dict["batteryPercent"] as? NSNumber)?.intValue ?? -1
        let isCharging = (dict["isCharging"] as? Bool) ?? false
        let freeDiskBytes = (dict["freeDiskBytes"] as? NSNumber)?.int64Value ?? 0
        let modeRaw = dict["keepAliveMode"] as? String ?? WatchKeepAliveMode.idle.rawValue
        let keepAliveMode = WatchKeepAliveMode(rawValue: modeRaw) ?? .idle
        let updatedAtMs = (dict["updatedAtMs"] as? NSNumber)?.int64Value ?? 0
        let lastError = dict["lastError"] as? String
        let appVersion = (dict["appVersion"] as? String) ?? ""
        return WatchStatusSnapshot(
            isRecording: isRecording,
            activeSessionId: activeSessionId,
            recordingStartedAtMs: recordingStartedAtMs,
            elapsedSec: elapsedSec,
            currentSliceIndex: currentSliceIndex,
            pendingSliceCount: pendingSliceCount,
            syncedSliceCount: syncedSliceCount,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            freeDiskBytes: freeDiskBytes,
            keepAliveMode: keepAliveMode,
            updatedAtMs: updatedAtMs,
            lastError: lastError,
            appVersion: appVersion
        )
    }
}

public enum WatchSliceTransferState: String, Codable, Sendable {
    case pending
    case transferring
    case awaitingAck = "awaiting_ack"
    case synced
}

/// 单个手表音频切片的完整描述；`marksOffsetMs` 严格存「相对录音起点的毫秒」。
public struct WatchSliceDescriptor: Codable, Equatable, Sendable, Identifiable {
    public static let metadataType = "rc.watch.slice"

    public var id: String { sliceId }
    public let sliceId: String
    public let sessionId: String
    public let sliceIndex: Int
    public let startAtMs: Int64
    public let durationMs: Int64
    public let marksOffsetMs: [Int64]
    public let gapCount: Int
    public let offlineRecorded: Bool
    public let isFinal: Bool
    public let byteSize: Int64
    public let codec: String
    public let fileName: String
    public var transferState: WatchSliceTransferState
    public var deliveredAtMs: Int64?
    public var lastError: String?

    private enum CodingKeys: String, CodingKey {
        case sliceId
        case sessionId
        case sliceIndex
        case startAtMs
        case durationMs
        case marksOffsetMs
        case gapCount
        case offlineRecorded
        case isFinal
        case byteSize
        case codec
        case fileName
        case transferState
        case deliveredAtMs
        case lastError
    }

    public init(
        sliceId: String,
        sessionId: String,
        sliceIndex: Int,
        startAtMs: Int64,
        durationMs: Int64,
        marksOffsetMs: [Int64] = [],
        gapCount: Int = 0,
        offlineRecorded: Bool = false,
        isFinal: Bool = false,
        byteSize: Int64,
        codec: String = "aac_m4a_16k_32k",
        fileName: String,
        transferState: WatchSliceTransferState = .pending,
        deliveredAtMs: Int64? = nil,
        lastError: String? = nil
    ) {
        self.sliceId = sliceId
        self.sessionId = sessionId
        self.sliceIndex = sliceIndex
        self.startAtMs = startAtMs
        self.durationMs = durationMs
        self.marksOffsetMs = marksOffsetMs
        self.gapCount = gapCount
        self.offlineRecorded = offlineRecorded
        self.isFinal = isFinal
        self.byteSize = byteSize
        self.codec = codec
        self.fileName = fileName
        self.transferState = transferState
        self.deliveredAtMs = deliveredAtMs
        self.lastError = lastError
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sliceId = try c.decode(String.self, forKey: .sliceId)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.sliceIndex = try c.decode(Int.self, forKey: .sliceIndex)
        self.startAtMs = try c.decode(Int64.self, forKey: .startAtMs)
        self.durationMs = try c.decode(Int64.self, forKey: .durationMs)
        self.marksOffsetMs = try c.decodeIfPresent([Int64].self, forKey: .marksOffsetMs) ?? []
        self.gapCount = try c.decodeIfPresent(Int.self, forKey: .gapCount) ?? 0
        self.offlineRecorded = try c.decodeIfPresent(Bool.self, forKey: .offlineRecorded) ?? false
        self.isFinal = try c.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
        self.byteSize = try c.decode(Int64.self, forKey: .byteSize)
        self.codec = try c.decodeIfPresent(String.self, forKey: .codec) ?? "aac_m4a_16k_32k"
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.transferState = try c.decodeIfPresent(WatchSliceTransferState.self, forKey: .transferState) ?? .pending
        self.deliveredAtMs = try c.decodeIfPresent(Int64.self, forKey: .deliveredAtMs)
        self.lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    public var canonicalWavFileName: String {
        WavFileCodec.liveWatchWavFileName(sessionId: sessionId, sliceIndex: sliceIndex)
    }

    public func toTransferMetadata() -> [String: Any] {
        var dict: [String: Any] = [
            "type": Self.metadataType,
            "sliceId": sliceId,
            "sessionId": sessionId,
            "sliceIndex": sliceIndex,
            "startAtMs": NSNumber(value: startAtMs),
            "durationMs": NSNumber(value: durationMs),
            "marksOffsetMs": marksOffsetMs.map { NSNumber(value: $0) },
            "gapCount": gapCount,
            "offlineRecorded": offlineRecorded,
            "isFinal": isFinal,
            "byteSize": NSNumber(value: byteSize),
            "codec": codec,
            "fileName": fileName,
            "transferState": transferState.rawValue,
        ]
        if let deliveredAtMs {
            dict["deliveredAtMs"] = NSNumber(value: deliveredAtMs)
        }
        if let lastError, !lastError.isEmpty {
            dict["lastError"] = lastError
        }
        return dict
    }

    public static func fromTransferMetadata(_ dict: [String: Any]) -> WatchSliceDescriptor? {
        guard (dict["type"] as? String) == Self.metadataType,
              let sliceId = dict["sliceId"] as? String,
              let sessionId = dict["sessionId"] as? String,
              let fileName = dict["fileName"] as? String else {
            return nil
        }
        let sliceIndex = (dict["sliceIndex"] as? NSNumber)?.intValue ?? 0
        let startAtMs = (dict["startAtMs"] as? NSNumber)?.int64Value ?? 0
        let durationMs = (dict["durationMs"] as? NSNumber)?.int64Value ?? 0
        let rawMarks = (dict["marksOffsetMs"] as? [NSNumber]) ?? []
        let marksOffsetMs = rawMarks.map { $0.int64Value }
        let gapCount = (dict["gapCount"] as? NSNumber)?.intValue ?? 0
        let offlineRecorded = (dict["offlineRecorded"] as? Bool) ?? false
        let isFinal = (dict["isFinal"] as? Bool) ?? false
        let byteSize = (dict["byteSize"] as? NSNumber)?.int64Value ?? 0
        let codec = (dict["codec"] as? String) ?? "aac_m4a_16k_32k"
        let stateRaw = (dict["transferState"] as? String) ?? WatchSliceTransferState.pending.rawValue
        let transferState = WatchSliceTransferState(rawValue: stateRaw) ?? .pending
        let deliveredAtMs = (dict["deliveredAtMs"] as? NSNumber)?.int64Value
        let lastError = dict["lastError"] as? String
        return WatchSliceDescriptor(
            sliceId: sliceId,
            sessionId: sessionId,
            sliceIndex: sliceIndex,
            startAtMs: startAtMs,
            durationMs: durationMs,
            marksOffsetMs: marksOffsetMs,
            gapCount: gapCount,
            offlineRecorded: offlineRecorded,
            isFinal: isFinal,
            byteSize: byteSize,
            codec: codec,
            fileName: fileName,
            transferState: transferState,
            deliveredAtMs: deliveredAtMs,
            lastError: lastError
        )
    }
}
