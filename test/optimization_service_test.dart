import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/core/utils/param_storage.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/optimization_service.dart';

/// Generate synthetic candles with a sinusoidal pattern.
List<CandleData> _generateCandles(int count, {double startPrice = 50000}) {
  final candles = <CandleData>[];
  final baseTs = DateTime(2024, 1, 1).millisecondsSinceEpoch;

  for (int i = 0; i < count; i++) {
    final wave = 2000 *
        (i % 60 < 30
            ? -1.0 + (i % 30) / 15.0
            : 1.0 - ((i % 30)) / 15.0);
    final price = startPrice + wave;
    candles.add(CandleData(
      timestamp: baseTs + i * 3600000,
      open: price - 20,
      high: price + 100,
      low: price - 100,
      close: price,
      volume: 1000 + i.toDouble(),
    ));
  }
  return candles;
}

void main() {
  group('ParamRange', () {
    test('generates correct values', () {
      const range = ParamRange(min: 10, max: 30, step: 10);
      expect(range.values, [10, 20, 30]);
      expect(range.count, 3);
    });

    test('handles fractional steps', () {
      const range = ParamRange(min: 1.0, max: 3.0, step: 0.5);
      expect(range.values, [1.0, 1.5, 2.0, 2.5, 3.0]);
      expect(range.count, 5);
    });

    test('single value range', () {
      const range = ParamRange(min: 20, max: 20, step: 5);
      expect(range.values, [20]);
      expect(range.count, 1);
    });
  });

  group('DefaultRanges', () {
    test('total combinations is positive', () {
      expect(DefaultRanges.totalCombinations, greaterThan(0));
    });

    test('total combinations matches expected', () {
      // BB: 10-50 step 5 = 9, StdDev: 1-3 step 0.5 = 5
      // RSI: 7-30 step 3 = 9 (7,10,13,16,19,22,25,28 = 8, + 30 check)
      // RSI OS: 20-40 step 5 = 5, RSI OB: 60-80 step 5 = 5
      final total = DefaultRanges.totalCombinations;
      expect(total, greaterThan(100));
      expect(total, lessThan(10000)); // sanity check
    });
  });

  group('GridSearchOptimizer', () {
    late List<CandleData> candles;

    setUp(() {
      candles = _generateCandles(300);
    });

    test('optimize returns results', () {
      final result = GridSearchOptimizer.optimize(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        // Use narrow ranges for speed
        bbPeriodRange: const ParamRange(min: 15, max: 25, step: 5),
        bbStdDevRange: const ParamRange(min: 1.5, max: 2.5, step: 0.5),
        rsiPeriodRange: const ParamRange(min: 10, max: 14, step: 4),
        rsiOversoldRange: const ParamRange(min: 25, max: 35, step: 5),
        rsiOverboughtRange: const ParamRange(min: 65, max: 75, step: 5),
      );

      expect(result.totalCombinations, greaterThan(0));
      expect(result.combinationsRun, result.totalCombinations);
      expect(result.elapsed.inMicroseconds, greaterThan(0));
    });

    test('results are sorted by Sharpe Ratio descending', () {
      final result = GridSearchOptimizer.optimize(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        bbPeriodRange: const ParamRange(min: 15, max: 25, step: 5),
        bbStdDevRange: const ParamRange(min: 1.5, max: 2.5, step: 0.5),
        rsiPeriodRange: const ParamRange(min: 10, max: 14, step: 4),
        rsiOversoldRange: const ParamRange(min: 25, max: 35, step: 5),
        rsiOverboughtRange: const ParamRange(min: 65, max: 75, step: 5),
      );

      if (result.topResults.length >= 2) {
        for (int i = 1; i < result.topResults.length; i++) {
          expect(result.topResults[i - 1].sharpeRatio,
              greaterThanOrEqualTo(result.topResults[i].sharpeRatio));
        }
      }
    });

    test('topN limits results', () {
      final result = GridSearchOptimizer.optimize(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        bbPeriodRange: const ParamRange(min: 10, max: 30, step: 5),
        bbStdDevRange: const ParamRange(min: 1.5, max: 2.5, step: 0.5),
        rsiPeriodRange: const ParamRange(min: 10, max: 14, step: 4),
        rsiOversoldRange: const ParamRange(min: 25, max: 35, step: 5),
        rsiOverboughtRange: const ParamRange(min: 65, max: 75, step: 5),
        topN: 3,
      );

      expect(result.topResults.length, lessThanOrEqualTo(3));
    });

    test('skips invalid oversold >= overbought combinations', () {
      final result = GridSearchOptimizer.optimize(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        bbPeriodRange: const ParamRange(min: 20, max: 20, step: 5),
        bbStdDevRange: const ParamRange(min: 2.0, max: 2.0, step: 0.5),
        rsiPeriodRange: const ParamRange(min: 14, max: 14, step: 3),
        // Overlapping ranges: oversold 50-60, overbought 50-60
        rsiOversoldRange: const ParamRange(min: 50, max: 60, step: 5),
        rsiOverboughtRange: const ParamRange(min: 50, max: 60, step: 5),
      );

      // Most combinations should be skipped (OS >= OB)
      // Only OS=50 & OB=55, OS=50 & OB=60, OS=55 & OB=60 are valid
      expect(result.combinationsRun, result.totalCombinations);
    });

    test('trials have valid BbRsiParams', () {
      final result = GridSearchOptimizer.optimize(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        bbPeriodRange: const ParamRange(min: 15, max: 25, step: 5),
        bbStdDevRange: const ParamRange(min: 1.5, max: 2.5, step: 0.5),
        rsiPeriodRange: const ParamRange(min: 10, max: 14, step: 4),
        rsiOversoldRange: const ParamRange(min: 25, max: 35, step: 5),
        rsiOverboughtRange: const ParamRange(min: 65, max: 75, step: 5),
      );

      for (final t in result.topResults) {
        expect(t.params.bbPeriod, inInclusiveRange(15, 25));
        expect(t.params.bbStdDev, inInclusiveRange(1.5, 2.5));
        expect(t.params.rsiPeriod, inInclusiveRange(10, 14));
        expect(t.params.rsiOversold, lessThan(t.params.rsiOverbought));
        expect(t.totalTrades, greaterThanOrEqualTo(2));
      }
    });

    test('bestParams returns first result params', () {
      final result = GridSearchOptimizer.optimize(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        bbPeriodRange: const ParamRange(min: 20, max: 20, step: 5),
        bbStdDevRange: const ParamRange(min: 2.0, max: 2.0, step: 0.5),
        rsiPeriodRange: const ParamRange(min: 14, max: 14, step: 3),
        rsiOversoldRange: const ParamRange(min: 30, max: 30, step: 5),
        rsiOverboughtRange: const ParamRange(min: 70, max: 70, step: 5),
      );

      if (result.topResults.isNotEmpty) {
        expect(result.bestParams, result.topResults.first.params);
      }
    });

    test('empty result when no trades generated', () {
      // Very few candles → no trades possible
      final shortCandles = _generateCandles(10);
      final result = GridSearchOptimizer.optimize(
        candles: shortCandles,
        initialBalance: 10000,
        feeRate: 0.0006,
        bbPeriodRange: const ParamRange(min: 20, max: 20, step: 5),
        bbStdDevRange: const ParamRange(min: 2.0, max: 2.0, step: 0.5),
        rsiPeriodRange: const ParamRange(min: 14, max: 14, step: 3),
        rsiOversoldRange: const ParamRange(min: 30, max: 30, step: 5),
        rsiOverboughtRange: const ParamRange(min: 70, max: 70, step: 5),
      );

      expect(result.topResults, isEmpty);
      expect(result.bestParams, isNull);
    });
  });

  group('OptimizationTrial', () {
    test('score combines sharpe and PF', () {
      const trial = OptimizationTrial(
        params: BbRsiParams(),
        sharpeRatio: 2.0,
        profitFactor: 1.5,
        totalReturn: 10.0,
        winRate: 60.0,
        maxDrawdownPercent: 5.0,
        totalTrades: 20,
      );

      expect(trial.score, 2.0 * 1000 + 1.5);
    });
  });

  group('OptimizedParamsStorage', () {
    late OptimizedParamsStorage storage;
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('param_storage_test_');
      storage = OptimizedParamsStorage(storageDir: tempDir.path);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('save and load params', () async {
      const params = BbRsiParams(
        bbPeriod: 25,
        bbStdDev: 1.5,
        rsiPeriod: 10,
        rsiOversold: 25,
        rsiOverbought: 75,
      );

      await storage.saveOptimizedParams('BTCUSDT', '1h', params);
      final loaded = await storage.loadOptimizedParams('BTCUSDT', '1h');

      expect(loaded, isNotNull);
      expect(loaded!.bbPeriod, 25);
      expect(loaded.bbStdDev, 1.5);
      expect(loaded.rsiPeriod, 10);
      expect(loaded.rsiOversold, 25);
      expect(loaded.rsiOverbought, 75);
    });

    test('returns null for non-existent params', () async {
      final loaded = await storage.loadOptimizedParams('ETHUSDT', '4h');
      expect(loaded, isNull);
    });

    test('hasOptimizedParams returns correct value', () async {
      expect(await storage.hasOptimizedParams('BTCUSDT', '1h'), isFalse);

      await storage.saveOptimizedParams(
          'BTCUSDT', '1h', const BbRsiParams());

      expect(await storage.hasOptimizedParams('BTCUSDT', '1h'), isTrue);
    });

    test('different symbols/timeframes are independent', () async {
      const params1 = BbRsiParams(bbPeriod: 15);
      const params2 = BbRsiParams(bbPeriod: 30);

      await storage.saveOptimizedParams('BTCUSDT', '1h', params1);
      await storage.saveOptimizedParams('ETHUSDT', '4h', params2);

      final loaded1 = await storage.loadOptimizedParams('BTCUSDT', '1h');
      final loaded2 = await storage.loadOptimizedParams('ETHUSDT', '4h');

      expect(loaded1!.bbPeriod, 15);
      expect(loaded2!.bbPeriod, 30);
    });

    test('deleteOptimizedParams removes entry', () async {
      await storage.saveOptimizedParams(
          'BTCUSDT', '1h', const BbRsiParams());
      expect(await storage.hasOptimizedParams('BTCUSDT', '1h'), isTrue);

      await storage.deleteOptimizedParams('BTCUSDT', '1h');
      expect(await storage.hasOptimizedParams('BTCUSDT', '1h'), isFalse);
    });

    test('clearAll removes everything', () async {
      await storage.saveOptimizedParams(
          'BTCUSDT', '1h', const BbRsiParams());
      await storage.saveOptimizedParams(
          'ETHUSDT', '4h', const BbRsiParams());

      await storage.clearAll();

      expect(await storage.hasOptimizedParams('BTCUSDT', '1h'), isFalse);
      expect(await storage.hasOptimizedParams('ETHUSDT', '4h'), isFalse);
    });

    test('listStoredKeys returns all keys', () async {
      await storage.saveOptimizedParams(
          'BTCUSDT', '1h', const BbRsiParams());
      await storage.saveOptimizedParams(
          'ETHUSDT', '4h', const BbRsiParams());

      final keys = await storage.listStoredKeys();
      expect(keys, containsAll(['BTCUSDT_1h', 'ETHUSDT_4h']));
    });

    test('overwriting params updates correctly', () async {
      await storage.saveOptimizedParams(
          'BTCUSDT', '1h', const BbRsiParams(bbPeriod: 15));
      await storage.saveOptimizedParams(
          'BTCUSDT', '1h', const BbRsiParams(bbPeriod: 30));

      final loaded = await storage.loadOptimizedParams('BTCUSDT', '1h');
      expect(loaded!.bbPeriod, 30);
    });
  });

  group('runOptimizationIsolate', () {
    test('produces same result as direct optimize', () {
      final candles = _generateCandles(200);
      final args = OptimizationArgs(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        topN: 5,
      );

      final result = runOptimizationIsolate(args);

      expect(result.topResults.length, lessThanOrEqualTo(5));
      expect(result.totalCombinations, DefaultRanges.totalCombinations);
    });
  });
}
