#!/usr/bin/env python3
"""Read-only iOS wiring/Pods checks; static checks are NOT a Mac build proof."""
import argparse
from pathlib import Path
import plistlib
import re
import sys

SYMBOLS = ("card_bridge_version", "card_bridge_request", "card_bridge_free_string",
           "card_bridge_set_event_callback")


class PreflightError(ValueError):
    pass


def check_wiring(root):
    root = Path(root)
    flutter = root / "app/ios/Flutter"
    info = plistlib.loads((root / "app/ios/Runner/Info.plist").read_bytes())
    schemes = [scheme for url_type in info.get("CFBundleURLTypes", [])
               for scheme in url_type.get("CFBundleURLSchemes", [])]
    if schemes != ["$(RC_OAUTH_CALLBACK_SCHEME)"]:
        raise PreflightError("Runner must register exactly one build-setting OAuth scheme")
    oauth = (flutter / "OAuth.xcconfig").read_text()
    assignments = re.findall(r"^RC_OAUTH_CALLBACK_SCHEME\s*=\s*(\S+)\s*$", oauth, re.M)
    if assignments != ["recording-card"] or '#include? "OAuthLocal.xcconfig"' not in oauth:
        raise PreflightError("OAuth defaults/local override are not wired safely")
    if oauth.index("RC_OAUTH_CALLBACK_SCHEME = recording-card") > oauth.index('#include? "OAuthLocal.xcconfig"'):
        raise PreflightError("The local OAuth override must follow the safe default")
    for name in ("Debug", "Release"):
        text = (flutter / f"{name}.xcconfig").read_text()
        includes = re.findall(r'^#include\??\s+"([^"]+)"', text, re.M)
        expected = [f"Pods/Target Support Files/Pods-Runner/Pods-Runner.{name.lower()}.xcconfig",
                    "Generated.xcconfig", "CardBridge.xcconfig", "OAuth.xcconfig"]
        if includes != expected:
            raise PreflightError(f"{name}: expected Pods -> Generated -> CardBridge -> OAuth include order")
    bridge = (flutter / "CardBridge.xcconfig").read_text()
    if 'OTHER_LDFLAGS = $(inherited) -force_load "$(CARD_BRIDGE_ARCHIVE)"' not in bridge:
        raise PreflightError("Rust archive must be force-loaded without discarding Pods linker flags")
    for symbol in SYMBOLS:
        if f"-Wl,-u,_{symbol}" not in bridge:
            raise PreflightError(f"Missing retained Rust FFI symbol {symbol}")
    script = root / "app/rust/card_bridge/scripts/build-ios.sh"
    text = script.read_text()
    for contract in ("set -euo pipefail", "Darwin", "iphoneos:arm64",
                     "iphonesimulator:arm64", "iphonesimulator:x86_64", "--show-sdk-path",
                     "cargo build --locked --release",
                     'bash "$ROOT/../../../scripts/rust_nm.sh" --defined-only --extern-only "$OUT/libcard_bridge.a"',
                     *SYMBOLS):
        if contract not in text:
            raise PreflightError("Rust iOS script is missing a checked SDK/archive/symbol contract")
    project = (root / "app/ios/Runner.xcodeproj/project.pbxproj").read_text()
    if 'shellScript = "/bin/bash \\"$PROJECT_DIR/../rust/card_bridge/scripts/build-ios.sh\\"";' not in project:
        raise PreflightError("Runner must invoke the checked-in Rust iOS build phase")
    local = flutter / "OAuthLocal.xcconfig"
    if local.exists():
        active = [line.strip() for line in local.read_text().splitlines()
                  if line.strip() and not line.strip().startswith("//")]
        if active not in (["RC_OAUTH_CALLBACK_SCHEME = recording-card"],
                          ["RC_OAUTH_CALLBACK_SCHEME = reai-mobile"]):
            raise PreflightError("OAuthLocal.xcconfig must contain only one safe known scheme assignment")


def check_pods(root):
    ios = Path(root) / "app/ios"
    lock = ios / "Podfile.lock"
    manifest = ios / "Pods/Manifest.lock"
    if not lock.is_file() or not manifest.is_file():
        raise PreflightError("Pods are not installed: on Mac run flutter pub get in app, then pod install in app/ios")
    if lock.read_bytes() != manifest.read_bytes():
        raise PreflightError("Pods/Manifest.lock differs from Podfile.lock; run pod install on the authorized Mac")
    for name in ("debug", "release"):
        if not (ios / f"Pods/Target Support Files/Pods-Runner/Pods-Runner.{name}.xcconfig").is_file():
            raise PreflightError(f"Missing installed Pods {name} xcconfig")
    generated = ios / "Flutter/Generated.xcconfig"
    if not generated.is_file() or "FLUTTER_ROOT=" not in generated.read_text():
        raise PreflightError("Flutter Generated.xcconfig is missing; run flutter pub get on Mac")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--pods", action="store_true", help="also require locally installed, synchronized Pods")
    args = parser.parse_args(argv)
    try:
        check_wiring(args.root)
        if args.pods:
            check_pods(args.root)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 2
    print("iOS wiring" + (" and installed Pods" if args.pods else " (static only)") + " checks passed; no build/device proof.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
