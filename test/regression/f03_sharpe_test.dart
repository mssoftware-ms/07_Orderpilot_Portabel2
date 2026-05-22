/// F-03 regression: Sharpe ratio annualization must be timeframe-aware and
/// match the Rust engine bit-for-bit.
///
/// Spec §3.4 F-03 (normative):
///   Sharpe = mean(returns) / stdev(returns) * sqrt(periods_per_year(tf))
///   risk-free rate = 0 (Crypto 24/7), NOT configurable.
///
/// The pre-F-03 Dart code hardcoded `sqrt(252)` (equity-market daily
/// approximation) for every timeframe; the pre-F-03 Rust code computed
/// Sharpe over trade.pnl_percent with no annualization at all. This test
/// pins the corrected, parity-aligned contract.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/timeframe.dart';
import 'package:trading_app/services/sharpe.dart';

/// Alternating +δ, −δ around `mean` with even `n` → sample mean exactly
/// `mean`, population stdev exactly `delta`.
List<double> constructReturns(double mean, double delta, int n) {
  if (n % 2 != 0) {
    throw ArgumentError('n must be even for exact sample stats');
  }
  return List.generate(n, (i) => i % 2 == 0 ? mean + delta : mean - delta);
}

void main() {
  group('F-03 periodsPerYear table (Plan §3.4)', () {
    test('matches Crypto 24/7 spec table', () {
      expect(periodsPerYear(Timeframe.m1), 525600.0);
      expect(periodsPerYear(Timeframe.m5), 105120.0);
      expect(periodsPerYear(Timeframe.m15), 35040.0);
      expect(periodsPerYear(Timeframe.h1), 8760.0);
      expect(periodsPerYear(Timeframe.h4), 2190.0);
      expect(periodsPerYear(Timeframe.d1), 365.0);
    });
  });

  group('F-03 annualizedSharpe', () {
    test('H1 annualization matches closed-form', () {
      const mean = 0.001;
      const delta = 0.002;
      final returns = constructReturns(mean, delta, 8760);
      final got = annualizedSharpe(returns, Timeframe.h1);
      final want = (mean / delta) * math.sqrt(8760.0);
      expect((got - want).abs() < 1e-9, isTrue,
          reason: 'H1 sharpe got $got want $want');
    });

    test('each timeframe uses its own annualization factor', () {
      const mean = 0.0005;
      const delta = 0.001;
      final returns = constructReturns(mean, delta, 1000);
      for (final tf in [
        Timeframe.m1,
        Timeframe.m5,
        Timeframe.m15,
        Timeframe.h1,
        Timeframe.h4,
        Timeframe.d1,
      ]) {
        final got = annualizedSharpe(returns, tf);
        final want = (mean / delta) * math.sqrt(periodsPerYear(tf));
        expect((got - want).abs() < 1e-9, isTrue,
            reason: '$tf sharpe got $got want $want');
      }
    });

    test('H1 > D1 for identical returns; ratio is sqrt(24)', () {
      final returns = constructReturns(0.001, 0.002, 1000);
      final sH1 = annualizedSharpe(returns, Timeframe.h1);
      final sD1 = annualizedSharpe(returns, Timeframe.d1);
      expect(sH1 > sD1, isTrue);
      final ratio = sH1 / sD1;
      final want = math.sqrt(8760.0 / 365.0);
      expect((ratio - want).abs() < 1e-9, isTrue);
    });

    test('empty returns yield 0 sharpe', () {
      expect(annualizedSharpe(<double>[], Timeframe.h1), 0.0);
    });

    test('zero stdev (flat returns) yield 0 sharpe — no float-noise blow-up',
        () {
      final flat = List<double>.filled(100, 0.001);
      expect(annualizedSharpe(flat, Timeframe.h1), 0.0);
    });
  });
}
