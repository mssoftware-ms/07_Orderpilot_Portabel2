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

// ─── Senkou-Span A / B (cloud edges) ───────────────────────────────────────

/// Canonical Ichimoku cloud-shift in bars (Spec §1.1 — Senkou-Span A/B
/// are visually displaced **forward** by this many bars; Chikou-Span is
/// displaced **backward** by the same amount). Hard-coded here because
/// every read-anchor helper below assumes this value; making it a
/// parameter would change three signatures simultaneously and force
/// every strategy to thread the value through.
pub const CLOUD_SHIFT_BARS: usize = 26;

/// Compute **Senkou-Span A** = `(Tenkan + Kijun) / 2`.
///
/// The output is stored **time-aligned to the bar at which both inputs
/// were computed** — there is NO future-shift baked into storage. The
/// visual `+26`-bar shift happens at READ time via the explicit
/// read-anchor helpers [`future_senkou_at_i`] (still-projected cloud)
/// and [`past_senkou_at_i_minus_26`] (cloud currently plotted at bar
/// `i`). See module doc for the rationale (no-look-ahead).
///
/// Returns `None` if the two inputs have mismatched lengths. NaN inputs
/// propagate per-bar (any NaN ⇒ NaN slot).
pub fn calc_senkou_span_a(tenkan: &[f64], kijun: &[f64]) -> Option<Vec<f64>> {
    if tenkan.len() != kijun.len() {
        return None;
    }
    let n = tenkan.len();
    let mut out = vec![f64::NAN; n];
    for (i, slot) in out.iter_mut().enumerate() {
        let t = tenkan[i];
        let k = kijun[i];
        if !t.is_nan() && !k.is_nan() {
            *slot = (t + k) / 2.0;
        }
    }
    Some(out)
}

/// Compute **Senkou-Span B** = `(HH_period + LL_period) / 2`.
///
/// Same midpoint math as [`calc_tenkan_sen`] / [`calc_kijun_sen`] with
/// the canonical 52-bar window (Spec §1.1 default `period = 52`).
/// Storage convention is identical to [`calc_senkou_span_a`] — no
/// future-shift in storage; reads go through the explicit helpers.
pub fn calc_senkou_span_b(
    highs: &[f64],
    lows: &[f64],
    period: usize,
) -> Option<Vec<f64>> {
    calc_midpoint_series(highs, lows, period)
}

// ─── Senkou-Span read anchors (explicit time-shift semantics) ──────────────
//
// These three helpers exist so strategy code reads self-documentingly
// instead of indexing raw `span[i]` / `span[i - 26]` without context.
// All three are pure index-into-slice; the only purpose is to pin
// temporal intent at every call site (Spec §1.1).

/// Read the Senkou-Span value computed at bar `i` — no time-shift
/// interpretation. Returns `NaN` for `i >= span.len()`.
///
/// Neutral helper: callers that don't need to disambiguate
/// past/future cloud semantics use this one and document context
/// separately.
pub fn senkou_at_i(span: &[f64], i: usize) -> f64 {
    if i >= span.len() {
        f64::NAN
    } else {
        span[i]
    }
}

/// Read the Senkou-Span value that, when visualized on a chart, will
/// be plotted at bar `i + 26` — the "still-projected" cloud computed
/// at bar `i`.
///
/// Numerically identical to [`senkou_at_i`] (because the visual
/// `+26`-shift happens at chart-render time, NOT in storage). Exists
/// so a strategy call site like
/// `future_senkou_at_i(&span_a, i) > kijun[i]` reads as "the cloud
/// projected forward from now is above Kijun", rather than the
/// opaque `span_a[i] > kijun[i]`.
pub fn future_senkou_at_i(span: &[f64], i: usize) -> f64 {
    senkou_at_i(span, i)
}

/// Read the Senkou-Span value that gets visualized **at bar `i`
/// itself** — i.e. the cloud currently plotted at bar `i`, which was
/// computed 26 bars ago. Returns `None` if `i < CLOUD_SHIFT_BARS` (no
/// prior history) or `i - CLOUD_SHIFT_BARS` is past the slice end.
///
/// This is the workhorse for Ichimoku confluence at bar `i`: to ask
/// "is the close above the current cloud?", compare `close[i]` to
/// `past_senkou_at_i_minus_26(&span_a, i)` and
/// `past_senkou_at_i_minus_26(&span_b, i)`. The helper proves
/// no-look-ahead by construction — it only ever reads `span[i - 26]`,
/// which depends on data at or before bar `i - 26 ≤ i`.
pub fn past_senkou_at_i_minus_26(span: &[f64], i: usize) -> Option<f64> {
    if i < CLOUD_SHIFT_BARS {
        return None;
    }
    let j = i - CLOUD_SHIFT_BARS;
    if j >= span.len() {
        None
    } else {
        Some(span[j])
    }
}

// ─── Chikou-Span (lagging line) ────────────────────────────────────────────

