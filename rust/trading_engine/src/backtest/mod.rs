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
    /// One-side slippage in basis points applied at every execution
    /// (entry and exit) against the trader. Plan rev2 §3.4 F-04 sets
    /// the default to 0 bps for Binance / Bitunix BTC + ETH at common
    /// retail sizes; raise for thin alts or large orders.
    #[serde(default)]
    pub slippage_bps: f64,
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
            slippage_bps: 0.0,
        }
    }

    /// Builder: set slippage_bps (default 0.0 per Plan rev2).
    pub fn with_slippage_bps(mut self, slippage_bps: f64) -> Self {
        self.slippage_bps = slippage_bps;
        self
    }
}

impl Default for BacktestConfig {
    fn default() -> Self {
        Self {
            initial_balance: 10_000.0,
            fee_rate: Self::default_fee_rate(),
            timeframe: Timeframe::H1,
            slippage_bps: 0.0,
        }
    }
}

// ─── Pending Order (F-04 next-bar-open execution) ────────────────────────────

/// An order queued during one bar's strategy.on_candle, to be filled at
/// the next bar's open. Plan §3.4 F-04: any strategy signal must execute
/// one bar later than it was decided to remove look-ahead bias.
#[derive(Debug, Clone)]
enum PendingOrder {
    EnterLong {
        sl: Option<f64>,
        tp: Option<f64>,
        size_pct: f64,
    },
    EnterShort {
        sl: Option<f64>,
        tp: Option<f64>,
        size_pct: f64,
    },
    Exit {
        reason: ExitReason,
    },
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
    /// F-04: order queued on the prior bar, filled at this bar's open.
    pending_order: Option<PendingOrder>,
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
            pending_order: None,
        }
    }

    /// Run a strategy against a list of candles with the given parameters.
    ///
    /// Per-bar order of operations (Plan §3.4 F-04, no look-ahead bias):
    /// 1. Execute any order queued on the previous bar at this bar's OPEN
    ///    (with one-side slippage_bps applied against the trader).
    /// 2. Check intra-bar SL / TP against this bar's OHLC. Stop and take-
    ///    profit are price-triggered orders that can fire during the bar,
    ///    so they execute on the same bar.
    /// 3. Call strategy.on_candle. Any signal it emits is QUEUED — it will
    ///    fill at the next bar's open, not at this bar's close. This is the
    ///    F-04 invariant; opening at this bar's close is look-ahead bias.
    /// 4. Record equity at this bar's close.
    ///
    /// End-of-data: a pending order on the final bar is discarded (there is
    /// no next bar to fill it on). Any still-open position is then force-
    /// closed at the final bar's close with `ExitReason::EndOfData`, no
    /// slippage (settle-to-last-mark convention).
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
        self.pending_order = None;

        // Reset strategy
        strategy.on_reset();

        // Build context
        let mut ctx = Context::new(candles.to_vec(), self.config.timeframe, params);

        let num_candles = candles.len();

        for (i, candle) in candles.iter().enumerate() {
            ctx.set_index(i);

            // ── Step 1: Execute pending order at this bar's OPEN ──
            if let Some(pending) = self.pending_order.take() {
                self.execute_pending(pending, candle);
            }

            // ── Step 2: Intra-bar exits, TP-first ordering (D-08). ──
            // Convention rewritten in D-08:
            //   a) TP check  — if `high ≥ TP` (long) / `low ≤ TP` (short)
            //      the limit order fills; exit at TP and skip the rest.
            //   b) BE-trail  — if no TP and the bar reached +1R, pull the
            //      SL to entry once and lock the flag.
            //   c) SL check  — using the possibly-updated SL.
            //
            // Pre-D-08 the engine resolved a same-bar SL+TP collision in
            // favour of SL (conservative). That convention turns BE-trail
            // into a strict loss for the trader on any bar that touches
            // both the TP and the retracement: the BE-trigger would move
            // the SL to entry, then the SL-first priority would close at
            // entry instead of letting the TP fill. TP-first resolves the
            // ambiguity in favour of the limit order that was actually
            // "first in queue" — both engines apply the same rule so the
            // Dart↔Rust parity is preserved.
            if self.position.is_some() {
                let tp_hit_first =
                    self.position.as_ref().unwrap().is_tp_hit(candle.low, candle.high);
                if tp_hit_first {
                    let tp_price = self.position.as_ref().unwrap().take_profit.unwrap();
                    self.close_position(tp_price, candle.timestamp, ExitReason::TakeProfit);
                } else {
                    if let Some(pos) = self.position.as_mut() {
                        if !pos.breakeven_applied {
                            if let Some(distance) = pos.initial_sl_distance {
                                let reached = match pos.side {
                                    PositionSide::Long => {
                                        candle.high >= pos.entry_price + distance
                                    }
                                    PositionSide::Short => {
                                        candle.low <= pos.entry_price - distance
                                    }
                                };
                                if reached {
                                    pos.stop_loss = Some(pos.entry_price);
                                    pos.breakeven_applied = true;
                                }
                            }
                        }
                    }
                    let sl_hit_post = self
                        .position
                        .as_ref()
                        .unwrap()
                        .is_stop_hit(candle.low, candle.high);
                    if sl_hit_post {
                        let sl_price = self.position.as_ref().unwrap().stop_loss.unwrap();
                        // N-15: apply slippage to SL closure (stop→market
                        // on trigger).  Default 0 bps — BTC/USDT retail
                        // has negligible spread.  Direction: long sells
                        // lower, short buys higher (against trader).
                        let sl_with_slippage = match self.position.as_ref().unwrap().side {
                            PositionSide::Long => {
                                sl_price * (1.0 - self.config.slippage_bps / 10000.0)
                            }
                            PositionSide::Short => {
                                sl_price * (1.0 + self.config.slippage_bps / 10000.0)
                            }
                        };
                        self.close_position(
                            sl_with_slippage,
                            candle.timestamp,
                            ExitReason::StopLoss,
                        );
                    }
                }
            }

            // ── Step 3: Call strategy, queue any signal for next bar ──
            ctx.in_position = self.position.is_some();
            if let Some(signal) = strategy.on_candle(&mut ctx, candle) {
                self.queue_signal(signal);
            }

            // ── Step 4: Record equity at candle close ──
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

        // ── End-of-data: pending order discarded (no next bar to fill), ──
        // ── then force-close any open position at the final bar's close.  ──
        self.pending_order = None;
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

    /// Translate a strategy `Signal` into the queued `PendingOrder` that
    /// will fill at the NEXT bar's open. Invalid combinations (enter while
    /// in position, exit while flat) are silently ignored — same policy as
    /// the pre-F-04 inline match. `MoveStop` does not need a fill and
    /// adjusts the current position's SL immediately.
    fn queue_signal(&mut self, signal: Signal) {
        match signal {
            Signal::EnterLong { sl, tp, size_pct } if self.position.is_none() => {
                if size_pct <= 0.0 {
                    return; // zero or negative allocation → don't queue (N-16)
                }
                let first_tp = tp;
                self.pending_order = Some(PendingOrder::EnterLong {
                    sl,
                    tp: first_tp,
                    size_pct,
                });
            }
            Signal::EnterShort { sl, tp, size_pct } if self.position.is_none() => {
                if size_pct <= 0.0 {
                    return; // zero or negative allocation → don't queue (N-16)
                }
                let first_tp = tp;
                self.pending_order = Some(PendingOrder::EnterShort {
                    sl,
                    tp: first_tp,
                    size_pct,
                });
            }
            Signal::Exit { reason } if self.position.is_some() => {
                self.pending_order = Some(PendingOrder::Exit { reason });
            }
            Signal::MoveStop { new_sl } if self.position.is_some() => {
                // N-24: skip move if SL would cross to wrong side of entry.
                if let Some(ref pos) = self.position {
                    let valid = match pos.side {
                        PositionSide::Long => new_sl < pos.entry_price,
                        PositionSide::Short => new_sl > pos.entry_price,
                    };
                    if !valid {
                        return;
                    }
                }
                if let Some(ref mut pos) = self.position {
                    pos.stop_loss = Some(new_sl);
                }
            }
            _ => {} // ignore invalid combinations
        }
    }

    /// Execute a previously-queued order at the current bar's OPEN, applying
    /// one-side slippage against the trader (long buy / short sell exit get
    /// `open * (1 + s)`; long sell / short buy entry get `open * (1 - s)`).
    /// Default slippage_bps = 0 → executes bit-exact at the open.
    ///
    /// N-22: all orders fill completely — no partial-fill simulation.
    /// For BTC/USDT at retail size on liquid exchanges this is realistic;
    /// for altcoins or large positions a volume-participation-rate model
    /// would be needed.
    fn execute_pending(&mut self, pending: PendingOrder, candle: &Candle) {
        let s = self.config.slippage_bps / 10_000.0;
        match pending {
            PendingOrder::EnterLong { sl, tp, size_pct } => {
                let price = candle.open * (1.0 + s);
                self.open_position(
                    price,
                    candle.timestamp,
                    PositionSide::Long,
                    sl,
                    tp,
                    size_pct,
                );
            }
            PendingOrder::EnterShort { sl, tp, size_pct } => {
                let price = candle.open * (1.0 - s);
                self.open_position(
                    price,
                    candle.timestamp,
                    PositionSide::Short,
                    sl,
                    tp,
                    size_pct,
                );
            }
            PendingOrder::Exit { reason } => {
                if let Some(pos) = self.position.as_ref() {
                    let price = match pos.side {
                        PositionSide::Long => candle.open * (1.0 - s),
                        PositionSide::Short => candle.open * (1.0 + s),
                    };
                    self.close_position(price, candle.timestamp, reason);
                }
            }
        }
    }

    /// Open a new position, deducting entry fee from balance.
    ///
    /// The entry fee is a cost debited from the account but does NOT reduce
    /// position size — quantity is based on the full allocation (N-13).  In
    /// real futures trading, fees are balance charges, not notional dilution.
    ///
    /// When a stop-loss is set, the allocation is adjusted for both entry
    /// AND exit fees (N-08, 0.06 % per side = 0.12 % round-trip on Bitunix
    /// VIP0) so the total loss at SL stays within the risk budget.
    fn open_position(
        &mut self,
        entry_price: f64,
        timestamp: i64,
        side: PositionSide,
        sl: Option<f64>,
        tp: Option<f64>,
        size_pct: f64,
    ) {
        debug_assert!(
            entry_price > 0.0,
            "open_position: entry_price must be positive, got {entry_price}"
        );
        if entry_price <= 0.0 {
            return;
        }
        // N-23: validate SL is on the correct side of entry.
        // Uses `warn` instead of `debug_assert` because the fill price
        // (next bar's open) can gap past the signal-bar SL, making the
        // assertion too strict for real-world data.
        if let Some(sl_price) = sl {
            match side {
                PositionSide::Long => {
                    if sl_price >= entry_price {
                        return; // SL at or above entry → skip this trade
                    }
                }
                PositionSide::Short => {
                    if sl_price <= entry_price {
                        return;
                    }
                }
            }
        }

        let raw_alloc = self.balance * (size_pct.clamp(0.0, 100.0) / 100.0);
        if raw_alloc <= 0.0 {
            return;
        }

        // Fee-adjusted allocation (N-08): the risk budget expressed by
        // size_pct targets the total loss including entry + exit fees.
        // Loss at SL = quantity * sl_dist + entry_fee + exit_fee_at_sl.
        // Exit fee at SL = quantity * sl_price * fee_rate.
        // Algebra: alloc = raw_alloc / (sl_dist/entry + fee*(1 + sl/entry)).
        let alloc = if let Some(sl_price) = sl {
            let sl_dist = (entry_price - sl_price).abs();
            if sl_dist > 0.0 {
                let fee_factor =
                    sl_dist / entry_price + self.config.fee_rate * (1.0 + sl_price / entry_price);
                if fee_factor > 0.0 {
                    (raw_alloc / fee_factor).min(self.balance).max(0.0)
                } else {
                    raw_alloc
                }
            } else {
                raw_alloc
            }
        } else {
            raw_alloc
        };
        if alloc <= 0.0 {
            return;
        }

        let entry_fee = alloc * self.config.fee_rate;
        let quantity = alloc / entry_price;

        self.balance -= alloc;
        self.current_entry_fee = entry_fee;
        self.total_fees += entry_fee;

        // D-08 capture: store the original SL distance once at entry so
        // the BE-trail can decide when +1R is reached even after the SL
        // has been pulled to entry. `None` SL means no BE trail fires.
        let initial_sl_distance = sl.map(|sl_price| (entry_price - sl_price).abs());

        self.position = Some(Position {
            entry_price,
            quantity,
            side,
            stop_loss: sl,
            take_profit: tp,
            entry_time: timestamp,
            initial_sl_distance,
            breakeven_applied: false,
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
    ///     `balance += alloc + net_pnl`
    ///     For LONGs this collapses algebraically to the older
    ///     `proceeds = exit_notional - exit_fee` expression; for SHORTs the
    ///     older expression drained balance by ~`2 * gross_pnl_short`.
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
        // `entry_notional = pos.quantity * entry_price` equals the full
        // allocation from open_position (since N-13 quantity is based on
        // full alloc, not alloc-minus-fee).
        self.balance += entry_notional + net_pnl;

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
    /// if the position closed at `current_price` right now.
    ///   entry_notional = quantity * entry_price (= full alloc from open,
    ///     since N-13 positions are notional-accurate)
    ///   equity = balance + entry_notional + unrealized - entry_fee - est_exit_fee
    fn current_equity(&self, current_price: f64) -> f64 {
        match &self.position {
            Some(pos) => {
                let entry_notional = pos.entry_price * pos.quantity;
                let unrealized = pos.unrealized_pnl(current_price);
                let est_exit_fee = pos.quantity * current_price * self.config.fee_rate;
                self.balance
                    + entry_notional
                    + unrealized
                    - self.current_entry_fee
                    - est_exit_fee
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
                    tp: None,
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
                    tp: Some(self.tp),
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
                        Some(Signal::EnterLong { sl: None, tp: None, size_pct: 100.0 })
                    }
                    2 if ctx.in_position => Some(Signal::Exit { reason: ExitReason::Signal("exit1".into()) }),
                    3 if !ctx.in_position => {
                        self.trade_num += 1;
                        Some(Signal::EnterLong { sl: None, tp: None, size_pct: 100.0 })
                    }
                    4 if ctx.in_position => Some(Signal::Exit { reason: ExitReason::Signal("exit2".into()) }),
                    _ => None,
                }
            }
            fn on_reset(&mut self) { self.trade_num = 0; }
        }

        // F-04: signals execute at next-bar OPEN. The strategy signals
        // Enter@i=1, Exit@i=2, Enter@i=3, Exit@i=4, so the four executions
        // land at candle[2].open, candle[3].open, candle[4].open, and
        // candle[5].open respectively. Original 5-candle fixture had no
        // candle[5]; extended to 6 candles so both trades close on their
        // pending Exit (not via EndOfData). Trade 1: 100→98 (loss).
        // Trade 2: 98→105 (win). Same shape as the pre-F-04 close-based
        // fixture, just sourced from different OHLC slots.
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0),  // trade 1 entry @ open=100
            candle(3000, 100.0, 101.0, 99.0, 100.0),  // signal Exit
            candle(4000, 98.0, 99.0, 97.0, 98.0),     // trade 1 exit @ open=98 (loss); signal Enter
            candle(5000, 98.0, 99.0, 97.0, 98.0),     // trade 2 entry @ open=98; signal Exit
            candle(6000, 105.0, 106.0, 104.0, 105.0), // trade 2 exit @ open=105 (win)
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
                    1 => Some(Signal::EnterShort { sl: None, tp: None, size_pct: 100.0 }),
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
        // F-04: FixedLongStrategy signals Enter@i=1 and Exit@i=3, so entry
        // fires at candle[2].open and exit at candle[4].open. The original
        // 4-candle fixture had no candle[4]; the new 5-candle fixture
        // assigns the entry/exit prices to candle[2].open / candle[4].open
        // (rather than the close of candle[1] / candle[3]) to preserve the
        // 50000 → 52000 trade the test was designed around.
        let candles = vec![
            candle(1000, 50000.0, 50100.0, 49900.0, 50000.0),
            candle(2000, 50000.0, 50100.0, 49900.0, 50000.0), // signal Enter
            candle(3000, 50000.0, 50100.0, 49900.0, 50000.0), // entry @ open=50000
            candle(4000, 51000.0, 51100.0, 50900.0, 51000.0), // signal Exit
            candle(5000, 52000.0, 52100.0, 51900.0, 52000.0), // exit  @ open=52000
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
                    1 => Some(Signal::EnterLong { sl: Some(90.0), tp: None, size_pct: 100.0 }),
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

    /// D-08 fixture-driven strategy used by the BE-trail regression tests.
    /// Emits a single long entry on bar 1 with the SL/TP passed at
    /// construction. Mirrors the SlTpStrategy helper but parametrises both
    /// bracket prices so the BE-trail conditions can be hit deterministically.
    struct EnterOnceLong {
        sl: f64,
        tp: f64,
    }
    impl StrategyAddin for EnterOnceLong {
        fn manifest(&self) -> crate::strategy::AddinManifest {
            crate::strategy::AddinManifest {
                id: "be_test".into(), name: "BE Test".into(),
                version: "0.1.0".into(), author: "test".into(),
                description: "test".into(),
                category: crate::strategy::StrategyCategory::Custom,
                timeframes: vec![Timeframe::H1], parameters: vec![],
            }
        }
        fn required_inputs(&self) -> Vec<crate::strategy::InputSpec> { vec![] }
        fn on_candle(&mut self, ctx: &mut Context, _candle: &Candle) -> Option<Signal> {
            if ctx.index() == 1 && !ctx.in_position {
                Some(Signal::EnterLong {
                    sl: Some(self.sl),
                    tp: Some(self.tp),
                    size_pct: 100.0,
                })
            } else {
                None
            }
        }
        fn on_reset(&mut self) {}
    }

    #[test]
    fn test_breakeven_trail_converts_retracement_to_zero_pnl_exit() {
        // D-08: long enters at 100, SL=90 (-10), TP=200 (well above any
        // bar). On bar 2 the high reaches 115 (+1.5R) so BE-trail pulls
        // SL to 100; same bar low retraces to 95. Pre-D-08 the engine
        // would have closed at the ORIGINAL SL=90 (or never, since 95>90
        // — but with SL-first priority on a fully-traversing bar
        // engagement). With the BE-trail + TP-first ordering, the trade
        // closes at BE = entry = 100 because low=95 ≤ new SL=100.
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // entry @ open=100, SL=90, TP=200
            candle(3000, 100.0, 115.0, 95.0, 105.0), // +1R touch + retrace to 95 → BE exit @100
            candle(4000, 105.0, 106.0, 104.0, 105.0),
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = EnterOnceLong { sl: 90.0, tp: 200.0 };
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        let trade = &result.metrics.trades[0];
        assert_eq!(trade.exit_reason, ExitReason::StopLoss);
        assert!(
            (trade.exit_price - 100.0).abs() < 1e-12,
            "BE-trail must pull SL to entry=100; got exit_price={}",
            trade.exit_price
        );
        assert!(
            trade.pnl.abs() < 1e-9,
            "BE exit at entry should produce ~zero PnL (no fees in this \
             test); got pnl={}",
            trade.pnl
        );
    }

    #[test]
    fn test_breakeven_trail_inactive_when_one_r_never_reached() {
        // Control: same setup but bar 2 NEVER touches +1R. The SL must
        // therefore stay at the original 90, and the low=89 hit closes
        // the trade at 90 (full SL loss). Pins that BE-trail is a strict
        // additive protection — it does not modify behaviour on bars that
        // don't satisfy the trigger condition.
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // entry @ 100, SL=90, TP=200
            candle(3000, 100.0, 109.5, 89.0, 95.0),  // high=109.5 < 110 (=entry+R), low=89 → SL
            candle(4000, 95.0, 96.0, 94.0, 95.0),
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = EnterOnceLong { sl: 90.0, tp: 200.0 };
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        let trade = &result.metrics.trades[0];
        assert_eq!(trade.exit_reason, ExitReason::StopLoss);
        assert!(
            (trade.exit_price - 90.0).abs() < 1e-12,
            "without +1R touch BE-trail must NOT fire; SL stays at 90, \
             got exit_price={}",
            trade.exit_price
        );
        assert!(trade.pnl < 0.0, "original-SL exit is a loss");
    }

    #[test]
    fn test_breakeven_trail_does_not_override_take_profit_same_bar() {
        // D-08 + D-06 interaction: on a bar where both TP and BE+SL would
        // fire, TP wins. Setup: long entry at 100, SL=90, TP=120. Bar 2
        // has high=125 (TP hit @120) AND low=95 (would hit BE-SL=100 if
        // BE fired first). TP-first priority closes the trade at 120
        // before the BE-trail can pull the SL down.
        let candles = vec![
            candle(1000, 100.0, 101.0, 99.0, 100.0),
            candle(2000, 100.0, 101.0, 99.0, 100.0), // entry @ 100, SL=90, TP=120
            candle(3000, 100.0, 125.0, 95.0, 115.0), // TP + retrace
            candle(4000, 115.0, 116.0, 114.0, 115.0),
        ];

        let config = BacktestConfig::new(10_000.0, 0.0, Timeframe::H1);
        let mut engine = BacktestEngine::new(config);
        let mut strategy = EnterOnceLong { sl: 90.0, tp: 120.0 };
        let result = engine.run(&mut strategy, &candles, HashMap::new());

        assert_eq!(result.metrics.total_trades, 1);
        let trade = &result.metrics.trades[0];
        assert_eq!(trade.exit_reason, ExitReason::TakeProfit);
        assert!((trade.exit_price - 120.0).abs() < 1e-12);
        assert!(trade.pnl > 0.0, "TP exit is a win");
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
