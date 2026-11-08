#!/usr/bin/env bash
# Local compile/config preflight only. Never login, call models, probe BLE, flash,
# delete recordings, or install on a phone. Build requires explicit --build.
set -euo pipefail
mode="${1:---check-only}"
if [[ "$mode" != "--check-only" && "$mode" != "--build" ]]; then
  echo "Usage: $0 [--check-only|--build]" >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "BLOCKED: iOS preflight requires an explicitly authorized online Mac; Linux is not iOS evidence." >&2
  exit 2
fi
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$here/../../../.." && pwd)"
for tool in flutter dart rustc cargo rustup xcodebuild xcrun pod; do
  command -v "$tool" >/dev/null || { echo "BLOCKED: missing $tool" >&2; exit 2; }
done
xcodebuild -version
flutter --version
rustc --version
cargo --version
xcrun --sdk iphoneos --show-sdk-version
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$target" || { echo "BLOCKED: missing Rust target $target" >&2; exit 2; }
done
[[ -f "$root/app/ios/Runner/Info.plist" ]] || { echo "BLOCKED: integrated iOS project missing" >&2; exit 2; }
# Do not print build defines/token/Wi-Fi password or inspect private config.
if [[ "$mode" == "--check-only" ]]; then
  echo "Local tools detected. NOT verification of OAuth callback/FFI linking/ASR/native sharing/hardware."
  echo "Review docs/test/MAC-DEVICE-HANDOFF.md and module A/B/D platform reports before a build."
  exit 0
fi
# B's native build/link instructions must be followed separately; no guessed path.
[[ "${QA_NATIVE_LINK_REVIEWED:-}" == "yes" ]] || { echo "BLOCKED: set QA_NATIVE_LINK_REVIEWED=yes only after checking B's exact staticlib/link instructions." >&2; exit 2; }
cd "$root/app"
flutter pub get
flutter analyze
flutter test --reporter expanded
flutter build ios --debug --no-codesign
echo "Unsigned iOS build completed. Device install, OAuth/ASR/BLE/Wi-Fi/OTA/share are NOT verified."
