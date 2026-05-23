//! Flutter Rust Bridge API functions.
//!
//! These functions are exposed to Dart via flutter_rust_bridge codegen.
//! Each public function here becomes callable from Flutter.

use std::collections::HashMap;

use crate::addins::{BbRsiStrategy, UtBotStrategy};
use crate::models::{Candle, Timeframe};
use crate::strategy::{AddinManifest, ParameterSchema, Signal, StrategyAddin, StrategyCategory};

/// Returns the engine version string.
pub fn get_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Simple ping function to verify the bridge is working.
pub fn ping() -> String {
    "pong from Rust trading_engine".to_string()
}

/// Create a test candle to verify data structure serialization across the bridge.
pub fn create_test_candle() -> Candle {
    Candle::new(
        1716307200000, // 2024-05-21 12:00:00 UTC
        67500.0,
        68200.0,
        67100.0,
        67850.0,
        1234.56,
    )
}

/// Test signal creation - returns a sample EnterLong signal.
pub fn create_test_signal_long() -> Signal {
    Signal::EnterLong {
        sl: Some(66000.0),
        tp: vec![69000.0, 70000.0],
        size_pct: 50.0,
    }
}

/// Test signal creation - returns a sample EnterShort signal.
pub fn create_test_signal_short() -> Signal {
    Signal::EnterShort {
        sl: Some(69000.0),
        tp: vec![66000.0],
        size_pct: 100.0,
    }
}

/// Test creating a NoAction signal.
pub fn create_test_signal_no_action() -> Signal {
    Signal::NoAction
}

/// Verify that a candle can round-trip through JSON serialization.
pub fn roundtrip_candle_json(candle: Candle) -> String {
    serde_json::to_string(&candle).unwrap_or_else(|e| format!("Error: {}", e))
}

/// Get the list of supported timeframes.
pub fn get_supported_timeframes() -> Vec<String> {
    vec![
        Timeframe::M1,
        Timeframe::M5,
        Timeframe::M15,
        Timeframe::M30,
        Timeframe::H1,
        Timeframe::H4,
        Timeframe::D1,
        Timeframe::W1,
    ]
    .into_iter()
    .map(|tf| tf.as_str().to_string())
    .collect()
}

/// Get a sample strategy manifest (for testing the manifest data flow).
pub fn get_sample_manifest() -> String {
    let manifest = AddinManifest {
        id: "bb_rsi_v1".to_string(),
        name: "Bollinger Bands + RSI Mean Reversion".to_string(),
        version: "1.0.0".to_string(),
        author: "Trading App Team".to_string(),
        description: "Buy when price touches lower BB and RSI < 30, exit at middle BB or RSI > 70"
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
    };
    serde_json::to_string_pretty(&manifest).unwrap_or_else(|e| format!("Error: {}", e))
}

/// Validate that a signal is actionable.
pub fn is_signal_actionable(signal_json: String) -> bool {
    match serde_json::from_str::<Signal>(&signal_json) {
        Ok(signal) => signal.is_actionable(),
        Err(_) => false,
    }
}

// ─── BB+RSI Strategy API ────────────────────────────────────────────────────

/// Get the BB+RSI strategy manifest as JSON.
pub fn get_bb_rsi_manifest() -> String {
    let strategy = BbRsiStrategy::new();
    serde_json::to_string_pretty(&strategy.manifest()).unwrap_or_default()
}

