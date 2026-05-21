/// Represents a closed trade for backtest results
class ClosedTrade {
  final int entryTime;
  final int exitTime;
  final double entryPrice;
  final double exitPrice;
  final double quantity;
  final double pnl;
  final double pnlPercent;
  final String exitReason;
  final bool isLong;

  const ClosedTrade({
    required this.entryTime,
    required this.exitTime,
    required this.entryPrice,
    required this.exitPrice,
    required this.quantity,
    required this.pnl,
    required this.pnlPercent,
    required this.exitReason,
    required this.isLong,
  });
}

/// Backtest performance metrics
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
  final double avgTradeDuration;
  final double largestWin;
  final double largestLoss;
  final List<ClosedTrade> trades;

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
    required this.avgTradeDuration,
    required this.largestWin,
    required this.largestLoss,
    required this.trades,
  });

  factory BacktestMetrics.empty() {
    return const BacktestMetrics(
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
      avgTradeDuration: 0,
      largestWin: 0,
      largestLoss: 0,
      trades: [],
    );
  }
}
