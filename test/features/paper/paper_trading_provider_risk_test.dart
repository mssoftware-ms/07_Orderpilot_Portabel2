/// Welle B4.3-2 — PaperTradingProvider × RiskManager gate integration.
///
/// Verifies that:
///   * a position-open is blocked when the injected RiskManager reports a
///     breach, and a `riskBlocked` order event lands on the trail;
///   * the gate is opt-in: when no RiskManager is injected (default) the
///     provider behaves exactly as it did pre-B4.3 (no regression against
///     the existing B4.2 suite).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/core/logging/app_log.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/features/paper/order_event.dart';
import 'package:trading_app/features/paper/paper_session.dart';
import 'package:trading_app/features/paper/paper_trading_provider.dart';
import 'package:trading_app/features/risk/risk_config.dart';
import 'package:trading_app/features/risk/risk_manager.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/binance_websocket.dart';

// ─── Shared test fakes ─────────────────────────────────────────────────

class FakeBinanceKlineStream extends BinanceKlineStream {
  FakeBinanceKlineStream() : super();

  final StreamController<KlineUpdate> _klines =
      StreamController<KlineUpdate>.broadcast();
  final StreamController<KlineConnectionStatus> _statusCtrl =
      StreamController<KlineConnectionStatus>.broadcast();
  KlineConnectionStatus _fakeStatus = KlineConnectionStatus.idle;
  bool _disposed = false;

