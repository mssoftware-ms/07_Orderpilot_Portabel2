# Ichimoku Cloud — Engineering Plan (Green-Field)

**Source spec:** [`01_Projectplan/specs/ichimoku_spec.md`](./ichimoku_spec.md) (Commit `d3ba6d3`)
**Phase-2-Plan-Anker:** [`01_Projectplan/260522_Gesamtplan_Phase1-3.md`](../260522_Gesamtplan_Phase1-3.md) §4 (rev4, Pfad A/B/C + Mandatory Sanity-Sweep)
**Erstellt:** 2026-05-23
**Charakter:** Green-Field-Implementierung — kein bestehender `ichimoku.rs` im Repo (Stand HEAD = `d3ba6d3`, `rust/trading_engine/src/addins/` enthält nur `bb_rsi.rs` und `ut_bot.rs`)
**Status:** Spec abgeschlossen, **Implementierung steht (warten auf QA-Sign-off der offenen Fragen aus §3)**

---

## 1. Bestehende Engine-Infrastruktur (was wir schon haben)

Vor der Welle-Aufteilung eine ehrliche Bestandsaufnahme nach BB+RSI- und UT-Bot-Implementierungen. Vieles aus Phase 1 + den ersten zwei Phase-2-Strategien kann Ichimoku direkt wiederverwenden — entscheidend für die Welle-Größen-Schätzung.

| Komponente | Verfügbar | Wo (Repo-Pfad) | Anmerkung |
|---|---|---|---|
| `StrategyAddin` trait + `AddinManifest` + `ParameterSchema` | ✓ | `rust/trading_engine/src/strategy/mod.rs` | Pattern direkt übernehmbar |
| `Signal::{EnterLong, EnterShort, MoveStop, Exit, NoAction}` mit `sl, tp, size_pct` | ✓ | `rust/trading_engine/src/strategy/signal.rs` | TP als `Vec<f64>` — wir nehmen erstes Element |
| `Context` mit `index`, `current_price`, `closes(n)`, `all_candles()`, `set_state`/`get_state`, `param_or` | ✓ | `rust/trading_engine/src/strategy/context.rs` | Direkt übernehmbar |
| `BacktestEngine` mit F-04 Next-Bar-Open-Execution + Slippage + Fees | ✓ | `rust/trading_engine/src/backtest/mod.rs` | Ichimoku muss keine eigene Execution-Logik bauen |
| **BE-Trail-Mechanik bei +1R** (D-08, TP-first → BE-Apply → SL-Check) | ✓ | `BacktestEngine::run` Step 2b | **Genau das, was Ichimoku §5 verlangt** — analog UT Bot |
| TP-first-Konflikt-Auflösung bei Same-Bar-SL+TP | ✓ | `BacktestEngine::run` Step 2a | wichtig für R:R 1:2 mit BE-Stop |
| `calc_ema(values, period)` mit SMA-seeded Wilder-Konvention | ✓ (BB+RSI Welle 1) | `bb_rsi.rs` | irrelevant für Ichimoku (kein EMA) |
| `calc_rsi(closes, period)` mit Wilder-Smoothing | ✓ | `bb_rsi.rs` | irrelevant für Ichimoku |
| `calc_atr(highs, lows, closes, period)` Wilder-Smoothing | ✓ (UT Bot Welle U1) | `addins/ut_bot.rs` (pub) | irrelevant für Ichimoku — aber zeigt das Helper-Pattern |
| `sma(values)`, `stddev(values)` | ✓ | `bb_rsi.rs` | irrelevant für Ichimoku |
| `swing_low(lows)`, `swing_high(highs)` | ✓ (BB+RSI Welle 2 / D-07) | `bb_rsi.rs` | **Indirekt relevant** — Ichimoku braucht **rolling_min/max INKLUSIVE der aktuellen Bar** (Spec §1: `high_max(N)` über die letzten N Bars). `swing_high/low` operieren auf „letzte N Bars exklusive der aktuellen". Drei Optionen siehe §3 Frage 1. |
| `position_size_pct(entry_price, sl_distance, risk_per_trade)` (Risk-2 %) | ✓ (BB+RSI Welle 2 / D-09) | `bb_rsi.rs` | **Direkt nutzbar für Ichimoku Risk-Sizing** |
| EMA Dart-Parität | ✓ | `lib/services/indicators.dart` (`calculateEMA`) | irrelevant für Ichimoku |
| `swing_low`/`swing_high` Dart-Parität | ✓ | `lib/services/indicators.dart` (`swingLow`/`swingHigh`) | Indirekt relevant analog Rust |
| Risk-Sizing Dart-Parität | ✓ | `lib/services/backtest_service.dart` `_PendingEnterLong` Fill | bestehend |
| **Session-Filter** (`is_in_session(timestamp_ms, ...)`) | ✓ (UT Bot Welle U2-3, lokal in `ut_bot.rs`) | `addins/ut_bot.rs` (lokal-pub) | **Wiederverwendbar** — entweder via direkter `pub use` oder durch Refactor zu `addins/common.rs` (siehe §3 Frage 3) |
| **Rolling-Max/-Min Helpers (inklusiv aktuelle Bar)** | ✗ | — | **NEU für Welle I1** |
| **Tenkan-Sen, Kijun-Sen Berechnung** | ✗ | — | **NEU für Welle I1** |
| **Senkou-Span A/B mit Future-Shift-Anker** | ✗ | — | **NEU für Welle I1** |
| **Chikou-Vergleichs-Anker (close_i vs cloud_{i-26})** | ✗ | — | **NEU für Welle I2** (im Strategy-Code, nicht als isolierter Helper) |
| **Cloud-Bound-Helpers (`cloud_upper`, `cloud_lower`, `cloud_is_green`)** | ✗ | — | **NEU für Welle I1** (trivial, aber explizit pub für Testbarkeit) |
| **Ichimoku-Score-Indikator (Confluence-Sum, §12.2 Default)** | ✗ | — | **NEU für Welle I2** |
| **`ichimoku.rs` selbst** | ✗ | `rust/trading_engine/src/addins/ichimoku.rs` (geplant) | **NEU für Welle I2** |
| **Dart `IchimokuParams` + Strategy-Branch** | ✗ | `lib/services/backtest_service.dart` (Erweiterung) | **NEU für Welle I2** |

