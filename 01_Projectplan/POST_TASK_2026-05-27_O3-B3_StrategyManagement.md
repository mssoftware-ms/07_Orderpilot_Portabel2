# Post-Task Welle O3-B3 — Strategy-Management-Screen (Apply-Trial-Loop)

**Issued:** 2026-05-27 by parallel-CC (WSL2)
**Recipient:** QA-Koordinator (Windows-CC) / Maik
**Branch:** `main` (alle 5 Commits gepusht auf `origin/main`)
**Base:** `b0a293f` (pre-task brief commit)

---

## 1. Commit-Hashes

| Commit | Hash | Subject |
|---|---|---|
| B3-1 | `234a0b4` | feat(phase-O3-B3): generalize applyOptimizedParams to all StrategyKinds |
| B3-2 | `dde0ae3` | feat(phase-O3-B3): strategy card widget with activate/apply/reset |
| B3-3 | `7a51a59` | feat(phase-O3-B3): apply-trial dialog with strategy-aware DB filter |
| B3-4 | `967f476` | feat(phase-O3-B3): strategy management screen as apply-trial hub |
| B3-5 | `6d93f93` | test(phase-O3-B3): end-to-end strategy management apply-trial loop |

Alle 5 Commits sind atomar, jeder läuft solo grün und ist auf `origin/main` gepusht (`git log` nach `b0a293f..HEAD` listet exakt diese 5).

---

## 2. Test-Status

### Finale Gates (nach B3-5, Top-Level)

| Gate | Stand | Detail |
|---|---|---|
| `flutter analyze` | ✅ Clean | 2 pre-existing `build/`-Issues (cargokit_build/ephemeral) — kein neuer Code |
| `flutter test` (gesamt) | ✅ **348 passed**, 0 failed, 34 skipped | +41 ggü. B2-Baseline (307) |
| `phase1_reference_backtest_test` | ✅ **8/8 grün** | 91 Trades bit-exakt Dart↔Rust 1e-9 — Frozen-Contract intakt |
| `dart_rust_parity_test` (BB+RSI) | ✅ grün | unverändert |
| `dart_rust_ut_bot_parity_test` | ✅ grün | unverändert |
| `dart_rust_ichimoku_parity_test` | ✅ grün | unverändert |
| `backtest_provider_test.dart` (B1-Tests) | ✅ grün | deprecated wrapper preserved no-op semantics |
| `cargo clippy --all-targets -- -D warnings` | ✅ 0 warnings | (kein Rust-Touch in B3) |
| `cargo test --release` | ✅ alle grün (398+ Tests insgesamt) | (kein Rust-Touch in B3) |

### Neue B3-Tests (zur Baseline 307)

| Datei | Tests | Status |
|---|---|---|
| `test/services/backtest_service_params_from_map_test.dart` | 13 | ✅ alle grün |
| `test/features/backtest/backtest_provider_apply_trial_test.dart` | 8 | ✅ alle grün |
| `test/ui/widgets/strategy_card_test.dart` | 7 | ✅ alle grün |
| `test/ui/widgets/apply_trial_dialog_test.dart` | 6 | ✅ alle grün |
| `test/ui/screens/strategy_management_screen_test.dart` | 6 | ✅ alle grün |
| `test/integration/strategy_management_smoke_test.dart` | 1 (e2e) | ✅ grün |
| **Total neu** | **41** | |

307 + 41 = 348 ✓ (deckt sich mit `flutter test`-Endergebnis).

---

## 3. Manuelle Smoke-Test-Aufgabe an Maik

Bitte über `Start.bat` (Windows) den vollen Loop einmal durchgehen:

1. **Tab "Strategies" öffnen** → 3 Karten sichtbar (BB+RSI, UT Bot, Ichimoku), aktive Karte hat grünes "Active"-Badge.
2. **BB+RSI-Karte → "Apply Trial"** → Dialog öffnet → "Pick .db" → `01_Projectplan/optimizer_studies/studies-bb_rsi.db` laden → Top-10 sichtbar → "Apply Selected Trial" → Dialog schließt → in **Backtest-Tab** sind die Params angepasst (siehe BB-Period / RSI-Werte).
3. **UT-Bot-Karte → "Apply Trial"** → Dialog öffnet → `studies-ut_bot.db` laden → "Apply Selected Trial" → Strategy-Tab zeigt UT-Bot als aktiv, Backtest-Tab hat UtBotParams + "Optimized" Pille.
4. **Ichimoku-Karte → "Apply Trial"** → `studies-ichimoku.db` laden → Apply → analog.
5. **Cross-Strategy-Apply (Warnung-Pfad)**: UT-Bot-Karte → Apply Trial → `studies-bb_rsi.db` laden → gelbes Warning-Banner ("This study targets `bb_rsi` but you are applying it to UT Bot…") wird angezeigt. Wer trotzdem Apply klickt: BacktestProvider hält **typisierte UtBotParams** (fehlende Keys → Defaults), kein Crash.
6. **Quicklinks**: "Open Studies viewer" (Header) → Studies-Tab. "Open Backtest" (Footer) → Backtest-Tab. Beide Tabs schalten via `AppNavigation`-Provider um.
7. **Reset-Button**: nach Apply Trial → "Reset" auf der Karte zurücksetzen → Params zurück auf Default, "Optimized"-Pille verschwindet.

