//! Bollinger Bands + RSI Strategy Add-in.
//!
//! Defaults, entry direction, RSI cross-back trigger, exit semantics,
//! swing-low / swing-high SL placement, R:R 1:3 take-profit, break-even
//! trail at +1R, and per-trade risk sizing all match the video-spec
//! "verbesserte Variante" (see `01_Projectplan/specs/bb_rsi_spec.md`
//! §1–§8, Diff D-01..D-09 and D-11). Positions are closed exclusively
//! by SL/TP placeholders attached at entry — no BB-middle or
//! RSI-extreme indicator exits.
//!
//! # Parameters
//! | Name                | Default | Range    | Description                                  |
//! |---------------------|---------|----------|----------------------------------------------|
//! | bb_period           | 200     | 5–500    | Bollinger Bands MA lookback                  |
//! | bb_stddev           | 0.2     | 0.1–5.0  | Standard-deviation multiplier                |
//! | bb_ma_type          | 1 (EMA) | 0–1      | Basis MA type (0=SMA, 1=EMA)                 |
//! | rsi_period          | 3       | 2–50     | RSI lookback period                          |
//! | rsi_oversold        | 20      | 5–45     | RSI oversold threshold / level for long     |
//! | rsi_overbought      | 80      | 55–95    | RSI overbought threshold / level for short  |
//! | swing_lookback_bars | 20      | 5–100    | SL swing-low/high window length (Diff D-07)  |
//! | tp_rr_ratio         | 3.0     | 0.5–10.0 | TP distance as multiple of SL distance (D-06)|
//! | risk_per_trade      | 0.02    | 0.001–1.0| Equity fraction risked per trade (Diff D-09) |

use std::collections::HashMap;

use crate::models::{Candle, Timeframe};
use crate::strategy::{
    AddinManifest, Context, InputSpec, ParameterSchema, Signal, StrategyAddin, StrategyCategory,
};

use super::common::{calc_adx, regime_passes_filter, within_session};

// ─── Indicator helpers (pure functions) ─────────────────────────────────────

/// Compute the Simple Moving Average of a slice.
pub fn sma(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.iter().sum::<f64>() / values.len() as f64
}

/// Compute the population standard deviation of a slice.
pub fn stddev(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mean = sma(values);
    let variance = values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / values.len() as f64;
    variance.sqrt()
}

/// Bollinger Bands result for a single bar.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BollingerBands {
    pub upper: f64,
    pub middle: f64,
    pub lower: f64,
}

/// Calculate Bollinger Bands from a series of close prices using SMA basis.
///
/// Returns `None` if there are fewer data points than `period`.
pub fn calc_bollinger_bands(closes: &[f64], period: usize, num_stddev: f64) -> Option<BollingerBands> {
    if closes.len() < period {
        return None;
    }
    let window = &closes[closes.len() - period..];
    let middle = sma(window);
    let sd = stddev(window);
    Some(BollingerBands {
        upper: middle + num_stddev * sd,
        middle,
        lower: middle - num_stddev * sd,
    })
}

/// Compute the Exponential Moving Average over a full close-price history.
///
/// Convention (locked for Dart↔Rust parity):
/// - Period must be > 0 and `values.len() >= period`, otherwise returns `None`.
/// - Alpha = `2 / (period + 1)` (the standard "smoothing factor").
/// - The EMA is **SMA-seeded**: the first `period` values are averaged to
///   form the initial EMA, then the recursive update
///   `ema = alpha * v + (1 - alpha) * ema` is applied for every subsequent
///   value. This matches the conventions used by TA-Lib, pandas-ta, and
///   TradingView (`ta.ema`).
/// - When `values.len() == period`, the return value equals the seed SMA
///   (no recursive updates applied yet).
///
/// EMA is path-dependent: feeding only the last N closes restarts the seed
/// from a different SMA and drifts compared to the cumulative computation.
/// Callers that need the BB(EMA) basis on bar `i` must therefore pass the
/// **full** prior close history `closes[..=i]`, mirroring the F-02b RSI
/// contract.
pub fn calc_ema(values: &[f64], period: usize) -> Option<f64> {
    if period == 0 || values.len() < period {
        return None;
    }
    let alpha = 2.0 / (period as f64 + 1.0);
    let mut ema = values[..period].iter().sum::<f64>() / period as f64;
    for &v in &values[period..] {
        ema = alpha * v + (1.0 - alpha) * ema;
    }
    Some(ema)
}

/// Calculate Bollinger Bands using an EMA basis.
///
/// Convention (locked for Dart↔Rust parity):
/// - `closes_full` must be the **full prior-close history** up to and
///   including the bar being evaluated, because the EMA basis is
///   path-dependent (see `calc_ema`). Passing only the last `period`
///   closes restarts the seed and drifts.
/// - `stddev` is computed against the **window-SMA** of the last `period`
///   closes — i.e. the standard-deviation component is identical to the
///   SMA-BB variant, so only the basis differs between SMA-BB and EMA-BB.
///   This keeps band-width comparable across MA-type switches and matches
///   the most common community convention (pandas-ta, Pine custom
///   indicators).
/// - Returns `None` if `period == 0` or `closes_full.len() < period`.
pub fn calc_bollinger_bands_ema(
    closes_full: &[f64],
    period: usize,
    num_stddev: f64,
) -> Option<BollingerBands> {
    if period == 0 || closes_full.len() < period {
        return None;
    }
    let middle = calc_ema(closes_full, period)?;
    let window = &closes_full[closes_full.len() - period..];
    let sd = stddev(window);
    Some(BollingerBands {
        upper: middle + num_stddev * sd,
        middle,
        lower: middle - num_stddev * sd,
    })
}

/// Compute the swing low: the minimum value across the given `lows`.
///
/// Convention (locked for Dart↔Rust parity, see `swingLow` in
/// `lib/services/indicators.dart`): the caller selects which bars to feed,
/// the helper does no slicing. Per `01_Projectplan/specs/bb_rsi_spec.md`
/// §4, the swing-low SL for a long entry at bar `i` uses
/// `min(low[i - N .. i - 1])` — i.e. the N bars BEFORE the signal bar,
/// EXCLUSIVE of the signal bar itself. Returns `None` if `lows` is empty.
pub fn swing_low(lows: &[f64]) -> Option<f64> {
    if lows.is_empty() {
        return None;
    }
    Some(lows.iter().copied().fold(f64::INFINITY, f64::min))
}

/// Compute the swing high: the maximum value across the given `highs`.
///
/// Mirror of [`swing_low`] for the short side. Spec §4: short-entry SL is
/// `max(high[i - N .. i - 1])` — N highs before the signal bar, exclusive.
pub fn swing_high(highs: &[f64]) -> Option<f64> {
    if highs.is_empty() {
        return None;
    }
    Some(highs.iter().copied().fold(f64::NEG_INFINITY, f64::max))
}

/// Convert the spec §8 risk-2 % sizing rule into a percentage of equity
/// that the engine's `open_position` can consume directly (Diff D-09).
///
/// Derivation: the spec defines
///   `qty = (equity * risk_per_trade) / sl_distance`
/// and the engine builds the position via
///   `alloc = balance * size_pct / 100`,
///   `qty = (alloc - alloc * fee_rate) / entry_price`.
/// Solving for `size_pct` (ignoring the second-order `(1 - fee_rate)`
/// term — fee_rate is bounded by 0.001 in the BB+RSI configs the
/// strategy ships with, so the residual is < 0.1 % of the target risk):
///   `size_pct = 100 * risk_per_trade * entry_price / sl_distance`.
/// Clamped to `[0, 100]` because the engine treats `size_pct > 100` the
/// same as 100 — spec §8 calls this the "naive full-balance clamp".
///
/// `sl_distance` must be strictly positive; the caller is expected to
/// have already enforced this via the degenerate-swing check.
/// `entry_price` is the signal-bar close (entry-price proxy) to keep
/// the calculation parity-locked across Dart and Rust at signal time.
pub fn position_size_pct(entry_price: f64, sl_distance: f64, risk_per_trade: f64) -> f64 {
    if sl_distance <= 0.0 || entry_price <= 0.0 || risk_per_trade <= 0.0 {
        return 0.0;
    }
    (100.0 * risk_per_trade * entry_price / sl_distance).clamp(0.0, 100.0)
}

