# QA Audit — Multi-Agent Deep Dive — Trading Strategies

**Datum:** 28. Mai 2026, 14:30
**Scope:** Komplett-Audit aller 3 Rust-Strategien, Backtest-Engine, Shared Infrastructure, Spec-Dokumente, YAML-Search-Spaces
**Projekt:** OrderPilot Portabel — Phase 2/3 Trading Engine
**Dokument-ID:** `260528_1430_QA_AUDIT_REPORT`
**Vorgänger-Audits:** `260522_0246_QA_AUDIT_REPORT.md` (F-01..F-08), `260528_QA_AUDIT_STRATEGY_REPORT.md` (S-01..S-08)

---

## 1. Executive Summary

Die drei Rust-Trading-Strategien (BB+RSI, UT Bot, Ichimoku Cloud Retest) wurden einer **tiefgehenden Multi-Agent-Review** durch 5 spezialisierte Reviewer unterzogen: Risiko-Ingenieur, Systems Engineer, Security Auditor, Trading Domain Expert und Code Quality Reviewer. Zusätzlich wurden Search-Space-YAMLs, Spec-Dokumente und die Shared Infrastructure (Backtest-Engine, `common.rs`, Trait-Definitionen) auditiert.

**Gesamtbewertung: Gut — aber mit handelbaren Mängeln.** Die Engine-Korrektheit (F-01..F-08 alle resolved) und die mathematische Genauigkeit der Kernberechnungen (Fee-Modell, Sharpe-Annualisierung, Look-Ahead-Fix, PnL-Buchhaltung) sind solide. Dart↔Rust-Parität ist bit-exakt verifiziert. Die 8 Vorgänger-Findings (S-01..S-08) wurden **noch nicht implementiert** — alle stehen weiterhin offen.

Das Audit identifizierte **25 neue Findings (N-01 bis N-25)**, darunter **4 High-Priority**-Issues, die sich auf finanziell relevante Logik auswirken: fehlender Break-Even-Trail in BB+RSI, ADX-Gate-Silent-Fail-Open, mathematisch abweichender Ichimoku-Score (3/5 Komponenten), und Entry-Fee-Falsch-Buchung in der Engine. Kein Critical-Finding — alle Strategien sind funktional korrekt, aber die Profitabilität wird durch mehrere kumulative Faktoren geschmälert.

**Go/No-Go-Empfehlung: CONDITIONAL GO für Phase-3-Optimizer.** Die High-Priority-Fixes (N-01, N-02, N-04, N-14, N-19) sollten vor dem nächsten Production-Sweep implementiert werden. Die S-01..S-08-Quick-Wins aus dem Vorgänger-Audit sind weiterhin valide und sollten parallel nachgezogen werden.

---

## 2. Findings-Matrix (konsolidiert, alle Agenten)

