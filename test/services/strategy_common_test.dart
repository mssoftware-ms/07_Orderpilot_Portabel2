/// Unit tests for the Dart helpers in `lib/services/strategy_common.dart`.
///
/// Every reference value in this file is shared bit-for-bit with the
/// Rust unit tests in `rust/trading_engine/src/addins/common.rs`
/// (`mod tests`), so the two engines stay in lock-step at the algorithm
/// level even before any FFI-roundtrip parity test exercises the
/// helpers end-to-end. Same pattern as `indicators_test.dart` does for
/// `calcAtr` / `calcSmi`.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/services/strategy_common.dart';

void main() {
  group('calcAdx', () {
    // ── Defensive returns ─────────────────────────────────────────────

    test('returns null for period 0', () {
      expect(calcAdx([1.0], [1.0], [1.0], 0), isNull);
    });

    test('returns null for mismatched lengths', () {
      expect(
        calcAdx([1.0, 2.0, 3.0], [0.5, 1.5], [0.7, 1.7, 2.7], 2),
        isNull,
      );
    });

    test('returns null when n < period (cannot seed first DI)', () {
      // Mirrors `test_adx_insufficient_data_returns_none` in Rust.
      expect(
        calcAdx([1.0, 2.0, 3.0], [0.5, 1.5, 2.5], [0.8, 1.8, 2.8], 14),
        isNull,
      );
    });

    // ── Behavioural tests ─────────────────────────────────────────────

    test('constant series → DX and ADX are exactly zero', () {
      // Mirrors `test_adx_constant_series_dx_and_adx_are_zero` in Rust:
      // high == low == close == const → TR = 0, +DM = -DM = 0,
      // both DI = 0 (TR_s == 0 branch), DX = 0, ADX = 0.
      const n = 40;
      final highs = List<double>.filled(n, 100.0);
      final lows = List<double>.filled(n, 100.0);
      final closes = List<double>.filled(n, 100.0);
      const period = 14;
      final out = calcAdx(highs, lows, closes, period)!;
      expect(out.adx.length, n);
      expect(out.plusDi.length, n);
      expect(out.minusDi.length, n);
      for (int i = 0; i < period - 1; i++) {
        expect(out.plusDi[i].isNaN, isTrue, reason: '+DI warmup at $i');
        expect(out.minusDi[i].isNaN, isTrue, reason: '-DI warmup at $i');
      }
      for (int i = 0; i < 2 * period - 2; i++) {
        expect(out.adx[i].isNaN, isTrue, reason: 'ADX warmup at $i');
      }
      for (int i = period - 1; i < n; i++) {
        expect(out.plusDi[i], 0.0, reason: '+DI at $i');
        expect(out.minusDi[i], 0.0, reason: '-DI at $i');
      }
      for (int i = 2 * period - 2; i < n; i++) {
        expect(out.adx[i], 0.0, reason: 'ADX at $i');
      }
    });

    test('monotone uptrend → +DI dominant, ADX > 50', () {
      // Mirrors
      // `test_adx_monotone_uptrend_plus_di_dominates_and_adx_high`.
      const n = 80;
      final highs =
          List<double>.generate(n, (i) => 100.0 + i.toDouble() + 0.5);
      final lows =
          List<double>.generate(n, (i) => 100.0 + i.toDouble() - 0.5);
      final closes = List<double>.generate(n, (i) => 100.0 + i.toDouble());
      const period = 14;
      final out = calcAdx(highs, lows, closes, period)!;
      for (int i = 2 * period - 2; i < n; i++) {
        expect(
          out.plusDi[i],
          greaterThan(out.minusDi[i]),
          reason:
              '+DI must dominate -DI at $i: +DI=${out.plusDi[i]} -DI=${out.minusDi[i]}',
        );
        expect(
          out.adx[i],
          greaterThan(50.0),
          reason: 'ADX must exceed 50 in monotone uptrend at $i: ${out.adx[i]}',
        );
      }
      for (int i = period - 1; i < n; i++) {
        expect(out.minusDi[i], 0.0, reason: '-DI must be 0 at $i');
      }
    });

    test('monotone downtrend → -DI dominant, ADX > 50', () {
      // Mirrors
      // `test_adx_monotone_downtrend_minus_di_dominates_and_adx_high`.
      const n = 80;
      final highs =
          List<double>.generate(n, (i) => 200.0 - i.toDouble() + 0.5);
      final lows =
          List<double>.generate(n, (i) => 200.0 - i.toDouble() - 0.5);
      final closes = List<double>.generate(n, (i) => 200.0 - i.toDouble());
      const period = 14;
      final out = calcAdx(highs, lows, closes, period)!;
      for (int i = 2 * period - 2; i < n; i++) {
        expect(
          out.minusDi[i],
          greaterThan(out.plusDi[i]),
          reason:
              '-DI must dominate +DI at $i: +DI=${out.plusDi[i]} -DI=${out.minusDi[i]}',
        );
        expect(
          out.adx[i],
          greaterThan(50.0),
          reason:
              'ADX must exceed 50 in monotone downtrend at $i: ${out.adx[i]}',
        );
      }
      for (int i = period - 1; i < n; i++) {
        expect(out.plusDi[i], 0.0, reason: '+DI must be 0 at $i');
      }
    });

    test('choppy alternating series → ADX stays below 20', () {
      // Mirrors `test_adx_choppy_series_keeps_adx_low` in Rust.
      const n = 80;
      final highs =
          List<double>.generate(n, (i) => i.isEven ? 101.0 : 100.0);
      final lows = List<double>.generate(n, (i) => i.isEven ? 99.0 : 98.0);
      final closes =
          List<double>.generate(n, (i) => i.isEven ? 100.0 : 99.0);
      const period = 14;
      final out = calcAdx(highs, lows, closes, period)!;
      for (int i = 2 * period - 2 + period; i < n; i++) {
        expect(
          out.adx[i],
          lessThan(20.0),
          reason: 'choppy ADX must stay below 20 at $i: got ${out.adx[i]}',
        );
      }
    });

    test('period=14 with exactly 14 candles → first DI valid, ADX all NaN', () {
      // Mirrors
      // `test_adx_period_14_with_14_candles_first_di_only_no_adx`.
      const period = 14;
      const n = period;
      final highs =
          List<double>.generate(n, (i) => 100.0 + i.toDouble() + 0.5);
      final lows =
          List<double>.generate(n, (i) => 100.0 + i.toDouble() - 0.5);
      final closes = List<double>.generate(n, (i) => 100.0 + i.toDouble());
      final out = calcAdx(highs, lows, closes, period)!;
      expect(out.adx.length, n);
      for (final v in out.adx) {
        expect(v.isNaN, isTrue, reason: 'ADX must be NaN throughout: $v');
      }
      for (int i = 0; i < period - 1; i++) {
        expect(out.plusDi[i].isNaN, isTrue);
        expect(out.minusDi[i].isNaN, isTrue);
      }
      expect(out.plusDi[period - 1].isNaN, isFalse);
      expect(out.minusDi[period - 1].isNaN, isFalse);
      expect(out.minusDi[period - 1], 0.0);
      expect(out.plusDi[period - 1], greaterThan(0.0));
    });

    // ── Pinned reference values ──────────────────────────────────────

    test('pinned 50-candle up-then-down fixture', () {
      // Mirrors `test_adx_pinned_50_candle_fixture` in Rust.
      // Reference values captured from the Rust implementation via
      // the ignored `dump_adx_reference_values` test. Tolerance 1e-12
      // (pure-arithmetic determinism, no parallelism / no RNG).
      // To re-pin after an intentional algorithm change, run the
      // Rust dumper and paste the same numbers into both this test
      // and the Rust mirror in the same commit.
      const n = 50;
      final highs = <double>[];
      final lows = <double>[];
      final closes = <double>[];
      for (int i = 0; i < 25; i++) {
        highs.add(100.0 + i + 0.5);
        lows.add(100.0 + i - 0.5);
        closes.add(100.0 + i.toDouble());
      }
      for (int i = 0; i < 25; i++) {
        final base = 124.0 - i;
        highs.add(base + 0.5);
        lows.add(base - 0.5);
        closes.add(base);
      }
      const period = 14;
      final out = calcAdx(highs, lows, closes, period)!;
      const eps = 1e-12;
      expect(out.plusDi[13], closeTo(63.41463414634147, eps));
      expect(out.minusDi[13], 0.0);
      expect(out.plusDi[26], closeTo(57.45826303207894, eps));
      expect(out.minusDi[26], closeTo(4.915232309238658, eps));
      expect(out.adx[26], closeTo(98.87423970657002, eps));
      expect(out.plusDi[49], closeTo(10.181512267099826, eps));
      expect(out.minusDi[49], closeTo(55.72441131045887, eps));
      expect(out.adx[49], closeTo(55.55968855269939, eps));
      // Range sanity: every post-warm-up DI / ADX must be in [0, 100].
      for (int i = period - 1; i < n; i++) {
        expect(out.plusDi[i], inInclusiveRange(0.0, 100.0));
        expect(out.minusDi[i], inInclusiveRange(0.0, 100.0));
      }
      for (int i = 2 * period - 2; i < n; i++) {
        expect(out.adx[i], inInclusiveRange(0.0, 100.0));
      }
    });

    test('Dart↔Rust parity on 200-candle sinus fixture (1e-9)', () {
      // Mirrors `test_adx_parity_200_candle_sinus_fixture` in Rust.
      // close[i] = 100 + 10 * sin(2π * i / 25), high = close + 0.6,
      // low = close - 0.6, period = 14. Pinned values lock indicator-
      // level Dart↔Rust parity to 1e-9; drift beyond that means a
      // real engine divergence and MUST be investigated rather than
      // papered over by widening the tolerance.
      const n = 200;
      final highs = <double>[];
      final lows = <double>[];
      final closes = <double>[];
      const twoPi = 2.0 * math.pi;
      for (int i = 0; i < n; i++) {
        final c = 100.0 + 10.0 * math.sin(twoPi * i / 25.0);
        closes.add(c);
        highs.add(c + 0.6);
        lows.add(c - 0.6);
      }
      final out = calcAdx(highs, lows, closes, 14)!;
      const eps = 1e-9;
      expect(out.plusDi[13], closeTo(32.417389945019025, eps));
      expect(out.minusDi[13], closeTo(36.48839945788317, eps));
      expect(out.adx[26], closeTo(22.73545258604863, eps));
      expect(out.adx[100], closeTo(25.839833200334414, eps));
      expect(out.adx[199], closeTo(26.86438326497518, eps));
      double sum = 0.0;
      for (int i = 26; i < n; i++) {
        sum += out.adx[i];
      }
      expect(sum, closeTo(4891.015271372291, 1e-6));
    });
  });

  group('withinSession', () {
    // Smoke tests for the existing `withinSession` helper — covered by
    // the Rust unit-test battery in `addins/common.rs`. The Dart side
    // adds two spot-checks here so a future refactor of the Dart helper
    // doesn't silently regress without the existing `ut_bot_backtest`
    // / `ichimoku_backtest` tests catching it.

    int tsAtUtcHour(int hour) {
      const baseUtcMs = 1705276800000; // 2024-01-15 00:00:00 UTC
      return baseUtcMs + hour * 3600000;
    }

    test('Berlin window 09–23 includes UTC 10 (local 11)', () {
      expect(withinSession(tsAtUtcHour(10), 9, 23, 1), isTrue);
    });

    test('Berlin window 09–23 excludes UTC 22 (local 23, end-exclusive)', () {
      expect(withinSession(tsAtUtcHour(22), 9, 23, 1), isFalse);
    });

    test('degenerate window (start == end) is always off', () {
      expect(withinSession(tsAtUtcHour(10), 12, 12, 1), isFalse);
    });

    test('overnight wrap-around 22–06 includes UTC 22 (local 23)', () {
      expect(withinSession(tsAtUtcHour(22), 22, 6, 1), isTrue);
      expect(withinSession(tsAtUtcHour(1), 22, 6, 1), isTrue);
      expect(withinSession(tsAtUtcHour(9), 22, 6, 1), isFalse);
    });
  });

  // ── regimePassesFilter ────────────────────────────────────────────────
  //
  // Reference rules shared bit-for-bit with the Rust mirror in
  // `rust/trading_engine/src/addins/common.rs::tests` so the gate stays
  // in lock-step with the Welle-R3 acceptance backtest.

  group('regimePassesFilter', () {
    test('blocks when adx < threshold (any direction or confluence)', () {
      expect(regimePassesFilter(20.0, 30.0, 10.0, 25.0, true, false), isFalse);
      expect(regimePassesFilter(20.0, 30.0, 10.0, 25.0, false, false), isFalse);
      expect(regimePassesFilter(20.0, 30.0, 10.0, 25.0, true, true), isFalse);
    });

    test('passes when adx >= threshold without confluence', () {
      expect(regimePassesFilter(30.0, 25.0, 25.0, 25.0, true, false), isTrue);
      expect(regimePassesFilter(30.0, 25.0, 25.0, 25.0, false, false), isTrue);
      // Boundary: adx == threshold passes (only `<` blocks).
      expect(regimePassesFilter(25.0, 25.0, 25.0, 25.0, true, false), isTrue);
    });

    test('di confluence blocks long when -DI dominates, passes short', () {
      expect(regimePassesFilter(40.0, 10.0, 30.0, 25.0, true, true), isFalse);
      expect(regimePassesFilter(40.0, 10.0, 30.0, 25.0, false, true), isTrue);
    });

    test('di confluence passes long when +DI dominates, blocks short', () {
      expect(regimePassesFilter(40.0, 30.0, 10.0, 25.0, true, true), isTrue);
      expect(regimePassesFilter(40.0, 30.0, 10.0, 25.0, false, true), isFalse);
    });

    test('di equality blocks both sides under confluence, passes without', () {
      // Strict dominance — equality is not "above" so both directions block.
      expect(regimePassesFilter(40.0, 20.0, 20.0, 25.0, true, true), isFalse);
      expect(regimePassesFilter(40.0, 20.0, 20.0, 25.0, false, true), isFalse);
      // Without confluence the ADX-only gate accepts the same inputs.
      expect(regimePassesFilter(40.0, 20.0, 20.0, 25.0, true, false), isTrue);
      expect(regimePassesFilter(40.0, 20.0, 20.0, 25.0, false, false), isTrue);
    });

    test('NaN in any input blocks the trade (warm-up safety)', () {
      expect(
        regimePassesFilter(double.nan, 30.0, 10.0, 25.0, true, false),
        isFalse,
      );
      expect(
        regimePassesFilter(40.0, double.nan, 10.0, 25.0, true, true),
        isFalse,
      );
      expect(
        regimePassesFilter(40.0, 30.0, double.nan, 25.0, false, true),
        isFalse,
      );
    });

    test('threshold zero accepts any finite ADX; confluence still applies', () {
      expect(regimePassesFilter(0.0, 5.0, 3.0, 0.0, true, false), isTrue);
      expect(regimePassesFilter(0.0, 5.0, 3.0, 0.0, true, true), isTrue);
      // +DI < -DI for a long → blocked under confluence.
      expect(regimePassesFilter(0.0, 3.0, 5.0, 0.0, true, true), isFalse);
    });
  });
}