/// Compute the **Chikou-Span** (Lagging Line) series.
///
/// Definition (Spec §1.1): Chikou-Span is the close price, visualized
/// **shifted 26 bars backward**. As with the Senkou-Spans, the visual
/// displacement happens at chart-render time, NOT in storage. The
/// helper therefore returns a verbatim copy of `closes` and the
/// strategy reads through the intent-explicit anchor helpers below.
///
/// Returning a `Vec<f64>` (rather than `&closes`) gives strategy code
/// an owned series it can pass through state snapshots / FFI bridges
/// without worrying about lifetimes.
pub fn calc_chikou_span(closes: &[f64]) -> Vec<f64> {
    closes.to_vec()
}

/// Chikou-Span confirmation for a **long** entry at bar `i`.
///
/// Rule (Spec §1.1, classical Ichimoku): the Chikou-Span — visually
/// plotted at bar `i - 26` with value `close[i]` — must be **above**
/// the actual close at that historical bar, i.e. `close[i] > close[i - 26]`.
/// Equivalent to "current close exceeds the close 26 bars ago".
///
/// Returns `None` if `i < CLOUD_SHIFT_BARS` (no prior history) or
/// `i >= closes.len()` (defensive against out-of-bounds reads).
/// Returns `Some(true/false)` otherwise — no NaN propagation needed
/// because a strict `>` comparison with NaN is always false in IEEE.
pub fn chikou_confirms_long(closes: &[f64], i: usize) -> Option<bool> {
    if i < CLOUD_SHIFT_BARS || i >= closes.len() {
        return None;
    }
    Some(closes[i] > closes[i - CLOUD_SHIFT_BARS])
}

/// Chikou-Span confirmation for a **short** entry at bar `i`.
///
/// Mirror of [`chikou_confirms_long`] — the Chikou-Span plotted at
/// bar `i - 26` must be **below** the historical close, i.e.
/// `close[i] < close[i - 26]`. Returns `None` if the comparison
/// isn't available yet.
pub fn chikou_confirms_short(closes: &[f64], i: usize) -> Option<bool> {
    if i < CLOUD_SHIFT_BARS || i >= closes.len() {
        return None;
    }
    Some(closes[i] < closes[i - CLOUD_SHIFT_BARS])
}

// ─── Ichimoku confluence score (Spec §12.2 default convention) ─────────────

/// Per-component weight used by [`calc_ichimoku_score`] — three
/// independent components × ±[`SCORE_WEIGHT`] = a [-60, +60] range.
/// Exposed as a `pub const` so strategy thresholds (Spec §12.2 default
/// = ±60 = full confluence) can refer to `3 * SCORE_WEIGHT` instead of
/// embedding the magic number.
pub const SCORE_WEIGHT: i32 = 20;

/// Compute the Ichimoku confluence score at bar `i`.
///
/// Score is the sum of three independent ±[`SCORE_WEIGHT`] components
/// (Spec §12.2 default convention):
///
/// 1. **Cross** (Tenkan vs Kijun at bar `i`):
///    - `+SCORE_WEIGHT` if `tenkan[i] > kijun[i]`
///    - `-SCORE_WEIGHT` if `tenkan[i] < kijun[i]`
///    - `0` if equal or either is `NaN`.
///
/// 2. **Color** (currently-visible cloud at bar `i`):
///    - `+SCORE_WEIGHT` if `past_span_a > past_span_b` (green cloud)
///    - `-SCORE_WEIGHT` if `past_span_a < past_span_b` (red cloud)
///    - `0` if equal, either NaN, or the past-shifted reads are
///      unavailable (warm-up region, `i < 26`).
///
/// 3. **Distance** (close vs the visible cloud band):
///    - `+SCORE_WEIGHT` if `close[i] > max(past_a, past_b)`
///    - `-SCORE_WEIGHT` if `close[i] < min(past_a, past_b)`
///    - `0` if the close is inside the cloud, any input is `NaN`, or
///      the past-shifted cloud reads are unavailable.
///
/// Total range: `[-60, +60]`. The canonical Spec §12.2 entry threshold
/// is `±60` ("all three components confluent in the same direction").
///
/// "Past cloud" reads go through [`past_senkou_at_i_minus_26`] — the
/// cloud actually visible at bar `i`, computed 26 bars ago — which
/// makes the score consistent with what a chart trader would see.
pub fn calc_ichimoku_score(
    tenkan: &[f64],
    kijun: &[f64],
    span_a: &[f64],
    span_b: &[f64],
    close: &[f64],
    i: usize,
) -> i32 {
    // Defensive bounds check — out-of-range `i` yields a 0 score
    // (interpretable as "no confluence detected at an invalid bar").
    if i >= tenkan.len() || i >= kijun.len() || i >= close.len() {
        return 0;
    }

    let mut score: i32 = 0;

    // Component 1: Tenkan vs Kijun cross.
    let t = tenkan[i];
    let k = kijun[i];
    if !t.is_nan() && !k.is_nan() {
        if t > k {
            score += SCORE_WEIGHT;
        } else if t < k {
            score -= SCORE_WEIGHT;
        }
    }

    // Past-shifted cloud reads — both component 2 and 3 use the same
    // pair of values, so compute once.
    let past_a = past_senkou_at_i_minus_26(span_a, i);
    let past_b = past_senkou_at_i_minus_26(span_b, i);

    if let (Some(a), Some(b)) = (past_a, past_b) {
        if !a.is_nan() && !b.is_nan() {
            // Component 2: cloud color.
            if a > b {
                score += SCORE_WEIGHT;
            } else if a < b {
                score -= SCORE_WEIGHT;
            }

            // Component 3: close vs cloud band.
            let c = close[i];
            if !c.is_nan() {
                let top = a.max(b);
                let bottom = a.min(b);
                if c > top {
                    score += SCORE_WEIGHT;
                } else if c < bottom {
                    score -= SCORE_WEIGHT;
                }
            }
        }
    }

    score
}

