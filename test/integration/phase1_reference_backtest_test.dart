/// Phase-1 Gate: Reference Backtest BTCUSDT 1h 2024-H1.
///
/// Per Plan rev3 §3.5 acceptance criteria. Three sequential runs against
/// real market data — last engineering checkpoint before v0.2.0 tag.
///
/// Proves:
///   1. Bit-exact reproducibility within Dart engine across 3 runs
///   2. Bit-exact reproducibility within Rust engine across 3 runs
///   3. Dart ↔ Rust numerical parity within 1e-9 on the full dataset
///   4. Observes F-04 PnL direction on real BTCUSDT data: post-F-04 the
///      default BB+RSI strategy realistically loses ~20% on a trend year,
///      which is the correct behavior (mean-reversion in a trend market).
///
/// F-09 fixed warmup-boundary off-by-one + RSI threshold harmonization
/// (Rust now matches Dart's `startIdx = max(bbPeriod, rsiPeriod + 1)`
/// and uses strict `>`/`<` operators on RSI thresholds). This test
/// guards against regressions in Phase-2/3 strategy work.
///
/// Tolerance is 1e-9. Wider drift = real engine divergence; do NOT widen.
/// Non-determinism within an engine (3-run failure) blocks the v0.2.0 tag.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/core/models/trade.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/binance_api_client.dart';
import 'package:trading_app/services/rust_bridge.dart';

const _symbol = 'BTCUSDT';
const _interval = '1h';
const _initialBalance = 10000.0;
const _feeRate = 0.0006; // Bitunix VIP0 taker (Plan rev2 §3.4)
// 2024-01-01 00:00:00 UTC -- 2024-07-01 00:00:00 UTC (end exclusive)
const _startMs = 1704067200000;
const _endMs = 1719792000000;
const _intervalMs = 60 * 60 * 1000;

