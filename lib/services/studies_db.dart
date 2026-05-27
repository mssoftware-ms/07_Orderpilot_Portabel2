/// Read-only access to the Optuna-style studies/trials SQLite databases
/// produced by `scripts/run_*_optimization.py`.
///
/// Welle O3-B2: pure read-side. Writing optimization results from the
/// Flutter app is out of scope (the optimizer CLI owns that).
///
/// The actual `databaseFactoryFfi` swap happens once in `main()` via
/// `sqfliteFfiInit()`. Tests do the same in their setUp blocks.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../core/logging/app_log.dart';
import '../core/models/study.dart';
import '../core/models/trial.dart';

/// Thrown by [StudiesDb.open] when the picked file is not a usable
/// Optuna-style studies database — either because it is not a SQLite
/// file at all (random bytes, ruvector.db with a non-SQLite format,
/// etc.) or because it is a valid SQLite file with the wrong schema
/// (no `studies` / `trials` tables — e.g. an unrelated app DB sitting
/// in the picker's start directory).
///
/// The [message] is user-friendly and safe to render verbatim in the
/// UI error banner; it never contains raw `SqfliteFfiException`
/// payload. Use [cause] / [stackTrace] for forensic logging only.
class NotAStudiesDbException implements Exception {
  final String message;
  final String path;
  final Object? cause;
  final StackTrace? stackTrace;

  const NotAStudiesDbException(
    this.message, {
    required this.path,
    this.cause,
    this.stackTrace,
  });

  @override
  String toString() => 'NotAStudiesDbException: $message';
}

class StudiesDb {
  Database? _db;
  String? _path;

  bool get isOpen => _db != null;
  String? get path => _path;

  /// Hint embedded in [NotAStudiesDbException.message] pointing the user
  /// back to the folder where the optimizer CLI writes its studies DBs.
  static const String _studiesFolderHint =
      '01_Projectplan/optimizer_studies/';

  Future<void> open(String path) async {
    // Tolerate re-open on a different path.
    await close();
    Database? db;
    try {
      db = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      // Schema preflight: the studies viewer needs BOTH `studies` and
      // `trials`. Doing this against sqlite_master (instead of letting
      // the first business query throw NOTADB) lets us wrap both
      // "wrong schema" and "not a SQLite file" into the same typed
      // exception below — the raw SqfliteFfiException never leaks.
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master "
        "WHERE type='table' AND name IN ('studies', 'trials')",
      );
      final found = tables.map((r) => r['name'] as String).toSet();
      if (!found.contains('studies') || !found.contains('trials')) {
        await db.close();
        throw NotAStudiesDbException(
          'This SQLite file does not contain an Optuna studies database '
          '(missing studies/trials tables). Pick a studies-*.db from '
          '$_studiesFolderHint instead.',
          path: path,
        );
      }
      _db = db;
      _path = path;
    } on NotAStudiesDbException {
      rethrow;
    } on DatabaseException catch (e, st) {
      await db?.close();
      throw NotAStudiesDbException(
        'This file is not a readable SQLite database. Pick a studies-*.db '
        'from $_studiesFolderHint instead.',
        path: path,
        cause: e,
        stackTrace: st,
      );
    }
  }

  Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
    }
    _db = null;
    _path = null;
  }

  Database _require() {
    final db = _db;
    if (db == null) {
      throw StateError('StudiesDb not open');
    }
    return db;
  }

  Future<List<Study>> listStudies() async {
    final db = _require();
    final rows = await db.query('studies', orderBy: 'id ASC');
    final out = <Study>[];
    for (final row in rows) {
      try {
        out.add(Study.fromRow(row));
      } catch (e, st) {
        AppLog.warn(
          'StudiesDb',
          'Skipped malformed studies row id=${row['id']}: $e',
          e,
          st,
        );
      }
    }
    return out;
  }

  Future<List<Trial>> listTrials(
    int studyId, {
    int? limit,
    int? offset,
  }) async {
    final db = _require();
    final rows = await db.query(
      'trials',
      where: 'study_id = ?',
      whereArgs: [studyId],
      orderBy: 'trial_id ASC',
      limit: limit,
      offset: offset,
    );
    return _parseTrialRows(rows);
  }

  /// Top-10 trials by score, descending. Excludes non-finite scores
  /// (Optuna writes `-inf` for 0-trade trials and they would otherwise
  /// dominate any sort direction).
  ///
  /// SQLite stores `-inf` as a REAL value that compares less than every
  /// finite number, so `score > -inf` is the cleanest exclusion filter
  /// (also catches NaN per IEEE-754 — NaN comparisons are always false,
  /// so NaN rows are dropped too).
  Future<List<Trial>> top10(int studyId) async {
    final db = _require();
    final rows = await db.rawQuery(
      'SELECT * FROM trials '
      'WHERE study_id = ? AND score > -1e308 '
      'ORDER BY score DESC '
      'LIMIT 10',
      [studyId],
    );
    return _parseTrialRows(rows);
  }

  List<Trial> _parseTrialRows(List<Map<String, Object?>> rows) {
    final out = <Trial>[];
    for (final row in rows) {
      try {
        out.add(Trial.fromRow(row));
      } catch (e, st) {
        AppLog.warn(
          'StudiesDb',
          'Skipped malformed trial row id=${row['id']}: $e',
          e,
          st,
        );
      }
    }
    return out;
  }
}
