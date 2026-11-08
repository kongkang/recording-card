#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to the installed Android NDK (do not install in this script)}"
JAVA_OUT="${CARD_JAVA_OUTPUT_DIR:-$ROOT/build/android/java}"
JNI_OUT="${CARD_JNI_OUTPUT_DIR:-$ROOT/build/android/jni}"
case "$(uname -s)" in Linux) HOST=linux-x86_64 ;; Darwin) HOST=darwin-x86_64 ;; *) echo "Unsupported NDK host" >&2; exit 2 ;; esac
BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST/bin"
[[ -x "$BIN/llvm-ar" ]] || { echo "ERROR: NDK LLVM toolchain missing: $BIN" >&2; exit 2; }
command -v python3 >/dev/null
META="$(mktemp)"; trap 'rm -f "$META"' EXIT
cargo metadata --locked --format-version 1 --manifest-path "$ROOT/Cargo.toml" > "$META"
# Copy locked btleplug Java + vendored jni-utils (BSD/MIT licenses retained below),
# never edit Cargo cache/reference source. Generated files are not Git source.
BTLE="$(python3 - "$META" <<'PY'
import json,sys,pathlib
m=json.load(open(sys.argv[1]))
p=next(p for p in m['packages'] if p['name']=='btleplug' and p['version']=='0.12.0')
print(pathlib.Path(p['manifest_path']).parent)
PY
)"
mkdir -p "$JAVA_OUT" "$JNI_OUT"
cp -R "$BTLE/src/droidplug/java/src/main/java/." "$JAVA_OUT/"
cp "$BTLE/LICENSE.md" "$JAVA_OUT/BTLEPLUG-LICENSE.md"
API="${CARD_ANDROID_API:-23}"
for ABI in ${CARD_ANDROID_ABIS:-arm64-v8a x86_64 armeabi-v7a}; do
  case "$ABI" in
    arm64-v8a) TARGET=aarch64-linux-android; CLANG=aarch64-linux-android ;;
    x86_64) TARGET=x86_64-linux-android; CLANG=x86_64-linux-android ;;
    armeabi-v7a) TARGET=armv7-linux-androideabi; CLANG=armv7a-linux-androideabi ;;
    *) echo "Unsupported Android ABI $ABI" >&2; exit 2 ;;
  esac
  rustup target list --installed | grep -qx "$TARGET" || { echo "Missing prerequisite: rustup target add $TARGET" >&2; exit 2; }
  KEY="$(echo "$TARGET" | tr '[:lower:]-' '[:upper:]_')"
  export "CARGO_TARGET_${KEY}_LINKER=$BIN/${CLANG}${API}-clang"
  export "CC_${TARGET//-/_}=$BIN/${CLANG}${API}-clang"
  export "AR_${TARGET//-/_}=$BIN/llvm-ar"
  cargo build --locked --release --target "$TARGET" --manifest-path "$ROOT/Cargo.toml"
  mkdir -p "$JNI_OUT/$ABI"
  cp "$ROOT/target/$TARGET/release/libcard_bridge.so" "$JNI_OUT/$ABI/"
  "$BIN/llvm-nm" -D "$JNI_OUT/$ABI/libcard_bridge.so" | grep ' card_bridge_request$' >/dev/null
  "$BIN/llvm-nm" -D "$JNI_OUT/$ABI/libcard_bridge.so" | grep ' Java_dev_kongkang_recording_1card_CardNative_initialize$' >/dev/null
  echo "Built real Rust JNI bridge: $ABI"
done
