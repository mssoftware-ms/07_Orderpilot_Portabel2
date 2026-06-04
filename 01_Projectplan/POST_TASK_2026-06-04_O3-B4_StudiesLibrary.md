# Post-Task Welle O3-B4 — Studies Library (Multi-DB-Leaderboard)

**Executed:** 2026-06-04 by parallel-CC (WSL2)
**Branch:** `main`, atomare Commits + push pro grünem Task
**Base:** `e538b81` (origin/main, inkl. der bereits committeten Dependency-Migration
auf file_picker 11 / fl_chart 1.2 / candlesticks 3 / flutter_secure_storage 10 /
sqflite_common_ffi 2.4.1)
**Status:** O3-B4-Feature vollständig implementiert + getestet (grün). **Final-Sign-off
beim QA-Koordinator** — ein Punkt (Phase-1-dart↔rust-Parität) ist ein vorbestehender,
O3-B4-fremder Befund (siehe §5).

---

## 1. Scope delivered

Studies-Screen hat jetzt eine **Library-Schicht** über dem bestehenden Single-DB-Viewer:

- **Multi-DB-Auto-Scan** von `01_Projectplan/optimizer_studies/` + manuelles „Add custom .db"
- **Pin/Unpin** mit persistentem Zustand (`SharedPreferences`, versioniert v1)
- **Health-Dot** pro Entry (grün/gelb/rot/grau, mtime-gecacht)
- **Global-Leaderboard** über alle gepinnten DBs × alle Studies, gefiltert auf
  `total_pnl > 0 AND total_trades >= min_trades`, mit Sort-By (score/pnl/sharpe/pf/
  trades/winRate), Top-N-Stepper und Min-Trades-Slider
- **Detail-Sheet** pro Leaderboard-Row (Strategy + Study + Trial + Params/Metrics)
- **Per-Study-Drill-Down (O3-B2) unverändert erhalten** unter „Per-study drill-down"

Out-of-scope (PRE_TASK §1) eingehalten: kein DB-Schreiben, kein Cross-DB-Convergence-Plot,
kein Live-Stream-Update, kein Custom-Re-Scoring, keine ruvector/stat_gates-Integration.

---

## 2. Commits shipped (12)

| # | Commit | Subject |
|---|---|---|
| 1 | `016c872` | feat(O3-B4-1): probe json_extract availability + fallback plan |
| 2 | `1a164e7` | feat(O3-B4-2): library + leaderboard data models |
| 3 | `b036126` | feat(O3-B4-2.1): studies_db.topNProfitable + healthSnapshot |
| 4 | `4ef2d56` | feat(O3-B4-3): studies_library SharedPreferences storage |
| 5 | `e96bd0d` | feat(O3-B4-3.1): studies_library provider |
| 6 | `644efeb` | feat(O3-B4-4): aggregate_leaderboard provider |
| 7 | `e6b6ef3` | feat(O3-B4-5a): library_panel widget |
| 8 | `e091edd` | feat(O3-B4-5b): leaderboard_filter_bar widget + tests |
| 9 | `4f487cb` | feat(O3-B4-5c): global_leaderboard_table widget |
| 10 | `81566f6` | feat(O3-B4-5.1): studies_screen composes library + leaderboard |
| 11 | `9995e96` | test(O3-B4-6): integration smoke test for studies library |
| 12 | `792d6ff` | chore(O3-B4-7): UAT pass + post-task report |
| 13 | `192a274` | fix(O3-B4-8): wire health-dot refresh + library-row drill-down (Codex stop-review) |
| 14 | `0d55af7` | fix(O3-B4-9): refreshHealth must not clobber concurrent pin changes (Codex stop-review) |

Working-Tree-Hinweis: Vor Task 1 lag eine fremde Dependency-Migration als M-Files vor;
der QA-Koordinator hat sie selbst committet+gepusht (`e538b81 #up`), bevor O3-B4 startete.
Damit war der Tree sauber und keine fremden M-Files wurden vereinnahmt.

