//! Phase-2.5 Welle R4 ADX-API wiring regression on LONG sequences.
//!
//! Companion to `regression_adx_api_wiring.rs`, which pins the wiring
//! on 37- and 190-bar synthetic fixtures. This file extends the
//! coverage to 1100-bar sequences (the regime in which Welle R3's
//! real-data sweep observed `filtered == baseline` across all 3
//! strategies). Two assertions per strategy:
//!
//! 1. `adx_filter_enabled=1, adx_threshold=100` must block every
//!    entry. ADX is bounded by 100 by construction so the gate cannot
//!    pass; a non-zero trade count means the filter is wired but
//!    short-circuited on long bars.
//! 2. `adx_filter_enabled=1, adx_threshold=25` must filter STRICTLY
//!    fewer entries than the disabled baseline. Catches a sub-bug
//!    where the threshold=100 case clears via short-circuit but
//!    in-range thresholds take a broken code path.
//!
//! Welle R4 RESOLUTION (2026-05-24): the R3 sweep result was caused
//! by a stale `libtrading_engine.{so,dll}` — the Flutter test runner
//! does not invoke `cargo build` on Rust source changes, so the .so
//! at `target/release/` retained pre-Welle-R2 code that didn't read
//! `adx_filter_enabled`. After `cargo build --release --lib` the
//! sweep produced bit-exact Dart↔Rust parity on all 12 configs (see
//! `regime_filter_diagnose_2026-05-24.md` §4 — RESOLVED). The Rust
//! source has been correct since Welle R2; only the cargo-built
//! artefact was lagging.
//!
//! These regression tests stay relevant for two reasons:
//!   - `cargo test` always rebuilds the under-test code, so this file
//!     catches any FUTURE wiring regression in the long-sequence regime
//!     without depending on the Flutter test runner.
//!   - The companion 37/190-bar tests in `regression_adx_api_wiring.rs`
//!     would still pass on a stale Welle-R1-only binary (which had no
//!     wiring at all and would baseline-pass with threshold=100 trivially
//!     for those fixtures); these long-sequence tests forced the
//!     diagnostic that surfaced the stale-binary root cause.

use serde_json::{json, Value};
use trading_engine::api::run_ut_bot_backtest;
use trading_engine::models::Candle;

const INITIAL_BALANCE: f64 = 10_000.0;
const FEE_RATE: f64 = 0.0006;

fn metrics_total_trades(resp: &str) -> i64 {
    let v: Value = serde_json::from_str(resp).expect("api response must be JSON");
    if let Some(err) = v.get("error") {
        panic!("api returned error: {err}");
    }
    v["metrics"]["total_trades"]
        .as_i64()
        .expect("metrics.total_trades must be present and integer")
}

fn invoke(candles: &[Candle], params: Value) -> i64 {
    let candles_json = serde_json::to_string(candles).unwrap();
    let params_json = serde_json::to_string(&params).unwrap();
    metrics_total_trades(&run_ut_bot_backtest(
        candles_json,
        params_json,
        INITIAL_BALANCE,
        FEE_RATE,
    ))
}

/// Deterministic 1100-bar LCG random walk. Same LCG constants as
/// `addins::ut_bot::tests::build_smoke_fixture` (s = 12345,
/// 1_103_515_245, +12345, & 0x7fff_ffff), only EXTENDED from 400 to
/// 1100 bars. The 400-bar version is known to fire ≥ 1 UT-Bot entry
/// under the `fast_warmup_params` parameter set (cf.
/// `test_adx_filter_disabled_does_not_change_signals_on_smoke_fixture`
/// in `ut_bot.rs`); extending the same LCG to 1100 bars gives the
/// long-sequence regime where Welle R3 observed the wiring bug.
fn ut_bot_lcg_fixture_long() -> Vec<Candle> {
    ut_bot_lcg_fixture_n(1100)
}

fn ut_bot_lcg_fixture_n(n: usize) -> Vec<Candle> {
    let mut closes: Vec<f64> = Vec::with_capacity(n);
    let mut s: u64 = 12345;
    let mut price = 100.0_f64;
    closes.push(price);
    while closes.len() < n {
        s = (s.wrapping_mul(1_103_515_245).wrapping_add(12345)) & 0x7fff_ffff;
        let step = ((s % 200) as f64 - 100.0) / 30.0; // ~[-3.3, +3.3]
        price = (price + step).clamp(80.0, 120.0);
        closes.push(price);
    }
    const BASE_TS: i64 = 1_700_000_000_000;
    closes
        .iter()
        .enumerate()
        .map(|(i, &c)| {
            Candle::new(
                BASE_TS + (i as i64) * 300_000, // 5-minute cadence
                c - 0.3,
                c + 1.2,
                c - 1.2,
                c,
                1_000.0 + i as f64,
            )
        })
        .collect()
}

