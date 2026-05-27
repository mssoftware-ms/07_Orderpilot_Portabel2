/// Paper-trading session orchestrator — Welle B4-2.
///
/// One [PaperTradingProvider] owns at most one active session: it opens
/// a [BinanceKlineStream] for the configured `{symbol, timeframe}`,
/// appends each closed-candle tick to a 500-candle ring buffer, and
/// re-runs the active strategy through [BacktestService] every tick.
/// The session's open position and recent closed trades are derived
/// from the last engine result (the engine's `End of Data` force-close
/// is the sentinel for "still open"). See [PaperPosition] and
/// [PaperSession] for the data shape.
///
/// Reconnect-cap, symbol/timeframe whitelist and per-tick latency
/// guards are layered on by Welle B4-4 + B4-5.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/logging/app_log.dart';
import '../../core/models/timeframe.dart';
import '../../features/backtest/backtest_provider.dart';
import '../../services/backtest_service.dart';
import '../../services/binance_websocket.dart';
import 'paper_position.dart';
import 'paper_session.dart';

/// Test-injectable factory for the WS client. Default constructs a
/// fresh [BinanceKlineStream] per `start()`.
typedef BinanceKlineStreamFactory = BinanceKlineStream Function();

/// Cap on the rolling-window engine replay buffer. 500 closed 1-minute
/// candles ≈ 8 h — enough for any default-period strategy in this
/// project (BB(200)+swing(20) needs 220-bar warm-up). At 1m the engine
/// runs once per minute; on a typical dev laptop the BB+RSI replay on
/// 500 candles is ~2 ms (probe in Welle B4-2 pre-check).
const int kPaperBufferCap = 500;

/// Tag used for log entries emitted from this provider.
const String _tag = 'PaperTrading';

/// Hard cap on consecutive failed WS reconnect attempts before the
/// session tips into [PaperSessionStatus.error]. Wired into the
/// default [BinanceKlineStream] factory; 5 mirrors the cap requested
/// in the Welle B4-4 brief and stops an unbounded backoff loop when
/// the WS endpoint is structurally unavailable (e.g. wrong symbol,
/// blocked port, DNS poisoned).
const int kPaperMaxReconnectAttempts = 5;

/// Subset of Binance's kline-interval whitelist that this app accepts
/// in step-1. Mirrors the (kline)-doc list at
/// `https://developers.binance.com/docs/binance-spot-api-docs/web-socket-streams#kline-candlestick-streams`,
/// trimmed to the timeframes the project's strategy defaults actually
/// produce trades on (1s / 1M would compile but produce noisy or
/// stale signals respectively).
const Set<String> kPaperSupportedTimeframes = {
  '1m',
  '3m',
  '5m',
  '15m',
  '30m',
  '1h',
  '2h',
  '4h',
  '1d',
  '1w',
};

class PaperTradingProvider extends ChangeNotifier {
  PaperTradingProvider({BinanceKlineStreamFactory? streamFactory})
      : _streamFactory = streamFactory ??
            (() => BinanceKlineStream(
                  maxReconnectAttempts: kPaperMaxReconnectAttempts,
                ));

  final BinanceKlineStreamFactory _streamFactory;

  PaperSessionStatus _status = PaperSessionStatus.idle;
  PaperSession? _session;
  String? _errorMessage;

  /// Config that "Sync from Backtest" stored — applied by the next
  /// [start] when no explicit config is passed. Null until the user
  /// hits the sync button at least once.
  PaperConfig? _pendingConfig;

  // Active WS plumbing — cleared in [stop] / [dispose].
  BinanceKlineStream? _stream;
  StreamSubscription<KlineUpdate>? _klineSub;
  StreamSubscription<KlineConnectionStatus>? _wsStatusSub;

  // ─── Getters ────────────────────────────────────────────────────────

  PaperSessionStatus get status => _status;
  PaperSession? get session => _session;
  PaperConfig? get pendingConfig => _pendingConfig;
  String? get errorMessage => _errorMessage;
  int get reconnectAttempts => _stream?.reconnectAttempts ?? 0;

  bool get isActive =>
      _status == PaperSessionStatus.connecting ||
      _status == PaperSessionStatus.running ||
      _status == PaperSessionStatus.reconnecting;

  // ─── Lifecycle ──────────────────────────────────────────────────────