**Punktuell wichtig:** Da die Engine die BE-Trail-Mechanik und Risk-Sizing schon kann, **emittiert die Ichimoku-Strategy nur statische SL/TP/size_pct beim Entry** (analog UT Bot nach Welle U2). Sie muss intra-Trade nichts mehr managen außer dem Session-Filter beim Entry.

**Schwierigkeits-Spread vs BB+RSI + UT Bot:**
- BB+RSI: 1 Indikator (BB), 1 Trigger (RSI), Welle 1 hatte `calc_ema` + `calc_rsi` als Hauptarbeit (~8 h).
- UT Bot: 1 Indikator (ATR), 2 Trigger (UT-Bot-Direction + SMI), Welle U1+U2 (~12 h).
- Ichimoku: **5 Indikator-Linien + 1 Score-Indikator** (Total 6 berechnete Werte pro Bar) + **3 Lese-Anker pro Senkou-Span** (current, future, i-26) — komplexester Indikator-Build der drei Strategien. Geschätzt ~14–18 h Welle I1+I2.

---

## 2. Implementation-Wellen

### Welle I1 — Ichimoku-Indikator-Helpers (Engine-Infrastruktur)

**Scope:** Pure-function Indikator-Helpers in Rust + Dart-Parität. Alle fünf Ichimoku-Linien + Cloud-Bound-Helpers + Rolling-Max/-Min mit den korrekten Shift-Konventionen aus Spec §1.1.

**Files:**
- `rust/trading_engine/src/addins/ichimoku.rs` (neu, wachsend über die atomaren Commits unten)
- `lib/services/indicators.dart` — Erweiterung um Ichimoku-Helpers

**Sub-Module (vorgeschlagene Reihenfolge in atomaren Commits):**

**I1-1: Rolling-Max/-Min Helpers (inklusive aktuelle Bar)**
- `pub fn rolling_max(values: &[f64], end_idx: usize, period: usize) -> Option<f64>` — `max` über `values[end_idx + 1 - period ..= end_idx]`, returns `None` falls `end_idx + 1 < period`
- `pub fn rolling_min(...)` analog
- Pure, parity-locked
- Tests:
  - `test_rolling_max_insufficient_data`: `values.len() == 5, period = 10` → `None`
  - `test_rolling_max_simple`: `values = [1,2,3,4,5], end_idx=4, period=3` → `5` (max von `[3,4,5]`)
  - `test_rolling_max_window_at_start`: `end_idx == period - 1` → max von ersten `period` Werten
  - `test_rolling_min` Spiegel
- **Dart-Parity:** `double? rollingMax(List<double> values, int endIdx, int period)` identisch
- Commit: `feat(phase-2): rolling_max/min helpers for Ichimoku (I1-1)`

**I1-2: Tenkan-Sen + Kijun-Sen**
- `pub fn calc_tenkan(highs: &[f64], lows: &[f64], end_idx: usize, period: usize) -> Option<f64>` = `(rolling_max(highs, end_idx, period) + rolling_min(lows, end_idx, period)) / 2.0`
- `pub fn calc_kijun(...)` identisch mit anderer Period
- Tests:
  - `test_tenkan_constant_range`: `highs = [100, 100, ...], lows = [90, 90, ...]` → Tenkan = 95
  - `test_kijun_at_warmup_boundary`: `end_idx = 25, period = 26` → None; `end_idx = 26` → erster gültiger Wert
  - `test_tenkan_window_slides_correctly`: monoton steigende highs/lows → Tenkan steigt monoton
  - Dart-Parity-Test
- Commit: `feat(phase-2): Tenkan-Sen + Kijun-Sen helpers for Ichimoku (I1-2)`

