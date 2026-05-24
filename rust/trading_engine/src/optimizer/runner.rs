//! Single-trial backtest runner for the parameter optimizer.
//!
//! `run_optimization_trial` drives one `BacktestEngine` run end-to-end:
//! it instantiates the requested strategy add-in, feeds it the candle
//! series and the trial's parameter map, extracts a slim `TrialMetrics`
//! from the resulting `BacktestResult`, and scores the trial via
//! `score_trial`.
//!
//! # Why no JSON layer
//! The Flutter-facing `run_*_backtest` API functions in `crate::api`
//! serialize candles and params to JSON because the FRB bridge expects
//! strings. For an in-process optimizer loop the JSON round-trip would
//! re-serialize the same candle vector once per trial — pure overhead.
//! This runner therefore drives `BacktestEngine` directly with the same
//! `HashMap<String, f64>` parameter shape, producing semantically
//! identical results without the (de)serialization cost.

use std::collections::HashMap;

use crate::addins::{BbRsiStrategy, IchimokuStrategy, UtBotStrategy};
use crate::backtest::{BacktestConfig, BacktestEngine, BacktestResult};
use crate::models::Candle;

use super::scoring::{score_trial, StrategyKind};
use super::{ScoreConstraints, TrialMetrics, TrialParams, TrialResult};

/// Run a single optimizer trial: configure engine, run strategy, score.
///
/// `params` must already include any `SearchSpace.fixed` entries the
/// sampler chose to apply — the runner does not consult the search-space
/// definition. This keeps the runner generic and lets the sampler decide
/// how to merge swept + fixed values.
pub fn run_optimization_trial(
    strategy: StrategyKind,
    trial_id: u32,
    params: TrialParams,
    candles: &[Candle],
    base_config: BacktestConfig,
    constraints: &ScoreConstraints,
) -> TrialResult {
    let initial_balance = base_config.initial_balance;
    let params_map: HashMap<String, f64> = params.values.clone();
    let result = run_strategy(strategy, candles, base_config, params_map);
    let metrics = extract_metrics(&result, initial_balance);
    let score = score_trial(&metrics, constraints);
    TrialResult {
        trial_id,
        params,
        metrics,
        score,
    }
}

/// Drive the `BacktestEngine` for the requested strategy.
fn run_strategy(
    strategy: StrategyKind,
    candles: &[Candle],
    config: BacktestConfig,
    params: HashMap<String, f64>,
) -> BacktestResult {
    let mut engine = BacktestEngine::new(config);
    match strategy {
        StrategyKind::BbRsi => {
            let mut s = BbRsiStrategy::new();
            engine.run(&mut s, candles, params)
        }
        StrategyKind::UtBot => {
            let mut s = UtBotStrategy::new();
            engine.run(&mut s, candles, params)
        }
        StrategyKind::Ichimoku => {
            let mut s = IchimokuStrategy::new();
            engine.run(&mut s, candles, params)
        }
    }
}

