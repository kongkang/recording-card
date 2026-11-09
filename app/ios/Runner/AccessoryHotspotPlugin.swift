import Flutter
import NetworkExtension
import UIKit

/// 系统接受配置不代表本地 HTTP 就绪；就绪探测由同一个 Dart 快传 session 负责。
final class AccessoryHotspotPlugin: NSObject, FlutterPlugin {
  private static let ssid = "DYJ-HD-AP"
  private static let passphrase = "reai_dyj_2026"
  private static let joinDeadline: TimeInterval = 60
  // engine 重建不能越过尚未 final 的旧 apply，或让旧清理拆掉新会话的配置。
  private static let instance = AccessoryHotspotPlugin()

  private final class PendingJoin {
    var result: FlutterResult?
    var deadline: DispatchWorkItem?
    var cancelled = false
    var timedOut = false
    var closeResults: [FlutterResult] = []

    init(result: @escaping FlutterResult) {
      self.result = result
    }
  }

  // 所有状态转换、NetworkExtension 调用和 Flutter 回包都在主线程串行。
  private var pending: PendingJoin?
  private var ownsConfiguration = false
  private var sessionOpen = false
  private var detached = false
  private var registrarIdentity: ObjectIdentifier?

  static func register(with registrar: FlutterPluginRegistrar) {
    assert(Thread.isMainThread)
    let channel = FlutterMethodChannel(
      name: "dev.kongkang.recording-card/hotspot",
      binaryMessenger: registrar.messenger()
    )
    let instance = Self.instance
    let identity = ObjectIdentifier(registrar as AnyObject)
    if let previous = instance.registrarIdentity, previous != identity {
      instance.abandonEngine()
    }
    instance.registrarIdentity = identity
    instance.detached = false
    registrar.addMethodCallDelegate(instance, channel: channel)
    // Flutter 只有 publish 的插件会收到 detachFromEngine 回调。
    registrar.publish(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard !self.detached else {
        result(FlutterError(code: "hotspot_unavailable", message: "热点插件已关闭", details: nil))
        return
      }
      switch call.method {
      case "join", "close":
        guard call.arguments == nil || call.arguments is NSNull else {
          result(FlutterError(code: "hotspot_invalid_arguments", message: "热点接口不接受参数", details: nil))
          return
        }
        if call.method == "join" {
          self.join(result: result)
        } else {
          self.close(result: result)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func join(result: @escaping FlutterResult) {
    assert(Thread.isMainThread)
    guard pending == nil && !sessionOpen else {
      result(FlutterError(code: "hotspot_busy", message: "上一热点会话尚未关闭", details: nil))
      return
    }

    let operation = PendingJoin(result: result)
    pending = operation
    let configuration = NEHotspotConfiguration(
      ssid: Self.ssid, passphrase: Self.passphrase, isWEP: false
    )
    configuration.joinOnce = true

    let deadline = DispatchWorkItem { [weak self, weak operation] in
      guard let self = self, let operation = operation else { return }
      self.expire(operation)
    }
    operation.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.joinDeadline, execute: deadline)
    // 强持有到真实 apply final：engine detach 后仍必须处理迟到配置并清理。
    NEHotspotConfigurationManager.shared.apply(configuration) { error in
      DispatchQueue.main.async {
        self.finish(operation, error: error as NSError?)
      }
    }
  }

  private func expire(_ operation: PendingJoin) {
    assert(Thread.isMainThread)
    guard pending === operation && !operation.cancelled else { return }
    operation.timedOut = true
    completeJoin(operation, value: FlutterError(
      code: "hotspot_timeout", message: "系统加入热点尚未完成，正在等待清理",
      details: ["nativeFinal": false]
    ))
    // 仅报告等待超时，不释放 pending、不回 close ACK。apply 没有公开取消 API。
  }

  private func close(result: @escaping FlutterResult) {
    assert(Thread.isMainThread)
    if let operation = pending {
      operation.cancelled = true
      operation.deadline?.cancel()
      operation.closeResults.append(result)
      completeJoin(operation, value: FlutterError(
        code: "hotspot_cancelled", message: "已取消加入热点，正在等待清理",
        details: ["nativeFinal": false]
      ))
      // 在途 close 只能在 finish 中完成；不能凭取消/超时冒充底层 final。
      return
    }
    removeOwnedConfiguration()
    sessionOpen = false
    result(nil)
  }

  private func finish(_ operation: PendingJoin, error: NSError?) {
    assert(Thread.isMainThread)
    guard pending === operation else { return }
    operation.deadline?.cancel()
    let alreadyAssociated = error?.domain == NEHotspotConfigurationErrorDomain
      && error?.code == NEHotspotConfigurationError.alreadyAssociated.rawValue

    // 仅 nil 回调证明本插件本次成功写入配置。alreadyAssociated 不夺取已有配置。
    if error == nil {
      ownsConfiguration = true
    }
    let abandoned = operation.cancelled || operation.timedOut || detached
    if abandoned {
      removeOwnedConfiguration()
      sessionOpen = false
    } else if error == nil || alreadyAssociated {
      sessionOpen = true
    }
    // 清理必须先于释放车道和 close 回包，防旧成功/旧清理污染下一次 join。
    pending = nil
    if !abandoned {
      if error == nil || alreadyAssociated {
        completeJoin(operation, value: ["accepted": true])
      } else if let error = error {
        completeJoin(operation, value: nativeError(error))
      }
    }
    let closeResults = operation.closeResults
    operation.closeResults.removeAll()
    for closeResult in closeResults {
      closeResult(nil)
    }
  }

  private func completeJoin(_ operation: PendingJoin, value: Any?) {
    let result = operation.result
    operation.result = nil
    result?(value)
  }

  private func nativeError(_ error: NSError) -> FlutterError {
    let denied = error.domain == NEHotspotConfigurationErrorDomain
      && error.code == NEHotspotConfigurationError.userDenied.rawValue
    // 不传 localizedDescription/userInfo，避免原生错误泄露配置中的凭据。
    return FlutterError(
      code: denied ? "hotspot_denied" : "hotspot_native_\(error.code)",
      message: denied ? "已取消系统加入热点确认" : "系统未能接受配件热点配置",
      details: ["domain": error.domain, "nativeCode": error.code, "nativeFinal": true]
    )
  }

  private func removeOwnedConfiguration() {
    guard ownsConfiguration else { return }
    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: Self.ssid)
    ownsConfiguration = false
    // Apple 的 remove 是 void API。close 表示调用已提交、apply 已 final，
    // 不声称系统已经切回 Internet Wi-Fi，也不读取当前网络/定位。
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    let identity = ObjectIdentifier(registrar as AnyObject)
    let cleanup = {
      guard self.registrarIdentity == identity else { return }
      self.registrarIdentity = nil
      self.abandonEngine()
    }
    if Thread.isMainThread {
      cleanup()
    } else {
      DispatchQueue.main.async(execute: cleanup)
    }
  }

  private func abandonEngine() {
    assert(Thread.isMainThread)
    detached = true
    sessionOpen = false
    if let operation = pending {
      operation.cancelled = true
      operation.deadline?.cancel()
      operation.result = nil
      operation.closeResults.removeAll()
      // 保留 pending 与强持有的 apply completion，迟到 nil 回调仍会清理。
    } else {
      removeOwnedConfiguration()
    }
  }
}
