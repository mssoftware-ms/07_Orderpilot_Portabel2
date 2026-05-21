// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/binance_api_client.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Build a realistic Binance kline array.
List<dynamic> _kline({
  int openTime = 1609459200000, // 2021-01-01 00:00 UTC
  String open = '29000.00',
  String high = '29500.00',
  String low = '28800.00',
  String close = '29300.00',
  String volume = '1234.567',
}) =>
    [
      openTime,
      open,
      high,
      low,
      close,
      volume,
      openTime + 3600000 - 1, // close time
      '36000000.00', // quote volume
      500, // trades
      '600.00', // taker buy base
      '17000000.00', // taker buy quote
      '0', // ignore
    ];

/// Build a list of N kline arrays with sequential timestamps.
List<List<dynamic>> _klines(int n, {int startMs = 1609459200000, int intervalMs = 3600000}) {
  return List.generate(n, (i) {
    final ts = startMs + i * intervalMs;
    return _kline(
      openTime: ts,
      open: '${29000 + i}',
      high: '${29500 + i}',
      low: '${28800 + i}',
      close: '${29300 + i}',
      volume: '${1000 + i}.0',
    );
  });
}

/// Create a MockClient that returns the given JSON body.
MockClient _mockSuccess(dynamic body, {int statusCode = 200}) {
  return MockClient((request) async {
    return http.Response(jsonEncode(body), statusCode);
  });
}

