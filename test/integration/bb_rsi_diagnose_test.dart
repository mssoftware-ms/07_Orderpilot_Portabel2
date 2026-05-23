/// Phase-2 BB+RSI diagnose-session sweep (2026-05-23).
///
/// Five sanity-check backtests around the Welle-2 baseline to identify
/// whether the XLSX-target shortfall is asset-/TF-driven, σ-driven, or
/// strategy-fundamental. ALL cases use the spec-default risk stack
/// (BB(200, EMA, 0.2σ) + RSI(3, 20/80) + swing-low SL N=20 + R:R 1:3 TP
/// + BE-trail at +1R + 2 % risk-per-trade) — only the `bb_stddev`
/// parameter or the candle source moves.
///
/// Each case runs the Dart engine three times and prints a single-line
/// summary (`pnl / wr / sharpe / ddpct / pf / trades / R`) so the QA
/// brief can pick numbers off the test log without re-extracting them.
/// `C1` additionally runs the Rust engine three times and asserts
/// Dart↔Rust parity at 1e-9 — the other cases stay Dart-only to keep
/// the manual run quick (parity is structurally identical because both
/// engines share the same BB-pre-compute / RSI / strategy code path,
/// pinned by the phase1_reference_backtest_test).
///
/// Run manually:
///   flutter test --plain-name "C1 BTCUSDT 4h" \
///     test/integration/bb_rsi_diagnose_test.dart
///   flutter test --plain-name "C2 ETHUSDT 1h" \
///     test/integration/bb_rsi_diagnose_test.dart
///   flutter test --plain-name "C3 BTCUSDT 1h sigma=0.5" \
///     test/integration/bb_rsi_diagnose_test.dart
///   flutter test --plain-name "C4 BTCUSDT 1h sigma=1.0" \
///     test/integration/bb_rsi_diagnose_test.dart
///   flutter test --plain-name "C5 BTCUSDT 1h sigma=2.0" \
///     test/integration/bb_rsi_diagnose_test.dart
///
/// All cases are SKIPPED in normal `flutter test` runs so the diagnostic
/// log doesn't pollute CI output and the manual run is opt-in only.
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
// 2024-01-01 00:00:00 UTC – 2024-07-01 00:00:00 UTC (end exclusive),
// identical to phase1_reference_backtest_test so the C-series numbers
// can be lined up bar-for-bar against the Welle-2 baseline.
const _startMs = 1704067200000;
const _endMs = 1719792000000;

/// Manual diagnostic — opt in via the `BB_RSI_DIAGNOSE=1` environment
/// variable so normal `flutter test` runs do NOT trigger a 6-month
/// Binance fetch and a Rust-bridge spin-up. A plain-name filter alone
/// would be insufficient because `flutter_test` always honours `skip:`
/// regardless of the filter set.
final Object? _skipReason = Platform.environment['BB_RSI_DIAGNOSE'] == '1'
    ? null
    : 'manual diagnostic — run with BB_RSI_DIAGNOSE=1 and --plain-name';

void main() {
  group('BB+RSI diagnose sweep', () {
    test('C1 BTCUSDT 4h sigma=0.2', () async {
      await _runDiagnose(
        label: 'C1 BTCUSDT 4h sigma=0.2',
        symbol: 'BTCUSDT',
        interval: '4h',
        params: const BbRsiParams(),
        runRust: true,
      );
    }, skip: _skipReason);

    test('C2 ETHUSDT 1h sigma=0.2', () async {
      await _runDiagnose(
        label: 'C2 ETHUSDT 1h sigma=0.2',
        symbol: 'ETHUSDT',
        interval: '1h',
        params: const BbRsiParams(),
      );
    }, skip: _skipReason);

    test('C3 BTCUSDT 1h sigma=0.5', () async {
      await _runDiagnose(
        label: 'C3 BTCUSDT 1h sigma=0.5',
        symbol: 'BTCUSDT',
        interval: '1h',
        params: const BbRsiParams(bbStdDev: 0.5),
      );
    }, skip: _skipReason);

    test('C4 BTCUSDT 1h sigma=1.0', () async {
      await _runDiagnose(
        label: 'C4 BTCUSDT 1h sigma=1.0',
        symbol: 'BTCUSDT',
        interval: '1h',
        params: const BbRsiParams(bbStdDev: 1.0),
      );
    }, skip: _skipReason);

    test('C5 BTCUSDT 1h sigma=2.0', () async {
      await _runDiagnose(
        label: 'C5 BTCUSDT 1h sigma=2.0',
        symbol: 'BTCUSDT',
        interval: '1h',
        params: const BbRsiParams(bbStdDev: 2.0),
      );
    }, skip: _skipReason);
  });
}

