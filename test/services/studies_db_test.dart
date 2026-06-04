/// Tests for the Welle O3-B2 StudiesDb read-only SQLite layer.
///
/// Uses test/fixtures/studies_fixture.db (5 well-formed trials + 1
/// malformed metrics_json) so the skip-and-warn path is also covered.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/services/studies_db.dart';

void main() {
  setUpAll(() {
    // Tests run via the Flutter test harness — `main()` from lib/main.dart
    // is NOT invoked, so the FFI swap has to happen here too.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('StudiesDb', () {
    late StudiesDb db;
    // sqflite_common_ffi resolves relative paths against its own data
    // directory, so we hand it an absolute path to the repo-tracked
    // fixture instead.
    final fixturePath = File('test/fixtures/studies_fixture.db')
        .absolute
        .path;

    setUp(() async {
      db = StudiesDb();
      await db.open(fixturePath);
    });

    tearDown(() async {
      await db.close();
    });

    test('open/close is idempotent', () async {
      expect(db.isOpen, isTrue);
      await db.close();
      expect(db.isOpen, isFalse);
      await db.close(); // second close should be a no-op
      expect(db.isOpen, isFalse);
    });

    test('open after close re-attaches to the same file', () async {
      await db.close();
      await db.open(fixturePath);
      expect(db.isOpen, isTrue);
      expect(db.path, fixturePath);
    });

    test('listStudies returns the single fixture study', () async {
      final studies = await db.listStudies();
      expect(studies.length, 1);
      expect(studies.first.strategy, 'bb_rsi');
      expect(studies.first.name, 'fixture_bb_rsi_5trials');
      expect(studies.first.searchSpaceYaml,
          contains('strategy_name: bb_rsi'));
    });

    test('listTrials parses params (unwraps "values") + metrics', () async {
      final studies = await db.listStudies();
      final trials = await db.listTrials(studies.first.id);
      // 5 valid + 1 malformed → 5 returned (malformed skipped).
      expect(trials.length, 5);

      // Trial 1 (index 1 in the seed) — params "values" unwrapped.
      final t1 = trials.firstWhere((t) => t.trialId == 1);
      expect(t1.params['bb_period'], 150.0);
      expect(t1.params['bb_stddev'], 0.3);
      expect(t1.metrics.totalTrades, 4);
      expect(t1.metrics.totalPnl, 120.5);
      expect(t1.metrics.sharpeRatio, 1.45);

      // Trial 0 score is -inf and surfaces as double.negativeInfinity.
      final t0 = trials.firstWhere((t) => t.trialId == 0);
      expect(t0.score, double.negativeInfinity);
      expect(t0.scoreIsFinite, isFalse);
    });

    test('top10 returns profitable trials ranked by PnL descending',
        () async {
      // Welle O3-B4-13: top10 is now PnL-ranked, profitable-only (not
      // score-ranked). Fixture profitable trials: trial 2 (pnl 450),
      // trial 1 (120.5), trial 4 (60.0). trials 0/3 have pnl 0 (excluded);
      // trial 5 is malformed (skipped).
      final studies = await db.listStudies();
      final top = await db.top10(studies.first.id);
      expect(top.length, 3);
      expect(top.first.trialId, 2);
      expect(top.first.metrics.totalPnl, 450.0);
      expect(top.last.metrics.totalPnl, 60.0);
      expect(top.every((t) => t.metrics.totalPnl > 0), isTrue);
      for (var i = 1; i < top.length; i++) {
        expect(
            top[i].metrics.totalPnl <= top[i - 1].metrics.totalPnl, isTrue,
            reason: 'top10 must be PnL-descending');
      }
    });

    test('malformed metrics_json row is skipped, others still load',
        () async {
      final studies = await db.listStudies();
      final all = await db.listTrials(studies.first.id);
      // Trial 5 in the fixture has invalid metrics_json — must NOT appear.
      final ids = all.map((t) => t.trialId).toSet();
      expect(ids.contains(5), isFalse,
          reason: 'trial 5 has malformed metrics_json and must be skipped');
      expect(all.length, 5);
    });

    test('listTrials honors limit and offset', () async {
      final studies = await db.listStudies();
      final firstTwo = await db.listTrials(studies.first.id, limit: 2);
      expect(firstTwo.length, 2);
      expect(firstTwo.first.trialId, 0);
      expect(firstTwo.last.trialId, 1);

      final nextTwo =
          await db.listTrials(studies.first.id, limit: 2, offset: 2);
      expect(nextTwo.length, 2);
      expect(nextTwo.first.trialId, 2);
    });

    test('querying before open throws StateError', () async {
      final fresh = StudiesDb();
      expect(() => fresh.listStudies(), throwsA(isA<StateError>()));
    });

    // ─── Welle O3-B4 — cross-study profitable filter ──────────────────────
    //
    // Fixture (strategy bb_rsi, study "fixture_bb_rsi_5trials"):
    //   trial 1: pnl 120.5, trades 4   (profitable)
    //   trial 2: pnl 450.0, trades 12  (profitable)
    //   trial 4: pnl  60.0, trades 7   (profitable)
    //   trials 0/3: pnl 0.0, score -inf (not profitable)
    //   trial 5: malformed metrics_json (skipped via json_valid guard)
    test('topNProfitable: keeps only profitable rows, skips malformed/0-pnl',
        () async {
      final all = await db.topNProfitable(minTrades: 0, limit: 50);
      expect(all.length, 3);
      expect(all.every((r) => r.trial.metrics.totalPnl > 0), isTrue);
      // Default sort is score desc → trial 2 (score 2.10) leads.
      expect(all.first.trial.trialId, 2);
      expect(all.first.trial.metrics.totalPnl,
          greaterThan(all.last.trial.metrics.totalPnl));
      // Strategy + study name are denormalized from the studies row.
      expect(all.first.strategy, 'bb_rsi');
      expect(all.first.studyName, 'fixture_bb_rsi_5trials');
      // The malformed-metrics_json trial 5 must never surface.
      expect(all.any((r) => r.trial.trialId == 5), isFalse);
    });

    test('topNProfitable: min_trades cutoff drops low-sample trials',
        () async {
      // Profitable trials carry 4 / 12 / 7 trades. min_trades=10 keeps only
      // the 12-trade trial; a cutoff above the max empties the result.
      final cut10 = await db.topNProfitable(minTrades: 10, limit: 50);
      expect(cut10.length, 1);
      expect(cut10.every((r) => r.trial.metrics.totalTrades >= 10), isTrue);
      final cut13 = await db.topNProfitable(minTrades: 13, limit: 50);
      expect(cut13, isEmpty);
    });

    test('topNProfitable: respects limit', () async {
      final one = await db.topNProfitable(minTrades: 0, limit: 1);
      expect(one.length, 1);
    });

    test('topNProfitable: sortBy=pnl reorders by totalPnl desc', () async {
      final byPnl =
          await db.topNProfitable(minTrades: 0, limit: 50, sortBy: 'pnl');
      expect(byPnl.first.trial.metrics.totalPnl, 450.0);
      expect(byPnl.last.trial.metrics.totalPnl, 60.0);
    });

    test('healthSnapshot returns counts (malformed row tolerated)', () async {
      final h = await db.healthSnapshot();
      expect(h.studyCount, 1);
      // 6 physical trial rows (incl. the malformed one).
      expect(h.totalTrialCount, 6);
      // 3 with total_pnl > 0; malformed row skipped by json_valid.
      expect(h.profitableTrialCount, 3);
    });
  });

  // ─── Welle O3-B2.1 — friendly schema preflight ────────────────────────────
  //
  // open() must reject files that look like SQLite but lack studies/trials
  // (e.g. ruvector.db sitting next to the optimizer studies in the same
  // folder) and files that are not SQLite at all (random bytes). In both
  // cases we want a typed NotAStudiesDbException with a user-friendly
  // message pointing back to 01_Projectplan/optimizer_studies/ — never
  // a raw SqfliteFfiException leaking into the UI.
  group('StudiesDb.open() schema preflight (Welle O3-B2.1)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('studies_b21_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('throws NotAStudiesDbException for SQLite DB without studies/trials',
        () async {
      // Build a fully valid SQLite DB that just happens to have a
      // different schema (mimics ruvector.db landing in the picker).
      final wrongSchemaPath = '${tempDir.path}/wrong_schema.db';
      final seed = await databaseFactory.openDatabase(wrongSchemaPath);
      await seed.execute('CREATE TABLE foo (id INTEGER PRIMARY KEY)');
      await seed.close();

      final db = StudiesDb();
      await expectLater(
        () => db.open(wrongSchemaPath),
        throwsA(isA<NotAStudiesDbException>()),
      );
      expect(db.isOpen, isFalse,
          reason: 'failed open must not leave a dangling handle');
    });

    test('throws NotAStudiesDbException for non-SQLite random bytes', () async {
      final junkPath = '${tempDir.path}/junk.db';
      // 256 bytes of garbage — magic header will not match SQLite.
      final bytes = List<int>.generate(256, (i) => (i * 7 + 13) & 0xFF);
      await File(junkPath).writeAsBytes(bytes);

      final db = StudiesDb();
      await expectLater(
        () => db.open(junkPath),
        throwsA(isA<NotAStudiesDbException>()),
      );
      expect(db.isOpen, isFalse);
    });

    test('NotAStudiesDbException.message points back to optimizer_studies',
        () async {
      final wrongSchemaPath = '${tempDir.path}/wrong_schema_msg.db';
      final seed = await databaseFactory.openDatabase(wrongSchemaPath);
      await seed.execute('CREATE TABLE foo (id INTEGER PRIMARY KEY)');
      await seed.close();

      final db = StudiesDb();
      try {
        await db.open(wrongSchemaPath);
        fail('expected NotAStudiesDbException');
      } on NotAStudiesDbException catch (e) {
        // User-friendly: no raw SQLite error code 26, no SqfliteFfiException
        // class name, and a hint pointing to the bundled studies folder.
        expect(e.message, isNot(contains('SqfliteFfiException')));
        expect(e.message, isNot(contains('code 26')));
        expect(e.message, isNot(contains('Causing statement')));
        expect(e.message, contains('01_Projectplan/optimizer_studies'));
        expect(e.path, wrongSchemaPath);
      }
    });
  });

  // ─── Welle O3-B4-12 — real-data regression: all-(-inf) scores ─────────────
  //
  // Real Optuna production studies penalise EVERY trial with score=-inf
  // (a hard constraint no trial satisfies), yet record raw total_pnl
  // independently. Verified against the shipped studies-bb_rsi.db: 1000
  // trials, ALL score=-inf, but 309 with total_pnl > 0. The legacy
  // `score > -1e308` filter (inherited from O3-B2 top10) wrongly dropped
  // every profitable trial → empty leaderboard. "Profitable" must be
  // defined purely by total_pnl, independent of the score value.
  group('StudiesDb.topNProfitable all-(-inf)-scores (O3-B4-12)', () {
    late Directory tempDir;
    late String dbPath;
    late StudiesDb db;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('studies_neginf_');
      dbPath = '${tempDir.path}/studies-neginf.db'
          .replaceAll('/', Platform.pathSeparator);
      final seed = await databaseFactory.openDatabase(dbPath);
      await seed.execute('CREATE TABLE studies (id INTEGER PRIMARY KEY, '
          'name TEXT NOT NULL, strategy TEXT NOT NULL, '
          'search_space_yaml TEXT NOT NULL, created_at TEXT NOT NULL, '
          'commit_hash TEXT)');
      await seed.execute('CREATE TABLE trials (id INTEGER PRIMARY KEY, '
          'study_id INTEGER NOT NULL, trial_id INTEGER NOT NULL, '
          'params_json TEXT NOT NULL, metrics_json TEXT NOT NULL, '
          'score REAL NOT NULL, created_at TEXT NOT NULL)');
      await seed.insert('studies', {
        'name': 'production_neginf',
        'strategy': 'bb_rsi',
        'search_space_yaml': 'strategy_name: bb_rsi',
        'created_at': '2026-06-04T00:00:00Z',
      });
      // Every trial carries score = -inf (production-study constraint
      // penalty); raw PnL is recorded independently.
      const seeded = [
        {'pnl': 1978.0, 'trades': 3}, // profitable, few trades
        {'pnl': 1382.0, 'trades': 10}, // profitable
        {'pnl': 1171.0, 'trades': 25}, // profitable, high sample
        {'pnl': -500.0, 'trades': 30}, // loss
        {'pnl': 0.0, 'trades': 0}, // 0-trade
      ];
      for (var i = 0; i < seeded.length; i++) {
        await seed.insert('trials', {
          'study_id': 1,
          'trial_id': i,
          'params_json': '{"values":{"x":0.5}}',
          'metrics_json': jsonEncode({
            'total_trades': seeded[i]['trades'],
            'total_pnl': seeded[i]['pnl'],
            'win_rate': 50.0,
            'sharpe_ratio': 1.0,
            'max_drawdown_pct': 5.0,
            'profit_factor': 1.5,
            'final_equity': 10000 + (seeded[i]['pnl'] as double),
          }),
          'score': double.negativeInfinity,
          'created_at': '2026-06-04T00:00:00Z',
        });
      }
      await seed.close();
      db = StudiesDb();
      await db.open(dbPath);
    });

    tearDown(() async {
      await db.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('returns profitable trials even when every score is -inf',
        () async {
      final rows = await db.topNProfitable(minTrades: 0, limit: 50);
      expect(rows.length, 3,
          reason: '3 trials have pnl>0; -inf score must not exclude them');
      expect(rows.every((r) => r.trial.metrics.totalPnl > 0), isTrue);
      expect(rows.every((r) => !r.trial.scoreIsFinite), isTrue,
          reason: 'all seeded scores are -inf — proves the filter is gone');
    });

    test('min_trades cutoff still applies with -inf scores', () async {
      final cut = await db.topNProfitable(minTrades: 20, limit: 50);
      expect(cut.length, 1,
          reason: 'only the 25-trade profitable trial qualifies');
      expect(cut.first.trial.metrics.totalTrades, 25);
    });

    test('sortBy=pnl orders by PnL despite -inf scores', () async {
      final byPnl =
          await db.topNProfitable(minTrades: 0, limit: 50, sortBy: 'pnl');
      expect(byPnl.first.trial.metrics.totalPnl, 1978.0);
      expect(byPnl.last.trial.metrics.totalPnl, 1171.0);
    });

    test('healthSnapshot counts profitable independent of -inf score',
        () async {
      final h = await db.healthSnapshot();
      expect(h.profitableTrialCount, 3,
          reason: 'health already ignores score — parity with leaderboard');
      expect(h.totalTrialCount, 5);
    });

    test('top10 returns profitable trials even when every score is -inf',
        () async {
      // Per-study drill-down (O3-B4-13): same -inf robustness as the
      // leaderboard. 3 trials have pnl>0; PnL-ranked → 1978 leads.
      final top = await db.top10(1);
      expect(top.length, 3,
          reason: '3 trials have pnl>0; -inf score must not exclude them');
      expect(top.every((t) => t.metrics.totalPnl > 0), isTrue);
      expect(top.every((t) => !t.scoreIsFinite), isTrue,
          reason: 'all seeded scores are -inf');
      expect(top.first.metrics.totalPnl, 1978.0);
    });
  });
}
