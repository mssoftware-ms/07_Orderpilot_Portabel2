/// Welle O3-B3 — provider-level applyTrialAsParams tests.
///
/// Covers:
///   - Apply for each StrategyKind switches active strategy + sets typed
///     params + flips usingOptimizedParams = true.
///   - Same-kind apply keeps the strategy and just swaps params.
///   - Unknown trial keys are ignored without throwing (schema-drift
///     tolerance) and the rest of the params still apply.
///   - The deprecated applyOptimizedParams wrapper still no-ops on
///     non-BB+RSI strategies — Welle-O3-B1 contract guard.
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/services/backtest_service.dart';

void main() {
  group('applyTrialAsParams', () {
    test('BB+RSI trial sets typed params and optimized flag', () {
      final p = BacktestProvider();
      final trial = const BbRsiParams(bbPeriod: 227, rsiPeriod: 7).toMap();
      p.applyTrialAsParams(kind: StrategyKind.bbRsi, trialParams: trial);
      expect(p.config.strategyKind, StrategyKind.bbRsi);
      expect((p.config.strategyParams as BbRsiParams).bbPeriod, 227);
      expect((p.config.strategyParams as BbRsiParams).rsiPeriod, 7);
      expect(p.usingOptimizedParams, isTrue);
    });

    test('UT-Bot trial from BB+RSI strategy auto-switches kind', () {
      final p = BacktestProvider();
      expect(p.config.strategyKind, StrategyKind.bbRsi);
      final trial = const UtBotParams(emaPeriod: 181, atrPeriod: 4).toMap();
      p.applyTrialAsParams(kind: StrategyKind.utBot, trialParams: trial);
      expect(p.config.strategyKind, StrategyKind.utBot);
      expect((p.config.strategyParams as UtBotParams).emaPeriod, 181);
      expect((p.config.strategyParams as UtBotParams).atrPeriod, 4);
      expect(p.usingOptimizedParams, isTrue);
    });

    test('Ichimoku trial from UT-Bot strategy auto-switches kind', () {
      final p = BacktestProvider();
      p.setStrategyKind(StrategyKind.utBot);
      final trial =
          const IchimokuParams(tenkanPeriod: 12, kijunPeriod: 33).toMap();
      p.applyTrialAsParams(
          kind: StrategyKind.ichimoku, trialParams: trial);
      expect(p.config.strategyKind, StrategyKind.ichimoku);
      expect((p.config.strategyParams as IchimokuParams).tenkanPeriod, 12);
      expect((p.config.strategyParams as IchimokuParams).kijunPeriod, 33);
      expect(p.usingOptimizedParams, isTrue);
    });

    test('unknown keys are ignored, known keys still apply', () {
      final p = BacktestProvider();
      final trial = {
        ...const BbRsiParams(bbPeriod: 200).toMap(),
        'totally_unknown_param': 42.0,
        'another_drift_key': 1.0,
      };
      p.applyTrialAsParams(kind: StrategyKind.bbRsi, trialParams: trial);
      expect((p.config.strategyParams as BbRsiParams).bbPeriod, 200);
      expect(p.usingOptimizedParams, isTrue);
    });

    test('partial trial uses defaults for missing keys', () {
      final p = BacktestProvider();
      p.applyTrialAsParams(
        kind: StrategyKind.bbRsi,
        trialParams: const {'bb_period': 99.0},
      );
      final bp = p.config.strategyParams as BbRsiParams;
      expect(bp.bbPeriod, 99);
      // All other fields fall back to BbRsiParams defaults.
      const d = BbRsiParams();
      expect(bp.rsiPeriod, d.rsiPeriod);
      expect(bp.adxThreshold, d.adxThreshold);
    });

    test('notifies listeners exactly once', () {
      final p = BacktestProvider();
      var notifyCount = 0;
      p.addListener(() => notifyCount++);
      p.applyTrialAsParams(
        kind: StrategyKind.bbRsi,
        trialParams: const {'bb_period': 50.0},
      );
      expect(notifyCount, 1);
    });
  });

  group('deprecated applyOptimizedParams wrapper', () {
    test('still no-ops on non-BB+RSI (Welle-O3-B1 contract)', () {
      final p = BacktestProvider();
      p.setStrategyKind(StrategyKind.utBot);
      final beforeParams = p.config.strategyParams;
      // ignore: deprecated_member_use_from_same_package
      p.applyOptimizedParams(const BbRsiParams(bbPeriod: 99));
      expect(p.config.strategyParams, same(beforeParams));
      expect(p.usingOptimizedParams, isFalse);
    });

    test('still applies on BB+RSI active strategy', () {
      final p = BacktestProvider();
      // ignore: deprecated_member_use_from_same_package
      p.applyOptimizedParams(const BbRsiParams(bbPeriod: 99));
      expect((p.config.strategyParams as BbRsiParams).bbPeriod, 99);
      expect(p.usingOptimizedParams, isTrue);
    });
  });
}
