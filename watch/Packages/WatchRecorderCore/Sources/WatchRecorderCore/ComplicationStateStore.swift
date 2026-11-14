import Foundation

public struct ComplicationDisplayState: Equatable, Sendable {
    public let isRecording: Bool
    public let startedAtMs: Int64?
    public let pendingCount: Int
    public let updatedAtMs: Int64

    public init(
        isRecording: Bool = false,
        startedAtMs: Int64? = nil,
        pendingCount: Int = 0,
        updatedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.isRecording = isRecording
        self.startedAtMs = startedAtMs
        self.pendingCount = pendingCount
        self.updatedAtMs = updatedAtMs
    }

    public var startedAtDate: Date? {
        guard let startedAtMs, startedAtMs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1000.0)
    }
}

/// 手表 App 与表盘复杂功能（WidgetKit Extension）之间的轻量状态桥。
/// 优先使用 App Group 共享 `UserDefaults`，不可用时降级标准 `UserDefaults`。
public final class ComplicationStateStore {
    private enum Keys {
        static let isRecording = "rc.watch.comp.isRecording"
        static let startedAtMs = "rc.watch.comp.startedAtMs"
        static let pendingCount = "rc.watch.comp.pendingCount"
        static let updatedAtMs = "rc.watch.comp.updatedAtMs"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil, suiteName: String = WatchConstants.appGroupId) {
        if let defaults {
            self.defaults = defaults
        } else if let grouped = UserDefaults(suiteName: suiteName) {
            self.defaults = grouped
        } else {
            self.defaults = .standard
        }
    }

    public func save(_ state: ComplicationDisplayState) {
        defaults.set(state.isRecording, forKey: Keys.isRecording)
        if let startedAtMs = state.startedAtMs {
            defaults.set(NSNumber(value: startedAtMs), forKey: Keys.startedAtMs)
        } else {
            defaults.removeObject(forKey: Keys.startedAtMs)
        }
        defaults.set(state.pendingCount, forKey: Keys.pendingCount)
        defaults.set(NSNumber(value: state.updatedAtMs), forKey: Keys.updatedAtMs)
    }

    public func load() -> ComplicationDisplayState {
        let isRecording = defaults.bool(forKey: Keys.isRecording)
        let startedNum = defaults.object(forKey: Keys.startedAtMs) as? NSNumber
        let pendingCount = defaults.integer(forKey: Keys.pendingCount)
        let updatedNum = defaults.object(forKey: Keys.updatedAtMs) as? NSNumber
        return ComplicationDisplayState(
            isRecording: isRecording,
            startedAtMs: startedNum?.int64Value,
            pendingCount: max(0, pendingCount),
            updatedAtMs: updatedNum?.int64Value ?? 0
        )
    }
}
