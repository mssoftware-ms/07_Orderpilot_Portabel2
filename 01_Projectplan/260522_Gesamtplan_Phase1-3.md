# OrderPilot Portabel2 — Gesamtplan Phase 1–3

**Datum:** 22. Mai 2026
**Projekt-Root:** `D:\03_Git\02_Python\07_Orderpilot_Portabel2`
**Charakter:** Private Single-User Finanz-App im Trade-Republic-Stil (kein Public-Release)
**Stack:** Flutter/Dart (UI) + Rust `trading_engine` via `flutter_rust_bridge` 2.12.0
**Strategien (aktuell im Code):** `bb_rsi.rs`, `ichimoku.rs`, `ut_bot.rs`
**Referenz-Dokumente:**
- `260522_0246_QA_AUDIT_REPORT.md` (Detail-Findings F-01 … F-08)
- `01_Projectplan/Trading Strategie Analyse.xlsx` (Performance-Ranking)
- `01_Projectplan/transskript bb+rsi.txt` (≈14 kB)
- `01_Projectplan/transskript ichimoku cloud.txt` (≈12 kB)
- `01_Projectplan/transskript ut bot alerts .txt` (≈12 kB)

---

## 0. Leitprinzipien

| Prinzip | Begründung |
|---|---|
| Korrektheit > Geschwindigkeit | Auch private Finanz-App. Falsche Sharpe/SL-Berechnung = falsche Selbst-Einschätzung = falsche Real-Entscheidungen. |
| Keine Optimierung über kaputter Engine | Garbage in, Garbage out. Phase 3 ist gesperrt bis Phase 1 abgeschlossen. |
| Keine Optimierung über nicht-video-treuen Strategien | Sonst tunst du eine andere Strategie als die mit dem Ranking-Profit. Phase 3 ist gesperrt bis Phase 2 abgeschlossen. |
| Tests sind das Gate, nicht der Code | Tests werden vor dem Fix geschrieben. Tests dürfen vom Agent nicht modifiziert werden — nur erweitert mit explizitem Approval. |
| Eine Änderung = ein Branch = ein PR | Jeder QA-Finding und jede Strategie-Spec bekommt einen eigenen Branch. |

---

## 1. Status quo (was funktioniert, was nicht)

| Komponente | Status | Bemerkung |
|---|---|---|
| Flutter UI (Backtest-Screen, Equity-Curve, Trade-Log, CSV-Export) | OK | siehe README |
| Binance REST API Client + Caching | buggy | F-05 (Cache-Bypass) |
| Dart `BacktestService` | mathematisch fehlerhaft | F-02, F-03, F-04 |
| Rust `trading_engine` (3 Strategien) | logisch korrekter als Dart, aber unverdrahtet + Sharpe-Variante | F-01, F-03 |
| FFI Bridge (`rust_bridge.dart`) | `_nativeAvailable = false` hardcoded | F-01 |
| Strategie-Implementierungen vs. Videos | vermutet abweichend | Phase 2 verifiziert |
| `optimization_service.dart` | zu früh gebaut | **eingefroren in Phase 1** |
| Live-WebSocket / Paper-Trading | Mock | F-07, F-08 |
| Test-Suite (59 Flutter + 57 Rust) | grün | wird in Phase 1 ergänzt |

---

## 2. Phase-Übersicht

| Phase | Inhalt | Tooling | Dauer (Schätzung) | Output |
|---|---|---|---|---|
| **1** | Engine-Korrektheit herstellen (8 QA-Findings) | Claude Code in tmux, lokal Windows | 3–5 Tage | Grüne Engine + erweiterte Test-Suite + eingefrorener Optimizer |
| **2** | Strategien video-treu machen | Claude Code + Transkripte | 2–3 Tage | 3 Spec-MDs + korrigierte `*.rs`-Files + Strategie-Audit |
| **3** | Optimizer-Loop | Rust-intern ODER Hermes (Entscheidung in Phase 2 Review) | 1–2 Wochen | Pro Strategie ranked Parameter-Sets mit DSR/PBO-Gates |

**Reihenfolge ist nicht verhandelbar.** Jede Phase liefert die Voraussetzung für die nächste.

---

## 3. Phase 1 — Engine-Korrektheit

### 3.1 Reihenfolge (aus QA-Report-Mermaid abgeleitet)

```
Tag 1:  F-05 (Cache) + F-06 (Models)         [parallel, klein]
Tag 2:  F-01 (FFI Bridge wiring)              [groß, alleinstehend]
Tag 3:  F-02 + F-03 (SL/TP + Sharpe Rust)    [parallel]
Tag 4:  F-04 (Look-Ahead Bias + Slippage)    [hängt von F-02/F-03]
Tag 5:  F-07 + F-08 (Live-WS + UI Mocks)     [optional, weniger kritisch]
```

### 3.2 Generelle Test-Strategie

Pro Finding **zuerst** den Test schreiben, der das Bug-Verhalten demonstriert (red), **danach** den Fix (green), **dann** den Refactor. Klassisch TDD.

