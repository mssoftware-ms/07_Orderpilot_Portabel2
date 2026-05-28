pub mod context;
pub mod signal;

pub use context::Context;
pub use signal::Signal;

use serde::{Deserialize, Serialize};

use crate::models::{Candle, Timeframe};

// ─── StrategyAddin Trait ─────────────────────────────────────────────────────

/// The core trait that all strategy add-ins must implement.
/// Each strategy is a self-contained plugin that declares its metadata,
/// data requirements, and signal logic.
pub trait StrategyAddin: Send + Sync {
    /// Return strategy metadata (name, version, parameters, etc.).
    fn manifest(&self) -> AddinManifest;

    /// Declare required data inputs (timeframes, minimum candle count).
    fn required_inputs(&self) -> Vec<InputSpec>;

    /// Process a single candle and optionally generate a trading signal.
    /// Called once per candle close during backtesting, or on each live candle update.
    fn on_candle(&mut self, ctx: &mut Context, candle: &Candle) -> Option<Signal>;

    /// Reset strategy state for a new backtest run.
    fn on_reset(&mut self);

    /// Optional: Validate parameters before execution.
    /// Default implementation accepts all parameters.
    fn validate_params(
        &self,
        _params: &std::collections::HashMap<String, f64>,
    ) -> Result<(), String> {
        Ok(())
    }
}

// ─── AddinManifest ───────────────────────────────────────────────────────────

/// Metadata describing a strategy add-in.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddinManifest {
    /// Unique identifier for this strategy (e.g., "bb_rsi_v1").
    pub id: String,
    /// Human-readable name (e.g., "Bollinger Bands + RSI Mean Reversion").
    pub name: String,
    /// Semantic version string (e.g., "1.0.0").
    pub version: String,
    /// Author name or organization.
    pub author: String,
    /// Strategy description.
    pub description: String,
    /// Strategy category.
    pub category: StrategyCategory,
    /// Recommended timeframes for this strategy.
    pub timeframes: Vec<Timeframe>,
    /// User-configurable parameter schemas.
    pub parameters: Vec<ParameterSchema>,
}

/// Category of a trading strategy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StrategyCategory {
    MeanReversion,
    Trend,
    Breakout,
    Momentum,
    Scalping,
    Custom,
}

impl std::fmt::Display for StrategyCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StrategyCategory::MeanReversion => write!(f, "Mean Reversion"),
            StrategyCategory::Trend => write!(f, "Trend Following"),
            StrategyCategory::Breakout => write!(f, "Breakout"),
            StrategyCategory::Momentum => write!(f, "Momentum"),
            StrategyCategory::Scalping => write!(f, "Scalping"),
            StrategyCategory::Custom => write!(f, "Custom"),
        }
    }
}

// ─── ParameterSchema ─────────────────────────────────────────────────────────

/// Schema for a user-configurable strategy parameter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParameterSchema {
    /// Internal parameter name (e.g., "bb_period").
    pub name: String,
    /// Display name shown in the UI (e.g., "Bollinger Bands Period").
    pub display_name: String,
    /// Default value.
    pub default: f64,
    /// Minimum allowed value.
    pub min: f64,
    /// Maximum allowed value.
    pub max: f64,
    /// Step size for UI sliders.
    pub step: f64,
}

impl ParameterSchema {
    /// Create a new ParameterSchema.
    pub fn new(
        name: &str,
        display_name: &str,
        default: f64,
        min: f64,
        max: f64,
        step: f64,
    ) -> Self {
        Self {
            name: name.to_string(),
            display_name: display_name.to_string(),
            default,
            min,
            max,
            step,
        }
    }

    /// Validate that a value falls within the parameter's allowed range.
    pub fn validate(&self, value: f64) -> Result<(), String> {
        if value < self.min || value > self.max {
            Err(format!(
                "Parameter '{}' value {} is out of range [{}, {}]",
                self.name, value, self.min, self.max
            ))
        } else {
            Ok(())
        }
    }
}

// ─── InputSpec ───────────────────────────────────────────────────────────────

/// Specification of data requirements for a strategy add-in.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum InputSpec {
    /// Requires OHLCV data for a specific timeframe.
    OhlcvTimeframe(Timeframe),
    /// Requires a named indicator to be pre-computed (e.g., "BB", "RSI").
    Indicator(String),
    /// Requires a minimum number of historical candles.
    MinCandles(usize),
}

// ─── StrategyError ───────────────────────────────────────────────────────────

/// Errors that can occur during strategy execution.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum StrategyError {
    /// Not enough historical data to compute indicators.
    InsufficientData,
    /// Invalid parameter value.
    InvalidParameter(String),
    /// General computation error.
    ComputationError(String),
}

impl std::fmt::Display for StrategyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StrategyError::InsufficientData => write!(f, "Insufficient historical data"),
            StrategyError::InvalidParameter(msg) => write!(f, "Invalid parameter: {}", msg),
            StrategyError::ComputationError(msg) => write!(f, "Computation error: {}", msg),
        }
    }
}

impl std::error::Error for StrategyError {}
