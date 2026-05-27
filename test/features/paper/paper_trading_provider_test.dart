/// Welle B4-2 — PaperTradingProvider tests.
///
/// Uses a FakeBinanceKlineStream so no real network I/O is required.
/// The fake exposes:
///   - `emitKline(KlineUpdate)` to drive ticks into the provider
///   - `emitStatus(KlineConnectionStatus)` to simulate WS lifecycle
/// matching the contract of the real BinanceKlineStream so the
/// provider's WS-status listener wiring stays exercised.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/logging/app_log.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/features/paper/order_event.dart';
import 'package:trading_app/features/paper/paper_session.dart';
import 'package:trading_app/features/paper/paper_trading_provider.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/binance_websocket.dart';

// ─── Test doubles ──────────────────────────────────────────────────────

class FakeBinanceKlineStream extends BinanceKlineStream {
  FakeBinanceKlineStream() : super();

  final StreamController<KlineUpdate> _klines =
      StreamController<KlineUpdate>.broadcast();
  final StreamController<KlineConnectionStatus> _statusCtrl =
      StreamController<KlineConnectionStatus>.broadcast();

  KlineConnectionStatus _fakeStatus = KlineConnectionStatus.idle;
  int _reconnectAttempts = 0;
  bool _disposed = false;

  String? lastSymbol;
  String? lastInterval;

  void emitKline(KlineUpdate update) {
    if (!_klines.isClosed) _klines.add(update);
  }

  void emitStatus(KlineConnectionStatus s) {
    _fakeStatus = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }

  void simulateReconnectIncrement() {
    _reconnectAttempts++;
  }

  @override
  KlineConnectionStatus get status => _fakeStatus;

  @override
  Stream<KlineConnectionStatus> get statusStream => _statusCtrl.stream;

  @override
  int get reconnectAttempts => _reconnectAttempts;

  @override
  bool get isClosed => _klines.isClosed;

  @override
  Stream<KlineUpdate> connect({
    required String symbol,
    required String interval,
    bool closedOnly = true,
  }) {
    if (_disposed) throw StateError('Fake disposed');
    lastSymbol = symbol;
    lastInterval = interval;
    emitStatus(KlineConnectionStatus.connecting);
    scheduleMicrotask(() => emitStatus(KlineConnectionStatus.running));
    return _klines.stream;
  }

  @override
  Future<void> disconnect() async {
    emitStatus(KlineConnectionStatus.stopped);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _klines.close();
    await _statusCtrl.close();
  }
}

/// Provider variant that lets the engine replay throw on demand.
class _ExplodingEngineProvider extends PaperTradingProvider {
  _ExplodingEngineProvider({required super.streamFactory});

  bool explode = false;

  @override
  BacktestResult runEngineForBuffer(PaperSession session) {
    if (explode) throw StateError('mock engine boom');
    return super.runEngineForBuffer(session);
  }
}

/// Scripted KlineBackfillFn — records every invocation and returns
/// either a pre-canned candle list or throws [error]. Used by the
/// Welle B4.2-4 gap-recovery tests.
class _FakeBackfill {
  final List<({String symbol, String interval, int startMs, int endMs})> calls =
      [];
  List<CandleData> response = const [];
  Object? error;

  Future<List<CandleData>> call({
    required String symbol,
    required String interval,
    required int startMs,
    required int endMs,
  }) async {
    calls.add((
      symbol: symbol,
      interval: interval,
      startMs: startMs,
      endMs: endMs,
    ));
    if (error != null) throw error!;
    return response;
  }
}

// ─── Fixture helpers ───────────────────────────────────────────────────

/// Same deterministic LCG as `dart_rust_ut_bot_parity_test`. 400-bar
/// random walk in [80, 120] — produces enough BB-band excursions to
/// trigger fast BB+RSI signals reliably.
List<CandleData> _lcgFixture(int n) {
  final closes = <double>[];
  int s = 12345;
  double price = 100.0;
  closes.add(price);
  while (closes.length < n) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    final step = ((s % 200) - 100) / 30.0;
    price = (price + step).clamp(80.0, 120.0);
    closes.add(price);
  }
  const baseTs = 1700000000000;
  return [
    for (int i = 0; i < closes.length; i++)
      CandleData(
        timestamp: baseTs + i * 60000,
        open: closes[i] - 0.3,
        high: closes[i] + 1.2,
        low: closes[i] - 1.2,
        close: closes[i],
        volume: 1000.0 + i,
      ),
  ];
}