/// Create a MockClient that always returns the given error status code.
MockClient _mockError(int statusCode, {String body = '{"code":-1,"msg":"error"}'}) {
  return MockClient((request) async {
    return http.Response(body, statusCode);
  });
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // CandleData model tests
  // ───────────────────────────────────────────────────────────────────────────

  group('CandleData', () {
    group('fromBinanceKline', () {
      test('parses a valid Binance kline array', () {
        final kline = _kline();
        final c = CandleData.fromBinanceKline(kline);
        expect(c.timestamp, 1609459200000);
        expect(c.open, 29000.0);
        expect(c.high, 29500.0);
        expect(c.low, 28800.0);
        expect(c.close, 29300.0);
        expect(c.volume, 1234.567);
      });

      test('handles string prices with many decimals', () {
        final kline = _kline(
          open: '0.00000100',
          high: '0.00000200',
          low: '0.00000050',
          close: '0.00000150',
          volume: '99999999.12345678',
        );
        final c = CandleData.fromBinanceKline(kline);
        expect(c.open, closeTo(0.000001, 1e-10));
        expect(c.volume, closeTo(99999999.12345678, 1e-4));
      });

      test('fromBinanceJson alias works the same', () {
        final kline = _kline();
        final a = CandleData.fromBinanceKline(kline);
        final b = CandleData.fromBinanceJson(kline);
        expect(a, equals(b));
      });
    });

    group('fromJson / toJson roundtrip', () {
      test('roundtrips correctly', () {
        final original = CandleData(
          timestamp: 1609459200000,
          open: 100.5,
          high: 110.0,
          low: 95.0,
          close: 105.0,
          volume: 5000.0,
        );
        final json = original.toJson();
        final restored = CandleData.fromJson(json);
        expect(restored, equals(original));
      });

      test('fromJson handles int values for prices', () {
        final json = {
          'timestamp': 1609459200000,
          'open': 100,
          'high': 110,
          'low': 95,
          'close': 105,
          'volume': 5000,
        };
        final c = CandleData.fromJson(json);
        expect(c.open, 100.0);
        expect(c.high, 110.0);
      });
    });

    group('toRustJson', () {
      test('produces expected format', () {
        final c = CandleData(
          timestamp: 1609459200000,
          open: 100.0,
          high: 110.0,
          low: 90.0,
          close: 105.0,
          volume: 1000.0,
        );
        final rust = c.toRustJson();
        expect(rust['timestamp'], 1609459200000);
        expect(rust['open'], 100.0);
        expect(rust['high'], 110.0);
        expect(rust['low'], 90.0);
        expect(rust['close'], 105.0);
        expect(rust['volume'], 1000.0);
      });
    });

    group('derived properties', () {
      test('isBullish when close >= open', () {
        final c = CandleData(timestamp: 0, open: 100, high: 110, low: 90, close: 105, volume: 1);
        expect(c.isBullish, true);
        expect(c.isBearish, false);
      });

      test('isBearish when close < open', () {
        final c = CandleData(timestamp: 0, open: 105, high: 110, low: 90, close: 100, volume: 1);
        expect(c.isBullish, false);
        expect(c.isBearish, true);
      });

      test('flat candle is bullish (close == open)', () {
        final c = CandleData(timestamp: 0, open: 100, high: 100, low: 100, close: 100, volume: 0);
        expect(c.isBullish, true);
        expect(c.isBearish, false);
      });

      test('bodySize, range, midpoint', () {
        final c = CandleData(timestamp: 0, open: 100, high: 120, low: 80, close: 110, volume: 1);
        expect(c.bodySize, 10.0);
        expect(c.range, 40.0);
        expect(c.midpoint, 100.0);
      });

      test('dateTime conversion', () {
        final c = CandleData(timestamp: 1609459200000, open: 0, high: 0, low: 0, close: 0, volume: 0);
        expect(c.dateTime, DateTime.utc(2021, 1, 1));
      });
    });

    group('equality', () {
      test('equal candles have same hashCode', () {
        final a = CandleData(timestamp: 1, open: 2, high: 3, low: 1, close: 2.5, volume: 100);
        final b = CandleData(timestamp: 1, open: 2, high: 3, low: 1, close: 2.5, volume: 100);
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('different candles are not equal', () {
        final a = CandleData(timestamp: 1, open: 2, high: 3, low: 1, close: 2.5, volume: 100);
        final b = CandleData(timestamp: 2, open: 2, high: 3, low: 1, close: 2.5, volume: 100);
        expect(a, isNot(equals(b)));
      });
    });

    test('toString contains key fields', () {
      final c = CandleData(timestamp: 123, open: 1, high: 2, low: 0, close: 1.5, volume: 10);
      expect(c.toString(), contains('123'));
      expect(c.toString(), contains('CandleData'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // BinanceApiClient tests
  // ───────────────────────────────────────────────────────────────────────────

  group('BinanceApiClient', () {
    group('fetchHistoricalKlines', () {
      test('parses successful kline response', () async {
        final mockKlines = _klines(5);
        final client = BinanceApiClient(
          client: _mockSuccess(mockKlines),
          maxRetries: 0,
        );

        final candles = await client.fetchHistoricalKlines(
          symbol: 'BTCUSDT',
          interval: '1h',
          limit: 5,
        );

        expect(candles.length, 5);
        expect(candles.first.timestamp, mockKlines.first[0]);
        expect(candles.last.timestamp, mockKlines.last[0]);
      });

      test('passes query parameters correctly', () async {
        Uri? capturedUri;
        final mockClient = MockClient((request) async {
          capturedUri = request.url;
          return http.Response(jsonEncode(_klines(1)), 200);
        });

        final client = BinanceApiClient(client: mockClient, maxRetries: 0);
        await client.fetchHistoricalKlines(
          symbol: 'ethusdt',
          interval: '15m',
          limit: 100,
          startTime: 1000,
          endTime: 2000,
        );

        expect(capturedUri, isNotNull);
        expect(capturedUri!.queryParameters['symbol'], 'ETHUSDT');
        expect(capturedUri!.queryParameters['interval'], '15m');
        expect(capturedUri!.queryParameters['limit'], '100');
        expect(capturedUri!.queryParameters['startTime'], '1000');
        expect(capturedUri!.queryParameters['endTime'], '2000');
      });

      test('preserves timestamp order from API', () async {
        final klines = _klines(3);
        final client = BinanceApiClient(
          client: _mockSuccess(klines),
          maxRetries: 0,
        );

        final candles = await client.fetchHistoricalKlines(
          symbol: 'BTCUSDT',
          interval: '1h',
        );

        for (int i = 1; i < candles.length; i++) {
          expect(candles[i].timestamp, greaterThan(candles[i - 1].timestamp));
        }
      });

      test('returns empty list for empty response', () async {
        final client = BinanceApiClient(
          client: _mockSuccess([]),
          maxRetries: 0,
        );

        final candles = await client.fetchHistoricalKlines(
          symbol: 'BTCUSDT',
          interval: '1h',
        );

        expect(candles, isEmpty);
      });
    });

    group('input validation', () {
      test('rejects invalid symbol format', () async {
        final client = BinanceApiClient(
          client: _mockSuccess([]),
          maxRetries: 0,
        );

        expect(
          () => client.fetchHistoricalKlines(symbol: 'BTC-USDT', interval: '1h'),
          throwsA(isA<BinanceInvalidParamException>()),
        );
      });

      test('rejects empty symbol', () async {
        final client = BinanceApiClient(
          client: _mockSuccess([]),
          maxRetries: 0,
        );

        expect(
          () => client.fetchHistoricalKlines(symbol: '', interval: '1h'),
          throwsA(isA<BinanceInvalidParamException>()),
        );
      });

      test('rejects invalid interval', () async {
        final client = BinanceApiClient(
          client: _mockSuccess([]),
          maxRetries: 0,
        );

        expect(
          () => client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '7m'),
          throwsA(isA<BinanceInvalidParamException>()),
        );
      });

      test('rejects limit out of range', () async {
        final client = BinanceApiClient(
          client: _mockSuccess([]),
          maxRetries: 0,
        );

        expect(
          () => client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '1h', limit: 0),
          throwsA(isA<BinanceInvalidParamException>()),
        );

        expect(
          () => client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '1h', limit: 1001),
          throwsA(isA<BinanceInvalidParamException>()),
        );
      });
    });

    group('error handling', () {
      test('throws BinanceRateLimitException on 429', () async {
        final mockClient = MockClient((request) async {
          return http.Response(
            '{"code":-1015,"msg":"Too many requests"}',
            429,
            headers: {'retry-after': '5'},
          );
        });

        final client = BinanceApiClient(
          client: mockClient,
          maxRetries: 0,
        );

        expect(
          () => client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '1h'),
          throwsA(isA<BinanceRateLimitException>()),
        );
      });

      test('throws BinanceApiException on 4xx errors', () async {
        final client = BinanceApiClient(
          client: _mockError(400),
          maxRetries: 0,
        );

        expect(
          () => client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '1h'),
          throwsA(isA<BinanceApiException>()),
        );
      });

      test('throws BinanceApiException on malformed JSON', () async {
        final mockClient = MockClient((request) async {
          return http.Response('not json at all', 200);
        });

        final client = BinanceApiClient(
          client: mockClient,
          maxRetries: 0,
        );

        expect(
          () => client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '1h'),
          throwsA(isA<BinanceApiException>()),
        );
      });

      test('retries on 5xx errors up to maxRetries', () async {
        int callCount = 0;
        final mockClient = MockClient((request) async {
          callCount++;
          if (callCount < 3) {
            return http.Response('server error', 500);
          }
          return http.Response(jsonEncode(_klines(1)), 200);
        });

        final client = BinanceApiClient(
          client: mockClient,
          maxRetries: 3,
          baseRetryDelay: Duration(milliseconds: 10), // fast for tests
        );

        final candles = await client.fetchHistoricalKlines(
          symbol: 'BTCUSDT',
          interval: '1h',
        );

        expect(candles.length, 1);
        expect(callCount, 3); // 2 failures + 1 success
      });

      test('throws after exhausting retries', () async {
        final client = BinanceApiClient(
          client: _mockError(503),
          maxRetries: 2,
          baseRetryDelay: Duration(milliseconds: 10),
        );

        expect(
          () => client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '1h'),
          throwsA(isA<BinanceApiException>()),
        );
      });
    });

    group('fetchKlines backward compatibility', () {
      test('fetchKlines delegates to fetchHistoricalKlines', () async {
        final client = BinanceApiClient(
          client: _mockSuccess(_klines(3)),
          maxRetries: 0,
        );

        final candles = await client.fetchKlines(
          symbol: 'BTCUSDT',
          interval: '1h',
          limit: 3,
        );

        expect(candles.length, 3);
      });
    });

    group('caching', () {
      late Directory tempDir;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('binance_cache_test_');
      });

      tearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      test('second call uses cache (mock not called twice)', () async {
        int callCount = 0;
        final mockClient = MockClient((request) async {
          callCount++;
          return http.Response(jsonEncode(_klines(5)), 200);
        });

        final client = BinanceApiClient(
          client: mockClient,
          maxRetries: 0,
        );
        await client.initCache(tempDir.path);

        // First call — hits network
        final first = await client.fetchHistoricalKlines(
          symbol: 'BTCUSDT',
          interval: '1h',
          limit: 5,
        );
        expect(callCount, 1);

        // Second call — same params, should use cache
        final second = await client.fetchHistoricalKlines(
          symbol: 'BTCUSDT',
          interval: '1h',
          limit: 5,
        );
        expect(callCount, 1); // still 1 — no new network call
        expect(second.length, first.length);
      });

      test('different params bypass cache', () async {
        int callCount = 0;
        final mockClient = MockClient((request) async {
          callCount++;
          return http.Response(jsonEncode(_klines(3)), 200);
        });

        final client = BinanceApiClient(
          client: mockClient,
          maxRetries: 0,
        );
        await client.initCache(tempDir.path);

        await client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '1h', limit: 3);
        await client.fetchHistoricalKlines(symbol: 'ETHUSDT', interval: '1h', limit: 3);
        expect(callCount, 2);
      });

      test('clearCache resets cache', () async {
        int callCount = 0;
        final mockClient = MockClient((request) async {
          callCount++;
          return http.Response(jsonEncode(_klines(2)), 200);
        });

        final client = BinanceApiClient(
          client: mockClient,
          maxRetries: 0,
        );
        await client.initCache(tempDir.path);

        await client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '1h', limit: 2);
        expect(callCount, 1);

        await client.clearCache();

        await client.fetchHistoricalKlines(symbol: 'BTCUSDT', interval: '1h', limit: 2);
        expect(callCount, 2);
      });
    });

    group('downloadHistory', () {
      test('fetches multiple pages and deduplicates', () async {
        int callCount = 0;
        final mockClient = MockClient((request) async {
          callCount++;
          final startTime = int.parse(request.url.queryParameters['startTime']!);
          // Return 1000 candles each call, simulate 2 pages then empty
          if (callCount <= 2) {
            return http.Response(
              jsonEncode(_klines(1000, startMs: startTime, intervalMs: 3600000)),
              200,
            );
          }
          return http.Response(jsonEncode([]), 200);
        });

        final client = BinanceApiClient(
          client: mockClient,
          maxRetries: 0,
        );

        final candles = await client.downloadHistory(
          symbol: 'BTCUSDT',
          interval: '1h',
          days: 90,
        );

        expect(candles.length, 2000);
        expect(callCount, 3); // 2 full pages + 1 empty
        // Verify sorted
        for (int i = 1; i < candles.length; i++) {
          expect(candles[i].timestamp, greaterThan(candles[i - 1].timestamp));
        }
      });
    });

    group('candlesToRustJson', () {
      test('produces valid JSON array string', () {
        final candles = [
          CandleData(timestamp: 1000, open: 10, high: 12, low: 9, close: 11, volume: 100),
          CandleData(timestamp: 2000, open: 11, high: 13, low: 10, close: 12, volume: 200),
        ];

        final jsonStr = BinanceApiClient.candlesToRustJson(candles);
        final parsed = jsonDecode(jsonStr) as List<dynamic>;

        expect(parsed.length, 2);
        expect(parsed[0]['timestamp'], 1000);
        expect(parsed[1]['close'], 12);
      });

      test('returns empty array for empty list', () {
        final jsonStr = BinanceApiClient.candlesToRustJson([]);
        expect(jsonStr, '[]');
      });
    });

    group('getters', () {
      test('getAvailableSymbols returns non-empty unmodifiable list', () {
        final client = BinanceApiClient(
          client: _mockSuccess([]),
          maxRetries: 0,
        );

        final symbols = client.getAvailableSymbols();
        expect(symbols, isNotEmpty);
        expect(symbols, contains('BTCUSDT'));
        expect(() => (symbols as List).add('X'), throwsA(isA<UnsupportedError>()));
      });

      test('getAvailableTimeframes returns non-empty unmodifiable list', () {
        final client = BinanceApiClient(
          client: _mockSuccess([]),
          maxRetries: 0,
        );

        final tf = client.getAvailableTimeframes();
        expect(tf, isNotEmpty);
        expect(tf, contains('1h'));
        expect(() => (tf as List).add('X'), throwsA(isA<UnsupportedError>()));
      });
    });

    group('exception types', () {
      test('BinanceApiException has correct fields', () {
        final e = BinanceApiException(400, 'bad request', '{"code":-1}');
        expect(e.statusCode, 400);
        expect(e.message, 'bad request');
        expect(e.body, '{"code":-1}');
        expect(e.toString(), contains('400'));
        expect(e.toString(), contains('bad request'));
      });

      test('BinanceRateLimitException has retryAfter', () {
        final e = BinanceRateLimitException(Duration(seconds: 30), 'rate limited');
        expect(e.retryAfter, Duration(seconds: 30));
        expect(e.statusCode, 429);
      });

      test('BinanceInvalidParamException has param and value in message', () {
        final e = BinanceInvalidParamException('symbol', 'INVALID');
        expect(e.statusCode, 400);
        expect(e.message, contains('symbol'));
        expect(e.message, contains('INVALID'));
      });
    });
  });
}
