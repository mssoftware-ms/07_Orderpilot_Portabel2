#!/usr/bin/env bash
# PreToolUse hook: rebuild the Rust FFI library if it's older than any
# .rs source — but only when the about-to-run Bash command is
# `flutter test*`. Other bash calls pass through with ~no overhead.
#
# Why: `flutter test` does not invoke `cargo build`. A stale
# `libtrading_engine.{so,dll,dylib}` silently masks engine fixes — the
# exact failure mode that hid the F-10 Dart↔Rust parity drift during
# diagnosis. `tool/test_with_rust.sh` already fixes this for explicit
# wrapper calls; this hook makes the guarantee automatic so plain
# `flutter test` (typed from muscle memory) cannot regress either.
#
# Triggered by `.claude/settings.json` PreToolUse on the Bash tool.
# Exit 0 = let the tool call proceed; exit 2 = hard fail with stderr.
# No JSON output → no permission override.
#
# O3-B4 platform-verification lesson + F-10-CI Option 1.

set -euo pipefail

# Read tool-use JSON from stdin, extract command field.
# Use python because jq is not guaranteed on Git-Bash (Windows-CC).
input=""
if [ ! -t 0 ]; then
  input="$(cat)"
fi
command="$(printf '%s' "$input" | python -c 'import json,sys; print(json.loads(sys.stdin.read()).get("tool_input",{}).get("command",""))' 2>/dev/null || echo "")"

# Only act when the bash command runs flutter test. Match `flutter test`
# at start-of-token (avoids matching e.g. `echo 'flutter test'` in a
# comment). Standalone `bash tool/test_with_rust.sh` already rebuilds,
# but the hook still runs to be a no-op (the lib will be fresh).
if ! printf '%s' "$command" | grep -qE '(^|[^[:alnum:]_/-])flutter[[:space:]]+test'; then
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  # Not in a git repo — let the test command run as-is.
  exit 0
fi

# Pick the platform-native rust library if one exists.
LIB=""
for candidate in \
  "$REPO_ROOT/rust/trading_engine/target/release/trading_engine.dll" \
  "$REPO_ROOT/rust/trading_engine/target/release/libtrading_engine.so" \
  "$REPO_ROOT/rust/trading_engine/target/release/libtrading_engine.dylib"; do
  if [ -f "$candidate" ]; then
    LIB="$candidate"
    break
  fi
done

if [ -z "$LIB" ]; then
  # No library at all — call `tool/build_rust.sh release` to seed it.
  echo "[pretest-hook] No rust library found — running tool/build_rust.sh release first." 1>&2
  bash "$REPO_ROOT/tool/build_rust.sh" release 1>&2
  exit 0
fi

# POSIX-`find -newer`: returns at least one path if any .rs is newer
# than $LIB. `-print -quit` stops after the first hit (fast path).
SRC_DIR="$REPO_ROOT/rust/trading_engine/src"
if [ -d "$SRC_DIR" ]; then
  stale_hit="$(find "$SRC_DIR" -name '*.rs' -newer "$LIB" -print -quit 2>/dev/null || true)"
  if [ -n "$stale_hit" ]; then
    echo "[pretest-hook] Rust source newer than $LIB — rebuilding before flutter test." 1>&2
    bash "$REPO_ROOT/tool/build_rust.sh" release 1>&2
  fi
fi

exit 0