Neue Test-Verzeichnisse:
- `test/regression/F0X_*.dart` — Dart-seitige Tests
- `rust/trading_engine/tests/regression_f0X.rs` — Rust-seitige Tests
- `test/integration/dart_rust_parity_test.dart` — Numerical Equivalence (nach F-01)

### 3.3 Optimizer einfrieren — sofortige Aktion

Vor jedem anderen Schritt: einen Banner-Kommentar in `lib/services/optimization_service.dart` einfügen:

```dart
// =============================================================================
// FROZEN: Phase 1+2 NOT COMPLETE.
// Engine bugs (F-02..F-04) and strategy verification (Phase 2) are open.
// Any results from this service are unreliable until Gesamtplan section 5 unlocked.
// DO NOT delete, DO NOT use in UI. Re-enable per checklist in Gesamtplan section 5.
// =============================================================================
```

UI-Aufrufe an `OptimizationService` müssen mit einem Disabled-State + Tooltip (wartet auf Phase 2) versehen werden.

### 3.4 Finding-Detail-Specs

Jedes Finding bekommt: Test-Skelett, Akzeptanzkriterium, Branch-Name, Aufwand.

#### F-05 — Cache-Key Endtime-Rounding

| | |
|---|---|
| **Branch** | `fix/f-05-cache-endtime-rounding` |
| **Aufwand** | S (≈ 1–2 h) |
| **Datei** | `lib/services/binance_api_client.dart` |

**Test (red, neu in `test/regression/f05_cache_key_stability_test.dart`):**
```dart
test('downloadHistory hits cache on second call within same hour', () async {
  final client = BinanceApiClient(cacheDir: tempDir);
  await client.downloadHistory('BTCUSDT', '1h', start: T0, end: T0 + days(7));
  final filesBefore = tempDir.listSync().length;
  await Future.delayed(Duration(milliseconds: 50));
  await client.downloadHistory('BTCUSDT', '1h', start: T0, end: T0 + days(7));
  final filesAfter = tempDir.listSync().length;
  expect(filesAfter, equals(filesBefore)); // no new file
});
```

**Fix:** In `_buildCacheKey` (oder Pendant) `endTime` auf die letzte volle Stunde runden: `endMs = (endMs ~/ 3600000) * 3600000`.

**Akzeptanz:**
- Test grün
- Cache-Verzeichnis enthält ≤ 1 Datei pro (Symbol, Interval, Range)
- Manueller Test: 5× Backtest auf gleichem Zeitraum → max. 1 neuer API-Call

---

#### F-06 — Modell-Konsolidierung

| | |
|---|---|
| **Branch** | `refactor/f-06-unify-trade-models` |
| **Aufwand** | S (≈ 2–3 h) |
| **Dateien** | `lib/services/backtest_service.dart`, `lib/core/models/trade.dart`, `lib/services/rust_bridge.dart` |

**Aktion:**
1. Lokale `TradeRecord` und `BacktestMetrics` in `backtest_service.dart` löschen
2. `ClosedTrade` und `BacktestMetrics` aus `lib/core/models/trade.dart` als einzige Quelle nutzen
3. `RustBacktestMetrics` in `rust_bridge.dart` wird zu reinem DTO mit `toBacktestMetrics()` Konverter
4. `flutter analyze` ohne Warnungen

**Akzeptanz:**
- 0 Warnungen
- Alle 59 Flutter-Tests weiterhin grün
- `grep -r "class BacktestMetrics" lib/` liefert nur eine Treffer-Datei

---

#### F-01 — FFI Bridge wiring (kritischster Task)

| | |
|---|---|
| **Branch** | `feat/f-01-wire-frb` |
| **Aufwand** | L (≈ 1 Tag, plattformspezifisches Testing) |
| **Dateien** | `lib/services/rust_bridge.dart`, `lib/src/rust/` (neu), CMake/Gradle, `rust/trading_engine/src/api.rs` |

**Schritte:**
1. `flutter_rust_bridge_codegen generate` mit Config in `flutter_rust_bridge.yaml`
2. Generierte Files unter `lib/src/rust/frb_generated.dart` einbinden
3. Native Lib in CMakeLists.txt (Windows/Linux) + Gradle (Android) referenzieren
4. `_nativeAvailable` von hardcoded `false` auf Runtime-Probe umstellen:
   ```dart
   _nativeAvailable = await _probeNative();
   ```
5. Dart-`BacktestService` wird Fallback-Path mit explizitem Logging „Native nicht verfügbar — fallback"

**Test (Integration, neu):**
```dart
test('rust bridge produces identical metrics to direct Rust on reference data', () async {
  final bridge = RustBridge();
  expect(bridge.nativeAvailable, isTrue);
  final dartResult = await DartBacktestService().run(refConfig, refCandles);
  final rustResult = await bridge.runBacktest(refConfig, refCandles);
  expect(rustResult.totalPnl, closeTo(dartResult.totalPnl, 1e-9));
  expect(rustResult.winRate, closeTo(dartResult.winRate, 1e-9));
});
```

