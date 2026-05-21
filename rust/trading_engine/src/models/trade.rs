use serde::{Deserialize, Serialize};

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

    /// Compute metrics from a list of closed trades.
    pub fn from_trades(trades: Vec<ClosedTrade>, initial_capital: f64) -> Self {
        if trades.is_empty() {
            return Self::empty();
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
            f64::INFINITY
        } else {
            0.0
        };

        let total_pnl: f64 = trades.iter().map(|t| t.pnl).sum();
        let total_pnl_percent = total_pnl / initial_capital * 100.0;

        // Max drawdown calculation
        let mut equity = initial_capital;
        let mut peak = equity;
        let mut max_dd = 0.0_f64;
        for trade in &trades {
            equity += trade.pnl;
            if equity > peak {
                peak = equity;
            }
            let dd = peak - equity;
            if dd > max_dd {
                max_dd = dd;
            }
        }
        let max_drawdown_percent = if peak > 0.0 {
            max_dd / peak * 100.0
        } else {
            0.0
        };

        // Sharpe ratio
        let returns: Vec<f64> = trades.iter().map(|t| t.pnl_percent).collect();
        let mean_return = returns.iter().sum::<f64>() / returns.len() as f64;
        let variance = returns
            .iter()
            .map(|r| (r - mean_return).powi(2))
            .sum::<f64>()
            / returns.len() as f64;
        let std_dev = variance.sqrt();
        let sharpe_ratio = if std_dev > 0.0 {
            mean_return / std_dev
        } else {
            0.0
        };

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
