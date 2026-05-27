/// Pinned regression contract for the Bitunix live-order-routing stubs
/// — Welle P4P Step-5.
///
/// `placeOrder` and `cancelOrder` MUST throw [LiveTradingDisabledException]
/// in every reachable configuration. This file lives separately from
/// `bitunix_client_test.dart` so the contract is loud — anyone removing
/// these tests has to do so deliberately, and the failure they cause
/// when the throw goes away should be impossible to mistake for an
/// unrelated regression.
///
/// The risk layer that unblocks the real implementation is Welle B4
/// Step-3 (kill-switch + daily-loss cap). Until that ships, every code
/// path through `BitunixClient` that could in principle hit
/// `POST /place-order` against Bitunix has to terminate with this
/// exception.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:trading_app/services/bitunix_auth.dart';
import 'package:trading_app/services/bitunix_client.dart';
import 'package:trading_app/services/bitunix_exceptions.dart';

const _creds = BitunixCredentials(apiKey: 'k', secret: 's');

BitunixClient _client() {
  // A MockClient that explodes on any call — proves the stubs never
  // get far enough to attempt a network request.
  final mock = MockClient((_) async {
    fail('Live order paths must never reach the HTTP client');
  });
  return BitunixClient(
    credentials: _creds,
    httpClient: mock,
    nonceProvider: () => 'fixed',
    timestampProvider: () => 1716800000000,
    maxRetries: 1,
    baseRetryDelay: const Duration(milliseconds: 1),
  );
}

void main() {
  group('LiveTradingDisabledException — placeOrder', () {
    test('MARKET BUY throws', () async {
      final c = _client();
      await expectLater(
        c.placeOrder(
          symbol: 'BTCUSDT',
          side: 'BUY',
          orderType: 'MARKET',
          qty: 0.01,
        ),
        throwsA(isA<LiveTradingDisabledException>()),
      );
    });

    test('LIMIT SELL with TP+SL throws', () async {
      final c = _client();
      await expectLater(
        c.placeOrder(
          symbol: 'BTCUSDT',
          side: 'SELL',
          orderType: 'LIMIT',
          qty: 0.1,
          price: 60000,
          tpPrice: 65000,
          slPrice: 55000,
        ),
        throwsA(isA<LiveTradingDisabledException>()),
      );
    });

    test('extreme qty + price still throws (no overflow-bypass)', () async {
      final c = _client();
      await expectLater(
        c.placeOrder(
          symbol: 'BTCUSDT',
          side: 'BUY',
          orderType: 'LIMIT',
          qty: 1e18,
          price: 1e18,
        ),
        throwsA(isA<LiveTradingDisabledException>()),
      );
    });
  });

  group('LiveTradingDisabledException — cancelOrder', () {
    test('with orderId throws', () async {
      final c = _client();
      await expectLater(
        c.cancelOrder(symbol: 'BTCUSDT', orderId: 'order-1'),
        throwsA(isA<LiveTradingDisabledException>()),
      );
    });

    test('without orderId throws', () async {
      final c = _client();
      await expectLater(
        c.cancelOrder(symbol: 'BTCUSDT'),
        throwsA(isA<LiveTradingDisabledException>()),
      );
    });
  });

  group('Exception payload', () {
    test('exception message names Welle B4 Step-3', () {
      try {
        throw const LiveTradingDisabledException();
      } on LiveTradingDisabledException catch (e) {
        expect(e.message, contains('Welle B4 Step-3'));
        expect(e.toString(), contains('LiveTradingDisabledException'));
      }
    });

    test('exception implements Exception', () {
      const e = LiveTradingDisabledException();
      expect(e, isA<Exception>());
    });

    test('a custom message survives the constructor', () {
      const e = LiveTradingDisabledException('custom hint');
      expect(e.message, 'custom hint');
      expect(e.toString(), 'LiveTradingDisabledException: custom hint');
    });
  });
}
