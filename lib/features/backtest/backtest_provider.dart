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

// ─── Configuration model ────────────────────────────────────────────────────

class BacktestConfig {
  final String strategy;
  final String symbol;
  final String timeframe;
  final DateTime startDate;
  final DateTime endDate;
  final double initialBalance;
  final double feeRate;
  final BbRsiParams strategyParams;

  BacktestConfig({
    this.strategy = 'BB+RSI Mean Reversion',
    this.symbol = 'BTCUSDT',
    this.timeframe = '1h',
    DateTime? startDate,
    DateTime? endDate,
    this.initialBalance = AppConstants.defaultInitialCapital,
    this.feeRate = AppConstants.defaultFeeRate,
    this.strategyParams = const BbRsiParams(),
  })  : startDate = startDate ?? DateTime.now().subtract(const Duration(days: 90)),
        endDate = endDate ?? DateTime.now();

  BacktestConfig copyWith({
    String? strategy,
    String? symbol,
    String? timeframe,
    DateTime? startDate,
    DateTime? endDate,
    double? initialBalance,
    double? feeRate,
    BbRsiParams? strategyParams,
  }) {
    return BacktestConfig(
      strategy: strategy ?? this.strategy,
      symbol: symbol ?? this.symbol,
      timeframe: timeframe ?? this.timeframe,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      initialBalance: initialBalance ?? this.initialBalance,
      feeRate: feeRate ?? this.feeRate,
      strategyParams: strategyParams ?? this.strategyParams,
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

  void updateStrategyParams(BbRsiParams params) {
    _config = _config.copyWith(strategyParams: params);
    _usingOptimizedParams = false;
    notifyListeners();
  }

  /// Apply specific optimized params from a trial result.
  void applyOptimizedParams(BbRsiParams params) {
    _config = _config.copyWith(strategyParams: params);
    _usingOptimizedParams = true;
    notifyListeners();
  }

  /// Reset strategy params to defaults.
  void resetParamsToDefaults() {
    _config = _config.copyWith(strategyParams: const BbRsiParams());
    _usingOptimizedParams = false;
    notifyListeners();
  }

  // ─── Auto-load optimized params ─────────────────────────────────────────

  Future<void> _tryLoadOptimizedParams() async {
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
        candles: candles,
        initialBalance: _config.initialBalance,
        feeRate: _config.feeRate,
        params: _config.strategyParams,
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
  Future<void> optimizeParameters() async {
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
  final List<CandleData> candles;
  final double initialBalance;
  final double feeRate;
  final BbRsiParams params;

  const _BacktestArgs({
    required this.candles,
    required this.initialBalance,
    required this.feeRate,
    required this.params,
  });
}

BacktestResult _runBacktestIsolate(_BacktestArgs args) {
  return BacktestService.runBbRsi(
    candles: args.candles,
    initialBalance: args.initialBalance,
    feeRate: args.feeRate,
    params: args.params,
  );
}
