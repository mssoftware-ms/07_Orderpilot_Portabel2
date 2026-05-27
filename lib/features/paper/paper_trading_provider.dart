/// Paper-trading session orchestrator — Welle B4-2.
///
/// One [PaperTradingProvider] owns at most one active session: it opens
/// a [BinanceKlineStream] for the configured `{symbol, timeframe}`,
/// appends each closed-candle tick to a 500-candle ring buffer, and
/// re-runs the active strategy through [BacktestService] every tick.
/// The session's open position and recent closed trades are derived
/// from the last engine result: [BacktestResult.openPosition] surfaces
/// the live position (with SL/TP) when the engine is called with
/// `extractOpenPosition: true` — see Welle B4.2-1. [PaperPosition] and
/// [PaperSession] document the on-screen shape.
///
/// Reconnect-cap, symbol/timeframe whitelist and per-tick latency
/// guards are layered on by Welle B4-4 + B4-5.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/logging/app_log.dart';
import '../../core/models/candle.dart';
import '../../core/models/timeframe.dart';
import '../../features/backtest/backtest_provider.dart';
import '../../services/backtest_service.dart';
import '../../services/binance_api_client.dart';
import '../../services/binance_websocket.dart';
import '../risk/risk_assessment.dart';
import '../risk/risk_manager.dart';
import 'order_event.dart';
import 'paper_position.dart';
import 'paper_session.dart';

/// Test-injectable factory for the WS client. Default constructs a
/// fresh [BinanceKlineStream] per `start()`.
typedef BinanceKlineStreamFactory = BinanceKlineStream Function();

/// REST gap-recovery hook (Welle B4.2-4). Returns the candles in the
/// `[startMs, endMs)` window for the given `symbol` / `interval` so the
/// provider can splice the missing range into the buffer after a WS
/// reconnect. Tests inject a fake that scripts the response without
/// hitting Binance.
typedef KlineBackfillFn = Future<List<CandleData>> Function({
  required String symbol,
  required String interval,
  required int startMs,
  required int endMs,
});

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

