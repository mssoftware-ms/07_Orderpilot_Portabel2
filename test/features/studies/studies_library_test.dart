import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/features/studies/studies_library.dart';
import 'package:trading_app/services/library_storage.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  late Directory tempDir;
  late String fixtureA;
  late String fixtureB;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('studies_library_');
    // Canonicalize to OS-native separators (Backslash on Windows). The
    // library stores `_canonicalize(file.path)`; mixed-slash test paths
    // miss every string-equals lookup. See O3-B4-10.
    fixtureA = '${tempDir.path}/studies-a.db'
        .replaceAll('/', Platform.pathSeparator);
    fixtureB = '${tempDir.path}/studies-b.db'
        .replaceAll('/', Platform.pathSeparator);
    for (final path in [fixtureA, fixtureB]) {
      final db = await databaseFactory.openDatabase(path);
      await db.execute('CREATE TABLE studies (id INTEGER PRIMARY KEY, '
          'name TEXT NOT NULL, strategy TEXT NOT NULL, '
          'search_space_yaml TEXT NOT NULL, created_at TEXT NOT NULL, '
          'commit_hash TEXT)');
      await db.execute('CREATE TABLE trials (id INTEGER PRIMARY KEY, '
          'study_id INTEGER NOT NULL, trial_id INTEGER NOT NULL, '
          'params_json TEXT NOT NULL, metrics_json TEXT NOT NULL, '
          'score REAL NOT NULL, created_at TEXT NOT NULL)');
      await db.close();
    }
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('scanDirectory finds .db files', () async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: [tempDir.path]);
    expect(lib.entries.length, 2);
    expect(lib.entries.every((e) => e.pinned == false), isTrue,
        reason: 'newly scanned entries must start unpinned');
  });

  test('boot preserves pin-state from storage', () async {
    final storage = LibraryStorage();
    final lib1 = StudiesLibrary(storage: storage);
    await lib1.boot(scanDirs: [tempDir.path]);
    await lib1.togglePin(fixtureA);
    expect(lib1.entries.firstWhere((e) => e.path == fixtureA).pinned, isTrue);

    final lib2 = StudiesLibrary(storage: storage);
    await lib2.boot(scanDirs: [tempDir.path]);
    expect(lib2.entries.firstWhere((e) => e.path == fixtureA).pinned, isTrue);
    expect(lib2.entries.firstWhere((e) => e.path == fixtureB).pinned, isFalse);
  });

  test('addCustom rejects non-studies DB', () async {
    final wrongPath = '${tempDir.path}/wrong.db'
        .replaceAll('/', Platform.pathSeparator);
    final db = await databaseFactory.openDatabase(wrongPath);
    await db.execute('CREATE TABLE foo (id INTEGER PRIMARY KEY)');
    await db.close();
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: const []);
    final added = await lib.addCustom(wrongPath);
    expect(added, isFalse);
    expect(lib.entries, isEmpty);
  });

  test('addCustom accepts valid studies DB', () async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: const []);
    final added = await lib.addCustom(fixtureA);
    expect(added, isTrue);
    expect(lib.entries.length, 1);
    expect(lib.entries.first.path, fixtureA);
    expect(lib.entries.first.pinned, isTrue,
        reason: 'manually added entries auto-pin (user just picked them)');
  });

  test('rescan dedupes by absolute path', () async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: [tempDir.path]);
    expect(lib.entries.length, 2);
    await lib.rescan(scanDirs: [tempDir.path]);
    expect(lib.entries.length, 2,
        reason: 'second scan must not duplicate existing entries');
  });

  test('boot does not compute health; refreshHealth populates it', () async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: [tempDir.path]);
    // boot must stay free of the sqflite health probe (so FakeAsync
    // widget tests that await boot() never block) — health is null until
    // refreshHealth runs (triggered by main.dart in the real app).
    expect(lib.entries.every((e) => e.health == null), isTrue);
    await lib.refreshHealth();
    expect(lib.entries.every((e) => e.health != null), isTrue);
  });

  test('refreshHealth preserves a pin toggled mid-probe', () async {
    // Single-DB dir so refreshHealth is provably probing THIS entry when
    // the pin toggle lands during its async db.open gap.
    final soloDir = await Directory.systemTemp.createTemp('studies_solo_');
    final solo = '${soloDir.path}/studies-solo.db'
        .replaceAll('/', Platform.pathSeparator);
    final db = await databaseFactory.openDatabase(solo);
    await db.execute('CREATE TABLE studies (id INTEGER PRIMARY KEY, '
        'name TEXT NOT NULL, strategy TEXT NOT NULL, '
        'search_space_yaml TEXT NOT NULL, created_at TEXT NOT NULL, '
        'commit_hash TEXT)');
    await db.execute('CREATE TABLE trials (id INTEGER PRIMARY KEY, '
        'study_id INTEGER NOT NULL, trial_id INTEGER NOT NULL, '
        'params_json TEXT NOT NULL, metrics_json TEXT NOT NULL, '
        'score REAL NOT NULL, created_at TEXT NOT NULL)');
    await db.close();

    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: [soloDir.path]);
    expect(lib.entries.single.pinned, isFalse);

    // Start the probe (it yields at the async db.open), pin while it is in
    // flight, then let it finish. A stale write-back would clobber the pin.
    final probe = lib.refreshHealth();
    await lib.togglePin(solo);
    await probe;

    expect(lib.entries.single.pinned, isTrue,
        reason: 'a pin toggled during the health probe must survive');
    expect(lib.entries.single.health, isNotNull,
        reason: 'health is still computed');

    // Persisted state must also keep the pin.
    final reloaded = await LibraryStorage().load();
    expect(reloaded.firstWhere((e) => e.path == solo).pinned, isTrue);

    await soloDir.delete(recursive: true);
  });

  test('missing file keeps entry but marks missing', () async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: [tempDir.path]);
    await File(fixtureA).delete();
    await lib.refreshHealth();
    final entry = lib.entries.firstWhere((e) => e.path == fixtureA);
    expect(lib.isMissing(entry), isTrue);
  });
}
