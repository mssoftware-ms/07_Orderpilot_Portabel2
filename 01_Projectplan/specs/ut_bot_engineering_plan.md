# UT Bot Alerts — Engineering Plan (Green-Field)

**Source spec:** [`01_Projectplan/specs/ut_bot_spec.md`](./ut_bot_spec.md) (Commit `541df22`)
**Phase-2-Plan-Anker:** [`01_Projectplan/260522_Gesamtplan_Phase1-3.md`](../260522_Gesamtplan_Phase1-3.md) §4 (rev4, Pfad A/B/C + Mandatory Sanity-Sweep)
**Erstellt:** 2026-05-23
**Charakter:** Green-Field-Implementierung — kein bestehender `ut_bot.rs` im Repo (Stand HEAD = `541df22`)
**Status:** Spec abgeschlossen, **Implementierung steht (warten auf QA-Sign-off der offenen Fragen aus Spec §12)**

---

## 1. Bestehende Engine-Infrastruktur (was wir schon haben)

Vor der Welle-Aufteilung eine ehrliche Bestandsaufnahme. Vieles aus Phase 1 + BB+RSI-Phase-2-Wellen kann UT Bot direkt wiederverwenden — entscheidend für die Welle-Größen-Schätzung.

| Komponente | Verfügbar | Wo (Repo-Pfad) | Anmerkung |
|---|---|---|---|
| `StrategyAddin` trait + `AddinManifest` + `ParameterSchema` | ✓ | `rust/trading_engine/src/strategy/mod.rs` | Pattern direkt übernehmbar |
| `Signal::{EnterLong, EnterShort, MoveStop, Exit, NoAction}` mit `sl, tp, size_pct` | ✓ | `rust/trading_engine/src/strategy/signal.rs` | TP als `Vec<f64>` — wir nehmen erstes Element |
| `Context` mit `index`, `current_price`, `closes(n)`, `all_candles()`, `set_state`/`get_state`, `param_or` | ✓ | `rust/trading_engine/src/strategy/context.rs` | Direkt übernehmbar |
| `BacktestEngine` mit F-04 Next-Bar-Open-Execution + Slippage + Fees | ✓ | `rust/trading_engine/src/backtest/mod.rs` | UT Bot muss keine eigene Execution-Logik bauen |
| **BE-Trail-Mechanik bei +1R** (D-08, TP-first → BE-Apply → SL-Check) | ✓ | `BacktestEngine::run` Step 2b | **Genau das, was UT Bot §5 verlangt** — keine Strategy-Änderung nötig, `initial_sl_distance` wird beim Entry automatisch erfasst |
| TP-first-Konflikt-Auflösung bei Same-Bar-SL+TP | ✓ | `BacktestEngine::run` Step 2a | wichtig für UT-Bot R:R 1:2 mit BE-Stop |
| `BollingerBands` + `calc_bollinger_bands` + `calc_bollinger_bands_ema` | ✓ | `rust/trading_engine/src/addins/bb_rsi.rs` | irrelevant für UT Bot (keine BB) — aber zeigt das Helper-Pattern |
| `calc_ema(values, period)` mit SMA-seeded Wilder-konvention | ✓ (BB+RSI Welle 1) | `bb_rsi.rs:94` | **Direkt nutzbar für UT-Bot EMA(200) Trendfilter** — pub function, importierbar |
| `calc_rsi(closes, period)` mit Wilder-Smoothing | ✓ | `bb_rsi.rs:193` | irrelevant für UT Bot — aber gibt das Wilder-Pattern als Vorlage für ATR |
| `sma(values)`, `stddev(values)` | ✓ | `bb_rsi.rs:34`, `bb_rsi.rs:42` | Helpers für SMI-Smoothing möglich |
| `swing_low(lows)`, `swing_high(highs)` | ✓ (BB+RSI Welle 2 / D-07) | `bb_rsi.rs:146`, `bb_rsi.rs:157` | **Direkt nutzbar für UT-Bot SL-Platzierung** — pub functions |
| `position_size_pct(entry_price, sl_distance, risk_per_trade)` (Risk-2 %) | ✓ (BB+RSI Welle 2 / D-09) | `bb_rsi.rs:183` | **Direkt nutzbar für UT-Bot Risk-Sizing** — pub function |
| EMA Dart-Parität | ✓ | `lib/services/indicators.dart` (vermutlich `calculateEMA`) | bestehend, BB+RSI nutzt es bereits |
| `swing_low`/`swing_high` Dart-Parität | ✓ | `lib/services/indicators.dart` (`swingLow`/`swingHigh`) | bestehend, BB+RSI Welle 2 |
| Risk-Sizing Dart-Parität | ✓ | `lib/services/backtest_service.dart` `_PendingEnterLong` Fill | bestehend, BB+RSI Welle 2 |
| **ATR-Indikator** (Wilder oder andere Smoothing) | ✗ | — | **NEU für UT-Bot Welle U1** |
| **UT-Bot-Trail-Linie + Direction-State** | ✗ | — | **NEU für Welle U2** |
| **Stochastic Momentum Index (SMI)** | ✗ | — | **NEU für Welle U2** |
| **Session-Filter (09:00–23:00 Lokalzeit)** | ✗ | — | **NEU für Welle U2** (auch von BB+RSI Spec §7 verlangt, dort aber nicht implementiert — siehe §12.2 der Spec) |
| **`ut_bot.rs` selbst** | ✗ | `rust/trading_engine/src/addins/ut_bot.rs` (geplant) | **NEU für Welle U2** |
| **Dart `UtBotParams` + Strategy-Branch** | ✗ | `lib/services/backtest_service.dart` (Erweiterung) | **NEU für Welle U2** |

