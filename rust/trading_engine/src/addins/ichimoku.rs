//! Ichimoku Kinkō Hyō indicator helpers.
//!
//! Phase-2 Welle I1 lands the pure indicator building-blocks consumed
//! later by the Ichimoku strategy (Welle I2). Spec reference:
//! `01_Projectplan/specs/ichimoku_spec.md`.
//!
//! Helpers are kept local to this file per QA decision F1 = A (clear,
//! prefixed names, no premature extraction to a shared module). Once a
//! second consumer for `rolling_max`/`rolling_min` materializes we
//! revisit the location.
//!
//! Dart mirror: `lib/services/indicators.dart` (`rollingMax`,
//! `rollingMin`). Behavior is locked bit-identical between the two
//! engines — see `test/services/indicators_test.dart` for the shared
//! reference fixture used by both sides.

// ─── Rolling-window primitives (pure, point queries) ────────────────────────

/// Maximum of `values[end_idx + 1 - period ..= end_idx]` — i.e. the
/// highest value across the last `period` samples **including the bar at
/// `end_idx` itself**.
///
/// `end_idx` is **inclusive** — at index `i` with `period = N`, the
/// helper looks at the `N` bars ending at bar `i`. This matches the
/// Ichimoku convention `HH_N = highest(high, N)` (Spec §1) and the
/// pandas-ta `ta.highest` / Pinescript `ta.highest` operators.
///
/// Returns `f64::NAN` when the window cannot be filled:
/// - `period == 0`
/// - `values` is empty
/// - `end_idx >= values.len()`
/// - `period > end_idx + 1` (warm-up region — fewer than `period`
///   samples available at or before `end_idx`)
///
/// NaN samples inside a valid window propagate (any NaN ⇒ NaN result),
/// matching the Pinescript/pandas-ta semantics where `na` participates
/// in the comparison and poisons the aggregate.
pub fn rolling_max(values: &[f64], end_idx: usize, period: usize) -> f64 {
    if period == 0 || values.is_empty() || end_idx >= values.len() || period > end_idx + 1 {
        return f64::NAN;
    }
    let start = end_idx + 1 - period;
    let mut max = f64::NEG_INFINITY;
    for &v in &values[start..=end_idx] {
        if v.is_nan() {
            return f64::NAN;
        }
        if v > max {
            max = v;
        }
    }
    max
}

/// Minimum of `values[end_idx + 1 - period ..= end_idx]` — the lowest
/// value across the last `period` samples **including the bar at
/// `end_idx` itself**.
///
/// Mirror of [`rolling_max`] for the lows side. Same `end_idx`-inclusive
/// convention, same NaN/warm-up semantics.
pub fn rolling_min(values: &[f64], end_idx: usize, period: usize) -> f64 {
    if period == 0 || values.is_empty() || end_idx >= values.len() || period > end_idx + 1 {
        return f64::NAN;
    }
    let start = end_idx + 1 - period;
    let mut min = f64::INFINITY;
    for &v in &values[start..=end_idx] {
        if v.is_nan() {
            return f64::NAN;
        }
        if v < min {
            min = v;
        }
    }
    min
}

// ─── Tenkan-Sen / Kijun-Sen midpoint lines ─────────────────────────────────

/// Shared midpoint-series builder backing both [`calc_tenkan_sen`] and
/// [`calc_kijun_sen`] — the math is identical (`(HH_N + LL_N) / 2`),
/// only the default period differs (9 vs 26 per Spec §1).
///
/// Returns `None` only on hard input errors (mismatched lengths, zero
/// period, or fewer candles than `period`). Otherwise the result has
/// the same length as the inputs with `NaN` for the warm-up region
/// (`i < period - 1`) and the midpoint for `i >= period - 1`.
fn calc_midpoint_series(
    highs: &[f64],
    lows: &[f64],
    period: usize,
) -> Option<Vec<f64>> {
    if period == 0 || highs.len() != lows.len() {
        return None;
    }
    let n = highs.len();
    if n < period {
        return None;
    }
    let mut out = vec![f64::NAN; n];
    for (i, slot) in out.iter_mut().enumerate().skip(period - 1) {
        let hh = rolling_max(highs, i, period);
        let ll = rolling_min(lows, i, period);
        if hh.is_nan() || ll.is_nan() {
            // NaN poisoning from a NaN sample in the window — leave
            // *slot as NaN (already the default).
            continue;
        }
        *slot = (hh + ll) / 2.0;
    }
    Some(out)
}

