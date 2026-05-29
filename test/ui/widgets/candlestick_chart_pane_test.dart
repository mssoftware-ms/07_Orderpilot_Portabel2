/// Welle P4C-H-3 — candlestick axis-label coverage.
///
/// The label *geometry* lives inside a private CustomPainter, but the
/// label *content* (tick values, decimals, per-timeframe time format,
/// which bars get a tick) is factored into pure top-level helpers so it
/// can be pinned here without pumping a canvas. A widget smoke test then
/// confirms the pane renders the axes without throwing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/ui/widgets/candlestick_chart_pane.dart';

CandleData _candle(int ts, double price) => CandleData(
      timestamp: ts,
      open: price,
      high: price + 1,
      low: price - 1,
      close: price,
      volume: 1.0,
    );

void main() {
  group('chartPriceTicks', () {
    test('produces the requested count spanning [min, max] inclusive', () {
      final ticks = chartPriceTicks(100, 200, count: 6);
      expect(ticks.length, 6);
      expect(ticks.first, 100);
      expect(ticks.last, 200);
      // Evenly spaced.
      for (int i = 1; i < ticks.length; i++) {
        expect(ticks[i] - ticks[i - 1], closeTo(20, 1e-9));
      }
    });

    test('collapses a degenerate range to a single label', () {
      expect(chartPriceTicks(50, 50), [50]);
      expect(chartPriceTicks(50, 40), [50]);
    });
  });

  group('chartPriceDecimals', () {
    test('scales precision down as the tick step grows', () {
      expect(chartPriceDecimals(400), 0); // BTC-scale steps
      expect(chartPriceDecimals(5), 2);
      expect(chartPriceDecimals(0.2), 4);
      expect(chartPriceDecimals(0.005), 6); // sub-cent alt
    });

    test('is sign agnostic', () {
      expect(chartPriceDecimals(-400), 0);
    });
  });

  group('chartTimeTickIndices', () {
    test('returns all indices when the window is shorter than the count', () {
      expect(chartTimeTickIndices(3, count: 5), [0, 1, 2]);
    });

    test('spaces evenly with first and last always present', () {
      final idx = chartTimeTickIndices(100, count: 5);
      expect(idx.first, 0);
      expect(idx.last, 99);
      expect(idx.length, 5);
      // Strictly increasing (de-duplicated).
      for (int i = 1; i < idx.length; i++) {
        expect(idx[i], greaterThan(idx[i - 1]));
      }
    });

    test('empty window yields no ticks', () {
      expect(chartTimeTickIndices(0), isEmpty);
    });
  });

  group('chartFormatTime', () {
    final t = DateTime.utc(2024, 1, 2, 14, 30);

    test('intraday minutes show wall-clock only', () {
      expect(chartFormatTime(t, '1m'), '14:30');
      expect(chartFormatTime(t, '15m'), '14:30');
      expect(chartFormatTime(t, '30m'), '14:30');
    });

    test('hourly buckets add the date with a pinned :00', () {
      expect(chartFormatTime(t, '1h'), '01-02 14:00');
      expect(chartFormatTime(t, '4h'), '01-02 14:00');
    });

    test('daily+ drops the time', () {
      expect(chartFormatTime(t, '1d'), '2024-01-02');
    });

    test('unknown timeframe falls back to date + time', () {
      expect(chartFormatTime(t, '7h'), '01-02 14:30');
    });
  });

  group('CandlestickChartPane widget', () {
    testWidgets('empty candles render the placeholder', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: CandlestickChartPane(candles: [], timeframe: '1h'),
        ),
      ));
      expect(find.text('No candles yet'), findsOneWidget);
    });

    testWidgets('non-empty candles paint the axes without throwing',
        (tester) async {
      final candles = [
        for (int i = 0; i < 40; i++)
          _candle(i * 3_600_000, 100.0 + i.toDouble()),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: CandlestickChartPane(candles: candles, timeframe: '1h'),
          ),
        ),
      ));
      // No "No candles yet" placeholder and a clean frame (no painter
      // exception bubbled up through pumpAndSettle).
      expect(find.text('No candles yet'), findsNothing);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
