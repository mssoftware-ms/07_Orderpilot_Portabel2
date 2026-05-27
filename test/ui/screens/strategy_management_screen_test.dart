/// Widget tests for the Welle O3-B3-4 StrategyManagementScreen.
library;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:trading_app/core/navigation/app_navigation.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/ui/screens/strategy_management_screen.dart';

Future<void> _pump(
  WidgetTester tester, {
  required BacktestProvider backtest,
  required AppNavigation nav,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  await tester.pumpWidget(
    MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<BacktestProvider>.value(value: backtest),
          ChangeNotifierProvider<AppNavigation>.value(value: nav),
        ],
        child: const StrategyManagementScreen(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('StrategyManagementScreen layout', () {
    testWidgets('renders three strategy cards', (tester) async {
      final backtest = BacktestProvider();
      final nav = AppNavigation();
      await _pump(tester, backtest: backtest, nav: nav);
      expect(find.byKey(const Key('strategy_card_bbRsi')), findsOneWidget);
      expect(find.byKey(const Key('strategy_card_utBot')), findsOneWidget);
      expect(
          find.byKey(const Key('strategy_card_ichimoku')), findsOneWidget);
    });

    testWidgets('header subtitle is visible', (tester) async {
      final backtest = BacktestProvider();
      final nav = AppNavigation();
      await _pump(tester, backtest: backtest, nav: nav);
      expect(
          find.text('Apply optimization results to the active backtest.'),
          findsOneWidget);
    });

    testWidgets('footer shows active strategy + default params status',
        (tester) async {
      final backtest = BacktestProvider();
      final nav = AppNavigation();
      await _pump(tester, backtest: backtest, nav: nav);
      expect(
        find.textContaining('BB+RSI Mean Reversion (default params)'),
        findsOneWidget,
      );
    });

    testWidgets('footer flips to optimized status when trial applied',
        (tester) async {
      final backtest = BacktestProvider();
      final nav = AppNavigation();
      backtest.applyTrialAsParams(
        kind: StrategyKind.bbRsi,
        trialParams: const {'bb_period': 99.0},
      );
      await _pump(tester, backtest: backtest, nav: nav);
      expect(
        find.textContaining('BB+RSI Mean Reversion (optimized params)'),
        findsOneWidget,
      );
    });
  });

  group('StrategyManagementScreen navigation', () {
    testWidgets('Open Studies link switches to studies tab',
        (tester) async {
      final backtest = BacktestProvider();
      final nav = AppNavigation();
      await _pump(tester, backtest: backtest, nav: nav);
      await tester.tap(find.byKey(const Key('strategies_open_studies_link')));
      expect(nav.selectedTab, AppTab.studies);
    });

    testWidgets('Open Backtest footer link switches to backtest tab',
        (tester) async {
      final backtest = BacktestProvider();
      final nav = AppNavigation();
      await _pump(tester, backtest: backtest, nav: nav);
      await tester
          .tap(find.byKey(const Key('strategies_open_backtest_link')));
      expect(nav.selectedTab, AppTab.backtest);
    });
  });
}
