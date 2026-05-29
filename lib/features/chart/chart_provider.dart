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

/// Welle P4C-H-2 — stale-stream watchdog tuning.
///
/// Maik's smoke-test surfaced two related defects: on 1m the chart
/// never ticked (no new closed candle in two minutes), and pulling
/// the wifi for a minute neither flipped the connection pill to
/// `reconnecting` nor recovered when the wifi came back. The most
/// likely cause is a half-open TCP socket where the OS still believes
/// the connection is alive while no data flows (Windows-WSL TCP
/// keep-alive defaults to ~2 h before the dead socket is detected),
/// so [BinanceKlineStream]'s exponential-backoff machinery never
/// triggers because no `onError`/`onDone` ever fires.
///
/// The defensive fix is a per-timeframe stale-stream watchdog: every
/// [kChartStaleCheckIntervalFactor]× the timeframe interval the
/// provider checks the time-since-last-tick; once we miss
/// [kChartStaleThresholdFactor]× the interval it tears the WS down
/// and reattaches a fresh one. A [kChartReconnectCooldown] floor
/// between restart attempts prevents a flaky network from triggering
/// a reconnect storm against Binance's edge.
const double kChartStaleThresholdFactor = 2.5;
const double kChartStaleCheckIntervalFactor = 1.0;
const Duration kChartReconnectCooldown = Duration(seconds: 30);
const Duration kChartWatchdogMinTick = Duration(milliseconds: 500);
const Duration kChartWatchdogMaxTick = Duration(minutes: 5);

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
    DateTime Function()? now,
  })  : _symbol = symbol, // ignore: prefer_initializing_formals
        _timeframe = timeframe, // ignore: prefer_initializing_formals
        _bbPeriod = bbPeriod, // ignore: prefer_initializing_formals
        _bbStdDev = bbStdDev, // ignore: prefer_initializing_formals
        _rsiPeriod = rsiPeriod, // ignore: prefer_initializing_formals
        _wsFactory = wsFactory ?? (() => BinanceKlineStream()),
        _restFn = restFn ?? _defaultRestFn,
        _now = now ?? DateTime.now;

  final ChartWsFactory _wsFactory;
  final ChartRestFn _restFn;

  /// Clock hook — defaults to [DateTime.now]. Tests inject a clock
  /// driven off `FakeAsync.elapsed` so the stale-watchdog can be
  /// exercised in simulated time without a real wall-clock wait.
  final DateTime Function() _now;

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

  /// Wall-time of the last received kline. Reset at every
  /// [_attachStream] so a fresh subscription gets a full grace window
  /// before the stale-watchdog can fire on it. Null between detach
  /// and the next attach.
  DateTime? _lastTickAt;

  /// Wall-time-ms of the last stale-detection-triggered restart.
  /// Compared against [kChartReconnectCooldown] so a sustained outage
  /// can't loop-restart the WS faster than once per 30 s. Null
  /// before any stale restart has fired.
  int? _lastStaleRestartMs;

  /// Per-attach watchdog timer. Recreated on every successful
  /// [_attachStream] so a timeframe switch picks up the new interval.
  Timer? _staleWatchdog;

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
    // Stop any prior watchdog up front; it is re-armed (with the
    // possibly-new timeframe cadence) only after a successful attach.
    _stopStaleWatchdog();
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
    // Arm the stale-watchdog for the live stream. It outlives individual
    // stream restarts (see [_restartStream]) and is only torn down by the
    // next load()/setTimeframe or dispose().
    _startStaleWatchdog();
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
    _stopStaleWatchdog();
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
    // Reset the stale-watchdog clock so the fresh subscription gets a
    // full grace window before the watchdog can decide it's dead. The
    // watchdog timer itself is owned by load()/[_startStaleWatchdog] so a
    // stale-restart can reattach without killing the watchdog.
    _lastTickAt = _now();
  }

  Future<void> _detachStream() async {
    final sub = _klineSub;
    _klineSub = null;
    final statusSub = _wsStatusSub;
    _wsStatusSub = null;
    final stream = _stream;
    _stream = null;
    // Fire-and-forget the cancels + dispose, mirroring [dispose]: the
    // refs are already dropped so no further event reaches the provider,
    // and a fresh attach must not block on the OS socket close. Awaiting
    // a broadcast `StreamSubscription.cancel()` also never resolves under
    // `FakeAsync`, which would otherwise deadlock the watchdog restart
    // both in tests and — more importantly — never re-arm a real reconnect.
    sub?.cancel();
    statusSub?.cancel();
    stream?.dispose();
  }

  void _onKline(KlineUpdate update) {
    if (_disposed) return;
    _lastTickAt = _now();
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

  /// Welle P4C-H-2: start a periodic watchdog that compares the
  /// wall-time since the last kline against
  /// [kChartStaleThresholdFactor]× the timeframe interval. Armed by
  /// [load] after the stream goes live and kept running across
  /// stale-restarts so a failed reattach still gets retried on the next
  /// tick; a timeframe switch re-runs [load] and rebuilds the timer with
  /// the new cadence.
  void _startStaleWatchdog() {
    _stopStaleWatchdog();
    if (_disposed) return;
    final tickEvery = _watchdogTickInterval(_timeframe);
    _staleWatchdog = Timer.periodic(tickEvery, (_) => _evaluateStale());
  }

  void _stopStaleWatchdog() {
    _staleWatchdog?.cancel();
    _staleWatchdog = null;
  }

  /// Watchdog callback — runs at every check interval and tears the
  /// stream down if no kline has arrived within
  /// [kChartStaleThresholdFactor]× the timeframe interval.
  /// Self-cooldown via [kChartReconnectCooldown] prevents a sustained
  /// outage from looping the restart faster than once per 30 s.
  void _evaluateStale() {
    if (_disposed) return;
    final tickAt = _lastTickAt;
    if (tickAt == null) return;
    final intervalMs = _timeframeToMs(_timeframe);
    final nowDt = _now();
    final elapsedMs = nowDt.difference(tickAt).inMilliseconds;
    final thresholdMs = (intervalMs * kChartStaleThresholdFactor).round();
    if (elapsedMs < thresholdMs) return;

    final nowMs = nowDt.millisecondsSinceEpoch;
    final lastRestart = _lastStaleRestartMs;
    if (lastRestart != null &&
        nowMs - lastRestart < kChartReconnectCooldown.inMilliseconds) {
      return;
    }
    _lastStaleRestartMs = nowMs;
    AppLog.warn(
      _tag,
      'Stale stream detected for $_symbol/$_timeframe '
      '(no tick for ${elapsedMs}ms ≥ ${thresholdMs}ms) — restarting WS',
    );
    if (_status != ChartStatus.reconnecting) {
      _setStatus(ChartStatus.reconnecting);
    }
    unawaited(_restartStream());
  }

  /// Tear down the current WS without re-running the REST backfill,
  /// then attach a fresh one. Used by the stale-watchdog when the
  /// existing subscription has gone silent — a full [load] would
  /// pummel the REST endpoint on every reconnect attempt.
  Future<void> _restartStream() async {
    if (_disposed) return;
    try {
      await _detachStream();
    } catch (e, st) {
      AppLog.warn(_tag, 'Detach during stale-restart failed: $e', e, st);
    }
    if (_disposed) return;
    try {
      await _attachStream();
    } catch (e, st) {
      AppLog.warn(_tag, 'Reattach during stale-restart failed: $e', e, st);
      // Keep the pill on `reconnecting` so the next watchdog tick
      // (after the cooldown floor) takes another shot.
    }
  }

  /// Pick a watchdog poll interval bounded to a sensible range. Tied
  /// to the timeframe so 1m polls every minute (cheap) and 1d polls
  /// at the kChartWatchdogMaxTick floor (so the daily chart still
  /// notices a half-day outage without waking the timer every day).
  Duration _watchdogTickInterval(String timeframe) {
    final intervalMs = _timeframeToMs(timeframe);
    final scaledMs = (intervalMs * kChartStaleCheckIntervalFactor).round();
    if (scaledMs < kChartWatchdogMinTick.inMilliseconds) {
      return kChartWatchdogMinTick;
    }
    if (scaledMs > kChartWatchdogMaxTick.inMilliseconds) {
      return kChartWatchdogMaxTick;
    }
    return Duration(milliseconds: scaledMs);
  }

  /// Convert a Binance timeframe label to its candle duration in ms.
  /// Falls back to 1 m on a malformed label so the watchdog can't
  /// divide-by-zero its way into a tight loop.
  static int _timeframeToMs(String timeframe) {
    final match = RegExp(r'^(\d+)([smhdwM])$').firstMatch(timeframe);
    if (match == null) return 60 * 1000;
    final value = int.tryParse(match.group(1)!) ?? 1;
    switch (match.group(2)!) {
      case 's':
        return value * 1000;
      case 'm':
        return value * 60 * 1000;
      case 'h':
        return value * 60 * 60 * 1000;
      case 'd':
        return value * 24 * 60 * 60 * 1000;
      case 'w':
        return value * 7 * 24 * 60 * 60 * 1000;
      case 'M':
        return value * 30 * 24 * 60 * 60 * 1000;
      default:
        return 60 * 1000;
    }
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
