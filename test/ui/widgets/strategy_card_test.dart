/// Widget tests for the Welle O3-B3-2 StrategyCard.
library;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/ui/widgets/strategy_card.dart';

Future<void> _pump(
  WidgetTester tester, {
  required StrategyKind kind,
  required BacktestProvider provider,
  void Function(BuildContext, StrategyKind)? onApply,
}) async {
  await tester.binding.setSurfaceSize(const Size(800, 600));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StrategyCard(
          kind: kind,
          provider: provider,
          onApplyTrialRequested:
              onApply ?? (_, _) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('StrategyCard render', () {
    testWidgets('shows displayLabel + category + params', (tester) async {
      final p = BacktestProvider();
      await _pump(tester, kind: StrategyKind.bbRsi, provider: p);
      expect(find.text(StrategyKind.bbRsi.displayLabel), findsOneWidget);
      expect(find.text('Mean Reversion'), findsOneWidget);
      // 'BB' chip label is rendered as part of a RichText, so check the
      // value chip "200 · 0.20σ" sub-string of one of the chips.
      expect(find.textContaining('200'), findsWidgets);
    });

    testWidgets('active card shows Active badge, inactive does not',
        (tester) async {
      final p = BacktestProvider();
      // bbRsi is active by default
      await _pump(tester, kind: StrategyKind.bbRsi, provider: p);
      expect(find.text('Active'), findsOneWidget);

      await _pump(tester, kind: StrategyKind.utBot, provider: p);
      expect(find.text('Active'), findsNothing);
    });

    testWidgets('inactive card shows Activate button, active card hides it',
        (tester) async {
      final p = BacktestProvider();
      // utBot card is inactive (provider is on bbRsi by default).
      await _pump(tester, kind: StrategyKind.utBot, provider: p);
      expect(find.byKey(const Key('strategy_card_activate')), findsOneWidget);

      await _pump(tester, kind: StrategyKind.bbRsi, provider: p);
      expect(find.byKey(const Key('strategy_card_activate')), findsNothing);
    });

    testWidgets('Reset button only shows when params differ from defaults',
        (tester) async {
      final p = BacktestProvider();
      // Defaults → no reset.
      await _pump(tester, kind: StrategyKind.bbRsi, provider: p);
      expect(find.byKey(const Key('strategy_card_reset')), findsNothing);

      // Apply optimized → reset button surfaces.
      p.applyTrialAsParams(
        kind: StrategyKind.bbRsi,
        trialParams: const {'bb_period': 99.0},
      );
      await _pump(tester, kind: StrategyKind.bbRsi, provider: p);
      expect(find.byKey(const Key('strategy_card_reset')), findsOneWidget);
      expect(find.text('Optimized'), findsOneWidget);
    });
  });

  group('StrategyCard actions', () {
    testWidgets('Activate switches active strategy on provider',
        (tester) async {
      final p = BacktestProvider();
      await _pump(tester, kind: StrategyKind.utBot, provider: p);
      await tester.tap(find.byKey(const Key('strategy_card_activate')));
      expect(p.config.strategyKind, StrategyKind.utBot);
    });

    testWidgets('Apply Trial fires the requested callback with the kind',
        (tester) async {
      final p = BacktestProvider();
      StrategyKind? captured;
      await _pump(
        tester,
        kind: StrategyKind.ichimoku,
        provider: p,
        onApply: (_, k) => captured = k,
      );
      await tester.tap(find.byKey(const Key('strategy_card_apply_trial')));
      expect(captured, StrategyKind.ichimoku);
    });

    testWidgets('Reset returns active params to defaults', (tester) async {
      final p = BacktestProvider();
      p.applyTrialAsParams(
        kind: StrategyKind.bbRsi,
        trialParams: const {'bb_period': 99.0},
      );
      expect((p.config.strategyParams as BbRsiParams).bbPeriod, 99);
      await _pump(tester, kind: StrategyKind.bbRsi, provider: p);
      await tester.tap(find.byKey(const Key('strategy_card_reset')));
      expect((p.config.strategyParams as BbRsiParams).bbPeriod, 200);
      expect(p.usingOptimizedParams, isFalse);
    });
  });
}
