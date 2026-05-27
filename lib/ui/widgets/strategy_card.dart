/// Welle O3-B3 — Strategy card for the StrategyManagementScreen.
///
/// One card per [StrategyKind]. Watches [BacktestProvider] for the active
/// strategy + current params and surfaces three actions:
///
///   * **Activate** — set this strategy as the active one in the provider
///     (only visible when the card's kind is not already active).
///   * **Apply Trial** — opens the [ApplyTrialDialog] so the user can pull
///     params from an optimizer study (always visible).
///   * **Reset** — reset the active strategy's params to its defaults
///     (only visible when params differ from defaults).
///
/// The card also surfaces a Mean-Reversion / Trend-Following / Multi-Indicator
/// category badge, an "Active" indicator pulled from provider state, and an
/// "Optimized params active" pill driven by `provider.usingOptimizedParams`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/backtest/backtest_provider.dart';
import '../../services/backtest_service.dart';
import '../themes/app_theme.dart';

/// Callback invoked when the user taps the "Apply Trial" button. Injected
/// so widget tests can verify the action without spinning up the real
/// dialog (the screen wires it to `showApplyTrialDialog`).
typedef ApplyTrialRequested = void Function(
    BuildContext context, StrategyKind kind);

class StrategyCard extends StatelessWidget {
  final StrategyKind kind;
  final BacktestProvider provider;
  final ApplyTrialRequested onApplyTrialRequested;

  const StrategyCard({
    super.key,
    required this.kind,
    required this.provider,
    required this.onApplyTrialRequested,
  });

  String get _categoryLabel => switch (kind) {
        StrategyKind.bbRsi => 'Mean Reversion',
        StrategyKind.utBot => 'Trend Following',
        StrategyKind.ichimoku => 'Multi-Indicator',
      };

  String get _description => switch (kind) {
        StrategyKind.bbRsi =>
          'Bollinger Band squeeze + RSI extremes — exits at the basis or '
              'opposite extreme.',
        StrategyKind.utBot =>
          'ATR trailing-stop trend system gated by SMI zero-line state.',
        StrategyKind.ichimoku =>
          'Cloud-retest entries with Tenkan/Kijun + score-threshold '
              'confluence filtering.',
      };

  bool get _isActive => provider.config.strategyKind == kind;

  /// Whether the active card's params differ from the strategy defaults.
  /// Inactive cards return false because they display their default chips
  /// (the live params live on the active strategy only).
  bool _paramsDifferFromDefaults() {
    if (!_isActive) return false;
    final params = provider.config.strategyParams as Object;
    final defaults = defaultParamsFor(kind);
    return !mapEquals(_paramsToMap(params), _paramsToMap(defaults)) ||
        provider.usingOptimizedParams;
  }

  /// Compact param chips for the card body. Shows the highest-signal knobs
  /// per strategy (kept small so 3 cards fit side-by-side on Wide layout).
  List<_Chip> _summaryChips() {
    // Inactive cards display their strategy defaults so the user can see
    // what they'd be activating.
    final Object p = _isActive
        ? provider.config.strategyParams as Object
        : defaultParamsFor(kind);
    switch (kind) {
      case StrategyKind.bbRsi:
        final bp = p as BbRsiParams;
        return [
          _Chip('BB', '${bp.bbPeriod} · ${bp.bbStdDev.toStringAsFixed(2)}σ'),
          _Chip('RSI',
              '${bp.rsiPeriod} · ${bp.rsiOversold.toInt()}/${bp.rsiOverbought.toInt()}'),
          _Chip('R:R', '1:${bp.tpRrRatio.toStringAsFixed(1)}'),
          _Chip('Risk', '${(bp.riskPerTrade * 100).toStringAsFixed(1)}%'),
          if (bp.adxFilterEnabled)
            _Chip('ADX', '≥${bp.adxThreshold.toStringAsFixed(0)}'),
        ];
      case StrategyKind.utBot:
        final up = p as UtBotParams;
        return [
          _Chip('EMA', '${up.emaPeriod}'),
          _Chip('Key', up.keyValue.toStringAsFixed(2)),
          _Chip('ATR', '${up.atrPeriod}'),
          _Chip('SMI',
              '${up.smiLength}·${up.smiKSmoothing}·${up.smiDSmoothing}'),
          _Chip('R:R', '1:${up.tpRrRatio.toStringAsFixed(1)}'),
          if (up.adxFilterEnabled)
            _Chip('ADX', '≥${up.adxThreshold.toStringAsFixed(0)}'),
        ];
      case StrategyKind.ichimoku:
        final ip = p as IchimokuParams;
        return [
          _Chip('Tenkan', '${ip.tenkanPeriod}'),
          _Chip('Kijun', '${ip.kijunPeriod}'),
          _Chip('SenkouB', '${ip.senkouBPeriod}'),
          _Chip('Score', '≥${ip.scoreThreshold}'),
          _Chip('R:R', '1:${ip.tpRrRatio.toStringAsFixed(1)}'),
          if (ip.adxFilterEnabled)
            _Chip('ADX', '≥${ip.adxThreshold.toStringAsFixed(0)}'),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final showActivate = !_isActive;
    final showReset = _paramsDifferFromDefaults();
    final showOptimizedPill = _isActive && provider.usingOptimizedParams;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    kind.displayLabel,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_isActive) _activeBadge(),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _categoryBadge(),
                if (showOptimizedPill) ...[
                  const SizedBox(width: 6),
                  _optimizedPill(),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _description,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _summaryChips().map((c) => c.build(context)).toList(),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (showActivate)
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('strategy_card_activate'),
                      onPressed: provider.isBusy
                          ? null
                          : () => provider.setStrategyKind(kind),
                      icon: const Icon(Icons.power_settings_new, size: 16),
                      label: const Text('Activate'),
                    ),
                  ),
                if (showActivate) const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    key: const Key('strategy_card_apply_trial'),
                    onPressed: provider.isBusy
                        ? null
                        : () => onApplyTrialRequested(context, kind),
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('Apply Trial'),
                  ),
                ),
                if (showReset) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    key: const Key('strategy_card_reset'),
                    onPressed: provider.isBusy
                        ? null
                        : provider.resetParamsToDefaults,
                    icon: const Icon(Icons.restart_alt, size: 16),
                    label: const Text('Reset'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _activeBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.bullGreen.withAlpha(30),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'Active',
          style: TextStyle(
            color: AppColors.bullGreen,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _categoryBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          _categoryLabel,
          style: const TextStyle(
            color: AppColors.accentPurple,
            fontSize: 11,
          ),
        ),
      );

  Widget _optimizedPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: AppColors.accentCyan.withAlpha(20),
          border: Border.all(color: AppColors.accentCyan.withAlpha(80)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 11, color: AppColors.accentCyan),
            SizedBox(width: 3),
            Text(
              'Optimized',
              style: TextStyle(
                color: AppColors.accentCyan,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );

  /// Serialize any of the three Param classes to a comparable map.
  static Map<String, double> _paramsToMap(Object params) {
    if (params is BbRsiParams) return params.toMap();
    if (params is UtBotParams) return params.toMap();
    if (params is IchimokuParams) return params.toMap();
    throw ArgumentError('Unknown params type: ${params.runtimeType}');
  }
}

class _Chip {
  final String label;
  final String value;
  const _Chip(this.label, this.value);

  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}
