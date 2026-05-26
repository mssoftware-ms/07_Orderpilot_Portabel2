/// Binance REST API client for fetching historical OHLCV candle data.
///
/// Features:
///   - Fetches klines from `GET /api/v3/klines`
///   - In-memory + on-disk (JSON file) caching to avoid redundant API calls
///   - Automatic retry with exponential backoff (network errors, 5xx, 429)
///   - Rate-limit detection (HTTP 429) with `Retry-After` header support
///   - Detailed logging for debugging (API calls, cache hits/misses, retries)
///   - Convenience method [downloadHistory] to fetch N days of data
///
/// ## Example – Fetch BTC/USDT 1h data for the last 30 days
/// ```dart
/// final client = BinanceApiClient();
/// final candles = await client.downloadHistory(
///   symbol: 'BTCUSDT',
///   interval: '1h',
///   days: 30,
/// );
/// print('Fetched ${candles.length} candles');
/// // Convert for Rust engine
/// final rustJsonList = candles.map((c) => c.toRustJson()).toList();
/// client.dispose();
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/constants/app_constants.dart';
import '../core/logging/app_log.dart';
import '../core/models/candle.dart';

// ─── Exceptions ─────────────────────────────────────────────────────────────

/// Thrown when the Binance API returns an error response.
class BinanceApiException implements Exception {
  final int statusCode;
  final String message;
  final String? body;

  const BinanceApiException(this.statusCode, this.message, [this.body]);

  @override
  String toString() => 'BinanceApiException($statusCode): $message';
}

/// Thrown when the API rate limit is hit (HTTP 429).
class BinanceRateLimitException extends BinanceApiException {
  final Duration retryAfter;

  BinanceRateLimitException(this.retryAfter, [String? body])
      : super(429, 'Rate limited – retry after ${retryAfter.inSeconds}s', body);
}

/// Thrown when the symbol or interval is invalid.
class BinanceInvalidParamException extends BinanceApiException {
  BinanceInvalidParamException(String param, String value)
      : super(400, 'Invalid $param: "$value"');
}

// ─── Logger ─────────────────────────────────────────────────────────────────

/// Simple logger for BinanceApiClient.
///
/// Set [BinanceApiClient.enableLogging] to `true` for debug console output.
/// Warnings and errors are always forwarded to [AppLog] so they surface in
/// the dashboard's System Log panel, independent of [enabled].
class _Log {
  static const String _tag = 'BinanceApi';
  static bool enabled = false;

  static void info(String msg) {
    if (enabled) {
      // ignore: avoid_print
      print('[$_tag] $msg');
    }
  }

  static void warn(String msg) {
    AppLog.warn(_tag, msg);
    if (enabled) {
      // ignore: avoid_print
      print('[$_tag] ⚠ $msg');
    }
  }

  static void error(String msg) {
    AppLog.error(_tag, msg);
    // Always print errors regardless of logging flag
    // ignore: avoid_print
    print('[$_tag] ❌ $msg');
  }
}

// ─── Cache ──────────────────────────────────────────────────────────────────

/// Simple in-memory + on-disk JSON cache for candle data.
///
/// Cache keys follow the pattern: `{symbol}_{interval}_{startMs}_{endMs}`
class _CandleCache {
  /// In-memory LRU-ish cache (most recent entries kept).
  final Map<String, List<CandleData>> _memory = {};

  /// Max number of entries to keep in memory.
  static const int _maxMemoryEntries = 50;

  /// Optional directory for persistent file cache.
  Directory? _cacheDir;

  /// Whether on-disk caching is enabled.
  bool get isDiskEnabled => _cacheDir != null;

  /// Initialize the cache. Call once at startup.
  /// [cacheDir] is the directory where JSON cache files are stored.
  /// Pass `null` to use memory-only caching.
  Future<void> init({String? cacheDirPath}) async {
    if (cacheDirPath != null) {
      _cacheDir = Directory(cacheDirPath);
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
      _Log.info('Disk cache initialized at: $cacheDirPath');
    }
  }

  /// Build a cache key.
  ///
  /// F-05: round `startMs` and `endMs` down to the last full hour so that
  /// ms-precise drift between calls (e.g. `endTime = DateTime.now()` in
  /// successive `downloadHistory` invocations) collides on the same key.
  static String key(String symbol, String interval, int? startMs, int? endMs, int limit) {
    const hourMs = 3600000;
    final sRounded = startMs != null ? (startMs ~/ hourMs) * hourMs : 0;
    final eRounded = endMs != null ? (endMs ~/ hourMs) * hourMs : 0;
    return '${symbol}_${interval}_${sRounded}_${eRounded}_$limit';
  }

