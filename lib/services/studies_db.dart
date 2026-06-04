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
import '../core/models/leaderboard_row.dart';
import '../core/models/library_entry.dart';
import '../core/models/study.dart';
import '../core/models/trial.dart';
import '../core/models/trial_metrics.dart';

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

  /// Welle O3-B4-13: top-10 PROFITABLE trials of a study, ranked by PnL
  /// descending. "Profitable" is `total_pnl > 0`, independent of the
  /// score value — real production studies write `score = -inf` for
  /// nearly every trial (constraint penalty; see [topNProfitable]).
  ///
  /// Ranking by PnL (not score) keeps the per-study drill-down consistent
  /// with the global leaderboard. The previous score-ranked +
  /// `score > -1e308`-filtered version returned an EMPTY table for those
  /// DBs (e.g. studies-bb_rsi.db: 309 profitable trials, all score=-inf).
  ///
  /// Client-side filter/sort — one study is ≤ ~1000 trials, so this needs
  /// no JSON1 extension and no fallback branch.
  Future<List<Trial>> top10(int studyId) async {
    final db = _require();
    final rows = await db.query(
      'trials',
      where: 'study_id = ?',
      whereArgs: [studyId],
    );
    final profitable = _parseTrialRows(rows)
        .where((t) => t.metrics.totalPnl > 0)
        .toList()
      ..sort((a, b) => b.metrics.totalPnl.compareTo(a.metrics.totalPnl));
    return profitable.take(10).toList();
  }

  /// Welle O3-B4: cross-study profitable trials within a single DB.
  ///
  /// Filters on `total_pnl > 0` and `total_trades >= minTrades`. The
  /// "profitable" definition is PURELY PnL-based and MUST NOT depend on
  /// the `score` value: real Optuna production studies penalise nearly
  /// every trial with `score = -inf` (a hard constraint no trial meets),
  /// yet record raw PnL independently — verified against the shipped
  /// studies-bb_rsi.db (1000 trials, all score=-inf, 309 with pnl>0).
  /// An earlier `score > -1e308` filter (copied from [top10]) wrongly
  /// dropped every profitable trial → empty leaderboard (Welle O3-B4-12).
  ///
  /// `sortBy` ∈ {score, pnl, sharpe, pf, trades, winRate}. Result rows
  /// are denormalized with strategy + study name so the UI needs no
  /// second JOIN.
  ///
  /// The SQL `WHERE` carries a `json_valid(metrics_json)` guard so a
  /// single malformed `metrics_json` row is skipped (matching the
  /// skip-and-warn behaviour of [_parseTrialRows]) instead of aborting
  /// the whole query — `json_extract` raises a hard SQL error on
  /// malformed JSON. The Dart fallback in [_topNProfitableFallback] is
  /// reached only if the engine lacks the JSON1 extension entirely
  /// (both `json_valid` and `json_extract` missing → DatabaseException).
  Future<List<LeaderboardRow>> topNProfitable({
    int minTrades = 20,
    int limit = 10,
    String sortBy = 'score',
  }) async {
    final db = _require();
    if (_jsonExtractAvailable ?? true) {
      try {
        return await _topNProfitableSql(db,
            minTrades: minTrades, limit: limit, sortBy: sortBy);
      } on DatabaseException catch (e) {
        // JSON1 functions missing — cache the negative result and fall back.
        AppLog.warn('StudiesDb',
            'JSON1 functions unavailable, switching to client-side filter: $e');
        _jsonExtractAvailable = false;
      }
    }
    return _topNProfitableFallback(db,
        minTrades: minTrades, limit: limit, sortBy: sortBy);
  }

  /// JSON1-availability probe result.
  ///
  /// `static` because `StudiesDb` is instantiated fresh per call (see
  /// `aggregate_leaderboard.dart` recompute loop + `studies_library.dart`
  /// refreshHealth). An instance field would re-probe every call and the
  /// negative-result cache would never persist beyond a single query —
  /// dead code. Once the first probe lands the result, all subsequent
  /// `StudiesDb` instances skip the failed-SQL path on JSON1-missing
  /// engines. Idempotent on Windows desktop (sqflite_common_ffi 2.4.1
  /// ships JSON1) — guards against future cross-platform regressions.
  ///
  /// O3-B4-Code-Review Major A follow-up.
  static bool? _jsonExtractAvailable;

  static const Map<String, String> _sortColumnMap = {
    'score': 't.score',
    'pnl': "CAST(json_extract(t.metrics_json, '\$.total_pnl') AS REAL)",
    'sharpe': "CAST(json_extract(t.metrics_json, '\$.sharpe_ratio') AS REAL)",
    'pf': "CAST(json_extract(t.metrics_json, '\$.profit_factor') AS REAL)",
    'trades':
        "CAST(json_extract(t.metrics_json, '\$.total_trades') AS INTEGER)",
    'winRate': "CAST(json_extract(t.metrics_json, '\$.win_rate') AS REAL)",
  };

  Future<List<LeaderboardRow>> _topNProfitableSql(
    Database db, {
    required int minTrades,
    required int limit,
    required String sortBy,
  }) async {
    final orderExpr = _sortColumnMap[sortBy] ?? 't.score';
    final rows = await db.rawQuery(
      'SELECT t.*, s.strategy AS _strategy, s.name AS _study_name '
      'FROM trials t JOIN studies s ON t.study_id = s.id '
      'WHERE json_valid(t.metrics_json) '
      "  AND CAST(json_extract(t.metrics_json, '\$.total_pnl') AS REAL) > 0 "
      "  AND CAST(json_extract(t.metrics_json, '\$.total_trades') AS INTEGER) >= ? "
      'ORDER BY $orderExpr DESC '
      'LIMIT ?',
      [minTrades, limit],
    );
    return _mapToLeaderboardRows(rows);
  }

  Future<List<LeaderboardRow>> _topNProfitableFallback(
    Database db, {
    required int minTrades,
    required int limit,
    required String sortBy,
  }) async {
    // Client-side: join studies + trials, parse metrics in Dart, filter,
    // sort. O(total_trials_in_db) per call — acceptable for ≤10k trials.
    // No score filter — "profitable" is PnL-based only (see topNProfitable
    // doc, Welle O3-B4-12). The pnl>0 / minTrades cut happens in Dart below.
    final rows = await db.rawQuery(
      'SELECT t.*, s.strategy AS _strategy, s.name AS _study_name '
      'FROM trials t JOIN studies s ON t.study_id = s.id',
    );
    final all = _mapToLeaderboardRows(rows)
        .where((r) =>
            r.trial.metrics.totalPnl > 0 &&
            r.trial.metrics.totalTrades >= minTrades)
        .toList();
    int cmp(LeaderboardRow a, LeaderboardRow b) {
      switch (sortBy) {
        case 'pnl':
          return b.trial.metrics.totalPnl.compareTo(a.trial.metrics.totalPnl);
        case 'sharpe':
          return b.trial.metrics.sharpeRatio
              .compareTo(a.trial.metrics.sharpeRatio);
        case 'pf':
          return b.trial.metrics.profitFactor
              .compareTo(a.trial.metrics.profitFactor);
        case 'trades':
          return b.trial.metrics.totalTrades
              .compareTo(a.trial.metrics.totalTrades);
        case 'winRate':
          return b.trial.metrics.winRate.compareTo(a.trial.metrics.winRate);
        case 'score':
        default:
          return b.trial.score.compareTo(a.trial.score);
      }
    }

    all.sort(cmp);
    return all.take(limit).toList();
  }

  List<LeaderboardRow> _mapToLeaderboardRows(
      List<Map<String, Object?>> rows) {
    final out = <LeaderboardRow>[];
    for (final row in rows) {
      try {
        final trial = Trial.fromRow(row);
        out.add(LeaderboardRow(
          trial: trial,
          strategy: row['_strategy'] as String,
          studyName: row['_study_name'] as String,
          studyDbId: trial.studyId,
          dbPath: _path ?? '',
        ));
      } catch (e, st) {
        AppLog.warn('StudiesDb',
            'Skipped malformed leaderboard row id=${row['id']}: $e', e, st);
      }
    }
    return out;
  }

  /// Welle O3-B4: lightweight counts for the Library health dot. The
  /// profitable-count query carries the same `json_valid` guard +
  /// JSON1-missing fallback as [topNProfitable].
  Future<LibraryHealth> healthSnapshot() async {
    final db = _require();
    final studyCountRow =
        await db.rawQuery('SELECT COUNT(*) AS c FROM studies');
    final totalRow = await db.rawQuery('SELECT COUNT(*) AS c FROM trials');
    int profitableCount;
    if (_jsonExtractAvailable ?? true) {
      try {
        final r = await db.rawQuery(
          "SELECT COUNT(*) AS c FROM trials WHERE "
          "json_valid(metrics_json) AND "
          "CAST(json_extract(metrics_json, '\$.total_pnl') AS REAL) > 0",
        );
        profitableCount = (r.first['c'] as num).toInt();
      } on DatabaseException {
        _jsonExtractAvailable = false;
        profitableCount = await _profitableCountFallback(db);
      }
    } else {
      profitableCount = await _profitableCountFallback(db);
    }
    return LibraryHealth(
      studyCount: (studyCountRow.first['c'] as num).toInt(),
      profitableTrialCount: profitableCount,
      totalTrialCount: (totalRow.first['c'] as num).toInt(),
      dbMtimeMs: 0, // filled by StudiesLibrary, not by StudiesDb
    );
  }

  Future<int> _profitableCountFallback(Database db) async {
    final all = await db.rawQuery('SELECT metrics_json FROM trials');
    var count = 0;
    for (final row in all) {
      try {
        final metrics =
            TrialMetrics.fromJsonString(row['metrics_json'] as String);
        if (metrics.totalPnl > 0) count++;
      } catch (_) {/* skip malformed */}
    }
    return count;
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
