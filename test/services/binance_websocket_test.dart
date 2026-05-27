/// Welle B4-1 — Binance kline WebSocket client tests.
///
/// Layered:
///   1. KlineUpdate parser — pure unit test of the JSON contract.
///   2. closedOnly filter — pure unit test of the in-flight filter.
///   3. Live happy-path against a local HttpServer with
///      WebSocketTransformer (real `web_socket_channel` traffic, just
///      pointed at 127.0.0.1).
///   4. Reconnect backoff with `connector:` injection.
///   5. Max-reconnect cap surfaces a terminal stream error.
///   6. AppLog.warn fires on unexpected close.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/logging/app_log.dart';
import 'package:trading_app/services/binance_websocket.dart';

Map<String, dynamic> _klinePayload({
  required int openTime,
  required int closeTime,
  required bool isClosed,
  String symbol = 'BTCUSDT',
  String interval = '1m',
  double open = 100.0,
  double high = 110.0,
  double low = 95.0,
  double close = 105.0,
  double volume = 1.5,
}) =>
    {
      'e': 'kline',
      'E': closeTime,
      's': symbol,
      'k': {
        't': openTime,
        'T': closeTime,
        's': symbol,
        'i': interval,
        'o': open.toStringAsFixed(8),
        'h': high.toStringAsFixed(8),
        'l': low.toStringAsFixed(8),
        'c': close.toStringAsFixed(8),
        'v': volume.toStringAsFixed(8),
        'x': isClosed,
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KlineUpdate.fromBinanceJson', () {
    test('parses a real-shape Binance kline event', () {
      final json = _klinePayload(
        openTime: 1672515780000,
        closeTime: 1672515839999,
        isClosed: true,
        open: 16500.10,
        high: 16505.50,
        low: 16498.20,
        close: 16502.75,
        volume: 12.34,
      );

      final update = KlineUpdate.fromBinanceJson(json);

      expect(update.openTime, 1672515780000);
      expect(update.closeTime, 1672515839999);
      expect(update.symbol, 'BTCUSDT');
      expect(update.interval, '1m');
      expect(update.open, closeTo(16500.10, 1e-6));
      expect(update.high, closeTo(16505.50, 1e-6));
      expect(update.low, closeTo(16498.20, 1e-6));
      expect(update.close, closeTo(16502.75, 1e-6));
      expect(update.volume, closeTo(12.34, 1e-6));
      expect(update.isClosed, isTrue);
    });

    test('toCandle preserves OHLCV + open-time as timestamp', () {
      final update = KlineUpdate.fromBinanceJson(_klinePayload(
        openTime: 1700000000000,
        closeTime: 1700000059999,
        isClosed: true,
        open: 50.0,
        high: 55.0,
        low: 48.0,
        close: 52.0,
        volume: 7.5,
      ));

      final candle = update.toCandle();
      expect(candle.timestamp, 1700000000000);
      expect(candle.open, 50.0);
      expect(candle.high, 55.0);
      expect(candle.low, 48.0);
      expect(candle.close, 52.0);
      expect(candle.volume, 7.5);
    });
  });

  group('BinanceKlineStream — local WS happy path', () {
    late HttpServer server;
    late String baseUrl;
    final pending = <WebSocket>[];

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'ws://127.0.0.1:${server.port}/ws';
      server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final ws = await WebSocketTransformer.upgrade(request);
          pending.add(ws);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
        }
      });
    });

    tearDown(() async {
      for (final ws in pending) {
        try {
          await ws.close();
        } catch (_) {}
      }
      pending.clear();
      await server.close(force: true);
    });

    test('closedOnly=true filters in-flight ticks', () async {
      final stream = BinanceKlineStream(baseUrl: baseUrl);
      addTearDown(stream.dispose);

      final klineStream = stream.connect(
        symbol: 'BTCUSDT',
        interval: '1m',
      );
      final received = <KlineUpdate>[];
      final sub = klineStream.listen(received.add);

      // Wait until the server accepts the connection.
      while (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final ws = pending.first;

      ws.add(jsonEncode(_klinePayload(
        openTime: 1000,
        closeTime: 1999,
        isClosed: false,
      )));
      ws.add(jsonEncode(_klinePayload(
        openTime: 2000,
        closeTime: 2999,
        isClosed: true,
      )));
      ws.add(jsonEncode(_klinePayload(
        openTime: 3000,
        closeTime: 3999,
        isClosed: false,
      )));

      // Give the WS pump a beat to drain.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(received, hasLength(1));
      expect(received.first.openTime, 2000);
      expect(received.first.isClosed, isTrue);
    });

    test('closedOnly=false lets in-flight ticks through', () async {
      final stream = BinanceKlineStream(baseUrl: baseUrl);
      addTearDown(stream.dispose);

      final klineStream = stream.connect(
        symbol: 'BTCUSDT',
        interval: '1m',
        closedOnly: false,
      );
      final received = <KlineUpdate>[];
      final sub = klineStream.listen(received.add);

      while (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final ws = pending.first;
      ws.add(jsonEncode(_klinePayload(
        openTime: 1000,
        closeTime: 1999,
        isClosed: false,
      )));
      ws.add(jsonEncode(_klinePayload(
        openTime: 2000,
        closeTime: 2999,
        isClosed: true,
      )));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      expect(received, hasLength(2));
    });

    test('status transitions idle → connecting → running on successful connect',
        () async {
      final stream = BinanceKlineStream(baseUrl: baseUrl);
      addTearDown(stream.dispose);

      final seen = <KlineConnectionStatus>[];
      final statusSub = stream.statusStream.listen(seen.add);

      final klineStream = stream.connect(
        symbol: 'BTCUSDT',
        interval: '1m',
      );
      final klineSub = klineStream.listen((_) {});

      while (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // ready + listen happens on the microtask; give it a tick.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await klineSub.cancel();
      await statusSub.cancel();

      expect(seen, contains(KlineConnectionStatus.connecting));
      expect(seen, contains(KlineConnectionStatus.running));
    });
  });

  group('BinanceKlineStream — reconnect logic', () {
    test('failed connect schedules a retry after baseRetryDelay', () async {
      var attempts = 0;
      final stream = BinanceKlineStream(
        baseRetryDelay: const Duration(milliseconds: 40),
        maxRetryDelay: const Duration(milliseconds: 40),
        maxReconnectAttempts: 3,
        connector: (uri) {
          attempts++;
          throw const SocketException('mock connect failure');
        },
      );
      addTearDown(stream.dispose);

      final klineStream = stream.connect(symbol: 'BTCUSDT', interval: '1m');

      final errors = <Object>[];
      final sub = klineStream.listen(
        (_) {},
        onError: errors.add,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await sub.cancel();

      // 1 initial + 3 retries before cap hits.
      expect(attempts, greaterThanOrEqualTo(4));
      expect(stream.status, KlineConnectionStatus.error);
      expect(errors, isNotEmpty);
    });

    test('AppLog.warn fires on connect failure', () async {
      // Clear log so this test is hermetic.
      AppLog.instance.clear();

      final stream = BinanceKlineStream(
        baseRetryDelay: const Duration(milliseconds: 20),
        maxReconnectAttempts: 1,
        connector: (uri) {
          throw const SocketException('mock connect failure');
        },
      );
      addTearDown(stream.dispose);

      final klineStream = stream.connect(symbol: 'BTCUSDT', interval: '1m');
      final sub = klineStream.listen((_) {}, onError: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();

      final entries = AppLog.instance.entries;
      final warnsErrors = entries.where((e) =>
          e.tag == 'BinanceWS' &&
          (e.level == LogLevel.warning || e.level == LogLevel.error));
      expect(warnsErrors, isNotEmpty);
    });

    test('connect after disconnect re-opens cleanly', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final url = 'ws://127.0.0.1:${server.port}/ws';
      final pending = <WebSocket>[];
      server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          pending.add(await WebSocketTransformer.upgrade(request));
        }
      });
      addTearDown(() async {
        for (final ws in pending) {
          try {
            await ws.close();
          } catch (_) {}
        }
        await server.close(force: true);
      });

      final stream = BinanceKlineStream(baseUrl: url);
      addTearDown(stream.dispose);

      // Round 1
      var s = stream.connect(symbol: 'BTCUSDT', interval: '1m');
      var sub = s.listen((_) {});
      while (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await sub.cancel();
      await stream.disconnect();
      expect(stream.status, KlineConnectionStatus.stopped);

      // Round 2
      pending.clear();
      s = stream.connect(symbol: 'ETHUSDT', interval: '5m');
      sub = s.listen((_) {});
      while (pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await sub.cancel();
      await stream.disconnect();

      expect(stream.status, KlineConnectionStatus.stopped);
    });
  });
}
