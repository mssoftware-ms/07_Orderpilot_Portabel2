use serde::{Deserialize, Serialize};

use crate::models::{
    annualized_sharpe, equity_curve_returns, max_drawdown_from_equity_curve, Timeframe,
};

/// Side of a trading position.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PositionSide {
    Long,
    Short,
}

/// Reason why a trade was exited.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ExitReason {
    StopLoss,
    TakeProfit,
    Signal(String),
    Manual,
    EndOfData,
}

impl std::fmt::Display for ExitReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExitReason::StopLoss => write!(f, "Stop Loss"),
            ExitReason::TakeProfit => write!(f, "Take Profit"),
            ExitReason::Signal(reason) => write!(f, "Signal: {}", reason),
            ExitReason::Manual => write!(f, "Manual"),
            ExitReason::EndOfData => write!(f, "End of Data"),
        }
    }
}

/// An open trading position.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Position {
    /// Entry price.
    pub entry_price: f64,
    /// Position quantity.
    pub quantity: f64,
    /// Position side (Long or Short).
    pub side: PositionSide,
    /// Stop loss price (absolute).
    pub stop_loss: Option<f64>,
    /// Take profit price (absolute).
    pub take_profit: Option<f64>,
    /// Timestamp of entry (Unix ms).
    pub entry_time: i64,
}

impl Position {
    /// Calculate unrealized PnL at a given price.
    pub fn unrealized_pnl(&self, current_price: f64) -> f64 {
        match self.side {
            PositionSide::Long => (current_price - self.entry_price) * self.quantity,
            PositionSide::Short => (self.entry_price - current_price) * self.quantity,
        }
    }

    /// Check if stop loss has been hit.
    pub fn is_stop_hit(&self, candle_low: f64, candle_high: f64) -> bool {
        match (self.side, self.stop_loss) {
            (PositionSide::Long, Some(sl)) => candle_low <= sl,
            (PositionSide::Short, Some(sl)) => candle_high >= sl,
            _ => false,
        }
    }

    /// Check if take profit has been hit.
    pub fn is_tp_hit(&self, candle_low: f64, candle_high: f64) -> bool {
        match (self.side, self.take_profit) {
            (PositionSide::Long, Some(tp)) => candle_high >= tp,
            (PositionSide::Short, Some(tp)) => candle_low <= tp,
            _ => false,
        }
    }
}

/// A completed (closed) trade with realized PnL.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClosedTrade {
    /// Timestamp of entry (Unix ms).
    pub entry_time: i64,
    /// Timestamp of exit (Unix ms).
    pub exit_time: i64,
    /// Entry price.
    pub entry_price: f64,
    /// Exit price.
    pub exit_price: f64,
    /// Trade quantity.
    pub quantity: f64,
    /// Position side.
    pub side: PositionSide,
    /// Net profit/loss after fees.
    pub pnl: f64,
    /// PnL as a percentage of entry notional.
    pub pnl_percent: f64,
    /// Reason for exit.
    pub exit_reason: ExitReason,
}

impl ClosedTrade {
    /// Returns whether this was a winning trade.
    pub fn is_winner(&self) -> bool {
        self.pnl > 0.0
    }

    /// Returns whether this was a long trade.
    pub fn is_long(&self) -> bool {
        self.side == PositionSide::Long
    }
}

/// Aggregate performance metrics from a backtest.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BacktestMetrics {
    pub total_trades: usize,
    pub winning_trades: usize,
    pub losing_trades: usize,
    pub win_rate: f64,
    pub profit_factor: f64,
    pub total_pnl: f64,
    pub total_pnl_percent: f64,
    pub max_drawdown: f64,
    pub max_drawdown_percent: f64,
    pub sharpe_ratio: f64,
    pub avg_trade_duration_ms: f64,
    pub largest_win: f64,
    pub largest_loss: f64,
    pub trades: Vec<ClosedTrade>,
}

