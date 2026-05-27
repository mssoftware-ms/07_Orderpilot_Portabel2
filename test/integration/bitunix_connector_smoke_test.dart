/// End-to-end smoke test for the Bitunix futures connector —
/// Welle P4P Step-5.
///
/// Walks the full happy-path UX without touching the network or the
/// platform secure-storage native plugin:
///
///   1. Pump MaterialApp(AccountScreen) backed by a mock HTTP layer
///      and an in-memory secrets backend.
///   2. The Live-Trading switch is disabled on the empty state.
///   3. Type an API key + secret, tap Save & Connect.
///   4. Provider transitions disconnected → connecting → connected.
///   5. Balance card + Positions card render with the mocked values.
///   6. Live-Trading switch is still disabled — even though the
///      provider is now in the most permissive state it ever reaches.
///   7. The credentials persisted to the in-memory backend can be
///      loaded back via a fresh `BitunixSecretsStore`.
///   8. Tap Clear stored — the screen falls back to the disconnected
///      state and the secrets backend is empty.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:trading_app/features/exchange/bitunix_connection_provider.dart';
import 'package:trading_app/services/bitunix_auth.dart';
import 'package:trading_app/services/bitunix_client.dart';
import 'package:trading_app/ui/screens/account_screen.dart';
import 'package:trading_app/ui/themes/app_theme.dart';

class _InMemoryBackend implements BitunixSecretsBackend {
  final Map<String, String> _store = {};
  Map<String, String> get snapshot => Map.unmodifiable(_store);

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

void main() {
  testWidgets('Bitunix connector E2E smoke', (tester) async {
    // ── Setup: mock HTTP + in-memory secrets backend ───────────────────
    final backend = _InMemoryBackend();
    final store = BitunixSecretsStore(backend: backend);

    final mock = MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v1/futures/account') {
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': [
              {
                'marginCoin': 'USDT',
                'available': '1000',
                'margin': '12.5',
                'crossUnrealizedPNL': '7.25',
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
                'qty': '0.05',
                'avgOpenPrice': '60000',
                'side': 'LONG',
                'leverage': 5,
                'unrealizedPNL': '7.25',
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

    final provider = BitunixConnectionProvider(
      secretsStore: store,
      clientFactory: (creds) => BitunixClient(
        credentials: creds,
        httpClient: mock,
        nonceProvider: () => 'smoke-nonce',
        timestampProvider: () => 1716800000000,
        maxRetries: 1,
        baseRetryDelay: const Duration(milliseconds: 1),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: ChangeNotifierProvider<BitunixConnectionProvider>.value(
          value: provider,
          child: const AccountScreen(),
        ),
      ),
    );
    await tester.pump();

    // ── 1. Empty state ──────────────────────────────────────────────────
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.byKey(const Key('account_balance_card')), findsNothing);
    expect(find.byKey(const Key('account_positions_card')), findsNothing);
    {
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNull,
          reason: 'live toggle must be disabled on empty state');
      expect(sw.value, isFalse);
    }

    // ── 2. Enter credentials + Save & Connect ───────────────────────────
    await tester.enterText(
        find.byKey(const Key('account_api_key_field')), 'smoke-key-001');
    await tester.enterText(
        find.byKey(const Key('account_secret_field')), 'smoke-secret-001');
    await tester.tap(find.byKey(const Key('account_save_connect_button')));
    await tester.pumpAndSettle();

    // ── 3. Connected, cards rendered ────────────────────────────────────
    expect(provider.status, BitunixConnectionStatus.connected);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byKey(const Key('account_balance_card')), findsOneWidget);
    expect(find.byKey(const Key('account_positions_card')), findsOneWidget);
    expect(find.text('BTCUSDT'), findsOneWidget);
    expect(find.text('LONG'), findsOneWidget);

    // ── 4. Live-Trading switch is STILL disabled ────────────────────────
    {
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.onChanged, isNull,
          reason: 'CRITICAL — live toggle must stay disabled even when '
              'fully connected to Bitunix.');
      expect(sw.value, isFalse);
      expect(provider.liveTradingEnabled, isFalse);
    }

    // ── 5. Tap-attack on the disabled switch must not flip it ────────────
    // Tapping a SwitchListTile whose onChanged is null is a no-op by
    // Material design; we tap anyway to prove the regression guard.
    await tester.tap(
      find.byKey(const Key('account_live_trading_switch')),
      warnIfMissed: false,
    );
    await tester.pump();
    {
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('account_live_trading_switch')));
      expect(sw.value, isFalse,
          reason: 'A tap on the disabled switch must not flip it on.');
    }

    // ── 6. Credentials really did land in the secrets backend ──────────
    final reloaded = await store.load();
    expect(reloaded,
        const BitunixCredentials(apiKey: 'smoke-key-001', secret: 'smoke-secret-001'));

    // ── 7. Clear stored — back to disconnected + empty backend ──────────
    await tester.tap(
        find.byKey(const Key('account_clear_credentials_button')));
    await tester.pumpAndSettle();

    expect(provider.status, BitunixConnectionStatus.disconnected);
    expect(provider.hasCredentials, isFalse);
    expect(find.byKey(const Key('account_balance_card')), findsNothing);
    expect(find.byKey(const Key('account_positions_card')), findsNothing);
    expect(backend.snapshot, isEmpty);
  });
}
