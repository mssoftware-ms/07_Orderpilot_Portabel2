/// Bitunix Futures REST client — Welle P4P Step-1.
///
/// Surface:
///   * Read-only calls: [getAccountBalance], [getOpenPositions],
///     [getOpenOrders]. Each call is signed via [BitunixSigner] using the
///     credentials passed to the constructor.
///   * Order routing: [placeOrder] and [cancelOrder] unconditionally
///     throw [LiveTradingDisabledException] until Welle B4 Step-3 lands
///     the risk layer (kill-switch + daily-loss cap). The signature is
///     deliberately minimal so the future implementation can fill it in
///     without re-shaping every caller.
///
/// All endpoints have been verified against the official documentation
/// at `https://www.bitunix.com/api-docs/futures/...`:
///   * Account:   `GET /api/v1/futures/account?marginCoin={coin}`
///   * Positions: `GET /api/v1/futures/position/get_pending_positions`
///   * Orders:    `GET /api/v1/futures/trade/get_pending_orders`
///
/// The signing string concatenates query parameters in ASCII-ascending key
/// order without `=` or `&` separators — `marginCoin=USDT` becomes
/// `marginCoinUSDT`. The HTTP URL keeps the standard form.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/constants/app_constants.dart';
import '../core/logging/app_log.dart';
import '../core/models/bitunix_models.dart';
import 'bitunix_auth.dart';
import 'bitunix_exceptions.dart';

const String _tag = 'BitunixClient';

/// Source of monotonically-increasing-ish nonces. Injectable so tests can
/// pin a deterministic value into the signing string.
typedef NonceProvider = String Function();

/// Source of `DateTime.now().millisecondsSinceEpoch`. Injectable so tests
/// can pin a deterministic value into the signing string.
typedef TimestampProvider = int Function();

