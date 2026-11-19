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
    NotificationCenter.default.post(
      name: Notification.Name("com.reai.recordingcard.actionButtonToggle"),
      object: nil
    )
    return .result()
  }
}

@available(iOS 16.0, *)
struct SendVoiceTaskToAgentIntent: AppIntent {
  static var title: LocalizedStringResource = "发送语音任务"
  static var description = IntentDescription("开始或结束一段发给录音卡智能体的语音指令；若当前已在录音则直接按时间戳截取音频，未录音则开启临时录音，处理完成后通过耳机或手机语音播报结果。")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    NotificationCenter.default.post(
      name: Notification.Name("com.reai.recordingcard.actionButtonAgent"),
      object: nil
    )
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
        "用\(.applicationName)停止录音",
      ],
      shortTitle: "切换录音",
      systemImageName: "mic.fill"
    )
    AppShortcut(
      intent: SendVoiceTaskToAgentIntent(),
      phrases: [
        "用\(.applicationName)发送语音任务",
        "用\(.applicationName)向智能体提问",
        "用\(.applicationName)语音提问",
      ],
      shortTitle: "发送语音任务",
      systemImageName: "waveform.and.mic"
    )
  }
}
#endif
