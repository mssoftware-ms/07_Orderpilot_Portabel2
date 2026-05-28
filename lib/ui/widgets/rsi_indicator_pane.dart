/// Welle P4C-4 RSI sub-chart.
///
/// Displays the RSI series produced by `ChartProvider` as a single
/// `fl_chart` line, with the canonical 30 / 70 oversold / overbought
/// thresholds rendered as dashed reference levels. Warm-up bars carry
/// the legacy 50.0 sentinel from `calcRsi` (matches the engine
/// initialisation that the bit-exact suite is pinned against) — the
/// pane trims those off the leading edge so the rendered line starts
/// at the first valid sample.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../themes/app_theme.dart';

class RsiIndicatorPane extends StatelessWidget {
  final List<double>? values;

  const RsiIndicatorPane({super.key, required this.values});

  @override
  Widget build(BuildContext context) {
    final raw = values;
    if (raw == null || raw.isEmpty) {
      return const Center(
        child: Text(
          'RSI Indicator (0–100)',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      );
    }

    // Skip leading warm-up bars that still carry the 50.0 init value.
    int startIdx = 0;
    while (startIdx < raw.length && raw[startIdx] == 50.0) {
      startIdx++;
    }
    if (startIdx >= raw.length) {
      return const Center(
        child: Text(
          'RSI warming up…',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      );
    }

    final spots = <FlSpot>[
      for (int i = startIdx; i < raw.length; i++)
        FlSpot(i.toDouble(), raw[i]),
    ];
    final xMin = startIdx.toDouble();
    final xMax = (raw.length - 1).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: 100,
          minX: xMin,
          maxX: xMax,
          gridData: const FlGridData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                interval: 50,
                getTitlesWidget: (value, _) => Text(
                  value.toInt().toString(),
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          borderData: FlBorderData(show: false),
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              HorizontalLine(
                y: 70,
                color: AppColors.bearRed.withAlpha(180),
                strokeWidth: 1,
                dashArray: const [4, 4],
              ),
              HorizontalLine(
                y: 30,
                color: AppColors.bullGreen.withAlpha(180),
                strokeWidth: 1,
                dashArray: const [4, 4],
              ),
            ],
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: AppColors.accentCyan,
              barWidth: 1.5,
              dotData: const FlDotData(show: false),
            ),
          ],
          lineTouchData: const LineTouchData(enabled: false),
        ),
      ),
    );
  }
}
