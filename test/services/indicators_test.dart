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
        ),
      );
      expect(resultExplicitEma.equityCurve.last.equity,
          closeTo(resultDefault.equityCurve.last.equity, 1e-12));
      expect(resultExplicitEma.metrics.totalTrades,
          equals(resultDefault.metrics.totalTrades));
    });

    // A dip-then-surge fixture that triggers the Phase-2 cross + close
    // > upper condition: 20 flat candles + 14-bar decline (drives
    // RSI(14) toward 0) + a single surge bar (close > upper, RSI crosses
    // up through 30) + SL-exit candle + flat tail. SMA-BB and EMA-BB
    // place the middle (and therefore the SL placeholder) at different
    // levels, so the exit price diverges between the two branches even
    // though the trigger bar is the same.
    List<CandleData> dipSurgeFixture() {
      final out = <CandleData>[];
      const baseTs = 1700000000000;
      for (int i = 0; i < 20; i++) {
        out.add(CandleData(
          timestamp: baseTs + i * 3600000,
          open: 99.9, high: 100.3, low: 99.7, close: 100.0, volume: 1000.0,
        ));
      }
      for (int i = 0; i < 14; i++) {
        final close = 100.0 - (i + 1) * 2.0;
        out.add(CandleData(
          timestamp: baseTs + (20 + i) * 3600000,
          open: close + 0.5, high: close + 0.5, low: close - 0.5,
          close: close, volume: 1000.0,
        ));
      }
      out.add(CandleData(
        timestamp: baseTs + 34 * 3600000,
        open: 72.5, high: 120.5, low: 72.0, close: 120.0, volume: 1000.0,
      ));
      out.add(CandleData(
        timestamp: baseTs + 35 * 3600000,
        open: 119.0, high: 120.0, low: 0.0, close: 110.0, volume: 1000.0,
      ));
      for (int i = 36; i < 60; i++) {
        out.add(CandleData(
          timestamp: baseTs + i * 3600000,
          open: 110.0, high: 110.5, low: 109.5, close: 110.0, volume: 1000.0,
        ));
      }
      return out;
    }

    test('EMA basis diverges from SMA on a dip+surge fixture', () {
      // EMA tracks price more tightly than SMA → BB middle (and the SL
      // placeholder = middle) sit at different prices. The trade exits
      // through SL at the middle, so the realised PnL differs between
      // branches even though the entry bar is the same.
      final candles = dipSurgeFixture();
      final sma = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0,
        params: const BbRsiParams(
          bbPeriod: 20,
          bbStdDev: 2.0,
          bbMaType: BbMaType.sma,
          rsiPeriod: 14,
          rsiOversold: 30.0,
          rsiOverbought: 70.0,
        ),
      );
      final ema = BacktestService.runBbRsi(
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
        ),
      );
      // We do not assert a specific direction (trade-count vs equity can
      // both shift); we only require that SMA and EMA produce non-identical
      // engine state, which is sufficient to prove the parameter is live.
      final smaTrades = sma.metrics.totalTrades;
      final emaTrades = ema.metrics.totalTrades;
      final smaEquity = sma.equityCurve.isEmpty
          ? 10000.0
          : sma.equityCurve.last.equity;
      final emaEquity = ema.equityCurve.isEmpty
          ? 10000.0
          : ema.equityCurve.last.equity;
      expect(
        smaTrades != emaTrades || (smaEquity - emaEquity).abs() > 1e-9,
        isTrue,
        reason: 'EMA branch must visibly affect the backtest output on a '
            'monotonic ramp; smaTrades=$smaTrades emaTrades=$emaTrades '
            'smaEquity=$smaEquity emaEquity=$emaEquity',
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