  /// Look up candles in memory, then disk.
  Future<List<CandleData>?> get(String cacheKey) async {
    // Memory hit
    if (_memory.containsKey(cacheKey)) {
      _Log.info('Cache HIT (memory): $cacheKey');
      return _memory[cacheKey];
    }

    // Disk hit
    if (isDiskEnabled) {
      final file = File('${_cacheDir!.path}/$cacheKey.json');
      if (await file.exists()) {
        try {
          final json = await file.readAsString();
          final List<dynamic> list = jsonDecode(json) as List<dynamic>;
          final candles = list
              .map((e) => CandleData.fromJson(e as Map<String, dynamic>))
              .toList();
          // Promote to memory cache
          _putMemory(cacheKey, candles);
          _Log.info('Cache HIT (disk): $cacheKey (${candles.length} candles)');
          return candles;
        } catch (e) {
          _Log.warn('Cache read error for $cacheKey: $e');
          // Corrupt file – delete it
          await file.delete().catchError((_) => file);
        }
      }
    }

    _Log.info('Cache MISS: $cacheKey');
    return null;
  }

  /// Store candles in memory and optionally on disk.
  Future<void> put(String cacheKey, List<CandleData> candles) async {
    _putMemory(cacheKey, candles);

    if (isDiskEnabled) {
      try {
        final file = File('${_cacheDir!.path}/$cacheKey.json');
        final json = jsonEncode(candles.map((c) => c.toJson()).toList());
        await file.writeAsString(json);
        _Log.info('Cache WRITE (disk): $cacheKey (${candles.length} candles)');
      } catch (e) {
        _Log.warn('Cache write error for $cacheKey: $e');
      }
    }
  }

  void _putMemory(String cacheKey, List<CandleData> candles) {
    // Evict oldest entries if at capacity
    while (_memory.length >= _maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
    _memory[cacheKey] = candles;
  }

  /// Clear all cached data.
  Future<void> clear() async {
    _memory.clear();
    if (isDiskEnabled) {
      final dir = _cacheDir!;
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File && entity.path.endsWith('.json')) {
            await entity.delete();
          }
        }
      }
    }
    _Log.info('Cache cleared');
  }

  /// Number of entries currently in memory.
  int get memorySize => _memory.length;
}

// ─── BinanceApiClient ───────────────────────────────────────────────────────

/// Client for fetching historical candle data from Binance REST API.
///
/// Supports caching, retry with backoff, and rate-limit handling.
class BinanceApiClient {
  final http.Client _client;
  final _CandleCache _cache = _CandleCache();

  /// Maximum number of retries for transient errors.
  final int maxRetries;

  /// Base delay for exponential backoff (doubled on each retry).
  final Duration baseRetryDelay;

  /// Whether debug logging is enabled.
  static bool enableLogging = false;

  /// Create a new BinanceApiClient.
  ///
  /// [client] – optional HTTP client (useful for testing with mocks).
  /// [maxRetries] – max retry attempts for transient errors (default 3).
  /// [baseRetryDelay] – initial backoff delay (default 1s, doubled each retry).
  /// [cacheDirPath] – optional directory path for on-disk caching.
  ///   Pass `null` for memory-only caching.
  BinanceApiClient({
    http.Client? client,
    this.maxRetries = 3,
    this.baseRetryDelay = const Duration(seconds: 1),
    String? cacheDirPath,
  }) : _client = client ?? http.Client() {
    _Log.enabled = enableLogging;
    if (cacheDirPath != null) {
      _cache.init(cacheDirPath: cacheDirPath);
    }
  }

  /// Initialize the on-disk cache directory.
  /// Call this if you didn't pass [cacheDirPath] in the constructor.
  Future<void> initCache(String cacheDirPath) async {
    await _cache.init(cacheDirPath: cacheDirPath);
  }

  // ─── Public API ─────────────────────────────────────────────────────────

