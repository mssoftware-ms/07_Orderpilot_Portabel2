/// Welle O3-B4: tri-control bar for the Global Leaderboard.
///
/// Slider → minTrades, Dropdown → sortBy, Stepper → top-N. All three
/// call into [AggregateLeaderboard] which fires its own recompute.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/studies/aggregate_leaderboard.dart';
import '../themes/app_theme.dart';

class LeaderboardFilterBar extends StatelessWidget {
  const LeaderboardFilterBar({super.key});

  static const List<int> _minTradesSnap = [0, 5, 10, 20, 50, 100, 250, 500];
  static const List<int> _topNSnap = [5, 10, 20, 50, 100];

  static const Map<String, String> _sortLabels = {
    'score': 'Score',
    'pnl': 'PnL',
    'sharpe': 'Sharpe',
    'pf': 'Profit factor',
    'trades': 'Trades',
    'winRate': 'Win rate',
  };

  int _snap(int v, List<int> snaps) {
    return snaps.reduce((a, b) => (v - a).abs() < (v - b).abs() ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final agg = context.watch<AggregateLeaderboard>();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 280,
            child: Row(
              children: [
                const Text('Min trades:',
                    style:
                        TextStyle(color: AppColors.textMuted, fontSize: 12)),
                Expanded(
                  child: Slider(
                    key: const Key('leaderboard-min-trades'),
                    min: 0,
                    max: 500,
                    divisions: 100,
                    value: agg.minTrades.toDouble(),
                    label: '${agg.minTrades}',
                    onChanged: (v) {
                      agg.minTrades = _snap(v.round(), _minTradesSnap);
                    },
                    onChangeEnd: (_) => agg.recompute(),
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Text('${agg.minTrades}',
                      style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 12),
                      textAlign: TextAlign.right),
                ),
              ],
            ),
          ),
          Row(
            children: [
              const Text('Sort:',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(width: 8),
              DropdownButton<String>(
                key: const Key('leaderboard-sort'),
                value: agg.sortBy,
                dropdownColor: AppColors.surfaceElevated,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 12),
                items: _sortLabels.entries
                    .map((e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  agg.sortBy = v;
                  agg.recompute();
                },
              ),
            ],
          ),
          Row(
            children: [
              const Text('Top:',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(width: 8),
              DropdownButton<int>(
                key: const Key('leaderboard-top-n'),
                value: _topNSnap.contains(agg.limit) ? agg.limit : 10,
                dropdownColor: AppColors.surfaceElevated,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 12),
                items: _topNSnap
                    .map((n) => DropdownMenuItem(
                          value: n,
                          child: Text('$n'),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  agg.limit = v;
                  agg.recompute();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