// ─── IchimokuStrategy ──────────────────────────────────────────────────────

use std::collections::HashMap;

use crate::models::{Candle, Timeframe};
use crate::strategy::{
    AddinManifest, Context, InputSpec, ParameterSchema, Signal, StrategyAddin,
    StrategyCategory,
};

/// Ichimoku Cloud Retest (Endstand-Variante) strategy add-in.
///
/// Body-struct (not unit-struct) so the flutter_rust_bridge codegen
/// pipeline can introspect it — FRB rejects unit structs. The strategy
/// is fully stateless; all per-run state lives on `Context`.
///
/// Welle I2-1 only lands the manifest + skeleton. `on_candle` is a
/// warm-up-gated stub that emits `NoAction` after the 78-bar Ichimoku
/// boundary so callers can wire the strategy into the engine without
/// crashes. The 5-confluence entry logic from Spec §2/§3 lands in I2-2.
#[derive(Debug, Clone, Default)]
pub struct IchimokuStrategy {}

impl IchimokuStrategy {
    pub fn new() -> Self {
        Self {}
    }
}

impl StrategyAddin for IchimokuStrategy {
    fn manifest(&self) -> AddinManifest {
        ichimoku_manifest()
    }

    fn required_inputs(&self) -> Vec<InputSpec> {
        // Senkou-B(52) + cloud shift(26) = 78 dominates the warm-up; we
        // add headroom so the Ichimoku-Score can settle. Mirrors the
        // start_idx computation in `on_candle` below.
        vec![
            InputSpec::OhlcvTimeframe(Timeframe::H1),
            InputSpec::MinCandles(100),
            InputSpec::Indicator("Ichimoku".to_string()),
        ]
    }

    fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
        // Welle I2-1 skeleton: hold the warm-up gate so the engine can
        // step the strategy without triggering an out-of-bounds read in
        // the indicator helpers, but DO NOT emit entries yet — that is
        // I2-2's scope. Returning `NoAction` (vs `None`) lets the
        // BacktestEngine still record per-bar state without treating
        // the bar as a missing call.
        let senkou_b_period = ctx.param_or("senkou_b_period", 52.0) as usize;
        let shift = ctx.param_or("shift", 26.0) as usize;
        let start_idx = senkou_b_period + shift;
        if ctx.index() < start_idx {
            return None;
        }
        Some(Signal::NoAction)
    }

    fn on_reset(&mut self) {
        // Stateless — every on_candle rebuilds the indicator series
        // from `ctx.all_candles()`. Nothing to clear here.
    }

    fn validate_params(&self, params: &HashMap<String, f64>) -> Result<(), String> {
        for schema in &self.manifest().parameters {
            if let Some(&val) = params.get(&schema.name) {
                schema.validate(val)?;
            }
        }
        Ok(())
    }
}

