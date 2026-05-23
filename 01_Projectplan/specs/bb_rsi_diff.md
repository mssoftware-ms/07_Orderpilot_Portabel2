# BB+RSI: Spec vs Implementation Diff

**Quelle Spec:** [`01_Projectplan/specs/bb_rsi_spec.md`](./bb_rsi_spec.md) — verbesserte Variante (Strategie 3) als kanonisch
**Quelle Code:** `rust/trading_engine/src/addins/bb_rsi.rs` (Engine, canonical) + `lib/services/backtest_service.dart` (Dart-Fallback, bit-parität)
**Erstellt:** 2026-05-23

> Diese Analyse vergleicht ausschließlich gegen die **verbesserte Variante (Variante 3)** aus dem Video, weil das die einzige ist, deren Performance im XLSX-Ranking erfasst ist. Variante 1 (Divergenz) und Variante 2 (RSI-Cross-Back nach SMA-BB) sind hier irrelevant — sie wurden vom Autor selbst verworfen.

---

## Übereinstimmungen (was bereits korrekt ist)

| Aspekt | Spec | Code | OK |
|---|---|---|---|
| Indikatortyp Bollinger Bands (close-basiert) | BB(close) | `calc_bollinger_bands(closes, …)` (bb_rsi.rs:55) | ✓ |
| Indikatortyp RSI mit Wilder-Smoothing | RSI Wilder | `calc_rsi(closes, period)` (bb_rsi.rs:72) | ✓ |
| Beide Indikatoren auf der gleichen Source (close) | close-only | beide nutzen `ctx.closes(...)` (bb_rsi.rs:185–186) | ✓ |
| Eine offene Position max | 1 | `if !ctx.in_position` (bb_rsi.rs:235), `if position == null` (backtest_service.dart:330) | ✓ |
| Execution beim Open der nächsten Kerze (F-04) | ja | `_PendingEnterLong`/Step A (backtest_service.dart:241–283) | ✓ |
| Symmetrische Long/Short-Behandlung | ja | beide Richtungen explizit (bb_rsi.rs:237, :245) | ✓ |
| Warm-Up vor Signalemission | ja (BB(200) + RSI(3) ⇒ ≥201 Kerzen) | `startIdx = max(bb_period, rsi_period + 1)` (bb_rsi.rs:175, backtest_service.dart:195) | ✓ (Mechanik vorhanden, **Default-Werte falsch** — siehe D-01/D-02) |

Strukturell ist die Engine also „die richtige Form" — Bar-Order, Pending-Queue, Indikator-Computation, Position-Tracking. Die Strategie-Logik selbst (Parameter, Entry-Trigger, Exit-Methode, Sizing) ist abweichend.

---

## Abweichungen

### Diff D-01: BB-Parameter — SMA(20, 2.0σ) vs EMA(200, 0.2σ)
- **Spec:** §1 — BB Period = **200**, MA-Typ = **EMA**, StdDev = **0.2** (Transkript T254–T270). Zweck: Trendfilter, nicht Volatilitäts-Envelope.
- **Code:**
  - `rust/trading_engine/src/addins/bb_rsi.rs:284` → `ParameterSchema::new("bb_period", "BB Period", 20.0, …)`
  - `rust/trading_engine/src/addins/bb_rsi.rs:285` → `ParameterSchema::new("bb_stddev", "BB Std Dev", 2.0, …)`
  - `rust/trading_engine/src/addins/bb_rsi.rs:55–67` → `calc_bollinger_bands` nutzt **SMA** (`sma(window)`), kein EMA-Pfad existiert
  - `lib/services/backtest_service.dart:50–65` → `BbRsiParams(bbPeriod=20, bbStdDev=2.0)`
  - `lib/services/backtest_service.dart:161–176` → SMA-Schleife (kein EMA)
