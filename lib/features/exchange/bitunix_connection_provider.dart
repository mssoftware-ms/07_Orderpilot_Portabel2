/// Bitunix exchange connection state — Welle P4P Step-3.
///
/// One [BitunixConnectionProvider] owns the read-only sync of the Bitunix
/// futures account at a time:
///   * Credentials live in [BitunixSecretsStore] on disk and in `_credentials`
///     while the user is active. [loadStoredCredentials] reads them at
///     app start without auto-connecting; the user still has to hit
///     "Test Connection".
///   * [connect] persists the credentials, then drives a single
///     `getAccountBalance + getOpenPositions + getOpenOrders` round-trip
///     via a fresh [BitunixClient] (disposed when the call returns to
///     avoid leaking HTTP connections).
///   * [refresh] re-runs the same round-trip when [connect] has already
///     succeeded — wired into the Account-Screen "Test Connection" /
///     pull-to-refresh affordances in P4P-4.
///   * [disconnect] wipes the in-memory state but leaves the disk
///     credentials in place. [clearStoredCredentials] is the explicit
///     "forget me" path that also wipes the secure storage.
///
/// All call sites that touch the connector go through this provider, so
/// PaperTradingProvider stays cleanly isolated from any exchange-side
/// concern — the only Bitunix touchpoint in the paper-trading path is
/// the (deliberately) disabled live-trading toggle in the Account screen.
library;

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/bitunix_models.dart';
import '../../services/bitunix_auth.dart';
import '../../services/bitunix_client.dart';
import '../../services/bitunix_exceptions.dart';

const String _tag = 'BitunixConnection';

/// Status machine. Allowed transitions:
///   disconnected → connecting → connected
///   disconnected → connecting → error
///   connected    → connecting (refresh) → connected | error
///   *            → disconnected (via [disconnect] / [clearStoredCredentials])
enum BitunixConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

/// Test-injectable factory so the provider can build clients with mocked
/// HTTP. Default constructs a fresh [BitunixClient] per call and the
/// caller disposes it.
typedef BitunixClientFactory = BitunixClient Function(BitunixCredentials);

BitunixClient _defaultClientFactory(BitunixCredentials creds) =>
    BitunixClient(credentials: creds);

class BitunixConnectionProvider extends ChangeNotifier {
  BitunixConnectionProvider({
    BitunixSecretsStore? secretsStore,
    BitunixClientFactory? clientFactory,
  })  : _secretsStore = secretsStore ?? BitunixSecretsStore(),
        _clientFactory = clientFactory ?? _defaultClientFactory;

  final BitunixSecretsStore _secretsStore;
  final BitunixClientFactory _clientFactory;

  BitunixConnectionStatus _status = BitunixConnectionStatus.disconnected;
  BitunixCredentials? _credentials;
  String? _errorMessage;
  BitunixBalance? _balance;
  List<BitunixPosition> _positions = const [];
  List<BitunixOrder> _orders = const [];
  DateTime? _lastSyncAt;

  // ─── Getters ────────────────────────────────────────────────────────────

  BitunixConnectionStatus get status => _status;

  /// Whether credentials are loaded (either via [loadStoredCredentials] or
  /// [connect]) — drives the "Save first" affordance in the Account-Screen.
  bool get hasCredentials => _credentials != null;

  String? get errorMessage => _errorMessage;
  BitunixBalance? get balance => _balance;
  List<BitunixPosition> get positions => List.unmodifiable(_positions);
  List<BitunixOrder> get orders => List.unmodifiable(_orders);
  DateTime? get lastSyncAt => _lastSyncAt;

  /// **Live trading is permanently disabled** in this wave (Welle P4P).
  /// The Account-Screen reads this flag to lock the toggle off; the
  /// real enable path lands once Welle B4 Step-3 ships the risk layer.
  /// Hardcoded constant on purpose: nothing inside this provider can flip
  /// it, and no test path should be able to either.
  bool get liveTradingEnabled => false;

