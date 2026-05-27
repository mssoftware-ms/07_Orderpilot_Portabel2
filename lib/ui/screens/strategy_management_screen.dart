/// Welle O3-B3-4 — Strategy-Management screen as apply-trial hub.
///
/// Renders one [StrategyCard] per [StrategyKind], live-bound to the active
/// [BacktestProvider]. The card's "Apply Trial" button opens the
/// [ApplyTrialDialog] so the loop
///
///     CLI optimizer → studies DB → Strategy-Management → Backtest tab
///
/// can be walked without leaving the navigation rail. A footer status bar
/// mirrors the currently-active strategy + whether its params are
/// optimized or defaults, and a quick-link routes to the Studies tab via
/// the shared [AppNavigation] notifier.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/navigation/app_navigation.dart';
import '../../features/backtest/backtest_provider.dart';
import '../themes/app_theme.dart';
import '../widgets/apply_trial_dialog.dart';
import '../widgets/strategy_card.dart';

class StrategyManagementScreen extends StatelessWidget {
  const StrategyManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<BacktestProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context),
                  const SizedBox(height: 20),
                  Expanded(child: _cardsLayout(context, provider)),
                  const SizedBox(height: 12),
                  _footer(context, provider),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Strategies',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Apply optimization results to the active backtest.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            key: const Key('strategies_open_studies_link'),
            onPressed: () =>
                context.read<AppNavigation>().goTo(AppTab.studies),
            icon: const Icon(Icons.analytics_outlined, size: 16),
            label: const Text('Open Studies viewer'),
          ),
        ],
      );

  Widget _cardsLayout(BuildContext context, BacktestProvider provider) {
    final width = MediaQuery.of(context).size.width;
    final cards = StrategyKind.values
        .map((k) => StrategyCard(
              key: Key('strategy_card_${k.name}'),
              kind: k,
              provider: provider,
              onApplyTrialRequested: (ctx, kind) => showApplyTrialDialog(
                ctx,
                targetKind: kind,
                backtestProvider: provider,
              ),
            ))
        .toList();

    // Wide layout: 3 cards in a row. Narrow: vertical scroll.
    if (width >= 900) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            Expanded(child: cards[i]),
            if (i < cards.length - 1) const SizedBox(width: 12),
          ],
        ],
      );
    }
    return ListView.separated(
      itemCount: cards.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) => cards[i],
    );
  }

  Widget _footer(BuildContext context, BacktestProvider provider) {
    final active = provider.config.strategyKind;
    final isOptimized = provider.usingOptimizedParams;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        border: Border.all(color: AppColors.border, width: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        key: const Key('strategies_footer_active_status'),
        children: [
          const Icon(Icons.play_circle_outline,
              size: 16, color: AppColors.accentCyan),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Active in Backtest: ${active.displayLabel} '
              '(${isOptimized ? "optimized" : "default"} params)',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
              ),
            ),
          ),
          TextButton.icon(
            key: const Key('strategies_open_backtest_link'),
            onPressed: () =>
                context.read<AppNavigation>().goTo(AppTab.backtest),
            icon: const Icon(Icons.arrow_forward, size: 14),
            label: const Text('Open Backtest'),
          ),
        ],
      ),
    );
  }
}
