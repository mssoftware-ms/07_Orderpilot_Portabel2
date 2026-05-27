/// Unit tests for the Bitunix Futures auth primitives — Welle P4P Step-1.
///
/// The signer side is verified against the official documentation example
/// at `https://www.bitunix.com/api-docs/futures/common/sign.html`: with the
/// inputs from the doc's Python snippet the expected hex output below was
/// reproduced in Python (`hashlib.sha256`) and again in Go (`crypto/sha256`)
/// before being pinned here. If either of these values ever drifts, every
/// authenticated request will fail with HTTP 401 and the bug will be hard
/// to track down at runtime — so we anchor the contract here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/services/bitunix_auth.dart';

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

void main() {
  group('BitunixSigner', () {
    test('reproduces the doc Python-example sign hash', () {
      // Inputs from https://www.bitunix.com/api-docs/futures/common/sign.html
      // The expected outputs were independently computed via Python
      // hashlib.sha256 and cross-checked against Go crypto/sha256.
      const nonce = '123456';
      const timestampMs = 20241120123045; // doc demo value, treated as int
      const apiKey = 'yourApiKey';
      const secret = 'yourSecretKey';
      const queryParams = 'id1uid200';
      const body =
          '{"uid":"2899","arr":[{"id":1,"name":"maple"},{"id":2,"name":"lily"}]}';

      final sign = BitunixSigner.sign(
        nonce: nonce,
        timestampMs: timestampMs,
        apiKey: apiKey,
        queryParams: queryParams,
        body: body,
        secretKey: secret,
      );

      expect(
        sign,
        '00397cd1e52c7dce3258067324363b6361fabc9178a0912b330c138db8745655',
      );
    });

    test('reproduces a known empty-body / empty-queryParams hash', () {
      // GET requests with no body and no query string still produce a
      // deterministic sign. Pinned to a value computed offline with
      // `hashlib.sha256` in CPython 3.12.
      final sign = BitunixSigner.sign(
        nonce: 'abcdef0123456789',
        timestampMs: 1716800000000,
        apiKey: 'testKey',
        queryParams: '',
        body: '',
        secretKey: 'testSecret',
      );

      expect(
        sign,
        'afc465f527384a8b58f5ecfc8f708af991cdd7a5c5985ab2eeb90491d0ee0eb7',
      );
    });

    test('stripBodyWhitespace removes spaces, tabs, newlines', () {
      const dirty = '{"a": 1,\n\t"b": "x"}';
      const clean = '{"a":1,"b":"x"}';
      expect(BitunixSigner.stripBodyWhitespace(dirty), clean);

      // A space-padded body must sign to the same hash as its stripped
      // form — proving the helper's contract matches what the Bitunix
      // doc requires ("remember to remove all spaces").
      const args = {
        'nonce': '123456',
        'timestampMs': 20241120123045,
        'apiKey': 'yourApiKey',
        'secret': 'yourSecretKey',
        'qs': '',
      };
      final stripped = BitunixSigner.stripBodyWhitespace(dirty);
      final signFromDirty = BitunixSigner.sign(
        nonce: args['nonce']! as String,
        timestampMs: args['timestampMs']! as int,
        apiKey: args['apiKey']! as String,
        queryParams: args['qs']! as String,
        body: stripped,
        secretKey: args['secret']! as String,
      );
      final signFromClean = BitunixSigner.sign(
        nonce: args['nonce']! as String,
        timestampMs: args['timestampMs']! as int,
        apiKey: args['apiKey']! as String,
        queryParams: args['qs']! as String,
        body: clean,
        secretKey: args['secret']! as String,
      );
      expect(signFromDirty, signFromClean);
    });

    test('different secret produces a different sign for identical input', () {
      final a = BitunixSigner.sign(
        nonce: 'n',
        timestampMs: 1,
        apiKey: 'k',
        queryParams: '',
        body: '',
        secretKey: 'secretA',
      );
      final b = BitunixSigner.sign(
        nonce: 'n',
        timestampMs: 1,
        apiKey: 'k',
        queryParams: '',
        body: '',
        secretKey: 'secretB',
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('BitunixCredentials', () {
    test('toString never exposes apiKey or secret', () {
      const creds = BitunixCredentials(
        apiKey: 'live-key-abcdef',
        secret: 'super-secret-xyz',
      );
      final s = creds.toString();
      expect(s, isNot(contains('live-key-abcdef')));
      expect(s, isNot(contains('super-secret-xyz')));
      // Sanity: the redacted form still identifies the class.
      expect(s, contains('BitunixCredentials'));
    });

    test('string interpolation does not leak the secret', () {
      const creds = BitunixCredentials(
        apiKey: 'live-key-abcdef',
        secret: 'super-secret-xyz',
      );
      final interpolated = 'auth failed for $creds';
      expect(interpolated, isNot(contains('live-key-abcdef')));
      expect(interpolated, isNot(contains('super-secret-xyz')));
    });

    test('equality is value-based for store-roundtrip assertions', () {
      const a = BitunixCredentials(apiKey: 'k', secret: 's');
      const b = BitunixCredentials(apiKey: 'k', secret: 's');
      const c = BitunixCredentials(apiKey: 'k', secret: 'different');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('isEmpty flags missing apiKey or secret', () {
      expect(const BitunixCredentials(apiKey: '', secret: 's').isEmpty, isTrue);
      expect(const BitunixCredentials(apiKey: 'k', secret: '').isEmpty, isTrue);
      expect(
          const BitunixCredentials(apiKey: 'k', secret: 's').isEmpty, isFalse);
    });
  });

  group('BitunixSecretsStore', () {
    test('save then load returns the same credentials', () async {
      final store = BitunixSecretsStore(backend: _InMemoryBackend());
      const creds = BitunixCredentials(apiKey: 'abc123', secret: 'xyz789');

      await store.save(creds);
      final loaded = await store.load();

      expect(loaded, equals(creds));
    });

    test('load on an empty backend returns null', () async {
      final store = BitunixSecretsStore(backend: _InMemoryBackend());
      expect(await store.load(), isNull);
    });

    test('clear removes the stored credentials', () async {
      final store = BitunixSecretsStore(backend: _InMemoryBackend());
      await store.save(const BitunixCredentials(apiKey: 'a', secret: 'b'));
      expect(await store.load(), isNotNull);

      await store.clear();
      expect(await store.load(), isNull);
    });

    test('partial state (only apiKey) loads as null', () async {
      final backend = _InMemoryBackend();
      await backend.write(key: 'bitunix.apiKey', value: 'orphaned-key');
      // secret intentionally not written

      final store = BitunixSecretsStore(backend: backend);
      expect(await store.load(), isNull);
    });

    test('empty-string values are treated as absent', () async {
      final backend = _InMemoryBackend();
      await backend.write(key: 'bitunix.apiKey', value: 'k');
      await backend.write(key: 'bitunix.secret', value: '');

      final store = BitunixSecretsStore(backend: backend);
      expect(await store.load(), isNull);
    });

    test('save overwrites a previously stored credential pair', () async {
      final store = BitunixSecretsStore(backend: _InMemoryBackend());
      await store.save(const BitunixCredentials(apiKey: 'k1', secret: 's1'));
      await store.save(const BitunixCredentials(apiKey: 'k2', secret: 's2'));

      final loaded = await store.load();
      expect(loaded, const BitunixCredentials(apiKey: 'k2', secret: 's2'));
    });
  });
}
