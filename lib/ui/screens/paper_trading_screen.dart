import 'package:flutter/material.dart';
import '../../ui/themes/app_theme.dart';
import '../widgets/coming_soon_banner.dart';

class PaperTradingScreen extends StatelessWidget {
  const PaperTradingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ComingSoonBanner(
                title: 'Paper Trading — In Development',
                body: 'This feature will arrive after Phase 3. For now, '
                    'use the Backtest screen to validate strategies on '
                    'historical data.',
              ),
              const SizedBox(height: 16),
              Text('Paper Trading', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                'Practice with virtual capital using live data',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),

              // Status card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          color: AppColors.textMuted,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text('Disconnected', style: TextStyle(color: AppColors.textSecondary)),
                      const Spacer(),
                      Tooltip(
                        message: 'Awaiting Phase 3',
                        child: OutlinedButton.icon(
                          onPressed: null,
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('Start'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Virtual balance card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Virtual Balance', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      const Text(
                        '\$10,000.00',
                        style: TextStyle(
                          color: AppColors.accentCyan,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'P&L: \$0.00 (0.00%)',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Open positions
              Text('Open Positions', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Expanded(
                child: Card(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.inbox_outlined, size: 48, color: AppColors.textMuted),
                        const SizedBox(height: 8),
                        const Text(
                          'No open positions',
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Start paper trading to see positions here',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
