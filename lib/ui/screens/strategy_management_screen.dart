import 'package:flutter/material.dart';
import '../../ui/themes/app_theme.dart';

class StrategyManagementScreen extends StatelessWidget {
  const StrategyManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Strategies', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                'Manage your trading strategy add-ins',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),

              // Installed strategies
              _buildStrategyCard(
                context,
                name: 'BB + RSI Mean Reversion',
                version: 'v1.0.0',
                category: 'Mean Reversion',
                description: 'Buy when price touches lower BB and RSI < 30, exit at middle BB or RSI > 70',
                isInstalled: true,
                isFree: true,
              ),
              const SizedBox(height: 12),
              _buildStrategyCard(
                context,
                name: 'UT Bot Alerts',
                version: 'v1.0.0',
                category: 'Trend Following',
                description: 'ATR-based trailing stop trend strategy',
                isInstalled: false,
                isFree: false,
              ),
              const SizedBox(height: 12),
              _buildStrategyCard(
                context,
                name: 'Ichimoku Cloud Retest',
                version: 'v1.0.0',
                category: 'Multi-Indicator',
                description: 'Cloud retest strategy with confluence filtering',
                isInstalled: false,
                isFree: false,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStrategyCard(
    BuildContext context, {
    required String name,
    required String version,
    required String category,
    required String description,
    required bool isInstalled,
    required bool isFree,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name, style: Theme.of(context).textTheme.titleMedium),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isInstalled
                        ? AppColors.bullGreen.withAlpha(30)
                        : AppColors.textMuted.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isInstalled ? 'Installed' : (isFree ? 'Free' : 'Premium'),
                    style: TextStyle(
                      color: isInstalled ? AppColors.bullGreen : AppColors.warningAmber,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(version, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(category, style: const TextStyle(color: AppColors.accentPurple, fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(description, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
