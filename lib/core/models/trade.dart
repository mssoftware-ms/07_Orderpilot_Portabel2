/// Canonical trade and backtest-metrics models.
///
/// These are the single source of truth for trade results across the app.
/// Both the Dart backtest engine (lib/services/backtest_service.dart) and
/// the Rust FFI bridge (lib/services/rust_bridge.dart) must produce
/// instances of [BacktestMetrics] and [ClosedTrade] from this file —
/// see test/regression/f06_model_unification_test.dart.
library;

import 'package:flutter/foundation.dart';

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

/// Snapshot of an open position at the end of a backtest run.
///
/// Returned via [BacktestResult.openPosition] when a caller passes
/// `extractOpenPosition: true` to `BacktestService.runXxx`. The default
/// `false` path keeps the legacy "force-close at last bar with
/// `exitReason == 'End of Data'`" behaviour so the Phase-1 reference
/// backtest stays bit-exact (see Welle B4.2-1 brief).
///
/// `slPrice` and `tpPrice` are nullable so non-SL/TP strategies, warm-up
/// edge cases, or NaN/Inf values can be surfaced as "—" in the UI
/// without breaking the contract.
@immutable
class OpenPositionSnapshot {
  /// `'LONG'` or `'SHORT'` — matches [ClosedTrade.direction] casing.
  final String direction;

  /// Unix ms timestamp of the FILL bar (next bar after the signal).
  final int openedAt;

  /// Actual filled entry price (open × slippage factor inside the engine).
  final double entryPrice;

  /// Filled quantity, derived from D-09 risk sizing inside the engine.
  final double quantity;

  /// Absolute SL price at entry. Null when the engine did not attach an
  /// SL (e.g. a future Phase-3 non-SL strategy) or when the value is
  /// NaN/Inf (warm-up edge case).
  final double? slPrice;

  /// Absolute TP price at entry. Null under the same conditions as
  /// [slPrice].
  final double? tpPrice;

  /// Entry fee paid at the FILL bar (already deducted from balance).
  final double entryFee;

  const OpenPositionSnapshot({
    required this.direction,
    required this.openedAt,
    required this.entryPrice,
    required this.quantity,
    required this.entryFee,
    this.slPrice,
    this.tpPrice,
  });

  bool get isLong => direction == 'LONG';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenPositionSnapshot &&
          direction == other.direction &&
          openedAt == other.openedAt &&
          entryPrice == other.entryPrice &&
          quantity == other.quantity &&
          slPrice == other.slPrice &&
          tpPrice == other.tpPrice &&
          entryFee == other.entryFee;

  @override
  int get hashCode => Object.hash(
        direction,
        openedAt,
        entryPrice,
        quantity,
        slPrice,
        tpPrice,
        entryFee,
      );
}
