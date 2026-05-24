/// Phase-2.5 Welle R3 ADX regime-filter real-data sweep.
///
/// Twelve gated backtests = 3 strategies × 4 ADX configs. Each test
/// runs the Dart engine 3 times (reproducibility gate) and the Rust
/// engine 3 times (Dart↔Rust parity at 1e-9, skipped when trades=0).
///
/// Goal: empirically classify whether the ADX regime filter rescues
/// the XLSX-band acceptance for any of the three Phase-2 strategies
/// (→ Pfad B), surfaces a useful Phase-3 optimizer-insight (→ Pfad C
/// augmented), or leaves the strategies structurally unchanged
/// (→ Pfad C).
///
/// Skipped by default — opt-in via `ADX_SWEEP=1` so a normal
/// `flutter test` does NOT trigger 12 Binance fetches (~40k candles
/// in aggregate) and 72 backtests. The plain-name filter alone is
/// insufficient because `flutter_test` always honours `skip:`.
///
/// Manual run:
///   ADX_SWEEP=1 flutter test --plain-name "ADX_SWEEP" \
///     test/integration/regime_filter_sweep_test.dart
///
/// Per strategy, [C0] re-runs the Welle-3 baseline (adx_filter_enabled=
/// false) so the sweep table is internally consistent — no copy-paste
/// from the prior Ichimoku/UT-Bot/BB+RSI diagnose docs. Configs:
///
///   C0 — baseline (adx_filter_enabled=false)
///   C1 — adx_filter_enabled=true, threshold=25, use_di_confluence=false
///   C2 — adx_filter_enabled=true, threshold=35, use_di_confluence=false
///   C3 — adx_filter_enabled=true, threshold=25, use_di_confluence=true
///
/// Date ranges mirror the per-strategy Welle-3 spec windows so the
/// numbers line up bar-for-bar against the prior diagnose docs:
///   BB+RSI    BTCUSDT 4h   2024-01-01 → 2024-07-01 (~1086 candles)
///   UT Bot    BTCUSDT 5m   2024-01-01 → 2024-03-07 (~19000 candles)
///   Ichimoku  BTCUSDT 1h   2023-04-01 → 2025-05-01 (~18250 candles)
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

// Per-strategy ranges
// BB+RSI: 2024-01-01 00:00:00 UTC → 2024-07-01 00:00:00 UTC
const _bbRsiStartMs = 1704067200000;
const _bbRsiEndMs = 1719792000000;
// UT-Bot: 2024-01-01 00:00:00 UTC → 2024-03-07 00:00:00 UTC
const _utBotStartMs = 1704067200000;
const _utBotEndMs = 1709769600000;
// Ichimoku: 2023-04-01 00:00:00 UTC → 2025-05-01 00:00:00 UTC
const _ichimokuStartMs = 1680307200000;
const _ichimokuEndMs = 1746057600000;

final Object? _skipReason = Platform.environment['ADX_SWEEP'] == '1'
    ? null
    : 'manual ADX sweep — run with ADX_SWEEP=1 and --plain-name "ADX_SWEEP"';

/// Four ADX configurations swept against every strategy.
///
/// `(label, enabled, threshold, useDiConfluence)`.
const _adxConfigs = <(String, bool, double, bool)>[
  ('C0 baseline', false, 0.0, false),
  ('C1 thr=25', true, 25.0, false),
  ('C2 thr=35', true, 35.0, false),
  ('C3 thr=25 +DI', true, 25.0, true),
];

void main() {
  group('ADX_SWEEP BB+RSI BTCUSDT 4h 2024-H1', () {
    for (final (label, enabled, threshold, useDi) in _adxConfigs) {
      test(label, () async {
        await _runBbRsi(
          label: 'ADX_SWEEP BB+RSI $label',
          params: BbRsiParams(
            adxFilterEnabled: enabled,
            adxThreshold: threshold,
            adxUseDiConfluence: useDi,
          ),
        );
      }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));
    }
  });

  group('ADX_SWEEP UT Bot BTCUSDT 5m 66d', () {
    for (final (label, enabled, threshold, useDi) in _adxConfigs) {
      test(label, () async {
        await _runUtBot(
          label: 'ADX_SWEEP UT Bot $label',
          params: UtBotParams(
            adxFilterEnabled: enabled,
            adxThreshold: threshold,
            adxUseDiConfluence: useDi,
          ),
        );
      }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));
    }
  });

  group('ADX_SWEEP Ichimoku BTCUSDT 1h 760d', () {
    for (final (label, enabled, threshold, useDi) in _adxConfigs) {
      test(label, () async {
        await _runIchimoku(
          label: 'ADX_SWEEP Ichimoku $label',
          params: IchimokuParams(
            adxFilterEnabled: enabled,
            adxThreshold: threshold,
            adxUseDiConfluence: useDi,
          ),
        );
      }, skip: _skipReason, timeout: const Timeout(Duration(minutes: 30)));
    }
  });
}

