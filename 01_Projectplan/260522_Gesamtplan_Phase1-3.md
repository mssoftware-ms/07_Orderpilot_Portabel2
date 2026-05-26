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

Drei mögliche Acceptance-Ausgänge pro Strategie (jeder eindeutig in der Spec-MD §13 dokumentiert):

**Pfad A — Im Toleranz-Band**
- [ ] Backtest auf Video-Asset/TF (oder nachgewiesenermassen äquivalent) reproduziert XLSX-Targets im jeweils festgelegten Toleranz-Band.
- → Strategie wird **produktiver Default-Kandidat** in Phase 3.

**Pfad B — Bewusste Abweichung dokumentiert**
- [ ] Implementierung weicht vom Video ab (Fee-Optimierung, plausibler Tippfehler im Video, vereinfachte Sub-Logik), Begründung in Spec §12.
- [ ] Diff-MD enthält die Abweichung als „dokumentiert" (nicht als „Fix erforderlich").
- → Strategie wird **produktiver Default-Kandidat** in Phase 3 mit dokumentierter Abweichung.

**Pfad C — Video-treu, aber Targets auf Ziel-Asset/TF nicht erreichbar** (eingeführt nach BB+RSI v3-Erkenntnis, 2026-05-23)
- [ ] Alle Spec-Diffs implementiert, Engine-Korrektheit per Test beweisbar (R:R / Parität / Reproduzierbarkeit).
- [ ] **Pflicht-Sanity-Sweep vor Klassifikation** in mindestens drei Variationen, dokumentiert als `01_Projectplan/specs/{strategy}_diagnose_{date}.md`:
  - Mindestens **eine alternative TF** auf demselben Asset
  - Mindestens **ein alternatives Asset** auf derselben TF
  - Mindestens **ein Parameter-Sweep** über die Haupt-Sensitivität der Strategie
- [ ] Sweep zeigt: Targets sind durch Param-Tuning *nicht* erreichbar; einzige profitable Variation hat zu wenig Volume oder andere Trade-off-Charakteristik.
- [ ] Spec §13 als Pfad-C-Acceptance markiert mit Root-Cause-Hypothese (Asset-Mismatch / Microstructure-Diskrepanz / Sample-Size-Limit).
- → Strategie bleibt im Add-in-Manifest als **Phase-3-Optimizer-Lab-Kandidat** (niedrigere Priorität als Default-Kandidaten), nicht als produktiver Default.

**Gemeinsame Voraussetzungen für alle drei Pfade:**
- [ ] Spec-MD nach Template (siehe 4.2) vollständig
- [ ] Diff-MD dokumentiert Abweichungen Code vs Video
- [ ] Engine-Korrektheits-Gate aus Phase 1 bleibt strukturell grün (Parität, Reproduzierbarkeit, totalTrades > 0)
- [ ] flutter analyze + cargo clippy 0 warnings nach allen Strategie-Commits

**Phase-2-Tag wird gesetzt** wenn:
- [ ] Drei Strategien (BB+RSI, UT Bot, Ichimoku) jeweils einem der drei Pfade zugeordnet sind
- [ ] Mindestens **eine** Strategie auf Pfad A oder B liegt (sonst hat Phase 3 keinen produktiven Default-Kandidaten — dann Phase 2 nicht abgeschlossen, Sub-Diagnose-Session erforderlich)
- [ ] Commit-Tag `v0.3.0-strategies-verified`

