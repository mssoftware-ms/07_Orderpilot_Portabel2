//! Backtest Engine – runs strategies against historical candle data with
//! realistic fee simulation, SL/TP execution, equity curve tracking, and
//! comprehensive performance metrics.
//!
//! # Architecture
//! The engine is **strategy-agnostic** – it accepts any `Box<dyn StrategyAddin>`
//! and drives it candle-by-candle.  Position management (open / close / SL / TP)
//! lives here, *not* inside the strategy.
//!
//! # Fee Model
//! Bitunix VIP0: 0.06 % taker fee per side (entry + exit).  The engine deducts
//! fees from PnL so `ClosedTrade.pnl` is always **net of fees**.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::models::{BacktestMetrics, Candle, ClosedTrade, ExitReason, Position, PositionSide, Timeframe};
use crate::strategy::{Context, Signal, StrategyAddin};

// ─── Configuration ───────────────────────────────────────────────────────────

/// Configuration for a backtest run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BacktestConfig {
    /// Starting account balance (quote currency, e.g. USDT).
    pub initial_balance: f64,
    /// Taker fee rate per side (0.0006 = 0.06 %).
    pub fee_rate: f64,
    /// Timeframe of the input candles.
    pub timeframe: Timeframe,
}

impl BacktestConfig {
    /// Bitunix VIP0 default: 0.06 % taker fee.
    pub fn default_fee_rate() -> f64 {
        0.0006
    }

    pub fn new(initial_balance: f64, fee_rate: f64, timeframe: Timeframe) -> Self {
        Self {
            initial_balance,
            fee_rate,
            timeframe,
        }
    }
}

impl Default for BacktestConfig {
    fn default() -> Self {
        Self {
            initial_balance: 10_000.0,
            fee_rate: Self::default_fee_rate(),
            timeframe: Timeframe::H1,
        }
    }
}

// ─── Equity Point ────────────────────────────────────────────────────────────

/// A single point on the equity curve, recorded at every candle close.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EquityPoint {
    /// Candle timestamp (Unix ms).
    pub timestamp: i64,
    /// Total equity (balance + unrealised PnL) at this candle close.
    pub equity: f64,
    /// Current drawdown from peak equity (absolute, always >= 0).
    pub drawdown: f64,
    /// Drawdown as a percentage of peak equity.
    pub drawdown_pct: f64,
}

// ─── Backtest Result ─────────────────────────────────────────────────────────

/// Full result of a backtest run – metrics, equity curve, and config.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BacktestResult {
    /// Aggregate performance metrics (includes the trade log).
    pub metrics: BacktestMetrics,
    /// Per-candle equity curve.
    pub equity_curve: Vec<EquityPoint>,
    /// The configuration that produced these results.
    pub config: BacktestConfig,
    /// Total fees paid across all trades (quote currency).
    pub total_fees: f64,
    /// Number of candles processed.
    pub candles_processed: usize,
}

// ─── Backtest Engine ─────────────────────────────────────────────────────────

/// The main backtest engine.
pub struct BacktestEngine {
    config: BacktestConfig,
    balance: f64,
    position: Option<Position>,
    trades: Vec<ClosedTrade>,
    equity_curve: Vec<EquityPoint>,
    total_fees: f64,
    peak_equity: f64,
    /// Fee amounts for the currently open position's entry.
    current_entry_fee: f64,
}

impl BacktestEngine {
    /// Create a new engine with the given configuration.
    pub fn new(config: BacktestConfig) -> Self {
        let initial = config.initial_balance;
        Self {
            config,
            balance: initial,
            position: None,
            trades: Vec::new(),
            equity_curve: Vec::new(),
            total_fees: 0.0,
            peak_equity: initial,
            current_entry_fee: 0.0,
        }
    }

