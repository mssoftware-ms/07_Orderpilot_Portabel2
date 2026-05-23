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

/// Compute an EMA series over `values` with explicit warm-up start.
///
/// The first `start + period - 1` output indices are `NaN` (gathering
/// seed values); `out[start + period - 1]` equals the SMA seed
/// `mean(values[start..start + period])`; subsequent indices apply the
/// standard EMA recursion `ema = alpha * v + (1 - alpha) * ema` with
/// `alpha = 2 / (period + 1)`. Matches the SMA-seeded convention of
/// [`calc_ema`](crate::addins::bb_rsi::calc_ema) and Pinescript's
/// `ta.ema` (which seeds with `ta.sma(source, length)` on the first
/// bar). Caller is responsible for ensuring `values[start..start + period]`
/// contains no `NaN`s — otherwise the seed itself becomes `NaN` and
/// every downstream sample stays `NaN`.
///
/// Returns an all-`NaN` vec when `period == 0` or `start + period > n`.
fn ema_series_from(values: &[f64], period: usize, start: usize) -> Vec<f64> {
    let n = values.len();
    let mut out = vec![f64::NAN; n];
    if period == 0 || start + period > n {
        return out;
    }
    let alpha = 2.0 / (period as f64 + 1.0);
    let mut ema = 0.0;
    for &v in &values[start..start + period] {
        ema += v;
    }
    ema /= period as f64;
    out[start + period - 1] = ema;
    for i in (start + period)..n {
        ema = alpha * values[i] + (1.0 - alpha) * ema;
        out[i] = ema;
    }
    out
}

/// Compute the Stochastic Momentum Index (SMI, Blau 1993) and its
/// EMA signal line over a candle stream.
///
/// Variant: TradingView Pinescript-standard double-EMA-smoothed SMI per
/// `01_Projectplan/specs/ut_bot_spec.md` §12.4 (Blau-1993-Standard with
/// three free parameters: `length`, `k_smoothing`, `d_smoothing`).
///
/// Formula (locked for Dart↔Rust parity, mirrors `calcSmi` in
/// `lib/services/indicators.dart`):
///
/// ```text
/// hh[i]   = highest(high, length) over the last `length` bars (inclusive)
/// ll[i]   = lowest(low,  length)
/// mid[i]  = (hh[i] + ll[i]) / 2
/// diff[i] = close[i] - mid[i]
/// rng[i]  = hh[i] - ll[i]
///
/// dk  = EMA(diff, k_smoothing)
/// dkd = EMA(dk,   d_smoothing)
/// rk  = EMA(rng,  k_smoothing)
/// rkd = EMA(rk,   d_smoothing)
///
/// smi[i]    = 200 * dkd[i] / rkd[i]              (NaN where rkd == 0)
/// signal[i] = EMA(smi, d_smoothing)               (uses d_smoothing again
///                                                   per QuantNomad / Blau
///                                                   defaults; spec §12.4
///                                                   does not introduce a
///                                                   separate signal_length)
/// ```
///
/// Returns `None` if any period is zero, if input slices have mismatched
/// lengths, or if there is not enough data to seed the SMI itself
/// (warm-up = `length - 1 + k_smoothing - 1 + d_smoothing - 1`). The
/// signal line requires `d_smoothing - 1` additional bars on top of that.
///
/// Returned tuple is `(smi, signal)`, each a `Vec<f64>` of length
/// `closes.len()` with `NaN` in the warm-up region.
#[allow(clippy::type_complexity)]
pub fn calc_smi(
    highs: &[f64],
    lows: &[f64],
    closes: &[f64],
    length: usize,
    k_smoothing: usize,
    d_smoothing: usize,
) -> Option<(Vec<f64>, Vec<f64>)> {
    if length == 0 || k_smoothing == 0 || d_smoothing == 0 {
        return None;
    }
    if highs.len() != closes.len() || lows.len() != closes.len() {
        return None;
    }
    let n = closes.len();
    // SMI warm-up: length-1 (diff/rng seed) + k_smoothing-1 (first EMA)
    // + d_smoothing-1 (second EMA). At that index the first SMI value is
    // available; signal[smi_start + d_smoothing - 1] is the first signal.
    let smi_start = length
        .saturating_sub(1)
        .saturating_add(k_smoothing.saturating_sub(1))
        .saturating_add(d_smoothing.saturating_sub(1));
    if n <= smi_start {
        return None;
    }

    // Step 1: per-bar diff (close - midpoint) and range (HH - LL).
    let mut diff = vec![f64::NAN; n];
    let mut rng = vec![f64::NAN; n];
    for i in (length - 1)..n {
        let win_h = &highs[i + 1 - length..=i];
        let win_l = &lows[i + 1 - length..=i];
        let hh = win_h.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let ll = win_l.iter().copied().fold(f64::INFINITY, f64::min);
        diff[i] = closes[i] - (hh + ll) / 2.0;
        rng[i] = hh - ll;
    }

    // Step 2: double-EMA smooth both series.
    let diff_k = ema_series_from(&diff, k_smoothing, length - 1);
    let diff_kd =
        ema_series_from(&diff_k, d_smoothing, length - 1 + k_smoothing - 1);
    let rng_k = ema_series_from(&rng, k_smoothing, length - 1);
    let rng_kd =
        ema_series_from(&rng_k, d_smoothing, length - 1 + k_smoothing - 1);

    // Step 3: SMI = 200 * diff_kd / rng_kd, NaN-safe.
    let mut smi = vec![f64::NAN; n];
    for i in smi_start..n {
        let dkd = diff_kd[i];
        let rkd = rng_kd[i];
        if !dkd.is_nan() && !rkd.is_nan() && rkd > 0.0 {
            smi[i] = 200.0 * dkd / rkd;
        }
    }

    // Step 4: signal = EMA(SMI, d_smoothing), starting from the first
    // valid SMI index.
    let signal = ema_series_from(&smi, d_smoothing, smi_start);

    Some((smi, signal))
}

