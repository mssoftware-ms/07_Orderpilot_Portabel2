/// Welle O3-B2-5: scatter plot for the Optuna-style trials list.
///
/// Two view modes:
///   - **Score mode** (default): x = trial_id, y = score. Non-finite
///     scores (-inf for 0-trade trials) are clamped onto a baseline
///     below the min finite score and rendered grey, so they appear in
///     the plot but do not blow up the y-axis bounds — fl_chart's auto-
///     ranging would otherwise produce NaN/Inf axis bounds and crash.
///   - **Param mode**: x = trial_id, y = the picked param's value.
///     Points are colored by score-bucket (Q1 worst → bearRed,
///     Q4 best → bullGreen) so the user can spot which areas of the
///     parameter range actually converged.
///
/// The widget reads the optimized parameter list from
/// `parseSearchSpace(study.searchSpaceYaml)` — `fixed:` values never
/// appear in the dropdown.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/models/trial.dart';
import '../../core/utils/search_space.dart';
import '../themes/app_theme.dart';

class ParamConvergencePlot extends StatefulWidget {
  final List<Trial> trials;
  final String searchSpaceYaml;

  const ParamConvergencePlot({
    super.key,
    required this.trials,
    required this.searchSpaceYaml,
  });

  @override
  State<ParamConvergencePlot> createState() => _ParamConvergencePlotState();
}

class _ParamConvergencePlotState extends State<ParamConvergencePlot> {
  String? _selectedParam; // null = score mode

  late final List<ParamSpec> _params =
      parseSearchSpace(widget.searchSpaceYaml)
          .where((p) => p.isNumeric)
          .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    if (widget.trials.isEmpty) {
      return const Text(
        'No trials to plot yet.',
        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
      );
    }