  /// Start a new session. If [config] is omitted the provider falls
  /// back to (a) the last "Sync from Backtest" config, then (b) the
  /// default starter config. Calling `start` while already active is
  /// a no-op so a double-click on the Start button doesn't tear down
  /// the running session.
  Future<void> start({PaperConfig? config}) async {
    if (isActive) {
      AppLog.warn(_tag, 'start() ignored — session already active');
      return;
    }
    final effective =
        config ?? _pendingConfig ?? PaperConfig.defaults();
    await _hardReset();
    final now = DateTime.now().millisecondsSinceEpoch;
    _session = PaperSession(config: effective, startedAtMs: now);
    _errorMessage = null;

    // Welle B4-4: gate on the symbol/timeframe whitelists before the
    // WS handshake so a typo'd config does not waste a network round
    // trip and surfaces as a session-level error instead of a deep
    // Binance 1100 ("Illegal characters") message buried in AppLog.
    final validation = _validateConfig(effective);
    if (validation != null) {
      _errorMessage = validation;
      AppLog.error(_tag, validation);
      _setStatus(PaperSessionStatus.error);
      return;
    }

    _setStatus(PaperSessionStatus.connecting);

    final stream = _streamFactory();
    _stream = stream;
    final Stream<KlineUpdate> klineStream;
    try {
      klineStream = stream.connect(
        symbol: effective.symbol,
        interval: effective.timeframe,
      );
    } catch (e, st) {
      AppLog.error(_tag, 'WS connect failed: $e', e, st);
      _errorMessage = 'WS connect failed: $e';
      _setStatus(PaperSessionStatus.error);
      return;
    }
    _klineSub = klineStream.listen(
      _onTick,
      onError: _onStreamError,
      onDone: _onStreamDone,
      cancelOnError: false,
    );
    _wsStatusSub = stream.statusStream.listen(_onWsStatusChange);
  }

  /// Stop the active session cleanly. Idempotent.
  Future<void> stop() async {
    if (_status == PaperSessionStatus.idle ||
        _status == PaperSessionStatus.stopped) {
      return;
    }
    await _tearDownStream();
    _setStatus(PaperSessionStatus.stopped);
  }

  /// Mirror a backtest config into the paper-session pending config.
  /// Does not start a session — the user still has to hit "Start".
  void syncFromBacktest(BacktestConfig source) {
    _pendingConfig = PaperConfig.fromBacktestConfig(source);
    notifyListeners();
  }