**Akzeptanz:**
- Test grün auf Linux + Windows (Android optional Phase 1, sonst Phase 3)
- App startet auf beiden Plattformen ohne FFI-Crash
- Console-Log: `[RustBridge] Native engine active`

**Fallstricke:**
- `flutter_rust_bridge` 2.x braucht Codegen vor jedem Build → in `run.bat` ergänzen
- Android NDK-Pfad muss in `local.properties` stimmen — nicht in Git committen
- Erste Iteration nur Linux + Windows, Android später

---

#### F-02 — Stop-Loss / Take-Profit (Rust-side bereits korrekt, Dart-Fallback nachziehen)

| | |
|---|---|
| **Branch** | `fix/f-02-sl-tp-exit-rules` |
| **Aufwand** | M (≈ 3–4 h) |
| **Dateien** | `lib/services/backtest_service.dart` (Fallback-Pfad), `rust/trading_engine/src/backtest/mod.rs` (Verifikation) |

**Tests (red):**
```rust
#[test]
fn position_exits_at_sl_when_low_breaches_threshold() {
    let candles = vec![/* candle with low < entry - sl_distance */];
    let result = run_backtest(entry_long(100.0, sl=95.0, tp=120.0), candles);
    assert_eq!(result.trades[0].exit_reason, ExitReason::StopLoss);
    assert!((result.trades[0].exit_price - 95.0).abs() < 1e-9);
}
```

```dart
test('dart fallback respects SL/TP intra-candle', () { ... }); // analog
```

**Fix:** In Dart-Service: pro Candle prüfen `low <= sl || high >= tp`, korrekten Exit-Preis + Reason setzen.

**Akzeptanz:**
- Trade-Log zeigt `exit_reason in {StopLoss, TakeProfit, Signal}`
- Dart vs Rust Numerical Equivalence Test grün (Toleranz 1e-9)
- Backtest auf BTCUSDT 1h 2024: PnL aus Dart-Fallback ≈ Rust-Path

---

#### F-03 — Sharpe-Annualisierung pro Timeframe

| | |
|---|---|
| **Branch** | `fix/f-03-sharpe-tf-annualization` |
| **Aufwand** | M (≈ 2–3 h) |
| **Dateien** | `rust/trading_engine/src/models/metrics.rs` (oder Pendant), `lib/core/models/trade.dart` |

**Mathe-Klärung (Crypto 24/7, kein 252-Faktor):**

| Timeframe | Perioden pro Jahr (N) | sqrt(N) |
|---|---|---|
| 1m | 525 600 | 725.0 |
| 5m | 105 120 | 324.2 |
| 15m | 35 040 | 187.2 |
| 1h | 8 760 | 93.6 |
| 4h | 2 190 | 46.8 |
| 1d | 365 | 19.1 |

**Definition (kanonisch):** Sharpe = Mean(period_returns) / StdDev(period_returns) × sqrt(N). Risk-free = 0 (Crypto, kein Standard-Benchmark). Period_returns = Equity-Curve-Returns, NICHT Trade-PnL.

**Test:**
```rust
#[test]
fn sharpe_on_1h_uses_sqrt_8760() {
    // construct returns with known mean and stdev, verify annualization factor
    let returns = construct_returns(mean=0.001, stdev=0.002, n=8760);
    let sharpe = annualized_sharpe(&returns, Timeframe::H1);
    let expected = 0.001 / 0.002 * (8760.0_f64).sqrt();
    assert!((sharpe - expected).abs() < 1e-6);
}
```

**Akzeptanz:**
- Annualisierungs-Faktor explizit timeframe-abhängig
- Dart + Rust nutzen identische Formel (Numerical Equivalence Test)
- Unit-Test mit konstruiertem Returns-Stream, Sharpe innerhalb 1e-6 vom analytischen Wert

---

#### F-04 — Look-Ahead Bias + Slippage-Modell

| | |
|---|---|
| **Branch** | `fix/f-04-look-ahead-bias` |
| **Aufwand** | M (≈ 3–4 h) |
| **Dateien** | `rust/trading_engine/src/backtest/mod.rs` (Hauptpfad) |
| **Hängt von** | F-02, F-03 |

**Aktion:**
1. Signal auf Candle `i` → Execution auf `open` von Candle `i+1`
2. Konfigurierbarer `slippage_bps: u32` als Aufschlag/Abschlag auf Execution-Preis. **Default für Binance BTC/ETH = 0** (Realität: extrem enges Spread, Retail-Order-Größe macht null Slippage). Optionale Stress-Test-Werte: 1 bps (mid-cap Altcoins), 5–50 bps (small-cap Altcoins).
3. **Trennung Fees ↔ Slippage:** Fees laufen separat über bestehenden `fee_rate`-Parameter, sind im Backtest deutlich relevanter als Slippage. Default-Fees:
   - Binance Spot Standard = 10 bps (0.1%)
   - Binance Spot mit BNB-Rabatt = 7.5 bps
   - Binance USDT-M Futures Taker = 5 bps, Maker = 2 bps
4. Last-Candle-Edge-Case: kein Open[i+1] → Position bleibt offen, am Backtest-Ende zum Close[N-1] glattstellen

