/// Typed wrapper for the `metrics_json` blob stored on each trial row.
///
/// Welle O3-B2: the optimizer writes a fixed-shape JSON object:
///   {
///     "total_trades": int,
///     "total_pnl": float,
///     "win_rate": float (0..100),
///     "sharpe_ratio": float,
///     "max_drawdown_pct": float (0..100),
///     "profit_factor": float (Infinity allowed),
///     "final_equity": float
///   }
///
/// Missing fields default to 0/empty so a partial blob still parses; a
/// malformed payload (not a JSON object) throws — the DB layer catches
/// and routes through AppLog.warn before skipping the row.
library;

import 'dart:convert';

class TrialMetrics {
  final int totalTrades;
  final double totalPnl;
  final double winRate;
  final double sharpeRatio;
  final double maxDrawdownPct;
  final double profitFactor;
  final double finalEquity;

  const TrialMetrics({
    required this.totalTrades,
    required this.totalPnl,
    required this.winRate,
    required this.sharpeRatio,
    required this.maxDrawdownPct,
    required this.profitFactor,
    required this.finalEquity,
  });

  factory TrialMetrics.fromJsonString(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      throw const FormatException('metrics_json is not a JSON object');
    }
    return TrialMetrics(
      totalTrades: _asInt(decoded['total_trades']),
      totalPnl: _asDouble(decoded['total_pnl']),
      winRate: _asDouble(decoded['win_rate']),
      sharpeRatio: _asDouble(decoded['sharpe_ratio']),
      maxDrawdownPct: _asDouble(decoded['max_drawdown_pct']),
      profitFactor: _asDouble(decoded['profit_factor']),
      finalEquity: _asDouble(decoded['final_equity']),
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static double _asDouble(Object? v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) {
      // Optuna's Python writer can emit `Infinity` / `-Infinity` strings —
      // standard `double.tryParse` already handles those.
      return double.tryParse(v) ?? 0.0;
    }
    return 0.0;
  }
}
