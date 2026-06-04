/// Welle O3-B2-4: Top-10 trials DataTable for the Studies viewer.
///
/// Renders the descending-by-score list from `StudiesProvider.top10`,
/// sortable per column. Tapping a row opens a ModalBottomSheet with the
/// full params and metrics blobs (the bits the table doesn't show).
///
/// `-inf` scores never reach this table — `StudiesDb.top10` filters
/// them out at the SQL layer. Defensive: any non-finite score that
/// sneaks in is rendered greyed-out with a "no trades" suffix.
library;

import 'package:flutter/material.dart';

import '../../core/models/trial.dart';
import '../themes/app_theme.dart';

enum _SortField { rank, trialId, score, totalTrades, totalPnl, winRate, sharpe, maxDd, profitFactor }

class TrialsTop10Table extends StatefulWidget {
  final List<Trial> trials;

  const TrialsTop10Table({super.key, required this.trials});

  @override
  State<TrialsTop10Table> createState() => _TrialsTop10TableState();
}

class _TrialsTop10TableState extends State<TrialsTop10Table> {
  // Welle O3-B4-13: default sort is PnL, not score. Real production
  // studies write score=-inf for nearly every trial, so a score-default
  // would re-order the PnL-ranked rows from `top10()` arbitrarily.
  _SortField _sortField = _SortField.totalPnl;
  bool _ascending = false; // best-first by default

  List<Trial> get _sortedTrials {
    final out = List<Trial>.of(widget.trials);
    int cmp(Trial a, Trial b) {
      int result;
      switch (_sortField) {
        case _SortField.rank:
        case _SortField.score:
          result = a.score.compareTo(b.score);
          break;
        case _SortField.trialId:
          result = a.trialId.compareTo(b.trialId);
          break;
        case _SortField.totalTrades:
          result = a.metrics.totalTrades.compareTo(b.metrics.totalTrades);
          break;
        case _SortField.totalPnl:
          result = a.metrics.totalPnl.compareTo(b.metrics.totalPnl);
          break;
        case _SortField.winRate:
          result = a.metrics.winRate.compareTo(b.metrics.winRate);
          break;
        case _SortField.sharpe:
          result = a.metrics.sharpeRatio.compareTo(b.metrics.sharpeRatio);
          break;
        case _SortField.maxDd:
          result =
              a.metrics.maxDrawdownPct.compareTo(b.metrics.maxDrawdownPct);
          break;
        case _SortField.profitFactor:
          result = _compareDoubleSafe(
              a.metrics.profitFactor, b.metrics.profitFactor);
          break;
      }
      return _ascending ? result : -result;
    }

    out.sort(cmp);
    return out;
  }

  /// `compareTo` on +Infinity / -Infinity is well-defined, but NaN turns
  /// `>`/`<` into false. `compareTo` happens to handle NaN safely (NaN
  /// sorts last), so this helper is currently just a documentation
  /// anchor for the contract.
  int _compareDoubleSafe(double a, double b) => a.compareTo(b);

  void _onSort(_SortField field) {
    setState(() {
      if (_sortField == field) {
        _ascending = !_ascending;
      } else {
        _sortField = field;
        _ascending = field == _SortField.maxDd; // lower-is-better column
      }
    });
  }

