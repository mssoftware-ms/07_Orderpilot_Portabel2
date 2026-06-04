/// F-10 diagnostic + regression lock: first per-trade Dart↔Rust divergence.
///
/// The Phase-1 reference backtest (`phase1_reference_backtest_test.dart`)
/// only compares aggregate metrics, so when its `closeTo(1e-9)` PnL
/// assertion fails it cannot say *which* trade — or *which subsystem* —
/// drifts. This test loads the identical BTCUSDT 1h 2024-H1 dataset, runs
/// both engines, and walks the trade logs in lock-step to surface the
/// FIRST trade whose net PnL diverges by more than 1e-12.
///
/// The printed report (between the BEGIN/END markers) is archived under
/// `01_Projectplan/F-10_first_divergence_report.txt` (Sub-task F-10-A.2).
/// Per-trade `quantity` is the key tell: a `rust.qty / dart.qty` ratio of
/// exactly `1 / (1 - feeRate)` localises the drift to entry sizing
/// (N-13: "entry fee does not shrink position" applied in Rust but not Dart).
///
/// After the F-10-B fix this test must show NO divergence and stays in the
/// repo as a lock: it passes on parity and fails (with a fresh report) on
/// any future per-trade drift. Tolerance is 1e-12 — do NOT widen.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/binance_api_client.dart';
import 'package:trading_app/services/rust_bridge.dart';
import 'package:trading_app/src/bridge/api.dart' as rust;

const _symbol = 'BTCUSDT';
const _interval = '1h';
const _initialBalance = 10000.0;
const _feeRate = 0.0006; // Bitunix VIP0 taker — same as Phase-1.
const _startMs = 1704067200000; // 2024-01-01 00:00:00 UTC
const _endMs = 1719792000000; // 2024-07-01 00:00:00 UTC (exclusive)
const _intervalMs = 60 * 60 * 1000;

/// Per-trade comparison record, engine-agnostic.
class _TradeView {
  final int entryTs;
  final int exitTs;
  final String direction; // 'LONG' | 'SHORT'
  final double entryPrice;
  final double exitPrice;
  final double quantity;
  final double pnl;
  final String exitReason;

  const _TradeView({
    required this.entryTs,
    required this.exitTs,
    required this.direction,
    required this.entryPrice,
    required this.exitPrice,
    required this.quantity,
    required this.pnl,
    required this.exitReason,
  });

  bool get isLong => direction == 'LONG';

  /// Gross PnL before fees, derived purely from price × quantity.
  double get gross =>
      isLong ? (exitPrice - entryPrice) * quantity : (entryPrice - exitPrice) * quantity;

  /// Total fees (entry + exit) implied by `gross - net`. For the Dart side
  /// this equals the explicit `ClosedTrade.fees`; the Rust per-trade payload
  /// carries no fee field, so the implied value is the only cross-engine
  /// comparable.
  double get impliedFees => gross - pnl;
}