    /// Run a strategy against a list of candles with the given parameters.
    ///
    /// This is the primary entry point.  It:
    /// 1. Resets the strategy
    /// 2. Iterates through candles one-by-one
    /// 3. On each candle: check SL/TP first, then call the strategy
    /// 4. Records equity at every candle close
    /// 5. Force-closes any open position at end-of-data
    /// 6. Computes aggregate metrics via `BacktestMetrics::from_trades`
    pub fn run(
        &mut self,
        strategy: &mut dyn StrategyAddin,
        candles: &[Candle],
        params: HashMap<String, f64>,
    ) -> BacktestResult {
        // Reset engine state
        self.balance = self.config.initial_balance;
        self.position = None;
        self.trades.clear();
        self.equity_curve.clear();
        self.total_fees = 0.0;
        self.peak_equity = self.config.initial_balance;
        self.current_entry_fee = 0.0;

        // Reset strategy
        strategy.on_reset();

        // Build context
        let mut ctx = Context::new(candles.to_vec(), self.config.timeframe, params);

        let num_candles = candles.len();

        for i in 0..num_candles {
            ctx.set_index(i);
            let candle = &candles[i];

            // ── Step 1: Check SL / TP on current candle OHLC ──
            if self.position.is_some() {
                let sl_hit = self.position.as_ref().unwrap().is_stop_hit(candle.low, candle.high);
                let tp_hit = self.position.as_ref().unwrap().is_tp_hit(candle.low, candle.high);

                if sl_hit && tp_hit {
                    // Ambiguous: assume SL hit first (conservative)
                    let sl_price = self.position.as_ref().unwrap().stop_loss.unwrap();
                    self.close_position(sl_price, candle.timestamp, ExitReason::StopLoss);
                    ctx.in_position = false;
                } else if sl_hit {
                    let sl_price = self.position.as_ref().unwrap().stop_loss.unwrap();
                    self.close_position(sl_price, candle.timestamp, ExitReason::StopLoss);
                    ctx.in_position = false;
                } else if tp_hit {
                    let tp_price = self.position.as_ref().unwrap().take_profit.unwrap();
                    self.close_position(tp_price, candle.timestamp, ExitReason::TakeProfit);
                    ctx.in_position = false;
                }
            }

            // ── Step 2: Call strategy ──
            if let Some(signal) = strategy.on_candle(&mut ctx, candle) {
                match signal {
                    Signal::EnterLong { sl, tp, size_pct } if self.position.is_none() => {
                        let first_tp = tp.first().copied();
                        self.open_position(
                            candle.close,
                            candle.timestamp,
                            PositionSide::Long,
                            sl,
                            first_tp,
                            size_pct,
                        );
                        ctx.in_position = true;
                    }
                    Signal::EnterShort { sl, tp, size_pct } if self.position.is_none() => {
                        let first_tp = tp.first().copied();
                        self.open_position(
                            candle.close,
                            candle.timestamp,
                            PositionSide::Short,
                            sl,
                            first_tp,
                            size_pct,
                        );
                        ctx.in_position = true;
                    }
                    Signal::Exit { reason } if self.position.is_some() => {
                        self.close_position(candle.close, candle.timestamp, reason);
                        ctx.in_position = false;
                    }
                    Signal::MoveStop { new_sl } if self.position.is_some() => {
                        if let Some(ref mut pos) = self.position {
                            pos.stop_loss = Some(new_sl);
                        }
                    }
                    _ => {} // ignore invalid combinations (e.g. enter while in position)
                }
            }

            // ── Step 3: Record equity at candle close ──
            let equity = self.current_equity(candle.close);
            if equity > self.peak_equity {
                self.peak_equity = equity;
            }
            let dd = self.peak_equity - equity;
            let dd_pct = if self.peak_equity > 0.0 {
                dd / self.peak_equity * 100.0
            } else {
                0.0
            };
            self.equity_curve.push(EquityPoint {
                timestamp: candle.timestamp,
                equity,
                drawdown: dd,
                drawdown_pct: dd_pct,
            });
        }

        // ── Step 4: Force-close open position at end-of-data ──
        if self.position.is_some() && !candles.is_empty() {
            let last = candles.last().unwrap();
            self.close_position(last.close, last.timestamp, ExitReason::EndOfData);
        }

        // ── Step 5: Compute metrics ──
        // F-03: Sharpe is computed over per-candle equity-curve returns and
        // annualized by sqrt(periods_per_year(timeframe)). Pass the equity
        // curve and timeframe so `from_trades` can do the canonical
        // calculation (matching the Dart engine).
        let equity_series: Vec<f64> =
            self.equity_curve.iter().map(|p| p.equity).collect();
        let metrics = BacktestMetrics::from_trades(
            self.trades.clone(),
            self.config.initial_balance,
            &equity_series,
            self.config.timeframe,
        );

        BacktestResult {
            metrics,
            equity_curve: self.equity_curve.clone(),
            config: self.config.clone(),
            total_fees: self.total_fees,
            candles_processed: num_candles,
        }
    }

