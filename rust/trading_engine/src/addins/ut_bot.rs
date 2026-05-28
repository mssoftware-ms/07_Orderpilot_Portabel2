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
//! the SMI helper, the UT-Bot trail-state helper, and the full
//! [`StrategyAddin`] implementation. The session filter was extracted to
//! [`crate::addins::common::within_session`] in Welle I2-0 once the third
//! strategy (Ichimoku) needed the same window check (engineering plan
//! §4.1 Rule-of-Three). Indicator helpers (`calc_atr`, `calc_smi`,
//! `calc_ut_bot_trail`) remain local to this file because no other
//! strategy consumes them yet.

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
pub fn calc_atr(highs: &[f64], lows: &[f64], closes: &[f64], period: usize) -> Option<Vec<f64>> {
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
    let diff_kd = ema_series_from(&diff_k, d_smoothing, length - 1 + k_smoothing - 1);
    let rng_k = ema_series_from(&rng, k_smoothing, length - 1);
    let rng_kd = ema_series_from(&rng_k, d_smoothing, length - 1 + k_smoothing - 1);

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

// ─── Confluence detection (pure, unit-testable) ─────────────────────────────

/// Result of the per-bar UT-Bot confluence check (Spec §2 / §3).
///
/// Both fields are mutually exclusive at most one is `true`; both can be
/// `false` (no entry this bar). Computing them via a single pure
/// function keeps the [`StrategyAddin::on_candle`] implementation thin
/// and lets the tests pin the confluence semantics directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct UtBotEntrySignal {
    pub long: bool,
    pub short: bool,
}

/// Evaluate the three-way UT-Bot confluence at the current bar.
///
/// - **Strict spec (default, `cross_above_zero = false`)** — long requires
///   SMI cross-up while both SMI and signal are strictly **below** zero
///   (Spec §2, condition 3: "unterhalb der Nullinie"); short mirrors with
///   strictly **above** zero (Spec §3).
/// - **Path-B experiment (`cross_above_zero = true`)** — the zero-line
///   constraint is flipped: long requires SMI cross-up while both SMI and
///   signal are strictly **above** zero, short while strictly **below**.
///   This is the relaxation explored in Spec §13.3 when the strict-spec
///   default produces no winning entries on the real-data backtest. See
///   `01_Projectplan/specs/ut_bot_spec.md` §12.5 for the rationale.
///
/// Any input being `NaN` (warm-up) suppresses the signal — the helper
/// returns `UtBotEntrySignal::default()`.
#[allow(clippy::too_many_arguments)] // 9 independent per-bar samples + toggle — flattening into a struct hurts test ergonomics.
pub fn detect_entry(
    price: f64,
    ema: f64,
    direction_prev: i8,
    direction_now: i8,
    smi_prev: f64,
    signal_prev: f64,
    smi_now: f64,
    signal_now: f64,
    cross_above_zero: bool,
) -> UtBotEntrySignal {
    if price.is_nan()
        || ema.is_nan()
        || smi_prev.is_nan()
        || signal_prev.is_nan()
        || smi_now.is_nan()
        || signal_now.is_nan()
    {
        return UtBotEntrySignal::default();
    }
    let flip_up = direction_prev == -1 && direction_now == 1;
    let flip_down = direction_prev == 1 && direction_now == -1;
    let smi_cross_up = smi_prev < signal_prev && smi_now > signal_now;
    let smi_cross_down = smi_prev > signal_prev && smi_now < signal_now;
    let smi_below_zero = smi_now < 0.0 && signal_now < 0.0;
    let smi_above_zero = smi_now > 0.0 && signal_now > 0.0;
    // Zero-line gate per mode — strict ↦ below/above, relaxed ↦ above/below.
    let smi_long_ok = if cross_above_zero {
        smi_above_zero
    } else {
        smi_below_zero
    };
    let smi_short_ok = if cross_above_zero {
        smi_below_zero
    } else {
        smi_above_zero
    };
    UtBotEntrySignal {
        long: price > ema && flip_up && smi_cross_up && smi_long_ok,
        short: price < ema && flip_down && smi_cross_down && smi_short_ok,
    }
}

// ─── UtBotStrategy ──────────────────────────────────────────────────────────

use std::collections::HashMap;

use crate::models::{Candle, Timeframe};
use crate::strategy::{
    AddinManifest, Context, InputSpec, ParameterSchema, Signal, StrategyAddin, StrategyCategory,
};

use super::bb_rsi::{calc_ema, position_size_pct_fee_aware, swing_high, swing_low};
use super::common::{calc_adx, regime_passes_filter, within_session};

