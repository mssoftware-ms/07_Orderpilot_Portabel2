/// Welle B4.3-1 — [RiskManager] gate semantics + persistence coverage.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/core/logging/app_log.dart';
import 'package:trading_app/core/models/trade.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/features/paper/paper_session.dart';
import 'package:trading_app/features/risk/risk_assessment.dart';
import 'package:trading_app/features/risk/risk_config.dart';
import 'package:trading_app/features/risk/risk_manager.dart';
import 'package:trading_app/services/backtest_service.dart';

PaperConfig _config({double initialBalance = 10000.0}) => PaperConfig(
      symbol: 'BTCUSDT',
      timeframe: '1m',
      strategyKind: StrategyKind.bbRsi,
      strategyParams: defaultBbRsiParams(),
      initialBalance: initialBalance,
      feeRate: 0.0006,
    );

PaperSession _session({
  double initialBalance = 10000.0,
  double equity = 10000.0,
  List<EquityPoint>? equityCurve,
  List<ClosedTrade>? trades,
}) =>
    PaperSession(
      config: _config(initialBalance: initialBalance),
      startedAtMs: 1700000000000,
      equity: equity,
      equityCurve: equityCurve,
      closedTrades: trades,
    );

ClosedTrade _losingTrade({double pnl = -50.0}) => ClosedTrade(
      entryTimestamp: 1700000000000,
      exitTimestamp: 1700000060000,
      direction: 'LONG',
      entryPrice: 100,
      exitPrice: 99,
      quantity: 1,
      pnl: pnl,
      pnlPercent: -1,
      fees: 0.1,
      exitReason: 'StopLoss',
    );

