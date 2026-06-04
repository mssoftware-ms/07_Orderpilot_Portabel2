import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/features/studies/aggregate_leaderboard.dart';
import 'package:trading_app/features/studies/studies_library.dart';
import 'package:trading_app/services/library_storage.dart';

Future<void> _seedDb(String path,
    {required String strategy, required List<Map<String, num>> trials}) async {
  final db = await databaseFactory.openDatabase(path);
  await db.execute('CREATE TABLE studies (id INTEGER PRIMARY KEY, '
      'name TEXT NOT NULL, strategy TEXT NOT NULL, '
      'search_space_yaml TEXT NOT NULL, created_at TEXT NOT NULL, '
      'commit_hash TEXT)');
  await db.execute('CREATE TABLE trials (id INTEGER PRIMARY KEY, '
      'study_id INTEGER NOT NULL, trial_id INTEGER NOT NULL, '
      'params_json TEXT NOT NULL, metrics_json TEXT NOT NULL, '
      'score REAL NOT NULL, created_at TEXT NOT NULL)');
  await db.insert('studies', {
    'name': '${strategy}_fixture',
    'strategy': strategy,
    'search_space_yaml': 'strategy_name: $strategy',
    'created_at': '2026-06-04T00:00:00Z',
  });
  for (var i = 0; i < trials.length; i++) {
    final t = trials[i];
    final pnl = t['pnl']!.toDouble();
    final trades = t['trades']!.toInt();
    final score = t['score']!.toDouble();
    await db.insert('trials', {
      'study_id': 1,
      'trial_id': i,
      'params_json': '{"values":{"x":0.5}}',
      'metrics_json': jsonEncode({
        'total_trades': trades,
        'total_pnl': pnl,
        'win_rate': 50.0,
        'sharpe_ratio': 1.0,
        'max_drawdown_pct': 5.0,
        'profit_factor': 1.5,
        'final_equity': 1000.0 + pnl,
      }),
      'score': score,
      'created_at': '2026-06-04T00:00:00Z',
    });
  }
  await db.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  late Directory tempDir;
  late StudiesLibrary library;
  late String dbA;
  late String dbB;
  late String dbEmpty;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agg_lb_');
    dbA = '${tempDir.path}/studies-a.db';
    dbB = '${tempDir.path}/studies-b.db';
    dbEmpty = '${tempDir.path}/studies-empty.db';
    await _seedDb(dbA, strategy: 'ichimoku', trials: [
      {'pnl': 100, 'trades': 30, 'score': 1.5},
      {'pnl': -50, 'trades': 30, 'score': -0.8},
      {'pnl': 200, 'trades': 25, 'score': 2.1},
      {'pnl': 10, 'trades': 5, 'score': 0.3}, // below min_trades
    ]);
    await _seedDb(dbB, strategy: 'bb_rsi', trials: [
      {'pnl': 75, 'trades': 40, 'score': 1.2},
      {'pnl': -30, 'trades': 40, 'score': -0.5},
      {'pnl': 150, 'trades': 22, 'score': 1.9},
    ]);
    await _seedDb(dbEmpty, strategy: 'ut_bot', trials: const []);

    library = StudiesLibrary(storage: LibraryStorage());
    await library.boot(scanDirs: [tempDir.path]);
    // Pin all three so they participate.
    for (final p in [dbA, dbB, dbEmpty]) {
      await library.togglePin(p);
    }
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('merges profitable trials across pinned DBs, sorted by score',
      () async {
    final agg = AggregateLeaderboard(library: library);
    await agg.recompute();
    expect(agg.rows.length, 4,
        reason: '3 profitable in A (one filtered by min_trades) → 2; '
            '2 profitable in B → 2; empty → 0; total 4');
    // Best score wins: dbA pnl=200 score=2.1 → first.
    expect(agg.rows.first.trial.score, 2.1);
    expect(agg.rows.first.strategy, 'ichimoku');
    // Strategies must mix in the result.
    expect(agg.rows.any((r) => r.strategy == 'bb_rsi'), isTrue);
  });

  test('min_trades cutoff drops below-threshold rows', () async {
    final agg = AggregateLeaderboard(library: library);
    agg.minTrades = 30;
    await agg.recompute();
    // dbA: only 2 profitable with trades>=30; dbB: 0 with trades>=30; total 2.
    expect(agg.rows.length, 2);
    expect(agg.rows.every((r) => r.trial.metrics.totalTrades >= 30), isTrue);
  });

  test('unpinning a DB removes its rows on recompute', () async {
    final agg = AggregateLeaderboard(library: library);
    await agg.recompute();
    final before = agg.rows.length;
    await library.togglePin(dbA);
    await agg.recompute();
    expect(agg.rows.length, lessThan(before));
    expect(agg.rows.every((r) => r.dbPath != dbA), isTrue);
  });

  test('generation counter discards stale results', () async {
    final agg = AggregateLeaderboard(library: library);
    // Fire two recomputes back-to-back; only the latest result should
    // populate rows. We assert by changing min_trades between calls.
    final f1 = agg.recompute();
    agg.minTrades = 30;
    final f2 = agg.recompute();
    await Future.wait([f1, f2]);
    expect(agg.rows.every((r) => r.trial.metrics.totalTrades >= 30), isTrue);
  });

  test('broken DB does not break the others', () async {
    // Replace dbB with garbage bytes.
    await File(dbB).writeAsBytes(List<int>.filled(256, 0xFF));
    final agg = AggregateLeaderboard(library: library);
    await agg.recompute();
    // Only dbA contributes; dbB is logged as broken.
    expect(agg.rows.every((r) => r.dbPath == dbA), isTrue);
    expect(agg.rows, isNotEmpty);
  });

  test('limit caps the result set', () async {
    final agg = AggregateLeaderboard(library: library);
    agg.limit = 1;
    await agg.recompute();
    expect(agg.rows.length, 1);
  });

  test('sortBy=pnl reorders', () async {
    final agg = AggregateLeaderboard(library: library);
    agg.sortBy = 'pnl';
    await agg.recompute();
    expect(agg.rows.first.trial.metrics.totalPnl, 200);
  });
}
