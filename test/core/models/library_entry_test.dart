import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/library_entry.dart';

void main() {
  group('LibraryEntry', () {
    test('JSON roundtrip preserves fields', () {
      final entry = LibraryEntry(
        path: '/abs/path/studies-foo.db',
        pinned: true,
        addedAt: DateTime.utc(2026, 6, 4, 10, 32),
        lastScannedAt: DateTime.utc(2026, 6, 4, 10, 35),
        health: const LibraryHealth(
          studyCount: 3,
          profitableTrialCount: 47,
          totalTrialCount: 1000,
          dbMtimeMs: 1748460000000,
        ),
      );
      final back = LibraryEntry.fromJson(entry.toJson());
      expect(back.path, entry.path);
      expect(back.pinned, isTrue);
      expect(back.addedAt, entry.addedAt);
      expect(back.lastScannedAt, entry.lastScannedAt);
      expect(back.health?.profitableTrialCount, 47);
      expect(back.health?.dbMtimeMs, 1748460000000);
    });

    test('fromJson tolerates missing optional fields', () {
      final json = {
        'path': '/abs/path/studies-foo.db',
        'pinned': false,
        'addedAt': '2026-06-04T10:32:00.000Z',
      };
      final entry = LibraryEntry.fromJson(json);
      expect(entry.lastScannedAt, isNull);
      expect(entry.health, isNull);
    });

    test('fromJson tolerates unknown forward-compat fields', () {
      final json = {
        'path': '/abs/path/studies-foo.db',
        'pinned': true,
        'addedAt': '2026-06-04T10:32:00.000Z',
        'futureField': 'ignored',
      };
      expect(() => LibraryEntry.fromJson(json), returnsNormally);
    });

    test('copyWith updates exactly one field', () {
      final entry = LibraryEntry(
        path: '/x.db',
        pinned: false,
        addedAt: DateTime.utc(2026, 6, 4),
      );
      final pinned = entry.copyWith(pinned: true);
      expect(pinned.pinned, isTrue);
      expect(pinned.path, entry.path);
      expect(pinned.addedAt, entry.addedAt);
    });
  });
}
