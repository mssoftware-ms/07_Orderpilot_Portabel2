// F-05 Regression Test: Cache key must remain stable across `downloadHistory`
// calls that fall within the same hour.
//
// Bug: `BinanceApiClient.downloadHistory` recomputes `DateTime.now()` on every
// invocation. The resulting `endTime` (and `startTime = now - days`) is
// millisecond-precise, so two calls separated by even a few ms produce
// different cache keys and a redundant disk write + HTTP fetch.
//
// Fix: round the endtime (and startime) used in the cache key down to the last
// full hour, so identical logical ranges within the same hour collide on the
// same key.
//
// Plan reference: §3.4 (F-05).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:trading_app/services/binance_api_client.dart';

/// Build a single Binance kline array for a given open time.
List<dynamic> _kline(int openTime) => [
      openTime,
      '29000.00',
      '29500.00',
      '28800.00',
      '29300.00',
      '1234.5',
      openTime + 3599999,
      '36000000.00',
      500,
      '600.00',
      '17000000.00',
      '0',
    ];

/// Build N kline arrays starting at [startMs], one per hour.
List<List<dynamic>> _hourlyKlines(int n, {required int startMs}) =>
    List.generate(n, (i) => _kline(startMs + i * 3600000));

void main() {
  // Plan-skeleton constants. The current `downloadHistory` API only takes
  // `days: int` and computes `now` internally — that is precisely where the
  // bug lives. T0 / days() are kept here to document the logical intent of
  // the test (a fixed 7-day window).
  final T0 =
      DateTime.utc(2024, 1, 1).millisecondsSinceEpoch; // > 7 days in the past
  int days(int n) => Duration(days: n).inMilliseconds;

  group('F-05: cache key stability', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('f05_cache_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('downloadHistory hits cache on second call within same hour',
        () async {
      // Sanity: T0 / days() helpers are well-defined.
      expect(T0, lessThan(DateTime.now().millisecondsSinceEpoch));
      expect(days(7), equals(7 * 24 * 60 * 60 * 1000));

      int callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        final startTime =
            int.parse(request.url.queryParameters['startTime']!);
        // Return 500 candles (< 1000 → loop breaks after this page).
        final payload = _hourlyKlines(500, startMs: startTime);
        return http.Response(jsonEncode(payload), 200);
      });

      final client = BinanceApiClient(client: mockClient, maxRetries: 0);
      await client.initCache(tempDir.path);

      await client.downloadHistory(
        symbol: 'BTCUSDT',
        interval: '1h',
        days: 7,
      );
      final filesBefore = tempDir.listSync().length;
      expect(filesBefore, greaterThan(0),
          reason: 'First call must have written at least one cache file.');

      await Future<void>.delayed(const Duration(milliseconds: 50));

      await client.downloadHistory(
        symbol: 'BTCUSDT',
        interval: '1h',
        days: 7,
      );
      final filesAfter = tempDir.listSync().length;

      expect(
        filesAfter,
        equals(filesBefore),
        reason:
            'Second downloadHistory call within the same hour must hit the '
            'disk cache instead of producing a fresh cache file. '
            'Cache key must round endtime to the last full hour.',
      );

      client.dispose();
    });
  });
}
