# Post-Renovation QA Fix Plan

> **For Hermes:** Implement with strict TDD, then run Rust + Flutter/Dart verification and independent review.

**Goal:** Repair correctness regressions discovered after the QA-audit implementation batch, especially trading risk sizing and bridge/API consistency.

**Architecture:** Keep `Signal.size_pct` as the existing notional allocation percentage contract. Fee-aware risk sizing belongs in strategy-side `position_size_pct` helpers, because strategies know risk-per-trade and SL distance. The backtest engine must consume `size_pct` as notional %, validate order brackets, and execute fills/accounting only.

**Tech Stack:** Rust trading engine, Flutter/Dart FRB bridge, YAML optimizer search spaces.

---

## Audit Findings to Fix

### F-PR-01 — CRITICAL: `size_pct` double-converted in `BacktestEngine::open_position`

**Root cause:** Strategies compute `size_pct = 100 * risk_per_trade * entry / sl_distance` as notional allocation. Recent N-08 engine change treated that notional percentage as a risk-budget percentage and divided by `fee_factor`, causing oversized trades for wider stops.

**Decision:** Preserve `Signal.size_pct` as notional allocation %. Move fee-aware formula into `position_size_pct` helpers used by BB+RSI, UT Bot, and Ichimoku.

**Files:**
- Modify: `rust/trading_engine/src/backtest/mod.rs`
- Modify: `rust/trading_engine/src/addins/bb_rsi.rs`
- Modify: `rust/trading_engine/src/addins/ut_bot.rs`
- Modify: `rust/trading_engine/src/addins/ichimoku.rs`

**Tests first:**
- Add/adjust Rust tests proving net SL loss including entry+exit fees is near configured risk for several SL distances.
- Add unit tests for the strategy sizing helper with fee rate.

**Implementation:**
- Add fee-aware strategy helper formula:
  `size_pct = 100 * risk_per_trade / (sl_dist / entry + fee_rate * (1 + sl_price / entry))`.
- Update strategy calls to pass SL price/fee rate if needed.
- Revert engine allocation to direct notional: `alloc = balance * size_pct.clamp(0,100) / 100`.
- Keep N-13: `quantity = alloc / entry_price`; fees remain balance costs.

---

### F-PR-02 — HIGH: BB+RSI `InputSpec::MinCandles(50)` stale

**Root cause:** `required_inputs()` still advertises 50 candles while default `bb_period=200` and warmup need at least ~200 candles before valid signals.

**Files:**
- Modify: `rust/trading_engine/src/addins/bb_rsi.rs`

**Tests first:**
- Add assertion that BB+RSI required MinCandles is at least the default BB period.

**Implementation:**
- Change `InputSpec::MinCandles(50)` to a conservative `InputSpec::MinCandles(200)` or computed constant matching default warmup.

---

### F-PR-03 — MEDIUM/HIGH: `MoveStop` validation blocks BE/profit-lock and allows loosening

**Root cause:** Validation only checks side vs entry (`new_sl < entry` for long, `new_sl > entry` for short). That blocks BE/profit-lock and allows moving SL farther away.

**Files:**
- Modify: `rust/trading_engine/src/backtest/mod.rs`

**Tests first:**
- Long BE move to `entry` is accepted.
- Long profit-lock above entry is accepted when it tightens current SL.
- Long loosening below current SL is rejected.
- Equivalent short tests if practical.

**Implementation:**
- If current stop exists:
  - Long: accept only `new_sl >= current_sl`.
  - Short: accept only `new_sl <= current_sl`.
- If no current stop exists, accept finite positive values; do not enforce entry-side because profit-lock is valid.

---

### F-PR-04 — MEDIUM: TP direction is not validated on entry

**Root cause:** `open_position()` validates SL side but not TP side, so invalid TP can trigger immediate nonsensical take-profit.

**Files:**
- Modify: `rust/trading_engine/src/backtest/mod.rs`

**Tests first:**
- Long with `tp <= entry` is skipped.
- Short with `tp >= entry` is skipped.

**Implementation:**
- Validate TP at entry:
  - Long: `tp > entry_price`.
  - Short: `tp < entry_price`.
  - positive finite price required.

---

### F-PR-05 — HIGH: Dart/FRB bridge stale after `Signal.tp` Vec→Option migration

**Root cause:** Rust uses `Option<f64>` but generated Dart bridge/wrapper/tests still expect `Float64List`/`List<double>`.

**Files:**
- Modify/regenerate: `lib/src/bridge/strategy/signal.dart`
- Modify/regenerate: `lib/src/bridge/strategy/signal.freezed.dart`
- Modify: `lib/services/rust_bridge.dart`
- Modify: `test/rust_bridge_test.dart`

**Tests first:**
- Dart test should expect nullable `double? tp`, not list.

**Implementation:**
- Prefer running FRB codegen if available.
- If generator is unavailable, perform minimal generated-file sync matching current Rust-generated SSE/Dart semantics.

---

### F-PR-06 — LOW/MEDIUM: YAML `slippage_bps` is engine config, not strategy param

**Root cause:** Search-space `fixed.slippage_bps` gets merged into strategy params and ignored by backtest engine. Current value 0.0 prevents numeric damage, but future non-zero sweeps would lie.

**Files:**
- Inspect/modify: `rust/trading_engine/src/optimizer/runner.rs`
- Inspect/modify: `01_Projectplan/search_spaces/*.yaml`

**Tests first:**
- Add/adjust YAML/runner test proving non-zero `slippage_bps` reaches `BacktestConfig`, or remove it from strategy YAMLs to avoid false control.

**Implementation:**
- Prefer explicit runner support for engine config fields if YAML schema supports it; otherwise remove `slippage_bps` from fixed search-space params and document default engine slippage.

---

## Verification Gate

Run from `rust/trading_engine`:

```bash
cargo +stable test --all-targets -- --nocapture
cargo +stable clippy --all-targets --all-features -- -D warnings
```

Run from repo root if Flutter toolchain is available:

```bash
flutter test
flutter analyze
```

Also run focused tests for any new Rust tests before full suite.

---

## Commit Strategy

1. Commit this plan/baseline before implementation.
2. Implement fixes in small commits or one verified commit if changes are tightly coupled.
3. Final commit message should mention post-renovation risk/bridge fixes.
