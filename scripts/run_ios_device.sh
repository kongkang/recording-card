#!/usr/bin/env bash
# Build/preflight only by default. No phone probe, OAuth, ASR download or OTA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---check}"
CONFIG="${RC_CONFIG_FILE:-$ROOT/config/device.public.json}"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'BLOCKED: iOS requires an authorized Mac/Xcode; Linux cannot build/sign an IPA.' >&2
  exit 2
fi
case "$MODE" in --check|--build|--run) ;; *) echo 'Usage: run_ios_device.sh [--check|--build|--run]'; exit 2;; esac
for tool in flutter dart cargo rustup xcodebuild xcrun pod python3; do
  command -v "$tool" >/dev/null || { echo "BLOCKED: missing $tool" >&2; exit 2; }
done
flutter --version
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
rustup target list --installed | grep -qx aarch64-apple-ios || { echo 'Run rustup target add aarch64-apple-ios on this Mac'; exit 2; }
[[ -f "$CONFIG" ]] || { echo 'Copy config/device.public.example.json to ignored config/device.public.json and fill approved public configuration.'; exit 2; }
python3 - "$CONFIG" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
if c.get('RC_OAUTH_REDIRECT_URI') != 'recording-card://callback': raise SystemExit('Callback must match committed platform scheme')
for key in c:
    if any(s in key.lower() for s in ('secret','password','access_token','refresh_token')): raise SystemExit('Secrets are prohibited in build config')
if not c.get('RC_TEXT_MODEL'): raise SystemExit('Configure exact approved RC_TEXT_MODEL; no automatic model fallback')
if c.get('RC_ASR_ALLOW_DOWNLOAD') in (True,'true'):
    if c.get('RC_ASR_LICENSE_ACCEPTED') not in (True,'true') or not all(c.get(k) for k in ('RC_ASR_MODEL_URL','RC_ASR_TOKENS_URL','RC_ASR_DOWNLOAD_HOSTS')): raise SystemExit('Audited model mirror, hosts and license acceptance required')
PY
if [[ "$MODE" == --check ]]; then echo 'Preflight only completed; no mobile build or device proof.'; exit 0; fi
cd "$ROOT/app"
flutter pub get
flutter analyze
flutter test --reporter expanded
(cd rust/card_bridge && cargo check --locked && cargo test --locked)
(cd ios && pod install)
# Xcode invokes the checked-in Rust phase for its current SDK and architecture.
flutter build ios --debug --no-codesign --dart-define-from-file="$CONFIG"
if [[ "$MODE" == --build ]]; then
  echo 'Unsigned Runner.app produced; NOT a signed IPA or an installed/verified app.'
  exit 0
fi
[[ "${RC_DEVICE_RUN_APPROVED:-}" == yes && -n "${RC_IOS_DEVICE_ID:-}" ]] || { echo 'Explicit RC_DEVICE_RUN_APPROVED=yes and RC_IOS_DEVICE_ID required for installation'; exit 2; }
# Flutter invokes local signing configured by the user in Runner.xcworkspace.
# Opening/using the app may start owned recording when connected: review manual.
flutter run --debug -d "$RC_IOS_DEVICE_ID" --dart-define-from-file="$CONFIG"
