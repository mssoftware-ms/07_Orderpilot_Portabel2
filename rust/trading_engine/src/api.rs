//! Flutter Rust Bridge API functions.
//!
//! These functions are exposed to Dart via flutter_rust_bridge codegen.
//! Each public function here becomes callable from Flutter.

use crate::models::{Candle, Timeframe};
use crate::strategy::{AddinManifest, ParameterSchema, Signal, StrategyCategory};

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
}
