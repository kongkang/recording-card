#!/usr/bin/env bash
# Rust's prebuilt Apple objects carry LLVM sections newer than old Xcode nm.
# Verify with the LLVM tools shipped with the SAME active Rust toolchain.
set -euo pipefail
# Respect the caller's compiler selection; ~/.cargo/bin can shadow rustup.
command -v rustc >/dev/null || { echo 'BLOCKED: missing rustc' >&2; exit 2; }
SYSROOT="$(rustc --print sysroot)"
RUST_VERSION="$(rustc -vV)"
HOST="$(sed -n 's/^host: //p' <<< "$RUST_VERSION")"
[[ -n "$HOST" ]] || { echo 'BLOCKED: rustc did not report a host' >&2; exit 2; }
LLVM_NM="$SYSROOT/lib/rustlib/$HOST/bin/llvm-nm"
[[ -x "$LLVM_NM" ]] || {
  echo 'BLOCKED: matching Rust LLVM symbol tool missing; run rustup component add llvm-tools for the active toolchain' >&2
  exit 2
}
exec "$LLVM_NM" "$@"