---

## 3. Deviations from PRE_TASK / IMPL_PLAN

| # | Abweichung | Grund (empirisch verifiziert) |
|---|---|---|
| D1 | **Q2-Storage:** `SharedPreferences` statt `path_provider`+JSON-Datei | Bereits im IMPL_PLAN als Q2-Deviation festgelegt (Dep-Parität, 0 neue Packages) |
| D2 | **`json_valid(metrics_json)`-Guard** in `topNProfitable`/`healthSnapshot`-SQL | Roh-`json_extract` wirft einen harten „malformed JSON, SQL logic error" auf eine einzelne kaputte Row und bricht die ganze Query ab (verifiziert gegen `studies_fixture.db`). `json_valid` überspringt sie (wie `_parseTrialRows` skip-and-warn) und hält den SQL-Pfad am Leben. Dart-Fallback nur noch bei komplett fehlendem JSON1 |
| D3 | **Studies_db-Tests an reale Fixture angepasst** | Plan nahm 2 profitable Trials / PnL 280.0 an; die echte `studies_fixture.db` hat 3 profitable (120.5/450.0/60.0). Assertions auf die tatsächlichen Werte korrigiert |
| D4 | **`dart:async`-`unawaited`** statt zweiter lokaler No-op in `aggregate_leaderboard.dart` | `studies_provider.dart` deklariert bereits eine top-level `unawaited`; eine zweite hätte beim gemeinsamen Import in `studies_screen.dart`/`main.dart` `ambiguous_import` riskiert |
| D5 | **Widget-/Smoke-Tests: synchrone Datei-I/O** (`createTempSync`/`copySync`/`deleteSync`, Platzhalter-`.db`) | Echtes Async-I/O (`Directory.createTemp`, `File.copy`, `sqflite openDatabase`) wird in der `testWidgets`-FakeAsync-Zone nie abgeschlossen → Hang (Lesson `testing_runasync_in_widget_tests`). `SharedPreferences` via `setMockInitialValues` läuft per Microtask, ist also ok; `recompute` bleibt in `tester.runAsync` für den sqflite-Isolate |
| D6 | **`build_fixture_library.dart`: absolute Pfade für `openDatabase`** | `sqflite_common_ffi` löst relative Pfade gegen sein eigenes `.dart_tool/`-Verzeichnis auf, sonst landen die Fixtures am falschen Ort |
| D7 | **Smoke-Test-Study-Name-Assertion auf Sheet-Teilbaum eingegrenzt** (`find.descendant`) | Die Tabelle hinter dem Modal-Sheet rendert den Study-Namen ebenfalls → Plan-`findsOneWidget` matchte 2 Widgets |
| D8 | **`studies_screen_test.dart` + `studies_viewer_smoke_test.dart` um 2 Provider ergänzt** | `StudiesScreen` liest jetzt `StudiesLibrary` + `AggregateLeaderboard`; ohne sie `ProviderNotFoundException`. Leere/un-gebootete Library → Leaderboard-Empty-State → keine `#`-Rank-Kollision mit den Per-Study-Top-10-Assertions |

---

## 4. Test status

**O3-B4 + studies-Regression: vollständig grün.**

| Suite | Tests | Status |
|---|---|---|
| `test/core/models/library_entry_test.dart` | 4 | ✅ |
| `test/services/studies_db_test.dart` (16, +5 neu) | 16 | ✅ |
| `test/services/library_storage_test.dart` | 5 | ✅ |
| `test/features/studies/studies_library_test.dart` | 6 | ✅ |
| `test/features/studies/aggregate_leaderboard_test.dart` | 7 | ✅ |
| `test/ui/widgets/library_panel_test.dart` | 2 | ✅ |
| `test/ui/widgets/leaderboard_filter_bar_test.dart` | 3 | ✅ |
| `test/ui/widgets/global_leaderboard_table_test.dart` | 3 | ✅ |
| `test/integration/studies_library_smoke_test.dart` | 1 | ✅ |
| `test/ui/screens/studies_screen_test.dart` (regression) | 4 | ✅ |
| `test/integration/studies_viewer_smoke_test.dart` (regression) | 1 | ✅ |
| `test/features/studies/studies_provider_test.dart` (regression) | ✓ | ✅ |

