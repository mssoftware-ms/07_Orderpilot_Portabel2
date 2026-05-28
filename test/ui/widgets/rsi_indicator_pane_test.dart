/// Welle P4C-4 — RsiIndicatorPane widget tests.
///
/// Focused on the surface behaviours that downstream code relies on:
/// renders an `fl_chart` LineChart for a non-empty series, falls back
/// to a placeholder when warming up or when nothing has been computed.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trading_app/ui/widgets/rsi_indicator_pane.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SizedBox(width: 400, height: 200, child: child)));

void main() {
  testWidgets('null values render the idle placeholder', (tester) async {
    await tester.pumpWidget(_host(const RsiIndicatorPane(values: null)));
    await tester.pump();

    expect(find.text('RSI Indicator (0–100)'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
  });

  testWidgets('empty values render the idle placeholder', (tester) async {
    await tester.pumpWidget(_host(const RsiIndicatorPane(values: [])));
    await tester.pump();

    expect(find.text('RSI Indicator (0–100)'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
  });

  testWidgets('only warm-up sentinels render the warming-up placeholder',
      (tester) async {
    // All values still at the 50.0 warm-up init from `calcRsi`.
    await tester.pumpWidget(
      _host(RsiIndicatorPane(values: List<double>.filled(10, 50.0))),
    );
    await tester.pump();

    expect(find.text('RSI warming up…'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
  });

  testWidgets('non-empty values render an fl_chart LineChart',
      (tester) async {
    // 5 warm-up bars at 50.0 followed by 5 real RSI samples.
    final rsi = <double>[
      50, 50, 50, 50, 50,
      45.5, 62.3, 71.8, 28.2, 55.0,
    ];
    await tester.pumpWidget(_host(RsiIndicatorPane(values: rsi)));
    await tester.pump();

    expect(find.byType(LineChart), findsOneWidget);
    expect(find.text('RSI Indicator (0–100)'), findsNothing);
  });
}