  void _openDetail(BuildContext context, Trial t) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceCard,
      // Welle O3-B2.1-2: isScrollControlled + useSafeArea fixes the
      // Windows-taskbar overlap that hid the bottom-most params/metrics.
      // The maxWidth cap stops the sheet from spanning a 27" monitor —
      // 720 px matches the content layout (160 px label column + 560 px
      // value column with comfortable padding).
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 720),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        builder: (_, scrollController) => _TrialDetailSheet(
          trial: t,
          scrollController: scrollController,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trials = _sortedTrials;
    if (trials.isEmpty) {
      return const Text(
        'No trials in this study yet.',
        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
      );
    }

    final sortColumnIndex = _columnIndexOf(_sortField);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        key: const Key('trials-top10-table'),
        headingRowColor: WidgetStateProperty.all(AppColors.surfaceElevated),
        dataRowMinHeight: 36,
        dataRowMaxHeight: 44,
        sortColumnIndex: sortColumnIndex,
        sortAscending: _ascending,
        columns: [
          _col('Rank', _SortField.rank),
          _col('Trial', _SortField.trialId),
          _col('Score', _SortField.score, numeric: true),
          _col('Trades', _SortField.totalTrades, numeric: true),
          _col('PnL', _SortField.totalPnl, numeric: true),
          _col('Win %', _SortField.winRate, numeric: true),
          _col('Sharpe', _SortField.sharpe, numeric: true),
          _col('Max DD %', _SortField.maxDd, numeric: true),
          _col('PF', _SortField.profitFactor, numeric: true),
        ],
        rows: [
          for (var i = 0; i < trials.length; i++)
            _row(context, i, trials[i]),
        ],
      ),
    );
  }

  DataColumn _col(String label, _SortField field, {bool numeric = false}) {
    return DataColumn(
      label: Text(
        label,
        style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600),
      ),
      numeric: numeric,
      onSort: (_, _) => _onSort(field),
    );
  }

  int _columnIndexOf(_SortField f) {
    switch (f) {
      case _SortField.rank:
        return 0;
      case _SortField.trialId:
        return 1;
      case _SortField.score:
        return 2;
      case _SortField.totalTrades:
        return 3;
      case _SortField.totalPnl:
        return 4;
      case _SortField.winRate:
        return 5;
      case _SortField.sharpe:
        return 6;
      case _SortField.maxDd:
        return 7;
      case _SortField.profitFactor:
        return 8;
    }
  }

  DataRow _row(BuildContext context, int displayRank, Trial t) {
    final isNonFiniteScore = !t.scoreIsFinite;
    final scoreColor =
        isNonFiniteScore ? AppColors.textMuted : AppColors.textPrimary;
    final scoreText = isNonFiniteScore
        ? '— (no trades)'
        : t.score.toStringAsFixed(3);

    return DataRow(
      key: ValueKey('trial-${t.id}'),
      onSelectChanged: (_) => _openDetail(context, t),
      cells: [
        _cell('#${displayRank + 1}', AppColors.accentCyan),
        _cell('${t.trialId}', AppColors.textPrimary),
        _cell(scoreText, scoreColor),
        _cell('${t.metrics.totalTrades}', AppColors.textPrimary),
        _cell(_fmtPnl(t.metrics.totalPnl),
            t.metrics.totalPnl >= 0 ? AppColors.bullGreen : AppColors.bearRed),
        _cell('${t.metrics.winRate.toStringAsFixed(1)}%',
            AppColors.textPrimary),
        _cell(t.metrics.sharpeRatio.toStringAsFixed(2),
            AppColors.textPrimary),
        _cell('${t.metrics.maxDrawdownPct.toStringAsFixed(2)}%',
            AppColors.bearRed),
        _cell(_fmtPf(t.metrics.profitFactor), AppColors.textPrimary),
      ],
    );
  }

  DataCell _cell(String text, Color color) {
    return DataCell(
      Text(
        text,
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }

  String _fmtPnl(double pnl) {
    final sign = pnl >= 0 ? '+' : '';
    return '$sign${pnl.toStringAsFixed(2)}';
  }

  String _fmtPf(double pf) {
    if (!pf.isFinite) return '∞';
    return pf.toStringAsFixed(2);
  }
}

// ─── Detail sheet ───────────────────────────────────────────────────────────

class _TrialDetailSheet extends StatelessWidget {
  final Trial trial;

  /// Threaded down from [DraggableScrollableSheet.builder]. The inner
  /// [ListView] MUST use this controller — otherwise drag-to-expand
  /// gestures stay trapped in the ListView and the sheet refuses to
  /// resize. Tests assert that dragging the handle moves the sheet up.
  final ScrollController? scrollController;

  const _TrialDetailSheet({required this.trial, this.scrollController});

  @override
  Widget build(BuildContext context) {
    final params = trial.params.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    // The drag handle lives INSIDE the ListView so a press-drag on the
    // handle routes through the scrollController-driven Scrollable —
    // DraggableScrollableSheet only resizes when its inner Scrollable
    // sees the drag (at scrollOffset == 0, upward drag → sheet grows).
    // A handle outside the ListView would render but not be draggable.
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      children: [
        Center(
          child: Container(
            key: const Key('trial-detail-drag-handle'),
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.accentCyan.withAlpha(40),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Trial ${trial.trialId}',
                style: const TextStyle(
                  color: AppColors.accentCyan,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              trial.scoreIsFinite
                  ? 'Score ${trial.score.toStringAsFixed(4)}'
                  : 'Score — (no trades)',
              style: TextStyle(
                color: trial.scoreIsFinite
                    ? AppColors.textPrimary
                    : AppColors.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('Parameters',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            )),
        const SizedBox(height: 6),
        for (final entry in params)
          _kvRow(entry.key, entry.value.toString()),
        const SizedBox(height: 14),
        const Text('Metrics',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            )),
        const SizedBox(height: 6),
        _kvRow('total_trades', '${trial.metrics.totalTrades}'),
        _kvRow('total_pnl', trial.metrics.totalPnl.toStringAsFixed(4)),
        _kvRow('win_rate', '${trial.metrics.winRate.toStringAsFixed(2)}%'),
        _kvRow('sharpe_ratio', trial.metrics.sharpeRatio.toStringAsFixed(4)),
        _kvRow('max_drawdown_pct',
            '${trial.metrics.maxDrawdownPct.toStringAsFixed(2)}%'),
        _kvRow(
            'profit_factor',
            trial.metrics.profitFactor.isFinite
                ? trial.metrics.profitFactor.toStringAsFixed(4)
                : '∞'),
        _kvRow('final_equity', trial.metrics.finalEquity.toStringAsFixed(2)),
      ],
    );
  }

  Widget _kvRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(
              k,
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