/// Build the canonical AddinManifest for the Ichimoku Cloud Retest
/// strategy. Defaults match `01_Projectplan/specs/ichimoku_spec.md` and
/// the engineering plan §2 Welle I2 parameter table; the strict-spec
/// `score_threshold = 60` (Spec §12.2) gates entries to "all three
/// components confluent in the same direction".
pub fn ichimoku_manifest() -> AddinManifest {
    AddinManifest {
        id: "ichimoku_v1".to_string(),
        name: "Ichimoku Cloud Retest (Endstand-Variante)".to_string(),
        version: "1.0.0".to_string(),
        author: "Trading App Team".to_string(),
        description:
            "Trend-following strategy: 5-confluence entry (price vs cloud, future cloud color, \
             Tenkan vs Kijun, Chikou vs past cloud, Ichimoku-Score), SL at min(Kijun, cloud bottom) \
             for long / max for short, R:R 1:2 with engine-side break-even trail."
                .to_string(),
        category: StrategyCategory::Trend,
        timeframes: vec![Timeframe::H1, Timeframe::H4],
        parameters: vec![
            // Spec §1 standard Ichimoku periods.
            ParameterSchema::new("tenkan_period", "Tenkan-Sen Period", 9.0, 3.0, 30.0, 1.0),
            ParameterSchema::new("kijun_period", "Kijun-Sen Period", 26.0, 5.0, 100.0, 1.0),
            ParameterSchema::new(
                "senkou_b_period",
                "Senkou-Span B Period",
                52.0,
                10.0,
                200.0,
                1.0,
            ),
            // Cloud-shift / Chikou-lag in bars. `CLOUD_SHIFT_BARS` is the
            // hard-coded value used by the read-anchor helpers; the
            // parameter lets the manifest surface the convention but the
            // strategy still reads through the const internally.
            ParameterSchema::new("shift", "Cloud / Chikou Shift", 26.0, 5.0, 100.0, 1.0),
            // Spec §12.2 default: ±60 = "3 × SCORE_WEIGHT" = full
            // confluence (all three Cross/Color/Distance components in
            // the same direction). Long fires at `score >= +threshold`,
            // short at `score <= -threshold`.
            ParameterSchema::new(
                "score_threshold",
                "Ichimoku-Score Threshold (±)",
                60.0,
                20.0,
                100.0,
                5.0,
            ),
            // Spec §5: R:R 1:2 with engine-driven BE-trail at +1R.
            ParameterSchema::new("tp_rr_ratio", "TP R:R Ratio", 2.0, 0.5, 10.0, 0.1),
            // Spec §8: 2 % of equity per trade.
            ParameterSchema::new("risk_per_trade", "Risk Per Trade", 0.02, 0.001, 1.0, 0.001),
            // Spec §4 algorithmic SL distance uses kijun/cloud anchors;
            // `swing_lookback_bars` is currently unused by the Ichimoku
            // SL (kept in the manifest so a Phase-3 hybrid SL variant
            // can opt in without breaking the parameter map).
            ParameterSchema::new(
                "swing_lookback_bars",
                "Swing Lookback Bars",
                20.0,
                5.0,
                100.0,
                1.0,
            ),
            // Spec §7 session filter (London + NY). Default OFF for
            // BTCUSDT (24/7); Phase-3 EUR/USD reruns can enable it
            // without code changes.
            ParameterSchema::new(
                "session_filter_enabled",
                "Session Filter Enabled (0/1)",
                0.0,
                0.0,
                1.0,
                1.0,
            ),
            ParameterSchema::new(
                "session_start_hour",
                "Session Start Hour (local)",
                9.0,
                0.0,
                23.0,
                1.0,
            ),
            ParameterSchema::new(
                "session_end_hour",
                "Session End Hour (local)",
                23.0,
                1.0,
                24.0,
                1.0,
            ),
            // Local timezone offset east of UTC (Berlin = +1, no DST).
            // Range covers the major liquid trading sessions.
            ParameterSchema::new(
                "tz_offset_hours",
                "Local TZ Offset (hours east of UTC)",
                1.0,
                -12.0,
                14.0,
                1.0,
            ),
        ],
    }
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

    // ── Senkou-Span A / B ───────────────────────────────────────────────

    #[test]
    fn test_senkou_span_a_mismatched_lengths_returns_none() {
        assert!(calc_senkou_span_a(&[1.0, 2.0], &[1.0]).is_none());
    }

    #[test]
    fn test_senkou_span_a_propagates_nan_per_bar() {
        // tenkan[0] = NaN (warm-up) → span_a[0] = NaN; bar 1 both
        // present → span_a[1] = (10 + 20) / 2 = 15.
        let tenkan = [f64::NAN, 10.0, 12.0];
        let kijun = [5.0, 20.0, f64::NAN];
        let a = calc_senkou_span_a(&tenkan, &kijun).unwrap();
        assert!(a[0].is_nan(), "a[0] = {}", a[0]);
        assert!((a[1] - 15.0).abs() < 1e-12, "a[1] = {}", a[1]);
        assert!(a[2].is_nan(), "a[2] = {}", a[2]);
    }

    #[test]
    fn test_senkou_span_a_average_of_tenkan_and_kijun() {
        // span_a is purely (t + k) / 2 — verify across a longer fixture.
        let tenkan: Vec<f64> = (0..10).map(|i| i as f64).collect();
        let kijun: Vec<f64> = (0..10).map(|i| (i as f64) * 2.0).collect();
        let a = calc_senkou_span_a(&tenkan, &kijun).unwrap();
        for (i, got) in a.iter().enumerate() {
            let want = (i as f64 + 2.0 * i as f64) / 2.0;
            assert!((got - want).abs() < 1e-12, "a[{}] = {}", i, got);
        }
    }

    #[test]
    fn test_senkou_span_b_zero_period_returns_none() {
        assert!(calc_senkou_span_b(&[1.0], &[1.0], 0).is_none());
    }

    #[test]
    fn test_senkou_span_b_uses_period_52_midpoint() {
        // 60 bars, period 52 — first valid index = 51. high[i]=i+1,
        // low[i]=i. At i=51: HH=52, LL=0 → midpoint=26.0.
        let n = 60;
        let highs: Vec<f64> = (0..n).map(|i| (i + 1) as f64).collect();
        let lows: Vec<f64> = (0..n).map(|i| i as f64).collect();
        let b = calc_senkou_span_b(&highs, &lows, 52).unwrap();
        for v in b.iter().take(51) {
            assert!(v.is_nan(), "warm-up must be NaN, got {}", v);
        }
        assert!((b[51] - 26.0).abs() < 1e-12, "b[51] = {}", b[51]);
        // At i=52: window slides → HH=53, LL=1 → 27.0.
        assert!((b[52] - 27.0).abs() < 1e-12, "b[52] = {}", b[52]);
    }

    // ── Read anchors (senkou_at_i / future_/ past_) ─────────────────────

    #[test]
    fn test_senkou_at_i_out_of_bounds_returns_nan() {
        let span = [1.0, 2.0, 3.0];
        assert!(senkou_at_i(&span, 5).is_nan());
    }

    #[test]
    fn test_senkou_at_i_returns_raw_value() {
        let span = [10.0, 20.0, 30.0];
        assert!((senkou_at_i(&span, 0) - 10.0).abs() < 1e-12);
        assert!((senkou_at_i(&span, 2) - 30.0).abs() < 1e-12);
    }

    #[test]
    fn test_future_senkou_at_i_numerically_equals_senkou_at_i() {
        // Future-shift semantics happen at chart-render time, NOT in
        // storage — so future_senkou_at_i is bit-identical to
        // senkou_at_i. Pin that contract so a "helpful" optimisation
        // can't quietly drift the two apart.
        let span: Vec<f64> = (0..50).map(|i| 100.0 + i as f64 * 0.5).collect();
        for i in 0..50 {
            let a = senkou_at_i(&span, i);
            let b = future_senkou_at_i(&span, i);
            assert!(
                (a - b).abs() < 1e-12 || (a.is_nan() && b.is_nan()),
                "future_senkou_at_i diverged from senkou_at_i at i={}: {} vs {}",
                i, a, b,
            );
        }
    }

    #[test]
    fn test_past_senkou_at_i_minus_26_none_for_i_below_shift() {
        let span = vec![1.0; 100];
        assert!(past_senkou_at_i_minus_26(&span, 0).is_none());
        assert!(past_senkou_at_i_minus_26(&span, 25).is_none());
    }

    #[test]
    fn test_past_senkou_at_i_minus_26_returns_span_at_i_minus_26() {
        let span: Vec<f64> = (0..100).map(|i| i as f64 * 0.5).collect();
        // i = 26 → span[0] = 0.0
        assert_eq!(past_senkou_at_i_minus_26(&span, 26), Some(0.0));
        // i = 80 → span[54] = 27.0
        assert_eq!(past_senkou_at_i_minus_26(&span, 80), Some(27.0));
    }

    #[test]
    fn test_past_senkou_at_i_minus_26_none_for_i_beyond_span() {
        // i - 26 >= len → None (defensive against caller bugs feeding
        // a bar index past the available span).
        let span = vec![1.0; 30];
        // i = 56 → j = 30, which is >= len = 30 → None.
        assert!(past_senkou_at_i_minus_26(&span, 56).is_none());
    }

    #[test]
    fn test_no_look_ahead_past_cloud_at_i_only_uses_data_at_or_before_i() {
        // No-look-ahead beleg: build a tenkan/kijun pair where everything
        // past bar `cutoff` is poisoned with NaN. The cloud-at-bar-i read
        // (past_senkou_at_i_minus_26) for i <= cutoff must NEVER touch the
        // NaN region — proven by getting a finite value back even though
        // the slice after `cutoff` is corrupt.
        let n = 100;
        let cutoff: usize = 50;
        let tenkan: Vec<f64> = (0..n)
            .map(|i| if i <= cutoff { 100.0 + i as f64 } else { f64::NAN })
            .collect();
        let kijun: Vec<f64> = (0..n)
            .map(|i| if i <= cutoff { 200.0 + i as f64 } else { f64::NAN })
            .collect();
        let span_a = calc_senkou_span_a(&tenkan, &kijun).unwrap();
        // At i = cutoff = 50, past cloud reads span_a[24] = (124 + 224)/2 = 174
        let got = past_senkou_at_i_minus_26(&span_a, cutoff).unwrap();
        assert!((got - 174.0).abs() < 1e-12, "got = {}", got);
        // The NaN region only kicks in at i = cutoff + 26 = 76 onward.
        assert!(past_senkou_at_i_minus_26(&span_a, 75).unwrap().is_finite());
        assert!(past_senkou_at_i_minus_26(&span_a, 77).unwrap().is_nan());
    }

    // ── Chikou-Span helpers ─────────────────────────────────────────────

    #[test]
    fn test_chikou_span_returns_verbatim_copy_of_closes() {
        let closes = [100.0, 101.0, 99.5, 102.0];
        let c = calc_chikou_span(&closes);
        assert_eq!(c.len(), closes.len());
        for (i, &v) in c.iter().enumerate() {
            assert!((v - closes[i]).abs() < 1e-12);
        }
    }

    #[test]
    fn test_chikou_confirms_long_none_before_shift() {
        let closes = vec![100.0; 100];
        assert!(chikou_confirms_long(&closes, 0).is_none());
        assert!(chikou_confirms_long(&closes, 25).is_none());
    }

    #[test]
    fn test_chikou_confirms_long_uses_close_at_i_vs_i_minus_26() {
        // Linear ramp: close[i] = i. Then close[26] = 26 > close[0] = 0
        // → confirms_long = true. close[26] < close[26+1] in flat
        // counter-example: build inverted ramp.
        let closes_up: Vec<f64> = (0..50).map(|i| i as f64).collect();
        assert_eq!(chikou_confirms_long(&closes_up, 26), Some(true));
        assert_eq!(chikou_confirms_long(&closes_up, 49), Some(true));

        let closes_down: Vec<f64> =
            (0..50).map(|i| 100.0 - i as f64).collect();
        assert_eq!(chikou_confirms_long(&closes_down, 26), Some(false));
    }

    #[test]
    fn test_chikou_confirms_short_mirrors_long() {
        let closes_down: Vec<f64> =
            (0..50).map(|i| 100.0 - i as f64).collect();
        // close[26] = 74 < close[0] = 100 → short confirmed
        assert_eq!(chikou_confirms_short(&closes_down, 26), Some(true));

        let closes_up: Vec<f64> = (0..50).map(|i| i as f64).collect();
        assert_eq!(chikou_confirms_short(&closes_up, 26), Some(false));
    }

    #[test]
    fn test_chikou_helpers_none_for_i_out_of_bounds() {
        let closes = vec![1.0; 30];
        assert!(chikou_confirms_long(&closes, 30).is_none());
        assert!(chikou_confirms_short(&closes, 30).is_none());
    }

    // ── Ichimoku score helper ───────────────────────────────────────────

    /// Build a 60-bar fixture where, at bar `i = 50`:
    /// - tenkan[50] vs kijun[50] is configurable
    /// - past_span_a[24] vs past_span_b[24] is configurable (since
    ///   past_senkou_at_i_minus_26(_, 50) reads index 50 - 26 = 24)
    /// - close[50] is configurable
    #[allow(clippy::type_complexity)] // 5-tuple of Vec<f64> is the clearest shape; flattening to a struct hurts test ergonomics.
    fn score_fixture(
        tenkan_50: f64,
        kijun_50: f64,
        past_span_a_24: f64,
        past_span_b_24: f64,
        close_50: f64,
    ) -> (Vec<f64>, Vec<f64>, Vec<f64>, Vec<f64>, Vec<f64>) {
        let n = 60;
        let mut tenkan = vec![0.0; n];
        let mut kijun = vec![0.0; n];
        let mut span_a = vec![0.0; n];
        let mut span_b = vec![0.0; n];
        let mut close = vec![100.0; n];
        tenkan[50] = tenkan_50;
        kijun[50] = kijun_50;
        span_a[24] = past_span_a_24;
        span_b[24] = past_span_b_24;
        close[50] = close_50;
        (tenkan, kijun, span_a, span_b, close)
    }

    #[test]
    fn test_score_full_long_confluence_is_plus_60() {
        // Cross+, Color+, Distance+ → +60 (Spec §12.2 long threshold).
        let (t, k, a, b, c) = score_fixture(
            /* tenkan */ 110.0,
            /* kijun  */ 100.0,  // tenkan > kijun → +20
            /* span_a (past) */ 105.0,
            /* span_b (past) */ 95.0,   // a > b → +20
            /* close */ 120.0,           // > top(105) → +20
        );
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 50), 60);
    }

    #[test]
    fn test_score_full_short_confluence_is_minus_60() {
        // Cross-, Color-, Distance- → -60.
        let (t, k, a, b, c) = score_fixture(
            100.0, 110.0,  // tenkan < kijun → -20
            95.0, 105.0,   // a < b → -20
            80.0,          // < bottom(95) → -20
        );
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 50), -60);
    }

    #[test]
    fn test_score_components_independent_partial_sums() {
        // Cross+ only (Color = 0 because a == b, Distance = 0 because
        // close inside cloud).
        let (t, k, a, b, c) = score_fixture(110.0, 100.0, 100.0, 100.0, 100.0);
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 50), 20);

        // Color+ only: tenkan == kijun (Cross = 0); close == cloud_top
        // (Distance = 0 because strict >).
        let (t, k, a, b, c) = score_fixture(100.0, 100.0, 110.0, 90.0, 110.0);
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 50), 20);

        // Distance+ only: equal tenkan/kijun + equal spans + close above
        // the (degenerate-equal) cloud.
        let (t, k, a, b, c) = score_fixture(100.0, 100.0, 100.0, 100.0, 120.0);
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 50), 20);
    }

    #[test]
    fn test_score_close_inside_cloud_distance_is_zero() {
        // close strictly between bottom(95) and top(105) → Distance = 0.
        // Tenkan == Kijun → Cross = 0. a > b → Color = +20.
        // Total = +20 only.
        let (t, k, a, b, c) = score_fixture(100.0, 100.0, 105.0, 95.0, 100.0);
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 50), 20);
    }

    #[test]
    fn test_score_nan_inputs_suppress_individual_components() {
        // NaN tenkan → Cross = 0; rest works.
        let (mut t, mut k, a, b, c) = score_fixture(110.0, 100.0, 105.0, 95.0, 120.0);
        t[50] = f64::NAN;
        // Color (+20) + Distance (+20) = +40, Cross suppressed.
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 50), 40);

        // Restore tenkan, NaN-ify kijun → Cross = 0 again.
        t[50] = 110.0;
        k[50] = f64::NAN;
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 50), 40);
    }

    #[test]
    fn test_score_warmup_below_cloud_shift_only_cross_fires() {
        // At i = 25, past_senkou_at_i_minus_26 returns None → Color
        // and Distance both suppressed. Only Cross can contribute.
        let n = 60;
        let mut t = vec![0.0; n];
        let mut k = vec![0.0; n];
        let a = vec![1.0; n];  // past reads → None for i < 26
        let b = vec![2.0; n];
        let c = vec![100.0; n];
        t[25] = 110.0;
        k[25] = 100.0;
        // Cross+ alone → +20.
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 25), 20);
    }

    #[test]
    fn test_score_out_of_bounds_index_returns_zero() {
        let (t, k, a, b, c) = score_fixture(110.0, 100.0, 105.0, 95.0, 120.0);
        // i past close length → defensive return 0.
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 200), 0);
    }

    #[test]
    fn test_score_threshold_boundary_plus_60_means_full_long_confluence() {
        // Pin the canonical ±60 boundary used by Spec §12.2: a Long
        // entry triggers when the score is exactly +60 (= 3 ×
        // SCORE_WEIGHT). Anything below — even +59 — must not trigger.
        // Construct the fixture so all three components fire and verify
        // the exact value, then verify the boundary semantics by
        // weakening one component to confirm the drop to +40.
        let (t, k, a, b, c) = score_fixture(110.0, 100.0, 105.0, 95.0, 120.0);
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c, 50), 60);
        // 3 * SCORE_WEIGHT = ±60 — pin the relationship so a future
        // bump to SCORE_WEIGHT propagates through this assertion.
        assert_eq!(3 * SCORE_WEIGHT, 60);

        // Weaken the Distance component (close inside the cloud) → +40.
        let (t, k, a, b, mut c2) = score_fixture(110.0, 100.0, 105.0, 95.0, 100.0);
        c2[50] = 100.0;
        assert_eq!(calc_ichimoku_score(&t, &k, &a, &b, &c2, 50), 40);
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

    // ── Manifest / skeleton (Welle I2-1) ────────────────────────────────

    #[test]
    fn test_ichimoku_manifest_id_category_timeframes() {
        let m = ichimoku_manifest();
        assert_eq!(m.id, "ichimoku_v1");
        assert_eq!(m.category, StrategyCategory::Trend);
        // Spec §1: 1h is the video baseline TF; 4h is the Mandatory
        // Sanity-Sweep partner. Pin both so an accidental drop here
        // would fail loud.
        assert!(m.timeframes.contains(&Timeframe::H1));
        assert!(m.timeframes.contains(&Timeframe::H4));
    }

    #[test]
    fn test_ichimoku_manifest_has_all_12_parameters_with_spec_defaults() {
        // The 12 parameters mandated by `01_Projectplan/specs/ichimoku_engineering_plan.md`
        // §2 Welle I2 table, each with their spec-default. Locked here so
        // any drift surfaces immediately rather than during a downstream
        // Dart-Rust parameter-map mismatch.
        let m = ichimoku_manifest();
        let expected: &[(&str, f64)] = &[
            ("tenkan_period", 9.0),
            ("kijun_period", 26.0),
            ("senkou_b_period", 52.0),
            ("shift", 26.0),
            ("score_threshold", 60.0),
            ("tp_rr_ratio", 2.0),
            ("risk_per_trade", 0.02),
            ("swing_lookback_bars", 20.0),
            ("session_filter_enabled", 0.0),
            ("session_start_hour", 9.0),
            ("session_end_hour", 23.0),
            ("tz_offset_hours", 1.0),
        ];
        assert_eq!(
            m.parameters.len(),
            expected.len(),
            "manifest should expose exactly {} parameters, found {}",
            expected.len(),
            m.parameters.len()
        );
        for &(name, default) in expected {
            let p = m
                .parameters
                .iter()
                .find(|p| p.name == name)
                .unwrap_or_else(|| panic!("manifest missing parameter '{}'", name));
            assert!(
                (p.default - default).abs() < 1e-12,
                "{} default = {}, want {}",
                name,
                p.default,
                default
            );
        }
    }

    #[test]
    fn test_ichimoku_manifest_score_threshold_matches_three_score_weights() {
        // Spec §12.2: the canonical "full confluence" threshold is
        // `3 * SCORE_WEIGHT = 60`. Pin the relationship so a future bump
        // to SCORE_WEIGHT propagates through the manifest default.
        let m = ichimoku_manifest();
        let st = m
            .parameters
            .iter()
            .find(|p| p.name == "score_threshold")
            .unwrap();
        assert_eq!(st.default as i32, 3 * SCORE_WEIGHT);
    }

    #[test]
    fn test_ichimoku_validate_params_ok_and_out_of_range() {
        let s = IchimokuStrategy::new();
        let mut ok = HashMap::new();
        ok.insert("score_threshold".to_string(), 80.0);
        ok.insert("tp_rr_ratio".to_string(), 1.5);
        assert!(s.validate_params(&ok).is_ok());

        let mut bad = HashMap::new();
        bad.insert("score_threshold".to_string(), 200.0); // max is 100
        assert!(s.validate_params(&bad).is_err());
    }

    #[test]
    fn test_ichimoku_skeleton_no_signal_during_warmup() {
        // 10 candles is far below the 78-bar warm-up gate — every
        // on_candle call must return `None` (warm-up region).
        let mut s = IchimokuStrategy::new();
        let candles: Vec<Candle> = (0..10)
            .map(|i| Candle::new(i * 3_600_000, 100.0, 101.0, 99.0, 100.0, 1.0))
            .collect();
        let mut ctx = Context::new(candles.clone(), Timeframe::H1, HashMap::new());
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            assert!(s.on_candle(&mut ctx, candle).is_none(), "bar {} produced a signal", i);
        }
    }

    #[test]
    fn test_ichimoku_skeleton_emits_no_action_after_warmup() {
        // Welle I2-1 guarantees only the warm-up gate + a `NoAction`
        // pass-through past it. Confluence-based entries land in I2-2;
        // this test will be widened then.
        let mut s = IchimokuStrategy::new();
        let n = 100; // > 78-bar warm-up
        let candles: Vec<Candle> = (0..n)
            .map(|i| Candle::new(i * 3_600_000, 100.0, 101.0, 99.0, 100.0, 1.0))
            .collect();
        let mut ctx = Context::new(candles.clone(), Timeframe::H1, HashMap::new());
        // Spec §1.1 minimum warm-up: senkou_b(52) + shift(26) = 78.
        let start_idx = 78usize;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            let sig = s.on_candle(&mut ctx, candle);
            if i < start_idx {
                assert!(sig.is_none(), "bar {} (warm-up) emitted {:?}", i, sig);
            } else {
                assert_eq!(
                    sig,
                    Some(Signal::NoAction),
                    "bar {} should emit NoAction skeleton",
                    i
                );
            }
        }
    }

    #[test]
    fn test_ichimoku_skeleton_warmup_respects_override_periods() {
        // Smaller senkou_b/shift override → smaller warm-up gate. Proves
        // the start_idx math is parameterised, not hard-coded to 78.
        let mut s = IchimokuStrategy::new();
        let n = 50;
        let candles: Vec<Candle> = (0..n)
            .map(|i| Candle::new(i * 3_600_000, 100.0, 101.0, 99.0, 100.0, 1.0))
            .collect();
        let params = HashMap::from([
            ("senkou_b_period".to_string(), 10.0),
            ("shift".to_string(), 5.0),
        ]);
        let mut ctx = Context::new(candles.clone(), Timeframe::H1, params);
        let start_idx = 15usize; // 10 + 5
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            let sig = s.on_candle(&mut ctx, candle);
            if i < start_idx {
                assert!(sig.is_none(), "bar {} warm-up violated", i);
            } else {
                assert_eq!(sig, Some(Signal::NoAction), "bar {} skeleton", i);
            }
        }
    }

    #[test]
    fn test_ichimoku_required_inputs_include_h1_and_min_candles() {
        let s = IchimokuStrategy::new();
        let inputs = s.required_inputs();
        assert!(inputs
            .iter()
            .any(|i| matches!(i, InputSpec::OhlcvTimeframe(Timeframe::H1))));
        assert!(inputs.iter().any(|i| matches!(i, InputSpec::MinCandles(_))));
    }

    #[test]
    fn test_ichimoku_reset_is_noop_on_stateless_struct() {
        let mut s = IchimokuStrategy::new();
        s.on_reset();
        let _ = s.manifest();
    }
}
