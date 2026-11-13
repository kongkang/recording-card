import Foundation

#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, *)
struct ToggleLocalRecordingIntent: AppIntent {
  static var title: LocalizedStringResource = "切换本机录音"
  static var description = IntentDescription("开启或关闭录音卡的手机本机录音，并在灵动岛显示运行状态。")
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
        "用\(.applicationName)切换本机录音",
        "用\(.applicationName)开始录音",
      ],
      shortTitle: "切换本机录音",
      systemImageName: "app.badge"
    )
  }
}
#endif
