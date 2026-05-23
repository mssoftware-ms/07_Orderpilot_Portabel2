/// Unit tests for the Dart indicator helpers in `lib/services/indicators.dart`.
///
/// Every reference value in this file is shared bit-for-bit with the
/// Rust unit tests in `rust/trading_engine/src/addins/bb_rsi.rs` under
/// `mod tests`, so the two engines stay in lock-step at the algorithm
/// level even before any integration parity test exercises EMA.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/indicators.dart';

void main() {
  group('calcAtr', () {
    // Every reference value in this group is shared bit-for-bit with the
    // Rust unit tests in `rust/trading_engine/src/addins/ut_bot.rs` so
    // the ATR helper stays in lock-step at the algorithm level even
    // before the UT-Bot strategy lands its end-to-end parity test
    // (Welle U2-4). The fixtures construct OHLC bars where the body is
    // zero (open == close) so the True Range collapses to the
    // high/low/prev-close interaction described in the doc comment.

    test('returns null for period 0', () {
      expect(calcAtr([1.0], [1.0], [1.0], 0), isNull);
    });

    test('returns null for insufficient data', () {
      expect(
        calcAtr([1.0, 2.0, 3.0], [0.5, 1.5, 2.5], [0.8, 1.8, 2.8], 5),
        isNull,
      );
    });

    test('returns null for mismatched lengths', () {
      expect(
        calcAtr([1.0, 2.0, 3.0], [0.5, 1.5], [0.8, 1.8, 2.8], 2),
        isNull,
      );
    });

    test('constant TR converges instantly to that value', () {
      // Mirrors `test_atr_constant_tr_converges_to_tr_value` in Rust:
      // high=100.5 low=99.5 close=100.0 for every bar →
      //   tr[0] = 1.0, tr[i>=1] = max(1.0, 0.5, 0.5) = 1.0.
      const n = 20;
      final highs = List<double>.filled(n, 100.5);
      final lows = List<double>.filled(n, 99.5);
      final closes = List<double>.filled(n, 100.0);
      const period = 5;
      final atr = calcAtr(highs, lows, closes, period)!;
      expect(atr.length, n);
      for (int i = 0; i < period - 1; i++) {
        expect(atr[i].isNaN, isTrue, reason: 'warm-up at $i must be NaN');
      }
      for (int i = period - 1; i < n; i++) {
        expect(atr[i], closeTo(1.0, 1e-12),
            reason: 'constant TR=1.0 expected ATR=1.0 at index $i');
      }
    });

    test('step function converges exponentially to new TR value', () {
      // Mirrors `test_atr_step_function_converges_exponentially` in Rust:
      // tr=1.0 for bars 0..period-1 (half-band 0.5), tr=2.0 from period
      // onward (half-band 1.0). Verify the first few smoothed values
      // analytically and the monotonic convergence behaviour after.
      const period = 5;
      const n = 20;
      final highs = <double>[];
      final lows = <double>[];
      final closes = <double>[];
      for (int i = 0; i < n; i++) {
        final half = i < period ? 0.5 : 1.0;
        highs.add(100.0 + half);
        lows.add(100.0 - half);
        closes.add(100.0);
      }
      final atr = calcAtr(highs, lows, closes, period)!;
      expect(atr[period - 1], closeTo(1.0, 1e-12));
      expect(atr[period], closeTo(1.2, 1e-12));
      expect(atr[period + 1], closeTo(1.36, 1e-12));
      expect(atr[period + 2], closeTo(1.488, 1e-12));
      for (int i = period + 1; i < n; i++) {
        expect(atr[i], greaterThan(atr[i - 1]),
            reason: 'ATR must rise monotonically toward 2.0');
        expect(atr[i], lessThan(2.0),
            reason: 'ATR must stay below 2.0 (asymptotic)');
      }
    });

    test('period equals length returns seed only (no Wilder step)', () {
      // Mirrors `test_atr_period_equals_length_returns_seed_only` in Rust.
      final h = [10.5, 11.5, 12.5, 13.5, 14.5];
      final l = [9.5, 10.5, 11.5, 12.5, 13.5];
      final c = [10.0, 11.0, 12.0, 13.0, 14.0];
      const period = 5;
      final atr = calcAtr(h, l, c, period)!;
      for (int i = 0; i < period - 1; i++) {
        expect(atr[i].isNaN, isTrue);
      }
      // tr[0] = 1.0; tr[1..4] = max(1.0, 1.5, 0.5) = 1.5 each.
      // mean(tr[0..5]) = (1.0 + 4 * 1.5) / 5 = 7/5 = 1.4
      expect(atr[period - 1], closeTo(1.4, 1e-12));
    });

    test('period 1 equals TR per bar (no warm-up, no smoothing)', () {
      // Mirrors `test_atr_period_one_equals_tr_per_bar` in Rust — used by
      // the UT-Bot verbesserte-Variante default `atrPeriod = 1`.
      final h = [101.0, 102.0, 103.5];
      final l = [99.0, 100.5, 100.0];
      final c = [100.0, 101.0, 102.0];
      final atr = calcAtr(h, l, c, 1)!;
      expect(atr.length, 3);
      expect(atr[0], closeTo(2.0, 1e-12));
      expect(atr[1], closeTo(2.0, 1e-12));
      expect(atr[2], closeTo(3.5, 1e-12));
    });

    test('first-bar TR uses high-low only (no synthetic prev-close)', () {
      // Mirrors `test_atr_tr_seeded_from_high_low_when_no_prev_close` in
      // Rust — pins the deterministic seed so the strategy reproduces
      // across runs even when fed with a fresh candle history.
      final h = [105.0, 106.0];
      final l = [95.0, 104.0];
      final c = [100.0, 105.5];
      final atr = calcAtr(h, l, c, 2)!;
      // tr[0] = 10.0; tr[1] = max(2.0, 6.0, 4.0) = 6.0;
      // atr[1] = (10 + 6) / 2 = 8.0
      expect(atr[1], closeTo(8.0, 1e-12));
    });
  });

  group('calcSmi', () {
    // Mirror of `mod tests::test_smi_*` in
    // `rust/trading_engine/src/addins/ut_bot.rs`. Every reference value
    // is shared bit-for-bit with the Rust unit tests so the SMI helper
    // stays in lock-step at the algorithm level (Welle-U1/U2 parity
    // pattern). End-to-end Dart↔Rust parity through the full UT-Bot
    // strategy lands in Welle U2-4.

    test('returns null for zero periods', () {
      final h = List<double>.filled(5, 1.0);
      final l = List<double>.filled(5, 0.5);
      final c = List<double>.filled(5, 0.7);
      expect(calcSmi(h, l, c, 0, 2, 2), isNull);
      expect(calcSmi(h, l, c, 3, 0, 2), isNull);
      expect(calcSmi(h, l, c, 3, 2, 0), isNull);
    });

    test('returns null for mismatched lengths', () {
      expect(
        calcSmi([1.0, 2.0, 3.0], [0.5, 1.5], [0.7, 1.7, 2.7], 2, 1, 1),
        isNull,
      );
    });

    test('returns null for insufficient data', () {
      expect(
        calcSmi(
          [1.0, 2.0, 3.0, 4.0],
          [0.5, 1.5, 2.5, 3.5],
          [0.8, 1.8, 2.8, 3.8],
          3,
          2,
          2,
        ),
        isNull,
      );
    });

    test('zero at perfect midrange', () {
      // Constant range with close at midpoint → diff is 0 → SMI is 0.
      const n = 20;
      final highs = List<double>.filled(n, 101.0);
      final lows = List<double>.filled(n, 99.0);
      final closes = List<double>.filled(n, 100.0);
      final result = calcSmi(highs, lows, closes, 5, 3, 3)!;
      for (int i = 8; i < n; i++) {
        expect(result.smi[i], closeTo(0.0, 1e-12));
      }
    });

    test('positive in monotone uptrend', () {
      const n = 50;
      final highs = [for (var i = 0; i < n; i++) 100.0 + i + 0.5];
      final lows = [for (var i = 0; i < n; i++) 100.0 + i - 0.5];
      final closes = [for (var i = 0; i < n; i++) 100.0 + i.toDouble()];
      final result = calcSmi(highs, lows, closes, 10, 5, 3)!;
      for (int i = 30; i < n; i++) {
        expect(result.smi[i], greaterThan(0.0),
            reason: 'SMI at $i expected > 0, got ${result.smi[i]}');
      }
    });

    test('negative in monotone downtrend', () {
      const n = 50;
      final highs = [for (var i = 0; i < n; i++) 200.0 - i + 0.5];
      final lows = [for (var i = 0; i < n; i++) 200.0 - i - 0.5];
      final closes = [for (var i = 0; i < n; i++) 200.0 - i.toDouble()];
      final result = calcSmi(highs, lows, closes, 10, 5, 3)!;
      for (int i = 30; i < n; i++) {
        expect(result.smi[i], lessThan(0.0));
      }
    });

    test('bounded by ±200', () {
      const n = 60;
      final highs = <double>[];
      final lows = <double>[];
      final closes = <double>[];
      for (int i = 0; i < n; i++) {
        final price = 100.0 + 10.0 * math.sin(i * 0.4);
        highs.add(price + 0.5);
        lows.add(price - 0.5);
        closes.add(price);
      }
      final result = calcSmi(highs, lows, closes, 10, 5, 3)!;
      for (final v in result.smi.where((v) => !v.isNaN)) {
        expect(v.abs(), lessThanOrEqualTo(200.0 + 1e-9));
      }
    });

    test('known values on small fixture mirror Rust expectations', () {
      // Mirror of `test_smi_known_values_small_fixture` in Rust.
      // closes = [100,101,102,103,104,103,102,101,100,99]; high/low ±1.0;
      // length=3, k=2, d=2 → smi_start = 4; signal_start = 5.
      final closes = [
        for (var i = 0; i < 10; i++)
          if (i <= 4) 100.0 + i else 100.0 + (8 - i),
      ];
      final highs = [for (final c in closes) c + 1.0];
      final lows = [for (final c in closes) c - 1.0];
      final r = calcSmi(highs, lows, closes, 3, 2, 2)!;

      for (int i = 0; i < 4; i++) {
        expect(r.smi[i].isNaN, isTrue);
      }
      expect(r.smi[4], closeTo(50.0, 1e-9));
      expect(r.smi[5], closeTo(18.75, 1e-9));
      expect(r.smi[6], closeTo(-18.0, 1e-9));
      expect(r.smi[7], closeTo(-36.53846153846154, 1e-9));
      expect(r.smi[8], closeTo(-44.56066945606695, 1e-9));
      expect(r.smi[9], closeTo(-47.85911602209945, 1e-9));

      for (int i = 0; i < 5; i++) {
        expect(r.signal[i].isNaN, isTrue);
      }
      expect(r.signal[5], closeTo(34.375, 1e-9));
      expect(r.signal[6], closeTo(-0.5416666666666665, 1e-9));
      expect(r.signal[7], closeTo(-24.53952991452992, 1e-9));
      expect(r.signal[8], closeTo(-37.88695627555257, 1e-9));
      expect(r.signal[9], closeTo(-44.53506277325049, 1e-9));
    });

    test('signal lags SMI in monotone uptrend', () {
      const n = 60;
      final highs = [for (var i = 0; i < n; i++) 100.0 + i + 0.5];
      final lows = [for (var i = 0; i < n; i++) 100.0 + i - 0.5];
      final closes = [for (var i = 0; i < n; i++) 100.0 + i.toDouble()];
      final r = calcSmi(highs, lows, closes, 10, 5, 3)!;
      for (int i = 30; i < n; i++) {
        expect(r.signal[i], lessThanOrEqualTo(r.smi[i] + 1e-9));
      }
    });
  });

  group('calcUtBotTrail', () {
    // Mirror of `mod tests::test_trail_*` in
    // `rust/trading_engine/src/addins/ut_bot.rs`. Every reference value
    // is shared bit-for-bit with the Rust unit tests so the UT-Bot
    // trail helper stays in lock-step at the algorithm level.

    test('returns null for mismatched lengths', () {
      expect(calcUtBotTrail([100.0, 101.0, 102.0], [1.0, 1.0], 2.0), isNull);
    });

    test('returns null for empty input', () {
      expect(calcUtBotTrail(const [], const [], 2.0), isNull);
    });

    test('returns null when ATR is all NaN', () {
      expect(
        calcUtBotTrail([100.0, 101.0, 102.0],
            [double.nan, double.nan, double.nan], 2.0),
        isNull,
      );
    });

    test('seeds at first valid ATR index', () {
      // ATR NaN at 0, valid at 1 with value 1.0. key=2 → nLoss=2.
      // trail[1] = close[1] - 2 = 99.
      final r = calcUtBotTrail([100.0, 101.0], [double.nan, 1.0], 2.0)!;
      expect(r.trail[0].isNaN, isTrue);
      expect(r.direction[0], 0);
      expect(r.trail[1], closeTo(99.0, 1e-12));
      expect(r.direction[1], 1);
    });

    test('monotone non-decreasing in uptrend, direction stays +1', () {
      const n = 20;
      final closes = [for (var i = 0; i < n; i++) 100.0 + i];
      final atr = List<double>.filled(n, 1.0);
      final r = calcUtBotTrail(closes, atr, 1.0)!;
      expect(r.trail[0], closeTo(99.0, 1e-12));
      expect(r.direction[0], 1);
      for (int i = 1; i < n; i++) {
        expect(r.trail[i], greaterThanOrEqualTo(r.trail[i - 1] - 1e-12));
        expect(r.direction[i], 1);
      }
    });

    test('flips on bar 1 in downtrend, then monotone non-increasing', () {
      const n = 20;
      final closes = [for (var i = 0; i < n; i++) 200.0 - i];
      final atr = List<double>.filled(n, 1.0);
      final r = calcUtBotTrail(closes, atr, 1.0)!;
      expect(r.trail[0], closeTo(199.0, 1e-12));
      expect(r.direction[0], 1);
      expect(r.trail[1], closeTo(200.0, 1e-12));
      expect(r.direction[1], -1);
      for (int i = 2; i < n; i++) {
        expect(r.trail[i], lessThanOrEqualTo(r.trail[i - 1] + 1e-12));
        expect(r.direction[i], -1);
      }
    });

    test('long-to-short flip on crash bar', () {
      final closes = [100.0, 101.0, 102.0, 103.0, 104.0, 80.0];
      final atr = List<double>.filled(6, 1.0);
      final r = calcUtBotTrail(closes, atr, 2.0)!;
      expect(r.direction, [1, 1, 1, 1, 1, -1]);
      expect(r.trail[4], closeTo(102.0, 1e-12));
      expect(r.trail[5], closeTo(82.0, 1e-12));
    });

    test('short-to-long flip on rip bar', () {
      final closes = [100.0, 99.0, 98.0, 97.0, 96.0, 120.0];
      final atr = List<double>.filled(6, 1.0);
      final r = calcUtBotTrail(closes, atr, 2.0)!;
      expect(r.direction, [1, 1, -1, -1, -1, 1]);
      expect(r.trail[5], closeTo(118.0, 1e-12));
    });

    test('known values on small fixture match Rust expectations', () {
      // Hand-computed reference, mirrors
      // `test_trail_known_values_small_fixture` in Rust.
      final closes = [100.0, 102.0, 101.0, 103.0, 99.0, 100.0, 105.0, 104.0];
      final atr = List<double>.filled(8, 1.0);
      final r = calcUtBotTrail(closes, atr, 1.5)!;
      const expectedTrail = [
        98.5, 100.5, 100.5, 101.5, 100.5, 100.5, 103.5, 103.5,
      ];
      const expectedDir = [1, 1, 1, 1, -1, -1, 1, 1];
      for (int i = 0; i < closes.length; i++) {
        expect(r.trail[i], closeTo(expectedTrail[i], 1e-12),
            reason: 'trail[$i]');
        expect(r.direction[i], expectedDir[i], reason: 'direction[$i]');
      }
    });
  });

  group('calcEma', () {
    test('returns null for insufficient data', () {
      expect(calcEma([1.0, 2.0, 3.0], 5), isNull);
    });

    test('returns null for period 0', () {
      expect(calcEma([1.0, 2.0, 3.0], 0), isNull);
    });

    test('seed equals SMA when history length equals period', () {
      // values.length == period → no recursive step applied yet
      final ema = calcEma([10.0, 12.0, 14.0, 16.0, 18.0], 5);
      expect(ema, isNotNull);
      expect(ema!, closeTo(14.0, 1e-12));
    });

    test('period 1 tracks the most recent value', () {
      // alpha = 2/(1+1) = 1 → EMA always equals current value
      final ema = calcEma([10.0, 20.0, 5.0, 7.0], 1);
      expect(ema, isNotNull);
      expect(ema!, closeTo(7.0, 1e-12));
    });

    test('constant series collapses to that constant', () {
      final closes = List<double>.filled(50, 100.0);
      final ema = calcEma(closes, 14);
      expect(ema, isNotNull);
      expect(ema!, closeTo(100.0, 1e-12));
    });

    test('known reference values for period 5', () {
      // Hand-computed reference, mirrored bit-exact in the Rust unit test
      // `test_ema_known_values_period_5`:
      //   alpha = 2/(5+1) = 1/3
      //   SMA seed of [10,12,11,13,14] = 12.0
      //   EMA after 15 = (1/3)*15 + (2/3)*12 = 13.0
      //   EMA after 14 = (1/3)*14 + (2/3)*13 = 13.333333333333334
      final ema = calcEma([10.0, 12.0, 11.0, 13.0, 14.0, 15.0, 14.0], 5);
      expect(ema, isNotNull);
      expect(ema!, closeTo(13.333333333333334, 1e-12));
    });

    test('is path-dependent on history length', () {
      // Same final 5 closes but different prior history → different EMA.
      // This pins WHY callers must feed the full prior-close history.
      const longHistory = <double>[100.0, 105.0, 102.0, 108.0, 110.0, 115.0, 120.0];
      final shortWindow = longHistory.sublist(longHistory.length - 5);

      final emaFull = calcEma(longHistory, 5);
      final emaPartial = calcEma(shortWindow, 5);
      expect(emaFull, isNotNull);
      expect(emaPartial, isNotNull);
      expect(
        (emaFull! - emaPartial!).abs(),
        greaterThan(1e-3),
        reason: 'EMA must drift when the seed window changes',
      );
    });
  });

  group('swingLow / swingHigh', () {
    test('basic min / max', () {
      expect(swingLow([10.0, 7.5, 8.0, 9.0, 6.5, 11.0]), closeTo(6.5, 1e-12));
      expect(swingHigh([10.0, 12.5, 8.0, 14.0, 13.5, 11.0]),
          closeTo(14.0, 1e-12));
    });

    test('empty slice returns null', () {
      expect(swingLow(const []), isNull);
      expect(swingHigh(const []), isNull);
    });

    test('single-element slice returns that value', () {
      expect(swingLow([42.5]), closeTo(42.5, 1e-12));
      expect(swingHigh([42.5]), closeTo(42.5, 1e-12));
    });

    test('handles negative values via real min/max, not zero-init', () {
      // Pin the comparison semantics against all-negative inputs — mirrors
      // the Rust unit test `test_swing_helpers_negative_values`.
      expect(swingLow([-1.0, -5.0, -3.0, -2.0]), closeTo(-5.0, 1e-12));
      expect(swingHigh([-1.0, -5.0, -3.0, -2.0]), closeTo(-1.0, 1e-12));
    });
  });

  group('BbMaType wiring through BacktestService.runBbRsi', () {
    // Deterministic 200-candle sinusoidal fixture, mirror of the F-01
    // parity fixture (cf. test/integration/dart_rust_parity_test.dart).
    // Designed to trigger several BB(20)+RSI(14) entries on both bands so
    // SMA-vs-EMA basis differences propagate visibly into trade outcomes.
    List<CandleData> sineFixture(int n) {
      final out = <CandleData>[];
      const baseTs = 1700000000000;
      const baseline = 50000.0;
      const amplitude = 8000.0;
      const period = 30.0;
      for (int i = 0; i < n; i++) {
        final phase = 2 * math.pi * i / period;
        final price = baseline + amplitude * math.sin(phase);
        out.add(CandleData(
          timestamp: baseTs + i * 3600000,
          open: price - 20,
          high: price + 100,
          low: price - 100,
          close: price,
          volume: 1000.0 + i,
        ));
      }
      return out;
    }

    test('EMA basis (default) matches explicit EMA selection', () {
      // After Diff D-01 the BbRsiParams default is BbMaType.ema. Pin
      // that by checking the unset call equals an explicit EMA call on
      // the same fixture and parameters. Pin Phase-1 BB(20)+RSI(14)
      // ranges so the sinusoid actually produces trades — the new
      // BB(200) default combined with the Phase-2 cross trigger
      // requires a hand-crafted dip+surge fixture which is not what we
      // are testing here.
      final candles = sineFixture(200);
      final resultDefault = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0,
        // Note: bbMaType intentionally omitted so it falls back to the
        // BbRsiParams default — the test verifies that default is EMA.
        params: const BbRsiParams(
          bbPeriod: 20,
          bbStdDev: 2.0,
          rsiPeriod: 14,
          rsiOversold: 30.0,
          rsiOverbought: 70.0,
          swingLookbackBars: 20,
          tpRrRatio: 3.0,
          riskPerTrade: 0.02,
        ),
      );
      final resultExplicitEma = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0,
        params: const BbRsiParams(
          bbPeriod: 20,
          bbStdDev: 2.0,
          bbMaType: BbMaType.ema,
          rsiPeriod: 14,
          rsiOversold: 30.0,
          rsiOverbought: 70.0,
          swingLookbackBars: 20,
          tpRrRatio: 3.0,
          riskPerTrade: 0.02,
        ),
      );
      expect(resultExplicitEma.equityCurve.last.equity,
          closeTo(resultDefault.equityCurve.last.equity, 1e-12));
      expect(resultExplicitEma.metrics.totalTrades,
          equals(resultDefault.metrics.totalTrades));
    });

    test('EMA basis produces different middle than window SMA on step-up', () {
      // Indicator-level proof that bbMaType=EMA wires through to a value
      // that diverges from the window-SMA. Pre-D-07 a separate test
      // proved this end-to-end through engine output (SL was BB-middle,
      // basis-dependent). Post-D-07 the SL is the basis-independent
      // swing-low, so the engine-output discriminator disappears for the
      // pre-built dip+surge fixture. We replace that test with this
      // direct check on the same algorithm the engine's BB pre-compute
      // loop uses: `calcEma` vs the window-SMA reduction in
      // `runBbRsi`. If the two collapse to equality, the bbMaType=EMA
      // branch in the engine would silently behave like SMA.
      final closes = <double>[
        ...List.filled(20, 100.0),
        105.0, 110.0, 115.0, 120.0, 125.0,
        130.0, 135.0, 140.0, 145.0, 150.0,
      ];
      final smaWindow = closes.sublist(closes.length - 20);
      final smaBasis =
          smaWindow.reduce((a, b) => a + b) / smaWindow.length;
      final emaBasis = calcEma(closes, 20);
      expect(emaBasis, isNotNull);
      expect(
        (emaBasis! - smaBasis).abs(),
        greaterThan(1.0),
        reason:
            'EMA tracks recent prices more aggressively → diverges from '
            'window-SMA on a step-up history; sma=$smaBasis ema=$emaBasis',
      );
    });

    test('rustParamValue encoding round-trips through f64', () {
      // The Rust engine receives `bb_ma_type` as f64 in {0.0, 1.0}.
      // Pin the encoding here so a Dart-side refactor of the enum
      // cannot silently break the FFI parity contract.
      expect(BbMaType.sma.rustParamValue, 0.0);
      expect(BbMaType.ema.rustParamValue, 1.0);
    });
  });

  group('rollingMax / rollingMin (Phase-2 Welle I1)', () {
    // Reference values shared bit-for-bit with the Rust unit tests in
    // `rust/trading_engine/src/addins/ichimoku.rs` (`mod tests`). The
    // 200-bar parity fixture below uses the same generator on both
    // sides, so the anchor assertions lock the two engines at 1e-9.

    test('rollingMax: period 0 returns NaN', () {
      expect(rollingMax(const [1.0, 2.0, 3.0], 2, 0).isNaN, isTrue);
    });

    test('rollingMax: empty values returns NaN', () {
      expect(rollingMax(const [], 0, 1).isNaN, isTrue);
    });

    test('rollingMax: end_idx out of bounds returns NaN', () {
      expect(rollingMax(const [1.0, 2.0], 5, 1).isNaN, isTrue);
    });

    test('rollingMax: warm-up (period > end_idx + 1) returns NaN', () {
      expect(
        rollingMax(const [1.0, 2.0, 3.0, 4.0, 5.0], 2, 9).isNaN,
        isTrue,
      );
    });

    test('rollingMax: period=1 equals values[end_idx]', () {
      const v = [10.0, 20.0, 15.0, 30.0];
      expect(rollingMax(v, 0, 1), closeTo(10.0, 1e-12));
      expect(rollingMax(v, 2, 1), closeTo(15.0, 1e-12));
      expect(rollingMax(v, 3, 1), closeTo(30.0, 1e-12));
    });

    test('rollingMax: constant values return the constant', () {
      final v = List<double>.filled(20, 42.0);
      for (int i = 0; i < 20; i++) {
        final period = math.min(5, i + 1);
        expect(rollingMax(v, i, period), closeTo(42.0, 1e-12));
      }
    });

    test('rollingMax: first valid index at period - 1', () {
      const v = [1.0, 2.0, 3.0, 4.0, 5.0];
      expect(rollingMax(v, 3, 5).isNaN, isTrue);
      expect(rollingMax(v, 4, 5), closeTo(5.0, 1e-12));
    });

    test('rollingMax: known small fixture, period 3', () {
      // Mirrors `test_rolling_max_known_small_fixture` in Rust.
      const v = [3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0, 3.0];
      const expected = <int, double>{
        2: 4.0,
        3: 4.0,
        4: 5.0,
        5: 9.0,
        6: 9.0,
        7: 9.0,
        8: 6.0,
        9: 6.0,
      };
      for (final entry in expected.entries) {
        expect(rollingMax(v, entry.key, 3), closeTo(entry.value, 1e-9),
            reason: 'rollingMax idx=${entry.key}');
      }
    });

    test('rollingMax: NaN inside the window poisons the result', () {
      const v = [1.0, 2.0, double.nan, 4.0, 5.0];
      expect(rollingMax(v, 3, 3).isNaN, isTrue);
      expect(rollingMax(v, 4, 2), closeTo(5.0, 1e-12));
    });

    test('rollingMin: period 0 returns NaN', () {
      expect(rollingMin(const [1.0, 2.0, 3.0], 2, 0).isNaN, isTrue);
    });

    test('rollingMin: empty values returns NaN', () {
      expect(rollingMin(const [], 0, 1).isNaN, isTrue);
    });

    test('rollingMin: end_idx out of bounds returns NaN', () {
      expect(rollingMin(const [1.0, 2.0], 5, 1).isNaN, isTrue);
    });

    test('rollingMin: warm-up returns NaN', () {
      expect(
        rollingMin(const [5.0, 4.0, 3.0, 2.0, 1.0], 2, 9).isNaN,
        isTrue,
      );
    });

    test('rollingMin: period=1 equals values[end_idx]', () {
      const v = [10.0, 20.0, 15.0, 30.0];
      expect(rollingMin(v, 0, 1), closeTo(10.0, 1e-12));
      expect(rollingMin(v, 2, 1), closeTo(15.0, 1e-12));
      expect(rollingMin(v, 3, 1), closeTo(30.0, 1e-12));
    });

    test('rollingMin: constant values return the constant', () {
      final v = List<double>.filled(20, 42.0);
      for (int i = 0; i < 20; i++) {
        final period = math.min(5, i + 1);
        expect(rollingMin(v, i, period), closeTo(42.0, 1e-12));
      }
    });

    test('rollingMin: first valid index at period - 1', () {
      const v = [5.0, 4.0, 3.0, 2.0, 1.0];
      expect(rollingMin(v, 3, 5).isNaN, isTrue);
      expect(rollingMin(v, 4, 5), closeTo(1.0, 1e-12));
    });

    test('rollingMin: known small fixture, period 3', () {
      // Mirrors `test_rolling_min_known_small_fixture` in Rust.
      const v = [3.0, 1.0, 4.0, 1.0, 5.0, 9.0, 2.0, 6.0, 5.0, 3.0];
      const expected = <int, double>{
        2: 1.0,
        3: 1.0,
        4: 1.0,
        5: 1.0,
        6: 2.0,
        7: 2.0,
        8: 2.0,
        9: 3.0,
      };
      for (final entry in expected.entries) {
        expect(rollingMin(v, entry.key, 3), closeTo(entry.value, 1e-9),
            reason: 'rollingMin idx=${entry.key}');
      }
    });

    test('rollingMin: NaN inside the window poisons the result', () {
      const v = [5.0, 4.0, double.nan, 2.0, 1.0];
      expect(rollingMin(v, 3, 3).isNaN, isTrue);
      expect(rollingMin(v, 4, 2), closeTo(1.0, 1e-12));
    });

    // ── 200-bar parity fixture (mirrors `parity_fixture_200` in Rust) ──

    /// Same generator as `parity_fixture_200` in
    /// `rust/trading_engine/src/addins/ichimoku.rs`:
    ///   v[i] = 100 + 10*sin(0.13*i) + 3*cos(0.41*i) + 0.5*(i%7)
    List<double> parityFixture200() {
      return List<double>.generate(
        200,
        (i) {
          final x = i.toDouble();
          return 100.0 +
              10.0 * math.sin(0.13 * x) +
              3.0 * math.cos(0.41 * x) +
              0.5 * (i % 7);
        },
      );
    }

    test('rollingMax: 200-bar parity fixture anchors match Rust', () {
      // Anchors hit: first valid window (period - 1), middle of the
      // series, and the last bar. Tolerance 1e-9 locks Dart↔Rust parity.
      final v = parityFixture200();
      expect(rollingMax(v, 8, 9), closeTo(107.70308334140422, 1e-9));
      expect(rollingMax(v, 100, 26), closeTo(102.23965253569493, 1e-9));
      expect(rollingMax(v, 199, 52), closeTo(114.61074181274041, 1e-9));
    });

    test('rollingMin: 200-bar parity fixture anchors match Rust', () {
      final v = parityFixture200();
      // i=0: 100 + 10*sin(0) + 3*cos(0) + 0 = 103.0 exactly.
      expect(rollingMin(v, 8, 9), closeTo(103.0, 1e-9));
      expect(rollingMin(v, 100, 26), closeTo(87.04923608392424, 1e-9));
      expect(rollingMin(v, 199, 52), closeTo(89.63103534666807, 1e-9));
    });
  });
}