  /// Fetch historical klines (candles) from Binance.
  ///
  /// - [symbol] – Trading pair (e.g. "BTCUSDT"). Case-insensitive.
  /// - [interval] – Candle timeframe (e.g. "1h", "15m"). See [getAvailableTimeframes].
  /// - [limit] – Number of candles to fetch (max 1000 per Binance API).
  /// - [startTime] – Optional start time in Unix milliseconds (UTC).
  /// - [endTime] – Optional end time in Unix milliseconds (UTC).
  ///
  /// Returns candles sorted by timestamp (oldest first).
  ///
  /// Throws:
  ///   - [BinanceInvalidParamException] for invalid symbol/interval
  ///   - [BinanceRateLimitException] if rate limited after all retries
  ///   - [BinanceApiException] for other API errors
  ///   - [Exception] for network errors after all retries
  Future<List<CandleData>> fetchHistoricalKlines({
    required String symbol,
    required String interval,
    int limit = AppConstants.defaultCandleCount,
    int? startTime,
    int? endTime,
  }) async {
    // Validate inputs
    final normalizedSymbol = symbol.toUpperCase().trim();
    final normalizedInterval = interval.toLowerCase().trim();
    _validateSymbol(normalizedSymbol);
    _validateInterval(normalizedInterval);
    if (limit < 1 || limit > 1000) {
      throw BinanceInvalidParamException('limit', '$limit (must be 1–1000)');
    }

    // Check cache
    final cacheKey = _CandleCache.key(
        normalizedSymbol, normalizedInterval, startTime, endTime, limit);
    final cached = await _cache.get(cacheKey);
    if (cached != null) return cached;

    // Build request URL
    final queryParams = <String, String>{
      'symbol': normalizedSymbol,
      'interval': normalizedInterval,
      'limit': limit.toString(),
    };
    if (startTime != null) queryParams['startTime'] = startTime.toString();
    if (endTime != null) queryParams['endTime'] = endTime.toString();

    final uri = Uri.parse(
      '${AppConstants.binanceBaseUrl}${AppConstants.binanceKlinesEndpoint}',
    ).replace(queryParameters: queryParams);

    // Fetch with retry
    final body = await _getWithRetry(uri);

    // Parse response
    final List<dynamic> data;
    try {
      data = jsonDecode(body) as List<dynamic>;
    } catch (e) {
      _Log.error('Failed to parse API response: $e');
      throw BinanceApiException(0, 'Failed to parse API response: $e', body);
    }

    final candles = data.map((e) {
      try {
        return CandleData.fromBinanceKline(e as List<dynamic>);
      } catch (err, st) {
        AppLog.error('BinanceApi', 'Failed to parse candle data: $err', err, st);
        throw BinanceApiException(
            0, 'Failed to parse candle data: $err', jsonEncode(e));
      }
    }).toList();

    _Log.info(
        'Fetched ${candles.length} candles for $normalizedSymbol/$normalizedInterval');

    // Cache result
    await _cache.put(cacheKey, candles);

    return candles;
  }

  /// Convenience: fetch klines using the old method signature.
  /// Delegates to [fetchHistoricalKlines].
  Future<List<CandleData>> fetchKlines({
    required String symbol,
    required String interval,
    int limit = AppConstants.defaultCandleCount,
    int? startTime,
    int? endTime,
  }) {
    return fetchHistoricalKlines(
      symbol: symbol,
      interval: interval,
      limit: limit,
      startTime: startTime,
      endTime: endTime,
    );
  }

  /// Download a full history of candles for the given number of days.
  ///
  /// Automatically paginates using the Binance API's 1000-candle limit.
  /// Results are sorted oldest-first and deduplicated by timestamp.
  ///
  /// ## Example
  /// ```dart
  /// final candles = await client.downloadHistory(
  ///   symbol: 'BTCUSDT',
  ///   interval: '1h',
  ///   days: 30,
  /// );
  /// ```
  Future<List<CandleData>> downloadHistory({
    required String symbol,
    required String interval,
    required int days,
  }) async {
    final intervalMs = _intervalToMs(interval);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final startMs = now - (days * 24 * 60 * 60 * 1000);

    _Log.info('Downloading $days days of $symbol/$interval '
        '(${DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true)} → now)');

    final allCandles = <CandleData>[];
    int currentStart = startMs;

    while (currentStart < now) {
      final batch = await fetchHistoricalKlines(
        symbol: symbol,
        interval: interval,
        limit: 1000,
        startTime: currentStart,
        endTime: now,
      );

      if (batch.isEmpty) break;

      allCandles.addAll(batch);

      // Move start past the last candle we received
      final lastTs = batch.last.timestamp;
      currentStart = lastTs + intervalMs;

      // Safety: if we got fewer than 1000, we've reached the end
      if (batch.length < 1000) break;
    }

    // Deduplicate by timestamp (can happen at page boundaries)
    final seen = <int>{};
    final deduplicated = <CandleData>[];
    for (final c in allCandles) {
      if (seen.add(c.timestamp)) {
        deduplicated.add(c);
      }
    }

    // Sort oldest first
    deduplicated.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    _Log.info('Downloaded ${deduplicated.length} total candles for $symbol/$interval');

    return deduplicated;
  }

  // ─── Helper methods ───────────────────────────────────────────────────

  /// Returns the list of supported trading symbols.
  List<String> getAvailableSymbols() => List.unmodifiable(AppConstants.supportedSymbols);