**Punktuell wichtig:** Da die Engine die BE-Trail-Mechanik und Risk-Sizing über `size_pct` schon kann, **emittiert die UT-Bot-Strategy nur statische SL/TP/size_pct beim Entry** (analog BB+RSI nach Welle 2). Sie muss intra-Trade nichts mehr managen außer dem Session-Filter beim Entry.

---

## 2. Implementation-Wellen

### Welle U1 — ATR-Indikator (Engine-Infrastruktur)

**Scope:** Pure-function ATR-Helper in Rust + Dart, Wilder-Smoothing-konvention (parity-konform mit `calc_rsi`).

**Files:**
- `rust/trading_engine/src/addins/ut_bot.rs` (neu) — `pub fn calc_atr(highs: &[f64], lows: &[f64], closes: &[f64], period: usize) -> Option<f64>` (oder ein dedizierter `addins/indicators.rs` falls QA Refactor-Path bevorzugt — siehe §3 offene Frage 1)
- `lib/services/indicators.dart` — `double? calculateATR(List<Candle> candles, int period)` parity-konform

**Spec der Funktion:**
- True Range pro Bar: `tr = max(high - low, |high - prev_close|, |low - prev_close|)`
- Wilder-Smoothing: erstes ATR = `mean(tr[0..period])` (= simple average), dann recursiv `atr = (atr * (period - 1) + tr) / period`
- Returns `None` falls `closes.len() < period + 1` (analog `calc_rsi`)
- Pure: kein Strategy-State, parity-locked

**Tests (mindestens):**
- `test_atr_insufficient_data`: weniger als `period + 1` closes → `None`
- `test_atr_constant_tr`: TR = 1.0 für alle Bars → ATR = 1.0 (konvergiert sofort)
- `test_atr_step_function`: TR = 1.0 für `period` Bars, dann TR = 2.0 → ATR konvergiert exponentiell zu 2.0; verifiziere ATR-Wert nach genau N Bars analytisch
- `test_atr_negative_tr_impossible`: TR ist per Definition ≥ 0, also kein negativer Wert in Test-Output
- `test_atr_dart_rust_parity` (Cross-Engine): synthetische 50-Candle-Fixture, Rust- und Dart-ATR weichen um < 1e-9 ab

**Atomarer Commit:** `feat(phase-2): ATR (Wilder) indicator helper for UT Bot`

**Geschätzt:** **2.5 h** (Rust + Dart + Tests + Parität-Verifikation)

---

### Welle U2 — UT Bot Strategy (Add-In + Helpers + Dart-Fallback)