**I1-3: Senkou-Span A/B mit Two-Anchor-Return**
- `pub fn calc_senkou_a(highs: &[f64], lows: &[f64], end_idx: usize, tenkan_period: usize, kijun_period: usize) -> Option<f64>`
  - returns `(calc_tenkan(highs, lows, end_idx, tenkan_period) + calc_kijun(highs, lows, end_idx, kijun_period)) / 2.0`
  - **WICHTIG:** Diese Funktion liefert den „heutigen Roh-Wert" — der ist der Future-Span-Wert (i+26) wenn man ihn als Senkou interpretiert, oder der Current-Span-Wert wenn man die Roh-Werte aus end_idx-26 nimmt. Die Strategy-Logik macht die Disambiguation.
- `pub fn calc_senkou_b(highs: &[f64], lows: &[f64], end_idx: usize, period: usize) -> Option<f64>` analog
- Konvention: Helper liefert **rohen** Wert. Strategy-Code wählt den Anker.
- Tests:
  - `test_senkou_a_equals_tenkan_kijun_average`: konstruierte Werte
  - `test_senkou_b_uses_period_52`: warmup-boundary bei period=52
  - Dart-Parity-Test
- Commit: `feat(phase-2): Senkou-Span A/B helpers for Ichimoku (I1-3)`

**I1-4: Cloud-Bound-Helpers**
- `pub fn cloud_upper(span_a: f64, span_b: f64) -> f64` = `span_a.max(span_b)`
- `pub fn cloud_lower(span_a: f64, span_b: f64) -> f64` = `span_a.min(span_b)`
- `pub fn cloud_is_green(span_a: f64, span_b: f64) -> bool` = `span_a > span_b` (strict-`>`, Spec §12.5)
- Trivial, aber explizit pub für Testbarkeit + Dokumentations-Anker
- Tests:
  - `test_cloud_upper_lower_swap`: `span_a < span_b` → upper = span_b, lower = span_a; und vice versa
  - `test_cloud_is_green_strict`: `span_a == span_b` → false (strict-`>`)
- Commit: `feat(phase-2): Cloud-Bound helpers + green/red color logic (I1-4)`

**Geschätzt:** **4 h** (4 atomare Commits, jeweils Rust + Dart + Tests; Helpers sind algorithmisch trivial, nur das Future-Shift-Anchor-Konzept braucht klare Dokumentation in den Doc-Comments)

---

### Welle I2 — Ichimoku Strategy (Add-In + Score + Dart-Fallback)

**Scope:** Vollständige Ichimoku-Strategy als StrategyAddin-Implementierung mit Score-Indikator-Sub-Modul, Session-Filter-Wiederverwendung (nach §3 Frage 3), Manifest-Registrierung, Dart-Fallback.

**Files:**
- `rust/trading_engine/src/addins/ichimoku.rs` (wachsend):
  - `calc_ichimoku_score()` (§12.2 Default-Implementation — Confluence-Sum mit 5 Komponenten, Periode-×4)
  - `IchimokuStrategy` struct + `impl StrategyAddin`
  - `ichimoku_manifest()` mit allen `ParameterSchema`-Einträgen
  - Tests pro Sub-Helper + Strategy-Integration-Tests
- `rust/trading_engine/src/addins/mod.rs` — `pub mod ichimoku; pub use ichimoku::IchimokuStrategy;`
- `lib/services/backtest_service.dart` — neuer `IchimokuParams`-Datentyp + Strategy-Branch in der Run-Schleife
- `lib/services/indicators.dart` — `calculateIchimokuScore(...)`, ggf. weitere Hilfs-Funktionen

**Falls §3 Frage 3 = Refactor jetzt:**
- `rust/trading_engine/src/addins/common.rs` (neu) — `pub fn is_in_session(...)` aus `ut_bot.rs` rausgezogen
- `rust/trading_engine/src/addins/ut_bot.rs` — Session-Filter-Aufruf via `super::common::is_in_session`
- `rust/trading_engine/src/addins/mod.rs` — `pub mod common;`
- `lib/services/indicators.dart` — Session-Filter Dart-Parität ebenfalls extrahieren (analog Rust)
- **Re-Test UT Bot:** `cargo test --test integration -p trading_engine` für Strategien-Integration grün; FFI-Parity-Test grün
- Commit: `refactor(phase-2): extract session-filter to addins/common.rs (used by ut_bot + ichimoku)`

**Parameter (manifest, alle f64 wegen Engine-Konvention):**

