/// Paper-trading session state and config — pure data containers
/// owned and mutated by [PaperTradingProvider].
library;

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/models/candle.dart';
import '../../core/models/trade.dart';
import '../../features/backtest/backtest_provider.dart';
import '../../services/backtest_service.dart';
import 'paper_position.dart';

/// Lifecycle status of a paper-trading session.
enum PaperSessionStatus {
  /// Session has not been started yet, or has been reset.
  idle,

  /// WS connect in progress (first attempt).
  connecting,

  /// WS connected, ticks are flowing.
  running,

  /// WS dropped, backoff retry running.
  reconnecting,

  /// User stopped the session cleanly.
  stopped,

  /// Terminal — either the WS reconnect cap was exceeded (Welle B4-4)
  /// or the session config failed validation. The session can be
  /// re-started with a new config.
  error,
}

/// Static config of a paper-trading session — fixed once `start()`
/// is called.
@immutable
class PaperConfig {
  final String symbol;
  final String timeframe;
  final StrategyKind strategyKind;
  final Object strategyParams;
  final double initialBalance;
  final double feeRate;

  /// Session-level one-side slippage in basis points (Welle B4.2-2).
  ///
  /// Default 5 bps reflects Binance Spot retail-fill quality for BTC/ETH
  /// at typical order sizes. The value is merged into the active
  /// `strategyParams.slippageBps` at `start()` so every strategy uses
  /// the same paper-trading-specific slippage regardless of what the
  /// user picked in the backtest tab.
  final double slippageBps;

  /// Lower bound the UI slider exposes for [slippageBps] (Welle B4.2-2).
  static const double minSlippageBps = 0.0;

  /// Upper bound the UI slider exposes for [slippageBps] (Welle B4.2-2).
  static const double maxSlippageBps = 20.0;

  /// Default value for [slippageBps] — 5 bps for Binance Spot retail.
  static const double defaultSlippageBps = 5.0;

  const PaperConfig({
    required this.symbol,
    required this.timeframe,
    required this.strategyKind,
    required this.strategyParams,
    required this.initialBalance,
    required this.feeRate,
    this.slippageBps = defaultSlippageBps,
  });

  /// Default starter config — BTCUSDT 1m, BB+RSI defaults, $10k, Bitunix
  /// VIP0 taker. Used when the user clicks "Start" without first
  /// running "Sync from Backtest".
  factory PaperConfig.defaults() => PaperConfig(
        symbol: AppConstants.supportedSymbols.first,
        timeframe: '1m',
        strategyKind: StrategyKind.bbRsi,
        strategyParams: defaultBbRsiParams(),
        initialBalance: AppConstants.defaultInitialCapital,
        feeRate: AppConstants.defaultFeeRate,
      );

  /// Mirror a [BacktestConfig] into a [PaperConfig] — invoked by
  /// PaperTradingProvider.syncFromBacktest. The two configs are NOT
  /// merged: a sync-then-start replaces the paper config wholesale.
  /// Slippage is paper-trading-specific (5 bps default for Binance Spot
  /// retail) and not pulled from the backtest config — the user sets it
  /// via the dedicated session slider.
  factory PaperConfig.fromBacktestConfig(BacktestConfig source) => PaperConfig(
        symbol: source.symbol,
        timeframe: source.timeframe,
        strategyKind: source.strategyKind,
        strategyParams: source.strategyParams as Object,
        initialBalance: source.initialBalance,
        feeRate: source.feeRate,
      );

  PaperConfig copyWith({
    String? symbol,
    String? timeframe,
    StrategyKind? strategyKind,
    Object? strategyParams,
    double? initialBalance,
    double? feeRate,
    double? slippageBps,
  }) =>
      PaperConfig(
        symbol: symbol ?? this.symbol,
        timeframe: timeframe ?? this.timeframe,
        strategyKind: strategyKind ?? this.strategyKind,
        strategyParams: strategyParams ?? this.strategyParams,
        initialBalance: initialBalance ?? this.initialBalance,
        feeRate: feeRate ?? this.feeRate,
        slippageBps: slippageBps ?? this.slippageBps,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PaperConfig &&
          symbol == other.symbol &&
          timeframe == other.timeframe &&
          strategyKind == other.strategyKind &&
          strategyParams == other.strategyParams &&
          initialBalance == other.initialBalance &&
          feeRate == other.feeRate &&
          slippageBps == other.slippageBps;

  @override
  int get hashCode => Object.hash(
        symbol,
        timeframe,
        strategyKind,
        strategyParams,
        initialBalance,
        feeRate,
        slippageBps,
      );
}

/// Mutable runtime state of an active paper-trading session.
class PaperSession {
  final PaperConfig config;

  /// Unix ms of the session start (for elapsed display).
  final int startedAtMs;

  /// Ring-buffered closed candles (newest at end). Capped at 500 by
  /// PaperTradingProvider so the engine replay stays bounded.
  final List<CandleData> candleBuffer;

  /// Open virtual position, re-derived after every tick from
  /// [BacktestResult.openPosition] (Welle B4.2-1, engine called with
  /// `extractOpenPosition: true`). Null whenever the engine has no
  /// still-open position at the end of its window.
  PaperPosition? openPosition;

  /// Real closed trades — engine result minus the open-position
  /// placeholder.
  List<ClosedTrade> closedTrades;

  /// Latest equity (balance + open-position mark-to-market).
  double equity;

  /// Latest equity curve from the rolling-window backtest. Refreshed
  /// every tick; not a true session-wide curve (see step-1 caveats).
  List<EquityPoint> equityCurve;

  /// Count of closed-candle ticks consumed since `start()`.
  int tickCount;

  PaperSession({
    required this.config,
    required this.startedAtMs,
    List<CandleData>? candleBuffer,
    this.openPosition,
    List<ClosedTrade>? closedTrades,
    double? equity,
    List<EquityPoint>? equityCurve,
    this.tickCount = 0,
  })  : candleBuffer = candleBuffer ?? <CandleData>[],
        closedTrades = closedTrades ?? <ClosedTrade>[],
        equity = equity ?? config.initialBalance,
        equityCurve = equityCurve ?? <EquityPoint>[];

  /// Absolute P&L since session start.
  double get totalPnl => equity - config.initialBalance;

  /// P&L as a percentage of starting capital.
  double get totalPnlPercent =>
      config.initialBalance > 0 ? (totalPnl / config.initialBalance) * 100 : 0;

  /// Mark price for the open-position card — the last close in the
  /// buffer, or the entry price if no candles have arrived yet.
  double? get latestMarkPrice =>
      candleBuffer.isEmpty ? null : candleBuffer.last.close;
}
