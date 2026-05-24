#!/usr/bin/env bash
# Phase-2.5 Welle R4 Rust-FFI build helper.
#
# `flutter test` does NOT invoke `cargo build` on Rust source changes —
# the test runner loads `rust/trading_engine/target/release/libtrading_
# engine.{so,dylib,dll}` via `RustBridge._findDevLibrary` and silently
# uses whatever artefact is already there. If the binary lags behind
# the source (e.g. after pulling new Welle R2 / R4 commits), the
# Flutter tests will silently exercise the OLD Rust code path and
# misdiagnose the discrepancy as a strategy bug — exactly the
# regression Welle R3 hit on ADX wiring (see
# `01_Projectplan/specs/regime_filter_diagnose_2026-05-24.md` §4).
#
# This script rebuilds the Rust FFI library so subsequent `flutter
# test` runs reflect the current Rust source. Run it after:
#   - Pulling new commits that touch `rust/trading_engine/src/**/*.rs`
#   - Editing any addin or engine code locally
#   - Switching branches in the rust/ subtree
#
# Usage:
#   bash tool/build_rust.sh             # release build (matches RustBridge default)
#   bash tool/build_rust.sh debug       # debug build (also probed by RustBridge fallback)
#
# Exits non-zero on cargo failure so CI / wrapper scripts can detect it.

set -euo pipefail

PROFILE="${1:-release}"
if [[ "${PROFILE}" != "release" && "${PROFILE}" != "debug" ]]; then
    echo "usage: $0 [release|debug]" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="${REPO_ROOT}/rust/trading_engine"

if [[ ! -d "${CRATE_DIR}" ]]; then
    echo "rust/trading_engine not found at ${CRATE_DIR}" >&2
    exit 1
fi

cd "${CRATE_DIR}"
if [[ "${PROFILE}" == "release" ]]; then
    cargo build --release --lib
else
    cargo build --lib
fi

# Surface the artefact path so callers can verify mtime.
case "$(uname -s)" in
    Linux*)   LIB="lib${LIB:-trading_engine}.so" ;;
    Darwin*)  LIB="lib${LIB:-trading_engine}.dylib" ;;
    *)        LIB="trading_engine.dll" ;;
esac
echo "built: ${CRATE_DIR}/target/${PROFILE}/${LIB}"