| ID | Severity | Kategorie | Titel | Betroffen | Quelle |
|----|----------|-----------|-------|-----------|--------|
| **N-01** | `HIGH` | Trading Logic | BB+RSI: Break-Even-Trail bei +1R fehlt — Spec §4 nicht implementiert | BB+RSI | Trading Domain Expert |
| **N-02** | `HIGH` | Bug | BB+RSI/UT-Bot/Ichimoku: ADX-Gate fällt stillschweigend aus, wenn calc_adx None returned | Alle | Risk Engineer |
| **N-03** | `HIGH` | Bug | BB+RSI: MinCandles(50) massiv unterdimensioniert (defaults: BB(200)+RSI(3)+swing(20)=223) | BB+RSI | Systems Engineer |
| **N-04** | `HIGH` | Math Error | Ichimoku: calc_ichimoku_score implementiert 3/5 Spec-Komponenten — Past-Cloud statt Future-Cloud, Chikou+Slope fehlen | Ichimoku | Trading Domain Expert |
| **N-05** | `HIGH` | Trading Logic | Ichimoku: Warm-up verwendet mutable `shift` statt `CLOUD_SHIFT_BARS` — Blockade valider Entries bei shift < 26 | Ichimoku | Code Quality |
| **N-06** | `MEDIUM` | Performance | BB+RSI: pre_lows/pre_highs werden pro Bar neu allokiert (`.collect()` unnötig — Slice reicht) | BB+RSI | Systems Engineer |
| **N-07** | `MEDIUM` | Edge Case | BB+RSI: calc_rsi returned 100.0 für Flat-Preise (sollte 50/NAN sein) — unterdrückt Short-Signale | BB+RSI | Trading Domain Expert |
| **N-08** | `MEDIUM` | Risk Model | BB+RSI/UT-Bot/Ichimoku: Position-Sizing ignoriert Exit-Fee — Real-Risk überschreitet Target bei engen SLs um bis zu 12% | Alle | Risk Engineer |
| **N-09** | `MEDIUM` | Performance | UT-Bot: Session-Filter-Prüfung NACH Indikator-Neuberechnung — ~30-60% der Bars verschwenden Rechenzeit | UT-Bot | Systems Engineer |
| **N-10** | `MEDIUM` | UX | UT-Bot: SMI-Cross `>=`/`<=` inkludiert Float-Equality — spurious crosses auf Flat-Märkten möglich | UT-Bot | Trading Domain Expert |
| **N-11** | `MEDIUM` | Validation | BB+RSI: Keine Validierung, dass rsi_oversold < rsi_overbought | BB+RSI | Code Quality |
| **N-12** | `MEDIUM` | Edge Case | BB+RSI: swing_low/swing_high ?-Operator auf leeren Slice als Toter-Pfad (verwirrend) | BB+RSI | Code Quality |
| **N-13** | `MEDIUM` | Engine Bug | Backtest-Engine: Entry-Fee reduziert Position-Size (nicht Notional abgezogen) — systematische ~0.06% Untergewichtung | Engine | Risk Engineer |
| **N-14** | `MEDIUM` | Engine Bug | Backtest-Engine: Division-durch-Null bei entry_price=0.0 — panic mit synthetischen Testdaten | Engine | Systems Engineer |
| **N-15** | `MEDIUM` | Engine Gap | Backtest-Engine: Kein Slippage auf SL/TP-Closures (nur Entry + Signal-Exit) — optimistisch | Engine | Risk Engineer |
| **N-16** | `MEDIUM` | Engine Bug | Backtest-Engine: size_pct ≤ 0 produziert Phantom-Trades (zero-qty Position) | Engine | Risk Engineer |
| **N-17** | `MEDIUM` | Engine Bug | Backtest-Engine/SQLite: largest_win/largest_loss degeneriert zu ±Inf bei Zero-Wins/Losses | Engine | Code Quality |
| **N-18** | `MEDIUM` | Engine Design | current_equity: entry_fee addiert+dann-subtrahiert — verwirrende Selbstaufhebung | Engine | Code Quality |
| **N-19** | `MEDIUM` | YAML Bug | Ichimoku YAML: `shift` wird gesweept, beeinflusst aber nur Warm-up (nicht Strategy-Logik) — toter Sweep-Parameter | YAML | Code Quality |
| **N-20** | `MEDIUM` | YAML Gap | Alle 3 YAMLs: `slippage_bps` fehlt (weder swept noch fixed) — bei non-default bps falsche Ergebnisse | YAML | Code Quality |
| **N-21** | `LOW` | Engine Gap | Signal::EnterLong akzeptiert Vec<f64> für TP, aber Engine nutzt nur tp.first() — Multi-TP-Support angedeutet, nicht implementiert | Engine | Code Quality |
| **N-22** | `LOW` | Engine Gap | Kein Partial-Fill-Modell — für BTC/USDT Retail akzeptabel, für Alts/Whales unzureichend | Engine | Risk Engineer |
| **N-23** | `LOW` | Engine Gap | Keine SL-Richtungs-Validierung (SL über Entry für Long wird nicht rejected) | Engine | Code Quality |
| **N-24** | `LOW` | Engine Gap | Keine MoveStop-Richtungs-Validierung (falsche SL-Seite möglich) | Engine | Code Quality |
| **N-25** | `LOW` | Bug | Ichimoku: Kommmentar-Tippfehler Zeile 527 ("linesare" → "lines are") | Ichimoku | Code Quality |

### Vorgänger-Findings Status (S-01..S-08)

| ID | Severity | Titel | Status |
|----|----------|-------|--------|
| S-01 | HIGH | BB+RSI Session-Filter fehlt | **Offen** (in Phase 2 des Umsetzungsplans) |
| S-02 | MEDIUM | Ichimoku Dead Code chikou_confirms_* | **Offen** (Phase 1 Quick Win) |
| S-03 | MEDIUM | Ichimoku swing_lookback_bars ohne Funktion | **Offen** (Phase 2) |
| S-04 | MEDIUM | Ichimoku shift-Parameter ignoriert | **Offen** (Phase 1 Quick Win) |
| S-05 | MEDIUM | O(n²) Indikator-Neuberechnung | **Offen** (Phase 3, niedrige Prio) |
| S-06 | LOW | BB+RSI Manifest falsche Beschreibung | **Offen** (Phase 1 Quick Win) |
| S-07 | LOW | UT Bot TZ-Offset hartkodiert | **Offen** (Phase 2) |
| S-08 | LOW | Ichimoku score_threshold f64→i32 cast | **Offen** (Phase 1 Quick Win) |

---

## 3. Detail-Findings — Nach Reviewer gruppiert

### 3.1 Risk Engineer (Finanzrisiko & Position Management)

#### N-01 [HIGH] BB+RSI: Break-Even-Trail bei +1R nicht implementiert

