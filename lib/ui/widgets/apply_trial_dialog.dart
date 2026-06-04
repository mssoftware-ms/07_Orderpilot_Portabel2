/// Welle O3-B3-3 — Apply-Trial dialog opened from a StrategyCard.
///
/// Flow:
///   1. User taps "Apply Trial" on a [StrategyCard] for a [StrategyKind].
///   2. Dialog opens with its OWN [StudiesProvider] instance (no cross-talk
///      with the Studies tab's global provider — applying a trial here must
///      not perturb the user's open study viewer).
///   3. User picks a `.db` (file_picker suggests `studies-{kind}*` files
///      first via the dialog title; the OS dialog itself is unfiltered).
///   4. Top-10 trials render in a reused [TrialsTop10Table] (read-only).
///   5. User picks a trial via dropdown + taps "Apply Selected Trial" →
///      [BacktestProvider.applyTrialAsParams] fires, dialog closes.
///
/// Strategy mismatches between the loaded study and [targetKind] are
/// allowed but surfaced with a warning banner (Welle-O3-B3 escalation
/// rule: fromMap must fill missing keys via defaults, not throw — so
/// mismatched applies stay well-defined).
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/trial.dart';
import '../../features/backtest/backtest_provider.dart';
import '../../features/studies/studies_provider.dart';
import '../themes/app_theme.dart';
import 'trials_top10_table.dart';

/// Best-effort initial directory for the apply-trial dialog's file picker.
/// Mirrors [StudiesScreen]'s `_suggestStudiesDir` — kept local to avoid
/// pulling the screen-level helper into the widget public surface.
String? _suggestStudiesDir() {
  final candidate = Directory('01_Projectplan/optimizer_studies');
  return candidate.existsSync() ? candidate.absolute.path : null;
}

/// Snake-case string the optimizer stores in `studies.strategy` for [kind].
String strategySnakeCase(StrategyKind kind) => switch (kind) {
      StrategyKind.bbRsi => 'bb_rsi',
      StrategyKind.utBot => 'ut_bot',
      StrategyKind.ichimoku => 'ichimoku',
    };

/// Convenience function used by [StrategyCard.onApplyTrialRequested].
Future<void> showApplyTrialDialog(
  BuildContext context, {
  required StrategyKind targetKind,
  required BacktestProvider backtestProvider,
  StudiesProvider? studiesProvider,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => ApplyTrialDialog(
      targetKind: targetKind,
      backtestProvider: backtestProvider,
      studiesProvider: studiesProvider,
    ),
  );
}

class ApplyTrialDialog extends StatefulWidget {
  final StrategyKind targetKind;
  final BacktestProvider backtestProvider;

  /// Optional override — when null, the dialog creates its own private
  /// [StudiesProvider]. Tests inject a pre-loaded one to skip file_picker.
  final StudiesProvider? studiesProvider;

  const ApplyTrialDialog({
    super.key,
    required this.targetKind,
    required this.backtestProvider,
    this.studiesProvider,
  });

  @override
  State<ApplyTrialDialog> createState() => _ApplyTrialDialogState();
}

class _ApplyTrialDialogState extends State<ApplyTrialDialog> {
  late final StudiesProvider _studies;
  late final bool _ownsStudies;
  Trial? _selectedTrial;

  @override
  void initState() {
    super.initState();
    if (widget.studiesProvider != null) {
      _studies = widget.studiesProvider!;
      _ownsStudies = false;
    } else {
      _studies = StudiesProvider();
      _ownsStudies = true;
    }
    _studies.addListener(_onStudiesChanged);
    // Pre-select the best trial if the injected provider already has data.
    _selectBestFinite();
  }

  void _selectBestFinite() {
    final top = _studies.top10.where((t) => t.scoreIsFinite).toList();
    _selectedTrial = top.isNotEmpty ? top.first : null;
  }

  @override
  void dispose() {
    _studies.removeListener(_onStudiesChanged);
    if (_ownsStudies) _studies.dispose();
    super.dispose();
  }

  void _onStudiesChanged() {
    if (!mounted) return;
    setState(_selectBestFinite);
  }

