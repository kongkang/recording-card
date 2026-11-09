import Flutter
import Darwin
import Network
import NetworkExtension
import UIKit

/// accepted / tcpReady 均不代表 HTTP、设备身份或下载就绪；Dart 仍须严格验证。
final class AccessoryHotspotPlugin: NSObject, FlutterPlugin {
  private static let ssid = "DYJ-HD-AP"
  private static let passphrase = "reai_dyj_2026"
  private static let joinDeadline: TimeInterval = 60
  private static let probeDeadline: TimeInterval = 5
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

  private final class PendingProbe {
    let connection: NWConnection
    var result: FlutterResult?
    var deadline: DispatchWorkItem?
    var outcome: String?
    var tcpReady = false
    var hasAccessoryWifiIPv4 = false
    var pathStatus = "unknown"
    // true 仅表示本次连接曾观察到公开的 localNetworkDenied；false 不证明已授权。
    var localNetworkDenied = false
    var errorDomain: String?
    var errorCode: Int?
    var closeRequested = false
    var closeResults: [FlutterResult] = []

    init(connection: NWConnection, result: @escaping FlutterResult) {
      self.connection = connection
      self.result = result
    }
  }

  // 所有状态转换、NetworkExtension 调用和 Flutter 回包都在主线程串行。
  private var pending: PendingJoin?
  private var pendingProbe: PendingProbe?
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
      case "join", "close", "probe":
        guard call.arguments == nil || call.arguments is NSNull else {
          result(FlutterError(code: "hotspot_invalid_arguments", message: "热点接口不接受参数", details: nil))
          return
        }
        if call.method == "join" {
          self.join(result: result)
        } else if call.method == "probe" {
          self.probe(result: result)
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
    guard pending == nil && pendingProbe == nil && !sessionOpen else {
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

  private func probe(result: @escaping FlutterResult) {
    assert(Thread.isMainThread)
    guard pending == nil && pendingProbe == nil else {
      result(FlutterError(code: "hotspot_busy", message: "上一热点原生动作尚未完成", details: nil))
      return
    }
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .wifi
    let connection = NWConnection(host: "192.168.4.1", port: 80, using: parameters)
    let operation = PendingProbe(connection: connection, result: result)
    pendingProbe = operation
    // 强持有 self 直到 cancelled：detach / engine 重建也不能提前释放原生车道。
    connection.stateUpdateHandler = { [weak operation] state in
      guard let operation = operation else { return }
      self.updateProbe(operation, state: state)
    }
    connection.pathUpdateHandler = { [weak operation] path in
      guard let operation = operation, self.pendingProbe === operation else { return }
      self.captureProbePath(operation, path: path)
    }
    let deadline = DispatchWorkItem { [weak self, weak operation] in
      guard let self = self, let operation = operation else { return }
      self.stopProbe(operation, outcome: "timeout")
    }
    operation.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.probeDeadline, execute: deadline)
    connection.start(queue: .main)
  }

  private func updateProbe(_ operation: PendingProbe, state: NWConnection.State) {
    assert(Thread.isMainThread)
    guard pendingProbe === operation else { return }
    if case .cancelled = state {
      finishProbe(operation)
      return
    }
    guard operation.outcome == nil else { return }
    if let path = operation.connection.currentPath {
      captureProbePath(operation, path: path)
    }
    switch state {
    case .ready:
      operation.tcpReady = true
      operation.errorDomain = nil
      operation.errorCode = nil
      stopProbe(operation, outcome: "ready")
    case .waiting(let error):
      captureProbeError(operation, error: error)
      // Wi-Fi/DHCP/TCC 可能仍在变化；不重启、不扩展五秒窗口。
    case .failed(let error):
      captureProbeError(operation, error: error)
      stopProbe(operation, outcome: "failed")
    default:
      break
    }
  }

  private func captureProbePath(_ operation: PendingProbe, path: Network.NWPath) {
    assert(Thread.isMainThread)
    guard operation.outcome == nil else { return }
    switch path.status {
    case .satisfied: operation.pathStatus = "satisfied"
    case .unsatisfied: operation.pathStatus = "unsatisfied"
    case .requiresConnection: operation.pathStatus = "requiresConnection"
    @unknown default: operation.pathStatus = "unknown"
    }
    if path.status == .unsatisfied && path.unsatisfiedReason == .localNetworkDenied {
      operation.localNetworkDenied = true
    }
  }

  private func captureProbeError(_ operation: PendingProbe, error: NWError) {
    switch error {
    case .posix(let code):
      operation.errorDomain = "posix"
      operation.errorCode = Int(code.rawValue)
    case .dns(let code):
      operation.errorDomain = "dns"
      operation.errorCode = Int(code)
    case .tls(let code):
      operation.errorDomain = "tls"
      operation.errorCode = Int(code)
    default:
      operation.errorDomain = "unknown"
      operation.errorCode = nil
    }
  }

  private func stopProbe(_ operation: PendingProbe, outcome: String) {
    assert(Thread.isMainThread)
    guard pendingProbe === operation && operation.outcome == nil else { return }
    if let path = operation.connection.currentPath {
      captureProbePath(operation, path: path)
    }
    operation.hasAccessoryWifiIPv4 = hasAccessoryWifiIPv4()
    operation.outcome = outcome
    operation.deadline?.cancel()
    operation.connection.cancel()
    // 五秒只限定连接尝试。仍须等实际 cancelled，不用定时器伪造原生 final。
  }

  private func cancelProbe(_ operation: PendingProbe) {
    assert(Thread.isMainThread)
    stopProbe(operation, outcome: "cancelled")
    // close 若抢在 ready -> cancelled 回调之间，也必须使旧结果失效。
    operation.outcome = "cancelled"
    operation.tcpReady = false
    operation.closeRequested = true
    operation.deadline?.cancel()
    operation.connection.cancel()
  }

  private func finishProbe(_ operation: PendingProbe) {
    assert(Thread.isMainThread)
    guard pendingProbe === operation else { return }
    operation.deadline?.cancel()
    operation.connection.stateUpdateHandler = nil
    operation.connection.pathUpdateHandler = nil
    if operation.closeRequested {
      removeOwnedConfiguration()
      sessionOpen = false
    }
    // 仅由实际 NW cancelled 进入此函数；旧配置清理先于车道释放和任何回包。
    pendingProbe = nil
    let result = operation.result
    operation.result = nil
    result?([
      "tcpReady": operation.tcpReady,
      "hasAccessoryWifiIPv4": operation.hasAccessoryWifiIPv4,
      "pathStatus": operation.pathStatus,
      "localNetworkDenied": operation.localNetworkDenied,
      "errorDomain": operation.errorDomain as Any? ?? NSNull(),
      "errorCode": operation.errorCode as Any? ?? NSNull(),
      "outcome": operation.outcome ?? "cancelled",
      "nativeFinal": true,
    ])
    let closeResults = operation.closeResults
    operation.closeResults.removeAll()
    for closeResult in closeResults {
      closeResult(nil)
    }
  }

  private func hasAccessoryWifiIPv4() -> Bool {
    // iOS 的 en0 为 Wi-Fi；仅对其 IPv4 作布尔网段比较，不读 SSID/BSSID/定位。
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return false }
    defer { freeifaddrs(first) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      let interface = entry.pointee
      if String(cString: interface.ifa_name) == "en0",
         interface.ifa_flags & UInt32(IFF_UP) != 0,
         let address = interface.ifa_addr,
         address.pointee.sa_family == UInt8(AF_INET) {
        let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
        if value & 0xFFFFFF00 == 0xC0A80400 { return true }
      }
      cursor = interface.ifa_next
    }
    return false
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
    if let operation = pendingProbe {
      operation.closeResults.append(result)
      cancelProbe(operation)
      // 保留 connection、回调与 closeResults，实际 cancelled 后才能确认关闭。
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
    } else if let operation = pendingProbe {
      operation.result = nil
      operation.closeResults.removeAll()
      cancelProbe(operation)
      // 保留 pendingProbe 到 cancelled；新 engine 不得越过旧动作或旧清理。
    } else {
      removeOwnedConfiguration()
    }
  }
}