**Scope:** Vollständige UT-Bot-Strategy als StrategyAddin-Implementierung mit allen Sub-Helpers (UT-Bot-Trail, SMI, Session-Filter), Manifest-Registrierung, Dart-Fallback.

**Files:**
- `rust/trading_engine/src/addins/ut_bot.rs` (neu, wachsend über die atomaren Commits unten):
  - UT-Bot-Trail-State + `update_trail()` pro Bar (Pinescript-Formel aus Spec §1)
  - `calc_smi()` (Blau-1993-Default-Variante, siehe Spec §12.4)
  - Session-Filter-Helper `is_in_session(timestamp_ms, tz_offset_minutes, start_hour, end_hour) -> bool` (lokal im UT-Bot, mit TODO-Refactor-Marker für Engine-Shared)
  - `UtBotStrategy` struct + `impl StrategyAddin`
  - `ut_bot_manifest()` mit allen `ParameterSchema`-Einträgen
  - Tests pro Sub-Helper + Strategy-Integration-Tests
- `rust/trading_engine/src/addins/mod.rs` — `pub mod ut_bot; pub use ut_bot::UtBotStrategy;`
- `lib/services/backtest_service.dart` — neuer `UtBotParams`-Datentyp + Strategy-Branch in der Run-Schleife (parallel zur Rust-Implementierung)
- `lib/services/indicators.dart` — `calculateSMI(candles, ...)`, `calculateUtBotTrail(candles, key_value, atr_period)`, `isInSession(timestamp_ms, ...)`

**Parameter (manifest, alle f64 wegen Engine-Konvention):**

| Name | Default | Min | Max | Step | Spec-§ | Bemerkung |
|---|---|---|---|---|---|---|
| `ema_period` | 200 | 20 | 500 | 1 | §1 | Trendfilter |
| `key_value` | **2.0** | 0.5 | 5.0 | 0.5 | §1, §12.1 | **Default-Wahl QA-pending — siehe §3 offene Frage 2** |
| `atr_period` | 1 | 1 | 50 | 1 | §1 | Im Video für die verbesserte Variante auf 1 reduziert |
| `smi_length` | 14 | 5 | 50 | 1 | §1, §12.4 | Blau-1993-Standard |
| `smi_k_smoothing` | 5 | 1 | 20 | 1 | §1, §12.4 | Blau-1993-Standard |
| `smi_d_smoothing` | 3 | 1 | 20 | 1 | §1, §12.4 | Blau-1993-Standard |
| `swing_lookback_bars` | 20 | 5 | 100 | 1 | §4 | analog BB+RSI |
| `tp_rr_ratio` | 2.0 | 0.5 | 10.0 | 0.1 | §5 | R:R 1:2 (BB+RSI nutzt 3.0) |
| `risk_per_trade` | 0.02 | 0.001 | 1.0 | 0.001 | §8 | analog BB+RSI |
| `session_start_hour_local` | 9 | 0 | 23 | 1 | §7 | Lokalzeit Berlin |
| `session_end_hour_local` | 23 | 1 | 24 | 1 | §7 | Lokalzeit Berlin |

**Entry-Logik im `on_candle` (Pseudocode, Long-Seite — Short ist Spiegel):**

