/// Phase-2 UT Bot real-data acceptance sweep (Welle U3).
///
/// Eskalations-Leiter analogous to the BB+RSI diagnose sweep:
///   Test 1 — Strict-Spec Baseline (defaults from ut_bot_spec.md §1)
///   Test 2 — Path-B backup key_value=3.0 (spec §12.1)
///   Test 3 — Path-B experiment smi_cross_above_zero (deferred, owned
///            by a separate sub-commit if Tests 1+2 miss the XLSX band)
///   Test 4 — Mandatory sanity sweep (BTCUSDT 15m/1h, ETHUSDT 5m, key
///            and ATR-period combinations)
///
/// Each test runs the Dart engine 3 times (reproducibility gate) and
/// the Rust engine 3 times (FFI parity at 1e-9), and prints a single
/// summary block matching the BB+RSI diagnose output format so the QA
/// brief can pick numbers off the test log without re-extracting them.
///
/// Manual run (opt-in via env var, so normal `flutter test` does NOT
/// hit Binance for 19k candles):
///
///   UT_BOT_DIAGNOSE=1 flutter test --plain-name "Test 1 BTCUSDT 5min strict" \
///     test/integration/ut_bot_real_data_test.dart
///
/// Date range: 2024-01-01 00:00:00 UTC → 2024-03-07 00:00:00 UTC (66
/// days ≈ 19000 5min candles). Matches the U2-5 task brief; widening or
/// shifting this window must be reflected in the Spec §13.2 actual-results
/// table so the comparison against XLSX targets stays apples-to-apples.
library;

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/core/models/trade.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/binance_api_client.dart';
import 'package:trading_app/services/rust_bridge.dart';

const _initialBalance = 10000.0;
const _feeRate = 0.0006;
// 2024-01-01 00:00:00 UTC = 1704067200000
const _startMs = 1704067200000;
// 2024-03-07 00:00:00 UTC = 1709769600000
const _endMs = 1709769600000;

final Object? _skipReason = Platform.environment['UT_BOT_DIAGNOSE'] == '1'
    ? null
    : 'manual diagnostic — run with UT_BOT_DIAGNOSE=1 and --plain-name';

