/// Backtest feature state management via ChangeNotifier (Provider pattern).
///
/// Manages both single backtest runs and parameter optimization.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../core/models/candle.dart';
import '../../core/utils/param_storage.dart';
import '../../services/backtest_service.dart';
import '../../services/binance_api_client.dart';
import '../../services/optimization_service.dart';

// ─── State enums ────────────────────────────────────────────────────────────

enum BacktestState { idle, fetchingData, running, success, error }
enum OptimizationState { idle, fetchingData, running, success, error }

// ─── Strategy kind ──────────────────────────────────────────────────────────

/// Identifies which strategy engine drives a backtest run.
///
/// Welle O3-B1: the UI selects a [StrategyKind] and the provider routes the
/// isolate call to the matching `BacktestService.runXxx` static. The legacy
/// `BacktestConfig.strategy` String field stays as a human-readable label
/// — [displayLabel] is the authoritative source for that label.
enum StrategyKind {
  bbRsi('BB+RSI Mean Reversion'),
  utBot('UT Bot'),
  ichimoku('Ichimoku Cloud');

  const StrategyKind(this.displayLabel);

  final String displayLabel;
}

// ─── Factory helpers ────────────────────────────────────────────────────────

/// Default BB+RSI parameters — Welle-R3 spec defaults.
BbRsiParams defaultBbRsiParams() => const BbRsiParams();

/// Default UT-Bot parameters — Welle-R3 spec defaults.
UtBotParams defaultUtBotParams() => const UtBotParams();

/// Default Ichimoku parameters — Welle-R3 spec defaults.
IchimokuParams defaultIchimokuParams() => const IchimokuParams();

/// Returns the default params instance for [kind].
Object defaultParamsFor(StrategyKind kind) {
  switch (kind) {
    case StrategyKind.bbRsi:
      return defaultBbRsiParams();
    case StrategyKind.utBot:
      return defaultUtBotParams();
    case StrategyKind.ichimoku:
      return defaultIchimokuParams();
  }
}

/// Asserts [params] matches [kind] — used in [BacktestConfig] copyWith /
/// constructor to keep the dynamic `strategyParams` field disciplined.
bool _paramsMatchKind(StrategyKind kind, Object params) {
  switch (kind) {
    case StrategyKind.bbRsi:
      return params is BbRsiParams;
    case StrategyKind.utBot:
      return params is UtBotParams;
    case StrategyKind.ichimoku:
      return params is IchimokuParams;
  }
}

// ─── Configuration model ────────────────────────────────────────────────────

class BacktestConfig {
  /// Human-readable strategy label. Mirrors [strategyKind.displayLabel]; kept
  /// as a separate field for backward compatibility with UI text that reads
  /// `config.strategy` directly.
  final String strategy;

  /// Logic-driving strategy kind. The provider routes the engine call based
  /// on this enum; [strategyParams] must match (asserted).
  final StrategyKind strategyKind;

  final String symbol;
  final String timeframe;
  final DateTime startDate;
  final DateTime endDate;
  final double initialBalance;
  final double feeRate;

  /// Strategy-specific parameter struct — concrete type is one of
  /// [BbRsiParams], [UtBotParams], [IchimokuParams] and must match
  /// [strategyKind]. Typed `dynamic` so the UI / provider can carry any
  /// of the three without a sealed-class refactor; the type discipline
  /// is enforced in the constructor and [copyWith] via an assert.
  final dynamic strategyParams;

  BacktestConfig({
    this.strategyKind = StrategyKind.bbRsi,
    String? strategy,
    this.symbol = 'BTCUSDT',
    this.timeframe = '1h',
    DateTime? startDate,
    DateTime? endDate,
    this.initialBalance = AppConstants.defaultInitialCapital,
    this.feeRate = AppConstants.defaultFeeRate,
    Object? strategyParams,
  })  : startDate = startDate ?? DateTime.now().subtract(const Duration(days: 90)),
        endDate = endDate ?? DateTime.now(),
        strategy = strategy ?? strategyKind.displayLabel,
        strategyParams = strategyParams ?? defaultParamsFor(strategyKind) {
    assert(
      _paramsMatchKind(strategyKind, this.strategyParams as Object),
      'strategyParams (${this.strategyParams.runtimeType}) does not match '
      'strategyKind ($strategyKind)',
    );
  }

  BacktestConfig copyWith({
    StrategyKind? strategyKind,
    String? strategy,
    String? symbol,
    String? timeframe,
    DateTime? startDate,
    DateTime? endDate,
    double? initialBalance,
    double? feeRate,
    Object? strategyParams,
  }) {
    return BacktestConfig(
      strategyKind: strategyKind ?? this.strategyKind,
      strategy: strategy ?? this.strategy,
      symbol: symbol ?? this.symbol,
      timeframe: timeframe ?? this.timeframe,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      initialBalance: initialBalance ?? this.initialBalance,
      feeRate: feeRate ?? this.feeRate,
      strategyParams: strategyParams ?? this.strategyParams as Object,
    );
  }
}