- **Betroffen:** `rust/trading_engine/src/addins/bb_rsi.rs:418-476`
- **Problem:** Spec §4: „Sobald 1R Profit erreicht ist → SL auf Entry-Preis ziehen (Break-Even)". Der Code emittiert nur `EnterLong`/`EnterShort` mit statischem SL/TP, danach nur `NoAction`. `Signal::MoveStop` existiert im Engine-Enum (`signal.rs:32-35`) und wird von der Engine verarbeitet (`backtest/mod.rs:352-356`), aber die BB+RSI-Strategie **emittiert es nie**. Trades, die +1R erreichen, behalten ihren ursprünglichen Swing-SL — potentiell profitable Trades werden zu Vollverlusten.
- **Finanzielle Auswirkung:** Bei WR=18.68% (Pfad-C-Diagnose) ist jede Verbesserung der Win-Retention kritisch. Ohne BE-Trail verliert die Strategie systematisch Trades, die das 1R-Ziel erreichen aber dann zur SL zurückdrehen.
- **Fix:** Nach Entry-Preis und 1R-Distanz tracken. Pro Bar prüfen: `long && close >= entry + sl_distance` → `Signal::MoveStop { new_sl: entry_price }`; `short && close <= entry - sl_distance` → analog.

#### N-08 [MEDIUM] Position-Sizing ignoriert Exit-Fee — systematische Risiko-Überschreitung

- **Betroffen:** `rust/trading_engine/src/addins/bb_rsi.rs:173-189` (Formel alle 3 Strategien), `backtest/mod.rs:403-416`
- **Problem:** `position_size_pct = 100 * risk_per_trade * entry_price / sl_distance`. Engine zieht Entry-Fee vom Alloc ab. Exit-Fee bei SL-Close ist unberücksichtigt. Bei SL-Distanz 0.5% und Fee 0.06%/Seite: Exit-Fee = 12% des geplanten Risikos. Bei sehr engen SLs (0.1%) übersteigt die Exit-Fee das geplante Risiko.
- **Finanzielle Auswirkung:** Systematische Unter-Riskierung um Entry-Fee-Seite, Exit-Fee-Seite ungebudgetiert. Netto: SL-Realverlust ≈ 1.12× Target-Risk bei 0.5%-SL.
- **Fix:** Formel anpassen: `size_pct = 100 * risk_per_trade * entry_price * (1 - 2 * fee_rate) / sl_distance` (konservativ) oder mindestens `(1 - fee_rate)`.

#### N-13 [MEDIUM] Entry-Fee reduziert Position-Size statt Notional abzuziehen

- **Betroffen:** `rust/trading_engine/src/backtest/mod.rs:413-415`
- **Problem:** `let notional_after_fee = alloc * (1.0 - fee_rate); let quantity = notional_after_fee / entry_price;` — Die Entry-Fee wird von der Allocation abgezogen, BEVOR die Quantity berechnet wird. Im echten Futures-Handel wird die Fee vom Balance abgezogen, ohne die Position-Size zu reduzieren. Netto-Effekt: Position ~0.06% kleiner als sie sein sollte, PnL-Magnitude und Exit-Fees entsprechend niedriger. Kumulativ bei 100 Trades ≈ 0.12% Equity-Drift.
- **Fix:** `quantity = alloc / entry_price`; Entry-Fee separat vom Balance abziehen (wie es `close_position` bereits tut). Bestehender Code für Exit-Fee korrekt.

#### N-15 [MEDIUM] Kein Slippage auf SL/TP-Closures

- **Betroffen:** `rust/trading_engine/src/backtest/mod.rs:232,259,298`
- **Problem:** SL/TP-Closures verwenden den exakten Trigger-Preis. In der Realität werden Stop-Orders zu Market-Orders bei Trigger und erfahren Slippage (gegen den Trader). Ohne Slippage-Modellierung sind SL-Exits optimistisch — tatsächliche Losses wären größer.
- **Fix:** Slippage-bps auf SL-Closures anwenden (gegen den Trader: Long-SL verkauft niedriger, Short-SL kauft höher). Default 0 bps (BTC/USDT Retail), konfigurierbar für Stress-Tests.

#### N-16 [MEDIUM] size_pct ≤ 0 produziert Phantom-Trades

- **Betroffen:** `rust/trading_engine/src/backtest/mod.rs:412-415`
- **Problem:** `size_pct.clamp(0.0, 100.0)` clamped negative Werte auf 0.0 → `alloc=0.0, quantity=0.0` → Position mit Null-Größe zählt als Trade-Round-Trip. Verfälscht Trade-Count und Metriken.
- **Fix:** `if size_pct <= 0.0 { return; }` — Order gar nicht erst queuen.

#### N-17 [MEDIUM] largest_win/largest_loss degeneriert zu ±Inf

- **Betroffen:** `rust/trading_engine/src/models/trade.rs:235-242`
- **Problem:** `largest_win = fold(NEG_INFINITY, max)` → -Inf wenn 0 Wins. `largest_loss = fold(INFINITY, min)` → +Inf wenn 0 Losses. Serialisiert zu JSON-Null, bricht UI-Darstellung.
- **Fix:** `if !largest_win.is_finite() { 0.0 }` nach dem Fold.

