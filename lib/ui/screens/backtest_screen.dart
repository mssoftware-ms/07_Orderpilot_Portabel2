/// Full-featured Backtest UI Screen.
///
/// Layout:
///   - Configuration panel (collapsible on mobile)
///   - Run button with loading indicator
///   - Results: equity curve chart, metrics grid, trade log
///   - CSV export buttons
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_constants.dart';
import '../../features/backtest/backtest_provider.dart';
import '../../services/backtest_service.dart';
import '../themes/app_theme.dart';
import '../widgets/equity_curve_chart.dart';
import '../widgets/metric_card.dart';
import '../widgets/trade_log_list.dart';

class BacktestScreen extends StatelessWidget {
  const BacktestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<BacktestProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Backtest'),
            actions: [
              if (provider.hasResult) ...[
                IconButton(
                  icon: const Icon(Icons.file_download_outlined),
                  tooltip: 'Export CSV',
                  onPressed: () => _showExportDialog(context, provider),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Reset',
                  onPressed: provider.reset,
                ),
              ],
            ],
          ),
          body: _BacktestBody(provider: provider),
        );
      },
    );
  }

  void _showExportDialog(BuildContext context, BacktestProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Export Data',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.list_alt, color: AppColors.accentCyan),
              title: const Text('Trade Log CSV'),
              subtitle: Text('${provider.result?.trades.length ?? 0} trades'),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  final path = await provider.exportTradesCsv();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Saved: $path')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Export error: $e')),
                    );
                  }
                }
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.show_chart, color: AppColors.accentCyan),
              title: const Text('Equity Curve CSV'),
              subtitle: Text(
                  '${provider.result?.equityCurve.length ?? 0} data points'),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  final path = await provider.exportEquityCsv();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Saved: $path')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Export error: $e')),
                    );
                  }
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ─── Body ───────────────────────────────────────────────────────────────────

class _BacktestBody extends StatelessWidget {
  final BacktestProvider provider;

  const _BacktestBody({required this.provider});

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;

    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 340,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _ConfigPanel(provider: provider),
            ),
          ),
          const VerticalDivider(width: 1, color: AppColors.divider),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _ResultsPanel(provider: provider),
            ),
          ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConfigPanel(provider: provider),
          const SizedBox(height: 16),
          _ResultsPanel(provider: provider),
        ],
      ),
    );
  }
}

// ─── Configuration Panel ────────────────────────────────────────────────────

class _ConfigPanel extends StatefulWidget {
  final BacktestProvider provider;
  const _ConfigPanel({required this.provider});

  @override
  State<_ConfigPanel> createState() => _ConfigPanelState();
}

class _ConfigPanelState extends State<_ConfigPanel> {
  late TextEditingController _balanceCtrl;
  late TextEditingController _feeCtrl;
  bool _showAdvanced = false;

  BacktestProvider get _p => widget.provider;

  @override
  void initState() {
    super.initState();
    _balanceCtrl = TextEditingController(
        text: _p.config.initialBalance.toStringAsFixed(0));
    _feeCtrl = TextEditingController(
        text: (_p.config.feeRate * 100).toStringAsFixed(2));
  }

