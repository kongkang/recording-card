import Foundation

#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, *)
struct ToggleLocalRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "切换录音"
  static var description = IntentDescription("开启或关闭录音（已连蓝牙硬件时控制硬件录音并开启本机待命保底，未连硬件时控制本机录音），并在灵动岛与锁屏显示实况。")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    LiveActivityBridge.shared.triggerActionButtonToggle()
    return .result()
  }
}

@available(iOS 16.0, *)
struct RecordingCardAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ToggleLocalRecordingIntent(),
      phrases: [
        "用\(.applicationName)切换录音",
        "用\(.applicationName)开始录音",
      ],
      shortTitle: "切换录音",
      systemImageName: "app.badge"
    )
  }
}
#endif