```rust
// Warm-up gate: largest required history
let start_idx = ema_period
    .max(atr_period + 1)
    .max(smi_length + smi_k_smoothing + smi_d_smoothing)
    .max(swing_lookback_bars);
if ctx.index() < start_idx { return None; }

// 1. Compute indicators on full prior-close history (path-dependence!)
let ema_200 = calc_ema(&ctx.closes(ctx.index() + 1), ema_period)?;
let atr = calc_atr(&highs_full, &lows_full, &closes_full, atr_period)?;

// 2. Update UT-Bot trail (state in self.state.trail / .prev_close / .direction)
self.update_ut_bot_trail(price, atr, key_value);
let direction_flip_up = self.state.prev_direction == -1 && self.state.direction == 1;

// 3. Compute SMI cross
let (smi_index_now, smi_signal_now, smi_index_prev, smi_signal_prev) =
    self.compute_smi_pair(...);
let smi_cross_up_below_zero =
    smi_index_prev < smi_signal_prev
    && smi_index_now >= smi_signal_now
    && smi_index_now < 0.0
    && smi_signal_now < 0.0;

// 4. Session filter
if !is_in_session(candle.timestamp, session_start_hour_local, session_end_hour_local) {
    return Some(Signal::NoAction);
}

// 5. Confluence
if !ctx.in_position
    && price > ema_200            // EMA trend
    && direction_flip_up           // UT Bot direction flipped this bar
    && smi_cross_up_below_zero     // SMI cross trigger
{
    let pre_signal = &ctx.all_candles()[ctx.index() - swing_lookback_bars .. ctx.index()];
    let swing_low_price = swing_low(&pre_signal.iter().map(|c| c.low).collect::<Vec<_>>())?;
    if swing_low_price >= price { return Some(Signal::NoAction); } // degenerate
    let sl_distance = price - swing_low_price;
    let tp_price = price + tp_rr_ratio * sl_distance;
    let size_pct = position_size_pct(price, sl_distance, risk_per_trade);
    ctx.in_position = true;
    return Some(Signal::EnterLong {
        sl: Some(swing_low_price),
        tp: vec![tp_price],
        size_pct,
    });
}
```

**Tests (mindestens):**

UT-Bot-Trail-Helper:
- `test_ut_bot_trail_initial`: erste Bar, prev_close == 0.0 / NaN-Init → Trail = close ± nLoss korrekt
- `test_ut_bot_trail_long_to_short_flip`: close crosses below trail → direction flips -1
- `test_ut_bot_trail_short_to_long_flip`: close crosses above trail → direction flips +1
- `test_ut_bot_trail_persists_when_no_flip`: trail steigt monoton in Uptrend, fällt monoton in Downtrend

SMI-Helper:
- `test_smi_zero_at_midrange`: konstanter Range mit close in der Mitte → SMI ≈ 0
- `test_smi_positive_in_uptrend`: monoton steigende Closes → SMI > 0
- `test_smi_negative_in_downtrend`: monoton fallende Closes → SMI < 0
- `test_smi_dart_rust_parity`: 50-Candle-Fixture, < 1e-9 Drift

Session-Filter:
- `test_session_filter_inside_window`: 12:00 UTC+1 (= 12:00 Lokal Berlin Sommer / 13:00 Berlin Winter, je nach TZ-Konvention) → in Session
- `test_session_filter_before_window`: 03:00 Lokal → out
- `test_session_filter_after_window`: 23:30 Lokal → out
- `test_session_filter_edge_at_start`: exakt 09:00:00 → in
- `test_session_filter_edge_at_end`: exakt 23:00:00 → in oder out (Konvention dokumentieren)

Strategy-Integration:
- `test_strategy_long_entry_signal`: synthetisches Fixture mit Uptrend + UT-Bot-Flip + SMI-Cross-Up-Below-Zero im Sessions-Fenster → EnterLong mit korrektem SL / TP / size_pct
- `test_strategy_short_entry_signal`: Spiegel
- `test_strategy_no_signal_without_ema_trend`: confluence-1 fehlt → keine Signal
- `test_strategy_no_signal_without_ut_bot_flip`: confluence-2 fehlt → keine Signal
- `test_strategy_no_signal_without_smi_cross`: confluence-3 fehlt → keine Signal
- `test_strategy_no_signal_outside_session`: Setup gültig aber Bar außerhalb 09:00–23:00 → keine Signal
- `test_strategy_long_tp_at_2r_from_signal_close`: signal-bar close + 2 × sl_distance
- `test_strategy_long_size_pct_matches_risk_2_percent_formula`: `100 * 0.02 * entry / sl_distance`
- `test_strategy_be_trail_via_engine`: Integration mit `BacktestEngine`, Bar reaches +1R → SL pulled to entry; nächster Retracement → BE-Exit (PnL ≈ 0 vor Fees)

Manifest:
- `test_strategy_manifest`: 11 Parameter, IDs konsistent, Default-Werte stimmen