/// Minimum spacing (ms) between REST gap-recovery calls (Welle B4.2-4).
/// Back-to-back WS reconnects within this window skip the REST round-trip
/// and lean on the next tick instead — protects against a reconnect
/// storm slamming the Binance REST endpoint.
const int kBackfillCooldownMs = 30000;

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
  PaperTradingProvider({
    BinanceKlineStreamFactory? streamFactory,
    KlineBackfillFn? backfillFn,
    RiskManager? riskManager,
  })  : _streamFactory = streamFactory ??
            (() => BinanceKlineStream(
                  maxReconnectAttempts: kPaperMaxReconnectAttempts,
                )),
        _backfillFn = backfillFn ?? _defaultBackfill,
        // ignore: prefer_initializing_formals
        _riskManager = riskManager;

  final BinanceKlineStreamFactory _streamFactory;
  final KlineBackfillFn _backfillFn;

  /// Welle B4.3-2: optional risk gate. When null (the default) the
  /// position-open path is un-gated — preserves the original B4-1/B4-2
  /// behaviour and keeps the prior test suite green without changes.
  /// Wired in production via `main.dart` so the Account-Screen sliders
  /// affect the live paper session.
  final RiskManager? _riskManager;

  /// Unix ms of the last successful REST gap-recovery — used to gate
  /// back-to-back reconnects against [kBackfillCooldownMs].
  int? _lastBackfillMs;

  PaperSessionStatus _status = PaperSessionStatus.idle;
  PaperSession? _session;
  String? _errorMessage;

  /// Config that "Sync from Backtest" stored — applied by the next
  /// [start] when no explicit config is passed. Null until the user
  /// hits the sync button at least once.
  PaperConfig? _pendingConfig;

  /// UI-tunable session slippage in basis points (Welle B4.2-2).
  /// Default 5 bps for Binance Spot retail. Applied by [start] when no
  /// explicit config is passed; explicit-config callers (tests) keep
  /// their config's own [PaperConfig.slippageBps].
  double _pendingSlippageBps = PaperConfig.defaultSlippageBps;

  // Active WS plumbing — cleared in [stop] / [dispose].
  BinanceKlineStream? _stream;
  StreamSubscription<KlineUpdate>? _klineSub;
  StreamSubscription<KlineConnectionStatus>? _wsStatusSub;

  // ─── Getters ────────────────────────────────────────────────────────

  PaperSessionStatus get status => _status;
  PaperSession? get session => _session;
  PaperConfig? get pendingConfig => _pendingConfig;
  double get pendingSlippageBps => _pendingSlippageBps;
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
    final base = config ?? _pendingConfig ?? PaperConfig.defaults();
    // Apply the UI-tunable session slippage only when no explicit config
    // was passed (test-friendly: explicit configs are honoured verbatim).
    final withSlippage = config == null
        ? base.copyWith(slippageBps: _pendingSlippageBps)
        : base;
    final mergedParams = _mergeSlippageBps(
        withSlippage.strategyParams, withSlippage.slippageBps);
    final effective = withSlippage.copyWith(strategyParams: mergedParams);
    await _hardReset();
    final now = DateTime.now().millisecondsSinceEpoch;
    _session = PaperSession(config: effective, startedAtMs: now);
    _errorMessage = null;
    _appendOrderEvent(_session!, OrderEventKind.sessionStarted,
        'Session started — ${effective.symbol} · ${effective.timeframe} · '
        '${effective.strategyKind.displayLabel}');

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
    final session = _session;
    if (session != null) {
      _appendOrderEvent(session, OrderEventKind.sessionStopped,
          'Session stopped by user');
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

  /// Set the session-level slippage that the next `start()` will apply
  /// (Welle B4.2-2). Clamped to the [PaperConfig.minSlippageBps] ..
  /// [PaperConfig.maxSlippageBps] range the UI slider exposes.
  /// No-op while a session is active so the slippage stays stable for
  /// the lifetime of the session.
  void setPendingSlippage(double bps) {
    if (isActive) return;
    final clamped = bps.clamp(
      PaperConfig.minSlippageBps,
      PaperConfig.maxSlippageBps,
    );
    if (clamped == _pendingSlippageBps) return;
    _pendingSlippageBps = clamped;
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
  ///
  /// Always passes `extractOpenPosition: true` so the engine returns the
  /// live position via [BacktestResult.openPosition] (carrying SL/TP)
  /// instead of force-closing it as an `'End of Data'` sentinel trade —
  /// see Welle B4.2-1.
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
          extractOpenPosition: true,
        );
      case StrategyKind.utBot:
        return BacktestService.runUtBot(
          candles: session.candleBuffer,
          initialBalance: session.config.initialBalance,
          feeRate: session.config.feeRate,
          params: session.config.strategyParams as UtBotParams,
          timeframe: tf,
          extractOpenPosition: true,
        );
      case StrategyKind.ichimoku:
        return BacktestService.runIchimoku(
          candles: session.candleBuffer,
          initialBalance: session.config.initialBalance,
          feeRate: session.config.feeRate,
          params: session.config.strategyParams as IchimokuParams,
          timeframe: tf,
          extractOpenPosition: true,
        );
    }
  }

  void _absorbResult(PaperSession session, BacktestResult result) {
    final prevOpen = session.openPosition;
    final prevClosedCount = session.closedTrades.length;

    // Update closed trades + equity first — those are the engine's own
    // bookkeeping and not subject to the risk gate (a position that was
    // already open and just closed must always settle).
    session.closedTrades = List.of(result.trades);
    session.equityCurve = result.equityCurve;
    session.equity = result.equityCurve.isNotEmpty
        ? result.equityCurve.last.equity
        : session.config.initialBalance;

    final snap = result.openPosition;
    final isNewlyOpened = snap != null &&
        (prevOpen == null || prevOpen.openedAt != snap.openedAt);

    // Welle B4.3-2: gate position opens through the optional risk manager.
    // The gate only applies to *new* opens — a position that was already
    // open in the previous tick is unaffected so it can close cleanly.
    if (isNewlyOpened && _riskManager != null) {
      final assessment = _riskManager.assess(session);
      if (!assessment.allGatesPass) {
        final breachLabel = _formatBreachedGates(assessment.breachedGates);
        AppLog.warn(_tag,
            'Position open blocked by risk gates: $breachLabel');
        // Keep openPosition at its previous value (typically null) so the
        // engine's would-be entry never appears in the UI.
        session.openPosition = prevOpen;
        _appendOrderEvent(
          session,
          OrderEventKind.riskBlocked,
          'Position blocked by risk gates: $breachLabel',
        );
        // Still emit close deltas — those happened before the engine
        // tried to re-enter.
        _emitClosedTradeDeltas(session, prevClosedCount: prevClosedCount);
        return;
      }
    }

    if (snap == null) {
      session.openPosition = null;
    } else {
      session.openPosition = PaperPosition(
        direction: snap.direction,
        entryPrice: snap.entryPrice,
        quantity: snap.quantity,
        openedAt: snap.openedAt,
        slPrice: snap.slPrice,
        tpPrice: snap.tpPrice,
      );
    }

    _emitTradeEvents(session, prevOpen: prevOpen, prevClosedCount: prevClosedCount);
  }

  /// Format a set of breached risk gates as a stable, sorted, comma-separated
  /// label so UI strings and AppLog lines never re-order between calls (the
  /// underlying [Set] iteration order isn't a contract — sorted is).
  String _formatBreachedGates(Set<RiskGate> gates) {
    final names = gates.map((g) => g.name).toList()..sort();
    return names.join(',');
  }

  /// Emit the [OrderEvent] deltas implied by a freshly absorbed engine
  /// result: every new closed trade becomes a `positionClosed` (plus
  /// `slHit` / `tpHit` when the exit reason matches), and a fresh open
  /// position becomes a `positionOpened`. The "fresh open" delta is
  /// detected by [PaperPosition.openedAt] so a same-tick close-then-open
  /// sequence still emits both events.
  void _emitTradeEvents(
    PaperSession session, {
    required PaperPosition? prevOpen,
    required int prevClosedCount,
  }) {
    _emitClosedTradeDeltas(session, prevClosedCount: prevClosedCount);

    final current = session.openPosition;
    final isNewlyOpened = current != null &&
        (prevOpen == null || prevOpen.openedAt != current.openedAt);
    if (isNewlyOpened) {
      _appendOrderEvent(
        session,
        OrderEventKind.positionOpened,
        '${current.direction} opened @ ${current.entryPrice.toStringAsFixed(2)}',
      );
    }
  }

  /// Emit just the closed-trade portion of the delta. Extracted from
  /// [_emitTradeEvents] so the risk-blocked path can reuse it without
  /// also firing a `positionOpened` event for the rejected entry.
  void _emitClosedTradeDeltas(
    PaperSession session, {
    required int prevClosedCount,
  }) {
    final newClosedCount = session.closedTrades.length;
    for (int i = prevClosedCount; i < newClosedCount; i++) {
      final t = session.closedTrades[i];
      final pnlSign = t.pnl >= 0 ? '+' : '';
      _appendOrderEvent(
        session,
        OrderEventKind.positionClosed,
        '${t.direction} closed @ ${t.exitPrice.toStringAsFixed(2)} '
            '($pnlSign${t.pnl.toStringAsFixed(2)}, ${t.exitReason})',
      );
      if (t.exitReason == 'StopLoss') {
        _appendOrderEvent(session, OrderEventKind.slHit,
            'SL hit @ ${t.exitPrice.toStringAsFixed(2)}');
      } else if (t.exitReason == 'TakeProfit') {
        _appendOrderEvent(session, OrderEventKind.tpHit,
            'TP hit @ ${t.exitPrice.toStringAsFixed(2)}');
      }
    }
  }

  /// Append an order-trail event to the session, trimming the head to
  /// keep the buffer at [kOrderTrailCap].
  void _appendOrderEvent(
      PaperSession session, OrderEventKind kind, String message) {
    session.orderTrail.add(OrderEvent(
      timestamp: DateTime.now(),
      kind: kind,
      message: message,
    ));
    while (session.orderTrail.length > kOrderTrailCap) {
      session.orderTrail.removeAt(0);
    }
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
    final wasReconnecting = _status == PaperSessionStatus.reconnecting;
    switch (wsStatus) {
      case KlineConnectionStatus.connecting:
        _setStatus(PaperSessionStatus.connecting);
      case KlineConnectionStatus.running:
        _setStatus(PaperSessionStatus.running);
        // After a reconnect, fire-and-forget the REST gap recovery
        // (Welle B4.2-4). The wsReconnect order event is emitted inside
        // [_attemptGapRecovery] so the message can carry the backfill
        // count (or failure / cooldown reason). New ticks racing the
        // backfill are tolerated by the sort+dedupe pass on append.
        if (wasReconnecting) {
          unawaited(_attemptGapRecovery());
        }
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

  /// Try to splice the missing candles in `[lastTickMs + 1, now)` back
  /// into the rolling buffer after a WS reconnect (Welle B4.2-4).
  ///
  /// Always emits a wsReconnect order event describing the outcome
  /// (backfilled N, no gap, no missed candles, cooldown skipped, or
  /// failure). Engine replay runs only when new candles actually
  /// arrived. REST failures degrade silently so a transient REST
  /// outage during a reconnect storm never tips the live session into
  /// the error state.
  Future<void> _attemptGapRecovery() async {
    final session = _session;
    if (session == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastBackfillMs != null &&
        now - _lastBackfillMs! < kBackfillCooldownMs) {
      _appendOrderEvent(session, OrderEventKind.wsReconnect,
          'WS reconnected (backfill on cooldown)');
      notifyListeners();
      return;
    }

    if (session.candleBuffer.isEmpty) {
      // No anchor for a startMs — wait for the next tick instead.
      _appendOrderEvent(session, OrderEventKind.wsReconnect,
          'WS reconnected (no anchor)');
      notifyListeners();
      return;
    }

    final lastTickMs = session.candleBuffer.last.timestamp;
    final startMs = lastTickMs + 1;
    if (startMs >= now) {
      // The reconnect was effectively instantaneous — no gap to fill.
      _appendOrderEvent(session, OrderEventKind.wsReconnect,
          'WS reconnected (no gap)');
      notifyListeners();
      return;
    }

    List<CandleData> backfilled;
    try {
      backfilled = await _backfillFn(
        symbol: session.config.symbol,
        interval: session.config.timeframe,
        startMs: startMs,
        endMs: now,
      );
    } catch (e, st) {
      AppLog.warn(_tag, 'REST gap-recovery failed: $e', e, st);
      _appendOrderEvent(session, OrderEventKind.wsReconnect,
          'WS reconnected (backfill failed)');
      notifyListeners();
      return;
    }
    _lastBackfillMs = now;

    // Dedupe against existing buffer + sort + cap-trim.
    final seen = session.candleBuffer.map((c) => c.timestamp).toSet();
    final unique = backfilled.where((c) => seen.add(c.timestamp)).toList();
    if (unique.isNotEmpty) {
      session.candleBuffer.addAll(unique);
      session.candleBuffer
          .sort((a, b) => a.timestamp.compareTo(b.timestamp));
      while (session.candleBuffer.length > kPaperBufferCap) {
        session.candleBuffer.removeAt(0);
      }
      session.tickCount += unique.length;
    }

    if (unique.isEmpty) {
      _appendOrderEvent(session, OrderEventKind.wsReconnect,
          'WS reconnected (no missed candles)');
      notifyListeners();
      return;
    }

    final n = unique.length;
    _appendOrderEvent(session, OrderEventKind.wsReconnect,
        'WS reconnected, backfilled $n candle${n == 1 ? '' : 's'}');
    AppLog.warn(_tag, 'Backfilled $n candles after WS reconnect');

    // Replay-tick: re-run the engine on the merged buffer so equity
    // curve / open position / closed trades catch up before the next
    // live WS tick arrives.
    try {
      final result = runEngineForBuffer(session);
      _absorbResult(session, result);
    } catch (e, st) {
      AppLog.error(_tag,
          'Engine replay failed during backfill: $e', e, st);
    }
    notifyListeners();
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

/// Default REST gap-recovery — fetches the `[startMs, endMs)` window via
/// a one-shot [BinanceApiClient]. Used when no override is injected via
/// [KlineBackfillFn] in the provider constructor (production path).
Future<List<CandleData>> _defaultBackfill({
  required String symbol,
  required String interval,
  required int startMs,
  required int endMs,
}) async {
  final client = BinanceApiClient();
  try {
    final intervalMs = _intervalLabelToMs(interval);
    final span = endMs - startMs;
    final estimate = span <= 0 ? 1 : (span ~/ intervalMs) + 1;
    final limit = estimate.clamp(1, 1000);
    return await client.fetchHistoricalKlines(
      symbol: symbol,
      interval: interval,
      startTime: startMs,
      endTime: endMs,
      limit: limit,
    );
  } finally {
    client.dispose();
  }
}

/// Map a Binance interval label to its width in milliseconds.
/// Falls back to 1 m (60 000 ms) for unknown labels so the backfill
/// limit estimate stays positive — `kPaperSupportedTimeframes` already
/// guards against fully unknown values at config-validation time.
int _intervalLabelToMs(String interval) {
  switch (interval) {
    case '1m':
      return 60 * 1000;
    case '3m':
      return 3 * 60 * 1000;
    case '5m':
      return 5 * 60 * 1000;
    case '15m':
      return 15 * 60 * 1000;
    case '30m':
      return 30 * 60 * 1000;
    case '1h':
      return 60 * 60 * 1000;
    case '2h':
      return 2 * 60 * 60 * 1000;
    case '4h':
      return 4 * 60 * 60 * 1000;
    case '1d':
      return 24 * 60 * 60 * 1000;
    case '1w':
      return 7 * 24 * 60 * 60 * 1000;
    default:
      return 60 * 1000;
  }
}

/// Re-build the given strategy params with `slippage_bps` overridden to
/// [slippageBps]. Used by [PaperTradingProvider.start] to push the
/// session-level slippage into the active strategy params (Welle B4.2-2).
/// Falls through unchanged when [params] is not one of the three known
/// strategy parameter classes — defensive future-proofing for Phase-3
/// additions.
Object _mergeSlippageBps(Object params, double slippageBps) {
  if (params is BbRsiParams) {
    final m = Map<String, double>.from(params.toMap());
    m['slippage_bps'] = slippageBps;
    return BbRsiParams.fromMap(m);
  }
  if (params is UtBotParams) {
    final m = Map<String, double>.from(params.toMap());
    m['slippage_bps'] = slippageBps;
    return UtBotParams.fromMap(m);
  }
  if (params is IchimokuParams) {
    final m = Map<String, double>.from(params.toMap());
    m['slippage_bps'] = slippageBps;
    return IchimokuParams.fromMap(m);
  }
  return params;
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
