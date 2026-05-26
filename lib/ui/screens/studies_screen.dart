/// Welle O3-B2 Studies viewer — top-level screen.
///
/// Three sections stacked top-to-bottom (or two-column on wide screens):
///   A — DB picker + studies dropdown + reload button
///   B — Top-10 trials table (B2-4 wires the real DataTable)
///   C — Convergence scatter plot (B2-5 wires the real fl_chart)
///
/// State lives in [StudiesProvider]; this widget is a thin presenter.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/study.dart';
import '../../features/studies/studies_provider.dart';
import '../themes/app_theme.dart';

class StudiesScreen extends StatelessWidget {
  const StudiesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<StudiesProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Studies'),
            actions: [
              if (provider.dbPath != null)
                IconButton(
                  key: const Key('studies-reload-button'),
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Reload current DB',
                  onPressed: provider.isLoading ? null : provider.reload,
                ),
            ],
          ),
          body: _StudiesBody(provider: provider),
        );
      },
    );
  }
}

class _StudiesBody extends StatelessWidget {
  final StudiesProvider provider;
  const _StudiesBody({required this.provider});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PickerSection(provider: provider),
          const SizedBox(height: 16),
          _Top10Placeholder(provider: provider),
          const SizedBox(height: 16),
          _ConvergencePlaceholder(provider: provider),
        ],
      ),
    );
  }
}

// ─── Section A — DB picker + studies dropdown ───────────────────────────────

class _PickerSection extends StatelessWidget {
  final StudiesProvider provider;
  const _PickerSection({required this.provider});

  Future<void> _pickDb(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['db', 'sqlite', 'sqlite3'],
        dialogTitle: 'Select an Optuna studies .db file',
      );
      final path = result?.files.single.path;
      if (path == null) return;
      await provider.loadDb(path);
    } catch (e, st) {
      AppLog.error('StudiesScreen',
          'File picker failed: $e', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
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
          Row(
            children: [
              const Icon(Icons.folder_open,
                  size: 18, color: AppColors.accentCyan),
              const SizedBox(width: 8),
              const Text('Optimizer studies database',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  )),
              const Spacer(),
              ElevatedButton.icon(
                key: const Key('studies-pick-db-button'),
                onPressed:
                    provider.isLoading ? null : () => _pickDb(context),
                icon: const Icon(Icons.file_open, size: 16),
                label: const Text('Pick .db'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentCyan,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (provider.dbPath != null) ...[
            Text(
              provider.dbPath!,
              style: const TextStyle(
                  color: AppColors.textMuted, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            _StudyDropdown(provider: provider),
          ],
          if (provider.errorMessage != null) ...[
            const SizedBox(height: 12),
            _ErrorBanner(message: provider.errorMessage!),
          ],
          if (provider.isLoading) ...[
            const SizedBox(height: 12),
            const _LoadingIndicator(),
          ],
        ],
      ),
    );
  }
}

class _StudyDropdown extends StatelessWidget {
  final StudiesProvider provider;
  const _StudyDropdown({required this.provider});

  @override
  Widget build(BuildContext context) {
    final studies = provider.studies;
    if (studies.isEmpty) {
      return const Text(
        'No studies found in this DB.',
        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          key: const Key('studies-study-dropdown'),
          value: provider.selectedStudy?.id,
          isExpanded: true,
          dropdownColor: AppColors.surfaceElevated,
          style: const TextStyle(
              color: AppColors.textPrimary, fontSize: 13),
          items: studies
              .map((Study s) => DropdownMenuItem<int>(
                    value: s.id,
                    child: Row(
                      children: [
                        Text(s.strategy,
                            style: const TextStyle(
                                color: AppColors.accentPurple,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            s.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ))
              .toList(),
          onChanged: provider.isLoading
              ? null
              : (id) {
                  if (id != null) provider.selectStudy(id);
                },
        ),
      ),
    );
  }
}

// ─── Section B — Top-10 placeholder (B2-4 replaces) ─────────────────────────

class _Top10Placeholder extends StatelessWidget {
  final StudiesProvider provider;
  const _Top10Placeholder({required this.provider});

  @override
  Widget build(BuildContext context) {
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
          const Row(
            children: [
              Icon(Icons.leaderboard,
                  size: 18, color: AppColors.accentCyan),
              SizedBox(width: 8),
              Text('Top-10 trials',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const SizedBox(height: 12),
          if (!provider.hasData)
            const Text(
              'Pick a studies .db file to populate the top-10 list.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            )
          else
            Text(
              '${provider.top10.length} finite-score trials '
              '(table widget lands in Welle O3-B2-4)',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

// ─── Section C — Convergence placeholder (B2-5 replaces) ────────────────────

class _ConvergencePlaceholder extends StatelessWidget {
  final StudiesProvider provider;
  const _ConvergencePlaceholder({required this.provider});

  @override
  Widget build(BuildContext context) {
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
          const Row(
            children: [
              Icon(Icons.scatter_plot,
                  size: 18, color: AppColors.accentCyan),
              SizedBox(width: 8),
              Text('Convergence plot',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const SizedBox(height: 12),
          if (!provider.hasData)
            const Text(
              'Pick a studies .db file to render the trial-score scatter.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            )
          else
            Text(
              '${provider.trials.length} trials loaded '
              '(scatter plot lands in Welle O3-B2-5)',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

// ─── Shared bits ─────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('studies-error-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.bearRed.withAlpha(25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.bearRed.withAlpha(80)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline,
              size: 16, color: AppColors.bearRed),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                  color: AppColors.bearRed, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingIndicator extends StatelessWidget {
  const _LoadingIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('studies-loading-indicator'),
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppColors.accentCyan),
        ),
        const SizedBox(width: 8),
        const Text(
          'Loading…',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      ],
    );
  }
}