    // ─── Private helpers ─────────────────────────────────────────────────────

    /// Open a new position, deducting entry fee from balance.
    fn open_position(
        &mut self,
        entry_price: f64,
        timestamp: i64,
        side: PositionSide,
        sl: Option<f64>,
        tp: Option<f64>,
        size_pct: f64,
    ) {
        let alloc = self.balance * (size_pct.clamp(0.0, 100.0) / 100.0);
        let entry_fee = alloc * self.config.fee_rate;
        let notional_after_fee = alloc - entry_fee;
        let quantity = notional_after_fee / entry_price;

        self.balance -= alloc;
        self.current_entry_fee = entry_fee;
        self.total_fees += entry_fee;

        self.position = Some(Position {
            entry_price,
            quantity,
            side,
            stop_loss: sl,
            take_profit: tp,
            entry_time: timestamp,
        });
    }

    /// Close the current position, computing net PnL after exit fee.
    ///
    /// Balance accounting (F-02c, direction-agnostic):
    ///   - On entry we deducted `alloc` from balance, where
    ///     `alloc = quantity * entry_price + entry_fee`.
    ///   - `unrealized_pnl` already encodes side (Long: exit-entry, Short:
    ///     entry-exit), so `net_pnl = gross_pnl - entry_fee - exit_fee` is
    ///     correctly signed for both sides.
    ///   - On close we return the reserved margin and add the realised P&L:
    ///       `balance += alloc + net_pnl`
    ///   For LONGs this collapses algebraically to the older
    ///   `proceeds = exit_notional - exit_fee` expression; for SHORTs the
    ///   older expression drained balance by ~`2 * gross_pnl_short`.
    fn close_position(&mut self, exit_price: f64, exit_time: i64, reason: ExitReason) {
        let pos = match self.position.take() {
            Some(p) => p,
            None => return,
        };

        let exit_notional = pos.quantity * exit_price;
        let exit_fee = exit_notional * self.config.fee_rate;
        self.total_fees += exit_fee;

        let gross_pnl = pos.unrealized_pnl(exit_price);
        let net_pnl = gross_pnl - self.current_entry_fee - exit_fee;

        let entry_notional = pos.entry_price * pos.quantity;
        let pnl_percent = if entry_notional > 0.0 {
            net_pnl / entry_notional * 100.0
        } else {
            0.0
        };

        // Return reserved margin + realised net P&L (direction-agnostic).
        let alloc = entry_notional + self.current_entry_fee;
        self.balance += alloc + net_pnl;

        self.current_entry_fee = 0.0;

        self.trades.push(ClosedTrade {
            entry_time: pos.entry_time,
            exit_time,
            entry_price: pos.entry_price,
            exit_price,
            quantity: pos.quantity,
            side: pos.side,
            pnl: net_pnl,
            pnl_percent,
            exit_reason: reason,
        });
    }