/// Compute the **Tenkan-Sen** (Conversion Line) series.
///
/// Definition (Spec §1.1, mirrors the canonical Ichimoku formula):
///
/// ```text
/// Tenkan-Sen[i] = (highest(high, period) + lowest(low, period)) / 2
/// ```
///
/// at each bar `i`, where the rolling window is `[i + 1 - period ..= i]`
/// (period bars **including** bar `i`). Spec default `period = 9`.
///
/// Returned `Vec<f64>` has the same length as `highs`; indices
/// `0..period - 1` are `NaN` (warm-up). Returns `None` on mismatched
/// `highs`/`lows` lengths, `period == 0`, or fewer than `period` candles.
pub fn calc_tenkan_sen(
    highs: &[f64],
    lows: &[f64],
    period: usize,
) -> Option<Vec<f64>> {
    calc_midpoint_series(highs, lows, period)
}

/// Compute the **Kijun-Sen** (Base Line) series.
///
/// Same midpoint math as [`calc_tenkan_sen`], differing only in the
/// canonical period (Spec default `period = 26`). Two distinct functions
/// (rather than one parameterised helper) keep the strategy call sites
/// self-documenting and let future overrides (e.g. spec-§13 sensitivity
/// runs) diverge without touching shared code.
pub fn calc_kijun_sen(
    highs: &[f64],
    lows: &[f64],
    period: usize,
) -> Option<Vec<f64>> {
    calc_midpoint_series(highs, lows, period)
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── rolling_max ─────────────────────────────────────────────────────

    #[test]
    fn test_rolling_max_zero_period_is_nan() {
        assert!(rolling_max(&[1.0, 2.0, 3.0], 2, 0).is_nan());
    }

    #[test]
    fn test_rolling_max_empty_values_is_nan() {
        assert!(rolling_max(&[], 0, 1).is_nan());
    }

    #[test]
    fn test_rolling_max_end_idx_out_of_bounds_is_nan() {
        assert!(rolling_max(&[1.0, 2.0], 5, 1).is_nan());
    }

    #[test]
    fn test_rolling_max_warmup_period_gt_end_idx_plus_one() {
        // values has 5 elements, end_idx=2, period=9 → need 9 samples
        // ending at idx 2, only 3 available → warm-up → NaN.
        assert!(rolling_max(&[1.0, 2.0, 3.0, 4.0, 5.0], 2, 9).is_nan());
    }

    #[test]
    fn test_rolling_max_period_one_equals_end_idx_value() {
        // period=1 → window is exactly [end_idx..=end_idx], so the
        // result is values[end_idx] verbatim.
        let v = [10.0, 20.0, 15.0, 30.0];
        assert!((rolling_max(&v, 0, 1) - 10.0).abs() < 1e-12);
        assert!((rolling_max(&v, 2, 1) - 15.0).abs() < 1e-12);
        assert!((rolling_max(&v, 3, 1) - 30.0).abs() < 1e-12);
    }

    #[test]
    fn test_rolling_max_constant_values_returns_constant() {
        // Constant series → max equals the constant for every valid window.
        let v = vec![42.0; 20];
        for i in 0..20 {
            assert!((rolling_max(&v, i, 5.min(i + 1)) - 42.0).abs() < 1e-12);
        }
    }

    #[test]
    fn test_rolling_max_first_valid_index_at_period_minus_one() {
        // With period=5, the smallest end_idx where the window can be
        // fully filled is end_idx = 4 (5 samples: indices 0..=4).
        let v = [1.0, 2.0, 3.0, 4.0, 5.0];
        // end_idx=3, period=5 → warm-up → NaN.
        assert!(rolling_max(&v, 3, 5).is_nan());
        // end_idx=4, period=5 → first valid window → max = 5.0.
        assert!((rolling_max(&v, 4, 5) - 5.0).abs() < 1e-12);
    }

    #[test]
    fn test_rolling_max_known_small_fixture() {
        // Hand-computed reference (shared bit-for-bit with the Dart
        // mirror in `test/services/indicators_test.dart`).
        //
        // values: [3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0, 3.0]
        // period = 3
        //
        // end_idx=2  → max(3,1,4) = 4
        // end_idx=3  → max(1,4,1) = 4
        // end_idx=4  → max(4,1,5) = 5
        // end_idx=5  → max(1,5,9) = 9
        // end_idx=6  → max(5,9,2) = 9
        // end_idx=7  → max(9,2,6) = 9
        // end_idx=8  → max(2,6,5) = 6
        // end_idx=9  → max(6,5,3) = 6
        let v = [3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0, 3.0];
        let expected = [
            (2usize, 4.0),
            (3, 4.0),
            (4, 5.0),
            (5, 9.0),
            (6, 9.0),
            (7, 9.0),
            (8, 6.0),
            (9, 6.0),
        ];
        for &(i, want) in expected.iter() {
            let got = rolling_max(&v, i, 3);
            assert!((got - want).abs() < 1e-9, "rolling_max idx={} want={} got={}", i, want, got);
        }
    }

    #[test]
    fn test_rolling_max_nan_inside_window_poisons() {
        // NaN inside the active window → result is NaN (pandas-ta /
        // Pinescript `ta.highest` propagate `na` the same way).
        let v = [1.0, 2.0, f64::NAN, 4.0, 5.0];
        assert!(rolling_max(&v, 3, 3).is_nan());
        // NaN outside the window → result is fine.
        assert!((rolling_max(&v, 4, 2) - 5.0).abs() < 1e-12);
    }

    // ── rolling_min ─────────────────────────────────────────────────────

    #[test]
    fn test_rolling_min_zero_period_is_nan() {
        assert!(rolling_min(&[1.0, 2.0, 3.0], 2, 0).is_nan());
    }

    #[test]
    fn test_rolling_min_empty_values_is_nan() {
        assert!(rolling_min(&[], 0, 1).is_nan());
    }

    #[test]
    fn test_rolling_min_end_idx_out_of_bounds_is_nan() {
        assert!(rolling_min(&[1.0, 2.0], 5, 1).is_nan());
    }

    #[test]
    fn test_rolling_min_warmup_period_gt_end_idx_plus_one() {
        assert!(rolling_min(&[5.0, 4.0, 3.0, 2.0, 1.0], 2, 9).is_nan());
    }

    #[test]
    fn test_rolling_min_period_one_equals_end_idx_value() {
        let v = [10.0, 20.0, 15.0, 30.0];
        assert!((rolling_min(&v, 0, 1) - 10.0).abs() < 1e-12);
        assert!((rolling_min(&v, 2, 1) - 15.0).abs() < 1e-12);
        assert!((rolling_min(&v, 3, 1) - 30.0).abs() < 1e-12);
    }

    #[test]
    fn test_rolling_min_constant_values_returns_constant() {
        let v = vec![42.0; 20];
        for i in 0..20 {
            assert!((rolling_min(&v, i, 5.min(i + 1)) - 42.0).abs() < 1e-12);
        }
    }

    #[test]
    fn test_rolling_min_first_valid_index_at_period_minus_one() {
        let v = [5.0, 4.0, 3.0, 2.0, 1.0];
        assert!(rolling_min(&v, 3, 5).is_nan());
        assert!((rolling_min(&v, 4, 5) - 1.0).abs() < 1e-12);
    }

    #[test]
    fn test_rolling_min_known_small_fixture() {
        // Same fixture as rolling_max, period = 3:
        //
        // end_idx=2  → min(3,1,4) = 1
        // end_idx=3  → min(1,4,1) = 1
        // end_idx=4  → min(4,1,5) = 1
        // end_idx=5  → min(1,5,9) = 1
        // end_idx=6  → min(5,9,2) = 2
        // end_idx=7  → min(9,2,6) = 2
        // end_idx=8  → min(2,6,5) = 2
        // end_idx=9  → min(6,5,3) = 3
        let v = [3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0, 3.0];
        let expected = [
            (2usize, 1.0),
            (3, 1.0),
            (4, 1.0),
            (5, 1.0),
            (6, 2.0),
            (7, 2.0),
            (8, 2.0),
            (9, 3.0),
        ];
        for &(i, want) in expected.iter() {
            let got = rolling_min(&v, i, 3);
            assert!((got - want).abs() < 1e-9, "rolling_min idx={} want={} got={}", i, want, got);
        }
    }

    #[test]
    fn test_rolling_min_nan_inside_window_poisons() {
        let v = [5.0, 4.0, f64::NAN, 2.0, 1.0];
        assert!(rolling_min(&v, 3, 3).is_nan());
        assert!((rolling_min(&v, 4, 2) - 1.0).abs() < 1e-12);
    }

    // ── 200-bar parity fixture (Dart↔Rust) ──────────────────────────────

    /// Deterministic 200-sample series used by both engines to lock the
    /// rolling-window primitives to bit-identical output. Same generator
    /// rule on the Dart side in `test/services/indicators_test.dart`:
    ///
    /// ```text
    /// v[i] = 100.0 + 10.0 * sin(0.13 * i)
    ///                + 3.0  * cos(0.41 * i)
    ///                + 0.5  * (i % 7) as f64
    /// ```
    ///
    /// Three blended frequencies + a small integer-modulo drift gives a
    /// path with frequent local maxima/minima — enough to exercise both
    /// the standard window and the warm-up boundary cleanly.
    fn parity_fixture_200() -> Vec<f64> {
        (0..200)
            .map(|i| {
                let x = i as f64;
                100.0 + 10.0 * (0.13 * x).sin() + 3.0 * (0.41 * x).cos() + 0.5 * (i % 7) as f64
            })
            .collect()
    }

    #[test]
    fn test_rolling_max_200_bar_fixture_reference_anchors() {
        // Reference values pinned bit-for-bit against the Dart mirror
        // (tolerance 1e-9). Both engines run the same generator above.
        // Anchors chosen to hit: first valid window (period - 1), middle
        // of the series, and the last bar — three distinct phases of the
        // sinusoid blend.
        let v = parity_fixture_200();
        // Period 9 (Tenkan default): first valid end_idx = 8.
        assert!(
            (rolling_max(&v, 8, 9) - 107.703_083_341_404_22).abs() < 1e-9,
            "rolling_max(8, 9) = {}",
            rolling_max(&v, 8, 9)
        );
        // Period 26 (Kijun default): mid-series anchor.
        assert!(
            (rolling_max(&v, 100, 26) - 102.239_652_535_694_93).abs() < 1e-9,
            "rolling_max(100, 26) = {}",
            rolling_max(&v, 100, 26)
        );
        // Period 52 (Senkou-B default): last bar.
        assert!(
            (rolling_max(&v, 199, 52) - 114.610_741_812_740_41).abs() < 1e-9,
            "rolling_max(199, 52) = {}",
            rolling_max(&v, 199, 52)
        );
    }

    // ── Tenkan-Sen / Kijun-Sen ──────────────────────────────────────────

    #[test]
    fn test_tenkan_sen_zero_period_returns_none() {
        assert!(calc_tenkan_sen(&[1.0], &[1.0], 0).is_none());
    }

    #[test]
    fn test_tenkan_sen_mismatched_lengths_returns_none() {
        assert!(calc_tenkan_sen(&[1.0, 2.0], &[1.0], 1).is_none());
    }

    #[test]
    fn test_tenkan_sen_insufficient_data_returns_none() {
        // 3 bars, period 9 → no valid index possible.
        assert!(calc_tenkan_sen(&[1.0, 2.0, 3.0], &[0.5, 1.5, 2.5], 9).is_none());
    }

    #[test]
    fn test_tenkan_sen_constant_high_low_constant_midpoint() {
        // highs ≡ 105, lows ≡ 95 → (HH + LL) / 2 = 100 from i = period-1.
        let n = 20;
        let highs = vec![105.0; n];
        let lows = vec![95.0; n];
        let t = calc_tenkan_sen(&highs, &lows, 9).unwrap();
        assert_eq!(t.len(), n);
        for v in t.iter().take(8) {
            assert!(v.is_nan(), "warm-up index must be NaN, got {}", v);
        }
        for v in t.iter().skip(8) {
            assert!((v - 100.0).abs() < 1e-12, "midpoint != 100: {}", v);
        }
    }

    #[test]
    fn test_tenkan_sen_first_valid_index_at_period_minus_one() {
        // period = 5 → first valid index = 4.
        let highs = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let lows = vec![0.5, 1.5, 2.5, 3.5, 4.5];
        let t = calc_tenkan_sen(&highs, &lows, 5).unwrap();
        assert_eq!(t.len(), 5);
        for v in t.iter().take(4) {
            assert!(v.is_nan());
        }
        // (max(1..5) + min(0.5..4.5)) / 2 = (5 + 0.5) / 2 = 2.75
        assert!((t[4] - 2.75).abs() < 1e-12);
    }

    #[test]
    fn test_tenkan_sen_known_small_fixture() {
        // Hand-computed reference, period 3 — shared bit-for-bit with
        // the Dart mirror.
        // highs: [3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0, 3.0]
        // lows:  [1.0, 0.0, 2.0, 0.0, 4.0, 8.0, 1.0, 5.0, 4.0, 2.0]
        //
        // i=2  → (max(3,1,4)=4   + min(1,0,2)=0  ) / 2 = 2.0
        // i=3  → (max(1,4,1)=4   + min(0,2,0)=0  ) / 2 = 2.0
        // i=4  → (max(4,1,5)=5   + min(2,0,4)=0  ) / 2 = 2.5
        // i=5  → (max(1,5,9)=9   + min(0,4,8)=0  ) / 2 = 4.5
        // i=6  → (max(5,9,2)=9   + min(4,8,1)=1  ) / 2 = 5.0
        // i=7  → (max(9,2,6)=9   + min(8,1,5)=1  ) / 2 = 5.0
        // i=8  → (max(2,6,5)=6   + min(1,5,4)=1  ) / 2 = 3.5
        // i=9  → (max(6,5,3)=6   + min(5,4,2)=2  ) / 2 = 4.0
        let highs = [3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0, 3.0];
        let lows = [1.0, 0.0, 2.0, 0.0, 4.0, 8.0, 1.0, 5.0, 4.0, 2.0];
        let t = calc_tenkan_sen(&highs, &lows, 3).unwrap();
        let expected = [
            (2usize, 2.0),
            (3, 2.0),
            (4, 2.5),
            (5, 4.5),
            (6, 5.0),
            (7, 5.0),
            (8, 3.5),
            (9, 4.0),
        ];
        for &(i, want) in expected.iter() {
            assert!(
                (t[i] - want).abs() < 1e-9,
                "tenkan idx={} want={} got={}", i, want, t[i],
            );
        }
    }

    #[test]
    fn test_kijun_sen_is_midpoint_with_default_period_26() {
        // Same shared math as Tenkan but with the Kijun default period.
        // Synthetic linear ramp: high[i] = i + 1, low[i] = i.
        // At i = 25 (first valid), window is [0..=25]:
        //   HH = 26, LL = 0 → midpoint = 13.0.
        let n = 30;
        let highs: Vec<f64> = (0..n).map(|i| (i + 1) as f64).collect();
        let lows: Vec<f64> = (0..n).map(|i| i as f64).collect();
        let k = calc_kijun_sen(&highs, &lows, 26).unwrap();
        assert_eq!(k.len(), n);
        for v in k.iter().take(25) {
            assert!(v.is_nan(), "warm-up must be NaN, got {}", v);
        }
        assert!((k[25] - 13.0).abs() < 1e-12, "k[25] = {}", k[25]);
        // At i = 26 the window slides to [1..=26]: HH = 27, LL = 1 → 14.0.
        assert!((k[26] - 14.0).abs() < 1e-12, "k[26] = {}", k[26]);
    }

    #[test]
    fn test_tenkan_sen_nan_inside_window_poisons_only_that_bar() {
        // A NaN at index 4 corrupts the midpoint at indices 4..=6 (any
        // window covering bar 4 with period 3) but bar 7's window
        // [5..=7] no longer contains the NaN → valid midpoint resumes.
        let highs = [10.0, 11.0, 12.0, 13.0, f64::NAN, 15.0, 16.0, 17.0];
        let lows = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0];
        let t = calc_tenkan_sen(&highs, &lows, 3).unwrap();
        assert!(t[4].is_nan(), "bar 4 must be NaN, got {}", t[4]);
        assert!(t[5].is_nan(), "bar 5 must be NaN, got {}", t[5]);
        assert!(t[6].is_nan(), "bar 6 must be NaN, got {}", t[6]);
        // i = 7: window [5..=7] = highs [15,16,17] / lows [6,7,8]
        //   → (17 + 6) / 2 = 11.5
        assert!((t[7] - 11.5).abs() < 1e-12, "t[7] = {}", t[7]);
    }

    #[test]
    fn test_tenkan_sen_200_bar_fixture_reference_anchors() {
        // 200-bar fixture parallel to the rolling-window anchors above:
        // highs = parity_fixture_200() + 0.5
        // lows  = parity_fixture_200() - 0.5
        // → midpoint(period=9, i=8)  ≡ rolling_max(values, 8, 9)+0.5
        //                             plus rolling_min(values, 8, 9)-0.5
        //                             divided by 2 — i.e. the running
        //                             midpoint of the band-shifted
        //                             values (locked at 1e-9 to Dart).
        let v = parity_fixture_200();
        let highs: Vec<f64> = v.iter().map(|x| x + 0.5).collect();
        let lows: Vec<f64> = v.iter().map(|x| x - 0.5).collect();

        let t9 = calc_tenkan_sen(&highs, &lows, 9).unwrap();
        // anchor: (rolling_max(v, 8, 9) + 0.5 + rolling_min(v, 8, 9) - 0.5) / 2
        // ≡ (107.70308334140422 + 103.0) / 2 = 105.35154167070211
        assert!(
            (t9[8] - 105.351_541_670_702_1).abs() < 1e-9,
            "tenkan[8] = {}", t9[8]
        );

        let k26 = calc_kijun_sen(&highs, &lows, 26).unwrap();
        // anchor: (102.23965253569493 + 87.04923608392424) / 2
        // = 94.64444430980959 (last digit at the ulp boundary of double).
        assert!(
            (k26[100] - 94.644_444_309_809_6).abs() < 1e-9,
            "kijun[100] = {}", k26[100]
        );
    }

    #[test]
    fn test_rolling_min_200_bar_fixture_reference_anchors() {
        let v = parity_fixture_200();
        // i=0: 100 + 10*sin(0) + 3*cos(0) + 0 = 103.0 exactly — the
        // minimum of the first 9 bars lands on this clean integer value.
        assert!(
            (rolling_min(&v, 8, 9) - 103.0).abs() < 1e-9,
            "rolling_min(8, 9) = {}",
            rolling_min(&v, 8, 9)
        );
        assert!(
            (rolling_min(&v, 100, 26) - 87.049_236_083_924_24).abs() < 1e-9,
            "rolling_min(100, 26) = {}",
            rolling_min(&v, 100, 26)
        );
        assert!(
            (rolling_min(&v, 199, 52) - 89.631_035_346_668_07).abs() < 1e-9,
            "rolling_min(199, 52) = {}",
            rolling_min(&v, 199, 52)
        );
    }
}