/// Collapse a full `BacktestResult` into the slim `TrialMetrics` the
/// optimizer keeps in its study database. `final_equity` is read from
/// the equity-curve tail; empty curves fall back to `initial_balance`
/// (a strategy that never traded ends with the starting capital).
fn extract_metrics(result: &BacktestResult, initial_balance: f64) -> TrialMetrics {
    let m = &result.metrics;
    let final_equity = result
        .equity_curve
        .last()
        .map(|p| p.equity)
        .unwrap_or(initial_balance);
    TrialMetrics {
        total_trades: m.total_trades as u32,
        total_pnl: m.total_pnl,
        win_rate: m.win_rate,
        sharpe_ratio: m.sharpe_ratio,
        max_drawdown_pct: m.max_drawdown_percent,
        profit_factor: m.profit_factor,
        final_equity,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Timeframe;

    /// Deterministic synthetic 1-hour candle series for smoke tests.
    /// Combines a slow linear drift with a high-frequency oscillation so
    /// the resulting series produces measurable indicator signals without
    /// requiring real market data. Pure function: identical inputs always
    /// produce identical output.
    fn synthetic_candles(n: usize) -> Vec<Candle> {
        let mut candles = Vec::with_capacity(n);
        let start_ts: i64 = 1_700_000_000_000; // arbitrary fixed timestamp
        let step_ms: i64 = 60 * 60 * 1_000; // 1h
        for i in 0..n {
            let t = i as f64;
            let drift = 60_000.0 + t * 5.0;
            let osc = 800.0 * (t * 0.21).sin();
            let micro = 120.0 * (t * 1.7).cos();
            let close = drift + osc + micro;
            let open = drift + osc + 60.0 * ((t - 1.0) * 1.7).cos();
            let high = close.max(open) + 80.0;
            let low = close.min(open) - 80.0;
            let volume = 100.0 + 20.0 * (t * 0.13).sin().abs();
            candles.push(Candle::new(
                start_ts + (i as i64) * step_ms,
                open,
                high,
                low,
                close,
                volume,
            ));
        }
        candles
    }

    fn permissive_constraints() -> ScoreConstraints {
        ScoreConstraints {
            max_drawdown_cap_pct: 100.0,
            min_trades: 0,
        }
    }

    fn base_config() -> BacktestConfig {
        BacktestConfig {
            initial_balance: 10_000.0,
            fee_rate: 0.0006,
            timeframe: Timeframe::H1,
            slippage_bps: 0.0,
        }
    }

    fn bb_rsi_default_params() -> TrialParams {
        let mut p = TrialParams::new();
        p.insert("bb_period", 200.0);
        p.insert("bb_stddev", 0.2);
        p.insert("bb_ma_type", 1.0);
        p.insert("rsi_period", 3.0);
        p.insert("rsi_oversold", 20.0);
        p.insert("rsi_overbought", 80.0);
        p.insert("swing_lookback_bars", 20.0);
        p.insert("tp_rr_ratio", 3.0);
        p.insert("risk_per_trade", 0.02);
        p.insert("adx_filter_enabled", 0.0);
        p
    }

    #[test]
    fn bb_rsi_smoke_run_produces_well_formed_trial_result() {
        let candles = synthetic_candles(300);
        let result = run_optimization_trial(
            StrategyKind::BbRsi,
            42,
            bb_rsi_default_params(),
            &candles,
            base_config(),
            &permissive_constraints(),
        );
        assert_eq!(result.trial_id, 42);
        // final_equity is always populated (>0) because the engine
        // records an equity point per candle.
        assert!(result.metrics.final_equity > 0.0);
        // Score is finite under permissive constraints (no disqualifier).
        assert!(
            result.score.is_finite() || result.metrics.profit_factor == 0.0,
            "score should be finite when constraints pass; got {} (pf={})",
            result.score,
            result.metrics.profit_factor
        );
    }

    #[test]
    fn impossible_min_trades_constraint_disqualifies_trial() {
        let candles = synthetic_candles(200);
        let strict = ScoreConstraints {
            max_drawdown_cap_pct: 100.0,
            min_trades: 1_000_000, // unreachable on 200 candles
        };
        let result = run_optimization_trial(
            StrategyKind::BbRsi,
            1,
            bb_rsi_default_params(),
            &candles,
            base_config(),
            &strict,
        );
        assert_eq!(result.score, f64::NEG_INFINITY);
    }

    #[test]
    fn impossible_drawdown_cap_disqualifies_trial() {
        let candles = synthetic_candles(200);
        let strict = ScoreConstraints {
            max_drawdown_cap_pct: -1.0, // any drawdown >= 0 violates this
            min_trades: 0,
        };
        let result = run_optimization_trial(
            StrategyKind::BbRsi,
            2,
            bb_rsi_default_params(),
            &candles,
            base_config(),
            &strict,
        );
        // Only disqualified if any drawdown observed. If the strategy
        // never opens a trade on synthetic data, drawdown can stay 0.0.
        // Test both branches:
        if result.metrics.max_drawdown_pct > -1.0 {
            assert_eq!(result.score, f64::NEG_INFINITY);
        }
    }

    #[test]
    fn identical_inputs_produce_bit_identical_trial_results() {
        let candles = synthetic_candles(250);
        let a = run_optimization_trial(
            StrategyKind::BbRsi,
            99,
            bb_rsi_default_params(),
            &candles,
            base_config(),
            &permissive_constraints(),
        );
        let b = run_optimization_trial(
            StrategyKind::BbRsi,
            99,
            bb_rsi_default_params(),
            &candles,
            base_config(),
            &permissive_constraints(),
        );
        assert_eq!(a, b, "two identical trials must produce identical results");
    }

    #[test]
    fn ut_bot_smoke_run_succeeds() {
        let candles = synthetic_candles(400);
        let mut p = TrialParams::new();
        p.insert("ema_period", 200.0);
        p.insert("key_value", 2.0);
        p.insert("atr_period", 1.0);
        p.insert("smi_length", 14.0);
        p.insert("smi_k_smoothing", 5.0);
        p.insert("smi_d_smoothing", 3.0);
        p.insert("adx_filter_enabled", 0.0);
        let result = run_optimization_trial(
            StrategyKind::UtBot,
            7,
            p,
            &candles,
            BacktestConfig {
                initial_balance: 10_000.0,
                fee_rate: 0.0006,
                timeframe: Timeframe::M5,
                slippage_bps: 0.0,
            },
            &permissive_constraints(),
        );
        assert_eq!(result.trial_id, 7);
        assert!(result.metrics.final_equity > 0.0);
    }

    #[test]
    fn ichimoku_smoke_run_succeeds() {
        let candles = synthetic_candles(400);
        let mut p = TrialParams::new();
        p.insert("tenkan_period", 9.0);
        p.insert("kijun_period", 26.0);
        p.insert("senkou_b_period", 52.0);
        p.insert("shift", 26.0);
        p.insert("score_threshold", 60.0);
        p.insert("adx_filter_enabled", 0.0);
        let result = run_optimization_trial(
            StrategyKind::Ichimoku,
            13,
            p,
            &candles,
            base_config(),
            &permissive_constraints(),
        );
        assert_eq!(result.trial_id, 13);
        assert!(result.metrics.final_equity > 0.0);
    }
}
