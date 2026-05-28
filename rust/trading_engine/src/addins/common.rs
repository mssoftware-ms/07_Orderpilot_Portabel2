//! Strategy-agnostic helpers shared across multiple add-ins.
//!
//! Phase-2 Welle I2-0 (engineering plan §4.1 Rule-of-Three) extracts the
//! session filter from `addins/ut_bot.rs` because the Ichimoku strategy
//! needs the same window check. The original `is_in_session` had Berlin
//! UTC+1 hard-coded; [`within_session`] takes the timezone offset as a
//! parameter so future addins (alt-asset, US sessions, etc.) can reuse it
//! without forking the helper again.
//!
//! Phase-2.5 Welle R1 adds [`calc_adx`] (Average Directional Index,
//! Wilder 1978) as the second engine-shared helper. ADX is the regime
//! filter that Welle R2 wires into all three strategies (UT-Bot, BB+RSI,
//! Ichimoku) — placing it here from day one avoids the calc_atr mistake
//! (originally local to `ut_bot.rs`, later needed everywhere). The
//! Phase-3 optimizer lab also needs per-bar ADX snapshots for
//! regime-aware parameter search.
//!
//! Dart mirror: `lib/services/strategy_common.dart`. Behavior is locked
//! bit-identical between the two engines.

/// Return `true` if the bar's `timestamp_ms` falls inside the local-hour
/// window `[start_hour, end_hour)` when interpreted in the fixed local
/// timezone `UTC + tz_offset_hours`.
///
/// Conventions (locked for Dart↔Rust parity):
///
/// - `tz_offset_hours`: integer hours east of UTC (Berlin standard = `1`).
///   No DST handling — the helper is intentionally deterministic; callers
///   for DST-sensitive assets must pre-shift the timestamp.
/// - `start_hour == end_hour` → degenerate window → returns `false`
///   (filter is a no-op rather than silently activating 24/7).
/// - `start_hour < end_hour` → straightforward inclusive-exclusive window
///   (so `end_hour = 23` excludes 23:00:00 itself).
/// - `start_hour > end_hour` → overnight wrap-around window
///   `[start_hour, 24) ∪ [0, end_hour)`.
/// - Hours are taken modulo 24 (so passing `25` is treated as `1`).
pub fn within_session(
    timestamp_ms: i64,
    start_hour: u32,
    end_hour: u32,
    tz_offset_hours: i32,
) -> bool {
    let secs_utc = timestamp_ms.div_euclid(1000);
    let secs_local = secs_utc + (tz_offset_hours as i64) * 3600;
    let hour = (secs_local.div_euclid(3600).rem_euclid(24)) as u32;
    let start = start_hour.rem_euclid(24);
    let end = end_hour.rem_euclid(24);
    if start == end {
        return false;
    }
    if start < end {
        hour >= start && hour < end
    } else {
        hour >= start || hour < end
    }
}

// ─── ADX (Average Directional Index, Wilder 1978) ───────────────────────────

/// Output bundle for [`calc_adx`]: the smoothed ADX line plus the two
/// directional indicators that feed into it.
///
/// Returning the three series together (rather than just `Vec<f64>` for
/// ADX) keeps the Welle R1 contract self-contained: regime tests need
/// `adx` only, but the diagnostic tests that pin "+DI dominant in
/// uptrend" / "-DI dominant in downtrend" need access to the underlying
/// `plus_di` / `minus_di` series, and a Phase-3 optimizer-lab snapshot
/// gets the +DI / -DI breakdown for free. Mirror of the Dart record
/// `({adx, plusDi, minusDi})` in `lib/services/strategy_common.dart`.
#[derive(Debug, Clone, PartialEq)]
pub struct AdxOutput {
    /// Smoothed Average Directional Index, range `[0, 100]`. NaN in the
    /// warm-up region `[0, 2 * period - 2)`.
    pub adx: Vec<f64>,
    /// Smoothed positive directional indicator (+DI), range `[0, 100]`.
    /// NaN in the warm-up region `[0, period - 1)`.
    pub plus_di: Vec<f64>,
    /// Smoothed negative directional indicator (-DI), range `[0, 100]`.
    /// NaN in the warm-up region `[0, period - 1)`.
    pub minus_di: Vec<f64>,
}

