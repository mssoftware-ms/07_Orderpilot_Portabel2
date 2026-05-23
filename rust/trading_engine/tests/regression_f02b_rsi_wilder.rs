//! F-02b RSI windowing-strategy regression.
//!
//! Locks in the contract that `BbRsiStrategy::on_candle` reports an RSI value
//! that matches **cumulative** Wilder smoothing across the full close history
//! up to the current bar — same windowing the Dart engine
//! (`lib/services/backtest_service.dart` `_computeRsi`) uses.
//!
//! Before F-02b, `on_candle` called `calc_rsi(ctx.closes(20), 14)`, i.e. the
//! RSI was reset to a fresh initial average every bar from only the last 20
//! closes. That diverges from cumulative Wilder smoothing whenever the recent
//! 20-close window's gain/loss profile differs from the long-term smoothing
//! state — which is the common case on any non-stationary series — and caused
//! the dart↔rust parity fixture to drift by ~$31.75 / $13900 totalPnl despite
//! identical SL/TP wiring after F-02 (cf. PR `fix/f-02-sl-tp-exit-rules`).
//!
//! This test is RED on the F-02 baseline (rolling 20-close RSI) and GREEN
//! once `on_candle` feeds the full prior-close history to `calc_rsi`.

use std::collections::HashMap;

use trading_engine::addins::bb_rsi::{calc_rsi, BbRsiStrategy};
use trading_engine::models::{Candle, Timeframe};
use trading_engine::strategy::{Context, StrategyAddin};

/// Build a 50-candle synthetic series with a clearly different trend in the
/// first half (monotonic up) vs the second half (mean-reverting oscillation).
/// The Wilder smoothing state from the first half persists into the second,
/// so cumulative RSI at i=49 differs from a fresh 20-close-window RSI by
/// several points — enough to be far outside any float-rounding tolerance.
fn build_two_regime_candles() -> Vec<Candle> {
    let mut closes: Vec<f64> = (0..30).map(|i| 100.0 + i as f64 * 1.5).collect();
    // Oscillating second half around the level reached at i=29 (= 143.5).
    let base = *closes.last().unwrap();
    let osc = [
        2.0, -2.0, 1.5, -1.8, 2.2, -1.5, 1.7, -2.1, 1.9, -1.6,
        2.0, -1.8, 1.5, -2.0, 1.9, -1.7, 2.2, -1.9, 1.6, -2.0,
    ];
    for d in osc {
        closes.push(closes.last().copied().unwrap_or(base) + d);
    }
    assert_eq!(closes.len(), 50);

    closes
        .iter()
        .enumerate()
        .map(|(i, &c)| Candle::new(i as i64 * 3_600_000, c, c + 0.5, c - 0.5, c, 1_000.0))
        .collect()
}

#[test]
fn on_candle_rsi_matches_cumulative_wilder() {
    let candles = build_two_regime_candles();
    let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();

    // Cumulative-Wilder reference: same algorithm as `calc_rsi`, fed the FULL
    // history closes[0..=49]. This is what the Dart engine computes.
    let expected_rsi = calc_rsi(&closes, 14).expect("reference RSI must compute");

    // Drive the strategy across every candle so the smoothing state for the
    // last bar is the one actually used by `on_candle`.
    //
    // F-02b pins the *windowing semantics* — that on_candle feeds the FULL
    // close history to calc_rsi rather than only the last bb_period closes.
    // It does not depend on the Phase-2 default shift (Diff D-01/D-02) to
    // BB(200)+RSI(3). Pin Phase-1 BB(20)+RSI(14) explicitly so the 50-candle
    // fixture is long enough to pass the warm-up boundary
    // (startIdx = max(bb_period, rsi_period+1) = 20).
    let mut params = HashMap::new();
    params.insert("bb_period".to_string(), 20.0);
    params.insert("bb_stddev".to_string(), 2.0);
    params.insert("bb_ma_type".to_string(), 0.0); // SMA
    params.insert("rsi_period".to_string(), 14.0);
    params.insert("rsi_oversold".to_string(), 30.0);
    params.insert("rsi_overbought".to_string(), 70.0);

    let mut strategy = BbRsiStrategy::new();
    let mut ctx = Context::new(candles.clone(), Timeframe::H1, params);
    for (i, candle) in candles.iter().enumerate() {
        ctx.set_index(i);
        let _ = strategy.on_candle(&mut ctx, candle);
    }

    let actual_rsi = ctx
        .get_state("rsi")
        .expect("on_candle must publish the RSI value via ctx.set_state");

    // Tight tolerance — both sides run the same algorithm on the same f64
    // inputs. Any drift above 1e-9 means the inputs differ, i.e. on_candle is
    // still using a truncated lookback window for RSI.
    let diff = (actual_rsi - expected_rsi).abs();
    assert!(
        diff < 1e-9,
        "F-02b: on_candle RSI must match cumulative Wilder over full history. \
         expected={}, actual={}, diff={}",
        expected_rsi,
        actual_rsi,
        diff
    );
}

#[test]
fn calc_rsi_is_path_dependent_on_close_history_length() {
    // Sanity check that pins WHY F-02b matters: the same `calc_rsi` algorithm
    // produces materially different values when fed the last 20 closes vs
    // the full 50-close history. If this test ever turns false the regression
    // above becomes a tautology — leave it in to catch that.
    let candles = build_two_regime_candles();
    let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();

    let full_rsi = calc_rsi(&closes, 14).unwrap();
    let last_20_rsi = calc_rsi(&closes[closes.len() - 20..], 14).unwrap();
    let diff = (full_rsi - last_20_rsi).abs();
    assert!(
        diff > 0.5,
        "fixture must keep the windowing-vs-cumulative gap meaningfully large; \
         full={}, last20={}, diff={}",
        full_rsi,
        last_20_rsi,
        diff
    );
}
