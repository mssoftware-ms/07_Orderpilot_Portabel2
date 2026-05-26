/// Shared section-label + parameter-slider widgets used by every strategy
/// parameter section on the Backtest screen.
///
/// Welle O3-B1 extracted these from the inline private classes in
/// [BacktestScreen] so the per-strategy widgets ([BbRsiParamSection],
/// [UtBotParamSection], [IchimokuParamSection]) can share a single
/// implementation without duplication.
library;

import 'package:flutter/material.dart';

import '../themes/app_theme.dart';

/// Section header: small all-caps-ish label for a config block.
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

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

/// Labelled slider used by every strategy parameter section.
///
/// `onChanged: null` renders the slider in disabled state (matches the
/// "busy / running" state of [BacktestProvider]).
class ParamSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double>? onChanged;

  const ParamSlider({
    super.key,
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
            width: 50,
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
