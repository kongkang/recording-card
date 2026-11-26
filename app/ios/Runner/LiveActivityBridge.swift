import Darwin
import Flutter
import Foundation
import UIKit

#if canImport(ActivityKit)
import ActivityKit
#endif

private final class LiveActivityBgTaskToken {
  private let lock = NSLock()
  private var taskId: UIBackgroundTaskIdentifier = .invalid
  private var expired = false

  func begin(name: String) {
    let startWork = {
      var created: UIBackgroundTaskIdentifier = .invalid
      created = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
        self?.handleExpiration()
      }
      self.lock.lock()
      if self.expired {
        self.lock.unlock()
        if created != .invalid {
          UIApplication.shared.endBackgroundTask(created)
        }
        return
      }
      self.taskId = created
      self.lock.unlock()
    }
    if Thread.isMainThread {
      startWork()
    } else {
      DispatchQueue.main.async(execute: startWork)
    }
  }

  private func handleExpiration() {
    lock.lock()
    expired = true
    let id = taskId
    taskId = .invalid
    lock.unlock()
    if id != .invalid {
      let endWork = {
        UIApplication.shared.endBackgroundTask(id)
      }
      if Thread.isMainThread {
        endWork()
      } else {
        DispatchQueue.main.async(execute: endWork)
      }
    }
  }

  func end() {
    lock.lock()
    expired = true
    let id = taskId
    taskId = .invalid
    lock.unlock()
    guard id != .invalid else { return }
    let endWork = {
      UIApplication.shared.endBackgroundTask(id)
    }
    if Thread.isMainThread {
      endWork()
    } else {
      DispatchQueue.main.async(execute: endWork)
    }
  }
}

final class LiveActivityBridge {
  static let shared = LiveActivityBridge()

  static let actionButtonToggleNotification = Notification.Name("com.reai.recordingcard.actionButtonToggle")
  static let actionButtonAgentNotification = Notification.Name("com.reai.recordingcard.actionButtonAgent")

  private var channel: FlutterMethodChannel?
  private var pendingActionToggle = false
  private var pendingActionAgent = false
  private var operationSeq: UInt64 = 0
  private var activeSessionDesired = false
  private var lastOperationTask: Task<Void, Never>?
  private var hourBlinkTask: Task<Void, Never>?

  private init() {
    NotificationCenter.default.addObserver(
      forName: Self.actionButtonToggleNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.triggerActionButtonToggle()
    }
    NotificationCenter.default.addObserver(
      forName: Self.actionButtonAgentNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.triggerActionButtonAgent()
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.cleanupOrphanedActivitiesIfIdle()
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.cleanupOrphanedActivitiesIfIdle()
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.handleAppWillTerminate()
    }
  }