- **Magnitude:** **Major** (Indikator-Typ unterschiedlich, Periode 10× anders, σ-Multiplier 10× anders → BB werden fundamental anders aussehen)
- **Empfohlene Aktion:** **Fix Code** — EMA-Funktion in Engine ergänzen, MA-Typ als Parameter (`bb_ma_type: enum {SMA, EMA}`), Defaults auf Video-Werte setzen (Period=200, σ=0.2, MA=EMA). SMA-Pfad bleibt für Backward-Compat / spätere Strategien.
- **Geschätzter Aufwand:** **M** (EMA-Implementierung mit Tests, Schema-Erweiterung in Manifest + Dart, Parity-Test anpassen)
- **Engine-Korrektheits-Risiko:** **hoch** — Default-Change verschiebt **alle** Reference-Backtest-Zahlen. Der gedruckte Phase-1-Diagnosewert (`pnl ≈ −2071.38 USDT, 139 Trades` auf BTCUSDT 1h 2024-H1) ist nach dem Fix Geschichte. Der Test selbst kollabiert nicht (keine Hard-Assertion auf diese Zahl), aber jede menschliche Erwartung daran muss überschrieben werden.

---

### Diff D-02: RSI-Periode + Levels — RSI(14, 30/70) vs RSI(3, 20/80)
- **Spec:** §1 — RSI Period = **3**, Oversold = **20**, Overbought = **80** (T255–T260). Der niedrige Period-Wert macht den Indikator extrem reaktiv (= mehr Signale).
- **Code:**
  - `rust/trading_engine/src/addins/bb_rsi.rs:286–288` → defaults 14 / 30 / 70
  - `lib/services/backtest_service.dart:52–54` → defaults 14 / 30.0 / 70.0
- **Magnitude:** **Major** (Periode ~4.7× kleiner; Levels weiter draußen)
- **Empfohlene Aktion:** **Fix Code** — Defaults im Manifest und in `BbRsiParams` auf 3/20/80 setzen. **Achtung:** `ParameterSchema::new("rsi_period", …, 7.0, 30.0, …)` (bb_rsi.rs:286) hat Min-Range 7 → muss auf 2 oder 3 abgesenkt werden. Analog `rsi_oversold` Min 20 (ok), `rsi_overbought` Max 80 (ok).
- **Geschätzter Aufwand:** **S** (Default-Werte + Range-Anpassung + ein Validierungs-Test)
- **Engine-Korrektheits-Risiko:** **hoch** — verschiebt Reference-Backtest-Zahlen massiv (RSI(3) feuert vielfach häufiger als RSI(14)).

---

### Diff D-03: Long-Entry-Logik — BB-Lower-Touch vs BB-Upper-Breach (Trendseite)
- **Spec:** §2 — Long entry braucht **Close > BB-Upper** (Preis ist ÜBER der Bandstruktur = Uptrend-Konfirmation) + RSI-Cross **20-aufwärts** als Pullback-Trigger.
- **Code:**
  - `rust/trading_engine/src/addins/bb_rsi.rs:237` → `if price <= bb.lower && rsi < rsi_oversold` — also Long bei Preis **UNTER** Lower-Band (klassische Mean Reversion)
  - `lib/services/backtest_service.dart:333` → identisch: `if (close <= lower && rsi < params.rsiOversold)`
