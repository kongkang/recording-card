"""Offline tests. All non-example configs are synthetic and temporary."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from validate_public_config import (ConfigError, FLAGS, REFERENCE_CLIENT_ID,
                                    load_config, validate_config)
from ios_config_preflight import PreflightError, check_pods, check_wiring


def public_config(**overrides):
    config = {
        "RC_OAUTH_CLIENT_ID": REFERENCE_CLIENT_ID,
        "RC_OAUTH_REDIRECT_URI": "recording-card://callback",
        "RC_TEXT_MODEL": "",
        "RC_ASR_ALLOW_DOWNLOAD": False,
        "RC_ASR_LICENSE_ACCEPTED": False,
    }
    config.update(overrides)
    return config


class PublicConfigTests(unittest.TestCase):
    def assert_invalid(self, **changes):
        with self.assertRaises(ConfigError):
            validate_config(public_config(**changes))

    def test_default_is_own_scheme_with_empty_model(self):
        self.assertEqual(validate_config(public_config()), "recording-card")

    def test_local_profile_requires_approval_and_license(self):
        profile = "reai-vibe-board-local-20261109"
        self.assert_invalid(RC_ASR_ARTIFACT_PROFILE=profile)
        self.assert_invalid(RC_ASR_ARTIFACT_PROFILE=profile, RC_ASR_LOCAL_ARTIFACTS_APPROVED=True)
        self.assertEqual(validate_config(public_config(
            RC_ASR_ARTIFACT_PROFILE=profile, RC_ASR_LOCAL_ARTIFACTS_APPROVED=True,
            RC_ASR_LICENSE_ACCEPTED=True)), "recording-card")

    def test_local_profile_never_downloads_or_replaces_pins(self):
        for override in ({"RC_ASR_ALLOW_DOWNLOAD": True}, {"RC_ASR_MODEL_URL": "https://fixture.invalid/model"},
                         {"RC_VAD_SIZE": 5, "RC_VAD_SHA256": "a" * 64}):
            with self.subTest(override=override):
                self.assert_invalid(RC_ASR_ARTIFACT_PROFILE="reai-vibe-board-local-20261109",
                                    RC_ASR_LOCAL_ARTIFACTS_APPROVED=True, RC_ASR_LICENSE_ACCEPTED=True,
                                    **override)

    def test_unknown_profile_and_implicit_local_approval_blocked(self):
        self.assert_invalid(RC_ASR_ARTIFACT_PROFILE="unknown-profile")
        self.assert_invalid(RC_ASR_LOCAL_ARTIFACTS_APPROVED=True)

    def test_committed_example_without_model_is_valid(self):
        self.assertEqual(validate_config(load_config(ROOT / "config/device.public.example.json")), "recording-card")

    def test_explicit_false_boolean_and_string(self):
        for value in (False, "false"):
            with self.subTest(value=value):
                self.assertEqual(validate_config(public_config(RC_OAUTH_REUSE_REFERENCE_CLIENT=value)), "recording-card")

    def test_reference_requires_explicit_true_boolean_or_string(self):
        for value in (True, "true"):
            with self.subTest(value=value):
                self.assertEqual(validate_config(public_config(
                    RC_OAUTH_REUSE_REFERENCE_CLIENT=value,
                    RC_OAUTH_REDIRECT_URI="reai-mobile://callback")), "reai-mobile")

    def test_reference_redirect_without_opt_in_is_blocked(self):
        self.assert_invalid(RC_OAUTH_REDIRECT_URI="reai-mobile://callback")

    def test_false_with_reference_redirect_is_blocked(self):
        self.assert_invalid(RC_OAUTH_REUSE_REFERENCE_CLIENT=False,
                            RC_OAUTH_REDIRECT_URI="reai-mobile://callback")

    def test_true_with_own_redirect_is_blocked(self):
        self.assert_invalid(RC_OAUTH_REUSE_REFERENCE_CLIENT=True)

    def test_reference_wrong_client_is_blocked(self):
        self.assert_invalid(RC_OAUTH_REUSE_REFERENCE_CLIENT=True,
                            RC_OAUTH_CLIENT_ID="different-public-client",
                            RC_OAUTH_REDIRECT_URI="reai-mobile://callback")

    def test_dedicated_public_client_uses_only_own_redirect(self):
        self.assertEqual(validate_config(public_config(RC_OAUTH_CLIENT_ID="dedicated-public-client")), "recording-card")

    def test_exact_redirect_no_paths_queries_fragments_or_case_changes(self):
        for uri in ("recording-card://callback/", "recording-card://callback?x=1",
                    "recording-card://callback#x", "RECORDING-CARD://callback",
                    "recording-card://other", " recording-card://callback", "https://callback"):
            with self.subTest(uri=uri):
                self.assert_invalid(RC_OAUTH_REDIRECT_URI=uri)

    def test_reference_redirect_is_exact(self):
        for uri in ("reai-mobile://callback/", "reai-mobile://callback?x=1", "reai-mobile://other"):
            with self.subTest(uri=uri):
                self.assert_invalid(RC_OAUTH_REUSE_REFERENCE_CLIENT=True, RC_OAUTH_REDIRECT_URI=uri)

    def test_all_known_flags_reject_ambiguous_values(self):
        for key in FLAGS:
            for value in (0, 1, None, "TRUE", "False", "yes", " true", [], {}):
                with self.subTest(key=key, value=value):
                    self.assert_invalid(**{key: value})

    def test_unknown_flag_typo_is_blocked(self):
        self.assert_invalid(RC_OAUTH_REUSE_REFERENCE_CLlENT=True)

    def test_client_and_redirect_must_be_explicit(self):
        for key in ("RC_OAUTH_CLIENT_ID", "RC_OAUTH_REDIRECT_URI"):
            config = public_config()
            del config[key]
            with self.subTest(key=key), self.assertRaises(ConfigError):
                validate_config(config)

    def test_non_scalar_values_and_non_objects_rejected(self):
        for value in (None, [], "{}", True):
            with self.subTest(value=value), self.assertRaises(ConfigError):
                validate_config(value)
        self.assert_invalid(RC_TEXT_MODEL=[])
        self.assert_invalid(RC_OAUTH_CLIENT_ID=" ")

    def test_secret_keys_are_blocked_without_echoing_values(self):
        for key in ("client_secret", "RC_PASSWORD", "RC_ACCESS_TOKEN", "refresh_token", "provider_api_key"):
            with self.subTest(key=key):
                self.assert_invalid(**{key: "synthetic-placeholder"})

    def test_nested_manifest_secret_is_blocked(self):
        self.assert_invalid(RC_FIRMWARE_MANIFEST_JSON=json.dumps({"nested": {"client_secret": "synthetic-placeholder"}}))

    def test_duplicate_json_keys_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "public.json"
            path.write_text('{"RC_OAUTH_REUSE_REFERENCE_CLIENT":false,"RC_OAUTH_REUSE_REFERENCE_CLIENT":true}')
            with self.assertRaises(ConfigError):
                load_config(path)

    def test_missing_invalid_json_and_utf8_are_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "public.json"
            with self.assertRaises(ConfigError):
                load_config(path)
            for content in (b"not-json", b"\xff"):
                path.write_bytes(content)
                with self.assertRaises(ConfigError):
                    load_config(path)

    def test_download_disabled_needs_no_urls_license_or_model(self):
        self.assertEqual(validate_config(public_config()), "recording-card")

    def test_download_requires_license_urls_and_hosts(self):
        complete = dict(RC_ASR_ALLOW_DOWNLOAD=True, RC_ASR_LICENSE_ACCEPTED=True,
                        RC_ASR_MODEL_URL="https://mirror.example/model.onnx",
                        RC_ASR_TOKENS_URL="https://mirror.example/tokens.txt",
                        RC_ASR_DOWNLOAD_HOSTS="mirror.example")
        self.assertEqual(validate_config(public_config(**complete)), "recording-card")
        for key in ("RC_ASR_LICENSE_ACCEPTED", "RC_ASR_MODEL_URL", "RC_ASR_TOKENS_URL", "RC_ASR_DOWNLOAD_HOSTS"):
            bad = complete.copy()
            bad[key] = False if key == "RC_ASR_LICENSE_ACCEPTED" else ""
            with self.subTest(key=key):
                self.assert_invalid(**bad)

    def test_download_urls_require_https_exact_hosts_no_credentials(self):
        for uri in ("http://mirror.example/a", "https://other.example/a", "https://u:p@mirror.example/a",
                    "https://mirror.example:444/a", "https://mirror.example/a#fragment",
                    "https://mirror.example/a?access_token=synthetic", "https://mirror.example/a b"):
            with self.subTest(uri=uri):
                self.assert_invalid(RC_ASR_MODEL_URL=uri, RC_ASR_DOWNLOAD_HOSTS="mirror.example")

    def test_download_host_csv_rejects_url_wildcard_port_empty_entry(self):
        for hosts in ("https://mirror.example", "*.example", "mirror.example:443", "mirror.example,", "a..example"):
            with self.subTest(hosts=hosts):
                self.assert_invalid(RC_ASR_DOWNLOAD_HOSTS=hosts)

    def test_https_endpoint_credentials_are_blocked(self):
        self.assert_invalid(RC_OAUTH_BASE_URL="https://user:synthetic@oauth.example")
        self.assert_invalid(RC_API_BASE="http://oauth.example")

    def test_vad_positive_size_and_exact_hash_required(self):
        good = dict(RC_VAD_SIZE="20", RC_VAD_SHA256="a" * 64,
                    RC_VAD_URL="https://mirror.example/vad.onnx", RC_ASR_DOWNLOAD_HOSTS="mirror.example")
        self.assertEqual(validate_config(public_config(**good)), "recording-card")
        for change in ({"RC_VAD_SIZE": 0}, {"RC_VAD_SIZE": -1}, {"RC_VAD_SIZE": True},
                       {"RC_VAD_SIZE": "2.5"}, {"RC_VAD_SHA256": "a" * 63}):
            with self.subTest(change=change):
                self.assert_invalid(**(good | change))

    def test_preinstalled_vad_spec_without_download_url_is_allowed(self):
        self.assertEqual(validate_config(public_config(RC_VAD_SIZE=20, RC_VAD_SHA256="a" * 64)), "recording-card")

    def test_upload_url_hosts_and_explicit_bearer_contract(self):
        self.assert_invalid(RC_UPLOAD_OAUTH_BEARER_APPROVED=True)
        self.assert_invalid(RC_UPLOAD_RAW_CONTRACT_APPROVED=True)
        self.assert_invalid(RC_UPLOAD_URL="https://upload.example/file", RC_UPLOAD_HOSTS="other.example")
        self.assertEqual(validate_config(public_config(
            RC_UPLOAD_URL="https://upload.example/file", RC_UPLOAD_HOSTS="upload.example",
            RC_UPLOAD_RAW_CONTRACT_APPROVED=True, RC_UPLOAD_OAUTH_BEARER_APPROVED=True)), "recording-card")

    def test_scheme_cli_is_read_only_and_warns_reference_collision(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "approved public.json"
            path.write_text(json.dumps(public_config(RC_OAUTH_REUSE_REFERENCE_CLIENT=True,
                                                     RC_OAUTH_REDIRECT_URI="reai-mobile://callback")))
            before = (path.read_bytes(), path.stat().st_mtime_ns, sorted(Path(directory).iterdir()))
            process = subprocess.run([sys.executable, str(ROOT / "scripts/validate_public_config.py"),
                                      str(path), "--scheme"], capture_output=True, text=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(process.stdout, "reai-mobile\n")
            self.assertIn("ASWebAuthenticationSession", process.stderr)
            self.assertIn("do not uninstall", process.stderr)
            self.assertIn("Android requires a separate test device", process.stderr)
            self.assertEqual(before, (path.read_bytes(), path.stat().st_mtime_ns, sorted(Path(directory).iterdir())))

    def test_cli_invalid_returns_two_without_secret_value(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "public.json"
            path.write_text(json.dumps(public_config(client_secret="synthetic-do-not-echo")))
            process = subprocess.run([sys.executable, str(ROOT / "scripts/validate_public_config.py"), str(path)], capture_output=True, text=True)
            self.assertEqual(process.returncode, 2)
            self.assertNotIn("synthetic-do-not-echo", process.stdout + process.stderr)


class NativeWiringTests(unittest.TestCase):
    def test_current_ios_static_wiring(self):
        check_wiring(ROOT)

    def test_android_has_only_placeholder_scheme_and_preserves_rust_prebuild(self):
        namespace = {"android": "http://schemas.android.com/apk/res/android"}
        manifest = ET.parse(ROOT / "app/android/app/src/main/AndroidManifest.xml")
        schemes = [entry.get("{http://schemas.android.com/apk/res/android}scheme")
                   for entry in manifest.findall(".//data", namespace)
                   if entry.get("{http://schemas.android.com/apk/res/android}scheme")]
        self.assertEqual(schemes, ["${rcOAuthCallbackScheme}"])
        gradle = (ROOT / "app/android/app/build.gradle.kts").read_text()
        self.assertIn('manifestPlaceholders["rcOAuthCallbackScheme"] = nativeOAuthCallbackScheme', gradle)
        self.assertIn('tasks.named("preBuild").configure { dependsOn(buildCardBridge) }', gradle)
        self.assertIn('commandLine("bash", rustRoot.resolve("scripts/build-android.sh").absolutePath)', gradle)

    def test_ios_fixture_rejects_two_schemes_and_include_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "app/ios", root / "app/ios", ignore=shutil.ignore_patterns("Pods", ".symlinks", "ephemeral", "build"))
            shutil.copytree(ROOT / "app/rust/card_bridge/scripts", root / "app/rust/card_bridge/scripts")
            launcher = root / "app/lib/services/auth/web_auth_launcher.dart"
            launcher.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / "app/lib/services/auth/web_auth_launcher.dart", launcher)
            debug = root / "app/ios/Flutter/Debug.xcconfig"
            original = debug.read_text()
            debug.write_text(original.replace('#include "OAuth.xcconfig"', '#include "Generated.xcconfig"'))
            with self.assertRaises(PreflightError):
                check_wiring(root)
            debug.write_text(original)
            local = root / "app/ios/Flutter/OAuthLocal.xcconfig"
            local.write_text("RC_OAUTH_CALLBACK_SCHEME = arbitrary\nOTHER_LDFLAGS = injected\n")
            with self.assertRaises(PreflightError):
                check_wiring(root)

    def test_ios_does_not_globally_register_reference_app_scheme(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "app/ios/Runner/Info.plist"
            target.parent.mkdir(parents=True)
            original = (ROOT / "app/ios/Runner/Info.plist").read_text()
            target.write_text(original.replace('<string>recording-card</string>', '<string>reai-mobile</string>'))
            with self.assertRaises(PreflightError):
                check_wiring(root)

    def test_pods_checks_only_local_fixture_consistency(self):
        # These are dummy text fixtures, not real Pods or a native build.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(PreflightError):
                check_pods(root)
            ios = root / "app/ios"
            (ios / "Pods/Target Support Files/Pods-Runner").mkdir(parents=True)
            (ios / "Flutter").mkdir()
            (ios / "Podfile.lock").write_text("fixture-lock\n")
            (ios / "Pods/Manifest.lock").write_text("different-fixture\n")
            with self.assertRaises(PreflightError):
                check_pods(root)
            (ios / "Pods/Manifest.lock").write_text("fixture-lock\n")
            for name in ("debug", "release"):
                (ios / f"Pods/Target Support Files/Pods-Runner/Pods-Runner.{name}.xcconfig").write_text("// fixture\n")
            (ios / "Flutter/Generated.xcconfig").write_text("FLUTTER_ROOT=/fixture-only\n")
            check_pods(root)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux boundary test")
    def test_linux_ios_check_returns_two_without_local_config_write(self):
        local = ROOT / "app/ios/Flutter/OAuthLocal.xcconfig"
        before = local.read_bytes() if local.exists() else None
        process = subprocess.run(["bash", str(ROOT / "scripts/run_ios_device.sh"), "--check"], capture_output=True, text=True)
        self.assertEqual(process.returncode, 2)
        self.assertIn("Linux cannot build/sign an IPA", process.stderr)
        self.assertEqual(before, local.read_bytes() if local.exists() else None)

    def test_bash_syntax_and_no_short_circuit_symbol_pipeline(self):
        process = subprocess.run(["bash", "-n", str(ROOT / "scripts/run_ios_device.sh")], capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        text = (ROOT / "scripts/run_ios_device.sh").read_text()
        self.assertIn("set -euo pipefail", text)
        self.assertNotIn("| grep -q", "\n".join(line for line in text.splitlines() if not line.strip().startswith("#")))
        self.assertNotIn("RC_TEXT_MODEL", text)


if __name__ == "__main__":
    unittest.main()
