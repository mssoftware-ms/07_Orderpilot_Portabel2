/// Unit tests for [BitunixConnectionProvider] — Welle P4P Step-3.
///
/// Each test injects a fresh `MockClient` and an in-memory secrets backend,
/// so the suite never touches secure storage or the network. The provider
/// is exercised end-to-end through its public API: load → connect → refresh
/// → disconnect → clearStoredCredentials. Status transitions and the
/// per-status fields (balance, positions, orders, lastSyncAt, errorMessage)
/// are asserted directly.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:trading_app/features/exchange/bitunix_connection_provider.dart';
import 'package:trading_app/services/bitunix_auth.dart';
import 'package:trading_app/services/bitunix_client.dart';

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

/// Build a [MockClient] that returns canned responses for the three
/// read-only endpoints. Any [Exception]-valued slot raises instead of
/// returning a body so the provider's auth/error branches can be tested.
MockClient _mockEndpoints({
  Object? balance,
  Object? positions,
  Object? orders,
}) {
  return MockClient((request) async {
    final path = request.url.path;
    Object? slot;
    if (path == '/api/v1/futures/account') {
      slot = balance;
    } else if (path == '/api/v1/futures/position/get_pending_positions') {
      slot = positions;
    } else if (path == '/api/v1/futures/trade/get_pending_orders') {
      slot = orders;
    } else {
      return http.Response('not found', 404);
    }
    if (slot is http.Response) return slot;
    if (slot is Map || slot is List) {
      return http.Response(jsonEncode(slot), 200);
    }
    // No canned response set → return a schema-correct empty success for
    // the matched endpoint so the client never logs a schema-drift warning
    // on tests that exercise paths that don't care about the data.
    if (path == '/api/v1/futures/trade/get_pending_orders') {
      return http.Response(
          '{"code":0,"data":{"orderList":[],"total":0},"msg":""}', 200);
    }
    return http.Response('{"code":0,"data":[],"msg":""}', 200);
  });
}

