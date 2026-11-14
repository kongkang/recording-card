import HealthKit
import SwiftUI
import WatchKit

final class RecordingCardWatchDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            await WatchSessionSyncEngine.shared.startRecording(
                workoutConfig: workoutConfiguration,
                sessionIdOverride: nil
            )
        }
    }
}

@main
struct RecordingCardWatchMainApp: App {
    @WKApplicationDelegateAdaptor(RecordingCardWatchDelegate.self) private var delegate
    @StateObject private var syncEngine = WatchSessionSyncEngine.shared

    var body: some Scene {
        WindowGroup {
            WatchMainView(engine: syncEngine)
                .onOpenURL { url in
                    syncEngine.handleDeepLink(url)
                }
        }
    }
}
