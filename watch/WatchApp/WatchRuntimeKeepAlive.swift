import Foundation
import WatchKit
#if canImport(WatchRecorderCore)
import WatchRecorderCore
#endif

/// 垂腕息屏录音后台运行状态跟踪器：
/// 遵循 App Store Review Guideline 2.5.4 / 5.1.3，仅使用合法的 `UIBackgroundModes: [audio]`
/// 搭配活跃 `AVAudioSession`（`.record`）保持腕上录音会话运行，绝不伪造 HealthKit 运动或冥想会话。
@MainActor
final class WatchRuntimeKeepAlive: NSObject, ObservableObject {
    @Published private(set) var mode: WatchKeepAliveMode = .idle
    @Published private(set) var lastWarning: String?

    private var active = false

    func start() {
        active = true
        lastWarning = nil
        mode = .audioBackground
    }

    func stop() {
        active = false
        lastWarning = nil
        mode = .idle
    }
}
