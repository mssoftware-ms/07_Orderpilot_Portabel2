/// UT-Bot strategy parameter section for the Backtest screen.
///
/// Welle O3-B1-3 — replaces the B1-2 stub. Surfaces the 8 main UT-Bot
/// knobs from `lib/services/backtest_service.dart` (UtBotParams) plus the
/// reset-to-defaults link. ADX filter knobs ship as a shared widget in
/// Welle O3-B1-4 — they are NOT mirrored here.
///
/// Param ranges follow `01_Projectplan/specs/ut_bot_spec.md`:
///   - key_value: 0.5–10.0 (default 2.0)
///   - atr_period: 1–30 (default 1)
///   - smi_length: 5–30 (default 14)
///   - smi_k: 2–15 (default 5)
///   - smi_d: 2–10 (default 3)
///   - swing_lookback_bars: 5–50 (default 20)
///   - tp_rr_ratio: 0.5–5.0 (default 2.0)
///   - risk_per_trade: 0.005–0.10 (default 0.02 = 2 %)
library;

import 'package:flutter/material.dart';

import '../../features/backtest/backtest_provider.dart';
import '../../services/backtest_service.dart';
import '../themes/app_theme.dart';
import 'param_slider.dart';

class UtBotParamSection extends StatelessWidget {
  final BacktestProvider provider;

  const UtBotParamSection({super.key, required this.provider});