// ─── Provider ───────────────────────────────────────────────────────────────

class BacktestProvider extends ChangeNotifier {
  final BinanceApiClient _binanceClient = BinanceApiClient();
  final OptimizedParamsStorage _paramStorage = OptimizedParamsStorage();

  // ── Backtest state ──
  BacktestState _state = BacktestState.idle;
  BacktestConfig _config = BacktestConfig();
  BacktestResult? _result;
  String? _errorMessage;
  String _statusMessage = '';
  int _candlesFetched = 0;

  // ── Optimization state ──
  OptimizationState _optState = OptimizationState.idle;
  OptimizationResult? _optResult;
  String? _optError;
  String _optStatusMessage = '';
  bool _usingOptimizedParams = false;

  // ── Getters: backtest ──
  BacktestState get state => _state;
  BacktestConfig get config => _config;
  BacktestResult? get result => _result;
  String? get errorMessage => _errorMessage;
  String get statusMessage => _statusMessage;
  int get candlesFetched => _candlesFetched;
  bool get hasResult => _result != null;
  bool get isRunning =>
      _state == BacktestState.fetchingData || _state == BacktestState.running;

  // ── Getters: optimization ──
  OptimizationState get optState => _optState;
  OptimizationResult? get optResult => _optResult;
  String? get optError => _optError;
  String get optStatusMessage => _optStatusMessage;
  bool get isOptimizing =>
      _optState == OptimizationState.fetchingData ||
      _optState == OptimizationState.running;
  bool get usingOptimizedParams => _usingOptimizedParams;
  bool get hasOptResult => _optResult != null;

  /// Whether any operation is in progress (backtest or optimization).
  bool get isBusy => isRunning || isOptimizing;

  // ─── Configuration updates ──────────────────────────────────────────────

  void updateConfig(BacktestConfig newConfig) {
    _config = newConfig;
    notifyListeners();
  }

  /// Switch to a different strategy kind and load its default params. Resets
  /// the "using optimized params" indicator because optimized params are
  /// BB+RSI-only today (see [applyOptimizedParams]).
  void setStrategyKind(StrategyKind kind) {
    if (_config.strategyKind == kind) return;
    _config = _config.copyWith(
      strategyKind: kind,
      strategy: kind.displayLabel,
      strategyParams: defaultParamsFor(kind),
    );
    _usingOptimizedParams = false;
    notifyListeners();
  }

  void updateSymbol(String symbol) {
    _config = _config.copyWith(symbol: symbol);
    _usingOptimizedParams = false;
    notifyListeners();
    // Auto-load optimized params for new symbol
    _tryLoadOptimizedParams();
  }

  void updateTimeframe(String tf) {
    _config = _config.copyWith(timeframe: tf);
    _usingOptimizedParams = false;
    notifyListeners();
    // Auto-load optimized params for new timeframe
    _tryLoadOptimizedParams();
  }

  void updateDateRange(DateTime start, DateTime end) {
    _config = _config.copyWith(startDate: start, endDate: end);
    notifyListeners();
  }

  void updateBalance(double balance) {
    _config = _config.copyWith(initialBalance: balance);
    notifyListeners();
  }

  void updateFeeRate(double rate) {
    _config = _config.copyWith(feeRate: rate);
    notifyListeners();
  }

  /// Update strategy-specific params. [params] must match the active
  /// [StrategyKind] (asserted by [BacktestConfig.copyWith]).
  void updateStrategyParams(Object params) {
    assert(
      _paramsMatchKind(_config.strategyKind, params),
      'updateStrategyParams: ${params.runtimeType} does not match '
      'strategyKind ${_config.strategyKind}',
    );
    _config = _config.copyWith(strategyParams: params);
    _usingOptimizedParams = false;
    notifyListeners();
  }

  /// Apply specific optimized params from a trial result. BB+RSI-only today
  /// — silently no-ops on non-BB+RSI strategies (Welle O3-B1 OOS).
  void applyOptimizedParams(BbRsiParams params) {
    if (_config.strategyKind != StrategyKind.bbRsi) {
      debugPrint(
          '[BacktestProvider] applyOptimizedParams ignored: '
          'strategyKind=${_config.strategyKind} (BB+RSI-only path)');
      return;
    }
    _config = _config.copyWith(strategyParams: params);
    _usingOptimizedParams = true;
    notifyListeners();
  }

