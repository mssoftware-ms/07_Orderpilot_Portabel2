// tool/probe_json_extract.dart
// Run: dart run tool/probe_json_extract.dart
// Exits 0 if json_extract is available, 1 otherwise.
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final fixturePath =
      File('test/fixtures/studies_fixture.db').absolute.path;
  final db = await databaseFactory.openDatabase(
    fixturePath,
    options: OpenDatabaseOptions(readOnly: true),
  );
  try {
    final rows = await db.rawQuery(
      "SELECT json_extract('{\"a\":1}', '\$.a') AS v",
    );
    stdout.writeln('json_extract OK: ${rows.first['v']}');
    exitCode = 0;
  } catch (e) {
    stderr.writeln('json_extract MISSING: $e');
    exitCode = 1;
  } finally {
    await db.close();
  }
}