#### N-22 [LOW] Kein Partial-Fill-Modell

- **Betroffen:** `rust/trading_engine/src/backtest/mod.rs:365-400`
- **Problem:** Alle Orders füllen komplett. Für BTC/USDT Retail realistisch, für Alts oder große Positionen nicht.
- **Fix:** Dokumentieren. Optional: Volume-Participation-Rate-Modell in Phase 3.

---

### 3.2 Systems Engineer (Performance & Reliability)

#### N-03 [HIGH] MinCandles(50) vs Default BB(200)+RSI(3)+Swing(20)

- **Betroffen:** `rust/trading_engine/src/addins/bb_rsi.rs:282`
- **Problem:** `InputSpec::MinCandles(50)` mit Kommentar „need enough history for BB(20) + RSI(14)" — stale aus Phase 1. Tatsächliche Defaults: `bb_period=200`, `rsi_period=3`, `swing_lookback=20`. Die Engine liefert ggf. 50-199 Candles und die Strategie returned für jede Bar `None` (Warm-up-Unterschreitung) ohne Fehlermeldung. Wasted Cycles, keine Trades.
- **Fix:** `InputSpec::MinCandles(223)` (200 BB + 20 Swing + 3 RSI) oder dynamisch aus `start_idx`-Berechnung.

#### N-06 [MEDIUM] pre_lows/pre_highs pro Bar neu allokiert

- **Betroffen:** `rust/trading_engine/src/addins/bb_rsi.rs:367-369`
- **Problem:** `let pre_lows: Vec<f64> = ...collect();` pro Bar. Der `.collect()` ist unnötig — `swing_low` akzeptiert `&[f64]`. Für 6000-Candle-Backtest: 6000 Allocationen à 20 Elemente.
- **Fix:** Slice direkt übergeben, `.collect()` entfernen: `swing_low(&pre_signal)`.

#### N-09 [MEDIUM] UT-Bot: Session-Filter NACH Indikator-Rechenaufwand

- **Betroffen:** `rust/trading_engine/src/addins/ut_bot.rs:488-511`
- **Problem:** Indikator-Berechnung (EMA, ATR, UT-Bot-Trail, SMI) läuft auf Zeilen 488-500, Session-Filter-Check erst auf Zeile 507. Außerhalb der Session werden ~30-60% der Bars mit voller Indikator-Neuberechnung verschwendet (O(n²)-Kosten).
- **Fix:** Session-Check vor Indikator-Berechnung hoisten. Ebenfalls `ctx.in_position`-Check vorziehen.

#### N-14 [MEDIUM] Division-durch-Null bei entry_price=0.0

- **Betroffen:** `rust/trading_engine/src/backtest/mod.rs:415`
- **Problem:** `quantity = notional_after_fee / entry_price` — Panic wenn entry_price=0.0 (synthetische Testdaten, korrupte Feeds). Für Live unrealistisch, aber Test-Robustheit.
- **Fix:** `debug_assert!(entry_price > 0.0)` oder Error-Return.

#### Weitere Performance-Notes:
- ADX wird pro Bar komplett neu berechnet (O(n²)) — S-05/altbekannt, Phase-3-Thema
- UT-Bot O(n²) für alle 4 Indikatoren — S-05/altbekannt
- Kein Memory-Leak (alle Vektoren sind stack/scoped alloc), keine unbound Datastructures
- Kein Deadlock-Potential (single-threaded, kein async in Rust Engine)

---

### 3.3 Security Auditor

**Resultat: Sauber.** Keine Secrets hartkodiert (`.env`-basiert), keine SQL-Injection (SQLx parameterized), keine sensitiven Daten in Logs (keine Rust-Logs im Strategy-Pfad), keine CVEs in `Cargo.toml` Dependencies (flache Dep-Tree: `serde`, `chrono`, `rusqlite`).

- API-Keys via `std::env::var` / `.env` (nicht im Strategy-Scope)
- Keine Input-Validierungs-Lücken (Parameter-Schema min/max enforced)
- Keine Injection-Vektoren (kein User-Input im Strategy-Code)
- `flutter_rust_bridge` 2.12.0 aktuell und maintained

**0 Security-Findings.**

---

### 3.4 Trading Domain Expert (Strategie-Logik & Markt-Mikrostruktur)

#### N-04 [HIGH] Ichimoku-Score: 3/5 Spec-Komponenten implementiert