/// Compute the Average Directional Index (ADX) with its +DI / -DI
/// components, using Wilder's two-stage smoothing (1978).
///
/// Convention (locked for Dart↔Rust parity, mirrors `calcAdx` in
/// `lib/services/strategy_common.dart`):
///
/// 1. **True Range** — identical to [`crate::addins::ut_bot::calc_atr`]:
///    `tr[0] = high[0] - low[0]`,
///    `tr[i] = max(high[i] - low[i], |high[i] - close[i-1]|, |low[i] - close[i-1]|)`
///    for `i >= 1`.
/// 2. **Directional Movement** — `+dm[0] = -dm[0] = 0`; for `i >= 1`:
///    - `up   = high[i]  - high[i - 1]`
///    - `down = low[i-1] - low[i]`
///    - `+dm[i] = up   if up > down && up   > 0 else 0`
///    - `-dm[i] = down if down > up && down > 0 else 0`
/// 3. **Wilder smoothing** (RMA) of TR, +DM, -DM. Seed at index
///    `period - 1`: `mean(tr[0..period])`, etc. — matches the calc_atr
///    seed convention. For `i >= period`:
///    `tr_s[i] = (tr_s[i-1] * (period - 1) + tr[i]) / period`.
/// 4. **Directional Indicators** at `i >= period - 1`:
///    `+DI[i] = 100 * +dm_s[i] / tr_s[i]` (0 if `tr_s == 0`).
/// 5. **Directional Index** `DX[i] = 100 * |+DI - -DI| / (+DI + -DI)`
///    (0 if `+DI + -DI == 0`).
/// 6. **ADX** = Wilder smoothing of DX. Seed at `i = 2 * period - 2`:
///    `mean(DX[period - 1 ..= 2 * period - 2])` — i.e. the first
///    `period` valid DX values. For `i >= 2 * period - 1`:
///    `adx[i] = (adx[i-1] * (period - 1) + dx[i]) / period`.
///
/// TODO(S-05): recomputes ADX from bar 0 on every call — O(n²) per
/// backtest.  A stateful incremental version (`update_adx`) that only
/// processes the latest bar would cut this to O(n).  Deferred because
/// statelessness guarantees Dart↔Rust parity and the optimizer bottleneck
/// is I/O-dominated; if Phase-3 sweep throughput becomes the limiting
/// factor, consider Rayon parallelisation first.
///
/// Returns `None` if `period == 0`, the input slices have mismatched
/// lengths, or fewer than `period` candles are supplied (i.e. not even
/// the first +DI / -DI can be seeded). When `period <= n < 2 * period - 1`
/// the function still returns `Some` with valid `plus_di` / `minus_di`
/// values from index `period - 1` onward, but the `adx` vec stays
/// entirely NaN — useful for callers that need DI exposure without
/// waiting for the full ADX warm-up.
pub fn calc_adx(highs: &[f64], lows: &[f64], closes: &[f64], period: usize) -> Option<AdxOutput> {
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
    let period_f = period as f64;

    // Step 1: TR (identical to calc_atr) and +DM / -DM per bar.
    let mut tr = vec![0.0f64; n];
    let mut pdm = vec![0.0f64; n];
    let mut mdm = vec![0.0f64; n];
    tr[0] = highs[0] - lows[0];
    // pdm[0] = mdm[0] = 0 (no prior bar to diff against).
    for i in 1..n {
        let hl = highs[i] - lows[i];
        let hpc = (highs[i] - closes[i - 1]).abs();
        let lpc = (lows[i] - closes[i - 1]).abs();
        tr[i] = hl.max(hpc).max(lpc);

        let up = highs[i] - highs[i - 1];
        let down = lows[i - 1] - lows[i];
        pdm[i] = if up > down && up > 0.0 { up } else { 0.0 };
        mdm[i] = if down > up && down > 0.0 { down } else { 0.0 };
    }

    // Step 2: Wilder smoothing of TR, +DM, -DM. Seed at index `period -
    // 1` from the mean of the first `period` raw values — same
    // convention as `calc_atr` so callers can compare smoothed-ATR /
    // smoothed-TR bit-for-bit at the seed index.
    let mut tr_s = vec![f64::NAN; n];
    let mut pdm_s = vec![f64::NAN; n];
    let mut mdm_s = vec![f64::NAN; n];
    let mut sum_tr = 0.0;
    let mut sum_pdm = 0.0;
    let mut sum_mdm = 0.0;
    for i in 0..period {
        sum_tr += tr[i];
        sum_pdm += pdm[i];
        sum_mdm += mdm[i];
    }
    tr_s[period - 1] = sum_tr / period_f;
    pdm_s[period - 1] = sum_pdm / period_f;
    mdm_s[period - 1] = sum_mdm / period_f;
    for i in period..n {
        tr_s[i] = (tr_s[i - 1] * (period_f - 1.0) + tr[i]) / period_f;
        pdm_s[i] = (pdm_s[i - 1] * (period_f - 1.0) + pdm[i]) / period_f;
        mdm_s[i] = (mdm_s[i - 1] * (period_f - 1.0) + mdm[i]) / period_f;
    }

    // Step 3: +DI / -DI / DX at every index where the smoothed TR is
    // defined. TR_s == 0 (constant flat market) → no movement at all
    // → DI = DX = 0. DI sum == 0 → directional movement cancels →
    // DX = 0 as well (numerator is also 0).
    let mut plus_di = vec![f64::NAN; n];
    let mut minus_di = vec![f64::NAN; n];
    let mut dx = vec![f64::NAN; n];
    for i in (period - 1)..n {
        let trv = tr_s[i];
        if trv > 0.0 {
            let pdi = 100.0 * pdm_s[i] / trv;
            let mdi = 100.0 * mdm_s[i] / trv;
            plus_di[i] = pdi;
            minus_di[i] = mdi;
            let sum_di = pdi + mdi;
            dx[i] = if sum_di > 0.0 {
                100.0 * (pdi - mdi).abs() / sum_di
            } else {
                0.0
            };
        } else {
            plus_di[i] = 0.0;
            minus_di[i] = 0.0;
            dx[i] = 0.0;
        }
    }

    // Step 4: ADX = Wilder smoothing of DX. Seed at i = 2*period - 2
    // from the mean of the first `period` valid DX values (indices
    // `period - 1 ..= 2*period - 2`). Requires at least 2*period - 1
    // candles to land a seed; otherwise the ADX vec stays all NaN and
    // the function still returns Some so callers can use +DI / -DI.
    let mut adx = vec![f64::NAN; n];
    let adx_seed_idx = 2 * period - 2;
    if n > adx_seed_idx {
        let sum_dx: f64 = dx[(period - 1)..=adx_seed_idx].iter().sum();
        adx[adx_seed_idx] = sum_dx / period_f;
        for i in (adx_seed_idx + 1)..n {
            adx[i] = (adx[i - 1] * (period_f - 1.0) + dx[i]) / period_f;
        }
    }

    Some(AdxOutput {
        adx,
        plus_di,
        minus_di,
    })
}

