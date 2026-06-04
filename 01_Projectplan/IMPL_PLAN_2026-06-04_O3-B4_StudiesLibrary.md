# O3-B4 Studies Library Implementation Plan

> **For agentic workers:** Step-by-step companion to [PRE_TASK_2026-06-04_O3-B4_StudiesLibrary.md](PRE_TASK_2026-06-04_O3-B4_StudiesLibrary.md). Use checkbox (`- [ ]`) syntax for tracking. Executor = parallel-CC in WSL2/tmux.

**Goal:** Multi-DB Studies Library above the existing single-DB viewer — auto-scan `01_Projectplan/optimizer_studies/`, pin/unpin DBs, cross-study cross-DB Global Leaderboard filtered on `total_pnl > 0 AND total_trades >= min_trades`.

**Architecture:** Two new ChangeNotifier providers (`StudiesLibrary`, `AggregateLeaderboard`) wrap the existing `StudiesDb` read-only layer. `LibraryStorage` persists pin-state in `SharedPreferences`. UI adds three new widgets above the current per-study sections; per-study drill-down (O3-B2) stays untouched.

**Tech Stack:** Flutter 3.12+, `sqflite_common_ffi 2.4.1`, `provider 6.1.4`, `shared_preferences 2.2.0` (all already in `pubspec.yaml`).

**Spec deviations from PRE_TASK §10:**
- **Q2:** Switch from `path_provider`+JSON-file to `shared_preferences` (single `String` key with JSON-encoded value). Reason: zero new deps, Risk-Layer-precedent in Welle B4.3.

---

## File Structure

| File | Responsibility | Status |
|---|---|---|
| `lib/core/models/library_entry.dart` | `LibraryEntry`, `LibraryHealth` value objects + JSON codec | **new** |
| `lib/core/models/leaderboard_row.dart` | `LeaderboardRow` (Trial + strategy + studyName + dbPath) | **new** |
| `lib/services/studies_db.dart` | +`topNProfitable({...})` cross-study within one DB; +`healthSnapshot()` | modify |
| `lib/services/library_storage.dart` | `SharedPreferences`-backed pin-state persistence | **new** |
| `lib/features/studies/studies_library.dart` | Scan + pin/unpin Provider | **new** |
| `lib/features/studies/aggregate_leaderboard.dart` | Multi-DB merge + filter Provider | **new** |
| `lib/ui/widgets/library_panel.dart` | DB list, pin toggle, health dot | **new** |
| `lib/ui/widgets/leaderboard_filter_bar.dart` | `min_trades` slider, sort dropdown, top-N stepper | **new** |
| `lib/ui/widgets/global_leaderboard_table.dart` | Cross-DB DataTable + reuse of `_TrialDetailSheet` | **new** |
| `lib/ui/screens/studies_screen.dart` | Compose new sections above existing ones | modify |
| `lib/main.dart` | Wire two new providers into `MultiProvider` | modify |
| `test/core/models/library_entry_test.dart` | JSON roundtrip + edge cases | **new** |
| `test/services/library_storage_test.dart` | SharedPreferences roundtrip | **new** |
| `test/services/studies_db_test.dart` | +`topNProfitable` + `healthSnapshot` cases | modify |
| `test/features/studies/studies_library_test.dart` | Scan, pin, missing-file | **new** |
| `test/features/studies/aggregate_leaderboard_test.dart` | Merge, debounce, generation-counter | **new** |
| `test/ui/widgets/library_panel_test.dart` | States + interactions | **new** |
| `test/ui/widgets/global_leaderboard_table_test.dart` | Sort + click | **new** |
| `test/integration/studies_library_smoke_test.dart` | End-to-end with 2 fixture DBs | **new** |
| `test/fixtures/studies_fixture_library_a.db` | Ichimoku-like fixture (3 studies, mixed) | **new** generated |
| `test/fixtures/studies_fixture_library_b.db` | BB-RSI-like fixture (1 study, mixed) | **new** generated |
| `test/fixtures/studies_fixture_library_empty.db` | Empty studies DB | **new** generated |
| `tool/build_fixture_library.dart` | One-shot script that generates the three above | **new** |

---

## Task 1: Probe `json_extract` Availability

**Files:**
- Create: `tool/probe_json_extract.dart`

- [ ] **Step 1: Write probe script**

```dart
// tool/probe_json_extract.dart
// Run: dart run tool/probe_json_extract.dart
// Exits 0 if json_extract is available, 1 otherwise.
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = await databaseFactory.openDatabase(
    'test/fixtures/studies_fixture.db',
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
```

- [ ] **Step 2: Run probe**

Run: `dart run tool/probe_json_extract.dart`
Expected: either `json_extract OK: 1` (exit 0) or `json_extract MISSING: …` (exit 1).

- [ ] **Step 3: Document outcome**

Append result to top of [PRE_TASK_2026-06-04_O3-B4_StudiesLibrary.md](PRE_TASK_2026-06-04_O3-B4_StudiesLibrary.md) §4.1:
- If OK → use SQL path everywhere in Task 3.
- If MISSING → use Dart-fallback (load all trials of the DB, filter+sort in Dart). Add a note to Task 3 Step 4.

- [ ] **Step 4: Commit**

```bash
git add tool/probe_json_extract.dart 01_Projectplan/PRE_TASK_2026-06-04_O3-B4_StudiesLibrary.md
git commit -m "feat(O3-B4-1): probe json_extract availability + fallback plan"
git push
```

---

## Task 2: Models — `LibraryEntry`, `LibraryHealth`, `LeaderboardRow`

**Files:**
- Create: `lib/core/models/library_entry.dart`
- Create: `lib/core/models/leaderboard_row.dart`
- Create: `test/core/models/library_entry_test.dart`

- [ ] **Step 1: Write failing test for `LibraryEntry` JSON roundtrip**

```dart
// test/core/models/library_entry_test.dart
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
```

- [ ] **Step 2: Run test → expect compile failure**

Run: `flutter test test/core/models/library_entry_test.dart`
Expected: build error “library_entry.dart not found”.

- [ ] **Step 3: Implement `LibraryEntry` + `LibraryHealth`**

```dart
// lib/core/models/library_entry.dart
library;

class LibraryHealth {
  final int studyCount;
  final int profitableTrialCount;
  final int totalTrialCount;
  final int dbMtimeMs;

  const LibraryHealth({
    required this.studyCount,
    required this.profitableTrialCount,
    required this.totalTrialCount,
    required this.dbMtimeMs,
  });

  factory LibraryHealth.fromJson(Map<String, Object?> j) => LibraryHealth(
        studyCount: (j['studyCount'] as num?)?.toInt() ?? 0,
        profitableTrialCount:
            (j['profitableTrialCount'] as num?)?.toInt() ?? 0,
        totalTrialCount: (j['totalTrialCount'] as num?)?.toInt() ?? 0,
        dbMtimeMs: (j['dbMtimeMs'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
        'studyCount': studyCount,
        'profitableTrialCount': profitableTrialCount,
        'totalTrialCount': totalTrialCount,
        'dbMtimeMs': dbMtimeMs,
      };
}

class LibraryEntry {
  final String path;
  final bool pinned;
  final DateTime addedAt;
  final DateTime? lastScannedAt;
  final LibraryHealth? health;

  const LibraryEntry({
    required this.path,
    required this.pinned,
    required this.addedAt,
    this.lastScannedAt,
    this.health,
  });

  factory LibraryEntry.fromJson(Map<String, Object?> j) => LibraryEntry(
        path: j['path'] as String,
        pinned: j['pinned'] as bool? ?? false,
        addedAt: DateTime.parse(j['addedAt'] as String),
        lastScannedAt: j['lastScannedAt'] is String
            ? DateTime.parse(j['lastScannedAt'] as String)
            : null,
        health: j['health'] is Map
            ? LibraryHealth.fromJson(
                Map<String, Object?>.from(j['health'] as Map))
            : null,
      );

  Map<String, Object?> toJson() => {
        'path': path,
        'pinned': pinned,
        'addedAt': addedAt.toUtc().toIso8601String(),
        if (lastScannedAt != null)
          'lastScannedAt': lastScannedAt!.toUtc().toIso8601String(),
        if (health != null) 'health': health!.toJson(),
      };

  LibraryEntry copyWith({
    bool? pinned,
    DateTime? lastScannedAt,
    LibraryHealth? health,
  }) =>
      LibraryEntry(
        path: path,
        pinned: pinned ?? this.pinned,
        addedAt: addedAt,
        lastScannedAt: lastScannedAt ?? this.lastScannedAt,
        health: health ?? this.health,
      );
}
```

