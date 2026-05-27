/// Welle B4.2-5 — end-to-end Paper-Trading Step-2 smoke test.
///
/// Drives the full B4.2 stack:
///   - session start with the 5 bps Binance Spot retail default slippage
///   - 100-candle synthetic LCG WS tick stream → engine produces trades
///   - mid-session WS reconnect: status → reconnecting → running
///   - 5-candle REST gap-recovery via the injected KlineBackfillFn
///   - expect: openPosition (when present) carries non-null SL/TP from
///     the B4.2-1 OpenPositionSnapshot, the order trail captures
///     wsReconnect with the backfill count, and clean shutdown.
///
/// No real network. The WS fake mirrors the B4-5 _PreloadedStream
/// pattern; the REST hook is a script.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/features/paper/order_event.dart';
import 'package:trading_app/features/paper/paper_session.dart';
import 'package:trading_app/features/paper/paper_trading_provider.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/binance_websocket.dart';

// ─── WS fake ───────────────────────────────────────────────────────────────

class _ControllableStream extends BinanceKlineStream {
  _ControllableStream() : super();

  final _klines = StreamController<KlineUpdate>.broadcast();
  final _statusCtrl = StreamController<KlineConnectionStatus>.broadcast();
  KlineConnectionStatus _s = KlineConnectionStatus.idle;
  bool _disposed = false;

  void emitKline(KlineUpdate u) {
    if (!_klines.isClosed) _klines.add(u);
  }

  void emitStatus(KlineConnectionStatus s) {
    _s = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }

  @override
  KlineConnectionStatus get status => _s;
  @override
  Stream<KlineConnectionStatus> get statusStream => _statusCtrl.stream;
  @override
  int get reconnectAttempts => 0;
  @override
  bool get isClosed => _klines.isClosed;

