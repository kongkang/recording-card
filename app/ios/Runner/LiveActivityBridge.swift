import Flutter
import Foundation
import UIKit

#if canImport(ActivityKit)
import ActivityKit
#endif

final class LiveActivityBridge {
  static let shared = LiveActivityBridge()

  private var channel: FlutterMethodChannel?
  private var pendingActionToggle = false

  private init() {}

  func register(with messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(
      name: "com.reai.recordingcard/live_activity",
      binaryMessenger: messenger
    )
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    channel = ch
    if pendingActionToggle {
      pendingActionToggle = false
      DispatchQueue.main.async {
        ch.invokeMethod("actionButtonToggle", arguments: nil)
      }
    }
  }

  func triggerActionButtonToggle() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let ch = self.channel {
        ch.invokeMethod("actionButtonToggle", arguments: nil)
      } else {
        self.pendingActionToggle = true
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(capabilitiesPayload())
    case "start":
      let args = call.arguments as? [String: Any]
      let startedAtMs = (args?["startedAtMs"] as? NSNumber)?.int64Value
        ?? Int64(Date().timeIntervalSince1970 * 1000)
      let title = (args?["title"] as? String) ?? "录音卡"
      let subtitle = (args?["subtitle"] as? String) ?? "本机录音运行中"
      startActivity(startedAtMs: startedAtMs, title: title, subtitle: subtitle, result: result)
    case "stop":
      stopActivity(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func deviceModelIdentifier() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    return withUnsafePointer(to: &sysinfo.machine) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: 1) {
        String(validatingUTF8: $0) ?? ""
      }
    }
  }

  /// 按真实机型 identifier 判断灵动岛与操作按钮支持：
  /// - 灵动岛：iPhone 14 Pro / Pro Max (`iPhone15,2`/`iPhone15,3`)、iPhone 15 全系 (`iPhone15,4`/`5`, `iPhone16,1`/`2`)、
  ///   iPhone 16 全系及更新机型 (`iPhone17,*` 及以上)。iPhone 13 mini (`iPhone14,4`) 等刘海屏返回 false。
  private static func hardwareFlags(model: String) -> (island: Bool, actionButton: Bool) {
    guard model.hasPrefix("iPhone") else { return (false, false) }
    let suffix = model.dropFirst("iPhone".count)
    let parts = suffix.split(separator: ",")
    guard parts.count == 2,
          let major = Int(parts[0]),
          let minor = Int(parts[1]) else {
      return (false, false)
    }
    let island = major >= 16 || (major == 15 && minor >= 2)
    let actionButton = major >= 17 || model == "iPhone16,1" || model == "iPhone16,2"
    return (island, actionButton)
  }

  private func capabilitiesPayload() -> [String: Any] {
    let model = Self.deviceModelIdentifier()
    let flags = Self.hardwareFlags(model: model)
    var supportsLive = false
    var enabled = false
    #if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      supportsLive = true
      enabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }
    #endif
    return [
      "supportsLiveActivities": supportsLive,
      "supportsDynamicIsland": flags.island && supportsLive,
      "supportsActionButton": flags.actionButton,
      "areActivitiesEnabled": enabled,
      "deviceModel": model,
    ]
  }

  private func startActivity(
    startedAtMs: Int64,
    title: String,
    subtitle: String,
    result: @escaping FlutterResult
  ) {
    #if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      Task { @MainActor in
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
          result(nil)
          return
        }
        let state = RecordingCardActivityAttributes.ContentState(
          title: title,
          subtitle: subtitle,
          startedAtMs: startedAtMs,
          isRecording: true
        )
        if let existing = Activity<RecordingCardActivityAttributes>.activities.first {
          if #available(iOS 16.2, *) {
            await existing.update(ActivityContent(state: state, staleDate: nil))
          } else {
            await existing.update(using: state)
          }
          result(existing.id)
          return
        }
        do {
          let attrs = RecordingCardActivityAttributes(appTitle: title)
          if #available(iOS 16.2, *) {
            let created = try Activity.request(
              attributes: attrs,
              content: ActivityContent(state: state, staleDate: nil),
              pushType: nil
            )
            result(created.id)
          } else {
            let created = try Activity.request(
              attributes: attrs,
              contentState: state,
              pushType: nil
            )
            result(created.id)
          }
        } catch {
          result(nil)
        }
      }
      return
    }
    #endif
    result(nil)
  }

  private func stopActivity(result: @escaping FlutterResult) {
    #if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      Task { @MainActor in
        let ended = RecordingCardActivityAttributes.ContentState(
          title: "录音卡",
          subtitle: "已停止",
          startedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
          isRecording: false
        )
        for activity in Activity<RecordingCardActivityAttributes>.activities {
          if #available(iOS 16.2, *) {
            await activity.end(
              ActivityContent(state: ended, staleDate: nil),
              dismissalPolicy: .immediate
            )
          } else {
            await activity.end(using: ended, dismissalPolicy: .immediate)
          }
        }
        result(nil)
      }
      return
    }
    #endif
    result(nil)
  }
}
