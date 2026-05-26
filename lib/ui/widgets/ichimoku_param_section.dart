/// Ichimoku strategy parameter section for the Backtest screen.
///
/// Welle O3-B1-3 — replaces the B1-2 stub. Surfaces the 8 main Ichimoku
/// knobs from `lib/services/backtest_service.dart` (IchimokuParams) plus
/// the reset-to-defaults link. ADX filter knobs ship as a shared widget
/// in Welle O3-B1-4 — they are NOT mirrored here.
///
/// Param ranges follow `01_Projectplan/specs/ichimoku_spec.md`:
///   - tenkan_period: 3–30 (default 9)
///   - kijun_period: 10–60 (default 26)
///   - senkou_b_period: 20–120 (default 52)
///   - shift: 10–60 (default 26)
///   - score_threshold: 0–100 (default 60)
///   - tp_rr_ratio: 0.5–5.0 (default 2.0)
///   - risk_per_trade: 0.005–0.10 (default 0.02 = 2 %)
///   - swing_lookback_bars: 5–50 (default 20)
library;

import 'package:flutter/material.dart';

import '../../features/backtest/backtest_provider.dart';
import '../../services/backtest_service.dart';
import '../themes/app_theme.dart';
import 'param_slider.dart';

class IchimokuParamSection extends StatelessWidget {
  final BacktestProvider provider;

  const IchimokuParamSection({super.key, required this.provider});

  IchimokuParams _withTenkan(IchimokuParams p, int v) =>
      IchimokuParams(
        tenkanPeriod: v,
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
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  IchimokuParams _withKijun(IchimokuParams p, int v) =>
      IchimokuParams(
        tenkanPeriod: p.tenkanPeriod,
        kijunPeriod: v,
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
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  IchimokuParams _withSenkouB(IchimokuParams p, int v) =>
      IchimokuParams(
        tenkanPeriod: p.tenkanPeriod,
        kijunPeriod: p.kijunPeriod,
        senkouBPeriod: v,
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
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  IchimokuParams _withShift(IchimokuParams p, int v) =>
      IchimokuParams(
        tenkanPeriod: p.tenkanPeriod,
        kijunPeriod: p.kijunPeriod,
        senkouBPeriod: p.senkouBPeriod,
        shift: v,
        scoreThreshold: p.scoreThreshold,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: p.riskPerTrade,
        swingLookbackBars: p.swingLookbackBars,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHour: p.sessionStartHour,
        sessionEndHour: p.sessionEndHour,
        tzOffsetHours: p.tzOffsetHours,
        slippageBps: p.slippageBps,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  IchimokuParams _withScoreThreshold(IchimokuParams p, int v) =>
      IchimokuParams(
        tenkanPeriod: p.tenkanPeriod,
        kijunPeriod: p.kijunPeriod,
        senkouBPeriod: p.senkouBPeriod,
        shift: p.shift,
        scoreThreshold: v,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: p.riskPerTrade,
        swingLookbackBars: p.swingLookbackBars,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHour: p.sessionStartHour,
        sessionEndHour: p.sessionEndHour,
        tzOffsetHours: p.tzOffsetHours,
        slippageBps: p.slippageBps,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  IchimokuParams _withTpRr(IchimokuParams p, double v) =>
      IchimokuParams(
        tenkanPeriod: p.tenkanPeriod,
        kijunPeriod: p.kijunPeriod,
        senkouBPeriod: p.senkouBPeriod,
        shift: p.shift,
        scoreThreshold: p.scoreThreshold,
        tpRrRatio: v,
        riskPerTrade: p.riskPerTrade,
        swingLookbackBars: p.swingLookbackBars,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHour: p.sessionStartHour,
        sessionEndHour: p.sessionEndHour,
        tzOffsetHours: p.tzOffsetHours,
        slippageBps: p.slippageBps,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  IchimokuParams _withRisk(IchimokuParams p, double v) =>
      IchimokuParams(
        tenkanPeriod: p.tenkanPeriod,
        kijunPeriod: p.kijunPeriod,
        senkouBPeriod: p.senkouBPeriod,
        shift: p.shift,
        scoreThreshold: p.scoreThreshold,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: v,
        swingLookbackBars: p.swingLookbackBars,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHour: p.sessionStartHour,
        sessionEndHour: p.sessionEndHour,
        tzOffsetHours: p.tzOffsetHours,
        slippageBps: p.slippageBps,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  IchimokuParams _withSwing(IchimokuParams p, int v) =>
      IchimokuParams(
        tenkanPeriod: p.tenkanPeriod,
        kijunPeriod: p.kijunPeriod,
        senkouBPeriod: p.senkouBPeriod,
        shift: p.shift,
        scoreThreshold: p.scoreThreshold,
        tpRrRatio: p.tpRrRatio,
        riskPerTrade: p.riskPerTrade,
        swingLookbackBars: v,
        sessionFilterEnabled: p.sessionFilterEnabled,
        sessionStartHour: p.sessionStartHour,
        sessionEndHour: p.sessionEndHour,
        tzOffsetHours: p.tzOffsetHours,
        slippageBps: p.slippageBps,
        adxFilterEnabled: p.adxFilterEnabled,
        adxThreshold: p.adxThreshold,
        adxPeriod: p.adxPeriod,
        adxUseDiConfluence: p.adxUseDiConfluence,
      );

  @override
  Widget build(BuildContext context) {
    final p = provider.config.strategyParams as IchimokuParams;
    final disabled = provider.isBusy;

    void update(IchimokuParams next) => provider.updateStrategyParams(next);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ParamSlider(
          label: 'Tenkan',
          value: p.tenkanPeriod.toDouble(),
          min: 3,
          max: 30,
          divisions: 27,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => update(_withTenkan(p, v.toInt())),
        ),
        ParamSlider(
          label: 'Kijun',
          value: p.kijunPeriod.toDouble(),
          min: 10,
          max: 60,
          divisions: 50,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => update(_withKijun(p, v.toInt())),
        ),
        ParamSlider(
          label: 'Senkou B',
          value: p.senkouBPeriod.toDouble(),
          min: 20,
          max: 120,
          divisions: 100,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => update(_withSenkouB(p, v.toInt())),
        ),
        ParamSlider(
          label: 'Shift',
          value: p.shift.toDouble(),
          min: 10,
          max: 60,
          divisions: 50,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => update(_withShift(p, v.toInt())),
        ),
        ParamSlider(
          label: 'Score Thr.',
          value: p.scoreThreshold.toDouble(),
          min: 0,
          max: 100,
          divisions: 100,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) =>
                  update(_withScoreThreshold(p, v.toInt())),
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
