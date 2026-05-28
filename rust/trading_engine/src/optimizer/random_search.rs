//! Seeded random-search engine for parameter optimization.
//!
//! Welle O1-6 wires together the previous primitives:
//!
//!   sample params from search space  →  run_optimization_trial
//!                                    →  score_trial
//!                                    →  StudyStorage::insert_trial
//!
//! repeated `n_trials` times under a single `StdRng` seeded by the
//! caller. Reproducibility guarantee: two engines created with the same
//! seed and driven against the same `SearchSpace` + candles + config
//! produce identical Top-N rankings, bit-for-bit.
//!
//! # Why random over Bayesian / Grid
//! Bergstra & Bengio (2012) showed that for the >3-D parameter spaces
//! typical of trading strategies, uniform random search dominates grid
//! search on the same evaluation budget — the grid wastes most of its
//! evaluations exploring axes that don't matter. TPE / Bayesian
//! optimization can do better still, but only with a working surrogate
//! model; that arrives in Welle O2 if MVP results justify the extra
//! complexity.

use anyhow::Result;
use rand::distributions::{Distribution, Uniform};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};

use crate::backtest::BacktestConfig;
use crate::models::Candle;

use super::runner::run_optimization_trial;
use super::scoring::StrategyKind;
use super::{ParameterSpec, ScoreConstraints, SearchSpace, StudyStorage, TrialParams, TrialResult};

/// Seedable random-search engine.
pub struct RandomSearchEngine {
    rng: StdRng,
}

impl RandomSearchEngine {
    /// Build an engine seeded by `seed`. Same seed → same sample sequence.
    pub fn new(seed: u64) -> Self {
        Self {
            rng: StdRng::seed_from_u64(seed),
        }
    }

    /// Draw one complete `TrialParams` from `space`. Each swept parameter
    /// is sampled per its `ParameterSpec`; every entry in `space.fixed`
    /// is copied through verbatim so the resulting map is a complete
    /// description of the strategy configuration.
    pub fn sample(&mut self, space: &SearchSpace) -> TrialParams {
        let mut params = TrialParams::new();
        for (name, spec) in &space.parameters {
            params.insert(name.clone(), self.sample_one(spec));
        }
        for (name, &value) in &space.fixed {
            params.insert(name.clone(), value);
        }
        params
    }

    fn sample_one(&mut self, spec: &ParameterSpec) -> f64 {
        match spec {
            ParameterSpec::Float { min, max, log } => {
                if *log {
                    // Validated at SearchSpace level: log => min > 0.
                    let lo = min.log10();
                    let hi = max.log10();
                    let u = Uniform::new_inclusive(lo, hi);
                    10.0_f64.powf(u.sample(&mut self.rng))
                } else {
                    let u = Uniform::new_inclusive(*min, *max);
                    u.sample(&mut self.rng)
                }
            }
            ParameterSpec::Int { min, max } => {
                let u = Uniform::new_inclusive(*min, *max);
                u.sample(&mut self.rng) as f64
            }
            ParameterSpec::Bool => {
                if self.rng.gen_bool(0.5) {
                    1.0
                } else {
                    0.0
                }
            }
            ParameterSpec::Categorical { values } => {
                // Validated at SearchSpace level: values non-empty.
                self.rng.gen_range(0..values.len()) as f64
            }
        }
    }

    /// Run a full study: create the study row, sample → score → persist
    /// for `n_trials` iterations, then return the Top-5.
    ///
    /// Logs a progress line every 100 trials (target::optimizer).
    #[allow(clippy::too_many_arguments)]
    pub fn run_study(
        &mut self,
        name: &str,
        space: &SearchSpace,
        strategy: StrategyKind,
        candles: &[Candle],
        base_config: BacktestConfig,
        constraints: &ScoreConstraints,
        n_trials: u32,
        storage: &mut StudyStorage,
    ) -> Result<Vec<TrialResult>> {
        let yaml = serde_yaml::to_string(space)?;
        let study_id = storage.create_study(name, strategy.as_str(), &yaml)?;

        for i in 0..n_trials {
            let params = self.sample(space);
            let result = run_optimization_trial(
                strategy,
                i,
                params,
                candles,
                base_config.clone(),
                constraints,
            );
            storage.insert_trial(study_id, &result)?;
            if (i + 1) % 100 == 0 {
                log::info!(
                    target: "optimizer",
                    "[{}] trial {}/{} score={}",
                    name,
                    i + 1,
                    n_trials,
                    result.score
                );
            }
        }

        storage.top_n_trials(study_id, 5)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn make_space() -> SearchSpace {
        let mut params: BTreeMap<String, ParameterSpec> = BTreeMap::new();
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
            "weight_mode".into(),
            ParameterSpec::Categorical {
                values: vec!["a".into(), "b".into(), "c".into()],
            },
        );
        let mut fixed = BTreeMap::new();
        fixed.insert("bb_ma_type".into(), 1.0);

        SearchSpace {
            strategy_name: "bb_rsi".into(),
            parameters: params,
            fixed,
        }
    }

