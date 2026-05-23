//! Bollinger Bands + RSI Mean Reversion Strategy Add-in.
//!
//! # Strategy Logic
//! - **Long entry**: Price touches lower Bollinger Band AND RSI < oversold threshold (default 30)
//! - **Short entry**: Price touches upper Bollinger Band AND RSI > overbought threshold (default 70)
//! - **Exit**: Opposite signal or price crosses the middle band (SMA)
//!
//! # Parameters
//! | Name            | Default | Range    | Description                       |
//! |-----------------|---------|----------|-----------------------------------|
//! | bb_period       | 20      | 10–50    | Bollinger Bands SMA lookback      |
//! | bb_stddev       | 2.0     | 1.0–3.0  | Standard-deviation multiplier     |
//! | rsi_period      | 14      | 7–30     | RSI lookback period               |
//! | rsi_oversold    | 30      | 20–40    | RSI oversold threshold            |
//! | rsi_overbought  | 70      | 60–80    | RSI overbought threshold          |

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
        let bb_period = ctx.param_or("bb_period", 20.0) as usize;
        let bb_stddev_mult = ctx.param_or("bb_stddev", 2.0);
        let rsi_period = ctx.param_or("rsi_period", 14.0) as usize;
        let rsi_oversold = ctx.param_or("rsi_oversold", 30.0);
        let rsi_overbought = ctx.param_or("rsi_overbought", 70.0);

        // F-09 parity gate: match Dart `startIdx = max(bbPeriod, rsiPeriod + 1)`.
        // Without this, Rust emits signals one bar earlier than Dart at the
        // BB-warmup boundary on real markets (cf. phase1_reference_backtest).
        // Plan rev3 §3.4 establishes Dart's convention as canonical.
        let start_idx = bb_period.max(rsi_period + 1);
        if ctx.index() < start_idx {
            return None;
        }

        // BB uses a fixed `bb_period` rolling window. RSI must run cumulative
        // Wilder smoothing across the FULL prior-close history (F-02b) to
        // match the Dart engine — feeding only the last 20 closes restarts
        // the smoothing every bar and drifts noticeably on non-stationary
        // series (cf. tests/regression_f02b_rsi_wilder.rs).
        let bb_closes = ctx.closes(bb_period);
        let rsi_closes = ctx.closes(ctx.index() + 1);
        if bb_closes.len() < bb_period || rsi_closes.len() < rsi_period + 1 {
            return None;
        }

        // Compute indicators
        let bb = calc_bollinger_bands(&bb_closes, bb_period, bb_stddev_mult)?;
        let rsi = calc_rsi(&rsi_closes, rsi_period)?;

        // Persist indicator values in context state for external access
        ctx.set_state("bb_upper", bb.upper);
        ctx.set_state("bb_middle", bb.middle);
        ctx.set_state("bb_lower", bb.lower);
        ctx.set_state("rsi", rsi);

        // Persist in our own struct too
        self.state.last_bb = Some(bb);
        self.state.last_rsi = Some(rsi);

        let price = ctx.current_price();

        // ── Exit logic (checked first) ──────────────────────────────────
        if self.state.in_long {
            // Exit long: price crosses above middle band or overbought RSI.
            // F-09: strict `>` matches Dart's operator (rsi > overbought) — avoids
            // floating-point equality edge at rsi == 70.0.
            if price >= bb.middle || rsi > rsi_overbought {
                self.state.in_long = false;
                ctx.in_position = false;
                return Some(Signal::Exit {
                    reason: ExitReason::Signal("BB middle / RSI exit".to_string()),
                });
            }
        }

        if self.state.in_short {
            // Exit short: price crosses below middle band or oversold RSI.
            // F-09: strict `<` matches Dart's operator (rsi < oversold) — avoids
            // floating-point equality edge at rsi == 30.0.
            if price <= bb.middle || rsi < rsi_oversold {
                self.state.in_short = false;
                ctx.in_position = false;
                return Some(Signal::Exit {
                    reason: ExitReason::Signal("BB middle / RSI exit".to_string()),
                });
            }
        }

        // ── Entry logic ─────────────────────────────────────────────────
        if !ctx.in_position {
            // Long entry: price touches lower BB AND RSI oversold
            if price <= bb.lower && rsi < rsi_oversold {
                self.state.in_long = true;
                self.state.in_short = false;
                ctx.in_position = true;
                return Some(Signal::long(Some(bb.lower - (bb.middle - bb.lower)), Some(bb.middle)));
            }

            // Short entry: price touches upper BB AND RSI overbought
            if price >= bb.upper && rsi > rsi_overbought {
                self.state.in_short = true;
                self.state.in_long = false;
                ctx.in_position = true;
                return Some(Signal::short(Some(bb.upper + (bb.upper - bb.middle)), Some(bb.middle)));
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
            ParameterSchema::new("bb_period", "BB Period", 20.0, 10.0, 50.0, 1.0),
            ParameterSchema::new("bb_stddev", "BB Std Dev", 2.0, 1.0, 3.0, 0.1),
            ParameterSchema::new("rsi_period", "RSI Period", 14.0, 7.0, 30.0, 1.0),
            ParameterSchema::new("rsi_oversold", "RSI Oversold", 30.0, 20.0, 40.0, 1.0),
            ParameterSchema::new("rsi_overbought", "RSI Overbought", 70.0, 60.0, 80.0, 1.0),
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
        assert_eq!(manifest.parameters.len(), 5);
        assert_eq!(manifest.category, StrategyCategory::MeanReversion);
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

    #[test]
    fn test_strategy_long_entry_signal() {
        let mut strategy = BbRsiStrategy::new();
        // Build candles: mostly stable around 100, then a sharp drop to trigger
        // lower BB touch + RSI oversold.
        let mut closes = vec![100.0; 30];
        // Add a sharp decline at the end
        for i in 0..8 {
            closes.push(100.0 - (i as f64 + 1.0) * 2.0);
        }

        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0)
            })
            .collect();

        let params = HashMap::new(); // use defaults
        let mut ctx = Context::new(candles.clone(), Timeframe::M1, params);

        // Walk through all candles
        let mut last_signal = Signal::NoAction;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(sig) = strategy.on_candle(&mut ctx, candle) {
                if sig.is_actionable() {
                    last_signal = sig;
                }
            }
        }

        // With a sharp decline, we expect a long entry signal at some point
        assert!(
            last_signal.is_entry(),
            "Expected long entry after sharp decline, got {:?}",
            last_signal
        );
    }

    #[test]
    fn test_strategy_short_entry_signal() {
        let mut strategy = BbRsiStrategy::new();
        // Build candles: mostly stable around 100, then a sharp rise
        let mut closes = vec![100.0; 30];
        for i in 0..8 {
            closes.push(100.0 + (i as f64 + 1.0) * 2.0);
        }

        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0)
            })
            .collect();

        let params = HashMap::new();
        let mut ctx = Context::new(candles.clone(), Timeframe::M1, params);

        let mut last_signal = Signal::NoAction;
        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);
            if let Some(sig) = strategy.on_candle(&mut ctx, candle) {
                if sig.is_actionable() {
                    last_signal = sig;
                }
            }
        }

        assert!(
            last_signal.is_entry(),
            "Expected short entry after sharp rise, got {:?}",
            last_signal
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
