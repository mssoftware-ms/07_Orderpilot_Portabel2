// tool/build_fixture_library.dart
// Run: dart run tool/build_fixture_library.dart
// Emits 3 fixture .db files into test/fixtures/.
//
// NOTE: sqflite_common_ffi resolves *relative* DB paths against its own
// data directory, so every openDatabase call is handed an absolute path
// (File(path).absolute.path) — otherwise the fixtures would land under
// .dart_tool/ instead of the repo's test/fixtures/.
import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _make(String path,
    {required String strategy,
    required List<Map<String, num>> trials}) async {
  final abs = File(path).absolute.path;
  if (File(abs).existsSync()) await File(abs).delete();
  final db = await databaseFactory.openDatabase(abs);
  await db.execute('CREATE TABLE studies (id INTEGER PRIMARY KEY, '
      'name TEXT NOT NULL, strategy TEXT NOT NULL, '
      'search_space_yaml TEXT NOT NULL, created_at TEXT NOT NULL, '
      'commit_hash TEXT)');
  await db.execute('CREATE TABLE trials (id INTEGER PRIMARY KEY, '
      'study_id INTEGER NOT NULL, trial_id INTEGER NOT NULL, '
      'params_json TEXT NOT NULL, metrics_json TEXT NOT NULL, '
      'score REAL NOT NULL, created_at TEXT NOT NULL)');
  await db.insert('studies', {
    'name': '${strategy}_fixture_library',
    'strategy': strategy,
    'search_space_yaml': 'strategy_name: $strategy',
    'created_at': '2026-06-04T00:00:00Z',
  });
  for (var i = 0; i < trials.length; i++) {
    final t = trials[i];
    await db.insert('trials', {
      'study_id': 1,
      'trial_id': i,
      'params_json': '{"values":{"x":0.5}}',
      'metrics_json': jsonEncode({
        'total_trades': t['trades']!.toInt(),
        'total_pnl': t['pnl']!.toDouble(),
        'win_rate': 50.0,
        'sharpe_ratio': 1.0,
        'max_drawdown_pct': 5.0,
        'profit_factor': 1.5,
        'final_equity': 1000 + t['pnl']!.toDouble(),
      }),
      'score': t['score']!.toDouble(),
      'created_at': '2026-06-04T00:00:00Z',
    });
  }
  await db.close();
}

Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await _make('test/fixtures/studies_fixture_library_a.db',
      strategy: 'ichimoku', trials: [
        {'pnl': 100, 'trades': 30, 'score': 1.5},
        {'pnl': -50, 'trades': 30, 'score': -0.8},
        {'pnl': 200, 'trades': 25, 'score': 2.1},
      ]);
  await _make('test/fixtures/studies_fixture_library_b.db',
      strategy: 'bb_rsi', trials: [
        {'pnl': 75, 'trades': 40, 'score': 1.2},
        {'pnl': 150, 'trades': 22, 'score': 1.9},
      ]);
  await _make('test/fixtures/studies_fixture_library_empty.db',
      strategy: 'ut_bot', trials: const []);
  stdout.writeln('Fixture library DBs written.');
}