**Regression-Test (neu, in `tests/regression_f04.rs`):**
```rust
#[test]
fn open_next_execution_yields_lower_pnl_than_close_same() {
    let candles = reference_candles_btc_1h_2024();
    let cfg_old = BacktestConfig { execution_mode: ExecutionMode::CloseSame, ..base() };
    let cfg_new = BacktestConfig { execution_mode: ExecutionMode::OpenNext, slippage_bps: 5, ..base() };
    let r_old = run_backtest(cfg_old, &candles);
    let r_new = run_backtest(cfg_new, &candles);
    assert!(r_new.total_pnl < r_old.total_pnl,
        "Look-ahead-Fix must reduce PnL (was: old={}, new={})", r_old.total_pnl, r_new.total_pnl);
}
```

**Akzeptanz:**
- Test grün (PnL sinkt nachweislich — der Effekt kommt dann allein aus Open[i+1] vs Close[i], NICHT aus Slippage, weil Default 0)
- `slippage_bps` und `fee_rate` als getrennte Parameter exposed → User kann in UI ändern
- Numerical Equivalence Test Dart vs Rust weiterhin grün
- Default-Werte in der UI: slippage_bps=0, fee_rate=10 bps (Binance Spot ohne BNB-Rabatt)

---

#### F-07 — Bitunix-WebSocket-Client aktivieren oder löschen

| | |
|---|---|
| **Branch** | `refactor/f-07-decide-websocket` |
| **Aufwand** | S (≈ 1 h für Entscheidung), L (≈ 1 Tag für Implementierung) |

**Entscheidungs-Frage:** Soll die App Live-Daten von Bitunix zeigen, oder bleibt sie Backtest-only?

- Wenn **ja** → F-08 entwickeln (siehe unten)
- Wenn **nein** → Datei + ungenutzte Dependencies aus `pubspec.yaml` entfernen

Vorschlag: **Phase 1 löschen** (Backtest-only), **Phase 3 entscheiden** ob Live-Feature gewünscht.

---

#### F-08 — UI-Mocks (Paper Trading, Chart)

| | |
|---|---|
| **Branch** | `feat/f-08-paper-trading-live` oder `refactor/f-08-remove-mocks` |
| **Aufwand** | XL (≈ 3–5 Tage) wenn implementiert |

**Empfehlung:** in Phase 1 als „nicht-implementiert"-Banner umlabeln, eigentliche Implementierung nach Phase 3 verschieben. Paper-Trading mit korrekter Strategie und korrektem Backtest ist deutlich nützlicher.

---

### 3.5 Phase-1-Akzeptanz (Gate für Phase 2)

- [ ] Alle F-01 bis F-06 Finding-Tests grün
- [ ] 59+ Flutter-Tests + 57+ Rust-Tests grün
- [ ] Numerical Equivalence Test Dart vs Rust grün
- [ ] `optimization_service.dart` mit FROZEN-Banner
- [ ] `flutter analyze` 0 Warnungen, `cargo clippy` 0 Warnungen
- [ ] Reference-Backtest (BTCUSDT 1h, 2024-01-01 bis 2024-06-30, BB+RSI) liefert reproduzierbare Zahlen bei 3 Wiederholungen
- [ ] Commit-Tag `v0.2.0-engine-correct`

---

## 4. Phase 2 — Strategien video-treu

### 4.1 Workflow pro Strategie

```
1. Transkript lesen (01_Projectplan/transskript *.txt)
2. Spec-MD schreiben nach Template (siehe 4.2)
   -> 01_Projectplan/specs/{strategy}_spec.md
3. Diff gegen aktuelle Implementierung (rust/trading_engine/src/addins/*.rs)
   -> 01_Projectplan/specs/{strategy}_diff.md
4. Entscheidung: Fix oder als Variante kennzeichnen
5. Implementierung anpassen + Test schreiben
6. Backtest auf Asset/Timeframe aus XLSX-Ranking
7. Vergleich Ergebnis vs. XLSX (±20% Toleranz)
```

### 4.2 Spec-Template (`01_Projectplan/specs/_template.md`)