- [ ] **Step 4: Run tests → pass**

Run: `flutter test test/core/models/library_entry_test.dart`
Expected: 4 passing.

- [ ] **Step 5: Implement `LeaderboardRow`**

```dart
// lib/core/models/leaderboard_row.dart
library;

import 'trial.dart';

class LeaderboardRow {
  final Trial trial;
  final String strategy;
  final String studyName;
  final int studyDbId;
  final String dbPath;

  const LeaderboardRow({
    required this.trial,
    required this.strategy,
    required this.studyName,
    required this.studyDbId,
    required this.dbPath,
  });

  String get rowKey => '$dbPath#$studyDbId#${trial.trialId}';
}
```

No test for `LeaderboardRow` on its own — it’s a plain value carrier, covered by the aggregate provider tests in Task 6.

- [ ] **Step 6: Commit**

```bash
git add lib/core/models/library_entry.dart lib/core/models/leaderboard_row.dart \
        test/core/models/library_entry_test.dart
git commit -m "feat(O3-B4-2): library + leaderboard data models"
git push
```

---

## Task 3: `StudiesDb.topNProfitable` + `healthSnapshot`

**Files:**
- Modify: `lib/services/studies_db.dart`
- Modify: `test/services/studies_db_test.dart`

- [ ] **Step 1: Write failing tests**

Append to `test/services/studies_db_test.dart` inside the existing top-level `main()` after the `'querying before open throws StateError'` test:

```dart
    // ─── Welle O3-B4 — cross-study profitable filter ──────────────────────
    test('topNProfitable: filters total_pnl > 0 AND min_trades', () async {
      // Fixture has 5 valid trials; only trial 1 (totalPnl 120.5,
      // totalTrades 4) and trial 2 (totalPnl 280.0, totalTrades 8) are
      // profitable. Trial 5 is malformed (skipped).
      final all = await db.topNProfitable(minTrades: 0, limit: 50);
      expect(all.length, 2);
      expect(all.first.trial.metrics.totalPnl,
          greaterThan(all.last.trial.metrics.totalPnl));
      expect(all.every((r) => r.trial.metrics.totalPnl > 0), isTrue);
      // Strategy name is denormalized from studies row.
      expect(all.first.strategy, 'bb_rsi');
    });

    test('topNProfitable: min_trades cutoff drops low-sample trials',
        () async {
      // Both profitable trials have <10 trades. min_trades=10 → empty.
      final result = await db.topNProfitable(minTrades: 10, limit: 50);
      expect(result, isEmpty);
    });

    test('topNProfitable: respects limit', () async {
      final one = await db.topNProfitable(minTrades: 0, limit: 1);
      expect(one.length, 1);
    });

    test('topNProfitable: sortBy=pnl reorders by totalPnl desc', () async {
      final byPnl =
          await db.topNProfitable(minTrades: 0, limit: 50, sortBy: 'pnl');
      expect(byPnl.first.trial.metrics.totalPnl, 280.0);
      expect(byPnl.last.trial.metrics.totalPnl, 120.5);
    });

    test('healthSnapshot returns counts', () async {
      final h = await db.healthSnapshot();
      expect(h.studyCount, 1);
      expect(h.totalTrialCount, greaterThanOrEqualTo(5));
      expect(h.profitableTrialCount, 2);
    });
```

- [ ] **Step 2: Run tests → expect compile failure**

Run: `flutter test test/services/studies_db_test.dart`
Expected: build error “topNProfitable / healthSnapshot not defined”.

- [ ] **Step 3: Add `_HealthCounts` and `topNProfitable` to `StudiesDb`**

Add at the bottom of `lib/services/studies_db.dart` (before the closing `}` of the file’s last class, or at file end — keep one class block per concept):

```dart
// (Inside the StudiesDb class, after top10:)

/// Welle O3-B4: cross-study profitable trials within a single DB.
///
/// Filters on `total_pnl > 0` and `total_trades >= minTrades`, drops
/// `-inf` scores (defensive). `sortBy` ∈ {score, pnl, sharpe, pf,
/// trades, winRate}; defaults to `score`. Result rows are denormalized
/// with strategy + study name so the UI does not need a second JOIN.
///
/// If `json_extract` is missing in the bundled sqflite_common_ffi
/// (probed in Task 1), this falls back to client-side filtering — see
/// `_topNProfitableFallback`.
Future<List<LeaderboardRow>> topNProfitable({
  int minTrades = 20,
  int limit = 10,
  String sortBy = 'score',
}) async {
  final db = _require();
  if (_jsonExtractAvailable ?? true) {
    try {
      return await _topNProfitableSql(db,
          minTrades: minTrades, limit: limit, sortBy: sortBy);
    } on DatabaseException catch (e) {
      // json_extract missing — cache the negative result and fall back.
      AppLog.warn('StudiesDb',
          'json_extract unavailable, switching to client-side filter: $e');
      _jsonExtractAvailable = false;
    }
  }
  return _topNProfitableFallback(db,
      minTrades: minTrades, limit: limit, sortBy: sortBy);
}

bool? _jsonExtractAvailable;

static const Map<String, String> _sortColumnMap = {
  'score': 't.score',
  'pnl': "CAST(json_extract(t.metrics_json, '\$.total_pnl') AS REAL)",
  'sharpe': "CAST(json_extract(t.metrics_json, '\$.sharpe_ratio') AS REAL)",
  'pf': "CAST(json_extract(t.metrics_json, '\$.profit_factor') AS REAL)",
  'trades':
      "CAST(json_extract(t.metrics_json, '\$.total_trades') AS INTEGER)",
  'winRate': "CAST(json_extract(t.metrics_json, '\$.win_rate') AS REAL)",
};

Future<List<LeaderboardRow>> _topNProfitableSql(
  Database db, {
  required int minTrades,
  required int limit,
  required String sortBy,
}) async {
  final orderExpr = _sortColumnMap[sortBy] ?? 't.score';
  final rows = await db.rawQuery(
    'SELECT t.*, s.strategy AS _strategy, s.name AS _study_name '
    'FROM trials t JOIN studies s ON t.study_id = s.id '
    'WHERE t.score > -1e308 '
    "  AND CAST(json_extract(t.metrics_json, '\$.total_pnl') AS REAL) > 0 "
    "  AND CAST(json_extract(t.metrics_json, '\$.total_trades') AS INTEGER) >= ? "
    'ORDER BY $orderExpr DESC '
    'LIMIT ?',
    [minTrades, limit],
  );
  return _mapToLeaderboardRows(rows);
}

Future<List<LeaderboardRow>> _topNProfitableFallback(
  Database db, {
  required int minTrades,
  required int limit,
  required String sortBy,
}) async {
  // Client-side: join studies + trials, parse metrics in Dart, filter,
  // sort. O(total_trials_in_db) per call — acceptable for ≤10k trials.
  final rows = await db.rawQuery(
    'SELECT t.*, s.strategy AS _strategy, s.name AS _study_name '
    'FROM trials t JOIN studies s ON t.study_id = s.id '
    'WHERE t.score > -1e308',
  );
  final all = _mapToLeaderboardRows(rows)
      .where((r) =>
          r.trial.metrics.totalPnl > 0 &&
          r.trial.metrics.totalTrades >= minTrades)
      .toList();
  int cmp(LeaderboardRow a, LeaderboardRow b) {
    switch (sortBy) {
      case 'pnl':
        return b.trial.metrics.totalPnl.compareTo(a.trial.metrics.totalPnl);
      case 'sharpe':
        return b.trial.metrics.sharpeRatio
            .compareTo(a.trial.metrics.sharpeRatio);
      case 'pf':
        return b.trial.metrics.profitFactor
            .compareTo(a.trial.metrics.profitFactor);
      case 'trades':
        return b.trial.metrics.totalTrades
            .compareTo(a.trial.metrics.totalTrades);
      case 'winRate':
        return b.trial.metrics.winRate.compareTo(a.trial.metrics.winRate);
      case 'score':
      default:
        return b.trial.score.compareTo(a.trial.score);
    }
  }

  all.sort(cmp);
  return all.take(limit).toList();
}

List<LeaderboardRow> _mapToLeaderboardRows(
    List<Map<String, Object?>> rows) {
  final out = <LeaderboardRow>[];
  for (final row in rows) {
    try {
      final trial = Trial.fromRow(row);
      out.add(LeaderboardRow(
        trial: trial,
        strategy: row['_strategy'] as String,
        studyName: row['_study_name'] as String,
        studyDbId: trial.studyId,
        dbPath: _path ?? '',
      ));
    } catch (e, st) {
      AppLog.warn('StudiesDb',
          'Skipped malformed leaderboard row id=${row['id']}: $e', e, st);
    }
  }
  return out;
}

/// Welle O3-B4: lightweight counts for the Library health dot.
Future<LibraryHealth> healthSnapshot() async {
  final db = _require();
  final studyCountRow = await db.rawQuery('SELECT COUNT(*) AS c FROM studies');
  final totalRow = await db.rawQuery('SELECT COUNT(*) AS c FROM trials');
  // Use the same SQL/fallback split as topNProfitable for the
  // profitable count.
  int profitableCount;
  if (_jsonExtractAvailable ?? true) {
    try {
      final r = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM trials WHERE "
        "CAST(json_extract(metrics_json, '\$.total_pnl') AS REAL) > 0",
      );
      profitableCount = (r.first['c'] as num).toInt();
    } on DatabaseException {
      _jsonExtractAvailable = false;
      profitableCount = await _profitableCountFallback(db);
    }
  } else {
    profitableCount = await _profitableCountFallback(db);
  }
  return LibraryHealth(
    studyCount: (studyCountRow.first['c'] as num).toInt(),
    profitableTrialCount: profitableCount,
    totalTrialCount: (totalRow.first['c'] as num).toInt(),
    dbMtimeMs: 0,  // filled by StudiesLibrary, not by StudiesDb
  );
}

Future<int> _profitableCountFallback(Database db) async {
  final all = await db.rawQuery('SELECT metrics_json FROM trials');
  var count = 0;
  for (final row in all) {
    try {
      final metrics = TrialMetrics.fromJsonString(row['metrics_json'] as String);
      if (metrics.totalPnl > 0) count++;
    } catch (_) {/* skip */}
  }
  return count;
}
```