impl BacktestMetrics {
    /// Create empty metrics (initial state).
    pub fn empty() -> Self {
        Self {
            total_trades: 0,
            winning_trades: 0,
            losing_trades: 0,
            win_rate: 0.0,
            profit_factor: 0.0,
            total_pnl: 0.0,
            total_pnl_percent: 0.0,
            max_drawdown: 0.0,
            max_drawdown_percent: 0.0,
            sharpe_ratio: 0.0,
            avg_trade_duration_ms: 0.0,
            largest_win: 0.0,
            largest_loss: 0.0,
            trades: Vec::new(),
        }
    }

    /// Compute metrics from a list of closed trades and the per-candle equity
    /// curve.
    ///
    /// `equity_curve` and `timeframe` are required for the annualized Sharpe
    /// (Plan §3.4 F-03): Sharpe is computed over **equity-curve returns**, not
    /// trade-PnL percentages, and is annualized by
    /// `sqrt(periods_per_year(timeframe))` on the Crypto 24/7 calendar.
    pub fn from_trades(
        trades: Vec<ClosedTrade>,
        initial_capital: f64,
        equity_curve: &[f64],
        timeframe: Timeframe,
    ) -> Self {
        if trades.is_empty() {
            // Still compute Sharpe — a flat equity curve yields 0, but a
            // strategy that takes no trades but holds inventory (not in this
            // engine yet) could in principle have a non-zero one. Cheap.
            let returns = equity_curve_returns(equity_curve);
            return Self {
                sharpe_ratio: annualized_sharpe(&returns, timeframe),
                ..Self::empty()
            };
        }

        let total_trades = trades.len();
        let winning_trades = trades.iter().filter(|t| t.is_winner()).count();
        let losing_trades = total_trades - winning_trades;
        let win_rate = winning_trades as f64 / total_trades as f64 * 100.0;

        let gross_profit: f64 = trades.iter().filter(|t| t.pnl > 0.0).map(|t| t.pnl).sum();
        let gross_loss: f64 = trades
            .iter()
            .filter(|t| t.pnl < 0.0)
            .map(|t| t.pnl.abs())
            .sum();
        let profit_factor = if gross_loss > 0.0 {
            gross_profit / gross_loss
        } else if gross_profit > 0.0 {
            999.99 // Cap for JSON serialization (no losses = effectively infinite)
        } else {
            0.0
        };

        let total_pnl: f64 = trades.iter().map(|t| t.pnl).sum();
        let total_pnl_percent = total_pnl / initial_capital * 100.0;

        // Max drawdown (F-03c): industry-standard running-peak formula over
        // the per-candle equity curve, matching the Dart engine bit-exact
        // (lib/services/backtest_service.dart:322-326). The pre-F-03c code
        // walked settled trade PnL only, which silently ignored open-position
        // intra-trade equity excursions and diverged from Dart by ~30x on
        // the parity fixture (28.75 vs 951.47). See Plan-rev3 §3.4 F-03c.
        let (max_dd, max_drawdown_percent) =
            max_drawdown_from_equity_curve(equity_curve);

        // Sharpe ratio (F-03): annualized over equity-curve returns,
        // NOT trade-PnL percentages. Identical formula to the Dart engine.
        let returns = equity_curve_returns(equity_curve);
        let sharpe_ratio = annualized_sharpe(&returns, timeframe);

        // Trade duration
        let total_duration: f64 = trades
            .iter()
            .map(|t| (t.exit_time - t.entry_time) as f64)
            .sum();
        let avg_trade_duration_ms = total_duration / total_trades as f64;

        let largest_win = trades
            .iter()
            .map(|t| t.pnl)
            .fold(f64::NEG_INFINITY, f64::max);
        let largest_loss = trades
            .iter()
            .map(|t| t.pnl)
            .fold(f64::INFINITY, f64::min);

        Self {
            total_trades,
            winning_trades,
            losing_trades,
            win_rate,
            profit_factor,
            total_pnl,
            total_pnl_percent,
            max_drawdown: max_dd,
            max_drawdown_percent,
            sharpe_ratio,
            avg_trade_duration_ms,
            largest_win,
            largest_loss,
            trades,
        }
    }
}