| Name | Default | Min | Max | Step | Spec-§ | Bemerkung |
|---|---|---|---|---|---|---|
| `tenkan_period` | 9 | 3 | 30 | 1 | §1 | Standard |
| `kijun_period` | 26 | 5 | 100 | 1 | §1 | Standard |
| `senkou_b_period` | 52 | 10 | 200 | 1 | §1 | Standard |
| `shift_period` | 26 | 5 | 100 | 1 | §1 | Senkou-Forward + Chikou-Backward |
| `score_period_multiplier` | 4 | 1 | 8 | 1 | §1, §12.2 | Periode-×4 für MTF-Verhalten |
| `score_long_threshold` | 60 | 20 | 100 | 5 | §12.2 | „grün" Cut-off |
| `score_short_threshold` | -60 | -100 | -20 | 5 | §12.2 | „rot" Cut-off |
| `tp_rr_ratio` | 2.0 | 0.5 | 10.0 | 0.1 | §5 | R:R 1:2 |
| `risk_per_trade` | 0.02 | 0.001 | 1.0 | 0.001 | §8 | 2 % |
| `session_start_hour_local` | 9 | 0 | 23 | 1 | §7 | Lokalzeit Berlin |
| `session_end_hour_local` | 23 | 1 | 24 | 1 | §7 | Lokalzeit Berlin |
| `session_filter_enabled` | 1.0 | 0.0 | 1.0 | 1.0 | §7 | 0=disabled (für Backtest-Range ohne Timezone-Daten) |

**Sub-Module (vorgeschlagene Reihenfolge in atomaren Commits):**

**I2-1: Ichimoku-Score-Indikator (Default-Implementation §12.2)**
- `pub fn calc_kijun_slope(kijun_values: &[f64], end_idx: usize, lookback_bars: usize) -> Option<f64>` — slope = `kijun[end_idx] - kijun[end_idx - lookback_bars]`
- `pub fn calc_ichimoku_score(
    close: f64,
    cloud_upper_at_i: f64,
    senkou_a_future: f64,
    senkou_b_future: f64,
    tenkan: f64,
    kijun: f64,
    cloud_upper_at_i_minus_26: f64,
    kijun_slope: f64,
  ) -> i32` — returns `-100..=+100` Score
- Tests:
  - `test_score_all_bullish_components_returns_100`: alle 5 Komponenten zeigen Long → Score = +100
  - `test_score_all_bearish_components_returns_minus_100`: Score = -100
  - `test_score_mixed_3_of_5_bullish_returns_20`: 3 von 5 Komponenten Long, 2 short → Score = 20 (3 × 20 - 2 × 20)
  - `test_score_kijun_slope_zero_is_neutral`: kijun-slope == 0 → Komponente trägt 0 bei
  - Dart-Parity-Test
- Commit: `feat(phase-2): Ichimoku-Score Confluence-Sum helper (I2-1)`

**I2-2: Ichimoku-Strategy Manifest + Skeleton**
- `pub struct IchimokuStrategy { state: ... }` + `impl StrategyAddin`
- `pub fn ichimoku_manifest() -> AddinManifest` mit 12 ParameterSchema-Einträgen
- `on_candle` Skeleton mit Warmup-Gate (`start_idx = senkou_b_period + shift_period = 78`), Indikator-Berechnung, **noch ohne** Confluence-Logik
- Tests:
  - `test_strategy_manifest_returns_12_params`: Manifest-Validierung
  - `test_strategy_warmup_returns_no_signal_before_78_bars`
- Commit: `feat(phase-2): Ichimoku strategy manifest + skeleton (I2-2)`

**I2-3: Long-Entry-Confluence (5 Bedingungen)**
- Implementierung der Bedingungen aus Spec §2:
  ```rust
  // Current-cloud (bei i, aus i-26-Daten)
  let cloud_at_i_upper = cloud_upper(span_a_at_i, span_b_at_i);
  // Future-cloud (bei i+26, aus i-Daten)
  let future_cloud_green = cloud_is_green(span_a_future, span_b_future);
  // Chikou-Vergleichs-Anker (close_i vs cloud bei i-26, mit Werten aus i-52)
  let cloud_at_i_minus_26_upper = cloud_upper(span_a_at_i_minus_26, span_b_at_i_minus_26);

  let long_ok = close > cloud_at_i_upper
             && future_cloud_green
             && tenkan_at_i > kijun_at_i
             && close > cloud_at_i_minus_26_upper
             && score >= score_long_threshold;
  ```
- SL-Berechnung: `let sl_long = kijun_at_i.min(cloud_lower(span_a_at_i, span_b_at_i));`
- TP-Berechnung: `let tp_long = close + tp_rr_ratio * (close - sl_long);`
- size_pct: `position_size_pct(close, close - sl_long, risk_per_trade)`
- Tests:
  - `test_long_entry_all_5_conditions_pass`: synthetisches Fixture mit kontrolliert konstruierten Werten → EnterLong-Signal
  - `test_long_entry_fails_when_below_cloud`: Bedingung 1 fehlt → keine Signal
  - `test_long_entry_fails_when_future_cloud_red`: Bedingung 2 fehlt → keine Signal
  - `test_long_entry_fails_when_tenkan_below_kijun`: Bedingung 3 fehlt → keine Signal
  - `test_long_entry_fails_when_chikou_below_cloud`: Bedingung 4 fehlt → keine Signal
  - `test_long_entry_fails_when_score_too_low`: Bedingung 5 fehlt → keine Signal
  - `test_long_entry_sl_is_kijun_when_kijun_lower_than_cloud_bottom`
  - `test_long_entry_sl_is_cloud_bottom_when_cloud_lower_than_kijun`
  - `test_long_entry_degenerate_sl_at_entry_returns_no_action`: SL == entry → NoAction (Spec §4 sanity)
