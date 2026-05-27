/// Welle B4.3-4 — Paper-screen Kill-Switch button + confirm-dialog.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/features/paper/paper_trading_provider.dart';
import 'package:trading_app/features/risk/risk_config.dart';
import 'package:trading_app/features/risk/risk_manager.dart';
import 'package:trading_app/ui/screens/paper_trading_screen.dart';
import 'package:trading_app/ui/themes/app_theme.dart';

Future<({RiskManager risk, PaperTradingProvider paper})> _pump(
  WidgetTester tester, {
  RiskConfig? initialConfig,
}) async {
  final risk = RiskManager();
  if (initialConfig != null) {
    await risk.saveConfig(initialConfig);
  } else {
    await risk.loadConfig();
  }
  final paper = PaperTradingProvider(riskManager: risk);
  addTearDown(paper.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.darkTheme,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<BacktestProvider>(
              create: (_) => BacktestProvider()),
          ChangeNotifierProvider<RiskManager>.value(value: risk),
          ChangeNotifierProvider<PaperTradingProvider>.value(value: paper),
        ],
        child: const PaperTradingScreen(),
      ),
    ),
  );
  await tester.pump();
  return (risk: risk, paper: paper);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Kill-Switch button visibility', () {
    testWidgets('button is visible in idle state', (tester) async {
      await _pump(tester);
      expect(find.byKey(const Key('paper-kill-switch-button')), findsOneWidget);
    });

    testWidgets('button is REPLACED by an ACTIVE pill once tripped',
        (tester) async {
      await _pump(tester,
          initialConfig: const RiskConfig(
            maxPositionRiskPct: 5,
            maxDailyLossPct: 3,
            maxDrawdownPct: 10,
            maxConsecutiveLosses: 5,
            killSwitchActive: true,
          ));
      expect(find.byKey(const Key('paper-kill-switch-button')), findsNothing);
      expect(find.byKey(const Key('paper-kill-switch-active-pill')),
          findsOneWidget);
      expect(find.text('KILL SWITCH ACTIVE'), findsOneWidget);
    });
  });

  group('ConfirmDialog flow', () {
    testWidgets('tap opens the confirm dialog', (tester) async {
      await _pump(tester);
      tester
          .widget<ElevatedButton>(
              find.byKey(const Key('paper-kill-switch-button')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paper-kill-switch-confirm-dialog')),
          findsOneWidget);
      expect(find.text('Activate Kill Switch?'), findsOneWidget);
    });

    testWidgets('Confirm activates kill-switch + stops the session',
        (tester) async {
      final created = await _pump(tester);
      tester
          .widget<ElevatedButton>(
              find.byKey(const Key('paper-kill-switch-button')))
          .onPressed!();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('paper-kill-switch-confirm')));
      await tester.pumpAndSettle();

      expect(created.risk.killSwitchActive, isTrue);
      // Idle session stays idle (stop is idempotent), but the post-confirm
      // UI must show the ACTIVE pill.
      expect(find.byKey(const Key('paper-kill-switch-active-pill')),
          findsOneWidget);
    });

    testWidgets('Cancel leaves kill-switch inactive', (tester) async {
      final created = await _pump(tester);
      tester
          .widget<ElevatedButton>(
              find.byKey(const Key('paper-kill-switch-button')))
          .onPressed!();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('paper-kill-switch-cancel')));
      await tester.pumpAndSettle();

      expect(created.risk.killSwitchActive, isFalse);
      expect(find.byKey(const Key('paper-kill-switch-button')), findsOneWidget);
    });
  });
}
