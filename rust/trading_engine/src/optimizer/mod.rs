//! Optimizer module — parameter-sweep infrastructure (Phase-3 Welle O1 MVP).
//!
//! This module provides the domain types, scoring, persistence, and search
//! engines used to optimize strategy parameters against historical candle
//! data. The MVP scope is Random-Search over an In-Sample range, with a
//! composite score (Profit-Factor primary + small Sharpe bonus, disqualified
//! by max-drawdown cap and min-trades constraints). Walk-Forward, PBO/DSR
//! gates, and UI integration land in Welle O2/O3.
//!
//! # Architecture
//! - `ParameterSpec` / `SearchSpace` describe what to sweep
//! - `TrialParams` is one sampled point in that space (always as `f64` to
//!   match the `param_or` convention used by `StrategyAddin`s)
//! - `TrialMetrics` is the slim subset of `BacktestMetrics` the optimizer
//!   cares about (everything needed to compute and explain the score)
//! - `ScoreConstraints` + `score_trial` produce the composite score
//! - `TrialResult` bundles trial id + params + metrics + score for persistence
//!
//! # `f64`-only convention
//! Booleans encode as `0.0` / `1.0`, categoricals as their index, ints as
//! the rounded float. This mirrors `Context::param_or` (which returns `f64`)
//! and means the optimizer never has to know the runtime semantics of any
//! individual parameter — the strategy add-in is the single source of truth
//! for how a parameter maps to behavior.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

pub mod runner;
pub mod scoring;
pub mod storage;
pub mod yaml;

pub use runner::run_optimization_trial;
pub use scoring::{score_constraints_for_strategy, score_trial, StrategyKind};
pub use storage::{StudyMeta, StudyStorage};
pub use yaml::{parse_search_space, parse_search_space_str};

// ─── Parameter Spec ──────────────────────────────────────────────────────────

/// Description of a single parameter's search range.
///
/// All variants are sampled into `TrialParams.values` as `f64`:
/// - `Float`: directly
/// - `Int`: rounded to f64
/// - `Bool`: `0.0` or `1.0` (matches the `>= 0.5` decode in addins)
/// - `Categorical`: index into the `values` vector as f64
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum ParameterSpec {
    /// Continuous parameter. `log = true` requests log-uniform sampling
    /// (rejects non-positive bounds).
    Float {
        min: f64,
        max: f64,
        #[serde(default)]
        log: bool,
    },
    /// Integer parameter; sampling draws an inclusive int and converts to f64.
    Int { min: i64, max: i64 },
    /// Boolean parameter; samples `0.0` or `1.0` with equal probability.
    Bool,
    /// Categorical parameter with named alternatives. The sampled f64 is the
    /// index into `values` — the strategy add-in is responsible for decoding.
    Categorical { values: Vec<String> },
}

impl ParameterSpec {
    /// Validate the spec's internal consistency. Called by `SearchSpace::validate`.
    pub fn validate(&self) -> Result<(), String> {
        match self {
            ParameterSpec::Float { min, max, log } => {
                if !min.is_finite() || !max.is_finite() {
                    return Err("Float bounds must be finite".to_string());
                }
                if min >= max {
                    return Err(format!("Float min ({}) must be < max ({})", min, max));
                }
                if *log && *min <= 0.0 {
                    return Err(format!(
                        "log-uniform Float requires min > 0 (got {})",
                        min
                    ));
                }
                Ok(())
            }
            ParameterSpec::Int { min, max } => {
                if min >= max {
                    return Err(format!("Int min ({}) must be < max ({})", min, max));
                }
                Ok(())
            }
            ParameterSpec::Bool => Ok(()),
            ParameterSpec::Categorical { values } => {
                if values.is_empty() {
                    return Err("Categorical requires at least one value".to_string());
                }
                Ok(())
            }
        }
    }
}

// ─── Search Space ────────────────────────────────────────────────────────────

