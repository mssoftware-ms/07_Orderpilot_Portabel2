/// Tests for the Welle O3-B2-2 StudiesProvider.
///
/// Drives the provider against the fixture DB from B2-1 and verifies:
///   - loadDb success populates studies + top10 and clears isLoading
///   - loadDb on a bad path stores errorMessage and fires AppLog.error
///   - selectStudy swaps trials + top-10
///   - clear() resets state
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/core/logging/app_log.dart';
import 'package:trading_app/features/studies/studies_provider.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    AppLog.instance.clear();
  });

  final fixturePath =
      File('test/fixtures/studies_fixture.db').absolute.path;

  test('loadDb success populates studies, selected, trials, top10',
      () async {
    final p = StudiesProvider();
    expect(p.isLoading, isFalse);
    expect(p.studies, isEmpty);

    await p.loadDb(fixturePath);

    expect(p.isLoading, isFalse);
    expect(p.errorMessage, isNull);
    expect(p.dbPath, fixturePath);
    expect(p.studies.length, 1);
    expect(p.selectedStudy?.strategy, 'bb_rsi');
    // 5 valid trials in fixture, 1 malformed skipped.
    expect(p.trials.length, 5);
    // top10 excludes the 2 -inf scores → 3 entries.
    expect(p.top10.length, 3);
    expect(p.top10.first.score, 2.10);
    p.dispose();
  });

  test('loadDb on bad path sets errorMessage and fires AppLog.error',
      () async {
    final p = StudiesProvider();
    await p.loadDb('/tmp/this/path/does/not/exist.db');

    expect(p.isLoading, isFalse);
    expect(p.errorMessage, isNotNull);
    expect(p.errorMessage, contains('Failed to load DB'));

    // AppLog should have captured an error entry.
    final errs = AppLog.instance.entries
        .where((e) => e.level == LogLevel.error)
        .toList();
    expect(errs, isNotEmpty);
    expect(errs.first.tag, 'StudiesProvider');
    p.dispose();
  });

  test('selectStudy reloads trials + top10 for the chosen study',
      () async {
    final p = StudiesProvider();
    await p.loadDb(fixturePath);
    expect(p.selectedStudy, isNotNull);
    final firstId = p.selectedStudy!.id;

    // Re-selecting the same study should still settle isLoading=false
    // and not erase the data.
    await p.selectStudy(firstId);
    expect(p.isLoading, isFalse);
    expect(p.errorMessage, isNull);
    expect(p.trials.length, 5);

    // Selecting a nonexistent study id is a no-op + AppLog.warn (does
    // NOT clobber state).
    final beforeStudies = p.studies;
    await p.selectStudy(99999);
    expect(p.studies, same(beforeStudies));
    p.dispose();
  });

  test('clear() resets the whole state', () async {
    final p = StudiesProvider();
    await p.loadDb(fixturePath);
    expect(p.hasData, isTrue);

    p.clear();

    expect(p.dbPath, isNull);
    expect(p.studies, isEmpty);
    expect(p.selectedStudy, isNull);
    expect(p.trials, isEmpty);
    expect(p.top10, isEmpty);
    expect(p.errorMessage, isNull);
    expect(p.hasData, isFalse);
    p.dispose();
  });

  test('reload() re-opens the same path', () async {
    final p = StudiesProvider();
    await p.loadDb(fixturePath);
    expect(p.studies.length, 1);

    await p.reload();
    expect(p.studies.length, 1);
    expect(p.dbPath, fixturePath);
    p.dispose();
  });
}
