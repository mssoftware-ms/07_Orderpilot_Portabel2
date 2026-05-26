import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/logging/app_log.dart';
import '../themes/app_theme.dart';

enum _Filter { all, errors, warnings }

class LogPanel extends StatefulWidget {
  const LogPanel({super.key, this.height = 240});

  final double height;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppLogStore>();
    final entries = _apply(_filter, store.entries);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, store),
            const SizedBox(height: 4),
            const Divider(height: 1, color: AppColors.divider),
            SizedBox(
              height: widget.height,
              child: entries.isEmpty
                  ? const _EmptyState()
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (ctx, i) => _LogTile(entry: entries[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AppLogStore store) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.list_alt_outlined,
                size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Text('System Log',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            _CountChip(
                label: 'E', count: store.errorCount, color: AppColors.bearRed),
            const SizedBox(width: 4),
            _CountChip(
                label: 'W',
                count: store.warningCount,
                color: AppColors.warningAmber),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<_Filter>(
              style: const ButtonStyle(
                visualDensity:
                    VisualDensity(horizontal: -3, vertical: -3),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(value: _Filter.all, label: Text('All')),
                ButtonSegment(value: _Filter.errors, label: Text('Err')),
                ButtonSegment(value: _Filter.warnings, label: Text('Warn')),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
            IconButton(
              tooltip: 'Clear log',
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
              onPressed: store.count == 0 ? null : store.clear,
            ),
          ],
        ),
      ],
    );
  }

  List<LogEntry> _apply(_Filter f, List<LogEntry> all) {
    switch (f) {
      case _Filter.all:
        return all;
      case _Filter.errors:
        return all.where((e) => e.level == LogLevel.error).toList();
      case _Filter.warnings:
        return all.where((e) => e.level == LogLevel.warning).toList();
    }
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip(
      {required this.label, required this.count, required this.color});

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No errors or warnings logged.',
        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final LogEntry entry;

  static String _fmtTime(DateTime ts) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final isError = entry.level == LogLevel.error;
    final color = isError ? AppColors.bearRed : AppColors.warningAmber;
    final levelLabel = isError ? 'ERROR' : 'WARN ';

    return InkWell(
      onTap: () => _showDetail(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _fmtTime(entry.timestamp),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              levelLabel,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                entry.tag,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: AppColors.accentCyan,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.message,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: AppColors.textPrimary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final isError = entry.level == LogLevel.error;
        final color = isError ? AppColors.bearRed : AppColors.warningAmber;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          builder: (ctx, scrollCtrl) => Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              controller: scrollCtrl,
              children: [
                Row(
                  children: [
                    Text(isError ? 'ERROR' : 'WARNING',
                        style: TextStyle(
                            color: color,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(width: 12),
                    Text('[${entry.tag}]',
                        style: const TextStyle(
                            color: AppColors.accentCyan, fontSize: 13)),
                    const Spacer(),
                    Text(entry.timestamp.toIso8601String(),
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 12),
                SelectableText(
                  entry.message,
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 13),
                ),
                if (entry.error != null) ...[
                  const SizedBox(height: 16),
                  const Text('Error object:',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                  const SizedBox(height: 4),
                  SelectableText(
                    entry.error.toString(),
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontFamily: 'monospace'),
                  ),
                ],
                if (entry.stackTrace != null) ...[
                  const SizedBox(height: 16),
                  const Text('Stack trace:',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                  const SizedBox(height: 4),
                  SelectableText(
                    entry.stackTrace.toString(),
                    style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
