import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../themes/app_theme.dart';
import '../../services/backtest_service.dart';

/// Interactive equity curve chart using fl_chart.
class EquityCurveChart extends StatelessWidget {
  final List<EquityPoint> equityCurve;
  final double initialBalance;

  const EquityCurveChart({
    super.key,
    required this.equityCurve,
    required this.initialBalance,
  });

  @override
  Widget build(BuildContext context) {
    if (equityCurve.isEmpty) {
      return Container(
        height: 300,
        alignment: Alignment.center,
        child: const Text('No equity data', style: TextStyle(color: AppColors.textMuted)),
      );
    }

    // Sample points for performance (max ~200 points)
    final sampled = _samplePoints(equityCurve, 200);

    final spots = sampled
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.equity))
        .toList();

    final minY = spots.map((s) => s.y).reduce(math.min);
    final maxY = spots.map((s) => s.y).reduce(math.max);
    final padding = (maxY - minY) * 0.08;

    // Determine color based on overall performance
    final lastEquity = equityCurve.last.equity;
    final lineColor = lastEquity >= initialBalance
        ? AppColors.bullGreen
        : AppColors.bearRed;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.show_chart, color: AppColors.accentCyan, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Equity Curve',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _PnlBadge(pnl: lastEquity - initialBalance, initial: initialBalance),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 260,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: _calcInterval(minY - padding, maxY + padding),
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: AppColors.divider,
                    strokeWidth: 0.5,
                  ),
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 60,
                      getTitlesWidget: (value, meta) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Text(
                            _formatMoney(value),
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 10,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: math.max(1, (spots.length / 5).floorToDouble()),
                      getTitlesWidget: (value, meta) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= sampled.length) {
                          return const SizedBox.shrink();
                        }
                        final dt = DateTime.fromMillisecondsSinceEpoch(
                            sampled[idx].timestamp,
                            isUtc: true);
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            DateFormat('MM/dd').format(dt),
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 9,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: false),
                minY: minY - padding,
                maxY: maxY + padding,
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.15,
                    color: lineColor,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: lineColor.withAlpha(25),
                    ),
                  ),
                  // Initial balance reference line
                  LineChartBarData(
                    spots: [
                      FlSpot(0, initialBalance),
                      FlSpot(spots.last.x, initialBalance),
                    ],
                    isCurved: false,
                    color: AppColors.textMuted.withAlpha(60),
                    barWidth: 1,
                    dotData: const FlDotData(show: false),
                    dashArray: [4, 4],
                  ),
                ],
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => AppColors.surfaceElevated,
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        if (spot.barIndex != 0) return null;
                        final idx = spot.spotIndex;
                        if (idx >= sampled.length) return null;
                        final point = sampled[idx];
                        final dt = DateTime.fromMillisecondsSinceEpoch(
                            point.timestamp, isUtc: true);
                        return LineTooltipItem(
                          '${DateFormat('MMM dd HH:mm').format(dt)}\n'
                          '\$${point.equity.toStringAsFixed(2)}\n'
                          'DD: ${point.drawdownPct.toStringAsFixed(1)}%',
                          const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        );
                      }).toList();
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<EquityPoint> _samplePoints(List<EquityPoint> points, int maxCount) {
    if (points.length <= maxCount) return points;
    final step = points.length / maxCount;
    final sampled = <EquityPoint>[];
    for (double i = 0; i < points.length; i += step) {
      sampled.add(points[i.floor()]);
    }
    // Always include the last point
    if (sampled.last != points.last) {
      sampled.add(points.last);
    }
    return sampled;
  }

  String _formatMoney(double v) {
    if (v >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}K';
    return '\$${v.toStringAsFixed(0)}';
  }

  double _calcInterval(double min, double max) {
    final range = max - min;
    if (range <= 0) return 1;
    final rawStep = range / 5;
    final mag = math.pow(10, (math.log(rawStep) / math.ln10).floor());
    return (rawStep / mag).ceil() * mag.toDouble();
  }
}

class _PnlBadge extends StatelessWidget {
  final double pnl;
  final double initial;

  const _PnlBadge({required this.pnl, required this.initial});

  @override
  Widget build(BuildContext context) {
    final pct = initial > 0 ? (pnl / initial) * 100 : 0;
    final isPositive = pnl >= 0;
    final color = isPositive ? AppColors.bullGreen : AppColors.bearRed;
    final icon = isPositive ? Icons.trending_up : Icons.trending_down;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 4),
          Text(
            '${isPositive ? '+' : ''}${pct.toStringAsFixed(2)}%',
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
