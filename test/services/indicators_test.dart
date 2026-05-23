/// Unit tests for the Dart indicator helpers in `lib/services/indicators.dart`.
///
/// Every reference value in this file is shared bit-for-bit with the
/// Rust unit tests in `rust/trading_engine/src/addins/bb_rsi.rs` under
/// `mod tests`, so the two engines stay in lock-step at the algorithm
/// level even before any integration parity test exercises EMA.
library;

import 'package:flutter_test/flutter_test.dart';
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
}