Parität:
- `test_dart_rust_parity_ut_bot_200_candle_fixture`: Synthese-Fixture mit mindestens 1 Long + 1 Short Entry, Dart-Backtest und Rust-Backtest haben identische Trades (entryTimestamp, exitTimestamp, exitPrice, pnl) mit < 1e-9 Drift

**Atomare Commits (Vorschlag):**
1. `feat(phase-2): UT Bot trail + direction state helper (U2.1)`
2. `feat(phase-2): Stochastic Momentum Index (Blau 1993) helper (U2.2)`
3. `feat(phase-2): session-filter helper for UT Bot (local 09:00–23:00) (U2.3)`
4. `feat(phase-2): UT Bot strategy manifest + skeleton (U2.4)`
5. `feat(phase-2): UT Bot long-entry confluence logic (U2.5)`
6. `feat(phase-2): UT Bot short-entry confluence logic (U2.6)`
7. `feat(phase-2): UT Bot R:R 1:2 TP + risk-2 % sizing wiring (U2.7)`
8. `feat(phase-2): UT Bot Dart fallback for backtest_service parity (U2.8)`
9. `test(phase-2): Dart-Rust UT Bot parity on 200-candle synthesis (U2.9)`

**Geschätzt:** **8–12 h** (Spread groß wegen offener QA-Fragen aus §3; falls SMI-Variante recherchiert werden muss + 1 h)

---

### Welle U3 — Reference-Backtest auf XLSX-Setup + Path-A/B/C-Klassifikation

**Scope:** Vollständiger Backtest auf BTCUSDT 5min über 66 Tage, Vergleich mit XLSX-Targets, ggf. Mandatory Sanity-Sweep, ggf. Diagnose-MD.

**Steps:**
1. **Data-Vorbereitung:** Sicherstellen dass BTCUSDT 5min Daten für 66 Tage verfügbar sind (≥ 19000 Kerzen). Standard-Range-Vorschlag: 2024-04-01 bis 2024-06-05 (66 Tage, Bull-Run-Phase-Mix). Falls Daten fehlen → Binance-Download-Job aus Phase 1.
2. **Baseline-Backtest:** UT Bot Default-Parameter aus Manifest auf BTCUSDT 5min, 66 Tage.
3. **Vergleich gegen Tabelle 13.2 der Spec.**
4. **Wenn alle Metriken im Band → Pfad A, fertig.**
5. **Wenn QA-Sign-off die Wahl von key_value (siehe §3 Frage 2) auf einen anderen Wert verschoben hat und das im Band landet → Pfad B mit Begründung in Spec §12.**
6. **Wenn baseline und einfache Param-Wahl nicht reichen → Mandatory Sanity-Sweep (Spec §13.3):**
   - TF-Sweep: BTCUSDT 15min, 1h
   - Asset-Sweep: ETHUSDT 5min
   - Param-Sweep: `key_value` ∈ {1.5, 2.0, 3.0, 5.0} × `atr_period` ∈ {1, 5, 10}
7. **Diagnose-MD schreiben:** `01_Projectplan/specs/ut_bot_diagnose_{YYYY-MM-DD}.md` mit Tabellen-Format analog zu `bb_rsi_diagnose_2026-05-23.md`.
8. **Spec §13 finalisieren** mit konkreter Path-A/B/C-Markierung und Root-Cause-Hypothese falls Pfad C.

**Atomarer Commit (falls Pfad A):** `docs(phase-2): ut_bot §13 classified as Path A — XLSX targets met`
**Atomare Commits (falls Pfad B):** `feat(phase-2): adjust UT Bot defaults per QA (key_value=X)` + `docs(phase-2): ut_bot §13 classified as Path B`
**Atomare Commits (falls Pfad C):** `docs(phase-2): UT Bot diagnose sweep + recommendation ({date})` + `docs(phase-2): ut_bot §13 classified as Path C with full diagnosis`

**Geschätzt:**
- Pfad A: **1.5 h** (Backtest-Run + Vergleich + Doku)
- Pfad B: **2 h** (zusätzlich Default-Anpassung)
- Pfad C: **3–4 h** (Sanity-Sweep mit ~7 Backtests + ausführliche Diagnose-MD)

