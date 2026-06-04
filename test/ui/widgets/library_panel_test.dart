import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/features/studies/studies_library.dart';
import 'package:trading_app/services/library_storage.dart';
import 'package:trading_app/ui/widgets/library_panel.dart';

// NOTE: these are testWidgets (FakeAsync zone). SharedPreferences with
// setMockInitialValues resolves via microtask and is safe here, but real
// async I/O (Directory.createTemp, sqflite openDatabase) never completes
// under FakeAsync — so the fixtures use *synchronous* file I/O only. The
// library scan only lists `*.db` files, so an empty placeholder file is
// enough; no real SQLite database is needed.
void main() {
  testWidgets('renders empty state with Scan button when no entries',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: const []);
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider.value(
          value: lib,
          child: const Scaffold(body: LibraryPanel()),
        ),
      ),
    );
    expect(find.text('No studies databases yet'), findsOneWidget);
    expect(find.byKey(const Key('library-add-custom')), findsOneWidget);
  });

  testWidgets('toggles pin via key', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final tempDir =
        Directory.systemTemp.createTempSync('library_panel_widget_');
    final dbPath = '${tempDir.path}/studies-x.db';
    File(dbPath).createSync(recursive: true);

    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: [tempDir.path]);

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider.value(
          value: lib,
          child: const Scaffold(body: LibraryPanel()),
        ),
      ),
    );
    expect(lib.entries.first.pinned, isFalse);
    await tester.tap(find.byKey(Key('library-pin-$dbPath')));
    await tester.pump();
    expect(lib.entries.first.pinned, isTrue);

    tempDir.deleteSync(recursive: true);
  });
}
