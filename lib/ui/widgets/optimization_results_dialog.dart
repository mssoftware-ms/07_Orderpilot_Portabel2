/// Full-screen dialog showing Top 10 optimization results.
///
/// Displays a sortable table of parameter combinations ranked by
/// Sharpe Ratio. Each row has a "Use" button to apply those parameters.
library;

import 'package:flutter/material.dart';
import '../themes/app_theme.dart';
import '../../services/backtest_service.dart';
import '../../services/optimization_service.dart';

class OptimizationResultsDialog extends StatefulWidget {
  final OptimizationResult result;
  final void Function(BbRsiParams params) onApply;

  const OptimizationResultsDialog({
    super.key,
    required this.result,
    required this.onApply,
  });

  /// Show the dialog as a full-screen modal.
  static Future<void> show(
    BuildContext context, {
    required OptimizationResult result,
    required void Function(BbRsiParams) onApply,
  }) {
    return showDialog(
      context: context,
      builder: (_) => OptimizationResultsDialog(
        result: result,
        onApply: onApply,
      ),
    );
  }

  @override
  State<OptimizationResultsDialog> createState() =>
      _OptimizationResultsDialogState();
}

class _OptimizationResultsDialogState
    extends State<OptimizationResultsDialog> {
  int _sortColumnIndex = 5; // Sharpe Ratio
  bool _sortAscending = false;
  late List<OptimizationTrial> _sorted;

  @override
  void initState() {
    super.initState();
    _sorted = List.of(widget.result.topResults);
  }

  void _sort(int colIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = colIndex;
      _sortAscending = ascending;
      _sorted.sort((a, b) {
        int cmp;
        switch (colIndex) {
          case 0:
            cmp = a.params.bbPeriod.compareTo(b.params.bbPeriod);
          case 1:
            cmp = a.params.bbStdDev.compareTo(b.params.bbStdDev);
          case 2:
            cmp = a.params.rsiPeriod.compareTo(b.params.rsiPeriod);
          case 3:
            cmp = a.params.rsiOversold.compareTo(b.params.rsiOversold);
          case 4:
            cmp = a.params.rsiOverbought.compareTo(b.params.rsiOverbought);
          case 5:
            cmp = a.sharpeRatio.compareTo(b.sharpeRatio);
          case 6:
            cmp = a.profitFactor.compareTo(b.profitFactor);
          case 7:
            cmp = a.totalReturn.compareTo(b.totalReturn);
          case 8:
            cmp = a.winRate.compareTo(b.winRate);
          default:
            cmp = 0;
        }
        return ascending ? cmp : -cmp;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;

    return Dialog.fullscreen(
      backgroundColor: AppColors.scaffoldBg,
      child: Scaffold(
        backgroundColor: AppColors.scaffoldBg,
        appBar: AppBar(
          backgroundColor: AppColors.surfaceDark,
          title: const Text('Optimization Results'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${r.combinationsRun} tested in ${r.elapsed.inSeconds}s',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
        body: _sorted.isEmpty
            ? const Center(
                child: Text(
                  'No valid results found.\nTry a different date range or data set.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    sortColumnIndex: _sortColumnIndex,
                    sortAscending: _sortAscending,
                    headingRowColor: WidgetStateProperty.all(
                        AppColors.surfaceCard),
                    dataRowColor: WidgetStateProperty.resolveWith(
                        (states) {
                      if (states.contains(WidgetState.hovered)) {
                        return AppColors.surfaceElevated;
                      }
                      return AppColors.scaffoldBg;
                    }),
                    columnSpacing: 16,
                    horizontalMargin: 12,
                    headingTextStyle: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                    dataTextStyle: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                    ),
                    columns: [
                      _col('#', numeric: true, sortable: false),
                      _col('BB Per', numeric: true, index: 0),
                      _col('BB Std', numeric: true, index: 1),
                      _col('RSI Per', numeric: true, index: 2),
                      _col('RSI OS', numeric: true, index: 3),
                      _col('RSI OB', numeric: true, index: 4),
                      _col('Sharpe', numeric: true, index: 5),
                      _col('PF', numeric: true, index: 6),
                      _col('Return %', numeric: true, index: 7),
                      _col('Win %', numeric: true, index: 8),
                      _col('DD %', numeric: true, sortable: false),
                      _col('Trades', numeric: true, sortable: false),
                      const DataColumn(label: Text(''), numeric: false),
                    ],
                    rows: List.generate(_sorted.length, (i) {
                      final t = _sorted[i];
                      final isFirst = i == 0;
                      return DataRow(
                        cells: [
                          DataCell(Text(
                            '#${i + 1}',
                            style: TextStyle(
                              color: isFirst
                                  ? AppColors.accentCyan
                                  : AppColors.textMuted,
                              fontWeight:
                                  isFirst ? FontWeight.bold : FontWeight.normal,
                            ),
                          )),
                          DataCell(Text('${t.params.bbPeriod}')),
                          DataCell(Text(t.params.bbStdDev.toStringAsFixed(1))),
                          DataCell(Text('${t.params.rsiPeriod}')),
                          DataCell(Text(
                              t.params.rsiOversold.toStringAsFixed(0))),
                          DataCell(Text(
                              t.params.rsiOverbought.toStringAsFixed(0))),
                          DataCell(Text(
                            t.sharpeRatio.toStringAsFixed(2),
                            style: TextStyle(
                              color: t.sharpeRatio >= 1.0
                                  ? AppColors.bullGreen
                                  : t.sharpeRatio >= 0
                                      ? AppColors.warningAmber
                                      : AppColors.bearRed,
                              fontWeight: FontWeight.w600,
                            ),
                          )),
                          DataCell(Text(
                            t.profitFactor.toStringAsFixed(2),
                            style: TextStyle(
                              color: t.profitFactor >= 1.5
                                  ? AppColors.bullGreen
                                  : t.profitFactor >= 1.0
                                      ? AppColors.warningAmber
                                      : AppColors.bearRed,
                            ),
                          )),
                          DataCell(Text(
                            '${t.totalReturn >= 0 ? '+' : ''}${t.totalReturn.toStringAsFixed(1)}%',
                            style: TextStyle(
                              color: t.totalReturn >= 0
                                  ? AppColors.bullGreen
                                  : AppColors.bearRed,
                            ),
                          )),
                          DataCell(Text(
                            '${t.winRate.toStringAsFixed(1)}%',
                            style: TextStyle(
                              color: t.winRate >= 50
                                  ? AppColors.bullGreen
                                  : AppColors.textSecondary,
                            ),
                          )),
                          DataCell(Text(
                            '${t.maxDrawdownPercent.toStringAsFixed(1)}%',
                            style: const TextStyle(color: AppColors.bearRed),
                          )),
                          DataCell(Text('${t.totalTrades}')),
                          DataCell(
                            Tooltip(
                              message:
                                  'Optimizer wartet auf Phase 2-Abschluss '
                                  '(siehe 260522_Gesamtplan_Phase1-3.md §3.3)',
                              child: TextButton(
                                onPressed: null,
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 4),
                                  backgroundColor:
                                      AppColors.accentCyan.withAlpha(20),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6),
                                    side: const BorderSide(
                                        color: AppColors.accentCyan,
                                        width: 0.5),
                                  ),
                                ),
                                child: const Text(
                                  'Use',
                                  style: TextStyle(
                                    color: AppColors.accentCyan,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                  ),
                ),
              ),
      ),
    );
  }

  DataColumn _col(String label,
      {bool numeric = false, bool sortable = true, int? index}) {
    return DataColumn(
      label: Text(label),
      numeric: numeric,
      onSort: sortable && index != null ? _sort : null,
    );
  }
}
