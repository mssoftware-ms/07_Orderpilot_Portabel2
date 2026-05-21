import 'package:flutter/material.dart';
import '../../ui/themes/app_theme.dart';
import '../../core/constants/app_constants.dart';

class ChartScreen extends StatefulWidget {
  const ChartScreen({super.key});

  @override
  State<ChartScreen> createState() => _ChartScreenState();
}

class _ChartScreenState extends State<ChartScreen> {
  String _selectedSymbol = AppConstants.supportedSymbols[0];
  String _selectedTimeframe = '1h';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Symbol & timeframe selector
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: AppColors.surfaceDark,
              child: Row(
                children: [
                  // Symbol dropdown
                  DropdownButton<String>(
                    value: _selectedSymbol,
                    dropdownColor: AppColors.surfaceElevated,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                    underline: const SizedBox(),
                    items: AppConstants.supportedSymbols.map((s) {
                      return DropdownMenuItem(value: s, child: Text(s));
                    }).toList(),
                    onChanged: (v) => setState(() => _selectedSymbol = v!),
                  ),
                  const SizedBox(width: 16),
                  // Timeframe chips
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: AppConstants.supportedTimeframes.map((tf) {
                          final isSelected = tf == _selectedTimeframe;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(tf),
                              selected: isSelected,
                              selectedColor: AppColors.accentCyan.withAlpha(50),
                              labelStyle: TextStyle(
                                color: isSelected ? AppColors.accentCyan : AppColors.textMuted,
                                fontSize: 12,
                              ),
                              side: BorderSide(
                                color: isSelected ? AppColors.accentCyan : AppColors.border,
                              ),
                              onSelected: (_) => setState(() => _selectedTimeframe = tf),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Chart placeholder
            Expanded(
              flex: 3,
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border, width: 0.5),
                ),
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.candlestick_chart, size: 64, color: AppColors.accentCyan),
                      SizedBox(height: 12),
                      Text(
                        'Candlestick Chart',
                        style: TextStyle(color: AppColors.textPrimary, fontSize: 18),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Chart will render here with Bollinger Bands & RSI overlays',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // RSI sub-chart placeholder
            Expanded(
              flex: 1,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border, width: 0.5),
                ),
                child: const Center(
                  child: Text(
                    'RSI Indicator (0–100)',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
