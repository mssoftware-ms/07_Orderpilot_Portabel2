# Pre-Task Welle O3-B4 — Studies Library (Multi-DB-Leaderboard)

**Issued:** 2026-06-04 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem grünen Commit
**Base:** `8445586` (origin/main, inkl. O3-B2 Studies-Viewer + O3-B2.1 Picker-UX + O3-B3 StrategyMgmt + P4P-* Bitunix + P4C-H-3 Chart-Axis)

---

## 0. Motivation (User-Pain)

Heute zeigt der Studies-Screen genau **eine Study** pro `.db` auf einmal. Cross-Strategie-Vergleich (Ichimoku vs. BB-RSI vs. UT-Bot) erfordert n Pick-`.db`-Klicks und mentales Merging. Top-10 enthält außerdem unprofitable Trials, weil der bestehende Filter nur `-inf`-Scores wirft, nicht negativen PnL.

**Konkret aus User-Feedback 2026-06-04:**
> „So ist das ein bisschen unübersichtlich und auch nicht gut strukturiert. […] Es sollten direkt übersichtlich alle Strategien angezeigt werden, deren Runs positiv sind, und davon die Top 10."

---

## 1. Scope

Studies-Screen bekommt eine **Library-Schicht**: Multi-DB-Auto-Scan + Pinning, Global-Leaderboard über alle gepinnten DBs × alle Studies, gefiltert auf **profitable Trials mit Mindest-Trade-Count**. Per-Study-Drill-Down (bestehendes O3-B2-Verhalten) bleibt erhalten.

**Out-of-scope** (für spätere Wellen):
- DB-Schreiben aus der App heraus (Optimierungsläufe bleiben CLI-only)
- Cross-DB Convergence-Plot (eigene Welle)
- Live-Stream-Update während Optimizer-CLI schreibt (manueller Reload bleibt)
- Custom Re-Scoring in UI (Score-Definition kommt aus DB wie sie ist)
- `ruvector.db` / `stat_gates_results.db` Integration (anderes Schema)

---

## 2. Kontext (Engine + Daten)

### Bestehendes Datenmodell (read-only mirror, unverändert)

```
studies (id, name, strategy, search_space_yaml, created_at, commit_hash?)
trials  (id, study_id, trial_id, params_json, metrics_json, score, created_at)
metrics_json: {total_trades, total_pnl, win_rate, sharpe_ratio,
               max_drawdown_pct, profit_factor, final_equity}
```

### Bestehende Codebasis (Wiederverwendung)

- `lib/services/studies_db.dart` — read-only SQLite-Wrapper, `NotAStudiesDbException`-Typing, schon production-tested. **+1 neue Methode** in dieser Welle.
- `lib/features/studies/studies_provider.dart` — Single-DB-State. **Unverändert**, bleibt für Drill-Down.
- `lib/ui/widgets/trials_top10_table.dart` — Top-10-DataTable inkl. Detail-Sheet. **Wird strukturell wiederverwendet** für das Global-Leaderboard (gleiches Sheet, +Strategy/Study-Spalte).
- `lib/ui/screens/studies_screen.dart` — Compositor. Bekommt zwei neue Sektionen oben.

### Default-Verzeichnis

`01_Projectplan/optimizer_studies/` (project-relative; siehe `_suggestStudiesDir()` in `studies_screen.dart:31`). Aktuell darin: `studies-bb_rsi.db`, `studies-bb_rsi_1h.db`, `studies-ichimoku.db`, `studies-ichimoku-tpe.db`, `studies-ichimoku-wf.db`, `studies-ichimoku-wf-w3a.db`, `studies-ut_bot.db`, `studies-ut_bot_zerofee.db`, `stat_gates_results.db`, `ruvector.db`. Die letzten zwei sind **kein** Studies-Schema und werden über die bestehende `NotAStudiesDbException`-Validierung automatisch abgelehnt.

---

## 3. Architektur

### 3.1 Komponentenkarte