// ─── BB+RSI runner ──────────────────────────────────────────────────────────

Future<void> _runBbRsi({
  required String label,
  required BbRsiParams params,
}) async {
  final candles =
      await _fetchRange('BTCUSDT', '4h', _bbRsiStartMs, _bbRsiEndMs);
  expect(candles.length, greaterThan(500),
      reason: '$label sanity: expected >500 candles, got ${candles.length}');

  final dartRuns = <BacktestResult>[];
  for (var i = 0; i < 3; i++) {
    dartRuns.add(BacktestService.runBbRsi(
      candles: candles,
      initialBalance: _initialBalance,
      feeRate: _feeRate,
      params: params,
    ));
  }
  _assertDartDeterminism(label, dartRuns);

  final dartTrades = dartRuns[0].metrics.totalTrades;
  BacktestMetrics? rustHead;
  if (dartTrades > 0) {
    await RustBridge.initialize();
    final rustRuns = <BacktestMetrics>[];
    for (var i = 0; i < 3; i++) {
      rustRuns.add(await RustBridge.runBacktest(
        candles: candles,
        initialBalance: _initialBalance,
        feeRate: _feeRate,
        strategyParams: _bbRsiParamsToMap(params),
      ));
    }
    _assertRustDeterminism(label, rustRuns);
    expect(rustRuns[0].totalPnl, closeTo(dartRuns[0].metrics.totalPnl, 1e-9),
        reason:
            '$label: dart↔rust totalPnl drift > 1e-9 — Welle R2-2 parity contract');
    expect(rustRuns[0].totalTrades, equals(dartTrades),
        reason: '$label: dart↔rust totalTrades mismatch');
    rustHead = rustRuns[0];
  }

  _printSummary(label, candles.length, dartRuns[0], rustHead);
}

// ─── UT-Bot runner ──────────────────────────────────────────────────────────

Future<void> _runUtBot({
  required String label,
  required UtBotParams params,
}) async {
  final candles =
      await _fetchRange('BTCUSDT', '5m', _utBotStartMs, _utBotEndMs);
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
  _assertDartDeterminism(label, dartRuns);

  final dartTrades = dartRuns[0].metrics.totalTrades;
  BacktestMetrics? rustHead;
  if (dartTrades > 0) {
    await RustBridge.initialize();
    final rustRuns = <BacktestMetrics>[];
    for (var i = 0; i < 3; i++) {
      rustRuns.add(await RustBridge.runUtBotBacktest(
        candles: candles,
        initialBalance: _initialBalance,
        feeRate: _feeRate,
        strategyParams: _utBotParamsToMap(params),
      ));
    }
    _assertRustDeterminism(label, rustRuns);
    expect(rustRuns[0].totalPnl, closeTo(dartRuns[0].metrics.totalPnl, 1e-9),
        reason:
            '$label: dart↔rust totalPnl drift > 1e-9 — Welle R2-3 parity contract');
    expect(rustRuns[0].totalTrades, equals(dartTrades),
        reason: '$label: dart↔rust totalTrades mismatch');
    rustHead = rustRuns[0];
  }

  _printSummary(label, candles.length, dartRuns[0], rustHead);
}

// ─── Ichimoku runner ────────────────────────────────────────────────────────