void main() {
  group('UT Bot real-data acceptance', () {
    test('Test 1 BTCUSDT 5min strict-spec baseline', () async {
      await _runDiagnose(
        label: 'Test 1 BTCUSDT 5min strict (key=2.0)',
        symbol: 'BTCUSDT',
        interval: '5m',
        params: const UtBotParams(),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 2 BTCUSDT 5min path-B backup key=3', () async {
      await _runDiagnose(
        label: 'Test 2 BTCUSDT 5min strict (key=3.0)',
        symbol: 'BTCUSDT',
        interval: '5m',
        params: const UtBotParams(keyValue: 3.0),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 3 BTCUSDT 5min path-B smi_cross_above_zero=true', () async {
      // Path-B exploration per Spec §12.5: keep strict-spec defaults
      // (key=2.0, atr=1, smi=14/5/3) but flip the SMI zero-line gate.
      await _runDiagnose(
        label: 'Test 3 BTCUSDT 5min cross_above_zero (key=2.0)',
        symbol: 'BTCUSDT',
        interval: '5m',
        params: const UtBotParams(smiCrossAboveZero: true),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    // ─── Test 4 sanity sweep (Spec §13.3) ────────────────────────────────
    // Only run if Tests 1 + 2 both miss the XLSX band. Decision lives in
    // the human brief — no automated gating, just plain-name selection.
    test('Test 4a BTCUSDT 15min strict', () async {
      await _runDiagnose(
        label: 'Test 4a BTCUSDT 15m strict (key=2.0)',
        symbol: 'BTCUSDT',
        interval: '15m',
        params: const UtBotParams(),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 4b BTCUSDT 1h strict', () async {
      await _runDiagnose(
        label: 'Test 4b BTCUSDT 1h strict (key=2.0)',
        symbol: 'BTCUSDT',
        interval: '1h',
        params: const UtBotParams(),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 4c ETHUSDT 5min strict', () async {
      await _runDiagnose(
        label: 'Test 4c ETHUSDT 5m strict (key=2.0)',
        symbol: 'ETHUSDT',
        interval: '5m',
        params: const UtBotParams(),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 4d BTCUSDT 5min key=1.5 atr=5', () async {
      await _runDiagnose(
        label: 'Test 4d BTCUSDT 5m (key=1.5, atr=5)',
        symbol: 'BTCUSDT',
        interval: '5m',
        params: const UtBotParams(keyValue: 1.5, atrPeriod: 5),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 4e BTCUSDT 5min key=5 atr=10', () async {
      await _runDiagnose(
        label: 'Test 4e BTCUSDT 5m (key=5.0, atr=10)',
        symbol: 'BTCUSDT',
        interval: '5m',
        params: const UtBotParams(keyValue: 5.0, atrPeriod: 10),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));
  });
}

Future<void> _runDiagnose({
  required String label,
  required String symbol,
  required String interval,
  required UtBotParams params,
}) async {
  final candles = await _fetchRange(symbol, interval, _startMs, _endMs);
  expect(candles.length, greaterThan(500),
      reason: '$label sanity: expected >500 candles, got ${candles.length}');

  final dartRuns = <BacktestResult>[];
  for (var i = 0; i < 3; i++) {
    dartRuns.add(BacktestService.runUtBot(
      candles: candles,
      initialBalance: _initialBalance,
      feeRate: _feeRate,
      params: params,
    ));
  }

  // Determinism gate — any drift here is a regression in the Dart engine
  // and stops the diagnostic; do NOT widen the assertion.
  for (var i = 1; i < 3; i++) {
    expect(dartRuns[i].metrics.totalPnl, equals(dartRuns[0].metrics.totalPnl),
        reason: '$label: dart run $i totalPnl differs from run 0');
    expect(dartRuns[i].metrics.totalTrades, equals(dartRuns[0].metrics.totalTrades),
        reason: '$label: dart run $i totalTrades differs');
  }

  await RustBridge.initialize();
  final rustRuns = <BacktestMetrics>[];
  for (var i = 0; i < 3; i++) {
    rustRuns.add(await RustBridge.runUtBotBacktest(
      candles: candles,
      initialBalance: _initialBalance,
      feeRate: _feeRate,
      strategyParams: _paramsToMap(params),
    ));
  }
  for (var i = 1; i < 3; i++) {
    expect(rustRuns[i].totalPnl, equals(rustRuns[0].totalPnl),
        reason: '$label: rust run $i totalPnl differs');
  }
  expect(rustRuns[0].totalPnl, closeTo(dartRuns[0].metrics.totalPnl, 1e-9),
      reason:
          '$label: dart↔rust totalPnl drift > 1e-9 — Welle U2-5 parity contract');
  expect(rustRuns[0].totalTrades, equals(dartRuns[0].metrics.totalTrades),
      reason: '$label: dart↔rust totalTrades mismatch');

  _printSummary(label, candles.length, dartRuns[0], rustRuns[0]);
}

Map<String, double> _paramsToMap(UtBotParams p) => {
      'ema_period': p.emaPeriod.toDouble(),
      'key_value': p.keyValue,
      'atr_period': p.atrPeriod.toDouble(),
      'smi_length': p.smiLength.toDouble(),
      'smi_k_smoothing': p.smiKSmoothing.toDouble(),
      'smi_d_smoothing': p.smiDSmoothing.toDouble(),
      'swing_lookback_bars': p.swingLookbackBars.toDouble(),
      'tp_rr_ratio': p.tpRrRatio,
      'risk_per_trade': p.riskPerTrade,
      'session_filter_enabled': p.sessionFilterEnabled ? 1.0 : 0.0,
      'session_start_hour_local': p.sessionStartHourLocal.toDouble(),
      'session_end_hour_local': p.sessionEndHourLocal.toDouble(),
      'smi_cross_above_zero': p.smiCrossAboveZero ? 1.0 : 0.0,
    };

Future<List<CandleData>> _fetchRange(
  String symbol,
  String interval,
  int startMs,
  int endMs,
) async {
  final client = BinanceApiClient();
  final intervalMs = _intervalToMs(interval);
  final all = <CandleData>[];
  var cursor = startMs;
  while (cursor < endMs) {
    final batch = await client.fetchHistoricalKlines(
      symbol: symbol,
      interval: interval,
      startTime: cursor,
      endTime: endMs,
      limit: 1000,
    );
    if (batch.isEmpty) break;
    all.addAll(batch);
    cursor = batch.last.timestamp + intervalMs;
    if (batch.length < 1000) break;
  }
  final seen = <int>{};
  final unique = all.where((c) => seen.add(c.timestamp)).toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return unique;
}

int _intervalToMs(String interval) {
  switch (interval) {
    case '1m':
      return 60 * 1000;
    case '5m':
      return 5 * 60 * 1000;
    case '15m':
      return 15 * 60 * 1000;
    case '1h':
      return 60 * 60 * 1000;
    case '4h':
      return 4 * 60 * 60 * 1000;
    case '1d':
      return 24 * 60 * 60 * 1000;
    default:
      throw ArgumentError('Unsupported interval for UT-Bot diagnostic: $interval');
  }
}

void _printSummary(
    String label, int numCandles, BacktestResult result, BacktestMetrics rust) {
  final m = result.metrics;
  final wins = result.trades.where((t) => t.pnl > 0).toList();
  final losses = result.trades.where((t) => t.pnl <= 0).toList();
  final grossProfit = wins.fold<double>(0, (s, t) => s + t.pnl);
  final grossLoss = losses.fold<double>(0, (s, t) => s + t.pnl.abs());
  final avgWin = wins.isEmpty ? 0.0 : grossProfit / wins.length;
  final avgLoss = losses.isEmpty ? 0.0 : grossLoss / losses.length;
  final realisedR = avgLoss > 0 ? avgWin / avgLoss : 0.0;
  final longTrades = result.trades.where((t) => t.direction == 'LONG').length;
  final shortTrades = result.trades.where((t) => t.direction == 'SHORT').length;

  // ignore: avoid_print
  print('================================================================');
  // ignore: avoid_print
  print('DIAGNOSE $label');
  // ignore: avoid_print
  print('  candles=$numCandles');
  // ignore: avoid_print
  print('  trades=${m.totalTrades}  long=$longTrades  short=$shortTrades  '
      'winning=${m.winningTrades}  losing=${m.losingTrades}');
  // ignore: avoid_print
  print('  totalPnl=${m.totalPnl.toStringAsFixed(6)} USDT '
      '(eq_final=${(_initialBalance + m.totalPnl).toStringAsFixed(6)})');
  // ignore: avoid_print
  print('  winRate=${m.winRate.toStringAsFixed(4)}%');
  // ignore: avoid_print
  print('  profitFactor=${m.profitFactor.toStringAsFixed(6)}');
  // ignore: avoid_print
  print('  sharpe=${m.sharpeRatio.toStringAsFixed(6)}');
  // ignore: avoid_print
  print('  maxDD%=${m.maxDrawdownPercent.toStringAsFixed(6)}');
  // ignore: avoid_print
  print('  avgWin=${avgWin.toStringAsFixed(6)}  '
      'avgLoss=${avgLoss.toStringAsFixed(6)}  '
      'realisedR=${realisedR.toStringAsFixed(4)}');
  // ignore: avoid_print
  print('  RUST mirror: trades=${rust.totalTrades}  '
      'pnl=${rust.totalPnl.toStringAsFixed(6)}  '
      'wr=${rust.winRate.toStringAsFixed(4)}%  '
      'sharpe=${rust.sharpeRatio.toStringAsFixed(6)}  '
      'ddPct=${rust.maxDrawdownPercent.toStringAsFixed(6)}');
  // ignore: avoid_print
  print('================================================================');
}
