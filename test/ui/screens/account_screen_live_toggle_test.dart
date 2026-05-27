/// Welle B4.4 — Live-trading toggle flow on the Account screen.
///
/// Pins the new contract that replaces the structural `onChanged: null`
/// from P4P Step-4:
///   * The switch is interactable iff all three [LiveModeEligibility]
///     conjuncts pass.
///   * Flipping ON pops a non-dismissible confirm dialog. Confirm →
///     [RiskManager.enableLiveTrading]. Cancel → no state change.
///   * Flipping OFF is the safety path — no dialog, immediate disable.
///   * A post-frame auto-disable hook clears the persisted bit the moment
///     any eligibility gate breaks (kill switch trip / exchange drop /
///     caps cleared).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/features/exchange/bitunix_connection_provider.dart';
import 'package:trading_app/features/paper/paper_trading_provider.dart';
import 'package:trading_app/features/risk/risk_config.dart';
import 'package:trading_app/features/risk/risk_manager.dart';
import 'package:trading_app/services/bitunix_auth.dart';
import 'package:trading_app/services/bitunix_client.dart';
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

MockClient _happyMock() => MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v1/futures/account') {
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': [
              {
                'marginCoin': 'USDT',
                'available': '500',
                'margin': '0',
                'crossUnrealizedPNL': '0',
                'isolationUnrealizedPNL': '0',
                'positionMode': 'HEDGE',
              }
            ],
            'msg': 'Success',
          }),
          200,
        );
      }
      if (path == '/api/v1/futures/position/get_pending_positions') {
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': const [],
            'msg': 'Success',
          }),
          200,
        );
      }
      if (path == '/api/v1/futures/trade/get_pending_orders') {
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'orderList': const [], 'total': 0},
            'msg': 'Success',
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

BitunixConnectionProvider _connectedProvider() => BitunixConnectionProvider(
      secretsStore: BitunixSecretsStore(backend: _InMemorySecretsBackend()),
      clientFactory: (creds) => BitunixClient(
        credentials: creds,
        httpClient: _happyMock(),
        nonceProvider: () => 'live-toggle-nonce',
        timestampProvider: () => 1716800000000,
        maxRetries: 1,
        baseRetryDelay: const Duration(milliseconds: 1),
      ),
    );

