/// Live-mode eligibility aggregate — Welle B4.3-5.
///
/// Pure value object that aggregates the three independent conditions that
/// must hold simultaneously before the Account-Screen live-trading toggle
/// can be unlocked in a future wave. **This wave only reports the state**
/// — the toggle's `onChanged: null` stays in place; the actual enable lands
/// behind an explicit user confirmation in a follow-up wave.
///
/// Decoupling readout from enabling keeps the wave's risk surface minimal:
/// even if every condition flips to `true`, nothing here can light the
/// toggle up. The next wave only has to thread `LiveModeEligibility.isEligible`
/// into the switch's `onChanged` parameter and add the confirm-dialog.
library;

import 'package:flutter/foundation.dart';

import '../exchange/bitunix_connection_provider.dart';
import 'risk_manager.dart';

@immutable
class LiveModeEligibility {
  /// True when the [RiskManager] has loaded a config whose four numeric
  /// caps are all strictly positive. The default config satisfies this,
  /// so a fresh user only fails this gate while [RiskManager.loadConfig]
  /// is still in flight at app start.
  final bool allRiskGatesActive;

  /// True when [BitunixConnectionProvider.status] is currently
  /// `BitunixConnectionStatus.connected`. Transient `connecting` /
  /// `error` / `disconnected` states all fail this gate.
  final bool exchangeConnected;

  /// True when the [RiskManager]'s kill switch is *not* tripped. An active
  /// kill switch flips this to false even if the other two gates pass.
  final bool killSwitchInactive;

  const LiveModeEligibility({
    required this.allRiskGatesActive,
    required this.exchangeConnected,
    required this.killSwitchInactive,
  });

  /// `true` iff every conjunct is `true`. The future live toggle's
  /// `onChanged` parameter is meant to be the only consumer of this flag.
  bool get isEligible =>
      allRiskGatesActive && exchangeConnected && killSwitchInactive;

  /// Build an eligibility snapshot from the live providers. Pure read —
  /// does not mutate either provider and does not subscribe to listeners.
  /// The Account-Screen rebuilds on either provider's notification and
  /// re-runs [evaluate] in `build`.
  static LiveModeEligibility evaluate({
    required RiskManager riskManager,
    required BitunixConnectionProvider exchangeProvider,
  }) {
    final cfg = riskManager.config;
    final allActive = riskManager.isLoaded &&
        cfg.maxPositionRiskPct > 0 &&
        cfg.maxDailyLossPct > 0 &&
        cfg.maxDrawdownPct > 0 &&
        cfg.maxConsecutiveLosses > 0;
    return LiveModeEligibility(
      allRiskGatesActive: allActive,
      exchangeConnected:
          exchangeProvider.status == BitunixConnectionStatus.connected,
      killSwitchInactive: !riskManager.killSwitchActive,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveModeEligibility &&
          allRiskGatesActive == other.allRiskGatesActive &&
          exchangeConnected == other.exchangeConnected &&
          killSwitchInactive == other.killSwitchInactive;

  @override
  int get hashCode => Object.hash(
        allRiskGatesActive,
        exchangeConnected,
        killSwitchInactive,
      );

  @override
  String toString() =>
      'LiveModeEligibility(risk=$allRiskGatesActive, '
      'exchange=$exchangeConnected, killSwitchInactive=$killSwitchInactive, '
      'isEligible=$isEligible)';
}
