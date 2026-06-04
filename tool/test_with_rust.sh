#!/usr/bin/env bash
# F-10 build-hardening: rebuild the Rust FFI library, THEN run flutter test.
#
# `flutter test` never invokes `cargo build`; it loads whatever
# `rust/trading_engine/target/release/libtrading_engine.{so,dylib,dll}`
# already exists (RustBridge._findDevLibrary). A stale artefact silently
# masks engine fixes — the exact failure mode that hid the F-10 Dart↔Rust
# parity drift behind an outdated .so during diagnosis. This wrapper makes
# the rebuild mandatory so any test that exercises engine code reflects the
# current Rust source.
#
# Usage (drop-in replacement for `flutter test`):
#   bash tool/test_with_rust.sh                                   # full suite
#   bash tool/test_with_rust.sh test/integration/phase1_reference_backtest_test.dart
#   bash tool/test_with_rust.sh --name 'parity' test/integration
#
# `cargo build --release` is incremental, so the rebuild is near-free when
# the Rust source is unchanged. Exits non-zero if either the build or the
# tests fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[test_with_rust] rebuilding Rust release library ..."
bash "${REPO_ROOT}/tool/build_rust.sh" release

echo "[test_with_rust] running flutter test ..."
cd "${REPO_ROOT}"
exec flutter test "$@"
