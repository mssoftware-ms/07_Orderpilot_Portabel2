/// F-01 Dart ↔ Rust Ichimoku backtest parity regression.
///
/// Pins the contract that the native Rust engine (via flutter_rust_bridge)
/// and the pure-Dart fallback engine produce numerically identical results
/// for the Ichimoku Cloud Retest strategy on a fixed deterministic
/// 400-candle fixture.
///
/// Test surface (final after Welle I2-6):
///
///   1. `parity smoke …` — fixture triggers ≥ 1 LONG entry on the
///      Dart-fallback engine so the numerical assertions below cannot
///      be tautologies of `0 == 0`. The V-shape fixture is sized so the
///      long-phase entry runs into the eventual reversal SL and re-opens
///      the in_position guard for the short side. If a future strategy
///      change makes both directions fire less reliably on this fixture,
///      redesign the fixture (longer / steeper trend phases) rather than
///      weakening the assertion.
///
///   2. `parity numerical …` — totalPnl / winRate / sharpe / drawdown
///      must match between engines within 1e-9. Tolerance mirrors the
///      UT-Bot parity test — any wider drift indicates real engine
///      divergence (fee ordering, rounding, indicator formula) and MUST
///      be investigated rather than papered over.
///
///   3. `parity determinism …` — repeating each engine three times on
///      the same fixture produces bit-identical metrics. Pins
///      "no hidden RNG / no time-of-day branching" on both sides of
///      the FFI bridge.
///
/// 400 candles cover the strict-spec 103-bar warm-up plus enough
/// active-bar runway to walk through up-trend (LONG entry + run-up to
/// reversal SL) and down-trend (SHORT entry).
///
/// Tolerance for the eventual FFI numerical comparison is `1e-9` —
/// mirror of the UT-Bot parity test. Any wider drift indicates real
/// engine divergence (ordering, rounding, indicator formula) and MUST
/// be investigated rather than papered over by widening the tolerance.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/rust_bridge.dart';

/// 400-candle V-shape fixture — pure-uptrend for 200 bars, then
/// pure-downtrend for 200 bars. Linear slope ±0.5 per bar around a
/// 100-baseline. Designed to trigger:
///   1. LONG entry past the 103-bar warm-up in the up-phase.
///   2. The long position's hard SL = min(kijun, cloud_lower) gets hit
///      somewhere in the down-phase as price retraces below the SL
///      anchor, releasing the in_position guard.
///   3. SHORT entry once enough down-phase bars accumulate fresh
///      past-cloud anchors (chikou_cloud_lower has to drop below
///      close[i] for c4 — needs ~78 bars of pure down-trend).
///
/// IEEE-754 f64 throughout; the input round-trips cleanly through JSON,
/// so the Rust FFI path (added in Welle I2-6) receives the same stream
/// bit-identical.
List<CandleData> _generateFixture() {
  const baseTs = 1700000000000; // 2023-11-14 22:13:20 UTC
  final closes = <double>[];
  for (int i = 0; i < 200; i++) {
    closes.add(100.0 + i * 0.5); // 100 → 199.5
  }
  for (int i = 0; i < 200; i++) {
    closes.add(199.5 - (i + 1) * 0.5); // 199 → 100
  }
  return [
    for (int i = 0; i < closes.length; i++)
      CandleData(
        timestamp: baseTs + i * 3600000, // 1h candles per Spec §1
        open: closes[i] - 0.2,
        high: closes[i] + 0.3,
        low: closes[i] - 0.3,
        close: closes[i],
        volume: 1000.0 + i,
      ),
  ];
}

