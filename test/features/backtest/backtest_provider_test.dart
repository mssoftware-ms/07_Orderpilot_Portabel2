/// Provider-level tests for the Welle-O3-B1 generic strategy params model.
///
/// Covers:
///   - Default state stays on BB+RSI (backward compat with pre-B1 tests).
///   - `setStrategyKind` swaps both the kind AND the param defaults.
///   - `copyWith` round-trips strategy switches without losing the new
///     params (regression guard for assert-only refactors).
///   - The type-discipline assert in `BacktestConfig` blocks mismatched
///     param structs (e.g. UtBotParams on strategyKind=bbRsi).
///   - `applyOptimizedParams` no-ops on non-BB+RSI strategies (Welle O3-B1
///     keeps the optimizer BB+RSI-only).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/services/backtest_service.dart';

void main() {
  group('BacktestConfig default state', () {
    test('defaults to BB+RSI strategy with matching params', () {
      final cfg = BacktestConfig();
      expect(cfg.strategyKind, StrategyKind.bbRsi);
      expect(cfg.strategy, 'BB+RSI Mean Reversion');
      expect(cfg.strategyParams, isA<BbRsiParams>());
    });

    test('explicit strategyKind selects matching default params', () {
      final utBotCfg = BacktestConfig(strategyKind: StrategyKind.utBot);
      expect(utBotCfg.strategy, 'UT Bot');
      expect(utBotCfg.strategyParams, isA<UtBotParams>());

      final ichimokuCfg =
          BacktestConfig(strategyKind: StrategyKind.ichimoku);
      expect(ichimokuCfg.strategy, 'Ichimoku Cloud');
      expect(ichimokuCfg.strategyParams, isA<IchimokuParams>());
    });
  });

  group('BacktestConfig.copyWith strategy switch', () {
    test('strategy switch resets param defaults when params not provided',
        () {
      final cfg = BacktestConfig(
        strategyKind: StrategyKind.bbRsi,
        strategyParams: const BbRsiParams(bbPeriod: 42),
      );
      // copyWith with new strategyKind AND new default params bundle —
      // this is what setStrategyKind() does inside the provider.
      final switched = cfg.copyWith(
        strategyKind: StrategyKind.utBot,
        strategy: StrategyKind.utBot.displayLabel,
        strategyParams: defaultUtBotParams(),
      );
      expect(switched.strategyKind, StrategyKind.utBot);
      expect(switched.strategyParams, isA<UtBotParams>());
      expect(switched.strategy, 'UT Bot');
    });

    test('copyWith without strategyParams keeps existing params (asserted)',
        () {
      final cfg = BacktestConfig(
        strategyKind: StrategyKind.bbRsi,
        strategyParams: const BbRsiParams(bbPeriod: 42),
      );
      final copied = cfg.copyWith(symbol: 'ETHUSDT');
      expect(copied.strategyKind, StrategyKind.bbRsi);
      expect((copied.strategyParams as BbRsiParams).bbPeriod, 42);
    });
  });

  group('BacktestConfig type-discipline assert', () {
    test('asserts when strategyKind=utBot is paired with BbRsiParams', () {
      expect(
        () => BacktestConfig(
          strategyKind: StrategyKind.utBot,
          strategyParams: const BbRsiParams(),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts when strategyKind=ichimoku is paired with UtBotParams',
        () {
      expect(
        () => BacktestConfig(
          strategyKind: StrategyKind.ichimoku,
          strategyParams: const UtBotParams(),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('BacktestProvider strategy switching', () {
    test('setStrategyKind swaps params and resets optimized flag', () {
      final p = BacktestProvider();
      expect(p.config.strategyKind, StrategyKind.bbRsi);

      p.setStrategyKind(StrategyKind.utBot);
      expect(p.config.strategyKind, StrategyKind.utBot);
      expect(p.config.strategyParams, isA<UtBotParams>());
      expect(p.usingOptimizedParams, isFalse);

      p.setStrategyKind(StrategyKind.ichimoku);
      expect(p.config.strategyParams, isA<IchimokuParams>());

      p.setStrategyKind(StrategyKind.bbRsi);
      expect(p.config.strategyParams, isA<BbRsiParams>());
    });

    test('setStrategyKind is a no-op when kind unchanged', () {
      final p = BacktestProvider();
      var notifyCount = 0;
      p.addListener(() => notifyCount++);

      p.setStrategyKind(StrategyKind.bbRsi);
      expect(notifyCount, 0);
    });

    test('updateStrategyParams asserts type matches active strategyKind',
        () {
      final p = BacktestProvider();
      p.setStrategyKind(StrategyKind.utBot);
      expect(
        () => p.updateStrategyParams(const BbRsiParams()),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('BacktestProvider applyOptimizedParams', () {
    test('no-ops when active strategy is not BB+RSI', () {
      final p = BacktestProvider();
      p.setStrategyKind(StrategyKind.utBot);
      final beforeParams = p.config.strategyParams;

      p.applyOptimizedParams(const BbRsiParams(bbPeriod: 99));

      expect(p.config.strategyParams, same(beforeParams));
      expect(p.usingOptimizedParams, isFalse);
    });

    test('applies when active strategy IS BB+RSI', () {
      final p = BacktestProvider();
      p.applyOptimizedParams(const BbRsiParams(bbPeriod: 99));
      expect((p.config.strategyParams as BbRsiParams).bbPeriod, 99);
      expect(p.usingOptimizedParams, isTrue);
    });
  });

  group('factory helpers', () {
    test('defaultParamsFor returns the right type per kind', () {
      expect(defaultParamsFor(StrategyKind.bbRsi), isA<BbRsiParams>());
      expect(defaultParamsFor(StrategyKind.utBot), isA<UtBotParams>());
      expect(defaultParamsFor(StrategyKind.ichimoku), isA<IchimokuParams>());
    });
  });
}