/// Calculate RSI using Wilder's smoothing method.
///
/// Returns `None` if there are fewer than `period + 1` data points.
pub fn calc_rsi(closes: &[f64], period: usize) -> Option<f64> {
    if closes.len() < period + 1 {
        return None;
    }

    // Calculate price changes
    let changes: Vec<f64> = closes.windows(2).map(|w| w[1] - w[0]).collect();

    // First average gain / loss over the initial `period` bars
    let (initial_gain_sum, initial_loss_sum) = changes[..period]
        .iter()
        .fold((0.0, 0.0), |(g, l), &c| {
            if c > 0.0 {
                (g + c, l)
            } else {
                (g, l + c.abs())
            }
        });

    let mut avg_gain = initial_gain_sum / period as f64;
    let mut avg_loss = initial_loss_sum / period as f64;

    // Apply Wilder's smoothing for remaining bars
    for &change in &changes[period..] {
        let gain = if change > 0.0 { change } else { 0.0 };
        let loss = if change < 0.0 { change.abs() } else { 0.0 };
        avg_gain = (avg_gain * (period as f64 - 1.0) + gain) / period as f64;
        avg_loss = (avg_loss * (period as f64 - 1.0) + loss) / period as f64;
    }

    if avg_loss == 0.0 {
        if avg_gain == 0.0 {
            return Some(50.0); // flat price → neutral RSI (N-07)
        }
        return Some(100.0);
    }
    let rs = avg_gain / avg_loss;
    Some(100.0 - 100.0 / (1.0 + rs))
}

// ─── BbRsiStrategy ──────────────────────────────────────────────────────────

/// Internal state tracked across candle calls.
#[derive(Debug, Clone, Default)]
pub struct BbRsiState {
    /// Last computed Bollinger Bands.
    pub last_bb: Option<BollingerBands>,
    /// Last computed RSI value.
    pub last_rsi: Option<f64>,
    /// RSI value from the previous bar — required by the Diff D-05 cross
    /// check. `None` on the first valid bar after warm-up, in which case
    /// no cross can be observed yet.
    pub prev_rsi: Option<f64>,
}

/// Bollinger Bands + RSI Mean Reversion strategy add-in.
#[derive(Debug, Clone)]
pub struct BbRsiStrategy {
    state: BbRsiState,
}

impl BbRsiStrategy {
    /// Create a new BbRsiStrategy instance.
    pub fn new() -> Self {
        Self {
            state: BbRsiState::default(),
        }
    }

    /// Read-only access to the current indicator state (useful for UI / debugging).
    pub fn indicator_state(&self) -> &BbRsiState {
        &self.state
    }
}

impl Default for BbRsiStrategy {
    fn default() -> Self {
        Self::new()
    }
}

impl StrategyAddin for BbRsiStrategy {
    fn manifest(&self) -> AddinManifest {
        bb_rsi_manifest()
    }

    fn required_inputs(&self) -> Vec<InputSpec> {
        vec![
            InputSpec::OhlcvTimeframe(Timeframe::H1),
            InputSpec::MinCandles(50), // minimum reasonable candles for BB + RSI
            InputSpec::Indicator("BB".to_string()),
            InputSpec::Indicator("RSI".to_string()),
        ]
    }

    fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
        // Defaults aligned with bb_rsi_manifest() — the video-spec verbesserte
        // Variante (01_Projectplan/specs/bb_rsi_spec.md §1, Diff D-01 + D-02).
        let bb_period = ctx.param_or("bb_period", 200.0) as usize;
        let bb_stddev_mult = ctx.param_or("bb_stddev", 0.2);
        // bb_ma_type: 0.0 = SMA, 1.0 = EMA (default EMA per spec D-01).
        // Encoded as f64 because the strategy parameter map is f64-typed;
        // the schema clamps to {0, 1} via min/max/step.
        let bb_ma_type_raw = ctx.param_or("bb_ma_type", 1.0);
        let use_ema_basis = bb_ma_type_raw >= 0.5;
        let rsi_period = ctx.param_or("rsi_period", 3.0) as usize;
        let rsi_oversold = ctx.param_or("rsi_oversold", 20.0);
        let rsi_overbought = ctx.param_or("rsi_overbought", 80.0);
        let swing_lookback = ctx.param_or("swing_lookback_bars", 20.0) as usize;
        let tp_rr_ratio = ctx.param_or("tp_rr_ratio", 3.0);
        let risk_per_trade = ctx.param_or("risk_per_trade", 0.02);
        // Welle R2-2 ADX regime filter. Default disabled → no ADX
        // compute, no behaviour change vs pre-R2. Threshold + period +
        // DI-confluence toggle mirror the BB+RSI / UT-Bot / Ichimoku
        // contract from Welle R2-1.
        let adx_filter_enabled = ctx.param_or("adx_filter_enabled", 0.0) >= 0.5;
        let adx_threshold = ctx.param_or("adx_threshold", 25.0);
        let adx_period = ctx.param_or("adx_period", 14.0) as usize;
        let adx_use_di_confluence =
            ctx.param_or("adx_use_di_confluence", 0.0) >= 0.5;
        // Session filter — default OFF for backward compatibility.
        // When enabled, entries only fire during [start, end) local time.
        let session_enabled = ctx.param_or("session_filter_enabled", 0.0) >= 0.5;
        let session_start = ctx.param_or("session_start_hour_local", 9.0) as u32;
        let session_end = ctx.param_or("session_end_hour_local", 23.0) as u32;
        let tz_offset = ctx.param_or("tz_offset_hours", 1.0) as i32;

        // F-09 parity gate: match Dart `startIdx = max(bbPeriod, rsiPeriod + 1)`.
        // Without this, Rust emits signals one bar earlier than Dart at the
        // BB-warmup boundary on real markets (cf. phase1_reference_backtest).
        // Plan rev3 §3.4 establishes Dart's convention as canonical.
        // Diff D-07 also requires `swing_lookback` bars BEFORE the signal
        // bar for the swing-low/high SL; fold it into the warm-up gate so
        // signals never emit without a usable SL.
        let start_idx = bb_period.max(rsi_period + 1).max(swing_lookback);
        if ctx.index() < start_idx {
            return None;
        }

        // Session filter — when enabled, no new entries fire outside
        // the configured [start, end) local-time window.  Placed BEFORE
        // the heavy indicator computation so off-session bars are cheap.
        if session_enabled
            && !within_session(
                ctx.all_candles()[ctx.index()].timestamp,
                session_start,
                session_end,
                tz_offset,
            )
        {
            return Some(Signal::NoAction);
        }

        // BB uses a fixed `bb_period` rolling window for the SMA-stddev
        // component. The EMA basis (when enabled) and the RSI must both run
        // across the FULL prior-close history (F-02b for RSI, same path-
        // dependence requirement for EMA) to match the Dart engine — feeding
        // only the last `bb_period` closes restarts seeds every bar and
        // drifts noticeably on non-stationary series
        // (cf. tests/regression_f02b_rsi_wilder.rs).
        let bb_closes = ctx.closes(bb_period);
        let rsi_closes = ctx.closes(ctx.index() + 1);
        if bb_closes.len() < bb_period || rsi_closes.len() < rsi_period + 1 {
            return None;
        }