/// Bitunix Futures REST client. One instance is intended to live for the
/// lifetime of a connection session — the provider owns it and disposes
/// when the user clears credentials.
class BitunixClient {
  BitunixClient({
    required this.credentials,
    http.Client? httpClient,
    this.baseUrl = AppConstants.bitunixFuturesBaseUrl,
    this.maxRetries = 3,
    this.baseRetryDelay = const Duration(milliseconds: 500),
    NonceProvider? nonceProvider,
    TimestampProvider? timestampProvider,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _nonceProvider = nonceProvider ?? _defaultNonce,
        _timestampProvider =
            timestampProvider ?? _defaultTimestamp;

  final BitunixCredentials credentials;
  final String baseUrl;
  final int maxRetries;
  final Duration baseRetryDelay;

  final http.Client _http;
  final bool _ownsHttp;
  final NonceProvider _nonceProvider;
  final TimestampProvider _timestampProvider;

  // ─── Read-only endpoints ────────────────────────────────────────────────

  /// `GET /api/v1/futures/account?marginCoin={coin}` → first matching entry
  /// of the `data` array. Defaults to `USDT` since the app's supported
  /// symbols are all USDT-margined.
  Future<BitunixBalance> getAccountBalance({String marginCoin = 'USDT'}) async {
    final body = await _signedGet(
      path: '/api/v1/futures/account',
      query: {'marginCoin': marginCoin},
    );
    final list = _unwrapList(body);
    if (list.isEmpty) {
      AppLog.warn(_tag, 'getAccountBalance: empty data array');
      return BitunixBalance(marginCoin: marginCoin);
    }
    return BitunixBalance.fromJson(list.first as Map<String, dynamic>);
  }

  /// `GET /api/v1/futures/position/get_pending_positions` — optionally
  /// filtered by [symbol]. The doc says both `symbol` and `positionId` are
  /// optional; passing neither returns the user's full open-position list.
  Future<List<BitunixPosition>> getOpenPositions({String? symbol}) async {
    final body = await _signedGet(
      path: '/api/v1/futures/position/get_pending_positions',
      query: symbol == null || symbol.isEmpty ? const {} : {'symbol': symbol},
    );
    final list = _unwrapList(body);
    return list
        .whereType<Map<String, dynamic>>()
        .map(BitunixPosition.fromJson)
        .toList();
  }

  /// `GET /api/v1/futures/trade/get_pending_orders` — optionally filtered
  /// by [symbol]. The response shape is
  /// `{code, data: {orderList: [...], total}, msg}`; we unwrap `orderList`.
  Future<List<BitunixOrder>> getOpenOrders({String? symbol}) async {
    final body = await _signedGet(
      path: '/api/v1/futures/trade/get_pending_orders',
      query: symbol == null || symbol.isEmpty ? const {} : {'symbol': symbol},
    );
    final data = _unwrapObject(body);
    final raw = data['orderList'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(BitunixOrder.fromJson)
        .toList();
  }

  // ─── Order routing (intentionally disabled) ─────────────────────────────

  /// **Disabled** until Welle B4 Step-3 ships the risk layer. Throws
  /// [LiveTradingDisabledException] on every call. The signature includes
  /// the parameters a future implementation will accept so callers compile
  /// against a stable interface, but the body has no path that actually
  /// hits the network — see `bitunix_live_disabled_test.dart` for the
  /// pinned regression test.
  Future<void> placeOrder({
    required String symbol,
    required String side,
    required String orderType,
    required double qty,
    double? price,
    double? tpPrice,
    double? slPrice,
  }) async {
    throw const LiveTradingDisabledException();
  }

  /// **Disabled** until Welle B4 Step-3 ships the risk layer. Throws
  /// [LiveTradingDisabledException].
  Future<void> cancelOrder({required String symbol, String? orderId}) async {
    throw const LiveTradingDisabledException();
  }

  // ─── Internals ──────────────────────────────────────────────────────────

  /// Build, sign, and execute a GET request. Decodes the JSON envelope
  /// `{code, data, msg}` and returns `data` on success; throws on any
  /// non-success path (network, auth, API, schema).
  Future<Object?> _signedGet({
    required String path,
    required Map<String, String> query,
  }) async {
    final attempt = await _executeWithRetry(() async {
      final nonce = _nonceProvider();
      final timestampMs = _timestampProvider();

      // Sort query params ASCII-ascending by key — required for the
      // signing string. The HTTP URL is built from the same sorted map
      // so the on-wire `?a=1&b=2` matches the signing-side `a1b2`.
      final sortedKeys = query.keys.toList()..sort();
      final qsSign = sortedKeys.map((k) => '$k${query[k]}').join();
      final url = Uri.parse('$baseUrl$path').replace(
        queryParameters: sortedKeys.isEmpty
            ? null
            : {for (final k in sortedKeys) k: query[k]!},
      );

      final sign = BitunixSigner.sign(
        nonce: nonce,
        timestampMs: timestampMs,
        apiKey: credentials.apiKey,
        queryParams: qsSign,
        body: '',
        secretKey: credentials.secret,
      );

      final response = await _http.get(
        url,
        headers: {
          'api-key': credentials.apiKey,
          'nonce': nonce,
          'timestamp': timestampMs.toString(),
          'sign': sign,
          'Content-Type': 'application/json',
          'language': 'en-US',
        },
      );

      return response;
    });

    return _decodeEnvelope(attempt);
  }

  /// Run [op] with retry + exponential backoff on transient failures
  /// (5xx, network errors). 401/403 and 4xx errors throw immediately
  /// without retry — those represent a bad request, not a flaky network.
  Future<http.Response> _executeWithRetry(
      Future<http.Response> Function() op) async {
    var attempt = 0;
    var delay = baseRetryDelay;
    while (true) {
      attempt++;
      try {
        final response = await op();
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw BitunixAuthException(
            'Bitunix rejected credentials (HTTP ${response.statusCode})',
            response.statusCode,
          );
        }
        if (response.statusCode >= 500 && attempt < maxRetries) {
          AppLog.warn(_tag,
              'HTTP ${response.statusCode} — retry $attempt/$maxRetries');
          await Future<void>.delayed(delay);
          delay *= 2;
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw BitunixApiException(
            response.statusCode,
            'Bitunix HTTP error',
            response.body,
          );
        }
        return response;
      } on BitunixAuthException {
        rethrow;
      } on BitunixApiException {
        rethrow;
      } on SocketException catch (e) {
        if (attempt >= maxRetries) {
          throw BitunixApiException(0, 'Network error: $e');
        }
        AppLog.warn(_tag,
            'Network error on attempt $attempt/$maxRetries — retrying');
        await Future<void>.delayed(delay);
        delay *= 2;
      } on http.ClientException catch (e) {
        if (attempt >= maxRetries) {
          throw BitunixApiException(0, 'HTTP client error: $e');
        }
        AppLog.warn(_tag,
            'Client error on attempt $attempt/$maxRetries — retrying');
        await Future<void>.delayed(delay);
        delay *= 2;
      } on TimeoutException catch (e) {
        if (attempt >= maxRetries) {
          throw BitunixApiException(0, 'Timeout: $e');
        }
        AppLog.warn(_tag, 'Timeout on attempt $attempt/$maxRetries — retrying');
        await Future<void>.delayed(delay);
        delay *= 2;
      }
    }
  }

  /// Decode a Bitunix `{code, data, msg}` envelope. Throws
  /// [BitunixApiException] on non-zero `code` so the read methods can
  /// rely on a happy path.
  Object? _decodeEnvelope(http.Response response) {
    Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw BitunixApiException(
        response.statusCode,
        'Malformed JSON response: $e',
        response.body,
      );
    }
    final code = envelope['code'];
    if (code is num && code.toInt() != 0) {
      final msg = envelope['msg']?.toString() ?? 'Bitunix API error';
      // Some auth failures arrive as 200 + non-zero code. Heuristic: if
      // the message hints at auth, raise the auth exception so the
      // provider can surface a single "Authentication failed" state.
      final lower = msg.toLowerCase();
      if (lower.contains('sign') ||
          lower.contains('auth') ||
          lower.contains('key') ||
          lower.contains('permission')) {
        throw BitunixAuthException('Bitunix code $code: $msg');
      }
      throw BitunixApiException(
        response.statusCode,
        'Bitunix code $code: $msg',
        response.body,
      );
    }
    return envelope['data'];
  }

  List<dynamic> _unwrapList(Object? data) {
    if (data is List) return data;
    AppLog.warn(_tag, 'Expected list, got ${data?.runtimeType}');
    return const [];
  }

  Map<String, dynamic> _unwrapObject(Object? data) {
    if (data is Map<String, dynamic>) return data;
    AppLog.warn(_tag, 'Expected object, got ${data?.runtimeType}');
    return const {};
  }

  /// Release the owned HTTP client. No-op if the constructor was passed
  /// an external client (the caller owns it).
  void dispose() {
    if (_ownsHttp) _http.close();
  }
}

// ─── Default providers ─────────────────────────────────────────────────────

final Random _rand = Random.secure();

String _defaultNonce() {
  // 32 hex chars (128 bits of entropy) — comfortably exceeds the doc's
  // "32-bit random string" hint and avoids any ambiguity over whether
  // "32-bit" meant a 32-character string or a 32-bit integer.
  final bytes = List<int>.generate(16, (_) => _rand.nextInt(256));
  return bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

int _defaultTimestamp() => DateTime.now().toUtc().millisecondsSinceEpoch;