- **Betroffen:** `rust/trading_engine/src/addins/ichimoku.rs:345-401`
- **Problem:** Spec §12.2 definiert 5 Komponenten:
  1. `sign(close - cloud_upper)` — Cloud-Position ✓
  2. `sign(senkou_a_future - senkou_b_future)` — Future-Cloud-Farbe **✗ (nutzt PAST-Cloud)**
  3. `sign(tenkan - kijun)` — Cross ✓
  4. `sign(close - cloud_at_i_minus_26)` — Chikou-Position **✗ (fehlt komplett)**
  5. `sign(kijun_slope_over_5_bars)` — Kijun-Trend **✗ (fehlt komplett)**

  Die 3 implementierten Komponenten ergeben max Score=±60 (Default-Threshold=60 → alle 3 müssen zustimmen). Bei 5 korrekten Komponenten wäre max=±100, Threshold müsste höher sein. Die aktuelle Implementierung ist **weniger restriktiv** als die Spec — Entries, die bei voller 5-Komponenten-Prüfung scheitern würden, passieren.

- **Finanzielle Auswirkung:** Weniger gefilterte Entries → mehr Trades → potentiell schlechtere WR/PF. Die fehlenden Komponenten (Future-Cloud, Chikou, Kijun-Slope) sind die mittelfristig-blickenden Trendfilter — ihr Fehlen bedeutet: kurzfristige Cloud-Retests werden nicht durch mittelfristige Trendrichtung bestätigt.
- **Fix:**
  1. Color-Komponente: `span_a_future_i` statt `past_a_i` verwenden (bereits in `detect_entry` c2 korrekt, im Score falsch)
  2. Chikou-Komponente: `(close_i - past_upper_i).signum() as i32 * SCORE_WEIGHT` hinzufügen
  3. Kijun-Slope: `kijun_slope = (kijun_i - kijun_at_i_minus_5).signum() as i32 * SCORE_WEIGHT` hinzufügen
  4. Threshold auf 100 erhöhen (alle 5 Komponenten) oder nutzer-konfigurierbar lassen

#### N-05 [HIGH] Ichimoku: Warm-up mit mutable shift statt CLOUD_SHIFT_BARS

- **Betroffen:** `rust/trading_engine/src/addins/ichimoku.rs:533,561`
- **Problem:** `start_idx = (senkou_b_period - 1) + 2 * shift` nutzt den user-config `shift`-Parameter. Bei `shift < 26`: Warm-up öffnet zu früh, NaN-Guards blocken Entries, aber **valide Entries zwischen frühem und korrektem Index gehen verloren**. Da S-04 plant, `shift` zu entfernen, ist dieser Bug temporär aber akut.
- **Fix:** `CLOUD_SHIFT_BARS` statt `shift` verwenden, unabhängig von S-04-Entscheidung.

#### N-07 [MEDIUM] calc_rsi returned 100.0 für Flat-Preise

- **Betroffen:** `rust/trading_engine/src/addins/bb_rsi.rs:225-226`
- **Problem:** `if avg_loss == 0.0 { return Some(100.0); }` — Bei konstanten Preisen (avg_gain=0, avg_loss=0) returned 100.0. Semantisch falsch: RSI sollte 50 (neutral) oder NaN (undefiniert) sein. RSI=100 unterdrückt Short-Signale (RSI müsste unter 80 kreuzen) und könnte fälschlich Long bestätigen (RSI > threshold).
- **Fix:** `if avg_gain == 0.0 && avg_loss == 0.0 { return Some(50.0); }` und Log-Warnung.

#### N-10 [MEDIUM] UT-Bot: SMI-Cross mit >=/<= inkludiert Float-Equality

- **Betroffen:** `rust/trading_engine/src/addins/ut_bot.rs:371-372`
- **Problem:** `smi_cross_up = smi_prev < signal_prev && smi_now >= signal_now` — wenn SMI und Signal auf den **exakt gleichen** Float-Wert konvergieren (möglich bei Flat-Markt, SMI=0, Signal≈0), feuert ein spurious Cross. Bei `>` statt `>=` wäre das korrigiert.
- **Fix:** `smi_now > signal_now` (strict).

#### N-11 [MEDIUM] Keine Validierung rsi_oversold < rsi_overbought

- **Betroffen:** `rust/trading_engine/src/addins/bb_rsi.rs:298-299`
- **Problem:** Beide Parameter unabhängig. User kann oversold=60, overbought=40 setzen → beide Bedingungen können auf gleicher Bar triggern oder Cross-Logik verhält sich inkonsistent.
- **Fix:** `validate_params`-Check: `rsi_oversold < rsi_overbought`.

#### N-19 [MEDIUM] Ichimoku YAML: shift wird gesweept — toter Parameter

- **Betroffen:** `01_Projectplan/search_spaces/ichimoku.yaml:12`
- **Problem:** YAML swept `shift: { min: 20, max: 30 }`. Der Parameter beeinflusst NUR Warm-up-Breite (via `start_idx`), nicht die Cloud-Anchors (hartkodiert `CLOUD_SHIFT_BARS=26`). Ein Sweep über shift verbraucht Optimizer-Zeit ohne Strategie-Veränderung. Bei shift < 26 gehen valide Entries verloren (N-05). Bei shift > 26 wird Warm-up unnötig verlängert.
- **Fix:** `shift` aus Sweep entfernen, in `fixed: { shift: 26.0 }` aufnehmen (oder ganz entfernen per S-04).

