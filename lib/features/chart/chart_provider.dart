/// Chart-tab orchestrator — Welle P4C-2.
///
/// One [ChartProvider] owns the live data backing the Chart screen:
/// an active `(symbol, timeframe)` selection, a 500-candle ring buffer
/// fed by a [BinanceKlineStream] (with closed-only filter, mirroring
/// the paper-trading convention), and the matching Bollinger Bands +
/// RSI series computed via the P4C-1 helpers in `indicators.dart` so
/// the chart-rendered indicators stay 1e-9 with the engine-computed
/// signals.
///
/// State changes — symbol switch, timeframe switch, indicator
/// reparametrisation — are coordinated so the WS subscription is torn
/// down before a new one is opened and the buffer is reset before the
/// REST backfill completes. Tests inject fakes for both the WS and the
/// REST hook via constructor parameters.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/logging/app_log.dart';
import '../../core/models/candle.dart';
import '../../services/binance_api_client.dart';
import '../../services/binance_websocket.dart';
import '../../services/indicators.dart';

/// Tag used for log entries emitted from this provider.
const String _tag = 'Chart';

/// Cap on the chart ring buffer. 500 closed candles ≈ 8 h at 1m and
/// 20 d at 1h — comfortably enough warm-up for any indicator the chart
/// renders by default (BB period 20, RSI period 14).
const int kChartBufferCap = 500;

/// Connection-lifecycle status surfaced to the chart screen.
enum ChartStatus {
  /// Created, no symbol/timeframe loaded yet.
  idle,

  /// REST backfill or WS handshake in progress.
  loading,

  /// WS connected and emitting closed candles.
  live,

  /// WS dropped, backoff timer is running.
  reconnecting,

  /// REST failure or terminal WS error — no further updates without a
  /// fresh [ChartProvider.load] call.
  error,
}

/// Test-injectable factory for the WS client. Default constructs a
/// fresh [BinanceKlineStream] per stream attach so a symbol/timeframe
/// switch tears the old one down and opens a clean replacement.
typedef ChartWsFactory = BinanceKlineStream Function();

/// Test-injectable REST hook for the initial backfill. Defaults to a
/// one-shot [BinanceApiClient] `fetchHistoricalKlines` call against the
/// configured `limit`. Test doubles script the response without
/// touching the network.
typedef ChartRestFn = Future<List<CandleData>> Function({
  required String symbol,
  required String interval,
  required int limit,
});

class ChartProvider extends ChangeNotifier {
  ChartProvider({
    String symbol = 'BTCUSDT',
    String timeframe = '1h',
    int bbPeriod = AppConstants.defaultBBPeriod,
    double bbStdDev = AppConstants.defaultBBStdDev,
    int rsiPeriod = AppConstants.defaultRSIPeriod,
    ChartWsFactory? wsFactory,
    ChartRestFn? restFn,
  })  : _symbol = symbol, // ignore: prefer_initializing_formals
        _timeframe = timeframe, // ignore: prefer_initializing_formals
        _bbPeriod = bbPeriod, // ignore: prefer_initializing_formals
        _bbStdDev = bbStdDev, // ignore: prefer_initializing_formals
        _rsiPeriod = rsiPeriod, // ignore: prefer_initializing_formals
        _wsFactory = wsFactory ?? (() => BinanceKlineStream()),
        _restFn = restFn ?? _defaultRestFn;

  final ChartWsFactory _wsFactory;
  final ChartRestFn _restFn;

  String _symbol;
  String _timeframe;
  int _bbPeriod;
  double _bbStdDev;
  int _rsiPeriod;

  final List<CandleData> _candles = [];
  BollingerBands? _bb;
  List<double>? _rsi;

  ChartStatus _status = ChartStatus.idle;
  String? _errorMessage;

  BinanceKlineStream? _stream;
  StreamSubscription<KlineUpdate>? _klineSub;
  StreamSubscription<KlineConnectionStatus>? _wsStatusSub;

  /// Monotonic counter incremented on every (re)load. Async REST
  /// completions check their snapshot against the live counter before
  /// touching state so a rapid symbol-switch can't have an in-flight
  /// stale response clobber the new buffer.
  int _loadGeneration = 0;