  /// Reset strategy params to defaults for the active strategy.
  void resetParamsToDefaults() {
    _config = _config.copyWith(
      strategyParams: defaultParamsFor(_config.strategyKind),
    );
    _usingOptimizedParams = false;
    notifyListeners();
  }

  // ─── Auto-load optimized params ─────────────────────────────────────────

  Future<void> _tryLoadOptimizedParams() async {
    // BB+RSI-only storage path. Other strategies don't have an optimizer
    // yet — skip silently to keep the UI calm.
    if (_config.strategyKind != StrategyKind.bbRsi) return;
    try {
      final params = await _paramStorage.loadOptimizedParams(
        _config.symbol,
        _config.timeframe,
      );
      if (params != null) {
        _config = _config.copyWith(strategyParams: params);
        _usingOptimizedParams = true;
        notifyListeners();
      }
    } catch (_) {
      // Silently ignore storage errors
    }
  }

  /// Explicitly load optimized params (callable from UI init).
  Future<void> loadOptimizedParamsIfAvailable() async {
    await _tryLoadOptimizedParams();
  }

  // ─── Run backtest ───────────────────────────────────────────────────────

  Future<void> runBacktest() async {
    _state = BacktestState.fetchingData;
    _errorMessage = null;
    _statusMessage = 'Fetching candle data from Binance...';
    _candlesFetched = 0;
    notifyListeners();

    try {
      final days = _config.endDate.difference(_config.startDate).inDays;
      if (days <= 0) {
        throw Exception('End date must be after start date');
      }

      final candles = await _binanceClient.downloadHistory(
        symbol: _config.symbol,
        interval: _config.timeframe,
        days: days,
      );

      _candlesFetched = candles.length;
      _statusMessage =
          'Fetched $_candlesFetched candles. Running backtest...';
      _state = BacktestState.running;
      notifyListeners();

      if (candles.isEmpty) {
        throw Exception(
            'No candle data returned for ${_config.symbol} ${_config.timeframe}');
      }

      final result = await compute(_runBacktestIsolate, _BacktestArgs(
        strategyKind: _config.strategyKind,
        candles: candles,
        initialBalance: _config.initialBalance,
        feeRate: _config.feeRate,
        params: _config.strategyParams as Object,
      ));

      _result = result;
      _state = BacktestState.success;
      _statusMessage =
          'Backtest complete: ${result.trades.length} trades on $_candlesFetched candles';
      notifyListeners();
    } catch (e) {
      _state = BacktestState.error;
      _errorMessage = e.toString();
      _statusMessage = 'Error: $e';
      notifyListeners();
    }
  }

  // ─── Parameter optimization ─────────────────────────────────────────────

  /// Run grid-search optimization over all BB+RSI parameter combinations.
  /// BB+RSI-only — Welle O3-B1 OOS, multi-strategy optimization is a later
  /// wave. Refuses to start when [StrategyKind.bbRsi] is not active.
  Future<void> optimizeParameters() async {
    if (_config.strategyKind != StrategyKind.bbRsi) {
      _optState = OptimizationState.error;
      _optError = 'Optimization is BB+RSI-only in this build';
      _optStatusMessage = _optError!;
      notifyListeners();
      return;
    }
    _optState = OptimizationState.fetchingData;
    _optError = null;
    _optStatusMessage = 'Fetching candle data for optimization...';
    _optResult = null;
    notifyListeners();

    try {
      final days = _config.endDate.difference(_config.startDate).inDays;
      if (days <= 0) {
        throw Exception('End date must be after start date');
      }

      final candles = await _binanceClient.downloadHistory(
        symbol: _config.symbol,
        interval: _config.timeframe,
        days: days,
      );

      if (candles.isEmpty) {
        throw Exception(
            'No candle data for ${_config.symbol} ${_config.timeframe}');
      }

      final totalCombs = DefaultRanges.totalCombinations;
      _optStatusMessage =
          'Running $totalCombs parameter combinations on ${candles.length} candles...';
      _optState = OptimizationState.running;
      notifyListeners();

      // Run in isolate for UI responsiveness
      final result = await compute(
        runOptimizationIsolate,
        OptimizationArgs(
          candles: candles,
          initialBalance: _config.initialBalance,
          feeRate: _config.feeRate,
        ),
      );

      _optResult = result;
      _optState = OptimizationState.success;

      if (result.topResults.isNotEmpty) {
        _optStatusMessage =
            'Optimization complete: ${result.combinationsRun} tested in '
            '${result.elapsed.inSeconds}s. Best Sharpe: '
            '${result.topResults.first.sharpeRatio.toStringAsFixed(2)}';

        // Auto-apply best params
        final bestParams = result.bestParams!;
        _config = _config.copyWith(strategyParams: bestParams);
        _usingOptimizedParams = true;

        // Save to persistent storage
        await _paramStorage.saveOptimizedParams(
          _config.symbol,
          _config.timeframe,
          bestParams,
        );
      } else {
        _optStatusMessage =
            'Optimization complete but no valid results found '
            '(${result.combinationsRun} combinations tested)';
      }

      notifyListeners();
    } catch (e) {
      _optState = OptimizationState.error;
      _optError = e.toString();
      _optStatusMessage = 'Optimization error: $e';
      notifyListeners();
    }
  }