void main() {
  late List<CandleData> candles;

  setUpAll(() async {
    await RustBridge.initialize();
    candles = await _fetchRange(_symbol, _interval, _startMs, _endMs);
  });

  test(
    'F-10: first per-trade Dart↔Rust PnL divergence (lock at 1e-12)',
    () async {
      expect(
        RustBridge.isNativeAvailable,
        isTrue,
        reason: 'Native Rust engine not loaded — build it first with '
            '`bash tool/build_rust.sh release`. Without it the comparison '
            'is meaningless (Dart-vs-Dart).',
      );
      expect(
        candles.length,
        greaterThan(4000),
        reason: 'Sanity: ~4320 1h candles expected, got ${candles.length}',
      );

      final dartTrades = _dartTrades(candles);
      final rustTrades = await _rustTrades(candles);

      // Sanity gate: if trade counts already differ the drift is in the
      // signal logic, not PnL — a different investigation (out of F-10 scope).
      expect(
        rustTrades.length,
        equals(dartTrades.length),
        reason: 'Trade-count mismatch (dart=${dartTrades.length}, '
            'rust=${rustTrades.length}) — signal-logic drift, not a PnL drift. '
            'Stop and diagnose entry/exit conditions, not sizing/fees.',
      );

      final n = dartTrades.length;
      var firstDivergence = -1;
      for (var i = 0; i < n; i++) {
        if ((dartTrades[i].pnl - rustTrades[i].pnl).abs() > 1e-12) {
          firstDivergence = i;
          break;
        }
      }

      final report = _buildReport(dartTrades, rustTrades, firstDivergence);
      // ignore: avoid_print
      print(report);

      expect(
        firstDivergence,
        equals(-1),
        reason: 'Per-trade PnL divergence found — see report above. '
            'After the F-10-B fix this must be -1 (no divergence).',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

List<_TradeView> _dartTrades(List<CandleData> candles) {
  final result = BacktestService.runBbRsi(
    candles: candles,
    initialBalance: _initialBalance,
    feeRate: _feeRate,
  );
  return result.trades
      .map((t) => _TradeView(
            entryTs: t.entryTimestamp,
            exitTs: t.exitTimestamp,
            direction: t.direction,
            entryPrice: t.entryPrice,
            exitPrice: t.exitPrice,
            quantity: t.quantity,
            pnl: t.pnl,
            exitReason: t.exitReason,
          ))
      .toList();
}

Future<List<_TradeView>> _rustTrades(List<CandleData> candles) async {
  final candlesJson = jsonEncode(candles.map((c) => c.toRustJson()).toList());
  final responseJson = await rust.runBbRsiBacktest(
    candlesJson: candlesJson,
    paramsJson: '{}',
    initialBalance: _initialBalance,
    feeRate: _feeRate,
  );
  final decoded = jsonDecode(responseJson) as Map<String, dynamic>;
  if (decoded.containsKey('error')) {
    throw Exception('Rust backtest failed: ${decoded['error']}');
  }
  final metrics = decoded['metrics'] as Map<String, dynamic>;
  final trades = (metrics['trades'] as List<dynamic>).cast<Map<String, dynamic>>();
  return trades.map((t) {
    final side = t['side'] as String; // 'Long' | 'Short'
    return _TradeView(
      entryTs: (t['entry_time'] as num).toInt(),
      exitTs: (t['exit_time'] as num).toInt(),
      direction: side == 'Long' ? 'LONG' : 'SHORT',
      entryPrice: (t['entry_price'] as num).toDouble(),
      exitPrice: (t['exit_price'] as num).toDouble(),
      quantity: (t['quantity'] as num).toDouble(),
      pnl: (t['pnl'] as num).toDouble(),
      exitReason: jsonEncode(t['exit_reason']),
    );
  }).toList();
}

String _buildReport(
  List<_TradeView> dart,
  List<_TradeView> rust,
  int idx,
) {
  final dartTotal = dart.fold<double>(0, (s, t) => s + t.pnl);
  final rustTotal = rust.fold<double>(0, (s, t) => s + t.pnl);
  final buf = StringBuffer()
    ..writeln('===== F-10 FIRST DIVERGENCE REPORT BEGIN =====')
    ..writeln('symbol            = $_symbol $_interval')
    ..writeln('range UTC ms      = $_startMs .. $_endMs (exclusive)')
    ..writeln('fee_rate          = $_feeRate')
    ..writeln('dart.trades       = ${dart.length}')
    ..writeln('rust.trades       = ${rust.length}')
    ..writeln('dart.total_pnl    = ${dartTotal.toStringAsFixed(6)}')
    ..writeln('rust.total_pnl    = ${rustTotal.toStringAsFixed(6)}')
    ..writeln('total_drift       = ${(rustTotal - dartTotal).toStringAsFixed(6)}');

  if (idx < 0) {
    buf
      ..writeln('first_divergence  = NONE (all ${dart.length} trades within 1e-12)')
      ..writeln('===== F-10 FIRST DIVERGENCE REPORT END =====');
    return buf.toString();
  }

  final d = dart[idx];
  final r = rust[idx];
  final qtyRatio = d.quantity != 0 ? r.quantity / d.quantity : double.nan;
  buf
    ..writeln('first_divergence at trade #$idx:')
    ..writeln('  entry_ts          = ${d.entryTs}  (rust ${r.entryTs})')
    ..writeln('  exit_ts           = ${d.exitTs}  (rust ${r.exitTs})')
    ..writeln('  direction         = ${d.direction}  (rust ${r.direction})')
    ..writeln('  exit_reason       = ${d.exitReason}  (rust ${r.exitReason})')
    ..writeln('  dart.entry_price  = ${d.entryPrice}')
    ..writeln('  rust.entry_price  = ${r.entryPrice}')
    ..writeln('  dart.exit_price   = ${d.exitPrice}')
    ..writeln('  rust.exit_price   = ${r.exitPrice}')
    ..writeln('  dart.quantity     = ${d.quantity}')
    ..writeln('  rust.quantity     = ${r.quantity}')
    ..writeln('  qty_ratio (r/d)   = $qtyRatio')
    ..writeln('  1/(1-fee_rate)    = ${1 / (1 - _feeRate)}')
    ..writeln('  dart.gross_pnl    = ${d.gross}')
    ..writeln('  rust.gross_pnl    = ${r.gross}')
    ..writeln('  dart.implied_fees = ${d.impliedFees}')
    ..writeln('  rust.implied_fees = ${r.impliedFees}')
    ..writeln('  dart.pnl          = ${d.pnl}')
    ..writeln('  rust.pnl          = ${r.pnl}')
    ..writeln('  delta (r-d)       = ${r.pnl - d.pnl}')
    ..writeln('===== F-10 FIRST DIVERGENCE REPORT END =====');
  return buf.toString();
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
