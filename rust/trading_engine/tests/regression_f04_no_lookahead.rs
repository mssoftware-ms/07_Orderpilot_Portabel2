//! F-04 regression: no look-ahead bias.
//!
//! Spec §3.4 F-04:
//!   A strategy signal generated on candle `i` (with information up to and
//!   including `candle[i].close`) MUST be executed at the OPEN of candle
//!   `i+1`, not at the close of candle `i`. The pre-F-04 engine opened
//!   positions at `candle[i].close` which is a textbook look-ahead bug:
//!   the strategy is reading information it would not have at the moment
//!   the order is sent.
//!
//! Pinned with a deterministic custom strategy that emits exactly one
//! `EnterLong` at index 20. The fixture is engineered so
//! `candle[20].close != candle[21].open`, which makes the assertion
//! `trade.entry_price == candle[21].open` (and inequality against
//! `candle[20].close`) the smoking gun.

use std::collections::HashMap;

use trading_engine::backtest::{BacktestConfig, BacktestEngine};
use trading_engine::models::{Candle, Timeframe};
use trading_engine::strategy::{
    AddinManifest, Context, InputSpec, ParameterSchema, Signal, StrategyAddin, StrategyCategory,
};

/// Test strategy that emits `EnterLong` at exactly `ctx.index() == 20`.
struct EnterAt20Strategy;

impl StrategyAddin for EnterAt20Strategy {
    fn manifest(&self) -> AddinManifest {
        AddinManifest {
            id: "test_enter_at_20".to_string(),
            name: "Enter At 20".to_string(),
            version: "0.1.0".to_string(),
            author: "f04 regression".to_string(),
            description: "fires EnterLong at candle index 20".to_string(),
            category: StrategyCategory::Custom,
            timeframes: vec![Timeframe::H1],
            parameters: Vec::<ParameterSchema>::new(),
        }
    }

    fn required_inputs(&self) -> Vec<InputSpec> {
        Vec::new()
    }

    fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
        if ctx.index() == 20 && !ctx.in_position {
            Some(Signal::EnterLong {
                sl: None,
                tp: Vec::new(),
                size_pct: 100.0,
            })
        } else {
            None
        }
    }

    fn on_reset(&mut self) {}
}

/// Build a 50-candle fixture where each candle's close differs materially
/// from the next candle's open. This way `entry_price == candle[N].open`
/// can only match the next-bar-open contract, never an off-by-one
/// substitution against `candle[N-1].close`.
fn build_fixture() -> Vec<Candle> {
    (0..50)
        .map(|i| {
            let ts = 1_700_000_000_000 + (i as i64) * 3_600_000;
            // open and close drift apart by 0.5 per bar — close[i] != open[i+1].
            let open = 100.0 + i as f64;
            let close = 100.0 + i as f64 + 0.5;
            Candle::new(ts, open, open + 1.0, open - 1.0, close, 1_000.0)
        })
        .collect()
}

#[test]
fn signal_on_bar_20_executes_at_bar_21_open() {
    let candles = build_fixture();
    let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
    let mut engine = BacktestEngine::new(config);
    let mut strat = EnterAt20Strategy;
    let result = engine.run(&mut strat, &candles, HashMap::new());

    assert_eq!(
        result.metrics.total_trades, 1,
        "expected exactly one round-trip from the deterministic fixture"
    );
    let trade = &result.metrics.trades[0];

    // The smoking gun: the signal arose with candle 20's information; the
    // fill MUST happen at the open of candle 21, NOT the close of candle 20.
    assert_eq!(
        trade.entry_time, candles[21].timestamp,
        "entry timestamp must be candle[21], got an off-by-one"
    );
    assert!(
        (trade.entry_price - candles[21].open).abs() < 1e-9,
        "expected entry_price == candle[21].open ({}), got {}",
        candles[21].open,
        trade.entry_price
    );
    assert!(
        (trade.entry_price - candles[20].close).abs() > 1e-9,
        "entry_price MUST NOT equal candle[20].close ({}) — that is the \
         look-ahead bug F-04 fixes",
        candles[20].close
    );
}

#[test]
fn entry_price_with_default_slippage_equals_next_bar_open_exactly() {
    // Plan rev2: default slippage = 0 bps. Therefore the bit-exact open
    // assertion must hold without tolerance widening.
    let candles = build_fixture();
    let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
    let mut engine = BacktestEngine::new(config);
    let mut strat = EnterAt20Strategy;
    let result = engine.run(&mut strat, &candles, HashMap::new());

    assert_eq!(result.metrics.total_trades, 1);
    let trade = &result.metrics.trades[0];
    // Bit-exact equality, not closeTo — default slippage is 0.
    assert_eq!(trade.entry_price, candles[21].open);
}