BitunixConnectionProvider _provider({
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

const _creds = BitunixCredentials(apiKey: 'k', secret: 's');

void main() {
  group('initial state', () {
    test('starts in disconnected with no data', () {
      final p = _provider(mock: _mockEndpoints());
      expect(p.status, BitunixConnectionStatus.disconnected);
      expect(p.balance, isNull);
      expect(p.positions, isEmpty);
      expect(p.orders, isEmpty);
      expect(p.lastSyncAt, isNull);
      expect(p.errorMessage, isNull);
      expect(p.hasCredentials, isFalse);
      expect(p.liveTradingEnabled, isFalse);
    });
  });

  group('loadStoredCredentials', () {
    test('hydrates _credentials when secure storage has a pair', () async {
      final backend = _InMemoryBackend();
      await backend.write(key: 'bitunix.secret', value: 'persisted-secret');
      await backend.write(key: 'bitunix.apiKey', value: 'persisted-key');

      final p = _provider(mock: _mockEndpoints(), backend: backend);
      await p.loadStoredCredentials();

      expect(p.hasCredentials, isTrue);
      // Status stays disconnected — no auto-connect.
      expect(p.status, BitunixConnectionStatus.disconnected);
    });

    test('does nothing when secure storage is empty', () async {
      final p = _provider(mock: _mockEndpoints());
      await p.loadStoredCredentials();
      expect(p.hasCredentials, isFalse);
      expect(p.status, BitunixConnectionStatus.disconnected);
    });
  });

  group('connect — happy path', () {
    test('transitions to connected and populates balance/positions/orders',
        () async {
      final mock = _mockEndpoints(
        balance: {
          'code': 0,
          'data': [
            {
              'marginCoin': 'USDT',
              'available': '1234.5',
              'crossUnrealizedPNL': '2',
              'isolationUnrealizedPNL': '0',
            }
          ],
          'msg': 'Success',
        },
        positions: {
          'code': 0,
          'data': [
            {
              'positionId': '1',
              'symbol': 'BTCUSDT',
              'qty': '0.1',
              'side': 'LONG',
              'leverage': 10,
            }
          ],
          'msg': 'Success',
        },
        orders: {
          'code': 0,
          'data': {
            'orderList': [
              {
                'orderId': 'o1',
                'symbol': 'BTCUSDT',
                'qty': '0.05',
                'price': '60000',
                'side': 'BUY',
                'orderType': 'LIMIT',
                'status': 'NEW',
              }
            ],
            'total': 1,
          },
          'msg': 'Success',
        },
      );

      final p = _provider(mock: mock);
      await p.connect(_creds);

      expect(p.status, BitunixConnectionStatus.connected);
      expect(p.balance?.available, 1234.5);
      expect(p.balance?.totalUnrealizedPNL, 2);
      expect(p.positions, hasLength(1));
      expect(p.positions.first.symbol, 'BTCUSDT');
      expect(p.orders, hasLength(1));
      expect(p.orders.first.orderId, 'o1');
      expect(p.lastSyncAt, isNotNull);
      expect(p.errorMessage, isNull);
      expect(p.hasCredentials, isTrue);
    });

    test('persists the credentials to secure storage', () async {
      final backend = _InMemoryBackend();
      final p = _provider(mock: _mockEndpoints(), backend: backend);
      await p.connect(_creds);

      final reloaded = await BitunixSecretsStore(backend: backend).load();
      expect(reloaded, _creds);
    });

    test('emits notifyListeners across the status transitions', () async {
      final p = _provider(mock: _mockEndpoints());
      final seen = <BitunixConnectionStatus>[];
      p.addListener(() => seen.add(p.status));

      await p.connect(_creds);
      expect(seen, contains(BitunixConnectionStatus.connecting));
      expect(seen.last, BitunixConnectionStatus.connected);
    });
  });

  group('connect — error paths', () {
    test('401 from balance call drops the provider into error state',
        () async {
      final mock = _mockEndpoints(
        balance: http.Response('{"code":401,"msg":"bad signature"}', 401),
      );
      final p = _provider(mock: mock);

      await p.connect(_creds);

      expect(p.status, BitunixConnectionStatus.error);
      expect(p.errorMessage, isNotNull);
      expect(p.errorMessage, contains('Authentication failed'));
      expect(p.balance, isNull);
    });

    test('non-zero envelope code surfaces as an api error', () async {
      final mock = _mockEndpoints(
        balance: {'code': 40001, 'msg': 'symbol not supported'},
      );
      final p = _provider(mock: mock);

      await p.connect(_creds);

      expect(p.status, BitunixConnectionStatus.error);
      expect(p.errorMessage, contains('API error'));
    });

    test('error state still leaves credentials available for retry', () async {
      final mock = _mockEndpoints(
        balance: http.Response('{"code":401}', 401),
      );
      final p = _provider(mock: mock);

      await p.connect(_creds);

      expect(p.status, BitunixConnectionStatus.error);
      expect(p.hasCredentials, isTrue);
    });
  });

  group('refresh', () {
    test('no-op when no credentials are configured', () async {
      final p = _provider(mock: _mockEndpoints());
      await p.refresh();
      expect(p.status, BitunixConnectionStatus.disconnected);
    });

    test('updates lastSyncAt after a successful re-fetch', () async {
      final p = _provider(mock: _mockEndpoints());
      await p.connect(_creds);
      final firstSync = p.lastSyncAt;
      expect(firstSync, isNotNull);

      // Spin one microtask to guarantee the next DateTime.now() differs.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await p.refresh();

      expect(p.status, BitunixConnectionStatus.connected);
      expect(p.lastSyncAt!.isAfter(firstSync!), isTrue);
    });
  });

  group('disconnect', () {
    test('wipes in-memory state but leaves the secure storage intact',
        () async {
      final backend = _InMemoryBackend();
      final p = _provider(mock: _mockEndpoints(), backend: backend);
      await p.connect(_creds);

      await p.disconnect();

      expect(p.status, BitunixConnectionStatus.disconnected);
      expect(p.balance, isNull);
      expect(p.positions, isEmpty);
      expect(p.orders, isEmpty);
      expect(p.lastSyncAt, isNull);
      expect(p.hasCredentials, isFalse);

      // Disk credentials still around.
      final reloaded = await BitunixSecretsStore(backend: backend).load();
      expect(reloaded, _creds);
    });
  });

  group('clearStoredCredentials', () {
    test('wipes both in-memory and on-disk credentials', () async {
      final backend = _InMemoryBackend();
      final p = _provider(mock: _mockEndpoints(), backend: backend);
      await p.connect(_creds);

      await p.clearStoredCredentials();

      expect(p.status, BitunixConnectionStatus.disconnected);
      expect(p.hasCredentials, isFalse);
      final reloaded = await BitunixSecretsStore(backend: backend).load();
      expect(reloaded, isNull);
    });
  });

  group('live-trading enable flag', () {
    test('liveTradingEnabled is hardcoded false', () async {
      final p = _provider(mock: _mockEndpoints());
      expect(p.liveTradingEnabled, isFalse);

      await p.connect(_creds);
      expect(p.liveTradingEnabled, isFalse,
          reason: 'Even a successfully connected provider must stay locked '
              'until Welle B4 Step-3 ships the risk layer.');
    });
  });
}
