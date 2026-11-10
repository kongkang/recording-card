#!/usr/bin/env bash
# 构建 card_bridge 的 iOS 静态库，供 Xcode 在链接前调用（Run Script 阶段）。
#
# 为什么需要这一步：pbxproj 用 -force_load 直接链 `target/aarch64-apple-ios/release/libcard_bridge.a`，
# 而 `target/` 是 gitignore 的构建产物 —— 干净检出直接 `flutter build ios` 会 `ld: file not found`。
#
# 为什么显式指定 RUSTC：本机 PATH 里 Homebrew 的 rustc 会遮住 rustup 工具链，
# 而 Homebrew 的 sysroot 没有 iOS 标准库（报 `can't find crate for core/std`）。
# 这里固定到已安装 iOS std 的 rustup 工具链，避免构建结果随 PATH 漂移。
set -euo pipefail

cd "$(dirname "$0")/card_bridge"

TOOLCHAIN="${RC_RUST_TOOLCHAIN:-1.94.0}"
RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME/.rustup}"
# 宿主三元组不要写死：Apple Silicon 是 aarch64-apple-darwin，Intel 是 x86_64-apple-darwin。
# 两种机器都用同一条 rustup 工具链名，按目录前缀找即可。
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
  echo "warning: 未找到 rustup 工具链 ${TOOLCHAIN}，回退到 PATH 中的 rustc（可能缺少 iOS std）" >&2
fi

if ! rustc --print target-list | grep -qx aarch64-apple-ios; then
  echo "error: rustc 不认识 aarch64-apple-ios" >&2
  exit 1
fi

if [ ! -d "$(rustc --print sysroot)/lib/rustlib/aarch64-apple-ios/lib" ]; then
  echo "error: 当前工具链未安装 iOS 标准库，请执行：rustup target add aarch64-apple-ios --toolchain $TOOLCHAIN" >&2
  exit 1
fi

# 支持「配置切换时才重建」：Xcode 会把 ACTION/CONFIGURATION 传进来
cargo build --release --target aarch64-apple-ios

echo "card_bridge: $(ls -lh target/aarch64-apple-ios/release/libcard_bridge.a | awk '{print $5}') @ $(date '+%H:%M:%S')"
