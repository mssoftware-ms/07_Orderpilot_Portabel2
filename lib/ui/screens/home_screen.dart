import 'package:flutter/material.dart';
import '../../ui/themes/app_theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Dashboard',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Welcome to Trading App',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              // Quick stats row
              Row(
                children: [
                  Expanded(child: _buildStatCard(context, 'Portfolio', '\$10,000', AppColors.accentCyan)),
                  const SizedBox(width: 12),
                  Expanded(child: _buildStatCard(context, 'Active Trades', '0', AppColors.accentPurple)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _buildStatCard(context, 'Win Rate', '--', AppColors.bullGreen)),
                  const SizedBox(width: 12),
                  Expanded(child: _buildStatCard(context, 'Total P&L', '--', AppColors.textMuted)),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                'Quick Actions',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _buildActionTile(context, Icons.candlestick_chart, 'View Charts', 'Real-time candlestick charts'),
              _buildActionTile(context, Icons.history, 'Run Backtest', 'Test strategies on historical data'),
              _buildActionTile(context, Icons.play_circle_outline, 'Paper Trade', 'Practice with virtual capital'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(BuildContext context, String label, String value, Color accentColor) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: accentColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionTile(BuildContext context, IconData icon, String title, String subtitle) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: AppColors.accentCyan),
        title: Text(title),
        subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
      ),
    );
  }
}