  Future<void> _pickDb() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['db', 'sqlite', 'sqlite3'],
        dialogTitle:
            'Pick an Optuna .db (suggest studies-${strategySnakeCase(widget.targetKind)}*.db)',
        initialDirectory: _suggestStudiesDir(),
      );
      final path = result?.files.single.path;
      if (path == null) return;
      await _studies.loadDb(path);
    } catch (e, st) {
      AppLog.error('ApplyTrialDialog',
          'File picker failed: $e', e, st);
    }
  }

  bool get _strategyMismatch {
    final s = _studies.selectedStudy;
    if (s == null) return false;
    return s.strategy != strategySnakeCase(widget.targetKind);
  }

  void _apply() {
    final t = _selectedTrial;
    if (t == null) return;
    widget.backtestProvider.applyTrialAsParams(
      kind: widget.targetKind,
      trialParams: t.params,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final dialogWidth = (size.width * 0.85).clamp(600.0, 1200.0);
    final dialogHeight = (size.height * 0.8).clamp(500.0, 900.0);

    return Dialog(
      backgroundColor: AppColors.surfaceCard,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(context),
              const SizedBox(height: 12),
              _pickerRow(),
              const SizedBox(height: 12),
              if (_studies.errorMessage != null)
                _banner(_studies.errorMessage!,
                    color: AppColors.bearRed,
                    icon: Icons.error_outline),
              if (_strategyMismatch) ...[
                _banner(
                  'This study targets "${_studies.selectedStudy!.strategy}" '
                  'but you are applying it to ${widget.targetKind.displayLabel}. '
                  'Unmatched keys will fall back to defaults.',
                  color: AppColors.warningAmber,
                  icon: Icons.warning_amber_rounded,
                ),
                const SizedBox(height: 12),
              ],
              Expanded(child: _body()),
              const SizedBox(height: 12),
              _footer(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) => Row(
        children: [
          const Icon(Icons.auto_awesome,
              size: 18, color: AppColors.accentCyan),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Apply Trial — ${widget.targetKind.displayLabel}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            key: const Key('apply_trial_dialog_close'),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            tooltip: 'Close',
          ),
        ],
      );

  Widget _pickerRow() {
    final loaded = _studies.dbPath;
    return Row(
      children: [
        ElevatedButton.icon(
          key: const Key('apply_trial_dialog_pick_db'),
          onPressed: _studies.isLoading ? null : _pickDb,
          icon: const Icon(Icons.file_open, size: 16),
          label: Text(loaded == null ? 'Pick .db' : 'Change .db'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            loaded ?? 'No studies database loaded yet.',
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _body() {
    if (_studies.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_studies.hasData) {
      return const Center(
        child: Text(
          'Load an optimizer studies .db to see its trials.',
          style:
              TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      );
    }
    final finite = _studies.top10.where((t) => t.scoreIsFinite).toList();
    if (finite.isEmpty) {
      return const Center(
        child: Text(
          'The selected study has no scored trials yet.',
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _studyMetaRow(),
        const SizedBox(height: 8),
        _trialDropdown(finite),
        const SizedBox(height: 8),
        Expanded(child: TrialsTop10Table(trials: _studies.top10)),
      ],
    );
  }

  Widget _studyMetaRow() {
    final s = _studies.selectedStudy;
    if (s == null) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        _metaChip('Study', s.name),
        _metaChip('Strategy', s.strategy),
        _metaChip('Trials', '${_studies.trials.length}'),
      ],
    );
  }

  Widget _trialDropdown(List<Trial> trials) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            key: const Key('apply_trial_dialog_trial_dropdown'),
            value: _selectedTrial?.id,
            isExpanded: true,
            dropdownColor: AppColors.surfaceElevated,
            style: const TextStyle(
                color: AppColors.textPrimary, fontSize: 13),
            items: trials
                .map((t) => DropdownMenuItem<int>(
                      value: t.id,
                      child: Text(
                        '#${t.trialId}  score=${t.score.toStringAsFixed(4)}  '
                        'trades=${t.metrics.totalTrades}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))
                .toList(),
            onChanged: (id) {
              if (id == null) return;
              setState(() {
                _selectedTrial =
                    trials.firstWhere((t) => t.id == id);
              });
            },
          ),
        ),
      );

  Widget _footer(BuildContext context) {
    return Row(
      children: [
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 12),
        ElevatedButton.icon(
          key: const Key('apply_trial_dialog_apply'),
          onPressed: _selectedTrial == null ? null : _apply,
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Apply Selected Trial'),
        ),
      ],
    );
  }

  Widget _banner(String text,
      {required Color color, required IconData icon}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        border: Border.all(color: color.withAlpha(80)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaChip(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 11)),
            const SizedBox(width: 4),
            Text(value,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