/// UT Bot Alerts (verbesserte Variante) strategy add-in.
///
/// Body-struct (not unit-struct) so the flutter_rust_bridge codegen
/// pipeline can introspect it — FRB rejects unit structs with the hint
/// "what about using `struct UtBotStrategy {}` instead". The strategy
/// is fully stateless; all per-run state lives on `Context`.
#[derive(Debug, Clone, Default)]
pub struct UtBotStrategy {}

impl UtBotStrategy {
    pub fn new() -> Self {
        Self {}
    }
}

impl StrategyAddin for UtBotStrategy {
    fn manifest(&self) -> AddinManifest {
        ut_bot_manifest()
    }

    fn required_inputs(&self) -> Vec<InputSpec> {
        // EMA(200) dominates the warm-up requirement; SMI + ATR + swing
        // lookback all fit inside the same window for the default
        // parameter set.
        vec![
            InputSpec::OhlcvTimeframe(Timeframe::M5),
            InputSpec::MinCandles(220),
            InputSpec::Indicator("EMA".to_string()),
            InputSpec::Indicator("ATR".to_string()),
            InputSpec::Indicator("SMI".to_string()),
        ]
    }

    fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
        // Defaults from `ut_bot_manifest()` — verbesserte Variante per
        // `01_Projectplan/specs/ut_bot_spec.md` §1.
        let ema_period = ctx.param_or("ema_period", 200.0) as usize;
        let key_value = ctx.param_or("key_value", 2.0);
        let atr_period = ctx.param_or("atr_period", 1.0) as usize;
        let smi_length = ctx.param_or("smi_length", 14.0) as usize;
        let smi_k = ctx.param_or("smi_k_smoothing", 5.0) as usize;
        let smi_d = ctx.param_or("smi_d_smoothing", 3.0) as usize;
        let swing_lookback = ctx.param_or("swing_lookback_bars", 20.0) as usize;
        let tp_rr_ratio = ctx.param_or("tp_rr_ratio", 2.0);
        let risk_per_trade = ctx.param_or("risk_per_trade", 0.02);
        let fee_rate = ctx.param_or("fee_rate", 0.0006);
        let session_enabled = ctx.param_or("session_filter_enabled", 0.0) >= 0.5;
        let session_start = ctx.param_or("session_start_hour_local", 9.0) as u32;
        let session_end = ctx.param_or("session_end_hour_local", 23.0) as u32;
        let tz_offset_hours = ctx.param_or("tz_offset_hours", 1.0) as i32;
        // Path-B toggle (Spec §12.5 / §13.3): default false = strict spec
        // (SMI cross while same-sign with zero); true flips the zero-line
        // gate per `detect_entry` doc.
        let cross_above_zero = ctx.param_or("smi_cross_above_zero", 0.0) >= 0.5;
        // Welle R2-3 ADX regime filter. Default disabled → no ADX
        // compute, no behaviour change vs pre-R2 UT-Bot. Identical
        // four-knob shape to BB+RSI / Ichimoku so the Welle-R3
        // acceptance backtest can sweep one parameter axis.
        let adx_filter_enabled = ctx.param_or("adx_filter_enabled", 0.0) >= 0.5;
        let adx_threshold = ctx.param_or("adx_threshold", 25.0);
        let adx_period = ctx.param_or("adx_period", 14.0) as usize;
        let adx_use_di_confluence = ctx.param_or("adx_use_di_confluence", 0.0) >= 0.5;

        // Warm-up: SMI signal needs `(length - 1) + (k - 1) + (d - 1) + (d - 1)`
        // bars; we also need at least one prior bar for the SMI cross and
        // direction-flip detection. EMA needs `ema_period`. Swing-lookback
        // needs that many bars BEFORE the signal bar.
        let smi_signal_warmup = smi_length.saturating_sub(1)
            + smi_k.saturating_sub(1)
            + smi_d.saturating_sub(1)
            + smi_d.saturating_sub(1);
        let start_idx = ema_period
            .max(atr_period)
            .max(smi_signal_warmup + 1)
            .max(swing_lookback);
        let i = ctx.index();
        if i < start_idx {
            return None;
        }

        // Pull everything needed from `ctx.all_candles()` as owned data so
        // the borrow ends before the mutable `set_state` block below.
        let (closes, highs, lows, lows_pre, highs_pre, current_ts, current_close) = {
            let candles = ctx.all_candles();
            let cs: Vec<f64> = candles[..=i].iter().map(|c| c.close).collect();
            let hs: Vec<f64> = candles[..=i].iter().map(|c| c.high).collect();
            let ls: Vec<f64> = candles[..=i].iter().map(|c| c.low).collect();
            let pre = &candles[i - swing_lookback..i];
            let lp: Vec<f64> = pre.iter().map(|c| c.low).collect();
            let hp: Vec<f64> = pre.iter().map(|c| c.high).collect();
            (cs, hs, ls, lp, hp, candles[i].timestamp, candles[i].close)
        };

