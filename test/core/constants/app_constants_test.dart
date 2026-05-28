/// Welle P4C-H-1 — pin `AppConstants.supportedTimeframes` against the
/// Binance Spot kline-interval whitelist so future additions can't
/// resurrect the `'3h'` mistake that left the chart tab silently
/// frozen during Maik's smoke.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/constants/app_constants.dart';

void main() {
  group('AppConstants.supportedTimeframes', () {
    test('does not contain the unsupported `3h` Binance interval', () {
      expect(
        AppConstants.supportedTimeframes,
        isNot(contains('3h')),
        reason: 'Binance Spot has no 3h kline interval — selecting it '
            'leaves the chart frozen on a silent WS connect failure.',
      );
    });

    test('contains `30m` (the slot that replaced `3h`)', () {
      expect(AppConstants.supportedTimeframes, contains('30m'));
    });

    test('is a strict subset of the Binance Spot kline whitelist', () {
      for (final tf in AppConstants.supportedTimeframes) {
        expect(
          AppConstants.binanceSpotKlineIntervals,
          contains(tf),
          reason: 'Timeframe "$tf" is not a documented Binance Spot '
              'kline interval — adding it will silently break the WS '
              'connect path.',
        );
      }
    });

    test('list has no duplicates', () {
      expect(
        AppConstants.supportedTimeframes.toSet().length,
        AppConstants.supportedTimeframes.length,
        reason: 'Duplicates in supportedTimeframes would render '
            'multiple identical chips in the chart/backtest screens.',
      );
    });

    test('expected eight entries — keeps the chip row layout stable', () {
      expect(AppConstants.supportedTimeframes.length, 8);
    });
  });
}