**`flutter analyze`:** 0 Issues in `lib/`+`test/`-Source (pro-Datei verifiziert). Der volle
`flutter analyze` meldet 2 Issues, beide in `build/windows/x64/plugins/.../cargokit_build/`
— **generierte, gitignored Windows-Build-Artefakte** (ephemeral-Symlink fehlt in WSL),
nicht O3-B4-bezogen, umgebungsbedingt.

**`flutter test` (volle Suite): NICHT durchgehend grün** — blockiert ausschließlich durch
den vorbestehenden dart↔rust-Paritäts-Fail (§5), der O3-B4-fremd ist.

---

## 5. Phase-1-Reference-Backtest — Befund (STOP-Punkt)

`tool/build_rust.sh release` neu gebaut (16.4s, frisches `libtrading_engine.so`), dann
`test/integration/phase1_reference_backtest_test.dart`:

```
trades = 91   (Dart & Rust, identisch)
Dart : pnl = -1565.358744  (3/3 deterministisch reproduziert)
Rust : pnl = -1514.059742  (3/3 deterministisch reproduziert)
→ Test FAILT auf dart↔rust-Parität: |−1565.36 − (−1514.06)| ≈ 51 USDT > 1e-9
```

**Einordnung:**

1. **Die `-2071.38 USDT`-Referenz ist veraltet.** `01_Projectplan/specs/bb_rsi_diff.md:40`
   dokumentiert selbst: „Der gedruckte Phase-1-Diagnosewert (pnl ≈ −2071.38 USDT, 139
   Trades) ist nach dem Fix Geschichte. Der Test selbst kollabiert nicht (keine
   Hard-Assertion auf diese Zahl)." Zahlreiche Engine-Fixes nach dem Baseline-Freeze
   (2026-05-26) — `86a6199` (risk sizing/TP), `28bdca0` (fee-adjusted allocation),
   `52ce16b`, `7eeeb5f` u.a. — haben den PnL legitim verschoben. **Trade-Count 91 ist
   stabil geblieben.**

2. **Der Test pinnt keinen absoluten PnL**, sondern prüft (a) Dart-Determinismus,
   (b) Rust-Determinismus, (c) dart↔rust-Parität (`closeTo 1e-9`). Er failt nur an (c).

3. **Nicht durch O3-B4 verursacht — beweisbar:** `git diff --stat e538b81..HEAD` berührt
   ausschließlich `studies/`, `main.dart` (Provider-Liste), studies-Tests, Tools, Docs —
   **null** Rust-/Backtest-/Strategy-Code. Das `.so` ist ein untracked, gitignored lokales
   Artefakt; das vorherige veraltete `.so` maskierte die Divergenz, der vom Plan geforderte
   Rebuild (aktueller main-Rust-Source) legte sie frei. Auf reinem `main` ohne O3-B4 würde
   derselbe Rebuild dieselbe Parität brechen → **vorbestehend, O3-B4-fremd**.

**Empfehlung:** dart↔rust-PnL-Divergenz (~51 USDT bei identischem Trade-Count) separat
untersuchen — Verdacht auf Rounding/Ordering in einem der F-01/F-02/F-03-Pfade bzw.
Rust-Source-Drift gegenüber der Dart-Engine seit dem letzten frischen `.so`. Außerhalb des
O3-B4-Scopes; QA-Koordinator-Entscheidung.

---

## 6. UAT-Akzeptanzkriterien (PRE_TASK §7)

