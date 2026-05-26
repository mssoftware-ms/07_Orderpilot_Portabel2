# HANDOFF — Offene Punkte + KI-Prompt für Weiterarbeit

**Erstellt:** 2026-05-26
**Repo:** `D:\03_Git\02_Python\07_Orderpilot_Portabel2` (Windows lokal) / `github.com/mssoftware-ms/07_Orderpilot_Portabel2`
**Aktueller Stand:** HEAD = `403e5b7` (Tag `v0.5.1-fee-realism-validated`), main synced mit origin, working tree clean außer `.claude/` untracked
**Zweck dieser Datei:** Vollständige Übergabe an eine neue KI-Session. Alles was nötig ist, um Phase-3.2-Backlog oder Phase-4-UI-Welle zu starten, ist hier verlinkt.

---

## Inhaltsverzeichnis

1. [Projekt-Kontext in 60 Sekunden](#1-projekt-kontext-in-60-sekunden)
2. [Abgeschlossene Phasen — Tag-Chain](#2-abgeschlossene-phasen--tag-chain)
3. [Aktueller Repo-Stand](#3-aktueller-repo-stand)
4. [Engineering-Assets (wiederverwendbar)](#4-engineering-assets-wiederverwendbar)
5. [Backlog — offene Punkte priorisiert](#5-backlog--offene-punkte-priorisiert)
6. [Empfohlener nächster Schritt: Welle O3-B1 (UI multi-strategy)](#6-empfohlener-nächster-schritt-welle-o3-b1)
7. [Detaillierter Pre-Task Welle O3-B1](#7-detaillierter-pre-task-welle-o3-b1)
8. [Workflow-Konventionen](#8-workflow-konventionen)
9. [Critical Knowledge — Gotchas und Lessons Learned](#9-critical-knowledge--gotchas-und-lessons-learned)
10. [Wichtige Datei-Referenzen](#10-wichtige-datei-referenzen)
11. [Prompt für die nächste KI-Session](#11-prompt-für-die-nächste-ki-session)

---

## 1. Projekt-Kontext in 60 Sekunden

**OrderPilot Portabel2** ist eine private Single-User-Trading-App (Trade-Republic-artige UX) für BTC-Backtesting.

**Stack:**
- **UI:** Flutter/Dart (Windows + mobile-ready)
- **Engine:** Rust `trading_engine` via `flutter_rust_bridge` 2.12.0
- **Persistence:** SQLite (`rusqlite` mit `bundled`-Feature)
- **Optimizer:** Random-Search + Walk-Forward + TPE + PBO/DSR (alles Rust-nativ)
- **Daten:** BTCUSDT von Binance (Cache als JSON in `01_Projectplan/optimizer_data/`)
- **Fees:** Bitunix VIP0 — Taker 0.06%, Maker 0.02%

**Strategien (alle Pfad-C-klassifiziert, mit unterschiedlichen Failure-Modes):**
- BB+RSI v3 (verbesserte Variante, Trendfolge mit BB(EMA200, σ=0.2)+RSI(3))
- UT Bot v1 (Trail-Stop + SMI-Confluence)
- Ichimoku Cloud (Retest-Endstand, 5-Confluence + Score)

**Engine-shared:** ADX-Regime-Filter, within_session, swing_low/high, BE-Trail, position_size_pct, EMA, ATR, SMI, Tenkan/Kijun/Senkou-A/B/Chikou, Ichimoku-Score.

**Rollenverteilung:**
- **Maik (User):** Projekt-Owner, moderiert
- **Claude Code CLI (WSL2/tmux):** Code-Operationen
- **Claude Chat Desktop (QA-Rolle):** Plan-Owner, Pre-Tasks, Brief-Reviews, Git-Operationen via Windows-MCP:PowerShell

---

## 2. Abgeschlossene Phasen — Tag-Chain

| Tag | Commit | Output | Schlüssel-Lesson |
|---|---|---|---|
| `v0.2.0-engine-correct` | `9bfffee` | Engine-Korrektheit (F-01..F-09) | Bug-Maskierung-Kaskade-Pattern: 6 Schichten hinter einem sichtbaren Bug |
| `v0.3.0-strategies-verified` | `3b081c4` | 3 Strategien + ADX-Filter | Video-Strategien sind asset-spezifisch (NQ/Forex ≠ BTC) |
| `v0.4.0-optimizer-mvp` | `bf8edbf` | Random-Search-Optimizer | Cross-Process-Determinismus-Bug (HashMap → BTreeMap) |
| `v0.5.0-walk-forward-validated` | `d2d7832` | Walk-Forward + TPE + PBO/DSR | Bailey-de-Prado empirisch: Single-Period-Top-N predicts OOS NICHT |
| `v0.5.1-fee-realism-validated` | `403e5b7` | BB+RSI 1h + UT-Bot 0%-Fee | Maker-Extrapolation closed-form spart Sweep-Compute |

### Phasen-Beschreibung kompakt

**Phase 1 (Engine-Korrektheit):** 18 Commits über 10 Findings. Reference-Baseline frozen: BTCUSDT 1h 2024-H1, BB(20,2σ)+RSI(14,30/70), 4369 candles → 91 Trades, -2071.38 USDT, WR 18.68%, MaxDD 24.68%, finalEquity 7928.62 USDT. **Dieser Wert ist Regression-Guard** für alle nachfolgenden Engine-Änderungen.

**Phase 2 (Strategien):** BB+RSI v3, UT Bot v1, Ichimoku implementiert. Alle 3 verfehlen XLSX-Targets auf BTCUSDT.

**Phase 2.5 (ADX-Regime-Filter, Welle R1-R4):** ADX als universeller Hebel. UT-Bot Vorzeichen-Flip -15% → +3%. Ichimoku DD halbiert. BB+RSI PF von 1.22 auf 4.88. ABER: Trade-Volumes kollabieren als Kollateral.

**Phase 3 MVP (Welle O1+O2):** Random-Search-Optimizer mit YAML-Search-Spaces + SQLite. 2500 Trials total × 10.7h Compute. Ichimoku als Pfad-B-Kandidat identifiziert (Top-1 PF 2.008, Lücke 0.12 zu XLSX-Schwelle 2.14).

**Phase 3.1 (Walk-Forward + TPE + Statistical Gates, Welle W1-W4):** Vollständige Validation-Pipeline. Welle-O2-Top-1 (Trial 515) ist Walk-Forward Rang 6 mit `worst_oos_pf=0.021` — **Bailey-de-Prado empirisch belegt**. TPE-Warm-Start ~13× Multiplier validiert. Welle W4: Pool-PBO = 1.0000, Top-1 DSR = 0.207 — kein Production-Default-Kandidat trotz aller Optimierung.

**Phase 3.2 (Strukturanpassung, Welle A1+A2):** BB+RSI 1h erreicht Pfad C mit edge-positivem Lab-Charakter (Top-1 PF 1.545, Sharpe +1.78). UT-Bot Fee-Realismus: bei tp_rr_ratio=3.20 ist Break-Even-WR 23.8%, Top-1 WR=19.23% — strukturell broken, Fee nicht dominanter Treiber.

---

## 3. Aktueller Repo-Stand

**HEAD:** `403e5b7` docs(phase-3.2): ut_bot fee-realism + Pfad-C strict confirmation Welle A2
**Tag aktuell:** `v0.5.1-fee-realism-validated`
**Working tree:** clean, nur `.claude/` untracked (kann ignoriert werden)
**Branch:** main, synced mit origin/main

**Pre-existing Issues (nicht-blockierend):**
- `build/windows/.../cargokit_build/*` flutter analyze Warnungen (auto-generierte Build-Artefakte, gitignored, kein Source-Code)
- `test/integration/dart_rust_parity_test.dart` BB+RSI Sinus-Fixture skipped (Welle I2-3 dokumentiert in `bb_rsi_diagnose_2026-05-23.md`)

**Letzte 6 Commits (Phase 3.2):**
```
403e5b7 docs(phase-3.2): ut_bot fee-realism + Pfad-C strict confirmation Welle A2
7bc9a22 data(phase-3.2): ut_bot 500-trial zero-fee sweep (fee-driver validation)
bdad505 feat(phase-3.2): production_sweep ut_bot fee-variant support
4cdbbb0 docs(phase-3.2): bb_rsi 1h path classification + spec §13.8 Welle A1
57329f5 data(phase-3.2): bb_rsi 1000-trial sweep on BTCUSDT 1h (TF-mismatch validation)
5c0596a feat(phase-3.2): production_sweep tf-variant support + bb_rsi 1h variant
```

---

## 4. Engineering-Assets (wiederverwendbar)

### Rust-Engine (`rust/trading_engine/`)

**Strategien (in `src/addins/`):**
- `bb_rsi.rs` — BB+RSI v3, ~750 LOC
- `ut_bot.rs` — UT-Bot v1 mit SMI, ~900 LOC
- `ichimoku.rs` — Ichimoku Cloud mit Score, ~1200 LOC
- `common.rs` — `within_session`, ADX (`calc_adx`, `AdxOutput`), `regime_passes_filter`
- `mod.rs` — Strategy Registry

**Optimizer (in `src/optimizer/`):**
- `mod.rs` — Domain Types (SearchSpace, TrialParams, TrialMetrics, ScoreConstraints, TrialResult)
- `runner.rs` — `run_optimization_trial` Single-Run-Wrapper
- `random_search.rs` — Random-Search-Engine mit seeded RNG
- `storage.rs` — SQLite-Persistence (`studies`, `trials`, `walk_forward_trials` Tabellen)
- `scoring.rs` — Composite-Score mit Disqualifikation (PF + Sharpe-Bonus, max_dd_cap, min_trades)
- `walk_forward.rs` — Rolling-Window-Splitter + Trial-Runner + 3 Stability-Score-Methoden (MeanStdPenalty / MedianIqr / TrimmedMean)
- `tpe.rs` — Rust-native TPE-Engine mit Box-Muller KDE, warm_start, suggest, report
- `stat_gates.rs` — PBO (CSCV combinatorial) + DSR (Bailey-2014 closed-form)

**CLIs (in `examples/`):**
- `production_sweep.rs` — Strategy × Search-Space × Variant Sweep (BB+RSI main/1h, UT-Bot main/zerofee/maker, Ichimoku main)
- `sweep_benchmark.rs` — Compute-Bench für Trial-Wrapper
- `walk_forward_replay.rs` — Welle-O2-DB → Walk-Forward → Survivor-Spec
- `tpe_walk_forward_run.rs` — Survivor-Pool → TpeEngine.warm_start → 200-Trial-Production-Run
- `stat_gates_run.rs` — Union-Pool → PBO + DSR
- `mini_sweep_report.rs` — Diagnostic-CLI für Sweep-Sanity-Checks

**Dependencies (Cargo.toml):**
```toml
flutter_rust_bridge = "=2.12.0"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
chrono = { version = "0.4", features = ["serde"] }
anyhow = "1"
log = "0.4"
rand = "0.8"
serde_yaml = "0.9"
rusqlite = { version = "0.31", features = ["bundled"] }
[dev-dependencies]
tempfile = "3"
tokio = { version = "1", features = ["full"] }
```

### Flutter UI (`lib/`)

**Bestehende Struktur:**
- `lib/main.dart` — App-Entry mit MultiProvider + AppScaffold (BottomNav + NavigationRail)
- `lib/core/` — Constants, Models (Candle), Utils (param_storage)
- `lib/features/backtest/backtest_provider.dart` — ChangeNotifier mit BacktestConfig + hardcoded BbRsiParams
- `lib/services/` — backtest_service.dart (~66 KB, BB+RSI/UT-Bot/Ichimoku alle gemirrort), binance_api_client.dart, equity.dart, indicators.dart, optimization_service.dart (FROZEN-Banner), rust_bridge.dart, sharpe.dart, strategy_common.dart
- `lib/ui/screens/` — home_screen, chart_screen (Coming-Soon), backtest_screen (42 KB, voll-funktional aber BB+RSI-only), paper_trading_screen (Coming-Soon), strategy_management_screen (Placeholder)
- `lib/ui/widgets/` — equity_curve_chart, metric_card, optimization_results_dialog, trade_log_list
- `lib/ui/themes/app_theme.dart`

**Tests:**
- `test/services/*` — Unit-Tests pro Service
- `test/integration/` — phase1_reference_backtest_test, dart_rust_ut_bot_parity_test, dart_rust_ichimoku_parity_test, regime_filter_sweep_test
- 226+ Dart-Tests grün

### Studies-DBs (commitiert in `01_Projectplan/optimizer_studies/`)

- `studies-bb_rsi.db` — Welle O2 BB+RSI 4h 1000 Trials
- `studies-ut_bot.db` — Welle O2 UT-Bot 5m 500 Trials
- `studies-ichimoku.db` — Welle O2 Ichimoku 1h 1000 Trials
- `studies-ichimoku-wf.db` — Welle W2 109 Walk-Forward-Trials
- `studies-ichimoku-wf-w3a.db` — Welle W3a mit MedianIqr + 2196-bar Validate
- `studies-ichimoku-tpe.db` — Welle W3.5 200 TPE-Trials
- `studies-bb_rsi_1h.db` — Welle A1 BB+RSI 1h 1000 Trials
- `studies-ut_bot_zerofee.db` — Welle A2 0%-Fee 500 Trials
- `stat_gates_results.db` — Welle W4 86 Trials Union-Pool

### Daten-Cache (commitiert in `01_Projectplan/optimizer_data/`)

- `BTCUSDT_4h_2024-01-01_2024-07-01.json` — ~1086 Candles
- `BTCUSDT_5m_2024-01-01_2024-03-08.json` — ~19000 Candles
- `BTCUSDT_1h_2024-01-01_2024-07-01.json` — ~4385 Candles
- `BTCUSDT_1h_2023-04-01_2025-05-02.json` — ~18289 Candles

---

## 5. Backlog — offene Punkte priorisiert

### Priorität HOCH (User-sichtbare Lücken)

| ID | Titel | Aufwand | Wertbeitrag |
|---|---|---|---|
| **O3-B1** | UI Backtest-Screen multi-strategy (UT-Bot + Ichimoku + ADX-Toggle) | 1-2 Sessions | Bestehende UI auf Engine-Stand bringen |
| **O3-B2** | Studies-Viewer-Screen (lädt `.db` → Top-10 + Param-Konvergenz) | 1 Session | 5 Monate Engineering-Output visuell |
| **O3-B3** | Strategy-Management-Screen mit echten Strategien (statt Placeholder) | 0.5 Session | Strategien aus Engine listen |

### Priorität MITTEL (analytische Strukturanpassung)

| ID | Titel | Aufwand | Wertbeitrag |
|---|---|---|---|
| **A1.1** | BB+RSI Welle A1.1 — ADX optional im Search-Space | 3-4h Engineering + 30min Compute | Klärt ob ADX always-on der Trade-Cutter ist |
| **A1.2** | BB+RSI Welle A1.2 — ADX-Threshold-Lowering Sub-Sweep | 2-3h Compute | Diagnose-Wert für ADX-Threshold-Sensitivity |
| **A3** | Alternative Strategy-Discovery aus XLSX (Top-4 bis Top-20) | offen, 1-3 Wochen | Möglicherweise Crypto-native Strategien tiefer im Ranking |

### Priorität NIEDRIG (Phase-4-Vorbereitung)

| ID | Titel | Aufwand | Wertbeitrag |
|---|---|---|---|
| **P4-Live** | Paper-Trading-Modul (echter Bitunix-Connector, Welle-O3-Status erstmal Coming-Soon) | 2-4 Wochen | Live-Trading-Vorbereitung |
| **P4-Chart** | Chart-Screen mit Live-Daten (Coming-Soon-Banner durch echte Chart-Lib ersetzen) | 1-2 Wochen | Trade-Republic-UX-Equivalent |
| **P4-Strict-Maker** | Strict-Maker-Modeling (probabilistic fill, statt assume-filled) | 1-2 Wochen | Realistischere UT-Bot/Ichimoku Backtests |
| **Spec-13.7-WR** | XLSX-Spec-Update: WR-Bänder von Forex 50-60% auf BTC-Realismus 30-40% korrigieren | 0.5 Session | Konsistenz-Wert |

### Phase-3-Tail-Backlog (deferred, möglicherweise nie)

| ID | Titel | Bemerkung |
|---|---|---|
| W4.5 | Erweiterte TPE-Caps (kijun, tp_rr_ratio über Welle-O2-§5.2-Schneidung) | NICHT empfohlen: PBO=1.0 obsolet Cap-Erweiterung |
| UT-A2.1 | UT-Bot Maker-Sweep | NICHT empfohlen: predicted PF~1.10 via closed-form, predictiv-redundant |
| UT-A2.2 | UT-Bot ETH-5m / BTC-15m Asset-Wechsel | NICHT empfohlen: duplikative Sample-Space-Lottery |
| UT-A2.3 | UT-Bot Search-Space-Bias auf selektiveres Regime | NICHT empfohlen: gleicher Grund |

---

## 6. Empfohlener nächster Schritt: Welle O3-B1

**Ziel:** Bestehender Backtest-Screen wird multi-strategy. UT-Bot + Ichimoku werden im UI wählbar, ADX-Filter-Toggle erscheint, Param-Sliders/Inputs pro Strategie.

**Warum jetzt B1 statt B2:**
1. UI ist BB+RSI-only — Engineering-Schuld die Maik beim Testen sofort sieht
2. UT-Bot + Ichimoku im Backtest-Screen macht Phase-2-Arbeit erfahrbar
3. ADX-Toggle ist trivial im Code, hat aber hohen UX-Wert (Welle-R3/R4-Effekt unmittelbar sichtbar)
4. Etabliert das Pattern für später (B2 Studies-Viewer kann darauf aufbauen)

**Welle-O3-B1-Skizze:**
- B1-1: BacktestProvider generisches Strategy-Params-Model (statt hardcoded BbRsiParams)
- B1-2: BacktestScreen Strategy-Dropdown + dynamische Param-Section
- B1-3: ADX-Filter-Toggle in jedem Strategy-Param-Set
- B1-4: Smoke-Test: Backtest auf allen 3 Strategien funktioniert end-to-end

**Compute:** keine (UI-Code), nur Smoke-Tests im Backtest-Modus

**Aufwand:** 1-2 Sessions (6-10h Engineering)

---

## 7. Detaillierter Pre-Task Welle O3-B1

```
Phase 3.2 abgeschlossen mit v0.5.1-fee-realism-validated. Phase O3 öffnet
mit UI-Multi-Strategy-Erweiterung des Backtest-Screens.

Wir sind auf main (HEAD = 403e5b7). Working tree clean außer .claude/.
Direkt auf main, atomare Commits, push nach jedem grünen Commit.

GESAMT-SCOPE Welle O3-B1: 4-5 atomare Commits, ~6-10h Engineering.

KONTEXT:
  - lib/ui/screens/backtest_screen.dart ist ~42KB, BB+RSI-only
  - lib/features/backtest/backtest_provider.dart hardcoded BbRsiParams
  - lib/services/backtest_service.dart hat runBbRsi + runUtBot + runIchimoku
    alle gemirrort vom Rust-Code
  - Rust-Engine via rust_bridge.dart hat run_bb_rsi_backtest +
    run_ut_bot_backtest + run_ichimoku_backtest verfügbar
  - 4 ADX-Manifest-Params in allen 3 Strategien (Welle R2):
    adx_filter_enabled, adx_threshold, adx_period, adx_use_di_confluence
  - Default-Welle-R3-Werte: enabled=true für ADX, threshold=25, period=14,
    use_di_confluence=false

COMMIT-PLAN:

  COMMIT B1-1: Generisches Strategy-Params-Model
  
    lib/features/backtest/backtest_provider.dart refactor:
    - BacktestConfig.strategyParams: dynamic (statt typed BbRsiParams)
    - Neuer Enum StrategyKind { bbRsi, utBot, ichimoku }
    - BacktestConfig erhält strategyKind: StrategyKind Field
    - Default-Params pro Strategy als const-Map oder Factory:
      - bbRsiDefaults() -> BbRsiParams
      - utBotDefaults() -> UtBotParams
      - ichimokuDefaults() -> IchimokuParams
    - Helper convertToJson(strategyKind, params) für Rust-Bridge-Call
    
    Tests:
    - BacktestConfig.copyWith Strategy-Wechsel reset Param-Defaults korrekt
    - JSON-Serialization aller 3 Param-Typen
    - Existing BB+RSI-Tests bleiben grün (backward-compat)
    
    "feat(phase-O3): generic strategy params model in BacktestProvider"

  COMMIT B1-2: Strategy-Dropdown in BacktestScreen
  
    lib/ui/screens/backtest_screen.dart:
    - DropdownButton<StrategyKind> mit 3 Optionen (BB+RSI, UT Bot, Ichimoku)
    - onChange triggert provider.setStrategyKind() → Default-Params laden
    - StrategyParamSection-Widget (neu) pro Strategy
    - StrategyParamSection delegiert zu BbRsiParamSection, UtBotParamSection,
      IchimokuParamSection (jeder Sub-Widget)
    - Bestehende BB+RSI-Param-Inputs in BbRsiParamSection extrahieren
    
    Tests:
    - Strategy-Dropdown-Wechsel zeigt korrekte Param-Section
    - Default-Werte erscheinen pro Strategy
    
    "feat(phase-O3): strategy dropdown + per-strategy param sections"

  COMMIT B1-3: UT-Bot + Ichimoku Param-Sections
  
    lib/ui/widgets/ut_bot_param_section.dart (neu):
    - TextFields/Sliders für key_value, atr_period, smi_length, smi_k,
      smi_d, swing_lookback_bars, tp_rr_ratio, risk_per_trade
    - Validation: numeric, ranges per Spec
    
    lib/ui/widgets/ichimoku_param_section.dart (neu):
    - TextFields/Sliders für tenkan_period, kijun_period, senkou_b_period,
      shift, score_threshold, tp_rr_ratio, risk_per_trade,
      swing_lookback_bars
    - Validation: numeric, ranges per Spec
    
    BacktestScreen importiert beide neuen Widgets
    
    Tests:
    - Jeder Widget rendert mit Default-Werten
    - Validation-Error bei Out-of-Range-Input
    
    "feat(phase-O3): UT-Bot + Ichimoku param section widgets"

  COMMIT B1-4: ADX-Filter-Toggle (engine-shared section)
  
    lib/ui/widgets/adx_filter_section.dart (neu):
    - Switch: ADX-Filter enabled
    - Slider (or TextField): adx_threshold 0-50
    - Slider (or TextField): adx_period 7-30
    - Switch: use_di_confluence
    - Erscheint UNTERHALB der Strategy-spezifischen Param-Section
    - Common für alle 3 Strategien
    - Default: enabled=true, threshold=25, period=14, di_confluence=false
    
    BacktestScreen + alle Strategy-Param-Sections rendern ADX-Section
    
    Tests:
    - ADX-Toggle on/off ändert Backtest-Run-Result (Smoke)
    - Defaults korrekt
    
    "feat(phase-O3): engine-shared ADX filter section widget"

  COMMIT B1-5: End-to-End Smoke-Test
  
    test/integration/multi_strategy_ui_smoke_test.dart (neu):
    - Render BacktestScreen
    - Wähle BB+RSI → Run → Result enthält Trades
    - Wähle UT Bot → Run → Result enthält Trades
    - Wähle Ichimoku → Run → Result enthält Trades
    - Toggle ADX off → Re-Run → Trade-Count anders als mit ADX
    
    "test(phase-O3): end-to-end multi-strategy UI smoke test"

PRO COMMIT:
  - flutter analyze: 0 issues
  - cargo clippy --all-targets -- -D warnings: 0 warnings
  - cargo test --release: alle grün
  - flutter test: alle grün
  - phase1_reference_backtest STRUKTURELL grün (KRITISCH:
    91 Trades, -2071.38 USDT, bit-exakt zu Phase-1-Baseline)
  - dart_rust_ut_bot_parity 3/3 grün
  - dart_rust_ichimoku_parity 4/4 grün
  - regime_filter_sweep_test 7/7 + 12 ADX skipped
  - Push direkt nach grünem Commit

ENDE DIESER SESSION nach B1-5: Brief an QA mit:
  - 4-5 Commit-Hashes
  - Manueller Smoke-Test-Result (User hat App mit Start.bat gestartet,
    alle 3 Strategien durchgelaufen?)
  - Empfehlung: GO Welle O3-B2 (Studies-Viewer) oder andere Welle

ESKALATIONS-STOPP wenn:
  - phase1_reference_backtest bricht: KRITISCH, sofort STOPP
  - dart_rust_*_parity_tests brechen: sofort STOPP
  - JSON-Param-Konvertierung produziert NaN/Inf in Engine-Aufruf:
    Diagnose-Brief
  - UT-Bot oder Ichimoku UI-Run produziert 0 Trades auf Standard-Daten:
    möglicherweise Param-Mapping-Bug, Diagnose-Brief
```

---

## 8. Workflow-Konventionen

### Pre-Task → Brief → Sign-off Pattern

1. **QA (Claude Desktop)** schreibt einen detaillierten Pre-Task mit:
   - Scope-Definition
   - Commit-Plan
   - Pro-Commit-Gates
   - Eskalations-Stopp-Bedingungen
   - Erwartete Brief-Inhalte am Ende

2. **CC (Claude Code CLI)** führt aus und liefert einen Brief mit:
   - Commit-Hashes
   - Compute-Times
   - Output-Tabellen
   - Gate-Status
   - Empfehlung für nächste Welle

3. **QA reviewt und gibt Sign-off**, ggf. mit Plan-Anpassungen oder Tag-Setzung.

### Atomare Commits

- Eine Änderung = ein Commit = ein Push
- Commit-Message-Convention: `<type>(<phase>): <subject>` z.B. `feat(phase-3.2): ...`
- Push nach jedem grünen Commit (kein Batch-Push am Ende)

### Auto-Mode-Classifier Block

- Direkter `git push origin main` wird manchmal vom Auto-Mode geblockt
- Falls geblockt: QA pushed manuell via Windows-MCP:PowerShell
- Falls Tag-Setzung mit großer Heredoc-Message hängt: write_file für temp-message, dann `git tag -F`

### Gates pro Commit (verpflichtend, in dieser Reihenfolge prüfen)

```bash
flutter analyze                               # 0 issues
cd rust/trading_engine
cargo clippy --all-targets -- -D warnings    # 0 warnings
cargo test --release                          # alle grün
cd ../..
flutter test                                  # alle grün
# Plus: phase1_reference_backtest darf NIE brechen
# Plus: dart_rust_*_parity_tests dürfen NIE brechen
```

### `tool/build_rust.sh` verwenden

Vor jedem Rust-Engine-Wechsel der Dart-Verhalten beeinflussen kann:
```bash
bash tool/build_rust.sh release
```
Sonst kann eine stale `libtrading_engine.so` falsche Backtests liefern (Welle-R4-Lesson).

---

## 9. Critical Knowledge — Gotchas und Lessons Learned

### Knowledge die jede neue KI-Session zuerst lesen sollte

1. **Phase-1-Reference-Backtest ist FROZEN Regression-Guard.**
   91 Trades, -2071.38 USDT, WR 18.68%, MaxDD 24.68%, finalEquity 7928.62 USDT.
   Auf BTCUSDT 1h 2024-H1 4369 Candles mit BB(20,2σ)+RSI(14,30/70) Strict-Spec.
   **Wenn dieser Test bricht: sofort STOPP, revert.**

2. **flutter test invokiert KEIN cargo build.**
   Welle-R4-Lesson: Rust-Engine-Änderungen brauchen explizites `cargo build --release --lib` oder `tool/build_rust.sh release`. Drei Schutzmaßnahmen sind im Repo:
   - `tool/build_rust.sh` Wrapper
   - `setUpAll`-Staleness-Guard in `regime_filter_sweep_test.dart`
   - `regression_adx_real_data.rs` Rust-side Pin

3. **HashMap-Iteration ist NICHT cross-process deterministisch.**
   Welle-O2-fix (Commit `4a2e131`): `SearchSpace.parameters` als BTreeMap, nicht HashMap. Sonst produziert Optimizer bei gleichem Seed unterschiedliche Top-N je Prozess-Run. `regression_optimizer_determinism.rs` ist der Pin.

4. **Cross-Process-Determinismus = REAL-Columns bit-exakt + JSON ≤1 ULP.**
   `serde_json+ryu` benutzt shortest-roundtrip, nicht bit-exakt für Floats. Persistence-Contract ist:
   - REAL-Columns in SQLite: bit-identisch
   - JSON-Floats in `params_json` / `splits_json`: ≤ 1 ULP
   Diese Konvention ist in `integration_walk_forward.rs` gepinnt.

5. **Bailey-de-Prado empirisch belegt: Single-Period-Top-N predicts OOS NICHT.**
   Welle-W2-Lesson: Welle-O2-Top-1 (Trial 515) ist Walk-Forward Rang 6 mit `worst_oos_pf=0.021`. **Vor jeder Production-Default-Entscheidung muss Walk-Forward + PBO/DSR durchlaufen sein.** Phase 3.1 Welle W4 zeigte: Pool-PBO=1.0 ist möglich auch bei plausibel-aussehenden Top-Trials.

6. **ADX-Threshold konvergiert in 28-36 über alle 3 Strategien.**
   Welle-O2-Cross-Strategy-Insight. DI-Confluence ist redundant auf BTC. ADX-Filter ist universeller Hebel aber Volume-Killer.

7. **Strategy Path-C-Klassifikationen sind ALLE auf BTC strukturell, nicht „funktioniert nicht".**
   - BB+RSI: edge-positive Lab-Kandidat, XLSX-Trade-Band + PF-Band nicht gleichzeitig erreichbar mit always-on ADX
   - UT-Bot: WR (19.23%) < Break-Even-WR (23.8% bei tp_rr=3.2), strukturell broken
   - Ichimoku: Pool-PBO=1.0, statistisch nicht von Random Chance unterscheidbar bei 86 Trials × 6 OOS-Splits

8. **Don't reproduce engine-shared helpers — use them.**
   Bei UI-Erweiterungen oder neuer Strategie immer:
   - `common::within_session` für Session-Filter
   - `common::calc_adx` + `common::AdxOutput` für ADX
   - `common::regime_passes_filter` für ADX-Filter-Check
   - `swing_high`/`swing_low` (in bb_rsi.rs aber engine-shared semantik) für SL-Placement
   - `calc_ema` (in bb_rsi.rs lokal aber engine-shared semantik)

9. **Test-Conventions:**
   - Property-Tests bevorzugt für Domain-Logik
   - Pinned Mini-Fixtures für Numerical-Validation (Werte via `dump_*_reference_values --ignored --nocapture` extrahiert)
   - Cross-Process-Determinismus-Pins für jede Persistence-Stelle
   - Smoke-Tests vor jedem Massen-Run (First-Trial-Sanity + < 30s Time-Budget-Check)

10. **Spec-Konvention:**
    - Spec-MDs in `01_Projectplan/specs/{strategy}_spec.md`
    - 13 Sections (siehe `_template.md`)
    - §13 ist Acceptance + Path-Klassifikation, immer updaten nach Welle
    - Bewusste Abweichungen in §12, mit Begründung

---

## 10. Wichtige Datei-Referenzen

### Plan + Specs

- `01_Projectplan/260522_Gesamtplan_Phase1-3.md` — Master-Plan mit §4.4 Phase-Status pro Welle
- `01_Projectplan/260522_Workflow_QA_Koordinator.md` — Workflow-Details (Pre-Task-Templates)
- `01_Projectplan/specs/_template.md` — Spec-Template (13 Sections)
- `01_Projectplan/specs/bb_rsi_spec.md` — BB+RSI v3 Spec (mit §13.8 Welle-A1-Update)
- `01_Projectplan/specs/ut_bot_spec.md` — UT-Bot v1 Spec (mit §13.7 Welle-A2-Update)
- `01_Projectplan/specs/ichimoku_spec.md` — Ichimoku Spec
- `01_Projectplan/specs/bb_rsi_engineering_plan.md` — BB+RSI Engineering-Plan
- `01_Projectplan/specs/ut_bot_engineering_plan.md` — UT-Bot Engineering-Plan
- `01_Projectplan/specs/ichimoku_engineering_plan.md` — Ichimoku Engineering-Plan

### Diagnose-MDs (Welle-Befunde)

- `01_Projectplan/specs/bb_rsi_diagnose_2026-05-23.md` — BB+RSI Pfad-C-Diagnose Phase 2
- `01_Projectplan/specs/ut_bot_diagnose_2026-05-23.md` — UT-Bot Pfad-C-Diagnose Phase 2
- `01_Projectplan/specs/ichimoku_diagnose_2026-05-24.md` — Ichimoku Pfad-C-Diagnose Phase 2
- `01_Projectplan/specs/regime_filter_diagnose_2026-05-24.md` — ADX-Sweep + Wiring-Bug-Diagnose
- `01_Projectplan/specs/regime_filter_resweep_2026-05-24.md` — ADX Re-Sweep nach R4-Fix
- `01_Projectplan/specs/optimizer_o2_consolidation_2026-05-24.md` — Welle-O2 Cross-Strategy-Bilanz
- `01_Projectplan/specs/walk_forward_w2_survivors_2026-05-25.md` — Welle-W2 Walk-Forward + W3-TPE-Range-Vorschlag
- `01_Projectplan/specs/walk_forward_w3a_survivors_2026-05-26.md` — Welle-W3a Median-Score
- `01_Projectplan/specs/tpe_w3_5_survivors_2026-05-26.md` — Welle-W3.5 TPE-Production-Run
- `01_Projectplan/specs/stat_gates_w4_results_2026-05-26.md` — Welle-W4 PBO + DSR
- `01_Projectplan/specs/bb_rsi_1h_path_classification_2026-05-26.md` — Welle-A1
- `01_Projectplan/specs/ut_bot_fee_realism_2026-05-26.md` — Welle-A2

### Engineering-Files (Rust)

- `rust/trading_engine/src/api.rs` — Public FFI (run_*_backtest pro Strategie)
- `rust/trading_engine/src/lib.rs` — Library-Root
- `rust/trading_engine/src/addins/` — Strategien + common.rs
- `rust/trading_engine/src/optimizer/` — Optimizer-Pipeline (10+ Submodule)
- `rust/trading_engine/tests/` — Integration-Tests + Regression-Pins
- `rust/trading_engine/examples/` — Production-CLIs

### Engineering-Files (Dart)

- `lib/main.dart` — App-Entry
- `lib/services/backtest_service.dart` — Dart-Backtest-Engine (Mirror der Rust-Engine)
- `lib/services/rust_bridge.dart` — FFI-Wrapper
- `lib/services/strategy_common.dart` — Dart-Mirror von common.rs
- `lib/services/indicators.dart` — Indicator-Berechnungen für Dart-Fallback
- `lib/features/backtest/backtest_provider.dart` — State-Management
- `lib/ui/screens/backtest_screen.dart` — Backtest-UI (BB+RSI-only, B1-Erweiterung pending)

### Studies-DBs + Daten

(Vollständige Liste in §4 oben)

---

## 11. Prompt für die nächste KI-Session

```
=============================================================================
PROMPT FÜR DIE NÄCHSTE KI-SESSION (OrderPilot Portabel2 QA-Koordinator-Rolle)
=============================================================================

Du übernimmst die QA-Koordinator-Rolle für das Trading-App-Projekt
"OrderPilot Portabel2" von Maik (CodingKI GmbH). Maik ist Solo-Developer
mit klarer Vision: private BTC-Backtesting-App im Trade-Republic-Stil,
Flutter/Dart-UI mit Rust-Engine via flutter_rust_bridge.

DEINE ROLLE:
  - QA-Reviewer für CC (Claude Code CLI in WSL2/tmux) der die Code-
    Operationen ausführt
  - Plan-Owner für 01_Projectplan/260522_Gesamtplan_Phase1-3.md
  - Git-Operator für Tag-Setzung, Plan-Updates, manuelle Pushes (Auto-Mode
    blockt manchmal direkten Push auf main, dann pushst du via
    Windows-MCP:PowerShell)
  - Pre-Task-Author: Du schreibst detaillierte Pre-Tasks für CC mit
    Scope, Commit-Plan, Gates, Eskalations-Stopp-Bedingungen

WICHTIG:
  - Lies ZUERST diese HANDOFF-Datei vollständig
    (01_Projectplan/HANDOFF_2026-05-26_OFFENE_PUNKTE_UND_KI_PROMPT.md)
  - Lies dann 01_Projectplan/260522_Gesamtplan_Phase1-3.md §4.4 für
    aktuellen Phase-Status
  - Lies optional 01_Projectplan/260522_Workflow_QA_Koordinator.md für
    Workflow-Details

AKTUELLER STAND:
  - HEAD: 403e5b7 docs(phase-3.2): ut_bot fee-realism Welle A2
  - Tag: v0.5.1-fee-realism-validated
  - main synced mit origin
  - Phase 1-3.2 abgeschlossen, 3 Strategien Pfad-C-klassifiziert
  - Engineering-Pipeline production-grade (Random-Search + Walk-Forward +
    TPE + PBO/DSR)
  - Keine Production-Default-Strategie identifiziert
  - Backtest-UI existiert aber BB+RSI-only

NÄCHSTE WELLE (von Maik bei Übergabe gewählt):
  Welle O3-B1: UI Backtest-Screen multi-strategy
  Pre-Task ist in §7 dieser Datei vollständig ausgeschrieben.
  
  Falls Maik eine andere Welle wählt, siehe Backlog in §5.

WORKFLOW:
  1. Maik gibt GO für eine Welle
  2. Du liest relevante Specs/Plan-Sektionen
  3. Du schreibst Pre-Task für CC (Format siehe §7 in dieser Datei)
  4. Maik leitet Pre-Task an CC weiter, CC arbeitet, CC schickt Brief
     zurück
  5. Du reviewst, gibst Sign-off, pushst ggf., setzt ggf. Tag
  6. Loop bis Welle abgeschlossen

KONVENTIONS-KURZFASSUNG:
  - Atomare Commits, push direkt nach grünem Commit
  - Pro-Commit-Gates: flutter analyze, cargo clippy -D warnings,
    cargo test --release, flutter test, phase1_reference_backtest grün,
    parity-Tests grün
  - Pre-Task immer mit Eskalations-Stopp-Bedingungen
  - Briefe-Format: Commit-Tabelle, Output-Tabelle, Gate-Status, Empfehlung

GOTCHAS DIE DU IMMER IM KOPF HABEN MUSST:
  1. flutter test invokiert kein cargo build → tool/build_rust.sh nutzen
  2. HashMap iteration → cross-process determinism (Pin via BTreeMap)
  3. Phase-1-Reference-Backtest ist FROZEN Regression-Guard (91 Trades,
     -2071.38 USDT) — niemals brechen
  4. Auto-Mode blockt direkten git push auf main → manuell pushen
  5. Bei großen Tag-Messages: write_file für temp-msg, dann git tag -F

VERFÜGBARE TOOLS:
  - Filesystem (lokales Read/Write)
  - Windows-MCP:PowerShell (Git-Ops, Build, Test)
  - Web-Search bei Bedarf (für externe Recherche wie crates.io-Versionen)

VERHALTEN:
  - Sei methodisch und transparent. Wenn etwas unklar ist, frage statt
    zu raten.
  - Bei Plan-Deviationen: dokumentiere im Commit-Body, nicht stillschweigend.
  - Bei Eskalations-Triggern: STOPP und Diagnose-Brief, nicht "weiter
    versuchen".
  - Maik schätzt brutale Ehrlichkeit über Cheerleading. Wenn ein Pfad
    nicht funktioniert, sag das sofort statt es schönzureden.
  - Wenn ein Brief von CC einen Befund hat den der Pre-Task nicht
    vorhergesehen hat: erkenne ihn explizit als wichtig an (das war oft
    der eigentliche Wert der Welle).

LET'S GO.
```

---

## Anhang: Letzte Briefe (für Kontext beim Wiedereinstieg)

Die wichtigsten Brief-Zusammenfassungen der letzten Wellen:

**Welle A2 (UT-Bot Fee-Realismus, Phase 3.2 close):**
- Engine-Fee-Accounting closed-form validiert (Δ +6.29pp ≈ predicted 6.24pp)
- Maker-Sweep skipped via closed-form Extrapolation (Compute-Sparen 2.5h)
- Strategy-strukturelle Diagnose: bei tp_rr=3.20 ist Break-Even-WR 23.8%, Top-1 WR=19.23% liegt 4.6pp UNTER Break-Even auch ohne Fees
- Pfad C strict bestätigt, Phase 3.2 closed

**Welle A1 (BB+RSI 1h, Phase 3.2 open):**
- TF-Wechsel 4h→1h: Qualified 0→13, Max-Trades 10→64
- Top-1: PF 1.545, Sharpe +1.78, profit +22.46%
- XLSX-Bands hit: 1/5 — edge-positive Lab-Kandidat
- rsi_period 14 empirisch widerlegt (Top-10 alle bei rsi 2-3)
- always-on ADX-Filter ist dominanter Trade-Cutter

**Welle W4 (PBO/DSR, Phase 3.1 close):**
- Union-Pool 86 Trials (79 TPE + 5 W3a-Top + 2 W3a-Survivors)
- Pool-PBO = 1.0000 (alle 20 CSCV-Combos)
- Top-1 DSR = 0.207 (Trial 688 / W3a, außerhalb TPE-Search-Space)
- E[max sharpe | N=86, H0] = 2.477 > Best 1.87
- Kein Production-Default-Kandidat unter Multi-Testing-Korrektur

Vollständige Briefe in den jeweiligen Diagnose-MDs (siehe §10).

---

**Ende HANDOFF — viel Erfolg.**