  bool _disposed = false;

  // ─── Getters ────────────────────────────────────────────────────────

  String get symbol => _symbol;
  String get timeframe => _timeframe;
  int get bbPeriod => _bbPeriod;
  double get bbStdDev => _bbStdDev;
  int get rsiPeriod => _rsiPeriod;

  List<CandleData> get candles => List.unmodifiable(_candles);
  BollingerBands? get bb => _bb;
  List<double>? get rsi => _rsi;

  ChartStatus get status => _status;
  String? get errorMessage => _errorMessage;

  bool get isActive =>
      _status == ChartStatus.loading ||
      _status == ChartStatus.live ||
      _status == ChartStatus.reconnecting;

  // ─── Lifecycle ──────────────────────────────────────────────────────

  /// Start (or restart) the chart pipeline. Tears down any existing
  /// stream, swaps the symbol/timeframe selection, runs the REST
  /// backfill, recomputes indicators, then attaches a fresh WS.
  ///
  /// Tolerant against rapid re-entry: a second `load()` while the first
  /// is in flight bumps the generation counter and the older REST
  /// response is discarded before it can write to state.
  Future<void> load({String? symbol, String? timeframe}) async {
    if (_disposed) return;
    if (symbol != null) _symbol = symbol;
    if (timeframe != null) _timeframe = timeframe;

    final gen = ++_loadGeneration;
    await _detachStream();
    _candles.clear();
    _bb = null;
    _rsi = null;
    _errorMessage = null;
    _setStatus(ChartStatus.loading);

    final List<CandleData> backfill;
    try {
      backfill = await _restFn(
        symbol: _symbol,
        interval: _timeframe,
        limit: kChartBufferCap,
      );
    } catch (e, st) {
      if (gen != _loadGeneration || _disposed) return;
      AppLog.error(_tag, 'REST backfill failed: $e', e, st);
      _errorMessage = 'REST backfill failed: $e';
      _setStatus(ChartStatus.error);
      return;
    }

    if (gen != _loadGeneration || _disposed) return;

    _candles
      ..clear()
      ..addAll(backfill);
    while (_candles.length > kChartBufferCap) {
      _candles.removeAt(0);
    }
    _recomputeIndicators();

    try {
      await _attachStream();
    } catch (e, st) {
      if (gen != _loadGeneration || _disposed) return;
      AppLog.error(_tag, 'WS connect failed: $e', e, st);
      _errorMessage = 'WS connect failed: $e';
      _setStatus(ChartStatus.error);
      return;
    }

    if (gen != _loadGeneration || _disposed) return;
    _setStatus(ChartStatus.live);
  }

  /// Swap the active symbol. No-op when the new value equals the
  /// current one. Restarts the stream on a real change.
  Future<void> setSymbol(String value) async {
    if (value == _symbol) return;
    await load(symbol: value);
  }

  /// Swap the active timeframe. No-op when the new value equals the
  /// current one. Restarts the stream on a real change.
  Future<void> setTimeframe(String value) async {
    if (value == _timeframe) return;
    await load(timeframe: value);
  }

  /// Reparametrise the indicators without touching the WS subscription
  /// or the buffer — pure recompute on the existing closes. Only the
  /// non-null arguments are applied; passing `null` keeps the current
  /// value. Notifies once after the recompute.
  void setIndicatorParams({int? bbPeriod, double? bbStdDev, int? rsiPeriod}) {
    var changed = false;
    if (bbPeriod != null && bbPeriod != _bbPeriod) {
      _bbPeriod = bbPeriod;
      changed = true;
    }
    if (bbStdDev != null && bbStdDev != _bbStdDev) {
      _bbStdDev = bbStdDev;
      changed = true;
    }
    if (rsiPeriod != null && rsiPeriod != _rsiPeriod) {
      _rsiPeriod = rsiPeriod;
      changed = true;
    }
    if (!changed) return;
    _recomputeIndicators();
    notifyListeners();
  }