        // Session filter — hoisted BEFORE indicator computation (N-09).
        if session_enabled
            && !within_session(current_ts, session_start, session_end, tz_offset_hours)
        {
            return Some(Signal::NoAction);
        }

        if ctx.in_position {
            return Some(Signal::NoAction);
        }

        let ema = calc_ema(&closes, ema_period)?;
        let atr_series = calc_atr(&highs, &lows, &closes, atr_period)?;
        let (_trail, direction_series) = calc_ut_bot_trail(&closes, &atr_series, key_value)?;
        let (smi_series, signal_series) =
            calc_smi(&highs, &lows, &closes, smi_length, smi_k, smi_d)?;

        // Snapshot state for UI / debugging (mirrors BB+RSI convention).
        ctx.set_state("ut_ema", ema);
        ctx.set_state("ut_atr", atr_series[i]);
        ctx.set_state("ut_smi", smi_series[i]);
        ctx.set_state("ut_smi_signal", signal_series[i]);
        ctx.set_state("ut_direction", direction_series[i] as f64);

        let entry = detect_entry(
            current_close,
            ema,
            direction_series[i - 1],
            direction_series[i],
            smi_series[i - 1],
            signal_series[i - 1],
            smi_series[i],
            signal_series[i],
            cross_above_zero,
        );

        // Welle R2-3 ADX regime snapshot — only computed when the filter
        // is enabled. Uses the same highs/lows/closes captured above
        // (already covers indices [0..=i]). When disabled the snapshot
        // is `None` and the gate below is skipped — pre-R2 UT-Bot path
        // bit-exact preserved.
        let adx_snapshot = if adx_filter_enabled {
            calc_adx(&highs, &lows, &closes, adx_period)
                .map(|out| (out.adx[i], out.plus_di[i], out.minus_di[i]))
        } else {
            None
        };

        // Helper: apply the ADX gate when the filter is enabled.  Returns
        // `true` when the bar should be *blocked* (gate rejected the entry
        // or the ADX computation failed).
        let adx_gate = |snapshot: Option<(f64, f64, f64)>, is_long: bool| -> bool {
            match snapshot {
                Some((adx_v, pdi, mdi)) => !regime_passes_filter(
                    adx_v,
                    pdi,
                    mdi,
                    adx_threshold,
                    is_long,
                    adx_use_di_confluence,
                ),
                // Filter enabled but calc_adx returned None — fail
                // CLOSED: no entry without a valid regime assessment.
                None => adx_filter_enabled,
            }
        };

        if entry.long {
            if adx_gate(adx_snapshot, true) {
                return Some(Signal::NoAction);
            }
            let swing = swing_low(&lows_pre)?;
            if swing < current_close {
                let sl_dist = current_close - swing;
                let tp = current_close + tp_rr_ratio * sl_dist;
                let size_pct =
                    position_size_pct_fee_aware(current_close, swing, risk_per_trade, fee_rate);
                ctx.in_position = true;
                return Some(Signal::EnterLong {
                    sl: Some(swing),
                    tp: Some(tp),
                    size_pct,
                });
            }
        }

        if entry.short {
            if adx_gate(adx_snapshot, false) {
                return Some(Signal::NoAction);
            }
            let swing = swing_high(&highs_pre)?;
            if swing > current_close {
                let sl_dist = swing - current_close;
                let tp = current_close - tp_rr_ratio * sl_dist;
                let size_pct =
                    position_size_pct_fee_aware(current_close, swing, risk_per_trade, fee_rate);
                ctx.in_position = true;
                return Some(Signal::EnterShort {
                    sl: Some(swing),
                    tp: Some(tp),
                    size_pct,
                });
            }
        }

