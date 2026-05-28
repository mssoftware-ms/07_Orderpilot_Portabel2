//! F-02c SHORT-position balance accounting regression.
//!
//! Locks in the contract that `BacktestEngine` updates `balance` correctly
//! after closing a SHORT position. The correct accounting for any side is:
//!
//!     balance_after_close = balance_before_open + realized_net_pnl
//!
//! which translates, given the engine's open-time bookkeeping
//! (`balance -= alloc`, where `alloc = quantity * entry_price + entry_fee`),
//! into the direction-agnostic post-close update:
//!
//!     balance += alloc + net_pnl
//!
//! Before F-02c, `close_position` used `balance += exit_notional - exit_fee`,
//! which is mathematically equivalent to `alloc + net_pnl` only for LONG
//! positions. For SHORTs it drains balance by ~`2 * gross_pnl`, masking the
//! Dart↔Rust parity test result on any mixed-direction fixture (see
//! `test/integration/dart_rust_parity_test.dart` and the F-02b brief).

use std::collections::HashMap;

use trading_engine::backtest::{BacktestConfig, BacktestEngine};
use trading_engine::models::{Candle, ExitReason, Timeframe};
use trading_engine::strategy::{
    AddinManifest, Context, InputSpec, Signal, StrategyAddin, StrategyCategory,
};

fn candle(ts: i64, open: f64, high: f64, low: f64, close: f64) -> Candle {
    Candle::new(ts, open, high, low, close, 100.0)
}

/// Stub strategy: emits one short entry on candle index 1, then exits on
/// candle index 3 with a `Signal` exit. The exit price is `candle.close` at
/// index 3 — the engine, not the strategy, owns the balance update.
struct OneShotShort;

impl StrategyAddin for OneShotShort {
    fn manifest(&self) -> AddinManifest {
        AddinManifest {
            id: "f02c_short".into(),
            name: "F-02c Short".into(),
            version: "1.0.0".into(),
            author: "regression".into(),
            description: "one-shot short for balance regression".into(),
            category: StrategyCategory::Custom,
            timeframes: vec![Timeframe::H1],
            parameters: vec![],
        }
    }
    fn required_inputs(&self) -> Vec<InputSpec> {
        vec![]
    }
    fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
        match ctx.index() {
            1 if !ctx.in_position => Some(Signal::EnterShort {
                sl: None,
                tp: None,
                size_pct: 100.0,
            }),
            3 if ctx.in_position => Some(Signal::Exit {
                reason: ExitReason::Signal("close short".into()),
            }),
            _ => None,
        }
    }
    fn on_reset(&mut self) {}
}

/// Stub strategy: LONG @ idx=1, exit @ idx=3, SHORT @ idx=5, exit @ idx=7.
/// Drives the post-LONG balance into the SHORT-open, so the SHORT trade
/// quantity depends on the LONG result, and the final balance compounds.
struct LongThenShort;

impl StrategyAddin for LongThenShort {
    fn manifest(&self) -> AddinManifest {
        AddinManifest {
            id: "f02c_mixed".into(),
            name: "F-02c Mixed".into(),
            version: "1.0.0".into(),
            author: "regression".into(),
            description: "long then short for compounding regression".into(),
            category: StrategyCategory::Custom,
            timeframes: vec![Timeframe::H1],
            parameters: vec![],
        }
    }
    fn required_inputs(&self) -> Vec<InputSpec> {
        vec![]
    }
    fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
        match ctx.index() {
            1 if !ctx.in_position => Some(Signal::EnterLong {
                sl: None,
                tp: None,
                size_pct: 100.0,
            }),
            3 if ctx.in_position => Some(Signal::Exit {
                reason: ExitReason::Signal("close long".into()),
            }),
            5 if !ctx.in_position => Some(Signal::EnterShort {
                sl: None,
                tp: None,
                size_pct: 100.0,
            }),
            7 if ctx.in_position => Some(Signal::Exit {
                reason: ExitReason::Signal("close short".into()),
            }),
            _ => None,
        }
    }
    fn on_reset(&mut self) {}
}