- Commit: `feat(phase-2): Ichimoku long-entry confluence + SL/TP wiring (I2-3)`

**I2-4: Short-Entry-Confluence (Spiegel)**
- Implementierung Spec §3 (Spiegel zu Long)
- SL-Berechnung: `let sl_short = kijun_at_i.max(cloud_upper(span_a_at_i, span_b_at_i));`
- Tests analog: 6 Failure-Mode-Tests + SL-Wahl-Tests + degenerate-Test
- Commit: `feat(phase-2): Ichimoku short-entry confluence + SL/TP wiring (I2-4)`

**I2-5: Session-Filter-Integration**
- Falls Refactor (§3 Frage 3) zuerst gemacht: `ichimoku.rs` ruft `super::common::is_in_session(candle.timestamp, ...)` auf
- Falls Duplikat: Session-Filter-Funktion in `ichimoku.rs` selbst
- Tests:
  - `test_no_signal_outside_session_long`: gültige Confluence aber Bar außerhalb 09:00–23:00 → NoAction
  - `test_no_signal_outside_session_short` analog
  - `test_session_filter_disabled_allows_signal`: `session_filter_enabled = 0.0` → Signal trotz Off-Hours
- Commit: `feat(phase-2): Ichimoku session-filter integration (I2-5)`

**I2-6: Dart-Fallback der gesamten Strategy**
- `lib/services/backtest_service.dart` erweitern um `IchimokuParams` + Strategy-Branch
- `lib/services/indicators.dart` um Ichimoku-Helpers
- Identische Logik wie Rust
- Commit: `feat(phase-2): Ichimoku Dart fallback for backtest_service (I2-6)`

**I2-7: Dart-Rust Parity-Test**
- `test/integration/dart_rust_ichimoku_parity_test.dart` (neu)
- 400-Candle LCG-Random-Walk-Fixture (analog UT Bot — synthetische Sinusoids triggern keine 5-Confluence wegen statischer Phase-Beziehungen)
- Mindestens 1 Long-Entry + 1 Short-Entry in der Fixture
- 1e-9 Drift in totalPnl, winRate, sharpe, maxDrawdown
- Falls Native-Engine via FFI verfügbar: zusätzlich `native vs dart-fallback`-Vergleich
- Commit: `test(phase-2): Dart-Rust Ichimoku parity on 400-candle random walk (I2-7)`

**Geschätzt:** **10–14 h** (7 atomare Commits, Spread = abhängig von §3 Frage 3 Entscheidung; falls Refactor zu common.rs zusätzlich + UT-Bot-Re-Test gemacht werden muss + 1.5 h)

**Falls Refactor zu `addins/common.rs` separat als Vorab-Commit:** I2-0 (Refactor) als zusätzlicher atomarer Commit + 1.5 h, dann erst I2-1 starten.

---

### Welle I3 — Reference-Backtest auf XLSX-Setup + Path-A/B/C-Klassifikation

**Scope:** Vollständiger Backtest auf BTCUSDT 1h über 760 Tage, Vergleich mit XLSX-Targets, ggf. Mandatory Sanity-Sweep, ggf. Diagnose-MD.

**Steps:**
1. **Data-Vorbereitung:** Sicherstellen dass BTCUSDT 1h Daten für 760 Tage verfügbar sind (≥ 18000 Kerzen). Standard-Range-Vorschlag: **2023-04-01 bis 2025-05-01** (760 Tage, deckt sowohl Bear-Phase Q3 2023 als auch Bull-Phasen Q4 2023 / Q1+Q4 2024 / Q1 2025 ab — strukturell repräsentativ). Falls Daten fehlen → Binance-Download-Job aus Phase 1.
2. **Baseline-Backtest:** Ichimoku Default-Parameter aus Manifest auf BTCUSDT 1h, 760 Tage.
3. **Vergleich gegen Tabelle 13.2 der Spec.**
4. **Wenn alle Metriken im Band → Pfad B (wegen Asset-Abweichung §12.1), Spec §13.6 finalisieren, fertig.**
5. **Wenn QA-Sign-off die Wahl von Score-Threshold (siehe §3 Frage 2) auf einen anderen Wert verschoben hat und das im Band landet → Pfad B mit zusätzlicher Begründung in Spec §12.2.**
6. **Wenn baseline und Score-Threshold-Wahl nicht reichen → Mandatory Sanity-Sweep (Spec §13.3):**
   - TF-Sweep: BTCUSDT 4h, 15min
   - Asset-Sweep: ETHUSDT 1h
   - Score-Threshold-Sweep: `score_long_threshold` ∈ {+40, +60, +80} (symmetrisch mit short)
7. **Diagnose-MD schreiben:** `01_Projectplan/specs/ichimoku_diagnose_{YYYY-MM-DD}.md` mit Tabellen-Format analog zu `bb_rsi_diagnose_2026-05-23.md` und `ut_bot_diagnose_2026-05-23.md`.
8. **Spec §13.6 finalisieren** mit konkreter Path-A/B/C-Markierung und Root-Cause-Hypothese falls Pfad C.