---

## 3. Risiken / Offene Fragen für QA-Entscheidung VOR Welle U2-Start

Diese Fragen müssen vor dem Code-Schreiben in Welle U2 entschieden werden. Ohne diese Entscheidungen entstehen entweder spätere Refactors oder Pfad-B-Vermerke ohne ehrliche Begründung.

### Frage 1 — Architektur: ATR + ggf. SMI/Session als shared Engine-Helpers?

**Was sagt der Code-Stand:** `bb_rsi.rs` enthält alle Helper-Funktionen (sma, stddev, swing_low, position_size_pct, calc_ema, calc_rsi, etc.) als `pub` direkt im selben File. Kein dedizierter `addins/indicators.rs`-Modul.

**Pragmatische Default-Entscheidung:** ATR + SMI + Session-Filter zunächst in `ut_bot.rs` als `pub` Helpers, mit `// TODO: extract to addins/indicators.rs once a third strategy needs them`. Refactor zum Shared-Modul in Phase 3 oder beim Ichimoku-Implement.

**QA-Entscheidung:** Sollen wir jetzt schon einen `addins/indicators.rs`-Refactor machen (sauberer, aber +1.5 h Aufwand und ein zusätzlicher Commit, der BB+RSI re-testen muss) oder pragmatisch in `ut_bot.rs` bleiben?

### Frage 2 — UT-Bot `key_value` Default (entscheidend für Backtest-Ergebnis)

**Was sagt das Transkript:** „den keyvue von z auf [TEXT ABGEBROCHEN]" (T194–T196). Variante-1-Wert war key=2 (T67). „Erhöhen" → mindestens 3.

**Optionen:**
- **(a) Default key=2** (TradingView-QuantNomad-Original-Default; konservativster Default-Treuer-Wert)
- **(b) Default key=3** (häufige Community-Konvention für „weniger sensitiv" auf 5min; passt zum „erhöhen"-Sprachgebrauch)
- **(c) Erst Welle U3-Backtest mit key=2 laufen lassen, falls nicht im Band dann auf key=3 wechseln und als Pfad B markieren**

**QA-Entscheidung:** Vorschlag = (c) — das ist die ehrlichste Form (keine Default-Vorab-Anpassung ohne Backtest-Beleg).

### Frage 3 — SMI-Variante (entscheidend für Reproduzierbarkeit des Videos)

**Was sagt das Transkript:** „stochastic Momentum Indikator … nehmt diesen hier von Uday" (T207–T208), Default-Werte (T216–T217). Konkrete Pinescript-Source des „Uday"-Indikators ist im Transkript nicht verlinkt.

**Optionen:**
- **(a) Blau-1993-Standard (Default in Spec §12.4)** — sauberster akademischer Default, parity-konform, klar dokumentiert
- **(b) Recherche zu Uday's exakter Variante** (Suche auf TradingView „Stochastic Momentum Index Uday") — Aufwand ~1 h, Risiko = mehrere Treffer, nicht eindeutig identifizierbar
- **(c) Erst Welle U3 mit Blau laufen lassen, falls Pfad-C-Risiko → Recherche-Nachzug**

**QA-Entscheidung:** Vorschlag = (c) — gleicher Pragmatismus wie Frage 2.

### Frage 4 — Session-Filter Architektur (Spec §12.2)