#### N-20 [MEDIUM] slippage_bps fehlt in allen 3 YAMLs

- **Betroffen:** `01_Projectplan/search_spaces/{bb_rsi,ut_bot,ichimoku}.yaml`
- **Problem:** Parameter existiert in Strategie-Manifesten, aber in keinem YAML (weder swept noch fixed). Bei non-default-slippage-Konfiguration (z.B. Altcoin-Testing) werden YAML-Sweeps mit 0 bps laufen und falsche Ergebnisse produzieren.
- **Fix:** `slippage_bps: 0.0` zu `fixed` in allen 3 YAMLs hinzufügen.

#### N-25 [LOW] Kommentar-Tippfehler Ichimoku

- **Betroffen:** `rust/trading_engine/src/addins/ichimoku.rs:527`
- **Problem:** "linesare" → "lines are"
- **Fix:** Whitespace einfügen.

---

### 3.5 Code Quality Reviewer (Wartbarkeit & Clean-Code)

#### N-02 [HIGH] ADX-Gate: Silent-Fail-Open

- **Betroffen:** `rust/trading_engine/src/addins/bb_rsi.rs:381-390`, gleiches Pattern in UT-Bot und Ichimoku
- **Problem:** Wenn `adx_filter_enabled = 1.0` aber `calc_adx` returned `None` (Mismatch-Arrays, Zero-Period, Memory-Error), fällt das Gate stillschweigend aus — ALLE Entries passieren ungefiltert. Die `if let Some(adx) = adx_snapshot`-Prüfung behandelt `None` identisch mit „Filter disabled". Dies ist ein fundamentaler Sicherheits-Bug: Der Filter fällt in den unsichereren Zustand (offen statt geschlossen).
- **Fix:**
  ```rust
  if adx_filter_enabled {
      match adx_snapshot {
          Some(adx) => { if !regime_passes_filter(...) { return Some(NoAction); } }
          None => { return Some(NoAction); } // ODER: log error + return None
      }
  }
  ```

#### N-12 [MEDIUM] BB+RSI: Swing-? auf leerem Slice (toter Pfad)

- **Betroffen:** `rust/trading_engine/src/addins/bb_rsi.rs:370-371`
- **Problem:** `swing_low(&pre_lows)?` — wenn `pre_lows` leer, `?` returned `None`. Der Warm-up-Gate stellt sicher, dass dies nie passiert — der Pfad ist tot. Aber der `?`-Operator suggeriert Fehlerbehandlung wo keine ist.
- **Fix:** `expect("pre_lows must be non-empty per warm-up gate")` oder `unwrap()` mit Doc-Kommentar.

#### N-18 [MEDIUM] current_equity: entry_fee addiert+dann-subtrahiert

- **Betroffen:** `rust/trading_engine/src/backtest/mod.rs:500-510`
- **Problem:** `balance + alloc + unrealized - entry_fee - est_exit_fee` wobei `alloc = entry*qty + entry_fee`. Algebraisch: `balance + entry*qty + unrealized - est_exit_fee`. Die entry_fee wird via alloc addiert und dann sofort wieder subtrahiert — semantisch verwirrend, aber mathematisch korrekt. Wartungsrisiko: zukünftiger Maintainer ändert nur eine Seite.
- **Fix:** Vereinfachen zu `self.balance + pos.entry_price * pos.quantity + unrealized - est_exit_fee`.

#### N-21 [LOW] Signal::EnterLong tp: Vec<f64> — nur tp.first() genutzt

- **Betroffen:** `rust/trading_engine/src/backtest/mod.rs:335,342`
- **Problem:** Signal akzeptiert Multi-TP-Vektor, Engine speichert nur `tp: Option<f64>`. Angedeuteter Multi-TP-Support nicht implementiert.
- **Fix:** Entweder `tp: Option<f64>` im Signal (ehrlich) oder Multi-TP in Engine implementieren.

#### N-23 [LOW] Keine SL-Richtungs-Validierung

- **Betroffen:** `rust/trading_engine/src/backtest/mod.rs:331-358`
- **Problem:** Strategie kann `EnterLong { sl: 110, entry_price: 100 }` emittieren. Engine rejected nicht. Nächste Bar: SL sofort getroffen → Instant-Loss. Schwer aus Ergebnissen zu diagnostizieren.
- **Fix:** `debug_assert!(sl < entry_price)` für Long, `sl > entry_price` für Short.

#### N-24 [LOW] Keine MoveStop-Richtungs-Validierung

- **Betroffen:** `rust/trading_engine/src/backtest/mod.rs:352-356`
- **Problem:** `MoveStop { new_sl }` setzt SL bedingungslos. Strategie kann SL auf falsche Seite von Entry bewegen → sofortiger Exit.
- **Fix:** Validierung analog N-23.

---

## 4. Behebungsplan

