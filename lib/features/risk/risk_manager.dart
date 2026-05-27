/// Risk manager — Welle B4.3.
///
/// Central gate-keeper for position opens. Owns the persistent
/// [RiskConfig] and the latest [RiskAssessment]; every consumer that wants
/// to open a position (paper today, live in a follow-up wave) goes through
/// [canOpenPosition]. The manager itself does no position-sizing — it only
/// answers `pass / fail` for the proposed size against the configured caps.
///
/// State surface:
///   * `config` (load-once, save-on-write) — pulled from shared_preferences
///     on first `loadConfig()`. Kill-switch state is part of the config so
///     the trip survives an app restart.
///   * `lastAssessment` — replaced on every `assess()` call, broadcast via
///     `notifyListeners()` so UI cards rebuild against the freshest numbers.
///
/// Test seam:
///   * `RiskManager(prefsLoader: ...)` injects a custom SharedPreferences
///     loader so tests can prime an in-memory `setMockInitialValues({...})`
///     and still exercise the same load/save code path.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/logging/app_log.dart';
import '../paper/paper_session.dart';
import 'risk_assessment.dart';
import 'risk_config.dart';

const String _tag = 'RiskManager';

/// Test-injectable factory that resolves a [SharedPreferences] instance.
/// Default fetches the singleton via `SharedPreferences.getInstance()`.
typedef SharedPreferencesLoader = Future<SharedPreferences> Function();

Future<SharedPreferences> _defaultPrefsLoader() =>
    SharedPreferences.getInstance();

class RiskManager extends ChangeNotifier {
  RiskManager({SharedPreferencesLoader? prefsLoader})
      : _prefsLoader = prefsLoader ?? _defaultPrefsLoader;

  final SharedPreferencesLoader _prefsLoader;

  RiskConfig _config = RiskConfig.defaults();
  RiskAssessment _lastAssessment = RiskAssessment.neutral();
  bool _loaded = false;

  // ─── Getters ────────────────────────────────────────────────────────────

  RiskConfig get config => _config;
  RiskAssessment get lastAssessment => _lastAssessment;
  bool get isLoaded => _loaded;

  /// True iff the persisted kill-switch flag is currently set. Convenience
  /// for UI gating (e.g. show the "Reset" button) — equivalent to
  /// `config.killSwitchActive`.
  bool get killSwitchActive => _config.killSwitchActive;

  // ─── Persistence ────────────────────────────────────────────────────────

  /// Pull the persisted config into memory. Falls back to
  /// [RiskConfig.defaults] when nothing is stored or the stored blob is
  /// unreadable. Idempotent — calling twice is fine, the second call just
  /// re-reads the same bytes.
  Future<void> loadConfig() async {
    try {
      final prefs = await _prefsLoader();
      _config = RiskConfig.loadFrom(prefs);
      _loaded = true;
      notifyListeners();
    } catch (e, st) {
      AppLog.error(_tag, 'Failed to load risk config: $e', e, st);
    }
  }

  /// Persist [next] and broadcast the change. The persisted blob is the only
  /// source of truth — the in-memory `_config` is updated only after the
  /// write returns so a failed persist leaves the cached config matching
  /// disk.
  Future<void> saveConfig(RiskConfig next) async {
    try {
      final prefs = await _prefsLoader();
      await next.persistTo(prefs);
      _config = next;
      _loaded = true;
      notifyListeners();
    } catch (e, st) {
      AppLog.error(_tag, 'Failed to save risk config: $e', e, st);
    }
  }

  // ─── Assessment ─────────────────────────────────────────────────────────