  UtBotParams _withKeyValue(UtBotParams p, double v) =>
      UtBotParams(
        emaPeriod: p.emaPeriod,
        keyValue: v,
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
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  UtBotParams _withAtrPeriod(UtBotParams p, int v) =>
      UtBotParams(
        emaPeriod: p.emaPeriod,
        keyValue: p.keyValue,
        atrPeriod: v,
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
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  UtBotParams _withSmiLength(UtBotParams p, int v) =>
      UtBotParams(
        emaPeriod: p.emaPeriod,
        keyValue: p.keyValue,
        atrPeriod: p.atrPeriod,
        smiLength: v,
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
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  UtBotParams _withSmiK(UtBotParams p, int v) =>
      UtBotParams(
        emaPeriod: p.emaPeriod,
        keyValue: p.keyValue,
        atrPeriod: p.atrPeriod,
        smiLength: p.smiLength,
        smiKSmoothing: v,
        smiDSmoothing: p.smiDSmoothing,
        swingLookbackBars: p.swingLookbackBars,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: p.riskPerTrade,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHourLocal: p.sessionStartHourLocal,
        sessionEndHourLocal: p.sessionEndHourLocal,
        slippageBps: p.slippageBps,
        smiCrossAboveZero: p.smiCrossAboveZero,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  UtBotParams _withSmiD(UtBotParams p, int v) =>
      UtBotParams(
        emaPeriod: p.emaPeriod,
        keyValue: p.keyValue,
        atrPeriod: p.atrPeriod,
        smiLength: p.smiLength,
        smiKSmoothing: p.smiKSmoothing,
        smiDSmoothing: v,
        swingLookbackBars: p.swingLookbackBars,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: p.riskPerTrade,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHourLocal: p.sessionStartHourLocal,
        sessionEndHourLocal: p.sessionEndHourLocal,
        slippageBps: p.slippageBps,
        smiCrossAboveZero: p.smiCrossAboveZero,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  UtBotParams _withSwing(UtBotParams p, int v) =>
      UtBotParams(
        emaPeriod: p.emaPeriod,
        keyValue: p.keyValue,
        atrPeriod: p.atrPeriod,
        smiLength: p.smiLength,
        smiKSmoothing: p.smiKSmoothing,
        smiDSmoothing: p.smiDSmoothing,
        swingLookbackBars: v,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: p.riskPerTrade,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHourLocal: p.sessionStartHourLocal,
        sessionEndHourLocal: p.sessionEndHourLocal,
        slippageBps: p.slippageBps,
        smiCrossAboveZero: p.smiCrossAboveZero,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  UtBotParams _withTpRr(UtBotParams p, double v) =>
      UtBotParams(
        emaPeriod: p.emaPeriod,
        keyValue: p.keyValue,
        atrPeriod: p.atrPeriod,
        smiLength: p.smiLength,
        smiKSmoothing: p.smiKSmoothing,
        smiDSmoothing: p.smiDSmoothing,
        swingLookbackBars: p.swingLookbackBars,
        tpRrRatio: v,
        riskPerTrade: p.riskPerTrade,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHourLocal: p.sessionStartHourLocal,
        sessionEndHourLocal: p.sessionEndHourLocal,
        slippageBps: p.slippageBps,
        smiCrossAboveZero: p.smiCrossAboveZero,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  UtBotParams _withRisk(UtBotParams p, double v) =>
      UtBotParams(
        emaPeriod: p.emaPeriod,
        keyValue: p.keyValue,
        atrPeriod: p.atrPeriod,
        smiLength: p.smiLength,
        smiKSmoothing: p.smiKSmoothing,
        smiDSmoothing: p.smiDSmoothing,
        swingLookbackBars: p.swingLookbackBars,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: v,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHourLocal: p.sessionStartHourLocal,
        sessionEndHourLocal: p.sessionEndHourLocal,
        slippageBps: p.slippageBps,
        smiCrossAboveZero: p.smiCrossAboveZero,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  @override
  Widget build(BuildContext context) {
    final p = provider.config.strategyParams as UtBotParams;
    final disabled = provider.isBusy;

    void update(UtBotParams next) => provider.updateStrategyParams(next);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ParamSlider(
          label: 'Key Value',
          value: p.keyValue,
          min: 0.5,
          max: 10.0,
          divisions: 95,
          format: (v) => v.toStringAsFixed(1),
          onChanged: disabled ? null : (v) => update(_withKeyValue(p, v)),
        ),
        ParamSlider(
          label: 'ATR Period',
          value: p.atrPeriod.toDouble(),
          min: 1,
          max: 30,
          divisions: 29,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => update(_withAtrPeriod(p, v.toInt())),
        ),
        ParamSlider(
          label: 'SMI Length',
          value: p.smiLength.toDouble(),
          min: 5,
          max: 30,
          divisions: 25,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => update(_withSmiLength(p, v.toInt())),
        ),
        ParamSlider(
          label: 'SMI K Smooth',
          value: p.smiKSmoothing.toDouble(),
          min: 2,
          max: 15,
          divisions: 13,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => update(_withSmiK(p, v.toInt())),
        ),
        ParamSlider(
          label: 'SMI D Smooth',
          value: p.smiDSmoothing.toDouble(),
          min: 2,
          max: 10,
          divisions: 8,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => update(_withSmiD(p, v.toInt())),
        ),
        ParamSlider(
          label: 'Swing Bars',
          value: p.swingLookbackBars.toDouble(),
          min: 5,
          max: 50,
          divisions: 45,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => update(_withSwing(p, v.toInt())),
        ),
        ParamSlider(
          label: 'TP R:R',
          value: p.tpRrRatio,
          min: 0.5,
          max: 5.0,
          divisions: 45,
          format: (v) => v.toStringAsFixed(2),
          onChanged: disabled ? null : (v) => update(_withTpRr(p, v)),
        ),
        ParamSlider(
          label: 'Risk/Trade',
          value: p.riskPerTrade,
          min: 0.005,
          max: 0.10,
          divisions: 95,
          format: (v) => '${(v * 100).toStringAsFixed(1)}%',
          onChanged: disabled ? null : (v) => update(_withRisk(p, v)),
        ),
        const SizedBox(height: 6),
        Center(
          child: TextButton(
            onPressed: disabled ? null : provider.resetParamsToDefaults,
            child: const Text(
              'Reset to defaults',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 10,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
