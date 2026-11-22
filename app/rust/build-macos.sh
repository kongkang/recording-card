#!/usr/bin/env bash
# 构建 card_bridge 的 macOS 动态库，供桌面客户端在运行时 dlopen。
#
# 产物：app/rust/card_bridge/target/release/libcard_bridge.dylib
# Xcode 的「Copy card_bridge」阶段会把它拷进 .app/Contents/MacOS/。
# 宿主工具链用 rustup（与 build-ios.sh 同一条），避免 PATH 里的 Homebrew rustc 漂移。
set -euo pipefail

cd "$(dirname "$0")/card_bridge"

TOOLCHAIN="${RC_RUST_TOOLCHAIN:-1.94.0}"
RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME/.rustup}"
TOOLCHAIN_BIN=""
for candidate in "$RUSTUP_HOME_DIR"/toolchains/"$TOOLCHAIN"-*/bin; do
  if [ -x "$candidate/rustc" ]; then
    TOOLCHAIN_BIN="$candidate"
    break
  fi
done

if [ -n "$TOOLCHAIN_BIN" ]; then
  export RUSTC="$TOOLCHAIN_BIN/rustc"
  export PATH="$TOOLCHAIN_BIN:$PATH"
else
  echo "warning: 未找到 rustup 工具链 ${TOOLCHAIN}，回退到 PATH 中的 rustc" >&2
fi

cargo build --release

echo "card_bridge: $(ls -lh target/release/libcard_bridge.dylib | awk '{print $5}') @ $(date '+%H:%M:%S')"
