import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../themes/app_theme.dart';
import '../../core/models/trade.dart';

/// Scrollable trade log list with expandable details.
class TradeLogList extends StatelessWidget {
  final List<ClosedTrade> trades;

  const TradeLogList({super.key, required this.trades});

  @override
  Widget build(BuildContext context) {
    if (trades.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(32),
        alignment: Alignment.center,
        child: const Text('No trades executed',
            style: TextStyle(color: AppColors.textMuted)),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.list_alt, color: AppColors.accentCyan, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Trade Log (${trades.length})',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Header row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: const [
                Expanded(flex: 2, child: _HeaderCell('Time')),
                Expanded(flex: 1, child: _HeaderCell('Dir')),
                Expanded(flex: 2, child: _HeaderCell('Entry')),
                Expanded(flex: 2, child: _HeaderCell('Exit')),
                Expanded(flex: 2, child: _HeaderCell('PnL')),
                Expanded(flex: 1, child: _HeaderCell('Reason')),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.divider),
          // Trade rows
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: trades.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 1, color: AppColors.divider),
            itemBuilder: (context, index) {
              final trade = trades[index];
              return _TradeRow(trade: trade, index: index);
            },
          ),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String text;
  const _HeaderCell(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textMuted,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _TradeRow extends StatelessWidget {
  final ClosedTrade trade;
  final int index;

  const _TradeRow({required this.trade, required this.index});

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('MM/dd HH:mm');
    final entryDt = DateTime.fromMillisecondsSinceEpoch(
        trade.entryTimestamp, isUtc: true);
    final isWin = trade.pnl > 0;
    final pnlColor = isWin ? AppColors.bullGreen : AppColors.bearRed;
    final dirColor = trade.direction == 'LONG'
        ? AppColors.bullGreen
        : AppColors.bearRed;

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      collapsedIconColor: AppColors.textMuted,
      iconColor: AppColors.accentCyan,
      title: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              dateFmt.format(entryDt),
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11),
            ),
          ),
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: dirColor.withAlpha(25),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                trade.direction,
                style: TextStyle(
                    color: dirColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '\$${trade.entryPrice.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 11),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '\$${trade.exitPrice.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 11),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${isWin ? '+' : ''}\$${trade.pnl.toStringAsFixed(2)}',
              style: TextStyle(
                color: pnlColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              trade.exitReason,
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 10),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      children: [
        Row(
          children: [
            _DetailChip('Qty', trade.quantity.toStringAsFixed(6)),
            const SizedBox(width: 8),
            _DetailChip('Fees', '\$${trade.fees.toStringAsFixed(2)}'),
            const SizedBox(width: 8),
            _DetailChip('PnL %',
                '${trade.pnlPercent >= 0 ? '+' : ''}${trade.pnlPercent.toStringAsFixed(2)}%'),
            const SizedBox(width: 8),
            _DetailChip('Exit', trade.exitReason),
          ],
        ),
      ],
    );
  }
}

class _DetailChip extends StatelessWidget {
  final String label;
  final String value;
  const _DetailChip(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 10),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
