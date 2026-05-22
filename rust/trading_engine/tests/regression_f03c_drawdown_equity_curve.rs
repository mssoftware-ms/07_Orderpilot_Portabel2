//! F-03c regression: max drawdown must be computed against the per-candle
//! equity curve (industry standard, sharpe-consistent), not against
//! per-trade settled PnL.
//!
//! Spec §3.4 F-03c:
//!   peak = running max of equity_curve points (initialised at equity_curve[0])
//!   drawdown_at_point = peak - equity_point
//!   max_drawdown      = max(drawdown_at_point) over the curve
//!   max_drawdown_pct  = max(drawdown_at_point / peak_at_point * 100)
//!
//! Mirrors the Dart engine bit-exact
//! (lib/services/backtest_service.dart:322-326). The pre-F-03c Rust engine
//! recomputed `max_drawdown` inside `BacktestMetrics::from_trades` by walking
//! settled trade PnL, which ignored open-position intra-trade equity excursions
//! and produced a value ≈ 30× smaller than the Dart engine on the parity
//! fixture (28.75 vs 951.47).
//!
//! Toleranz: 1e-9 (gleiche f64-Operationen, keine sqrt).

use trading_engine::models::max_drawdown_from_equity_curve;

#[test]
fn drawdown_finds_largest_peak_to_trough_excursion() {
    // Peak at 10_800 (index 2), trough at 9_500 (index 3) → max_dd = 1_300.
    // A later excursion (11_000 → 10_200, dd = 800) is smaller and must not
    // overwrite the result.
    let equity = [
        10_000.0, 10_500.0, 10_800.0, 9_500.0, 9_800.0, 11_000.0, 10_200.0,
        11_500.0,
    ];
    let (max_dd, _max_dd_pct) = max_drawdown_from_equity_curve(&equity);
    assert!(
        (max_dd - 1_300.0).abs() < 1e-9,
        "expected max_dd = 1300.0, got {}",
        max_dd
    );
}

#[test]
fn drawdown_is_zero_on_monotonically_rising_curve() {
    let equity = [10_000.0, 10_100.0, 10_500.0, 11_000.0, 12_000.0];
    let (max_dd, max_dd_pct) = max_drawdown_from_equity_curve(&equity);
    assert!(
        max_dd.abs() < 1e-9,
        "expected max_dd = 0 on rising curve, got {}",
        max_dd
    );
    assert!(
        max_dd_pct.abs() < 1e-9,
        "expected max_dd_pct = 0 on rising curve, got {}",
        max_dd_pct
    );
}

#[test]
fn drawdown_equals_start_minus_end_on_monotonically_falling_curve() {
    // Peak stays at the first point; max drawdown is the total fall.
    let equity = [10_000.0, 9_500.0, 8_750.0, 8_000.0, 7_000.0];
    let (max_dd, max_dd_pct) = max_drawdown_from_equity_curve(&equity);
    let expected_dd = 10_000.0 - 7_000.0;
    let expected_pct = expected_dd / 10_000.0 * 100.0;
    assert!(
        (max_dd - expected_dd).abs() < 1e-9,
        "expected max_dd = {}, got {}",
        expected_dd,
        max_dd
    );
    assert!(
        (max_dd_pct - expected_pct).abs() < 1e-9,
        "expected max_dd_pct ≈ {}, got {}",
        expected_pct,
        max_dd_pct
    );
}

#[test]
fn drawdown_empty_curve_returns_zero() {
    let (max_dd, max_dd_pct) = max_drawdown_from_equity_curve(&[]);
    assert_eq!(max_dd, 0.0);
    assert_eq!(max_dd_pct, 0.0);
}