Hinweis: Die App läuft auf Windows (`flutter run -d windows`); der Executor arbeitet
headless in WSL2 ohne GUI, kann das visuelle Walkthrough also nicht selbst durchführen.
Jede Zeile ist daher mit der **automatisierten Test-Evidenz** belegt; die finale
visuelle Bestätigung am Windows-Build liegt beim QA-Koordinator.

| # | Check | Automatisierte Evidenz | Status |
|---|---|---|---|
| 1 | Library listet optimizer_studies; ruvector/stat_gates kein Crash, nicht silent | Scan listet alle `.db` (studies_library_test); Health-Dots werden im App-Flow per `main.dart` → `refreshHealth()` gefüllt (O3-B4-8, test „boot…refreshHealth populates it"); ungültige DBs → `NotAStudiesDbException` gefangen+übersprungen | 🔶 siehe Hinweis A |
| 2 | Alle Entries beim ersten Boot un-pinned | studies_library_test „scanDirectory finds .db files" (alle `pinned==false`) | ✅ |
| 3 | Pin 2 DBs → Leaderboard mischt beide Strategien | aggregate_leaderboard_test + studies_library_smoke_test (ichimoku+bb_rsi) | ✅ |
| 4 | min_trades=20 → Low-Sample raus, im Drill-Down weiter sichtbar | studies_db topNProfitable min_trades + aggregate min_trades-cutoff | ✅ |
| 5 | Sort PnL → Reihenfolge + Rank-Update | filter_bar sort-dropdown + aggregate sortBy=pnl | ✅ |
| 6 | Click Leaderboard-Row → Detail-Sheet (Strategy+Study+Trial) | global_leaderboard_table_test „tap on row opens detail sheet" + smoke | ✅ |
| 7 | Click Library-Row → Per-Study-Drill-Down lädt | LibraryPanel `onOpenDb`-Callback → `provider.loadDb` (O3-B4-8); library_panel_test „row body tap fires onOpenDb with the entry path" + studies_viewer_smoke (loadDb rendert Per-Study) | ✅ |
| 8 | DB löschen → Reload → „Missing", andere liefern weiter, kein Crash | studies_library_test „missing file keeps entry but marks missing" + aggregate broken-DB-Test | 🔶 (GUI-Reload visuell offen) |
| 9 | Add custom ruvector.db → „Not an Optuna studies DB", nicht gespeichert | studies_library_test „addCustom rejects non-studies DB" | ✅ |
| 10 | SharedPreferences zerschossen → leere Library + Warn + Auto-Rescan | library_storage_test „corrupt JSON resets to empty" / „unknown version resets" | ✅ |
| 11 | Bestehender Pick-`.db`-Flow + studies_viewer_smoke_test grün | studies_viewer_smoke_test ✅ (grün mit neuen Providern) | ✅ |
| 12 | Phase-1-Backtest unverändert (91 Trades / -2071.38 USDT) | trades=91 ✅; PnL & Parität siehe §5 | ⚠️ §5 |

**Hinweis A (UAT 1) — Rest-Nuance:** Gültige Studies-DBs zeigen seit O3-B4-8 ihren
echten Health-Dot (grün/gelb/rot via `refreshHealth` im App-Boot). Auto-gescannte
Nicht-Studies-DBs (`ruvector.db`, `stat_gates_results.db`) erscheinen als **graue**
Dots („Not scanned yet", da der Health-Open fehlschlägt) und tragen nichts zum
Leaderboard bei. Sie werden also **nicht** silent geschluckt und crashen nicht — aber
es wird kein expliziter „Not a studies DB"-Text gerendert (nur der manuelle
Add-Custom-Pfad zeigt den Toast). Minor-Deviation gegenüber dem PRE_TASK-§7.1-Wortlaut;
Verschärfung optional (siehe §8).

**Hinweis B (UAT 7) — erledigt in O3-B4-8:** Library-Row-Body-Tap lädt jetzt die DB in
den Per-Study-Drill-Down (`LibraryPanel.onOpenDb` → `StudiesProvider.loadDb`); die
Pin-Schaltfläche gewinnt weiterhin ihren eigenen Tap. Der manuelle „Pick .db"-Picker
bleibt zusätzlich erhalten (UAT 11).

---

## 7. Sign-Off-Checkliste (Status)

- [x] Subtasks 1.0–6.0 (11 Code/Test-Commits) + O3-B4-8 App-Flow-Fix atomic committed + pushed
- [x] `flutter analyze` clean für alle O3-B4-`lib/`+`test/`-Dateien (2 Restissues nur in
      gitignored `build/windows/`-Artefakten, umgebungsbedingt)
- [x] Alle neuen + studies-Regressions-Tests grün
- [x] Bestehender `studies_viewer_smoke_test.dart` grün (kein Regress)
- [ ] **`flutter test` durchgehend grün — BLOCKIERT** durch vorbestehende dart↔rust-Parität (§5)
- [~] UAT 1–12 — automatisiert belegt (siehe §6); UAT 7 + Health-Dots seit O3-B4-8 im
      App-Flow verdrahtet; offen bleiben visuelle Windows-Bestätigung + UAT 12-Parität (§5)
      beim QA-Koordinator
- [x] POST_TASK-Report (dieses Dokument)

---

## 8. Notes for next welle

1. **dart↔rust Phase-1-Parität** (~51 USDT PnL-Drift bei 91 Trades) untersuchen — eigene
   Engine-Welle. Verdacht: Rust-Source-Drift seit letztem frischem `.so` bzw.
   Rounding/Ordering in F-01/F-02/F-03. `tool/build_rust.sh release` als Pflicht-Schritt
   in jede CI/Test-Routine aufnehmen, damit stale `.so` solche Divergenzen nicht maskiert.
2. **`-2071.38`-Referenz aktualisieren** in HANDOFF/Memory `project-regression-guards` →
   aktueller Dart-Wert `-1565.358744` (91 Trades), oder den Wert nach behobener Parität.
3. **UAT 1** optional schärfen: expliziter „Not a studies DB"-Hint für auto-gescannte
   Nicht-Studies-DBs (Health-Probe beim Scan statt erst lazy bei `refreshHealth`).

*(UAT 7 Library-Row-Drill-Down + Health-Dot-Verdrahtung wurden in O3-B4-8 nachgezogen —
nicht mehr offen. O3-B4-9 behebt zudem eine Race-Condition: der automatische
Health-Refresh überschrieb beim Write-Back nach der async Health-Probe einen währenddessen
gesetzten Pin — jetzt wird der Entry per Pfad neu aufgelöst, sodass Pin-Änderungen
erhalten bleiben.)*

---

## 9. QA-Koordinator-Audit (Windows-CC, 2026-06-04)

POST_TASK-Behauptung in §4 (alle studies-Tests grün) auf Windows nachverifiziert.

**Befund:** Auf Windows failten 6 / 7 `aggregate_leaderboard_test` und 5 / 6
`library_panel_test` — alle mit `Actual: <0>` bzw. `Actual: []`. Root-Cause:
Tests konstruierten ihre Fixture-Pfade als `'${tempDir.path}/studies-x.db'`. Auf
Windows liefert `Directory.systemTemp.createTemp` einen Backslash-Pfad, das
angehängte `/` ergab **Mixed-Slash**; `File('...').absolute.path` behält den
gemischten Slash-Style. Die Implementation speicherte `f.absolute.path` und
verglich in `togglePin` / `remove` per String-Equals — Mixed-Slash matched
nie die Backslash-Form, jeder Test-Pin lief silently ins Leere, Aggregate
lieferte konsistent 0 Rows. WSL2 sah den Bug nicht (Forward-Slash nativ).

**Fix (Commit `1088035`, „O3-B4-10"):**
- Neuer statischer Helper `StudiesLibrary._canonicalize(path)` —
  `File.absolute.path` + `Platform.isWindows`-guarded `'/' → '\'`-Replace.
- Wired in `_mergeScan` (Storage), `addCustom` (Storage), `togglePin` (Lookup),
  `remove` (Lookup) — jede Entry-Schreibung und jede Pfad-Lookup nutzt
  jetzt dieselbe OS-native Form.
- Tests (`studies_library_test.dart`, `aggregate_leaderboard_test.dart`,
  `library_panel_test.dart`) konstruieren ihre Fixture-Pfade ebenfalls per
  `.replaceAll('/', Platform.pathSeparator)` — so matched Test-Construct =
  Library-Storage.

**Verifikation:** `flutter test test/features/studies/ test/services/
test/ui/widgets/ test/ui/screens/ test/integration/studies_library_smoke_test.dart
test/integration/studies_viewer_smoke_test.dart test/core/models/` →
**399 / 399 grün auf Windows**. `flutter analyze` auf modified files clean.

**Latent-Production-Risk (offen, niedrige Wahrscheinlichkeit):** Falls
`file_picker` auf Windows einen Mixed-Slash-Pfad zurückliefert, würde der
gleiche Add-und-dann-Duplicate-Bug auch in Production manifest werden.
`addCustom` ist seit O3-B4-10 durch `_canonicalize` defensiv, also gefixt.

**Code-Reviewer-Findings (offen, alle „Major" / „Minor", **kein Blocker**):**
- **Major A** — `_jsonExtractAvailable` ist instance-Feld in `StudiesDb`,
  aber `StudiesDb` wird pro Call frisch instanziert (`aggregate_leaderboard.dart`
  Z. 65; `studies_library.dart` Z. 136). Cache ist tote Code-Pfad — auf
  JSON1-fehlenden Engines würde jeder Recompute den Catch-Pfad laufen. Heute
  harmlos (Probe O3-B4-1 bestätigt JSON1-Verfügbarkeit). Fix: `static bool?`.
- **Minor C** — Kein Test für `_addCustom`-Picker-Fehler-Pfad.

**Empfehlung nächste Welle (O3-B4-11 oder Engine-Welle als Teil-Scope):**
1. Major A als 5-Minute-Fix: `static bool? _jsonExtractAvailable`.
2. POST_TASK §4 Convention für künftige WSL2-only-Executions: **„Sign-off-Statement
   `flutter test green` darf nur stehen, wenn explizit auf der Ziel-Plattform
   (Windows) verifiziert wurde."** Lessons-Learned-Memory-Eintrag empfohlen.

**Sign-off-Status (post-Audit):**

- [x] Subtasks 1.0–6.0 + O3-B4-8 + O3-B4-9 + O3-B4-10 atomic committed + pushed
- [x] `flutter analyze` clean auf modified files
- [x] **399 / 399 Tests grün auf Windows** (war vor O3-B4-10 falsch behauptet)
- [x] Bestehender `studies_viewer_smoke_test.dart` grün
- [~] **`flutter test` durchgehend grün — `phase1_reference_backtest_test`
      separat behandelt** (siehe §5 + Memory-Update auf neuen Dart-Wert
      `-1565.358744`). O3-B4-fremd, eigene Engine-Welle.
- [~] UAT 1–11 automatisiert belegt; visuelle Windows-UAT vom QA-Koordinator
      noch nicht vollständig durchgespielt (separat verbleibend).
- [x] POST_TASK + Audit-Trailer (dieses Dokument)

**Final-Sign-off-Entscheidung:** O3-B4 ist **inhaltlich abgeschlossen** und
auditiert. Verbleibende Items (Visual-UAT-Pass, Major-A-Follow-up, Phase-1-Engine-
Parität) sind als Folgewellen klar dokumentiert und blockieren nicht.