/// Run the BB+RSI strategy on a list of candles (JSON in, JSON out).
///
/// `candles_json` – JSON array of candle objects.
/// `params_json`  – JSON object with parameter overrides (e.g. `{"bb_period": 25}`).
///
/// Returns a JSON array of objects `{ "index": N, "signal": <Signal> }` for every
/// actionable signal the strategy emitted.
pub fn run_bb_rsi_strategy(candles_json: String, params_json: String) -> String {
    let candles: Vec<Candle> = match serde_json::from_str(&candles_json) {
        Ok(c) => c,
        Err(e) => return format!(r#"{{"error":"bad candles json: {}"}}"#, e),
    };
    let params: HashMap<String, f64> = match serde_json::from_str(&params_json) {
        Ok(p) => p,
        Err(e) => return format!(r#"{{"error":"bad params json: {}"}}"#, e),
    };

    let mut strategy = BbRsiStrategy::new();
    if let Err(e) = strategy.validate_params(&params) {
        return format!(r#"{{"error":"{}"}}"#, e);
    }

    let mut ctx = crate::strategy::Context::new(candles.clone(), Timeframe::H1, params);
    let mut results: Vec<serde_json::Value> = Vec::new();

    for (i, candle) in candles.iter().enumerate() {
        ctx.set_index(i);
        if let Some(signal) = strategy.on_candle(&mut ctx, candle) {
            if signal.is_actionable() {
                results.push(serde_json::json!({
                    "index": i,
                    "signal": signal,
                    "bb_upper": ctx.get_state("bb_upper"),
                    "bb_middle": ctx.get_state("bb_middle"),
                    "bb_lower": ctx.get_state("bb_lower"),
                    "rsi": ctx.get_state("rsi"),
                }));
            }
        }
    }

    serde_json::to_string_pretty(&results).unwrap_or_default()
}

// ─── Backtest API ────────────────────────────────────────────────────────────

/// Run a full backtest of the BB+RSI strategy on historical candles.
///
/// `candles_json`    – JSON array of `Candle` objects.
/// `params_json`     – JSON object with parameter overrides (e.g. `{"bb_period": 25}`).
/// `initial_balance` – Starting account balance in quote currency (e.g. 10000.0 USDT).
/// `fee_rate`        – Taker fee rate per side (e.g. 0.0006 for Bitunix VIP0 0.06 %).
///
/// Returns a JSON-serialised `BacktestResult` containing metrics, equity curve,
/// trade log, and fee summary – ready for Flutter consumption.
pub fn run_bb_rsi_backtest(
    candles_json: String,
    params_json: String,
    initial_balance: f64,
    fee_rate: f64,
) -> String {
    use crate::backtest::{BacktestConfig, BacktestEngine};

    let candles: Vec<Candle> = match serde_json::from_str(&candles_json) {
        Ok(c) => c,
        Err(e) => return format!(r#"{{"error":"bad candles json: {}"}}"#, e),
    };
    let params: HashMap<String, f64> = match serde_json::from_str(&params_json) {
        Ok(p) => p,
        Err(e) => return format!(r#"{{"error":"bad params json: {}"}}"#, e),
    };

    let mut strategy = BbRsiStrategy::new();
    if let Err(e) = strategy.validate_params(&params) {
        return format!(r#"{{"error":"{}"}}"#, e);
    }

    let config = BacktestConfig::new(initial_balance, fee_rate, Timeframe::H1);
    let mut engine = BacktestEngine::new(config);
    let result = engine.run(&mut strategy, &candles, params);

    serde_json::to_string(&result).unwrap_or_else(|e| format!(r#"{{"error":"{}"}}"#, e))
}

/// Run a full backtest of the UT Bot Alerts (verbesserte Variante) strategy
/// on historical candles.
///
/// `candles_json`    – JSON array of `Candle` objects.
/// `params_json`     – JSON object with parameter overrides (e.g.
///                     `{"key_value": 3.0, "atr_period": 5}`).
/// `initial_balance` – Starting account balance in quote currency.
/// `fee_rate`        – Taker fee rate per side.
///
/// Returns a JSON-serialised `BacktestResult` identical in shape to
/// `run_bb_rsi_backtest`. The Phase-2 video-spec defaults map to the BTCUSDT
/// 5-minute timeframe; pass overrides via `params_json` for sweeps.
pub fn run_ut_bot_backtest(
    candles_json: String,
    params_json: String,
    initial_balance: f64,
    fee_rate: f64,
) -> String {
    use crate::backtest::{BacktestConfig, BacktestEngine};

    let candles: Vec<Candle> = match serde_json::from_str(&candles_json) {
        Ok(c) => c,
        Err(e) => return format!(r#"{{"error":"bad candles json: {}"}}"#, e),
    };
    let params: HashMap<String, f64> = match serde_json::from_str(&params_json) {
        Ok(p) => p,
        Err(e) => return format!(r#"{{"error":"bad params json: {}"}}"#, e),
    };

    let mut strategy = UtBotStrategy::new();
    if let Err(e) = strategy.validate_params(&params) {
        return format!(r#"{{"error":"{}"}}"#, e);
    }

    let config = BacktestConfig::new(initial_balance, fee_rate, Timeframe::M5);
    let mut engine = BacktestEngine::new(config);
    let result = engine.run(&mut strategy, &candles, params);

    serde_json::to_string(&result).unwrap_or_else(|e| format!(r#"{{"error":"{}"}}"#, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_version() {
        let version = get_version();
        assert_eq!(version, "0.1.0");
    }

    #[test]
    fn test_ping() {
        assert_eq!(ping(), "pong from Rust trading_engine");
    }

    #[test]
    fn test_create_test_candle() {
        let candle = create_test_candle();
        assert_eq!(candle.timestamp, 1716307200000);
        assert_eq!(candle.open, 67500.0);
        assert!(candle.is_bullish());
    }

    #[test]
    fn test_create_test_signals() {
        let long = create_test_signal_long();
        assert!(long.is_entry());
        assert!(long.is_actionable());

        let short = create_test_signal_short();
        assert!(short.is_entry());

        let no_action = create_test_signal_no_action();
        assert!(!no_action.is_actionable());
    }

    #[test]
    fn test_roundtrip_candle_json() {
        let candle = create_test_candle();
        let json = roundtrip_candle_json(candle.clone());
        let parsed: Candle = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, candle);
    }

    #[test]
    fn test_get_supported_timeframes() {
        let tfs = get_supported_timeframes();
        assert_eq!(tfs.len(), 8);
        assert!(tfs.contains(&"1m".to_string()));
        assert!(tfs.contains(&"1h".to_string()));
    }

    #[test]
    fn test_get_sample_manifest() {
        let json = get_sample_manifest();
        let manifest: AddinManifest = serde_json::from_str(&json).unwrap();
        assert_eq!(manifest.id, "bb_rsi_v1");
        assert_eq!(manifest.parameters.len(), 5);
    }

    #[test]
    fn test_get_bb_rsi_manifest() {
        let json = get_bb_rsi_manifest();
        let manifest: AddinManifest = serde_json::from_str(&json).unwrap();
        assert_eq!(manifest.id, "bb_rsi_v1");
        assert_eq!(manifest.category, StrategyCategory::MeanReversion);
    }

    #[test]
    fn test_run_ut_bot_backtest_bad_json_returns_error() {
        // Malformed candles JSON must surface as a structured error rather
        // than panicking — same contract as run_bb_rsi_backtest.
        let result = run_ut_bot_backtest(
            "not json".to_string(),
            "{}".to_string(),
            10_000.0,
            0.0006,
        );
        assert!(
            result.contains("\"error\""),
            "expected error JSON, got: {}",
            result
        );
    }

    #[test]
    fn test_run_ut_bot_backtest_emits_valid_metrics_on_synth_fixture() {
        // Mirror of the Dart-fallback "runs end-to-end" smoke from
        // `test/services/ut_bot_backtest_test.dart`. Fast-warm-up
        // parameters so the 200-bar fixture clears warm-up well inside
        // the candle window; we don't require trades to fire on this
        // synthetic path (Welle U3 owns the real-data signal-emission
        // gate per the U2-4 ESKALATIONS-MARKER).
        let mut closes: Vec<f64> = Vec::with_capacity(200);
        for i in 0..50 {
            closes.push(100.0 + i as f64 * 0.4);
        }
        for i in 0..100 {
            closes.push(120.0 - (i as f64 + 1.0) * 0.4);
        }
        for i in 0..50 {
            closes.push(80.0 + (i as f64 + 1.0) * 0.4);
        }
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                Candle::new(
                    1_700_000_000_000 + i as i64 * 300_000,
                    c - 0.5,
                    c + 1.0,
                    c - 1.0,
                    c,
                    1000.0 + i as f64,
                )
            })
            .collect();

        let candles_json = serde_json::to_string(&candles).unwrap();
        let params_json = r#"{"ema_period": 30, "key_value": 1.0, "atr_period": 1, "smi_length": 5, "smi_k_smoothing": 3, "smi_d_smoothing": 3, "swing_lookback_bars": 5, "tp_rr_ratio": 2.0, "risk_per_trade": 0.02}"#
            .to_string();

        let result = run_ut_bot_backtest(candles_json, params_json, 10_000.0, 0.0006);
        assert!(
            !result.contains("\"error\""),
            "backtest must not error on the synth fixture, got: {}",
            result
        );
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        // candles_processed must equal the input length (Step D runs
        // unconditionally for every bar).
        assert_eq!(
            parsed["candles_processed"].as_u64().unwrap(),
            candles.len() as u64
        );
        // Equity curve must cover every bar — invariant shared with
        // runBbRsi and pinned by the Dart-fallback determinism test.
        assert_eq!(
            parsed["equity_curve"].as_array().unwrap().len(),
            candles.len()
        );
    }

    #[test]
    fn test_run_bb_rsi_strategy_on_candles() {
        // Generate 60 synthetic candles with a dip pattern
        let mut closes: Vec<f64> = vec![100.0; 40];
        for i in 0..20 {
            closes.push(100.0 - (i as f64 + 1.0) * 1.5);
        }
        let candles: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| Candle::new(i as i64 * 60000, c, c + 0.5, c - 0.5, c, 100.0))
            .collect();

        let candles_json = serde_json::to_string(&candles).unwrap();
        // Pin full Phase-1 BB(20, SMA, 2.0σ) + RSI(14, 30/70) so this API
        // smoke test stays decoupled from the Phase-2 default shift
        // (Diff D-01/D-02). The 60-candle dip fixture was built for that
        // configuration.
        let params_json = r#"{"bb_period": 20, "bb_stddev": 2.0, "bb_ma_type": 0, "rsi_period": 14, "rsi_oversold": 30, "rsi_overbought": 70, "swing_lookback_bars": 20, "tp_rr_ratio": 3.0, "risk_per_trade": 0.02}"#.to_string();

        let result = run_bb_rsi_strategy(candles_json, params_json);
        let signals: Vec<serde_json::Value> = serde_json::from_str(&result).unwrap();
        // Should have at least one actionable signal
        assert!(!signals.is_empty(), "Expected actionable signals, got none");
    }
}
