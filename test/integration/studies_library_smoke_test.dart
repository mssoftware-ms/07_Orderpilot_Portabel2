/// Welle O3-B4: end-to-end smoke test for the multi-DB Studies Library.
///
/// Boots a library over a temp dir holding two real fixture DBs, pins
/// both via the UI, and asserts the global leaderboard merges profitable
/// trials across strategies and opens a detail sheet on row tap.
///
/// FakeAsync note: testWidgets runs in a fake-async zone where real async
/// I/O never completes. So fixture setup uses *synchronous* file I/O
/// (createTempSync / copySync / deleteSync), and the sqflite-backed
/// recompute is driven through tester.runAsync so the FFI isolate can
/// talk over the real event loop.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/features/studies/aggregate_leaderboard.dart';
import 'package:trading_app/features/studies/studies_library.dart';
import 'package:trading_app/features/studies/studies_provider.dart';
import 'package:trading_app/services/library_storage.dart';
import 'package:trading_app/ui/screens/studies_screen.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'boot → library scans fixtures → pin both DBs → global leaderboard '
      'merges profitable trials across strategies',
      (tester) async {
    final fixA =
        File('test/fixtures/studies_fixture_library_a.db').absolute.path;
    final fixB =
        File('test/fixtures/studies_fixture_library_b.db').absolute.path;

    // Build the fixture dir on the fly so the scan picks up exactly our
    // 2 DBs (and not the rest of test/fixtures/). Synchronous I/O only.
    final tempDir = Directory.systemTemp.createTempSync('lib_smoke_');
    File(fixA).copySync('${tempDir.path}/studies-a.db');
    File(fixB).copySync('${tempDir.path}/studies-b.db');

    final library = StudiesLibrary(storage: LibraryStorage());
    await library.boot(scanDirs: [tempDir.path]);
    expect(library.entries.length, 2);

    final agg = AggregateLeaderboard(library: library);
    final provider = StudiesProvider();

    await tester.binding.setSurfaceSize(const Size(1600, 1800));
    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: agg),
            ChangeNotifierProvider.value(value: provider),
          ],
          child: const StudiesScreen(),
        ),
      ),
    );
    await tester.pump();

    // Empty leaderboard until something is pinned.
    expect(find.text('No profitable trials yet — pin some DBs above.'),
        findsOneWidget);

    // Pin both DBs by tapping their pin icons.
    for (final e in library.entries) {
      await tester.tap(find.byKey(Key('library-pin-${e.path}')));
      await tester.pump();
    }
    // Drive the sqflite-backed recompute through the real event loop.
    await tester.runAsync(() => agg.recompute());
    await tester.pump();

    // Leaderboard now has rows; best score 2.1 from ichimoku.
    expect(find.byKey(const Key('global-leaderboard-table')), findsOneWidget);
    expect(find.text('ichimoku'), findsAtLeast(1));
    expect(find.text('bb_rsi'), findsAtLeast(1));
    expect(find.text('#1'), findsOneWidget);

    // Drill-down: click a leaderboard row → detail sheet shows the
    // study name from the originating DB.
    await tester.tap(find.text('#1'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Parameters'), findsOneWidget);
    expect(find.text('Metrics'), findsOneWidget);

    tempDir.deleteSync(recursive: true);
    provider.dispose();
    agg.dispose();
    library.dispose();
  });
}
