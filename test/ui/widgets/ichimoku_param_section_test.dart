/// Widget tests for the Welle O3-B1-3 IchimokuParamSection.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/ui/widgets/ichimoku_param_section.dart';

Future<void> _pump(WidgetTester tester, BacktestProvider provider) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: IchimokuParamSection(provider: provider),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the 8 Ichimoku knob labels with defaults',
      (tester) async {
    final provider = BacktestProvider();
    provider.setStrategyKind(StrategyKind.ichimoku);
    await _pump(tester, provider);

    expect(find.text('Tenkan'), findsOneWidget);
    expect(find.text('Kijun'), findsOneWidget);
    expect(find.text('Senkou B'), findsOneWidget);
    expect(find.text('Shift'), findsOneWidget);
    expect(find.text('Score Thr.'), findsOneWidget);
    expect(find.text('TP R:R'), findsOneWidget);
    expect(find.text('Risk/Trade'), findsOneWidget);
    expect(find.text('Swing Bars'), findsOneWidget);
  });

  testWidgets('dragging Tenkan slider updates IchimokuParams.tenkanPeriod',
      (tester) async {
    final provider = BacktestProvider();
    provider.setStrategyKind(StrategyKind.ichimoku);
    await _pump(tester, provider);

    final before =
        (provider.config.strategyParams as IchimokuParams).tenkanPeriod;
    expect(before, 9);

    final row = find.ancestor(
      of: find.text('Tenkan'),
      matching: find.byType(Row),
    );
    final slider = find.descendant(of: row, matching: find.byType(Slider));
    await tester.drag(slider, const Offset(60, 0));
    await tester.pumpAndSettle();

    final after =
        (provider.config.strategyParams as IchimokuParams).tenkanPeriod;
    expect(after, isNot(before),
        reason: 'Slider drag should have changed tenkanPeriod');
  });

  testWidgets('Senkou B slider enforces 20..120 range', (tester) async {
    final provider = BacktestProvider();
    provider.setStrategyKind(StrategyKind.ichimoku);
    await _pump(tester, provider);

    final row = find.ancestor(
      of: find.text('Senkou B'),
      matching: find.byType(Row),
    );
    final slider = tester.widget<Slider>(
      find.descendant(of: row, matching: find.byType(Slider)),
    );
    expect(slider.min, 20);
    expect(slider.max, 120);
  });
}