  // ─── Public API ─────────────────────────────────────────────────────────

  /// Pull credentials from secure storage if any are present. Does *not*
  /// auto-connect — the user still has to hit "Test Connection" so a
  /// rogue saved key cannot silently fire an authenticated request on
  /// app start.
  Future<void> loadStoredCredentials() async {
    try {
      final stored = await _secretsStore.load();
      if (stored == null) return;
      _credentials = stored;
      notifyListeners();
    } catch (e, st) {
      AppLog.error(_tag, 'Failed to load stored credentials', e, st);
    }
  }

  /// Persist [creds] to secure storage, switch the status to `connecting`,
  /// and run a single read-only round-trip. On success: status → connected
  /// with balance/positions/orders populated. On any failure: status →
  /// error with a friendly [errorMessage] (credentials stay in the store
  /// so the user can correct typos without re-entering both fields).
  Future<void> connect(BitunixCredentials creds) async {
    _credentials = creds;
    _errorMessage = null;
    _setStatus(BitunixConnectionStatus.connecting);

    try {
      await _secretsStore.save(creds);
    } catch (e, st) {
      AppLog.error(_tag, 'Failed to persist credentials', e, st);
      // Persistence failure is non-fatal — we keep the in-memory creds
      // and continue to the fetch. The user will see the missing-store
      // side-effect (creds vanish after a restart) but the current
      // session still works.
    }

    await _fetchAll(creds);
  }

  /// Re-fetch balance/positions/orders for the current credentials.
  /// No-op when no credentials are configured.
  Future<void> refresh() async {
    final creds = _credentials;
    if (creds == null) {
      AppLog.warn(_tag, 'refresh() ignored — no credentials configured');
      return;
    }
    _errorMessage = null;
    _setStatus(BitunixConnectionStatus.connecting);
    await _fetchAll(creds);
  }

  /// Wipe in-memory state but leave the credentials in secure storage.
  /// Use [clearStoredCredentials] for the explicit "forget me" path.
  Future<void> disconnect() async {
    _credentials = null;
    _balance = null;
    _positions = const [];
    _orders = const [];
    _lastSyncAt = null;
    _errorMessage = null;
    _setStatus(BitunixConnectionStatus.disconnected);
  }

  /// Wipe both the in-memory state and the on-disk credentials. The
  /// next app start sees a fresh credentials prompt.
  Future<void> clearStoredCredentials() async {
    try {
      await _secretsStore.clear();
    } catch (e, st) {
      AppLog.error(_tag, 'Failed to clear stored credentials', e, st);
    }
    await disconnect();
  }

  // ─── Internals ──────────────────────────────────────────────────────────

  Future<void> _fetchAll(BitunixCredentials creds) async {
    final client = _clientFactory(creds);
    try {
      final balance = await client.getAccountBalance();
      final positions = await client.getOpenPositions();
      final orders = await client.getOpenOrders();
      _balance = balance;
      _positions = positions;
      _orders = orders;
      _lastSyncAt = DateTime.now();
      _setStatus(BitunixConnectionStatus.connected);
    } on BitunixAuthException catch (e, st) {
      AppLog.error(_tag, 'Bitunix authentication failed: ${e.message}', e, st);
      _errorMessage = 'Authentication failed: ${e.message}';
      _setStatus(BitunixConnectionStatus.error);
    } on BitunixApiException catch (e, st) {
      AppLog.error(_tag, 'Bitunix API error: ${e.message}', e, st);
      _errorMessage = 'API error: ${e.message}';
      _setStatus(BitunixConnectionStatus.error);
    } catch (e, st) {
      AppLog.error(_tag, 'Unexpected error during fetch: $e', e, st);
      _errorMessage = 'Unexpected error: $e';
      _setStatus(BitunixConnectionStatus.error);
    } finally {
      client.dispose();
    }
  }

  void _setStatus(BitunixConnectionStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }
}