/// A full search space for one strategy: which params to sweep, plus any
/// parameters held fixed at a known value (e.g. `adx_filter_enabled = 1.0`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchSpace {
    pub strategy_name: String,
    pub parameters: HashMap<String, ParameterSpec>,
    #[serde(default)]
    pub fixed: HashMap<String, f64>,
}

impl SearchSpace {
    /// Validate all parameter specs.
    pub fn validate(&self) -> Result<(), String> {
        if self.strategy_name.trim().is_empty() {
            return Err("strategy_name must not be empty".to_string());
        }
        if self.parameters.is_empty() {
            return Err("search space must define at least one parameter".to_string());
        }
        for (name, spec) in &self.parameters {
            spec.validate().map_err(|e| format!("param '{}': {}", name, e))?;
        }
        // Disallow same name in `parameters` and `fixed` — caller error.
        for name in self.fixed.keys() {
            if self.parameters.contains_key(name) {
                return Err(format!(
                    "param '{}' appears in both parameters and fixed",
                    name
                ));
            }
        }
        Ok(())
    }
}

// ─── Trial Parameters ────────────────────────────────────────────────────────

/// One concrete point in a search space — every parameter resolved to f64.
/// Includes both swept and fixed values (the latter copied from the
/// `SearchSpace.fixed` map at sample time).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrialParams {
    pub values: HashMap<String, f64>,
}

impl TrialParams {
    pub fn new() -> Self {
        Self {
            values: HashMap::new(),
        }
    }

    /// Helper: return the value for `key` or `default` if missing.
    /// Mirrors the `Context::param_or` convention used by `StrategyAddin`s.
    pub fn get_or(&self, key: &str, default: f64) -> f64 {
        self.values.get(key).copied().unwrap_or(default)
    }

    pub fn insert(&mut self, key: impl Into<String>, value: f64) {
        self.values.insert(key.into(), value);
    }
}

impl Default for TrialParams {
    fn default() -> Self {
        Self::new()
    }
}

// ─── Trial Metrics ───────────────────────────────────────────────────────────

/// Slim subset of `BacktestMetrics` consumed by the optimizer.
///
/// All fields are populated from a finished `BacktestResult`; the optimizer
/// does not recompute them. `max_drawdown_pct` is the equity-curve drawdown
/// reported by the backtest (positive percentage).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrialMetrics {
    pub total_trades: u32,
    pub total_pnl: f64,
    pub win_rate: f64,
    pub sharpe_ratio: f64,
    pub max_drawdown_pct: f64,
    pub profit_factor: f64,
    pub final_equity: f64,
}

// ─── Score Constraints ───────────────────────────────────────────────────────

/// Disqualification gates applied to a trial before composite scoring.
///
/// A trial whose metrics violate any gate scores `f64::NEG_INFINITY` and
/// is sorted to the bottom of any Top-N query.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct ScoreConstraints {
    /// Max equity-curve drawdown percentage permitted (e.g. `19.0` = 19%).
    pub max_drawdown_cap_pct: f64,
    /// Minimum trade count for the trial to be statistically meaningful.
    pub min_trades: u32,
}

// ─── Trial Result ────────────────────────────────────────────────────────────

