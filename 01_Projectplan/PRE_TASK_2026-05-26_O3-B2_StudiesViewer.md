# Pre-Task Welle O3-B2 — Studies-Viewer-Screen

**Issued:** 2026-05-26 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem grünen Commit
**Base:** `9f2902f` (origin/main, inkl. O3-B1 + Logging-Infrastruktur)

---

## 1. Scope

Studies-Viewer-Screen, der die in `01_Projectplan/optimizer_studies/*.db` gespeicherten Optimization-Trials sichtbar macht: Top-10 nach Score, Param-Konvergenz-Plot, Trial-Detail. Macht 5 Monate Engineering-Output (10 DBs, je ~1000 Trials) erstmals visuell zugänglich. Wertbeitrag laut Handoff: **„5 Monate Engineering-Output visuell"**, Aufwand 1 Session.

**Out-of-scope** (für spätere Wellen):
- DB-Schreiben aus der App heraus (Optimierungsläufe bleiben CLI-only)
- Trial-Re-Simulation mit anderem Symbol/Timeframe (B3 oder später)
- `ruvector.db` Integration (separates Schema, nicht Teil von B2)
- `stat_gates_results.db` Integration (separates Schema, B2.1 falls Bedarf)

---

## 2. Kontext (Engine + Daten)

### DB-Schema (verifiziert auf `studies-bb_rsi.db`)

```sql
CREATE TABLE studies (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,                  -- z.B. "production_bb_rsi_n1000_seed42_2026-05-24"
  strategy TEXT NOT NULL,              -- "bb_rsi" | "ut_bot" | "ichimoku"
  search_space_yaml TEXT NOT NULL,     -- YAML-string mit Parameter-Ranges
  created_at TEXT NOT NULL,            -- ISO-8601 UTC
  commit_hash TEXT                     -- nullable
);

CREATE TABLE trials (
  id INTEGER PRIMARY KEY,
  study_id INTEGER NOT NULL,
  trial_id INTEGER NOT NULL,           -- 0..N-1 innerhalb der Study
  params_json TEXT NOT NULL,           -- {"values":{k:v}}
  metrics_json TEXT NOT NULL,          -- {total_trades, total_pnl, win_rate,
                                       --  sharpe_ratio, max_drawdown_pct,
                                       --  profit_factor, final_equity}
  score REAL NOT NULL,                 -- optimization objective; kann -inf sein
                                       -- (0-Trade-Trials)
  created_at TEXT NOT NULL
);
```

### Verfügbare DBs

| File                              | Strategy | Trials | Use case                  |
|-----------------------------------|----------|--------|---------------------------|
| `studies-bb_rsi.db`               | bb_rsi   | 1000   | Phase-3.2 production run  |
| `studies-bb_rsi_1h.db`            | bb_rsi   | ~1000  | 1h-TF-variant (A1)        |
| `studies-ut_bot.db`               | ut_bot   | ~1000  | Phase-3.2 production      |
| `studies-ut_bot_zerofee.db`       | ut_bot   | 500    | Zero-fee diagnostic (A2)  |
| `studies-ichimoku.db`             | ichimoku | ~1000  | Phase-3.2 production      |
| `studies-ichimoku-tpe.db`         | ichimoku | ~1000  | TPE-sampler variant (W3.5)|
| `studies-ichimoku-wf.db`          | ichimoku | ~1000  | Walk-forward W2           |
| `studies-ichimoku-wf-w3a.db`      | ichimoku | ~1000  | Walk-forward W3a          |

**1 Study pro DB** (verifiziert auf bb_rsi). Generisch trotzdem für N-Studies-pro-DB designen.

### Edge-Cases (KRITISCH)

