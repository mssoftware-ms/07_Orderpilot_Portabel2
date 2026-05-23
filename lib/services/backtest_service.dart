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

/// Moving-average basis for the Bollinger Bands middle line.
///
/// Encoded numerically when forwarded to the Rust engine
/// (`bb_ma_type` strategy parameter: 0=SMA, 1=EMA) so it round-trips
/// through the f64-typed parameter map. The stddev component is
/// independent of the basis (always window-SMA stddev) so band-width is
/// comparable across MA-type switches — see
/// `calc_bollinger_bands_ema` in `rust/trading_engine/src/addins/bb_rsi.rs`.
enum BbMaType {
  /// Simple Moving Average basis (default, backwards-compatible).
  sma(0.0),

  /// Exponential Moving Average basis (Phase-2 video-spec trend filter).
  ema(1.0);

  const BbMaType(this.rustParamValue);

  /// Numeric encoding sent to the Rust engine's `bb_ma_type` parameter.
  final double rustParamValue;
}

class BbRsiParams {
  final int bbPeriod;
  final double bbStdDev;

  /// Basis MA type for the BB middle line. Default [BbMaType.sma] keeps
  /// the legacy Phase-1 behavior bit-exact; the upcoming video-spec
  /// trend filter (Diff D-01) uses [BbMaType.ema].
  final BbMaType bbMaType;

  final int rsiPeriod;
  final double rsiOversold;
  final double rsiOverbought;

  /// One-side slippage in basis points applied at each execution
  /// (entry and exit) against the trader. Plan rev2 §3.4 F-04 sets the
  /// default to 0 bps for Binance / Bitunix BTC + ETH at retail size;
  /// raise for thin alts or large orders. Must match the Rust
  /// BacktestConfig.slippage_bps for Dart↔Rust parity.
  final double slippageBps;

