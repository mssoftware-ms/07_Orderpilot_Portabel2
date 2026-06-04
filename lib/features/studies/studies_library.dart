/// Welle O3-B4: pin/unpin + scan provider for the multi-DB Library.
///
/// The provider owns the canonical [LibraryEntry] list. Pin-state is
/// persisted via [LibraryStorage]; health-counts are recomputed
/// lazily by [refreshHealth] and cached on the entry.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/library_entry.dart';
import '../../services/library_storage.dart';
import '../../services/studies_db.dart';

class StudiesLibrary extends ChangeNotifier {
  final LibraryStorage _storage;
  StudiesLibrary({LibraryStorage? storage})
      : _storage = storage ?? LibraryStorage();

  final List<LibraryEntry> _entries = [];
  List<LibraryEntry> get entries => List.unmodifiable(_entries);

  bool _ready = false;
  bool get ready => _ready;

  bool isMissing(LibraryEntry e) => !File(e.path).existsSync();

  Future<void> boot({required List<String> scanDirs}) async {
    final fromDisk = await _storage.load();
    _entries
      ..clear()
      ..addAll(fromDisk);
    await _mergeScan(scanDirs);
    _ready = true;
    notifyListeners();
  }

  Future<void> rescan({required List<String> scanDirs}) async {
    await _mergeScan(scanDirs);
    notifyListeners();
  }

  Future<void> _mergeScan(List<String> scanDirs) async {
    final known = _entries.map((e) => e.path).toSet();
    for (final dirPath in scanDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        if (!f.path.endsWith('.db')) continue;
        final abs = f.absolute.path;
        if (known.contains(abs)) continue;
        _entries.add(LibraryEntry(
          path: abs,
          pinned: false,
          addedAt: DateTime.now().toUtc(),
        ));
        known.add(abs);
      }
    }
    await _storage.save(_entries);
  }

  Future<void> togglePin(String path) async {
    final i = _entries.indexWhere((e) => e.path == path);
    if (i < 0) return;
    _entries[i] = _entries[i].copyWith(pinned: !_entries[i].pinned);
    await _storage.save(_entries);
    notifyListeners();
  }

  Future<void> remove(String path) async {
    _entries.removeWhere((e) => e.path == path);
    await _storage.save(_entries);
    notifyListeners();
  }

  /// Returns false if the file is not an Optuna studies DB. On success
  /// the entry is added pinned (the user just deliberately picked it).
  /// A re-add of an already-known entry ensures it is pinned (set, not
  /// toggle — re-picking must never silently unpin).
  Future<bool> addCustom(String path) async {
    final abs = File(path).absolute.path;
    final existing = _entries.indexWhere((e) => e.path == abs);
    if (existing >= 0) {
      if (!_entries[existing].pinned) {
        _entries[existing] = _entries[existing].copyWith(pinned: true);
        await _storage.save(_entries);
        notifyListeners();
      }
      return true;
    }
    final db = StudiesDb();
    try {
      await db.open(abs);
      await db.close();
    } on NotAStudiesDbException catch (e, st) {
      AppLog.warn(
          'StudiesLibrary', 'addCustom rejected $abs: ${e.message}', e, st);
      return false;
    }
    _entries.add(LibraryEntry(
      path: abs,
      pinned: true,
      addedAt: DateTime.now().toUtc(),
    ));
    await _storage.save(_entries);
    notifyListeners();
    return true;
  }

  Future<void> refreshHealth() async {
    // Iterate over a path snapshot and re-resolve each entry by path
    // *after* the async health probe before writing back. The probe
    // yields (db.open/healthSnapshot), and a pin/unpin/remove can land in
    // that gap; capturing the entry up front and writing the stale copy
    // back would clobber the concurrent pin change (it only carries the
    // pinned bit it was captured with). `copyWith` touches health +
    // lastScannedAt only, so re-resolving preserves whatever pinned state
    // is current at write-back time.
    final paths =
        _entries.map((e) => e.path).toList(growable: false);
    for (final path in paths) {
      final i0 = _entries.indexWhere((e) => e.path == path);
      if (i0 < 0) continue; // removed during a prior probe
      final current = _entries[i0];
      if (isMissing(current)) continue;
      final file = File(path);
      final mtimeMs = file.statSync().modified.millisecondsSinceEpoch;
      if (current.health != null && current.health!.dbMtimeMs == mtimeMs) {
        continue;
      }
      LibraryHealth? health;
      final db = StudiesDb();
      try {
        await db.open(path);
        final snapshot = await db.healthSnapshot();
        health = LibraryHealth(
          studyCount: snapshot.studyCount,
          profitableTrialCount: snapshot.profitableTrialCount,
          totalTrialCount: snapshot.totalTrialCount,
          dbMtimeMs: mtimeMs,
        );
      } catch (err, st) {
        AppLog.warn(
            'StudiesLibrary', 'refreshHealth failed for $path: $err', err, st);
      } finally {
        await db.close();
      }
      if (health == null) continue;
      // Re-resolve now — the entry may have moved (add/remove) or had its
      // pin toggled during the probe.
      final i = _entries.indexWhere((e) => e.path == path);
      if (i < 0) continue;
      _entries[i] = _entries[i].copyWith(
        lastScannedAt: DateTime.now().toUtc(),
        health: health,
      );
    }
    await _storage.save(_entries);
    notifyListeners();
  }
}
