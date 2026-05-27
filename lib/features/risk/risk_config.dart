/// Risk configuration — Welle B4.3.
///
/// Persistent risk limits that gate every paper- and (future) live-trading
/// position open. Stored via shared_preferences as a single JSON blob so a
/// later schema bump can be done in place without migrating individual keys.
///
/// Limits are intentionally session-global in step-3 (no per-symbol /
/// per-strategy splits) — the four levers below are what the user can dial
/// before flipping the future live toggle, and what an emergency kill-switch
/// will trip. Fields are non-sensitive (no API keys, no balances), so plain
/// shared_preferences is sufficient.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Key under which the JSON-serialised [RiskConfig] is stored. Single key
/// keeps the schema atomic: a partial-write crash leaves either the old or
/// the new config intact, never a half-merged hybrid.
const String kRiskConfigPrefsKey = 'b4_3_risk_config_v1';

@immutable
class RiskConfig {
  /// Max risk per single position as a percentage of the current equity.
  /// E.g. `5.0` means the proposed position notional must not exceed 5 % of
  /// the session's equity at the time of the open. Default 5 %.
  final double maxPositionRiskPct;

  /// Max session-relative daily-loss cap (percentage). Computed against
  /// `session.config.initialBalance` so a fixture session that has lost more
  /// than this percentage cannot open more positions. Default 3 %.
  final double maxDailyLossPct;

  /// Max drawdown allowed from session peak equity, in percent of the peak.
  /// Default 10 %. Trailing semantics live in [RiskAssessment]; this struct
  /// only stores the cap.
  final double maxDrawdownPct;

  /// Max consecutive losing trades before the consecutive-losses gate trips.
  /// Default 5.
  final int maxConsecutiveLosses;

  /// When `true`, every [RiskAssessment] is forced to `allGatesPass = false`
  /// and `canOpenPosition` returns `false` unconditionally. Set via
  /// `RiskManager.activateKillSwitch` and only cleared via
  /// `RiskManager.resetKillSwitch`. Persists across app restarts.
  final bool killSwitchActive;

  /// When `true`, the Account-Screen Live-Trading toggle is in the ON
  /// position. Persists across app restarts so an active live session
  /// re-arms on next launch — but the post-load eligibility evaluation
  /// flips it back off the moment any gate is missing (kill-switch
  /// tripped, exchange disconnected, caps cleared). Set via
  /// `RiskManager.enableLiveTrading` / `disableLiveTrading`; the
  /// kill-switch retains precedence and an enable while the switch is
  /// tripped is a logged no-op, never a state flip.
  final bool liveTradingEnabled;

  const RiskConfig({
    required this.maxPositionRiskPct,
    required this.maxDailyLossPct,
    required this.maxDrawdownPct,
    required this.maxConsecutiveLosses,
    required this.killSwitchActive,
    this.liveTradingEnabled = false,
  });

  /// Conservative defaults matched to the pre-task brief: position risk 5 %,
  /// daily loss 3 %, drawdown 10 %, consecutive losses 5, kill-switch
  /// inactive, live-trading off. Used when no config has been persisted yet.
  factory RiskConfig.defaults() => const RiskConfig(
        maxPositionRiskPct: 5.0,
        maxDailyLossPct: 3.0,
        maxDrawdownPct: 10.0,
        maxConsecutiveLosses: 5,
        killSwitchActive: false,
        liveTradingEnabled: false,
      );

  /// Strict-read roundtrip — every numeric field is coerced via `num.toDouble`
  /// so the JSON decoder's int-vs-double distinction doesn't matter (e.g.
  /// `"maxDailyLossPct": 3` decodes to `int 3` and still survives the round
  /// trip).
  factory RiskConfig.fromMap(Map<String, dynamic> map) => RiskConfig(
        maxPositionRiskPct:
            (map['maxPositionRiskPct'] as num?)?.toDouble() ?? 5.0,
        maxDailyLossPct: (map['maxDailyLossPct'] as num?)?.toDouble() ?? 3.0,
        maxDrawdownPct: (map['maxDrawdownPct'] as num?)?.toDouble() ?? 10.0,
        maxConsecutiveLosses: (map['maxConsecutiveLosses'] as num?)?.toInt() ?? 5,
        killSwitchActive: (map['killSwitchActive'] as bool?) ?? false,
        liveTradingEnabled: (map['liveTradingEnabled'] as bool?) ?? false,
      );

  Map<String, dynamic> toMap() => {
        'maxPositionRiskPct': maxPositionRiskPct,
        'maxDailyLossPct': maxDailyLossPct,
        'maxDrawdownPct': maxDrawdownPct,
        'maxConsecutiveLosses': maxConsecutiveLosses,
        'killSwitchActive': killSwitchActive,
        'liveTradingEnabled': liveTradingEnabled,
      };

  RiskConfig copyWith({
    double? maxPositionRiskPct,
    double? maxDailyLossPct,
    double? maxDrawdownPct,
    int? maxConsecutiveLosses,
    bool? killSwitchActive,
    bool? liveTradingEnabled,
  }) =>
      RiskConfig(
        maxPositionRiskPct: maxPositionRiskPct ?? this.maxPositionRiskPct,
        maxDailyLossPct: maxDailyLossPct ?? this.maxDailyLossPct,
        maxDrawdownPct: maxDrawdownPct ?? this.maxDrawdownPct,
        maxConsecutiveLosses: maxConsecutiveLosses ?? this.maxConsecutiveLosses,
        killSwitchActive: killSwitchActive ?? this.killSwitchActive,
        liveTradingEnabled: liveTradingEnabled ?? this.liveTradingEnabled,
      );

  /// Persist this config under [kRiskConfigPrefsKey]. Uses the SharedPreferences
  /// instance passed in so tests can inject a mock-initialised store.
  Future<void> persistTo(SharedPreferences prefs) async {
    await prefs.setString(kRiskConfigPrefsKey, jsonEncode(toMap()));
  }

  /// Load the persisted config, falling back to [RiskConfig.defaults] when no
  /// entry exists or the stored JSON is unreadable (e.g. partial-write
  /// corruption). The fallback is intentionally silent — the only legitimate
  /// reason for a missing/corrupt entry is a first-run or an interrupted
  /// upgrade, and the UI surfaces the active values directly so the user can
  /// immediately re-save if they want.
  static RiskConfig loadFrom(SharedPreferences prefs) {
    final raw = prefs.getString(kRiskConfigPrefsKey);
    if (raw == null || raw.isEmpty) return RiskConfig.defaults();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return RiskConfig.fromMap(decoded);
      }
    } catch (_) {
      // Falls through to defaults.
    }
    return RiskConfig.defaults();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RiskConfig &&
          maxPositionRiskPct == other.maxPositionRiskPct &&
          maxDailyLossPct == other.maxDailyLossPct &&
          maxDrawdownPct == other.maxDrawdownPct &&
          maxConsecutiveLosses == other.maxConsecutiveLosses &&
          killSwitchActive == other.killSwitchActive &&
          liveTradingEnabled == other.liveTradingEnabled;

  @override
  int get hashCode => Object.hash(
        maxPositionRiskPct,
        maxDailyLossPct,
        maxDrawdownPct,
        maxConsecutiveLosses,
        killSwitchActive,
        liveTradingEnabled,
      );

  @override
  String toString() => 'RiskConfig('
      'pos=$maxPositionRiskPct%, '
      'daily=$maxDailyLossPct%, '
      'dd=$maxDrawdownPct%, '
      'consec=$maxConsecutiveLosses, '
      'kill=$killSwitchActive, '
      'live=$liveTradingEnabled)';
}