  private func runOnMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

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
    if pendingActionAgent {
      pendingActionAgent = false
      DispatchQueue.main.async {
        ch.invokeMethod("actionButtonAgent", arguments: nil)
      }
    }
  }

  func cleanupOrphanedActivitiesIfIdle() {
    #if canImport(ActivityKit)
    if #available(iOS 16.1, *), Self.isActivityKitRuntimeAvailable() {
      runOnMain { [weak self] in
        guard let self, !self.activeSessionDesired else { return }
        let hasLingering = Activity<RecordingCardActivityAttributes>.activities.contains {
          $0.activityState != .dismissed
        }
        if hasLingering {
          self.enqueueStopActivities(result: nil)
        }
      }
    }
    #endif
  }

  private func handleAppWillTerminate() {
    runOnMain { [weak self] in
      self?.enqueueStopActivities(result: nil)
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

  func triggerActionButtonAgent() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let ch = self.channel {
        ch.invokeMethod("actionButtonAgent", arguments: nil)
      } else {
        self.pendingActionAgent = true
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(capabilitiesPayload())
    case "activeActivity":
      result(activeActivityPayload())
    case "start":
      let args = call.arguments as? [String: Any]
      let startedAtMs = (args?["startedAtMs"] as? NSNumber)?.int64Value
        ?? Int64(Date().timeIntervalSince1970 * 1000)
      let title = (args?["title"] as? String) ?? "录音卡"
      let subtitle = (args?["subtitle"] as? String) ?? "本机录音运行中"
      let isRecording = (args?["isRecording"] as? Bool) ?? true
      startActivity(
        startedAtMs: startedAtMs,
        title: title,
        subtitle: subtitle,
        isRecording: isRecording,
        result: result
      )
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

  private static let isActivityKitDylibLoaded: Bool = {
    guard let handle = dlopen(
      "/System/Library/Frameworks/ActivityKit.framework/ActivityKit",
      RTLD_LAZY
    ) else {
      return false
    }
    return dlsym(
      handle,
      "$s11ActivityKit0A17AuthorizationInfoCACycfC"
    ) != nil
  }()

  static func isActivityKitRuntimeAvailable(
    isiOSAppOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac,
    isMacCatalystApp: Bool = ProcessInfo.processInfo.isMacCatalystApp
  ) -> Bool {
    #if targetEnvironment(macCatalyst)
    return false
    #elseif canImport(ActivityKit)
    if isiOSAppOnMac || isMacCatalystApp {
      return false
    }
    guard #available(iOS 16.1, *) else {
      return false
    }
    return isActivityKitDylibLoaded
    #else
    return false
    #endif
  }

  /// 按真实机型 identifier 判断灵动岛与操作按钮支持：
  /// - 灵动岛：iPhone 14 Pro / Pro Max (`iPhone15,2`/`iPhone15,3`)、iPhone 15 全系 (`iPhone15,4`/`5`, `iPhone16,1`/`2`)、
  ///   iPhone 16 全系及更新机型 (`iPhone17,*` 及以上)。iPhone 13 mini (`iPhone14,4`) 等刘海屏返回 false。
  static func hardwareFlags(model: String) -> (island: Bool, actionButton: Bool) {
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
    if #available(iOS 16.1, *), Self.isActivityKitRuntimeAvailable() {
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

  private func activeActivityPayload() -> [String: Any] {
    #if canImport(ActivityKit)
    if #available(iOS 16.1, *), Self.isActivityKitRuntimeAvailable() {
      let activities = Activity<RecordingCardActivityAttributes>.activities
      let current = activities.first(where: { Self.isLiveActivityState($0.activityState) })
      if let activity = current {
        let state: RecordingCardActivityAttributes.ContentState
        if #available(iOS 16.2, *) {
          state = activity.content.state
        } else {
          state = activity.contentState
        }
        return [
          "active": true,
          "id": activity.id,
          "title": state.title,
          "subtitle": state.subtitle,
          "startedAtMs": NSNumber(value: state.startedAtMs),
          "isRecording": state.isRecording,
        ]
      }
    }
    #endif
    return ["active": false]
  }

  private func startActivity(
    startedAtMs: Int64,
    title: String,
    subtitle: String,
    isRecording: Bool,
    result: @escaping FlutterResult
  ) {
    #if canImport(ActivityKit)
    if #available(iOS 16.1, *), Self.isActivityKitRuntimeAvailable() {
      runOnMain { [weak self] in
        guard let self else {
          result(nil)
          return
        }
        self.operationSeq &+= 1
        let seq = self.operationSeq
        self.activeSessionDesired = true
        self.hourBlinkTask?.cancel()
        self.hourBlinkTask = nil
        let previous = self.lastOperationTask
        let task = Task { @MainActor [weak self] in
          await previous?.value
          guard let self,
                self.operationSeq == seq,
                self.activeSessionDesired else {
            result(nil)
            return
          }
          guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            result(nil)
            return
          }
          let elapsedSec = Date().timeIntervalSince1970 - (Double(startedAtMs) / 1000.0)
          let overHour = isRecording && elapsedSec >= 3600.0
          let state = RecordingCardActivityAttributes.ContentState(
            title: title,
            subtitle: subtitle,
            startedAtMs: startedAtMs,
            isRecording: isRecording,
            isOverOneHour: overHour,
            colonVisible: true
          )
          let hourSwitchDate: Date? = (!isRecording || overHour)
            ? nil
            : Date(timeIntervalSince1970: (Double(startedAtMs) / 1000.0) + 3600.0)
          let liveActivities = Activity<RecordingCardActivityAttributes>.activities.filter {
            Self.isLiveActivityState($0.activityState)
          }
          if let existing = liveActivities.first {
            for extra in liveActivities.dropFirst() {
              await self.endSingleActivity(extra)
            }
            guard self.operationSeq == seq, self.activeSessionDesired else {
              if !self.activeSessionDesired {
                await self.endAllActivitiesNow()
              }
              result(nil)
              return
            }
            if #available(iOS 16.2, *) {
              await existing.update(ActivityContent(state: state, staleDate: hourSwitchDate))
            } else {
              await existing.update(using: state)
            }
            guard self.operationSeq == seq, self.activeSessionDesired else {
              if !self.activeSessionDesired {
                await self.endAllActivitiesNow()
              }
              result(nil)
              return
            }
            if isRecording {
              self.scheduleHourTransitionAndBlink(
                seq: seq,
                startedAtMs: startedAtMs,
                title: title,
                subtitle: subtitle
              )
            }
            result(existing.id)
            return
          }
          do {
            let attrs = RecordingCardActivityAttributes(appTitle: title)
            let createdId: String
            if #available(iOS 16.2, *) {
              let created = try Activity.request(
                attributes: attrs,
                content: ActivityContent(state: state, staleDate: hourSwitchDate),
                pushType: nil
              )
              createdId = created.id
            } else {
              let created = try Activity.request(
                attributes: attrs,
                contentState: state,
                pushType: nil
              )
              createdId = created.id
            }
            guard self.operationSeq == seq, self.activeSessionDesired else {
              if !self.activeSessionDesired {
                await self.endAllActivitiesNow()
              }
              result(nil)
              return
            }
            if isRecording {
              self.scheduleHourTransitionAndBlink(
                seq: seq,
                startedAtMs: startedAtMs,
                title: title,
                subtitle: subtitle
              )
            }
            result(createdId)
          } catch {
            result(nil)
          }
        }
        self.lastOperationTask = task
      }
      return
    }
    #endif
    result(nil)
  }

  #if canImport(ActivityKit)
  @available(iOS 16.1, *)
  private static func isLiveActivityState(_ state: ActivityState) -> Bool {
    if state == .active { return true }
    if #available(iOS 16.2, *) {
      if state == .stale { return true }
    }
    return false
  }

  @available(iOS 16.1, *)
  @MainActor
  private func endSingleActivity(_ activity: Activity<RecordingCardActivityAttributes>) async {
    guard activity.activityState != .dismissed else { return }
    let ended = RecordingCardActivityAttributes.ContentState(
      title: "录音卡",
      subtitle: "已停止",
      startedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
      isRecording: false,
      isOverOneHour: false,
      colonVisible: true
    )
    if #available(iOS 16.2, *) {
      await activity.end(
        ActivityContent(state: ended, staleDate: nil),
        dismissalPolicy: .immediate
      )
    } else {
      await activity.end(using: ended, dismissalPolicy: .immediate)
    }
  }

  @available(iOS 16.1, *)
  @MainActor
  private func endAllActivitiesNow() async {
    for activity in Activity<RecordingCardActivityAttributes>.activities {
      await endSingleActivity(activity)
    }
  }

  @available(iOS 16.1, *)
  @MainActor
  private func scheduleHourTransitionAndBlink(
    seq: UInt64,
    startedAtMs: Int64,
    title: String,
    subtitle: String
  ) {
    hourBlinkTask?.cancel()
    hourBlinkTask = nil
    let startSec = Double(startedAtMs) / 1000.0
    let nowSec = Date().timeIntervalSince1970
    let waitBeforeHour = 3600.0 - (nowSec - startSec)
    guard waitBeforeHour > 0 else { return }

    // 仅在满 1 小时（3600s）时刻单次唤醒切换 MM:SS → HH:MM；1Hz 冒号闪烁交由 Widget 端
    // RCLcdBlink-Regular + TimeDataSource(.hourMinuteSecond) 系统级驱动，不再每秒轮询。
    hourBlinkTask = Task { @MainActor [weak self] in
      let nanos = UInt64(waitBeforeHour * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      guard let self,
            !Task.isCancelled,
            self.operationSeq == seq,
            self.activeSessionDesired,
            let activity = Activity<RecordingCardActivityAttributes>.activities.first(where: {
              Self.isLiveActivityState($0.activityState)
            }) else {
        return
      }
      let next = RecordingCardActivityAttributes.ContentState(
        title: title,
        subtitle: subtitle,
        startedAtMs: startedAtMs,
        isRecording: true,
        isOverOneHour: true,
        colonVisible: true
      )
      if #available(iOS 16.2, *) {
        await activity.update(ActivityContent(state: next, staleDate: nil))
      } else {
        await activity.update(using: next)
      }
    }
  }
  #endif

  private func stopActivity(result: @escaping FlutterResult) {
    enqueueStopActivities(result: result)
  }

  private func enqueueStopActivities(result: FlutterResult?) {
    #if canImport(ActivityKit)
    if #available(iOS 16.1, *), Self.isActivityKitRuntimeAvailable() {
      runOnMain { [weak self] in
        guard let self else {
          result?(nil)
          return
        }
        self.operationSeq &+= 1
        self.activeSessionDesired = false
        self.hourBlinkTask?.cancel()
        self.hourBlinkTask = nil
        let bgToken = LiveActivityBgTaskToken()
        bgToken.begin(name: "RCLiveActivityStop")
        let previous = self.lastOperationTask
        let task = Task { @MainActor [weak self] in
          defer { bgToken.end() }
          await previous?.value
          guard let self else {
            result?(nil)
            return
          }
          if !self.activeSessionDesired {
            await self.endAllActivitiesNow()
          }
          result?(nil)
        }
        self.lastOperationTask = task
      }
      return
    }
    #endif
    result?(nil)
  }
}
