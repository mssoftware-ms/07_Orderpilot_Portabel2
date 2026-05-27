/// Tests for the Welle O3-B2 StudiesDb read-only SQLite layer.
///
/// Uses test/fixtures/studies_fixture.db (5 well-formed trials + 1
/// malformed metrics_json) so the skip-and-warn path is also covered.
library;

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

    test('top10 excludes -inf scores and sorts descending', () async {
      final studies = await db.listStudies();
      final top = await db.top10(studies.first.id);
      // 3 finite trials in the fixture: scores 0.85, 1.45, 2.10.
      expect(top.length, 3);
      expect(top.first.score, 2.10);
      expect(top.last.score, 0.85);
      // All scores must be finite.
      for (final t in top) {
        expect(t.score.isFinite, isTrue,
            reason: 'top10 must never contain non-finite scores');
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
}
