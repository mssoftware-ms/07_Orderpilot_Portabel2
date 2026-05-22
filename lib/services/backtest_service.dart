/// Pure-Dart backtest engine implementing BB+RSI mean-reversion strategy.
///
/// This mirrors the Rust trading_engine logic so the Flutter UI can run
/// backtests without needing the native FFI bridge at runtime.
library;

import 'dart:math' as math;

import '../core/models/candle.dart';
import '../core/models/timeframe.dart';
import '../core/models/trade.dart';
import 'equity.dart';
import 'sharpe.dart';

// ─── Engine-specific result models ──────────────────────────────────────────
// Trade and metrics types are imported from lib/core/models/trade.dart —
// see F-06 (test/regression/f06_model_unification_test.dart).

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

/// Complete backtest result.
class BacktestResult {
  final BacktestMetrics metrics;
  final List<EquityPoint> equityCurve;
  final List<ClosedTrade> trades;

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

  /// Absolute stop-loss price (null = no SL attached at entry).
  /// Mirrors `Position::stop_loss` in the Rust engine.
  final double? stopLoss;

  /// Absolute take-profit price (null = no TP attached at entry).
  /// Mirrors `Position::take_profit` in the Rust engine.
  final double? takeProfit;

  _OpenPosition({
    required this.isLong,
    required this.entryPrice,
    required this.quantity,
    required this.entryTimestamp,
    required this.entryFee,
    this.stopLoss,
    this.takeProfit,
  });
}

// ─── Backtest Engine ────────────────────────────────────────────────────────

