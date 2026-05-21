import 'package:flutter/material.dart';
import '../../ui/themes/app_theme.dart';
import '../../core/constants/app_constants.dart';

class BacktestScreen extends StatelessWidget {
  const BacktestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Backtest', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                'Test strategies on historical data',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),

              // Configuration card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Configuration', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 16),
                      _buildParamRow('Symbol', 'BTCUSDT'),
                      _buildParamRow('Timeframe', '1h'),
                      _buildParamRow('Candles', '${AppConstants.defaultCandleCount}'),
                      _buildParamRow('Initial Capital', '\$${AppConstants.defaultInitialCapital.toInt()}'),
                      _buildParamRow('Fee Rate', '${(AppConstants.defaultFeeRate * 100).toStringAsFixed(2)}%'),
                      const Divider(height: 24),
                      Text('BB+RSI Parameters', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      _buildParamRow('BB Period', '${AppConstants.defaultBBPeriod}'),
                      _buildParamRow('BB Std Dev', '${AppConstants.defaultBBStdDev}'),
                      _buildParamRow('RSI Period', '${AppConstants.defaultRSIPeriod}'),
                      _buildParamRow('RSI Oversold', '${AppConstants.defaultRSIOversold.toInt()}'),
                      _buildParamRow('RSI Overbought', '${AppConstants.defaultRSIOverbought.toInt()}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Run button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Backtest engine not yet connected (Rust bridge pending)')),
                    );
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run Backtest'),
                ),
              ),
              const SizedBox(height: 24),

              // Results placeholder
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Results', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 16),
                      _buildMetricRow('Total Trades', '--'),
                      _buildMetricRow('Win Rate', '--'),
                      _buildMetricRow('Profit Factor', '--'),
                      _buildMetricRow('Total Return', '--'),
                      _buildMetricRow('Max Drawdown', '--'),
                      _buildMetricRow('Sharpe Ratio', '--'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildParamRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          Text(value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          Text(value, style: const TextStyle(color: AppColors.accentCyan, fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
