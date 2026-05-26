/// Single Optuna trial row from the `trials` table.
///
/// Welle O3-B2: unwraps the `{"values": {...}}` wrapper from
/// `params_json` so the UI gets a plain `Map<String, double>`. Score is
/// surfaced as-is (including `double.negativeInfinity` for 0-trade
/// trials — the UI filters and clamps).
library;

import 'dart:convert';

import 'trial_metrics.dart';

class Trial {
  final int id;
  final int studyId;
  final int trialId;
  final Map<String, double> params;
  final TrialMetrics metrics;
  final double score;
  final DateTime createdAt;

  const Trial({
    required this.id,
    required this.studyId,
    required this.trialId,
    required this.params,
    required this.metrics,
    required this.score,
    required this.createdAt,
  });

  factory Trial.fromRow(Map<String, Object?> row) {
    final paramsJson = row['params_json'] as String;
    final decoded = jsonDecode(paramsJson);
    Map<String, dynamic> valuesMap;
    if (decoded is Map && decoded['values'] is Map) {
      valuesMap = Map<String, dynamic>.from(decoded['values'] as Map);
    } else if (decoded is Map) {
      // Tolerate older payloads written without the "values" wrapper.
      valuesMap = Map<String, dynamic>.from(decoded);
    } else {
      throw const FormatException('params_json is not a JSON object');
    }
    final params = <String, double>{
      for (final e in valuesMap.entries)
        e.key: (e.value is num)
            ? (e.value as num).toDouble()
            : double.tryParse(e.value.toString()) ?? 0.0,
    };

    return Trial(
      id: row['id'] as int,
      studyId: row['study_id'] as int,
      trialId: row['trial_id'] as int,
      params: params,
      metrics: TrialMetrics.fromJsonString(row['metrics_json'] as String),
      score: _asDouble(row['score']),
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  /// True for trials whose score is non-finite (`-inf`/`+inf`/`NaN`).
  /// The Welle-O3-B2 UI greys these out and excludes them from top-10.
  bool get scoreIsFinite => score.isFinite;

  static double _asDouble(Object? v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? double.nan;
    return double.nan;
  }
}