```markdown
# {Strategie} — Specification
**Quelle:** {YouTube-Link aus Ranking}
**Transkript:** transskript {name}.txt
**Ranking:** Platz {n}, Profit {x}, WR {y}%, R:R {z}
**Asset/TF im Video:** {symbol} / {timeframe}

## Indikatoren (mit Parametern aus Video)
- {Name}: Period={...}, ...

## Entry — Long
- Bedingung 1: ...
- Bedingung 2: ...
- (alle Bedingungen MÜSSEN gleichzeitig erfüllt sein, sofern nicht anders vermerkt)

## Entry — Short
- ...

## Exit — Stop Loss
- Platzierung: {z.B. „letztes Swing-Low – 1 ATR"}
- Logik: {fix / dynamic / trailing}

## Exit — Take Profit
- Methode: {1× SL als R, R:R 1:2, etc.}
- Partial TP: {ja/nein, bei welcher R-Stufe}

## Exit — Signal (regulär)
- Bedingung: ...

## Filter / Zusatzregeln
- Trendfilter: {ja/nein, wie}
- Session-Filter: {ja/nein}
- Re-Entry nach SL: {erlaubt / verboten / nach X Bars}

## Position Sizing
- Risk pro Trade: {% des Equity}
- Position size = (Equity × Risk%) / (Entry – SL)

## Besonderheiten / Optimierungen vom Video-Autor
- (z.B. „RSI-Threshold von 30/70 auf 20/80 verschoben")
- (z.B. „BB von 20/2 auf 30/2.5 angepasst")

## Bekannte Limitierungen
- (z.B. „Nur Trending-Märkte, im Range-Markt vermeiden")

## Acceptance für Implementierung
- Backtest auf {Asset}/{TF} über {Range aus XLSX}:
  - Profit-Faktor in [{X − 0.3}, {X + 0.3}]
  - Win-Rate in [{Y − 5pp}, {Y + 5pp}]
  - Max-Drawdown < {Z + 5pp}
```

### 4.3 Strategie-Reihenfolge

1. **BB+RSI** zuerst — einfachste Implementierung, gutes Aufwärmen für den Workflow
2. **UT Bot** — etwas komplexer (ATR-basiertes Trailing)
3. **Ichimoku** — komplexeste (5 Linien, Cloud-Logik, Senkou-Span-Future-Shift)

### 4.4 Phase-2-Akzeptanz (Gate für Phase 3)

- [ ] 3 Spec-MDs in `01_Projectplan/specs/` vollständig
- [ ] 3 Diff-MDs dokumentieren Abweichungen Code vs Video
- [ ] Pro Strategie ein Backtest auf XLSX-Referenz-Setup mit Ergebnis im Toleranz-Band
- [ ] Sollte eine Implementierung *nicht* dem Video folgen (bewusste Abweichung), ist das in der Spec-MD unter „Abweichung von Vorlage" dokumentiert
- [ ] Commit-Tag `v0.3.0-strategies-verified`

---

## 5. Phase 3 — Optimizer-Loop

### 5.1 Entscheidungsfrage: Rust-intern vs. Hermes/Auto-Research

| Kriterium | Rust-internes argmin/grid | Hermes Auto-Research |
|---|---|---|
| Setup-Aufwand | 1–2 Tage | 1–2 Wochen (Docker, Worker-Profile, Skills) |
| Cost pro Sweep | Compute-only (lokal) | Compute + LLM-Token ($) |
| Skalierbarkeit auf neue Strategien | Manuell (neue Objective-Function) | Agent kann ableiten (mit Guardrails) |
| Hypothesen-Generierung | nein, nur Parameter-Tuning | ja, kann z.B. neue Filter vorschlagen |
| Anti-Overfit-Komplexität | Walk-Forward + DSR/PBO als Code | Selber Code-Block, plus Anti-Cheat-Skills |
| Risiko des Loop-Drifts | gering (deterministisch) | mittel (Goodhart, dokumentiert in Hermes-Recherche) |

**Empfehlung (Stand jetzt):**
- Wenn nach Phase 2 die 3 Strategien feststehen und vorerst keine weiteren hinzukommen → **Rust-intern**
- Wenn parallel YouTube-Ranking-Strategien systematisch portiert werden sollen (z.B. Top-20 aus XLSX) → **Hermes** lohnt sich

Entscheidung nicht jetzt — am Ende von Phase 2 mit aktuellem Wissensstand treffen.

### 5.2 Was Phase 3 in jedem Fall enthält

```
1. Per-Strategie Search-Space-File (YAML)
   -> 01_Projectplan/search_spaces/{strategy}.yaml
2. Walk-Forward-Harness (in Rust oder Python-Sidecar)
   - In-Sample: 70% chronologisch
   - Out-of-Sample: 30% danach
   - Min. 5 Splits
3. Composite-Score (nicht roh PnL!):
   - Out-of-Sample Sharpe
   - Profit-Faktor
   - Max-Drawdown-Constraint (< Schwellwert sonst Disqualifikation)
   - Min-Trade-Count-Constraint (z.B. >= 30 Trades)
3a. **Sensitivity-Sweep für Robustheit:**
   - Run ranked params zusätzlich mit slippage_bps ∈ {0, 1, 5}
   - Run ranked params zusätzlich mit fee_rate ∈ {7.5, 10, 12.5} bps
   - Acceptance: Top-5 bleibt im Top-10 bei allen Kombinationen
4. Statistische Gates VOR Annahme:
   - Probability of Backtest Overfitting (PBO) <= 0.5
   - Deflated Sharpe Ratio (DSR) > 1.0
   - Top-5-Ensemble Parameter-Varianz < 30%
5. Ergebnis-Persistenz (SQLite oder PostgreSQL):
   - study_name, commit_hash, asset, timeframe, params, scores
6. Reporting in der App:
   - Strategie-Detail-Screen zeigt Top-5 Param-Sets + DSR/PBO + Equity-Curve
```

### 5.3 Phase-3-Akzeptanz

