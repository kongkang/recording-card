#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "ERROR: iOS requires an authorized Mac with Xcode. Linux is not an iOS build." >&2
  exit 2
fi
command -v cargo >/dev/null
command -v xcrun >/dev/null
xcrun --find clang >/dev/null
# Xcode invokes this for exactly its current SDK/architectures. No cargo-lipo
# merger between device and simulator (which would corrupt arm64 slices).
PLATFORM="${PLATFORM_NAME:-iphoneos}"
ARCHITECTURES="${ARCHS:-arm64}"
OUT="${CARD_BRIDGE_OUTPUT_DIR:-$ROOT/build/ios/$PLATFORM}"
mkdir -p "$OUT"
LIBS=()
for ARCH in $ARCHITECTURES; do
  case "$PLATFORM:$ARCH" in
    iphoneos:arm64) TARGET=aarch64-apple-ios; SDK=iphoneos ;;
    iphonesimulator:arm64) TARGET=aarch64-apple-ios-sim; SDK=iphonesimulator ;;
    iphonesimulator:x86_64) TARGET=x86_64-apple-ios; SDK=iphonesimulator ;;
    *) echo "ERROR: unsupported iOS slice $PLATFORM:$ARCH" >&2; exit 2 ;;
  esac
  INSTALLED_TARGETS="$(rustup target list --installed)"
  if ! grep -qx "$TARGET" <<< "$INSTALLED_TARGETS"; then
    echo "ERROR: prerequisite missing; run rustup target add $TARGET on this Mac" >&2
    exit 2
  fi
  SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
  [[ -d "$SDKROOT" ]] || { echo "ERROR: installed SDK not found: $SDK" >&2; exit 2; }
  export SDKROOT
  export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
  cargo build --locked --release --manifest-path "$ROOT/Cargo.toml" --target "$TARGET"
  LIBS+=("$ROOT/target/$TARGET/release/libcard_bridge.a")
done
if [[ ${#LIBS[@]} -eq 1 ]]; then cp "${LIBS[0]}" "$OUT/libcard_bridge.a";
else xcrun lipo -create "${LIBS[@]}" -output "$OUT/libcard_bridge.a"; fi
for SYMBOL in card_bridge_version card_bridge_request card_bridge_free_string card_bridge_set_event_callback; do
  if ! xcrun nm -g "$OUT/libcard_bridge.a" | grep "_$SYMBOL" >/dev/null; then
    echo "ERROR: missing FFI symbol $SYMBOL" >&2; exit 3
  fi
done
echo "Rust iOS archive built for $PLATFORM ($ARCHITECTURES): $OUT/libcard_bridge.a"
