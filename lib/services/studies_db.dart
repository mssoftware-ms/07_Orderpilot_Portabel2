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

class StudiesDb {
  Database? _db;
  String? _path;

  bool get isOpen => _db != null;
  String? get path => _path;

  Future<void> open(String path) async {
    // Tolerate re-open on a different path.
    await close();
    _db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    _path = path;
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