Also add imports at the top of `lib/services/studies_db.dart`:

```dart
import '../core/models/leaderboard_row.dart';
import '../core/models/library_entry.dart';
import '../core/models/trial_metrics.dart';
```

- [ ] **Step 4: Run all studies_db tests → pass**

Run: `flutter test test/services/studies_db_test.dart`
Expected: previous tests still green + 5 new tests passing.

- [ ] **Step 5: Commit**

```bash
git add lib/services/studies_db.dart test/services/studies_db_test.dart
git commit -m "feat(O3-B4-2.1): studies_db.topNProfitable + healthSnapshot"
git push
```

---

## Task 4: `LibraryStorage` (SharedPreferences-backed)

**Files:**
- Create: `lib/services/library_storage.dart`
- Create: `test/services/library_storage_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
// test/services/library_storage_test.dart
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
```

- [ ] **Step 2: Run → expect compile failure**

Run: `flutter test test/services/library_storage_test.dart`
Expected: build error “library_storage.dart not found”.

- [ ] **Step 3: Implement `LibraryStorage`**

```dart
// lib/services/library_storage.dart
/// Welle O3-B4: pin-state persistence for the Studies Library.
///
/// SharedPreferences-backed (single JSON-encoded String at the key
/// [_key]). Chose SharedPreferences over a file in AppSupport for
/// dep parity with Welle B4.3 (Risk Layer) and zero new packages.
///
/// Schema version is `1`; future schemas read the `version` field and
/// either migrate or reset (corrupt-JSON / unknown-version → empty
/// list + AppLog.warn — never crash).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/logging/app_log.dart';
import '../core/models/library_entry.dart';

class LibraryStorage {
  static const String _key = 'studies_library_v1';
  static const int _schemaVersion = 1;

  Future<List<LibraryEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        AppLog.warn('LibraryStorage',
            'Stored payload is not a JSON object — resetting.');
        return const [];
      }
      final version = (decoded['version'] as num?)?.toInt() ?? 0;
      if (version != _schemaVersion) {
        AppLog.warn('LibraryStorage',
            'Unknown schema version $version — resetting.');
        return const [];
      }
      final entries = decoded['entries'];
      if (entries is! List) return const [];
      final out = <LibraryEntry>[];
      for (final e in entries) {
        if (e is Map) {
          try {
            out.add(LibraryEntry.fromJson(Map<String, Object?>.from(e)));
          } catch (err, st) {
            AppLog.warn('LibraryStorage',
                'Skipped malformed entry: $err', err, st);
          }
        }
      }
      return out;
    } catch (e, st) {
      AppLog.warn('LibraryStorage',
          'Failed to decode library — resetting. $e', e, st);
      return const [];
    }
  }

  Future<void> save(List<LibraryEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode({
      'version': _schemaVersion,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
    await prefs.setString(_key, payload);
  }
}
```

- [ ] **Step 4: Run tests → pass**

Run: `flutter test test/services/library_storage_test.dart`
Expected: 5 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/services/library_storage.dart test/services/library_storage_test.dart
git commit -m "feat(O3-B4-3): studies_library SharedPreferences storage"
git push
```

---

## Task 5: `StudiesLibrary` Provider

**Files:**
- Create: `lib/features/studies/studies_library.dart`
- Create: `test/features/studies/studies_library_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
// test/features/studies/studies_library_test.dart
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
    fixtureA = '${tempDir.path}/studies-a.db';
    fixtureB = '${tempDir.path}/studies-b.db';
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
    final wrongPath = '${tempDir.path}/wrong.db';
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

  test('missing file keeps entry but marks missing', () async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: [tempDir.path]);
    await File(fixtureA).delete();
    await lib.refreshHealth();
    final entry = lib.entries.firstWhere((e) => e.path == fixtureA);
    expect(lib.isMissing(entry), isTrue);
  });
}
```

- [ ] **Step 2: Run → expect compile failure**

Run: `flutter test test/features/studies/studies_library_test.dart`
Expected: build error “studies_library.dart not found”.

- [ ] **Step 3: Implement `StudiesLibrary`**

```dart
// lib/features/studies/studies_library.dart
/// Welle O3-B4: pin/unpin + scan provider for the multi-DB Library.
///
/// The provider owns the canonical [LibraryEntry] list. Pin-state is
/// persisted via [LibraryStorage]; health-counts are recomputed
/// lazily by [refreshHealth] and cached on the entry.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/library_entry.dart';
import '../../services/library_storage.dart';
import '../../services/studies_db.dart';

class StudiesLibrary extends ChangeNotifier {
  final LibraryStorage _storage;
  StudiesLibrary({LibraryStorage? storage})
      : _storage = storage ?? LibraryStorage();

  final List<LibraryEntry> _entries = [];
  List<LibraryEntry> get entries => List.unmodifiable(_entries);

  bool _ready = false;
  bool get ready => _ready;

  bool isMissing(LibraryEntry e) => !File(e.path).existsSync();

  Future<void> boot({required List<String> scanDirs}) async {
    final fromDisk = await _storage.load();
    _entries
      ..clear()
      ..addAll(fromDisk);
    await _mergeScan(scanDirs);
    _ready = true;
    notifyListeners();
  }

  Future<void> rescan({required List<String> scanDirs}) async {
    await _mergeScan(scanDirs);
    notifyListeners();
  }

