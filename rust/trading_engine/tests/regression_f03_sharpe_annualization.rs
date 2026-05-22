//! F-03 regression: Sharpe ratio must be annualized using the timeframe of the
//! input candles (Crypto 24/7: H1 → sqrt(8760), D1 → sqrt(365), etc.) and must
//! be computed over equity-curve returns, not trade-PnL percentages.
//!
//! Spec §3.4 F-03:
//!   Sharpe = mean(returns) / stdev(returns) * sqrt(periods_per_year(tf))
//!   risk-free rate = 0 (Crypto, no benchmark), NOT configurable.
//!
//! The QA audit found Rust computing Sharpe over `trade.pnl_percent` with no
//! time annualization at all — these tests pin the corrected behaviour.
//!
//! All tests construct a returns stream with analytically known mean and
//! standard deviation, then assert the annualized Sharpe matches the closed
//! form within 1e-9.

use trading_engine::models::{annualized_sharpe, periods_per_year, Timeframe};

/// Alternating +δ, −δ around `mean` with even `n` → sample mean exactly `mean`,
/// sample stdev (population formula, /n) exactly `delta`.
fn construct_returns(mean: f64, delta: f64, n: usize) -> Vec<f64> {
    assert!(n % 2 == 0, "n must be even for exact sample stats");
    (0..n)
        .map(|i| if i % 2 == 0 { mean + delta } else { mean - delta })
        .collect()
}

#[test]
fn periods_per_year_matches_spec_table() {
    // Crypto 24/7 calendar — values are normative per Plan §3.4 F-03.
    assert_eq!(periods_per_year(Timeframe::M1), 525_600.0);
    assert_eq!(periods_per_year(Timeframe::M5), 105_120.0);
    assert_eq!(periods_per_year(Timeframe::M15), 35_040.0);
    assert_eq!(periods_per_year(Timeframe::H1), 8_760.0);
    assert_eq!(periods_per_year(Timeframe::H4), 2_190.0);
    assert_eq!(periods_per_year(Timeframe::D1), 365.0);
}

#[test]
fn h1_annualization_matches_closed_form() {
    let mean = 0.001;
    let delta = 0.002;
    let n = 8760; // exactly one year of hourly returns
    let returns = construct_returns(mean, delta, n);

    // Sanity: constructed sample stats are exact
    let sample_mean = returns.iter().sum::<f64>() / n as f64;
    let sample_var = returns.iter().map(|r| (r - sample_mean).powi(2)).sum::<f64>() / n as f64;
    let sample_stdev = sample_var.sqrt();
    assert!((sample_mean - mean).abs() < 1e-15);
    assert!((sample_stdev - delta).abs() < 1e-15);

    let got = annualized_sharpe(&returns, Timeframe::H1);
    let want = (mean / delta) * (8760.0_f64).sqrt();
    assert!(
        (got - want).abs() < 1e-9,
        "H1 sharpe got {}, want {}",
        got,
        want
    );
}

#[test]
fn each_timeframe_uses_its_own_annualization_factor() {
    // Identical returns stream, different timeframe annualization. Sharpe
    // must scale by sqrt(periods_per_year(tf)).
    let mean = 0.0005;
    let delta = 0.001;
    let n = 1000;
    let returns = construct_returns(mean, delta, n);

    for tf in [
        Timeframe::M1,
        Timeframe::M5,
        Timeframe::M15,
        Timeframe::H1,
        Timeframe::H4,
        Timeframe::D1,
    ] {
        let got = annualized_sharpe(&returns, tf);
        let want = (mean / delta) * periods_per_year(tf).sqrt();
        assert!(
            (got - want).abs() < 1e-9,
            "{:?} sharpe got {}, want {}",
            tf,
            got,
            want
        );
    }
}

#[test]
fn h1_sharpe_exceeds_d1_sharpe_for_same_returns() {
    // For an identical returns series, higher-frequency timeframes yield a
    // larger annualization factor, hence a larger annualized Sharpe.
    let returns = construct_returns(0.001, 0.002, 1000);
    let sharpe_h1 = annualized_sharpe(&returns, Timeframe::H1);
    let sharpe_d1 = annualized_sharpe(&returns, Timeframe::D1);
    assert!(
        sharpe_h1 > sharpe_d1,
        "expected H1 sharpe > D1 sharpe for same returns; got H1={}, D1={}",
        sharpe_h1,
        sharpe_d1
    );
    // Specifically: ratio is sqrt(8760/365) = sqrt(24) ≈ 4.899
    let ratio = sharpe_h1 / sharpe_d1;
    let want_ratio = (8760.0_f64 / 365.0_f64).sqrt();
    assert!((ratio - want_ratio).abs() < 1e-9);
}

#[test]
fn empty_returns_yield_zero_sharpe() {
    assert_eq!(annualized_sharpe(&[], Timeframe::H1), 0.0);
}

#[test]
fn zero_stdev_yields_zero_sharpe() {
    // Flat returns (no variance) → division by zero would be UB; we must
    // return 0 instead.
    let flat = vec![0.001_f64; 100];
    assert_eq!(annualized_sharpe(&flat, Timeframe::H1), 0.0);
}
