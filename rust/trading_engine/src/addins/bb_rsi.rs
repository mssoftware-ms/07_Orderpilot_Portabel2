//! Bollinger Bands + RSI Strategy Add-in.
//!
//! Defaults, entry direction and RSI cross-back trigger match the
//! video-spec "verbesserte Variante" (see
//! `01_Projectplan/specs/bb_rsi_spec.md` §1–§3, Diff D-01..D-05). The
//! BB-middle / RSI-extreme exit removal (D-11) and the R:R 1:3 +
//! swing-low SL (D-06/D-07/D-08/D-09) land in subsequent commits.
//!
//! # Parameters
//! | Name            | Default | Range    | Description                                  |
//! |-----------------|---------|----------|----------------------------------------------|
//! | bb_period       | 200     | 5–500    | Bollinger Bands MA lookback                  |
//! | bb_stddev       | 0.2     | 0.1–5.0  | Standard-deviation multiplier                |
//! | bb_ma_type      | 1 (EMA) | 0–1      | Basis MA type (0=SMA, 1=EMA)                 |
//! | rsi_period      | 3       | 2–50     | RSI lookback period                          |
//! | rsi_oversold    | 20      | 5–45     | RSI oversold threshold / level for long     |
//! | rsi_overbought  | 80      | 55–95    | RSI overbought threshold / level for short  |

use std::collections::HashMap;

use crate::models::{Candle, ExitReason, Timeframe};
use crate::strategy::{
    AddinManifest, Context, InputSpec, ParameterSchema, Signal, StrategyAddin, StrategyCategory,
};

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
    /// Whether we are in a long position.
    pub in_long: bool,
    /// Whether we are in a short position.
    pub in_short: bool,
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
            InputSpec::MinCandles(50), // need enough history for BB(20) + RSI(14)
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

        // F-09 parity gate: match Dart `startIdx = max(bbPeriod, rsiPeriod + 1)`.
        // Without this, Rust emits signals one bar earlier than Dart at the
        // BB-warmup boundary on real markets (cf. phase1_reference_backtest).
        // Plan rev3 §3.4 establishes Dart's convention as canonical.
        let start_idx = bb_period.max(rsi_period + 1);
        if ctx.index() < start_idx {
            return None;
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

        // ── Exit logic (checked first) ──────────────────────────────────
        // Phase-2 Diff D-03/D-04 inverts the strategy from mean-reversion
        // to trend-following: long enters above the upper band, short
        // enters below the lower band. The intermediate exit conditions
        // here mirror the OLD mean-reversion exits so the strategy stays
        // coherent at this commit (price reverting to the middle band
        // means the trend pullback is over). Diff D-11 (next commit)
        // removes these blocks entirely; the final spec uses only SL/TP
        // exits set at entry.
        if self.state.in_long && (price <= bb.middle || rsi < rsi_oversold) {
            self.state.in_long = false;
            ctx.in_position = false;
            return Some(Signal::Exit {
                reason: ExitReason::Signal("BB middle / RSI exit".to_string()),
            });
        }

        if self.state.in_short && (price >= bb.middle || rsi > rsi_overbought) {
            self.state.in_short = false;
            ctx.in_position = false;
            return Some(Signal::Exit {
                reason: ExitReason::Signal("BB middle / RSI exit".to_string()),
            });
        }

        // ── Entry logic ─────────────────────────────────────────────────
        // Diff D-03/D-04 + Diff D-05: trend-follow + RSI cross-back
        // through the oversold/overbought level per video-spec §2/§3.
        //   Long  ⇔ price > BB.upper AND RSI(prev) < oversold AND RSI(cur) ≥ oversold
        //   Short ⇔ price < BB.lower AND RSI(prev) > overbought AND RSI(cur) ≤ overbought
        // Strict comparison on the prev side prevents re-triggering after
        // RSI flatlines on a threshold. `None` for prev_rsi (first valid
        // bar after warm-up) suppresses the cross — no signal possible.
        // SL/TP placeholders are still the BB-geometry mirror from
        // Diff D-04; video-spec R:R 1:3 + swing-low SL land in Welle 2.
        if !ctx.in_position {
            if let Some(prev) = prev_rsi {
                if price > bb.upper && prev < rsi_oversold && rsi >= rsi_oversold {
                    self.state.in_long = true;
                    self.state.in_short = false;
                    ctx.in_position = true;
                    return Some(Signal::long(
                        Some(bb.middle),
                        Some(bb.upper + (bb.upper - bb.middle)),
                    ));
                }

                if price < bb.lower && prev > rsi_overbought && rsi <= rsi_overbought {
                    self.state.in_short = true;
                    self.state.in_long = false;
                    ctx.in_position = true;
                    return Some(Signal::short(
                        Some(bb.middle),
                        Some(bb.lower - (bb.middle - bb.lower)),
                    ));
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
        Ok(())
    }
}

/// Build the canonical AddinManifest for BB+RSI.
pub fn bb_rsi_manifest() -> AddinManifest {
    AddinManifest {
        id: "bb_rsi_v1".to_string(),
        name: "Bollinger Bands + RSI Mean Reversion".to_string(),
        version: "1.0.0".to_string(),
        author: "Trading App Team".to_string(),
        description:
            "Mean-reversion strategy: enter when price touches a Bollinger Band extreme \
             with confirming RSI, exit at the middle band or opposite RSI extreme."
                .to_string(),
        category: StrategyCategory::MeanReversion,
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
        // bb_period, bb_stddev, bb_ma_type, rsi_period, rsi_oversold, rsi_overbought
        assert_eq!(manifest.parameters.len(), 6);
        assert_eq!(manifest.category, StrategyCategory::MeanReversion);
        assert!(manifest
            .parameters
            .iter()
            .any(|p| p.name == "bb_ma_type"));
    }

    #[test]
    fn test_strategy_reset() {
        let mut strategy = BbRsiStrategy::new();
        strategy.state.in_long = true;
        strategy.state.last_rsi = Some(42.0);
        strategy.on_reset();
        assert!(!strategy.state.in_long);
        assert!(strategy.state.last_rsi.is_none());
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