- `score = -inf`: Trial mit 0 Trades. Dart `double.parse("-inf")` produziert `double.negativeInfinity` — beim Sortieren/Anzeigen abfangen.
- `total_trades = 0` mit `final_equity = 10000.0`: kein Trade, Initialbalance unverändert.
- `params_json` Wrapper: alle Werte unter `{"values": {...}}` — nicht direkt im Top-Level.
- `search_space_yaml` enthält `parameters:` (variable Ranges) + `fixed:` (fixe Werte) — für Param-Konvergenz nur `parameters`-Section relevant.

### Vorhandene Infrastruktur

- **Charts:** `fl_chart: ^0.70.2` im pubspec — bereits in Equity-Curve verwendet
- **State:** Provider-Pattern (`BacktestProvider` als Vorbild)
- **Logging:** `AppLog.error/.warn` ist global verfügbar (Commits `2c104bc` + `9f2902f`)
- **Theme:** `AppColors.*` in `lib/ui/themes/app_theme.dart`
- **Navigation:** `lib/main.dart` `_AppScaffold` mit `_NavItem` — neuer Tab dort hinzufügen

### Neue Dependencies (in `pubspec.yaml` zu addieren)

```yaml
dependencies:
  # SQLite (FFI for desktop — same engine as Optuna's writer)
  sqflite_common_ffi: ^2.3.0
  # File picker for DB selection
  file_picker: ^8.0.0
  # YAML parsing for search_space_yaml
  yaml: ^3.1.2
```

**Wichtig:** `sqflite_common_ffi` braucht `sqfliteFfiInit()` im `main()` *vor* `runApp`. Auf Linux ggf. `libsqlite3-dev` als System-Dep (in CI dokumentieren).

---

## 3. Commit-Plan (5-6 atomare Commits)

### COMMIT B2-1: Dependencies + DB-Layer

**Files:**
- `pubspec.yaml` — sqflite_common_ffi, file_picker, yaml
- `lib/core/models/study.dart` — `Study { id, name, strategy, searchSpaceYaml, createdAt, commitHash }`
- `lib/core/models/trial.dart` — `Trial { id, studyId, trialId, params: Map<String,double>, metrics: TrialMetrics, score, createdAt }`
- `lib/core/models/trial_metrics.dart` — typed Wrapper für metrics_json
- `lib/services/studies_db.dart` — `StudiesDb` class: `open(path)`, `listStudies()`, `listTrials(studyId, {limit, offset})`, `top10(studyId)`, `close()`
- `lib/main.dart` — `sqfliteFfiInit()` + `databaseFactory = databaseFactoryFfi` vor `runApp`

**Tests:**
- `test/services/studies_db_test.dart` mit Fixture-DB (kleine `.db` ins repo unter `test/fixtures/`, ~5 Trials, score-Mix inkl. `-inf`)
- `studies_db_test` deckt: open/close, listStudies count, listTrials parsing, top10 Sortierung mit `-inf`-Filter, malformed JSON → `AppLog.warn` + skip

**Commit msg:**
```
feat(phase-O3-B2): SQLite studies DB layer + typed models

Adds sqflite_common_ffi-backed StudiesDb for read-only access to the
Optuna-style studies/trials schema in 01_Projectplan/optimizer_studies/.
Models normalize params_json {"values":{...}} unwrapping, surface -inf
scores explicitly so the UI layer can filter, and route malformed-row
warnings through AppLog.
```

### COMMIT B2-2: StudiesProvider (State)

**Files:**
- `lib/features/studies/studies_provider.dart` — `ChangeNotifier`:
  - State: `dbPath`, `studies`, `selectedStudy`, `trials` (alle), `top10`, `isLoading`, `errorMessage`
  - Methoden: `Future<void> loadDb(String path)`, `void selectStudy(int id)`, `void clear()`
  - All async work in try/catch → `AppLog.error` + `_errorMessage`
- `lib/main.dart` — `ChangeNotifierProvider(create: (_) => StudiesProvider())` im MultiProvider

**Tests:**
- `test/features/studies/studies_provider_test.dart`: loadDb success, loadDb failure (bad path), selectStudy, clear