  @override
  void dispose() {
    // Mirror PaperTradingProvider.dispose: cancel subs synchronously to
    // avoid the "ChangeNotifier was disposed" assertion firing on a
    // late notifyListeners from an in-flight tick, then fire-and-forget
    // the async WS teardown.
    _disposed = true;
    final sub = _klineSub;
    _klineSub = null;
    final statusSub = _wsStatusSub;
    _wsStatusSub = null;
    sub?.cancel();
    statusSub?.cancel();
    final stream = _stream;
    _stream = null;
    stream?.dispose();
    super.dispose();
  }

  // ─── Internals ──────────────────────────────────────────────────────

  Future<void> _attachStream() async {
    final stream = _wsFactory();
    _stream = stream;
    final klineStream = stream.connect(
      symbol: _symbol,
      interval: _timeframe,
    );
    _klineSub = klineStream.listen(
      _onKline,
      onError: _onStreamError,
      onDone: _onStreamDone,
      cancelOnError: false,
    );
    _wsStatusSub = stream.statusStream.listen(_onWsStatusChange);
  }

  Future<void> _detachStream() async {
    final sub = _klineSub;
    _klineSub = null;
    await sub?.cancel();
    final statusSub = _wsStatusSub;
    _wsStatusSub = null;
    await statusSub?.cancel();
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      await stream.dispose();
    }
  }

  void _onKline(KlineUpdate update) {
    if (_disposed) return;
    _candles.add(update.toCandle());
    while (_candles.length > kChartBufferCap) {
      _candles.removeAt(0);
    }
    _recomputeIndicators();
    if (_status != ChartStatus.live) {
      _setStatus(ChartStatus.live);
    } else {
      notifyListeners();
    }
  }

  void _onWsStatusChange(KlineConnectionStatus s) {
    if (_disposed) return;
    switch (s) {
      case KlineConnectionStatus.idle:
      case KlineConnectionStatus.connecting:
        // The provider's own status drives the UI during the initial
        // handshake (already `loading` from load()); leave it alone so
        // a stale `connecting` event after `live` doesn't blink the
        // pill back.
        break;
      case KlineConnectionStatus.running:
        _setStatus(ChartStatus.live);
      case KlineConnectionStatus.reconnecting:
        AppLog.warn(_tag,
            'WS reconnecting for $_symbol/$_timeframe '
            '(attempts=${_stream?.reconnectAttempts ?? 0})');
        _setStatus(ChartStatus.reconnecting);
      case KlineConnectionStatus.stopped:
        // Stopped fires from our own _detachStream — don't churn the
        // UI status; load() will flip it back to loading/live.
        break;
      case KlineConnectionStatus.error:
        _errorMessage = 'WS stream errored';
        _setStatus(ChartStatus.error);
    }
  }

  void _onStreamError(Object error, StackTrace st) {
    if (_disposed) return;
    AppLog.warn(_tag, 'WS error: $error', error, st);
  }

  void _onStreamDone() {
    if (_disposed) return;
    // BinanceKlineStream.maxReconnectAttempts == null by default → the
    // stream never auto-closes on transient drops; if onDone fires it
    // means the controller was explicitly disposed (which we already
    // handle elsewhere). Nothing to do here.
  }

  void _recomputeIndicators() {
    if (_candles.isEmpty) {
      _bb = null;
      _rsi = null;
      return;
    }
    final closes = [for (final c in _candles) c.close];
    _bb = calcBollingerBands(closes, _bbPeriod, _bbStdDev, BbBasis.sma);
    _rsi = calcRsi(closes, _rsiPeriod);
  }

  void _setStatus(ChartStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }
}

/// Default REST hook: one-shot [BinanceApiClient.fetchHistoricalKlines].
/// Mirrors the PaperTradingProvider convenience of constructing the
/// client lazily so the chart tab does not hold an HTTP client across
/// idle screens.
Future<List<CandleData>> _defaultRestFn({
  required String symbol,
  required String interval,
  required int limit,
}) async {
  final client = BinanceApiClient();
  return client.fetchHistoricalKlines(
    symbol: symbol,
    interval: interval,
    limit: limit,
  );
}
