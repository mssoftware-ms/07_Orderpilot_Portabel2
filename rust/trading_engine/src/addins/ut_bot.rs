//! UT Bot Alerts Strategy Add-in (verbesserte Variante).
//!
//! Phase-2 implementation of the strategy described in
//! `01_Projectplan/specs/ut_bot_spec.md` (verbesserte Variante per §1):
//! EMA(200) trend filter + UT-Bot ATR-trail direction flip + Stochastic
//! Momentum Index cross trigger, with swing-low/high SL placement,
//! R:R 1:2 take-profit and engine-driven break-even trail at +1R
//! (BacktestEngine D-08 mechanic, no strategy-side intra-trade management).
//!
//! # Module layout
//!
//! Welle U1 lands the ATR helper only. Welle U2 extends this module with
//! the SMI helper, the UT-Bot trail-state helper, the session filter, and
//! the full [`StrategyAddin`] implementation. Helpers are kept local to
//! this file per QA decision F1 (lokal mit TODO-Marker); a shared
//! `addins/indicators.rs` refactor is deferred to the third strategy.

// TODO(phase-3): once a third strategy (e.g. Ichimoku) is implemented,
// extract `calc_atr`, `calc_smi`, `update_ut_bot_trail`, and the session
// filter into a shared `rust/trading_engine/src/addins/indicators.rs`
// module to avoid duplication across strategies (Spec §12.2 / engineering
// plan §3 Frage 1 + Frage 4).

// ─── Indicator helpers (pure functions) ─────────────────────────────────────