        // Compute indicators
        let bb = if use_ema_basis {
            calc_bollinger_bands_ema(&rsi_closes, bb_period, bb_stddev_mult)?
        } else {
            calc_bollinger_bands(&bb_closes, bb_period, bb_stddev_mult)?
        };
        let rsi = calc_rsi(&rsi_closes, rsi_period)?;

        // Persist indicator values in context state for external access
        ctx.set_state("bb_upper", bb.upper);
        ctx.set_state("bb_middle", bb.middle);
        ctx.set_state("bb_lower", bb.lower);
        ctx.set_state("rsi", rsi);

        // Persist in our own struct too. `prev_rsi` is rotated from
        // last_rsi BEFORE overwriting it, so the entry block below can
        // observe (prev_rsi, rsi) of the cross.
        let prev_rsi = self.state.last_rsi;
        self.state.last_bb = Some(bb);
        self.state.last_rsi = Some(rsi);
        self.state.prev_rsi = prev_rsi;

        let price = ctx.current_price();

        // ── Swing-based SL window (Diff D-07) ───────────────────────────
        // Per spec §4, the SL for a long uses the lowest `low` of the N
        // bars BEFORE the signal bar (exclusive of the signal bar itself);
        // mirror for shorts. The warm-up gate above already guarantees
        // `ctx.index() >= swing_lookback`, so the slice is in-bounds.
        let pre_signal = &ctx.all_candles()[ctx.index() - swing_lookback..ctx.index()];
        let pre_lows: Vec<f64> = pre_signal.iter().map(|c| c.low).collect();
        let pre_highs: Vec<f64> = pre_signal.iter().map(|c| c.high).collect();
        let swing_low_price = swing_low(&pre_lows)
            .expect("swing_lookback warm-up guarantees non-empty pre_lows");
        let swing_high_price = swing_high(&pre_highs)
            .expect("swing_lookback warm-up guarantees non-empty pre_highs");

        // ── Welle R2-2 ADX regime snapshot ──────────────────────────────
        // Only computed when the filter is enabled — keeps the disabled
        // path byte-identical to pre-R2 BB+RSI. When enabled, the helper
        // is called once per bar against the full bar-history up to and
        // including `i` (mirrors the FFI per-bar full-recompute pattern
        // used by `calc_atr` / `calc_smi` in the other strategies). DI
        // confluence is passed through unchanged from the manifest
        // parameter.
        let adx_snapshot = if adx_filter_enabled {
            let i = ctx.index();
            let highs_full = ctx.highs(i + 1);
            let lows_full = ctx.lows(i + 1);
            let closes_full = ctx.closes(i + 1);
            calc_adx(&highs_full, &lows_full, &closes_full, adx_period)
                .map(|out| (out.adx[i], out.plus_di[i], out.minus_di[i]))
        } else {
            // Filter disabled — `None` signals that the gate must be
            // skipped entirely (pre-R2 path preserved).
            None
        };

        // Helper: apply the ADX gate when the filter is enabled.  Returns
        // `true` when the bar should be *blocked* (i.e. the gate rejected
        // the entry or the ADX computation failed).
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
                // Filter is enabled but calc_adx returned None — fail
                // CLOSED: no entry without a valid regime assessment.
                None => adx_filter_enabled,
            }
        };

        // ── Entry logic ─────────────────────────────────────────────────
        // Diff D-03/D-04 + Diff D-05 + Diff D-06 + Diff D-07: trend-follow
        // + RSI cross-back through the oversold/overbought level +
        // swing-based SL + R:R 1:3 take-profit per video-spec §2/§3/§4/§5.
        //   Long  ⇔ price > BB.upper AND RSI(prev) < oversold AND RSI(cur) ≥ oversold
        //   Short ⇔ price < BB.lower AND RSI(prev) > overbought AND RSI(cur) ≤ overbought
        // Strict comparison on the prev side prevents re-triggering after
        // RSI flatlines on a threshold. `None` for prev_rsi (first valid
        // bar after warm-up) suppresses the cross — no signal possible.
        // SL is anchored on the swing-low/high of the prior N bars (spec
        // §4 algorithm). TP distance = `tp_rr_ratio` × SL distance from
        // the signal-bar close (spec §5). Using the signal-bar close as
        // the entry-price proxy is necessary because the actual fill
        // happens at the next bar's open (F-04) — both engines apply
        // the same proxy so the implicit R:R stays parity-locked.
        // Degenerate swings (swing_low ≥ signal-bar price for a long, or
        // swing_high ≤ signal-bar price for a short) are suppressed — those
        // SLs would be on the wrong side of entry and trip the position
        // immediately at fill.
        //
        // Welle R2-2: once the entry confluence holds, the ADX regime
        // gate (when enabled) has the last word — the gate evaluates
        // adx/+DI/-DI for the same bar against the configured threshold
        // and (optionally) the DI dominance rule. When the filter is
        // disabled `adx_snapshot` is `None` and the gate is skipped, so
        // the pre-R2 code path is bit-exact preserved.
        if !ctx.in_position {
            if let Some(prev) = prev_rsi {
                if price > bb.upper
                    && prev < rsi_oversold
                    && rsi >= rsi_oversold
                    && swing_low_price < price
                {
                    if adx_gate(adx_snapshot, true) {
                        return Some(Signal::NoAction);
                    }
                    let sl_distance = price - swing_low_price;
                    let tp_price = price + tp_rr_ratio * sl_distance;
                    let size_pct = position_size_pct(price, sl_distance, risk_per_trade);
                    ctx.in_position = true;
                    return Some(Signal::EnterLong {
                        sl: Some(swing_low_price),
                        tp: Some(tp_price),
                        size_pct,
                    });
                }

                if price < bb.lower
                    && prev > rsi_overbought
                    && rsi <= rsi_overbought
                    && swing_high_price > price
                {
                    if adx_gate(adx_snapshot, false) {
                        return Some(Signal::NoAction);
                    }
                    let sl_distance = swing_high_price - price;
                    let tp_price = price - tp_rr_ratio * sl_distance;
                    let size_pct = position_size_pct(price, sl_distance, risk_per_trade);
                    ctx.in_position = true;
                    return Some(Signal::EnterShort {
                        sl: Some(swing_high_price),
                        tp: Some(tp_price),
                        size_pct,
                    });
                }
            }
        }

        Some(Signal::NoAction)
    }

    fn on_reset(&mut self) {
        self.state = BbRsiState::default();
    }

    fn validate_params(&self, params: &HashMap<String, f64>) -> Result<(), String> {
        for schema in &self.manifest().parameters {
            if let Some(&val) = params.get(&schema.name) {
                schema.validate(val)?;
            }
        }
        // N-11: cross-parameter validation — oversold must be below overbought.
        let oversold = params
            .get("rsi_oversold")
            .copied()
            .unwrap_or(30.0);
        let overbought = params
            .get("rsi_overbought")
            .copied()
            .unwrap_or(70.0);
        if oversold >= overbought {
            return Err(format!(
                "rsi_oversold ({}) must be less than rsi_overbought ({})",
                oversold, overbought
            ));
        }
        Ok(())
    }
}

