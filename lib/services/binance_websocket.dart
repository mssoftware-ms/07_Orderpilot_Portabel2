/// Binance Spot kline WebSocket client.
///
/// Streams `{symbol}@kline_{interval}` updates from
/// `wss://stream.binance.com:9443/ws/...`. The default `closedOnly`
/// filter (mirrors the convention used by every Binance-derived
/// backtest in this project) lets only fully-closed candles through —
/// in-flight ticks would otherwise re-trigger downstream strategies on
/// every WS heartbeat and produce signal flicker.
///
/// On disconnect the client retries with capped exponential backoff
/// (1 s → 2 s → 4 s → 8 s → 16 s). When [maxReconnectAttempts] is
/// non-null, the stream emits a terminal error after that many
/// consecutive failures — Welle B4-4 wires this to 5 from the
/// PaperTradingProvider so a structurally broken WS tips the session
/// into Error instead of looping forever.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/logging/app_log.dart';
import '../core/models/candle.dart';

/// One Binance kline update, parsed from the
/// `{e: "kline", k: {…}}` payload.
class KlineUpdate {
  /// Candle open time (Unix ms, UTC) — matches `CandleData.timestamp`.
  final int openTime;

  /// Candle close time (Unix ms, UTC).
  final int closeTime;

  /// Trading pair, uppercase (e.g. `BTCUSDT`).
  final String symbol;

  /// Candle interval as Binance label (e.g. `1m`, `5m`, `1h`).
  final String interval;

  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  /// `true` when Binance reports this candle as closed (`k.x == true`).
  final bool isClosed;

  const KlineUpdate({
    required this.openTime,
    required this.closeTime,
    required this.symbol,
    required this.interval,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.isClosed,
  });

  /// Parse a Binance WS kline event payload of shape:
  /// `{"e": "kline", "E": <ms>, "s": "BTCUSDT", "k": { "t":…, "o":…, "x":… }}`.
  factory KlineUpdate.fromBinanceJson(Map<String, dynamic> json) {
    final k = json['k'] as Map<String, dynamic>;
    return KlineUpdate(
      openTime: (k['t'] as num).toInt(),
      closeTime: (k['T'] as num).toInt(),
      symbol: k['s'] as String,
      interval: k['i'] as String,
      open: double.parse(k['o'] as String),
      high: double.parse(k['h'] as String),
      low: double.parse(k['l'] as String),
      close: double.parse(k['c'] as String),
      volume: double.parse(k['v'] as String),
      isClosed: k['x'] as bool,
    );
  }

  /// Convert to a canonical [CandleData] — same `timestamp` semantics
  /// (open-time in ms) as `CandleData.fromBinanceKline` so the
  /// rolling-window engine replay in [PaperTradingProvider] sees the
  /// same shape as a REST-fetched backtest history.
  CandleData toCandle() => CandleData(
        timestamp: openTime,
        open: open,
        high: high,
        low: low,
        close: close,
        volume: volume,
      );

  @override
  String toString() =>
      'KlineUpdate($symbol/$interval, t=$openTime, O=$open, H=$high, '
      'L=$low, C=$close, V=$volume, closed=$isClosed)';
}

/// Connection lifecycle status exposed via [BinanceKlineStream.statusStream].
enum KlineConnectionStatus {
  /// Created, not yet [BinanceKlineStream.connect]-ed.
  idle,

  /// WS handshake in progress — first attempt of a session.
  connecting,

  /// WS connected and emitting klines.
  running,

  /// WS dropped, backoff timer is running.
  reconnecting,

  /// Disconnect-on-user — terminal until next [BinanceKlineStream.connect].
  stopped,

  /// Reconnect cap exceeded — terminal, stream sealed with an error.
  error,
}

/// Test-injectable WS factory; defaults to [WebSocketChannel.connect].
typedef KlineWsConnector = WebSocketChannel Function(Uri url);

