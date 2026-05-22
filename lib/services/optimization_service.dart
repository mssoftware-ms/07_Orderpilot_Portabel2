/// Grid-search parameter optimizer for BB+RSI strategy.
///
/// Generates all parameter combinations within defined ranges,
/// runs backtests for each, and returns the top results sorted
/// by Sharpe Ratio (primary) then Profit Factor (secondary).
library;

import '../core/models/candle.dart';
import 'backtest_service.dart';

// =============================================================================
// FROZEN: Phase 1+2 NOT COMPLETE.
// Engine bugs (F-02..F-04) and strategy verification (Phase 2) are open.
// Any results from this service are unreliable until Gesamtplan section 5 unlocked.
// DO NOT delete, DO NOT use in UI. Re-enable per checklist in Gesamtplan section 5.
// =============================================================================

// ─── Parameter Range Definition ─────────────────────────────────────────────

/// Defines a range of values for a single parameter.
class ParamRange {
  final double min;
  final double max;
  final double step;

  const ParamRange({required this.min, required this.max, required this.step});

  /// Generate all discrete values in this range.
  List<double> get values {
    final result = <double>[];
    for (double v = min; v <= max + step * 0.01; v += step) {
      result.add(_round(v));
    }
    return result;
  }

  int get count => values.length;

  static double _round(double v) =>
      (v * 1000).roundToDouble() / 1000; // avoid FP drift
}

/// Default parameter ranges for grid search.
class DefaultRanges {
  static const bbPeriod = ParamRange(min: 10, max: 50, step: 5);
  static const bbStdDev = ParamRange(min: 1.0, max: 3.0, step: 0.5);
  static const rsiPeriod = ParamRange(min: 7, max: 30, step: 3);
  static const rsiOversold = ParamRange(min: 20, max: 40, step: 5);
  static const rsiOverbought = ParamRange(min: 60, max: 80, step: 5);

  static int get totalCombinations =>
      bbPeriod.count *
      bbStdDev.count *
      rsiPeriod.count *
      rsiOversold.count *
      rsiOverbought.count;
}

// ─── Result Models ──────────────────────────────────────────────────────────

/// A single optimization trial result.
class OptimizationTrial {
  final BbRsiParams params;
  final double sharpeRatio;
  final double profitFactor;
  final double totalReturn;
  final double winRate;
  final double maxDrawdownPercent;
  final int totalTrades;

  const OptimizationTrial({
    required this.params,
    required this.sharpeRatio,
    required this.profitFactor,
    required this.totalReturn,
    required this.winRate,
    required this.maxDrawdownPercent,
    required this.totalTrades,
  });

  /// Composite score: Sharpe is primary, PF is tiebreaker.
  double get score => sharpeRatio * 1000 + profitFactor;
}

/// Complete optimization result containing top parameter combinations.
class OptimizationResult {
  final List<OptimizationTrial> topResults;
  final int totalCombinations;
  final int combinationsRun;
  final Duration elapsed;

  const OptimizationResult({
    required this.topResults,
    required this.totalCombinations,
    required this.combinationsRun,
    required this.elapsed,
  });

  /// Best parameters (highest Sharpe + PF).
  BbRsiParams? get bestParams =>
      topResults.isNotEmpty ? topResults.first.params : null;
}

// ─── Progress Callback ──────────────────────────────────────────────────────

/// Callback for reporting optimization progress.
typedef OptimizationProgressCallback = void Function(
    int current, int total, Duration elapsed);

// ─── Grid Search Optimizer ──────────────────────────────────────────────────

class GridSearchOptimizer {
  /// Run grid search optimization.
  ///
  /// This should be called inside a compute() isolate for UI responsiveness.
  /// [progressCallback] is called periodically (not from isolate — use
  /// the isolate-compatible [optimizeInIsolate] instead for progress).
  static OptimizationResult optimize({
    required List<CandleData> candles,
    required double initialBalance,
    required double feeRate,
    ParamRange bbPeriodRange = DefaultRanges.bbPeriod,
    ParamRange bbStdDevRange = DefaultRanges.bbStdDev,
    ParamRange rsiPeriodRange = DefaultRanges.rsiPeriod,
    ParamRange rsiOversoldRange = DefaultRanges.rsiOversold,
    ParamRange rsiOverboughtRange = DefaultRanges.rsiOverbought,
    int topN = 10,
  }) {
    final stopwatch = Stopwatch()..start();
    final trials = <OptimizationTrial>[];
    int count = 0;

    final bbPeriods = bbPeriodRange.values;
    final bbStdDevs = bbStdDevRange.values;
    final rsiPeriods = rsiPeriodRange.values;
    final rsiOversolds = rsiOversoldRange.values;
    final rsiOverboughts = rsiOverboughtRange.values;

    final total = bbPeriods.length *
        bbStdDevs.length *
        rsiPeriods.length *
        rsiOversolds.length *
        rsiOverboughts.length;

    for (final bbP in bbPeriods) {
      for (final bbS in bbStdDevs) {
        for (final rsiP in rsiPeriods) {
          for (final rsiOS in rsiOversolds) {
            for (final rsiOB in rsiOverboughts) {
              // Skip invalid: oversold must be less than overbought
              if (rsiOS >= rsiOB) {
                count++;
                continue;
              }

              final params = BbRsiParams(
                bbPeriod: bbP.toInt(),
                bbStdDev: bbS,
                rsiPeriod: rsiP.toInt(),
                rsiOversold: rsiOS,
                rsiOverbought: rsiOB,
              );

              final result = BacktestService.runBbRsi(
                candles: candles,
                initialBalance: initialBalance,
                feeRate: feeRate,
                params: params,
              );

              final m = result.metrics;

              // Only keep results with at least some trades
              if (m.totalTrades >= 2) {
                trials.add(OptimizationTrial(
                  params: params,
                  sharpeRatio: m.sharpeRatio,
                  profitFactor: m.profitFactor,
                  totalReturn: m.totalPnlPercent,
                  winRate: m.winRate,
                  maxDrawdownPercent: m.maxDrawdownPercent,
                  totalTrades: m.totalTrades,
                ));
              }

              count++;
            }
          }
        }
      }
    }

    // Sort by Sharpe Ratio (desc), then Profit Factor (desc)
    trials.sort((a, b) {
      final cmp = b.sharpeRatio.compareTo(a.sharpeRatio);
      if (cmp != 0) return cmp;
      return b.profitFactor.compareTo(a.profitFactor);
    });

    stopwatch.stop();

    return OptimizationResult(
      topResults: trials.take(topN).toList(),
      totalCombinations: total,
      combinationsRun: count,
      elapsed: stopwatch.elapsed,
    );
  }
}

// ─── Isolate-compatible args ────────────────────────────────────────────────

/// Arguments for running optimization in a compute() isolate.
class OptimizationArgs {
  final List<CandleData> candles;
  final double initialBalance;
  final double feeRate;
  final int topN;

  const OptimizationArgs({
    required this.candles,
    required this.initialBalance,
    required this.feeRate,
    this.topN = 10,
  });
}

/// Top-level function for compute() isolate.
OptimizationResult runOptimizationIsolate(OptimizationArgs args) {
  return GridSearchOptimizer.optimize(
    candles: args.candles,
    initialBalance: args.initialBalance,
    feeRate: args.feeRate,
    topN: args.topN,
  );
}