    /// Current equity = balance + mark-to-market of open position.
    ///
    /// Direction-agnostic (F-02c): equity is what the account would settle to
    /// if the position closed at `current_price` right now. Using the same
    /// algebra as `close_position`:
    ///   equity = balance + alloc + net_unrealized_pnl
    ///          = balance + alloc + (gross_unrealized - entry_fee - est_exit_fee)
    /// For LONGs this collapses to the previous `balance + exit_notional -
    /// est_exit_fee` formula; for SHORTs the old formula reported negative
    /// unrealised P&L when the trade was in the money.
    fn current_equity(&self, current_price: f64) -> f64 {
        match &self.position {
            Some(pos) => {
                let alloc = pos.entry_price * pos.quantity + self.current_entry_fee;
                let unrealized = pos.unrealized_pnl(current_price);
                let est_exit_fee = pos.quantity * current_price * self.config.fee_rate;
                self.balance + alloc + unrealized - self.current_entry_fee - est_exit_fee
            }
            None => self.balance,
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: create a simple candle.
    fn candle(ts: i64, open: f64, high: f64, low: f64, close: f64) -> Candle {
        Candle::new(ts, open, high, low, close, 100.0)
    }

    /// A trivial strategy that emits a long entry on candle index 1 and exit on candle index 3.
    struct FixedLongStrategy;

    impl StrategyAddin for FixedLongStrategy {
        fn manifest(&self) -> crate::strategy::AddinManifest {
            crate::strategy::AddinManifest {
                id: "test".into(),
                name: "Test".into(),
                version: "0.1.0".into(),
                author: "test".into(),
                description: "test".into(),
                category: crate::strategy::StrategyCategory::Custom,
                timeframes: vec![Timeframe::H1],
                parameters: vec![],
            }
        }
        fn required_inputs(&self) -> Vec<crate::strategy::InputSpec> {
            vec![]
        }
        fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
            let i = ctx.index();
            match i {
                1 => Some(Signal::EnterLong {
                    sl: None,
                    tp: vec![],
                    size_pct: 100.0,
                }),
                3 => Some(Signal::Exit {
                    reason: ExitReason::Signal("test exit".into()),
                }),
                _ => None,
            }
        }
        fn on_reset(&mut self) {}
    }

    /// A strategy that enters long with SL and TP.
    struct SlTpStrategy {
        sl: f64,
        tp: f64,
    }

    impl StrategyAddin for SlTpStrategy {
        fn manifest(&self) -> crate::strategy::AddinManifest {
            crate::strategy::AddinManifest {
                id: "sltp".into(),
                name: "SL/TP Test".into(),
                version: "0.1.0".into(),
                author: "test".into(),
                description: "test".into(),
                category: crate::strategy::StrategyCategory::Custom,
                timeframes: vec![Timeframe::H1],
                parameters: vec![],
            }
        }
        fn required_inputs(&self) -> Vec<crate::strategy::InputSpec> {
            vec![]
        }
        fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
            if ctx.index() == 1 && !ctx.in_position {
                Some(Signal::EnterLong {
                    sl: Some(self.sl),
                    tp: vec![self.tp],
                    size_pct: 100.0,
                })
            } else {
                None
            }
        }
        fn on_reset(&mut self) {}
    }

    // ── Basic round-trip test ──

