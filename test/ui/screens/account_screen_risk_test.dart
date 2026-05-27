/// Welle B4.3-3 — Risk-Limits UI on the account screen.
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

BitunixConnectionProvider _bitunixProvider() => BitunixConnectionProvider(
      secretsStore: BitunixSecretsStore(backend: _InMemorySecretsBackend()),
    );

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
          ChangeNotifierProvider<BitunixConnectionProvider>.value(
              value: _bitunixProvider()),
          ChangeNotifierProvider<RiskManager>.value(value: risk),
          ChangeNotifierProvider<PaperTradingProvider>.value(value: paper),
        ],
        child: const AccountScreen(),
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

  group('Risk-Limits card renders defaults', () {
    testWidgets('shows the four sliders and a disabled Save button',
        (tester) async {
      await _pump(tester);
      expect(find.byKey(const Key('account_risk_limits_card')), findsOneWidget);
      expect(find.byKey(const Key('risk_slider_max_position')), findsOneWidget);
      expect(find.byKey(const Key('risk_slider_daily_loss')), findsOneWidget);
      expect(find.byKey(const Key('risk_slider_drawdown')), findsOneWidget);
      expect(find.byKey(const Key('risk_slider_consec_losses')),
          findsOneWidget);

      final saveBtn = tester.widget<ElevatedButton>(
          find.byKey(const Key('account_save_risk_limits_button')));
      expect(saveBtn.onPressed, isNull,
          reason: 'Save is disabled until the user drags any slider');
    });

    testWidgets('default config shows 5.0 / 3.0 / 10 / 5', (tester) async {
      await _pump(tester);
      expect(find.text('5.0 %'), findsOneWidget);
      expect(find.text('3.0 %'), findsOneWidget);
      expect(find.text('10 %'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
    });
  });

  group('Slider drag → pending state', () {
    // Trigger the slider's onChanged callback directly via the widget API.
    // The Account-Screen is a long scrollable column — a literal drag would
    // need the Risk-Limits card scrolled into view first, and the gesture
    // pixel arithmetic is fragile against future card-ordering changes.
    void pushSlider(WidgetTester tester, Key key, double newValue) {
      final slider = tester.widget<Slider>(find.byKey(key));
      slider.onChanged!(newValue);
    }

    testWidgets('moving the position-risk slider enables Save', (tester) async {
      final created = await _pump(tester);
      pushSlider(tester, const Key('risk_slider_max_position'), 2.5);
      await tester.pump();
      final saveBtn = tester.widget<ElevatedButton>(
          find.byKey(const Key('account_save_risk_limits_button')));
      expect(saveBtn.onPressed, isNotNull,
          reason: 'after a slider change Save must be enabled');
      expect(find.byKey(const Key('account_discard_risk_limits_button')),
          findsOneWidget);

      // Persisted config is unchanged until Save fires.
      expect(created.risk.config, RiskConfig.defaults());
    });

    testWidgets('Save persists the dragged values', (tester) async {
      final created = await _pump(tester);
      pushSlider(tester, const Key('risk_slider_drawdown'), 20);
      await tester.pump();
      // The card sits below the 600-pixel default test viewport — call the
      // button's onPressed directly to avoid scroll-into-view choreography.
      tester
          .widget<ElevatedButton>(
              find.byKey(const Key('account_save_risk_limits_button')))
          .onPressed!();
      await tester.pumpAndSettle();

      expect(created.risk.config.maxDrawdownPct, 20.0);

      // Save button disabled again after a successful save.
      final saveBtn = tester.widget<ElevatedButton>(
          find.byKey(const Key('account_save_risk_limits_button')));
      expect(saveBtn.onPressed, isNull);
    });

    testWidgets('Discard reverts the pending state', (tester) async {
      final created = await _pump(tester);
      pushSlider(tester, const Key('risk_slider_daily_loss'), 7);
      await tester.pump();
      tester
          .widget<TextButton>(
              find.byKey(const Key('account_discard_risk_limits_button')))
          .onPressed!();
      await tester.pump();

      expect(find.byKey(const Key('account_discard_risk_limits_button')),
          findsNothing);
      expect(created.risk.config, RiskConfig.defaults());
    });

    testWidgets('setting the slider back to the persisted value clears pending',
        (tester) async {
      await _pump(tester);
      pushSlider(tester, const Key('risk_slider_max_position'), 2.5);
      await tester.pump();
      pushSlider(tester, const Key('risk_slider_max_position'), 5.0);
      await tester.pump();
      final saveBtn = tester.widget<ElevatedButton>(
          find.byKey(const Key('account_save_risk_limits_button')));
      expect(saveBtn.onPressed, isNull,
          reason: 'reverting to the saved value clears pending');
    });
  });

  group('Risk-Status card', () {
    testWidgets('renders the four mini-cards', (tester) async {
      await _pump(tester);
      expect(find.byKey(const Key('risk_status_daily_pnl')), findsOneWidget);
      expect(find.byKey(const Key('risk_status_drawdown')), findsOneWidget);
      expect(find.byKey(const Key('risk_status_consec_losses')),
          findsOneWidget);
      expect(find.byKey(const Key('risk_status_kill_switch')), findsOneWidget);
    });

    testWidgets('kill-switch active shows ACTIVE in the mini-card',
        (tester) async {
      await _pump(tester,
          initialConfig: const RiskConfig(
            maxPositionRiskPct: 5,
            maxDailyLossPct: 3,
            maxDrawdownPct: 10,
            maxConsecutiveLosses: 5,
            killSwitchActive: true,
          ));
      expect(find.text('ACTIVE'), findsOneWidget);
    });

    testWidgets('no active session falls back to neutral values',
        (tester) async {
      await _pump(tester);
      // PaperTradingProvider is idle → assessment.currentDailyPnlPct == 0.
      expect(find.text('0.00 %'), findsWidgets);
      expect(find.text('0'), findsWidgets);
      expect(find.text('inactive'), findsOneWidget);
    });
  });

  group('Live-Trading toggle still gated when the exchange is disconnected',
      () {
    testWidgets(
        'switch keeps onChanged: null while exchange eligibility is missing',
        (tester) async {
      // The `_pump` helper installs a fresh provider that has never gone
      // through `connect()`, so `eligibility.exchangeConnected` stays false
      // and the switch must remain non-interactable even though the risk
      // limits are configured and the kill switch is inactive.
      await _pump(tester);
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNull,
          reason: 'Exchange gate not yet satisfied — switch must stay '
              'structurally locked.');
      expect(sw.value, isFalse);
    });

    testWidgets(
        'persisted live=true with the exchange disconnected → auto-disables',
        (tester) async {
      // The disconnected exchange already fails the eligibility check,
      // so the auto-disable hook in `build()` must fire even before any
      // kill-switch trip. This is the "reload after a crash while live
      // was on but the exchange is still warming up" recovery scenario.
      final created = await _pump(tester,
          initialConfig: const RiskConfig(
            maxPositionRiskPct: 5,
            maxDailyLossPct: 3,
            maxDrawdownPct: 10,
            maxConsecutiveLosses: 5,
            killSwitchActive: false,
            liveTradingEnabled: true,
          ));
      // First pump runs `build`; the post-frame callback schedules the
      // disable. Second pump processes the resulting notifyListeners.
      await tester.pump();
      await tester.pump();
      expect(created.risk.liveTradingEnabled, isFalse,
          reason: 'reloading with live=true but exchange disconnected must '
              'auto-clear the flag rather than re-arm an unsafe state');
    });
  });
}