/// Full outcome of one optimizer trial — input params, output metrics, score.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrialResult {
    pub trial_id: u32,
    pub params: TrialParams,
    pub metrics: TrialMetrics,
    pub score: f64,
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parameter_spec_float_validates_min_lt_max() {
        let bad = ParameterSpec::Float {
            min: 5.0,
            max: 2.0,
            log: false,
        };
        assert!(bad.validate().is_err());
        let ok = ParameterSpec::Float {
            min: 0.1,
            max: 1.0,
            log: false,
        };
        assert!(ok.validate().is_ok());
    }

    #[test]
    fn parameter_spec_float_log_requires_positive_min() {
        let bad = ParameterSpec::Float {
            min: 0.0,
            max: 1.0,
            log: true,
        };
        assert!(bad.validate().is_err());
        let ok = ParameterSpec::Float {
            min: 1e-6,
            max: 1.0,
            log: true,
        };
        assert!(ok.validate().is_ok());
    }

    #[test]
    fn parameter_spec_int_validates_min_lt_max() {
        let bad = ParameterSpec::Int { min: 10, max: 5 };
        assert!(bad.validate().is_err());
        let ok = ParameterSpec::Int { min: 5, max: 10 };
        assert!(ok.validate().is_ok());
    }

    #[test]
    fn parameter_spec_categorical_requires_nonempty() {
        let bad = ParameterSpec::Categorical { values: vec![] };
        assert!(bad.validate().is_err());
        let ok = ParameterSpec::Categorical {
            values: vec!["a".into(), "b".into()],
        };
        assert!(ok.validate().is_ok());
    }

    #[test]
    fn parameter_spec_bool_always_valid() {
        assert!(ParameterSpec::Bool.validate().is_ok());
    }

    #[test]
    fn search_space_roundtrips_through_yaml() {
        let mut params: HashMap<String, ParameterSpec> = HashMap::new();
        params.insert(
            "bb_period".into(),
            ParameterSpec::Int { min: 100, max: 300 },
        );
        params.insert(
            "bb_stddev".into(),
            ParameterSpec::Float {
                min: 0.2,
                max: 1.0,
                log: false,
            },
        );
        params.insert("adx_use_di_confluence".into(), ParameterSpec::Bool);
        params.insert(
            "bb_ma_type_alt".into(),
            ParameterSpec::Categorical {
                values: vec!["SMA".into(), "EMA".into()],
            },
        );

        let mut fixed = HashMap::new();
        fixed.insert("adx_filter_enabled".to_string(), 1.0);

        let space = SearchSpace {
            strategy_name: "bb_rsi".into(),
            parameters: params,
            fixed,
        };
        space.validate().unwrap();

        let yaml = serde_yaml::to_string(&space).unwrap();
        let parsed: SearchSpace = serde_yaml::from_str(&yaml).unwrap();
        assert_eq!(parsed, space);
    }

    #[test]
    fn search_space_rejects_empty_parameters() {
        let space = SearchSpace {
            strategy_name: "bb_rsi".into(),
            parameters: HashMap::new(),
            fixed: HashMap::new(),
        };
        assert!(space.validate().is_err());
    }

    #[test]
    fn search_space_rejects_name_conflict_between_parameters_and_fixed() {
        let mut params: HashMap<String, ParameterSpec> = HashMap::new();
        params.insert("bb_period".into(), ParameterSpec::Int { min: 10, max: 20 });
        let mut fixed = HashMap::new();
        fixed.insert("bb_period".to_string(), 15.0);
        let space = SearchSpace {
            strategy_name: "bb_rsi".into(),
            parameters: params,
            fixed,
        };
        assert!(space.validate().is_err());
    }

    #[test]
    fn trial_params_get_or_returns_default_when_missing() {
        let mut p = TrialParams::new();
        p.insert("foo", 2.5);
        assert_eq!(p.get_or("foo", 0.0), 2.5);
        assert_eq!(p.get_or("missing", 7.5), 7.5);
    }

    #[test]
    fn trial_result_serializes_with_neg_infinity_score() {
        let result = TrialResult {
            trial_id: 1,
            params: TrialParams::new(),
            metrics: TrialMetrics {
                total_trades: 0,
                total_pnl: 0.0,
                win_rate: 0.0,
                sharpe_ratio: 0.0,
                max_drawdown_pct: 0.0,
                profit_factor: f64::NAN,
                final_equity: 0.0,
            },
            score: f64::NEG_INFINITY,
        };
        // serde_json represents NaN/Inf as null by default — round-tripping
        // a disqualified trial therefore uses an explicit f64 sentinel in the
        // SQLite layer, not the JSON. We still want to confirm the struct
        // accepts these values structurally.
        assert!(result.score.is_infinite());
        assert!(result.metrics.profit_factor.is_nan());
    }
}
