/// Welle B4.3-5 — Full-stack risk-layer smoke.
///
/// Walks the user-visible sequence the QA brief specifies:
///   1. Fresh app start → RiskManager loads defaults, exchange is
///      disconnected, kill-switch inactive. Eligibility flag is false
///      because the exchange isn't connected yet.
///   2. User connects to Bitunix (mocked HTTP). Exchange flips to
///      connected → eligibility's `exchangeConnected` is now true and the
///      aggregate `isEligible` flips to true.
///   3. **Live-Toggle stays disabled.** Even with all three checkmarks
///      green, the SwitchListTile's `onChanged` is `null` — the actual
///      enable is a follow-up wave.
///   4. User activates the kill-switch. Eligibility's `killSwitchInactive`
///      flips to false. `isEligible` returns to false.
///   5. User resets the kill-switch. Eligibility is back to all-green.
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
import 'package:trading_app/features/risk/live_mode_eligibility.dart';
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
                'available': '250',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Risk layer end-to-end: eligibility tracks live state',
      (tester) async {
    // ── Setup providers ────────────────────────────────────────────────
    final risk = RiskManager();
    await risk.loadConfig();
    final paper = PaperTradingProvider(riskManager: risk);
    addTearDown(paper.dispose);
    final bitunix = BitunixConnectionProvider(
      secretsStore: BitunixSecretsStore(backend: _InMemorySecretsBackend()),
      clientFactory: (creds) => BitunixClient(
        credentials: creds,
        httpClient: _happyMock(),
        nonceProvider: () => 'smoke-nonce',
        timestampProvider: () => 1716800000000,
        maxRetries: 1,
        baseRetryDelay: const Duration(milliseconds: 1),
      ),
    );

    // Surface size big enough for the full Account screen to fit so all
    // eligibility / live-trading widgets are reachable in one frame.
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<BitunixConnectionProvider>.value(
                value: bitunix),
            ChangeNotifierProvider<RiskManager>.value(value: risk),
            ChangeNotifierProvider<PaperTradingProvider>.value(value: paper),
          ],
          child: const AccountScreen(),
        ),
      ),
    );
    await tester.pump();

    // ── 1. Fresh start ─────────────────────────────────────────────────
    {
      final eligibility = LiveModeEligibility.evaluate(
          riskManager: risk, exchangeProvider: bitunix);
      expect(eligibility.allRiskGatesActive, isTrue,
          reason: 'defaults satisfy all caps > 0');
      expect(eligibility.exchangeConnected, isFalse);
      expect(eligibility.killSwitchInactive, isTrue);
      expect(eligibility.isEligible, isFalse,
          reason: 'exchange not connected yet');
    }
    expect(find.byKey(const Key('account_live_mode_eligibility')),
        findsOneWidget);
    expect(find.byKey(const Key('eligibility_exchange')), findsOneWidget);

    // ── 2. Connect to Bitunix ──────────────────────────────────────────
    await tester.enterText(
        find.byKey(const Key('account_api_key_field')), 'smoke-key');
    await tester.enterText(
        find.byKey(const Key('account_secret_field')), 'smoke-secret');
    await tester.tap(find.byKey(const Key('account_save_connect_button')));
    await tester.pumpAndSettle();

    expect(bitunix.status, BitunixConnectionStatus.connected);
    {
      final eligibility = LiveModeEligibility.evaluate(
          riskManager: risk, exchangeProvider: bitunix);
      expect(eligibility.exchangeConnected, isTrue);
      expect(eligibility.isEligible, isTrue,
          reason: 'all three gates now pass');
    }

    // ── 3. Live-Toggle is now enable-bar — but persisted OFF ──────────
    // Welle B4.4 opened the UI path: with every conjunct green the
    // switch's `onChanged` is no longer null. Flipping it ON still
    // requires the user to walk through a confirm dialog; merely
    // becoming eligible does NOT auto-enable.
    {
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNotNull,
          reason: 'all three eligibility gates pass — switch is now '
              'interactable behind the confirm dialog.');
      expect(sw.value, isFalse,
          reason: 'no confirm has happened — persisted state is still OFF');
      expect(risk.liveTradingEnabled, isFalse);
    }

    // ── 4. User opts in: enable live trading explicitly ─────────────────
    await risk.enableLiveTrading();
    await tester.pump();
    {
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.value, isTrue,
          reason: 'after enableLiveTrading the switch must reflect ON');
      expect(risk.liveTradingEnabled, isTrue);
    }

    // ── 5. Activate kill-switch → auto-disable kicks in ────────────────
    await risk.activateKillSwitch(reason: 'smoke-test');
    await tester.pump();
    // Second pump so the post-frame auto-disable callback runs and the
    // resulting notifyListeners rebuilds the screen.
    await tester.pump();
    {
      final eligibility = LiveModeEligibility.evaluate(
          riskManager: risk, exchangeProvider: bitunix);
      expect(eligibility.killSwitchInactive, isFalse);
      expect(eligibility.isEligible, isFalse);
      expect(risk.liveTradingEnabled, isFalse,
          reason: 'auto-disable hook must clear the live flag the moment '
              'an eligibility gate breaks — even if the user just enabled');

      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNull,
          reason: 'kill switch tripped → switch is locked again');
      expect(sw.value, isFalse);
    }

    // ── 6. Reset kill-switch → switch becomes enable-bar again ─────────
    await risk.resetKillSwitch();
    await tester.pump();
    {
      final eligibility = LiveModeEligibility.evaluate(
          riskManager: risk, exchangeProvider: bitunix);
      expect(eligibility.killSwitchInactive, isTrue);
      expect(eligibility.isEligible, isTrue,
          reason: 'reset clears the third gate again');

      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNotNull,
          reason: 'all gates green again — switch is interactable but the '
              'persisted state stays OFF, the user has to re-confirm to flip ON');
      expect(sw.value, isFalse,
          reason: 'auto-disable cleared the flag; re-enable requires the '
              'confirm dialog again');
    }
  });

  group('LiveModeEligibility unit semantics', () {
    test('isEligible is the AND of the three conjuncts', () {
      const allTrue = LiveModeEligibility(
        allRiskGatesActive: true,
        exchangeConnected: true,
        killSwitchInactive: true,
      );
      expect(allTrue.isEligible, isTrue);

      const oneFalse = LiveModeEligibility(
        allRiskGatesActive: true,
        exchangeConnected: false,
        killSwitchInactive: true,
      );
      expect(oneFalse.isEligible, isFalse);
    });

    test('equality compares all three conjuncts', () {
      const a = LiveModeEligibility(
        allRiskGatesActive: true,
        exchangeConnected: false,
        killSwitchInactive: true,
      );
      const b = LiveModeEligibility(
        allRiskGatesActive: true,
        exchangeConnected: false,
        killSwitchInactive: true,
      );
      const c = LiveModeEligibility(
        allRiskGatesActive: false,
        exchangeConnected: false,
        killSwitchInactive: true,
      );
      expect(a, b);
      expect(a, isNot(c));
      expect(a.hashCode, b.hashCode);
    });
  });
}