#[test]
fn short_only_final_equity_matches_initial_plus_net_pnl() {
    // Pure SHORT trade: enter @ candle[1].close=100, exit @ candle[3].close=95
    // with fee_rate = 0.001 (0.1%).
    let candles = vec![
        candle(1_000, 100.0, 101.0, 99.0, 100.0),
        candle(2_000, 100.0, 101.0, 99.0, 100.0), // entry at 100
        candle(3_000, 98.0, 99.0, 96.0, 98.0),
        candle(4_000, 95.0, 96.0, 94.0, 95.0), // exit at 95
    ];

    let initial_balance = 10_000.0;
    let fee_rate = 0.001;
    let config = BacktestConfig::new(initial_balance, fee_rate, Timeframe::H1);
    let mut engine = BacktestEngine::new(config);
    let mut strategy = OneShotShort;
    let result = engine.run(&mut strategy, &candles, HashMap::new());

    assert_eq!(result.metrics.total_trades, 1);
    let trade = &result.metrics.trades[0];
    let net_pnl = trade.pnl;

    // Final equity is the post-loop equity_curve point (no open position).
    let final_equity = result.equity_curve.last().unwrap().equity;
    let expected = initial_balance + net_pnl;
    assert!(
        (final_equity - expected).abs() < 1e-9,
        "F-02c: final equity after a closed short must equal initial_balance + \
         net_pnl. expected={}, actual={}, diff={}",
        expected,
        final_equity,
        final_equity - expected
    );
}

#[test]
fn mixed_long_then_short_final_equity_compounds_correctly() {
    // LONG @ candle[1]=100 → exit @ candle[3]=110 (profit), then
    // SHORT @ candle[5]=110 → exit @ candle[7]=100 (profit).
    let candles = vec![
        candle(1_000, 100.0, 101.0, 99.0, 100.0),
        candle(2_000, 100.0, 101.0, 99.0, 100.0), // long entry at 100
        candle(3_000, 105.0, 106.0, 104.0, 105.0),
        candle(4_000, 110.0, 111.0, 109.0, 110.0), // long exit at 110
        candle(5_000, 110.0, 111.0, 109.0, 110.0),
        candle(6_000, 110.0, 111.0, 109.0, 110.0), // short entry at 110
        candle(7_000, 105.0, 106.0, 104.0, 105.0),
        candle(8_000, 100.0, 101.0, 99.0, 100.0), // short exit at 100
    ];

    let initial_balance = 10_000.0;
    let fee_rate = 0.001;
    let config = BacktestConfig::new(initial_balance, fee_rate, Timeframe::H1);
    let mut engine = BacktestEngine::new(config);
    let mut strategy = LongThenShort;
    let result = engine.run(&mut strategy, &candles, HashMap::new());

    assert_eq!(result.metrics.total_trades, 2);
    let total_pnl: f64 = result.metrics.trades.iter().map(|t| t.pnl).sum();

    let final_equity = result.equity_curve.last().unwrap().equity;
    let expected = initial_balance + total_pnl;
    assert!(
        (final_equity - expected).abs() < 1e-9,
        "F-02c: final equity after long→short must equal initial_balance + \
         sum(net_pnl). expected={}, actual={}, diff={}",
        expected,
        final_equity,
        final_equity - expected
    );

    // Sanity: both trades are profitable in this fixture; if SHORT balance
    // accounting is broken, the second trade's quantity (and thus pnl) will
    // be wrong, but `total_pnl` will still be the SUM of two recorded pnls.
    // The contract under test is the relationship between equity and pnl,
    // not the absolute size of either.
    assert!(
        total_pnl > 0.0,
        "fixture must produce a net-positive sequence; got total_pnl={}",
        total_pnl
    );
}
