use std::collections::HashMap;

use crate::models::{Candle, Timeframe};

/// Context provided to strategy add-ins during `on_candle` calls.
/// Provides read-only access to candle history and strategy state.
pub struct Context {
    /// Historical candle data (oldest first).
    candles: Vec<Candle>,
    /// Current candle index in the backtest loop.
    current_index: usize,
    /// Strategy parameters (user-configurable).
    parameters: HashMap<String, f64>,
    /// Timeframe being traded.
    timeframe: Timeframe,
    /// Whether a position is currently open.
    pub in_position: bool,
    /// Custom key-value state storage for strategies.
    state: HashMap<String, f64>,
}

impl Context {
    /// Create a new Context with candle data and parameters.
    pub fn new(
        candles: Vec<Candle>,
        timeframe: Timeframe,
        parameters: HashMap<String, f64>,
    ) -> Self {
        Self {
            candles,
            current_index: 0,
            parameters,
            timeframe,
            in_position: false,
            state: HashMap::new(),
        }
    }

    /// Set the current candle index (used by backtest engine).
    pub fn set_index(&mut self, index: usize) {
        self.current_index = index;
    }

    /// Get the current candle.
    pub fn current_candle(&self) -> Option<&Candle> {
        self.candles.get(self.current_index)
    }

    /// Get the previous candle (one candle back).
    pub fn prev_candle(&self) -> Option<&Candle> {
        if self.current_index > 0 {
            self.candles.get(self.current_index - 1)
        } else {
            None
        }
    }

    /// Get `n` candles before the current one (most recent first).
    pub fn lookback(&self, n: usize) -> &[Candle] {
        let end = self.current_index + 1;
        let start = end.saturating_sub(n);
        &self.candles[start..end]
    }

    /// Get recent close prices (up to and including current candle).
    pub fn closes(&self, lookback: usize) -> Vec<f64> {
        self.lookback(lookback).iter().map(|c| c.close).collect()
    }

    /// Get recent high prices.
    pub fn highs(&self, lookback: usize) -> Vec<f64> {
        self.lookback(lookback).iter().map(|c| c.high).collect()
    }

    /// Get recent low prices.
    pub fn lows(&self, lookback: usize) -> Vec<f64> {
        self.lookback(lookback).iter().map(|c| c.low).collect()
    }

    /// Get the current close price.
    pub fn current_price(&self) -> f64 {
        self.current_candle().map(|c| c.close).unwrap_or(0.0)
    }

    /// Get a strategy parameter value by name.
    pub fn param(&self, name: &str) -> Option<f64> {
        self.parameters.get(name).copied()
    }

    /// Get a strategy parameter with a default value.
    pub fn param_or(&self, name: &str, default: f64) -> f64 {
        self.parameters.get(name).copied().unwrap_or(default)
    }

    /// Get the trading timeframe.
    pub fn timeframe(&self) -> Timeframe {
        self.timeframe
    }

    /// Get the total number of available candles.
    pub fn total_candles(&self) -> usize {
        self.candles.len()
    }

    /// Get the current candle index.
    pub fn index(&self) -> usize {
        self.current_index
    }

    /// Store a custom state value.
    pub fn set_state(&mut self, key: &str, value: f64) {
        self.state.insert(key.to_string(), value);
    }

    /// Retrieve a custom state value.
    pub fn get_state(&self, key: &str) -> Option<f64> {
        self.state.get(key).copied()
    }

    /// Clear all custom state (called on reset).
    pub fn clear_state(&mut self) {
        self.state.clear();
        self.in_position = false;
    }

    /// Get all candles as a slice.
    pub fn all_candles(&self) -> &[Candle] {
        &self.candles
    }
}