- [ ] Per Strategie + Asset + Timeframe ein Top-5 mit DSR > 1 und PBO < 0.5
- [ ] Walk-Forward-Robustheit dokumentiert (OOS Sharpe >= 70% von IS Sharpe)
- [ ] App-UI zeigt Optimierungs-Ergebnisse strukturiert
- [ ] Commit-Tag `v0.4.0-optimizer-validated`

---

## 6. Cross-Phase: Test-Suite-Architektur

```
test/
├── unit/                        # bestehende Unit-Tests
├── regression/                  # NEU — pro QA-Finding ein Test
│   ├── f01_ffi_bridge_test.dart
│   ├── f02_sl_tp_test.dart
│   ├── f03_sharpe_test.dart
│   ├── f04_lookahead_test.dart
│   ├── f05_cache_key_stability_test.dart
│   └── f06_model_unification_test.dart
├── integration/                 # NEU — cross-component
│   └── dart_rust_parity_test.dart
└── strategy/                    # NEU in Phase 2
    ├── bb_rsi_video_fidelity_test.dart
    ├── ut_bot_video_fidelity_test.dart
    └── ichimoku_video_fidelity_test.dart

rust/trading_engine/tests/
├── regression_f02.rs
├── regression_f03.rs
├── regression_f04.rs
└── strategy_fidelity_*.rs       # in Phase 2
```

**Goldene Regel:** Tests, die ein Finding gateten, werden **nie** gelöscht oder umgeschrieben. Sie sind die Garantie, dass der Bug nicht zurückkommt.

---

## 7. Branch- und Commit-Strategie

- `main` — immer green, immer releasable
- `feat/*` und `fix/*` pro Finding/Spec
- Conventional Commits mit Finding-Prefix: `fix(F-05): round cache key endtime to last full hour`
- Pre-commit-Hook: `flutter analyze && flutter test && cd rust/trading_engine && cargo test`
- Squash-Merge bei kleinen Findings, Merge-Commit bei großen (F-01)
- Tags: `v0.2.0-engine-correct`, `v0.3.0-strategies-verified`, `v0.4.0-optimizer-validated`

---

## 8. Risikoregister

| Risiko | Phase | Mitigation |
|---|---|---|
| Look-Ahead Bias bleibt unentdeckt | 1 | F-04 Regression-Test mit PnL-Sinkt-Assertion |
| Strategie-Implementierung weicht subtil von Video ab | 2 | Spec-MD muss vor Implementierung review-fertig sein; Video-Backtest-Referenz |
| Goodhart's Law im Optimizer | 3 | Walk-Forward + DSR + PBO als harte Gates, niemals Single-Metric |
| Slippage-Annahme realistisch halten | 1, 3 | Default 0 bps für BTC/ETH auf Binance (de-facto Realität). Wichtiger: **Fees korrekt modellieren** (10 bps Spot Standard, 5 bps Futures Taker). Sensitivity-Analyse mit slippage_bps ∈ {0,1,5} in Phase 3. |
| `optimization_service.dart` wird versehentlich vor Phase 3 genutzt | 1 | FROZEN-Banner + UI-Disable + Code-Review-Checkliste |
| Dart-Rust-Drift nach späterem Refactor | dauerhaft | Numerical-Equivalence-Test im CI |
| FFI-Bridge bricht plattformspezifisch | 1 | Phase 1 testet Linux + Windows, Android in Phase 3 |
| Falsche Steuer/Reporting in der App | out-of-scope | App ist privat, keine Steuer-Auskünfte. Disclaimer in About-Screen. |
| Ranking aus XLSX entspricht nicht heutigem Markt | 2 | Toleranz ±20%, eigene Backtests auf 2024+ Daten |
| Optimizer-Token-Kosten explodieren (wenn Hermes) | 3 | Hard-Cap pro Session, Auto-Pause bei $40 |

---

## 9. Out-of-Scope (bewusste Decisions)

| Was | Warum nicht |
|---|---|
| Public-Release / App-Store | Privat-Use, kein Compliance/Auth-Aufwand nötig |
| Multi-User-Account-Logik | nur ein User (du) |
| Live-Trading mit echtem Geld | bewusst nicht Teil dieser drei Phasen; separate Diskussion nach Phase 3 |
| Steuer-Reporting | privat genutzt, keine 3rd-party-Auskunft |
| Onboarding-Flow / Tutorials | nicht nötig |
| Bitunix-Live-Order-Submission | nicht in Scope, Bitunix-WS war ohnehin Dead Code |
| ML/AI-basierte Strategien | später, erst nach validem Setup |
| Sentiment-Analyse / News | nicht in Scope |

---

## 10. Nächste konkrete Aktion (heute / morgen)

1. **Branch anlegen:** `git checkout -b sprint/phase-1-engine-correct`
2. **FROZEN-Banner** in `lib/services/optimization_service.dart` einfügen + UI-Disable
3. **Parallel starten:**
   - `git worktree add ../portabel2-f05 fix/f-05-cache-endtime-rounding` (oder Branch direkt)
   - `git worktree add ../portabel2-f06 refactor/f-06-unify-trade-models`
