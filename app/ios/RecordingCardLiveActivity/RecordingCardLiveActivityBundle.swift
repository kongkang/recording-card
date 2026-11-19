import AppIntents
import CoreText
import Foundation
import SwiftUI
import WidgetKit

enum RCLcdFontRegistrar {
  private static let lock = NSLock()
  private static var registered = false

  static func registerIfNeeded() {
    lock.lock()
    defer { lock.unlock() }
    guard !registered else { return }
    registered = true

    let bundles: [Bundle] = [Bundle.main, Bundle(for: BundleAnchor.self)]
    for fontName in ["RCLcdDigital-Regular", "RCLcdBlink-Regular"] {
      for bundle in bundles {
        if let url = bundle.url(forResource: fontName, withExtension: "ttf") {
          CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
          break
        }
      }
    }
  }

  private final class BundleAnchor {}
}

@available(iOSApplicationExtension 18.0, *)
struct RecordingCardAgentControlIntent: AppIntent {
  static var title: LocalizedStringResource = "发送语音任务"
  static var description = IntentDescription("启动录音卡向智能体发送语音任务")
  static var isDiscoverable: Bool = false
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult & OpensIntent {
    .result(opensIntent: OpenURLIntent(URL(string: "reai-mobile://action/agent")!))
  }
}

@available(iOSApplicationExtension 18.0, *)
struct RecordingCardToggleControlIntent: AppIntent {
  static var title: LocalizedStringResource = "切换录音"
  static var description = IntentDescription("开启或关闭录音卡录音")
  static var isDiscoverable: Bool = false
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult & OpensIntent {
    .result(opensIntent: OpenURLIntent(URL(string: "reai-mobile://action/toggle")!))
  }
}

@available(iOSApplicationExtension 18.0, *)
struct RecordingCardAgentControlWidget: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.reai.recordingcard.control.agent") {
      ControlWidgetButton(action: RecordingCardAgentControlIntent()) {
        Label("发送语音任务", systemImage: "waveform.and.mic")
      }
    }
    .displayName("发送语音任务")
    .description("从操作按钮、控制中心或锁屏快速向智能体发送语音任务")
  }
}

@available(iOSApplicationExtension 18.0, *)
struct RecordingCardToggleControlWidget: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.reai.recordingcard.control.record") {
      ControlWidgetButton(action: RecordingCardToggleControlIntent()) {
        Label("切换录音", systemImage: "mic.fill")
      }
    }
    .displayName("切换录音")
    .description("从操作按钮、控制中心或锁屏开启或停止录音")
  }
}

@available(iOSApplicationExtension 16.1, *)
@main
struct RecordingCardLiveActivityBundle: WidgetBundle {
  init() {
    RCLcdFontRegistrar.registerIfNeeded()
  }

  var body: some Widget {
    RecordingCardLiveActivityWidget()
    if #available(iOSApplicationExtension 18.0, *) {
      RecordingCardAgentControlWidget()
      RecordingCardToggleControlWidget()
    }
  }
}