  Future<void> _mergeScan(List<String> scanDirs) async {
    final known = _entries.map((e) => e.path).toSet();
    for (final dirPath in scanDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        if (!f.path.endsWith('.db')) continue;
        final abs = f.absolute.path;
        if (known.contains(abs)) continue;
        _entries.add(LibraryEntry(
          path: abs,
          pinned: false,
          addedAt: DateTime.now().toUtc(),
        ));
        known.add(abs);
      }
    }
    await _storage.save(_entries);
  }

  Future<void> togglePin(String path) async {
    final i = _entries.indexWhere((e) => e.path == path);
    if (i < 0) return;
    _entries[i] = _entries[i].copyWith(pinned: !_entries[i].pinned);
    await _storage.save(_entries);
    notifyListeners();
  }

  Future<void> remove(String path) async {
    _entries.removeWhere((e) => e.path == path);
    await _storage.save(_entries);
    notifyListeners();
  }

  /// Returns false if the file is not an Optuna studies DB. On success
  /// the entry is added pinned (the user just deliberately picked it).
  Future<bool> addCustom(String path) async {
    final abs = File(path).absolute.path;
    if (_entries.any((e) => e.path == abs)) {
      // Already known — flip to pinned and return true.
      await togglePin(abs);
      return true;
    }
    final db = StudiesDb();
    try {
      await db.open(abs);
      await db.close();
    } on NotAStudiesDbException catch (e, st) {
      AppLog.warn('StudiesLibrary',
          'addCustom rejected $abs: ${e.message}', e, st);
      return false;
    }
    _entries.add(LibraryEntry(
      path: abs,
      pinned: true,
      addedAt: DateTime.now().toUtc(),
    ));
    await _storage.save(_entries);
    notifyListeners();
    return true;
  }

  Future<void> refreshHealth() async {
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      if (isMissing(e)) continue;
      final file = File(e.path);
      final mtimeMs = file.statSync().modified.millisecondsSinceEpoch;
      if (e.health != null && e.health!.dbMtimeMs == mtimeMs) continue;
      final db = StudiesDb();
      try {
        await db.open(e.path);
        final snapshot = await db.healthSnapshot();
        _entries[i] = e.copyWith(
          lastScannedAt: DateTime.now().toUtc(),
          health: LibraryHealth(
            studyCount: snapshot.studyCount,
            profitableTrialCount: snapshot.profitableTrialCount,
            totalTrialCount: snapshot.totalTrialCount,
            dbMtimeMs: mtimeMs,
          ),
        );
      } catch (err, st) {
        AppLog.warn('StudiesLibrary',
            'refreshHealth failed for ${e.path}: $err', err, st);
      } finally {
        await db.close();
      }
    }
    await _storage.save(_entries);
    notifyListeners();
  }
}
```

- [ ] **Step 4: Run tests → pass**

Run: `flutter test test/features/studies/studies_library_test.dart`
Expected: 6 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/features/studies/studies_library.dart \
        test/features/studies/studies_library_test.dart
git commit -m "feat(O3-B4-3.1): studies_library provider"
git push
```

---

## Task 6: `AggregateLeaderboard` Provider

**Files:**
- Create: `lib/features/studies/aggregate_leaderboard.dart`
- Create: `test/features/studies/aggregate_leaderboard_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
// test/features/studies/aggregate_leaderboard_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/features/studies/aggregate_leaderboard.dart';
import 'package:trading_app/features/studies/studies_library.dart';
import 'package:trading_app/services/library_storage.dart';

Future<void> _seedDb(String path,
    {required String strategy, required List<Map<String, num>> trials}) async {
  final db = await databaseFactory.openDatabase(path);
  await db.execute('CREATE TABLE studies (id INTEGER PRIMARY KEY, '
      'name TEXT NOT NULL, strategy TEXT NOT NULL, '
      'search_space_yaml TEXT NOT NULL, created_at TEXT NOT NULL, '
      'commit_hash TEXT)');
  await db.execute('CREATE TABLE trials (id INTEGER PRIMARY KEY, '
      'study_id INTEGER NOT NULL, trial_id INTEGER NOT NULL, '
      'params_json TEXT NOT NULL, metrics_json TEXT NOT NULL, '
      'score REAL NOT NULL, created_at TEXT NOT NULL)');
  await db.insert('studies', {
    'name': '${strategy}_fixture',
    'strategy': strategy,
    'search_space_yaml': 'strategy_name: $strategy',
    'created_at': '2026-06-04T00:00:00Z',
  });
  for (var i = 0; i < trials.length; i++) {
    final t = trials[i];
    final pnl = t['pnl']!.toDouble();
    final trades = t['trades']!.toInt();
    final score = t['score']!.toDouble();
    await db.insert('trials', {
      'study_id': 1,
      'trial_id': i,
      'params_json': '{"values":{"x":0.5}}',
      'metrics_json': jsonEncode({
        'total_trades': trades,
        'total_pnl': pnl,
        'win_rate': 50.0,
        'sharpe_ratio': 1.0,
        'max_drawdown_pct': 5.0,
        'profit_factor': 1.5,
        'final_equity': 1000.0 + pnl,
      }),
      'score': score,
      'created_at': '2026-06-04T00:00:00Z',
    });
  }
  await db.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  late Directory tempDir;
  late StudiesLibrary library;
  late String dbA;
  late String dbB;
  late String dbEmpty;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agg_lb_');
    dbA = '${tempDir.path}/studies-a.db';
    dbB = '${tempDir.path}/studies-b.db';
    dbEmpty = '${tempDir.path}/studies-empty.db';
    await _seedDb(dbA, strategy: 'ichimoku', trials: [
      {'pnl': 100, 'trades': 30, 'score': 1.5},
      {'pnl': -50, 'trades': 30, 'score': -0.8},
      {'pnl': 200, 'trades': 25, 'score': 2.1},
      {'pnl': 10, 'trades': 5, 'score': 0.3}, // below min_trades
    ]);
    await _seedDb(dbB, strategy: 'bb_rsi', trials: [
      {'pnl': 75, 'trades': 40, 'score': 1.2},
      {'pnl': -30, 'trades': 40, 'score': -0.5},
      {'pnl': 150, 'trades': 22, 'score': 1.9},
    ]);
    await _seedDb(dbEmpty, strategy: 'ut_bot', trials: const []);

    library = StudiesLibrary(storage: LibraryStorage());
    await library.boot(scanDirs: [tempDir.path]);
    // Pin all three so they participate.
    for (final p in [dbA, dbB, dbEmpty]) {
      await library.togglePin(p);
    }
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('merges profitable trials across pinned DBs, sorted by score',
      () async {
    final agg = AggregateLeaderboard(library: library);
    await agg.recompute();
    expect(agg.rows.length, 4,
        reason: '3 profitable in A (one filtered by min_trades) → 2; '
            '2 profitable in B → 2; empty → 0; total 4');
    // Best score wins: dbA pnl=200 score=2.1 → first.
    expect(agg.rows.first.trial.score, 2.1);
    expect(agg.rows.first.strategy, 'ichimoku');
    // Strategies must mix in the result.
    expect(agg.rows.any((r) => r.strategy == 'bb_rsi'), isTrue);
  });

  test('min_trades cutoff drops below-threshold rows', () async {
    final agg = AggregateLeaderboard(library: library);
    agg.minTrades = 30;
    await agg.recompute();
    // dbA: only 2 profitable with trades>=30; dbB: 0 with trades>=30; total 2.
    expect(agg.rows.length, 2);
    expect(agg.rows.every((r) => r.trial.metrics.totalTrades >= 30), isTrue);
  });

  test('unpinning a DB removes its rows on recompute', () async {
    final agg = AggregateLeaderboard(library: library);
    await agg.recompute();
    final before = agg.rows.length;
    await library.togglePin(dbA);
    await agg.recompute();
    expect(agg.rows.length, lessThan(before));
    expect(agg.rows.every((r) => r.dbPath != dbA), isTrue);
  });

  test('generation counter discards stale results', () async {
    final agg = AggregateLeaderboard(library: library);
    // Fire two recomputes back-to-back; only the latest result should
    // populate rows. We assert by changing min_trades between calls.
    final f1 = agg.recompute();
    agg.minTrades = 30;
    final f2 = agg.recompute();
    await Future.wait([f1, f2]);
    expect(agg.rows.every((r) => r.trial.metrics.totalTrades >= 30), isTrue);
  });

  test('broken DB does not break the others', () async {
    // Replace dbB with garbage bytes.
    await File(dbB).writeAsBytes(List<int>.filled(256, 0xFF));
    final agg = AggregateLeaderboard(library: library);
    await agg.recompute();
    // Only dbA contributes; dbB is logged as broken.
    expect(agg.rows.every((r) => r.dbPath == dbA), isTrue);
    expect(agg.rows, isNotEmpty);
  });

  test('limit caps the result set', () async {
    final agg = AggregateLeaderboard(library: library);
    agg.limit = 1;
    await agg.recompute();
    expect(agg.rows.length, 1);
  });

  test('sortBy=pnl reorders', () async {
    final agg = AggregateLeaderboard(library: library);
    agg.sortBy = 'pnl';
    await agg.recompute();
    expect(agg.rows.first.trial.metrics.totalPnl, 200);
  });
}
```

