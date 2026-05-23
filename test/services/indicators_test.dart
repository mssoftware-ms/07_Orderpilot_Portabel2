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
}
