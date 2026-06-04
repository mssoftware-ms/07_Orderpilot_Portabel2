/// Welle O3-B4: Library Panel — lists known studies DBs with pin
/// toggle, health dot, missing-file marker, and a "Add custom .db"
/// button (file_picker).
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/library_entry.dart';
import '../../features/studies/studies_library.dart';
import '../themes/app_theme.dart';

class LibraryPanel extends StatelessWidget {
  const LibraryPanel({super.key});

  Future<void> _addCustom(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['db', 'sqlite', 'sqlite3'],
        dialogTitle: 'Add a studies .db to the library',
      );
      final path = result?.files.single.path;
      if (path == null) return;
      if (!context.mounted) return;
      final lib = context.read<StudiesLibrary>();
      final ok = await lib.addCustom(path);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Added to library'
            : 'Not an Optuna studies DB — entry not added'),
      ));
    } catch (e, st) {
      AppLog.error('LibraryPanel', 'addCustom failed: $e', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<StudiesLibrary>();
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
              const Icon(Icons.library_books,
                  size: 18, color: AppColors.accentCyan),
              const SizedBox(width: 8),
              const Text('Studies library',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              ElevatedButton.icon(
                key: const Key('library-add-custom'),
                onPressed: () => _addCustom(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add custom .db'),
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
          if (lib.entries.isEmpty)
            const Text('No studies databases yet',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12))
          else
            ...lib.entries.map((e) => _LibraryRow(entry: e, library: lib)),
        ],
      ),
    );
  }
}

class _LibraryRow extends StatelessWidget {
  final LibraryEntry entry;
  final StudiesLibrary library;
  const _LibraryRow({required this.entry, required this.library});

  Color get _healthColor {
    final h = entry.health;
    if (library.isMissing(entry)) return AppColors.bearRed;
    if (h == null || h.totalTrialCount == 0) return AppColors.textMuted;
    final ratio = h.profitableTrialCount / h.totalTrialCount;
    if (ratio >= 0.10) return AppColors.bullGreen;
    if (h.profitableTrialCount > 0) return Colors.amber;
    return AppColors.bearRed;
  }

  String get _displayName {
    final last = entry.path.split(RegExp(r'[\\/]')).last;
    return last;
  }

  @override
  Widget build(BuildContext context) {
    final h = entry.health;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: _healthColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_displayName,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 13)),
                Text(
                  library.isMissing(entry)
                      ? 'File missing'
                      : h == null
                          ? 'Not scanned yet'
                          : '${h.studyCount} studies · '
                              '${h.profitableTrialCount}/${h.totalTrialCount} '
                              'profitable',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            key: Key('library-pin-${entry.path}'),
            icon: Icon(
              entry.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              color: entry.pinned ? AppColors.accentCyan : AppColors.textMuted,
              size: 18,
            ),
            tooltip: entry.pinned ? 'Unpin' : 'Pin',
            onPressed: () => library.togglePin(entry.path),
          ),
        ],
      ),
    );
  }
}
