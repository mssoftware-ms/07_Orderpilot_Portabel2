/// Engine-shared ADX regime filter section for the Backtest screen.
///
/// Welle O3-B1-4 — same quartet of knobs lives on every strategy
/// (BbRsiParams / UtBotParams / IchimokuParams Welle-R2 wiring), so the
/// Backtest panel surfaces it as ONE widget below the strategy-specific
/// param section. Reading the active param struct via runtime type
/// switch keeps this widget independent of the strategy-kind enum —
/// when a fourth strategy lands, only the inner type-switch grows.
///
/// Param semantics (mirror `strategy_common.dart::regimePassesFilter`):
///   - adxFilterEnabled: switches the gate on/off (default OFF — Welle-R2
///     preserves pre-filter parity bit-exact)
///   - adxThreshold: minimum ADX value for a trade to clear the gate
///   - adxPeriod: Wilder-smoothed lookback for the ADX calculation
///   - adxUseDiConfluence: when ON, blocks Longs unless +DI > -DI and
///     Shorts unless -DI > +DI
library;

import 'package:flutter/material.dart';

import '../../features/backtest/backtest_provider.dart';
import '../../services/backtest_service.dart';
import '../themes/app_theme.dart';
import 'param_slider.dart';

class AdxFilterSection extends StatelessWidget {
  final BacktestProvider provider;

  const AdxFilterSection({super.key, required this.provider});

  /// Reads the active param struct's ADX quartet — returns null if the
  /// strategy doesn't expose ADX params (today every strategy does, so
  /// this is just defensive against future kinds).
  ({bool enabled, double threshold, int period, bool diConfluence})?
      _readAdx() {
    final p = provider.config.strategyParams;
    if (p is BbRsiParams) {
      return (
        enabled: p.adxFilterEnabled,
        threshold: p.adxThreshold,
        period: p.adxPeriod,
        diConfluence: p.adxUseDiConfluence,
      );
    }
    if (p is UtBotParams) {
      return (
        enabled: p.adxFilterEnabled,
        threshold: p.adxThreshold,
        period: p.adxPeriod,
        diConfluence: p.adxUseDiConfluence,
      );
    }
    if (p is IchimokuParams) {
      return (
        enabled: p.adxFilterEnabled,
        threshold: p.adxThreshold,
        period: p.adxPeriod,
        diConfluence: p.adxUseDiConfluence,
      );
    }
    return null;
  }

  /// Writes a new ADX quartet onto the active param struct, preserving
  /// every other field — one branch per known strategy kind. Future
  /// strategies plug in here.
  void _writeAdx({
    bool? enabled,
    double? threshold,
    int? period,
    bool? diConfluence,
  }) {
    final p = provider.config.strategyParams;
    final current = _readAdx();
    if (current == null) return;
    final newEnabled = enabled ?? current.enabled;
    final newThreshold = threshold ?? current.threshold;
    final newPeriod = period ?? current.period;
    final newDi = diConfluence ?? current.diConfluence;

    if (p is BbRsiParams) {
      provider.updateStrategyParams(BbRsiParams(
        bbPeriod: p.bbPeriod,
        bbStdDev: p.bbStdDev,
        bbMaType: p.bbMaType,
        rsiPeriod: p.rsiPeriod,
        rsiOversold: p.rsiOversold,
        rsiOverbought: p.rsiOverbought,
        swingLookbackBars: p.swingLookbackBars,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: p.riskPerTrade,
        slippageBps: p.slippageBps,
        adxFilterEnabled: newEnabled,
        adxThreshold: newThreshold,
        adxPeriod: newPeriod,
        adxUseDiConfluence: newDi,
      ));
    } else if (p is UtBotParams) {
      provider.updateStrategyParams(UtBotParams(
        emaPeriod: p.emaPeriod,
        keyValue: p.keyValue,
        atrPeriod: p.atrPeriod,
        smiLength: p.smiLength,
        smiKSmoothing: p.smiKSmoothing,
        smiDSmoothing: p.smiDSmoothing,
        swingLookbackBars: p.swingLookbackBars,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: p.riskPerTrade,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHourLocal: p.sessionStartHourLocal,
        sessionEndHourLocal: p.sessionEndHourLocal,
        slippageBps: p.slippageBps,
        smiCrossAboveZero: p.smiCrossAboveZero,
        adxFilterEnabled: newEnabled,
        adxThreshold: newThreshold,
        adxPeriod: newPeriod,
        adxUseDiConfluence: newDi,
      ));
    } else if (p is IchimokuParams) {
      provider.updateStrategyParams(IchimokuParams(
        tenkanPeriod: p.tenkanPeriod,
        kijunPeriod: p.kijunPeriod,
        senkouBPeriod: p.senkouBPeriod,
        shift: p.shift,
        scoreThreshold: p.scoreThreshold,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: p.riskPerTrade,
        swingLookbackBars: p.swingLookbackBars,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHour: p.sessionStartHour,
        sessionEndHour: p.sessionEndHour,
        tzOffsetHours: p.tzOffsetHours,
        slippageBps: p.slippageBps,
        adxFilterEnabled: newEnabled,
        adxThreshold: newThreshold,
        adxPeriod: newPeriod,
        adxUseDiConfluence: newDi,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final adx = _readAdx();
    if (adx == null) return const SizedBox.shrink();

    final disabled = provider.isBusy;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.filter_alt_outlined,
                  size: 14, color: AppColors.accentPurple),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'ADX Regime Filter',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                key: const Key('adx-filter-enabled-switch'),
                value: adx.enabled,
                onChanged: disabled
                    ? null
                    : (v) => _writeAdx(enabled: v),
                activeThumbColor: AppColors.accentCyan,
              ),
            ],
          ),
          if (adx.enabled) ...[
            const SizedBox(height: 4),
            ParamSlider(
              label: 'Threshold',
              value: adx.threshold,
              min: 0,
              max: 50,
              divisions: 50,
              format: (v) => v.toInt().toString(),
              onChanged:
                  disabled ? null : (v) => _writeAdx(threshold: v),
            ),
            ParamSlider(
              label: 'Period',
              value: adx.period.toDouble(),
              min: 7,
              max: 30,
              divisions: 23,
              format: (v) => v.toInt().toString(),
              onChanged: disabled
                  ? null
                  : (v) => _writeAdx(period: v.toInt()),
            ),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '+DI / -DI confluence',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ),
                Switch(
                  key: const Key('adx-di-confluence-switch'),
                  value: adx.diConfluence,
                  onChanged: disabled
                      ? null
                      : (v) => _writeAdx(diConfluence: v),
                  activeThumbColor: AppColors.accentCyan,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