| Komponente | Datei | Typ | Verantwortung |
|---|---|---|---|
| `LibraryEntry` | `lib/core/models/library_entry.dart` | **neu** Model | `{path, pinned, addedAt, lastScannedAt?, healthCache?}` |
| `LibraryHealth` | `lib/core/models/library_entry.dart` | **neu** Model | `{studyCount, profitableTrialCount, totalTrialCount, dbMtime}` — gecached pro Entry |
| `LibraryStorage` | `lib/services/library_storage.dart` | **neu** Service | JSON-Persistenz in `<app-support>/studies_library.json` via `path_provider` |
| `StudiesLibrary` | `lib/features/studies/studies_library.dart` | **neu** Provider | Scan Default-Dir + manuelle Adds → Liste `LibraryEntry`, fire change, pin/unpin |
| `LeaderboardRow` | `lib/core/models/leaderboard_row.dart` | **neu** Model | `Trial + strategy + studyName + dbPath + studyId` (Detail-Sheet braucht den DB-Path um zu drillen) |
| `AggregateLeaderboard` | `lib/features/studies/aggregate_leaderboard.dart` | **neu** Provider | Lädt jede gepinnte DB read-only, aggregiert `topNProfitable`, mergt, sortiert, slice top-N |
| `LibraryPanel` | `lib/ui/widgets/library_panel.dart` | **neu** Widget | Pin/Unpin-Liste mit Health-Dot + Add-DB-Button + Scan-Refresh |
| `GlobalLeaderboardTable` | `lib/ui/widgets/global_leaderboard_table.dart` | **neu** Widget | TopN-Tabelle, basiert auf `TrialsTop10Table`, +Strategy/+Study-Spalte, Sort-Toggle |
| `LeaderboardFilterBar` | `lib/ui/widgets/leaderboard_filter_bar.dart` | **neu** Widget | `min_trades`-Slider, Sort-By-Dropdown, Top-N-Stepper |
| `studies_db.dart` | bestehend | **+1 Methode** | `topNProfitable({minTrades, limit, sortBy})` — **cross-study innerhalb einer DB** (kein `studyId`-Filter; bestehendes `top10(studyId)` bleibt für Per-Study-Drill-Down erhalten) |
| `studies_screen.dart` | bestehend | **modifiziert** | Komposition: Library + Leaderboard + (bestehender Picker bleibt als „Add custom .db") + Drill-Down |

### 3.2 Dependency-Diagramm

```
StudiesScreen
  ├── StudiesLibrary  ─── LibraryStorage ─── path_provider
  │     (Scan + Pin/Unpin + Health-Cache)
  │
  ├── AggregateLeaderboard ── liest aus StudiesLibrary
  │     (öffnet jede pinned DB read-only via StudiesDb)
  │
  ├── LibraryPanel        (consumes StudiesLibrary)
  ├── LeaderboardFilterBar (consumes AggregateLeaderboard)
  ├── GlobalLeaderboardTable (consumes AggregateLeaderboard)
  │
  └── StudiesProvider     (bestehend, Per-Study-Drill-Down — unverändert)
      └── triggered by GlobalLeaderboardTable.onRowClick
```

### 3.3 Persistenz-Schema

`<app-support>/studies_library.json`:

```json
{
  "version": 1,
  "entries": [
    {
      "path": "D:/03_Git/02_Python/07_Orderpilot_Portabel2/01_Projectplan/optimizer_studies/studies-ichimoku-wf.db",
      "pinned": true,
      "addedAt": "2026-06-04T10:32:00Z",
      "lastScannedAt": "2026-06-04T10:32:00Z",
      "healthCache": {
        "studyCount": 3,
        "profitableTrialCount": 47,
        "totalTrialCount": 1000,
        "dbMtime": "2026-05-25T18:59:00Z"
      }
    }
  ]
}
```

`version: 1` ist Pflicht — wenn wir das Schema später ändern, lesen wir `version` und migrieren. Unbekannte Felder beim Lesen tolerieren (forward-compat).

---

## 4. Filter-Definition (verbindlich)

### 4.1 SQL für `topNProfitable` (cross-study within a single DB)

```sql
SELECT t.id, t.study_id, t.trial_id, t.params_json, t.metrics_json,
       t.score, t.created_at,
       s.strategy, s.name AS study_name
FROM trials t
JOIN studies s ON t.study_id = s.id
WHERE t.score > -1e308
  AND CAST(json_extract(t.metrics_json, '$.total_pnl') AS REAL) > 0
  AND CAST(json_extract(t.metrics_json, '$.total_trades') AS INTEGER) >= :min_trades
ORDER BY t.score DESC
LIMIT :limit
```

**Annahmen verifizieren:**
- `json_extract` ist SQLite-3.38+ Standard. Verifizieren mit `SELECT sqlite_version();` an `studies-ichimoku-wf.db` während Phase-1-Subtask 4.1.
- Falls die genutzte sqflite-FFI-Version `json_extract` **nicht** liefert: Fallback ist **In-Memory-Filter** in Dart (Query alle Trials der Study, filtere clientseitig). Performance-Akzeptanz: 1000 Trials × 10 Studies × 10 DBs = 100k Rows — auf Windows-Desktop in <500 ms machbar.

### 4.2 Defaults

| Parameter | Default | Range | UI-Control |
|---|---|---|---|
| `min_trades` | **20** | 0–500 | Slider mit Snap-Points 0/5/10/20/50/100/250/500 |
| `limit` (Top-N) | **10** | 5–100 | Stepper |
| `sortBy` | `score` | score / pnl / sharpe / pf / trades / win_rate | Dropdown |

`min_trades = 20` rationale: bei 1000 Trials liefern reine Glückstreffer mit 1–5 Trades konsistent leere/grenzwertige Stichproben; 20 ist die übliche Min-Sample-Size für ein erstes Out-of-Sample-Statement.

### 4.3 Health-Dot (Library-Panel)

Pro Entry beim Boot/Refresh einmal:

```sql
SELECT
  (SELECT COUNT(*) FROM studies) AS study_count,
  (SELECT COUNT(*) FROM trials WHERE
    CAST(json_extract(metrics_json, '$.total_pnl') AS REAL) > 0) AS profitable_count,
  (SELECT COUNT(*) FROM trials) AS total_count
```

Farbe:
- **grün** wenn `profitable_count / total_count >= 0.10`
- **gelb** wenn `profitable_count > 0 AND < 10%`
- **rot** wenn `profitable_count == 0`
- **grau** wenn `total_count == 0` oder Datei fehlt/broken

Cache invalidieren wenn `dbMtime` von `File(path).lastModified()` abweicht.

---

## 5. Error-Handling (Edge-Cases explizit)

| Fall | Verhalten | Test |
|---|---|---|
| DB-Datei beim Boot weg (umbenannt, gelöscht) | Entry bleibt in Library, Health = grau „Missing", aus Aggregation ausgeschlossen, User sieht Hint „File not found" + Unpin-Button | Unit `aggregate_leaderboard_test.dart` |
| User pickt `ruvector.db` o. Ä. | Wirft `NotAStudiesDbException` (bestehend), Toast „Not an Optuna studies DB", **Entry wird nicht gespeichert** | Unit `studies_library_test.dart` |
| Eine von n DBs ist broken | Andere DBs liefern weiter, broken Entry zeigt rotes „Error: <message>" inline, fließt nicht ins Leaderboard | Integration |
| Leere DB (0 Trials, 0 Studies) | Health = grau „(empty)", trägt 0 Rows zum Leaderboard bei | Unit |
| `metrics_json` korrupt für einzelne Row | Bestehender `_parseTrialRows`-Skip via `AppLog.warn` ([studies_db.dart:178](lib/services/studies_db.dart:178)), Row fehlt im Result, kein Crash | Bestehender Test ergänzt |
| `metrics_json` enthält `Infinity` als String | Vorhandener `_asDouble`-Pfad ([trial_metrics.dart:67](lib/core/models/trial_metrics.dart:67)) parst korrekt | Bestehender Test |
| `total_pnl > 0` aber `score == -inf` | `score > -1e308` Filter wirft die Row → korrekt rausgehalten | Unit |
| Race: User unpinned mid-recompute | `AggregateLeaderboard` hält einen `int _recomputeGen`; jeder Recompute prüft am Ende `if (gen != _recomputeGen) return;` und verwirft sein Result | Unit |
| Recompute parallel von mehreren Triggern (Pin + Filter + Refresh) | Debounce 200 ms in `AggregateLeaderboard`, letzter Trigger gewinnt | Unit |
| 50+ DBs im Default-Dir | Sequentiell pro DB öffnen + `topNProfitable` + close (kein Connection-Pool). UI zeigt „Scanning… (12/50)" wenn >10 DBs | Manual UAT |
| `LibraryStorage` JSON kaputt (User hat editiert) | Beim Lesen `try/catch` → Reset auf leere Library, `AppLog.warn`. Default-Scan erfindet Library wieder neu, nur `pinned`-State geht verloren | Unit |
| `json_extract` in sqflite-FFI **nicht verfügbar** | Fallback: clientseitiger Filter in `_parseTrialRows`; siehe Subtask 4.1 | Phase-1-Validierung |
| Sehr lange Pfade auf Windows (>260 chars) | `path_provider` liefert kurze AppSupport-Pfade; `LibraryStorage` schreibt nur dort, nicht in `01_Projectplan/`. Tolerant gegen Long-Paths in `LibraryEntry.path` | Manual |

---

## 6. Testing

### 6.1 Unit-Tests (pflichten)

- `test/services/library_storage_test.dart`
  - JSON roundtrip mit/ohne `healthCache`
  - Forward-compat: unbekanntes Feld im JSON wird stillschweigend ignoriert
  - Korrupt-JSON → Reset-auf-empty + Log-Warning
  - Version-Migrations-Pfad (Version 1 lesen, Version 99 reset)

- `test/features/studies/studies_library_test.dart`
  - Default-Dir-Scan dedupliziert nach absolutem Pfad
  - Manuell hinzugefügter Pfad + erneuter Scan = kein Duplikat
  - Pin/Unpin/Remove → Storage wird geschrieben
  - `NotAStudiesDbException` beim Add wird gefangen, Entry nicht gespeichert
  - File-not-found bleibt in Library, markiert als missing

- `test/features/studies/aggregate_leaderboard_test.dart`
  - Mit 3 In-Memory-Test-DBs (Ichimoku-like, BB-RSI-like, leer)
  - Filter `total_pnl > 0`: rejected Rows verify
  - `min_trades = 20`: cutoff verify
  - Sort-By Score/PnL/Sharpe: Order verify
  - Limit/Top-N respektiert
  - Race: zwei `recompute()`-Aufrufe → nur das letzte Result fired notifyListeners
  - Eine broken DB unter drei → andere liefern weiter

- `test/services/studies_db_test.dart` (bestehend erweitern)
  - Neue Methode `topNProfitable` mit den drei Fixture-DBs
  - Edge: alle Trials negativ → leeres Result (kein leer-Top-10 mit Verlustreihen)
  - Edge: `min_trades = 0` → alle Trials mit `total_pnl > 0` über alle Studies der DB, Top-N nach gewähltem Sort-Key
  - Edge: DB mit nur einer Study → Result-Set ist Subset des bestehenden `top10(studyId)` (gefiltert auf `total_pnl > 0` und `total_trades >= min_trades`)
  - Edge: DB mit drei Studies → Result kann Trials aus allen drei mischen, sortiert ist konsistent global

### 6.2 Widget-Tests

- `test/ui/widgets/library_panel_test.dart`
  - Loading / empty / error / „missing file" / „add custom .db" States
  - Pin-Toggle löst `library.toggle(path)` aus

- `test/ui/widgets/global_leaderboard_table_test.dart`
  - Sort-Header-Click toggelt Reihenfolge
  - Click auf Row öffnet Detail-Sheet (gleicher Pfad wie `TrialsTop10Table`)
  - Sheet zeigt Strategy + Study + Trial# als Kopf

- `test/ui/widgets/leaderboard_filter_bar_test.dart`
  - Slider → `aggregate.setMinTrades`
  - Dropdown → `aggregate.setSortBy`
  - Debounce: schnelle Drags lösen genau 1 Recompute aus

### 6.3 Integration-Test

- `test/integration/studies_library_smoke_test.dart` **(neu)**
  - Bootet mit zwei echten Test-DBs in tmpDir (eine Ichimoku-shaped, eine BB-RSI-shaped, beide mit gemischt-profitablen Trials)
  - Verify: Library zeigt beide; Leaderboard merged korrekt
  - Verify: Click auf Leaderboard-Row → Drill-Down lädt korrekte Study im StudiesProvider
  - Verify: Unpin einer DB → Leaderboard rechnet neu

- `test/integration/studies_viewer_smoke_test.dart` (bestehend, **NICHT brechen**)
  - Bestehender Pick-`.db`-Flow muss weiterhin grün durchlaufen — die neue Library-Schicht darf den manuellen Picker nicht entfernen

### 6.4 Lessons-Learned-Disziplin (aus Memory)

- **WidgetsFlutterBinding.ensureInitialized() VOR `sqfliteFfiInit()`** in jedem neuen Widget-/Integration-Test (siehe `pretask_lesson_binding_first.md`)
- **`tester.runAsync(() async {...})`** wenn `Future.delayed(Duration.zero)` o. Ä. im Provider hängt (siehe `testing_runasync_in_widget_tests.md`)
- **Drag-Handle im Detail-Sheet bleibt erstes Kind der inneren ListView** (siehe `pretask_lesson_draggable_sheet_handle.md`) — wir verwenden `TrialsTop10Table`s Sheet wieder, also nicht versehentlich verändern
- **Atomare Commits**, push nach jedem grünen Commit, Phase-1-Reference-Backtest (91 Trades, -2071.38 USDT) darf nicht bewegt werden (siehe `project_regression_guards.md`)

---

## 7. UAT-Akzeptanzkriterien

1. **Boot:** App starten → Studies-Tab → Library-Panel zeigt automatisch alle `.db` aus `01_Projectplan/optimizer_studies/`, `ruvector.db` und `stat_gates_results.db` werden mit grauem Dot und Hint „Not a studies DB" markiert (NICHT crash, NICHT silent geschluckt).
2. **Default-Pinning:** Beim ersten Boot sind alle erkannten valid Studies-DBs **un-pinned** — User entscheidet aktiv was im Leaderboard landet.
3. **Pin Ichimoku-WF + BB-RSI:** Global-Leaderboard zeigt Top-10 profitable Trials gemischt aus beiden DBs, jede Row mit Spalten Strategy + Study + Trial.
4. **min_trades = 20:** Trials mit `total_trades < 20` verschwinden aus dem Leaderboard, sind aber im Drill-Down (per-Study-Top-10) weiterhin sichtbar.
5. **Sort-By PnL:** Reihenfolge ändert sich, Rank-Spalte aktualisiert.
6. **Click auf Leaderboard-Row:** Detail-Sheet öffnet (gleich wie bisher), Header zeigt zusätzlich Strategy + Study-Name.
7. **Drill-Down:** Wenn User eine DB im Library-Panel anklickt (nicht das Leaderboard) → bestehender Per-Study-Picker + Convergence-Plot laden wie heute.
8. **DB löschen während App läuft → Reload-Button:** Entry zeigt rot „Missing", andere DBs liefern weiter, kein Crash.
9. **Manuelles „Add custom .db" → ruvector.db:** Toast „Not an Optuna studies DB", Entry wird NICHT gespeichert.
10. **Library-JSON manuell mit Texteditor zerschossen:** App-Restart → leere Library, AppLog-Warning, Auto-Scan füllt sie wieder, nur `pinned`-Bits verloren.
11. **Bestehender Pick-`.db`-Flow** (file_picker auf manuellen DB-Pfad) funktioniert weiterhin, der bestehende `studies_viewer_smoke_test.dart` bleibt grün.
12. **Phase-1-Reference-Backtest unverändert** (91 Trades, -2071.38 USDT).

---

## 8. Sub-Tasks (Reihenfolge / atomare Commits)

| # | Subtask | Branch-Commit-Subject |
|---|---|---|
| 1.0 | `json_extract`-Verfügbarkeit in sqflite-FFI verifizieren, sonst Dart-Fallback im SQL-Builder | `feat(O3-B4-1): probe json_extract availability + fallback plan` |
| 2.0 | Models `LibraryEntry`, `LibraryHealth`, `LeaderboardRow` + Unit-Tests | `feat(O3-B4-2): library + leaderboard data models` |
| 2.1 | `StudiesDb.topNProfitable` + Unit | `feat(O3-B4-2.1): studies_db.topNProfitable cross-study query` |
| 3.0 | `LibraryStorage` (JSON-Roundtrip + Version-1-Schema + Forward-compat) + Unit | `feat(O3-B4-3): studies_library JSON persistence` |
| 3.1 | `StudiesLibrary` Provider (Scan + Pin/Unpin + Health-Cache) + Unit | `feat(O3-B4-3.1): studies_library provider` |
| 4.0 | `AggregateLeaderboard` Provider (Multi-DB-Merge + Debounce + Generation-Counter) + Unit | `feat(O3-B4-4): aggregate_leaderboard provider` |
| 5.0 | `LibraryPanel` + `LeaderboardFilterBar` + `GlobalLeaderboardTable` Widgets + Widget-Tests | `feat(O3-B4-5): library + global leaderboard UI` |
| 5.1 | `StudiesScreen` Komposition: neue Sektionen oben, Drill-Down-Verdrahtung | `feat(O3-B4-5.1): studies_screen wires library + drilldown` |
| 6.0 | Integration-Smoke-Test `studies_library_smoke_test.dart` | `test(O3-B4-6): library smoke test` |
| 7.0 | Manual-UAT-Pass (Punkte 1–12 aus §7) | `chore(O3-B4-7): UAT pass + post-task report` |

Jeder Subtask = ein grüner Commit, dann push.

---

## 9. Sign-Off-Checkliste (QA-Koordinator)

- [ ] Subtasks 1.0–7.0 atomic committed + pushed
- [ ] `flutter analyze` clean
- [ ] `flutter test` clean (alle bestehenden + neuen)
- [ ] Bestehender `studies_viewer_smoke_test.dart` grün
- [ ] Phase-1-Reference-Backtest unverändert (Verify via `tool/build_rust.sh release` + relevanten Test)
- [ ] UAT-Punkte 1–12 manuell durchgespielt
- [ ] POST_TASK-Report nach `01_Projectplan/POST_TASK_2026-06-04_O3-B4_StudiesLibrary.md`

---

## 10. Offene Fragen für Executor (parallel-CC)

- **Q1:** Hat die im Projekt verwendete `sqflite_common_ffi`-Version `json_extract` verfügbar? → Subtask 1.0 ist der Probe.
- **Q2:** Soll `AppSupport`-Verzeichnis für `studies_library.json` über `path_provider.getApplicationSupportDirectory()` oder lieber `path_provider.getApplicationDocumentsDirectory()` adressiert werden? Default-Entscheidung: **AppSupport** (Windows: `%LOCALAPPDATA%/<app>`), weil keine User-Sichtbarkeit nötig. Override falls Convention im Projekt anders ist.
- **Q3:** Falls `flutter analyze` einen Lint wegen `unawaited` (siehe `studies_provider.dart:153`) wirft: bestehende Pattern beibehalten, nicht umbauen.