  /// Pure function — derive the four live indicators from `session` state
  /// and produce a [RiskAssessment] against the active [RiskConfig]. Does
  /// *not* read `_lastAssessment` and does *not* notify; callers that want
  /// the broadcast pass through [refreshAssessment] instead.
  RiskAssessment assess(PaperSession session) {
    final dailyPnlPct = session.totalPnlPercent;
    final drawdownPct = _computeDrawdownPct(session);
    final consecLosses = _consecutiveLosses(session);

    final breached = <RiskGate>{};
    if (dailyPnlPct <= -_config.maxDailyLossPct) {
      breached.add(RiskGate.dailyLoss);
    }
    if (drawdownPct >= _config.maxDrawdownPct) {
      breached.add(RiskGate.drawdown);
    }
    if (consecLosses >= _config.maxConsecutiveLosses) {
      breached.add(RiskGate.consecutiveLosses);
    }
    if (_config.killSwitchActive) {
      breached.add(RiskGate.killSwitch);
    }

    return RiskAssessment(
      currentDailyPnlPct: dailyPnlPct,
      currentDrawdownPct: drawdownPct,
      currentConsecutiveLosses: consecLosses,
      killSwitchActive: _config.killSwitchActive,
      breachedGates: breached,
    );
  }

  /// Re-run [assess], cache the result, broadcast to listeners. Returns the
  /// fresh assessment so call sites can decide-and-display in one step.
  RiskAssessment refreshAssessment(PaperSession session) {
    _lastAssessment = assess(session);
    notifyListeners();
    return _lastAssessment;
  }

  /// True iff [session] passes every gate AND the proposed notional fits
  /// inside `maxPositionRiskPct` of the current equity. The kill-switch
  /// always forces `false` — even when every other gate would pass.
  bool canOpenPosition(
    PaperSession session, {
    required double proposedNotional,
  }) {
    final assessment = assess(session);
    if (!assessment.allGatesPass) return false;
    if (_config.killSwitchActive) return false;

    final equity = session.equity;
    if (equity <= 0) return false;
    final notionalCapPct = (proposedNotional / equity) * 100.0;
    if (notionalCapPct > _config.maxPositionRiskPct) return false;
    return true;
  }

  // ─── Kill switch ────────────────────────────────────────────────────────

  /// Trip the kill switch. Persists the change so it survives an app
  /// restart, broadcasts an error-level log entry with the supplied
  /// `reason`, and forces [canOpenPosition] to `false` on every subsequent
  /// call until [resetKillSwitch] is called.
  Future<void> activateKillSwitch({required String reason}) async {
    if (_config.killSwitchActive) return; // idempotent
    AppLog.error(_tag, 'Kill switch activated: $reason');
    await saveConfig(_config.copyWith(killSwitchActive: true));
  }

  /// Manually clear the kill switch. Logs at warn level so the operator
  /// can see a reset in the live log without it tipping the error counter.
  Future<void> resetKillSwitch() async {
    if (!_config.killSwitchActive) return; // idempotent
    AppLog.warn(_tag, 'Kill switch reset');
    await saveConfig(_config.copyWith(killSwitchActive: false));
  }

  // ─── Internals ──────────────────────────────────────────────────────────

  /// Drawdown vs. session peak — peak is the max of (initialBalance, any
  /// equity-curve point, current equity). Falls back to 0 when peak is
  /// non-positive (degenerate session config).
  double _computeDrawdownPct(PaperSession session) {
    double peak = session.config.initialBalance;
    for (final p in session.equityCurve) {
      if (p.equity > peak) peak = p.equity;
    }
    if (session.equity > peak) peak = session.equity;
    if (peak <= 0) return 0.0;
    final dd = ((peak - session.equity) / peak) * 100.0;
    return dd < 0 ? 0.0 : dd;
  }

  /// Count of closed trades from the end whose `pnl < 0`. Stops at the first
  /// non-negative `pnl`. Empty trade list ⇒ 0.
  int _consecutiveLosses(PaperSession session) {
    final trades = session.closedTrades;
    var count = 0;
    for (var i = trades.length - 1; i >= 0; i--) {
      if (trades[i].pnl < 0) {
        count++;
      } else {
        break;
      }
    }
    return count;
  }
}