- [ ] **Step 2: Run → expect compile failure**

Run: `flutter test test/features/studies/aggregate_leaderboard_test.dart`
Expected: build error “aggregate_leaderboard.dart not found”.

- [ ] **Step 3: Implement `AggregateLeaderboard`**

```dart
// lib/features/studies/aggregate_leaderboard.dart
/// Welle O3-B4: Multi-DB profitable-trial leaderboard.
///
/// Reads from a [StudiesLibrary], opens each pinned (existing,
/// readable) DB sequentially, calls [StudiesDb.topNProfitable] with a
/// generous per-DB limit, merges, sorts globally, and truncates to
/// [limit]. Per-DB cap is `limit * 2` so a strategy with many high
/// scorers can still dominate the global slice — we trade slight
/// over-fetch for correctness near the boundary.
library;

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/leaderboard_row.dart';
import '../../services/studies_db.dart';
import 'studies_library.dart';

class AggregateLeaderboard extends ChangeNotifier {
  final StudiesLibrary library;
  AggregateLeaderboard({required this.library}) {
    library.addListener(_onLibraryChange);
  }

  int minTrades = 20;
  int limit = 10;
  String sortBy = 'score';

  List<LeaderboardRow> _rows = const [];
  List<LeaderboardRow> get rows => _rows;

  bool _loading = false;
  bool get loading => _loading;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  int _generation = 0;

  void _onLibraryChange() {
    // Library mutations (pin/unpin/refresh) trigger a recompute. Cheap
    // path — no debounce, the UI debounces user input upstream.
    unawaited(recompute());
  }

  Future<void> recompute() async {
    _loading = true;
    _errorMessage = null;
    notifyListeners();
    final gen = ++_generation;

    final pinned = library.entries
        .where((e) => e.pinned && !library.isMissing(e))
        .toList(growable: false);

    final merged = <LeaderboardRow>[];
    for (final entry in pinned) {
      if (gen != _generation) return;  // stale — drop result
      final db = StudiesDb();
      try {
        await db.open(entry.path);
        final batch = await db.topNProfitable(
          minTrades: minTrades,
          limit: limit * 2,
          sortBy: sortBy,
        );
        merged.addAll(batch);
      } catch (e, st) {
        AppLog.warn('AggregateLeaderboard',
            'Skipping ${entry.path}: $e', e, st);
      } finally {
        await db.close();
      }
    }

    if (gen != _generation) return;

    merged.sort(_comparatorFor(sortBy));
    _rows = merged.take(limit).toList(growable: false);
    _loading = false;
    notifyListeners();
  }

  int Function(LeaderboardRow, LeaderboardRow) _comparatorFor(String key) {
    switch (key) {
      case 'pnl':
        return (a, b) =>
            b.trial.metrics.totalPnl.compareTo(a.trial.metrics.totalPnl);
      case 'sharpe':
        return (a, b) => b.trial.metrics.sharpeRatio
            .compareTo(a.trial.metrics.sharpeRatio);
      case 'pf':
        return (a, b) =>
            b.trial.metrics.profitFactor.compareTo(a.trial.metrics.profitFactor);
      case 'trades':
        return (a, b) =>
            b.trial.metrics.totalTrades.compareTo(a.trial.metrics.totalTrades);
      case 'winRate':
        return (a, b) =>
            b.trial.metrics.winRate.compareTo(a.trial.metrics.winRate);
      case 'score':
      default:
        return (a, b) => b.trial.score.compareTo(a.trial.score);
    }
  }

  @override
  void dispose() {
    library.removeListener(_onLibraryChange);
    super.dispose();
  }
}

void unawaited(Future<void>? f) {}
```

- [ ] **Step 4: Run tests → pass**

Run: `flutter test test/features/studies/aggregate_leaderboard_test.dart`
Expected: 7 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/features/studies/aggregate_leaderboard.dart \
        test/features/studies/aggregate_leaderboard_test.dart
git commit -m "feat(O3-B4-4): aggregate_leaderboard provider"
git push
```

---

## Task 7: `LibraryPanel` Widget

**Files:**
- Create: `lib/ui/widgets/library_panel.dart`
- Create: `test/ui/widgets/library_panel_test.dart`

- [ ] **Step 1: Write failing widget test**

```dart
// test/ui/widgets/library_panel_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/features/studies/studies_library.dart';
import 'package:trading_app/services/library_storage.dart';
import 'package:trading_app/ui/widgets/library_panel.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

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
        await Directory.systemTemp.createTemp('library_panel_widget_');
    final dbPath = '${tempDir.path}/studies-x.db';
    final db = await databaseFactory.openDatabase(dbPath);
    await db.execute('CREATE TABLE studies (id INTEGER PRIMARY KEY)');
    await db.execute('CREATE TABLE trials (id INTEGER PRIMARY KEY)');
    await db.close();

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

    await tempDir.delete(recursive: true);
  });
}
```

- [ ] **Step 2: Run → expect compile failure**

Run: `flutter test test/ui/widgets/library_panel_test.dart`
Expected: build error “library_panel.dart not found”.

- [ ] **Step 3: Implement `LibraryPanel`**

```dart
// lib/ui/widgets/library_panel.dart
/// Welle O3-B4: Library Panel — lists known studies DBs with pin
/// toggle, health dot, missing-file marker, and a "Add custom .db"
/// button (file_picker).
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/library_entry.dart';
import '../../features/studies/studies_library.dart';
import '../themes/app_theme.dart';

class LibraryPanel extends StatelessWidget {
  const LibraryPanel({super.key});

  Future<void> _addCustom(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['db', 'sqlite', 'sqlite3'],
        dialogTitle: 'Add a studies .db to the library',
      );
      final path = result?.files.single.path;
      if (path == null) return;
      if (!context.mounted) return;
      final lib = context.read<StudiesLibrary>();
      final ok = await lib.addCustom(path);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Added to library'
            : 'Not an Optuna studies DB — entry not added'),
      ));
    } catch (e, st) {
      AppLog.error('LibraryPanel', 'addCustom failed: $e', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<StudiesLibrary>();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.library_books,
                  size: 18, color: AppColors.accentCyan),
              const SizedBox(width: 8),
              const Text('Studies library',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              ElevatedButton.icon(
                key: const Key('library-add-custom'),
                onPressed: () => _addCustom(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add custom .db'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentCyan,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (lib.entries.isEmpty)
            const Text('No studies databases yet',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12))
          else
            ...lib.entries.map((e) => _LibraryRow(entry: e, library: lib)),
        ],
      ),
    );
  }
}

class _LibraryRow extends StatelessWidget {
  final LibraryEntry entry;
  final StudiesLibrary library;
  const _LibraryRow({required this.entry, required this.library});

  Color get _healthColor {
    final h = entry.health;
    if (library.isMissing(entry)) return AppColors.bearRed;
    if (h == null || h.totalTrialCount == 0) return AppColors.textMuted;
    final ratio = h.profitableTrialCount / h.totalTrialCount;
    if (ratio >= 0.10) return AppColors.bullGreen;
    if (h.profitableTrialCount > 0) return Colors.amber;
    return AppColors.bearRed;
  }

  String get _displayName {
    final last = entry.path.split(RegExp(r'[\\/]')).last;
    return last;
  }

