/// Risk assessment snapshot — Welle B4.3.
///
/// Pure value object describing the result of a single
/// `RiskManager.assess(session)` call. Captures the four live indicators
/// (daily PnL, drawdown, consecutive losses, kill-switch state) and the set
/// of gates that tripped against the active [RiskConfig].
///
/// The assessment is a snapshot — calling `assess` again produces a fresh
/// instance; it never mutates an existing one. This keeps the UI rebuild
/// surface narrow (the manager broadcasts a notifyListeners after each
/// assess) and lets tests pin specific session states without provider
/// coupling.
library;

import 'package:flutter/foundation.dart';

/// Discrete gate kinds. The set of breached gates is what determines whether
/// a position can open. Kept separate from the numeric snapshot fields so a
/// future gate (e.g. session-time-of-day filter) can land without breaking
/// older serialisations.
enum RiskGate {
  positionRisk,
  dailyLoss,
  drawdown,
  consecutiveLosses,
  killSwitch,
}

@immutable
class RiskAssessment {
  /// Daily PnL as a percentage of the session's initial balance. Negative
  /// when the session is in a loss. Used as the metric the [maxDailyLossPct]
  /// gate is compared against (i.e. gate trips when `currentDailyPnlPct <=
  /// -maxDailyLossPct`).
  final double currentDailyPnlPct;

  /// Current drawdown from peak equity, as a percentage of the peak. Always
  /// non-negative; `0` means equity is at the peak. Gate trips when
  /// `currentDrawdownPct >= maxDrawdownPct`.
  final double currentDrawdownPct;

  /// Count of the most recent consecutive losing trades. Resets to 0 on the
  /// first winning trade. Gate trips when this reaches
  /// `maxConsecutiveLosses`.
  final int currentConsecutiveLosses;

  /// Mirrors [RiskConfig.killSwitchActive] at the time of the assessment.
  /// When `true`, [breachedGates] always contains [RiskGate.killSwitch] and
  /// [allGatesPass] is forced to `false`.
  final bool killSwitchActive;

  /// Exact set of gates that failed for this assessment. Empty set ⇒ all
  /// gates pass. Stable across rebuilds (immutable `Set.unmodifiable`).
  final Set<RiskGate> breachedGates;

  RiskAssessment({
    required this.currentDailyPnlPct,
    required this.currentDrawdownPct,
    required this.currentConsecutiveLosses,
    required this.killSwitchActive,
    required Set<RiskGate> breachedGates,
  }) : breachedGates = Set.unmodifiable(breachedGates);

  /// Convenience for the position-open gate: `true` exactly when no gate has
  /// tripped. Always `false` when the kill-switch is active.
  bool get allGatesPass => breachedGates.isEmpty;

  /// Convenience for the UI summary card.
  bool gateBreached(RiskGate gate) => breachedGates.contains(gate);

  /// "Neutral" assessment used as the seed value in [RiskManager] before the
  /// first `assess` call lands. No gates breached, all live values at 0.
  factory RiskAssessment.neutral() => RiskAssessment(
        currentDailyPnlPct: 0.0,
        currentDrawdownPct: 0.0,
        currentConsecutiveLosses: 0,
        killSwitchActive: false,
        breachedGates: const <RiskGate>{},
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RiskAssessment &&
          currentDailyPnlPct == other.currentDailyPnlPct &&
          currentDrawdownPct == other.currentDrawdownPct &&
          currentConsecutiveLosses == other.currentConsecutiveLosses &&
          killSwitchActive == other.killSwitchActive &&
          _setEquals(breachedGates, other.breachedGates);

  @override
  int get hashCode => Object.hash(
        currentDailyPnlPct,
        currentDrawdownPct,
        currentConsecutiveLosses,
        killSwitchActive,
        Object.hashAllUnordered(breachedGates),
      );

  @override
  String toString() => 'RiskAssessment('
      'dailyPnl=${currentDailyPnlPct.toStringAsFixed(2)}%, '
      'dd=${currentDrawdownPct.toStringAsFixed(2)}%, '
      'consec=$currentConsecutiveLosses, '
      'kill=$killSwitchActive, '
      'breached=${breachedGates.map((g) => g.name).join(",")})';
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final v in a) {
    if (!b.contains(v)) return false;
  }
  return true;
}
