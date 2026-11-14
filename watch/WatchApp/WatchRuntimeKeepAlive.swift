import Foundation
import HealthKit
import WatchKit
import WatchRecorderCore

/// 垂腕息屏不断录保活器：
/// 1. 优先启动室内 `HKWorkoutSession`（`.mindAndBody`），获取手表最高级连续后台运行契约；
/// 2. 若健康权限不可用或建立失败，自动降级到 `WKExtendedRuntimeSession`；
/// 3. 两者均受限时仍以 `UIBackgroundModes: audio` 会话托底并如实汇报当前保活模式。
@MainActor
final class WatchRuntimeKeepAlive: NSObject, ObservableObject {
    @Published private(set) var mode: WatchKeepAliveMode = .idle
    @Published private(set) var lastWarning: String?

    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private var extendedSession: WKExtendedRuntimeSession?
    private var active = false

    func start(configuration: HKWorkoutConfiguration? = nil) {
        if active && mode != .idle {
            return
        }
        active = true
        lastWarning = nil

        if HKHealthStore.isHealthDataAvailable() {
            let config = configuration ?? {
                let c = HKWorkoutConfiguration()
                c.activityType = .mindAndBody
                c.locationType = .indoor
                return c
            }()
            do {
                let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
                session.delegate = self
                workoutSession = session
                session.prepare()
                session.startActivity(with: Date())
                mode = .workout
                return
            } catch {
                lastWarning = "运动保活会话启动降级：\(error.localizedDescription)"
            }
        }

        startExtendedFallback()
    }

    func stop() {
        active = false
        workoutSession?.end()
        workoutSession = nil
        extendedSession?.invalidate()
        extendedSession = nil
        mode = .idle
    }

    private func startExtendedFallback() {
        extendedSession?.invalidate()
        let ext = WKExtendedRuntimeSession()
        ext.delegate = self
        extendedSession = ext
        ext.start()
        mode = .extended
    }
}

extension WatchRuntimeKeepAlive: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            if toState == .running && self.active {
                self.mode = .workout
            } else if toState == .ended && self.active {
                self.startExtendedFallback()
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: any Error
    ) {
        Task { @MainActor in
            guard self.active else { return }
            self.lastWarning = "运动保活降级：\(error.localizedDescription)"
            self.workoutSession = nil
            self.startExtendedFallback()
        }
    }
}

extension WatchRuntimeKeepAlive: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            if self.active && self.workoutSession == nil {
                self.mode = .extended
            }
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard self.active else { return }
            self.lastWarning = "扩展保活临近上限，已切至音频后台会话"
            self.mode = .audioBackground
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        Task { @MainActor in
            guard self.active else { return }
            if self.workoutSession == nil {
                self.mode = .audioBackground
                if let error {
                    self.lastWarning = "保活已回落音频后台：\(error.localizedDescription)"
                }
            }
        }
    }
}