    #[test]
    fn sample_includes_fixed_values_unchanged() {
        let space = make_space();
        let mut engine = RandomSearchEngine::new(7);
        let p = engine.sample(&space);
        assert_eq!(p.get_or("bb_ma_type", -1.0), 1.0);
    }

    #[test]
    fn sample_respects_int_bounds() {
        let space = make_space();
        let mut engine = RandomSearchEngine::new(11);
        for _ in 0..200 {
            let p = engine.sample(&space);
            let v = p.get_or("bb_period", f64::NAN);
            assert!(v.is_finite());
            assert!((100.0..=300.0).contains(&v));
            // Int sampling rounds to whole numbers.
            assert!(v.fract().abs() < 1e-9);
        }
    }

    #[test]
    fn sample_respects_float_bounds() {
        let space = make_space();
        let mut engine = RandomSearchEngine::new(13);
        for _ in 0..200 {
            let p = engine.sample(&space);
            let v = p.get_or("bb_stddev", f64::NAN);
            assert!((0.2..=1.0).contains(&v));
        }
    }

    #[test]
    fn sample_respects_bool_encoding() {
        let space = make_space();
        let mut engine = RandomSearchEngine::new(17);
        let mut seen_zero = false;
        let mut seen_one = false;
        for _ in 0..200 {
            let p = engine.sample(&space);
            let v = p.get_or("adx_use_di_confluence", f64::NAN);
            assert!(v == 0.0 || v == 1.0, "bool must be 0.0 or 1.0, got {}", v);
            if v == 0.0 {
                seen_zero = true;
            }
            if v == 1.0 {
                seen_one = true;
            }
        }
        assert!(seen_zero && seen_one, "200 draws must cover both booleans");
    }

    #[test]
    fn sample_categorical_returns_valid_indices() {
        let space = make_space();
        let mut engine = RandomSearchEngine::new(19);
        for _ in 0..200 {
            let p = engine.sample(&space);
            let v = p.get_or("weight_mode", f64::NAN);
            assert!(
                v == 0.0 || v == 1.0 || v == 2.0,
                "categorical index out of bounds: {}",
                v
            );
        }
    }

    #[test]
    fn same_seed_produces_identical_sample_sequence() {
        let space = make_space();
        let mut a = RandomSearchEngine::new(42);
        let mut b = RandomSearchEngine::new(42);
        for _ in 0..50 {
            assert_eq!(a.sample(&space), b.sample(&space));
        }
    }

    #[test]
    fn different_seeds_produce_different_sample_sequences() {
        let space = make_space();
        let mut a = RandomSearchEngine::new(1);
        let mut b = RandomSearchEngine::new(2);
        let mut differ = false;
        for _ in 0..50 {
            if a.sample(&space) != b.sample(&space) {
                differ = true;
                break;
            }
        }
        assert!(differ, "two distinct seeds must diverge within 50 draws");
    }

    #[test]
    fn log_uniform_sampling_stays_within_bounds() {
        let mut params: BTreeMap<String, ParameterSpec> = BTreeMap::new();
        params.insert(
            "lr".into(),
            ParameterSpec::Float {
                min: 1e-4,
                max: 1e-1,
                log: true,
            },
        );
        let space = SearchSpace {
            strategy_name: "synthetic".into(),
            parameters: params,
            fixed: BTreeMap::new(),
        };
        let mut engine = RandomSearchEngine::new(23);
        for _ in 0..200 {
            let p = engine.sample(&space);
            let v = p.get_or("lr", f64::NAN);
            assert!(
                (1e-4..=1e-1).contains(&v),
                "log-uniform escaped bounds: {}",
                v
            );
        }
    }
}
