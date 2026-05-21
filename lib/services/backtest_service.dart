/// Pure-Dart backtest engine implementing BB+RSI mean-reversion strategy.
///
/// This mirrors the Rust trading_engine logic so the Flutter UI can run
/// backtests without needing the native FFI bridge at runtime.
library;

import 'dart:math' as math;

import '../core/models/candle.dart';

// ─── Result models ──────────────────────────────────────────────────────────

/// A single point on the equity curve.
class EquityPoint {
  final int timestamp;
  final double equity;
  final double drawdown;
  final double drawdownPct;

  const EquityPoint({
    required this.timestamp,
    required this.equity,
    required this.drawdown,
    required this.drawdownPct,
  });
}

/// A completed trade record.
class TradeRecord {
  final int entryTimestamp;
  final int exitTimestamp;
  final String direction; // 'LONG' or 'SHORT'
  final double entryPrice;
  final double exitPrice;
  final double quantity;
  final double pnl;
  final double pnlPercent;
  final double fees;
  final String exitReason;

  const TradeRecord({
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
}

/// Complete backtest result.
class BacktestResult {
  final BacktestMetrics metrics;
  final List<EquityPoint> equityCurve;
  final List<TradeRecord> trades;

  const BacktestResult({
    required this.metrics,
    required this.equityCurve,
    required this.trades,
  });
}

// ─── BB+RSI Strategy Parameters ─────────────────────────────────────────────

class BbRsiParams {
  final int bbPeriod;
  final double bbStdDev;
  final int rsiPeriod;
  final double rsiOversold;
  final double rsiOverbought;

  const BbRsiParams({
    this.bbPeriod = 20,
    this.bbStdDev = 2.0,
    this.rsiPeriod = 14,
    this.rsiOversold = 30.0,
    this.rsiOverbought = 70.0,
  });
}

// ─── Internal position tracking ─────────────────────────────────────────────

class _OpenPosition {
  final bool isLong;
  final double entryPrice;
  final double quantity;
  final int entryTimestamp;
  final double entryFee;

  _OpenPosition({
    required this.isLong,
    required this.entryPrice,
    required this.quantity,
    required this.entryTimestamp,
    required this.entryFee,
  });
}

// ─── Backtest Engine ────────────────────────────────────────────────────────

class BacktestService {
  /// Run a BB+RSI backtest on the given candle data.
  static BacktestResult runBbRsi({
    required List<CandleData> candles,
    required double initialBalance,
    required double feeRate,
    BbRsiParams params = const BbRsiParams(),
  }) {
    if (candles.length < params.bbPeriod + 1) {
      return BacktestResult(
        metrics: BacktestMetrics(
          totalTrades: 0, winningTrades: 0, losingTrades: 0,
          winRate: 0, profitFactor: 0, totalPnl: 0, totalPnlPercent: 0,
          maxDrawdown: 0, maxDrawdownPercent: 0, sharpeRatio: 0,
          totalFees: 0, candlesProcessed: candles.length,
        ),
        equityCurve: [],
        trades: [],
      );
    }

    // Pre-compute indicators
    final closes = candles.map((c) => c.close).toList();
    final bbUpper = List<double>.filled(candles.length, 0);
    final bbMiddle = List<double>.filled(candles.length, 0);
    final bbLower = List<double>.filled(candles.length, 0);
    final rsiValues = List<double>.filled(candles.length, 50);

    // Bollinger Bands (SMA + stddev)
    for (int i = params.bbPeriod - 1; i < candles.length; i++) {
      double sum = 0;
      for (int j = i - params.bbPeriod + 1; j <= i; j++) {
        sum += closes[j];
      }
      final sma = sum / params.bbPeriod;
      double variance = 0;
      for (int j = i - params.bbPeriod + 1; j <= i; j++) {
        final diff = closes[j] - sma;
        variance += diff * diff;
      }
      final stdDev = math.sqrt(variance / params.bbPeriod);
      bbMiddle[i] = sma;
      bbUpper[i] = sma + params.bbStdDev * stdDev;
      bbLower[i] = sma - params.bbStdDev * stdDev;
    }

    // RSI (Wilder's smoothing)
    _computeRsi(closes, params.rsiPeriod, rsiValues);

    // Strategy execution
    double balance = initialBalance;
    double peakEquity = initialBalance;
    double maxDrawdown = 0;
    double maxDrawdownPct = 0;
    double totalFees = 0;
    _OpenPosition? position;

    final trades = <TradeRecord>[];
    final equityCurve = <EquityPoint>[];
    final returns = <double>[];
    double prevEquity = initialBalance;

    final startIdx = math.max(params.bbPeriod, params.rsiPeriod + 1);

    for (int i = 0; i < candles.length; i++) {
      final candle = candles[i];

      // Current equity (mark-to-market)
      double equity = balance;
      if (position != null) {
        final unrealizedPnl = position.isLong
            ? (candle.close - position.entryPrice) * position.quantity
            : (position.entryPrice - candle.close) * position.quantity;
        equity += unrealizedPnl;
      }

      // Track drawdown
      if (equity > peakEquity) peakEquity = equity;
      final dd = peakEquity - equity;
      final ddPct = peakEquity > 0 ? (dd / peakEquity) * 100 : 0.0;
      if (dd > maxDrawdown) maxDrawdown = dd;
      if (ddPct > maxDrawdownPct) maxDrawdownPct = ddPct;

      equityCurve.add(EquityPoint(
        timestamp: candle.timestamp,
        equity: equity,
        drawdown: dd,
        drawdownPct: ddPct,
      ));

      // Track returns for Sharpe
      if (i > 0) {
        final ret = prevEquity > 0 ? (equity - prevEquity) / prevEquity : 0.0;
        returns.add(ret);
      }
      prevEquity = equity;

      // Skip until indicators are warmed up
      if (i < startIdx) continue;

      // --- Strategy logic ---
      final close = candle.close;
      final rsi = rsiValues[i];
      final lower = bbLower[i];
      final middle = bbMiddle[i];
      final upper = bbUpper[i];

      if (position == null) {
        // Entry: price below lower BB AND RSI oversold → LONG
        if (close <= lower && rsi < params.rsiOversold) {
          final fee = balance * feeRate;
          final availableBalance = balance - fee;
          final qty = availableBalance / close;
          position = _OpenPosition(
            isLong: true,
            entryPrice: close,
            quantity: qty,
            entryTimestamp: candle.timestamp,
            entryFee: fee,
          );
          balance = 0;
          totalFees += fee;
        }
        // Entry: price above upper BB AND RSI overbought → SHORT
        else if (close >= upper && rsi > params.rsiOverbought) {
          final notional = balance;
          final fee = notional * feeRate;
          final qty = (notional - fee) / close;
          position = _OpenPosition(
            isLong: false,
            entryPrice: close,
            quantity: qty,
            entryTimestamp: candle.timestamp,
            entryFee: fee,
          );
          balance = 0;
          totalFees += fee;
        }
      } else {
        // Exit conditions
        String? exitReason;

        if (position.isLong) {
          if (close >= middle) exitReason = 'BB Middle';
          if (rsi > params.rsiOverbought) exitReason = 'RSI Overbought';
        } else {
          if (close <= middle) exitReason = 'BB Middle';
          if (rsi < params.rsiOversold) exitReason = 'RSI Oversold';
        }

        if (exitReason != null) {
          final exitNotional = position.quantity * close;
          final exitFee = exitNotional * feeRate;
          totalFees += exitFee;

          final grossPnl = position.isLong
              ? (close - position.entryPrice) * position.quantity
              : (position.entryPrice - close) * position.quantity;
          final netPnl = grossPnl - position.entryFee - exitFee;
          final entryNotional = position.entryPrice * position.quantity;
          final pnlPct = entryNotional > 0 ? (netPnl / entryNotional) * 100 : 0.0;

          balance = exitNotional - exitFee;
          // For short: balance = initial notional + gross pnl - fees
          if (!position.isLong) {
            balance = position.entryPrice * position.quantity + grossPnl -
                position.entryFee - exitFee;
          }

          trades.add(TradeRecord(
            entryTimestamp: position.entryTimestamp,
            exitTimestamp: candle.timestamp,
            direction: position.isLong ? 'LONG' : 'SHORT',
            entryPrice: position.entryPrice,
            exitPrice: close,
            quantity: position.quantity,
            pnl: netPnl,
            pnlPercent: pnlPct,
            fees: position.entryFee + exitFee,
            exitReason: exitReason,
          ));
          position = null;
        }
      }
    }

    // Close any remaining position at last candle
    if (position != null && candles.isNotEmpty) {
      final lastCandle = candles.last;
      final exitNotional = position.quantity * lastCandle.close;
      final exitFee = exitNotional * feeRate;
      totalFees += exitFee;
      final grossPnl = position.isLong
          ? (lastCandle.close - position.entryPrice) * position.quantity
          : (position.entryPrice - lastCandle.close) * position.quantity;
      final netPnl = grossPnl - position.entryFee - exitFee;
      final entryNotional = position.entryPrice * position.quantity;
      final pnlPct = entryNotional > 0 ? (netPnl / entryNotional) * 100 : 0.0;

      if (!position.isLong) {
        balance = position.entryPrice * position.quantity + grossPnl -
            position.entryFee - exitFee;
      } else {
        balance = exitNotional - exitFee;
      }

      trades.add(TradeRecord(
        entryTimestamp: position.entryTimestamp,
        exitTimestamp: lastCandle.timestamp,
        direction: position.isLong ? 'LONG' : 'SHORT',
        entryPrice: position.entryPrice,
        exitPrice: lastCandle.close,
        quantity: position.quantity,
        pnl: netPnl,
        pnlPercent: pnlPct,
        fees: position.entryFee + exitFee,
        exitReason: 'End of Data',
      ));
    }

    // Compute aggregate metrics
    final winningTrades = trades.where((t) => t.pnl > 0).toList();
    final losingTrades = trades.where((t) => t.pnl <= 0).toList();
    final totalPnl = trades.fold<double>(0, (s, t) => s + t.pnl);
    final totalPnlPct = initialBalance > 0 ? (totalPnl / initialBalance) * 100 : 0.0;
    final winRate = trades.isNotEmpty
        ? (winningTrades.length / trades.length) * 100
        : 0.0;

    final grossProfit = winningTrades.fold<double>(0, (s, t) => s + t.pnl);
    final grossLoss = losingTrades.fold<double>(0, (s, t) => s + t.pnl.abs());
    double profitFactor = grossLoss > 0 ? grossProfit / grossLoss : 0;
    if (profitFactor > 999.99) profitFactor = 999.99;
    if (grossLoss == 0 && grossProfit > 0) profitFactor = 999.99;

    // Sharpe ratio (annualized)
    double sharpe = 0;
    if (returns.length > 1) {
      final meanReturn = returns.reduce((a, b) => a + b) / returns.length;
      final variance = returns.fold<double>(
              0, (s, r) => s + (r - meanReturn) * (r - meanReturn)) /
          returns.length;
      final stdDev = math.sqrt(variance);
      if (stdDev > 0) {
        sharpe = (meanReturn / stdDev) * math.sqrt(252);
      }
    }

    return BacktestResult(
      metrics: BacktestMetrics(
        totalTrades: trades.length,
        winningTrades: winningTrades.length,
        losingTrades: losingTrades.length,
        winRate: winRate,
        profitFactor: profitFactor,
        totalPnl: totalPnl,
        totalPnlPercent: totalPnlPct,
        maxDrawdown: maxDrawdown,
        maxDrawdownPercent: maxDrawdownPct,
        sharpeRatio: sharpe,
        totalFees: totalFees,
        candlesProcessed: candles.length,
      ),
      equityCurve: equityCurve,
      trades: trades,
    );
  }

  /// Compute RSI using Wilder's smoothing method.
  static void _computeRsi(
      List<double> closes, int period, List<double> output) {
    if (closes.length < period + 1) return;

    // Initial average gain/loss
    double avgGain = 0, avgLoss = 0;
    for (int i = 1; i <= period; i++) {
      final change = closes[i] - closes[i - 1];
      if (change > 0) {
        avgGain += change;
      } else {
        avgLoss += change.abs();
      }
    }
    avgGain /= period;
    avgLoss /= period;

    output[period] = avgLoss == 0 ? 100 : 100 - (100 / (1 + avgGain / avgLoss));

    // Wilder's smoothing
    for (int i = period + 1; i < closes.length; i++) {
      final change = closes[i] - closes[i - 1];
      final gain = change > 0 ? change : 0.0;
      final loss = change < 0 ? change.abs() : 0.0;
      avgGain = (avgGain * (period - 1) + gain) / period;
      avgLoss = (avgLoss * (period - 1) + loss) / period;
      output[i] = avgLoss == 0 ? 100 : 100 - (100 / (1 + avgGain / avgLoss));
    }
  }
}
