"""iOS hotspot static/pure lifecycle regressions; these do not prove iOS RF/TCC behavior."""
from pathlib import Path
import json
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / 'app/ios/Runner'
PROJECT = ROOT / 'app/ios/Runner.xcodeproj/project.pbxproj'


def body(source, name):
    """Extract a balanced Swift function body (the checked functions have no string braces)."""
    start = source.index('{', source.index(f'func {name}('))
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start + 1:end - 1]


class IosHotspotWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (RUNNER / 'AccessoryHotspotPlugin.swift').read_text()
        cls.delegate = (RUNNER / 'AppDelegate.swift').read_text()
        cls.project_source = PROJECT.read_text()

    def test_public_fixed_join_once_without_ssid_or_location_access(self):
        self.assertIn('import NetworkExtension', self.source)
        self.assertIn('private static let ssid = "DYJ-HD-AP"', self.source)
        self.assertEqual(self.source.count('"reai_dyj_2026"'), 1)
        join = body(self.source, 'join')
        self.assertIn('ssid: Self.ssid, passphrase: Self.passphrase, isWEP: false', join)
        self.assertIn('configuration.joinOnce = true', join)
        self.assertIn('NEHotspotConfigurationManager.shared.apply(configuration)', join)
        for forbidden in ('getSSID', 'getConfiguredSSIDs', 'fetchCurrent', 'CaptiveNetwork',
                          'CoreLocation', 'CLLocationManager', 'NEHotspotHelper',
                          'access-wifi-info', 'UIApplication.shared.open', 'print(', 'NSLog('):
            self.assertNotIn(forbidden, self.source)

    def test_frozen_channel_and_no_arbitrary_credentials(self):
        self.assertIn('name: "dev.kongkang.recording-card/hotspot"', self.source)
        handle = body(self.source, 'handle')
        self.assertIn('case "join", "close", "probe":', handle)
        self.assertIn('call.arguments == nil || call.arguments is NSNull', handle)
        self.assertNotRegex(handle, r'arguments\s+as[?!]?')
        self.assertIn('self.probe(result: result)', handle)
        self.assertIn('FlutterMethodNotImplemented', handle)

    def test_registration_uses_real_implicit_engine_and_preserves_generated_plugins(self):
        registration = body(self.delegate, 'didInitializeImplicitFlutterEngine')
        self.assertIn('GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)', registration)
        self.assertIn('engineBridge.pluginRegistry.registrar(forPlugin: "AccessoryHotspotPlugin")', registration)
        self.assertIn('AccessoryHotspotPlugin.register(with: registrar)', registration)
        launch = body(self.delegate, 'application')
        self.assertNotIn('AccessoryHotspotPlugin.register', launch)
        self.assertIn('registrar.addMethodCallDelegate(instance, channel: channel)', self.source)
        self.assertIn('registrar.publish(instance)', self.source)

    def test_entitlement_is_only_hotspot_not_location_or_keychain(self):
        entitlements = plistlib.loads((RUNNER / 'Runner.entitlements').read_bytes())
        self.assertEqual(entitlements, {'com.apple.developer.networking.HotspotConfiguration': True})

    def test_runner_project_wiring_all_configs_preserves_identity(self):
        plutil = shutil.which('plutil')
        if plutil is None:
            self.skipTest('plutil unavailable; project parse not validated on this host')
        parsed = subprocess.run([plutil, '-convert', 'json', '-o', '-', '--', str(PROJECT)],
                                check=True, capture_output=True, text=True)
        objects = json.loads(parsed.stdout)['objects']
        runner = objects['97C146ED1CF9000F007C117D']
        config_ids = objects[runner['buildConfigurationList']]['buildConfigurations']
        self.assertEqual({objects[key]['name'] for key in config_ids}, {'Debug', 'Release', 'Profile'})
        for key in config_ids:
            settings = objects[key]['buildSettings']
            self.assertEqual(settings['CODE_SIGN_ENTITLEMENTS'], 'Runner/Runner.entitlements')
            self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'], 'dev.kongkang.recordingCard')
            self.assertEqual(settings['DEVELOPMENT_TEAM'], '35N5SGDE59')
            self.assertNotIn('PROVISIONING_PROFILE_SPECIFIER', settings)
        attributes = objects['97C146E61CF9000F007C117D']['attributes']['TargetAttributes']
        self.assertEqual(int(attributes['97C146ED1CF9000F007C117D']['SystemCapabilities']
                                   ['com.apple.HotspotConfiguration']['enabled']), 1)
        source_refs = [objects[key]['fileRef'] for key in objects['97C146EA1CF9000F007C117D']['files']]
        source_paths = [objects[key]['path'] for key in source_refs]
        self.assertEqual(source_paths.count('AccessoryHotspotPlugin.swift'), 1)
        self.assertIn('AppDelegate.swift', source_paths)
        self.assertIn('SceneDelegate.swift', source_paths)
        self.assertNotIn('Runner.entitlements', source_paths)

    def test_one_inflight_and_no_rejoin_before_close(self):
        join = body(self.source, 'join')
        self.assertIn('guard pending == nil && pendingProbe == nil && !sessionOpen else', join)
        self.assertIn('"hotspot_busy"', join)
        self.assertLess(join.index('pending = operation'), join.index('.shared.apply(configuration)'))

    def test_timeout_reports_nonfinal_but_keeps_native_lane(self):
        expire = body(self.source, 'expire')
        self.assertIn('guard pending === operation && !operation.cancelled', expire)
        self.assertIn('operation.timedOut = true', expire)
        self.assertIn('"hotspot_timeout"', expire)
        self.assertIn('["nativeFinal": false]', expire)
        self.assertNotIn('pending = nil', expire)
        self.assertNotIn('closeResult(nil)', expire)
        self.assertNotIn('removeOwnedConfiguration()', expire)
        self.assertIn('DispatchQueue.main.asyncAfter', body(self.source, 'join'))

    def test_close_inflight_marks_cancel_and_waits_for_apply_final(self):
        close = body(self.source, 'close')
        pending_branch = close[close.index('if let operation = pending'):close.index('removeOwnedConfiguration()')]
        self.assertIn('operation.cancelled = true', pending_branch)
        self.assertIn('operation.deadline?.cancel()', pending_branch)
        self.assertIn('operation.closeResults.append(result)', pending_branch)
        self.assertIn('"hotspot_cancelled"', pending_branch)
        self.assertIn('["nativeFinal": false]', pending_branch)
        self.assertIn('return', pending_branch)
        self.assertNotIn('result(nil)', pending_branch)
        self.assertNotIn('pending = nil', pending_branch)

    def test_late_success_cleanup_precedes_lane_release_and_close_ack(self):
        finish = body(self.source, 'finish')
        self.assertIn('guard pending === operation', finish)
        self.assertIn('operation.cancelled || operation.timedOut || detached', finish)
        cleanup = finish.index('removeOwnedConfiguration()')
        release = finish.index('pending = nil')
        self.assertLess(cleanup, release)
        self.assertLess(release, finish.index('closeResult(nil)'))
        self.assertIn('if !abandoned {', finish)
        self.assertLess(finish.index('if !abandoned {'), finish.index('["accepted": true]'))
        self.assertNotIn('[weak self]', body(self.source, 'join').split('.shared.apply(configuration)')[1])

    def test_already_associated_is_accepted_without_taking_ownership(self):
        finish = body(self.source, 'finish')
        self.assertIn('error?.domain == NEHotspotConfigurationErrorDomain', finish)
        self.assertIn('NEHotspotConfigurationError.alreadyAssociated.rawValue', finish)
        self.assertRegex(finish, r'if error == nil\s*\{\s*ownsConfiguration = true\s*\}')
        self.assertIn('error == nil || alreadyAssociated', finish)
        self.assertEqual(self.source.count('ownsConfiguration = true'), 1)
        cleanup = body(self.source, 'removeOwnedConfiguration')
        self.assertIn('guard ownsConfiguration else { return }', cleanup)
        self.assertIn('removeConfiguration(forSSID: Self.ssid)', cleanup)
        self.assertLess(cleanup.index('removeConfiguration('), cleanup.index('ownsConfiguration = false'))

    def test_denial_and_native_codes_preserved_without_sensitive_error_text(self):
        native_error = body(self.source, 'nativeError')
        self.assertIn('NEHotspotConfigurationError.userDenied.rawValue', native_error)
        self.assertIn('"hotspot_denied"', native_error)
        self.assertIn('"hotspot_native_\\(error.code)"', native_error)
        self.assertIn('"domain": error.domain, "nativeCode": error.code', native_error)
        code_only = re.sub(r'//[^\n]*', '', native_error)
        self.assertNotIn('localizedDescription', code_only)
        self.assertNotIn('userInfo', code_only)
        self.assertNotIn('value: false', self.source)

    def test_engine_detach_keeps_pending_cleanup_and_drops_old_callbacks(self):
        self.assertIn('private static let instance = AccessoryHotspotPlugin()', self.source)
        detach = body(self.source, 'detachFromEngine')
        self.assertIn('self.registrarIdentity == identity', detach)
        self.assertIn('if Thread.isMainThread', detach)
        abandon = body(self.source, 'abandonEngine')
        self.assertIn('operation.cancelled = true', abandon)
        self.assertIn('operation.result = nil', abandon)
        self.assertIn('operation.closeResults.removeAll()', abandon)
        self.assertNotIn('pending = nil', abandon)
        complete = body(self.source, 'completeJoin')
        self.assertLess(complete.index('operation.result = nil'), complete.index('result?(value)'))

    def test_native_never_claims_local_http_or_internet_readiness(self):
        self.assertEqual(self.source.count('["accepted": true]'), 1)
        self.assertNotIn('URLSession', self.source)
        self.assertEqual(self.source.count('"192.168.4.1"'), 1)
        self.assertNotIn('/api/files', self.source)
        self.assertNotRegex(self.source, r'\.(send|receive|receiveMessage)\(')
        self.assertNotIn('NWBrowser', self.source)
        self.assertNotIn('NWListener', self.source)
        self.assertNotIn('bonjour', self.source.lower())
        self.assertNotIn('NWPathMonitor', self.source)
        self.assertNotIn('SecTask', self.source)

    def test_probe_is_one_fixed_tcp_connection_on_wifi_with_five_second_window(self):
        probe = body(self.source, 'probe')
        self.assertIn('import Network\n', self.source)
        self.assertIn('private static let probeDeadline: TimeInterval = 5', self.source)
        self.assertIn('guard pending == nil && pendingProbe == nil else', probe)
        self.assertIn('NWParameters.tcp', probe)
        self.assertIn('parameters.requiredInterfaceType = .wifi', probe)
        self.assertIn('NWConnection(host: "192.168.4.1", port: 80, using: parameters)', probe)
        self.assertEqual(self.source.count('NWConnection(host:'), 1)
        self.assertLess(probe.index('pendingProbe = operation'), probe.index('connection.start('))
        self.assertIn('connection.start(queue: .main)', probe)
        self.assertIn('DispatchQueue.main.asyncAfter', probe)
        self.assertIn('self.stopProbe(operation, outcome: "timeout")', probe)
        self.assertNotIn('restart()', self.source)
        self.assertNotIn('forceCancel()', self.source)

    def test_probe_stop_and_cancel_keep_lane_and_callbacks_until_cancelled(self):
        stop = body(self.source, 'stopProbe')
        cancel = body(self.source, 'cancelProbe')
        for action in (stop, cancel):
            self.assertIn('operation.connection.cancel()', action)
            self.assertIn('operation.deadline?.cancel()', action)
            self.assertNotIn('pendingProbe = nil', action)
            self.assertNotIn('operation.result = nil', action)
            self.assertNotIn('stateUpdateHandler = nil', action)
            self.assertNotIn('closeResult(nil)', action)
        self.assertIn('operation.outcome == nil', stop)
        self.assertIn('operation.outcome = "cancelled"', cancel)
        self.assertIn('operation.tcpReady = false', cancel)
        self.assertIn('operation.closeRequested = true', cancel)
        update = body(self.source, 'updateProbe')
        self.assertIn('if case .cancelled = state', update)
        self.assertEqual(update.count('finishProbe(operation)'), 1)
        self.assertEqual(self.source.count('finishProbe(operation)'), 1)
        self.assertLess(update.index('finishProbe(operation)'), update.index('operation.outcome == nil'))
        self.assertIn('operation.tcpReady = true', update)
        self.assertIn('outcome: "ready"', update)
        self.assertIn('outcome: "failed"', update)

    def test_close_and_detach_wait_for_probe_final_without_old_engine_callbacks(self):
        close = body(self.source, 'close')
        branch = close[close.index('if let operation = pendingProbe'):close.index('removeOwnedConfiguration()')]
        self.assertIn('operation.closeResults.append(result)', branch)
        self.assertIn('cancelProbe(operation)', branch)
        self.assertIn('return', branch)
        self.assertNotIn('result(nil)', branch)
        abandon = body(self.source, 'abandonEngine')
        self.assertIn('else if let operation = pendingProbe', abandon)
        self.assertIn('cancelProbe(operation)', abandon)
        self.assertNotIn('pendingProbe = nil', abandon)
        probe = body(self.source, 'probe')
        self.assertNotIn('[weak self', probe.split('connection.stateUpdateHandler =')[1].split('let deadline =')[0])
        finish = body(self.source, 'finishProbe')
        self.assertIn('guard pendingProbe === operation', finish)
        self.assertIn('if operation.closeRequested', finish)
        self.assertLess(finish.index('removeOwnedConfiguration()'), finish.index('pendingProbe = nil'))
        self.assertLess(finish.index('pendingProbe = nil'), finish.index('result?('))
        self.assertLess(finish.index('operation.result = nil'), finish.index('result?('))
        self.assertLess(finish.index('result?('), finish.index('closeResult(nil)'))
        self.assertIn('stateUpdateHandler = nil', finish)
        self.assertIn('pathUpdateHandler = nil', finish)

    def test_probe_diagnostics_are_structured_numeric_and_not_permission_assertions(self):
        finish = body(self.source, 'finishProbe')
        keys = re.findall(r'^\s*"(\w+)":', finish, re.M)
        self.assertEqual(set(keys), {'tcpReady', 'hasAccessoryWifiIPv4', 'pathStatus',
                                    'localNetworkDenied', 'errorDomain', 'errorCode',
                                    'outcome', 'nativeFinal'})
        self.assertIn('"nativeFinal": true', finish)
        self.assertIn('operation.errorCode as Any? ?? NSNull()', finish)
        path = body(self.source, 'captureProbePath')
        self.assertIn('path.status == .unsatisfied && path.unsatisfiedReason == .localNetworkDenied', path)
        self.assertIn('operation.localNetworkDenied = true', path)
        self.assertNotIn('operation.localNetworkDenied = false', path)
        self.assertIn('operation.outcome == nil', path)
        error = body(self.source, 'captureProbeError')
        for domain in ('posix', 'dns', 'tls', 'unknown'):
            self.assertIn(f'operation.errorDomain = "{domain}"', error)
        code_only = re.sub(r'//[^\n]*', '', self.source)
        for forbidden in ('localizedDescription', 'debugDescription', 'userInfo',
                          'String(describing:', 'inet_ntop', 'getnameinfo'):
            self.assertNotIn(forbidden, code_only)

    def test_ipv4_check_is_only_wifi_subnet_boolean_and_frees_ifaddrs(self):
        check = body(self.source, 'hasAccessoryWifiIPv4')
        self.assertIn('import Darwin', self.source)
        self.assertIn('getifaddrs(&interfaces)', check)
        self.assertIn('defer { freeifaddrs(first) }', check)
        self.assertIn('String(cString: interface.ifa_name) == "en0"', check)
        self.assertIn('interface.ifa_flags & UInt32(IFF_UP) != 0', check)
        self.assertIn('address.pointee.sa_family == UInt8(AF_INET)', check)
        self.assertIn('UInt32(bigEndian: $0.pointee.sin_addr.s_addr)', check)
        self.assertIn('value & 0xFFFFFF00 == 0xC0A80400', check)
        self.assertNotIn('String(', check.split('let value =')[1])
        self.assertNotIn('ifa_name', body(self.source, 'finishProbe'))

    def test_pure_swift_probe_lifecycle_waits_for_controlled_cancelled_event(self):
        """Execute production transition bodies with fakes, never real Network/getifaddrs.

        This proves callback/lane ordering under controlled events, not Apple cancellation,
        RF, TCC, DHCP, HTTP, identity or download behavior on a phone.
        """
        swiftc = shutil.which('swiftc')
        if swiftc is None:
            self.skipTest('swiftc unavailable; pure lifecycle harness not executed')
        start = self.source.index('  private final class PendingProbe {')
        end = self.source.index('  // 所有状态转换', start)
        probe_type = self.source[start:end]
        methods = []
        for name in ('updateProbe', 'captureProbePath', 'captureProbeError', 'stopProbe',
                     'cancelProbe', 'finishProbe', 'close', 'abandonEngine', 'completeJoin'):
            start = self.source.index(f'  private func {name}(')
            brace = self.source.index('{', start)
            methods.append(self.source[start:brace + 1] + body(self.source, name) + '}')
        production = (probe_type + '\n'.join(methods)).replace('Network.NWPath', 'NWPath')
        fixture = r'''
import Foundation
typealias FlutterResult = (Any?) -> Void
final class FlutterError {
  init(code: String, message: String, details: Any?) {}
}
struct FakeCode { let rawValue: Int }
enum NWError { case posix(FakeCode), dns(Int32), tls(Int32), other }
struct NWPath {
  enum Status { case satisfied, unsatisfied, requiresConnection }
  enum Reason { case notAvailable, localNetworkDenied }
  var status: Status
  var unsatisfiedReason: Reason
}
final class NWConnection {
  enum State { case setup, ready, waiting(NWError), failed(NWError), cancelled }
  var currentPath: NWPath?
  var stateUpdateHandler: ((State) -> Void)?
  var pathUpdateHandler: ((NWPath) -> Void)?
  var cancels = 0
  // Deliberately no automatic final: tests deliver cancelled separately.
  func cancel() { cancels += 1 }
}
final class ProbeHarness {
  private final class PendingJoin {
    var result: FlutterResult?
    var deadline: DispatchWorkItem?
    var cancelled = false
    var closeResults: [FlutterResult] = []
  }
  private var pending: PendingJoin?
  private var pendingProbe: PendingProbe?
  private var ownsConfiguration = true
  private var sessionOpen = true
  private var detached = false
  private var removals = 0
  // Test seam: no host interface enumeration, no real Apple configuration calls.
  private func hasAccessoryWifiIPv4() -> Bool { false }
  private func removeOwnedConfiguration() {
    if ownsConfiguration { removals += 1; ownsConfiguration = false }
  }
'''
        driver = r'''
  func run() {
    var results: [[String: Any]] = []
    func make() -> PendingProbe {
      let operation = PendingProbe(connection: NWConnection()) { value in
        precondition(Thread.isMainThread)
        precondition(self.pendingProbe == nil)
        results.append(value as! [String: Any])
      }
      operation.connection.stateUpdateHandler = { _ in }
      operation.connection.pathUpdateHandler = { _ in }
      pendingProbe = operation
      return operation
    }
    let ready = make()
    ready.connection.currentPath = NWPath(status: .satisfied, unsatisfiedReason: .notAvailable)
    updateProbe(ready, state: .ready)
    precondition(results.isEmpty && pendingProbe === ready && ready.connection.cancels > 0)
    precondition(ready.connection.stateUpdateHandler != nil)
    updateProbe(ready, state: .cancelled)
    updateProbe(ready, state: .cancelled)
    precondition(results.count == 1 && results[0]["tcpReady"] as? Bool == true)
    precondition(results[0]["nativeFinal"] as? Bool == true)
    precondition(results[0]["outcome"] as? String == "ready")
    precondition(results[0]["errorCode"] is NSNull)
    precondition(ready.connection.stateUpdateHandler == nil)
    precondition(ready.connection.pathUpdateHandler == nil)
    precondition(removals == 0 && sessionOpen)

    let timeout = make()
    stopProbe(timeout, outcome: "timeout")
    updateProbe(timeout, state: .ready) // Late ready cannot turn timeout into success.
    precondition(results.count == 1 && pendingProbe === timeout)
    updateProbe(timeout, state: .cancelled)
    precondition(results.count == 2 && results[1]["outcome"] as? String == "timeout")
    precondition(results[1]["tcpReady"] as? Bool == false)

    let failed = make()
    failed.connection.currentPath = NWPath(status: .unsatisfied, unsatisfiedReason: .localNetworkDenied)
    updateProbe(failed, state: .waiting(.posix(FakeCode(rawValue: 13))))
    precondition(results.count == 2 && failed.connection.cancels == 0)
    updateProbe(failed, state: .failed(.posix(FakeCode(rawValue: 13))))
    precondition(results.count == 2 && pendingProbe === failed)
    updateProbe(failed, state: .cancelled)
    precondition(results.count == 3 && results[2]["localNetworkDenied"] as? Bool == true)
    precondition(results[2]["pathStatus"] as? String == "unsatisfied")
    precondition(results[2]["errorDomain"] as? String == "posix")
    precondition(results[2]["errorCode"] as? Int == 13)

    let closing = make()
    updateProbe(closing, state: .ready)
    var acknowledgements = 0
    let ack: FlutterResult = { _ in
      precondition(Thread.isMainThread && self.pendingProbe == nil)
      precondition(!self.ownsConfiguration && !self.sessionOpen && self.removals == 1)
      precondition(results.count == 4)
      acknowledgements += 1
    }
    close(result: ack)
    close(result: ack)
    precondition(acknowledgements == 0 && results.count == 3)
    precondition(pendingProbe === closing && ownsConfiguration && removals == 0)
    updateProbe(closing, state: .cancelled)
    precondition(acknowledgements == 2 && results.count == 4)
    precondition(results[3]["outcome"] as? String == "cancelled")
    precondition(results[3]["tcpReady"] as? Bool == false)

    ownsConfiguration = true
    sessionOpen = true
    let abandoned = make()
    close(result: { _ in preconditionFailure("old engine close callback") })
    abandonEngine()
    precondition(detached && pendingProbe === abandoned && ownsConfiguration)
    detached = false // Simulate registrar replacement while old cancel is still pending.
    updateProbe(abandoned, state: .ready)
    precondition(pendingProbe === abandoned && results.count == 4)
    updateProbe(abandoned, state: .cancelled)
    precondition(results.count == 4 && !ownsConfiguration && removals == 2)
    let newer = make()
    updateProbe(abandoned, state: .cancelled)
    precondition(pendingProbe === newer) // Stale final cannot release a new engine lane.
    cancelProbe(newer)
    updateProbe(newer, state: .cancelled)
    precondition(results.count == 5)
    print("pure Swift lifecycle: ready, timeout, failure, double close, detach, stale final OK")
  }
}
ProbeHarness().run()
'''
        with tempfile.TemporaryDirectory(prefix='rc-hotspot-lifecycle-') as directory:
            path = Path(directory)
            (path / 'main.swift').write_text(fixture + production + driver)
            compiled = subprocess.run([swiftc, '-module-cache-path', str(path / 'module-cache'),
                                       str(path / 'main.swift'), '-o', str(path / 'probe-test')],
                                      capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            executed = subprocess.run([str(path / 'probe-test')], capture_output=True,
                                      text=True, timeout=10)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
            self.assertIn('stale final OK', executed.stdout)


if __name__ == '__main__':
    unittest.main()