**Status nach Welle-I3-Abschluss (2026-05-24):**
- BB+RSI v3: **Pfad C** (Diagnose-Sweep: `bb_rsi_diagnose_2026-05-23.md`)
- UT Bot v1: **Pfad C** (Diagnose-Sweep: `ut_bot_diagnose_2026-05-23.md`, 7 Variationen alle defizitär — best-of-sweep PF=0.81 auf ETHUSDT 5min; Spec §13.5 finalisiert mit Root-Cause-Hypothese „Confluence-Inkompatibilität auf Krypto-5min")
- Ichimoku v1: **Pfad C** (Diagnose-Sweep: `ichimoku_diagnose_2026-05-24.md`, 7 Variationen — best-of-sweep T3c BTCUSDT 1h tenkan=7/kijun=21 mit PF=1.29 und profit %=+38.6 %, netto profitabel aber 4/5 Bänder verfehlt; Spec §13.6 finalisiert mit Root-Cause-Hypothese „Asset-Mismatch EUR/USD-Forex vs BTCUSDT-Crypto + Score-Implementation-Drift §12.2")

**Sub-Diagnose-Session „Welle R" eröffnet (2026-05-23, abgeschlossen 2026-05-24):**

Sub-Aufgabe #3 aus der Empfehlungs-Liste (ADX-basierter Markt-Regime-Filter) wurde als „Welle R1–R3" eigenständig durchgeführt:
- **R1** ADX-Indikator + `regime_passes_filter` shared helper (Dart + Rust, bit-exakte Parität)
- **R2** Wiring des Filters in alle drei Strategien (Default `off` für Backwards-Kompatibilität)
- **R3** 12-Backtest-Sweep (`regime_filter_sweep_test.dart`) = 3 Strategien × 4 ADX-Configs (off, thr=25, thr=35, thr=25 +DI), Resultate in `regime_filter_diagnose_2026-05-24.md`

**Welle-R3-Ergebnis:** Alle drei Strategien bleiben unter Dart-Engine **Pfad C** — keine ADX-Config rettet die volle XLSX-Acceptance. C2 (thr=35) produziert aber einen klaren **Phase-3-Optimizer-Insight** auf allen drei:
- BB+RSI:  C2 PF=4.89 (über Band-Upper), MaxDD=4.6 % (3/5 Bänder, trades-Count bleibt struktureller Blocker)
- UT Bot:  C2 PF=2.34 ∈ XLSX-Band, **Vorzeichen-Flip von −15.3 % → +2.8 %** (2/5 Bänder)
- Ichimoku: C2 DD=12.7 ∈ XLSX-Band, profit % 12.5 → 16.8 % (2/5 Bänder)

**Phase-2-Gate-Outcome nach Welle R3 (initial-Befund): B mit BLOCKER** — Rust-Engine schien ADX-Filter auf realen Daten zu ignorieren. **Welle R4 hat den Blocker als STALE-BINARY-Artefakt aufgelöst** (siehe Welle-R4-Resolution unten); der finale Phase-2-Gate-Outcome ist **B (Pfad C mit Phase-3-Optimizer-Insight)** ohne Blocker, und der Phase-2-Tag ist freigegeben.

**Welle R4 — Rust-ADX-Wiring Real-Data Re-Verifikation (2026-05-24, abgeschlossen):**

R4-Diagnose ergab: Welle R3 hat den Sweep gegen ein **stales `libtrading_engine.so`** vom 2026-05-24 04:14 ausgeführt — kompiliert vor der Welle-R2-Wiring-Implementation. Flutter `flutter test` invokiert nicht `cargo build` auf .rs-Änderungen; die FFI-binary muss explizit per `cargo build --release --lib` (bzw. `bash tool/build_rust.sh`) aktualisiert werden. Nach explizitem Rebuild ist die Welle-R2-Wiring im Binary präsent und der Sweep produziert auf allen 12 Configs (3 Strategien × 4 ADX-Configs) bit-exakte Dart↔Rust 1e-9 Parität für PnL+Sharpe+MaxDD (Beleg: `01_Projectplan/specs/regime_filter_resweep_2026-05-24.md`). Der Rust-Strategy-Code (`bb_rsi.rs`, `ut_bot.rs`, `ichimoku.rs` ADX-Filter-Pfade) sowie die Welle-R1-Helper (`calc_adx`, `regime_passes_filter`) sind ALLE korrekt — kein Code-Fix nötig.

R4-Schutzmaßnahmen gegen Wiederholung:
- `tool/build_rust.sh` — convenience wrapper für cargo build, sodass QA das Rebuild nicht vergisst (`bash tool/build_rust.sh` vor `flutter test`)
- `regime_filter_sweep_test.dart` setUpAll **staleness-guard** — invoked `threshold=100 → 0 trades` invariant über JSON-API VOR dem Sweep; pre-Welle-R2 binary fails-fast mit klarer „run `cargo build --release --lib`" message statt 30s in einen rauschigen 12-Test parity-Fail zu landen
- `rust/trading_engine/tests/regression_adx_real_data.rs` — long-sequence (1100-bar LCG) Rust-side wiring-pin via `cargo test` (auto-rebuild garantiert frische binary)

**Phase-2-Gate-Outcome final (nach R4-Resolution): B (Pfad C mit Phase-3-Optimizer-Insight)**

- BB+RSI: Pfad C, Best-Config C3 thr=25 +DI (3/5 Bänder), Phase-3-Insight = `adx_threshold` ∈ [30, 45] + DI-confluence toggle
- UT Bot: Pfad C, Best-Config C2 thr=35 (2/5 Bänder, PF=2.34 ∈ XLSX-Band, Vorzeichen-Flip), Phase-3-Insight = `adx_threshold` ∈ [30, 40] **default-aktiv**
- Ichimoku: Pfad C, Best-Config C2 thr=35 (2/5 Bänder, DD=12.7 ∈ XLSX-Band), Phase-3-Insight = `adx_threshold` ∈ [30, 40], DI-confluence redundant

**Phase-2-Tag `v0.3.0-strategies-verified` freigegeben** — QA setzt den Tag manuell nach finalem Sign-off der Welle-R4-Re-Sweep-Resultate (Beleg-Doc `regime_filter_resweep_2026-05-24.md` §2).

**Phase-3-Startparameter (aus C2-Insights):**
1. ADX-augmented Optimizer-Ranges pro Strategie: `adx_threshold` ∈ [30, 40] als zusätzliche Sweep-Dimension; `adx_use_di_confluence` ∈ {true, false} als Toggle
2. Default-`adx_filter_enabled` bleibt auf strategy-Manifest-Ebene `off` für Phase-2-Spec-Treue
3. Optimizer-Default-`adx_filter_enabled` = true (Phase-3-spezifisch), insbesondere für UT-Bot (stärkster ADX-Augmentation-Kandidat per Vorzeichen-Flip-Befund)

Die übrigen Sub-Aufgaben aus der ursprünglichen QA-Empfehlung (Optimizer-Lab vorziehen / alternative Strategie-Kandidaten) sind durch Welle R3+R4 NICHT obsolet; der ADX-augmented Optimizer-Sweep wird Sub-Aufgabe #1 (Phase-3-Optimizer-Lab vorziehen) deutlich aufladen.

---

**Welle O1 + O2 — Phase-3-MVP Optimizer-Sweep (2026-05-24..2026-05-25, abgeschlossen):**

Welle O1 baute den Random-Search-Optimizer auf (Domain-Types, YAML-Search-Spaces, Composite-Score mit Disqualifikations-Gates, SQLite-Persistenz, In-Process-Mini-Sweep-Acceptance). Welle O2 trieb den Production-Sweep gegen reale BTCUSDT-Candles für alle drei Strategien.

**Welle O2 Belege:** `01_Projectplan/specs/optimizer_benchmark_2026-05-24.md` (Compute-Bench), `bb_rsi_sweep_2026-05-24.md`, `ut_bot_sweep_2026-05-24.md`, `ichimoku_sweep_2026-05-24.md`, sowie `optimizer_o2_consolidation_2026-05-24.md` (Cross-Strategy). Studies-DBs unter `01_Projectplan/optimizer_studies/studies-{strategy}.db` (committed, single-user-Repo, < 15 MB total).

**Cross-Process Determinismus-Fix (commit 4a2e131):** Pre-Production-Sweep enttarnte einen `SearchSpace.parameters: HashMap<String, ParameterSpec>` Bug: HashMap-Iteration-Order wird per Prozess per `RandomState` randomisiert, sodass zwei separate `cargo run --release --example production_sweep` Aufrufe am gleichen Seed unterschiedliche Top-N-Rankings produzierten. Fix: HashMap → BTreeMap für SearchSpace + TrialParams. Regression-Test `regression_optimizer_determinism.rs` pins die Cross-Process-Bit-Equality.

**Welle-O2-Sweep-Outcome pro Strategie (n_trials/qualified_count/Top-1-PF/Pfad):**

| Strategie | n_trials | qualified | Top-1 PF | XLSX-PF-Band | Pfad |
|---|---:|---:|---:|:---:|:---:|
| BB+RSI | 1000 | 0 (0.0 %) | n/a | [1.58, 2.18] | **C confirmed** |
| UT Bot | 500 | 2 (0.4 %) | 0.92 | [2.01, 2.61] | **C confirmed** (bimodal) |
| Ichimoku | 1000 | 109 (10.9 %) | **2.008** | [2.14, 2.74] | **B-Kandidat** (Delta 0.13) |

Aktualisierter Phase-2-Outcome (jetzt nach Welle O2): **B (Pfad-B-Kandidat Ichimoku + Pfad-C-Insights BB+RSI/UT-Bot)**. Ichimoku verdient Phase 3.1 (Walk-Forward + TPE/Bayes); BB+RSI und UT-Bot brauchen erst Phase-3.0.5-Strukturanpassungen.

**Phase-3.1-Startparameter (aus Welle-O2-Konsolidierung):**
1. **Ichimoku-Refinement-Loop** (höchste Priorität): Walk-Forward auf 109 Trials → Bayes/TPE-Optimization um Top-1 → PBO/DSR-Gate → Live-Default-Pick.
2. **BB+RSI-Strukturanpassung:** Timeframe-Mismatch klären (XLSX 80-120 Trades passt zu 1h, nicht 4h?); falls 4h korrekt, Search-Space erweitern (ADX optional, bb_period ab 50, rsi_period bis 14).
3. **UT-Bot-Fee-Realismus-Prüfung:** Fee-to-ATR-Validation (möglich Fee-dominiert auf 5m); falls ja, Maker-only-Variant einführen oder Search-Space-Bias auf selektives Regime (key_value ≥ 2.5, adx_threshold ≥ 35).
4. **XLSX-Spec-Update für WR-Bänder:** Forex-WR 50-60 % ist auf BTC nicht erreichbar; Spec-§13.7-Update auf BTC-Realismus 30-40 % erwägen (statt blind Forex-WR zu projizieren).

---

**Welle W1–W4 — Phase 3.1 Walk-Forward Refinement Loop (2026-05-25..2026-05-26, abgeschlossen):**

Die vier Wellen lieferten eine vollständige Statistical-Validation-Pipeline für Ichimoku, mit dem methodisch wichtigen Befund dass **kein Trial die PBO-/DSR-Gates passiert**.

| Welle | Inhalt | Belege |
|---|---|---|
| **W1** | Walk-Forward-Splitter (Rolling Window, strategy-agnostisch) + Trial-Runner mit stability-penalized Score + SQLite-Persistence (additive Schema, backward-compatible mit Welle-O2-DBs) + Integration-Tests inkl. Cross-Process-Determinismus-Pin | `optimizer/walk_forward.rs`, `tests/integration_walk_forward.rs` |
| **W2** | 109-Trial Walk-Forward-Replay der Welle-O2 qualifizierten Ichimoku-Trials (25min Compute) + SurvivorCriteria mit CLI-Override. **Bailey-de-Prado-Effekt empirisch belegt:** Welle-O2-Top-1 (Trial 515) ist Walk-Forward Rang 6 mit `worst_oos_pf=0.021`. 0/109 Survivors unter Default-Criteria; 20/109 unter relaxierten. | `studies-ichimoku-wf.db`, `walk_forward_w2_survivors_2026-05-25.md` |
| **W3** | MedianIqr-Stability-Score (W3-1/W3-2) + W3a Re-Run mit `train=4392 / validate=2196 / step=2196` (6 statt 9 Splits, 13min Compute) + TpeEngine (Rust-native, Box-Muller KDE, warm_start, 19/19 Tests grün). **Strukturelle Score-Verbesserung:** `std_oos_pf p50` 19.19 → 1.60 (-92 %); `worst_oos_pf p75` 0.222 → 0.431 (+94 %); Default-Survivors 0 → 2. | `studies-ichimoku-wf-w3a.db`, `walk_forward_w3a_survivors_2026-05-26.md`, `optimizer/tpe.rs` |
| **W3.5** | TPE × Walk-Forward Production-Run: 200 TPE-Trials warm-started aus 28-Trial-Relaxed-Pool (33m16s Compute, 10s/trial, +35 % vs W3a wegen TPE-Suggest+History-Sweeps). **Warm-Start ~13× Multiplier validiert:** 80/200 (40 %) Pfad-A-Reach `mean_oos_pf ≥ 2.14` vs 3 % in W3a. Top-1: TPE Trial 101 mit `agg=1.5842`, `mean=2.024` (XLSX-Schwelle 2.14, Lücke 0.12). Cap-Drücker: `kijun=39` und `tp_rr_ratio=2.6` gegen Search-Space-Rand. | `studies-ichimoku-tpe.db`, `tpe_top_ichimoku.csv`, `tpe_w3_5_survivors_2026-05-26.md` |
| **W4** | PBO + DSR Statistical Gates (Bailey-López-de-Prado 2014) auf Union-Pool aus TPE-Pfad-A-Reach + W3a-Top-5 + W3a-Default-Survivors = 86 Trials. **Pool-PBO = 1.0000** (alle 20 CSCV-Combos zeigen IS-Top-Trial unter OOS-Median). **Top-1 DSR = 0.207** (Z* = -0.82) — `E[max sharpe \| N=86, H0] = 2.477` übersteigt Best-Trial-Sharpe 1.87, statistische Korrektur für Multi-Testing-Bias verlangt höhere Sharpe-Werte als die Pool produziert. | `stat_gates_union_pool.csv`, `stat_gates_results.db`, `stat_gates_w4_results_2026-05-26.md` |

**Phase-3.1-Outcome final: Walk-Forward-validation als Ergebnis (Pfad C bestätigt unter Statistical-Multi-Testing-Korrektur)**

Kein Production-Default-Kandidat identifizierbar. Die TPE-Top-Trials erreichen `mean_oos_pf ≈ 2.0` aber `worst_oos_pf < 0.6` (bindende Default-Survivor-Constraint). Selbst unter relaxten Criteria zeigt PBO=1.0 maximales Overfitting-Signal. Die statistische Schwäche kommt primär aus dem Verhältnis (86 Trials vs 6 OOS-Splits) — Multi-Testing-Sample-Size-Problem, kein Parameter-Cap-Problem. Welle W4.5 (Cap-Erweiterung) würde primär die TPE-Region verschieben; PBO-Diagnose würde sich kaum ändern.

**Phase-3.1-Tag `v0.5.0-walk-forward-validated` Setzung-Konvention:**
- Tag dokumentiert die **vollständige Statistical-Validation-Pipeline als Engineering-Asset**, nicht einen Production-Default
- Ichimoku bleibt Phase-3-Optimizer-Lab-Kandidat (analog BB+RSI/UT-Bot), nicht produktiver Default
- Bemerkenswert: Top-2 DSR-Trials sind beide aus W3a (688, 266) — Parametersätze AUSSERHALB des TPE-Suchraums (`adx_threshold=43.06` > TPE-Cap=38). Welle-W3.5-Cap-Hypothese in W4 bestätigt, aber PBO-Diagnose macht Cap-Erweiterung obsolet.

**Engineering-Assets aus Welle W1–W4 (wiederverwendbar für jede zukünftige Strategie):**
- `optimizer/walk_forward.rs` (Rolling-Window-Splitter + Trial-Runner + 3 Stability-Score-Methoden)
- `optimizer/tpe.rs` (Rust-native TPE mit Box-Muller KDE, warm_start, Builder-Pattern)
- `optimizer/stat_gates.rs` (PBO via CSCV + DSR via Bailey-2014 closed-form)
- 4 CLI-Examples: `walk_forward_replay`, `tpe_walk_forward_run`, `stat_gates_run` + Bestand `production_sweep`/`sweep_benchmark`
- Reproducibility-Pins: cross-process Determinismus, regression-Tests gegen Stale-Binary-Drift

**Phase-3.2-Empfehlung (Backlog):**
1. **BB+RSI + UT-Bot Phase-3.0.5-Strukturanpassung** (TF-Check 4h vs 1h, Fee-Realismus, Maker-Variant): Bestand-Empfehlung aus Welle-O2-Konsolidierung. NICHT durch Welle-W1–W4 obsolet. **Welle A1 (BB+RSI 1h) und Welle A2 (UT-Bot Fee-Realismus) abgeschlossen — siehe Welle-A1+A2-Block unten.**
2. **Spec §13.7-Update für BTC-WR-Realismus** (statt Forex-Bänder 50-60 % auf BTC 30-40 %): parallel zur Strukturanpassung.
3. **Alternative Strategy-Discovery aus XLSX-Ranking**: Optional, sobald BB+RSI/UT-Bot-Strukturanpassung Pool erweitert.
4. **App-UI-Integration der Pipeline-Outputs** (Welle O3 deferred): die Walk-Forward + TPE + PBO/DSR-Outputs sind production-grade Engineering-Assets — UI muss diese verlässlich für jede zukünftige Strategie anzeigen können.

---

**Welle A1 + A2 — Phase 3.2 Strukturanpassung (2026-05-26, abgeschlossen):**

Welle A1 testete die BB+RSI TF-Mismatch-Hypothese (Welle-O2 4h erzeugte 0/1000 qualifizierte Trials — möglicherweise weil das XLSX-Trade-Band [80, 120] auf 4h Candle-Volumen-strukturell unerreichbar ist). Welle A2 testete die UT-Bot Fee-Driver-Hypothese (Welle-O2 5m taker 0.06 % erzeugte Top-1 mit −15.27 % PnL, Fee-Drag ~100 % der Verlust-Magnitude).

**Belege:** `bb_rsi_1h_sweep_2026-05-26.md`, `bb_rsi_1h_path_classification_2026-05-26.md` (Welle A1); `ut_bot_zerofee_sweep_2026-05-26.md`, `ut_bot_fee_realism_2026-05-26.md` (Welle A2). Spec-Updates: `bb_rsi_spec.md` §13.8, `ut_bot_spec.md` §13.7. Production-Sweep-Erweiterung: `production_sweep` CLI nimmt jetzt `variant` als 4. Positional-Arg (`bb_rsi:[main|1h]`, `ut_bot:[main|zerofee|maker]`, `ichimoku:[main]`). Studies-DBs `studies-bb_rsi_1h.db` (Welle A1) und `studies-ut_bot_zerofee.db` (Welle A2) committed unter `01_Projectplan/optimizer_studies/`.

**Welle-A1+A2-Outcome pro Strategie:**

| Strategie | Welle | n_trials | qualified | Top-1 PF | Top-1 Bands | Verdikt |
|---|---|---:|---:|---:|:---:|:---:|
| BB+RSI 1h | A1 | 1000 | 13 (1.3 %) | 1.545 | 1/5 | **Pfad C mit Verbesserung** |
| UT Bot zerofee | A2 | 500 | 2 (0.4 %) | 1.271 | 1/5 | **Pfad C strikt** (Outcome b) |

**Welle-A1-Insight (BB+RSI 1h):** Trade-Volume-Skalierung ×4 Candles → ×6.4 max-Trades; Top-1 ist edge-positiv (PF=1.545, Sharpe +1.78, profit +22.46 %) aber Trade-Count 42 bleibt unter XLSX-Lower [80]. Edge-Volumen-Trade-off ist strikt monoton: höhere ADX-Threshold → weniger Trades, höherer PF. Optionale Sub-Wellen A1.1 (ADX optional) + A1.2 (ADX-Threshold-Lowering) als Backlog-Items dokumentiert, NICHT priorisiert.

**Welle-A2-Insight (UT-Bot Fee-Realismus):** Zero-Fee-Variation produziert identischen Top-1 Trial (deterministisch); Δ-Profit (+6.29 pp) matched predicted Fee-Drag (+6.24 pp) → Engine-Fee-Accounting validiert. ABER: qualifizierter Trial-Count bleibt 2/500 (0.4 %) konstant; Bands-Hit-Count bleibt 1/5 konstant; WR=19.23 % konstant. Bei `tp_rr_ratio=3.20` ist break-even-WR=23.8 % — Top-1 ist **strukturell sub-break-even selbst ohne Fees**. Maker-Sweep (closed-form predicted PF=1.10, profit=+2.56 %) **nicht ausgeführt** weil prediktiv-redundant. §13.5-Mikrostruktur-Hypothese verschärft sich (Fee aus Erklärungs-Set entfernt).

**Phase-3.2-Tail-Empfehlung:**
1. **Tag setzen** für Phase 3.2 close: `v0.3.2-phase-3.2-strukturanpassung-closed` (oder ohne Tag, Repo-Single-User).
2. **Optionale Backlog-Items** (Phase-3-Optimizer-Tail-Wave, niedrige Priorität): BB+RSI Welle A1.1/A1.2; alternative Strategy-Discovery aus XLSX-Ranking.
3. **NICHT empfohlen:** UT-Bot weitere Sub-Wellen (A2.1 Maker, A2.2 ETH-5m, A2.3 Search-Space-Bias) — alle drei haben prediktiv-niedrige Erfolgswahrscheinlichkeit oder duplizieren bestehende Welle-U3/R3-Insights.

**Cross-Strategy-Bilanz nach Welle A1+A2:**

| Strategie | Initial-Welle-O2 | Phase-3.2-Verfeinerung | Phase-3.2-End-Status |
|---|---|---|---|
| BB+RSI | Pfad C (1 qualified, 4h Volume-limitiert) | Welle A1 (1h) → 13 qualified, PF=1.545 | Pfad C mit Verbesserung (Lab-Kandidat) |
| UT Bot | Pfad C (2 qualified, bimodal) | Welle A2 (zerofee) → 2 qualified, PF=1.271 | Pfad C strikt (Strategy-limitiert) |
| Ichimoku | Pfad B-Kandidat (109 qualified, PF=2.008) | Welle W1–W4 → PBO=1.0, DSR=0.21 | Pfad C unter Multi-Testing-Korrektur |

**Phase-3-Strategie-Pool-Status:** 0 Production-Default-Kandidaten. Alle drei Strategien sind Lab-Kandidaten unter unterschiedlichen Failure-Modes (BB+RSI: Edge ohne Volumen; UT-Bot: kein Edge; Ichimoku: Statistical-Multi-Testing-Failure). Phase-3-Decision-Gate für Live-Trading bleibt offen; Phase-3.2-Backlog-Item 3 (Alternative Strategy-Discovery aus XLSX-Ranking) wird zur höchsten Priorität.

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