/// Build the canonical AddinManifest for BB+RSI.
pub fn bb_rsi_manifest() -> AddinManifest {
    AddinManifest {
        id: "bb_rsi_v1".to_string(),
        name: "Bollinger Bands + RSI Trend Following".to_string(),
        version: "1.0.0".to_string(),
        author: "Trading App Team".to_string(),
        description:
            "Trend-following strategy: price beyond BB marks trend direction, \
             RSI cross-back provides pullback re-entry, swing-based SL/TP (1:3)."
                .to_string(),
        category: StrategyCategory::Trend,
        timeframes: vec![Timeframe::M15, Timeframe::H1, Timeframe::H4],
        parameters: vec![
            // Defaults from the video-spec verbesserte Variante
            // (01_Projectplan/specs/bb_rsi_spec.md §1, Diff D-01 + D-02).
            // Ranges widened to keep Phase-1 optimizer/regression configs
            // (bb_period∈[10,50], bb_stddev∈[1.0,3.0], rsi_period∈[7,30])
            // valid while permitting the new spec defaults.
            ParameterSchema::new("bb_period", "BB Period", 200.0, 5.0, 500.0, 1.0),
            ParameterSchema::new("bb_stddev", "BB Std Dev", 0.2, 0.1, 5.0, 0.1),
            // bb_ma_type: 0=SMA, 1=EMA (default EMA per spec D-01).
            ParameterSchema::new("bb_ma_type", "BB MA Type (0=SMA,1=EMA)", 1.0, 0.0, 1.0, 1.0),
            ParameterSchema::new("rsi_period", "RSI Period", 3.0, 2.0, 50.0, 1.0),
            ParameterSchema::new("rsi_oversold", "RSI Oversold", 20.0, 5.0, 45.0, 1.0),
            ParameterSchema::new("rsi_overbought", "RSI Overbought", 80.0, 55.0, 95.0, 1.0),
            // Diff D-07: swing-low/high window for the SL placement
            // (01_Projectplan/specs/bb_rsi_spec.md §4 algorithmic
            // definition). N=20 on 1h-bars ≈ one-day lookback.
            ParameterSchema::new(
                "swing_lookback_bars",
                "Swing Lookback Bars",
                20.0,
                5.0,
                100.0,
                1.0,
            ),
            // Diff D-06: TP distance as a multiple of the swing-derived
            // SL distance, measured from the signal-bar close (entry-price
            // proxy). Default 3.0 matches the spec §5 R:R 1:3 contract.
            ParameterSchema::new(
                "tp_rr_ratio",
                "TP R:R Ratio",
                3.0,
                0.5,
                10.0,
                0.1,
            ),
            // Diff D-09: fraction of equity risked per trade (spec §8 =
            // 2 %). The strategy converts this into a per-signal
            // `size_pct` via `position_size_pct` so the engine's
            // `open_position` can consume it directly.
            ParameterSchema::new(
                "risk_per_trade",
                "Risk Per Trade",
                0.02,
                0.001,
                1.0,
                0.001,
            ),
            // ── Session filter (Spec §7) ───────────────────────────────
            // Default OFF: pre-Phase-2.5 backtests remain byte-identical.
            // When enabled, entries fire only during [start, end) local
            // time (default 09:00–23:00 UTC+1 Berlin, no DST).
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
            // ── Welle R2-2 ADX regime filter ──────────────────────────
            // All four default to "off" so a fresh BB+RSI instance
            // behaves byte-identical to the pre-R2 implementation. The
            // four-knob shape (enabled / threshold / period / DI
            // confluence) is shared bit-for-bit with the UT-Bot and
            // Ichimoku manifests so the Welle-R3 acceptance backtest
            // can sweep an IDENTICAL parameter axis across strategies.
            ParameterSchema::new(
                "adx_filter_enabled",
                "ADX Regime Filter Enabled (0/1)",
                0.0,
                0.0,
                1.0,
                1.0,
            ),
            // Wilder's textbook chop/trend boundary is 25; 20–30 is the
            // commonly cited band. Range allows the Welle-R3 sweep to
            // explore 15..40 without re-touching the manifest.
            ParameterSchema::new(
                "adx_threshold",
                "ADX Threshold",
                25.0,
                0.0,
                100.0,
                1.0,
            ),
            // Wilder default = 14. Range bracketed to keep the helper
            // tractable on 1h fixtures while leaving headroom for
            // higher-TF experiments.
            ParameterSchema::new(
                "adx_period",
                "ADX Period",
                14.0,
                2.0,
                100.0,
                1.0,
            ),
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

    // ── SMA tests ────────────────────────────────────────────────────────

    #[test]
    fn test_sma_basic() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        assert!((sma(&data) - 3.0).abs() < 1e-10);
    }

    #[test]
    fn test_sma_single() {
        assert!((sma(&[42.0]) - 42.0).abs() < 1e-10);
    }

    #[test]
    fn test_sma_empty() {
        assert_eq!(sma(&[]), 0.0);
    }

    // ── Stddev tests ────────────────────────────────────────────────────

    #[test]
    fn test_stddev_basic() {
        // Population stddev of [2, 4, 4, 4, 5, 5, 7, 9] = 2.0
        let data = vec![2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0];
        assert!((stddev(&data) - 2.0).abs() < 1e-10);
    }

    #[test]
    fn test_stddev_constant() {
        let data = vec![5.0; 10];
        assert!((stddev(&data)).abs() < 1e-10);
    }

    // ── Bollinger Bands tests ────────────────────────────────────────────

    #[test]
    fn test_bb_insufficient_data() {
        let closes = vec![1.0, 2.0, 3.0];
        assert!(calc_bollinger_bands(&closes, 5, 2.0).is_none());
    }

    #[test]
    fn test_bb_constant_prices() {
        // With constant prices, stddev = 0, so upper == middle == lower
        let closes = vec![100.0; 20];
        let bb = calc_bollinger_bands(&closes, 20, 2.0).unwrap();
        assert!((bb.middle - 100.0).abs() < 1e-10);
        assert!((bb.upper - 100.0).abs() < 1e-10);
        assert!((bb.lower - 100.0).abs() < 1e-10);
    }

    #[test]
    fn test_bb_known_values() {
        // 5-period BB on [10, 12, 11, 13, 14]
        let closes = vec![10.0, 12.0, 11.0, 13.0, 14.0];
        let bb = calc_bollinger_bands(&closes, 5, 2.0).unwrap();
        let expected_mean = 12.0;
        assert!((bb.middle - expected_mean).abs() < 1e-10);
        let sd = stddev(&closes);
        assert!((bb.upper - (expected_mean + 2.0 * sd)).abs() < 1e-10);
        assert!((bb.lower - (expected_mean - 2.0 * sd)).abs() < 1e-10);
    }

    #[test]
    fn test_bb_uses_last_n_closes() {
        // Ensure only the last `period` closes are used
        let closes = vec![100.0, 200.0, 10.0, 10.0, 10.0];
        let bb = calc_bollinger_bands(&closes, 3, 2.0).unwrap();
        assert!((bb.middle - 10.0).abs() < 1e-10);
    }

    // ── EMA tests ────────────────────────────────────────────────────────

    #[test]
    fn test_ema_insufficient_data() {
        assert!(calc_ema(&[1.0, 2.0, 3.0], 5).is_none());
    }

    #[test]
    fn test_ema_zero_period() {
        assert!(calc_ema(&[1.0, 2.0, 3.0], 0).is_none());
    }

    #[test]
    fn test_ema_seed_equals_sma_when_history_equals_period() {
        // values.len() == period → EMA equals seed SMA (no recursive step yet)
        let closes = vec![10.0, 12.0, 14.0, 16.0, 18.0];
        let ema = calc_ema(&closes, 5).unwrap();
        assert!((ema - 14.0).abs() < 1e-12, "EMA seed: {}", ema);
    }

    #[test]
    fn test_ema_period_1_tracks_last_value() {
        // alpha = 2/(1+1) = 1 → EMA always equals current value
        let closes = vec![10.0, 20.0, 5.0, 7.0];
        let ema = calc_ema(&closes, 1).unwrap();
        assert!((ema - 7.0).abs() < 1e-12);
    }

    #[test]
    fn test_ema_constant_series() {
        let closes = vec![100.0; 50];
        let ema = calc_ema(&closes, 14).unwrap();
        assert!((ema - 100.0).abs() < 1e-12);
    }

    #[test]
    fn test_ema_known_values_period_5() {
        // Hand-computed reference (locked for Dart↔Rust parity):
        //   alpha = 2/(5+1) = 1/3
        //   SMA seed of [10,12,11,13,14] = 12.0
        //   EMA after 15 = (1/3)*15 + (2/3)*12 = 13.0
        //   EMA after 14 = (1/3)*14 + (2/3)*13 = 13.333333333333334
        let closes = vec![10.0, 12.0, 11.0, 13.0, 14.0, 15.0, 14.0];
        let ema = calc_ema(&closes, 5).unwrap();
        let expected = 13.333_333_333_333_334;
        assert!(
            (ema - expected).abs() < 1e-12,
            "EMA(5): expected {} got {}",
            expected,
            ema
        );
    }

    #[test]
    fn test_bb_ema_basis_equals_sma_when_period_equals_history() {
        // values.len() == period → EMA seed = SMA, so BB-EMA basis equals
        // BB-SMA basis. Stddev component is identical by construction.
        let closes = vec![10.0, 12.0, 11.0, 13.0, 14.0];
        let bb_sma = calc_bollinger_bands(&closes, 5, 2.0).unwrap();
        let bb_ema = calc_bollinger_bands_ema(&closes, 5, 2.0).unwrap();
        assert!((bb_ema.middle - bb_sma.middle).abs() < 1e-12);
        assert!((bb_ema.upper - bb_sma.upper).abs() < 1e-12);
        assert!((bb_ema.lower - bb_sma.lower).abs() < 1e-12);
    }

    #[test]
    fn test_bb_ema_basis_drifts_from_sma_on_long_history() {
        // With more history than period and a non-linear path, EMA
        // diverges from the window-SMA basis. A strictly linear ramp
        // hits a numeric coincidence where EMA(period=5) lands exactly
        // on the window SMA after 3 alpha steps, so we use an early-jump
        // pattern: low base, then a sharp step up, then a plateau.
        let closes = vec![10.0, 10.0, 10.0, 10.0, 10.0, 80.0, 80.0, 80.0];
        let bb_sma = calc_bollinger_bands(&closes, 5, 2.0).unwrap();
        let bb_ema = calc_bollinger_bands_ema(&closes, 5, 2.0).unwrap();
        // Window-SMA of [10,10,80,80,80] = 52.0. EMA-after-step:
        //   seed = mean(10,10,10,10,10) = 10
        //   ema_5 = (1/3)*80 + (2/3)*10 = 33.333...
        //   ema_6 = (1/3)*80 + (2/3)*33.333... = 48.888...
        //   ema_7 = (1/3)*80 + (2/3)*48.888... = 59.259...
        // → EMA basis is well below the window SMA on this pattern.
        assert!(
            (bb_ema.middle - bb_sma.middle).abs() > 1.0,
            "ema={} sma={}",
            bb_ema.middle,
            bb_sma.middle
        );
        // Stddev is computed against the window-SMA in both variants → the
        // band-width (upper - lower) must match exactly.
        let width_sma = bb_sma.upper - bb_sma.lower;
        let width_ema = bb_ema.upper - bb_ema.lower;
        assert!(
            (width_ema - width_sma).abs() < 1e-12,
            "BB band width must be identical between SMA and EMA variants \
             (stddev component is independent of basis); width_sma={} \
             width_ema={}",
            width_sma,
            width_ema
        );
    }

    #[test]
    fn test_bb_ema_insufficient_data() {
        assert!(calc_bollinger_bands_ema(&[1.0, 2.0], 5, 2.0).is_none());
    }

    // ── Swing-low / swing-high tests (Diff D-07) ─────────────────────────

    #[test]
    fn test_swing_low_basic() {
        // Minimum across the slice — exact, no float fuzz.
        let lows = vec![10.0, 7.5, 8.0, 9.0, 6.5, 11.0];
        assert!((swing_low(&lows).unwrap() - 6.5).abs() < 1e-12);
    }

    #[test]
    fn test_swing_high_basic() {
        let highs = vec![10.0, 12.5, 8.0, 14.0, 13.5, 11.0];
        assert!((swing_high(&highs).unwrap() - 14.0).abs() < 1e-12);
    }

    #[test]
    fn test_swing_helpers_empty() {
        // Empty slice → no swing defined → None (mirrors `swingLow`/
        // `swingHigh` in `lib/services/indicators.dart`).
        assert!(swing_low(&[]).is_none());
        assert!(swing_high(&[]).is_none());
    }

    #[test]
    fn test_swing_helpers_single() {
        // Single-value slice trivially returns that value.
        assert!((swing_low(&[42.5]).unwrap() - 42.5).abs() < 1e-12);
        assert!((swing_high(&[42.5]).unwrap() - 42.5).abs() < 1e-12);
    }

    #[test]
    fn test_position_size_pct_typical_case() {
        // entry=100, sl=98 → sl_distance=2; risk=0.02
        // size_pct = 100 * 0.02 * 100 / 2 = 100 → exactly capped.
        let got = position_size_pct(100.0, 2.0, 0.02);
        assert!((got - 100.0).abs() < 1e-12);
    }

    #[test]
    fn test_position_size_pct_tight_sl_clamps_to_full_balance() {
        // entry=100, sl_distance=0.5 → unclamped would be 100*0.02*100/0.5
        // = 400 (= 4x leverage), the engine spec says clamp to 100.
        let got = position_size_pct(100.0, 0.5, 0.02);
        assert!((got - 100.0).abs() < 1e-12);
    }

    #[test]
    fn test_position_size_pct_wide_sl_reduces_size() {
        // entry=100, sl_distance=20 → 100*0.02*100/20 = 10. The signal is
        // small enough that the trade only puts 10 % of equity at notional.
        let got = position_size_pct(100.0, 20.0, 0.02);
        assert!((got - 10.0).abs() < 1e-12);
    }

    #[test]
    fn test_position_size_pct_zero_or_negative_inputs_yield_zero() {
        assert_eq!(position_size_pct(100.0, 0.0, 0.02), 0.0);
        assert_eq!(position_size_pct(100.0, -1.0, 0.02), 0.0);
        assert_eq!(position_size_pct(0.0, 1.0, 0.02), 0.0);
        assert_eq!(position_size_pct(100.0, 1.0, 0.0), 0.0);
    }

    #[test]
    fn test_swing_helpers_negative_values() {
        // Pin the comparison semantics against signed values — `f64::min`
        // and `f64::max` handle these correctly; a naive accumulator
        // initialised to 0.0 would break for all-negative inputs.
        let lows = vec![-1.0, -5.0, -3.0, -2.0];
        let highs = vec![-1.0, -5.0, -3.0, -2.0];
        assert!((swing_low(&lows).unwrap() - -5.0).abs() < 1e-12);
        assert!((swing_high(&highs).unwrap() - -1.0).abs() < 1e-12);
    }

    #[test]
    fn test_ema_path_dependent_on_history_length() {
        // Same final 5 closes but different prior history → different EMA.
        // This pins WHY the strategy must feed the full prior-close history
        // (mirrors the F-02b contract for RSI).
        let long_history = vec![100.0, 105.0, 102.0, 108.0, 110.0, 115.0, 120.0];
        let short_window = &long_history[long_history.len() - 5..]; // [102,108,110,115,120]

        let ema_full = calc_ema(&long_history, 5).unwrap();
        let ema_partial = calc_ema(short_window, 5).unwrap();
        // ema_full uses 7 closes, ema_partial only the last 5 → seeds differ.
        assert!(
            (ema_full - ema_partial).abs() > 1e-3,
            "EMA must be path-dependent on history length: full={} partial={}",
            ema_full,
            ema_partial
        );
    }

    // ── RSI tests ────────────────────────────────────────────────────────

    #[test]
    fn test_rsi_insufficient_data() {
        let closes = vec![1.0, 2.0, 3.0];
        assert!(calc_rsi(&closes, 14).is_none());
    }

    #[test]
    fn test_rsi_all_gains() {
        // Monotonically increasing prices → RSI should be 100
        let closes: Vec<f64> = (0..=20).map(|i| 100.0 + i as f64).collect();
        let rsi = calc_rsi(&closes, 14).unwrap();
        assert!((rsi - 100.0).abs() < 1e-6, "RSI all gains: {}", rsi);
    }

    #[test]
    fn test_rsi_all_losses() {
        // Monotonically decreasing prices → RSI should be 0
        let closes: Vec<f64> = (0..=20).map(|i| 100.0 - i as f64).collect();
        let rsi = calc_rsi(&closes, 14).unwrap();
        assert!(rsi.abs() < 1e-6, "RSI all losses: {}", rsi);
    }

    #[test]
    fn test_rsi_equal_gains_losses() {
        // Alternating +1 / -1 → roughly RSI 50
        let mut closes = vec![100.0];
        for i in 1..=28 {
            if i % 2 == 1 {
                closes.push(closes.last().unwrap() + 1.0);
            } else {
                closes.push(closes.last().unwrap() - 1.0);
            }
        }
        let rsi = calc_rsi(&closes, 14).unwrap();
        assert!(
            (rsi - 50.0).abs() < 5.0,
            "RSI with equal gains/losses should be near 50, got {}",
            rsi
        );
    }

    #[test]
    fn test_rsi_known_value() {
        // Hand-computed RSI(5) for a small dataset
        // closes = [44, 44.34, 44.09, 43.61, 44.33, 44.83]
        // changes =     [0.34,  -0.25, -0.48,  0.72,  0.50]
        // First avg gain = (0.34 + 0.72 + 0.50) / 5 = 0.312
        // First avg loss = (0.25 + 0.48) / 5 = 0.146
        // RS = 0.312 / 0.146 = 2.13699...
        // RSI = 100 - 100/(1+2.13699) = 68.12...
        let closes = vec![44.0, 44.34, 44.09, 43.61, 44.33, 44.83];
        let rsi = calc_rsi(&closes, 5).unwrap();
        assert!(
            (rsi - 68.13).abs() < 0.5,
            "RSI(5) expected ~68.13, got {}",
            rsi
        );
    }

    // ── Strategy integration tests ──────────────────────────────────────

    #[test]
    fn test_strategy_manifest() {
        let strategy = BbRsiStrategy::new();
        let manifest = strategy.manifest();
        assert_eq!(manifest.id, "bb_rsi_v1");
        // bb_period, bb_stddev, bb_ma_type, rsi_period, rsi_oversold,
        // rsi_overbought, swing_lookback_bars (D-07), tp_rr_ratio (D-06),
        // risk_per_trade (D-09) + R2-2 ADX filter quartet
        // (adx_filter_enabled, adx_threshold, adx_period,
        // adx_use_di_confluence) = 13.
        assert_eq!(manifest.parameters.len(), 17); // +4 session params (S-01)
        assert_eq!(manifest.category, StrategyCategory::Trend);
        assert!(manifest
            .parameters
            .iter()
            .any(|p| p.name == "bb_ma_type"));
        assert!(manifest
            .parameters
            .iter()
            .any(|p| p.name == "swing_lookback_bars"));
        assert!(manifest
            .parameters
            .iter()
            .any(|p| p.name == "tp_rr_ratio"));
        assert!(manifest
            .parameters
            .iter()
            .any(|p| p.name == "risk_per_trade"));
    }

    #[test]
    fn test_strategy_reset() {
        let mut strategy = BbRsiStrategy::new();
        strategy.state.last_rsi = Some(42.0);
        strategy.state.prev_rsi = Some(40.0);
        strategy.on_reset();
        assert!(strategy.state.last_rsi.is_none());
        assert!(strategy.state.prev_rsi.is_none());
    }

    #[test]
    fn test_strategy_validate_params_ok() {
        let strategy = BbRsiStrategy::new();
        let mut params = HashMap::new();
        params.insert("bb_period".to_string(), 20.0);
        params.insert("rsi_period".to_string(), 14.0);
        assert!(strategy.validate_params(&params).is_ok());
    }

    #[test]
    fn test_strategy_validate_params_out_of_range() {
        let strategy = BbRsiStrategy::new();
        let mut params = HashMap::new();
        params.insert("bb_period".to_string(), 999.0); // max is 50
        assert!(strategy.validate_params(&params).is_err());
    }

    #[test]
    fn test_strategy_no_signal_insufficient_data() {
        let mut strategy = BbRsiStrategy::new();
        // Only 5 candles, not enough for BB(20)
        let candles: Vec<Candle> = (0..5)
            .map(|i| Candle::new(i * 60000, 100.0, 101.0, 99.0, 100.0, 1.0))
            .collect();
        let mut ctx = Context::new(candles.clone(), Timeframe::M1, HashMap::new());
        ctx.set_index(4);
        let signal = strategy.on_candle(&mut ctx, &candles[4]);
        assert!(signal.is_none());
    }

    /// Helper: assert that the strategy emitted an entry signal of the
    /// expected direction at some bar during the walk. Robust to the
    /// intermediate state where the BB-middle exit might fire on the
    /// very next bar (D-11 cleanup is in a later commit).
    fn assert_entry_direction(
        candles: &[Candle],
        expect_long: bool,
        params: HashMap<String, f64>,
    ) {
        let mut strategy = BbRsiStrategy::new();
        let mut ctx = Context::new(candles.to_vec(), Timeframe::M1, params);
        let mut seen_long = false;
        let mut seen_short = false;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(sig) = strategy.on_candle(&mut ctx, candle) {
                match sig {
                    Signal::EnterLong { .. } => seen_long = true,
                    Signal::EnterShort { .. } => seen_short = true,
                    _ => {}
                }
            }
        }
        if expect_long {
            assert!(seen_long, "expected an EnterLong signal, none observed");
            assert!(
                !seen_short,
                "did not expect any EnterShort signal on this fixture"
            );
        } else {
            assert!(seen_short, "expected an EnterShort signal, none observed");
            assert!(
                !seen_long,
                "did not expect any EnterLong signal on this fixture"
            );
        }
    }

    fn phase1_pinned_params() -> HashMap<String, f64> {
        let mut params = HashMap::new();
        params.insert("bb_period".to_string(), 20.0);
        params.insert("bb_stddev".to_string(), 2.0);
        params.insert("bb_ma_type".to_string(), 0.0); // SMA
        params.insert("rsi_period".to_string(), 14.0);
        params.insert("rsi_oversold".to_string(), 30.0);
        params.insert("rsi_overbought".to_string(), 70.0);
        params.insert("swing_lookback_bars".to_string(), 20.0);
        params.insert("tp_rr_ratio".to_string(), 3.0);
        params.insert("risk_per_trade".to_string(), 0.02);
        params
    }

    #[test]
    fn test_strategy_long_entry_signal() {
        // Phase-2 entry (Diff D-03 + D-05): long requires close > upper
        // AND RSI cross UP through oversold. The fixture has to first
        // drive RSI(14) below 30 (sustained decline), then push price
        // above the upper band on a single surge bar so RSI crosses
        // back through 30 on the same bar.
        let mut closes = vec![100.0; 20]; // BB warmup at 100
        for i in 0..14 {
            closes.push(100.0 - (i as f64 + 1.0) * 2.0); // 98, 96, …, 72
        }
        closes.push(120.0); // surge: close > upper, RSI crosses UP through 30
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0)
            })
            .collect();
        assert_entry_direction(&candles, true, phase1_pinned_params());
    }

    #[test]
    fn test_strategy_short_entry_signal() {
        // Mirror of the long-entry fixture: 14-bar ascent drives RSI(14)
        // above 70, then a single crash bar pulls close below the lower
        // band so RSI crosses DOWN through 70 on the same bar.
        let mut closes = vec![100.0; 20];
        for i in 0..14 {
            closes.push(100.0 + (i as f64 + 1.0) * 2.0); // 102, 104, …, 128
        }
        closes.push(80.0); // crash: close < lower, RSI crosses DOWN through 70
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0)
            })
            .collect();
        assert_entry_direction(&candles, false, phase1_pinned_params());
    }

    #[test]
    fn test_strategy_long_sl_equals_swing_low_of_pre_signal_window() {
        // Diff D-07: the long-entry SL must equal the minimum `low` of
        // the N bars immediately BEFORE the signal bar (spec §4 algorithm,
        // exclusive of the signal bar itself). We rebuild the same
        // 20-flat + 14-decline + surge fixture used by the entry-direction
        // test, but capture the emitted Signal::EnterLong and assert its
        // sl equals the hand-computed swing low.
        let mut closes = vec![100.0; 20];
        for i in 0..14 {
            closes.push(100.0 - (i as f64 + 1.0) * 2.0);
        }
        closes.push(120.0);
        // low = close - 0.5 → swing_low(lows[14..34]) =
        //   min(99.5 ×6 at bars 14..19, 97.5,95.5,…,71.5 at bars 20..33)
        //   = 71.5 (bar 33).
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0)
            })
            .collect();

        let mut strategy = BbRsiStrategy::new();
        let mut ctx =
            Context::new(candles.clone(), Timeframe::M1, phase1_pinned_params());
        let mut captured_sl: Option<f64> = None;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(Signal::EnterLong { sl, .. }) = strategy.on_candle(&mut ctx, candle) {
                captured_sl = sl;
                break;
            }
        }
        let got = captured_sl.expect("expected EnterLong with SL");
        assert!(
            (got - 71.5).abs() < 1e-12,
            "swing-low SL expected 71.5 (bar 33 low), got {}",
            got
        );
    }

    #[test]
    fn test_strategy_short_sl_equals_swing_high_of_pre_signal_window() {
        // Mirror of the long-SL test: 20-flat + 14-ascent + crash bar.
        // swing_high(highs[14..34]) = max(100.5 ×6, 102.5,…,128.5) = 128.5.
        let mut closes = vec![100.0; 20];
        for i in 0..14 {
            closes.push(100.0 + (i as f64 + 1.0) * 2.0);
        }
        closes.push(80.0);
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0)
            })
            .collect();

        let mut strategy = BbRsiStrategy::new();
        let mut ctx =
            Context::new(candles.clone(), Timeframe::M1, phase1_pinned_params());
        let mut captured_sl: Option<f64> = None;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(Signal::EnterShort { sl, .. }) = strategy.on_candle(&mut ctx, candle) {
                captured_sl = sl;
                break;
            }
        }
        let got = captured_sl.expect("expected EnterShort with SL");
        assert!(
            (got - 128.5).abs() < 1e-12,
            "swing-high SL expected 128.5 (bar 33 high), got {}",
            got
        );
    }

    #[test]
    fn test_strategy_long_tp_at_three_times_sl_distance_from_signal_close() {
        // Diff D-06: TP distance = `tp_rr_ratio` × SL distance, measured
        // from the signal-bar close (which serves as entry-price proxy
        // since the actual fill is at the next bar's open). For the same
        // 20-flat + 14-decline + surge fixture used elsewhere:
        //   signal-bar close = 120
        //   swing_low = 71.5
        //   sl_distance = 120 - 71.5 = 48.5
        //   tp = 120 + 3.0 * 48.5 = 265.5
        let mut closes = vec![100.0; 20];
        for i in 0..14 {
            closes.push(100.0 - (i as f64 + 1.0) * 2.0);
        }
        closes.push(120.0);
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0)
            })
            .collect();

        let mut strategy = BbRsiStrategy::new();
        let mut ctx =
            Context::new(candles.clone(), Timeframe::M1, phase1_pinned_params());
        let mut captured_tp: Option<f64> = None;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(Signal::EnterLong { tp, .. }) = strategy.on_candle(&mut ctx, candle) {
                captured_tp = tp;
                break;
            }
        }
        let got = captured_tp.expect("expected EnterLong with TP");
        assert!(
            (got - 265.5).abs() < 1e-9,
            "R:R 1:3 TP from signal-bar close: expected 265.5, got {}",
            got
        );
    }

    #[test]
    fn test_strategy_short_tp_at_three_times_sl_distance_from_signal_close() {
        // Mirror for short: signal-bar close = 80, swing_high = 128.5,
        // sl_distance = 48.5, tp = 80 - 3.0 * 48.5 = -65.5 (theoretically
        // unreachable for the synthetic fixture — see the discussion in
        // 01_Projectplan/specs/bb_rsi_spec.md §13 about asset-mismatch on
        // BTCUSDT 1h with the default-strategy SL/TP). We assert the
        // arithmetic regardless: the engine emits the spec-derived TP
        // and lets the bar action decide whether it gets hit.
        let mut closes = vec![100.0; 20];
        for i in 0..14 {
            closes.push(100.0 + (i as f64 + 1.0) * 2.0);
        }
        closes.push(80.0);
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0)
            })
            .collect();

        let mut strategy = BbRsiStrategy::new();
        let mut ctx =
            Context::new(candles.clone(), Timeframe::M1, phase1_pinned_params());
        let mut captured_tp: Option<f64> = None;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(Signal::EnterShort { tp, .. }) = strategy.on_candle(&mut ctx, candle) {
                captured_tp = tp;
                break;
            }
        }
        let got = captured_tp.expect("expected EnterShort with TP");
        assert!(
            (got - -65.5).abs() < 1e-9,
            "R:R 1:3 TP from signal-bar close: expected -65.5, got {}",
            got
        );
    }

    #[test]
    fn test_strategy_long_size_pct_matches_risk_2_percent_formula() {
        // Diff D-09: long entry on the 20-flat + 14-decline + surge
        // fixture. signal-bar close=120, swing_low=71.5, sl_distance=48.5.
        // With risk_per_trade=0.02:
        //   size_pct = 100 * 0.02 * 120 / 48.5 ≈ 4.9484536...
        // The emitted signal must carry this value (NOT 100.0 — that was
        // the legacy full-balance default).
        let mut closes = vec![100.0; 20];
        for i in 0..14 {
            closes.push(100.0 - (i as f64 + 1.0) * 2.0);
        }
        closes.push(120.0);
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0)
            })
            .collect();

        let mut strategy = BbRsiStrategy::new();
        let mut ctx =
            Context::new(candles.clone(), Timeframe::M1, phase1_pinned_params());
        let mut captured_pct: Option<f64> = None;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(Signal::EnterLong { size_pct, .. }) =
                strategy.on_candle(&mut ctx, candle)
            {
                captured_pct = Some(size_pct);
                break;
            }
        }
        let got = captured_pct.expect("expected EnterLong with size_pct");
        let expected = 100.0 * 0.02 * 120.0 / 48.5;
        assert!(
            (got - expected).abs() < 1e-12,
            "risk-sized size_pct: expected {} got {}",
            expected,
            got
        );
        // Sanity: well below 100, so the signal does NOT get clamped to
        // full balance on this fixture.
        assert!(got < 100.0);
    }

    #[test]
    fn test_strategy_ema_basis_changes_bb_state() {
        // With ma_type=EMA the published bb_middle in ctx state must equal
        // the EMA of the full prior-close history, not the SMA of the last
        // `bb_period` closes. Pins the on_candle EMA branch.
        let mut strategy = BbRsiStrategy::new();
        let mut closes = vec![100.0; 30];
        for i in 0..15 {
            closes.push(100.0 + (i as f64 + 1.0) * 5.0);
        }
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0))
            .collect();
        // Pin bb_period=20 so the 45-candle fixture clears the warm-up
        // boundary; this test isolates the EMA-basis wiring, not the
        // Phase-2 default shift.
        let params = HashMap::from([
            ("bb_ma_type".to_string(), 1.0),
            ("bb_period".to_string(), 20.0),
            ("bb_stddev".to_string(), 2.0),
            ("rsi_period".to_string(), 14.0),
            ("rsi_oversold".to_string(), 30.0),
            ("rsi_overbought".to_string(), 70.0),
        ]);
        let mut ctx = Context::new(candles.clone(), Timeframe::H1, params);
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            let _ = strategy.on_candle(&mut ctx, candle);
        }
        // After running on the full history with bb_period=20, the basis
        // should equal calc_ema(&closes, 20).
        let expected = calc_ema(&closes, 20).unwrap();
        let got = ctx.get_state("bb_middle").unwrap();
        assert!(
            (got - expected).abs() < 1e-12,
            "ma_type=EMA: bb_middle expected {} got {}",
            expected,
            got
        );
    }

    // ── Welle R2-2: ADX regime filter wiring ────────────────────────────
    //
    // The synthetic 20-flat + 14-decline + surge / -ascent + crash
    // fixtures from the entry-direction tests reach a strong directional
    // ADX once the trend leg unfolds (≈30+ by the signal bar with
    // adx_period=14), so they exercise both the "filter blocks" and
    // "filter passes" paths cleanly.

    fn build_long_fixture() -> Vec<Candle> {
        // Same shape as `test_strategy_long_entry_signal`: 20 flat, 14
        // declining bars, then a surge that triggers the BB+RSI cross.
        let mut closes = vec![100.0; 20];
        for i in 0..14 {
            closes.push(100.0 - (i as f64 + 1.0) * 2.0);
        }
        closes.push(120.0);
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0))
            .collect()
    }

    fn count_entries(candles: &[Candle], params: HashMap<String, f64>) -> usize {
        let mut strategy = BbRsiStrategy::new();
        let mut ctx = Context::new(candles.to_vec(), Timeframe::M1, params);
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

    #[test]
    fn test_adx_filter_disabled_does_not_change_signals_on_long_fixture() {
        // Default `phase1_pinned_params` keeps adx_filter_enabled
        // absent (param map empty for that key → `param_or(_, 0.0)`
        // takes the disabled branch). Explicitly setting the flag to
        // 0.0 must produce the same entry count — pins that the
        // disabled gate skips all ADX code paths.
        let candles = build_long_fixture();
        let baseline = count_entries(&candles, phase1_pinned_params());
        let mut with_flag = phase1_pinned_params();
        with_flag.insert("adx_filter_enabled".to_string(), 0.0);
        assert_eq!(
            count_entries(&candles, with_flag),
            baseline,
            "adx_filter_enabled=0.0 must be identical to default",
        );
        // Sanity: the fixture really does emit at least one signal —
        // otherwise the equality above would be a tautology.
        assert!(baseline >= 1, "fixture must emit ≥ 1 entry");
    }

    #[test]
    fn test_adx_filter_high_threshold_blocks_entries() {
        // With the filter on and the threshold pegged at 100 the gate
        // can never pass (ADX is bounded by 100 by construction; only
        // a perfectly monotone trend approaches the cap, and even then
        // the smoothing has to settle there). The entry block must
        // emit 0 EnterLong/EnterShort.
        let candles = build_long_fixture();
        let mut params = phase1_pinned_params();
        params.insert("adx_filter_enabled".to_string(), 1.0);
        params.insert("adx_threshold".to_string(), 100.0);
        params.insert("adx_period".to_string(), 14.0);
        assert_eq!(
            count_entries(&candles, params),
            0,
            "adx_threshold=100 must block every entry",
        );
    }

    #[test]
    fn test_adx_filter_zero_threshold_matches_disabled_count_on_long_fixture() {
        // adx_threshold=0 collapses the ADX gate to a NaN-only check.
        // The 14-bar decline + 14-bar warm-up on adx_period=14 means
        // the first valid ADX seed lands at bar 26 = bar 27 in the
        // 35-bar fixture (well before the signal bar at 34). So the
        // entry count under filter=on/threshold=0 must equal the
        // disabled-baseline — pins that the gate is a true pass-
        // through when threshold=0 (within DI-confluence rules).
        let candles = build_long_fixture();
        let baseline = count_entries(&candles, phase1_pinned_params());

        let mut params = phase1_pinned_params();
        params.insert("adx_filter_enabled".to_string(), 1.0);
        params.insert("adx_threshold".to_string(), 0.0);
        params.insert("adx_period".to_string(), 14.0);
        params.insert("adx_use_di_confluence".to_string(), 0.0);
        assert_eq!(
            count_entries(&candles, params),
            baseline,
            "adx_threshold=0 + no DI confluence must equal disabled baseline",
        );
    }

    // Note: DI-confluence semantics are pinned bit-for-bit on the helper
    // itself by `addins::common::tests::test_regime_filter_di_confluence_*`
    // (5 tests covering pass/block on both sides, equality, NaN). Those
    // would catch a logic flip; the BB+RSI tests above pin the wiring
    // (enabled/disabled, threshold range), which is the part the helper
    // tests cannot see.

    /// Example: instantiate and run the strategy on synthetic candle data.
    #[test]
    fn test_example_full_run() {
        let mut strategy = BbRsiStrategy::new();

        // Generate 100 candles with a sine-wave pattern (mean-reverting by nature)
        let candles: Vec<Candle> = (0..100)
            .map(|i| {
                let base = 50000.0;
                let wave = 500.0 * (i as f64 * 0.15).sin();
                let close = base + wave;
                let high = close + 50.0;
                let low = close - 50.0;
                Candle::new(i * 60_000, close - 25.0, high, low, close, 100.0 + i as f64)
            })
            .collect();

        let params = HashMap::from([
            ("bb_period".to_string(), 20.0),
            ("bb_stddev".to_string(), 2.0),
            ("rsi_period".to_string(), 14.0),
            ("rsi_oversold".to_string(), 30.0),
            ("rsi_overbought".to_string(), 70.0),
        ]);

        let mut ctx = Context::new(candles.clone(), Timeframe::H1, params);

        let mut entries = 0u32;
        let mut exits = 0u32;
        let mut no_actions = 0u32;

        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(signal) = strategy.on_candle(&mut ctx, candle) {
                match &signal {
                    Signal::EnterLong { .. } | Signal::EnterShort { .. } => entries += 1,
                    Signal::Exit { .. } => exits += 1,
                    Signal::NoAction => no_actions += 1,
                    _ => {}
                }
            }
        }

        // Verify the strategy actually ran and produced signals
        assert!(no_actions > 0, "Should have NoAction signals");
        println!(
            "Full run: {} entries, {} exits, {} no-action (total {} candles)",
            entries,
            exits,
            no_actions,
            candles.len()
        );

        // Verify indicator state is populated after the run
        let state = strategy.indicator_state();
        assert!(state.last_bb.is_some(), "BB should be computed");
        assert!(state.last_rsi.is_some(), "RSI should be computed");
    }
}