class BacktestService {
  /// Run a BB+RSI backtest on the given candle data.
  ///
  /// `timeframe` defaults to [Timeframe.h1] for backward compatibility with
  /// the parity fixture; pass the actual candle timeframe to get a correct
  /// annualized Sharpe (Plan §3.4 F-03).
  static BacktestResult runBbRsi({
    required List<CandleData> candles,
    required double initialBalance,
    required double feeRate,
    BbRsiParams params = const BbRsiParams(),
    Timeframe timeframe = Timeframe.h1,
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

    final trades = <ClosedTrade>[];
    final equityCurve = <EquityPoint>[];
    final returns = <double>[];
    double prevEquity = initialBalance;

    final startIdx = math.max(params.bbPeriod, params.rsiPeriod + 1);

    for (int i = 0; i < candles.length; i++) {
      final candle = candles[i];

      // F-03b: trade/strategy logic runs FIRST in each bar, then equity is
      // recorded against the post-trade position state — mirrors Rust
      // BacktestEngine::run step order (rust/.../backtest/mod.rs:154-235:
      // SL/TP → strategy → record equity). The pre-F-03b Dart loop sampled
      // equity at bar-start, which silently diverged from Rust on any bar
      // where SL/TP closed a position.
      //
      // --- Strategy logic (skipped during indicator warm-up) ---
      if (i >= startIdx) {
        final close = candle.close;
        final rsi = rsiValues[i];
        final lower = bbLower[i];
        final middle = bbMiddle[i];
        final upper = bbUpper[i];

        if (position == null) {
        // Entry: price below lower BB AND RSI oversold → LONG
        // SL/TP mirror Rust BbRsiStrategy::on_candle (bb_rsi.rs:224):
        //   long SL = lower - (middle - lower) = 2*lower - middle
        //   long TP = middle
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
            stopLoss: 2 * lower - middle,
            takeProfit: middle,
          );
          balance = 0;
          totalFees += fee;
        }
        // Entry: price above upper BB AND RSI overbought → SHORT
        // SL/TP mirror Rust BbRsiStrategy::on_candle (bb_rsi.rs:232):
        //   short SL = upper + (upper - middle) = 2*upper - middle
        //   short TP = middle
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
            stopLoss: 2 * upper - middle,
            takeProfit: middle,
          );
          balance = 0;
          totalFees += fee;
        }
      } else {
        // Exit logic — F-02 priority: intra-candle SL/TP first, then the
        // indicator-based BB-middle / RSI exits. Mirrors the step order in
        // Rust BacktestEngine::run (backtest/mod.rs:158-217).
        String? exitReason;
        double exitPrice = close;

        if (position.isLong) {
          // Long SL = candle.low ≤ SL; ambiguous SL+TP → SL wins (conservative).
          final slHit =
              position.stopLoss != null && candle.low <= position.stopLoss!;
          final tpHit = position.takeProfit != null &&
              candle.high >= position.takeProfit!;
          if (slHit) {
            exitReason = 'StopLoss';
            exitPrice = position.stopLoss!;
          } else if (tpHit) {
            exitReason = 'TakeProfit';
            exitPrice = position.takeProfit!;
          } else if (close >= middle) {
            exitReason = 'BB Middle';
          } else if (rsi > params.rsiOverbought) {
            exitReason = 'RSI Overbought';
          }
        } else {
          // Short SL = candle.high ≥ SL; short TP = candle.low ≤ TP.
          final slHit =
              position.stopLoss != null && candle.high >= position.stopLoss!;
          final tpHit = position.takeProfit != null &&
              candle.low <= position.takeProfit!;
          if (slHit) {
            exitReason = 'StopLoss';
            exitPrice = position.stopLoss!;
          } else if (tpHit) {
            exitReason = 'TakeProfit';
            exitPrice = position.takeProfit!;
          } else if (close <= middle) {
            exitReason = 'BB Middle';
          } else if (rsi < params.rsiOversold) {
            exitReason = 'RSI Oversold';
          }
        }

        if (exitReason != null) {
          final exitNotional = position.quantity * exitPrice;
          final exitFee = exitNotional * feeRate;
          totalFees += exitFee;

          final grossPnl = position.isLong
              ? (exitPrice - position.entryPrice) * position.quantity
              : (position.entryPrice - exitPrice) * position.quantity;
          final netPnl = grossPnl - position.entryFee - exitFee;
          final entryNotional = position.entryPrice * position.quantity;
          final pnlPct = entryNotional > 0 ? (netPnl / entryNotional) * 100 : 0.0;

          // Direction-agnostic balance update (F-02c): return reserved margin
          // (alloc = entry_notional + entry_fee) plus realised net P&L. For
          // LONGs this collapses algebraically to `exitNotional - exitFee`;
          // for SHORTs the previous branch missed one entry_fee per close.
          final alloc = entryNotional + position.entryFee;
          balance = alloc + netPnl;

          trades.add(ClosedTrade(
            entryTimestamp: position.entryTimestamp,
            exitTimestamp: candle.timestamp,
            direction: position.isLong ? 'LONG' : 'SHORT',
            entryPrice: position.entryPrice,
            exitPrice: exitPrice,
            quantity: position.quantity,
            pnl: netPnl,
            pnlPercent: pnlPct,
            fees: position.entryFee + exitFee,
            exitReason: exitReason,
          ));
          position = null;
        }
      }
      } // end: if (i >= startIdx) — strategy block

      // --- Equity, drawdown, returns: recorded against POST-trade state ---
      // F-03b mirror of Rust BacktestEngine::current_equity. When the
      // position is open, equity restores the reserved margin and deducts
      // an estimated exit fee at the current mark, matching the Rust
      // engine bit-for-bit (rust/.../backtest/mod.rs:349-359).
      final double equity;
      if (position == null) {
        equity = balance;
      } else {
        equity = midTradeEquity(
          balance: balance,
          entryPrice: position.entryPrice,
          quantity: position.quantity,
          entryFee: position.entryFee,
          markPrice: candle.close,
          feeRate: feeRate,
          isLong: position.isLong,
        );
      }

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

      if (i > 0) {
        final ret = prevEquity > 0 ? (equity - prevEquity) / prevEquity : 0.0;
        returns.add(ret);
      }
      prevEquity = equity;
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

      // Same direction-agnostic balance update as the in-loop exit branch
      // (F-02c). Mirrors close_position in rust/.../backtest/mod.rs.
      final alloc = entryNotional + position.entryFee;
      balance = alloc + netPnl;

      trades.add(ClosedTrade(
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

    // Sharpe ratio (F-03): timeframe-aware annualization over equity-curve
    // returns. Identical formula to rust/.../models/metrics.rs, so the two
    // engines produce numerically equivalent Sharpe values on the same
    // candle stream + timeframe.
    final sharpe = annualizedSharpe(returns, timeframe);

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