    final yMode = _selectedParam == null ? _YMode.score : _YMode.param;
    final dataset = _buildDataset(widget.trials, yMode, _selectedParam);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _modeSwitcher(),
        const SizedBox(height: 8),
        SizedBox(
          height: 280,
          child: ScatterChart(
            key: const Key('convergence-scatter-chart'),
            ScatterChartData(
              minX: dataset.minX,
              maxX: dataset.maxX,
              minY: dataset.minY,
              maxY: dataset.maxY,
              scatterSpots: dataset.spots,
              borderData: FlBorderData(
                show: true,
                border: Border.all(color: AppColors.border),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  axisNameWidget: const Text(
                    'trial_id',
                    style: TextStyle(
                        color: AppColors.textMuted, fontSize: 10),
                  ),
                  sideTitles: const SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                  ),
                ),
                leftTitles: AxisTitles(
                  axisNameWidget: Text(
                    _selectedParam ?? 'score',
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 10),
                  ),
                  sideTitles: const SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                  ),
                ),
              ),
              gridData: FlGridData(
                show: true,
                drawHorizontalLine: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: AppColors.border.withAlpha(70),
                  strokeWidth: 0.5,
                ),
              ),
              scatterTouchData: ScatterTouchData(
                enabled: true,
                touchTooltipData: ScatterTouchTooltipData(
                  getTooltipColor: (_) => AppColors.surfaceElevated,
                  getTooltipItems: (spot) {
                    final idx = dataset.spots.indexOf(spot);
                    if (idx < 0 || idx >= dataset.tooltipLines.length) {
                      return null;
                    }
                    return ScatterTooltipItem(
                      dataset.tooltipLines[idx],
                      textStyle: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 10,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _modeSwitcher() {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text(
          'Y-axis:',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
        ),
        ChoiceChip(
          key: const Key('convergence-mode-score-chip'),
          label: const Text('score'),
          selected: _selectedParam == null,
          onSelected: (s) {
            if (s) setState(() => _selectedParam = null);
          },
          labelStyle: TextStyle(
            color: _selectedParam == null
                ? AppColors.accentCyan
                : AppColors.textSecondary,
            fontSize: 11,
          ),
          selectedColor: AppColors.accentCyan.withAlpha(40),
          backgroundColor: AppColors.surfaceElevated,
          side: BorderSide(
            color: _selectedParam == null
                ? AppColors.accentCyan
                : AppColors.border,
          ),
        ),
        ..._params.map((p) => ChoiceChip(
              key: Key('convergence-mode-${p.name}-chip'),
              label: Text(p.name),
              selected: _selectedParam == p.name,
              onSelected: (s) {
                if (s) setState(() => _selectedParam = p.name);
              },
              labelStyle: TextStyle(
                color: _selectedParam == p.name
                    ? AppColors.accentPurple
                    : AppColors.textSecondary,
                fontSize: 11,
              ),
              selectedColor: AppColors.accentPurple.withAlpha(40),
              backgroundColor: AppColors.surfaceElevated,
              side: BorderSide(
                color: _selectedParam == p.name
                    ? AppColors.accentPurple
                    : AppColors.border,
              ),
            )),
      ],
    );
  }

  _Dataset _buildDataset(
      List<Trial> trials, _YMode mode, String? paramName) {
    // 1. Compute finite-score quantile thresholds so points in param-mode
    //    can be colour-coded by score-bucket.
    final finiteScores = trials.where((t) => t.scoreIsFinite).toList()
      ..sort((a, b) => a.score.compareTo(b.score));
    final qThresholds = _quartileThresholds(
        finiteScores.map((t) => t.score).toList(growable: false));

    // 2. Min finite Y (for the -inf clamp in score-mode) and the visible
    //    y-bounds.
    double? minFiniteY;
    double? maxFiniteY;
    for (final t in trials) {
      final y = mode == _YMode.score
          ? t.score
          : (paramName != null
              ? (t.params[paramName] ?? double.nan)
              : double.nan);
      if (y.isFinite) {
        minFiniteY = minFiniteY == null ? y : (y < minFiniteY ? y : minFiniteY);
        maxFiniteY = maxFiniteY == null ? y : (y > maxFiniteY ? y : maxFiniteY);
      }
    }
    minFiniteY ??= 0.0;
    maxFiniteY ??= 1.0;
    if (maxFiniteY == minFiniteY) {
      // Avoid zero-range axis (fl_chart would draw nothing).
      maxFiniteY = minFiniteY + 1.0;
    }
    final yRange = maxFiniteY - minFiniteY;
    final clampY = minFiniteY - yRange * 0.1;

    int minX = 0;
    int maxX = 0;
    for (final t in trials) {
      if (t.trialId < minX) minX = t.trialId;
      if (t.trialId > maxX) maxX = t.trialId;
    }
    if (maxX == minX) maxX = minX + 1;

    final spots = <ScatterSpot>[];
    final tooltipLines = <String>[];
    for (final t in trials) {
      double y;
      bool nonFinite;
      if (mode == _YMode.score) {
        y = t.score.isFinite ? t.score : clampY;
        nonFinite = !t.score.isFinite;
      } else {
        final raw = paramName != null ? t.params[paramName] : null;
        if (raw == null || !raw.isFinite) {
          // Skip trials missing the chosen param.
          continue;
        }
        y = raw;
        nonFinite = false;
      }

      final color = nonFinite
          ? AppColors.textMuted
          : (mode == _YMode.score
              ? AppColors.accentCyan
              : _scoreBucketColor(t.score, qThresholds));

      spots.add(ScatterSpot(
        t.trialId.toDouble(),
        y,
        dotPainter: FlDotCirclePainter(
          radius: 3.5,
          color: color,
          strokeColor: color.withAlpha(180),
          strokeWidth: 0.5,
        ),
      ));
      tooltipLines.add(_tooltipFor(t, paramName));
    }

    return _Dataset(
      spots: spots,
      tooltipLines: tooltipLines,
      minX: minX.toDouble(),
      maxX: maxX.toDouble(),
      minY: mode == _YMode.score ? clampY : minFiniteY - yRange * 0.05,
      maxY: maxFiniteY + yRange * 0.05,
    );
  }

  Color _scoreBucketColor(double score, List<double> qs) {
    if (!score.isFinite) return AppColors.textMuted;
    // qs: [q1, q2, q3]. Below q1 = worst, above q3 = best.
    if (qs.isEmpty) return AppColors.accentCyan;
    if (score < qs[0]) return AppColors.bearRed;
    if (score < qs[1]) return AppColors.warningAmber;
    if (score < qs[2]) return AppColors.accentBlue;
    return AppColors.bullGreen;
  }

  List<double> _quartileThresholds(List<double> sorted) {
    if (sorted.length < 4) return const [];
    double q(int index) => sorted[
        (index * sorted.length / 4).floor().clamp(0, sorted.length - 1)];
    return [q(1), q(2), q(3)];
  }

  String _tooltipFor(Trial t, String? paramName) {
    final parts = <String>[
      'trial ${t.trialId}',
      t.scoreIsFinite
          ? 'score=${t.score.toStringAsFixed(3)}'
          : 'score=-inf',
    ];
    if (paramName != null) {
      final v = t.params[paramName];
      parts.add('$paramName=${v?.toStringAsFixed(3) ?? '?'}');
    }
    return parts.join('  ');
  }
}

enum _YMode { score, param }

class _Dataset {
  final List<ScatterSpot> spots;
  final List<String> tooltipLines;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  const _Dataset({
    required this.spots,
    required this.tooltipLines,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });
}