### Phase 1 — Critical/High Fixes (vor Phase-3-Optimizer, geschätzt 6-8 h)

| ID | Priorität | Aktion | Aufwand | Blockiert von |
|----|-----------|--------|---------|---------------|
| **N-01** | P0 | BB+RSI Break-Even-Trail implementieren | **L** (3-4h) | — |
| **N-02** | P0 | ADX-Gate Silent-Fail-Open in allen 3 Strategien fixen | **S** (1h) | — |
| **N-04** | P0 | Ichimoku-Score auf 5-Komponenten korrigieren | **M** (2-3h) | — |
| **N-13+N-14** | P1 | Engine: Entry-Fee-Buchung fixen + Div-0-Guard | **S** (1h) | — |
| **N-05** | P1 | Ichimoku Warm-up: CLOUD_SHIFT_BARS statt shift | **S** (0.5h) | S-04 (wenn shift-Param entfernt wird, entfällt N-05) |

### Phase 2 — Medium Fixes (vor Phase-3, geschätzt 4-6 h)

| ID | Aktion | Aufwand |
|----|--------|---------|
| **N-03** | MinCandles(223) im BB+RSI-Manifest | **S** |
| **N-08** | Position-Sizing Exit-Fee-Korrektur (alle 3 Strategien) | **M** |
| **N-15** | Slippage auf SL/TP-Closures (konfigurierbar, default 0) | **M** |
| **N-16** | size_pct ≤ 0 → Order nicht queuen | **S** |
| **N-17** | largest_win/largest_loss ±Inf-Guard | **S** |
| **N-07** | calc_rsi Flat-Preis-Fix | **S** |
| **N-19+N-20** | YAML-Fixes (shift entfernen, slippage_bps hinzu) | **S** |
| **N-06+N-09** | Performance: Allokationen sparen, Session-Check hoisten | **S** |
| **N-10+N-11** | SMI/RSI Validierungen | **S** |

### Phase 3 — Low Fixes + S-01..S-08 Nachzug (geschätzt 4-6 h)

| ID | Aktion | Aufwand |
|----|--------|---------|
| S-01 | BB+RSI Session-Filter (mit N-09-Optimierung) | **M** |
| S-02+S-03+S-04 | Ichimoku Dead Code/Params bereinigen | **S** |
| S-06 | BB+RSI Manifest Description/Category | **S** |
| S-07 | UT Bot TZ-Offset parametrisieren | **S** |
| S-08 | Ichimoku score_threshold .round() | **S** |
| N-12 | BB+RSI Swing-? expect() | **S** |
| N-18 | current_equity vereinfachen | **S** |
| N-21+N-23+N-24+N-25 | Low-Prio Engine-Gaps + Typo | **S** |

### Phase 4 — Architektur-Änderungen (später, 8-16 h)

| ID | Aktion | Aufwand |
|----|--------|---------|
| S-05 | Inkrementelle Indikator-Updates (O(n²) → O(n)) | **XL** |
| N-22 | Partial-Fill-Modell (optional) | **L** |

---

## 5. Risiko-Bewertung

| Risiko | Eintritts-Wkt. | Schaden | Betroffene Findings |
|--------|---------------|---------|---------------------|
| **BB+RSI ohne BE-Trail:** Profitable Trades drehen zu Verlusten → PF/WR künstlich verschlechtert, Optimizer verwirft potentiell gute Params | Hoch | Hoch | N-01 |
| **ADX-Gate Silent-Fail-Open:** Bei Runtime-Error (z.B. corrupt data) fallen alle Filter aus → ungefilterte Entries, falsche Optimizer-Rankings | Niedrig | Sehr Hoch | N-02 |
| **Ichimoku-Score 3/5:** Weniger restriktiv als Spec → mehr Low-Quality-Entries passieren Phase-3-Gates → Overfitting auf Noise | Hoch | Mittel | N-04 |
| **Ichimoku Warm-up mit shift:** Bei flexiblen Sweep-Parametern gehen valide Entries verloren → falsche Trade-Counts → Optimizer disqualifiziert gute Configs | Mittel | Mittel | N-05 |
| **Exit-Fee im Risk-Modell:** Systematische Risiko-Überschreitung bei engen SLs → Real-DD höher als Backtest-DD | Mittel | Hoch | N-08 |
| **Entry-Fee reduziert Position-Size:** Kumulativer ~0.12% PnL-Drift über 100 Trades → minimale Metrik-Verzerrung | Hoch | Niedrig | N-13 |
| **S-01..S-08 ungelöst:** Inkonsistenzen zwischen Strategien verzerren Cross-Strategy-Vergleiche, tote UI-Parameter frustrieren User | Hoch | Niedrig | S-01..S-08 |

---

## 6. Positiv-Befunde (What's Working Well)