/// A Binance Spot kline WebSocket client with capped exponential-backoff
/// reconnect.
///
/// One instance corresponds to one (symbol, interval) subscription.
/// Call [connect] to obtain the kline stream; call [disconnect] to
/// tear it down (also fired automatically when the returned stream is
/// cancelled by the last listener).
class BinanceKlineStream {
  static const String defaultBaseUrl = 'wss://stream.binance.com:9443/ws';
  static const String _tag = 'BinanceWS';

  /// Endpoint root, e.g. `wss://stream.binance.com:9443/ws`.
  /// Configurable for the test path (local HttpServer with upgrade).
  final String baseUrl;

  /// Stops reconnecting after this many consecutive failures and
  /// terminates the stream with an error. `null` = retry forever (the
  /// default; the paper-trading provider sets a finite cap).
  final int? maxReconnectAttempts;

  /// First reconnect delay; doubles each subsequent attempt until
  /// [maxRetryDelay] is reached.
  final Duration baseRetryDelay;

  /// Hard cap on the per-attempt reconnect delay.
  final Duration maxRetryDelay;

  final KlineWsConnector _connect;

  String? _symbol;
  String? _interval;
  bool _closedOnly = true;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  StreamController<KlineUpdate>? _klineCtrl;
  final StreamController<KlineConnectionStatus> _statusCtrl =
      StreamController<KlineConnectionStatus>.broadcast();
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _stopping = false;
  KlineConnectionStatus _status = KlineConnectionStatus.idle;

  BinanceKlineStream({
    String? baseUrl,
    this.maxReconnectAttempts,
    this.baseRetryDelay = const Duration(seconds: 1),
    this.maxRetryDelay = const Duration(seconds: 16),
    KlineWsConnector? connector,
  })  : baseUrl = baseUrl ?? defaultBaseUrl,
        _connect = connector ?? WebSocketChannel.connect;

  /// Current connection status.
  KlineConnectionStatus get status => _status;

  /// Broadcast stream of status transitions. Hot — late subscribers
  /// miss earlier events; observe [status] for the latest value.
  Stream<KlineConnectionStatus> get statusStream => _statusCtrl.stream;

  /// Consecutive failed connect attempts since the last successful
  /// connect. Resets to 0 once the WS is back to [KlineConnectionStatus.running].
  int get reconnectAttempts => _reconnectAttempts;

  /// `true` when the stream is closed (either never connected, or
  /// after [disconnect] / max-reconnect-error).
  bool get isClosed => _klineCtrl == null || _klineCtrl!.isClosed;

  /// Open the WS for `{symbol}@kline_{interval}` and return the kline
  /// stream. The instance is single-subscription per session —
  /// calling [connect] twice without an intervening [disconnect]
  /// throws [StateError]. The returned stream auto-disconnects when
  /// its last listener cancels.
  Stream<KlineUpdate> connect({
    required String symbol,
    required String interval,
    bool closedOnly = true,
  }) {
    if (_klineCtrl != null && !_klineCtrl!.isClosed) {
      throw StateError(
        'BinanceKlineStream is already connected; call disconnect() first',
      );
    }
    _symbol = symbol.toLowerCase();
    _interval = interval;
    _closedOnly = closedOnly;
    _reconnectAttempts = 0;
    _stopping = false;
    final ctrl = StreamController<KlineUpdate>(
      onCancel: () async {
        await disconnect();
      },
    );
    _klineCtrl = ctrl;
    // Schedule the actual connect on the microtask queue so the
    // caller receives the stream first and can attach a listener
    // before any kline is emitted.
    scheduleMicrotask(_openChannel);
    return ctrl.stream;
  }

