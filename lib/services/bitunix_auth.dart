/// Bitunix Futures API authentication primitives — Welle P4P (Phase-4-Prep)
/// Step-1.
///
/// Three responsibilities:
///   * [BitunixCredentials] holds the API key + secret as an immutable pair.
///     `toString` and the redacted error-formatter strip the values so a
///     stray `print(creds)` or `AppLog.error('$creds')` cannot leak them.
///   * [BitunixSigner.sign] reproduces the double-SHA-256 algorithm
///     documented at `https://www.bitunix.com/api-docs/futures/common/sign.html`:
///     `digest = SHA256(nonce + timestamp + apiKey + queryParams + body)` →
///     hex string, then `sign = SHA256(digest + secretKey)` → hex string.
///     Body whitespace MUST be stripped by the caller (signing string must
///     be byte-identical to the request body). The provided
///     [BitunixSigner.stripBodyWhitespace] helper enforces that.
///   * [BitunixSecretsStore] wraps `flutter_secure_storage` to persist the
///     credentials on platform-secure key stores (DPAPI on Windows, Keychain
///     on macOS/iOS, libsecret on Linux, Android Keystore-backed storage on
///     Android). A [BitunixSecretsBackend] hook keeps the store
///     unit-testable without spinning up the native plugin.
///
/// No live order routing lives here — see [bitunix_client.dart] for the
/// REST surface, which intentionally throws on `placeOrder` / `cancelOrder`
/// until Welle B4 Step-3 lands the risk layer.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// ─── Credentials ────────────────────────────────────────────────────────────

/// Immutable API-key + secret pair.
///
/// Both values are `final` and `private` field-typed `String`; the only way
/// to read them is via [apiKey] / [secret]. [toString] returns a redacted
/// placeholder so a stray log line cannot leak them. Equality and hashCode
/// use the values so a test can assert "store roundtrip preserved both
/// fields" without exposing the values to a failure-message renderer.
class BitunixCredentials {
  final String apiKey;
  final String secret;

  const BitunixCredentials({required this.apiKey, required this.secret});

  bool get isEmpty => apiKey.isEmpty || secret.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is BitunixCredentials &&
      other.apiKey == apiKey &&
      other.secret == secret;

  @override
  int get hashCode => Object.hash(apiKey, secret);

  /// Redacted — the values never appear in `toString` output so a stray
  /// `print(creds)` or `AppLog.error('failed for $creds')` cannot leak
  /// the secret.
  @override
  String toString() => 'BitunixCredentials(apiKey: ***, secret: ***)';
}

// ─── Signer ─────────────────────────────────────────────────────────────────

/// Double-SHA-256 signer matching the Bitunix Futures spec.
///
/// All methods are `static` — there is no state to keep. The signer is a
/// pure function over the request fields; the caller is responsible for
/// generating a fresh [nonce] per request and a monotonically increasing
/// [timestampMs] within the documented ±60 s drift window.
class BitunixSigner {
  BitunixSigner._();

  /// Compute the Bitunix `sign` header value for a single request.
  ///
  /// Concatenation order (per the official doc, verified against the Python
  /// + Go reference implementations):
  ///   `digestInput = nonce + timestampMs + apiKey + queryParams + body`
  ///   `digest      = sha256_hex(digestInput)`
  ///   `signInput   = digest + secretKey`
  ///   `sign        = sha256_hex(signInput)`
  ///
  /// [queryParams] must be the ASCII-ascending-sorted `key1value1key2value2`
  /// concatenation that the doc requires; pass `''` for endpoints without
  /// query parameters. [body] must already have whitespace stripped — use
  /// [stripBodyWhitespace] if the caller serializes JSON via `jsonEncode`.
  static String sign({
    required String nonce,
    required int timestampMs,
    required String apiKey,
    required String queryParams,
    required String body,
    required String secretKey,
  }) {
    final digestInput = '$nonce$timestampMs$apiKey$queryParams$body';
    final digest = _sha256Hex(digestInput);
    return _sha256Hex('$digest$secretKey');
  }

  /// Strip every whitespace character (space, tab, newline, CR) from the
  /// supplied JSON body. The Bitunix doc requires the signing string to be
  /// byte-identical to the request body; the only safe way to guarantee
  /// that is to remove whitespace on both sides.
  static String stripBodyWhitespace(String body) =>
      body.replaceAll(RegExp(r'\s+'), '');

  static String _sha256Hex(String input) =>
      sha256.convert(utf8.encode(input)).toString();
}

// ─── Secrets store ──────────────────────────────────────────────────────────

/// Pluggable backend so the store can be exercised in pure-Dart unit tests
/// without spinning up the `flutter_secure_storage` native plugin.
abstract class BitunixSecretsBackend {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
}

class _FlutterSecureStorageBackend implements BitunixSecretsBackend {
  _FlutterSecureStorageBackend(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}

/// Wraps the platform-secure storage with a credentials-aware API. The
/// store keeps two keys (`bitunix.apiKey` + `bitunix.secret`); a partial
/// state (one key set, the other missing) loads as `null` so a corrupted
/// install does not surface as half-broken auth attempts.
class BitunixSecretsStore {
  /// Storage keys are namespaced to avoid collisions with other features
  /// that may share the same secure-storage bucket on the host platform.
  static const String _apiKeyName = 'bitunix.apiKey';
  static const String _secretName = 'bitunix.secret';

  BitunixSecretsStore({BitunixSecretsBackend? backend})
      : _backend = backend ??
            _FlutterSecureStorageBackend(const FlutterSecureStorage());

  final BitunixSecretsBackend _backend;

  /// Persist [creds]. Overwrites any previously-stored values atomically
  /// from the caller's perspective; the two writes are sequenced so the
  /// secret is written first to avoid a partial state where the apiKey is
  /// present without its secret.
  Future<void> save(BitunixCredentials creds) async {
    await _backend.write(key: _secretName, value: creds.secret);
    await _backend.write(key: _apiKeyName, value: creds.apiKey);
  }

  /// Returns the stored credentials, or `null` if either key is missing
  /// or empty (treated as no credentials configured).
  Future<BitunixCredentials?> load() async {
    final apiKey = await _backend.read(key: _apiKeyName);
    final secret = await _backend.read(key: _secretName);
    if (apiKey == null || secret == null) return null;
    if (apiKey.isEmpty || secret.isEmpty) return null;
    return BitunixCredentials(apiKey: apiKey, secret: secret);
  }

  /// Wipe both keys. Subsequent [load] calls return `null`.
  Future<void> clear() async {
    await _backend.delete(key: _apiKeyName);
    await _backend.delete(key: _secretName);
  }
}
