/// Welle B4.3-4 — Account-screen Reset-Kill-Switch flow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/features/exchange/bitunix_connection_provider.dart';
import 'package:trading_app/features/paper/paper_trading_provider.dart';
import 'package:trading_app/features/risk/risk_config.dart';
import 'package:trading_app/features/risk/risk_manager.dart';
import 'package:trading_app/services/bitunix_auth.dart';
import 'package:trading_app/ui/screens/account_screen.dart';
import 'package:trading_app/ui/themes/app_theme.dart';

class _InMemorySecretsBackend implements BitunixSecretsBackend {
  final Map<String, String> _store = {};
  @override
  Future<void> write({required String key, required String value}) async {
    _store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => _store[key];
  @override
  Future<void> delete({required String key}) async {
    _store.remove(key);
  }
}

Future<RiskManager> _pump(
  WidgetTester tester, {
  required bool killSwitchActive,
}) async {
  final risk = RiskManager();
  await risk.saveConfig(RiskConfig(
    maxPositionRiskPct: 5,
    maxDailyLossPct: 3,
    maxDrawdownPct: 10,
    maxConsecutiveLosses: 5,
    killSwitchActive: killSwitchActive,
  ));
  final paper = PaperTradingProvider(riskManager: risk);
  addTearDown(paper.dispose);
  final bitunix = BitunixConnectionProvider(
    secretsStore: BitunixSecretsStore(backend: _InMemorySecretsBackend()),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.darkTheme,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<BitunixConnectionProvider>.value(value: bitunix),
          ChangeNotifierProvider<RiskManager>.value(value: risk),
          ChangeNotifierProvider<PaperTradingProvider>.value(value: paper),
        ],
        child: const AccountScreen(),
      ),
    ),
  );
  await tester.pump();
  return risk;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Reset-Kill-Switch button visibility', () {
    testWidgets('hidden when kill switch is inactive', (tester) async {
      await _pump(tester, killSwitchActive: false);
      expect(find.byKey(const Key('account_reset_kill_switch_button')),
          findsNothing);
    });

    testWidgets('visible when kill switch is active', (tester) async {
      await _pump(tester, killSwitchActive: true);
      expect(find.byKey(const Key('account_reset_kill_switch_button')),
          findsOneWidget);
    });
  });

  group('ConfirmDialog flow', () {
    testWidgets('Confirm resets the kill switch', (tester) async {
      final risk = await _pump(tester, killSwitchActive: true);
      expect(risk.killSwitchActive, isTrue);

      tester
          .widget<ElevatedButton>(
              find.byKey(const Key('account_reset_kill_switch_button')))
          .onPressed!();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account_reset_kill_switch_dialog')),
          findsOneWidget);
      await tester
          .tap(find.byKey(const Key('account_reset_kill_switch_confirm')));
      await tester.pumpAndSettle();

      expect(risk.killSwitchActive, isFalse);
      expect(find.byKey(const Key('account_reset_kill_switch_button')),
          findsNothing,
          reason: 'after reset, the button hides again');
    });

    testWidgets('Cancel leaves the kill switch active', (tester) async {
      final risk = await _pump(tester, killSwitchActive: true);

      tester
          .widget<ElevatedButton>(
              find.byKey(const Key('account_reset_kill_switch_button')))
          .onPressed!();
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(const Key('account_reset_kill_switch_cancel')));
      await tester.pumpAndSettle();

      expect(risk.killSwitchActive, isTrue);
      expect(find.byKey(const Key('account_reset_kill_switch_button')),
          findsOneWidget);
    });
  });
}