**Atomare Commits:**
- **Pfad A oder B (alles im Band):** `docs(phase-2): ichimoku §13.6 classified as Path B — XLSX targets met on BTCUSDT 1h (asset-substituted)`
- **Pfad B mit Threshold-Adjustment:** `feat(phase-2): adjust Ichimoku score thresholds per Welle-I3 (long=X short=Y)` + `docs(phase-2): ichimoku §13.6 classified as Path B`
- **Pfad C:** `docs(phase-2): Ichimoku diagnose sweep + recommendation ({date})` + `docs(phase-2): ichimoku §13.6 classified as Path C with full diagnosis`

**Geschätzt:**
- Pfad A oder B (direkt): **2 h** (Backtest-Run + Vergleich + Doku)
- Pfad B mit Threshold-Adjustment: **2.5 h** (zusätzlich kleines Sweep-Set)
- Pfad C: **4–5 h** (vollständiger Sanity-Sweep + ausführliche Diagnose-MD)

---

## 3. Risiken / Offene Fragen für QA-Entscheidung VOR Welle I2-Start

Diese Fragen müssen vor dem Code-Schreiben in Welle I2 entschieden werden. Ohne diese Entscheidungen entstehen entweder spätere Refactors oder Pfad-B-Vermerke ohne ehrliche Begründung.

### Frage 1 — Rolling-Max/-Min: separater Helper vs param-erweiterte Variante von swing_high/swing_low?

**Was sagt der Code-Stand:** `bb_rsi.rs` enthält `swing_high(highs: &[f64]) -> Option<f64>` und `swing_low(lows: &[f64]) -> Option<f64>` als „rolling über die letzten N Bars **exklusive der aktuellen**" (BB+RSI-Konvention für swing-points „vor dem Signal-Bar").

Ichimoku braucht **rolling-max/min über die letzten N Bars INKLUSIVE der aktuellen Bar** (Spec §1: `high_max(9)` als Berechnungs-Input für Tenkan auf Bar i).

**Optionen:**
- **(a) Eigene Helpers `rolling_max(values, end_idx, period)` in `addins/ichimoku.rs` (oder ggf. `addins/common.rs`)** — keine Berührung mit BB+RSI-Code, klare Trennung. Vorgeschlagen in Welle-I1-1.
- **(b) `swing_high`/`swing_low` um optionalen `include_current: bool` Parameter erweitern** — DRY, aber BB+RSI muss re-getestet werden.
- **(c) Beides parallel** — Code-Duplikation, schlecht.

**Pragmatische Default-Entscheidung:** Option **(a)** — Welle I1-1 baut eigene Helpers. Begründung: `swing_high/low` sind als Swing-Detection-Funktionen semantisch verschieden von Rolling-Aggregates. Sie *erinnern* an Rolling-Max/-Min, aber sie sind das nicht (sie sind die N-Bar-Lookback-Variante mit Exklusion). Ein Refactor zu `(b)` würde die Semantik vermischen.

**QA-Entscheidung:** OK mit (a)? Oder soll Welle I1-1 stattdessen `(b)` umsetzen mit BB+RSI Re-Test?

### Frage 2 — Score-Threshold-Default (entscheidend für Backtest-Ergebnis)

**Was sagt das Transkript:** Konkreter numerischer Schwellwert wird im Video nicht genannt. Autor sagt nur „Score im grünen Bereich" (T244) / „im roten Bereich" (T250). Visuell zeigt der Indikator vermutlich farb-codierte Balken oder Linien.

