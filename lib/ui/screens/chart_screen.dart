import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../features/chart/chart_provider.dart';
import '../themes/app_theme.dart';
import '../widgets/candlestick_chart_pane.dart';
import '../widgets/rsi_indicator_pane.dart';

/// Welle P4C-3 chart tab.
///
/// Real-time Bollinger Bands + RSI visualisation backed by
/// [ChartProvider]. The RSI sub-chart stays a placeholder for one
/// more commit (P4C-4); everything else is live: candle render,
/// BB overlay, symbol/timeframe controls wired to the provider,
/// connection-status pill.
class ChartScreen extends StatefulWidget {
  const ChartScreen({super.key});

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Trigger the initial REST backfill + WS attach exactly once per
    // mount. Provider.read is safe here because the load() call is
    // fire-and-forget and the UI watches the provider for updates.
    if (!_loaded) {
      _loaded = true;
      // ignore: discarded_futures
      context.read<ChartProvider>().load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChartProvider>();
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _ChartToolbar(provider: provider),
            // Candlestick + BB pane.
            Expanded(
              flex: 3,
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border, width: 0.5),
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: CandlestickChartPane(
                    candles: provider.candles,
                    bb: provider.bb,
                  ),
                ),
              ),
            ),
            // RSI sub-chart.
            Expanded(
              flex: 1,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border, width: 0.5),
                ),
                clipBehavior: Clip.antiAlias,
                child: RsiIndicatorPane(values: provider.rsi),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _ChartToolbar extends StatelessWidget {
  final ChartProvider provider;
  const _ChartToolbar({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.surfaceDark,
      child: Row(
        children: [
          // Symbol dropdown wired to the provider.
          DropdownButton<String>(
            value: provider.symbol,
            dropdownColor: AppColors.surfaceElevated,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            underline: const SizedBox(),
            items: AppConstants.supportedSymbols
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              // ignore: discarded_futures
              provider.setSymbol(value);
            },
          ),
          const SizedBox(width: 12),
          // Timeframe chips wired to the provider.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: AppConstants.supportedTimeframes.map((tf) {
                  final selected = tf == provider.timeframe;
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(tf),
                      selected: selected,
                      selectedColor: AppColors.accentCyan.withAlpha(50),
                      labelStyle: TextStyle(
                        color: selected
                            ? AppColors.accentCyan
                            : AppColors.textMuted,
                        fontSize: 12,
                      ),
                      side: BorderSide(
                        color: selected
                            ? AppColors.accentCyan
                            : AppColors.border,
                      ),
                      onSelected: (_) {
                        // ignore: discarded_futures
                        provider.setTimeframe(tf);
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _ConnectionPill(status: provider.status),
          IconButton(
            tooltip: 'Indicator settings',
            icon: const Icon(Icons.tune, size: 18, color: AppColors.textMuted),
            onPressed: () => _openSettingsSheet(context, provider),
          ),
        ],
      ),
    );
  }

  static void _openSettingsSheet(BuildContext context, ChartProvider provider) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceCard,
      isScrollControlled: true,
      builder: (sheetCtx) => _IndicatorSettingsSheet(provider: provider),
    );
  }
}

/// Settings sheet for the indicator parameters. Sliders feed directly
/// into [ChartProvider.setIndicatorParams] — no WS restart, no REST
/// refetch, just a local recompute of BB + RSI.
class _IndicatorSettingsSheet extends StatefulWidget {
  final ChartProvider provider;
  const _IndicatorSettingsSheet({required this.provider});

  @override
  State<_IndicatorSettingsSheet> createState() =>
      _IndicatorSettingsSheetState();
}

class _IndicatorSettingsSheetState extends State<_IndicatorSettingsSheet> {
  late int _bbPeriod;
  late double _bbStdDev;
  late int _rsiPeriod;

  @override
  void initState() {
    super.initState();
    _bbPeriod = widget.provider.bbPeriod;
    _bbStdDev = widget.provider.bbStdDev;
    _rsiPeriod = widget.provider.rsiPeriod;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Indicator settings',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            _SliderRow(
              label: 'BB period',
              value: _bbPeriod.toDouble(),
              min: 5,
              max: 200,
              divisions: 195,
              displayValue: _bbPeriod.toString(),
              onChanged: (v) {
                setState(() => _bbPeriod = v.round());
                widget.provider.setIndicatorParams(bbPeriod: _bbPeriod);
              },
            ),
            _SliderRow(
              label: 'BB stddev',
              value: _bbStdDev,
              min: 1.0,
              max: 3.5,
              divisions: 25,
              displayValue: _bbStdDev.toStringAsFixed(1),
              onChanged: (v) {
                setState(() => _bbStdDev = double.parse(v.toStringAsFixed(1)));
                widget.provider.setIndicatorParams(bbStdDev: _bbStdDev);
              },
            ),
            _SliderRow(
              label: 'RSI period',
              value: _rsiPeriod.toDouble(),
              min: 2,
              max: 50,
              divisions: 48,
              displayValue: _rsiPeriod.toString(),
              onChanged: (v) {
                setState(() => _rsiPeriod = v.round());
                widget.provider.setIndicatorParams(rsiPeriod: _rsiPeriod);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: displayValue,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            displayValue,
            textAlign: TextAlign.right,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// Tiny status indicator that mirrors the [ChartStatus] from the
/// provider — `live`, `reconnecting`, `loading`, `error`, `idle`.
/// The shape stays stable across states so the layout doesn't shift
/// during reconnects.
class _ConnectionPill extends StatelessWidget {
  final ChartStatus status;
  const _ConnectionPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ChartStatus.idle => ('idle', AppColors.textMuted),
      ChartStatus.loading => ('loading', AppColors.warningAmber),
      ChartStatus.live => ('live', AppColors.bullGreen),
      ChartStatus.reconnecting => ('reconnecting', AppColors.warningAmber),
      ChartStatus.error => ('error', AppColors.bearRed),
    };
    return Container(
      key: const ValueKey('chart-status-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color, width: 0.6),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11),
      ),
    );
  }
}
