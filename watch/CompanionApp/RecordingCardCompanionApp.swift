import SwiftUI

@main
struct RecordingCardCompanionApp: App {
    @StateObject private var controller = PhoneWatchSessionController.shared

    var body: some Scene {
        WindowGroup {
            PhoneCompanionMainView(controller: controller)
        }
    }
}
