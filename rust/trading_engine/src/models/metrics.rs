//! Timeframe-aware performance metric helpers.
//!
//! Plan §3.4 F-03: annualized Sharpe must scale by `sqrt(periods_per_year(tf))`
//! where `periods_per_year` reflects the Crypto 24/7 calendar (no weekends,
//! no holidays). The risk-free rate is 0 (no benchmark exists for Crypto in
//! this context) and is NOT configurable.
//!
//! Returns must be **equity-curve returns** (one per candle close), not
//! trade-PnL percentages — see Plan §3.4 F-03 normative paragraph.

use crate::models::Timeframe;

/// Number of `tf`-sized periods in one Crypto 24/7 year.
///
/// Values for M1/M5/M15/H1/H4/D1 are normative per Plan §3.4 F-03.
/// M30 and W1 are not part of the spec table but are filled with the
/// natural extension so callers using the full `Timeframe` enum compile.
pub fn periods_per_year(tf: Timeframe) -> f64 {
    match tf {
        Timeframe::M1 => 525_600.0,  // 365 * 24 * 60
        Timeframe::M5 => 105_120.0,  // 525600 / 5
        Timeframe::M15 => 35_040.0,  // 525600 / 15
        Timeframe::M30 => 17_520.0,  // 525600 / 30
        Timeframe::H1 => 8_760.0,    // 365 * 24
        Timeframe::H4 => 2_190.0,    // 8760 / 4
        Timeframe::D1 => 365.0,
        Timeframe::W1 => 52.0,       // 365 / 7, rounded down
    }
}

/// Annualized Sharpe ratio of an equity-curve return series.
///
/// Formula (risk-free rate = 0):
///   sharpe = mean(returns) / stdev(returns) * sqrt(periods_per_year(tf))
///
/// Uses the population stdev (divide by `n`, not `n-1`) so both engines
/// produce bit-identical results. Returns 0 for empty input or when
/// `stdev == 0` (flat returns) to avoid NaN / Inf.
pub fn annualized_sharpe(returns: &[f64], tf: Timeframe) -> f64 {
    if returns.is_empty() {
        return 0.0;
    }
    // Detect mathematically-zero variance (all returns identical) without an
    // arbitrary epsilon — accumulating sum-of-squared-deviations from a
    // float-rounded mean would otherwise leave tens of ULPs of noise and
    // explode `mean / stdev` for a flat series.
    let (min, max) = returns
        .iter()
        .fold((f64::INFINITY, f64::NEG_INFINITY), |(lo, hi), &r| {
            (lo.min(r), hi.max(r))
        });
    if min == max {
        return 0.0;
    }
    let n = returns.len() as f64;
    let mean = returns.iter().sum::<f64>() / n;
    let variance = returns.iter().map(|r| (r - mean).powi(2)).sum::<f64>() / n;
    let stdev = variance.sqrt();
    if stdev == 0.0 {
        return 0.0;
    }
    (mean / stdev) * periods_per_year(tf).sqrt()
}

/// Convert an equity curve (one value per candle close) into per-candle
/// returns. Output length is `equity.len() - 1`. For an empty or
/// single-point curve, returns an empty vector.
///
/// Definition (matching the Dart engine):
///   ret[i] = (equity[i+1] - equity[i]) / equity[i]
///
/// If a point's equity is non-positive (degenerate path), that return is
/// recorded as 0.0 — that way a wipe-out doesn't inject NaN into Sharpe.
pub fn equity_curve_returns(equity: &[f64]) -> Vec<f64> {
    if equity.len() < 2 {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(equity.len() - 1);
    for i in 1..equity.len() {
        let prev = equity[i - 1];
        let ret = if prev > 0.0 {
            (equity[i] - prev) / prev
        } else {
            0.0
        };
        out.push(ret);
    }
    out
}