  /// Tear down the active WS and seal the stream. Idempotent.
  Future<void> disconnect() async {
    if (_klineCtrl == null && _wsSub == null && _channel == null) {
      _stopping = true;
      return;
    }
    _stopping = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final sub = _wsSub;
    _wsSub = null;
    await sub?.cancel();
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        await ch.sink.close(ws_status.normalClosure);
      } catch (_) {
        // best-effort
      }
    }
    final ctrl = _klineCtrl;
    _klineCtrl = null;
    if (ctrl != null && !ctrl.isClosed) {
      await ctrl.close();
    }
    _setStatus(KlineConnectionStatus.stopped);
  }

  /// Release the status broadcast controller. Call exactly once when
  /// the [BinanceKlineStream] instance is permanently retired (e.g.
  /// from PaperTradingProvider.dispose). After [dispose], the
  /// instance must not be re-[connect]-ed.
  Future<void> dispose() async {
    await disconnect();
    if (!_statusCtrl.isClosed) {
      await _statusCtrl.close();
    }
  }

  // ─── Internals ──────────────────────────────────────────────────────

  void _openChannel() async {
    if (_stopping || _klineCtrl == null || _klineCtrl!.isClosed) return;
    _setStatus(_reconnectAttempts > 0
        ? KlineConnectionStatus.reconnecting
        : KlineConnectionStatus.connecting);
    final uri = Uri.parse('$baseUrl/${_symbol!}@kline_${_interval!}');
    try {
      final channel = _connect(uri);
      _channel = channel;
      // `ready` resolves when the WS handshake completes. On 3.x this
      // is a Future<void> that throws on connect failure.
      await channel.ready;
      if (_stopping) {
        // disconnect() raced ahead of the handshake; bail cleanly.
        try {
          await channel.sink.close(ws_status.normalClosure);
        } catch (_) {}
        return;
      }
      _reconnectAttempts = 0;
      _setStatus(KlineConnectionStatus.running);
      _wsSub = channel.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
    } catch (e, st) {
      AppLog.warn(_tag,
          'WS connect failed for ${_symbol ?? "?"}/${_interval ?? "?"}: $e', e, st);
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic data) {
    final ctrl = _klineCtrl;
    if (ctrl == null || ctrl.isClosed) return;
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['e'] != 'kline') return;
      final update = KlineUpdate.fromBinanceJson(decoded);
      if (_closedOnly && !update.isClosed) return;
      ctrl.add(update);
    } catch (e, st) {
      AppLog.warn(_tag, 'Failed to parse kline payload: $e', e, st);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    AppLog.warn(_tag, 'WS error: $error', error, stackTrace);
    // onDone will fire after onError for a hard-closed WS; let the
    // backoff scheduler take over there to avoid double-scheduling.
  }

  void _onDone() {
    if (_stopping) return;
    AppLog.warn(_tag,
        'WS closed unexpectedly for ${_symbol ?? "?"}/${_interval ?? "?"}; scheduling reconnect');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopping) return;
    final ctrl = _klineCtrl;
    if (ctrl == null || ctrl.isClosed) return;

    // Drop the dead WS before retrying so we don't accumulate
    // listeners across reconnect cycles.
    _wsSub?.cancel();
    _wsSub = null;
    _channel = null;
    _reconnectTimer?.cancel();

    _reconnectAttempts++;
    if (maxReconnectAttempts != null &&
        _reconnectAttempts > maxReconnectAttempts!) {
      AppLog.error(
        _tag,
        'Max reconnect attempts ($maxReconnectAttempts) exceeded for '
        '${_symbol ?? "?"}/${_interval ?? "?"}',
      );
      _setStatus(KlineConnectionStatus.error);
      ctrl.addError(
        StateError('BinanceKlineStream: max reconnect attempts exceeded'),
      );
      ctrl.close();
      _klineCtrl = null;
      return;
    }

    // 1 × baseDelay, then doubled per attempt, capped at maxRetryDelay.
    final shift = (_reconnectAttempts - 1).clamp(0, 30);
    final attemptedMs = baseRetryDelay.inMilliseconds * (1 << shift);
    final delayMs = math.min(attemptedMs, maxRetryDelay.inMilliseconds);
    final delay = Duration(milliseconds: delayMs);
    _setStatus(KlineConnectionStatus.reconnecting);
    _reconnectTimer = Timer(delay, _openChannel);
  }

  void _setStatus(KlineConnectionStatus next) {
    if (_status == next) return;
    _status = next;
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(next);
    }
  }
}