/// Fetch the requested candle range, run 3 Dart backtests (reproducibility
/// check), optionally 3 Rust backtests (parity spot-check) and print the
/// full numeric summary used by the QA brief.
Future<void> _runDiagnose({
  required String label,
  required String symbol,
  required String interval,
  required BbRsiParams params,
  bool runRust = false,
}) async {
  final candles = await _fetchRange(symbol, interval, _startMs, _endMs);
  expect(candles.length, greaterThan(50),
      reason: '$label sanity: expected sufficient candles, got ${candles.length}');

  final dartRuns = <BacktestResult>[];
  for (var i = 0; i < 3; i++) {
    dartRuns.add(BacktestService.runBbRsi(
      candles: candles,
      initialBalance: _initialBalance,
      feeRate: _feeRate,
      params: params,
    ));
  }

  // Reproducibility gate: any deviation is a regression and stops the
  // diagnostic — do NOT widen the assertion.
  for (var i = 1; i < 3; i++) {
    expect(dartRuns[i].metrics.totalPnl, equals(dartRuns[0].metrics.totalPnl),
        reason: '$label: dart run $i totalPnl differs from run 0');
    expect(dartRuns[i].metrics.totalTrades, equals(dartRuns[0].metrics.totalTrades),
        reason: '$label: dart run $i totalTrades differs');
  }

  if (runRust) {
    await RustBridge.initialize();
    final rustRuns = <BacktestMetrics>[];
    for (var i = 0; i < 3; i++) {
      rustRuns.add(await RustBridge.runBacktest(
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
            '$label: dart↔rust totalPnl drift > 1e-9 — Welle-2 parity contract');
    expect(rustRuns[0].totalTrades, equals(dartRuns[0].metrics.totalTrades),
        reason: '$label: dart↔rust totalTrades mismatch');
  }

  _printSummary(label, candles.length, dartRuns[0]);
}

Map<String, double> _paramsToMap(BbRsiParams p) => {
      'bb_period': p.bbPeriod.toDouble(),
      'bb_stddev': p.bbStdDev,
      'bb_ma_type': p.bbMaType.rustParamValue,
      'rsi_period': p.rsiPeriod.toDouble(),
      'rsi_oversold': p.rsiOversold,
      'rsi_overbought': p.rsiOverbought,
      'swing_lookback_bars': p.swingLookbackBars.toDouble(),
      'tp_rr_ratio': p.tpRrRatio,
      'risk_per_trade': p.riskPerTrade,
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
    case '15m':
      return 15 * 60 * 1000;
    case '1h':
      return 60 * 60 * 1000;
    case '4h':
      return 4 * 60 * 60 * 1000;
    case '1d':
      return 24 * 60 * 60 * 1000;
    default:
      throw ArgumentError('Unsupported interval for diagnostic: $interval');
  }
}

void _printSummary(String label, int numCandles, BacktestResult result) {
  final m = result.metrics;
  final wins = result.trades.where((t) => t.pnl > 0).toList();
  final losses = result.trades.where((t) => t.pnl <= 0).toList();
  final grossProfit = wins.fold<double>(0, (s, t) => s + t.pnl);
  final grossLoss = losses.fold<double>(0, (s, t) => s + t.pnl.abs());
  final avgWin = wins.isEmpty ? 0.0 : grossProfit / wins.length;
  final avgLoss = losses.isEmpty ? 0.0 : grossLoss / losses.length;
  final realisedR = avgLoss > 0 ? avgWin / avgLoss : 0.0;

  // ignore: avoid_print
  print('================================================================');
  // ignore: avoid_print
  print('DIAGNOSE $label');
  // ignore: avoid_print
  print('  candles=$numCandles');
  // ignore: avoid_print
  print('  trades=${m.totalTrades}  winning=${m.winningTrades}  '
      'losing=${m.losingTrades}');
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
  print('================================================================');
}
