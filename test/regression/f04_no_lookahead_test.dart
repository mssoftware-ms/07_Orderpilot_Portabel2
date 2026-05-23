/// F-04 regression: no look-ahead bias (Dart engine).
///
/// Spec §3.4 F-04:
///   A strategy signal generated on candle `i` (with information up to and
///   including `candle[i].close`) MUST be executed at the OPEN of candle
///   `i+1`, not at the close of candle `i`. The pre-F-04 Dart engine
///   opened positions at `candle[i].close` which is a textbook look-ahead
///   bug: the strategy is reading information it would not have at the
///   moment the order is sent.
///
/// F-04 strukturelle Verifikation: Signal-Bar i führt zu Execution beim
/// open von Bar i+1, NICHT beim close von Bar i. Bit-exakte Lag-Assertion
/// auf Entry-Timestamp und Entry-Preis. Die semantische „Look-Ahead
/// favourisiert die Strategie"-Assertion ist auf der 200-Candle Sinus-
/// Fixture nicht testbar (Fixture-Konvention `open = price - 20` dreht
/// den Effekt um). Sie wird im Phase-1-Gate Reference-Backtest auf
/// BTCUSDT 1h 2024-01..06 verifiziert (Plan §3.5).
///
/// Tolerance: 1e-9 for the open-match. Slippage default is 0 bps per
/// Plan rev2 normative paragraph.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';

/// The 200-candle parity fixture, copied verbatim from
/// test/integration/dart_rust_parity_test.dart so this regression is
/// self-contained and does not import a test-only helper.
List<CandleData> _generateParityFixture() {
  final candles = <CandleData>[];
  const baseTs = 1700000000000;
  const baseline = 50000.0;
  const amplitude = 8000.0;
  const period = 30.0;
  for (int i = 0; i < 200; i++) {
    final phase = 2 * math.pi * i / period;
    final price = baseline + amplitude * math.sin(phase);
    candles.add(CandleData(
      timestamp: baseTs + i * 3600000,
      open: price - 20,
      high: price + 100,
      low: price - 100,
      close: price,
      volume: 1000.0 + i,
    ));
  }
  return candles;
}

/// Find a candle by its timestamp. Returns the index, or -1 if absent.
int _indexOfTimestamp(List<CandleData> candles, int ts) {
  for (int i = 0; i < candles.length; i++) {
    if (candles[i].timestamp == ts) return i;
  }
  return -1;
}

void main() {
  const initialBalance = 10000.0;
  const feeRate = 0.0006;

  group('F-04 no lookahead bias', () {
    test(
      'every trade entryPrice equals its bar\'s open, not the previous bar\'s close',
      () {
        final candles = _generateParityFixture();
        final result = BacktestService.runBbRsi(
          candles: candles,
          initialBalance: initialBalance,
          feeRate: feeRate,
        );

        expect(
          result.trades,
          isNotEmpty,
          reason: 'parity fixture must produce trades — otherwise the F-04 '
              'regression would be a tautology of 0 == 0',
        );

        for (final trade in result.trades) {
          final entryIdx = _indexOfTimestamp(candles, trade.entryTimestamp);
          expect(
            entryIdx,
            isNonNegative,
            reason:
                'trade.entryTimestamp ${trade.entryTimestamp} must reference '
                'a real candle in the fixture',
          );

          final entryCandle = candles[entryIdx];
          // Default slippage = 0 → entry executes bit-exact at the bar open.
          expect(
            trade.entryPrice,
            closeTo(entryCandle.open, 1e-9),
            reason: 'entry must execute at the bar OPEN (next-bar-open rule)',
          );

          // Smoking gun: prior bar's close MUST differ from entry price.
          // In the parity fixture every candle has close - open = 20, so
          // this inequality is mechanical, not depending on which bar
          // signalled.
          if (entryIdx > 0) {
            final priorClose = candles[entryIdx - 1].close;
            expect(
              (trade.entryPrice - priorClose).abs(),
              greaterThan(1e-6),
              reason: 'entry_price MUST NOT equal candle[entryIdx-1].close '
                  '— that pattern is the F-04 look-ahead bug',
            );
          }
        }
      },
    );
  });
}