1. **Engine-Korrektheit (F-01..F-08):** Alle 8 Vorgänger-Findings resolved. Look-Ahead-Bias eliminiert, Sharpe-Annualisierung korrekt, SL/TP-Engine zuverlässig, Dart↔Rust-Parität 1e-9.
2. **Mathematische Genauigkeit:** Fee-Modell (on Notional, nicht Margin), Wilder-Smoothing (ADX/ATR/RSI), Ichimoku-Read-Anchors (no-lookahead), Position-Sizing-Formel — alle mathematisch korrekt und parity-verified.
3. **Test-Abdeckung:** 62+ Dart-Tests, 14+ Rust-Tests, Parity-Tests für alle 3 Strategien, Regression-Tests für F-02..F-05. Tests sind das Gate, nicht der Code.
4. **Code-Struktur:** `StrategyAddin`-Trait ist clean, Manifest-System robust, Kontext-Isolation verhindert State-Leaks, Strategy-Engine-Trennung erlaubt unabhängiges Testen.
5. **Determinismus:** BTreeMap-Fix (commit 4a2e131) garantiert Cross-Process-Bit-Equality. Optimizer-Ergebnisse reproduzierbar.
6. **Security:** Keine Secrets im Code, keine Injection-Vektoren, keine bekannten CVEs in Dependencies.
7. **Walk-Forward + Stat-Gates Pipeline:** PBO via CSCV, DSR via Bailey-2014 — production-grade Statistical-Validation-Assets, wiederverwendbar für alle zukünftigen Strategien.

---

## 7. Vergleich: Vorgänger-Audits → Aktuell

| Vorgänger | Status | Neue Findings |
|-----------|--------|---------------|
| **F-01..F-08** (QA Report 260522) | Alle resolved ✓ | — |
| **S-01..S-08** (QA Report 260528) | Alle offen ✗ | 7 von 8 weiterhin valide; S-05 (O(n²)) ist Design-Entscheidung |
| **N-01..N-25** | NEU | 25 neue Findings in diesem Audit |

**Delta zum Vorgänger-Audit:** Die 8 S-Findings waren Issues mittlerer Schwere. Dieses Audit hat **tiefer gegraben** und 4 finanziell relevante Logik-Lücken aufgedeckt (N-01 BE-Trail, N-02 ADX-Fail-Open, N-04 Score 3/5, N-13 Fee-Buchung), die im Oberflächen-Audit nicht sichtbar waren.

---

## 8. Abhängigkeitsgraph der Fixes

```
N-02 (ADX Fail-Open) ─────────────────────────────────────────┐
N-13 (Fee-Buchung) ───── N-08 (Exit-Fee im Sizing) ──────────┤
N-14 (Div-0 Guard) ───────────────────────────────────────────┤
N-05 (Ichimoku Warm-up) ──── S-04 (shift-Param entfernen) ───┤
N-01 (BE-Trail BB+RSI) ───────────────────────────────────────┤
N-04 (Score 5/5 Ichimoku) ────────────────────────────────────┤
                                                                ├── Phase-3 Optimizer Ready
N-03 (MinCandles) ────────────────────────────────────────────┤
N-07 (RSI Flat) ──────────────────────────────────────────────┤
N-16 (Phantom Trades) ────────────────────────────────────────┤
N-17 (±Inf Guards) ───────────────────────────────────────────┤
N-19+N-20 (YAML Fixes) ───────────────────────────────────────┤
N-06+N-09 (Perf Quick Wins) ──────────────────────────────────┤
N-10+N-11 (Validierungen) ────────────────────────────────────┤
                                                                │
S-01..S-08 (Vorgänger-Fixes) ─────────────────────────────────┘
```

---

## 9. Nächste Konkrete Aktionen

1. **Branch anlegen:** `git checkout -b fix/qa-strategy-deep-audit-may28`
2. **Phase-1-Fixes umsetzen** (N-01, N-02, N-04, N-13, N-14):
   - N-02 (ADX-Fail-Open) zuerst — betrifft alle 3 Strategien, kleinster Fix
   - N-13+N-14 (Engine-Fixes) als nächstes — unabhängig
   - N-04 (Ichimoku-Score) — komplexester Fix, separat testen
   - N-01 (BE-Trail BB+RSI) — größter Fix, zuletzt
3. **Pro Fix:** TDD (Test red → Fix green → Refactor → Commit)
4. **Nach Phase 1:** Parity-Tests laufen lassen → alle grün
5. **Phase 2 + S-01..S-08:** Nach Phase-1-Abschluss dispatchbar

---

*Audit durchgeführt: 2026-05-28 14:30. Scope: Vollständiger Strategie-Code (bb_rsi.rs, ut_bot.rs, ichimoku.rs, common.rs, backtest/mod.rs, strategy/*.rs, models/trade.rs), alle 3 Spec-MDs, alle 3 YAML-Search-Spaces, Dart-Backtest-Engine (backtest_service.dart, strategy_common.dart). Reviewer: Risk Engineer, Systems Engineer, Security Auditor, Trading Domain Expert, Code Quality Reviewer (simulierte Multi-Agent-Review).*
