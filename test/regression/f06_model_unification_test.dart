/// F-06 Regression: Trade/BacktestMetrics model unification.
///
/// Before this refactor the codebase had three diverging classes:
///   - lib/core/models/trade.dart           : BacktestMetrics, ClosedTrade
///   - lib/services/backtest_service.dart   : BacktestMetrics, TradeRecord
///   - lib/services/rust_bridge.dart        : RustBacktestMetrics
///
/// After F-06 the canonical types live in lib/core/models/trade.dart and the
/// FFI DTO (RustBacktestMetrics) exposes a converter to the canonical type.
///
/// These tests use Dart's type identity (a class is identified by its
/// declaring library) so an `isA<canonical.BacktestMetrics>` check is `false`
/// while the engine still returns a same-named local duplicate.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/core/models/trade.dart' as canonical;
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/rust_bridge.dart';

void main() {
  List<CandleData> buildCandles({int count = 200}) {
    final baseTs = DateTime.utc(2024, 1, 1).millisecondsSinceEpoch;
    final out = <CandleData>[];
    for (int i = 0; i < count; i++) {
      final wave = 2000 *
          (i % 60 < 30 ? -1.0 + (i % 30) / 15.0 : 1.0 - (i % 30) / 15.0);
      final price = 50000 + wave;
      out.add(CandleData(
        timestamp: baseTs + i * 3600000,
        open: price - 20,
        high: price + 100,
        low: price - 100,
        close: price,
        volume: 1000 + i.toDouble(),
      ));
    }
    return out;
  }

  group('F-06: Trade/BacktestMetrics model unification', () {
    test('BacktestService.runBbRsi returns canonical BacktestMetrics', () {
      final result = BacktestService.runBbRsi(
        candles: buildCandles(),
        initialBalance: 10000,
        feeRate: 0.0006,
      );

      expect(
        result.metrics,
        isA<canonical.BacktestMetrics>(),
        reason:
            'BacktestService must return canonical BacktestMetrics from '
            'lib/core/models/trade.dart, not a local duplicate.',
      );
    });

    test('BacktestService.runBbRsi returns canonical ClosedTrade list', () {
      final result = BacktestService.runBbRsi(
        candles: buildCandles(),
        initialBalance: 10000,
        feeRate: 0.0006,
      );

      expect(
        result.trades,
        isA<List<canonical.ClosedTrade>>(),
        reason:
            'trades list must use canonical ClosedTrade from '
            'lib/core/models/trade.dart, not a local TradeRecord.',
      );
    });

    test('RustBacktestMetrics exposes toBacktestMetrics() converter', () {
      final dto = RustBacktestMetrics.empty();
      final dynamic d = dto;

      expect(
        () => d.toBacktestMetrics(),
        returnsNormally,
        reason:
            'RustBacktestMetrics must provide a toBacktestMetrics() converter '
            'so the FFI DTO can be mapped to the canonical BacktestMetrics '
            'type instead of being a parallel "metrics" class itself.',
      );

      final result = d.toBacktestMetrics();
      expect(
        result,
        isA<canonical.BacktestMetrics>(),
        reason:
            'toBacktestMetrics() must return the canonical BacktestMetrics '
            'from lib/core/models/trade.dart.',
      );
    });
  });
}