  @override
  void dispose() {
    // Fire-and-forget: ChangeNotifier.dispose is synchronous, but
    // the WS teardown is async. We MUST cancel subscriptions
    // synchronously here to avoid the "ChangeNotifier was disposed"
    // assertion firing on a late notifyListeners from an in-flight
    // tick. The Future itself is intentionally unawaited.
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

  // ─── WS event handlers ──────────────────────────────────────────────

  void _onTick(KlineUpdate update) {
    final session = _session;
    if (session == null) return;

    // 1. Append candle to ring buffer (trim oldest beyond cap).
    session.candleBuffer.add(update.toCandle());
    while (session.candleBuffer.length > kPaperBufferCap) {
      session.candleBuffer.removeAt(0);
    }
    session.tickCount += 1;

    // 2. Replay the active strategy on the buffer. Engine failures on
    //    a single tick must NOT kill the session — log and continue.
    final BacktestResult result;
    try {
      result = runEngineForBuffer(session);
    } catch (e, st) {
      AppLog.error(_tag,
          'Engine replay failed at tick ${session.tickCount}: $e', e, st);
      notifyListeners();
      return;
    }

    // 3. Absorb result into session state.
    _absorbResult(session, result);
    notifyListeners();
  }

  /// Public for testability — override in tests to inject engine
  /// failures or stubbed results.
  @visibleForTesting
  BacktestResult runEngineForBuffer(PaperSession session) {
    final tf = _timeframeFromLabel(session.config.timeframe);
    switch (session.config.strategyKind) {
      case StrategyKind.bbRsi:
        return BacktestService.runBbRsi(
          candles: session.candleBuffer,
          initialBalance: session.config.initialBalance,
          feeRate: session.config.feeRate,
          params: session.config.strategyParams as BbRsiParams,
          timeframe: tf,
        );
      case StrategyKind.utBot:
        return BacktestService.runUtBot(
          candles: session.candleBuffer,
          initialBalance: session.config.initialBalance,
          feeRate: session.config.feeRate,
          params: session.config.strategyParams as UtBotParams,
          timeframe: tf,
        );
      case StrategyKind.ichimoku:
        return BacktestService.runIchimoku(
          candles: session.candleBuffer,
          initialBalance: session.config.initialBalance,
          feeRate: session.config.feeRate,
          params: session.config.strategyParams as IchimokuParams,
          timeframe: tf,
        );
    }
  }

  void _absorbResult(PaperSession session, BacktestResult result) {
    if (result.trades.isEmpty) {
      session.closedTrades = const [];
      session.openPosition = null;
    } else {
      final last = result.trades.last;
      final stillOpen = last.exitReason == 'End of Data';
      if (stillOpen) {
        session.closedTrades =
            result.trades.sublist(0, result.trades.length - 1);
        session.openPosition = PaperPosition(
          direction: last.direction,
          entryPrice: last.entryPrice,
          quantity: last.quantity,
          openedAt: last.entryTimestamp,
        );
      } else {
        session.closedTrades = List.of(result.trades);
        session.openPosition = null;
      }
    }
    session.equityCurve = result.equityCurve;
    session.equity = result.equityCurve.isNotEmpty
        ? result.equityCurve.last.equity
        : session.config.initialBalance;
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    AppLog.error(_tag, 'WS stream error: $error', error, stackTrace);
    _errorMessage = error.toString();
    _setStatus(PaperSessionStatus.error);
  }

  void _onStreamDone() {
    // Engine emits done when the stream is sealed (either by user
    // stop() or by the max-reconnect cap in BinanceKlineStream).
    if (_status == PaperSessionStatus.error ||
        _status == PaperSessionStatus.stopped) {
      return;
    }
    _setStatus(PaperSessionStatus.stopped);
  }

  void _onWsStatusChange(KlineConnectionStatus wsStatus) {
    switch (wsStatus) {
      case KlineConnectionStatus.connecting:
        _setStatus(PaperSessionStatus.connecting);
      case KlineConnectionStatus.running:
        _setStatus(PaperSessionStatus.running);
      case KlineConnectionStatus.reconnecting:
        _setStatus(PaperSessionStatus.reconnecting);
      case KlineConnectionStatus.error:
        _errorMessage ??= 'WS reconnect cap exceeded';
        _setStatus(PaperSessionStatus.error);
      case KlineConnectionStatus.stopped:
        _setStatus(PaperSessionStatus.stopped);
      case KlineConnectionStatus.idle:
        // Pre-connect snapshot; ignore.
        break;
    }
  }

  // ─── Internals ──────────────────────────────────────────────────────

  void _setStatus(PaperSessionStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }

  Future<void> _tearDownStream() async {
    final sub = _klineSub;
    _klineSub = null;
    await sub?.cancel();
    final wsSub = _wsStatusSub;
    _wsStatusSub = null;
    await wsSub?.cancel();
    final stream = _stream;
    _stream = null;
    await stream?.dispose();
  }

  /// Wipe all session and stream state so a fresh `start()` cannot
  /// leak the previous session's listeners or in-flight position.
  Future<void> _hardReset() async {
    await _tearDownStream();
    _session = null;
    _errorMessage = null;
    // status reset is the caller's responsibility; start() drives it.
  }

  /// Validate the config against the project's symbol whitelist and
  /// the Binance WS interval whitelist. Returns the error message on
  /// failure, null on success.
  String? _validateConfig(PaperConfig cfg) {
    if (!AppConstants.supportedSymbols.contains(cfg.symbol)) {
      return 'Unsupported symbol "${cfg.symbol}". '
          'Allowed: ${AppConstants.supportedSymbols.join(", ")}';
    }
    if (!kPaperSupportedTimeframes.contains(cfg.timeframe)) {
      return 'Unsupported timeframe "${cfg.timeframe}". '
          'Allowed: ${kPaperSupportedTimeframes.join(", ")}';
    }
    return null;
  }
}

/// Map a Binance interval label (`1m`, `5m`, …) to the closest
/// [Timeframe] the backtest engine understands. Unknown labels fall
/// back to `h1` so Sharpe annualization stays defined — Welle B4-4
/// adds a strict whitelist on top of this so the session never
/// silently picks the wrong annualization factor.
Timeframe _timeframeFromLabel(String label) {
  switch (label) {
    case '1m':
      return Timeframe.m1;
    case '5m':
      return Timeframe.m5;
    case '15m':
      return Timeframe.m15;
    case '30m':
      return Timeframe.m30;
    case '1h':
      return Timeframe.h1;
    case '4h':
      return Timeframe.h4;
    case '1d':
      return Timeframe.d1;
    case '1w':
      return Timeframe.w1;
    default:
      return Timeframe.h1;
  }
}
