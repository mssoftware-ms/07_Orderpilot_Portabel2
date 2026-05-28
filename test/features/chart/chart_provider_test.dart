/// Welle P4C-2 — ChartProvider tests.
///
/// Drives the provider through a `FakeBinanceKlineStream` and a
/// scripted REST hook so no real network I/O runs. Mirrors the
/// PaperTradingProvider test setup (`test/features/paper/...`) to
/// keep the WS-status listener wiring exercised on the chart side too.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/features/chart/chart_provider.dart';
import 'package:trading_app/services/binance_websocket.dart';

// ─── Test doubles ──────────────────────────────────────────────────────

class FakeBinanceKlineStream extends BinanceKlineStream {
  FakeBinanceKlineStream() : super();

  final StreamController<KlineUpdate> _klines =
      StreamController<KlineUpdate>.broadcast();
  final StreamController<KlineConnectionStatus> _statusCtrl =
      StreamController<KlineConnectionStatus>.broadcast();

  KlineConnectionStatus _fakeStatus = KlineConnectionStatus.idle;
  final int _reconnectAttempts = 0;
  bool _disposed = false;

  String? lastSymbol;
  String? lastInterval;
  bool? lastClosedOnly;

  void emitKline(KlineUpdate update) {
    if (!_klines.isClosed) _klines.add(update);
  }

