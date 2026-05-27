/// Welle B4-3 — PaperTradingScreen widget tests.
///
/// Drives the screen against the real [PaperTradingProvider] with a
/// FakeBinanceKlineStream injected, mirroring the test-double from
/// `paper_trading_provider_test.dart`. The screen is wrapped in a
/// surface-sized MaterialApp so the desktop wide-layout assertions
/// stay deterministic.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/features/paper/paper_session.dart';
import 'package:trading_app/features/paper/paper_trading_provider.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/binance_websocket.dart';
import 'package:trading_app/ui/screens/paper_trading_screen.dart';

class _FakeStream extends BinanceKlineStream {
  _FakeStream() : super();

  final _klines = StreamController<KlineUpdate>.broadcast();
  final _statusCtrl = StreamController<KlineConnectionStatus>.broadcast();
  KlineConnectionStatus _fakeStatus = KlineConnectionStatus.idle;
  final int _attempts = 0;
  bool _disposed = false;

  void emit(KlineUpdate u) {
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
  int get reconnectAttempts => _attempts;
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

Future<void> _pump(
  WidgetTester tester, {
  required PaperTradingProvider paper,
  required BacktestProvider backtest,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  await tester.pumpWidget(
    MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<PaperTradingProvider>.value(value: paper),
          ChangeNotifierProvider<BacktestProvider>.value(value: backtest),
        ],
        child: const PaperTradingScreen(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('PaperTradingScreen — idle state', () {
    testWidgets('shows Start button + empty-state card, no Stop', (tester) async {
      final paper = PaperTradingProvider(streamFactory: () => _FakeStream());
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      addTearDown(bt.dispose);

      await _pump(tester, paper: paper, backtest: bt);

      expect(find.byKey(const Key('paper-start-button')), findsOneWidget);
      expect(find.byKey(const Key('paper-stop-button')), findsNothing);
      expect(find.byKey(const Key('paper-status-label')), findsOneWidget);
      expect(find.text('Idle'), findsOneWidget);
      expect(find.byKey(const Key('paper-active-session-card')), findsNothing);
      expect(find.text('No active session'), findsOneWidget);
    });

    testWidgets('Sync from Backtest button mirrors the active backtest config',
        (tester) async {
      final paper = PaperTradingProvider(streamFactory: () => _FakeStream());
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      bt.updateSymbol('ETHUSDT');
      bt.updateTimeframe('5m');
      addTearDown(bt.dispose);

      await _pump(tester, paper: paper, backtest: bt);

      await tester.tap(find.byKey(const Key('paper-sync-backtest-button')));
      await tester.pump();

      expect(paper.pendingConfig?.symbol, 'ETHUSDT');
      expect(paper.pendingConfig?.timeframe, '5m');
      expect(find.textContaining('Pending: ETHUSDT'), findsOneWidget);
    });
  });

  group('PaperTradingScreen — active session state', () {
    testWidgets('Running session shows status, active-session card, tick counter',
        (tester) async {
      final fake = _FakeStream();
      final paper = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      addTearDown(bt.dispose);

      // Real async work — provider.start() + microtask-scheduled WS
      // status broadcast — has to run OUTSIDE the testWidgets fake-async
      // zone, or its zero-duration Timers never resolve.
      await tester.runAsync(() async {
        await paper.start(
          config: PaperConfig(
            symbol: 'BTCUSDT',
            timeframe: '1m',
            strategyKind: StrategyKind.bbRsi,
            strategyParams: const BbRsiParams(
              bbPeriod: 20,
              bbStdDev: 0.2,
              bbMaType: BbMaType.ema,
              rsiPeriod: 3,
              swingLookbackBars: 5,
            ),
            initialBalance: 10000,
            feeRate: 0.0006,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        fake.emit(KlineUpdate(
          openTime: 1700000000000,
          closeTime: 1700000059999,
          symbol: 'BTCUSDT',
          interval: '1m',
          open: 100,
          high: 101,
          low: 99,
          close: 100.5,
          volume: 10,
          isClosed: true,
        ));
        await Future<void>.delayed(Duration.zero);
      });

      await _pump(tester, paper: paper, backtest: bt);
      await tester.pump();

      expect(find.text('Running'), findsOneWidget);
      expect(find.byKey(const Key('paper-active-session-card')), findsOneWidget);
      expect(find.byKey(const Key('paper-tick-counter')), findsOneWidget);
      expect(find.textContaining('1 tick'), findsOneWidget);
      expect(find.byKey(const Key('paper-stop-button')), findsOneWidget);
      expect(find.byKey(const Key('paper-start-button')), findsNothing);
    });

    testWidgets('Stop button transitions session to stopped', (tester) async {
      final fake = _FakeStream();
      final paper = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      addTearDown(bt.dispose);

      await tester.runAsync(() async {
        await paper.start();
        await Future<void>.delayed(Duration.zero);
      });

      await _pump(tester, paper: paper, backtest: bt);
      await tester.tap(find.byKey(const Key('paper-stop-button')));
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(find.text('Stopped'), findsOneWidget);
      expect(find.byKey(const Key('paper-start-button')), findsOneWidget);
    });

    testWidgets('Open-Position card only renders when openPosition != null',
        (tester) async {
      final fake = _FakeStream();
      final paper = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      addTearDown(bt.dispose);

      await tester.runAsync(() async {
        await paper.start(
          config: PaperConfig(
            symbol: 'BTCUSDT',
            timeframe: '1m',
            strategyKind: StrategyKind.bbRsi,
            strategyParams:
                const BbRsiParams(bbPeriod: 20, swingLookbackBars: 5),
            initialBalance: 10000,
            feeRate: 0.0006,
          ),
        );
        await Future<void>.delayed(Duration.zero);
      });

      await _pump(tester, paper: paper, backtest: bt);
      // No ticks yet → no open position.
      expect(find.byKey(const Key('paper-open-position-card')), findsNothing);
    });

    testWidgets('Reconnecting status shows attempt counter', (tester) async {
      final fake = _FakeStream();
      final paper = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      addTearDown(bt.dispose);

      await tester.runAsync(() async {
        await paper.start();
        await Future<void>.delayed(Duration.zero);
        fake.emitStatus(KlineConnectionStatus.reconnecting);
        await Future<void>.delayed(Duration.zero);
      });

      await _pump(tester, paper: paper, backtest: bt);
      expect(find.text('Reconnecting'), findsOneWidget);
    });
  });

  group('PaperTradingScreen — Welle B4.2-3 order trail card', () {
    testWidgets('Order Trail card renders sessionStarted after start',
        (tester) async {
      final fake = _FakeStream();
      final paper = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      addTearDown(bt.dispose);

      await tester.runAsync(() async {
        await paper.start();
        await Future<void>.delayed(Duration.zero);
      });
      await _pump(tester, paper: paper, backtest: bt);

      expect(find.byKey(const Key('paper-order-trail-card')), findsOneWidget);
      expect(find.text('Order trail'), findsOneWidget);
      expect(find.text('START'), findsOneWidget);
    });
  });

  group('PaperTradingScreen — Welle B4.2-2 slippage slider', () {
    testWidgets('slippage card visible in idle, slider enabled', (tester) async {
      final paper = PaperTradingProvider(streamFactory: () => _FakeStream());
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      addTearDown(bt.dispose);

      await _pump(tester, paper: paper, backtest: bt);

      expect(find.byKey(const Key('paper-slippage-card')), findsOneWidget);
      expect(find.byKey(const Key('paper-slippage-slider')), findsOneWidget);
      expect(find.text('5 bps'), findsOneWidget);

      final slider = tester.widget<Slider>(
          find.byKey(const Key('paper-slippage-slider')));
      expect(slider.onChanged, isNotNull,
          reason: 'slider must be enabled while idle so the user can tune '
              'the session slippage before pressing Start');
    });

    testWidgets('slider is disabled while running', (tester) async {
      final fake = _FakeStream();
      final paper = PaperTradingProvider(streamFactory: () => fake);
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      addTearDown(bt.dispose);

      await tester.runAsync(() async {
        await paper.start();
        await Future<void>.delayed(Duration.zero);
      });
      await _pump(tester, paper: paper, backtest: bt);

      final slider = tester.widget<Slider>(
          find.byKey(const Key('paper-slippage-slider')));
      expect(slider.onChanged, isNull,
          reason: 'slider must be disabled while the session is active so '
              'slippage stays stable for its lifetime');
    });

    testWidgets('value label reflects pendingSlippageBps mutations',
        (tester) async {
      final paper = PaperTradingProvider(streamFactory: () => _FakeStream());
      addTearDown(paper.dispose);
      final bt = BacktestProvider();
      addTearDown(bt.dispose);

      await _pump(tester, paper: paper, backtest: bt);
      expect(find.text('5 bps'), findsOneWidget);

      paper.setPendingSlippage(12.0);
      await tester.pump();
      expect(find.text('12 bps'), findsOneWidget);
      expect(find.text('5 bps'), findsNothing);
    });
  });
}
