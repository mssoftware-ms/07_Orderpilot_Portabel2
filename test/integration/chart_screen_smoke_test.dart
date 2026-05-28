/// Welle P4C-5 — Chart pipeline end-to-end smoke.
///
/// Drives the full ChartProvider lifecycle with mocks: REST backfill,
/// WS attach, per-tick indicator recompute, symbol switch, clean
/// dispose. Provider ↔ widget wiring is covered by
/// `test/ui/screens/chart_screen_test.dart`; this file walks the
/// async chain end-to-end without involving the widget tree (which
/// kept `pumpAndSettle` spinning on the broadcast stream listeners
/// from the WS-status subscription).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/features/chart/chart_provider.dart';
import 'package:trading_app/services/binance_websocket.dart';

class _FakeBinanceKlineStream extends BinanceKlineStream {
  _FakeBinanceKlineStream() : super();

  final StreamController<KlineUpdate> _klines =
      StreamController<KlineUpdate>.broadcast();
  final StreamController<KlineConnectionStatus> _statusCtrl =
      StreamController<KlineConnectionStatus>.broadcast();
  bool _disposed = false;

  String? lastSymbol;
  String? lastInterval;

  void emitKline(KlineUpdate u) {
    if (!_klines.isClosed) _klines.add(u);
  }

  @override
  Stream<KlineConnectionStatus> get statusStream => _statusCtrl.stream;

  @override
  bool get isClosed => _klines.isClosed;

  @override
  Stream<KlineUpdate> connect({
    required String symbol,
    required String interval,
    bool closedOnly = true,
  }) {
    if (_disposed) throw StateError('disposed');
    lastSymbol = symbol;
    lastInterval = interval;
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(KlineConnectionStatus.connecting);
      _statusCtrl.add(KlineConnectionStatus.running);
    }
    return _klines.stream;
  }

  @override
  Future<void> disconnect() async {
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(KlineConnectionStatus.stopped);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _klines.close();
    await _statusCtrl.close();
  }
}

List<CandleData> _backfill(int count, {double start = 100.0}) => [
      for (int i = 0; i < count; i++)
        CandleData(
          timestamp: i * 60_000,
          open: start + i,
          high: start + i + 1,
          low: start + i - 1,
          close: start + i + 0.5,
          volume: 1,
        ),
    ];

KlineUpdate _kline(int ts, double close) => KlineUpdate(
      openTime: ts,
      closeTime: ts + 60_000,
      symbol: 'BTCUSDT',
      interval: '1h',
      open: close,
      high: close + 1,
      low: close - 1,
      close: close,
      volume: 1.0,
      isClosed: true,
    );

void main() {
  test(
    'full chart pipeline: REST backfill → WS attach → tick → '
    'symbol switch → dispose',
    () async {
      final streams = <_FakeBinanceKlineStream>[];

      var restCalls = 0;
      Future<List<CandleData>> restFn({
        required String symbol,
        required String interval,
        required int limit,
      }) async {
        restCalls++;
        return _backfill(100,
            start: symbol == 'BTCUSDT' ? 100.0 : 500.0);
      }

      final provider = ChartProvider(
        wsFactory: () {
          final s = _FakeBinanceKlineStream();
          streams.add(s);
          return s;
        },
        restFn: restFn,
      );

      // ── Step 1: initial REST backfill + WS attach.
      await provider.load();

      expect(restCalls, 1);
      expect(provider.candles.length, 100);
      expect(streams.length, 1);
      expect(streams.first.lastSymbol, 'BTCUSDT');
      expect(streams.first.lastInterval, '1h');
      expect(provider.status, ChartStatus.live);
      expect(provider.bb, isNotNull,
          reason: 'BB(20) populated on a 100-candle buffer');
      expect(provider.rsi, isNotNull,
          reason: 'RSI(14) populated on a 100-candle buffer');

      // ── Step 2: five closed-candle ticks → buffer grows, indicators
      // recompute on each tick.
      final preBb = provider.bb!.middle.last;
      for (int i = 0; i < 5; i++) {
        streams.first.emitKline(_kline(1000 * 60_000 + i, 200.0 + i));
        await Future<void>.delayed(Duration.zero);
      }
      expect(provider.candles.length, 105);
      expect(provider.candles.last.close, 204.0);
      expect(provider.bb!.middle.last, isNot(preBb),
          reason: 'BB middle must shift after non-trivial close changes');

      // ── Step 3: symbol switch — fires a new REST + WS attach, old
      // stream gets disconnected.
      await provider.setSymbol('ETHUSDT');

      expect(provider.symbol, 'ETHUSDT');
      expect(restCalls, 2);
      expect(streams.length, 2);
      expect(streams.last.lastSymbol, 'ETHUSDT');
      expect(streams.first.isClosed, isTrue,
          reason: 'prior WS must be torn down on symbol switch');
      expect(provider.candles.length, 100,
          reason: 'buffer reset to fresh REST backfill on symbol switch');
      expect(provider.candles.first.close, 500.5,
          reason: 'new backfill used the ETHUSDT base price');

      // ── Step 4: dispose. The dispose cancels the subscription
      // synchronously, so a late tick must not throw the
      // "ChangeNotifier was disposed" assertion.
      provider.dispose();
      streams.last.emitKline(_kline(9999, 999.0));
      await Future<void>.delayed(Duration.zero);
      // Reaching here without an exception is the assertion.
    },
  );
}