  /// Dismiss optimization results dialog state.
  void dismissOptimization() {
    _optState = OptimizationState.idle;
    notifyListeners();
  }

  // ─── CSV export ─────────────────────────────────────────────────────────

  Future<String> exportTradesCsv() async {
    if (_result == null) throw Exception('No backtest result to export');

    final df = DateFormat('yyyy-MM-dd_HH-mm');
    final fileName = 'trades_${_config.symbol}_${_config.timeframe}_'
        '${df.format(DateTime.now())}.csv';

    final dir = Directory.systemTemp;
    final file = File('${dir.path}/$fileName');

    final sb = StringBuffer();
    sb.writeln(
        'Entry Time,Exit Time,Direction,Entry Price,Exit Price,Quantity,PnL,PnL %,Fees,Exit Reason');

    final dateFmt = DateFormat('yyyy-MM-dd HH:mm');
    for (final t in _result!.trades) {
      final entry = dateFmt.format(
          DateTime.fromMillisecondsSinceEpoch(t.entryTimestamp, isUtc: true));
      final exit = dateFmt.format(
          DateTime.fromMillisecondsSinceEpoch(t.exitTimestamp, isUtc: true));
      sb.writeln(
          '$entry,$exit,${t.direction},${t.entryPrice.toStringAsFixed(2)},'
          '${t.exitPrice.toStringAsFixed(2)},${t.quantity.toStringAsFixed(6)},'
          '${t.pnl.toStringAsFixed(2)},${t.pnlPercent.toStringAsFixed(2)},'
          '${t.fees.toStringAsFixed(2)},${t.exitReason}');
    }

    await file.writeAsString(sb.toString());
    return file.path;
  }

  Future<String> exportEquityCsv() async {
    if (_result == null) throw Exception('No backtest result to export');

    final df = DateFormat('yyyy-MM-dd_HH-mm');
    final fileName = 'equity_${_config.symbol}_${_config.timeframe}_'
        '${df.format(DateTime.now())}.csv';

    final dir = Directory.systemTemp;
    final file = File('${dir.path}/$fileName');

    final sb = StringBuffer();
    sb.writeln('Timestamp,Equity,Drawdown,Drawdown %');

    final dateFmt = DateFormat('yyyy-MM-dd HH:mm');
    for (final p in _result!.equityCurve) {
      final ts = dateFmt.format(
          DateTime.fromMillisecondsSinceEpoch(p.timestamp, isUtc: true));
      sb.writeln('$ts,${p.equity.toStringAsFixed(2)},'
          '${p.drawdown.toStringAsFixed(2)},${p.drawdownPct.toStringAsFixed(2)}');
    }

    await file.writeAsString(sb.toString());
    return file.path;
  }

  // ─── Reset ──────────────────────────────────────────────────────────────

  void reset() {
    _state = BacktestState.idle;
    _result = null;
    _errorMessage = null;
    _statusMessage = '';
    _candlesFetched = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _binanceClient.dispose();
    super.dispose();
  }
}

// ─── Isolate helpers ────────────────────────────────────────────────────────

class _BacktestArgs {
  final StrategyKind strategyKind;
  final List<CandleData> candles;
  final double initialBalance;
  final double feeRate;
  final Object params;

  const _BacktestArgs({
    required this.strategyKind,
    required this.candles,
    required this.initialBalance,
    required this.feeRate,
    required this.params,
  });
}

BacktestResult _runBacktestIsolate(_BacktestArgs args) {
  switch (args.strategyKind) {
    case StrategyKind.bbRsi:
      return BacktestService.runBbRsi(
        candles: args.candles,
        initialBalance: args.initialBalance,
        feeRate: args.feeRate,
        params: args.params as BbRsiParams,
      );
    case StrategyKind.utBot:
      return BacktestService.runUtBot(
        candles: args.candles,
        initialBalance: args.initialBalance,
        feeRate: args.feeRate,
        params: args.params as UtBotParams,
      );
    case StrategyKind.ichimoku:
      return BacktestService.runIchimoku(
        candles: args.candles,
        initialBalance: args.initialBalance,
        feeRate: args.feeRate,
        params: args.params as IchimokuParams,
      );
  }
}
