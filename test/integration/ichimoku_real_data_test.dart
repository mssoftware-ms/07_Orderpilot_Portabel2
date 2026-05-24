/// Phase-2 Ichimoku real-data acceptance sweep (Welle I3).
///
/// Eskalations-Leiter analogous to BB+RSI / UT-Bot diagnose sweeps:
///   Phase A — Test 1  Strict-Spec Baseline (defaults from ichimoku_spec §1)
///   Phase B — Test 2  Score-Threshold sweep (spec §12.2 path-B candidate)
///   Phase B — Test 3  Mandatory sanity sweep (spec §13.3): alt TF, alt
///                     asset, tenkan/kijun variations
///
/// Each test runs the Dart engine 3 times (reproducibility gate) and the
/// Rust engine 3 times (FFI parity at 1e-9), and prints a single summary
/// block matching the diagnose output format from BB+RSI / UT-Bot so the
/// QA brief can pick numbers off the test log without re-extracting them.
///
/// Manual run (opt-in via env var, so normal `flutter test` does NOT hit
/// Binance for 18k candles):
///
///   ICHIMOKU_DIAGNOSE=1 flutter test --plain-name "Test 1 BTCUSDT 1h strict" \
///     test/integration/ichimoku_real_data_test.dart
///
/// Date range: 2023-04-01 00:00:00 UTC → 2025-05-01 00:00:00 UTC (760
/// days ≈ 18250 1h candles). Matches the I3 brief and the spec §13.2
/// "760 Tage" target window. Widening or shifting must be reflected in
/// the §13 actual-results table.
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
// 2023-04-01 00:00:00 UTC
const _startMs = 1680307200000;
// 2025-05-01 00:00:00 UTC
const _endMs = 1746057600000;

final Object? _skipReason = Platform.environment['ICHIMOKU_DIAGNOSE'] == '1'
    ? null
    : 'manual diagnostic — run with ICHIMOKU_DIAGNOSE=1 and --plain-name';

void main() {
  group('Ichimoku real-data acceptance', () {
    // ─── Phase A ────────────────────────────────────────────────────────
    test('Test 1 BTCUSDT 1h strict-spec baseline', () async {
      await _runDiagnose(
        label: 'Test 1 BTCUSDT 1h strict (score=60)',
        symbol: 'BTCUSDT',
        interval: '1h',
        params: const IchimokuParams(),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    // ─── Phase B — Test 2: Score-Threshold sweep (spec §12.2) ──────────
    test('Test 2a BTCUSDT 1h score=40 (looser confluence)', () async {
      await _runDiagnose(
        label: 'Test 2a BTCUSDT 1h score=40',
        symbol: 'BTCUSDT',
        interval: '1h',
        params: const IchimokuParams(scoreThreshold: 40),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 2b BTCUSDT 1h score=80 (stricter confluence)', () async {
      await _runDiagnose(
        label: 'Test 2b BTCUSDT 1h score=80',
        symbol: 'BTCUSDT',
        interval: '1h',
        params: const IchimokuParams(scoreThreshold: 80),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    // ─── Phase B — Test 3: Mandatory sanity sweep (spec §13.3) ─────────
    test('Test 3a BTCUSDT 4h strict-spec', () async {
      await _runDiagnose(
        label: 'Test 3a BTCUSDT 4h strict (score=60)',
        symbol: 'BTCUSDT',
        interval: '4h',
        params: const IchimokuParams(),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 3b ETHUSDT 1h strict-spec', () async {
      await _runDiagnose(
        label: 'Test 3b ETHUSDT 1h strict (score=60)',
        symbol: 'ETHUSDT',
        interval: '1h',
        params: const IchimokuParams(),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 3c BTCUSDT 1h tenkan=7/kijun=21', () async {
      await _runDiagnose(
        label: 'Test 3c BTCUSDT 1h tenkan=7 kijun=21',
        symbol: 'BTCUSDT',
        interval: '1h',
        params: const IchimokuParams(tenkanPeriod: 7, kijunPeriod: 21),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));

    test('Test 3d BTCUSDT 1h tenkan=13/kijun=40', () async {
      await _runDiagnose(
        label: 'Test 3d BTCUSDT 1h tenkan=13 kijun=40',
        symbol: 'BTCUSDT',
        interval: '1h',
        params: const IchimokuParams(tenkanPeriod: 13, kijunPeriod: 40),
      );
    }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));
  });
}

Future<void> _runDiagnose({
  required String label,
  required String symbol,
  required String interval,
  required IchimokuParams params,
}) async {
  final candles = await _fetchRange(symbol, interval, _startMs, _endMs);
  expect(candles.length, greaterThan(500),
      reason: '$label sanity: expected >500 candles, got ${candles.length}');

  final dartRuns = <BacktestResult>[];
  for (var i = 0; i < 3; i++) {
    dartRuns.add(BacktestService.runIchimoku(
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
    rustRuns.add(await RustBridge.runIchimokuBacktest(
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
          '$label: dart↔rust totalPnl drift > 1e-9 — Welle I2-6 parity contract');
  expect(rustRuns[0].totalTrades, equals(dartRuns[0].metrics.totalTrades),
      reason: '$label: dart↔rust totalTrades mismatch');

  _printSummary(label, candles.length, dartRuns[0], rustRuns[0]);
}

Map<String, double> _paramsToMap(IchimokuParams p) => {
      'tenkan_period': p.tenkanPeriod.toDouble(),
      'kijun_period': p.kijunPeriod.toDouble(),
      'senkou_b_period': p.senkouBPeriod.toDouble(),
      'shift': p.shift.toDouble(),
      'score_threshold': p.scoreThreshold.toDouble(),
      'tp_rr_ratio': p.tpRrRatio,
      'risk_per_trade': p.riskPerTrade,
      'swing_lookback_bars': p.swingLookbackBars.toDouble(),
      'session_filter_enabled': p.sessionFilterEnabled ? 1.0 : 0.0,
      'session_start_hour': p.sessionStartHour.toDouble(),
      'session_end_hour': p.sessionEndHour.toDouble(),
      'tz_offset_hours': p.tzOffsetHours.toDouble(),
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
      throw ArgumentError('Unsupported interval for Ichimoku diagnostic: $interval');
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
  final profitPct = (m.totalPnl / _initialBalance) * 100.0;

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
  print('  profit%=${profitPct.toStringAsFixed(4)}');
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