Future<void> _runIchimoku({
  required String label,
  required IchimokuParams params,
}) async {
  final candles =
      await _fetchRange('BTCUSDT', '1h', _ichimokuStartMs, _ichimokuEndMs);
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
  _assertDartDeterminism(label, dartRuns);

  final dartTrades = dartRuns[0].metrics.totalTrades;
  BacktestMetrics? rustHead;
  if (dartTrades > 0) {
    await RustBridge.initialize();
    final rustRuns = <BacktestMetrics>[];
    for (var i = 0; i < 3; i++) {
      rustRuns.add(await RustBridge.runIchimokuBacktest(
        candles: candles,
        initialBalance: _initialBalance,
        feeRate: _feeRate,
        strategyParams: _ichimokuParamsToMap(params),
      ));
    }
    _assertRustDeterminism(label, rustRuns);
    expect(rustRuns[0].totalPnl, closeTo(dartRuns[0].metrics.totalPnl, 1e-9),
        reason:
            '$label: dart↔rust totalPnl drift > 1e-9 — Welle R2-4 parity contract');
    expect(rustRuns[0].totalTrades, equals(dartTrades),
        reason: '$label: dart↔rust totalTrades mismatch');
    rustHead = rustRuns[0];
  }

  _printSummary(label, candles.length, dartRuns[0], rustHead);
}

// ─── Determinism gates ──────────────────────────────────────────────────────

void _assertDartDeterminism(String label, List<BacktestResult> runs) {
  for (var i = 1; i < runs.length; i++) {
    expect(runs[i].metrics.totalPnl, equals(runs[0].metrics.totalPnl),
        reason: '$label: dart run $i totalPnl differs from run 0');
    expect(runs[i].metrics.totalTrades, equals(runs[0].metrics.totalTrades),
        reason: '$label: dart run $i totalTrades differs');
  }
}

void _assertRustDeterminism(String label, List<BacktestMetrics> runs) {
  for (var i = 1; i < runs.length; i++) {
    expect(runs[i].totalPnl, equals(runs[0].totalPnl),
        reason: '$label: rust run $i totalPnl differs');
    expect(runs[i].totalTrades, equals(runs[0].totalTrades),
        reason: '$label: rust run $i totalTrades differs');
  }
}

// ─── Param maps (mirror manifest keys 1:1) ──────────────────────────────────

Map<String, double> _bbRsiParamsToMap(BbRsiParams p) => {
      'bb_period': p.bbPeriod.toDouble(),
      'bb_stddev': p.bbStdDev,
      'bb_ma_type': p.bbMaType.rustParamValue,
      'rsi_period': p.rsiPeriod.toDouble(),
      'rsi_oversold': p.rsiOversold,
      'rsi_overbought': p.rsiOverbought,
      'swing_lookback_bars': p.swingLookbackBars.toDouble(),
      'tp_rr_ratio': p.tpRrRatio,
      'risk_per_trade': p.riskPerTrade,
      'adx_filter_enabled': p.adxFilterEnabled ? 1.0 : 0.0,
      'adx_threshold': p.adxThreshold,
      'adx_period': p.adxPeriod.toDouble(),
      'adx_use_di_confluence': p.adxUseDiConfluence ? 1.0 : 0.0,
    };

Map<String, double> _utBotParamsToMap(UtBotParams p) => {
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
      'adx_filter_enabled': p.adxFilterEnabled ? 1.0 : 0.0,
      'adx_threshold': p.adxThreshold,
      'adx_period': p.adxPeriod.toDouble(),
      'adx_use_di_confluence': p.adxUseDiConfluence ? 1.0 : 0.0,
    };

Map<String, double> _ichimokuParamsToMap(IchimokuParams p) => {
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
      'adx_filter_enabled': p.adxFilterEnabled ? 1.0 : 0.0,
      'adx_threshold': p.adxThreshold,
      'adx_period': p.adxPeriod.toDouble(),
      'adx_use_di_confluence': p.adxUseDiConfluence ? 1.0 : 0.0,
    };

// ─── Binance range fetch (cached via BinanceApiClient) ──────────────────────

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
      throw ArgumentError('Unsupported interval for ADX sweep: $interval');
  }
}

// ─── Output (matches existing diagnose summary block) ───────────────────────

void _printSummary(
  String label,
  int numCandles,
  BacktestResult result,
  BacktestMetrics? rust,
) {
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
  if (rust != null) {
    // ignore: avoid_print
    print('  RUST mirror: trades=${rust.totalTrades}  '
        'pnl=${rust.totalPnl.toStringAsFixed(6)}  '
        'wr=${rust.winRate.toStringAsFixed(4)}%  '
        'sharpe=${rust.sharpeRatio.toStringAsFixed(6)}  '
        'ddPct=${rust.maxDrawdownPercent.toStringAsFixed(6)}');
  } else {
    // ignore: avoid_print
    print('  RUST mirror: SKIPPED (dart trades=0, nothing numeric to parity-gate)');
  }
  // ignore: avoid_print
  print('================================================================');
}
