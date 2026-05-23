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
import 'indicators.dart';
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

  /// Swing-low / swing-high lookback (Diff D-07).
  ///
  /// Spec §4 algorithmic SL definition: long SL = `min(low[i - N .. i - 1])`,
  /// short SL = `max(high[i - N .. i - 1])` where `N = swingLookbackBars`.
  /// Default 20 matches the Rust manifest and approximates a ~one-day
  /// lookback on 1h candles. Must equal the Rust `swing_lookback_bars`
  /// parameter for Dart↔Rust parity.
  final int swingLookbackBars;

  /// TP distance as a multiple of the swing-derived SL distance (Diff D-06).
  ///
  /// Spec §5: R:R 1:3 → `tpRrRatio = 3.0` (default). At signal time the
  /// engine sets TP = entry-proxy ± ratio × |entry-proxy − sl_price|,
  /// using the signal-bar close as entry proxy (the actual fill is at
  /// the next bar's open per F-04). Must equal the Rust `tp_rr_ratio`
  /// parameter for Dart↔Rust parity.
  final double tpRrRatio;

  /// One-side slippage in basis points applied at each execution
  /// (entry and exit) against the trader. Plan rev2 §3.4 F-04 sets the
  /// default to 0 bps for Binance / Bitunix BTC + ETH at retail size;
  /// raise for thin alts or large orders. Must match the Rust
  /// BacktestConfig.slippage_bps for Dart↔Rust parity.
  final double slippageBps;

  /// Defaults match the video-spec "verbesserte Variante" — see
  /// `01_Projectplan/specs/bb_rsi_spec.md` §1, Diff D-01 + D-02
  /// (BB(200, EMA, 0.2σ) + RSI(3, 20/80)) plus Diff D-06 R:R 1:3 TP
  /// and Diff D-07 swing-SL N=20. Mirrors the bb_rsi_manifest() defaults
  /// in `rust/trading_engine/src/addins/bb_rsi.rs`.
  const BbRsiParams({
    this.bbPeriod = 200,
    this.bbStdDev = 0.2,
    this.bbMaType = BbMaType.ema,
    this.rsiPeriod = 3,
    this.rsiOversold = 20.0,
    this.rsiOverbought = 80.0,
    this.swingLookbackBars = 20,
    this.tpRrRatio = 3.0,
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
  /// Mutated by the D-08 break-even trail; the original distance is
  /// preserved in [initialSlDistance] so the +1R check still works
  /// after the SL is pulled to entry. Mirrors `Position::stop_loss`
  /// in the Rust engine.
  double? stopLoss;

  /// Absolute take-profit price (null = no TP attached at entry).
  /// Mirrors `Position::take_profit` in the Rust engine.
  final double? takeProfit;

  /// Original SL distance at entry (`|entryPrice − stopLoss|` at open).
  /// Captured once and never updated; used by the D-08 break-even
  /// trail to know when +1R has been reached even after [stopLoss]
  /// has been pulled to entry. `null` when the position opened
  /// without an SL — in that case BE-trail does not fire.
  final double? initialSlDistance;

  /// True once the D-08 break-even trail has pulled [stopLoss] to
  /// [entryPrice]. Permanent — no further trailing or re-application.
  bool breakevenApplied;

  _OpenPosition({
    required this.isLong,
    required this.entryPrice,
    required this.quantity,
    required this.entryTimestamp,
    required this.entryFee,
    this.stopLoss,
    this.takeProfit,
    this.initialSlDistance,
  }) : breakevenApplied = false;
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

// Diff D-11 removed the BB-middle / RSI-extreme indicator exits, so
// the pending-order queue no longer carries `_PendingExit` entries —
// positions close exclusively via Step B intra-bar SL/TP, or via the
// end-of-data force-close in `runBbRsi`.

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

    // Previous bar's RSI for the Diff D-05 cross check. Rotated at the
    // end of each post-warm-up iteration so the first cross can fire on
    // bar `startIdx + 1` at the earliest — mirrors the Rust
    // BbRsiStrategy's `prev_rsi` state semantics.
    double? prevRsi;

    // Diff D-07 widens the warm-up gate to also cover the swing-low/high
    // window: signals can only fire when `swingLookbackBars` candles are
    // available BEFORE the signal bar (exclusive of it), otherwise the
    // SL would be undefined. Mirrors the Rust strategy's `start_idx`
    // computation (rust/.../addins/bb_rsi.rs) so both engines emit signals
    // on the same set of bars.
    final startIdx = math.max(
      math.max(params.bbPeriod, params.rsiPeriod + 1),
      params.swingLookbackBars,
    );
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
              initialSlDistance: (entryPrice - p.stopLoss).abs(),
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
              initialSlDistance: (p.stopLoss - entryPrice).abs(),
            );
            balance = 0;
            totalFees += fee;
        }
        pending = null;
      }

      // ── Step B: intra-bar exits, TP-first ordering (D-08). ──
      // Convention rewritten in D-08:
      //   a) TP check  — if `high ≥ TP` (long) / `low ≤ TP` (short) the
      //      limit order fills; exit at TP and skip the rest.
      //   b) BE-trail  — if no TP and the bar reached +1R, pull the SL
      //      to entry once and lock the flag.
      //   c) SL check  — using the possibly-updated SL.
      //
      // Pre-D-08 Dart resolved same-bar SL+TP in favour of SL (matching
      // the Rust pre-D-08 convention). That priority turns the BE-trail
      // into a strict loss for the trader on any bar that touches the TP
      // and retraces: BE would pull SL to entry, then SL-first would
      // close at entry instead of letting the TP fill. TP-first resolves
      // the ambiguity in favour of the limit order; both engines apply
      // the same rule so Dart↔Rust parity is preserved.
      final posPre = position;
      if (posPre != null) {
        final tpHitFirst = posPre.takeProfit != null &&
            (posPre.isLong
                ? candle.high >= posPre.takeProfit!
                : candle.low <= posPre.takeProfit!);
        if (tpHitFirst) {
          closePosition(posPre.takeProfit!, candle.timestamp, 'TakeProfit');
        } else {
          if (!posPre.breakevenApplied && posPre.initialSlDistance != null) {
            final dist = posPre.initialSlDistance!;
            final reached = posPre.isLong
                ? candle.high >= posPre.entryPrice + dist
                : candle.low <= posPre.entryPrice - dist;
            if (reached) {
              posPre.stopLoss = posPre.entryPrice;
              posPre.breakevenApplied = true;
            }
          }
          final slHit = posPre.stopLoss != null &&
              (posPre.isLong
                  ? candle.low <= posPre.stopLoss!
                  : candle.high >= posPre.stopLoss!);
          if (slHit) {
            closePosition(posPre.stopLoss!, candle.timestamp, 'StopLoss');
          }
        }
      }

      // ── Step C: Strategy decisions queue a pending order for next bar. ──
      // Entry conditions (no position) AND indicator-based exit conditions
      // (BB middle / opposite RSI extreme) both queue pending; only the
      // price-triggered SL/TP exits in Step B fill on the same bar.
      // Skipped during indicator warm-up.
      if (i >= startIdx) {
        final close = candle.close;
        final rsi = rsiValues[i];

        if (pending == null) {
          final lower = bbLower[i];
          final upper = bbUpper[i];
          // Diff D-06: TP is no longer derived from BB-middle geometry —
          // it is `tpRrRatio * sl_distance` from the signal-bar close.
          // `bbMiddle[i]` stays populated for the EMA-basis state but is
          // not consumed by the entry block anymore.

          if (position == null) {
            // Diff D-03/D-04 + Diff D-05 + Diff D-07: trend-follow + RSI
            // cross-back through the oversold/overbought level + swing-
            // low / swing-high SL placement (video spec §2/§3/§4).
            //   Long  ⇔ close > upper AND prev_rsi < oversold AND rsi ≥ oversold
            //   Short ⇔ close < lower AND prev_rsi > overbought AND rsi ≤ overbought
            // Null prev_rsi (first bar after warm-up) suppresses the
            // cross — no signal possible. SL is the swing-low (long) or
            // swing-high (short) of the `swingLookbackBars` bars BEFORE
            // the signal bar (exclusive). Degenerate swings
            // (swing-low ≥ close for a long, swing-high ≤ close for a
            // short) suppress the signal so the engine never opens with
            // the SL on the wrong side of entry. The TP placeholder is
            // still the BB-geometry mirror from Diff D-04; D-06 converts
            // it to the R:R 1:3 contract.
            final prev = prevRsi;
            if (prev != null) {
              final preLows = <double>[];
              final preHighs = <double>[];
              for (int j = i - params.swingLookbackBars; j < i; j++) {
                preLows.add(candles[j].low);
                preHighs.add(candles[j].high);
              }
              final slLong = swingLow(preLows);
              final slShort = swingHigh(preHighs);
              if (slLong != null &&
                  slShort != null &&
                  close > upper &&
                  prev < params.rsiOversold &&
                  rsi >= params.rsiOversold &&
                  slLong < close) {
                // Diff D-06: TP = entry-proxy + ratio * sl_distance.
                // The signal-bar close is the entry-price proxy; the
                // actual fill at the next bar's open may differ slightly
                // under non-zero slippage (the asymmetric impact on R:R
                // is documented in the Welle-2 QA brief).
                final tpLong = close + params.tpRrRatio * (close - slLong);
                pending = _PendingEnterLong(slLong, tpLong);
              } else if (slLong != null &&
                  slShort != null &&
                  close < lower &&
                  prev > params.rsiOverbought &&
                  rsi <= params.rsiOverbought &&
                  slShort > close) {
                final tpShort =
                    close - params.tpRrRatio * (slShort - close);
                pending = _PendingEnterShort(slShort, tpShort);
              }
            }
          }
          // Diff D-11 (Phase-2): BB-middle and RSI-extreme indicator
          // exits removed. Positions are closed exclusively by SL/TP
          // (Step B intra-bar) or end-of-data force-close.
        }

        // Rotate prevRsi for the next iteration regardless of whether a
        // decision fired this bar, mirroring Rust's `state.last_rsi`
        // rotation in on_candle.
        prevRsi = rsi;
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