  @override
  Widget build(BuildContext context) {
    final h = entry.health;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              color: _healthColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_displayName,
                    style: const TextStyle(
                        color: AppColors.textPrimary, fontSize: 13)),
                Text(
                  library.isMissing(entry)
                      ? 'File missing'
                      : h == null
                          ? 'Not scanned yet'
                          : '${h.studyCount} studies · '
                              '${h.profitableTrialCount}/${h.totalTrialCount} '
                              'profitable',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            key: Key('library-pin-${entry.path}'),
            icon: Icon(
              entry.pinned
                  ? Icons.push_pin
                  : Icons.push_pin_outlined,
              color: entry.pinned ? AppColors.accentCyan : AppColors.textMuted,
              size: 18,
            ),
            tooltip: entry.pinned ? 'Unpin' : 'Pin',
            onPressed: () => library.togglePin(entry.path),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests → pass**

Run: `flutter test test/ui/widgets/library_panel_test.dart`
Expected: 2 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/widgets/library_panel.dart test/ui/widgets/library_panel_test.dart
git commit -m "feat(O3-B4-5a): library_panel widget"
git push
```

---

## Task 8: `LeaderboardFilterBar` Widget

**Files:**
- Create: `lib/ui/widgets/leaderboard_filter_bar.dart`
- Create: `test/ui/widgets/leaderboard_filter_bar_test.dart`

- [ ] **Step 1: Write failing widget test**

```dart
// test/ui/widgets/leaderboard_filter_bar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/features/studies/aggregate_leaderboard.dart';
import 'package:trading_app/features/studies/studies_library.dart';
import 'package:trading_app/services/library_storage.dart';
import 'package:trading_app/ui/widgets/leaderboard_filter_bar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders three controls with current values', (tester) async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: const []);
    final agg = AggregateLeaderboard(library: lib);
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: lib),
              ChangeNotifierProvider.value(value: agg),
            ],
            child: const LeaderboardFilterBar(),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('leaderboard-min-trades')), findsOneWidget);
    expect(find.byKey(const Key('leaderboard-sort')), findsOneWidget);
    expect(find.byKey(const Key('leaderboard-top-n')), findsOneWidget);
    expect(find.text('20'), findsOneWidget,
        reason: 'default min_trades label = 20');
  });

  testWidgets('sort dropdown change updates agg.sortBy + 1 recompute',
      (tester) async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: const []);
    final agg = _CountingAggregate(library: lib);
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: lib),
              ChangeNotifierProvider<AggregateLeaderboard>.value(value: agg),
            ],
            child: const LeaderboardFilterBar(),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('leaderboard-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PnL').last);
    await tester.pumpAndSettle();
    expect(agg.sortBy, 'pnl');
    expect(agg.recomputeCalls, 1,
        reason: 'a single dropdown change must trigger exactly one recompute');
  });

  testWidgets('slider drag fires recompute only on release (onChangeEnd)',
      (tester) async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: const []);
    final agg = _CountingAggregate(library: lib);
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: lib),
              ChangeNotifierProvider<AggregateLeaderboard>.value(value: agg),
            ],
            child: const LeaderboardFilterBar(),
          ),
        ),
      ),
    );
    // Drag the slider — simulate a press-drag-release gesture.
    final slider = find.byKey(const Key('leaderboard-min-trades'));
    final center = tester.getCenter(slider);
    await tester.dragFrom(center, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(agg.recomputeCalls, 1,
        reason: 'continuous drag must coalesce to a single recompute on release');
  });
}

class _CountingAggregate extends AggregateLeaderboard {
  int recomputeCalls = 0;
  _CountingAggregate({required super.library});

  @override
  Future<void> recompute() async {
    recomputeCalls++;
    notifyListeners();
  }
}
```

- [ ] **Step 2: Run → expect compile failure**

Run: `flutter test test/ui/widgets/leaderboard_filter_bar_test.dart`
Expected: build error “leaderboard_filter_bar.dart not found”.

- [ ] **Step 3: Implement `LeaderboardFilterBar`**

```dart
// lib/ui/widgets/leaderboard_filter_bar.dart
/// Welle O3-B4: tri-control bar for the Global Leaderboard.
///
/// Slider → minTrades, Dropdown → sortBy, Stepper → top-N. All three
/// call into [AggregateLeaderboard] which fires its own recompute.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/studies/aggregate_leaderboard.dart';
import '../themes/app_theme.dart';

class LeaderboardFilterBar extends StatelessWidget {
  const LeaderboardFilterBar({super.key});

  static const List<int> _minTradesSnap = [0, 5, 10, 20, 50, 100, 250, 500];
  static const List<int> _topNSnap = [5, 10, 20, 50, 100];

  static const Map<String, String> _sortLabels = {
    'score': 'Score',
    'pnl': 'PnL',
    'sharpe': 'Sharpe',
    'pf': 'Profit factor',
    'trades': 'Trades',
    'winRate': 'Win rate',
  };