        Some(Signal::NoAction)
    }

    fn on_reset(&mut self) {
        // The strategy is fully stateless: every on_candle call rebuilds
        // the indicator series from `ctx.all_candles()`. Nothing to clear.
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

/// Build the canonical AddinManifest for UT Bot Alerts.
pub fn ut_bot_manifest() -> AddinManifest {
    AddinManifest {
        id: "ut_bot_v1".to_string(),
        name: "UT Bot Alerts (verbesserte Variante)".to_string(),
        version: "1.0.0".to_string(),
        author: "Trading App Team".to_string(),
        description: "Trend-following strategy: EMA(200) bias, UT-Bot ATR-trail direction \
             flip, Stochastic Momentum Index cross trigger, swing-low/high SL, \
             R:R 1:2 with engine-side break-even trail."
            .to_string(),
        category: StrategyCategory::Trend,
        timeframes: vec![Timeframe::M5, Timeframe::M15, Timeframe::H1],
        parameters: vec![
            // Spec §1 / engineering plan §2 — all defaults documented in
            // 01_Projectplan/specs/ut_bot_spec.md.
            ParameterSchema::new("ema_period", "EMA Trend Period", 200.0, 20.0, 500.0, 1.0),
            // QA F2 = C: default key_value = 2.0 (TradingView/QuantNomad
            // default). Spec §12.1 documents the open question — Welle U3
            // will sweep if defaults miss the XLSX band.
            ParameterSchema::new("key_value", "UT Bot Sensitivity", 2.0, 0.5, 5.0, 0.5),
            ParameterSchema::new("atr_period", "ATR Period", 1.0, 1.0, 50.0, 1.0),
            // QA F3 = C: Blau-1993-Standard SMI defaults.
            ParameterSchema::new("smi_length", "SMI Length", 14.0, 5.0, 50.0, 1.0),
            ParameterSchema::new("smi_k_smoothing", "SMI %K Smoothing", 5.0, 1.0, 20.0, 1.0),
            ParameterSchema::new("smi_d_smoothing", "SMI %D Smoothing", 3.0, 1.0, 20.0, 1.0),
            ParameterSchema::new(
                "swing_lookback_bars",
                "Swing Lookback Bars",
                20.0,
                5.0,
                100.0,
                1.0,
            ),
            ParameterSchema::new("tp_rr_ratio", "TP R:R Ratio", 2.0, 0.5, 10.0, 0.1),
            ParameterSchema::new("risk_per_trade", "Risk Per Trade", 0.02, 0.001, 1.0, 0.001),
            // QA F4 = A: session filter local to ut_bot.rs, default OFF
            // (BTC trades 24/7 — the filter is a no-op for the Phase-2
            // baseline; left in the manifest so Phase-3 / alt-asset runs
            // can enable it without touching code).
            ParameterSchema::new(
                "session_filter_enabled",
                "Session Filter Enabled (0/1)",
                0.0,
                0.0,
                1.0,
                1.0,
            ),
            ParameterSchema::new(
                "session_start_hour_local",
                "Session Start Hour (Berlin)",
                9.0,
                0.0,
                23.0,
                1.0,
            ),
            ParameterSchema::new(
                "session_end_hour_local",
                "Session End Hour (Berlin)",
                23.0,
                1.0,
                24.0,
                1.0,
            ),
            ParameterSchema::new(
                "tz_offset_hours",
                "TZ Offset from UTC (hours)",
                1.0,
                -12.0,
                14.0,
                1.0,
            ),
            // Path-B toggle (Spec §12.5). Default 0 = strict spec
            // (Long: SMI cross while below zero, Short: cross while
            // above zero). Set to 1 to flip the zero-line gate — used
            // by the Welle-U3 Path-B experiment when the strict default
            // produces no winning entries on real-data backtests.
            ParameterSchema::new(
                "smi_cross_above_zero",
                "SMI Cross Above-Zero Mode (0/1)",
                0.0,
                0.0,
                1.0,
                1.0,
            ),
            // ── Welle R2-3 ADX regime filter ──────────────────────────
            // All four default to "off" — fresh UT-Bot instance behaves
            // byte-identical to pre-R2. Shape mirrors BB+RSI / Ichimoku
            // bit-for-bit so the Welle-R3 acceptance backtest sweeps an
            // IDENTICAL parameter axis across strategies.
            ParameterSchema::new(
                "adx_filter_enabled",
                "ADX Regime Filter Enabled (0/1)",
                0.0,
                0.0,
                1.0,
                1.0,
            ),
            ParameterSchema::new("adx_threshold", "ADX Threshold", 25.0, 0.0, 100.0, 1.0),
            ParameterSchema::new("adx_period", "ADX Period", 14.0, 2.0, 100.0, 1.0),
            ParameterSchema::new(
                "adx_use_di_confluence",
                "ADX +DI/-DI Confluence (0/1)",
                0.0,
                0.0,
                1.0,
                1.0,
            ),
        ],
    }
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
        assert!(
            (atr[period - 1] - 1.4).abs() < 1e-12,
            "got {}",
            atr[period - 1]
        );
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
        let (smi, _signal) = calc_smi(&highs, &lows, &closes, 10, 5, 3).unwrap();
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
        let highs: Vec<f64> = (0..n).map(|i| 200.0 - i as f64 + 0.5).collect();
        let lows: Vec<f64> = (0..n).map(|i| 200.0 - i as f64 - 0.5).collect();
        let closes: Vec<f64> = (0..n).map(|i| 200.0 - i as f64).collect();
        let (smi, _signal) = calc_smi(&highs, &lows, &closes, 10, 5, 3).unwrap();
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
            .map(|i| {
                if i <= 4 {
                    100.0 + i as f64
                } else {
                    100.0 + (8 - i) as f64
                }
            })
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
        assert!(
            (signal[5] - 34.375).abs() < 1e-9,
            "signal[5] = {}",
            signal[5]
        );
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
        let (smi, signal) = calc_smi(&highs, &lows, &closes, 10, 5, 3).unwrap();
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
            assert!(
                trail[i] >= trail[i - 1] - 1e-12,
                "trail must be monotone non-decreasing in uptrend at {}: {} → {}",
                i,
                trail[i - 1],
                trail[i]
            );
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
            assert!(
                trail[i] <= trail[i - 1] + 1e-12,
                "trail must be monotone non-increasing in downtrend at {}: {} → {}",
                i,
                trail[i - 1],
                trail[i]
            );
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
        let (trail, direction) = calc_ut_bot_trail(&closes, &atr, 1.5).unwrap();
        let expected_trail = [98.5, 100.5, 100.5, 101.5, 100.5, 100.5, 103.5, 103.5];
        let expected_dir = [1i8, 1, 1, 1, -1, -1, 1, 1];
        for (i, &want) in expected_trail.iter().enumerate() {
            assert!(
                (trail[i] - want).abs() < 1e-12,
                "trail[{}] expected {} got {}",
                i,
                want,
                trail[i],
            );
            assert_eq!(
                direction[i], expected_dir[i],
                "direction[{}] expected {} got {}",
                i, expected_dir[i], direction[i],
            );
        }
    }

    // ── Session-fixture helper (used by strategy-integration tests) ─────
    //
    // The six standalone `is_in_session` unit tests moved to
    // `addins/common.rs` in Welle I2-0 together with the helper itself.
    // Only `ts_at_utc_hour` stays here because the strategy-level
    // session-filter tests below still need it to build off-hours bars.

    /// Helper: build a UTC timestamp for `hour` (0..23) on 2024-01-15.
    /// With the Berlin = UTC+1 convention used by [`UtBotStrategy`], the
    /// local hour equals `hour_utc + 1` (mod 24).
    fn ts_at_utc_hour(hour: i64) -> i64 {
        // 2024-01-15 00:00:00 UTC = 1705276800000 ms (no DST in January).
        const BASE_UTC_MS: i64 = 1_705_276_800_000;
        BASE_UTC_MS + hour * 3_600_000
    }

    // ── detect_entry confluence tests ───────────────────────────────────

    #[test]
    fn test_detect_entry_long_when_all_three_conditions_met() {
        // price > ema, direction flipped −1→+1, SMI crossed up while
        // both lines still negative.
        let r = detect_entry(
            /* price */ 105.0, /* ema */ 100.0, /* dir_prev */ -1,
            /* dir_now */ 1, /* smi_prev */ -50.0, /* sig_prev */ -40.0,
            /* smi_now */ -20.0, /* sig_now */ -30.0, /* cross_above_zero */ false,
        );
        assert!(r.long);
        assert!(!r.short);
    }

    #[test]
    fn test_detect_entry_short_when_all_three_conditions_met_mirrored() {
        let r = detect_entry(
            /* price */ 95.0, /* ema */ 100.0, /* dir_prev */ 1,
            /* dir_now */ -1, /* smi_prev */ 50.0, /* sig_prev */ 40.0,
            /* smi_now */ 20.0, /* sig_now */ 30.0, /* cross_above_zero */ false,
        );
        assert!(!r.long);
        assert!(r.short);
    }

    #[test]
    fn test_detect_entry_long_suppressed_when_price_below_ema() {
        let r = detect_entry(95.0, 100.0, -1, 1, -50.0, -40.0, -20.0, -30.0, false);
        assert!(!r.long);
    }

    #[test]
    fn test_detect_entry_long_suppressed_when_no_direction_flip() {
        // direction stays at +1 across bars (no flip).
        let r = detect_entry(105.0, 100.0, 1, 1, -50.0, -40.0, -20.0, -30.0, false);
        assert!(!r.long);
    }

    #[test]
    fn test_detect_entry_long_suppressed_when_no_smi_cross() {
        // SMI already above its signal on prev bar → no cross-up here.
        let r = detect_entry(105.0, 100.0, -1, 1, -20.0, -30.0, -10.0, -25.0, false);
        assert!(!r.long);
    }

    #[test]
    fn test_detect_entry_long_suppressed_when_smi_above_zero() {
        // All other conditions met but SMI/signal already positive.
        let r = detect_entry(105.0, 100.0, -1, 1, 10.0, 20.0, 30.0, 25.0, false);
        assert!(!r.long);
    }

    #[test]
    fn test_detect_entry_nan_inputs_suppress_signal() {
        let r = detect_entry(105.0, f64::NAN, -1, 1, -50.0, -40.0, -20.0, -30.0, false);
        assert!(!r.long && !r.short);
        let r = detect_entry(105.0, 100.0, -1, 1, f64::NAN, -40.0, -20.0, -30.0, false);
        assert!(!r.long && !r.short);
    }

    // ── cross_above_zero toggle (Path-B experiment, Spec §12.5) ─────────

    #[test]
    fn test_detect_entry_cross_above_zero_inverts_long_gate() {
        // SAME inputs that fired Long in strict mode (smi cross while
        // below zero) MUST be suppressed in cross_above_zero mode — the
        // gate is now "above zero" for long.
        let r = detect_entry(
            105.0, 100.0, -1, 1, -50.0, -40.0, -20.0, -30.0, /* cross_above_zero */ true,
        );
        assert!(
            !r.long,
            "strict-mode long must NOT fire in cross_above_zero mode"
        );
        assert!(!r.short);
    }

    #[test]
    fn test_detect_entry_cross_above_zero_fires_long_when_smi_positive() {
        // Long requires SMI cross-up while above zero in the relaxed mode.
        let r = detect_entry(
            105.0, 100.0, /* dir_prev */ -1, /* dir_now */ 1, /* smi_prev */ 10.0,
            /* sig_prev */ 20.0, /* smi_now */ 30.0, /* sig_now */ 25.0,
            /* cross_above_zero */ true,
        );
        assert!(
            r.long,
            "cross_above_zero mode must fire long on above-zero cross"
        );
        assert!(!r.short);
    }

    #[test]
    fn test_detect_entry_cross_above_zero_fires_short_when_smi_negative() {
        // Mirror — short requires SMI cross-down while below zero in
        // the relaxed mode.
        let r = detect_entry(
            95.0, 100.0, /* dir_prev */ 1, /* dir_now */ -1, /* smi_prev */ -10.0,
            /* sig_prev */ -20.0, /* smi_now */ -30.0, /* sig_now */ -25.0,
            /* cross_above_zero */ true,
        );
        assert!(!r.long);
        assert!(
            r.short,
            "cross_above_zero mode must fire short on below-zero cross"
        );
    }

    // ── Strategy integration tests ──────────────────────────────────────

    #[test]
    fn test_strategy_manifest() {
        let s = UtBotStrategy::new();
        let m = s.manifest();
        assert_eq!(m.id, "ut_bot_v1");
        assert_eq!(m.category, StrategyCategory::Trend);
        // ema_period, key_value, atr_period, smi_length, smi_k_smoothing,
        // smi_d_smoothing, swing_lookback_bars, tp_rr_ratio, risk_per_trade,
        // session_filter_enabled, session_start_hour_local,
        // session_end_hour_local, tz_offset_hours, smi_cross_above_zero
        // + R2-3 ADX filter quartet (adx_filter_enabled, adx_threshold,
        // adx_period, adx_use_di_confluence) = 18 parameters.
        assert_eq!(m.parameters.len(), 18);
        for required in [
            "ema_period",
            "key_value",
            "atr_period",
            "smi_length",
            "smi_k_smoothing",
            "smi_d_smoothing",
            "swing_lookback_bars",
            "tp_rr_ratio",
            "risk_per_trade",
            "session_filter_enabled",
            "session_start_hour_local",
            "session_end_hour_local",
            "tz_offset_hours",
            "smi_cross_above_zero",
            "adx_filter_enabled",
            "adx_threshold",
            "adx_period",
            "adx_use_di_confluence",
        ] {
            assert!(
                m.parameters.iter().any(|p| p.name == required),
                "manifest missing parameter '{}'",
                required,
            );
        }
        // Default key_value = 2.0 per QA F2 = C.
        let key = m.parameters.iter().find(|p| p.name == "key_value").unwrap();
        assert_eq!(key.default, 2.0);
        // Default session_filter_enabled = 0.0 (OFF) per QA F4 = A.
        let sess = m
            .parameters
            .iter()
            .find(|p| p.name == "session_filter_enabled")
            .unwrap();
        assert_eq!(sess.default, 0.0);
        // Default tp_rr_ratio = 2.0 per Spec §5.
        let tp = m
            .parameters
            .iter()
            .find(|p| p.name == "tp_rr_ratio")
            .unwrap();
        assert_eq!(tp.default, 2.0);
    }

    #[test]
    fn test_strategy_validate_params_ok_and_out_of_range() {
        let s = UtBotStrategy::new();
        let mut ok = HashMap::new();
        ok.insert("key_value".to_string(), 2.5);
        ok.insert("tp_rr_ratio".to_string(), 2.0);
        assert!(s.validate_params(&ok).is_ok());

        let mut bad = HashMap::new();
        bad.insert("key_value".to_string(), 99.0); // max is 5.0
        assert!(s.validate_params(&bad).is_err());
    }

    #[test]
    fn test_strategy_reset_is_noop_on_stateless_struct() {
        // UtBotStrategy is stateless (every on_candle rebuilds series).
        // The test pins that reset does not panic and the struct
        // remains valid for re-use.
        let mut s = UtBotStrategy::new();
        s.on_reset();
        let _ = s.manifest();
    }

    #[test]
    fn test_strategy_no_signal_during_warmup() {
        // Only 10 candles — far below the 200-bar EMA warm-up.
        let mut s = UtBotStrategy::new();
        let candles: Vec<Candle> = (0..10)
            .map(|i| Candle::new(i * 60000, 100.0, 101.0, 99.0, 100.0, 1.0))
            .collect();
        let mut ctx = Context::new(candles.clone(), Timeframe::M5, HashMap::new());
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            assert!(s.on_candle(&mut ctx, candle).is_none());
        }
    }

    #[test]
    fn test_strategy_smoke_run_on_synthetic_fixture_does_not_panic() {
        // 500-candle sinusoid with smaller indicator periods so the
        // strategy actually clears warm-up inside the fixture. We do
        // NOT assert a specific trade count — the parity test in
        // Welle U2-4 owns end-to-end signal-emission correctness.
        // Here we only prove on_candle is robust on real-shape input
        // and produces a Signal enum on every post-warm-up bar.
        let mut s = UtBotStrategy::new();
        let n = 500;
        let candles: Vec<Candle> = (0..n)
            .map(|i| {
                let phase = (i as f64) * 0.15;
                let base = 50000.0 + 500.0 * phase.sin();
                Candle::new(
                    i * 60_000,
                    base,
                    base + 30.0,
                    base - 30.0,
                    base,
                    100.0 + i as f64,
                )
            })
            .collect();
        let params = HashMap::from([
            ("ema_period".to_string(), 50.0),
            ("smi_length".to_string(), 10.0),
            ("smi_k_smoothing".to_string(), 5.0),
            ("smi_d_smoothing".to_string(), 3.0),
        ]);
        let mut ctx = Context::new(candles.clone(), Timeframe::M5, params);
        let mut produced_any = false;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if s.on_candle(&mut ctx, candle).is_some() {
                produced_any = true;
            }
        }
        assert!(
            produced_any,
            "strategy must emit at least Signal::NoAction once past warm-up"
        );
        // State snapshot should be populated by the last call.
        assert!(ctx.get_state("ut_ema").is_some());
        assert!(ctx.get_state("ut_atr").is_some());
        assert!(ctx.get_state("ut_smi").is_some());
    }

    #[test]
    fn test_strategy_session_filter_default_off_does_not_block() {
        // With session_filter_enabled=0 (default) the bar timestamp is
        // ignored — on_candle must return some Signal on every
        // post-warm-up bar instead of being filtered out. Construct a
        // bar timestamp deep in the night (03:00 Berlin) and verify
        // no filter blocks it.
        let mut s = UtBotStrategy::new();
        let n = 300;
        let night_base = ts_at_utc_hour(2); // local 03:00 → off-hours
        let candles: Vec<Candle> = (0..n)
            .map(|i| {
                Candle::new(
                    night_base + i * 300_000, // 5-min spacing
                    100.0,
                    101.0,
                    99.0,
                    100.0 + (i as f64 * 0.01),
                    1.0,
                )
            })
            .collect();
        let mut ctx = Context::new(
            candles.clone(),
            Timeframe::M5,
            HashMap::from([("ema_period".to_string(), 50.0)]),
        );
        let mut got_signal = false;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if s.on_candle(&mut ctx, candle).is_some() {
                got_signal = true;
            }
        }
        assert!(got_signal);
    }

    #[test]
    fn test_strategy_session_filter_when_enabled_blocks_off_hours() {
        // Same fixture, but session_filter_enabled = 1. All bars are
        // night-time → on_candle must emit Signal::NoAction (filter
        // active) on every post-warm-up bar, never an entry.
        let mut s = UtBotStrategy::new();
        let n = 300;
        let night_base = ts_at_utc_hour(2); // 03:00 Berlin — outside default window
        let candles: Vec<Candle> = (0..n)
            .map(|i| {
                Candle::new(
                    night_base + i * 300_000,
                    100.0,
                    101.0,
                    99.0,
                    100.0 + (i as f64 * 0.01),
                    1.0,
                )
            })
            .collect();
        let params = HashMap::from([
            ("ema_period".to_string(), 50.0),
            ("session_filter_enabled".to_string(), 1.0),
        ]);
        let mut ctx = Context::new(candles.clone(), Timeframe::M5, params);
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(sig) = s.on_candle(&mut ctx, candle) {
                assert!(
                    !matches!(sig, Signal::EnterLong { .. } | Signal::EnterShort { .. }),
                    "session filter must block entries at off-hours bar {}",
                    i,
                );
            }
        }
    }

    // ── Welle R2-3 ADX regime filter wiring ─────────────────────────────
    //
    // Uses the same 500-candle sinusoid fixture as the smoke-run test
    // (small ema=50, smi=10/5/3 to clear warm-up inside the fixture).
    // The fixture is known to produce at least one entry signal, so
    // the "disabled = baseline" and "high threshold = 0 trades" pins
    // are not tautologies of `0 == 0`. Confluence semantics are pinned
    // bit-for-bit on the helper itself by
    // `addins::common::tests::test_regime_filter_di_confluence_*`.

    fn build_smoke_fixture() -> Vec<Candle> {
        // 400 deterministic candles via the same LCG random-walk used by
        // `test/integration/dart_rust_ut_bot_parity_test.dart` — known to
        // trigger ≥ 1 UT-Bot entry under the fast-warmup parameter set,
        // so the "disabled = baseline" pin is not a tautology of 0 == 0.
        let mut closes = Vec::with_capacity(400);
        let mut s: u64 = 12345;
        let mut price = 100.0_f64;
        closes.push(price);
        while closes.len() < 400 {
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
                    BASE_TS + (i as i64) * 300_000, // 5-minute candles
                    c - 0.3,
                    c + 1.2,
                    c - 1.2,
                    c,
                    1000.0 + i as f64,
                )
            })
            .collect()
    }

    fn count_ut_bot_entries(candles: &[Candle], params: HashMap<String, f64>) -> usize {
        let mut strategy = UtBotStrategy::new();
        let mut ctx = Context::new(candles.to_vec(), Timeframe::M5, params);
        let mut entries = 0usize;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(sig) = strategy.on_candle(&mut ctx, candle) {
                if matches!(sig, Signal::EnterLong { .. } | Signal::EnterShort { .. }) {
                    entries += 1;
                }
            }
        }
        entries
    }

    fn fast_warmup_params() -> HashMap<String, f64> {
        // Same fast-warmup parameter set as the dart_rust_ut_bot_parity
        // test — produces ≥ 1 entry on the LCG fixture above.
        HashMap::from([
            ("ema_period".to_string(), 30.0),
            ("key_value".to_string(), 1.0),
            ("atr_period".to_string(), 1.0),
            ("smi_length".to_string(), 5.0),
            ("smi_k_smoothing".to_string(), 3.0),
            ("smi_d_smoothing".to_string(), 3.0),
            ("swing_lookback_bars".to_string(), 5.0),
            ("tp_rr_ratio".to_string(), 2.0),
            ("risk_per_trade".to_string(), 0.02),
        ])
    }

    #[test]
    fn test_adx_filter_disabled_does_not_change_signals_on_smoke_fixture() {
        let candles = build_smoke_fixture();
        let baseline = count_ut_bot_entries(&candles, fast_warmup_params());
        let mut explicit = fast_warmup_params();
        explicit.insert("adx_filter_enabled".to_string(), 0.0);
        assert_eq!(
            count_ut_bot_entries(&candles, explicit),
            baseline,
            "adx_filter_enabled=0.0 must equal default (disabled)",
        );
        assert!(baseline >= 1, "smoke fixture must emit ≥ 1 UT-Bot entry");
    }

    #[test]
    fn test_adx_filter_high_threshold_blocks_all_ut_bot_entries() {
        let candles = build_smoke_fixture();
        let mut params = fast_warmup_params();
        params.insert("adx_filter_enabled".to_string(), 1.0);
        params.insert("adx_threshold".to_string(), 100.0);
        params.insert("adx_period".to_string(), 14.0);
        assert_eq!(
            count_ut_bot_entries(&candles, params),
            0,
            "adx_threshold=100 must block every UT-Bot entry",
        );
    }

    #[test]
    fn test_adx_filter_zero_threshold_matches_disabled_on_smoke_fixture() {
        // small adx_period=5 → warmup is only 8 bars, well clear of the
        // ema=50 + smi gate, so the gate becomes pure pass-through.
        let candles = build_smoke_fixture();
        let baseline = count_ut_bot_entries(&candles, fast_warmup_params());
        let mut params = fast_warmup_params();
        params.insert("adx_filter_enabled".to_string(), 1.0);
        params.insert("adx_threshold".to_string(), 0.0);
        params.insert("adx_period".to_string(), 5.0);
        params.insert("adx_use_di_confluence".to_string(), 0.0);
        assert_eq!(
            count_ut_bot_entries(&candles, params),
            baseline,
            "threshold=0 + no confluence must equal disabled baseline",
        );
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