**Commit msg:**
```
feat(phase-O3-B2): StudiesProvider + main wiring

Provider holds the currently-loaded DB, available studies, trials, and
the derived top-10 view. Every catch routes through AppLog.error so
DB-open / schema-mismatch failures surface in the dashboard's System
Log panel.
```

### COMMIT B2-3: Studies-Screen Skeleton + Tab

**Files:**
- `lib/ui/screens/studies_screen.dart` (neu): 3-Section-Layout
  - Section A: DB-Picker (file_picker) + Studies-Dropdown + "Reload"-Button
  - Section B: Top-10-Tabelle (Placeholder, B2-4 füllt)
  - Section C: Param-Konvergenz-Plot (Placeholder, B2-5 füllt)
- `lib/main.dart` `_AppScaffold` — neuer Tab "Studies" mit Icon `Icons.analytics_outlined`/`Icons.analytics`

**Tests:**
- `test/ui/screens/studies_screen_test.dart`: rendert Empty-State (kein DB geladen), zeigt Loading-Indicator während `loadDb`, zeigt Error-Banner bei Provider-`errorMessage`

**Commit msg:**
```
feat(phase-O3-B2): Studies tab scaffold + DB picker

Adds a fifth nav item "Studies" with a three-section layout (picker,
top-10 placeholder, convergence placeholder). The picker uses
file_picker to select a .db from disk and delegates loading to
StudiesProvider. Sections B/C are filled in B2-4 and B2-5.
```

### COMMIT B2-4: Top-10-Tabelle

**Files:**
- `lib/ui/widgets/trials_top10_table.dart` — `DataTable` mit Spalten:
  - Rank, Trial ID, Score, Total Trades, Total PnL, Win Rate %, Sharpe, Max DD %, Profit Factor
  - Sortable per Spalte (DataTable native)
  - Tap-Row → ModalBottomSheet mit ALLEN Params + ALLEN Metrics (Trial-Detail-Sheet)
  - Score-Spalte: `-inf` → grau dargestellt mit Hinweis "no trades"
- `studies_screen.dart` integriert Widget in Section B

**Tests:**
- `test/ui/widgets/trials_top10_table_test.dart`: rendert 10 Rows, Sort funktioniert, Tap öffnet Sheet

**Commit msg:**
```
feat(phase-O3-B2): top-10 trials table with detail sheet

DataTable shows the top 10 trials by score (descending). Tapping a row
opens a bottom sheet with the full params/metrics dump. -inf scores
(0-trade trials) are rendered greyed-out so they don't dominate the
sort.
```

### COMMIT B2-5: Param-Konvergenz-Plot

**Files:**
- `lib/ui/widgets/param_convergence_plot.dart` — `fl_chart` `ScatterChart`:
  - x-axis = trial_id (0..N), y-axis = score (clamp -inf zu min_finite_score - 10%)
  - Optional: Param-Picker (Dropdown der Parameter aus search_space_yaml) → x=trial_id, y=Param-Wert, colored by score-bucket
  - Tooltip: Trial-ID + Params (kompakt) bei Hover/Tap
- `studies_screen.dart` integriert Widget in Section C
- `lib/core/utils/search_space.dart` (neu) — YAML-Parser für `search_space_yaml` → `List<ParamSpec { name, type, min, max }>`

**Tests:**
- `test/ui/widgets/param_convergence_plot_test.dart`: rendert ohne crash bei -inf-Werten, Param-Switch ändert Y-Axis-Datasource
- `test/core/utils/search_space_test.dart`: parsed BB+RSI / UT-Bot / Ichimoku Search-Spaces korrekt

**Commit msg:**
```
feat(phase-O3-B2): convergence scatter plot + search-space YAML parser

ScatterChart visualizes trial_id vs score, with an optional per-param
view that color-codes points by score-bucket. The search_space_yaml
column is parsed into typed ParamSpec entries so the UI can list only
the optimized parameters (excluding the `fixed:` section).
```

### COMMIT B2-6: End-to-End Smoke-Test