void main() {
  const initialBalance = 10000.0;
  const feeRate = 0.0006;

  setUpAll(() async {
    await RustBridge.initialize();
  });

  group('F-01 Dart ↔ Rust Ichimoku parity', () {
    test('parity smoke: native available + fixture triggers ≥ 1 long entry',
        () async {
      expect(
        RustBridge.isNativeAvailable,
        isTrue,
        reason:
            'native engine must be loaded; cargo build artefacts in '
            'rust/trading_engine/target/release/ are required for this test',
      );

      final candles = _generateFixture();
      final dartResult = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );
      final longs = dartResult.trades
          .where((t) => t.direction == 'LONG')
          .length;
      expect(
        longs,
        greaterThan(0),
        reason:
            'V-shape fixture must trigger ≥ 1 Ichimoku LONG entry on the '
            'Dart engine; otherwise the numerical parity asserts below '
            'would be tautological. If this fails after a strategy change, '
            'redesign the fixture rather than weakening the assertion.',
      );
    });

    test(
        'parity numerical: totalPnl/winRate/sharpe/drawdown match within 1e-9',
        () async {
      final candles = _generateFixture();
      final dartResult = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );

      final rustMetrics = await RustBridge.runIchimokuBacktest(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );

      expect(
        rustMetrics.totalTrades,
        equals(dartResult.metrics.totalTrades),
        reason: 'totalTrades must match exactly — divergence here points '
            'to an entry-condition or warm-up-gate mismatch between engines',
      );
      expect(
        rustMetrics.totalPnl,
        closeTo(dartResult.metrics.totalPnl, 1e-9),
        reason: 'totalPnl divergence > 1e-9 indicates real engine drift — '
            'do NOT widen tolerance, investigate ordering/rounding instead',
      );
      expect(
        rustMetrics.winRate,
        closeTo(dartResult.metrics.winRate, 1e-9),
      );
      expect(
        rustMetrics.profitFactor,
        closeTo(dartResult.metrics.profitFactor, 1e-9),
      );

      final dartFinalEquity =
          initialBalance + dartResult.metrics.totalPnl;
      final rustFinalEquity = initialBalance + rustMetrics.totalPnl;
      expect(rustFinalEquity, closeTo(dartFinalEquity, 1e-9));

      // F-03b / F-03c parity guarantees: equity series + running-peak
      // drawdown share a single definition across engines.
      expect(
        rustMetrics.sharpeRatio,
        closeTo(dartResult.metrics.sharpeRatio, 1e-9),
      );
      expect(
        rustMetrics.maxDrawdown,
        closeTo(dartResult.metrics.maxDrawdown, 1e-9),
      );
      expect(
        rustMetrics.maxDrawdownPercent,
        closeTo(dartResult.metrics.maxDrawdownPercent, 1e-9),
      );

      // Sanity: drawdown must be non-trivial so the asserts above
      // are not 0 == 0 (totalTrades > 0 already pinned by the smoke).
      expect(dartResult.metrics.maxDrawdown, greaterThan(0.0));
      expect(rustMetrics.maxDrawdown, greaterThan(0.0));
    });

    test('parity determinism: 3x Dart and 3x Rust bit-exact',
        () async {
      // Determinism contract: same input → same output, no float-noise
      // drift across repeated runs. Extends the Dart-fallback
      // determinism test in `test/services/ichimoku_backtest_test.dart`
      // across the FFI boundary by exercising both engines three times.
      final candles = _generateFixture();

      final d1 = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );
      final d2 = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );
      final d3 = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );

      expect(d2.metrics.totalPnl, equals(d1.metrics.totalPnl));
      expect(d3.metrics.totalPnl, equals(d1.metrics.totalPnl));
      expect(d2.metrics.totalTrades, equals(d1.metrics.totalTrades));

      final r1 = await RustBridge.runIchimokuBacktest(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );
      final r2 = await RustBridge.runIchimokuBacktest(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );
      final r3 = await RustBridge.runIchimokuBacktest(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );

      expect(r2.totalPnl, equals(r1.totalPnl));
      expect(r3.totalPnl, equals(r1.totalPnl));
      expect(r2.totalTrades, equals(r1.totalTrades));
      expect(r2.sharpeRatio, equals(r1.sharpeRatio));
      expect(r2.maxDrawdown, equals(r1.maxDrawdown));
    });

    test('parity dart-fallback per-trade reproducibility', () {
      // 3x Dart runs must agree on the trade log position-by-position,
      // not just on the aggregate metrics. Catches drift inside the
      // strategy itself (e.g. a HashMap iteration order change in the
      // engine that flips entry/exit ordering across runs) while still
      // letting the cross-engine numerical test treat metrics as the
      // primary parity contract.
      final candles = _generateFixture();
      BacktestResult run() => BacktestService.runIchimoku(
            candles: candles,
            initialBalance: initialBalance,
            feeRate: feeRate,
          );

      final d1 = run();
      final d2 = run();
      final d3 = run();
      expect(d2.trades.length, equals(d1.trades.length));
      expect(d3.trades.length, equals(d1.trades.length));
      for (int i = 0; i < d1.trades.length; i++) {
        expect(d2.trades[i].entryPrice, equals(d1.trades[i].entryPrice));
        expect(d2.trades[i].exitPrice, equals(d1.trades[i].exitPrice));
        expect(d2.trades[i].pnl, equals(d1.trades[i].pnl));
        expect(d2.trades[i].direction, equals(d1.trades[i].direction));
        expect(d2.trades[i].exitReason, equals(d1.trades[i].exitReason));
      }
    });
  });
}