Erwartung: alles fluide, kein file_picker-Hänger (Init-Reihenfolge identisch zu B2), keine Crashes bei Cross-Strategy-Apply.

---

## 4. Push-Status

```text
b0a293f..6d93f93  main -> main
```

Alle 5 Commits sind auf `origin/main`. `git status` zeigt nur:
- `.claude/` (untracked, Skill-Konfig — nicht für Repo gedacht)
- `01_Projectplan/Trading Strategie Analyse.xlsx` (modified — **NICHT von B3 geändert**, kam von Maik während der Session)

Working tree damit sauber bzgl. B3.

---

## 5. Anomalien

### Inhaltlich
- **`applyOptimizedParams` Backward-Compat**: Der Pre-Task-Brief schlug einen 1:1 Delegationspfad zum neuen `applyTrialAsParams` vor. Das hätte die B1-Test "no-ops when active strategy is not BB+RSI" gebrochen (`applyTrialAsParams` switcht die Strategy). Lösung: Der deprecated Wrapper bewahrt explizit die Welle-O3-B1-Semantik (silent no-op auf nicht-BB+RSI) **vor** der Delegation. B1-Tests bleiben grün.
- **Map<String, double>-Vergleich**: Dart vergleicht Maps via Referenzgleichheit. `BbRsiParams().toMap() == BbRsiParams().toMap()` ist `false`. Verwendet `foundation.mapEquals` in `StrategyCard._paramsDifferFromDefaults`.
- **Chip-Inhalt in RichText nicht via `find.text` findbar**: Initial mit `RichText` gebaut → Test-Failure. Auf Row + zwei `Text`-Widgets refactored.
- **Cross-Strategy-Apply mit fehlenden Keys**: `applyTrialAsParams(kind: utBot, trial: <bb_rsi-Trial>)` produziert eine `UtBotParams`-Instanz mit fehlenden UT-Bot-Keys aus Defaults gefüllt. AppLog.warn loggt die unbekannten Keys (`bb_period`, `bb_stddev`, `rsi_period`) — kein Crash, Engine-Lauf wäre semantisch sinnlos aber strukturell wohldefiniert.

### Architektur-Eingriff
- **`AppNavigation`-Provider neu**: Damit das Strategy-Management-Screen den "Open Studies viewer"-Quicklink anbieten kann, brauchte es eine schmale Cross-Screen-Tab-Steuerung. `lib/core/navigation/app_navigation.dart` (24 Zeilen) + Anpassung `lib/main.dart`. Tab-Order in `AppTab`-Enum spiegelt `_AppScaffoldState._screens` — wenn dort jemals umsortiert wird, muss das Enum mit. Test `widget_test.dart "App scaffold renders with navigation"` bleibt grün.

### Untouched
- **`ruvector.db` (B2.1)** noch nicht angefasst.
- **`searchSpaceYaml` Parsing** unverändert seit B2.
- **Rust-Engine** komplett unverändert (kein clippy/cargo-Touch).

---

## 6. Empfehlung nächste Welle

Vorzugsreihenfolge nach aktuellem Stand:

1. **B4: Paper-Trading-Modul Step-1** (höchster User-Value, schließt den letzten großen UX-Gap; B3 hat den Apply-Trial-Loop sauber abgedichtet, B4 baut darauf auf, weil Paper-Trading exakt diese applied Params live spielt). Empfohlen wenn die manuelle B3-Smoke-Validation durchläuft.
2. **A1.1 + A1.2 ADX-Sub-Sweep** (orthogonale Engineering-Welle, kein UI-Risk, gut parallelisierbar; bringt scharfere Optimizer-Ergebnisse, die B3 direkt verarbeitet). Empfohlen wenn der Optimizer-Output-Quality-Hebel höher priorisiert ist als neue UI-Surface.
3. **B2.1 ruvector.db** (zieht nach wenn Vector-Search im Studies-Tab gewünscht ist; nicht blockierend für B4).
4. **Phase-4-Prep**: Kann warten bis Paper-Trading läuft — sonst plant man Phase 4 ohne Live-Daten-Signal.

**Persönliche Empfehlung von parallel-CC:** B4 als nächstes, damit der vollständige Loop CLI-Optimizer → Studies → Strategy-Management → Backtest → Paper-Trading geschlossen ist. Danach A1.1/A1.2 für Optimizer-Quality.

---

## 7. Sign-off

parallel-CC fertig. Brief liegt zur QA-Validierung bereit.