/// Compute the UT Bot ATR-trailing-stop line and per-bar direction
/// (close-vs-trail bias) over a candle stream.
///
/// Pinescript reference (QuantNomad's "UT Bot Alerts", abridged):
///
/// ```text
/// nLoss = key_value * ATR(atr_period)
/// trail[i] = max(trail[i-1], close[i] - nLoss)   if close[i] > trail[i-1] AND close[i-1] > trail[i-1]
///          = min(trail[i-1], close[i] + nLoss)   if close[i] < trail[i-1] AND close[i-1] < trail[i-1]
///          = close[i] - nLoss                     if close[i] > trail[i-1] (else)
///          = close[i] + nLoss                     if close[i] < trail[i-1] (else)
/// direction[i] = +1 if close > trail[i]
///              = -1 if close < trail[i]
///              =  0 (warm-up only — NaN ATR; tied scenarios inherit prev)
/// ```
///
/// Seeding follows the Pinescript `nz(xATRTrailingStop[1], 0)` convention:
/// at the first bar where ATR is valid we have no prior trail, but with
/// `prev_trail = 0` and positive prices the `else if close > prev_trail`
/// branch fires → `trail[seed] = close - nLoss`. We adopt this seed
/// directly so the helper is deterministic from the first valid ATR
/// index without needing a hidden `nz` default in every comparison.
///
/// Returns `None` if `closes.len() != atr.len()` or no valid ATR exists.
///
/// Convention locked for Dart↔Rust parity (mirror lands in
/// `lib/services/indicators.dart` `calcUtBotTrail`).
pub fn calc_ut_bot_trail(
    closes: &[f64],
    atr: &[f64],
    key_value: f64,
) -> Option<(Vec<f64>, Vec<i8>)> {
    if closes.len() != atr.len() {
        return None;
    }
    let n = closes.len();
    if n == 0 {
        return None;
    }

    let mut trail = vec![f64::NAN; n];
    let mut direction = vec![0i8; n];

    // First valid ATR index — anything before that is warm-up.
    let first_valid = atr.iter().position(|v| !v.is_nan())?;
    if first_valid >= n {
        return None;
    }

    // Seed: with `prev_trail = 0` (nz default in Pinescript) and a
    // positive close, the third branch of the iff-chain fires:
    // trail = close - nLoss. Direction is +1 because close > trail
    // (since nLoss = key_value * ATR is non-negative).
    let n_loss_seed = key_value * atr[first_valid];
    trail[first_valid] = closes[first_valid] - n_loss_seed;
    direction[first_valid] = if closes[first_valid] > trail[first_valid] {
        1
    } else if closes[first_valid] < trail[first_valid] {
        -1
    } else {
        0
    };

    for i in (first_valid + 1)..n {
        let nloss = key_value * atr[i];
        let prev_trail = trail[i - 1];
        let close = closes[i];
        let prev_close = closes[i - 1];

        let new_trail = if close > prev_trail && prev_close > prev_trail {
            (close - nloss).max(prev_trail)
        } else if close < prev_trail && prev_close < prev_trail {
            (close + nloss).min(prev_trail)
        } else if close > prev_trail {
            close - nloss
        } else {
            // close <= prev_trail (treats equality as "below" per the
            // Pinescript fall-through; flip-detection still works since
            // a true cross sets close strictly on the other side).
            close + nloss
        };

        trail[i] = new_trail;
        direction[i] = if close > new_trail {
            1
        } else if close < new_trail {
            -1
        } else {
            // close exactly == trail (rare float coincidence) — inherit
            // previous direction so cross detection is not falsely
            // triggered by a tie.
            direction[i - 1]
        };
    }

    Some((trail, direction))
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

    // ── SMI helper tests ────────────────────────────────────────────────

    #[test]
    fn test_smi_zero_period_returns_none() {
        let h = vec![1.0; 5];
        let l = vec![0.5; 5];
        let c = vec![0.7; 5];
        assert!(calc_smi(&h, &l, &c, 0, 2, 2).is_none());
        assert!(calc_smi(&h, &l, &c, 3, 0, 2).is_none());
        assert!(calc_smi(&h, &l, &c, 3, 2, 0).is_none());
    }

    #[test]
    fn test_smi_mismatched_lengths_return_none() {
        let h = vec![1.0, 2.0, 3.0];
        let l = vec![0.5, 1.5];
        let c = vec![0.7, 1.7, 2.7];
        assert!(calc_smi(&h, &l, &c, 2, 1, 1).is_none());
    }

    #[test]
    fn test_smi_insufficient_data_returns_none() {
        // length=3, k=2, d=2 → smi_start = 2+1+1 = 4 → need at least 5 bars
        let h = vec![1.0, 2.0, 3.0, 4.0];
        let l = vec![0.5, 1.5, 2.5, 3.5];
        let c = vec![0.8, 1.8, 2.8, 3.8];
        assert!(calc_smi(&h, &l, &c, 3, 2, 2).is_none());
    }

    #[test]
    fn test_smi_zero_at_perfect_midrange() {
        // Constant range with close exactly at the midpoint: diff is 0,
        // so SMI is 0 (numerator 0, denominator > 0). Engineering plan §2
        // Welle U2 test list: "konstanter Range mit close in der Mitte
        // → SMI ≈ 0".
        let n = 20;
        let highs = vec![101.0; n];
        let lows = vec![99.0; n];
        let closes = vec![100.0; n];
        let (smi, _signal) = calc_smi(&highs, &lows, &closes, 5, 3, 3).unwrap();
        // smi_start = 5-1 + 3-1 + 3-1 = 8 → first valid SMI at index 8.
        for (i, &v) in smi.iter().enumerate().skip(8) {
            assert!(v.abs() < 1e-12, "SMI at {}: {}", i, v);
        }
    }

    #[test]
    fn test_smi_positive_in_uptrend() {
        // Monotonically rising closes → close trends above the midpoint
        // of (HH, LL), so diff > 0 and SMI > 0.
        let n = 50;
        let highs: Vec<f64> = (0..n).map(|i| 100.0 + i as f64 + 0.5).collect();
        let lows: Vec<f64> = (0..n).map(|i| 100.0 + i as f64 - 0.5).collect();
        let closes: Vec<f64> = (0..n).map(|i| 100.0 + i as f64).collect();
        let (smi, _signal) =
            calc_smi(&highs, &lows, &closes, 10, 5, 3).unwrap();
        // smi_start = 9+4+2 = 15. After 15 the SMI must settle positive.
        // Allow a small tolerance for the initial Wilder ramp.
        for (i, &v) in smi.iter().enumerate().skip(30) {
            assert!(v > 0.0, "SMI at {} expected > 0, got {}", i, v);
        }
    }

    #[test]
    fn test_smi_negative_in_downtrend() {
        // Monotonically falling closes → mirror of the uptrend test.
        let n = 50;
        let highs: Vec<f64> =
            (0..n).map(|i| 200.0 - i as f64 + 0.5).collect();
        let lows: Vec<f64> =
            (0..n).map(|i| 200.0 - i as f64 - 0.5).collect();
        let closes: Vec<f64> = (0..n).map(|i| 200.0 - i as f64).collect();
        let (smi, _signal) =
            calc_smi(&highs, &lows, &closes, 10, 5, 3).unwrap();
        for (i, &v) in smi.iter().enumerate().skip(30) {
            assert!(v < 0.0, "SMI at {} expected < 0, got {}", i, v);
        }
    }

    #[test]
    fn test_smi_bounded_by_minus_200_to_200() {
        // SMI is bounded by ±200 by construction (numerator |diff_kd|
        // can never exceed rkd/2 by the highest/lowest range definition).
        let n = 60;
        let mut highs = Vec::with_capacity(n);
        let mut lows = Vec::with_capacity(n);
        let mut closes = Vec::with_capacity(n);
        for i in 0..n {
            let phase = (i as f64) * 0.4;
            let price = 100.0 + 10.0 * phase.sin();
            highs.push(price + 0.5);
            lows.push(price - 0.5);
            closes.push(price);
        }
        let (smi, _) = calc_smi(&highs, &lows, &closes, 10, 5, 3).unwrap();
        for v in smi.iter().filter(|v| !v.is_nan()) {
            assert!(v.abs() <= 200.0 + 1e-9, "SMI out of bounds: {}", v);
        }
    }

    #[test]
    fn test_smi_known_values_small_fixture() {
        // Hand-computed reference (also enforced bit-exact by the Dart
        // mirror in `test/services/indicators_test.dart`):
        //
        // length=3, k=2, d=2.
        // Bars 0..9 with body=0 (open==close==listed), tight ±1.0 wicks
        // around the close so HH/LL inside the window collapse to the
        // close itself ±0/±1 depending on the position in the window.
        //
        // Closes:  [100, 101, 102, 103, 104, 103, 102, 101, 100, 99]
        // Highs:   close + 1.0
        // Lows:    close - 1.0
        //
        // Resulting first valid SMI at index 4 = 50.0; subsequent values
        // computed below by walking the double-EMA chain by hand. See
        // commit message for the full derivation.
        let closes: Vec<f64> = (0..10)
            .map(|i| if i <= 4 { 100.0 + i as f64 } else { 100.0 + (8 - i) as f64 })
            .collect();
        let highs: Vec<f64> = closes.iter().map(|c| c + 1.0).collect();
        let lows: Vec<f64> = closes.iter().map(|c| c - 1.0).collect();

        let (smi, signal) = calc_smi(&highs, &lows, &closes, 3, 2, 2).unwrap();
        // smi_start = 2 + 1 + 1 = 4
        for v in smi.iter().take(4) {
            assert!(v.is_nan());
        }
        // Reference values derived analytically (HH/LL window
        // [i-2..=i]; close 100,101,102,103,104,103,102,101,100,99;
        // diff/rng walked through two EMA(2) passes; SMI = 200 * dkd/rkd).
        // Tolerance 1e-9 — locks bit-parity contract with the Dart mirror.
        assert!((smi[4] - 50.0).abs() < 1e-9, "smi[4] = {}", smi[4]);
        assert!((smi[5] - 18.75).abs() < 1e-9, "smi[5] = {}", smi[5]);
        assert!((smi[6] - (-18.0)).abs() < 1e-9, "smi[6] = {}", smi[6]);
        assert!(
            (smi[7] - (-36.538_461_538_461_54)).abs() < 1e-9,
            "smi[7] = {}",
            smi[7]
        );
        assert!(
            (smi[8] - (-44.560_669_456_066_95)).abs() < 1e-9,
            "smi[8] = {}",
            smi[8]
        );
        assert!(
            (smi[9] - (-47.859_116_022_099_45)).abs() < 1e-9,
            "smi[9] = {}",
            smi[9]
        );

        // Signal: EMA(SMI, 2) starting at index 4 → first valid at index 5.
        // signal[5] = mean(smi[4..6]) = (50 + 18.75) / 2 = 34.375
        // signal[6] = (2/3)*-18 + (1/3)*34.375 = -12 + 11.458333... = -0.5416666...
        for v in signal.iter().take(5) {
            assert!(v.is_nan());
        }
        assert!((signal[5] - 34.375).abs() < 1e-9, "signal[5] = {}", signal[5]);
        assert!(
            (signal[6] - (-0.541_666_666_666_666_5)).abs() < 1e-9,
            "signal[6] = {}",
            signal[6]
        );
        assert!(
            (signal[7] - (-24.539_529_914_529_92)).abs() < 1e-9,
            "signal[7] = {}",
            signal[7]
        );
        assert!(
            (signal[8] - (-37.886_956_275_552_57)).abs() < 1e-9,
            "signal[8] = {}",
            signal[8]
        );
        assert!(
            (signal[9] - (-44.535_062_773_250_49)).abs() < 1e-9,
            "signal[9] = {}",
            signal[9]
        );
    }

    #[test]
    fn test_smi_signal_lags_smi_in_uptrend() {
        // The signal line is an EMA of the SMI, so it must lag behind
        // the SMI itself during a rising SMI phase (signal <= smi).
        let n = 60;
        let highs: Vec<f64> = (0..n).map(|i| 100.0 + i as f64 + 0.5).collect();
        let lows: Vec<f64> = (0..n).map(|i| 100.0 + i as f64 - 0.5).collect();
        let closes: Vec<f64> = (0..n).map(|i| 100.0 + i as f64).collect();
        let (smi, signal) =
            calc_smi(&highs, &lows, &closes, 10, 5, 3).unwrap();
        // After the warm-up plus a few bars of ramp, signal should be
        // consistently below smi in this monotonic uptrend.
        for i in 30..n {
            assert!(
                signal[i] <= smi[i] + 1e-9,
                "signal {} > smi {} at index {}",
                signal[i],
                smi[i],
                i
            );
        }
    }

    // ── UT-Bot trail helper tests ───────────────────────────────────────

    #[test]
    fn test_trail_mismatched_lengths_returns_none() {
        let closes = vec![100.0, 101.0, 102.0];
        let atr = vec![1.0, 1.0];
        assert!(calc_ut_bot_trail(&closes, &atr, 2.0).is_none());
    }

    #[test]
    fn test_trail_empty_returns_none() {
        let closes: Vec<f64> = vec![];
        let atr: Vec<f64> = vec![];
        assert!(calc_ut_bot_trail(&closes, &atr, 2.0).is_none());
    }

    #[test]
    fn test_trail_all_nan_atr_returns_none() {
        let closes = vec![100.0, 101.0, 102.0];
        let atr = vec![f64::NAN, f64::NAN, f64::NAN];
        assert!(calc_ut_bot_trail(&closes, &atr, 2.0).is_none());
    }

    #[test]
    fn test_trail_seed_at_first_valid_atr() {
        // ATR warm-up: NaN for index 0, 1.0 from index 1 onward.
        // key_value = 2.0 → nLoss = 2.0. Seed trail at index 1 should be
        // close[1] - nLoss = 101 - 2 = 99. Direction = +1 (close above trail).
        // Index 0 is warm-up (NaN trail, 0 direction).
        let closes = vec![100.0, 101.0];
        let atr = vec![f64::NAN, 1.0];
        let (trail, direction) = calc_ut_bot_trail(&closes, &atr, 2.0).unwrap();
        assert!(trail[0].is_nan());
        assert_eq!(direction[0], 0);
        assert!((trail[1] - 99.0).abs() < 1e-12);
        assert_eq!(direction[1], 1);
    }

    #[test]
    fn test_trail_monotone_in_uptrend() {
        // Closes rise +1 per bar, ATR constant 1.0, key=1.0 → nLoss=1.0.
        // Every bar satisfies `close > prev_trail AND prev_close > prev_trail`
        // after the seed, so trail = max(prev_trail, close - 1) and must
        // rise monotonically. Direction stays +1 throughout.
        let n = 20;
        let closes: Vec<f64> = (0..n).map(|i| 100.0 + i as f64).collect();
        let atr = vec![1.0; n];
        let (trail, direction) = calc_ut_bot_trail(&closes, &atr, 1.0).unwrap();
        // Seed at index 0: trail = 100 - 1 = 99, direction = +1.
        assert!((trail[0] - 99.0).abs() < 1e-12);
        assert_eq!(direction[0], 1);
        for i in 1..n {
            assert!(trail[i] >= trail[i - 1] - 1e-12,
                "trail must be monotone non-decreasing in uptrend at {}: {} → {}",
                i, trail[i - 1], trail[i]);
            assert_eq!(direction[i], 1, "direction must stay +1 in uptrend");
        }
    }

    #[test]
    fn test_trail_monotone_in_downtrend() {
        // Closes fall -1 per bar, ATR constant 1.0. At seed close=200 →
        // trail=199, direction=+1. On the next bar close=199 → not >
        // prev_trail (199 == 199, "else if close > prev_trail" fires false),
        // first branch fails (close not > prev_trail). Lands in the
        // fall-through `else` branch: trail = close + nLoss = 199 + 1 = 200.
        // Direction = -1 (close=199 < trail=200). From there on the
        // second branch (close < prev_trail AND prev_close < prev_trail)
        // applies and trail = min(prev_trail, close + 1) → monotone down.
        let n = 20;
        let closes: Vec<f64> = (0..n).map(|i| 200.0 - i as f64).collect();
        let atr = vec![1.0; n];
        let (trail, direction) = calc_ut_bot_trail(&closes, &atr, 1.0).unwrap();
        assert!((trail[0] - 199.0).abs() < 1e-12);
        assert_eq!(direction[0], 1);
        // Flip on bar 1.
        assert!((trail[1] - 200.0).abs() < 1e-12, "trail[1] = {}", trail[1]);
        assert_eq!(direction[1], -1);
        // After the flip, trail must be monotone non-increasing.
        for i in 2..n {
            assert!(trail[i] <= trail[i - 1] + 1e-12,
                "trail must be monotone non-increasing in downtrend at {}: {} → {}",
                i, trail[i - 1], trail[i]);
            assert_eq!(direction[i], -1, "direction must stay -1 in downtrend");
        }
    }

    #[test]
    fn test_trail_long_to_short_flip() {
        // Sustained uptrend then sharp crash below trail → direction flip.
        // Closes: 100, 101, 102, 103, 104, 80
        // ATR=1.0 constant, key=2.0 → nLoss=2.0.
        // Seed (i=0): trail = 100 - 2 = 98, dir = +1.
        // i=1: close=101 > prev_trail=98 AND prev_close=100 > 98
        //   → trail = max(98, 101-2) = 99, dir = +1.
        // i=2: close=102, prev_trail=99 → max(99, 100) = 100, dir = +1.
        // i=3: trail = max(100, 101) = 101, dir = +1.
        // i=4: trail = max(101, 102) = 102, dir = +1.
        // i=5: close=80 < prev_trail=102 AND prev_close=104 > 102 → fall
        //   through to "else if close > prev_trail" (false, 80 < 102) →
        //   final else: trail = close + nLoss = 80 + 2 = 82, dir = -1.
        let closes = vec![100.0, 101.0, 102.0, 103.0, 104.0, 80.0];
        let atr = vec![1.0; 6];
        let (trail, direction) = calc_ut_bot_trail(&closes, &atr, 2.0).unwrap();
        assert_eq!(direction, vec![1, 1, 1, 1, 1, -1]);
        assert!((trail[4] - 102.0).abs() < 1e-12);
        assert!((trail[5] - 82.0).abs() < 1e-12, "trail[5] = {}", trail[5]);
    }

    #[test]
    fn test_trail_short_to_long_flip() {
        // Mirror of the long-to-short flip:
        // Closes: 100, 99, 98, 97, 96, 120
        // Seed (i=0): trail = 100 - 2 = 98, dir = +1.
        // i=1: close=99 > prev_trail=98 AND prev_close=100 > 98 → first
        //   branch: trail = max(98, 99-2=97) = 98. close=99 vs trail=98 →
        //   dir still +1. trail stayed at 98.
        // i=2: close=98 > prev_trail=98? FALSE (98 == 98, strict >). Falls
        //   into elif close > prev_trail (false), then elif close < prev_trail
        //   AND prev_close < prev_trail (also false: 98 == 98). Falls to
        //   else: trail = close + nLoss = 100, dir = -1.
        // i=3: close=97 < 100 AND prev_close=98 < 100 → second branch:
        //   trail = min(100, 97+2=99) = 99. dir = -1 (97 < 99).
        // i=4: close=96 < 99 AND prev_close=97 < 99 → min(99, 98) = 98, dir=-1.
        // i=5: close=120 > 98 AND prev_close=96 < 98 → first branch FAILS
        //   (prev_close 96 not > prev_trail 98). elif close > prev_trail
        //   (true: 120 > 98) → trail = 120 - 2 = 118, dir = +1.
        let closes = vec![100.0, 99.0, 98.0, 97.0, 96.0, 120.0];
        let atr = vec![1.0; 6];
        let (trail, direction) = calc_ut_bot_trail(&closes, &atr, 2.0).unwrap();
        assert_eq!(direction, vec![1, 1, -1, -1, -1, 1]);
        assert!((trail[5] - 118.0).abs() < 1e-12, "trail[5] = {}", trail[5]);
    }

    #[test]
    fn test_trail_known_values_small_fixture() {
        // Hand-computed reference shared bit-for-bit with the Dart mirror.
        // closes: [100, 102, 101, 103, 99, 100, 105, 104]
        // atr:    1.0 constant
        // key:    1.5 → nLoss = 1.5
        //
        // i=0 seed: trail = 100 - 1.5 = 98.5, dir = +1
        // i=1: close=102 > 98.5 AND prev_close=100 > 98.5
        //      → trail = max(98.5, 102-1.5=100.5) = 100.5, dir = +1
        // i=2: close=101 > 100.5 AND prev_close=102 > 100.5
        //      → trail = max(100.5, 101-1.5=99.5) = 100.5, dir = +1
        // i=3: close=103 > 100.5 AND prev_close=101 > 100.5
        //      → trail = max(100.5, 103-1.5=101.5) = 101.5, dir = +1
        // i=4: close=99 < 101.5 AND prev_close=103 > 101.5 → fall-through
        //      elif close > prev_trail (false: 99 < 101.5) → else
        //      trail = 99 + 1.5 = 100.5, dir = -1
        // i=5: close=100 < 100.5 AND prev_close=99 < 100.5 → second branch
        //      trail = min(100.5, 100+1.5=101.5) = 100.5, dir = -1
        // i=6: close=105 > 100.5 AND prev_close=100 < 100.5 → first branch
        //      FAILS (prev_close 100 not > prev_trail 100.5).
        //      elif close > prev_trail (true: 105 > 100.5) → trail = 105 - 1.5
        //      = 103.5, dir = +1
        // i=7: close=104 > 103.5 AND prev_close=105 > 103.5 → first branch
        //      trail = max(103.5, 104-1.5=102.5) = 103.5, dir = +1
        let closes = vec![100.0, 102.0, 101.0, 103.0, 99.0, 100.0, 105.0, 104.0];
        let atr = vec![1.0; 8];
        let (trail, direction) =
            calc_ut_bot_trail(&closes, &atr, 1.5).unwrap();
        let expected_trail = [98.5, 100.5, 100.5, 101.5, 100.5, 100.5, 103.5, 103.5];
        let expected_dir = [1i8, 1, 1, 1, -1, -1, 1, 1];
        for (i, &want) in expected_trail.iter().enumerate() {
            assert!(
                (trail[i] - want).abs() < 1e-12,
                "trail[{}] expected {} got {}", i, want, trail[i],
            );
            assert_eq!(
                direction[i], expected_dir[i],
                "direction[{}] expected {} got {}", i, expected_dir[i], direction[i],
            );
        }
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