void main() {
  late List<CandleData> candles;

  setUpAll(() async {
    await RustBridge.initialize();
    candles = await _fetchRange(_symbol, _interval, _startMs, _endMs);
  });

  test(
    'Phase-1 reference: 3x dart + 3x rust reproducibility + 1e-9 parity',
    () async {
      expect(
        candles.length,
        greaterThan(4000),
        reason: 'Sanity: 6 months × 24h ≈ 4320 1h candles expected, got '
            '${candles.length}',
      );

      final dartRuns = <BacktestResult>[];
      for (var i = 0; i < 3; i++) {
        dartRuns.add(BacktestService.runBbRsi(
          candles: candles,
          initialBalance: _initialBalance,
          feeRate: _feeRate,
        ));
      }

      final rustRuns = <BacktestMetrics>[];
      for (var i = 0; i < 3; i++) {
        rustRuns.add(await RustBridge.runBacktest(
          candles: candles,
          initialBalance: _initialBalance,
          feeRate: _feeRate,
        ));
      }

      _printReport(candles.length, dartRuns, rustRuns);

      expect(
        dartRuns[0].metrics.totalTrades,
        greaterThan(0),
        reason: 'BB+RSI default params produced 0 trades on 6 months of '
            'BTCUSDT 1h — strategy too conservative or data corrupted',
      );

      for (var i = 1; i < 3; i++) {
        final ref = dartRuns[0].metrics;
        final cur = dartRuns[i].metrics;
        expect(cur.totalPnl, equals(ref.totalPnl),
            reason: 'Dart run $i totalPnl != run 0 → non-determinism');
        expect(cur.winRate, equals(ref.winRate),
            reason: 'Dart run $i winRate != run 0');
        expect(cur.sharpeRatio, equals(ref.sharpeRatio),
            reason: 'Dart run $i sharpeRatio != run 0');
        expect(cur.maxDrawdown, equals(ref.maxDrawdown),
            reason: 'Dart run $i maxDrawdown != run 0');
        expect(cur.maxDrawdownPercent, equals(ref.maxDrawdownPercent),
            reason: 'Dart run $i maxDrawdownPercent != run 0');
        expect(cur.totalTrades, equals(ref.totalTrades),
            reason: 'Dart run $i totalTrades != run 0');
      }

      for (var i = 1; i < 3; i++) {
        final ref = rustRuns[0];
        final cur = rustRuns[i];
        expect(cur.totalPnl, equals(ref.totalPnl),
            reason: 'Rust run $i totalPnl != run 0 → non-determinism');
        expect(cur.winRate, equals(ref.winRate),
            reason: 'Rust run $i winRate != run 0');
        expect(cur.sharpeRatio, equals(ref.sharpeRatio),
            reason: 'Rust run $i sharpeRatio != run 0');
        expect(cur.maxDrawdown, equals(ref.maxDrawdown),
            reason: 'Rust run $i maxDrawdown != run 0');
        expect(cur.maxDrawdownPercent, equals(ref.maxDrawdownPercent),
            reason: 'Rust run $i maxDrawdownPercent != run 0');
        expect(cur.totalTrades, equals(ref.totalTrades),
            reason: 'Rust run $i totalTrades != run 0');
      }

      final d = dartRuns[0].metrics;
      final r = rustRuns[0];
      expect(r.totalPnl, closeTo(d.totalPnl, 1e-9),
          reason: 'dart↔rust totalPnl drift > 1e-9 — do NOT widen, '
              'investigate F-01/F-02/F-03 ordering/rounding');
      expect(r.winRate, closeTo(d.winRate, 1e-9),
          reason: 'dart↔rust winRate drift > 1e-9');
      expect(r.sharpeRatio, closeTo(d.sharpeRatio, 1e-9),
          reason: 'dart↔rust sharpeRatio drift > 1e-9 — equity series '
              'mismatch, see F-03b');
      expect(r.maxDrawdown, closeTo(d.maxDrawdown, 1e-9),
          reason: 'dart↔rust maxDrawdown drift > 1e-9 — running-peak '
              'mismatch, see F-03c');
      expect(r.maxDrawdownPercent, closeTo(d.maxDrawdownPercent, 1e-9));
      expect(r.totalTrades, equals(d.totalTrades),
          reason: 'dart↔rust totalTrades must be identical (integer)');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<List<CandleData>> _fetchRange(
  String symbol,
  String interval,
  int startMs,
  int endMs,
) async {
  final client = BinanceApiClient();
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
    cursor = batch.last.timestamp + _intervalMs;
    if (batch.length < 1000) break;
  }
  final seen = <int>{};
  final unique = all.where((c) => seen.add(c.timestamp)).toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return unique;
}

void _printReport(
  int candlesLen,
  List<BacktestResult> dartRuns,
  List<BacktestMetrics> rustRuns,
) {
  final startIso =
      DateTime.fromMillisecondsSinceEpoch(_startMs, isUtc: true).toIso8601String();
  final endIso =
      DateTime.fromMillisecondsSinceEpoch(_endMs, isUtc: true).toIso8601String();
  final buf = StringBuffer()
    ..writeln('================================================================')
    ..writeln('Phase-1 Reference Backtest Result')
    ..writeln('================================================================')
    ..writeln('Setup:')
    ..writeln('  Symbol:            $_symbol')
    ..writeln('  Timeframe:         $_interval')
    ..writeln('  Date range UTC:    $startIso')
    ..writeln('                  -- $endIso (exclusive)')
    ..writeln('  Strategy:          BB(20, 2.0σ) + RSI(14, 30/70) default')
    ..writeln('  Initial capital:   ${_initialBalance.toStringAsFixed(2)} USDT')
    ..writeln('  Fee rate:          ${(_feeRate * 100).toStringAsFixed(4)}% '
        '(Bitunix VIP0 taker)')
    ..writeln('  Slippage:          0 bps (Plan rev2 §3.4)')
    ..writeln('  Candles processed: $candlesLen')
    ..writeln();
  for (var i = 0; i < dartRuns.length; i++) {
    final m = dartRuns[i].metrics;
    buf.writeln('Run ${i + 1} (Dart): ${_fmt(m.totalPnl, m.winRate,
        _initialBalance + m.totalPnl, m.sharpeRatio, m.maxDrawdownPercent,
        m.totalTrades)}');
  }
  buf.writeln();
  for (var i = 0; i < rustRuns.length; i++) {
    final m = rustRuns[i];
    buf.writeln('Run ${i + 1} (Rust): ${_fmt(m.totalPnl, m.winRate,
        _initialBalance + m.totalPnl, m.sharpeRatio, m.maxDrawdownPercent,
        m.totalTrades)}');
  }
  buf
    ..writeln()
    ..writeln('Reproducibility:')
    ..writeln('  Dart 3x bit-exact:  ${_bitExact3(dartRuns.map((r) => r.metrics).toList())}')
    ..writeln('  Rust 3x bit-exact:  ${_bitExact3(rustRuns)}')
    ..writeln('  Dart vs Rust 1e-9: ${_parity1e9(dartRuns[0].metrics, rustRuns[0])}')
    ..writeln('================================================================');
  // ignore: avoid_print
  print(buf.toString());
}

String _fmt(double pnl, double wr, double eq, double sharpe, double ddPct,
    int trades) {
  return 'pnl=${pnl.toStringAsFixed(6)}, '
      'wr=${wr.toStringAsFixed(4)}%, '
      'eq=${eq.toStringAsFixed(6)}, '
      'sharpe=${sharpe.toStringAsFixed(6)}, '
      'ddPct=${ddPct.toStringAsFixed(6)}%, '
      'trades=$trades';
}

String _bitExact3(List<BacktestMetrics> runs) {
  bool eq(BacktestMetrics a, BacktestMetrics b) =>
      a.totalPnl == b.totalPnl &&
      a.winRate == b.winRate &&
      a.sharpeRatio == b.sharpeRatio &&
      a.maxDrawdown == b.maxDrawdown &&
      a.maxDrawdownPercent == b.maxDrawdownPercent &&
      a.totalTrades == b.totalTrades;
  return (eq(runs[0], runs[1]) && eq(runs[1], runs[2])) ? '✓' : '✗';
}

String _parity1e9(BacktestMetrics d, BacktestMetrics r) {
  bool ok(double x, double y) => (x - y).abs() <= 1e-9;
  final pass = ok(d.totalPnl, r.totalPnl) &&
      ok(d.winRate, r.winRate) &&
      ok(d.sharpeRatio, r.sharpeRatio) &&
      ok(d.maxDrawdown, r.maxDrawdown) &&
      ok(d.maxDrawdownPercent, r.maxDrawdownPercent) &&
      d.totalTrades == r.totalTrades;
  return pass ? '✓' : '✗';
}
