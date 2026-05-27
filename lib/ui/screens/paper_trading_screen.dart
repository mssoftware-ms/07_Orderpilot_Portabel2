/// Welle B4-3 — Paper-Trading dashboard.
///
/// Replaces the Phase-3 ComingSoonBanner with a live session UI:
/// status card with Start/Stop + Sync-from-Backtest, active-session
/// summary, optional open-position card with mark-to-market PnL, a
/// recent-closed-trades table, and a compact equity-curve sparkline.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/models/trade.dart';
import '../../features/backtest/backtest_provider.dart';
import '../../features/paper/paper_position.dart';
import '../../features/paper/paper_session.dart';
import '../../features/paper/paper_trading_provider.dart';
import '../../services/backtest_service.dart';
import '../themes/app_theme.dart';

class PaperTradingScreen extends StatelessWidget {
  const PaperTradingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<PaperTradingProvider>();
    final session = provider.session;
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Paper Trading', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                'Live signal observer with virtual fills — '
                'no real funds at risk',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),

              _StatusCard(provider: provider),
              const SizedBox(height: 12),
              _SlippageCard(provider: provider),
              const SizedBox(height: 12),

              if (session != null) ...[
                _ActiveSessionCard(session: session),
                const SizedBox(height: 12),
                if (session.equityCurve.isNotEmpty)
                  _EquitySparkline(
                    points: session.equityCurve,
                    initialBalance: session.config.initialBalance,
                  ),
                if (session.equityCurve.isNotEmpty) const SizedBox(height: 12),
                if (session.openPosition != null) ...[
                  _OpenPositionCard(
                    position: session.openPosition!,
                    markPrice: session.latestMarkPrice,
                  ),
                  const SizedBox(height: 12),
                ],
                _RecentTradesCard(trades: session.closedTrades),
              ] else
                _EmptyStateCard(provider: provider),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Status card ──────────────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final PaperTradingProvider provider;
  const _StatusCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final status = provider.status;
    final (label, color, icon) = _statusVisual(status);
    final isStartable = !provider.isActive;
    final pending = provider.pendingConfig;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatusDot(color: color, key: const Key('paper-status-dot')),
                const SizedBox(width: 10),
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 6),
                Text(
                  label,
                  key: const Key('paper-status-label'),
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (status == PaperSessionStatus.reconnecting) ...[
                  const SizedBox(width: 8),
                  Text(
                    '(attempt ${provider.reconnectAttempts})',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
                const Spacer(),
                if (isStartable)
                  ElevatedButton.icon(
                    key: const Key('paper-start-button'),
                    onPressed: () => provider.start(),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Start'),
                  )
                else
                  OutlinedButton.icon(
                    key: const Key('paper-stop-button'),
                    onPressed: provider.stop,
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('Stop'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton.icon(
                  key: const Key('paper-sync-backtest-button'),
                  onPressed: () => _onSync(context),
                  icon: const Icon(Icons.sync_alt, size: 16),
                  label: const Text('Sync from Backtest'),
                ),
                if (pending != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      'Pending: ${pending.symbol} · ${pending.timeframe} · '
                      '${pending.strategyKind.displayLabel}',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
            if (provider.errorMessage != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.bearRed.withAlpha(40),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: AppColors.bearRed, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        provider.errorMessage!,
                        style: const TextStyle(
                          color: AppColors.bearRed,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _onSync(BuildContext context) {
    final backtest = context.read<BacktestProvider>();
    provider.syncFromBacktest(backtest.config);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Synced ${backtest.config.symbol} · ${backtest.config.timeframe} · '
          '${backtest.config.strategyKind.displayLabel}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

(String, Color, IconData) _statusVisual(PaperSessionStatus s) {
  switch (s) {
    case PaperSessionStatus.idle:
      return ('Idle', AppColors.textMuted, Icons.circle_outlined);
    case PaperSessionStatus.connecting:
      return ('Connecting', AppColors.warningAmber, Icons.cloud_sync);
    case PaperSessionStatus.running:
      return ('Running', AppColors.bullGreen, Icons.bolt);
    case PaperSessionStatus.reconnecting:
      return ('Reconnecting', AppColors.warningAmber, Icons.cloud_off);
    case PaperSessionStatus.stopped:
      return ('Stopped', AppColors.textMuted, Icons.stop_circle);
    case PaperSessionStatus.error:
      return ('Error', AppColors.bearRed, Icons.error);
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;
  const _StatusDot({required this.color, super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

// ─── Session slippage card ────────────────────────────────────────────────

class _SlippageCard extends StatelessWidget {
  final PaperTradingProvider provider;
  const _SlippageCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    final isActive = provider.isActive;
    // While running, show the frozen session value. While idle, show
    // the live pending value the user is tuning.
    final live = isActive
        ? (provider.session?.config.slippageBps ?? provider.pendingSlippageBps)
        : provider.pendingSlippageBps;
    final hint = isActive
        ? 'Locked for the active session'
        : 'Binance Spot retail default = 5 bps';

    return Card(
      key: const Key('paper-slippage-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_horiz,
                    color: AppColors.accentCyan, size: 16),
                const SizedBox(width: 6),
                const Text(
                  'Session slippage',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${live.toStringAsFixed(0)} bps',
                  key: const Key('paper-slippage-value'),
                  style: const TextStyle(
                    color: AppColors.accentCyan,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('paper-slippage-slider'),
              value: live.clamp(
                PaperConfig.minSlippageBps,
                PaperConfig.maxSlippageBps,
              ),
              min: PaperConfig.minSlippageBps,
              max: PaperConfig.maxSlippageBps,
              divisions: 20,
              onChanged: isActive
                  ? null
                  : (v) => provider.setPendingSlippage(v),
            ),
            Text(
              hint,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Active session card ──────────────────────────────────────────────────

class _ActiveSessionCard extends StatelessWidget {
  final PaperSession session;
  const _ActiveSessionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final pnl = session.totalPnl;
    final pnlPct = session.totalPnlPercent;
    final pnlColor = pnl >= 0 ? AppColors.bullGreen : AppColors.bearRed;
    final cfg = session.config;

    return Card(
      key: const Key('paper-active-session-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.dashboard_outlined,
                    color: AppColors.accentCyan, size: 18),
                const SizedBox(width: 8),
                Text(
                  '${cfg.symbol} · ${cfg.timeframe} · '
                  '${cfg.strategyKind.displayLabel}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${session.tickCount} tick${session.tickCount == 1 ? '' : 's'}',
                  key: const Key('paper-tick-counter'),
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _StatTile(
                  label: 'Equity',
                  value: _fmtMoney(session.equity),
                  valueColor: AppColors.accentCyan,
                ),
                const SizedBox(width: 12),
                _StatTile(
                  label: 'P&L',
                  value: '${_fmtSignedMoney(pnl)} '
                      '(${pnlPct >= 0 ? '+' : ''}${pnlPct.toStringAsFixed(2)}%)',
                  valueColor: pnlColor,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _StatTile(
                  label: 'Initial',
                  value: _fmtMoney(cfg.initialBalance),
                ),
                const SizedBox(width: 12),
                _StatTile(
                  label: 'Fee rate',
                  value: '${(cfg.feeRate * 100).toStringAsFixed(4)}%',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Open-position card ───────────────────────────────────────────────────

class _OpenPositionCard extends StatelessWidget {
  final PaperPosition position;
  final double? markPrice;

  const _OpenPositionCard({required this.position, required this.markPrice});

  @override
  Widget build(BuildContext context) {
    final mark = markPrice ?? position.entryPrice;
    final unrealized = position.unrealizedPnl(mark);
    final unrealizedPct = position.unrealizedPnlPercent(mark);
    final pnlColor =
        unrealized >= 0 ? AppColors.bullGreen : AppColors.bearRed;
    final dirColor =
        position.isLong ? AppColors.bullGreen : AppColors.bearRed;

    return Card(
      key: const Key('paper-open-position-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: dirColor.withAlpha(40),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    position.direction,
                    style: TextStyle(
                      color: dirColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Open position',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_fmtSignedMoney(unrealized)} '
                  '(${unrealizedPct >= 0 ? '+' : ''}${unrealizedPct.toStringAsFixed(2)}%)',
                  style: TextStyle(
                    color: pnlColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _StatTile(label: 'Entry', value: _fmtPrice(position.entryPrice)),
                const SizedBox(width: 12),
                _StatTile(label: 'Mark', value: _fmtPrice(mark)),
                const SizedBox(width: 12),
                _StatTile(
                  label: 'Qty',
                  value: position.quantity.toStringAsFixed(6),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _StatTile(
                  label: 'SL',
                  value: position.slPrice == null
                      ? '—'
                      : _fmtPrice(position.slPrice!),
                ),
                const SizedBox(width: 12),
                _StatTile(
                  label: 'TP',
                  value: position.tpPrice == null
                      ? '—'
                      : _fmtPrice(position.tpPrice!),
                ),
                const SizedBox(width: 12),
                _StatTile(
                  label: 'Opened',
                  value: _fmtTime(position.openedAt),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Recent trades card ───────────────────────────────────────────────────

class _RecentTradesCard extends StatelessWidget {
  final List<ClosedTrade> trades;
  const _RecentTradesCard({required this.trades});

  static const int _maxRows = 10;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('paper-recent-trades-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.history, color: AppColors.accentCyan, size: 18),
                SizedBox(width: 8),
                Text(
                  'Recent trades',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (trades.isEmpty)
              const Text(
                'No closed trades yet.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  key: const Key('paper-recent-trades-table'),
                  headingRowColor:
                      WidgetStateProperty.all(AppColors.surfaceElevated),
                  dataRowMinHeight: 32,
                  dataRowMaxHeight: 40,
                  columns: const [
                    DataColumn(label: Text('Time')),
                    DataColumn(label: Text('Side')),
                    DataColumn(label: Text('Entry'), numeric: true),
                    DataColumn(label: Text('Exit'), numeric: true),
                    DataColumn(label: Text('Qty'), numeric: true),
                    DataColumn(label: Text('PnL'), numeric: true),
                    DataColumn(label: Text('Reason')),
                  ],
                  rows: [
                    for (final t in _newestFirst(trades).take(_maxRows))
                      _row(t),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Iterable<ClosedTrade> _newestFirst(List<ClosedTrade> in_) {
    final out = List<ClosedTrade>.of(in_);
    out.sort((a, b) => b.exitTimestamp.compareTo(a.exitTimestamp));
    return out;
  }

  DataRow _row(ClosedTrade t) {
    final pnlColor = t.pnl >= 0 ? AppColors.bullGreen : AppColors.bearRed;
    final sideColor =
        t.direction == 'LONG' ? AppColors.bullGreen : AppColors.bearRed;
    return DataRow(
      cells: [
        DataCell(Text(_fmtTime(t.exitTimestamp),
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12))),
        DataCell(Text(t.direction,
            style: TextStyle(
                color: sideColor, fontSize: 12, fontWeight: FontWeight.w600))),
        DataCell(Text(_fmtPrice(t.entryPrice),
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
        DataCell(Text(_fmtPrice(t.exitPrice),
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
        DataCell(Text(t.quantity.toStringAsFixed(6),
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
        DataCell(Text(_fmtSignedMoney(t.pnl),
            style: TextStyle(color: pnlColor, fontSize: 12))),
        DataCell(Text(t.exitReason,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12))),
      ],
    );
  }
}

// ─── Mini equity sparkline ────────────────────────────────────────────────

class _EquitySparkline extends StatelessWidget {
  final List<EquityPoint> points;
  final double initialBalance;

  const _EquitySparkline({required this.points, required this.initialBalance});

  @override
  Widget build(BuildContext context) {
    final last = points.last.equity;
    final lineColor =
        last >= initialBalance ? AppColors.bullGreen : AppColors.bearRed;
    final spots = <FlSpot>[];
    for (var i = 0; i < points.length; i++) {
      spots.add(FlSpot(i.toDouble(), points[i].equity));
    }

    return Card(
      key: const Key('paper-equity-sparkline-card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.show_chart, color: AppColors.accentCyan, size: 16),
                SizedBox(width: 6),
                Text(
                  'Equity (session-window replay)',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 120,
              child: LineChart(
                LineChartData(
                  gridData: const FlGridData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: false,
                      color: lineColor,
                      barWidth: 1.5,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: lineColor.withAlpha(40),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────

class _EmptyStateCard extends StatelessWidget {
  final PaperTradingProvider provider;
  const _EmptyStateCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.play_circle_outline,
                size: 48, color: AppColors.textMuted),
            const SizedBox(height: 8),
            const Text(
              'No active session',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Sync the active backtest config and hit Start to begin '
              'observing live signals.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () => provider.start(),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start with current pending config'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Stat tile ────────────────────────────────────────────────────────────

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _StatTile({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                color: valueColor ?? AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Format helpers ───────────────────────────────────────────────────────

final _moneyFmt = NumberFormat.currency(locale: 'en_US', symbol: '\$', decimalDigits: 2);

String _fmtMoney(double v) => _moneyFmt.format(v);

String _fmtSignedMoney(double v) {
  final s = _moneyFmt.format(v.abs());
  return v >= 0 ? '+$s' : '-$s';
}

String _fmtPrice(double v) {
  if (v.abs() >= 1000) return v.toStringAsFixed(2);
  if (v.abs() >= 1) return v.toStringAsFixed(4);
  return v.toStringAsFixed(6);
}

String _fmtTime(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
  return DateFormat('HH:mm:ss').format(dt);
}
