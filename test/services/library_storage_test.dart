import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/core/models/library_entry.dart';
import 'package:trading_app/services/library_storage.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load returns empty list when key absent', () async {
    final storage = LibraryStorage();
    final entries = await storage.load();
    expect(entries, isEmpty);
  });

  test('save then load roundtrips entries (incl. health)', () async {
    final storage = LibraryStorage();
    final original = [
      LibraryEntry(
        path: '/abs/a.db',
        pinned: true,
        addedAt: DateTime.utc(2026, 6, 4),
        health: const LibraryHealth(
          studyCount: 1,
          profitableTrialCount: 5,
          totalTrialCount: 10,
          dbMtimeMs: 1234567890000,
        ),
      ),
      LibraryEntry(
        path: '/abs/b.db',
        pinned: false,
        addedAt: DateTime.utc(2026, 6, 4),
      ),
    ];
    await storage.save(original);
    final back = await storage.load();
    expect(back.length, 2);
    expect(back.first.path, '/abs/a.db');
    expect(back.first.pinned, isTrue);
    expect(back.first.health?.profitableTrialCount, 5);
    expect(back.last.pinned, isFalse);
  });

  test('corrupt JSON resets to empty', () async {
    SharedPreferences.setMockInitialValues({
      'studies_library_v1': '{not valid json',
    });
    final storage = LibraryStorage();
    final entries = await storage.load();
    expect(entries, isEmpty);
  });

  test('unknown version resets to empty', () async {
    SharedPreferences.setMockInitialValues({
      'studies_library_v1': jsonEncode({'version': 99, 'entries': []}),
    });
    final storage = LibraryStorage();
    final entries = await storage.load();
    expect(entries, isEmpty);
  });

  test('forward-compat: unknown top-level fields ignored', () async {
    final payload = jsonEncode({
      'version': 1,
      'entries': [
        {
          'path': '/abs/x.db',
          'pinned': true,
          'addedAt': '2026-06-04T00:00:00.000Z',
          'futureMeta': 'tolerated',
        },
      ],
      'unknownTopLevel': 42,
    });
    SharedPreferences.setMockInitialValues({'studies_library_v1': payload});
    final storage = LibraryStorage();
    final entries = await storage.load();
    expect(entries.length, 1);
    expect(entries.first.path, '/abs/x.db');
  });
}