**Optionen:**
- **(a) Default `±60`** (entspricht „3 von 5 Komponenten Konvergenz") — konservativ, aber Score-Filter wird ca. 30–40 % der Setups entfernen, was die XLSX-Trade-Anzahl von 100 erreichen sollte.
- **(b) Default `±40`** (entspricht „2 von 5 Konvergenz" — etwa wie "leicht grün") — weniger Filterung, mehr Trades, evtl. zu permissiv.
- **(c) Default `±80`** (entspricht „4 von 5 Konvergenz") — stark filtert, evtl. zu wenig Trades.
- **(d) Erst Welle I3-Backtest mit `±60` laufen lassen, falls nicht im Band dann Threshold-Sweep (±40, ±60, ±80) im Sanity-Sweep und besten als Pfad-B-Default markieren**

**QA-Entscheidung:** Vorschlag = **(d)** — analog UT Bot Frage 2 die ehrlichste Form.

### Frage 3 — Session-Filter-Refactor zu `addins/common.rs` JETZT?

**Was sagt der Code-Stand:** UT Bot Welle U2-3 hat `is_in_session(...)` lokal in `ut_bot.rs` implementiert mit TODO-Marker „extract to common once a third strategy needs them" (UT-Bot-Engineering-Plan §3 Frage 4).

Ichimoku ist die dritte Strategie, die denselben Session-Filter braucht (Spec §7).

**Optionen:**
- **(a) Duplikat in `ichimoku.rs`** — schnellster Pfad, aber Code-Verdoppelung; bei dritter Strategy ist das ein klares Anti-Pattern.
- **(b) Refactor zu `addins/common.rs` JETZT** als Welle-I2-0 (Vorab-Commit, vor I2-1) — sauberer, +1.5 h Aufwand. UT Bot muss re-getestet werden (Engine + FFI Parity), aber das ist eine bestehende Test-Suite.

**Pragmatische Default-Entscheidung:** Option **(b)** — die UT-Bot-§3-Frage-4-Entscheidung war „extrahiere wenn dritte Strategy". Diese Bedingung ist jetzt erfüllt.

**QA-Entscheidung:** OK mit Refactor (b) als Welle-I2-0? Oder doch Duplikat (a)?

### Frage 4 — Ichimoku-Score-Implementation: §12.2-Confluence-Sum-Default vs Recherche

**Was sagt das Transkript:** „Ichimoku Score Indikator von dreams defined" (T203), Pinescript-Source nicht verlinkt. Es gibt mehrere TradingView-Indikatoren mit diesem Namen.

**Optionen:**
- **(a) §12.2-Default-Implementation:** 5-Komponenten-Confluence-Sum, ±20 Gewichte je Komponente, Score-Range [-100, +100] mit ±60-Threshold-Default. Klar dokumentiert, sauber testbar, parity-konform.
- **(b) Recherche zu „dreams defined Ichimoku Score" auf TradingView** (Open-Source-Pinescript) — Aufwand ~1–2 h. Risiko: mehrere Treffer, nicht eindeutig identifizierbar; Pinescript-Code muss in Rust portiert werden (manueller Aufwand mit Test-Fixtures).
- **(c) Erst Welle I3 mit §12.2-Default laufen lassen, falls Pfad-C-Risiko → Recherche-Nachzug in Welle I4 (Phase-3-Backlog)**

**Pragmatische Default-Entscheidung:** Option **(c)** — gleicher Pragmatismus wie UT-Bot-§3-Frage-3.

**QA-Entscheidung:** Vorschlag = (c).

### Frage 5 — Welle I2 Push-Strategie (analog UT-Bot-§3-Frage-5)

**Beobachtung:** BB+RSI und UT Bot Wellen wurden in vielen kleinen atomaren Commits direkt auf `main` gepusht. Ichimoku-Welle I2 hat **7 vorgeschlagene atomare Commits** (+ ggf. I2-0 für Refactor), was ~10–14 h Arbeit über mehrere Sessions sein wird.

**QA-Entscheidung:** Soll Welle I2 als 7+1 separate Pushes auf `main` oder als zusammenhängender Push am Ende erfolgen?

**Vorschlag:** Atomare Pushes (wie BB+RSI / UT Bot) — fortschrittliche Sichtbarkeit + frühere Detection von Engine-Drift via Reference-Backtest pro Push.

---

## 4. Vorgeschlagene Reihenfolge

Sobald die 5 Fragen aus §3 geklärt sind:

1. **Welle I1.1–I1.4 atomar:** Rolling-Helpers + Tenkan/Kijun + Senkou-A/B + Cloud-Bounds (4 Commits + Pushes)
2. **Welle I2.0 (falls Refactor) ODER skip:** Session-Filter-Refactor zu `addins/common.rs` + UT-Bot-Re-Test → 1 Commit + Push
3. **Welle I2.1–I2.7 atomar:** Score-Indikator + Strategy-Manifest + Long-Confluence + Short-Confluence + Session-Integration + Dart-Fallback + Parity-Test (7 Commits + Pushes)
4. **Parity-Verifikation nach Welle I2.7:** kein Commit, nur Run von `flutter test test/integration/dart_rust_ichimoku_parity_test.dart` und der bestehenden BB+RSI / UT-Bot-Parity-Tests (Drift-Check für Engine-Korrektheit)
5. **Welle I3:** Reference-Backtest + Path-Klassifikation (1–3 Commits je nach Pfad).
6. **Phase-2-Tag-Vorbereitung:** Phase-2-Plan §4.4 aktualisieren mit finaler Ichimoku-Pfad-Klassifikation. **Wenn Pfad A oder B → `v0.3.0-strategies-verified` setzbar (Phase-2-Tag-Bedingung erfüllt).** Wenn Pfad C → Sub-Diagnose-Session-Eröffnung (Plan §4.4 letzter Aufzählungspunkt) muss verhandelt werden.

---

## 5. Geschätzter Gesamt-Aufwand

| Welle | Aufwand | Annahmen |
|---|---|---|
| I1 (Rolling + Tenkan/Kijun + Senkou-A/B + Cloud-Bounds) | 4 h | Triviale Helpers mit klaren Tests, jeweils Rust + Dart-Parity-Test |
| I2-0 (Session-Filter-Refactor, falls QA `(b)`) | +1.5 h | UT-Bot-Re-Test enthalten |
| I2.1–I2.7 (Score + Strategy + Dart-Fallback + Parity) | 10–14 h | Spread = abhängig von §3 Frage 2 (Score-Threshold-Wahl) |
| I3 Pfad A oder direkt B | 2 h | optimaler Fall, kein Sanity-Sweep |
| I3 Pfad B mit Threshold-Adjustment | 2.5 h | + Default-Anpassung |
| I3 Pfad C | 4–5 h | Sanity-Sweep + Diagnose-MD |

**Erwarteter Gesamt-Aufwand:** **16–22 h** für die Implementierung + Welle I3, je nach Pfad-C-Eintritt und Refactor-Entscheidung.

**Vergleich UT Bot:** Welle U1 + U2 + U3 zusammen ~12–18 h. Ichimoku ist **etwa 30 % aufwändiger** wegen:
- 5 Indikator-Linien (statt 1 für UT Bot ATR)
- Future-Shift-Anchor-Konzept (komplex zu testen, +1 h Test-Aufwand)
- Score-Indikator-Implementation (analog SMI bei UT Bot, aber mit zusätzlicher Periode-×4-Skalierung)
- Längere Warmup-Pflicht (78 Bars statt UT-Bot ~15)
- 400-Candle-Parity-Fixture (statt UT-Bot 200) wegen Warmup

**Vergleich BB+RSI:** Welle 1+2+3 (mit Diagnose) ~20–25 h. Ichimoku ähnlich, da BB+RSI von Engine-Bug-Schmerz (D-01..D-09) belastet war.

---

## 6. Out-of-Scope für diese Wellen

- **Ichimoku-Score „dreams defined" Bit-Exact-Reproduktion** (§12.2 / §3 Frage 4): Default-Implementation reicht für Phase 2; Recherche-Aufwand ist Phase-3-Backlog.
- **Multi-Strategy-Run** (BB+RSI + UT Bot + Ichimoku parallel im selben Backtest): kein Feature der Engine, kein Phase-2-Scope.
- **Live-Trading mit Ichimoku:** out-of-scope (Phase-3-Diskussion).
- **EUR/USD-Datenquelle erschließen** (z.B. Oanda, FXCM, Dukascopy): out-of-scope für Phase 2. Falls Pfad C eintritt **und** EUR/USD-Backtest als Diagnose-Variante gewünscht ist, wird das in einer separaten Sub-Phase verhandelt.
- **Adaptive Periode-Skalierung** (z.B. ATR-basiert): zu früh, gehört in Phase-3-Optimizer.
- **Übertragung der Cloud-Logik auf andere Strategien** (z.B. „BB+RSI mit Ichimoku-Cloud-Filter"): separate Spec, nicht in dieser Ichimoku-Welle.

---

## 7. Bekannte Risiken (vor Welle-Start)

| Risiko | Wahrscheinlichkeit | Impact | Mitigation |
|---|---|---|---|
| Future-Shift-Anchor-Konfusion im Code → subtiler Look-Ahead-Bias | Mittel | Hoch (Strategy hat unrealistische Backtest-PnL) | Explizite Helper-Konvention (rohe Werte, Anker via Strategy-Code) + ausführliche Doc-Comments + dedizierter Test `test_future_cloud_uses_only_past_data` der explizit prüft, dass keine `i+1`-Index-Zugriffe stattfinden |
| Ichimoku-Score-Implementation weicht stark von „dreams defined"-Original ab | Hoch | Mittel (Pfad-C-Risiko erhöht) | §12.2-Default ist konzeptionell richtig (Cross + Farb + Distanz); Recherche-Nachzug in Phase 3 falls Pfad C |
| Volume-Risiko: Score-Filter dropt zu viele BTCUSDT-Signale → < 50 Trades in 760 Tagen | Mittel | Hoch (XLSX-Volume-Band [80, 120] nicht erreichbar) | Score-Threshold-Sweep in I3 §13.3 — wenn `±40` ein Band erreicht, ist das Pfad B mit kleiner Default-Anpassung |
| Asset-Mismatch BTCUSDT vs EUR/USD: Ichimoku auf Forex-Sessions vs Crypto 24/7 | Hoch | Mittel | Pre-Diagnose §13.7: erwartete Pfad-B/C-Verteilung 40/55, deutlich besser als UT Bot (Pfad-A-Chance < 20 %); Mitigation via TF-Sweep auf 4h |
| Refactor zu `addins/common.rs` bricht UT-Bot-Tests | Niedrig | Mittel | UT-Bot Test-Suite ist umfangreich (Welle U2-5 FFI-Parity grün) — Re-Test deckt Drift auf; falls Bruch → Refactor zurückrollen, Duplikat (a) wählen |
| Spec §12.5 strict-`>` vs `>=` macht Pfad-A/B unmöglich | Niedrig | Niedrig | Falls Pfad C eintritt → Sweep mit `>=` als zusätzliche Variation im Diagnose-MD; falls dort im Band → Path B mit §12.5-Adjustment |
| Reproduzierbarkeit-Bruch durch Floating-Point-Drift in 5-Komponenten-Score-Sum | Sehr niedrig | Mittel | Score ist `i32`-Return (integer-Komponenten), kein Drift möglich |