// ─── Regime filter (engine-shared, Welle R2-1) ─────────────────────────────

/// Direction-agnostic regime gate that all three Phase-2 strategies
/// (BB+RSI, UT-Bot, Ichimoku) call before emitting an entry signal.
///
/// Centralised here so the three add-ins cannot drift apart on how
/// "trending enough to trade" is defined — the Welle-R3 acceptance
/// backtest must compare strategies under an IDENTICAL filter or the
/// numbers are meaningless. Once a strategy needs a different ADX
/// definition it gets a new helper, not a divergent branch inside
/// this one.
///
/// Inputs are the per-bar ADX snapshot from [`calc_adx`] plus a
/// fixed threshold and (optionally) a `+DI` / `-DI` confluence rule:
///
/// - `adx`            — smoothed ADX value at the signal bar.
/// - `plus_di`        — smoothed +DI value at the signal bar.
/// - `minus_di`       — smoothed -DI value at the signal bar.
/// - `threshold`      — minimum ADX required to pass (Wilder default 25).
/// - `is_long`        — direction of the entry being filtered.
/// - `use_di_confluence` — when `true`, additionally require
///   `+DI > -DI` for longs / `-DI > +DI` for shorts.
///
/// Semantics:
///
/// 1. Any `NaN` input blocks the trade (warm-up safety). This catches
///    the `[0, 2*period - 2)` ADX warm-up region in [`calc_adx`] —
///    a NaN comparison would otherwise always be `false` and the gate
///    would silently block forever; making the NaN-block explicit pins
///    the intent.
/// 2. `adx < threshold` blocks (chop regime — defining behaviour).
/// 3. When DI confluence is on, the directional ranking must match
///    the trade side. `+DI == -DI` (exactly equal) is rejected on
///    both sides because the rule asks for strict dominance.
/// 4. With confluence off, only step 2 gates the trade.
///
/// Callers MUST short-circuit on the `adx_filter_enabled` strategy
/// parameter BEFORE invoking this helper so that the disabled path
/// stays byte-identical to the pre-Welle-R2 behaviour (no ADX
/// computation, no NaN-block side effects). Returning `true` here
/// for a disabled filter would force the caller to thread the flag
/// through anyway; keeping it as the caller's contract avoids that.
pub fn regime_passes_filter(
    adx: f64,
    plus_di: f64,
    minus_di: f64,
    threshold: f64,
    is_long: bool,
    use_di_confluence: bool,
) -> bool {
    if adx.is_nan() || plus_di.is_nan() || minus_di.is_nan() {
        return false;
    }
    if adx < threshold {
        return false;
    }
    if use_di_confluence {
        return if is_long {
            plus_di > minus_di
        } else {
            minus_di > plus_di
        };
    }
    true
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: build a UTC timestamp for `hour` (0..23) on 2024-01-15.
    /// With `tz_offset_hours = 1` the local hour equals `hour_utc + 1`
    /// (mod 24), matching the Berlin-no-DST convention used by UT-Bot.
    fn ts_at_utc_hour(hour: i64) -> i64 {
        // 2024-01-15 00:00:00 UTC = 1705276800000 ms (no DST in January).
        const BASE_UTC_MS: i64 = 1_705_276_800_000;
        BASE_UTC_MS + hour * 3_600_000
    }

    // ── UT-Bot baseline parity (Berlin = UTC+1) ─────────────────────────
    // These six tests preserve the exact contracts the pre-refactor
    // `is_in_session(ts, start, end)` had — same fixture, same start/end,
    // tz_offset_hours = 1. If any of them flips, UT-Bot behavior has
    // drifted and Welle-I2-0-1 has shipped a bug.

    #[test]
    fn test_within_session_inside_window() {
        // Window 09:00–23:00 Berlin (= 08:00–22:00 UTC).
        // UTC 10:00 → local 11:00 → inside.
        assert!(within_session(ts_at_utc_hour(10), 9, 23, 1));
    }

    #[test]
    fn test_within_session_before_window() {
        // UTC 03:00 → local 04:00 → outside (before 09:00).
        assert!(!within_session(ts_at_utc_hour(3), 9, 23, 1));
    }

    #[test]
    fn test_within_session_at_window_start_inclusive() {
        // UTC 08:00 → local 09:00 exactly → inside (`>= start`).
        assert!(within_session(ts_at_utc_hour(8), 9, 23, 1));
    }

    #[test]
    fn test_within_session_at_window_end_exclusive() {
        // UTC 22:00 → local 23:00 exactly → outside (`< end`).
        assert!(!within_session(ts_at_utc_hour(22), 9, 23, 1));
    }

    #[test]
    fn test_within_session_overnight_wrap() {
        // Window 22:00–06:00 Berlin: bars at local 23 and local 02
        // are inside, bar at local 10 is outside.
        // local 23 = UTC 22
        assert!(within_session(ts_at_utc_hour(22), 22, 6, 1));
        // local 02 = UTC 01
        assert!(within_session(ts_at_utc_hour(1), 22, 6, 1));
        // local 10 = UTC 09
        assert!(!within_session(ts_at_utc_hour(9), 22, 6, 1));
    }

    #[test]
    fn test_within_session_degenerate_window_is_off() {
        // start == end → no-op (always returns false). Pins the
        // documented degenerate behavior so an accidental `start=end`
        // config does not silently enable a 24/7 filter.
        assert!(!within_session(ts_at_utc_hour(10), 12, 12, 1));
    }

    // ── tz_offset_hours parameter ───────────────────────────────────────

    #[test]
    fn test_within_session_utc_zero_offset() {
        // tz_offset_hours = 0 → local equals UTC, no shift.
        // UTC 09:00 → local 09:00 → inside [09, 23).
        assert!(within_session(ts_at_utc_hour(9), 9, 23, 0));
        // UTC 08:00 → local 08:00 → outside [09, 23).
        assert!(!within_session(ts_at_utc_hour(8), 9, 23, 0));
    }

    #[test]
    fn test_within_session_negative_offset_west_of_utc() {
        // tz_offset_hours = -5 (e.g. US Eastern Standard Time).
        // UTC 14:00 → local 09:00 → inside [09, 23).
        assert!(within_session(ts_at_utc_hour(14), 9, 23, -5));
        // UTC 13:00 → local 08:00 → outside.
        assert!(!within_session(ts_at_utc_hour(13), 9, 23, -5));
    }

    #[test]
    fn test_within_session_hours_modulo_24() {
        // Hours outside [0, 24) are reduced mod 24. Window (25, 47, 1)
        // ≡ (1, 23, 1) → UTC 10:00 + Berlin = local 11:00 → inside.
        assert!(within_session(ts_at_utc_hour(10), 25, 47, 1));
    }

    // ── ADX helper tests ────────────────────────────────────────────────
    //
    // Reference values shared bit-for-bit with the Dart unit tests in
    // `test/services/strategy_common_test.dart` so the two engines stay
    // in lock-step at the algorithm level. Where the test asserts a
    // specific magnitude (e.g. ADX > 50), the Dart mirror uses the same
    // threshold against the same fixture.

    #[test]
    fn test_adx_zero_period_returns_none() {
        let h = vec![1.0; 5];
        let l = vec![0.5; 5];
        let c = vec![0.7; 5];
        assert!(calc_adx(&h, &l, &c, 0).is_none());
    }

    #[test]
    fn test_adx_mismatched_lengths_return_none() {
        let h = vec![1.0, 2.0, 3.0];
        let l = vec![0.5, 1.5];
        let c = vec![0.7, 1.7, 2.7];
        assert!(calc_adx(&h, &l, &c, 2).is_none());
    }

    #[test]
    fn test_adx_insufficient_data_returns_none() {
        // n < period → cannot even seed first +DI/-DI → None.
        let h = vec![1.0, 2.0, 3.0];
        let l = vec![0.5, 1.5, 2.5];
        let c = vec![0.8, 1.8, 2.8];
        assert!(calc_adx(&h, &l, &c, 14).is_none());
    }

    #[test]
    fn test_adx_constant_series_dx_and_adx_are_zero() {
        // User R1-1 test #1: high == low == close == const for every bar
        // → TR = 0, +DM = -DM = 0, both DI = 0 (TR_s == 0 branch),
        // DX = 0, ADX = 0. Constant series has no directional movement
        // by construction.
        let n = 40;
        let highs = vec![100.0; n];
        let lows = vec![100.0; n];
        let closes = vec![100.0; n];
        let period = 14;
        let out = calc_adx(&highs, &lows, &closes, period).unwrap();
        assert_eq!(out.adx.len(), n);
        assert_eq!(out.plus_di.len(), n);
        assert_eq!(out.minus_di.len(), n);
        // Warm-up: first `period - 1` indices must be NaN for the DIs;
        // ADX warm-up extends to `2 * period - 2` exclusive.
        for i in 0..(period - 1) {
            assert!(out.plus_di[i].is_nan(), "+DI warmup at {i}");
            assert!(out.minus_di[i].is_nan(), "-DI warmup at {i}");
        }
        for i in 0..(2 * period - 2) {
            assert!(out.adx[i].is_nan(), "ADX warmup at {i}");
        }
        // Post warm-up: every DI and ADX value is exactly 0.0.
        for i in (period - 1)..n {
            assert_eq!(out.plus_di[i], 0.0, "+DI at {i}");
            assert_eq!(out.minus_di[i], 0.0, "-DI at {i}");
        }
        for i in (2 * period - 2)..n {
            assert_eq!(out.adx[i], 0.0, "ADX at {i}");
        }
    }

    #[test]
    fn test_adx_monotone_uptrend_plus_di_dominates_and_adx_high() {
        // User R1-1 test #2: linear uptrend → only +DM fires every bar,
        // -DM stays 0 → |+DI - -DI| / (+DI + -DI) = 1.0 → DX = 100 →
        // ADX converges to a very high value (close to 100 once the
        // double-smoothing settles).
        //
        // Fixture: high[i] = 100 + i + 0.5, low[i] = 100 + i - 0.5,
        // close[i] = 100 + i. Every bar shifts up by 1.0.
        let n = 80;
        let highs: Vec<f64> = (0..n).map(|i| 100.0 + i as f64 + 0.5).collect();
        let lows: Vec<f64> = (0..n).map(|i| 100.0 + i as f64 - 0.5).collect();
        let closes: Vec<f64> = (0..n).map(|i| 100.0 + i as f64).collect();
        let period = 14;
        let out = calc_adx(&highs, &lows, &closes, period).unwrap();
        // After ADX warm-up (i >= 2*period - 2 = 26) +DI dominates -DI
        // and ADX is far above the 50 regime threshold.
        for i in (2 * period - 2)..n {
            assert!(
                out.plus_di[i] > out.minus_di[i],
                "+DI must dominate -DI at {i}: +DI={} -DI={}",
                out.plus_di[i],
                out.minus_di[i]
            );
            assert!(
                out.adx[i] > 50.0,
                "ADX must exceed 50 in monotone uptrend at {i}: got {}",
                out.adx[i]
            );
        }
        // -DI stays exactly 0 throughout: no down-move ever fires.
        for i in (period - 1)..n {
            assert_eq!(out.minus_di[i], 0.0, "-DI must be 0 at {i}");
        }
    }

    #[test]
    fn test_adx_monotone_downtrend_minus_di_dominates_and_adx_high() {
        // User R1-1 test #3: mirror of the uptrend test for the short
        // side. Linear downtrend → only -DM fires.
        let n = 80;
        let highs: Vec<f64> = (0..n).map(|i| 200.0 - i as f64 + 0.5).collect();
        let lows: Vec<f64> = (0..n).map(|i| 200.0 - i as f64 - 0.5).collect();
        let closes: Vec<f64> = (0..n).map(|i| 200.0 - i as f64).collect();
        let period = 14;
        let out = calc_adx(&highs, &lows, &closes, period).unwrap();
        for i in (2 * period - 2)..n {
            assert!(
                out.minus_di[i] > out.plus_di[i],
                "-DI must dominate +DI at {i}: +DI={} -DI={}",
                out.plus_di[i],
                out.minus_di[i]
            );
            assert!(
                out.adx[i] > 50.0,
                "ADX must exceed 50 in monotone downtrend at {i}: got {}",
                out.adx[i]
            );
        }
        for i in (period - 1)..n {
            assert_eq!(out.plus_di[i], 0.0, "+DI must be 0 at {i}");
        }
    }

    #[test]
    fn test_adx_choppy_series_keeps_adx_low() {
        // User R1-1 test #4: bar-by-bar alternation of high / low / close
        // shifts pdm and mdm symmetrically — smoothed they cancel, so
        // |+DI - -DI| stays small and ADX collapses well below the 20
        // chop threshold.
        //
        // Fixture: even bar high=101 low=99 close=100, odd bar high=100
        // low=98 close=99 → every step alternates one bar of up-move
        // with one bar of down-move.
        let n = 80;
        let highs: Vec<f64> = (0..n)
            .map(|i| if i % 2 == 0 { 101.0 } else { 100.0 })
            .collect();
        let lows: Vec<f64> = (0..n)
            .map(|i| if i % 2 == 0 { 99.0 } else { 98.0 })
            .collect();
        let closes: Vec<f64> = (0..n)
            .map(|i| if i % 2 == 0 { 100.0 } else { 99.0 })
            .collect();
        let period = 14;
        let out = calc_adx(&highs, &lows, &closes, period).unwrap();
        // Once the second smoothing stage settles (a few bars beyond
        // the formal 2*period-2 warm-up), ADX must be below 20 — the
        // "no trend" regime threshold used by Welle R2 / R3.
        for i in (2 * period - 2 + period)..n {
            assert!(
                out.adx[i] < 20.0,
                "choppy ADX must stay below 20 at {i}: got {}",
                out.adx[i]
            );
        }
    }

    #[test]
    fn test_adx_period_14_with_14_candles_first_di_only_no_adx() {
        // User R1-1 test #6: with exactly `period` candles the last bar
        // delivers the first valid +DI / -DI, but the ADX needs
        // `2 * period - 1` bars before the seed lands. Returns `Some`
        // (so callers can probe DI) with the `adx` vec entirely NaN.
        //
        // Linear uptrend matching the magnitude test so we can pin a
        // sane +DI value at the seed index.
        let period = 14;
        let n = period;
        let highs: Vec<f64> = (0..n).map(|i| 100.0 + i as f64 + 0.5).collect();
        let lows: Vec<f64> = (0..n).map(|i| 100.0 + i as f64 - 0.5).collect();
        let closes: Vec<f64> = (0..n).map(|i| 100.0 + i as f64).collect();
        let out = calc_adx(&highs, &lows, &closes, period).unwrap();
        assert_eq!(out.adx.len(), n);
        // ADX warm-up extends through the entire fixture.
        for v in &out.adx {
            assert!(v.is_nan(), "ADX must be NaN throughout: got {v}");
        }
        // +DI / -DI: NaN until index period - 1, valid on the last bar.
        for i in 0..(period - 1) {
            assert!(out.plus_di[i].is_nan(), "+DI warmup at {i}");
            assert!(out.minus_di[i].is_nan(), "-DI warmup at {i}");
        }
        assert!(!out.plus_di[period - 1].is_nan());
        assert!(!out.minus_di[period - 1].is_nan());
        // Monotone uptrend with no down-moves → -DI = 0, +DI > 0.
        assert_eq!(out.minus_di[period - 1], 0.0);
        assert!(out.plus_di[period - 1] > 0.0);
    }

    /// Temporary scaffolding test — prints the reference values that
    /// land in [`test_adx_pinned_50_candle_fixture`] and the 200-candle
    /// sinus parity test. Marked `#[ignore]` so `cargo test` skips it
    /// by default; run with
    /// `cargo test --lib addins::common::tests::dump_adx -- --ignored --nocapture`
    /// when the algorithm or fixture changes. Stays in the codebase as
    /// a documented re-pinning workflow rather than a throwaway.
    #[test]
    #[ignore]
    fn dump_adx_reference_values() {
        // 50-candle up-then-down fixture.
        let n = 50;
        let mut highs = Vec::with_capacity(n);
        let mut lows = Vec::with_capacity(n);
        let mut closes = Vec::with_capacity(n);
        for i in 0..25 {
            highs.push(100.0 + i as f64 + 0.5);
            lows.push(100.0 + i as f64 - 0.5);
            closes.push(100.0 + i as f64);
        }
        for i in 0..25 {
            let base = 124.0 - i as f64;
            highs.push(base + 0.5);
            lows.push(base - 0.5);
            closes.push(base);
        }
        let out = calc_adx(&highs, &lows, &closes, 14).unwrap();
        println!("=== 50-candle pinned fixture ===");
        println!("plus_di[13]  = {:.15}", out.plus_di[13]);
        println!("minus_di[13] = {:.15}", out.minus_di[13]);
        println!("plus_di[26]  = {:.15}", out.plus_di[26]);
        println!("minus_di[26] = {:.15}", out.minus_di[26]);
        println!("adx[26]      = {:.15}", out.adx[26]);
        println!("plus_di[49]  = {:.15}", out.plus_di[49]);
        println!("minus_di[49] = {:.15}", out.minus_di[49]);
        println!("adx[49]      = {:.15}", out.adx[49]);

        // 200-candle deterministic sinus fixture for Dart-Rust parity.
        // Closing-price construction (mirrored in the Dart test):
        //   close[i] = 100 + 10 * sin(2π * i / 25)
        //   high[i]  = close[i] + 0.6
        //   low[i]   = close[i] - 0.6
        let m = 200;
        let mut h2 = Vec::with_capacity(m);
        let mut l2 = Vec::with_capacity(m);
        let mut c2 = Vec::with_capacity(m);
        let two_pi = 2.0 * std::f64::consts::PI;
        for i in 0..m {
            let c = 100.0 + 10.0 * (two_pi * i as f64 / 25.0).sin();
            c2.push(c);
            h2.push(c + 0.6);
            l2.push(c - 0.6);
        }
        let out2 = calc_adx(&h2, &l2, &c2, 14).unwrap();
        println!("=== 200-candle sinus parity ===");
        println!("plus_di[13]   = {:.15}", out2.plus_di[13]);
        println!("minus_di[13]  = {:.15}", out2.minus_di[13]);
        println!("adx[26]       = {:.15}", out2.adx[26]);
        println!("adx[100]      = {:.15}", out2.adx[100]);
        println!("adx[199]      = {:.15}", out2.adx[199]);
        // Aggregate over the post-warm-up region — locks every single
        // ADX sample, not just the spot-checks above. Drift in any
        // single bar will move the sum away from the pinned value.
        let mut sum = 0.0;
        for i in 26..m {
            sum += out2.adx[i];
        }
        println!("sum(adx[26..200]) = {:.15}", sum);
    }

    #[test]
    fn test_adx_pinned_50_candle_fixture() {
        // User R1-1 test #7: 50-candle fixture with a deterministic
        // up-then-down profile (25 bars +1 per bar, 25 bars -1 per
        // bar). Reference values below were captured from the Rust
        // implementation via `dump_adx_reference_values` and pinned
        // bit-for-bit into the Dart mirror test in
        // `test/services/strategy_common_test.dart` to lock numerical
        // parity at the indicator level — the same pattern used by the
        // ATR / SMI tests. To re-pin after an intentional algorithm
        // change, run the ignored `dump_adx_reference_values` test and
        // paste the new numbers into BOTH this test and the Dart
        // mirror in the same commit.
        let n = 50;
        let mut highs = Vec::with_capacity(n);
        let mut lows = Vec::with_capacity(n);
        let mut closes = Vec::with_capacity(n);
        for i in 0..25 {
            highs.push(100.0 + i as f64 + 0.5);
            lows.push(100.0 + i as f64 - 0.5);
            closes.push(100.0 + i as f64);
        }
        for i in 0..25 {
            let base = 124.0 - i as f64;
            highs.push(base + 0.5);
            lows.push(base - 0.5);
            closes.push(base);
        }
        let period = 14;
        let out = calc_adx(&highs, &lows, &closes, period).unwrap();
        // Pinned values (1e-12 tolerance — pure-arithmetic
        // determinism, no time/RNG / no parallel reduction).
        let eps = 1e-12;
        assert!((out.plus_di[13] - 63.414_634_146_341_47).abs() < eps);
        assert_eq!(out.minus_di[13], 0.0);
        assert!((out.plus_di[26] - 57.458_263_032_078_94).abs() < eps);
        assert!((out.minus_di[26] - 4.915_232_309_238_658).abs() < eps);
        assert!((out.adx[26] - 98.874_239_706_570_02).abs() < eps);
        assert!((out.plus_di[49] - 10.181_512_267_099_826).abs() < eps);
        assert!((out.minus_di[49] - 55.724_411_310_458_87).abs() < eps);
        assert!((out.adx[49] - 55.559_688_552_699_39).abs() < eps);
        // Range sanity: every post-warm-up DI / ADX must be in [0, 100].
        for &v in out.plus_di.iter().skip(period - 1) {
            assert!((0.0..=100.0).contains(&v), "+DI out of range: {v}");
        }
        for &v in out.minus_di.iter().skip(period - 1) {
            assert!((0.0..=100.0).contains(&v), "-DI out of range: {v}");
        }
        for &v in out.adx.iter().skip(2 * period - 2) {
            assert!((0.0..=100.0).contains(&v), "ADX out of range: {v}");
        }
    }

    // ── regime_passes_filter tests ──────────────────────────────────────
    //
    // Reference rules shared bit-for-bit with the Dart mirror in
    // `test/services/strategy_common_test.dart` so the gate stays in
    // lock-step with the Welle-R3 acceptance backtest (where the three
    // strategies must apply IDENTICAL filtering).

    #[test]
    fn test_regime_filter_blocks_when_adx_below_threshold() {
        // ADX < threshold → false regardless of direction or confluence.
        assert!(!regime_passes_filter(20.0, 30.0, 10.0, 25.0, true, false));
        assert!(!regime_passes_filter(20.0, 30.0, 10.0, 25.0, false, false));
        assert!(!regime_passes_filter(20.0, 30.0, 10.0, 25.0, true, true));
    }

    #[test]
    fn test_regime_filter_passes_when_adx_above_threshold() {
        // ADX >= threshold without confluence → true for both sides.
        assert!(regime_passes_filter(30.0, 25.0, 25.0, 25.0, true, false));
        assert!(regime_passes_filter(30.0, 25.0, 25.0, 25.0, false, false));
        // Boundary: adx == threshold passes (only `<` blocks).
        assert!(regime_passes_filter(25.0, 25.0, 25.0, 25.0, true, false));
    }

    #[test]
    fn test_regime_filter_di_confluence_blocks_long_when_minus_dominant() {
        // ADX is trending, but -DI dominates → long must be rejected;
        // short would pass with the same inputs.
        assert!(!regime_passes_filter(40.0, 10.0, 30.0, 25.0, true, true));
        assert!(regime_passes_filter(40.0, 10.0, 30.0, 25.0, false, true));
    }

    #[test]
    fn test_regime_filter_di_confluence_passes_long_when_plus_dominant() {
        // Mirror: +DI dominant → long passes, short blocks.
        assert!(regime_passes_filter(40.0, 30.0, 10.0, 25.0, true, true));
        assert!(!regime_passes_filter(40.0, 30.0, 10.0, 25.0, false, true));
    }

    #[test]
    fn test_regime_filter_di_equality_blocks_both_sides_when_confluence_on() {
        // `+DI == -DI` → no strict dominance → both directions blocked
        // under confluence. With confluence off the ADX gate alone
        // decides, so the same inputs pass.
        assert!(!regime_passes_filter(40.0, 20.0, 20.0, 25.0, true, true));
        assert!(!regime_passes_filter(40.0, 20.0, 20.0, 25.0, false, true));
        assert!(regime_passes_filter(40.0, 20.0, 20.0, 25.0, true, false));
        assert!(regime_passes_filter(40.0, 20.0, 20.0, 25.0, false, false));
    }

    #[test]
    fn test_regime_filter_nan_inputs_block() {
        // Warm-up safety: any NaN input (ADX warm-up region, NaN-poisoned
        // candle) must block the trade explicitly. NaN-aware short-circuit
        // is intentional — a raw `<` comparison with NaN is always false
        // and would let downstream `if use_di_confluence` logic run on
        // garbage data.
        assert!(!regime_passes_filter(
            f64::NAN,
            30.0,
            10.0,
            25.0,
            true,
            false
        ));
        assert!(!regime_passes_filter(
            40.0,
            f64::NAN,
            10.0,
            25.0,
            true,
            true
        ));
        assert!(!regime_passes_filter(
            40.0,
            30.0,
            f64::NAN,
            25.0,
            false,
            true
        ));
    }

    #[test]
    fn test_regime_filter_threshold_zero_passes_when_finite() {
        // threshold=0 makes the ADX gate a no-op for any non-negative
        // ADX value — equivalent to "filter on, but accept any
        // trendiness". DI-confluence still applies when requested.
        assert!(regime_passes_filter(0.0, 5.0, 3.0, 0.0, true, false));
        assert!(regime_passes_filter(0.0, 5.0, 3.0, 0.0, true, true));
        assert!(!regime_passes_filter(0.0, 3.0, 5.0, 0.0, true, true));
    }

    #[test]
    fn test_adx_parity_200_candle_sinus_fixture() {
        // User R1-1 test #8: 200-candle deterministic sinus fixture
        // serving as the Dart↔Rust parity probe at the indicator
        // level. The Dart mirror test in
        // `test/services/strategy_common_test.dart` runs the SAME
        // fixture through `calcAdx` and asserts the same pinned
        // values to within 1e-9 — drift past that tolerance means an
        // engine-level divergence and MUST be investigated rather
        // than papered over by widening the tolerance.
        //
        // FFI was not extended for individual indicator round-trips
        // in Welle R1 (the bridge only exposes backtest entry
        // points); the implicit FFI parity will be exercised when
        // Welle R2 wires ADX into each strategy and the existing
        // parity tests re-run end-to-end. Pinned values here lock
        // algorithm parity even before that wiring lands.
        let n = 200;
        let mut highs = Vec::with_capacity(n);
        let mut lows = Vec::with_capacity(n);
        let mut closes = Vec::with_capacity(n);
        let two_pi = 2.0 * std::f64::consts::PI;
        for i in 0..n {
            let c = 100.0 + 10.0 * (two_pi * i as f64 / 25.0).sin();
            closes.push(c);
            highs.push(c + 0.6);
            lows.push(c - 0.6);
        }
        let out = calc_adx(&highs, &lows, &closes, 14).unwrap();
        let eps = 1e-9;
        assert!((out.plus_di[13] - 32.417_389_945_019_025).abs() < eps);
        assert!((out.minus_di[13] - 36.488_399_457_883_17).abs() < eps);
        assert!((out.adx[26] - 22.735_452_586_048_63).abs() < eps);
        assert!((out.adx[100] - 25.839_833_200_334_414).abs() < eps);
        assert!((out.adx[199] - 26.864_383_264_975_18).abs() < eps);
        // Aggregate over the post-warm-up region — locks every single
        // ADX sample, not just the spot-checks above. Any drift in a
        // single bar will move the sum away from the pinned total.
        let sum: f64 = out.adx[26..].iter().sum();
        assert!((sum - 4_891.015_271_372_291).abs() < 1e-6);
    }
}
