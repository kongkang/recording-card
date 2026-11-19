#!/usr/bin/env bash
# 构建 card_bridge 的 Android 原生库（.so），供 Gradle 打包进 APK。
#
# Android 与 iOS 的关键差异：btleplug 在 Android 上不是走系统框架，而是通过 JNI 调
# Android 的 BluetoothAdapter。所以 .so 里必须导出 JNI_OnLoad（见 src/lib.rs），
# 在 Flutter 加载库时把 JavaVM 交给 btleplug::platform::init。
#
# 为什么显式指定 RUSTC：本机 PATH 里 Homebrew 的 rustc 会遮住 rustup 工具链，
# 而 Homebrew 的 sysroot 没有 Android/iOS 标准库。
#
# 用法：
#   ./rust/build-android.sh                          # arm64-v8a
#   RC_ANDROID_ALL_ABIS=1 ./rust/build-android.sh    # 额外 armeabi-v7a 与 x86_64
#
# 说明：NDK 探测只做「文件存在 + 目录结构完整」的静态判断，**不执行 clang 探测**——
# NDK 的 clang 包装脚本在非交互环境下可能阻塞，导致构建卡死。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/card_bridge"

TOOLCHAIN="${RC_RUST_TOOLCHAIN:-1.94.0}"
RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME/.rustup}"
TOOLCHAIN_BIN="$RUSTUP_HOME_DIR/toolchains/$TOOLCHAIN-aarch64-apple-darwin/bin"
if [ -x "$TOOLCHAIN_BIN/rustc" ]; then
  export RUSTC="$TOOLCHAIN_BIN/rustc"
  export PATH="$TOOLCHAIN_BIN:$PATH"
else
  echo "warning: 未找到 rustup 工具链 $TOOLCHAIN，回退到 PATH 中的 rustc" >&2
fi

API_LEVEL="${RC_ANDROID_API:-24}"
HOST_TAG="darwin-x86_64"

# ── 选 NDK：优先显式指定，否则按版本从新到旧找第一个结构完整的 ──
ndk_ok() {
  local ndk="$1"
  [ -n "$ndk" ] || return 1
  [ -x "$ndk/toolchains/llvm/prebuilt/$HOST_TAG/bin/aarch64-linux-android${API_LEVEL}-clang" ] || return 1
  [ -e "$ndk/toolchains/llvm/prebuilt/$HOST_TAG/bin/clang" ] || return 1
  return 0
}

# 首选版本优先于环境变量：Gradle 会把自己的 ndkDirectory 传成 ANDROID_NDK_HOME，
# 而本机 Flutter 选中的是 NDK 28（其 clang 会让 cc-rs 找不到编译器）。
# 只有显式指定 RC_ANDROID_NDK_VERSION=auto 才完全尊重环境变量。
NDK=""
preferred_version="${RC_ANDROID_NDK_VERSION:-26.3.11579264}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [ "$preferred_version" != "auto" ] && ndk_ok "$SDK/ndk/$preferred_version"; then
  NDK="$SDK/ndk/$preferred_version"
fi
if [ -z "$NDK" ]; then
  for candidate in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
    if ndk_ok "$candidate"; then NDK="$candidate"; break; fi
  done
fi
if [ -z "$NDK" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
  # 已知问题：本机 NDK 27/28 的 clang 包装脚本在构建时找不到目标编译器
  # （cc-rs 报 failed to find tool），26.3 已验证可用。固定版本并允许覆盖。
  preferred="${RC_ANDROID_NDK_VERSION:-26.3.11579264}"
  if ndk_ok "$SDK/ndk/$preferred"; then
    NDK="$SDK/ndk/$preferred"
  else
    echo "warning: 首选 NDK $preferred 不可用，退回可用版本" >&2
    for candidate in $(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V -r); do
      if ndk_ok "$candidate"; then NDK="$candidate"; break; fi
    done
  fi
fi
if [ -z "$NDK" ]; then
  echo "error: 找不到可用的 Android NDK（设置 ANDROID_NDK_HOME，或安装到 \$ANDROID_HOME/ndk/）" >&2
  exit 1
fi
echo "NDK: $NDK"

BIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
SHIM_DIR="$PWD/target/android-cc"
mkdir -p "$SHIM_DIR"

# cc-rs 找的是不带版本号的编译器名，而 NDK 只提供带 API 版本的包装脚本。
# 生成一层 shim 用绝对路径 exec 真正的编译器；不能用 symlink——NDK 的包装脚本
# 靠 dirname "$0" 定位 clang，symlink 会让它找错目录。
make_shim() {
  local real="$1" name="$2"
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$real" > "$SHIM_DIR/$name"
  chmod +x "$SHIM_DIR/$name"
}

build_abi() {
  local triple="$1" clang_prefix="$2" abi_dir="$3"
  local cc="$BIN/${clang_prefix}${API_LEVEL}-clang"
  local cxx="$BIN/${clang_prefix}${API_LEVEL}-clang++"
  if [ ! -x "$cc" ]; then
    echo "error: 找不到编译器 $cc" >&2
    return 1
  fi

  local env_var
  env_var="$(echo "$triple" | tr '-' '_' | tr '[:lower:]' '[:upper:]')"

  make_shim "$cc" "${clang_prefix}-clang"
  # .cargo/config.toml 里按相对路径引用，这里补齐 llvm-ar 与 ar 的软链
  ln -sf "$BIN/llvm-ar" "$SHIM_DIR/llvm-ar"
  export "CC_${env_var}=$SHIM_DIR/${clang_prefix}-clang"
  if [ -x "$cxx" ]; then
    make_shim "$cxx" "${clang_prefix}-clang++"
    export "CXX_${env_var}=$SHIM_DIR/${clang_prefix}-clang++"
    export "CXXFLAGS_${env_var}=-Wno-register"
  fi
  export "AR_${env_var}=$BIN/llvm-ar"
  export "CARGO_TARGET_${env_var}_LINKER=$SHIM_DIR/${clang_prefix}-clang"

  cargo build --release --target "$triple"

  local out="$here/../android/app/src/main/jniLibs/$abi_dir"
  mkdir -p "$out"
  cp "target/$triple/release/libcard_bridge.so" "$out/"
  echo "card_bridge -> $abi_dir ($(ls -lh "$out/libcard_bridge.so" | awk '{print $5}'))"
}

build_abi "aarch64-linux-android" "aarch64-linux-android" "arm64-v8a"

if [ "${RC_ANDROID_ALL_ABIS:-0}" = "1" ]; then
  build_abi "armv7-linux-androideabi" "armv7a-linux-androideabi" "armeabi-v7a"
  build_abi "x86_64-linux-android" "x86_64-linux-android" "x86_64"
fi
