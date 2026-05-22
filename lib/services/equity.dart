/// Mid-trade equity formula (Plan-rev3 §3.4 F-03b).
///
/// Bit-for-bit mirror of Rust `BacktestEngine::current_equity`
/// (rust/.../backtest/mod.rs:349). When a position is open, equity must
/// restore the reserved margin (`alloc = entry_notional + entry_fee`) on
/// top of the post-entry balance — otherwise mid-trade equity goes
/// strongly negative and the equity-curve-based Sharpe / drawdown
/// computations diverge from the Rust engine.
///
///   equity = balance + alloc + unrealized_pnl - entry_fee - est_exit_fee
///
/// where:
///   alloc           = entry_price * quantity + entry_fee
///   unrealized_pnl  = (mark - entry) * quantity     (LONG)
///                   = (entry - mark) * quantity     (SHORT)
///   est_exit_fee    = mark_price * quantity * fee_rate
///
/// For a closed position (qty=0), this collapses to `balance`.
library;

double midTradeEquity({
  required double balance,
  required double entryPrice,
  required double quantity,
  required double entryFee,
  required double markPrice,
  required double feeRate,
  required bool isLong,
}) {
  final alloc = entryPrice * quantity + entryFee;
  final unrealized = isLong
      ? (markPrice - entryPrice) * quantity
      : (entryPrice - markPrice) * quantity;
  final estExitFee = markPrice * quantity * feeRate;
  return balance + alloc + unrealized - entryFee - estExitFee;
}
