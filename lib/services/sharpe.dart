/// Timeframe-aware Sharpe ratio helpers (Plan §3.4 F-03).
///
/// Mirrors `rust/trading_engine/src/models/metrics.rs` bit-for-bit so the
/// Dart and Rust engines produce numerically identical Sharpe values.
///
/// Sharpe = mean(returns) / stdev(returns) * sqrt(periodsPerYear(tf)).
/// Risk-free rate = 0 (Crypto 24/7, no benchmark) and is NOT configurable.
/// Returns must be **equity-curve returns** (one per candle close), not
/// trade-PnL percentages.
library;

import 'dart:math' as math;

import '../core/models/timeframe.dart';

/// Number of `tf`-sized periods in one Crypto 24/7 year.
///
/// M1/M5/M15/H1/H4/D1 are normative per Plan §3.4 F-03. M30 and W1 fill the
/// remainder of the Timeframe enum with the natural extension so all enum
/// variants are total.
double periodsPerYear(Timeframe tf) {
  switch (tf) {
    case Timeframe.m1:
      return 525600.0;
    case Timeframe.m5:
      return 105120.0;
    case Timeframe.m15:
      return 35040.0;
    case Timeframe.m30:
      return 17520.0;
    case Timeframe.h1:
      return 8760.0;
    case Timeframe.h4:
      return 2190.0;
    case Timeframe.d1:
      return 365.0;
    case Timeframe.w1:
      return 52.0;
  }
}

/// Annualized Sharpe ratio of an equity-curve return series.
///
/// Empty input → 0. Mathematically-zero variance (all returns identical) →
/// 0 — detected via min == max equality so accumulated float-rounding
/// noise doesn't explode `mean / stdev` on a flat series.
double annualizedSharpe(List<double> returns, Timeframe tf) {
  if (returns.isEmpty) return 0.0;

  double minR = double.infinity;
  double maxR = double.negativeInfinity;
  for (final r in returns) {
    if (r < minR) minR = r;
    if (r > maxR) maxR = r;
  }
  if (minR == maxR) return 0.0;

  final n = returns.length;
  double sum = 0;
  for (final r in returns) {
    sum += r;
  }
  final mean = sum / n;
  double sqsum = 0;
  for (final r in returns) {
    final d = r - mean;
    sqsum += d * d;
  }
  final variance = sqsum / n;
  final stdev = math.sqrt(variance);
  if (stdev == 0.0) return 0.0;
  return (mean / stdev) * math.sqrt(periodsPerYear(tf));
}

/// Convert an equity curve (one value per candle close) into per-candle
/// returns. Output length is `equity.length - 1`. Empty / single-point
/// curves produce an empty list. A non-positive previous equity yields a
/// 0.0 return (degenerate wipe-out, avoids NaN).
List<double> equityCurveReturns(List<double> equity) {
  if (equity.length < 2) return const <double>[];
  final out = <double>[];
  for (int i = 1; i < equity.length; i++) {
    final prev = equity[i - 1];
    out.add(prev > 0 ? (equity[i] - prev) / prev : 0.0);
  }
  return out;
}
