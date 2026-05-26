/// Widget tests for the Welle O3-B1-3 UtBotParamSection.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/ui/widgets/ut_bot_param_section.dart';

Future<void> _pump(WidgetTester tester, BacktestProvider provider) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: UtBotParamSection(provider: provider),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the 8 UT-Bot knob labels with defaults',
      (tester) async {
    final provider = BacktestProvider();
    provider.setStrategyKind(StrategyKind.utBot);
    await _pump(tester, provider);

    expect(find.text('Key Value'), findsOneWidget);
    expect(find.text('ATR Period'), findsOneWidget);
    expect(find.text('SMI Length'), findsOneWidget);
    expect(find.text('SMI K Smooth'), findsOneWidget);
    expect(find.text('SMI D Smooth'), findsOneWidget);
    expect(find.text('Swing Bars'), findsOneWidget);
    expect(find.text('TP R:R'), findsOneWidget);
    expect(find.text('Risk/Trade'), findsOneWidget);
  });

  testWidgets('dragging Key Value slider updates provider param',
      (tester) async {
    final provider = BacktestProvider();
    provider.setStrategyKind(StrategyKind.utBot);
    await _pump(tester, provider);

    // Before mutation: default keyValue is 2.0 (per UtBotParams spec)
    final before = (provider.config.strategyParams as UtBotParams).keyValue;
    expect(before, 2.0);

    // Find the slider labelled "Key Value" and drag it slightly right.
    final keyValueRow = find.ancestor(
      of: find.text('Key Value'),
      matching: find.byType(Row),
    );
    final keyValueSlider = find.descendant(
      of: keyValueRow.first,
      matching: find.byType(Slider),
    );
    await tester.drag(keyValueSlider, const Offset(50, 0));
    await tester.pumpAndSettle();

    final after = (provider.config.strategyParams as UtBotParams).keyValue;
    expect(after, isNot(before),
        reason: 'Slider drag should have changed keyValue');
  });

  testWidgets('out-of-range value: SMI K min=2 is clamped via Slider',
      (tester) async {
    final provider = BacktestProvider();
    provider.setStrategyKind(StrategyKind.utBot);
    await _pump(tester, provider);

    // Default smiKSmoothing = 5, slider divisions enforce min=2.
    final smiKRow = find.ancestor(
      of: find.text('SMI K Smooth'),
      matching: find.byType(Row),
    );
    final slider = tester.widget<Slider>(
      find.descendant(of: smiKRow, matching: find.byType(Slider)),
    );
    expect(slider.min, 2);
    expect(slider.max, 15);
  });
}
