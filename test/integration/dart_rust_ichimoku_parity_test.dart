/// F-01 Dart ↔ Rust Ichimoku backtest parity regression.
///
/// Pins the contract that the native Rust engine (via flutter_rust_bridge)
/// and the pure-Dart fallback engine produce numerically identical results
/// for the Ichimoku Cloud Retest strategy on a fixed deterministic
/// 400-candle fixture.
///
/// **Welle I2-5 (this commit) — Dart-side scope:**
///   - Fixture triggers ≥ 1 LONG entry on the Dart-fallback engine so the
///     subsequent numerical assertions below cannot be tautologies of
///     `0 == 0`. We aim for both LONG and SHORT triggers; the V-shaped
///     fixture is sized so the long-phase entry runs into the eventual
///     reversal SL and re-opens the in_position guard for the short
///     side. If a future strategy change makes both directions fire
///     less reliably on this fixture, redesign the fixture (longer
///     trend phases) rather than weakening the assertion.
///   - 3x Dart-fallback determinism: same input → bit-exact metrics
///     across three runs. Pins "no hidden RNG / no time-of-day
///     branching" on the Dart side.
///
/// **Welle I2-6 (follow-up) — Rust + FFI scope:**
///   - Adds `run_ichimoku_backtest` to the FFI surface via flutter_
///     rust_bridge codegen.
///   - Extends this file with the 3x Rust determinism + Dart-vs-Rust
///     1e-9 cross-engine assertions (mirror of dart_rust_ut_bot_parity_test).
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

  group('F-01 Dart Ichimoku parity (Welle I2-5)', () {
    test('parity smoke: fixture triggers ≥ 1 long entry on Dart engine',
        () {
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
            'Dart engine; otherwise the numerical parity asserts wired in '
            'Welle I2-6 would be tautological. If this fails after a '
            'strategy change, redesign the fixture (longer / steeper '
            'trend phases) rather than weakening the assertion.',
      );
    });

    test('parity smoke: at least one trade closes (in_position guard works)',
        () {
      // V-shape fixture: long opens in up-phase, must close (SL or TP)
      // so the in_position guard releases. Pins that the Dart engine
      // actually exits positions rather than holding indefinitely.
      final candles = _generateFixture();
      final dartResult = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );
      expect(
        dartResult.trades,
        isNotEmpty,
        reason: 'at least one trade must be in the trade log',
      );
      // Sanity: every closed trade must have non-zero quantity and a
      // documented exit reason — pins that the trade log isn't being
      // populated with placeholder rows.
      for (final t in dartResult.trades) {
        expect(t.quantity, greaterThan(0));
        expect(t.exitReason, isNotEmpty);
      }
    });

    test('parity smoke: drawdown is non-trivial on the V-shape fixture',
        () {
      final candles = _generateFixture();
      final dartResult = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );
      // A 200-bar reversal absorbs at least some equity excursion on
      // any winning long — pin that the equity series itself isn't
      // flat (which would zero out the Welle-I2-6 drawdown parity
      // assertion).
      expect(
        dartResult.metrics.maxDrawdown,
        greaterThan(0.0),
        reason: 'V-shape fixture should produce a non-zero max-drawdown '
            'so the drawdown parity assertion in Welle I2-6 is not a '
            'tautology of 0 == 0',
      );
    });

    test('determinism: 3x Dart-fallback runs are bit-exact', () {
      final candles = _generateFixture();
      BacktestResult run() => BacktestService.runIchimoku(
            candles: candles,
            initialBalance: initialBalance,
            feeRate: feeRate,
          );

      final d1 = run();
      final d2 = run();
      final d3 = run();
      expect(d2.metrics.totalPnl, equals(d1.metrics.totalPnl));
      expect(d3.metrics.totalPnl, equals(d1.metrics.totalPnl));
      expect(d2.metrics.totalTrades, equals(d1.metrics.totalTrades));
      expect(d2.metrics.winRate, equals(d1.metrics.winRate));
      expect(d2.metrics.maxDrawdown, equals(d1.metrics.maxDrawdown));
      expect(d2.metrics.sharpeRatio, equals(d1.metrics.sharpeRatio));
      // Trade log must match position-by-position, not just the
      // aggregate totals — pins per-trade reproducibility.
      expect(d2.trades.length, equals(d1.trades.length));
      for (int i = 0; i < d1.trades.length; i++) {
        expect(d2.trades[i].entryPrice, equals(d1.trades[i].entryPrice));
        expect(d2.trades[i].exitPrice, equals(d1.trades[i].exitPrice));
        expect(d2.trades[i].pnl, equals(d1.trades[i].pnl));
        expect(d2.trades[i].direction, equals(d1.trades[i].direction));
      }
    });
  });
}
