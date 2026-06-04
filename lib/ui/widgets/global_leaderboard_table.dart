/// Welle O3-B4: cross-DB cross-study leaderboard table.
///
/// Layout mirrors `TrialsTop10Table` but adds Strategy + Study
/// columns at the front and opens a slightly richer detail sheet
/// (header carries strategy + study name + db file).
library;

import 'package:flutter/material.dart';

import '../../core/models/leaderboard_row.dart';
import '../themes/app_theme.dart';

class GlobalLeaderboardTable extends StatelessWidget {
  final List<LeaderboardRow> rows;
  const GlobalLeaderboardTable({super.key, required this.rows});

  String _fmtPnl(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';

  String _fmtPf(double v) => v.isFinite ? v.toStringAsFixed(2) : '∞';

  void _openDetail(BuildContext context, LeaderboardRow r) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceCard,
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
        builder: (_, scroll) => _GlobalDetailSheet(
          row: r,
          scrollController: scroll,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Text(
        'No profitable trials yet — pin some DBs above.',
        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        key: const Key('global-leaderboard-table'),
        headingRowColor: WidgetStateProperty.all(AppColors.surfaceElevated),
        dataRowMinHeight: 36,
        dataRowMaxHeight: 44,
        columns: const [
          DataColumn(label: Text('Rank')),
          DataColumn(label: Text('Strategy')),
          DataColumn(label: Text('Study')),
          DataColumn(label: Text('Trial'), numeric: true),
          DataColumn(label: Text('Score'), numeric: true),
          DataColumn(label: Text('PnL'), numeric: true),
          DataColumn(label: Text('Trades'), numeric: true),
          DataColumn(label: Text('Win %'), numeric: true),
          DataColumn(label: Text('Sharpe'), numeric: true),
          DataColumn(label: Text('Max DD %'), numeric: true),
          DataColumn(label: Text('PF'), numeric: true),
        ],
        rows: [
          for (var i = 0; i < rows.length; i++)
            DataRow(
              key: ValueKey(rows[i].rowKey),
              onSelectChanged: (_) => _openDetail(context, rows[i]),
              cells: _cells(i, rows[i]),
            ),
        ],
      ),
    );
  }

  List<DataCell> _cells(int displayIdx, LeaderboardRow r) {
    final m = r.trial.metrics;
    return [
      DataCell(Text('#${displayIdx + 1}',
          style: const TextStyle(color: AppColors.accentCyan, fontSize: 12))),
      DataCell(Text(r.strategy,
          style:
              const TextStyle(color: AppColors.accentPurple, fontSize: 12))),
      DataCell(SizedBox(
        width: 200,
        child: Text(r.studyName,
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(color: AppColors.textPrimary, fontSize: 12)),
      )),
      DataCell(Text('${r.trial.trialId}',
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text(r.trial.score.toStringAsFixed(3),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text(_fmtPnl(m.totalPnl),
          style: TextStyle(
              color: m.totalPnl >= 0 ? AppColors.bullGreen : AppColors.bearRed,
              fontSize: 12))),
      DataCell(Text('${m.totalTrades}',
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text('${m.winRate.toStringAsFixed(1)}%',
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text(m.sharpeRatio.toStringAsFixed(2),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text('${m.maxDrawdownPct.toStringAsFixed(2)}%',
          style: const TextStyle(color: AppColors.bearRed, fontSize: 12))),
      DataCell(Text(_fmtPf(m.profitFactor),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
    ];
  }
}

class _GlobalDetailSheet extends StatelessWidget {
  final LeaderboardRow row;
  final ScrollController? scrollController;

  const _GlobalDetailSheet({required this.row, this.scrollController});

  @override
  Widget build(BuildContext context) {
    final params = row.trial.params.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      children: [
        Center(
          child: Container(
            key: const Key('global-detail-drag-handle'),
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            _badge('Trial ${row.trial.trialId}', AppColors.accentCyan),
            _badge(row.strategy, AppColors.accentPurple),
            Text(row.studyName,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 8),
        Text(row.dbPath,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 16),
        const Text('Parameters',
            style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
        const SizedBox(height: 6),
        for (final e in params) _kv(e.key, e.value.toString()),
        const SizedBox(height: 14),
        const Text('Metrics',
            style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
        const SizedBox(height: 6),
        _kv('total_trades', '${row.trial.metrics.totalTrades}'),
        _kv('total_pnl', row.trial.metrics.totalPnl.toStringAsFixed(4)),
        _kv('win_rate', '${row.trial.metrics.winRate.toStringAsFixed(2)}%'),
        _kv('sharpe_ratio', row.trial.metrics.sharpeRatio.toStringAsFixed(4)),
        _kv('max_drawdown_pct',
            '${row.trial.metrics.maxDrawdownPct.toStringAsFixed(2)}%'),
        _kv(
            'profit_factor',
            row.trial.metrics.profitFactor.isFinite
                ? row.trial.metrics.profitFactor.toStringAsFixed(4)
                : '∞'),
        _kv('final_equity',
            row.trial.metrics.finalEquity.toStringAsFixed(2)),
      ],
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withAlpha(40),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 160,
              child: Text(k,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontFamily: 'monospace')),
            ),
          ],
        ),
      );
}