4. **Pro Worktree** eine Claude-Code-Session in eigenem tmux-Pane öffnen
5. **TDD-Reihenfolge** je Session: Test red → Fix green → Refactor → Commit → PR an `sprint/phase-1-engine-correct`
6. **Nach F-05 + F-06 grün:** F-01 als einzelne Session (kein Worktree, weil zentral)

---

## 11. Dokument-Index

| Pfad | Inhalt |
|---|---|
| `01_Projectplan/260522_Gesamtplan_Phase1-3.md` | **dieses Dokument** |
| `260522_0246_QA_AUDIT_REPORT.md` | Detail-Findings F-01..F-08 |
| `01_Projectplan/Trading Strategie Analyse.xlsx` | YouTube-Ranking 68 Strategien |
| `01_Projectplan/transskript bb+rsi.txt` | Quelle für `bb_rsi_spec.md` (Phase 2) |
| `01_Projectplan/transskript ichimoku cloud.txt` | Quelle für `ichimoku_spec.md` (Phase 2) |
| `01_Projectplan/transskript ut bot alerts .txt` | Quelle für `ut_bot_spec.md` (Phase 2) |
| `01_Projectplan/specs/` | wird in Phase 2 angelegt |
| `01_Projectplan/search_spaces/` | wird in Phase 3 angelegt |

---

## 12. Änderungshistorie

| Datum | Änderung | Rationale |
|---|---|---|
| 2026-05-22 initial | Erstfassung | siehe Chat-Verlauf |
| 2026-05-22 rev2 | Slippage-Defaults korrigiert: 0 statt 5 bps für BTC/ETH; Fee-Defaults explizit dokumentiert; Sensitivity-Sweep in Phase 3.5.2 ergänzt | Binance BTC/ETH hat de-facto null Slippage bei Retail-Größe; Fees sind die dominante Cost-Komponente und müssen separat modelliert werden |
| 2026-05-22 rev3 | Phase-1-Klarstellungen aus 18 Finding-Briefen konsolidiert (siehe §12.1) | Im Lauf der Phase-1-Implementation entstandene Präzisierungen und Bug-Maskierung-Erkenntnisse, die den Plan für Phase 2 + 3 stabilisieren |

### 12.1 Phase-1 Plan-Klarstellungen (rev3)

**Engine-Korrektheit & Setup**

- **§3.4 F-05**: Cache-Key-Rundung trifft `startMs` **und** `endMs` (nicht nur `endMs`). `startMs` wird aus `now - days * 86400000` ms-präzise abgeleitet und würde sonst synchron mit-driften. Bug-Reproduktion erfordert Rundung beider.
- **§3.4 F-06**: `BacktestMetrics`-Feldset finalisiert: `avgTradeDuration`, `largestWin`, `largestLoss`, `trades`-Liste entfernt (waren ungenutzt). `totalFees` + `candlesProcessed` aufgenommen. `TradeRecord` ersetzt durch kanonischen `ClosedTrade`-Shape mit `entryTimestamp`/`exitTimestamp`/`direction:String`/`fees`.
- **§3.4 F-01**: FRB-Output unter `lib/src/bridge/` (nicht `lib/src/rust/` — Kollision mit stale FRB-Outputs aus früherem Codegen-Lauf). Stale Files entfernt (0 Konsumenten verifiziert). JSON-RoundTrip-Variante implementiert (typed Bridge optional als F-01b). `rust_builder`-Plugin-Pattern statt manueller CMake-Edits. `totalFees`+`candlesProcessed` via FFI-Aufrufer-Site, nicht Rust-Side. Windows-Build + Paper-Trading explizit out-of-scope.
- **§3.4 F-01**: Numerical-Equivalence-Parity-Test wird in F-01 etabliert, darf bei F-01-Abschluss rot sein. F-01-Scope = Bridge wired + JSON-RoundTrip läuft + Smoke grün. Parity grün ist F-02+-Scope.

**Bug-Maskierung-Kaskade (F-02 Familie)**

- **§3.4 F-02**: SL/TP-Logik scope-konform implementiert. Konkrete Engine-Asymmetrie: Rust BB+RSI emittiert Signal mit `SL = bb_lower - (bb_middle - bb_lower)`, `TP = bb_middle`. Rust BacktestEngine prüft intra-candle `high >= tp` / `low <= sl`. Dart wurde analog ausgestattet. Engine-Parity blieb anfänglich blockiert durch RSI-Windowing-Unterschied → F-02b.
- **§3.4 F-02 Coverage-Notiz**: 200-Candle-Parity-Fixture aktiviert SL/TP-Pfad nicht (alle Exits via BB Middle). Realistische F-02-Verifikation erfolgt in Phase-1 Reference-Backtest (BTCUSDT 1h 2024) oder Phase 2 BB+RSI-Spec.
- **§3.4 F-02b (NEU)**: RSI-Bug saß im Aufrufer (`bb_rsi.rs:on_candle`), nicht in `calc_rsi` selbst. Fix: zwei separate close-Vektoren (BB rolling, RSI full history). `calc_rsi` unverändert. Rust matched damit Dart's cumulative Wilder-Implementierung (TradingView-Standard, korrekt für Phase-2-YouTube-Strategie-Referenz).
- **§3.4 F-02c (NEU)**: SHORT-Balance-Accounting in beiden Engines fehlerhaft. Direction-agnostic Formel: `balance_after = balance_before + alloc + net_pnl` mit `alloc = entry_price * quantity + entry_fee`. Für LONG kollabiert algebraisch zur alten Formel; existierende Long-Tests blieben grün. Zusätzlicher Fund: Rust `current_equity` hatte denselben Bug für offene Shorts, mit-gefixt.

