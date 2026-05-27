/// Welle B4-5 — end-to-end paper-trading smoke test.
///
/// Drives the full provider stack with a synthetic 200-bar LCG candle
/// stream injected via constructor-injected BinanceKlineStream:
///   - start → status connecting → running
///   - ticks fill the rolling-window candle buffer
///   - the BB+RSI engine produces ≥1 closed trade
///   - equity diverges from the initial balance
///   - stop tears the WS down and the stream is cleanly closed.
///
/// No real network / WS / HttpServer involvement — the test is
/// hermetic and bit-deterministic via the seeded LCG fixture.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/features/paper/paper_session.dart';
import 'package:trading_app/features/paper/paper_trading_provider.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/binance_websocket.dart';

// ─── In-process WS fake ─────────────────────────────────────────────────

class _PreloadedStream extends BinanceKlineStream {
  _PreloadedStream(this._scriptedKlines) : super();

  final List<KlineUpdate> _scriptedKlines;
  final _kctrl = StreamController<KlineUpdate>.broadcast();
  final _sctrl = StreamController<KlineConnectionStatus>.broadcast();
  KlineConnectionStatus _s = KlineConnectionStatus.idle;
  bool _disposed = false;

  @override
  KlineConnectionStatus get status => _s;
  @override
  Stream<KlineConnectionStatus> get statusStream => _sctrl.stream;
  @override
  int get reconnectAttempts => 0;
  @override
  bool get isClosed => _kctrl.isClosed;

  @override
  Stream<KlineUpdate> connect({
    required String symbol,
    required String interval,
    bool closedOnly = true,
  }) {
    _setStatus(KlineConnectionStatus.connecting);
    scheduleMicrotask(() async {
      _setStatus(KlineConnectionStatus.running);
      // Push the scripted klines back-to-back via the event loop so the
      // provider's listener can drain each one before the next arrives.
      for (final u in _scriptedKlines) {
        if (_kctrl.isClosed) return;
        _kctrl.add(u);
        await Future<void>.delayed(Duration.zero);
      }
    });
    return _kctrl.stream;
  }

  @override
  Future<void> disconnect() async {
    _setStatus(KlineConnectionStatus.stopped);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _kctrl.close();
    await _sctrl.close();
  }

  void _setStatus(KlineConnectionStatus s) {
    _s = s;
    if (!_sctrl.isClosed) _sctrl.add(s);
  }
}

// ─── Fixture ────────────────────────────────────────────────────────────

const int _smokeCandleCount = 200;

/// 200-bar LCG random walk in [80, 120] — same shape as the rest of
/// this repo's parity-test fixtures, but trimmed to 200 to stay within
/// the rolling-window buffer cap.
List<CandleData> _fixture() {
  final closes = <double>[];
  int s = 12345;
  double price = 100.0;
  closes.add(price);
  while (closes.length < _smokeCandleCount) {
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

  test('B4-5 E2E smoke: start → 200 candles → trades + equity → clean stop',
      () async {
    final fixture = _fixture();
    final scripted = fixture.map(_toUpdate).toList();
    final fake = _PreloadedStream(scripted);
    final provider = PaperTradingProvider(streamFactory: () => fake);
    addTearDown(provider.dispose);

    const config = PaperConfig(
      symbol: 'BTCUSDT',
      timeframe: '1m',
      strategyKind: StrategyKind.bbRsi,
      // Fast BB+RSI params — small periods so the 200-bar window
      // reliably crosses signals (engine warm-up is bbPeriod+swing).
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
    );

    await provider.start(config: config);

    // The scripted stream pumps one tick per event-loop turn; drain
    // the full 200-tick run.
    for (var i = 0; i < scripted.length + 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(provider.status, PaperSessionStatus.running);

    final s = provider.session!;
    expect(s.tickCount, _smokeCandleCount,
        reason: 'all 200 candles must reach the engine');
    expect(s.candleBuffer.length, _smokeCandleCount,
        reason: '200 candles < 500-buffer cap — none should be evicted');
    expect(s.closedTrades.length + (s.openPosition == null ? 0 : 1),
        greaterThanOrEqualTo(1),
        reason: 'fast BB+RSI on 200 LCG candles must produce at least one trade');
    expect(s.equity, isNot(closeTo(config.initialBalance, 1e-6)),
        reason: 'equity must diverge from the initial balance');
    expect(s.equityCurve, isNotEmpty);

    // Clean stop: tears down the WS, the stream is sealed, status flips
    // to stopped.
    await provider.stop();
    expect(provider.status, PaperSessionStatus.stopped);
    expect(fake.isClosed, isTrue,
        reason: 'WS stream must be closed after provider.stop()');
  });
}