**Files:**
- `test/integration/studies_viewer_smoke_test.dart`:
  - Pump `StudiesScreen` mit `StudiesProvider` + test-fixture DB
  - Trigger `loadDb` → Erwarte Top-10 sichtbar
  - Tap erste Row → Erwarte Bottom-Sheet mit Params
  - Wähle Param im Convergence-Plot → Erwarte Chart-Update

**Commit msg:**
```
test(phase-O3-B2): end-to-end studies viewer smoke test

Drives the full B2 stack: DB load → top-10 table render → trial detail
sheet → convergence plot param switch. Uses the shared 5-trial fixture
DB from test/fixtures/.
```

---

## 4. Gates pro Commit

| Gate                                  | Erwartung                                                                       |
|---------------------------------------|---------------------------------------------------------------------------------|
| `flutter analyze`                     | 0 issues                                                                        |
| `cargo clippy --all-targets -- -D warnings` | 0 warnings (kein Rust-Touch, aber Standard-Gate)                          |
| `cargo test --release`                | alle grün (kein Rust-Touch)                                                     |
| `flutter test` (gesamt)               | alle vorhandenen grün + neue B2-Tests grün                                      |
| `phase1_reference_backtest_test`      | 8/8 grün, **91 Trades bit-exakt Dart↔Rust 1e-9** (FROZEN, KRITISCH)             |
| `dart_rust_*_parity_test`             | alle grün                                                                       |
| Push                                  | Direkt nach grünem Commit                                                       |

---

## 5. Eskalations-Stopp

Sofort STOPP + Diagnose-Brief wenn:

- `phase1_reference_backtest` bricht (KRITISCH, immer)
- DB-Open auf real existierender DB schlägt fehl mit Schema-Mismatch → unerwartete Schema-Version → **Diagnose**
- Trial-Score `-inf` propagiert ungefiltert in `fl_chart` → NaN/Inf Axis-Bounds → Renderer-Crash → **Robustheit fixen, dann Commit**
- `search_space_yaml` Parser bricht auf einer der echten DBs (z.B. Ichimoku) → YAML-Schema-Variation, der Parser muss tolerant sein → **Diagnose-Brief mit failing-payload**
- File-Picker auf Linux/macOS hängt oder produziert leere Path → ggf. dialog-init Reihenfolge zum `sqfliteFfiInit` → **Reihenfolge dokumentieren**
- Memory-Blow-up beim Laden einer 1000-Trial-DB ins Memory (alle Trials gleichzeitig) → **Pagination einbauen, Top-10 separat per `ORDER BY score DESC LIMIT 10`**

---

## 6. Endbericht (nach B2-6)

Brief an QA mit:
1. **5-6 Commit-Hashes** in Tabelle
2. **Test-Status-Tabelle** (alle Gates, finaler Stand)
3. **Manueller Smoke-Test-Aufgabe an Maik** (Start.bat starten, Studies-Tab öffnen, eine echte DB aus `01_Projectplan/optimizer_studies/` laden, Top-10 sichten, Convergence-Plot prüfen)
4. **Push-Status** (alle Commits auf origin/main?)
5. **Anomalien** (z.B. unerwartete Trial-Counts, Score-Edge-Cases, fehlende Studies)
6. **Empfehlung nächste Welle:** GO O3-B3 (Strategy-Management-Screen) oder Alternative

---

## 7. Aufwand & Risiko

- **Geschätzt:** 1 Session, 5-8h Engineering
- **Hauptrisiko:** `fl_chart` Axis-Robustheit bei `-inf` Scores — vor B2-5 prüfen
- **Sekundärrisiko:** `sqflite_common_ffi` Plattform-Init-Reihenfolge auf Linux — `sqfliteFfiInit()` strikt vor `WidgetsFlutterBinding.ensureInitialized()` und vor `file_picker`-Calls

---

## 8. Sign-off

QA-Koordinator wartet auf Maik-Sign-off bevor dieser Brief an parallel-CC weitergereicht wird.
