/// Widget tests for the Account screen — Welle P4P Step-4.
///
/// The Live-Trading toggle MUST stay disabled in every state of the
/// provider. A regression test exercises both `disconnected` and a
/// successfully `connected` provider; if either path ever lights the
/// switch up, the test fails — which is what we want before Welle B4
/// Step-3 lands the risk layer.
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
import 'package:trading_app/features/risk/risk_manager.dart';
import 'package:trading_app/services/bitunix_auth.dart';
import 'package:trading_app/services/bitunix_client.dart';
import 'package:trading_app/ui/screens/account_screen.dart';
import 'package:trading_app/ui/themes/app_theme.dart';

class _InMemoryBackend implements BitunixSecretsBackend {
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
                'available': '500.25',
                'margin': '12.5',
                'crossUnrealizedPNL': '3.5',
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
            'data': [
              {
                'positionId': '1',
                'symbol': 'BTCUSDT',
                'qty': '0.1',
                'avgOpenPrice': '60000',
                'side': 'LONG',
                'leverage': 10,
                'unrealizedPNL': '5.0',
              }
            ],
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

BitunixConnectionProvider _buildProvider({
  required MockClient mock,
  BitunixSecretsBackend? backend,
}) {
  final store = BitunixSecretsStore(backend: backend ?? _InMemoryBackend());
  return BitunixConnectionProvider(
    secretsStore: store,
    clientFactory: (creds) => BitunixClient(
      credentials: creds,
      httpClient: mock,
      nonceProvider: () => 'fixed',
      timestampProvider: () => 1716800000000,
      maxRetries: 1,
      baseRetryDelay: const Duration(milliseconds: 1),
    ),
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  BitunixConnectionProvider provider, {
  RiskManager? risk,
  PaperTradingProvider? paper,
}) async {
  // Welle B4.3-3: AccountScreen now reads RiskManager + PaperTradingProvider
  // from the surrounding MultiProvider. SharedPreferences is primed by the
  // setUp hook so the RiskManager's loadConfig hits an in-memory mock store.
  final riskMgr = risk ?? RiskManager();
  await riskMgr.loadConfig();
  final paperMgr = paper ?? PaperTradingProvider(riskManager: riskMgr);
  addTearDown(paperMgr.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.darkTheme,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<BitunixConnectionProvider>.value(
              value: provider),
          ChangeNotifierProvider<RiskManager>.value(value: riskMgr),
          ChangeNotifierProvider<PaperTradingProvider>.value(value: paperMgr),
        ],
        child: const AccountScreen(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('initial / disconnected state', () {
    testWidgets('shows credentials card, no balance / positions cards yet',
        (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      expect(find.byKey(const Key('account_api_key_field')), findsOneWidget);
      expect(find.byKey(const Key('account_secret_field')), findsOneWidget);
      expect(find.byKey(const Key('account_save_connect_button')),
          findsOneWidget);
      expect(find.byKey(const Key('account_balance_card')), findsNothing);
      expect(find.byKey(const Key('account_positions_card')), findsNothing);
      expect(find.text('Disconnected'), findsOneWidget);
    });

    testWidgets('Clear button is disabled when no credentials are stored',
        (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      final clearBtn = tester.widget<OutlinedButton>(find.byKey(
          const Key('account_clear_credentials_button')));
      expect(clearBtn.onPressed, isNull);
    });

    testWidgets('Test Connection button is disabled with no credentials',
        (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      final btn = tester.widget<OutlinedButton>(
          find.byKey(const Key('account_test_connection_button')));
      expect(btn.onPressed, isNull);
    });
  });

  group('save & connect flow', () {
    testWidgets('entering credentials and tapping Save & Connect populates '
        'balance + positions cards', (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      await tester.enterText(
          find.byKey(const Key('account_api_key_field')), 'live-key-abc');
      await tester.enterText(
          find.byKey(const Key('account_secret_field')), 'live-secret-xyz');
      await tester.tap(find.byKey(const Key('account_save_connect_button')));
      await tester.pumpAndSettle();

      expect(find.text('Connected'), findsOneWidget);
      expect(find.byKey(const Key('account_balance_card')), findsOneWidget);
      expect(find.byKey(const Key('account_positions_card')), findsOneWidget);
      expect(find.text('BTCUSDT'), findsOneWidget);
      expect(find.text('LONG'), findsOneWidget);
    });

    testWidgets('Save & Connect with empty fields does nothing', (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      await tester.tap(find.byKey(const Key('account_save_connect_button')));
      await tester.pumpAndSettle();

      expect(p.status, BitunixConnectionStatus.disconnected);
    });
  });

  group('error path', () {
    testWidgets('401 from backend surfaces the error banner', (tester) async {
      final mock = MockClient((_) async =>
          http.Response('{"code":401,"msg":"bad signature"}', 401));
      final p = _buildProvider(mock: mock);
      await _pumpScreen(tester, p);

      await tester.enterText(
          find.byKey(const Key('account_api_key_field')), 'k');
      await tester.enterText(
          find.byKey(const Key('account_secret_field')), 's');
      await tester.tap(find.byKey(const Key('account_save_connect_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account_error_banner')), findsOneWidget);
      expect(find.text('Error'), findsOneWidget);
    });
  });

  group('Live-Trading toggle — regression guard', () {
    testWidgets('switch is disabled while disconnected', (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNull,
          reason: 'Live toggle must be disabled — no risk layer yet.');
      expect(sw.value, isFalse);
    });

    testWidgets(
        'CRITICAL: switch stays disabled even when successfully connected',
        (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      await tester.enterText(
          find.byKey(const Key('account_api_key_field')), 'k');
      await tester.enterText(
          find.byKey(const Key('account_secret_field')), 's');
      await tester.tap(find.byKey(const Key('account_save_connect_button')));
      await tester.pumpAndSettle();

      // Sanity: provider really did connect — otherwise the test
      // wouldn't be exercising the dangerous state.
      expect(p.status, BitunixConnectionStatus.connected);

      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNull,
          reason: 'Even a fully connected provider must keep live trading '
              'locked off until Welle B4 Step-3 ships.');
      expect(sw.value, isFalse);
    });

    testWidgets('Step-3 pending pill is visible', (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);
      expect(find.byKey(const Key('account_step3_pending_pill')),
          findsOneWidget);
      expect(find.text('Step-3 pending'), findsOneWidget);
    });

    testWidgets('Tooltip carries the Step-3 risk-layer hint', (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      final tooltip = tester.widget<Tooltip>(
          find.byKey(const Key('account_live_trading_tooltip')));
      expect(tooltip.message, contains('Welle B4 Step-3'));
      expect(tooltip.message, contains('kill-switch'));
      expect(tooltip.message, contains('Currently disabled'));
    });
  });

