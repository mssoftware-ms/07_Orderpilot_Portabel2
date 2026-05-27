/// Unit tests for the Welle P4C-1 Bollinger Bands and RSI helpers in
/// `lib/services/indicators.dart`.
///
/// These extracted helpers are the same code that used to live inline in
/// `BacktestService.runBbRsi`. Every reference value here is hand-derived
/// from the algorithm spec; the cross-engine bit-exact guarantee is
/// covered by `test/integration/phase1_reference_backtest_test.dart`,
/// not by this file.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/services/indicators.dart';

void main() {
  group('calcBollingerBands', () {
    test('returns null for period 0', () {
      expect(
        calcBollingerBands([1.0, 2.0, 3.0], 0, 2.0, BbBasis.sma),
        isNull,
      );
    });

    test('returns null for insufficient data', () {
      expect(
        calcBollingerBands([1.0, 2.0, 3.0], 5, 2.0, BbBasis.sma),
        isNull,
      );
    });

    test('warm-up bars init to 0 (SMA)', () {
      // closes = [1..10], period=5 → indices 0..3 are warm-up and must
      // stay zero to preserve the legacy parity initialisation.
      final closes = List<double>.generate(10, (i) => (i + 1).toDouble());
      final bb = calcBollingerBands(closes, 5, 2.0, BbBasis.sma)!;
      for (int i = 0; i < 4; i++) {
        expect(bb.upper[i], 0.0, reason: 'upper warm-up at $i');
        expect(bb.middle[i], 0.0, reason: 'middle warm-up at $i');
        expect(bb.lower[i], 0.0, reason: 'lower warm-up at $i');
      }
    });

    test('SMA basis with hand-computed values', () {
      // closes = [1..10], period=5, stdDev=2.
      //
      // At i=4 (first valid): window=[1,2,3,4,5]
      //   SMA = 3
      //   population variance = ((1-3)²+(2-3)²+(3-3)²+(4-3)²+(5-3)²) / 5
      //                       = (4+1+0+1+4) / 5
      //                       = 2.0
      //   stddev = sqrt(2)
      //   middle = 3,  upper = 3 + 2·sqrt(2),  lower = 3 - 2·sqrt(2)
      //
      // At i=9: window=[6,7,8,9,10] — same shape shifted by 5,
      //   SMA = 8, stddev = sqrt(2), middle = 8.
      final closes = List<double>.generate(10, (i) => (i + 1).toDouble());
      final bb = calcBollingerBands(closes, 5, 2.0, BbBasis.sma)!;
      final s = math.sqrt(2.0);

      expect(bb.middle[4], closeTo(3.0, 1e-12));
      expect(bb.upper[4], closeTo(3.0 + 2.0 * s, 1e-12));
      expect(bb.lower[4], closeTo(3.0 - 2.0 * s, 1e-12));

      expect(bb.middle[9], closeTo(8.0, 1e-12));
      expect(bb.upper[9], closeTo(8.0 + 2.0 * s, 1e-12));
      expect(bb.lower[9], closeTo(8.0 - 2.0 * s, 1e-12));
    });

    test('EMA basis seed at first valid bar equals window-SMA', () {
      // EMA basis is SMA-seeded — the seed sample at `i = period - 1`
      // must therefore equal the window-SMA (no recursive step yet).
      final closes = List<double>.generate(10, (i) => (i + 1).toDouble());
      final ema = calcBollingerBands(closes, 5, 2.0, BbBasis.ema)!;
      final sma = calcBollingerBands(closes, 5, 2.0, BbBasis.sma)!;
      expect(ema.middle[4], closeTo(sma.middle[4], 1e-12));
    });

    test('EMA basis tracks alpha-weighted recurrence after seed', () {
      // closes = [1..10], period=5, alpha = 2/6 = 1/3.
      // Seed at i=4: ema = SMA([1..5]) = 3.
      // i=5: ema = 1/3 · 6 + 2/3 · 3 = 2 + 2 = 4
      // i=6: ema = 1/3 · 7 + 2/3 · 4 = 7/3 + 8/3 = 5
      // i=7: ema = 1/3 · 8 + 2/3 · 5 = 8/3 + 10/3 = 6
      // i=8: ema = 1/3 · 9 + 2/3 · 6 = 3 + 4 = 7
      // i=9: ema = 1/3 · 10 + 2/3 · 7 = 10/3 + 14/3 = 8
      final closes = List<double>.generate(10, (i) => (i + 1).toDouble());
      final bb = calcBollingerBands(closes, 5, 2.0, BbBasis.ema)!;
      expect(bb.middle[5], closeTo(4.0, 1e-12));
      expect(bb.middle[6], closeTo(5.0, 1e-12));
      expect(bb.middle[7], closeTo(6.0, 1e-12));
      expect(bb.middle[8], closeTo(7.0, 1e-12));
      expect(bb.middle[9], closeTo(8.0, 1e-12));
    });

    test('stddev component is independent of basis', () {
      // Band-width = upper - lower = 2·stdDev·windowStddev — purely a
      // function of the window-SMA stddev, NOT of the basis. This is
      // the explicit spec contract so toggling SMA ↔ EMA does not
      // change how "wide" the bands feel on the same closes.
      final closes = List<double>.generate(10, (i) => (i + 1).toDouble());
      final sma = calcBollingerBands(closes, 5, 2.0, BbBasis.sma)!;
      final ema = calcBollingerBands(closes, 5, 2.0, BbBasis.ema)!;
      for (int i = 4; i < 10; i++) {
        final widthSma = sma.upper[i] - sma.lower[i];
        final widthEma = ema.upper[i] - ema.lower[i];
        expect(widthEma, closeTo(widthSma, 1e-12), reason: 'i=$i');
      }
    });

    test('output arrays have the same length as the input', () {
      final closes = List<double>.generate(25, (i) => i.toDouble());
      final bb = calcBollingerBands(closes, 5, 2.0, BbBasis.sma)!;
      expect(bb.upper.length, 25);
      expect(bb.middle.length, 25);
      expect(bb.lower.length, 25);
    });
  });

  group('calcRsi', () {
    test('returns null for period 0', () {
      expect(calcRsi([1.0, 2.0, 3.0], 0), isNull);
    });

    test('returns null for insufficient data', () {
      // need `period + 1` samples to compute the first RSI.
      expect(calcRsi([1.0, 2.0, 3.0], 3), isNull);
    });

    test('warm-up bars init to 50', () {
      // closes length 10, period=5 → indices 0..4 are warm-up.
      final closes = List<double>.generate(10, (i) => (i + 1).toDouble());
      final rsi = calcRsi(closes, 5)!;
      for (int i = 0; i < 5; i++) {
        expect(rsi[i], 50.0, reason: 'warm-up at $i');
      }
    });

    test('strictly increasing closes -> RSI saturates at 100', () {
      // Every per-bar change is positive, so avgLoss stays 0 from the
      // initial window onward and the RSI formula short-circuits to 100.
      final closes = List<double>.generate(10, (i) => (i + 1).toDouble());
      final rsi = calcRsi(closes, 5)!;
      for (int i = 5; i < 10; i++) {
        expect(rsi[i], 100.0, reason: 'i=$i');
      }
    });

    test('strictly decreasing closes -> RSI saturates at 0', () {
      // avgGain stays 0 → RS = 0 / avgLoss = 0 → RSI = 100 - 100/(1+0) = 0.
      final closes = List<double>.generate(10, (i) => (10 - i).toDouble());
      final rsi = calcRsi(closes, 5)!;
      for (int i = 5; i < 10; i++) {
        expect(rsi[i], closeTo(0.0, 1e-12), reason: 'i=$i');
      }
    });

    test('hand-computed RSI on a small mixed series', () {
      // closes:  10, 11, 10, 12, 13, 11, 14   (period=3)
      // changes: +1, -1, +2, +1, -2, +3
      // Initial window (i=1..3): gains [1, 0, 2] -> avg=3/3=1
      //                          losses [0, 1, 0] -> avg=1/3
      //   rs = 1 / (1/3) = 3 → rsi[3] = 100 - 100/4 = 75.0
      // i=4: change=+1, gain=1, loss=0
      //   avgGain = (1·2 + 1)/3 = 1.0
      //   avgLoss = (1/3·2 + 0)/3 = 2/9
      //   rs = 1 / (2/9) = 4.5 → rsi[4] = 100 - 100/5.5 = 81.81818...
      // i=5: change=-2, gain=0, loss=2
      //   avgGain = (1·2 + 0)/3 = 2/3
      //   avgLoss = (2/9·2 + 2)/3 = (4/9 + 2)/3 = (22/9)/3 = 22/27
      //   rs = (2/3) / (22/27) = (2/3)·(27/22) = 54/66 = 9/11
      //   rsi[5] = 100 - 100/(1 + 9/11) = 100 - 100/(20/11)
      //          = 100 - 1100/20 = 100 - 55 = 45.0
      // i=6: change=+3, gain=3, loss=0
      //   avgGain = (2/3·2 + 3)/3 = (4/3 + 3)/3 = (13/3)/3 = 13/9
      //   avgLoss = (22/27·2 + 0)/3 = (44/27)/3 = 44/81
      //   rs = (13/9) / (44/81) = (13/9)·(81/44) = 13·9/44 = 117/44
      //   rsi[6] = 100 - 100/(1 + 117/44) = 100 - 100/(161/44)
      //          = 100 - 4400/161 ≈ 72.67080745341615
      final closes = [10.0, 11.0, 10.0, 12.0, 13.0, 11.0, 14.0];
      final rsi = calcRsi(closes, 3)!;
      expect(rsi[3], closeTo(75.0, 1e-12));
      expect(rsi[4], closeTo(100.0 - 100.0 / 5.5, 1e-12));
      expect(rsi[5], closeTo(45.0, 1e-12));
      expect(rsi[6], closeTo(100.0 - 4400.0 / 161.0, 1e-12));
    });

    test('output array has the same length as the input', () {
      final closes = List<double>.generate(20, (i) => i.toDouble());
      final rsi = calcRsi(closes, 5)!;
      expect(rsi.length, 20);
    });
  });
}