/// Fast-warm-up UT-Bot params — identical to `fast_warmup_params()` in
/// `addins::ut_bot::tests`. The strict-spec EMA(200) / SMI(14/5/3)
/// defaults would push the start_idx past 200 bars and leave too few
/// signal bars in the 1100-bar window; fast-warmup gives the
/// long-sequence test enough bars after warm-up for the ADX gate
/// to actually filter SOMETHING.
fn ut_bot_fast_warmup_params() -> Value {
    json!({
        "ema_period": 30.0,
        "key_value": 1.0,
        "atr_period": 1.0,
        "smi_length": 5.0,
        "smi_k_smoothing": 3.0,
        "smi_d_smoothing": 3.0,
        "swing_lookback_bars": 5.0,
        "tp_rr_ratio": 2.0,
        "risk_per_trade": 0.02,
    })
}

fn merge(base: Value, extra: Value) -> Value {
    let (Value::Object(mut a), Value::Object(b)) = (base, extra) else {
        unreachable!("merge expects two JSON objects");
    };
    a.extend(b);
    Value::Object(a)
}

#[test]
fn ut_bot_adx_filter_unreachable_threshold_blocks_all_entries_on_long_sequence() {
    // 1100-bar extension of the 400-bar smoke fixture that
    // `addins::ut_bot::tests::test_adx_filter_high_threshold_blocks_all_
    // ut_bot_entries` already pins at 0 trades for threshold=100. This
    // extends the same fixture-shape to the sequence-length regime
    // where Welle R3 observed the wiring break.
    let candles = ut_bot_lcg_fixture_long();

    let baseline_params = ut_bot_fast_warmup_params();
    let baseline = invoke(&candles, baseline_params.clone());

    let filtered_params = merge(
        baseline_params,
        json!({
            "adx_filter_enabled": 1.0,
            "adx_threshold": 100.0,
            "adx_period": 14.0,
            "adx_use_di_confluence": 0.0,
        }),
    );
    let filtered = invoke(&candles, filtered_params);

    // Sanity gate: the LCG fixture must emit ≥ 1 baseline entry over
    // 1100 bars under fast-warmup, or the inequality below is a
    // tautology of `0 == 0` and tells us nothing.
    assert!(
        baseline >= 1,
        "1100-bar LCG fixture must emit ≥ 1 UT-Bot entry under \
         disabled filter, got {baseline} — fixture is degenerate"
    );
    // Smoking gun: ADX ≤ 100 by construction, so threshold=100 MUST
    // block every entry. R3 observed `filtered == baseline` on real
    // BTC 5m (19009 bars) — same param vector, longer sequence.
    assert_eq!(
        filtered, 0,
        "UT-Bot long-sequence ADX wiring: adx_threshold=100 must block \
         every entry on a 1100-bar fixture through the JSON API \
         (got filtered={filtered}, baseline={baseline}). \
         Welle R3 diagnose §4 — Rust ignores the ADX filter on long \
         sequences. Hypotheses H3 / H5 / H1 in priority order."
    );
}

/// Realistic-threshold variant — ADX ∈ ~[5, 50] on the 1100-bar LCG
/// random walk means thr=25 should filter SOME but not ALL UT-Bot
/// entries. If the gate is wired correctly, `filtered < baseline`;
/// if it is silently skipped, `filtered == baseline`. Catches a
/// sub-bug where the helper short-circuits cleanly on
/// `threshold=100` (everything blocked) but takes a broken code path
/// for in-range thresholds.
#[test]
fn ut_bot_adx_filter_thr25_filters_some_entries_on_long_sequence() {
    let candles = ut_bot_lcg_fixture_long();

    let baseline_params = ut_bot_fast_warmup_params();
    let baseline = invoke(&candles, baseline_params.clone());

    let filtered_params = merge(
        baseline_params,
        json!({
            "adx_filter_enabled": 1.0,
            "adx_threshold": 25.0,
            "adx_period": 14.0,
            "adx_use_di_confluence": 0.0,
        }),
    );
    let filtered = invoke(&candles, filtered_params);

    assert!(
        baseline >= 2,
        "1100-bar fixture must emit ≥ 2 baseline entries for thr=25 to \
         have something to filter, got {baseline}"
    );
    assert!(
        filtered < baseline,
        "UT-Bot long-sequence ADX wiring: adx_threshold=25 must filter \
         AT LEAST ONE entry on a 1100-bar fixture (got \
         filtered={filtered}, baseline={baseline}). Welle R3 sweep \
         observed `filtered == baseline` on real BTC 5m — filter \
         silently skipped on long sequences."
    );
}