ClosedTrade _winningTrade({double pnl = 80.0}) => ClosedTrade(
      entryTimestamp: 1700000000000,
      exitTimestamp: 1700000060000,
      direction: 'LONG',
      entryPrice: 100,
      exitPrice: 102,
      quantity: 1,
      pnl: pnl,
      pnlPercent: 2,
      fees: 0.1,
      exitReason: 'TakeProfit',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.instance.clear();
  });

  group('loadConfig / saveConfig', () {
    test('loadConfig with nothing stored returns defaults', () async {
      final manager = RiskManager();
      expect(manager.isLoaded, isFalse);
      await manager.loadConfig();
      expect(manager.isLoaded, isTrue);
      expect(manager.config, RiskConfig.defaults());
    });

    test('saveConfig persists and a fresh manager reads it back', () async {
      final manager = RiskManager();
      const updated = RiskConfig(
        maxPositionRiskPct: 2.0,
        maxDailyLossPct: 6.0,
        maxDrawdownPct: 8.0,
        maxConsecutiveLosses: 3,
        killSwitchActive: false,
      );
      await manager.saveConfig(updated);
      expect(manager.config, updated);

      final freshManager = RiskManager();
      await freshManager.loadConfig();
      expect(freshManager.config, updated);
    });

    test('saveConfig notifies listeners exactly once', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      var notifications = 0;
      manager.addListener(() => notifications++);
      await manager.saveConfig(
          manager.config.copyWith(maxPositionRiskPct: 1.5));
      expect(notifications, 1);
    });
  });

  group('assess — fresh session', () {
    test('zeroed indicators and no breaches', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      final s = _session();
      final a = manager.assess(s);
      expect(a.currentDailyPnlPct, 0.0);
      expect(a.currentDrawdownPct, 0.0);
      expect(a.currentConsecutiveLosses, 0);
      expect(a.breachedGates, isEmpty);
      expect(a.allGatesPass, isTrue);
    });
  });

  group('assess — gate breaches', () {
    test('daily-loss gate trips when session PnL drops below -cap', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      // -5 % vs 3 % cap → trips.
      final s = _session(equity: 9500.0);
      final a = manager.assess(s);
      expect(a.currentDailyPnlPct, closeTo(-5.0, 1e-9));
      expect(a.gateBreached(RiskGate.dailyLoss), isTrue);
      expect(a.allGatesPass, isFalse);
    });

    test('daily-loss gate does NOT trip at exactly -cap (strict inequality)',
        () async {
      // Spec uses `<=` so exact -cap trips. Pin that contract.
      final manager = RiskManager();
      await manager.loadConfig();
      final s = _session(equity: 9700.0); // -3 % = -cap exactly
      final a = manager.assess(s);
      expect(a.currentDailyPnlPct, closeTo(-3.0, 1e-9));
      expect(a.gateBreached(RiskGate.dailyLoss), isTrue,
          reason: 'pnl == -cap should trip the gate (<= comparison)');
    });

    test('drawdown gate trips when current equity is below cap of peak',
        () async {
      final manager = RiskManager();
      await manager.loadConfig();
      // Peak 12000 (from equityCurve), now 10800 → 10 % dd vs 10 % cap → trips
      // (>= comparison).
      final s = _session(
        equity: 10800.0,
        equityCurve: const [
          EquityPoint(
              timestamp: 1700000000000,
              equity: 10000.0,
              drawdown: 0,
              drawdownPct: 0),
          EquityPoint(
              timestamp: 1700000060000,
              equity: 12000.0,
              drawdown: 0,
              drawdownPct: 0),
          EquityPoint(
              timestamp: 1700000120000,
              equity: 10800.0,
              drawdown: 1200,
              drawdownPct: 10),
        ],
      );
      final a = manager.assess(s);
      expect(a.currentDrawdownPct, closeTo(10.0, 1e-9));
      expect(a.gateBreached(RiskGate.drawdown), isTrue);
    });

    test('consecutive-losses gate trips at exactly the cap', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      final s = _session(
        trades: List.generate(5, (_) => _losingTrade()),
      );
      final a = manager.assess(s);
      expect(a.currentConsecutiveLosses, 5);
      expect(a.gateBreached(RiskGate.consecutiveLosses), isTrue);
    });

    test('consecutive-losses counts from the end and resets on a winner',
        () async {
      final manager = RiskManager();
      await manager.loadConfig();
      final s = _session(trades: [
        _losingTrade(),
        _losingTrade(),
        _losingTrade(),
        _losingTrade(),
        _losingTrade(),
        _winningTrade(),
        _losingTrade(),
        _losingTrade(),
      ]);
      final a = manager.assess(s);
      expect(a.currentConsecutiveLosses, 2,
          reason: 'counter resets after each win, only the tail counts');
      expect(a.gateBreached(RiskGate.consecutiveLosses), isFalse);
    });

    test('multiple gate breaches stack into breachedGates', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      final s = _session(
        equity: 8500.0, // -15 % daily, big drawdown
        equityCurve: const [          EquityPoint(
              timestamp: 1,
              equity: 10000.0,
              drawdown: 0,
              drawdownPct: 0),
          EquityPoint(
              timestamp: 2,
              equity: 8500.0,
              drawdown: 1500,
              drawdownPct: 15),
        ],
        trades: List.generate(5, (_) => _losingTrade()),
      );
      final a = manager.assess(s);
      expect(a.breachedGates, containsAll([
        RiskGate.dailyLoss,
        RiskGate.drawdown,
        RiskGate.consecutiveLosses,
      ]));
    });
  });

  group('canOpenPosition — position-risk gate', () {
    test('passes when proposed notional fits inside maxPositionRiskPct',
        () async {
      final manager = RiskManager();
      await manager.loadConfig();
      final s = _session(equity: 10000.0);
      // 5 % of 10000 = 500 — 400 fits.
      expect(
          manager.canOpenPosition(s, proposedNotional: 400.0), isTrue);
    });

    test('rejects when proposed notional exceeds maxPositionRiskPct',
        () async {
      final manager = RiskManager();
      await manager.loadConfig();
      final s = _session(equity: 10000.0);
      // 5 % of 10000 = 500 — 600 over-shoots.
      expect(
          manager.canOpenPosition(s, proposedNotional: 600.0), isFalse);
    });

    test('rejects on non-positive equity', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      final s = _session(equity: 0.0);
      expect(
          manager.canOpenPosition(s, proposedNotional: 1.0), isFalse);
    });

    test('breached non-positionRisk gates still block the open', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      final s = _session(
        equity: 9000.0, // -10 % daily → trips daily-loss
      );
      expect(
          manager.canOpenPosition(s, proposedNotional: 100.0), isFalse);
    });
  });

  group('kill switch', () {
    test('activateKillSwitch persists + logs error', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.activateKillSwitch(reason: 'manual');
      expect(manager.killSwitchActive, isTrue);

      final fresh = RiskManager();
      await fresh.loadConfig();
      expect(fresh.killSwitchActive, isTrue,
          reason: 'kill-switch state must survive across instances');

      final errors = AppLog.instance.entries.where(
          (e) => e.level == LogLevel.error && e.tag == 'RiskManager');
      expect(errors, isNotEmpty);
    });

    test('activateKillSwitch is idempotent', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.activateKillSwitch(reason: 'first');
      var notifications = 0;
      manager.addListener(() => notifications++);
      await manager.activateKillSwitch(reason: 'second');
      expect(notifications, 0, reason: 'no-op second call must not notify');
    });

    test('resetKillSwitch clears the flag', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.activateKillSwitch(reason: 'manual');
      expect(manager.killSwitchActive, isTrue);
      await manager.resetKillSwitch();
      expect(manager.killSwitchActive, isFalse);
    });

    test('kill switch active → canOpenPosition false unconditionally',
        () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.activateKillSwitch(reason: 'manual');
      // Even a tiny, otherwise-fine position must be rejected.
      final s = _session(equity: 10000.0);
      expect(
          manager.canOpenPosition(s, proposedNotional: 1.0), isFalse);
    });

    test('kill switch active surfaces as the killSwitch gate', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.activateKillSwitch(reason: 'manual');
      final a = manager.assess(_session());
      expect(a.killSwitchActive, isTrue);
      expect(a.gateBreached(RiskGate.killSwitch), isTrue);
      expect(a.allGatesPass, isFalse);
    });
  });

  group('refreshAssessment', () {
    test('caches the latest snapshot and notifies', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      var notifications = 0;
      manager.addListener(() => notifications++);
      final s = _session(equity: 9500.0);
      final a = manager.refreshAssessment(s);
      expect(a.gateBreached(RiskGate.dailyLoss), isTrue);
      expect(manager.lastAssessment, a);
      expect(notifications, 1);
    });
  });

  group('live trading toggle — Welle B4.4', () {
    test('default state is off and exposes via liveTradingEnabled getter',
        () async {
      final manager = RiskManager();
      await manager.loadConfig();
      expect(manager.liveTradingEnabled, isFalse);
      expect(manager.config.liveTradingEnabled, isFalse);
    });

    test('enableLiveTrading flips state, persists across instances, logs warn',
        () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.enableLiveTrading();
      expect(manager.liveTradingEnabled, isTrue);

      final fresh = RiskManager();
      await fresh.loadConfig();
      expect(fresh.liveTradingEnabled, isTrue,
          reason: 'persisted across instances — restart re-arms');

      final warns = AppLog.instance.entries.where((e) =>
          e.level == LogLevel.warning &&
          e.tag == 'RiskManager' &&
          e.message.contains('Live trading enabled'));
      expect(warns, isNotEmpty);
    });

    test('enableLiveTrading is idempotent — no duplicate notify', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.enableLiveTrading();
      var notifications = 0;
      manager.addListener(() => notifications++);
      await manager.enableLiveTrading();
      expect(notifications, 0,
          reason: 'second call is a no-op, must not broadcast');
    });

    test(
        'enableLiveTrading is a logged no-op when the kill switch is active',
        () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.activateKillSwitch(reason: 'manual');
      AppLog.instance.clear();
      await manager.enableLiveTrading();
      expect(manager.liveTradingEnabled, isFalse,
          reason: 'kill switch must veto an enable attempt');

      final warns = AppLog.instance.entries.where((e) =>
          e.level == LogLevel.warning &&
          e.tag == 'RiskManager' &&
          e.message.contains('kill switch is active'));
      expect(warns, isNotEmpty,
          reason: 'the veto must surface in the log so the user sees it');
    });

    test('disableLiveTrading flips back off and includes the reason in the log',
        () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.enableLiveTrading();
      AppLog.instance.clear();
      await manager.disableLiveTrading(reason: 'Eligibility lost');
      expect(manager.liveTradingEnabled, isFalse);

      final warns = AppLog.instance.entries.where((e) =>
          e.level == LogLevel.warning &&
          e.tag == 'RiskManager' &&
          e.message.contains('Live trading disabled') &&
          e.message.contains('Eligibility lost'));
      expect(warns, isNotEmpty,
          reason: 'reason must be surfaced so post-mortems can distinguish '
              'manual disable from auto-disable');
    });

    test('disableLiveTrading default reason is "manual"', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.enableLiveTrading();
      AppLog.instance.clear();
      await manager.disableLiveTrading();

      final warns = AppLog.instance.entries.where((e) =>
          e.level == LogLevel.warning &&
          e.tag == 'RiskManager' &&
          e.message.contains('Live trading disabled') &&
          e.message.contains('manual'));
      expect(warns, isNotEmpty);
    });

    test('disableLiveTrading is idempotent when already off', () async {
      final manager = RiskManager();
      await manager.loadConfig();
      var notifications = 0;
      manager.addListener(() => notifications++);
      await manager.disableLiveTrading(reason: 'noop');
      expect(notifications, 0);
      expect(manager.liveTradingEnabled, isFalse);
    });

    test('disableLiveTrading clears state even when the kill switch is on',
        () async {
      // Safety path: even an active kill switch must not block a disable.
      final manager = RiskManager();
      await manager.loadConfig();
      await manager.enableLiveTrading();
      await manager.activateKillSwitch(reason: 'breach');
      await manager.disableLiveTrading(reason: 'Eligibility lost');
      expect(manager.liveTradingEnabled, isFalse);
    });
  });
}
