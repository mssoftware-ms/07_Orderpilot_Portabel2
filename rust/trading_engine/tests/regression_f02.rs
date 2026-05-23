//! F-02 SL/TP intra-candle exit regression.
//!
//! Locks in the contract for §3.4 F-02 from `260522_Gesamtplan_Phase1-3.md`:
//! when a position has an absolute SL / TP price attached and the next candle
//! penetrates that level by `low` (long SL / short TP) or `high` (long TP /
//! short SL), the backtest engine MUST close the position at the SL/TP price
//! itself — not at `close`. The exit reason MUST be `ExitReason::StopLoss` /
//! `ExitReason::TakeProfit` accordingly.
//!
//! Rust ran this contract correctly before F-02 (cf.
//! `src/backtest/mod.rs::test_stop_loss_hit` / `test_take_profit_hit`); this
//! file exists as a dedicated regression fence so any future refactor of the
//! intra-candle exit ordering fails loudly.

use std::collections::HashMap;

use trading_engine::backtest::{BacktestConfig, BacktestEngine};
use trading_engine::models::{Candle, ExitReason, Timeframe};
use trading_engine::strategy::{
    AddinManifest, Context, InputSpec, Signal, StrategyAddin, StrategyCategory,
};

/// Minimal stub strategy that fires a single entry on candle index 1 with the
/// SL / TP supplied at construction time, then never emits another signal.
struct OneShotEntry {
    side_long: bool,
    sl: f64,
    tp: f64,
}

impl StrategyAddin for OneShotEntry {
    fn manifest(&self) -> AddinManifest {
        AddinManifest {
            id: "regression_f02".into(),
            name: "F-02 Regression".into(),
            version: "1.0.0".into(),
            author: "regression".into(),
            description: "fires one entry with explicit SL/TP".into(),
            category: StrategyCategory::Custom,
            timeframes: vec![Timeframe::H1],
            parameters: vec![],
        }
    }

    fn required_inputs(&self) -> Vec<InputSpec> {
        vec![]
    }

    fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
        if ctx.index() == 1 && !ctx.in_position {
            Some(if self.side_long {
                Signal::EnterLong {
                    sl: Some(self.sl),
                    tp: vec![self.tp],
                    size_pct: 100.0,
                }
            } else {
                Signal::EnterShort {
                    sl: Some(self.sl),
                    tp: vec![self.tp],
                    size_pct: 100.0,
                }
            })
        } else {
            None
        }
    }

    fn on_reset(&mut self) {}
}

fn candle(ts: i64, open: f64, high: f64, low: f64, close: f64) -> Candle {
    Candle::new(ts, open, high, low, close, 100.0)
}

#[test]
fn long_sl_hit_exits_at_sl_price_exactly() {
    // Entry at candle[1].close = 100.0, SL = 95.0.
    // Candle[2] dips to low=94.0 → SL must hit at exactly 95.0.
    let candles = vec![
        candle(1_000, 100.0, 101.0, 99.0, 100.0),
        candle(2_000, 100.0, 101.0, 99.0, 100.0),
        candle(3_000, 99.5, 100.0, 94.0, 96.0),
        candle(4_000, 96.0, 97.0, 95.0, 96.0),
    ];

    let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
    let mut engine = BacktestEngine::new(config);
    let mut strategy = OneShotEntry {
        side_long: true,
        sl: 95.0,
        tp: 110.0,
    };
    let result = engine.run(&mut strategy, &candles, HashMap::new());

    assert_eq!(result.metrics.total_trades, 1);
    let trade = &result.metrics.trades[0];
    assert_eq!(trade.exit_reason, ExitReason::StopLoss);
    assert!(
        (trade.exit_price - 95.0).abs() < 1e-9,
        "long SL exit price must equal SL, got {}",
        trade.exit_price
    );
    assert!(trade.pnl < 0.0, "long SL hit is by definition a loss");
}

#[test]
fn short_tp_hit_exits_at_tp_price_exactly() {
    // Short entry at candle[1].close = 100.0, TP = 90.0.
    // Candle[2] dips to low=89.0 → TP must hit at exactly 90.0 for a short.
    let candles = vec![
        candle(1_000, 100.0, 101.0, 99.0, 100.0),
        candle(2_000, 100.0, 101.0, 99.0, 100.0),
        candle(3_000, 99.0, 99.5, 89.0, 91.0),
        candle(4_000, 91.0, 92.0, 90.0, 91.0),
    ];

    let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
    let mut engine = BacktestEngine::new(config);
    let mut strategy = OneShotEntry {
        side_long: false,
        sl: 110.0,
        tp: 90.0,
    };
    let result = engine.run(&mut strategy, &candles, HashMap::new());

    assert_eq!(result.metrics.total_trades, 1);
    let trade = &result.metrics.trades[0];
    assert_eq!(trade.exit_reason, ExitReason::TakeProfit);
    assert!(
        (trade.exit_price - 90.0).abs() < 1e-9,
        "short TP exit price must equal TP, got {}",
        trade.exit_price
    );
    assert!(
        trade.pnl > 0.0,
        "short TP hit (entry 100 → exit 90) must be a win"
    );
}