  group('balance + positions rendering', () {
    testWidgets('balance card shows Available + Unrealized PnL after connect',
        (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      await tester.enterText(
          find.byKey(const Key('account_api_key_field')), 'k');
      await tester.enterText(
          find.byKey(const Key('account_secret_field')), 's');
      await tester.tap(find.byKey(const Key('account_save_connect_button')));
      await tester.pumpAndSettle();

      // Available 500.25 → shows fractionDigits=2 → "500.25"
      expect(find.text('500.25'), findsOneWidget);
      // Unrealized PnL (total) = 3.5 → "3.5000" (fractionDigits=4)
      expect(find.text('3.5000'), findsOneWidget);
    });

    testWidgets('positions card lists the open position symbol + side',
        (tester) async {
      final p = _buildProvider(mock: _happyMock());
      await _pumpScreen(tester, p);

      await tester.enterText(
          find.byKey(const Key('account_api_key_field')), 'k');
      await tester.enterText(
          find.byKey(const Key('account_secret_field')), 's');
      await tester.tap(find.byKey(const Key('account_save_connect_button')));
      await tester.pumpAndSettle();

      expect(find.text('Open Positions (1)'), findsOneWidget);
      expect(find.text('BTCUSDT'), findsOneWidget);
      expect(find.text('LONG'), findsOneWidget);
    });
  });
}