**Was sagt der Code-Stand:** Session-Filter ist auch in BB+RSI Spec §7 verlangt, dort aber **nicht implementiert** (Diff-MD listet als „Fehlt komplett"). UT Bot bringt denselben Bedarf.

**Optionen:**
- **(a) UT-Bot-lokal:** Session-Filter im `ut_bot.rs` als private function. Duplikat-Risiko falls BB+RSI nachgezogen wird.
- **(b) Engine-shared:** Neues `rust/trading_engine/src/addins/common.rs` (oder ähnlich) für `is_in_session(...)`. BB+RSI muss dann nicht re-implementiert werden, aber jetziger BB+RSI-Status (kein Session-Filter aktiv) **darf nicht ungewollt aktiviert werden** — sonst kippt BB+RSI Welle-2-Verifikation.

**QA-Entscheidung:** Vorschlag = (a) für die erste Implementation, mit klarem TODO-Marker. Refactor zu (b) erst dann, wenn entweder eine dritte Strategy es braucht oder BB+RSI nachgezogen wird.

### Frage 5 — Welle-U2-Größe (8–12 h) — als ein PR oder gesplittet?

**Beobachtung:** BB+RSI Welle 1 und Welle 2 wurden in vielen kleinen atomaren Commits direkt auf `main` ge-pushed (siehe Git-Log D-01..D-11). UT Bot Welle U2 hat 9 vorgeschlagene atomare Commits, was bei 8–12 h Aufwand zu mehreren Push-Punkten führt.

**QA-Entscheidung:** Soll Welle U2 als 9 separate Pushes auf `main` (wie BB+RSI) oder als ein zusammenhängender Push am Ende der Welle erfolgen?

---

## 4. Vorgeschlagene Reihenfolge

Sobald die 5 Fragen aus §3 geklärt sind:

1. **Welle U1 atomar:** ATR-Helper (Rust + Dart + Parität-Test) → 1 Commit + Push
2. **Welle U2.1–U2.9 (siehe oben):** Pro atomarer Commit grün → Push. Reihenfolge wie in §2 Welle-U2-Commits aufgelistet.
3. **Parity-Verifikation nach Welle U2.9:** kein Commit, nur Run von `flutter test test/integration/dart_rust_parity_test.dart` und der UT-Bot-Parity-Fixture.
4. **Welle U3:** Reference-Backtest + Path-Klassifikation (1–3 Commits je nach Pfad).
5. **Phase-2-Tag-Vorbereitung:** Wenn UT Bot abgeschlossen ist und Ichimoku noch aussteht — Pfad-Status in `01_Projectplan/260522_Gesamtplan_Phase1-3.md` §4.4 aktualisieren.

---

## 5. Geschätzter Gesamt-Aufwand

| Welle | Aufwand | Annahmen |
|---|---|---|
| U1 (ATR) | 2.5 h | Standard Wilder-Smoothing, klares Pattern aus `calc_rsi` |
| U2 (Strategy + Helpers + Dart-Parität) | 8–12 h | Spread = abhängig von QA-Antworten zu §3 (besonders SMI-Variante und Architektur) |
| U3 Pfad A | 1.5 h | optimaler Fall |
| U3 Pfad B | 2 h | + Default-Anpassung |
| U3 Pfad C | 3–4 h | Sanity-Sweep + Diagnose-MD |

**Erwarteter Gesamt-Aufwand:** **12–18 h** für die Implementierung + Welle U3, je nach Pfad-C-Eintritt.

**Vergleich BB+RSI:** Welle 1 + Welle 2 + Welle 3 (Diagnose) zusammen ~20–25 h Code+Doku (geschätzt aus Git-Log: 14 Commits zwischen 5a33814 und 63e31e8 über mehrere Sessions). UT Bot ist ohne den Backtester-Bias-Schmerz von BB+RSI etwas schlanker, aber mit drei neuen Indikatoren (ATR + SMI + Session-Filter) statt nur Default-Verschiebung von Bestehendem.

---

## 6. Out-of-Scope für diese Wellen

- **Variante 1** (Mo's Original mit Linear Regression Candles): vom Autor verworfen, kein eigener Indikator in Engine, **keine Implementierung**.
- **Multi-Strategy-Run** (BB+RSI + UT Bot parallel im selben Backtest): kein Feature der Engine, kein Phase-2-Scope.
- **Live-Trading mit UT Bot:** out-of-scope (Phase-3-Diskussion).
- **Adaptive `key_value` oder `atr_period`** (z.B. Bollinger-Width-basiert): zu früh, gehört in Phase-3-Optimizer.
- **Übertragung der UT-Bot-Logik auf andere Strategien** (z.B. „BB+RSI mit ATR-basiertem SL statt Swing-Low"): Spec BB+RSI §4 erwähnt das als „Phase-3 Alternative" — separate Spec, nicht in dieser UT-Bot-Welle.
