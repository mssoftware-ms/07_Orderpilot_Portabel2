/// Canonical trade and backtest-metrics models.
///
/// These are the single source of truth for trade results across the app.
/// Both the Dart backtest engine (lib/services/backtest_service.dart) and
/// the Rust FFI bridge (lib/services/rust_bridge.dart) must produce
/// instances of [BacktestMetrics] and [ClosedTrade] from this file —
/// see test/regression/f06_model_unification_test.dart.
library;

/// A single completed trade.
class ClosedTrade {
  /// Unix timestamp (ms, UTC) when the position was opened.
  final int entryTimestamp;

  /// Unix timestamp (ms, UTC) when the position was closed.
  final int exitTimestamp;

  /// Trade direction: `'LONG'` or `'SHORT'`.
  final String direction;

  final double entryPrice;
  final double exitPrice;
  final double quantity;

  /// Net P&L in quote currency (after fees).
  final double pnl;

  /// Net P&L as a percentage of entry notional.
  final double pnlPercent;

  /// Total fees paid (entry + exit), quote currency.
  final double fees;

  /// Human-readable reason for the exit (e.g. `'BB Middle'`, `'RSI Overbought'`).
  final String exitReason;

  const ClosedTrade({
    required this.entryTimestamp,
    required this.exitTimestamp,
    required this.direction,
    required this.entryPrice,
    required this.exitPrice,
    required this.quantity,
    required this.pnl,
    required this.pnlPercent,
    required this.fees,
    required this.exitReason,
  });

  bool get isWin => pnl > 0;
  bool get isLong => direction == 'LONG';
}

/// Aggregate backtest performance metrics.
class BacktestMetrics {
  final int totalTrades;
  final int winningTrades;
  final int losingTrades;
  final double winRate;
  final double profitFactor;
  final double totalPnl;
  final double totalPnlPercent;
  final double maxDrawdown;
  final double maxDrawdownPercent;
  final double sharpeRatio;
  final double totalFees;
  final int candlesProcessed;

  const BacktestMetrics({
    required this.totalTrades,
    required this.winningTrades,
    required this.losingTrades,
    required this.winRate,
    required this.profitFactor,
    required this.totalPnl,
    required this.totalPnlPercent,
    required this.maxDrawdown,
    required this.maxDrawdownPercent,
    required this.sharpeRatio,
    required this.totalFees,
    required this.candlesProcessed,
  });

  factory BacktestMetrics.empty() => const BacktestMetrics(
        totalTrades: 0,
        winningTrades: 0,
        losingTrades: 0,
        winRate: 0,
        profitFactor: 0,
        totalPnl: 0,
        totalPnlPercent: 0,
        maxDrawdown: 0,
        maxDrawdownPercent: 0,
        sharpeRatio: 0,
        totalFees: 0,
        candlesProcessed: 0,
      );
}
