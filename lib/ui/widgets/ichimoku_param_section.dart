/// Ichimoku strategy parameter section for the Backtest screen.
///
/// Welle O3-B1 STUB — the real param inputs (tenkan/kijun/senkou_b
/// periods, shift, score_threshold, tp_rr_ratio, risk_per_trade,
/// swing_lookback) ship in Welle O3-B1-3. Renders a single info card
/// today so the strategy dropdown can mount it without crashing.
library;

import 'package:flutter/material.dart';

import '../../features/backtest/backtest_provider.dart';
import '../themes/app_theme.dart';

class IchimokuParamSection extends StatelessWidget {
  final BacktestProvider provider;

  const IchimokuParamSection({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: const Row(
        children: [
          Icon(Icons.hourglass_top,
              size: 16, color: AppColors.accentPurple),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Ichimoku parameter inputs ship in Welle O3-B1-3. '
              'Running with current defaults.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