    #[test]
    fn test_basic_long_trade() {
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // enter long at 100
            candle(3000, 101.0, 102.0, 100.0, 101.0),
            candle(4000, 102.0, 103.0, 101.0, 102.0), // exit at 102
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1); // no fees
        let mut engine = BacktestEngine::new(config);
        let mut strategy = FixedLongStrategy;
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        assert_eq!(result.metrics.winning_trades, 1);
        assert!(result.metrics.total_pnl > 0.0, "Should be profitable");
        assert_eq!(result.candles_processed, 4);
        assert_eq!(result.equity_curve.len(), 4);
    }

    #[test]
    fn test_fee_deduction() {
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // enter at 100
            candle(3000, 100.0, 101.0, 99.0, 100.0),
            candle(4000, 100.0, 101.0, 99.0, 100.0), // exit at 100 (flat)
        ];

        let fee_rate = 0.001; // 0.1% per side
        let config = BacktestConfig::new(10_000.0, fee_rate, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = FixedLongStrategy;
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        // With flat price, PnL should be negative (fees only)
        assert!(
            result.metrics.total_pnl < 0.0,
            "Flat trade should lose money to fees, got {}",
            result.metrics.total_pnl
        );
        assert!(result.total_fees > 0.0);

        // Verify fee amounts:
        // Entry: alloc = 10000, entry_fee = 10000 * 0.001 = 10
        // quantity = (10000 - 10) / 100 = 99.9
        // Exit notional = 99.9 * 100 = 9990, exit_fee = 9990 * 0.001 = 9.99
        // Total fees ≈ 19.99
        let expected_total_fees = 10.0 + 9.99;
        assert!(
            (result.total_fees - expected_total_fees).abs() < 0.01,
            "Total fees should be ~{}, got {}",
            expected_total_fees,
            result.total_fees
        );
    }

    #[test]
    fn test_stop_loss_hit() {
        // Enter long at close of candle 1 = 100, SL at 95
        // Candle 2 low dips to 94 → SL hit at 95
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // entry
            candle(3000, 99.0, 100.0, 94.0, 96.0),    // SL hit (low=94 < 95)
            candle(4000, 96.0, 97.0, 95.0, 96.0),
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = SlTpStrategy { sl: 95.0, tp: 110.0 };
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        let trade = &result.metrics.trades[0];
        assert_eq!(trade.exit_price, 95.0);
        assert_eq!(trade.exit_reason, ExitReason::StopLoss);
        assert!(trade.pnl < 0.0, "SL trade should be a loss");
    }

    #[test]
    fn test_take_profit_hit() {
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // entry at 100, TP at 105
            candle(3000, 102.0, 106.0, 101.0, 104.0), // TP hit (high=106 > 105)
            candle(4000, 104.0, 105.0, 103.0, 104.0),
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = SlTpStrategy { sl: 90.0, tp: 105.0 };
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        let trade = &result.metrics.trades[0];
        assert_eq!(trade.exit_price, 105.0);
        assert_eq!(trade.exit_reason, ExitReason::TakeProfit);
        assert!(trade.pnl > 0.0, "TP trade should be a win");
    }

    #[test]
    fn test_end_of_data_close() {
        // Enter long but never hit SL/TP or exit signal → force-close at end
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // entry
            candle(3000, 101.0, 102.0, 100.0, 101.0),
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = SlTpStrategy { sl: 80.0, tp: 200.0 }; // very wide SL/TP
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        assert_eq!(
            result.metrics.trades[0].exit_reason,
            ExitReason::EndOfData
        );
        assert_eq!(result.metrics.trades[0].exit_price, 101.0);
    }

    #[test]
    fn test_no_trades() {
        struct NoOpStrategy;
        impl StrategyAddin for NoOpStrategy {
            fn manifest(&self) -> crate::strategy::AddinManifest {
                crate::strategy::AddinManifest {
                    id: "noop".into(), name: "NoOp".into(), version: "0.1.0".into(),
                    author: "test".into(), description: "test".into(),
                    category: crate::strategy::StrategyCategory::Custom,
                    timeframes: vec![Timeframe::H1], parameters: vec![],
                }
            }
            fn required_inputs(&self) -> Vec<crate::strategy::InputSpec> { vec![] }
            fn on_candle(&mut self, _ctx: &mut Context, _candle: &Candle) -> Option<Signal> { None }
            fn on_reset(&mut self) {}
        }

        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 101.0, 102.0, 100.0, 101.0),
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = NoOpStrategy;
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 0);
        assert_eq!(result.metrics.total_pnl, 0.0);
        assert_eq!(result.total_fees, 0.0);
        // Equity should remain flat at initial balance
        assert_eq!(result.equity_curve[0].equity, 10_000.0);
        assert_eq!(result.equity_curve[1].equity, 10_000.0);
    }

    #[test]
    fn test_equity_curve_drawdown() {
        // Two trades: first a loss, then a win
        struct TwoTradeStrategy { trade_num: usize }
        impl StrategyAddin for TwoTradeStrategy {
            fn manifest(&self) -> crate::strategy::AddinManifest {
                crate::strategy::AddinManifest {
                    id: "two".into(), name: "Two".into(), version: "0.1.0".into(),
                    author: "test".into(), description: "test".into(),
                    category: crate::strategy::StrategyCategory::Custom,
                    timeframes: vec![Timeframe::H1], parameters: vec![],
                }
            }
            fn required_inputs(&self) -> Vec<crate::strategy::InputSpec> { vec![] }
            fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
                let i = ctx.index();
                match i {
                    1 if !ctx.in_position => {
                        self.trade_num += 1;
                        Some(Signal::EnterLong { sl: None, tp: vec![], size_pct: 100.0 })
                    }
                    2 if ctx.in_position => Some(Signal::Exit { reason: ExitReason::Signal("exit1".into()) }),
                    3 if !ctx.in_position => {
                        self.trade_num += 1;
                        Some(Signal::EnterLong { sl: None, tp: vec![], size_pct: 100.0 })
                    }
                    4 if ctx.in_position => Some(Signal::Exit { reason: ExitReason::Signal("exit2".into()) }),
                    _ => None,
                }
            }
            fn on_reset(&mut self) { self.trade_num = 0; }
        }

        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // enter at 100
            candle(3000, 98.0, 99.0, 97.0, 98.0),     // exit at 98 (loss)
            candle(4000, 98.0, 99.0, 97.0, 98.0),     // enter at 98
            candle(5000, 105.0, 106.0, 104.0, 105.0), // exit at 105 (win)
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = TwoTradeStrategy { trade_num: 0 };
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 2);
        assert_eq!(result.metrics.winning_trades, 1);
        assert_eq!(result.metrics.losing_trades, 1);
        assert_eq!(result.metrics.win_rate, 50.0);

        // Max drawdown should be > 0 (from the losing trade)
        assert!(result.metrics.max_drawdown > 0.0);
    }

    #[test]
    fn test_short_trade() {
        struct ShortStrategy;
        impl StrategyAddin for ShortStrategy {
            fn manifest(&self) -> crate::strategy::AddinManifest {
                crate::strategy::AddinManifest {
                    id: "short".into(), name: "Short".into(), version: "0.1.0".into(),
                    author: "test".into(), description: "test".into(),
                    category: crate::strategy::StrategyCategory::Custom,
                    timeframes: vec![Timeframe::H1], parameters: vec![],
                }
            }
            fn required_inputs(&self) -> Vec<crate::strategy::InputSpec> { vec![] }
            fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
                match ctx.index() {
                    1 => Some(Signal::EnterShort { sl: None, tp: vec![], size_pct: 100.0 }),
                    3 => Some(Signal::Exit { reason: ExitReason::Signal("close short".into()) }),
                    _ => None,
                }
            }
            fn on_reset(&mut self) {}
        }

        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // enter short at 100
            candle(3000, 99.0, 100.0, 98.0, 99.0),
            candle(4000, 97.0, 98.0, 96.0, 97.0),     // exit at 97 (win for short)
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = ShortStrategy;
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        assert!(result.metrics.total_pnl > 0.0, "Short at 100 exit 97 should be profitable");
    }

    #[test]
    fn test_bitunix_vip0_fees() {
        // Verify exact Bitunix VIP0 fee calculation (0.06% per side)
        let candles = vec![
            candle(1000, 50000.0, 50100.0, 49900.0, 50000.0),
            candle(2000, 50000.0, 50100.0, 49900.0, 50000.0), // enter at 50000
            candle(3000, 51000.0, 51100.0, 50900.0, 51000.0),
            candle(4000, 52000.0, 52100.0, 51900.0, 52000.0), // exit at 52000
        ];

        let fee_rate = 0.0006; // Bitunix VIP0
        let initial = 10_000.0;
        let config = BacktestConfig::new(initial, fee_rate, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = FixedLongStrategy;
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        // Entry: alloc = 10000, entry_fee = 10000 * 0.0006 = 6
        // quantity = (10000 - 6) / 50000 = 0.19988
        // Exit notional = 0.19988 * 52000 = 10393.76
        // exit_fee = 10393.76 * 0.0006 = 6.23626
        // gross_pnl = 0.19988 * (52000 - 50000) = 399.76
        // net_pnl = 399.76 - 6 - 6.23626 ≈ 387.52
        let trade = &result.metrics.trades[0];
        assert!(trade.pnl > 380.0 && trade.pnl < 395.0,
            "Expected net PnL ~387.5, got {}", trade.pnl);

        // Total fees should be ~12.24
        assert!(result.total_fees > 12.0 && result.total_fees < 13.0,
            "Expected total fees ~12.24, got {}", result.total_fees);
    }

    #[test]
    fn test_empty_candles() {
        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = FixedLongStrategy;
        let result = engine.run(&mut strategy, &[], HashMap::new());

        assert_eq!(result.metrics.total_trades, 0);
        assert_eq!(result.candles_processed, 0);
        assert!(result.equity_curve.is_empty());
    }

    #[test]
    fn test_move_stop() {
        struct MoveStopStrategy;
        impl StrategyAddin for MoveStopStrategy {
            fn manifest(&self) -> crate::strategy::AddinManifest {
                crate::strategy::AddinManifest {
                    id: "ms".into(), name: "MoveStop".into(), version: "0.1.0".into(),
                    author: "test".into(), description: "test".into(),
                    category: crate::strategy::StrategyCategory::Custom,
                    timeframes: vec![Timeframe::H1], parameters: vec![],
                }
            }
            fn required_inputs(&self) -> Vec<crate::strategy::InputSpec> { vec![] }
            fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
                match ctx.index() {
                    1 => Some(Signal::EnterLong { sl: Some(90.0), tp: vec![], size_pct: 100.0 }),
                    2 => Some(Signal::MoveStop { new_sl: 99.0 }), // tighten stop
                    _ => None,
                }
            }
            fn on_reset(&mut self) {}
        }

        // Candle 3: low=98 which is below the moved SL of 99 → SL hit
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // enter, SL=90
            candle(3000, 101.0, 102.0, 100.0, 101.0), // move SL to 99
            candle(4000, 100.0, 101.0, 98.0, 99.0),   // low=98 < SL=99 → hit
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = MoveStopStrategy;
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        let trade = &result.metrics.trades[0];
        assert_eq!(trade.exit_reason, ExitReason::StopLoss);
        assert_eq!(trade.exit_price, 99.0);
    }

    #[test]
    fn test_backtest_result_serialization() {
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0),
            candle(3000, 102.0, 103.0, 101.0, 102.0),
            candle(4000, 103.0, 104.0, 102.0, 103.0),
        ];

        let config = BacktestConfig::new(10_000.0, 0.0006, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = FixedLongStrategy;
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        // Must be serializable to JSON for Flutter consumption
        let json = serde_json::to_string(&result).expect("BacktestResult must serialize to JSON");
        let parsed: BacktestResult =
            serde_json::from_str(&json).expect("BacktestResult must deserialize from JSON");
        assert_eq!(parsed.metrics.total_trades, result.metrics.total_trades);
        assert_eq!(parsed.candles_processed, result.candles_processed);
    }
}
