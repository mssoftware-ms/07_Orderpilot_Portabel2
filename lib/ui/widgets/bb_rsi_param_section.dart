/// BB+RSI strategy parameter section for the Backtest screen.
///
/// Welle O3-B1 extracts the legacy inline BB+RSI sliders from
/// [BacktestScreen] into a reusable widget so the new strategy dropdown
/// can mount/unmount it cleanly when the user switches between BB+RSI,
/// UT-Bot, and Ichimoku.
///
/// Wires `provider.updateStrategyParams` for the five BB+RSI knobs,
/// keeps the "Optimize Parameters (frozen)" tooltip (BB+RSI-only path),
/// and surfaces the "View last optimization results" + reset-to-defaults
/// links that were attached to the BB+RSI params in pre-B1 builds.
library;

import 'package:flutter/material.dart';

import '../../features/backtest/backtest_provider.dart';
import '../../services/backtest_service.dart';
import '../themes/app_theme.dart';
import 'optimization_results_dialog.dart';
import 'param_slider.dart';

class BbRsiParamSection extends StatelessWidget {
  final BacktestProvider provider;

  const BbRsiParamSection({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final params = provider.config.strategyParams as BbRsiParams;
    final disabled = provider.isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (provider.usingOptimizedParams) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: AppColors.accentCyan.withAlpha(15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.accentCyan.withAlpha(50)),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome,
                    size: 14, color: AppColors.accentCyan),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Using optimized parameters',
                    style: TextStyle(
                      color: AppColors.accentCyan,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                InkWell(
                  onTap: disabled ? null : provider.resetParamsToDefaults,
                  child: const Text(
                    'Reset',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 10,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        ParamSlider(
          label: 'BB Period',
          value: params.bbPeriod.toDouble(),
          min: 10,
          max: 300,
          divisions: 29,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => provider.updateStrategyParams(
                    BbRsiParams(
                      bbPeriod: v.toInt(),
                      bbStdDev: params.bbStdDev,
                      bbMaType: params.bbMaType,
                      rsiPeriod: params.rsiPeriod,
                      rsiOversold: params.rsiOversold,
                      rsiOverbought: params.rsiOverbought,
                      swingLookbackBars: params.swingLookbackBars,
                      tpRrRatio: params.tpRrRatio,
                      riskPerTrade: params.riskPerTrade,
                      slippageBps: params.slippageBps,
                      adxFilterEnabled: params.adxFilterEnabled,
                      adxThreshold: params.adxThreshold,
                      adxPeriod: params.adxPeriod,
                      adxUseDiConfluence: params.adxUseDiConfluence,
                    ),
                  ),
        ),
        ParamSlider(
          label: 'BB Std Dev',
          value: params.bbStdDev,
          min: 0.1,
          max: 3.0,
          divisions: 29,
          format: (v) => v.toStringAsFixed(1),
          onChanged: disabled
              ? null
              : (v) => provider.updateStrategyParams(
                    BbRsiParams(
                      bbPeriod: params.bbPeriod,
                      bbStdDev: v,
                      bbMaType: params.bbMaType,
                      rsiPeriod: params.rsiPeriod,
                      rsiOversold: params.rsiOversold,
                      rsiOverbought: params.rsiOverbought,
                      swingLookbackBars: params.swingLookbackBars,
                      tpRrRatio: params.tpRrRatio,
                      riskPerTrade: params.riskPerTrade,
                      slippageBps: params.slippageBps,
                      adxFilterEnabled: params.adxFilterEnabled,
                      adxThreshold: params.adxThreshold,
                      adxPeriod: params.adxPeriod,
                      adxUseDiConfluence: params.adxUseDiConfluence,
                    ),
                  ),
        ),
        ParamSlider(
          label: 'RSI Period',
          value: params.rsiPeriod.toDouble(),
          min: 2,
          max: 30,
          divisions: 28,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => provider.updateStrategyParams(
                    BbRsiParams(
                      bbPeriod: params.bbPeriod,
                      bbStdDev: params.bbStdDev,
                      bbMaType: params.bbMaType,
                      rsiPeriod: v.toInt(),
                      rsiOversold: params.rsiOversold,
                      rsiOverbought: params.rsiOverbought,
                      swingLookbackBars: params.swingLookbackBars,
                      tpRrRatio: params.tpRrRatio,
                      riskPerTrade: params.riskPerTrade,
                      slippageBps: params.slippageBps,
                      adxFilterEnabled: params.adxFilterEnabled,
                      adxThreshold: params.adxThreshold,
                      adxPeriod: params.adxPeriod,
                      adxUseDiConfluence: params.adxUseDiConfluence,
                    ),
                  ),
        ),
        ParamSlider(
          label: 'RSI Oversold',
          value: params.rsiOversold,
          min: 5,
          max: 40,
          divisions: 35,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => provider.updateStrategyParams(
                    BbRsiParams(
                      bbPeriod: params.bbPeriod,
                      bbStdDev: params.bbStdDev,
                      bbMaType: params.bbMaType,
                      rsiPeriod: params.rsiPeriod,
                      rsiOversold: v,
                      rsiOverbought: params.rsiOverbought,
                      swingLookbackBars: params.swingLookbackBars,
                      tpRrRatio: params.tpRrRatio,
                      riskPerTrade: params.riskPerTrade,
                      slippageBps: params.slippageBps,
                      adxFilterEnabled: params.adxFilterEnabled,
                      adxThreshold: params.adxThreshold,
                      adxPeriod: params.adxPeriod,
                      adxUseDiConfluence: params.adxUseDiConfluence,
                    ),
                  ),
        ),
        ParamSlider(
          label: 'RSI Overbought',
          value: params.rsiOverbought,
          min: 60,
          max: 95,
          divisions: 35,
          format: (v) => v.toInt().toString(),
          onChanged: disabled
              ? null
              : (v) => provider.updateStrategyParams(
                    BbRsiParams(
                      bbPeriod: params.bbPeriod,
                      bbStdDev: params.bbStdDev,
                      bbMaType: params.bbMaType,
                      rsiPeriod: params.rsiPeriod,
                      rsiOversold: params.rsiOversold,
                      rsiOverbought: v,
                      swingLookbackBars: params.swingLookbackBars,
                      tpRrRatio: params.tpRrRatio,
                      riskPerTrade: params.riskPerTrade,
                      slippageBps: params.slippageBps,
                      adxFilterEnabled: params.adxFilterEnabled,
                      adxThreshold: params.adxThreshold,
                      adxPeriod: params.adxPeriod,
                      adxUseDiConfluence: params.adxUseDiConfluence,
                    ),
                  ),
        ),
        const SizedBox(height: 10),

        // Optimize Parameters button — FROZEN (Plan §3.3)
        SizedBox(
          width: double.infinity,
          height: 36,
          child: Tooltip(
            message: 'Optimizer wartet auf Phase 2-Abschluss '
                '(siehe 260522_Gesamtplan_Phase1-3.md §3.3)',
            child: OutlinedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.lock_outline, size: 16),
              label: const Text(
                'Optimize Parameters (frozen)',
                style: TextStyle(fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentPurple,
                side: const BorderSide(color: AppColors.accentPurple),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ),

        if (provider.hasOptResult) ...[
          const SizedBox(height: 6),
          Center(
            child: TextButton(
              onPressed: () => _showOptResults(context),
              child: const Text(
                'View optimization results',
                style: TextStyle(
                  color: AppColors.accentPurple,
                  fontSize: 11,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        ],

        if (!provider.usingOptimizedParams) ...[
          const SizedBox(height: 2),
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
      ],
    );
  }

  void _showOptResults(BuildContext context) {
    if (provider.optResult == null) return;
    OptimizationResultsDialog.show(
      context,
      result: provider.optResult!,
      onApply: provider.applyOptimizedParams,
    );
  }
}