Future<({RiskManager risk, BitunixConnectionProvider exchange})> _pump(
  WidgetTester tester, {
  RiskConfig? initialConfig,
  bool autoConnect = true,
}) async {
  final risk = RiskManager();
  if (initialConfig != null) {
    await risk.saveConfig(initialConfig);
  } else {
    await risk.loadConfig();
  }
  final exchange = _connectedProvider();
  final paper = PaperTradingProvider(riskManager: risk);
  addTearDown(paper.dispose);

  // Bigger surface so every card on the Account screen is reachable in
  // a single frame — the Live-Trading card sits below the fold on the
  // default 800x600 test viewport.
  await tester.binding.setSurfaceSize(const Size(1000, 2400));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.darkTheme,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<BitunixConnectionProvider>.value(
              value: exchange),
          ChangeNotifierProvider<RiskManager>.value(value: risk),
          ChangeNotifierProvider<PaperTradingProvider>.value(value: paper),
        ],
        child: const AccountScreen(),
      ),
    ),
  );
  await tester.pump();

  if (autoConnect) {
    await tester.enterText(
        find.byKey(const Key('account_api_key_field')), 'k');
    await tester.enterText(
        find.byKey(const Key('account_secret_field')), 's');
    await tester.tap(find.byKey(const Key('account_save_connect_button')));
    await tester.pumpAndSettle();
  }
  return (risk: risk, exchange: exchange);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Switch enable-bar gating', () {
    testWidgets('disabled while the exchange is disconnected', (tester) async {
      final ctx = await _pump(tester, autoConnect: false);
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNull);
      expect(sw.value, isFalse);
      expect(ctx.risk.liveTradingEnabled, isFalse);
    });

    testWidgets('disabled while the kill switch is active', (tester) async {
      final ctx = await _pump(tester);
      await ctx.risk.activateKillSwitch(reason: 'audit');
      await tester.pump();
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNull,
          reason: 'kill switch trip fails the third eligibility conjunct');
    });

    testWidgets('enabled once all three gates pass', (tester) async {
      await _pump(tester);
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNotNull);
      expect(sw.value, isFalse,
          reason: 'eligible does not mean enabled — the user still has to '
              'walk through the confirm dialog');
    });
  });

  group('Confirm dialog — flip OFF → ON', () {
    testWidgets('tapping the switch pops a confirm dialog (not yet enabled)',
        (tester) async {
      final ctx = await _pump(tester);
      await tester.tap(find.byKey(const Key('account_live_trading_switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account_enable_live_trading_dialog')),
          findsOneWidget);
      expect(ctx.risk.liveTradingEnabled, isFalse,
          reason: 'opening the dialog must not pre-flip the persisted state');
    });

    testWidgets('confirm button flips persisted state to ON', (tester) async {
      final ctx = await _pump(tester);
      await tester.tap(find.byKey(const Key('account_live_trading_switch')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('account_enable_live_trading_confirm')));
      await tester.pumpAndSettle();
      expect(ctx.risk.liveTradingEnabled, isTrue);

      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.value, isTrue);
    });

    testWidgets('cancel button leaves the persisted state untouched',
        (tester) async {
      final ctx = await _pump(tester);
      await tester.tap(find.byKey(const Key('account_live_trading_switch')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('account_enable_live_trading_cancel')));
      await tester.pumpAndSettle();
      expect(ctx.risk.liveTradingEnabled, isFalse);
    });

    testWidgets('dialog is non-dismissible — tap-outside does not close it',
        (tester) async {
      // Sanity: the user MUST pick Cancel or Confirm explicitly, not just
      // tap somewhere else to escape — this is the safety-critical
      // barrierDismissible: false contract.
      await _pump(tester);
      await tester.tap(find.byKey(const Key('account_live_trading_switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account_enable_live_trading_dialog')),
          findsOneWidget);

      // Tap on a topleft outside-the-dialog spot.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account_enable_live_trading_dialog')),
          findsOneWidget,
          reason: 'tap-outside must not dismiss — only Cancel or Confirm '
              'closes the dialog');
    });

    testWidgets('confirm body spells out the real-money implication',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const Key('account_live_trading_switch')));
      await tester.pumpAndSettle();
      final dialog = find.byKey(const Key('account_enable_live_trading_dialog'));
      expect(dialog, findsOneWidget);
      // Three checklist points must be visible — these are the things the
      // user is signing off on.
      expect(find.textContaining('real-money'), findsOneWidget);
      expect(find.textContaining('kill switch'), findsOneWidget);
      expect(find.textContaining('Risk-Layer'), findsOneWidget);
    });
  });

  group('Flip ON → OFF (safety path, no dialog)', () {
    testWidgets('disable triggers immediately without a confirm dialog',
        (tester) async {
      // Pump first, connect, then enable live trading via the API — that
      // way the auto-disable hook (which runs the first time `build` sees
      // live=true but exchange=disconnected) cannot pre-empt the test.
      final ctx = await _pump(tester);
      await ctx.risk.enableLiveTrading();
      await tester.pumpAndSettle();
      expect(ctx.risk.liveTradingEnabled, isTrue);

      await tester.tap(find.byKey(const Key('account_live_trading_switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account_enable_live_trading_dialog')),
          findsNothing,
          reason: 'flipping OFF must skip the dialog — it is the safety path');
      expect(ctx.risk.liveTradingEnabled, isFalse);
    });
  });

  group('Auto-disable hook', () {
    testWidgets('kill-switch trip flips a previously enabled toggle off',
        (tester) async {
      final ctx = await _pump(tester);
      await ctx.risk.enableLiveTrading();
      await tester.pumpAndSettle();
      expect(ctx.risk.liveTradingEnabled, isTrue,
          reason: 'connected exchange + all caps positive → toggle stays ON');

      await ctx.risk.activateKillSwitch(reason: 'audit');
      // First pump processes the notifyListeners from activateKillSwitch,
      // second pump runs the post-frame auto-disable callback, third pump
      // processes the disableLiveTrading notify so the screen reflects it.
      await tester.pump();
      await tester.pump();
      expect(ctx.risk.liveTradingEnabled, isFalse,
          reason: 'auto-disable hook must catch the eligibility loss');
    });

    testWidgets('persisted state survives a full provider rehydrate',
        (tester) async {
      // First session: enable live trading via the confirm dialog.
      await _pump(tester);
      await tester.tap(find.byKey(const Key('account_live_trading_switch')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('account_enable_live_trading_confirm')));
      await tester.pumpAndSettle();

      // Sanity: shared_preferences mock now holds liveTradingEnabled = true.
      final freshRisk = RiskManager();
      await freshRisk.loadConfig();
      expect(freshRisk.liveTradingEnabled, isTrue,
          reason: 'the bit must persist so a restart can rearm — the in-app '
              'auto-disable then re-evaluates eligibility on first build');
    });
  });
}
