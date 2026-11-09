"""Static iOS hotspot wiring regressions; these do not run iOS or prove RF/TCC behavior."""
from pathlib import Path
import json
import plistlib
import re
import shutil
import subprocess
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
        self.assertIn('case "join", "close":', handle)
        self.assertIn('call.arguments == nil || call.arguments is NSNull', handle)
        self.assertNotRegex(handle, r'arguments\s+as[?!]?')
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
        self.assertIn('guard pending == nil && !sessionOpen else', join)
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
        self.assertNotIn('192.168.4.1', self.source)
        self.assertNotIn('NWPathMonitor', self.source)
        self.assertNotIn('SecTask', self.source)


if __name__ == '__main__':
    unittest.main()