  @override
  void dispose() {
    _balanceCtrl.dispose();
    _feeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _p.config;
    final params = cfg.strategyParams;

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
          // Header
          Row(
            children: [
              const Icon(Icons.tune, color: AppColors.accentCyan, size: 20),
              const SizedBox(width: 8),
              const Text('Configuration',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const SizedBox(height: 16),

          // Strategy (fixed for now)
          _SectionLabel('Strategy'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_graph, color: AppColors.accentPurple, size: 16),
                const SizedBox(width: 8),
                const Text('BB+RSI Mean Reversion',
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Symbol
          _SectionLabel('Symbol'),
          _buildDropdown<String>(
            value: cfg.symbol,
            items: AppConstants.supportedSymbols,
            onChanged: _p.isRunning ? null : (v) => _p.updateSymbol(v!),
          ),
          const SizedBox(height: 14),

          // Timeframe chips
          _SectionLabel('Timeframe'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: AppConstants.supportedTimeframes.map((tf) {
              final selected = cfg.timeframe == tf;
              return ChoiceChip(
                label: Text(tf),
                selected: selected,
                onSelected: _p.isRunning ? null : (s) {
                  if (s) _p.updateTimeframe(tf);
                },
                selectedColor: AppColors.accentCyan.withAlpha(40),
                labelStyle: TextStyle(
                  color: selected ? AppColors.accentCyan : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
                side: BorderSide(
                  color: selected ? AppColors.accentCyan : AppColors.border,
                ),
                backgroundColor: AppColors.surfaceElevated,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),

          // Date Range
          _SectionLabel('Date Range'),
          _DateRangeSelector(
            start: cfg.startDate,
            end: cfg.endDate,
            enabled: !_p.isRunning,
            onChanged: _p.updateDateRange,
          ),
          const SizedBox(height: 14),

          // Balance & Fees
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionLabel('Balance (\$)'),
                    _buildTextField(_balanceCtrl, onSubmit: (v) {
                      final val = double.tryParse(v);
                      if (val != null && val > 0) _p.updateBalance(val);
                    }),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionLabel('Fee (%)'),
                    _buildTextField(_feeCtrl, onSubmit: (v) {
                      final val = double.tryParse(v);
                      if (val != null && val >= 0) _p.updateFeeRate(val / 100);
                    }),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Advanced params toggle
          InkWell(
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Row(
              children: [
                Icon(
                  _showAdvanced
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: AppColors.accentCyan,
                  size: 18,
                ),
                const SizedBox(width: 4),
                const Text('Strategy Parameters',
                    style: TextStyle(
                        color: AppColors.accentCyan,
                        fontSize: 12,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),

          if (_showAdvanced) ...[
            const SizedBox(height: 12),
            _ParamSlider(
              label: 'BB Period',
              value: params.bbPeriod.toDouble(),
              min: 10,
              max: 50,
              divisions: 40,
              format: (v) => v.toInt().toString(),
              onChanged: _p.isRunning ? null : (v) {
                _p.updateStrategyParams(BbRsiParams(
                  bbPeriod: v.toInt(),
                  bbStdDev: params.bbStdDev,
                  rsiPeriod: params.rsiPeriod,
                  rsiOversold: params.rsiOversold,
                  rsiOverbought: params.rsiOverbought,
                ));
              },
            ),
            _ParamSlider(
              label: 'BB Std Dev',
              value: params.bbStdDev,
              min: 1.0,
              max: 3.0,
              divisions: 20,
              format: (v) => v.toStringAsFixed(1),
              onChanged: _p.isRunning ? null : (v) {
                _p.updateStrategyParams(BbRsiParams(
                  bbPeriod: params.bbPeriod,
                  bbStdDev: v,
                  rsiPeriod: params.rsiPeriod,
                  rsiOversold: params.rsiOversold,
                  rsiOverbought: params.rsiOverbought,
                ));
              },
            ),
            _ParamSlider(
              label: 'RSI Period',
              value: params.rsiPeriod.toDouble(),
              min: 7,
              max: 30,
              divisions: 23,
              format: (v) => v.toInt().toString(),
              onChanged: _p.isRunning ? null : (v) {
                _p.updateStrategyParams(BbRsiParams(
                  bbPeriod: params.bbPeriod,
                  bbStdDev: params.bbStdDev,
                  rsiPeriod: v.toInt(),
                  rsiOversold: params.rsiOversold,
                  rsiOverbought: params.rsiOverbought,
                ));
              },
            ),
            _ParamSlider(
              label: 'RSI Oversold',
              value: params.rsiOversold,
              min: 20,
              max: 40,
              divisions: 20,
              format: (v) => v.toInt().toString(),
              onChanged: _p.isRunning ? null : (v) {
                _p.updateStrategyParams(BbRsiParams(
                  bbPeriod: params.bbPeriod,
                  bbStdDev: params.bbStdDev,
                  rsiPeriod: params.rsiPeriod,
                  rsiOversold: v,
                  rsiOverbought: params.rsiOverbought,
                ));
              },
            ),
            _ParamSlider(
              label: 'RSI Overbought',
              value: params.rsiOverbought,
              min: 60,
              max: 80,
              divisions: 20,
              format: (v) => v.toInt().toString(),
              onChanged: _p.isRunning ? null : (v) {
                _p.updateStrategyParams(BbRsiParams(
                  bbPeriod: params.bbPeriod,
                  bbStdDev: params.bbStdDev,
                  rsiPeriod: params.rsiPeriod,
                  rsiOversold: params.rsiOversold,
                  rsiOverbought: v,
                ));
              },
            ),
          ],

          const SizedBox(height: 20),

          // Run button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _p.isRunning ? null : _p.runBacktest,
              icon: _p.isRunning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black))
                  : const Icon(Icons.play_arrow),
              label: Text(_p.isRunning ? _p.statusMessage : 'Run Backtest'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentCyan,
                foregroundColor: Colors.black,
                disabledBackgroundColor: AppColors.accentCyan.withAlpha(80),
                disabledForegroundColor: Colors.black54,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),

          // Status message
          if (_p.statusMessage.isNotEmpty && !_p.isRunning) ...[
            const SizedBox(height: 8),
            Text(
              _p.statusMessage,
              style: TextStyle(
                color: _p.state == BacktestState.error
                    ? AppColors.bearRed
                    : AppColors.textMuted,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDropdown<T>({
    required T value,
    required List<T> items,
    required ValueChanged<T?>? onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: AppColors.surfaceElevated,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
          items: items
              .map((i) => DropdownMenuItem(value: i, child: Text('$i')))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl,
      {required ValueChanged<String> onSubmit}) {
    return TextField(
      controller: ctrl,
      enabled: !_p.isRunning,
      keyboardType: TextInputType.number,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        filled: true,
        fillColor: AppColors.surfaceElevated,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.accentCyan),
        ),
      ),
      onSubmitted: onSubmit,
      onEditingComplete: () => onSubmit(ctrl.text),
    );
  }
}

// ─── Section Label ──────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ─── Param Slider ───────────────────────────────────────────────────────────

class _ParamSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double>? onChanged;

  const _ParamSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 11)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: AppColors.accentCyan,
                inactiveTrackColor: AppColors.border,
                thumbColor: AppColors.accentCyan,
                overlayColor: AppColors.accentCyan.withAlpha(30),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              format(value),
              style: const TextStyle(
                  color: AppColors.accentCyan,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Date Range Selector ────────────────────────────────────────────────────

class _DateRangeSelector extends StatelessWidget {
  final DateTime start;
  final DateTime end;
  final bool enabled;
  final void Function(DateTime, DateTime) onChanged;

  const _DateRangeSelector({
    required this.start,
    required this.end,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM dd, yyyy');

    return Row(
      children: [
        Expanded(
          child: _DateButton(
            label: fmt.format(start),
            enabled: enabled,
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: start,
                firstDate: DateTime(2017),
                lastDate: end,
                builder: (ctx, child) => Theme(
                  data: Theme.of(ctx).copyWith(
                    colorScheme: const ColorScheme.dark(
                      primary: AppColors.accentCyan,
                      surface: AppColors.surfaceCard,
                    ),
                  ),
                  child: child!,
                ),
              );
              if (picked != null) onChanged(picked, end);
            },
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Icon(Icons.arrow_forward, size: 14, color: AppColors.textMuted),
        ),
        Expanded(
          child: _DateButton(
            label: fmt.format(end),
            enabled: enabled,
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: end,
                firstDate: start,
                lastDate: DateTime.now(),
                builder: (ctx, child) => Theme(
                  data: Theme.of(ctx).copyWith(
                    colorScheme: const ColorScheme.dark(
                      primary: AppColors.accentCyan,
                      surface: AppColors.surfaceCard,
                    ),
                  ),
                  child: child!,
                ),
              );
              if (picked != null) onChanged(start, picked);
            },
          ),
        ),
      ],
    );
  }
}

class _DateButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _DateButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today,
                size: 13, color: AppColors.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Results Panel ──────────────────────────────────────────────────────────

class _ResultsPanel extends StatelessWidget {
  final BacktestProvider provider;

  const _ResultsPanel({required this.provider});

  @override
  Widget build(BuildContext context) {
    switch (provider.state) {
      case BacktestState.idle:
        return _IdlePlaceholder();
      case BacktestState.fetchingData:
      case BacktestState.running:
        return _LoadingView(provider: provider);
      case BacktestState.error:
        return _ErrorView(message: provider.errorMessage ?? 'Unknown error');
      case BacktestState.success:
        if (provider.result == null) return _IdlePlaceholder();
        return _SuccessView(
          result: provider.result!,
          config: provider.config,
        );
    }
  }
}

class _IdlePlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.science_outlined,
              size: 64, color: AppColors.textMuted.withAlpha(60)),
          const SizedBox(height: 16),
          const Text('Configure and run a backtest',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 16,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          const Text(
            'Select parameters, date range, and click\n"Run Backtest" to see results',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  final BacktestProvider provider;
  const _LoadingView({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              color: AppColors.accentCyan,
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            provider.state == BacktestState.fetchingData
                ? 'Fetching candle data...'
                : 'Running backtest...',
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Text(
            provider.statusMessage,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          if (provider.candlesFetched > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${provider.candlesFetched} candles loaded',
              style: const TextStyle(
                  color: AppColors.accentCyan, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  const _ErrorView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: AppColors.bearRed),
          const SizedBox(height: 16),
          const Text('Backtest Failed',
              style: TextStyle(
                  color: AppColors.bearRed,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  final BacktestResult result;
  final BacktestConfig config;

  const _SuccessView({required this.result, required this.config});

  @override
  Widget build(BuildContext context) {
    final m = result.metrics;
    final pnlColor = m.totalPnl >= 0 ? AppColors.bullGreen : AppColors.bearRed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Metrics grid
        LayoutBuilder(
          builder: (context, constraints) {
            final cols = constraints.maxWidth > 600 ? 4 : 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _metricSized(cols, constraints,
                  MetricCard(
                    label: 'TOTAL PNL',
                    value: '${m.totalPnl >= 0 ? '+' : ''}\$${m.totalPnl.toStringAsFixed(2)}',
                    icon: Icons.attach_money,
                    valueColor: pnlColor,
                    subtitle: '${m.totalPnlPercent >= 0 ? '+' : ''}${m.totalPnlPercent.toStringAsFixed(2)}%',
                  ),
                ),
                _metricSized(cols, constraints,
                  MetricCard(
                    label: 'WIN RATE',
                    value: '${m.winRate.toStringAsFixed(1)}%',
                    icon: Icons.pie_chart_outline,
                    valueColor: m.winRate >= 50 ? AppColors.bullGreen : AppColors.warningAmber,
                    subtitle: '${m.winningTrades}W / ${m.losingTrades}L',
                  ),
                ),
                _metricSized(cols, constraints,
                  MetricCard(
                    label: 'PROFIT FACTOR',
                    value: m.profitFactor.toStringAsFixed(2),
                    icon: Icons.balance,
                    valueColor: m.profitFactor >= 1.5
                        ? AppColors.bullGreen
                        : m.profitFactor >= 1.0
                            ? AppColors.warningAmber
                            : AppColors.bearRed,
                  ),
                ),
                _metricSized(cols, constraints,
                  MetricCard(
                    label: 'MAX DRAWDOWN',
                    value: '${m.maxDrawdownPercent.toStringAsFixed(2)}%',
                    icon: Icons.trending_down,
                    valueColor: AppColors.bearRed,
                    subtitle: '\$${m.maxDrawdown.toStringAsFixed(2)}',
                  ),
                ),
                _metricSized(cols, constraints,
                  MetricCard(
                    label: 'SHARPE RATIO',
                    value: m.sharpeRatio.toStringAsFixed(2),
                    icon: Icons.insights,
                    valueColor: m.sharpeRatio >= 1.0
                        ? AppColors.bullGreen
                        : AppColors.textSecondary,
                  ),
                ),
                _metricSized(cols, constraints,
                  MetricCard(
                    label: 'TOTAL TRADES',
                    value: '${m.totalTrades}',
                    icon: Icons.swap_vert,
                  ),
                ),
                _metricSized(cols, constraints,
                  MetricCard(
                    label: 'TOTAL FEES',
                    value: '\$${m.totalFees.toStringAsFixed(2)}',
                    icon: Icons.receipt_long,
                    valueColor: AppColors.warningAmber,
                  ),
                ),
                _metricSized(cols, constraints,
                  MetricCard(
                    label: 'CANDLES',
                    value: '${m.candlesProcessed}',
                    icon: Icons.candlestick_chart,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),

        // Equity curve
        EquityCurveChart(
          equityCurve: result.equityCurve,
          initialBalance: config.initialBalance,
        ),
        const SizedBox(height: 20),

        // Trade log
        TradeLogList(trades: result.trades),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _metricSized(int cols, BoxConstraints constraints, Widget child) {
    final width = (constraints.maxWidth - (cols - 1) * 10) / cols;
    return SizedBox(width: width, child: child);
  }
}
