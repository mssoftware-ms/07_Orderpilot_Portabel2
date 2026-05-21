/// Backtest feature state management via ChangeNotifier (Provider pattern).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../core/models/candle.dart';
import '../../services/backtest_service.dart';
import '../../services/binance_api_client.dart';

// ─── State enum ─────────────────────────────────────────────────────────────

enum BacktestState { idle, fetchingData, running, success, error }

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

  BacktestState _state = BacktestState.idle;
  BacktestConfig _config = BacktestConfig();
  BacktestResult? _result;
  String? _errorMessage;
  String _statusMessage = '';
  int _candlesFetched = 0;

  // Getters
  BacktestState get state => _state;
  BacktestConfig get config => _config;
  BacktestResult? get result => _result;
  String? get errorMessage => _errorMessage;
  String get statusMessage => _statusMessage;
  int get candlesFetched => _candlesFetched;
  bool get hasResult => _result != null;
  bool get isRunning =>
      _state == BacktestState.fetchingData || _state == BacktestState.running;

  // ─── Configuration updates ──────────────────────────────────────────────

  void updateConfig(BacktestConfig newConfig) {
    _config = newConfig;
    notifyListeners();
  }

  void updateSymbol(String symbol) {
    _config = _config.copyWith(symbol: symbol);
    notifyListeners();
  }

  void updateTimeframe(String tf) {
    _config = _config.copyWith(timeframe: tf);
    notifyListeners();
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
    notifyListeners();
  }

  // ─── Run backtest ───────────────────────────────────────────────────────

  Future<void> runBacktest() async {
    _state = BacktestState.fetchingData;
    _errorMessage = null;
    _statusMessage = 'Fetching candle data from Binance...';
    _candlesFetched = 0;
    notifyListeners();

    try {
      // Calculate days between start and end
      final days = _config.endDate.difference(_config.startDate).inDays;
      if (days <= 0) {
        throw Exception('End date must be after start date');
      }

      // Fetch candles from Binance
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

      // Run backtest (compute-bound, runs synchronously)
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

  // ─── CSV export ─────────────────────────────────────────────────────────

  /// Export trade log to CSV and return the file path.
  Future<String> exportTradesCsv() async {
    if (_result == null) throw Exception('No backtest result to export');

    final df = DateFormat('yyyy-MM-dd_HH-mm');
    final fileName = 'trades_${_config.symbol}_${_config.timeframe}_'
        '${df.format(DateTime.now())}.csv';

    // Use temp directory or current directory
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

  /// Export equity curve to CSV and return the file path.
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

// ─── Isolate helper ─────────────────────────────────────────────────────────

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