  const BbRsiParams({
    this.bbPeriod = 20,
    this.bbStdDev = 2.0,
    this.bbMaType = BbMaType.sma,
    this.rsiPeriod = 14,
    this.rsiOversold = 30.0,
    this.rsiOverbought = 70.0,
    this.slippageBps = 0.0,
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

// ─── Pending order (F-04 next-bar-open execution) ────────────────────────────

/// A trade decision made at bar `i`, filled at bar `i+1`'s open. Plan §3.4
/// F-04: strategy signals must NOT execute at the bar that produced them
/// (that uses information unavailable at order-send time — look-ahead).
sealed class _PendingOrder {}

class _PendingEnterLong extends _PendingOrder {
  final double stopLoss;
  final double takeProfit;
  _PendingEnterLong(this.stopLoss, this.takeProfit);
}

class _PendingEnterShort extends _PendingOrder {
  final double stopLoss;
  final double takeProfit;
  _PendingEnterShort(this.stopLoss, this.takeProfit);
}

class _PendingExit extends _PendingOrder {
  final String reason;
  _PendingExit(this.reason);
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

    // Bollinger Bands.
    //
    // The stddev component always uses the window-SMA of the last
    // `bbPeriod` closes — independent of `bbMaType` — so band-width is
    // comparable when switching between SMA and EMA basis. Mirrors
    // `calc_bollinger_bands_ema` in
    // `rust/trading_engine/src/addins/bb_rsi.rs`.
    //
    // For EMA basis the running EMA is maintained cumulatively (O(N))
    // instead of being recomputed from scratch per bar (O(N²)). The
    // first valid bar is `bbPeriod - 1`; the EMA at that bar equals the
    // SMA seed (no recursive step yet).
    final emaAlpha = 2.0 / (params.bbPeriod + 1);
    double emaBasis = 0.0;
    for (int i = params.bbPeriod - 1; i < candles.length; i++) {
      // Window-SMA stddev (shared between SMA-BB and EMA-BB branches).
      double sumWindow = 0;
      for (int j = i - params.bbPeriod + 1; j <= i; j++) {
        sumWindow += closes[j];
      }
      final smaWindow = sumWindow / params.bbPeriod;
      double variance = 0;
      for (int j = i - params.bbPeriod + 1; j <= i; j++) {
        final diff = closes[j] - smaWindow;
        variance += diff * diff;
      }
      final stdDev = math.sqrt(variance / params.bbPeriod);

      final double basis;
      if (params.bbMaType == BbMaType.sma) {
        basis = smaWindow;
      } else {
        if (i == params.bbPeriod - 1) {
          // Seed: SMA of the first `bbPeriod` closes
          emaBasis = smaWindow;
        } else {
          emaBasis = emaAlpha * closes[i] + (1 - emaAlpha) * emaBasis;
        }
        basis = emaBasis;
      }

      bbMiddle[i] = basis;
      bbUpper[i] = basis + params.bbStdDev * stdDev;
      bbLower[i] = basis - params.bbStdDev * stdDev;
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
    _PendingOrder? pending;

    final trades = <ClosedTrade>[];
    final equityCurve = <EquityPoint>[];
    final returns = <double>[];
    double prevEquity = initialBalance;

    final startIdx = math.max(params.bbPeriod, params.rsiPeriod + 1);
    final slipFactor = params.slippageBps / 10000.0;

    // Local helper: close the open position at `exitPrice` and record the
    // ClosedTrade. Direction-agnostic balance update mirrors close_position
    // in rust/.../backtest/mod.rs:311-348 bit-exact (F-02c).
    void closePosition(double exitPrice, int exitTs, String reason) {
      final pos = position!;
      final exitNotional = pos.quantity * exitPrice;
      final exitFee = exitNotional * feeRate;
      totalFees += exitFee;

      final grossPnl = pos.isLong
          ? (exitPrice - pos.entryPrice) * pos.quantity
          : (pos.entryPrice - exitPrice) * pos.quantity;
      final netPnl = grossPnl - pos.entryFee - exitFee;
      final entryNotional = pos.entryPrice * pos.quantity;
      final pnlPct = entryNotional > 0 ? (netPnl / entryNotional) * 100 : 0.0;
      final alloc = entryNotional + pos.entryFee;
      balance = alloc + netPnl;

      trades.add(ClosedTrade(
        entryTimestamp: pos.entryTimestamp,
        exitTimestamp: exitTs,
        direction: pos.isLong ? 'LONG' : 'SHORT',
        entryPrice: pos.entryPrice,
        exitPrice: exitPrice,
        quantity: pos.quantity,
        pnl: netPnl,
        pnlPercent: pnlPct,
        fees: pos.entryFee + exitFee,
        exitReason: reason,
      ));
      position = null;
    }

    for (int i = 0; i < candles.length; i++) {
      final candle = candles[i];

      // F-04 bar order: A pending → B SL/TP intra-bar → C strategy decisions
      // queue new pending → D equity. Mirrors rust/.../backtest/mod.rs::run
      // exactly so the parity test stays bit-identical to 1e-9.

      // ── Step A: Execute pending order at this bar's OPEN (F-04). ──
      // The decision was made at the previous bar's close; the fill happens
      // at this bar's open with one-side slippage against the trader.
      if (pending != null) {
        switch (pending) {
          case _PendingEnterLong p:
            final entryPrice = candle.open * (1 + slipFactor);
            final fee = balance * feeRate;
            final qty = (balance - fee) / entryPrice;
            position = _OpenPosition(
              isLong: true,
              entryPrice: entryPrice,
              quantity: qty,
              entryTimestamp: candle.timestamp,
              entryFee: fee,
              stopLoss: p.stopLoss,
              takeProfit: p.takeProfit,
            );
            balance = 0;
            totalFees += fee;
          case _PendingEnterShort p:
            final entryPrice = candle.open * (1 - slipFactor);
            final fee = balance * feeRate;
            final qty = (balance - fee) / entryPrice;
            position = _OpenPosition(
              isLong: false,
              entryPrice: entryPrice,
              quantity: qty,
              entryTimestamp: candle.timestamp,
              entryFee: fee,
              stopLoss: p.stopLoss,
              takeProfit: p.takeProfit,
            );
            balance = 0;
            totalFees += fee;
          case _PendingExit p:
            final pos = position;
            if (pos != null) {
              final exitPrice = pos.isLong
                  ? candle.open * (1 - slipFactor)
                  : candle.open * (1 + slipFactor);
              closePosition(exitPrice, candle.timestamp, p.reason);
            }
        }
        pending = null;
      }

      // ── Step B: SL / TP intra-bar (price-triggered, same-bar fill). ──
      // These are not strategy decisions — they're stop / limit orders
      // already resting on the book, so they execute the moment price
      // touches them. Ambiguous SL+TP → SL wins (conservative).
      final posForRiskCheck = position;
      if (posForRiskCheck != null) {
        if (posForRiskCheck.isLong) {
          final slHit = posForRiskCheck.stopLoss != null &&
              candle.low <= posForRiskCheck.stopLoss!;
          final tpHit = posForRiskCheck.takeProfit != null &&
              candle.high >= posForRiskCheck.takeProfit!;
          if (slHit) {
            closePosition(
                posForRiskCheck.stopLoss!, candle.timestamp, 'StopLoss');
          } else if (tpHit) {
            closePosition(
                posForRiskCheck.takeProfit!, candle.timestamp, 'TakeProfit');
          }
        } else {
          final slHit = posForRiskCheck.stopLoss != null &&
              candle.high >= posForRiskCheck.stopLoss!;
          final tpHit = posForRiskCheck.takeProfit != null &&
              candle.low <= posForRiskCheck.takeProfit!;
          if (slHit) {
            closePosition(
                posForRiskCheck.stopLoss!, candle.timestamp, 'StopLoss');
          } else if (tpHit) {
            closePosition(
                posForRiskCheck.takeProfit!, candle.timestamp, 'TakeProfit');
          }
        }
      }

      // ── Step C: Strategy decisions queue a pending order for next bar. ──
      // Entry conditions (no position) AND indicator-based exit conditions
      // (BB middle / opposite RSI extreme) both queue pending; only the
      // price-triggered SL/TP exits in Step B fill on the same bar.
      // Skipped during indicator warm-up.
      if (i >= startIdx && pending == null) {
        final close = candle.close;
        final rsi = rsiValues[i];
        final lower = bbLower[i];
        final middle = bbMiddle[i];
        final upper = bbUpper[i];

        if (position == null) {
          // Entry: SL/TP computed at SIGNAL bar's BB (i), filled at i+1
          // open. Mirrors Rust BbRsiStrategy::on_candle (bb_rsi.rs:224, :232).
          if (close <= lower && rsi < params.rsiOversold) {
            pending = _PendingEnterLong(2 * lower - middle, middle);
          } else if (close >= upper && rsi > params.rsiOverbought) {
            pending = _PendingEnterShort(2 * upper - middle, middle);
          }
        } else {
          final pos = position!;
          if (pos.isLong) {
            if (close >= middle) {
              pending = _PendingExit('BB Middle');
            } else if (rsi > params.rsiOverbought) {
              pending = _PendingExit('RSI Overbought');
            }
          } else {
            if (close <= middle) {
              pending = _PendingExit('BB Middle');
            } else if (rsi < params.rsiOversold) {
              pending = _PendingExit('RSI Oversold');
            }
          }
        }
      }

      // ── Step D: equity + drawdown + per-candle return. ──
      // F-03b: equity is recorded against the POST-trade position state.
      final double equity;
      final posForEquity = position;
      if (posForEquity == null) {
        equity = balance;
      } else {
        equity = midTradeEquity(
          balance: balance,
          entryPrice: posForEquity.entryPrice,
          quantity: posForEquity.quantity,
          entryFee: posForEquity.entryFee,
          markPrice: candle.close,
          feeRate: feeRate,
          isLong: posForEquity.isLong,
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

    // End-of-data: any pending order is discarded (no next bar to fill on);
    // any still-open position is force-closed at the last bar's close with
    // reason 'End of Data', no slippage (mark-to-last). Matches Rust
    // backtest/mod.rs::run end-of-loop handling.
    pending = null;
    if (position != null && candles.isNotEmpty) {
      final lastCandle = candles.last;
      closePosition(lastCandle.close, lastCandle.timestamp, 'End of Data');
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