  @override
  Stream<KlineUpdate> connect({
    required String symbol,
    required String interval,
    bool closedOnly = true,
  }) {
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

// ─── Fixture ───────────────────────────────────────────────────────────────

const int _wsCandleCount = 100;

/// 100-bar LCG random walk → reliably crosses BB+RSI signals on the
/// fast configuration below.
List<CandleData> _wsFixture({required int startMs}) {
  final closes = <double>[];
  int s = 31337;
  double price = 100.0;
  closes.add(price);
  while (closes.length < _wsCandleCount) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    final step = ((s % 200) - 100) / 30.0;
    price = (price + step).clamp(80.0, 120.0);
    closes.add(price);
  }
  return [
    for (int i = 0; i < closes.length; i++)
      CandleData(
        timestamp: startMs + i * 60000,
        open: closes[i] - 0.3,
        high: closes[i] + 1.2,
        low: closes[i] - 1.2,
        close: closes[i],
        volume: 1000.0 + i,
      ),
  ];
}

/// 5-bar synthetic backfill that starts strictly after the WS fixture's
/// last timestamp.
List<CandleData> _restBackfill({required int startMs}) {
  return [
    for (int i = 0; i < 5; i++)
      CandleData(
        timestamp: startMs + i * 60000,
        open: 102 + i * 0.1,
        high: 103 + i * 0.1,
        low: 101 + i * 0.1,
        close: 102.5 + i * 0.1,
        volume: 1500.0 + i,
      ),
  ];
}

KlineUpdate _toUpdate(CandleData c) => KlineUpdate(
      openTime: c.timestamp,
      closeTime: c.timestamp + 59999,
      symbol: 'BTCUSDT',
      interval: '1m',
      open: c.open,
      high: c.high,
      low: c.low,
      close: c.close,
      volume: c.volume,
      isClosed: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'B4.2-5 E2E: 5bps slippage + 100 candles + WS reconnect + 5-candle '
      'backfill + clean shutdown', () async {
    // Anchor the WS fixture timestamps far enough in the past that
    // `startMs = lastTickMs + 1` is strictly less than the test wall
    // clock — without this, the gap-recovery's startMs >= now pre-check
    // would skip the REST call. The fixture spans 99 × 1 min ≈ 1h 39m,
    // so we start 110 minutes ago and leave ~11 minutes of slack between
    // the last WS candle and the backfill window's end.
    final fixtureStartMs =
        DateTime.now().millisecondsSinceEpoch - 110 * 60 * 1000;
    final wsCandles = _wsFixture(startMs: fixtureStartMs);
    final lastWsTs = wsCandles.last.timestamp;
    final restCandles = _restBackfill(startMs: lastWsTs + 60000);

    final fake = _ControllableStream();
    final restCalls =
        <({String symbol, String interval, int startMs, int endMs})>[];
    Future<List<CandleData>> mockBackfill({
      required String symbol,
      required String interval,
      required int startMs,
      required int endMs,
    }) async {
      restCalls.add((
        symbol: symbol,
        interval: interval,
        startMs: startMs,
        endMs: endMs,
      ));
      return restCandles;
    }

    final provider = PaperTradingProvider(
      streamFactory: () => fake,
      backfillFn: mockBackfill,
    );
    addTearDown(provider.dispose);

    const config = PaperConfig(
      symbol: 'BTCUSDT',
      timeframe: '1m',
      strategyKind: StrategyKind.bbRsi,
      strategyParams: BbRsiParams(
        bbPeriod: 20,
        bbStdDev: 0.2,
        bbMaType: BbMaType.ema,
        rsiPeriod: 3,
        rsiOversold: 30.0,
        rsiOverbought: 70.0,
        swingLookbackBars: 5,
        tpRrRatio: 3.0,
        riskPerTrade: 0.02,
      ),
      initialBalance: 10000.0,
      feeRate: 0.0006,
      slippageBps: 5.0,
    );

    // 1. Start session — explicit config so slippageBps = 5 wins.
    await provider.start(config: config);
    await Future<void>.delayed(Duration.zero);
    expect(provider.status, PaperSessionStatus.running);
    expect(provider.session!.config.slippageBps, 5.0);
    // Slippage is merged into the active BbRsiParams (Welle B4.2-2).
    final paramsAfterMerge =
        provider.session!.config.strategyParams as BbRsiParams;
    expect(paramsAfterMerge.slippageBps, 5.0);

    // 2. Stream 100 WS candles into the engine.
    for (final c in wsCandles) {
      fake.emitKline(_toUpdate(c));
    }
    // Drain the broadcast queue.
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(provider.session!.tickCount, _wsCandleCount);
    expect(provider.session!.candleBuffer.length, _wsCandleCount);

    // 3-5. Simulate WS disconnect → reconnect → running. The transition
    // fires the gap-recovery against the injected mockBackfill.
    fake.emitStatus(KlineConnectionStatus.reconnecting);
    await Future<void>.delayed(Duration.zero);
    expect(provider.status, PaperSessionStatus.reconnecting);

    fake.emitStatus(KlineConnectionStatus.running);
    // gap-recovery is fire-and-forget; drain microtasks until the
    // future settles.
    for (int i = 0; i < 15; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(provider.status, PaperSessionStatus.running);

    // 6. Backfill spliced into the buffer: 100 WS + 5 REST = 105, all
    // within the 500-candle cap.
    expect(restCalls, hasLength(1),
        reason: 'gap-recovery must call the backfill hook exactly once');
    expect(restCalls.single.startMs, lastWsTs + 1);
    expect(provider.session!.candleBuffer.length, _wsCandleCount + 5);
    // tickCount tracks every candle consumed by the engine — initial 100
    // WS + 5 backfilled = 105.
    expect(provider.session!.tickCount, _wsCandleCount + 5);

    // 7. Order trail records the reconnect with the backfill count.
    final trail = provider.session!.orderTrail;
    final reconnectEvent = trail
        .lastWhere((e) => e.kind == OrderEventKind.wsReconnect,
            orElse: () => throw StateError('missing wsReconnect event'));
    expect(reconnectEvent.message, contains('backfilled 5 candle'));

    // 8. If a position is open at the end of the merged window, its
    // SL/TP must surface via the B4.2-1 OpenPositionSnapshot path.
    final pos = provider.session!.openPosition;
    if (pos != null) {
      expect(pos.slPrice, isNotNull,
          reason: 'B4.2-1: SL must be filled on the live PaperPosition');
      expect(pos.tpPrice, isNotNull,
          reason: 'B4.2-1: TP must be filled on the live PaperPosition');
      expect(pos.slPrice!.isFinite, isTrue);
      expect(pos.tpPrice!.isFinite, isTrue);
    }

    // 9. Clean shutdown.
    await provider.stop();
    expect(provider.status, PaperSessionStatus.stopped);
    expect(fake.isClosed, isTrue);
    // Final sessionStopped event landed on the trail.
    expect(
        trail.any((e) => e.kind == OrderEventKind.sessionStopped), isTrue);
  });
}