  int _snap(int v, List<int> snaps) {
    return snaps.reduce((a, b) => (v - a).abs() < (v - b).abs() ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final agg = context.watch<AggregateLeaderboard>();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 280,
            child: Row(
              children: [
                const Text('Min trades:',
                    style: TextStyle(
                        color: AppColors.textMuted, fontSize: 12)),
                Expanded(
                  child: Slider(
                    key: const Key('leaderboard-min-trades'),
                    min: 0, max: 500, divisions: 100,
                    value: agg.minTrades.toDouble(),
                    label: '${agg.minTrades}',
                    onChanged: (v) {
                      agg.minTrades = _snap(v.round(), _minTradesSnap);
                    },
                    onChangeEnd: (_) => agg.recompute(),
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Text('${agg.minTrades}',
                      style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 12),
                      textAlign: TextAlign.right),
                ),
              ],
            ),
          ),
          Row(
            children: [
              const Text('Sort:',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(width: 8),
              DropdownButton<String>(
                key: const Key('leaderboard-sort'),
                value: agg.sortBy,
                dropdownColor: AppColors.surfaceElevated,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 12),
                items: _sortLabels.entries
                    .map((e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  agg.sortBy = v;
                  agg.recompute();
                },
              ),
            ],
          ),
          Row(
            children: [
              const Text('Top:',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              const SizedBox(width: 8),
              DropdownButton<int>(
                key: const Key('leaderboard-top-n'),
                value: _topNSnap.contains(agg.limit) ? agg.limit : 10,
                dropdownColor: AppColors.surfaceElevated,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 12),
                items: _topNSnap
                    .map((n) => DropdownMenuItem(
                          value: n,
                          child: Text('$n'),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  agg.limit = v;
                  agg.recompute();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests → pass**

Run: `flutter test test/ui/widgets/leaderboard_filter_bar_test.dart`
Expected: 3 passing.

- [ ] **Step 5: `flutter analyze` clean**

Run: `flutter analyze lib/ui/widgets/leaderboard_filter_bar.dart`
Expected: no issues.

- [ ] **Step 6: Commit**

```bash
git add lib/ui/widgets/leaderboard_filter_bar.dart \
        test/ui/widgets/leaderboard_filter_bar_test.dart
git commit -m "feat(O3-B4-5b): leaderboard_filter_bar widget + tests"
git push
```

---

## Task 9: `GlobalLeaderboardTable` Widget

**Files:**
- Create: `lib/ui/widgets/global_leaderboard_table.dart`
- Create: `test/ui/widgets/global_leaderboard_table_test.dart`

- [ ] **Step 1: Write failing widget test**

```dart
// test/ui/widgets/global_leaderboard_table_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/leaderboard_row.dart';
import 'package:trading_app/core/models/trial.dart';
import 'package:trading_app/core/models/trial_metrics.dart';
import 'package:trading_app/ui/widgets/global_leaderboard_table.dart';

LeaderboardRow _row({
  required int trialId,
  required String strategy,
  required double pnl,
  required double score,
}) =>
    LeaderboardRow(
      trial: Trial(
        id: trialId,
        studyId: 1,
        trialId: trialId,
        params: const {'x': 0.5},
        metrics: TrialMetrics(
          totalTrades: 30,
          totalPnl: pnl,
          winRate: 50.0,
          sharpeRatio: 1.0,
          maxDrawdownPct: 5.0,
          profitFactor: 1.5,
          finalEquity: 1000 + pnl,
        ),
        score: score,
        createdAt: DateTime.utc(2026, 6, 4),
      ),
      strategy: strategy,
      studyName: '${strategy}_study',
      studyDbId: 1,
      dbPath: '/x/$strategy.db',
    );

void main() {
  testWidgets('renders rows and empty hint when empty', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: GlobalLeaderboardTable(rows: const [])),
    ));
    expect(find.text('No profitable trials yet — pin some DBs above.'),
        findsOneWidget);
  });

  testWidgets('renders one row per LeaderboardRow', (tester) async {
    final rows = [
      _row(trialId: 1, strategy: 'ichimoku', pnl: 200, score: 2.1),
      _row(trialId: 2, strategy: 'bb_rsi', pnl: 100, score: 1.5),
    ];
    await tester.binding.setSurfaceSize(const Size(1600, 600));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: GlobalLeaderboardTable(rows: rows)),
    ));
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
    expect(find.text('ichimoku'), findsOneWidget);
    expect(find.text('bb_rsi'), findsOneWidget);
  });

  testWidgets('tap on row opens detail sheet', (tester) async {
    final rows = [
      _row(trialId: 7, strategy: 'ichimoku', pnl: 200, score: 2.1),
    ];
    await tester.binding.setSurfaceSize(const Size(1600, 800));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: GlobalLeaderboardTable(rows: rows)),
    ));
    await tester.tap(find.text('7'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Trial 7'), findsOneWidget);
    expect(find.text('Parameters'), findsOneWidget);
    expect(find.text('ichimoku_study'), findsOneWidget,
        reason: 'detail sheet shows the originating study name');
  });
}
```

- [ ] **Step 2: Run → expect compile failure**

Run: `flutter test test/ui/widgets/global_leaderboard_table_test.dart`
Expected: build error “global_leaderboard_table.dart not found”.

- [ ] **Step 3: Implement `GlobalLeaderboardTable`**

```dart
// lib/ui/widgets/global_leaderboard_table.dart
/// Welle O3-B4: cross-DB cross-study leaderboard table.
///
/// Layout mirrors `TrialsTop10Table` but adds Strategy + Study
/// columns at the front and opens a slightly richer detail sheet
/// (header carries strategy + study name + db file).
library;

import 'package:flutter/material.dart';

import '../../core/models/leaderboard_row.dart';
import '../themes/app_theme.dart';

class GlobalLeaderboardTable extends StatelessWidget {
  final List<LeaderboardRow> rows;
  const GlobalLeaderboardTable({super.key, required this.rows});

  String _fmtPnl(double v) =>
      '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';

  String _fmtPf(double v) => v.isFinite ? v.toStringAsFixed(2) : '∞';

  void _openDetail(BuildContext context, LeaderboardRow r) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceCard,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 720),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        builder: (_, scroll) => _GlobalDetailSheet(
          row: r,
          scrollController: scroll,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Text(
        'No profitable trials yet — pin some DBs above.',
        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        key: const Key('global-leaderboard-table'),
        headingRowColor: WidgetStateProperty.all(AppColors.surfaceElevated),
        dataRowMinHeight: 36,
        dataRowMaxHeight: 44,
        columns: const [
          DataColumn(label: Text('Rank')),
          DataColumn(label: Text('Strategy')),
          DataColumn(label: Text('Study')),
          DataColumn(label: Text('Trial'), numeric: true),
          DataColumn(label: Text('Score'), numeric: true),
          DataColumn(label: Text('PnL'), numeric: true),
          DataColumn(label: Text('Trades'), numeric: true),
          DataColumn(label: Text('Win %'), numeric: true),
          DataColumn(label: Text('Sharpe'), numeric: true),
          DataColumn(label: Text('Max DD %'), numeric: true),
          DataColumn(label: Text('PF'), numeric: true),
        ],
        rows: [
          for (var i = 0; i < rows.length; i++)
            DataRow(
              key: ValueKey(rows[i].rowKey),
              onSelectChanged: (_) => _openDetail(context, rows[i]),
              cells: _cells(i, rows[i]),
            ),
        ],
      ),
    );
  }

  List<DataCell> _cells(int displayIdx, LeaderboardRow r) {
    final m = r.trial.metrics;
    return [
      DataCell(Text('#${displayIdx + 1}',
          style: const TextStyle(color: AppColors.accentCyan, fontSize: 12))),
      DataCell(Text(r.strategy,
          style: const TextStyle(
              color: AppColors.accentPurple, fontSize: 12))),
      DataCell(SizedBox(
        width: 200,
        child: Text(r.studyName,
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(color: AppColors.textPrimary, fontSize: 12)),
      )),
      DataCell(Text('${r.trial.trialId}',
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text(r.trial.score.toStringAsFixed(3),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text(_fmtPnl(m.totalPnl),
          style: TextStyle(
              color: m.totalPnl >= 0
                  ? AppColors.bullGreen
                  : AppColors.bearRed,
              fontSize: 12))),
      DataCell(Text('${m.totalTrades}',
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text('${m.winRate.toStringAsFixed(1)}%',
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text(m.sharpeRatio.toStringAsFixed(2),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
      DataCell(Text('${m.maxDrawdownPct.toStringAsFixed(2)}%',
          style: const TextStyle(color: AppColors.bearRed, fontSize: 12))),
      DataCell(Text(_fmtPf(m.profitFactor),
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12))),
    ];
  }
}

class _GlobalDetailSheet extends StatelessWidget {
  final LeaderboardRow row;
  final ScrollController? scrollController;

  const _GlobalDetailSheet({required this.row, this.scrollController});

  @override
  Widget build(BuildContext context) {
    final params = row.trial.params.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      children: [
        Center(
          child: Container(
            key: const Key('global-detail-drag-handle'),
            width: 40, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Wrap(
          spacing: 12, runSpacing: 6,
          children: [
            _badge('Trial ${row.trial.trialId}', AppColors.accentCyan),
            _badge(row.strategy, AppColors.accentPurple),
            Text(row.studyName,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 8),
        Text(row.dbPath,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 16),
        const Text('Parameters',
            style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
        const SizedBox(height: 6),
        for (final e in params) _kv(e.key, e.value.toString()),
        const SizedBox(height: 14),
        const Text('Metrics',
            style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
        const SizedBox(height: 6),
        _kv('total_trades', '${row.trial.metrics.totalTrades}'),
        _kv('total_pnl', row.trial.metrics.totalPnl.toStringAsFixed(4)),
        _kv('win_rate', '${row.trial.metrics.winRate.toStringAsFixed(2)}%'),
        _kv('sharpe_ratio', row.trial.metrics.sharpeRatio.toStringAsFixed(4)),
        _kv('max_drawdown_pct',
            '${row.trial.metrics.maxDrawdownPct.toStringAsFixed(2)}%'),
        _kv(
            'profit_factor',
            row.trial.metrics.profitFactor.isFinite
                ? row.trial.metrics.profitFactor.toStringAsFixed(4)
                : '∞'),
        _kv('final_equity',
            row.trial.metrics.finalEquity.toStringAsFixed(2)),
      ],
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withAlpha(40),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 160,
              child: Text(k,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontFamily: 'monospace')),
            ),
          ],
        ),
      );
}
```

- [ ] **Step 4: Run tests → pass**

Run: `flutter test test/ui/widgets/global_leaderboard_table_test.dart`
Expected: 3 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/widgets/global_leaderboard_table.dart \
        test/ui/widgets/global_leaderboard_table_test.dart
git commit -m "feat(O3-B4-5c): global_leaderboard_table widget"
git push
```

---

## Task 10: Compose into `StudiesScreen` + Wire `main.dart`

**Files:**
- Modify: `lib/ui/screens/studies_screen.dart`
- Modify: `lib/main.dart`

- [ ] **Step 1: Wire providers in `main.dart`**

Replace the `MultiProvider` providers list ([main.dart:46-66](lib/main.dart#L46)) with:

```dart
providers: [
  ChangeNotifierProvider(create: (_) => BacktestProvider()),
  ChangeNotifierProvider(create: (_) => StudiesProvider()),
  // Welle O3-B4: Library + AggregateLeaderboard. Library boots in
  // its constructor (scan + persistent pin-state).
  ChangeNotifierProvider(
    create: (_) => StudiesLibrary()
      ..boot(scanDirs: const ['01_Projectplan/optimizer_studies']),
  ),
  ChangeNotifierProxyProvider<StudiesLibrary, AggregateLeaderboard>(
    create: (ctx) =>
        AggregateLeaderboard(library: ctx.read<StudiesLibrary>()),
    update: (_, lib, prev) => prev ?? AggregateLeaderboard(library: lib),
  ),
  ChangeNotifierProvider(create: (_) => ChartProvider()),
  ChangeNotifierProvider(create: (_) => RiskManager()..loadConfig()),
  ChangeNotifierProvider(
    create: (ctx) => PaperTradingProvider(
      riskManager: ctx.read<RiskManager>(),
    ),
  ),
  ChangeNotifierProvider(
    create: (_) => BitunixConnectionProvider()..loadStoredCredentials(),
  ),
  ChangeNotifierProvider(create: (_) => AppNavigation()),
  ChangeNotifierProvider<AppLogStore>.value(value: AppLog.instance),
],
```

Add imports at the top of `main.dart`:

```dart
import 'features/studies/aggregate_leaderboard.dart';
import 'features/studies/studies_library.dart';
```

- [ ] **Step 2: Compose into `StudiesScreen`**

Replace the `_StudiesBody` build method in `lib/ui/screens/studies_screen.dart` ([studies_screen.dart:67-83](lib/ui/screens/studies_screen.dart#L67)) with:

```dart
@override
Widget build(BuildContext context) {
  return SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Welle O3-B4: Library + Global Leaderboard above the
        // existing single-DB picker + per-study sections.
        const LibraryPanel(),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Row(
                children: [
                  Icon(Icons.emoji_events,
                      size: 18, color: AppColors.accentCyan),
                  SizedBox(width: 8),
                  Text('Global leaderboard',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              SizedBox(height: 12),
              LeaderboardFilterBar(),
              SizedBox(height: 12),
              _GlobalLeaderboardConsumer(),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Divider(color: AppColors.divider),
        const SizedBox(height: 16),
        const Text('Per-study drill-down',
            style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5)),
        const SizedBox(height: 12),
        _PickerSection(provider: provider),
        const SizedBox(height: 16),
        _Top10Placeholder(provider: provider),
        const SizedBox(height: 16),
        _ConvergencePlaceholder(provider: provider),
      ],
    ),
  );
}
```

Add this class at the bottom of `studies_screen.dart`:

```dart
class _GlobalLeaderboardConsumer extends StatelessWidget {
  const _GlobalLeaderboardConsumer();

  @override
  Widget build(BuildContext context) {
    final agg = context.watch<AggregateLeaderboard>();
    if (agg.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return GlobalLeaderboardTable(rows: agg.rows);
  }
}
```

Add imports at the top of `studies_screen.dart`:

```dart
import '../../features/studies/aggregate_leaderboard.dart';
import '../widgets/global_leaderboard_table.dart';
import '../widgets/leaderboard_filter_bar.dart';
import '../widgets/library_panel.dart';
```

- [ ] **Step 3: `flutter analyze` clean**

Run: `flutter analyze`
Expected: 0 issues.

- [ ] **Step 4: Run existing studies tests (regression guard)**

Run: `flutter test test/services/studies_db_test.dart test/features/studies/studies_provider_test.dart test/ui/screens/studies_screen_test.dart test/integration/studies_viewer_smoke_test.dart`
Expected: all previously-green tests stay green.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart lib/ui/screens/studies_screen.dart
git commit -m "feat(O3-B4-5.1): studies_screen composes library + leaderboard"
git push
```

---

## Task 11: Integration Smoke Test

**Files:**
- Create: `tool/build_fixture_library.dart`
- Create: `test/fixtures/studies_fixture_library_a.db` (generated)
- Create: `test/fixtures/studies_fixture_library_b.db` (generated)
- Create: `test/fixtures/studies_fixture_library_empty.db` (generated)
- Create: `test/integration/studies_library_smoke_test.dart`

- [ ] **Step 1: Build fixture-generator script**

```dart
// tool/build_fixture_library.dart
// Run: dart run tool/build_fixture_library.dart
// Emits 3 fixture .db files into test/fixtures/.
import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _make(String path,
    {required String strategy,
    required List<Map<String, num>> trials}) async {
  if (File(path).existsSync()) await File(path).delete();
  final db = await databaseFactory.openDatabase(path);
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
```

- [ ] **Step 2: Generate the fixtures**

Run: `dart run tool/build_fixture_library.dart`
Expected: stdout “Fixture library DBs written.”; three new files under `test/fixtures/`.

- [ ] **Step 3: Write integration smoke test**

```dart
// test/integration/studies_library_smoke_test.dart
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
    // 2 DBs (and not the rest of test/fixtures/).
    final tempDir =
        await Directory.systemTemp.createTemp('lib_smoke_');
    await File(fixA).copy('${tempDir.path}/studies-a.db');
    await File(fixB).copy('${tempDir.path}/studies-b.db');

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
    await tester.runAsync(() => agg.recompute());
    await tester.pump();

    // Leaderboard now has rows; best score 2.1 from ichimoku.
    expect(find.byKey(const Key('global-leaderboard-table')),
        findsOneWidget);
    expect(find.text('ichimoku'), findsAtLeast(1));
    expect(find.text('bb_rsi'), findsAtLeast(1));
    expect(find.text('#1'), findsOneWidget);

    // Drill-down: click a leaderboard row → detail sheet shows the
    // study name from the originating DB.
    await tester.tap(find.text('#1'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Parameters'), findsOneWidget);
    expect(find.text('Metrics'), findsOneWidget);

    await tempDir.delete(recursive: true);
    provider.dispose();
    agg.dispose();
    library.dispose();
  });
}
```

- [ ] **Step 4: Run smoke test + existing smoke test (regression)**

Run: `flutter test test/integration/studies_library_smoke_test.dart test/integration/studies_viewer_smoke_test.dart`
Expected: both green.

- [ ] **Step 5: Full test suite**

Run: `flutter test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add tool/build_fixture_library.dart test/fixtures/studies_fixture_library_*.db \
        test/integration/studies_library_smoke_test.dart
git commit -m "test(O3-B4-6): integration smoke test for studies library"
git push
```

---

## Task 12: Manual UAT + Phase-1-Reference-Backtest Guard

**Files:** none (manual verification + report)

- [ ] **Step 1: Rebuild Rust binary (Memory `project_build_gotchas`)**

Run: `bash tool/build_rust.sh release`
Expected: rust-binary refreshed under the target dir.

- [ ] **Step 2: Run Phase-1-Reference-Backtest**

Run the regression backtest the repo provides (the canonical 91-trade fixture run). Reference: Memory `project_regression_guards` — expected `91 trades, -2071.38 USDT`. Any drift = STOP.

- [ ] **Step 3: Launch app (`flutter run -d windows`)**

- [ ] **Step 4: UAT walkthrough (12 checks from PRE_TASK §7)**

| # | Check | OK? |
|---|---|---|
| 1 | Studies-Tab open → Library lists optimizer_studies dir, ruvector.db + stat_gates_results.db marked “Not a studies DB”, no crash | ☐ |
| 2 | All entries start un-pinned | ☐ |
| 3 | Pin Ichimoku-WF + BB-RSI → leaderboard mixes both strategies | ☐ |
| 4 | min_trades=20 → low-sample trials gone from leaderboard, still in per-study drill-down | ☐ |
| 5 | Sort PnL → reorder + rank update | ☐ |
| 6 | Click leaderboard row → detail sheet shows strategy + study + trial | ☐ |
| 7 | Click library row → per-study drill-down loads | ☐ |
| 8 | Delete a pinned DB on disk → click Reload → entry marked Missing, others still render | ☐ |
| 9 | Add custom .db → ruvector.db → toast “Not an Optuna studies DB”, NOT stored | ☐ |
| 10 | Manually corrupt SharedPreferences entry, restart → empty Library + AppLog warn + auto-rescan | ☐ |
| 11 | Existing manual “Pick .db” flow + `studies_viewer_smoke_test.dart` green | ☐ |
| 12 | Phase-1-Reference-Backtest still 91 trades / -2071.38 USDT | ☐ |

- [ ] **Step 5: Write POST_TASK report**

Write `01_Projectplan/POST_TASK_2026-06-04_O3-B4_StudiesLibrary.md` listing: scope delivered, UAT result (12-row table), commits shipped, deviations from PRE_TASK (Q2 storage switch), notes for next welle.

- [ ] **Step 6: Commit + push**

```bash
git add 01_Projectplan/POST_TASK_2026-06-04_O3-B4_StudiesLibrary.md
git commit -m "chore(O3-B4-7): UAT pass + post-task report"
git push
```

---

## Sign-Off Checklist (QA-Koordinator)

- [ ] Subtasks 1–12 atomic committed + pushed (12 commits expected)
- [ ] `flutter analyze` clean
- [ ] `flutter test` fully green (incl. all new + existing studies/integration tests)
- [ ] Bestehender `studies_viewer_smoke_test.dart` grün (no regression)
- [ ] Phase-1-Reference-Backtest unverändert (91 Trades, -2071.38 USDT)
- [ ] UAT-Punkte 1–12 manuell abgehakt
- [ ] POST_TASK-Report committed