  /// Returns the list of supported candle timeframes/intervals.
  List<String> getAvailableTimeframes() =>
      List.unmodifiable(AppConstants.supportedTimeframes);

  /// Convert a list of [CandleData] to the JSON format expected by the Rust
  /// engine bridge ([`run_bb_rsi_strategy`] and friends).
  ///
  /// Returns a JSON string of an array of candle objects.
  static String candlesToRustJson(List<CandleData> candles) {
    return jsonEncode(candles.map((c) => c.toRustJson()).toList());
  }

  /// Clear the entire candle cache (memory + disk).
  Future<void> clearCache() => _cache.clear();

  /// Number of entries currently in the memory cache.
  int get memoryCacheSize => _cache.memorySize;

  /// Release resources. Call when the client is no longer needed.
  void dispose() => _client.close();

  // ─── Private helpers ──────────────────────────────────────────────────

  /// Execute a GET request with automatic retry and backoff.
  Future<String> _getWithRetry(Uri uri) async {
    int attempt = 0;
    Duration delay = baseRetryDelay;

    while (true) {
      attempt++;
      _Log.info('HTTP GET $uri (attempt $attempt/$maxRetries)');

      try {
        final response = await _client.get(uri);

        // Success
        if (response.statusCode == 200) {
          return response.body;
        }

        // Rate limited
        if (response.statusCode == 429) {
          final retryAfterSec =
              int.tryParse(response.headers['retry-after'] ?? '') ?? 10;
          final retryAfter = Duration(seconds: retryAfterSec);

          if (attempt >= maxRetries) {
            throw BinanceRateLimitException(retryAfter, response.body);
          }

          _Log.warn('Rate limited (429). Waiting ${retryAfter.inSeconds}s '
              'before retry $attempt/$maxRetries');
          await Future.delayed(retryAfter);
          continue;
        }

        // Server error – retry
        if (response.statusCode >= 500 && attempt < maxRetries) {
          _Log.warn('Server error ${response.statusCode}. '
              'Retrying in ${delay.inMilliseconds}ms...');
          await Future.delayed(delay);
          delay *= 2;
          continue;
        }

        // Client error – don't retry
        throw BinanceApiException(
          response.statusCode,
          _parseErrorMessage(response.body),
          response.body,
        );
      } on SocketException catch (e) {
        if (attempt >= maxRetries) {
          throw Exception('Network error after $maxRetries attempts: $e');
        }
        _Log.warn('Network error: $e. Retrying in ${delay.inMilliseconds}ms...');
        await Future.delayed(delay);
        delay *= 2;
      } on http.ClientException catch (e) {
        if (attempt >= maxRetries) {
          throw Exception('HTTP client error after $maxRetries attempts: $e');
        }
        _Log.warn('Client error: $e. Retrying in ${delay.inMilliseconds}ms...');
        await Future.delayed(delay);
        delay *= 2;
      }
    }
  }

  /// Parse the error message from a Binance error response body.
  String _parseErrorMessage(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['msg'] as String? ?? body;
    } catch (e) {
      AppLog.warn('BinanceApi', 'Non-JSON error body, using raw body: $e');
      return body;
    }
  }

  /// Validate the trading symbol.
  void _validateSymbol(String symbol) {
    // Basic validation: must be alphanumeric, at least 2 chars
    if (symbol.length < 2 || !RegExp(r'^[A-Z0-9]+$').hasMatch(symbol)) {
      throw BinanceInvalidParamException('symbol', symbol);
    }
  }

  /// Validate the candle interval.
  void _validateInterval(String interval) {
    const validIntervals = {
      '1s', '1m', '3m', '5m', '15m', '30m',
      '1h', '2h', '4h', '6h', '8h', '12h',
      '1d', '3d', '1w', '1M',
    };
    if (!validIntervals.contains(interval)) {
      throw BinanceInvalidParamException('interval', interval);
    }
  }

  /// Convert a Binance interval string to milliseconds.
  int _intervalToMs(String interval) {
    final match = RegExp(r'^(\d+)([smhdwM])$').firstMatch(interval);
    if (match == null) {
      throw BinanceInvalidParamException('interval', interval);
    }
    final value = int.parse(match.group(1)!);
    final unit = match.group(2)!;
    return switch (unit) {
      's' => value * 1000,
      'm' => value * 60 * 1000,
      'h' => value * 60 * 60 * 1000,
      'd' => value * 24 * 60 * 60 * 1000,
      'w' => value * 7 * 24 * 60 * 60 * 1000,
      'M' => value * 30 * 24 * 60 * 60 * 1000, // approximate
      _ => throw BinanceInvalidParamException('interval', interval),
    };
  }
}