  void emitKline(KlineUpdate u) {
    if (!_klines.isClosed) _klines.add(u);
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
  int get reconnectAttempts => 0;

  @override
  bool get isClosed => _klines.isClosed;

  @override
  Stream<KlineUpdate> connect({
    required String symbol,
    required String interval,
    bool closedOnly = true,
  }) {
    if (_disposed) throw StateError('Fake disposed');
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

// Same deterministic LCG fixture as the B4.2 suite — 400 candles in
// [80, 120] suffice to reliably produce at least one open position with
// the fast BB+RSI params below.
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

PaperConfig _config() => const PaperConfig(
      symbol: 'BTCUSDT',
      timeframe: '1m',
      strategyKind: StrategyKind.bbRsi,
      strategyParams: _fastBbRsi,
      initialBalance: 10000.0,
      feeRate: 0.0006,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.instance.clear();
  });

  group('B4.3-2 — risk gate blocks position opens', () {
    test('kill-switch active → no openPosition + riskBlocked event',
        () async {
      final risk = RiskManager();
      await risk.loadConfig();
      await risk.activateKillSwitch(reason: 'unit-test');
      expect(risk.killSwitchActive, isTrue);

      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        riskManager: risk,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _config());
      await Future<void>.delayed(Duration.zero);

      final fixture = _lcgFixture(400);
      for (final c in fixture) {
        fake.emitKline(_toUpdate(c));
      }
      await Future<void>.delayed(Duration.zero);

      // The engine still tries to open at least once on this fixture, but
      // every attempt must be blocked by the kill-switch. So the live
      // session must never have surfaced an open position.
      expect(provider.session!.openPosition, isNull,
          reason: 'kill-switch must block every open while active');

      final trail = provider.session!.orderTrail;
      final kinds = trail.map((e) => e.kind).toSet();
      expect(kinds, contains(OrderEventKind.riskBlocked),
          reason: 'a blocked open must surface as a riskBlocked event');
      expect(kinds, isNot(contains(OrderEventKind.positionOpened)),
          reason: 'no positionOpened event may sneak through');

      final blockedEvents = trail
          .where((e) => e.kind == OrderEventKind.riskBlocked)
          .toList();
      expect(blockedEvents, isNotEmpty);
      expect(blockedEvents.first.message, contains('killSwitch'));
    });

    test('passing risk gate → position opens normally', () async {
      // Defaults are wide enough that a 400-bar LCG session is well inside
      // every gate — the open path should land unchanged.
      final risk = RiskManager();
      await risk.loadConfig();
      expect(risk.killSwitchActive, isFalse);

      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        riskManager: risk,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _config());
      await Future<void>.delayed(Duration.zero);

      final fixture = _lcgFixture(400);
      bool sawOpen = false;
      for (final c in fixture) {
        fake.emitKline(_toUpdate(c));
        await Future<void>.delayed(Duration.zero);
        if (provider.session!.openPosition != null) sawOpen = true;
      }

      expect(sawOpen, isTrue,
          reason: 'with passing gates the provider must still open positions');
      final trail = provider.session!.orderTrail;
      expect(trail.any((e) => e.kind == OrderEventKind.positionOpened),
          isTrue);
    });

    test('AppLog.warn fires when a position open is blocked', () async {
      final risk = RiskManager();
      await risk.loadConfig();
      await risk.activateKillSwitch(reason: 'unit-test');

      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        riskManager: risk,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _config());
      await Future<void>.delayed(Duration.zero);

      // Reset the log after start() so we only inspect tick-time warnings.
      AppLog.instance.clear();

      final fixture = _lcgFixture(400);
      for (final c in fixture) {
        fake.emitKline(_toUpdate(c));
      }
      await Future<void>.delayed(Duration.zero);

      final warns = AppLog.instance.entries.where(
          (e) => e.level == LogLevel.warning && e.tag == 'PaperTrading');
      expect(warns.any((e) => e.message.contains('blocked by risk gates')),
          isTrue);
    });
  });

  group('B4.3-2 — default null riskManager keeps B4.2 behaviour', () {
    test('no risk manager injected → positions open as before', () async {
      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(provider.dispose);

      await provider.start(config: _config());
      await Future<void>.delayed(Duration.zero);

      final fixture = _lcgFixture(400);
      bool sawOpen = false;
      for (final c in fixture) {
        fake.emitKline(_toUpdate(c));
        await Future<void>.delayed(Duration.zero);
        if (provider.session!.openPosition != null) sawOpen = true;
      }
      expect(sawOpen, isTrue);

      final trail = provider.session!.orderTrail;
      expect(trail.any((e) => e.kind == OrderEventKind.riskBlocked), isFalse,
          reason: 'no riskBlocked events without a risk manager');
    });
  });

  group('B4.3-2 — sorted breach label', () {
    test('riskBlocked message is sorted-comma-joined for stable rendering',
        () async {
      // Force two simultaneous breaches: daily-loss + kill-switch.
      final risk = RiskManager(
        prefsLoader: () async {
          SharedPreferences.setMockInitialValues({});
          return SharedPreferences.getInstance();
        },
      );
      // Save a tight config so the dailyLoss gate trips easily, plus the
      // kill switch.
      await risk.saveConfig(const RiskConfig(
        maxPositionRiskPct: 5.0,
        maxDailyLossPct: 0.1, // virtually any loss trips this
        maxDrawdownPct: 10.0,
        maxConsecutiveLosses: 5,
        killSwitchActive: true,
      ));

      final fake = FakeBinanceKlineStream();
      final provider = PaperTradingProvider(
        streamFactory: () => fake,
        riskManager: risk,
      );
      addTearDown(provider.dispose);

      await provider.start(config: _config());
      await Future<void>.delayed(Duration.zero);

      final fixture = _lcgFixture(400);
      for (final c in fixture) {
        fake.emitKline(_toUpdate(c));
      }
      await Future<void>.delayed(Duration.zero);

      final blockEvents = provider.session!.orderTrail
          .where((e) => e.kind == OrderEventKind.riskBlocked)
          .toList();
      expect(blockEvents, isNotEmpty);
      // Sorted: dailyLoss < killSwitch alphabetically.
      expect(blockEvents.first.message, contains('dailyLoss'));
      expect(blockEvents.first.message, contains('killSwitch'));
      final daily = blockEvents.first.message.indexOf('dailyLoss');
      final kill = blockEvents.first.message.indexOf('killSwitch');
      expect(daily < kill, isTrue, reason: 'gates must be sorted in the label');
    });
  });
}