- **Magnitude:** **Major** — **konzeptioneller Strategy-Bruch**: Code macht Mean Reversion (kauft den Dip), Spec macht Trendfolge mit Pullback (kauft erst wenn Trend bestätigt). Der Long-Trigger ist nicht nur „etwas anders" — er ist **gegenseitig**.
- **Empfohlene Aktion:** **Fix Code** — `price <= bb.lower` zu `price > bb.upper` umkehren. Vergleichs-Operator ebenfalls neu prüfen (Spec sagt „über" = strict `>`).
- **Geschätzter Aufwand:** **S** (Operator-Flip + Tests umschreiben — `test_strategy_long_entry_signal` produziert aktuell ein Mean-Reversion-Setup; neuer Test braucht Trend-Uptrend-Fixture)
- **Engine-Korrektheits-Risiko:** **hoch** — fundamentale Signal-Inversion; Reference-Backtest-Zahlen werden komplett wandern und der Sign wechselt potentiell (Mean Reversion verliert auf Trendjahr 2024-H1; Trendfolge sollte gewinnen).

---

### Diff D-04: Short-Entry-Logik — BB-Upper-Touch vs BB-Lower-Breach (Trendseite)
- **Spec:** §3 — Short entry braucht **Close < BB-Lower** + RSI-Cross **80-abwärts**.
- **Code:**
  - `rust/trading_engine/src/addins/bb_rsi.rs:245` → `if price >= bb.upper && rsi > rsi_overbought` — Short bei Preis ÜBER Upper-Band
  - `lib/services/backtest_service.dart:335` → identisch
- **Magnitude:** **Major** (Mirror von D-03)
- **Empfohlene Aktion:** **Fix Code** — `price >= bb.upper` zu `price < bb.lower`.
- **Geschätzter Aufwand:** **S** (gleicher Refactor-Block wie D-03)
- **Engine-Korrektheits-Risiko:** **hoch** (wie D-03)

---

### Diff D-05: RSI-Trigger — Threshold-Vergleich vs Cross
- **Spec:** §2/§3 — RSI muss das Level **kreuzen** (von unten → oben durch 20 für Long, von oben → unten durch 80 für Short). Das ist ein **event-basierter Trigger** (`prev_rsi < 20 && curr_rsi >= 20`), kein Schwellwert-Vergleich.
- **Code:** Beide Implementierungen vergleichen nur den aktuellen Wert: `rsi < rsi_oversold` (bb_rsi.rs:237, backtest_service.dart:333). Der RSI-Zustand der Vorperiode wird nicht persistiert (siehe `BbRsiState` in bb_rsi.rs:113 — kein `last_rsi_prev`).
- **Magnitude:** **Major** (Trigger-Semantik unterschiedlich — Threshold-Vergleich feuert ggf. mehrfach in Folge, während Cross genau einmal pro Durchquerung feuert)
- **Empfohlene Aktion:** **Fix Code** — `prev_rsi` als zusätzliches State-Feld in `BbRsiState` + Dart `BacktestService`-Loop tracken; Cross-Condition implementieren. Edge-Cases: erster gültiger RSI-Wert (kein prev), und `prev == level` (Tie-Behandlung — Spec impliziert nicht durchquert).
- **Geschätzter Aufwand:** **M** (Crossing-Logik symmetrisch für Long/Short + Tests für „kein Re-Trigger ohne Cross-Out-First")
- **Engine-Korrektheits-Risiko:** **mittel** — verändert Trade-Anzahl (vermutlich weniger Trades, sauberer getimt). Reference-Backtest-Zahlen verschieben sich, aber qualitativ in dieselbe Richtung wie der RSI(3)-Wechsel (D-02).

---

### Diff D-06: Take Profit — BB-Mittelband vs R:R 1:3
- **Spec:** §5 — TP = **Entry + 3 × (Entry − SL)** für Long, symmetrisch für Short. Fester Multiplikator vom Risk-Anteil.
- **Code:**
  - `rust/trading_engine/src/addins/bb_rsi.rs:241` → Signal liefert `Some(bb.middle)` als TP → TP-Distanz ist „bis zum Mittelband", nicht risk-relativ
  - `lib/services/backtest_service.dart:334–336` → `_PendingEnterLong(2 * lower - middle, middle)` → SL = `2·lower − middle` (Reflexion), TP = `middle`
- **Magnitude:** **Major** — komplett anderes TP-Konzept (geometrisch BB-basiert vs R:R-basiert), und das R:R der Code-Implementierung ist 1:1 by construction (Reflexions-SL und Mittelband-TP haben symmetrische Distanz), nicht 1:3.
- **Empfohlene Aktion:** **Fix Code** — TP-Berechnung umstellen auf `entry_price ± 3 × sl_distance`. SL kommt jetzt aus Swing-Low/High (siehe D-07), TP wird dann darüber abgeleitet.
- **Geschätzter Aufwand:** **S** (sobald SL-Definition steht — siehe D-07 — ist TP eine Multiplikation)
- **Engine-Korrektheits-Risiko:** **hoch** — Trade-PnL-Profile ändern sich grundlegend. WR sollte sinken (TP weiter weg = schwerer erreichbar), Avg-Win/Avg-Loss-Verhältnis steigt auf 3:1.

---

### Diff D-07: Stop Loss — Reflexion an BB-Lower vs Swing-Low/High
- **Spec:** §4 — SL = letztes Swing Low (Long) bzw. Swing High (Short). Algorithmische Definition im Video offen → Phase-2-Implementierung muss „letztes pivotales Low/High der letzten N Kerzen" oder ATR-basiert definieren.
- **Code:**
  - `rust/trading_engine/src/addins/bb_rsi.rs:241` → `bb.lower - (bb.middle - bb.lower)` = `2·lower − middle` (geometrische Reflexion, kein Bezug zu echten Swing-Punkten)
  - `lib/services/backtest_service.dart:334` → identisch (`2 * lower - middle`)
- **Magnitude:** **Major** (SL-Distanz ist deterministisch aus BB statt aus Marktstruktur — ändert Risiko-Profil komplett, und das Sizing hängt davon ab)
- **Empfohlene Aktion:** **Fix Code** + **Spec-Entscheidung nötig** — der Video-Autor liefert keine algorithmische Swing-Definition. Vorschlag für Phase-2-Spec-Erweiterung: Swing-Low = `min(low[i-N..i])` mit N als Parameter (Default z. B. 20 für 1h-Kerzen ≈ 1 Tag), oder ATR-Multiple (z. B. SL = `entry − 1.5×ATR(14)`). Diese Entscheidung sollte **vor** dem Code-Fix getroffen werden.
- **Geschätzter Aufwand:** **M** (Swing-Detection + Tests + Parametrisierung; größerer Aufwand wenn ATR gewählt, da ATR-Indikator in der Engine noch fehlt)
- **Engine-Korrektheits-Risiko:** **hoch** (SL-Distanz ist Hauptdriver von Position-Size **und** TP-Distanz nach D-06)

---

### Diff D-08: Break-Even-Trail bei 1R fehlt
- **Spec:** §4 — Sobald Trade 1R Profit zeigt (= entry + sl_distance für Long), wird der SL auf den Entry-Preis gezogen (Break-Even-Trail).
- **Code:**
  - SL ist initial konstant (`stopLoss: pos.stopLoss`, backtest_service.dart:253), keine Update-Logik im Strategie-Layer und keine im Engine-Layer
  - `rust/trading_engine/src/backtest/mod.rs` (Tracking gegen Rust) — Position hat ein `stop_loss`-Feld, aber kein Trailing-Modul, das es während des Trades modifiziert
- **Magnitude:** **Major** (verändert effektive Verlustverteilung; macht aus Long-Tail-Losses kleine 0-R-Trades — fundamentaler Driver der Profit-Faktor-Verbesserung von Strategy 2 → 3)
- **Empfohlene Aktion:** **Fix Code** — pro Bar (in Step B / SL-Check) prüfen: wenn Long und `high ≥ entry + sl_distance`, dann `stop_loss := entry_price` (mit kleiner Toleranz für Slippage). Symmetrisch für Short. Erste Anwendung permanent (kein nachträgliches Hochziehen weiter Richtung TP — nur Break-Even).
- **Geschätzter Aufwand:** **M** (BE-Logik in Dart + Rust spiegeln; Parity-Test braucht eine Fixture die BE-Trigger forciert; Edge-Case wenn Entry-Bar selbst schon 1R erreicht — Spec impliziert „during trade", nicht „inkl. Entry-Bar")
- **Engine-Korrektheits-Risiko:** **hoch** (gerade weil dies der Mechanismus ist, der die 38 %-WR auf PF 1.88 bringt; ohne BE-Trail würde die Strategie deutlich schlechter performen)

---

### Diff D-09: Position Sizing — voller Balance vs Risk-2 %
- **Spec:** §8 — `position_size = (equity × 0.02) / |entry − sl|`. Bei 2 % Risiko pro Trade kostet ein SL-Treffer 2 % vom Equity.
- **Code:**
  - `lib/services/backtest_service.dart:245–246` → `final fee = balance * feeRate; final qty = (balance - fee) / entryPrice;` — der **gesamte verfügbare Balance** wird auf den Trade allokiert (kein Risk-basiertes Sizing)
  - `rust/trading_engine/src/backtest/mod.rs` (gleiche Logik bit-parität)
- **Magnitude:** **Major** (komplett anderes Risiko-Modell; bei voller Allokation ist ein 1 %-Move = 1 %-Equity-Move statt 0.02 %)
- **Empfohlene Aktion:** **Fix Code** — Sizing-Funktion umstellen auf `qty = (balance * risk_pct) / abs(entry - sl)` mit `risk_pct` als Strategy- oder Engine-Parameter (Default 0.02). Falls die SL-Distanz so klein ist, dass die berechnete Position-Notional > balance / leverage wäre, muss eine Leverage-Cap-Klausel rein (alternativ: skip-trade).
- **Geschätzter Aufwand:** **M** (Sizing-Refactor + Tests, plus Engine-Parameter „leverage" oder „max_notional" als Schutz)
- **Engine-Korrektheits-Risiko:** **hoch** — alle Reference-Backtest-PnL-Werte werden um Faktor ~50 kleiner (skaliert mit Risk-Anteil). Equity-Kurve glättet sich, MaxDD% bleibt qualitativ ähnlich aber numerisch verschoben.

---

### Diff D-10: Session-Filter 09:00–23:00 fehlt komplett
- **Spec:** §7 — Entries nur zwischen 09:00 und 23:00 Lokalzeit (London + New York Session).
- **Code:** Keine Zeitprüfung in Entry-Branches; `on_candle` (bb_rsi.rs:164) hat keinen Zeitstempel-Filter, `BacktestService` ebenso nicht.
- **Magnitude:** **Minor** für Krypto-24/7 (BTCUSDT hat keine harten Sessions wie NQ), **Major** wenn Strategy „as-is" für Aktien-Indices angewendet würde. Für unsere BTC-Anwendung: kosmetisch.
- **Empfohlene Aktion:** **Phase-3-Optimizer-Range** — als optionaler Parameter `session_start_hour_utc` / `session_end_hour_utc` einbauen, Default = „alle 24h erlaubt" für BTC. Den Optimizer in Phase 3 entscheiden lassen, ob ein Time-of-Day-Filter PF verbessert.
- **Geschätzter Aufwand:** **S** (eine Time-Check-Helper-Funktion + ein Parameter im Schema)
- **Engine-Korrektheits-Risiko:** **keine** (Default-„kein Filter" = identisch zu bisherigem Verhalten; Reference-Backtest unverändert)

---

### Diff D-11: Reguläre Signal-Exits (BB-Mitte / RSI-Gegenseite) — vorhanden im Code, nicht in Spec
- **Spec:** §6 — Im Video **keine** signal-basierten Exits erwähnt. Position läuft bis SL/TP.
- **Code:**
  - `rust/trading_engine/src/addins/bb_rsi.rs:212` → `if price >= bb.middle || rsi > rsi_overbought { Exit }` für Long
  - `rust/trading_engine/src/addins/bb_rsi.rs:225` → Spiegel für Short
  - `lib/services/backtest_service.dart:340–352` → gleiche Exit-Trigger als Pending-Order (BB Middle, RSI Overbought/Oversold)
- **Magnitude:** **Major** (fügt Exit-Pfade hinzu, die in der Spec nicht existieren — Trades enden vorzeitig, R:R 1:3 wird selten realisiert)
- **Empfohlene Aktion:** **Fix Code** — diese Exits ersatzlos entfernen. Position bleibt offen bis SL (incl. BE-Trail) oder TP getroffen wird, oder end-of-data. Diese Diff hängt eng mit D-06 (TP) und D-08 (BE-Trail) zusammen — der TP wird zur einzigen geplanten Exit-Quelle.
- **Geschätzter Aufwand:** **S** (Code-Removal + Tests, die diese Exits derzeit erwarten, anpassen)
- **Engine-Korrektheits-Risiko:** **hoch** — derzeit ein wesentlicher Anteil aller Trades schließt über BB-Middle (statistisch dominant über SL/TP). Entfernen verändert Trade-Anzahl drastisch (vermutlich Halbierung oder weniger) und mittlere Trade-Dauer steigt.

---

### Diff D-12: Trendfilter EMA-200 als Pre-Condition — fehlt
- **Spec:** §1/§7 — Der EMA-200-Schwerpunkt der BB(0.2σ) ist selbst der Trendfilter; es gibt keinen *zusätzlichen* externen Trendfilter.
- **Code:** Nach D-01-Fix (BB → EMA 200) ist diese Diff automatisch geschlossen, weil die BB dann strukturell den Trendfilter darstellen. **Vor** D-01-Fix existiert kein äquivalenter Trendfilter — die SMA(20) ist viel zu lokal.
- **Magnitude:** **Major** in der jetzigen Code-Form, **automatisch gelöst durch D-01**
- **Empfohlene Aktion:** **Fix via D-01** (kein separater Code-Change nötig).
- **Geschätzter Aufwand:** **0** (kein eigener Aufwand)
- **Engine-Korrektheits-Risiko:** subsumiert in D-01

---

### Diff D-13: Fee-Rate Konstante — Video 0.1 % vs Phase-1 0.06 %
- **Spec:** §8 — Video rechnet mit 0.1 % pro Trade. Phase 1 nutzt Bitunix VIP0 = 0.06 %.
- **Code:** `_feeRate = 0.0006` in `test/integration/phase1_reference_backtest_test.dart:33` — passt zu Bitunix, nicht zum Video.
- **Magnitude:** **Minor** (Fee ist Parameter, kein Strategie-Verhalten)
- **Empfohlene Aktion:** **Begründete Abweichung dokumentieren** — Phase-1-Wahl (0.06 %) ist realistischer für unsere Zielbörse. Im Acceptance-Test §13 wird die Brutto-Profit-Erwartung gegen 0.1 % verglichen, separate Sanity-Check dass tatsächliche Fees < 12 % des Brutto sind.
- **Geschätzter Aufwand:** **0** (Doku-Eintrag)
- **Engine-Korrektheits-Risiko:** **keine**

---

## Zusammenfassung

| Kategorie | Anzahl |
|---|---|
| **Major Diffs** | 10 (D-01, D-02, D-03, D-04, D-05, D-06, D-07, D-08, D-09, D-11) |
| **Minor Diffs** | 2 (D-10, D-13) |
| **Automatisch gelöst** | 1 (D-12, durch D-01) |

**Geschätzter Phase-2-Aufwand für BB+RSI Code-Fix:**

| Kategorie | Diffs | Mantelschätzung |
|---|---|---|
| Defaults / Schema (S) | D-01-Manifest-Teil, D-02 | ~1 Stunde |
| Operator-Flips / Signalumkehr (S) | D-03, D-04, D-11 | ~2 Stunden inkl. Tests |
| TP-Refactor (S) | D-06 | ~1 Stunde nach D-07 |
| EMA-Implementierung (M) | D-01 EMA-Pfad | ~3 Stunden inkl. Tests + Dart-Parity |
| RSI-Cross-Logik (M) | D-05 | ~2 Stunden |
| Swing-Detection für SL (M) | D-07 | ~3 Stunden + Spec-Entscheidung vorab |
| Break-Even-Trail (M) | D-08 | ~3 Stunden inkl. bit-parität Dart↔Rust |
| Risk-basiertes Sizing (M) | D-09 | ~3 Stunden inkl. Leverage-Cap-Logik |
| Session-Filter (Phase 3) | D-10 | aus Phase-2-Scope ausgenommen |
| Dokumentation Fee-Abweichung | D-13 | trivial |
| **Summe Phase-2-BB+RSI-Fix** | | **~18 Stunden** Engineering (ohne Backtest-Iteration) |

**Welche Diffs würden die Reference-Backtest-Zahlen verändern?**

Alle Majors außer D-10 verändern die *gedruckten* Phase-1-Reference-Backtest-Werte (`pnl ≈ −2071.38 USDT, 139 Trades` auf BTCUSDT 1h 2024-H1). Der Test selbst (`test/integration/phase1_reference_backtest_test.dart`) asserted **nicht hart** auf diese Zahlen — er prüft nur (a) 3-Run-Reproduzierbarkeit, (b) Dart↔Rust-Parität 1e-9, (c) `totalTrades > 0`. Daher wird der Test nach den Fixes **strukturell weiterhin grün laufen**, aber die im Test-Output gedruckten Werte werden komplett anders aussehen.

⚠️ **Achtung:** Wenn D-09 (Risk-Sizing) ohne D-03/D-04 (Signal-Umkehr) implementiert wird, könnte die Strategie *fast keine* Trades generieren (Mean Reversion mit BB(200, 0.2σ) bedeutet: Preis muss riesig weit von der EMA200 weg sein, was selten passiert) → Gefahr `totalTrades == 0` → Test rot. **Reihenfolge der Fixes ist wichtig: D-01/D-02/D-03/D-04 zusammen, dann D-05/D-08/D-11, dann D-06/D-07/D-09.**

**Empfehlung: was zuerst angehen**

1. **Spec-Entscheidung Swing-Definition (D-07)** — *bevor* Code-Arbeit beginnt. Vorschlag: Swing-Low = `min(low[i-20..i])` für 1h-Kerzen als Default-Algorithmus, alternativ ATR-basierter SL. Diese Entscheidung blockiert D-07 + D-06 + D-09 in dieser Reihenfolge.
2. **Erste Code-Welle (Defaults + Signal-Umkehr):** D-01-Schema + D-02 + D-03 + D-04 + D-05 + D-11 — alles in einem oder zwei zusammenhängenden Commits. Danach erstmal Reference-Backtest neu laufen lassen und die *neuen* Diagnosewerte als Phase-2-Baseline dokumentieren.
3. **Zweite Code-Welle (Exit + Sizing):** D-06 + D-07 + D-08 + D-09 — diese sind voneinander abhängig (TP braucht SL, BE braucht SL, Sizing braucht SL).
4. **Optional in Phase 3:** D-10 (Session-Filter) als Optimizer-Parameter.
5. **Doku (D-13)** beiläufig mit dem ersten Commit der ersten Welle.

⚠️ **Stopp-Bedingung:** Wenn Welle 1 unter neuen Defaults < 10 Trades auf BTCUSDT 1h 2024-H1 generiert, ist die Strategie für unseren Markt zu konservativ — dann muss vor Welle 2 entschieden werden, ob (a) BB-σ erhöht wird, (b) Asset/TF gewechselt wird (Video-Autor sagt explizit „jeder Markt", aber zeigt NQ — BTC könnte zu volatil sein für σ=0.2), oder (c) Spec-Variante 2 als Fallback adoptiert wird.