**Bug-Maskierung-Kaskade (F-03 Familie)**

- **§3.4 F-03**: Sharpe-Annualisierung timeframe-aware in beiden Engines. Formel bit-identisch verifiziert (cross-check: Rust-Equity-Series durch Dart-Formel = exakter Match). Period_returns aus Equity-Curve, nicht Trade-PnL. Zero-Variance-Edge-Case via `min == max`-Check.
- **§3.4 F-03b (NEU)**: Dart mid-trade equity reconciled via `midTradeEquity`-Helper (bit-mirror von Rust `current_equity`). Loop restrukturiert: SL/TP → Strategy → record equity (Rust-Order). F-02c orthogonal Issue #1 (Recording-Order) mit-gefixt. Parity Sharpe-Assert 1e-9 grün.
- **§3.4 F-03c (NEU)**: Rust `maxDrawdown` auf equity-curve-Basis umgestellt (industry-standard). Helper `max_drawdown_from_equity_curve` in `models/metrics.rs`. Dart unverändert (war schon korrekt). Parity 1e-9 grün. Keine 6. Schicht entdeckt — Engine-Reconciliation-Kaskade vollständig.

**Look-Ahead & UI**

- **§3.4 F-04**: Signal-Bar `i` führt zu Execution bei `candle[i+1].open`. Slippage-Parameter mit Default 0 bps (Plan rev2). Last-Bar-Handling: Pending Order verfällt, offene Position force-close zu `last_candle.close` mit `ExitReason::EndOfData`. Bit-exakte Parity zwischen Engines erhalten.
- **§3.4 F-04**: PnL-Sinkt-Assertion auf 200-Candle-Parity-Fixture entfernt. Fixture-Konvention (`open = price - 20`) produziert systematische Intra-Bar-Drift, die die Plan-Annahme „Look-Ahead favourisiert die Strategie“ auf dieser Fixture umkehrt. Strukturelle Verifikation via Lag-Assertion (Test 1) + Parity-Test. PnL-Direction wird im Phase-1-Gate Reference-Backtest auf BTCUSDT 1h 2024 verifiziert.
- **§3.4 F-07/F-08**: WebSocket-Client gelöscht (0 Konsumenten). `web_socket_channel` zu transitive demoted, AppConstants.bitunixWsUrl entfernt. Paper-Trading + Chart-Screen mit `ComingSoonBanner`-Widget versehen, interaktive Controls disabled. Phase-1-Scope = Backtest-only.

**Lessons-Learned**

- **Bug-Maskierung-Kaskade-Pattern**: 5 Schichten in Phase 1 entdeckt: F-02 (SL/TP) → F-02b (RSI) → F-02c (Balance) → F-03b (Mid-Trade Equity) → F-03c (Drawdown-Definition). Erste 4 waren echte Bugs, 5. war Definitions-Frage. Tests als ehrlicher Drift-Detektor (1e-9-Toleranz nie aufgeweicht). Jede Schicht aktivierte einen anderen Code-Pfad (End-State → Indikator → Buchhaltung → Equity-Sampling → Drawdown-Definition). Vier Schichten reichten für Bug-Findings; die fünfte war konventionell.
- **„Kosmetisch“ gilt nur für aktuelle Verwendung**: F-02c's als kosmetisch klassifizierte orthogonale Issues wurden in F-03b PnL-relevant, sobald Equity-Curve Input einer Metrik wurde (Sharpe, Drawdown). Generalisiert: jeder „kosmetische“ Bug ist potenziell ein zukünftiger Engine-Bug.
- **Phase-1 Test-Environment = WSL2**: Linux WSL2 ist die kanonische Test-Environment für FFI-Tests. Windows-Native cdylib-Build deferred zu Phase 3 oder später.
- **Workflow-Lerning**: Git-Operations vom QA-Koordinator gemacht (statt User) reduziert Copy-Paste-Fehler bei Branch-Namen-Verwechslungen. Etabliert ab F-02b.
- **Plan-Skizzen sind Skizzen**: Test-Code-Snippets im Plan dokumentieren Intent, nicht API. CC adaptiert an reale Code-Signaturen, dokumentiert Drift im Brief.

---

*Plan-Stand: 22. Mai 2026 (rev3). Änderungen nur per Git-Commit auf diese Datei, mit Rationale im Commit-Message und Eintrag in Section 12.*