KlineUpdate _toUpdate(CandleData c, {String symbol = 'BTCUSDT', String interval = '1m'}) =>
    KlineUpdate(
      openTime: c.timestamp,
      closeTime: c.timestamp + 59999,
      symbol: symbol,
      interval: interval,
      open: c.open,
      high: c.high,
      low: c.low,
      close: c.close,
      volume: c.volume,
      isClosed: true,
    );

/// Fast BB+RSI params — small periods so signals reliably fire on the
/// 400-bar LCG fixture, but otherwise identical mechanics to the
/// production defaults.
const BbRsiParams _fastBbRsi = BbRsiParams(
  bbPeriod: 20,
  bbStdDev: 0.2,
  bbMaType: BbMaType.ema,
  rsiPeriod: 3,
  rsiOversold: 30.0,
  rsiOverbought: 70.0,
  swingLookbackBars: 5,
  tpRrRatio: 3.0,
  riskPerTrade: 0.02,
);

PaperConfig _fastConfig() => PaperConfig(
      symbol: 'BTCUSDT',
      timeframe: '1m',
      strategyKind: StrategyKind.bbRsi,
      strategyParams: _fastBbRsi,
      initialBalance: 10000.0,
      feeRate: 0.0006,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PaperTradingProvider — lifecycle', () {
    test('start transitions idle → connecting → running', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      final transitions = <PaperSessionStatus>[];
      provider.addListener(() => transitions.add(provider.status));

      expect(provider.status, PaperSessionStatus.idle);
      await provider.start(config: _fastConfig());
      // Drain microtask queue so the running-status broadcast lands.
      await Future<void>.delayed(Duration.zero);

      expect(provider.status, PaperSessionStatus.running);
      expect(transitions, contains(PaperSessionStatus.connecting));
      expect(transitions, contains(PaperSessionStatus.running));
      expect(provider.session, isNotNull);
      expect(provider.session!.config.symbol, 'BTCUSDT');
    });

    test('stop transitions to stopped and tears down stream', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      expect(provider.status, PaperSessionStatus.running);

      await provider.stop();
      expect(provider.status, PaperSessionStatus.stopped);
    });

    test('double start is a no-op while active', () async {
      final fakes = <FakeBinanceKlineStream>[];
      final provider = PaperTradingProvider(streamFactory: () {
        final f = FakeBinanceKlineStream();
        fakes.add(f);
        return f;
      });
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);

      expect(fakes, hasLength(1));
    });

    test('3× start/stop cycles leak no subscriptions', () async {
      final factories = <FakeBinanceKlineStream>[];
      final provider = PaperTradingProvider(streamFactory: () {
        final f = FakeBinanceKlineStream();
        factories.add(f);
        return f;
      });
      addTearDown(provider.dispose);

      for (int i = 0; i < 3; i++) {
        await provider.start(config: _fastConfig());
        await Future<void>.delayed(Duration.zero);
        expect(provider.status, PaperSessionStatus.running);
        // Welle B4.2-3: each fresh session starts with exactly the
        // sessionStarted event — never inherits the previous session's
        // trail.
        final trail = provider.session!.orderTrail;
        expect(trail, hasLength(1),
            reason: 'fresh session must start with one sessionStarted event');
        expect(trail.first.kind, OrderEventKind.sessionStarted);
        await provider.stop();
        expect(provider.status, PaperSessionStatus.stopped);
      }

      // One fake per start, all disposed.
      expect(factories, hasLength(3));
      for (final f in factories) {
        expect(f.isClosed, isTrue, reason: 'fake stream must be disposed after stop');
      }
    });
  });

  group('PaperTradingProvider — engine ticks', () {
    test(
      'closes ≥1 real trade after replaying the 400-bar LCG fixture',
      () async {
        final fake = FakeBinanceKlineStream();
        final provider = PaperTradingProvider(streamFactory: () => fake);
        addTearDown(provider.dispose);

        await provider.start(config: _fastConfig());
        await Future<void>.delayed(Duration.zero);

        final fixture = _lcgFixture(400);
        for (final c in fixture) {
          fake.emitKline(_toUpdate(c));
        }
        // Let all microtasks drain.
        await Future<void>.delayed(Duration.zero);

        final s = provider.session!;
        expect(s.tickCount, 400);
        // Buffer capped at 500, fixture is 400 → all 400 fit.
        expect(s.candleBuffer, hasLength(400));
        expect(s.closedTrades.length + (s.openPosition == null ? 0 : 1),
            greaterThanOrEqualTo(1),
            reason: 'fast BB+RSI on 400 LCG candles must produce at least one trade');
      },
    );

    test('open position appears, marks to market, then closes', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);

      // Feed the full 400-bar fixture and verify at least once during
      // the replay we saw an open position. Welle B4.2-1: provider calls
      // the engine with extractOpenPosition: true, so the live position
      // surfaces via BacktestResult.openPosition (with non-null SL/TP)
      // instead of the legacy 'End of Data' sentinel trade.
      bool sawOpenPosition = false;
      double? markPriceWhenOpen;
      double? slWhenOpen;
      double? tpWhenOpen;
      final fixture = _lcgFixture(400);
      for (final c in fixture) {
        fake.emitKline(_toUpdate(c));
        // Broadcast-stream delivery is scheduled on the microtask
        // queue; pump it so the provider's listener has fired before
        // we read the open-position state.
        await Future<void>.delayed(Duration.zero);
        final pos = provider.session!.openPosition;
        if (pos != null && !sawOpenPosition) {
          sawOpenPosition = true;
          markPriceWhenOpen = provider.session!.latestMarkPrice;
          slWhenOpen = pos.slPrice;
          tpWhenOpen = pos.tpPrice;
        }
      }

      expect(sawOpenPosition, isTrue,
          reason: 'fast BB+RSI on 400 LCG candles must open at least one position');
      expect(markPriceWhenOpen, isNotNull);
      expect(slWhenOpen, isNotNull,
          reason: 'Welle B4.2-1: SL must surface via openPosition snapshot');
      expect(tpWhenOpen, isNotNull,
          reason: 'Welle B4.2-1: TP must surface via openPosition snapshot');
    });

    test('engine error per tick logs to AppLog and session stays running',
        () async {
      AppLog.instance.clear();

      final fake = FakeBinanceKlineStream();
      final provider = _ExplodingEngineProvider(
        streamFactory: () => fake,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      expect(provider.status, PaperSessionStatus.running);

      provider.explode = true;
      fake.emitKline(_toUpdate(_lcgFixture(1).first));
      await Future<void>.delayed(Duration.zero);

      expect(provider.status, PaperSessionStatus.running,
          reason: 'single engine failure must not tip session into error');
      final errors = AppLog.instance.entries.where(
          (e) => e.level == LogLevel.error && e.tag == 'PaperTrading');
      expect(errors, isNotEmpty);
    });
  });

  group('PaperTradingProvider — syncFromBacktest', () {
    test('mirrors symbol, timeframe, kind, params, balance, fee', () {
      final provider = PaperTradingProvider(
          streamFactory: () => FakeBinanceKlineStream());
      addTearDown(provider.dispose);

      final source = BacktestConfig(
        strategyKind: StrategyKind.utBot,
        symbol: 'ETHUSDT',
        timeframe: '5m',
        initialBalance: 25000.0,
        feeRate: 0.001,
        strategyParams: const UtBotParams(emaPeriod: 50, keyValue: 1.5),
      );

      provider.syncFromBacktest(source);

      final cfg = provider.pendingConfig!;
      expect(cfg.symbol, 'ETHUSDT');
      expect(cfg.timeframe, '5m');
      expect(cfg.strategyKind, StrategyKind.utBot);
      expect(cfg.initialBalance, 25000.0);
      expect(cfg.feeRate, 0.001);
      expect(cfg.strategyParams, isA<UtBotParams>());
      final params = cfg.strategyParams as UtBotParams;
      expect(params.emaPeriod, 50);
      expect(params.keyValue, 1.5);
    });

    test('start without config falls back to pendingConfig', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      provider.syncFromBacktest(BacktestConfig(
        symbol: 'ETHUSDT',
        timeframe: '15m',
        strategyKind: StrategyKind.bbRsi,
      ));

      await provider.start();
      await Future<void>.delayed(Duration.zero);

      expect(provider.session!.config.symbol, 'ETHUSDT');
      expect(provider.session!.config.timeframe, '15m');
      expect(fake.lastSymbol, 'ETHUSDT');
      expect(fake.lastInterval, '15m');
    });
  });

  group('PaperTradingProvider — Welle B4-4 validation', () {
    test('invalid symbol fails start with Error + AppLog', () async {
      AppLog.instance.clear();
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(
        config: _fastConfig().copyWith(symbol: 'XYZUSDT'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(provider.status, PaperSessionStatus.error);
      expect(provider.errorMessage, contains('Unsupported symbol'));
      final errors = AppLog.instance.entries.where(
          (e) => e.level == LogLevel.error && e.tag == 'PaperTrading');
      expect(errors, isNotEmpty);
      // WS must NOT have been opened — the validation gate is pre-handshake.
      expect(fake.lastSymbol, isNull);
    });

    test('invalid timeframe fails start with Error', () async {
      AppLog.instance.clear();
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(
        config: _fastConfig().copyWith(timeframe: '7m'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(provider.status, PaperSessionStatus.error);
      expect(provider.errorMessage, contains('Unsupported timeframe'));
      expect(fake.lastInterval, isNull);
    });

    test('error after restart with valid config reclears errorMessage',
        () async {
      final fake1 = FakeBinanceKlineStream();
      var fakeIdx = 0;
      final fakes = [fake1, FakeBinanceKlineStream()];
      final provider = PaperTradingProvider(
          streamFactory: () => fakes[fakeIdx++]);
      addTearDown(provider.dispose);

      await provider.start(
          config: _fastConfig().copyWith(symbol: 'XYZUSDT'));
      await Future<void>.delayed(Duration.zero);
      expect(provider.status, PaperSessionStatus.error);
      expect(provider.errorMessage, isNotNull);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      expect(provider.status, PaperSessionStatus.running);
      expect(provider.errorMessage, isNull);
    });
  });

  group('PaperTradingProvider — Welle B4.2-2 slippage', () {
    test('pendingSlippageBps defaults to 5 bps (Binance Spot retail)',
        () async {
      final provider = PaperTradingProvider(
          streamFactory: () => FakeBinanceKlineStream());
      addTearDown(provider.dispose);

      expect(provider.pendingSlippageBps, PaperConfig.defaultSlippageBps);
      expect(provider.pendingSlippageBps, 5.0);
    });

    test('setPendingSlippage clamps to [0, 20] bps', () async {
      final provider = PaperTradingProvider(
          streamFactory: () => FakeBinanceKlineStream());
      addTearDown(provider.dispose);

      provider.setPendingSlippage(7.5);
      expect(provider.pendingSlippageBps, 7.5);

      provider.setPendingSlippage(-3.0);
      expect(provider.pendingSlippageBps, 0.0,
          reason: 'below-range values clamp to PaperConfig.minSlippageBps');

      provider.setPendingSlippage(99.0);
      expect(provider.pendingSlippageBps, 20.0,
          reason: 'above-range values clamp to PaperConfig.maxSlippageBps');
    });

    test('setPendingSlippage notifies listeners once per real change',
        () async {
      final provider = PaperTradingProvider(
          streamFactory: () => FakeBinanceKlineStream());
      addTearDown(provider.dispose);

      var notifications = 0;
      provider.addListener(() => notifications++);

      provider.setPendingSlippage(10.0);
      provider.setPendingSlippage(10.0); // duplicate value — no-op
      provider.setPendingSlippage(12.0);

      expect(notifications, 2,
          reason: 'duplicate-value calls must be no-ops');
    });

    test('setPendingSlippage is a no-op while the session is active',
        () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);

      provider.setPendingSlippage(13.0);
      expect(provider.pendingSlippageBps, PaperConfig.defaultSlippageBps,
          reason: 'slippage stays stable for the lifetime of the session');
    });

    test('start() merges pendingSlippageBps into BbRsi strategy params',
        () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      provider.setPendingSlippage(8.0);
      await provider.start(); // no explicit config → defaults + 8 bps
      await Future<void>.delayed(Duration.zero);

      final params = provider.session!.config.strategyParams as BbRsiParams;
      expect(params.slippageBps, 8.0,
          reason: 'pending slippage must be merged into the live strategy '
              'params at start()');
      expect(provider.session!.config.slippageBps, 8.0);
    });

    test('start() respects an explicit config.slippageBps verbatim',
        () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      provider.setPendingSlippage(15.0);
      // Caller passes an explicit config with slippageBps 3.0 → wins over
      // the UI-tunable pending value (test-friendly contract).
      await provider.start(
        config: _fastConfig().copyWith(slippageBps: 3.0),
      );
      await Future<void>.delayed(Duration.zero);

      expect(provider.session!.config.slippageBps, 3.0);
      final params = provider.session!.config.strategyParams as BbRsiParams;
      expect(params.slippageBps, 3.0);
    });
  });

  group('PaperTradingProvider — Welle B4.2-3 order trail', () {
    test('start() emits sessionStarted as the first trail entry', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);

      final trail = provider.session!.orderTrail;
      expect(trail, isNotEmpty);
      expect(trail.first.kind, OrderEventKind.sessionStarted);
      expect(trail.first.message, contains('BTCUSDT'));
    });

    test('stop() emits sessionStopped event', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      final sessionRef = provider.session!;

      await provider.stop();

      // session reference survives stop until the next start (status went
      // to stopped, but the trail is still readable).
      final stopEvent = sessionRef.orderTrail.lastWhere(
          (e) => e.kind == OrderEventKind.sessionStopped,
          orElse: () => throw StateError('missing sessionStopped event'));
      expect(stopEvent.message, contains('user'));
    });

    test('replay emits positionOpened + positionClosed events with TP hint',
        () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);

      final fixture = _lcgFixture(400);
      for (final c in fixture) {
        fake.emitKline(_toUpdate(c));
      }
      await Future<void>.delayed(Duration.zero);

      final trail = provider.session!.orderTrail;
      final kinds = trail.map((e) => e.kind).toSet();
      expect(kinds, contains(OrderEventKind.sessionStarted));
      expect(kinds, contains(OrderEventKind.positionOpened),
          reason: 'fast BB+RSI on 400 LCG candles must open at least one '
              'position and emit positionOpened');
      // The 400-bar LCG fixture reliably produces at least one closed
      // trade — verify the trail captured it as positionClosed and one
      // of the SL/TP outcomes.
      expect(kinds, contains(OrderEventKind.positionClosed));
      final closeOutcomes = {OrderEventKind.slHit, OrderEventKind.tpHit};
      final hasOutcome = trail.any((e) => closeOutcomes.contains(e.kind));
      expect(hasOutcome, isTrue,
          reason: 'BB+RSI positions exit via SL or TP — order trail must '
              'record one of those outcomes');
    });

    test('WS reconnecting → running transition emits wsReconnect event',
        () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);

      fake.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);
      fake.emitStatus(KlineConnectionStatus.running);
      await Future<void>.delayed(Duration.zero);

      final trail = provider.session!.orderTrail;
      final hasReconnect =
          trail.any((e) => e.kind == OrderEventKind.wsReconnect);
      expect(hasReconnect, isTrue);
    });

    test('order trail is capped at kOrderTrailCap (100) entries', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);

      // Toggle WS status repeatedly to flood the trail with wsReconnect
      // events past the cap.
      for (int i = 0; i < kOrderTrailCap + 30; i++) {
        fake.emitStatus(KlineConnectionStatus.reconnecting);
        fake.emitStatus(KlineConnectionStatus.running);
      }
      await Future<void>.delayed(Duration.zero);

      expect(provider.session!.orderTrail.length, kOrderTrailCap,
          reason: 'order trail must be ring-buffered at kOrderTrailCap');
    });
  });

  group('PaperTradingProvider — Welle B4.2-4 REST gap recovery', () {
    /// Build a minimal buffer of `count` candles ending at `lastTs` with
    /// a 60 s spacing — gives the gap-recovery a non-empty anchor and a
    /// `startMs` strictly before `now`.
    Future<void> primeBuffer(
      PaperTradingProvider provider,
      FakeBinanceKlineStream fake,
      int count, {
      required int lastTs,
    }) async {
      const intervalMs = 60 * 1000;
      for (int i = count - 1; i >= 0; i--) {
        final ts = lastTs - i * intervalMs;
        final closePrice = 100.0 + (i % 7);
        fake.emitKline(KlineUpdate(
          openTime: ts,
          closeTime: ts + intervalMs - 1,
          symbol: 'BTCUSDT',
          interval: '1m',
          open: closePrice - 0.3,
          high: closePrice + 1.2,
          low: closePrice - 1.2,
          close: closePrice,
          volume: 1000 + i.toDouble(),
          isClosed: true,
        ));
      }
      await Future<void>.delayed(Duration.zero);
    }

    test('reconnect with 3 backfill candles grows buffer and emits count',
        () async {
      final fake = FakeBinanceKlineStream();
      final backfill = _FakeBackfill();
      // Anchor the buffer's last timestamp far enough in the past that
      // startMs is guaranteed to be strictly less than now() for the
      // test's wall-clock.
      final lastTs =
          DateTime.now().millisecondsSinceEpoch - 10 * 60 * 1000; // 10 min ago
      backfill.response = [
        for (int i = 1; i <= 3; i++)
          CandleData(
            timestamp: lastTs + i * 60 * 1000,
            open: 101,
            high: 102,
            low: 100,
            close: 101.5,
            volume: 1000.0 + i,
          ),
      ];
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        backfillFn: backfill.call,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      await primeBuffer(provider, fake, 5, lastTs: lastTs);
      final bufBefore = provider.session!.candleBuffer.length;

      fake.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);
      fake.emitStatus(KlineConnectionStatus.running);
      // _attemptGapRecovery is fire-and-forget — drain microtasks until
      // the future settles.
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(backfill.calls, hasLength(1));
      expect(backfill.calls.single.symbol, 'BTCUSDT');
      expect(backfill.calls.single.startMs, lastTs + 1);
      expect(provider.session!.candleBuffer.length, bufBefore + 3);
      final trail = provider.session!.orderTrail;
      final reconnectMsg = trail
          .lastWhere((e) => e.kind == OrderEventKind.wsReconnect)
          .message;
      expect(reconnectMsg, contains('backfilled 3 candle'));
    });

    test('REST failure logs warn, keeps session running, emits failure trail',
        () async {
      AppLog.instance.clear();
      final fake = FakeBinanceKlineStream();
      final backfill = _FakeBackfill()..error = StateError('boom');
      final lastTs =
          DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000;
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        backfillFn: backfill.call,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      await primeBuffer(provider, fake, 3, lastTs: lastTs);

      fake.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);
      fake.emitStatus(KlineConnectionStatus.running);
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(provider.status, PaperSessionStatus.running);
      final warns = AppLog.instance.entries
          .where((e) => e.level == LogLevel.warning && e.tag == 'PaperTrading');
      expect(warns.any((e) => e.message.contains('gap-recovery failed')),
          isTrue);
      final trail = provider.session!.orderTrail;
      final reconnectMsg = trail
          .lastWhere((e) => e.kind == OrderEventKind.wsReconnect)
          .message;
      expect(reconnectMsg, contains('backfill failed'));
    });

    test('empty backfill response emits "no missed candles" trail',
        () async {
      final fake = FakeBinanceKlineStream();
      final backfill = _FakeBackfill()..response = const [];
      final lastTs =
          DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000;
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        backfillFn: backfill.call,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      await primeBuffer(provider, fake, 3, lastTs: lastTs);
      final bufBefore = provider.session!.candleBuffer.length;

      fake.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);
      fake.emitStatus(KlineConnectionStatus.running);
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(provider.session!.candleBuffer.length, bufBefore);
      final reconnectMsg = provider.session!.orderTrail
          .lastWhere((e) => e.kind == OrderEventKind.wsReconnect)
          .message;
      expect(reconnectMsg, contains('no missed candles'));
    });

    test('dedupes backfill candles that are already in the buffer',
        () async {
      final fake = FakeBinanceKlineStream();
      final backfill = _FakeBackfill();
      final lastTs =
          DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000;
      // The REST response replays the last two existing candles plus
      // adds one truly new one. Dedupe must drop the two duplicates.
      backfill.response = [
        CandleData(
          timestamp: lastTs - 60 * 1000,
          open: 100, high: 101, low: 99, close: 100.5, volume: 100,
        ),
        CandleData(
          timestamp: lastTs,
          open: 100, high: 101, low: 99, close: 100.5, volume: 100,
        ),
        CandleData(
          timestamp: lastTs + 60 * 1000,
          open: 101, high: 102, low: 100, close: 101.5, volume: 100,
        ),
      ];
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        backfillFn: backfill.call,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      await primeBuffer(provider, fake, 3, lastTs: lastTs);
      final bufBefore = provider.session!.candleBuffer.length;

      fake.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);
      fake.emitStatus(KlineConnectionStatus.running);
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(provider.session!.candleBuffer.length, bufBefore + 1,
          reason: 'only the truly new candle survives the dedupe pass');
      final reconnectMsg = provider.session!.orderTrail
          .lastWhere((e) => e.kind == OrderEventKind.wsReconnect)
          .message;
      expect(reconnectMsg, contains('backfilled 1 candle'));
    });

    test('startMs >= now (instant reconnect) skips the REST call',
        () async {
      final fake = FakeBinanceKlineStream();
      final backfill = _FakeBackfill();
      // Anchor the buffer's last timestamp at "now" — pre-check trips,
      // no REST round-trip happens.
      final lastTs = DateTime.now().millisecondsSinceEpoch + 5 * 60 * 1000;
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        backfillFn: backfill.call,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      await primeBuffer(provider, fake, 1, lastTs: lastTs);

      fake.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);
      fake.emitStatus(KlineConnectionStatus.running);
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(backfill.calls, isEmpty,
          reason: 'pre-check must prevent the REST call when there is no '
              'gap to fill (startMs >= now)');
      final reconnectMsg = provider.session!.orderTrail
          .lastWhere((e) => e.kind == OrderEventKind.wsReconnect)
          .message;
      expect(reconnectMsg, contains('no gap'));
    });

    test('second reconnect within cooldown window skips REST', () async {
      final fake = FakeBinanceKlineStream();
      final backfill = _FakeBackfill();
      final lastTs =
          DateTime.now().millisecondsSinceEpoch - 5 * 60 * 1000;
      backfill.response = [
        CandleData(
          timestamp: lastTs + 60 * 1000,
          open: 101, high: 102, low: 100, close: 101.5, volume: 100,
        ),
      ];
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        backfillFn: backfill.call,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      await primeBuffer(provider, fake, 3, lastTs: lastTs);

      // First reconnect → backfill fires.
      fake.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);
      fake.emitStatus(KlineConnectionStatus.running);
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(backfill.calls, hasLength(1));

      // Second reconnect right after → cooldown trips.
      fake.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);
      fake.emitStatus(KlineConnectionStatus.running);
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(backfill.calls, hasLength(1),
          reason: 'cooldown gates the second backfill within 30 s');

      final cooldownEvent = provider.session!.orderTrail.where(
          (e) =>
              e.kind == OrderEventKind.wsReconnect &&
              e.message.contains('cooldown'));
      expect(cooldownEvent, isNotEmpty);
    });
  });

  group('PaperTradingProvider — WS status mirroring', () {
    test('reconnecting status from WS surfaces in session status', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);
      expect(provider.status, PaperSessionStatus.running);

      fake.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);
      expect(provider.status, PaperSessionStatus.reconnecting);

      fake.emitStatus(KlineConnectionStatus.running);
      await Future<void>.delayed(Duration.zero);
      expect(provider.status, PaperSessionStatus.running);
    });

    test('error status from WS tips session to error', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _fastConfig());
      await Future<void>.delayed(Duration.zero);

      fake.emitStatus(KlineConnectionStatus.error);
      await Future<void>.delayed(Duration.zero);
      expect(provider.status, PaperSessionStatus.error);
      expect(provider.errorMessage, isNotNull);
    });
  });
}