  void emitStatus(KlineConnectionStatus s) {
    _fakeStatus = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
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
    lastClosedOnly = closedOnly;
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

class _ScriptedRest {
  final List<({String symbol, String interval, int limit})> calls = [];
  List<CandleData> response = const [];
  Object? error;

  Future<List<CandleData>> call({
    required String symbol,
    required String interval,
    required int limit,
  }) async {
    calls.add((symbol: symbol, interval: interval, limit: limit));
    if (error != null) throw error!;
    return response;
  }
}

CandleData _makeCandle(int ts, {double close = 100.0}) => CandleData(
      timestamp: ts,
      open: close,
      high: close + 1,
      low: close - 1,
      close: close,
      volume: 1.0,
    );

List<CandleData> _makeBackfill(int count, {double start = 100.0}) {
  return [
    for (int i = 0; i < count; i++)
      _makeCandle(i * 60_000, close: start + i.toDouble()),
  ];
}

KlineUpdate _makeKline({
  required int ts,
  required bool closed,
  double close = 200.0,
  String symbol = 'BTCUSDT',
  String interval = '1h',
}) =>
    KlineUpdate(
      openTime: ts,
      closeTime: ts + 60_000,
      symbol: symbol,
      interval: interval,
      open: close,
      high: close + 1,
      low: close - 1,
      close: close,
      volume: 1.0,
      isClosed: closed,
    );

void main() {
  group('ChartProvider lifecycle', () {
    test('initial state is idle with default params', () {
      final p = ChartProvider();
      expect(p.symbol, 'BTCUSDT');
      expect(p.timeframe, '1h');
      expect(p.bbPeriod, 20);
      expect(p.bbStdDev, 2.0);
      expect(p.rsiPeriod, 14);
      expect(p.status, ChartStatus.idle);
      expect(p.candles, isEmpty);
      expect(p.bb, isNull);
      expect(p.rsi, isNull);
      expect(p.errorMessage, isNull);
      p.dispose();
    });

    test('load() runs REST backfill then attaches WS and goes live',
        () async {
      final fakeStream = FakeBinanceKlineStream();
      final rest = _ScriptedRest()..response = _makeBackfill(30);
      final p = ChartProvider(
        wsFactory: () => fakeStream,
        restFn: rest.call,
      );

      await p.load();

      expect(rest.calls.single.symbol, 'BTCUSDT');
      expect(rest.calls.single.interval, '1h');
      expect(rest.calls.single.limit, 500);
      expect(p.candles.length, 30);
      expect(p.bb, isNotNull,
          reason: 'BB(20) should populate on a 30-candle backfill');
      expect(p.rsi, isNotNull,
          reason: 'RSI(14) should populate on a 30-candle backfill');
      expect(fakeStream.lastSymbol, 'BTCUSDT');
      expect(fakeStream.lastInterval, '1h');
      expect(p.status, ChartStatus.live);
      p.dispose();
    });

    test('REST failure surfaces as ChartStatus.error with errorMessage',
        () async {
      final fakeStream = FakeBinanceKlineStream();
      final rest = _ScriptedRest()..error = StateError('rest boom');
      final p = ChartProvider(
        wsFactory: () => fakeStream,
        restFn: rest.call,
      );

      await p.load();

      expect(p.status, ChartStatus.error);
      expect(p.errorMessage, contains('rest boom'));
      expect(p.candles, isEmpty);
      p.dispose();
    });

    test('WS tick appends candle, recomputes indicators, notifies',
        () async {
      final fakeStream = FakeBinanceKlineStream();
      final rest = _ScriptedRest()..response = _makeBackfill(40);
      final p = ChartProvider(
        wsFactory: () => fakeStream,
        restFn: rest.call,
      );

      var notifications = 0;
      p.addListener(() => notifications++);

      await p.load();
      final preTickLen = p.candles.length;
      final preTickBbMid = p.bb!.middle.last;

      // Use a close far enough off the trailing window-SMA to shift
      // the BB middle band — a monotonic backfill already saturates
      // the RSI at 100, so RSI is not a reliable witness here.
      fakeStream.emitKline(
        _makeKline(ts: 99 * 60_000, closed: true, close: 9999.0),
      );
      // Allow stream microtask to fan out.
      await Future<void>.delayed(Duration.zero);

      expect(p.candles.length, preTickLen + 1);
      expect(p.candles.last.close, 9999.0);
      expect(p.bb!.middle.last, isNot(preTickBbMid),
          reason: 'A fresh tick must shift the BB middle band');
      expect(notifications, greaterThan(0));
      p.dispose();
    });

    test('setSymbol() restarts the stream and clears the buffer', () async {
      final streams = <FakeBinanceKlineStream>[];
      final rest = _ScriptedRest()..response = _makeBackfill(20);
      final p = ChartProvider(
        wsFactory: () {
          final s = FakeBinanceKlineStream();
          streams.add(s);
          return s;
        },
        restFn: rest.call,
      );

      await p.load();
      expect(streams.length, 1);
      expect(p.symbol, 'BTCUSDT');

      // Swap REST response so we can tell the new buffer apart from
      // the original one.
      rest.response = _makeBackfill(25, start: 500.0);
      await p.setSymbol('ETHUSDT');

      expect(p.symbol, 'ETHUSDT');
      expect(streams.length, 2);
      expect(streams.last.lastSymbol, 'ETHUSDT');
      expect(p.candles.length, 25);
      expect(p.candles.first.close, 500.0);
      p.dispose();
    });

    test('setSymbol() is a no-op when the symbol is unchanged', () async {
      final streams = <FakeBinanceKlineStream>[];
      final rest = _ScriptedRest()..response = _makeBackfill(5);
      final p = ChartProvider(
        wsFactory: () {
          final s = FakeBinanceKlineStream();
          streams.add(s);
          return s;
        },
        restFn: rest.call,
      );

      await p.load();
      expect(streams.length, 1);

      await p.setSymbol('BTCUSDT');
      expect(streams.length, 1, reason: 'no restart on identical symbol');
      expect(rest.calls.length, 1);
      p.dispose();
    });

    test('setTimeframe() restarts the stream with the new interval',
        () async {
      final streams = <FakeBinanceKlineStream>[];
      final rest = _ScriptedRest()..response = _makeBackfill(5);
      final p = ChartProvider(
        wsFactory: () {
          final s = FakeBinanceKlineStream();
          streams.add(s);
          return s;
        },
        restFn: rest.call,
      );

      await p.load();
      await p.setTimeframe('15m');

      expect(p.timeframe, '15m');
      expect(streams.last.lastInterval, '15m');
      expect(rest.calls.last.interval, '15m');
      p.dispose();
    });

    test('setTimeframe(`30m`) wires the new Binance-supported interval',
        () async {
      // Welle P4C-H-1: '30m' replaced the unsupported '3h' slot.
      // Pin the provider against accepting the new interval so a
      // future regression in supportedTimeframes is caught here too.
      final streams = <FakeBinanceKlineStream>[];
      final rest = _ScriptedRest()..response = _makeBackfill(5);
      final p = ChartProvider(
        wsFactory: () {
          final s = FakeBinanceKlineStream();
          streams.add(s);
          return s;
        },
        restFn: rest.call,
      );

      await p.load();
      await p.setTimeframe('30m');

      expect(p.timeframe, '30m');
      expect(streams.last.lastInterval, '30m');
      expect(rest.calls.last.interval, '30m');
      expect(p.status, ChartStatus.live);
      p.dispose();
    });

    test(
      'setIndicatorParams() recomputes locally without restarting stream',
      () async {
        final streams = <FakeBinanceKlineStream>[];
        final rest = _ScriptedRest()..response = _makeBackfill(40);
        final p = ChartProvider(
          wsFactory: () {
            final s = FakeBinanceKlineStream();
            streams.add(s);
            return s;
          },
          restFn: rest.call,
        );

        await p.load();
        final originalBbMid = p.bb!.middle.last;
        expect(streams.length, 1);

        p.setIndicatorParams(bbPeriod: 5, rsiPeriod: 5);

        expect(p.bbPeriod, 5);
        expect(p.rsiPeriod, 5);
        expect(streams.length, 1,
            reason: 'recomputing indicators must NOT restart the WS');
        expect(rest.calls.length, 1,
            reason: 'recomputing indicators must NOT refetch the REST');
        expect(p.bb!.middle.last, isNot(originalBbMid),
            reason: 'shorter BB period shifts the middle band');
        p.dispose();
      },
    );

    test('setIndicatorParams() is a no-op when all params unchanged',
        () async {
      final fakeStream = FakeBinanceKlineStream();
      final rest = _ScriptedRest()..response = _makeBackfill(40);
      final p = ChartProvider(
        wsFactory: () => fakeStream,
        restFn: rest.call,
      );

      await p.load();

      var notifications = 0;
      p.addListener(() => notifications++);

      p.setIndicatorParams(bbPeriod: 20, bbStdDev: 2.0, rsiPeriod: 14);

      expect(notifications, 0,
          reason: 'no-change call must not notify listeners');
      p.dispose();
    });

    test('WS status reconnecting maps to ChartStatus.reconnecting',
        () async {
      final fakeStream = FakeBinanceKlineStream();
      final rest = _ScriptedRest()..response = _makeBackfill(5);
      final p = ChartProvider(
        wsFactory: () => fakeStream,
        restFn: rest.call,
      );

      await p.load();
      expect(p.status, ChartStatus.live);

      fakeStream.emitStatus(KlineConnectionStatus.reconnecting);
      await Future<void>.delayed(Duration.zero);

      expect(p.status, ChartStatus.reconnecting);
      p.dispose();
    });

    test('WS terminal error maps to ChartStatus.error with message',
        () async {
      final fakeStream = FakeBinanceKlineStream();
      final rest = _ScriptedRest()..response = _makeBackfill(5);
      final p = ChartProvider(
        wsFactory: () => fakeStream,
        restFn: rest.call,
      );

      await p.load();

      fakeStream.emitStatus(KlineConnectionStatus.error);
      await Future<void>.delayed(Duration.zero);

      expect(p.status, ChartStatus.error);
      expect(p.errorMessage, isNotNull);
      p.dispose();
    });

    test('candle buffer is capped at kChartBufferCap', () async {
      final fakeStream = FakeBinanceKlineStream();
      // Backfill already at cap → next tick must trim the oldest entry.
      final rest = _ScriptedRest()
        ..response = _makeBackfill(kChartBufferCap, start: 100.0);
      final p = ChartProvider(
        wsFactory: () => fakeStream,
        restFn: rest.call,
      );

      await p.load();
      expect(p.candles.length, kChartBufferCap);
      final originalFirstTs = p.candles.first.timestamp;

      fakeStream.emitKline(
        _makeKline(ts: 999 * 60_000, closed: true, close: 777.0),
      );
      await Future<void>.delayed(Duration.zero);

      expect(p.candles.length, kChartBufferCap,
          reason: 'buffer must not grow beyond the cap');
      expect(p.candles.first.timestamp, isNot(originalFirstTs),
          reason: 'oldest candle must be trimmed off');
      expect(p.candles.last.close, 777.0);
      p.dispose();
    });

    test('dispose cancels subscriptions and tears down the stream',
        () async {
      final fakeStream = FakeBinanceKlineStream();
      final rest = _ScriptedRest()..response = _makeBackfill(5);
      final p = ChartProvider(
        wsFactory: () => fakeStream,
        restFn: rest.call,
      );

      await p.load();
      p.dispose();
      await Future<void>.delayed(Duration.zero);

      // A late tick after dispose must not throw "ChangeNotifier was
      // disposed" — the provider's internal subscription was cancelled.
      fakeStream.emitKline(_makeKline(ts: 12345, closed: true));
      // The fake's controller has been closed too via dispose() — no
      // assertion expected, just confirm no exception bubbled.
      expect(true, isTrue);
    });
  });
}