/// Compute the Average True Range (ATR) series with Wilder's smoothing.
///
/// Convention (locked for Dart↔Rust parity, mirrors `calculateAtr` in
/// `lib/services/indicators.dart`):
///
/// - True Range per bar:
///   - `tr[0] = high[0] - low[0]` (no prior close available; matches the
///     TradingView `ta.atr()` and QuantNomad UT-Bot-Alerts conventions)
///   - `tr[i] = max(high[i] - low[i], |high[i] - close[i-1]|,
///                  |low[i] - close[i-1]|)` for `i >= 1`
/// - Initial ATR is the simple average of the first `period` TR values:
///   `atr[period - 1] = mean(tr[0..period])`. Indices `0..period - 1` are
///   set to `f64::NAN` to flag the warm-up region (callers must use
///   `is_nan()` to skip).
/// - Wilder smoothing for subsequent bars:
///   `atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period`
///
/// Returns `None` if `period == 0`, if the input slices have mismatched
/// lengths, or if there are fewer than `period` candles. Otherwise the
/// returned `Vec<f64>` has the same length as `closes`.
pub fn calc_atr(
    highs: &[f64],
    lows: &[f64],
    closes: &[f64],
    period: usize,
) -> Option<Vec<f64>> {
    if period == 0 {
        return None;
    }
    if highs.len() != closes.len() || lows.len() != closes.len() {
        return None;
    }
    let n = closes.len();
    if n < period {
        return None;
    }

    // True Range per bar — TR[0] is the seed (high - low only).
    let mut tr = vec![0.0f64; n];
    tr[0] = highs[0] - lows[0];
    for i in 1..n {
        let hl = highs[i] - lows[i];
        let hpc = (highs[i] - closes[i - 1]).abs();
        let lpc = (lows[i] - closes[i - 1]).abs();
        tr[i] = hl.max(hpc).max(lpc);
    }

    // Warm-up: indices 0..period-1 are NaN, atr[period-1] = mean(tr[0..period]).
    let mut atr = vec![f64::NAN; n];
    let mut sum = 0.0;
    for &v in &tr[..period] {
        sum += v;
    }
    atr[period - 1] = sum / period as f64;

    // Wilder smoothing for the remainder.
    for i in period..n {
        atr[i] = (atr[i - 1] * (period as f64 - 1.0) + tr[i]) / period as f64;
    }

    Some(atr)
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── ATR helper tests ────────────────────────────────────────────────

    #[test]
    fn test_atr_zero_period() {
        assert!(calc_atr(&[1.0], &[1.0], &[1.0], 0).is_none());
    }

    #[test]
    fn test_atr_insufficient_data() {
        // 3 closes, period 5 → None (mirrors calc_rsi convention).
        let h = vec![1.0, 2.0, 3.0];
        let l = vec![0.5, 1.5, 2.5];
        let c = vec![0.8, 1.8, 2.8];
        assert!(calc_atr(&h, &l, &c, 5).is_none());
    }

    #[test]
    fn test_atr_mismatched_lengths_return_none() {
        let h = vec![1.0, 2.0, 3.0];
        let l = vec![0.5, 1.5];
        let c = vec![0.8, 1.8, 2.8];
        assert!(calc_atr(&h, &l, &c, 2).is_none());
    }

    #[test]
    fn test_atr_constant_tr_converges_to_tr_value() {
        // Engineering-plan §2 Welle-U1 test #2: with TR ≡ 1.0 for every bar,
        // ATR equals 1.0 from the first valid index onward (no recursion
        // can drift it away from a constant input).
        //
        // Fixture construction: open == close == constant, so for i >= 1
        //   high[i] - low[i]              = 1.0
        //   |high[i] - close[i-1]|        = 0.5
        //   |low[i]  - close[i-1]|        = 0.5
        //   → tr[i] = max(1.0, 0.5, 0.5) = 1.0
        // and tr[0] = high[0] - low[0] = 1.0 as well.
        let n = 20;
        let highs: Vec<f64> = (0..n).map(|_| 100.5).collect();
        let lows: Vec<f64> = (0..n).map(|_| 99.5).collect();
        let closes: Vec<f64> = (0..n).map(|_| 100.0).collect();
        let period = 5;
        let atr = calc_atr(&highs, &lows, &closes, period).unwrap();
        assert_eq!(atr.len(), n);
        // Warm-up: NaN for indices 0..period-1.
        for v in atr.iter().take(period - 1) {
            assert!(v.is_nan(), "warm-up index expected NaN, got {}", v);
        }
        // From period-1 onwards: ATR == 1.0 (constant TR converges instantly).
        for v in atr.iter().skip(period - 1) {
            assert!((v - 1.0).abs() < 1e-12, "ATR expected 1.0, got {}", v);
        }
    }

    #[test]
    fn test_atr_step_function_converges_exponentially() {
        // Engineering-plan §2 Welle-U1 test #3: TR=1.0 for the first
        // `period` bars, then TR=2.0. ATR converges towards 2.0 with
        // recursion factor (period-1)/period per bar — verify the first
        // few smoothed values analytically.
        //
        // Same fixture trick as the constant-TR test: bars 0..N use
        // body=0, range=1.0; bars N.. use body=0, range=2.0. The 1→2
        // step is taken on the FIRST step bar — for that bar
        //   |high[i] - close[i-1]| = (101.0 - 100.0) = 1.0
        //   |low[i]  - close[i-1]| = (99.0 - 100.0).abs() = 1.0
        //   high - low             = 2.0
        //   → tr = 2.0 from the step onwards. (close stays at 100.0 because
        //     the high/low band widens symmetrically around it.)
        let period = 5;
        let n = 20;
        let mut highs = Vec::with_capacity(n);
        let mut lows = Vec::with_capacity(n);
        let mut closes = Vec::with_capacity(n);
        for i in 0..n {
            let half = if i < period { 0.5 } else { 1.0 };
            highs.push(100.0 + half);
            lows.push(100.0 - half);
            closes.push(100.0);
        }
        let atr = calc_atr(&highs, &lows, &closes, period).unwrap();
        // atr[period-1] = mean(tr[0..period]) = mean of five 1.0s = 1.0
        assert!((atr[period - 1] - 1.0).abs() < 1e-12);
        // atr[period]   = (atr[period-1] * (period-1) + tr[period]) / period
        //               = (1.0 * 4 + 2.0) / 5 = 6/5 = 1.2
        assert!((atr[period] - 1.2).abs() < 1e-12);
        // atr[period+1] = (1.2 * 4 + 2.0) / 5 = 6.8 / 5 = 1.36
        assert!((atr[period + 1] - 1.36).abs() < 1e-12);
        // atr[period+2] = (1.36 * 4 + 2.0) / 5 = 7.44 / 5 = 1.488
        assert!((atr[period + 2] - 1.488).abs() < 1e-12);
        // Long-run check: monotonically approaches 2.0 from below.
        for i in (period + 1)..n {
            assert!(atr[i] > atr[i - 1], "ATR must rise toward 2.0");
            assert!(atr[i] < 2.0);
        }
    }

    #[test]
    fn test_atr_period_equals_length_returns_seed_only() {
        // `closes.len() == period` → only one valid ATR value at index
        // period-1 (the seed), no Wilder steps applied. Mirrors the
        // calc_ema convention "result equals seed SMA when history == period".
        let h = vec![10.5, 11.5, 12.5, 13.5, 14.5];
        let l = vec![9.5, 10.5, 11.5, 12.5, 13.5];
        let c = vec![10.0, 11.0, 12.0, 13.0, 14.0];
        let period = 5;
        let atr = calc_atr(&h, &l, &c, period).unwrap();
        // tr[0] = 1.0 (high-low), tr[1..] = max(1.0, |11.5-10|, |10.5-10|)
        //       = max(1.0, 1.5, 0.5) = 1.5, and same 1.5 for bars 2..4.
        // mean(tr[0..5]) = (1.0 + 1.5*4) / 5 = 7/5 = 1.4
        for v in atr.iter().take(period - 1) {
            assert!(v.is_nan());
        }
        assert!((atr[period - 1] - 1.4).abs() < 1e-12, "got {}", atr[period - 1]);
    }

    #[test]
    fn test_atr_period_one_equals_tr_per_bar() {
        // Edge case: period=1 means ATR equals TR for every bar from index
        // 0 onwards (no warm-up, no smoothing). Useful for the UT-Bot
        // verbesserte-Variante default (`atr_period = 1` per spec §1).
        let h = vec![101.0, 102.0, 103.5];
        let l = vec![99.0, 100.5, 100.0];
        let c = vec![100.0, 101.0, 102.0];
        let atr = calc_atr(&h, &l, &c, 1).unwrap();
        assert_eq!(atr.len(), 3);
        // tr[0] = 101 - 99 = 2.0
        assert!((atr[0] - 2.0).abs() < 1e-12);
        // tr[1] = max(1.5, |102-100|=2.0, |100.5-100|=0.5) = 2.0
        assert!((atr[1] - 2.0).abs() < 1e-12);
        // tr[2] = max(3.5, |103.5-101|=2.5, |100-101|=1.0) = 3.5
        assert!((atr[2] - 3.5).abs() < 1e-12);
    }

    #[test]
    fn test_atr_tr_seeded_from_high_low_when_no_prev_close() {
        // Pin TR[0] convention: first-bar TR uses high-low only (no
        // prev-close fallback). This matches TradingView `ta.atr()` and
        // QuantNomad's UT-Bot-Alerts Pinescript source. Pre-existing
        // closes "before the first candle" are not part of the input
        // contract — TR[0] must be deterministic from highs[0]/lows[0]
        // alone so the strategy seeds reproducibly across runs.
        let h = vec![105.0, 106.0];
        let l = vec![95.0, 104.0];
        let c = vec![100.0, 105.5];
        let atr = calc_atr(&h, &l, &c, 2).unwrap();
        // tr[0] = 105 - 95 = 10.0
        // tr[1] = max(2.0, |106 - 100| = 6.0, |104 - 100| = 4.0) = 6.0
        // atr[1] = mean(tr[0..2]) = (10 + 6) / 2 = 8.0
        assert!((atr[1] - 8.0).abs() < 1e-12, "got {}", atr[1]);
    }
}
