# QA Audit — Umsetzungsplan

**Datum:** 28. Mai 2026
**Referenz:** `260528_QA_AUDIT_STRATEGY_REPORT.md` (Findings S-01 bis S-08)
**Ziel-Branch:** `fix/qa-strategy-findings-may28`

---

## Übersicht

| ID | Sev. | Titel | Strategie | Aufwand | Phase |
|---|---|---|---|---|---|
| S-06 | LOW | BB+RSI Manifest: Description + Category falsch | BB+RSI | S | 1 |
| S-08 | LOW | score_threshold f64→i32 Cast | Ichimoku | S | 1 |
| S-02 | MED | Dead Code: chikou_confirms_* | Ichimoku | S | 1 |
| S-04 | MED | shift-Parameter ignoriert | Ichimoku | S | 1 |
| S-07 | LOW | UT Bot TZ-Offset hartkodiert | UT Bot | S | 2 |
| S-01 | HIGH | BB+RSI Session-Filter fehlt | BB+RSI | M | 2 |
| S-03 | MED | swing_lookback_bars ohne Funktion | Ichimoku | S | 2 |
| S-05 | MED | O(n²) Indikator-Neuberechnung | Alle | L | 3 (später) |

---

## Phase 1 — Quick Wins (< 2 h)

### [ ] S-06 — BB+RSI Manifest: Description + Category auf Trendfolge korrigieren

**Datei:** `rust/trading_engine/src/addins/bb_rsi.rs`

**Aktion 1 — Description ersetzen (Zeile 496–505):**

```rust
// VORHER:
fn bb_rsi_manifest() -> AddinManifest {
    AddinManifest {
        id: "bb_rsi_v1".to_string(),
        name: "Bollinger Bands + RSI Mean Reversion".to_string(),
        // ...
        description:
            "Mean-reversion strategy: enter when price touches a Bollinger Band extreme \
             with confirming RSI, exit at the middle band or opposite RSI extreme."
                .to_string(),
        category: StrategyCategory::MeanReversion,

// NACHHER:
fn bb_rsi_manifest() -> AddinManifest {
    AddinManifest {
        id: "bb_rsi_v1".to_string(),
        name: "Bollinger Bands + RSI Trend Following".to_string(),
        // ...
        description:
            "Trend-following strategy: price beyond BB marks trend direction, \
             RSI cross-back provides pullback re-entry, swing-based SL/TP (1:3)."
                .to_string(),
        category: StrategyCategory::Trend,
```

**Aktion 2 — Unit-Test anpassen (Zeile 953):**

```rust
// VORHER:
assert_eq!(manifest.category, StrategyCategory::MeanReversion);

// NACHHER:
assert_eq!(manifest.category, StrategyCategory::Trend);
```

**Verifikation:**
- [ ] `cargo test -p trading_engine --lib addins::bb_rsi::tests::test_strategy_manifest` — grün
- [ ] `cargo clippy -p trading_engine` — 0 warnings

---

### [ ] S-08 — Ichimoku score_threshold: f64→i32 mit .round() absichern

**Datei:** `rust/trading_engine/src/addins/ichimoku.rs` (Zeile 534)

**Aktion:**

```rust
// VORHER:
let score_threshold = ctx.param_or("score_threshold", 60.0) as i32;

// NACHHER:
let score_threshold = ctx.param_or("score_threshold", 60.0).round() as i32;
```

**Verifikation:**
- [ ] `cargo test -p trading_engine --lib addins::ichimoku` — alle grün
- [ ] `cargo clippy -p trading_engine` — 0 warnings

---

### [ ] S-02 — Ichimoku Dead Code: chikou_confirms_long/short löschen

**Datei:** `rust/trading_engine/src/addins/ichimoku.rs` (Zeile 277–306)

**Entscheidung: Löschen.** Die klassische Chikou-Definition weicht von der video-spec-konformen Definition ab, die `detect_entry` verwendet. Zwei konkurrierende Definitionen im selben Modul stiften Verwirrung.

**Aktion — Folgende Zeilen löschen:**

```rust
// ZU LÖSCHEN: Zeile 277–306
/// Compute the **Chikou-Span** (Lagging Line) series.
/// ...
pub fn calc_chikou_span(closes: &[f64]) -> Vec<f64> {
    closes.to_vec()
}

/// Chikou-Span confirmation for a **long** entry at bar `i`.
/// ...
pub fn chikou_confirms_long(closes: &[f64], i: usize) -> Option<bool> {
    if i < CLOUD_SHIFT_BARS || i >= closes.len() {
        return None;
    }
    Some(closes[i] > closes[i - CLOUD_SHIFT_BARS])
}

/// Chikou-Span confirmation for a **short** entry at bar `i`.
/// ...
pub fn chikou_confirms_short(closes: &[f64], i: usize) -> Option<bool> {
    if i < CLOUD_SHIFT_BARS || i >= closes.len() {
        return None;
    }
    Some(closes[i] < closes[i - CLOUD_SHIFT_BARS])
}
```

**Verifikation:**
- [ ] `cargo build -p trading_engine` — kompiliert
- [ ] `cargo test -p trading_engine --lib addins::ichimoku` — alle grün
- [ ] `cargo clippy -p trading_engine` — 0 warnings

---

### [ ] S-04 — Ichimoku shift-Parameter aus Manifest entfernen

**Dateien:**
- `rust/trading_engine/src/addins/ichimoku.rs` (Manifest + on_candle)
- `01_Projectplan/specs/ichimoku_spec.md` (§12 dokumentieren)

**Aktion 1 — shift-Parameter aus Manifest löschen (Zeile 798–802):**

```rust
// ZU LÖSCHEN:
ParameterSchema::new("shift", "Cloud / Chikou Shift", 26.0, 5.0, 100.0, 1.0),
```

**Aktion 2 — shift-Variable in on_candle entfernen (Zeile 533):**

```rust
// ZU LÖSCHEN:
let shift = ctx.param_or("shift", 26.0) as usize;
```

Das hartkodierte `CLOUD_SHIFT_BARS = 26` (Zeile 159) bleibt unverändert und wird weiterhin von allen Read-Anchors verwendet.

**Aktion 3 — Manifest-Test anpassen:**

Im Ichimoku-Testblock die Parameterzählung suchen und um 1 reduzieren. Falls kein expliziter Count-Test existiert, keinen neuen hinzufügen — die Manifest-Struktur ist durch `validate_params` abgedeckt.

**Verifikation:**
- [ ] `cargo test -p trading_engine --lib addins::ichimoku` — alle grün
- [ ] `cargo clippy -p trading_engine` — 0 warnings
- [ ] Dart↔Rust-Parity-Test (`dart_rust_ichimoku_parity`) — grün (Manifest-Änderung berührt nicht die Signal-Logik)

---

## Phase 2 — Strategie-Konsistenz (2–4 h)

### [ ] S-07 — UT Bot: hartkodierten TZ-Offset auf Parameter migrieren

**Dateien:**
- `rust/trading_engine/src/addins/ut_bot.rs` (on_candle + Manifest)
- `01_Projectplan/specs/ut_bot_spec.md` (§12 dokumentieren)

**Aktion 1 — Manifest-Parameter hinzufügen (nach session_end_hour_local):**

```rust
// NACH session_end_hour_local EINFÜGEN:
ParameterSchema::new(
    "tz_offset_hours",
    "Local TZ Offset (hours east of UTC)",
    1.0,
    -12.0,
    14.0,
    1.0,
),
```

**Aktion 2 — tz_offset in on_candle lesen (nach session_end):**

```rust
// NACH session_end EINFÜGEN:
let tz_offset = ctx.param_or("tz_offset_hours", 1.0) as i32;
```

**Aktion 3 — within_session-Aufruf ändern (Zeile 504):**

```rust
// VORHER:
if session_enabled
    && !within_session(current_ts, session_start, session_end, 1)

// NACHHER:
if session_enabled
    && !within_session(current_ts, session_start, session_end, tz_offset)
```

**Aktion 4 — Manifest-Test anpassen:**

Den Parameter-Count im `test_strategy_manifest` (ut_bot.rs Tests) um 1 erhöhen (von 18 auf 19).

**Aktion 5 — Spec dokumentieren:**

In `ut_bot_spec.md` §12 einen Eintrag hinzufügen:
```
**12.6 TZ-Offset-Parametrisierung**
- **Abweichung:** UT Bot hatte UTC+1 hartkodiert. Auf Ichimoku-Konsistenz migriert — 
  `tz_offset_hours`-Parameter mit Default 1.0 (Berlin).
```

**Verifikation:**
- [ ] `cargo test -p trading_engine --lib addins::ut_bot` — alle grün
- [ ] `cargo clippy -p trading_engine` — 0 warnings
- [ ] Dart↔Rust-Parity-Test (`dart_rust_ut_bot_parity`) — grün (TZ-Offset betrifft nur Entry-Filter, Parity-Fixture hat keinen Session-Filter aktiv)
- [ ] Sanity-Check: `within_session` mit `tz_offset=1` und `tz_offset_hours=1.0` liefert identisches Ergebnis wie vorher hartkodiertes `1`

---

### [ ] S-01 — BB+RSI Session-Filter implementieren

**Dateien:**
- `rust/trading_engine/src/addins/bb_rsi.rs` (Manifest + on_candle)
- `01_Projectplan/specs/bb_rsi_spec.md` (§12 dokumentieren)

> **Hinweis:** Die Pfad-C-Diagnose zeigt WR 18.68 % OHNE Session-Filter. Der Filter wird die Trade-Anzahl reduzieren — die Spec verlangt ihn trotzdem. Falls der Filter zu drastischem Trade-Schwund führt (< 30 Trades auf 284 Tagen), in Spec §12 als bewusste Abweichung dokumentieren.

**Aktion 1 — Session-Parameter ins Manifest aufnehmen (am Ende der Parameter-Liste, vor ADX):**

```rust
// NACH risk_per_trade (Zeile 554) EINFÜGEN:
ParameterSchema::new(
    "session_filter_enabled",
    "Session Filter Enabled (0/1)",
    0.0,
    0.0,
    1.0,
    1.0,
),
ParameterSchema::new(
    "session_start_hour_local",
    "Session Start Hour (Berlin)",
    9.0,
    0.0,
    23.0,
    1.0,
),
ParameterSchema::new(
    "session_end_hour_local",
    "Session End Hour (Berlin)",
    23.0,
    1.0,
    24.0,
    1.0,
),
ParameterSchema::new(
    "tz_offset_hours",
    "Local TZ Offset (hours east of UTC)",
    1.0,
    -12.0,
    14.0,
    1.0,
),
```

**Aktion 2 — Session-Parameter in on_candle lesen (nach adx_use_di_confluence, Zeile 311):**

```rust
// NACH adx_use_di_confluence EINFÜGEN:
let session_enabled = ctx.param_or("session_filter_enabled", 0.0) >= 0.5;
let session_start = ctx.param_or("session_start_hour_local", 9.0) as u32;
let session_end = ctx.param_or("session_end_hour_local", 23.0) as u32;
let tz_offset = ctx.param_or("tz_offset_hours", 1.0) as i32;
```

**Aktion 3 — Session-Check einbauen (nach swing-berechnung, vor Entry-Logik, ca. Zeile 371):**

```rust
// NACH der swing-high/low-Berechnung, VOR dem Entry-Block EINFÜGEN:

// Session filter — default OFF. When enabled and the bar falls outside
// [start, end) local time, no new entries fire.
if session_enabled
    && !within_session(
        ctx.all_candles()[ctx.index()].timestamp,
        session_start,
        session_end,
        tz_offset,
    )
{
    return Some(Signal::NoAction);
}
```

> **Wichtig:** `ctx.all_candles()` wird bereits zweimal im selben Scope aufgerufen (swing-Berechnung + ADX-Snapshot). Session-Check VOR dem ADX-Snapshot platzieren, um unnötige ADX-Berechnung außerhalb der Session zu vermeiden. Der aktuelle Code holt `pre_signal` via `ctx.all_candles()` in Zeile 367 — danach die Session-Prüfung einfügen, aber vor ADX.

**Aktion 4 — Manifest-Test anpassen (Zeile 952):**

```rust
// VORHER:
assert_eq!(manifest.parameters.len(), 13);

// NACHHER:
assert_eq!(manifest.parameters.len(), 17); // +4 session params
```

**Aktion 5 — Spec dokumentieren:**

In `bb_rsi_spec.md` §12 einen Eintrag hinzufügen:
```
**12.3 Session-Filter-Implementierung (nachgezogen Mai 2026)**
- **Abweichung:** Der Session-Filter war in Phase 2 nicht implementiert.
  In Phase 2.5 nachgezogen mit identischen Parametern wie UT Bot / Ichimoku.
  Default OFF um Pre-Phase-2.5-Backtests nicht zu invaidieren.
```

**Verifikation:**
- [ ] `cargo test -p trading_engine --lib addins::bb_rsi` — alle grün
- [ ] `cargo clippy -p trading_engine` — 0 warnings
- [ ] Dart↔Rust-Parity-Test — grün (session_filter_enabled=0 → Byte-identisch zu vorher)
- [ ] Manueller Check: Session-Filter ON auf 2024-H1-Baseline → Trades ≤ 91 (Vergleich mit vorher), Session-Filter OFF → Byte-identische Trade-Liste

---

### [ ] S-03 — Ichimoku swing_lookback_bars aus Manifest entfernen

**Datei:** `rust/trading_engine/src/addins/ichimoku.rs`

**Aktion 1 — Parameter aus Manifest löschen (Zeile 823–830):**

```rust
// ZU LÖSCHEN:
// Spec §4 algorithmic SL distance uses kijun/cloud anchors;
// `swing_lookback_bars` is currently unused by the Ichimoku
// SL (kept in the manifest so a Phase-3 hybrid SL variant
// can opt in without breaking the parameter map).
ParameterSchema::new(
    "swing_lookback_bars",
    "Swing Lookback Bars",
    20.0,
    5.0,
    100.0,
    1.0,
),
```

**Aktion 2 — Manifest-Test anpassen:**

Parameter-Count im Ichimoku-Testblock um 1 reduzieren.

**Verifikation:**
- [ ] `cargo test -p trading_engine --lib addins::ichimoku` — alle grün
- [ ] `cargo clippy -p trading_engine` — 0 warnings
- [ ] Dart↔Rust-Parity-Test — grün (Parameter-Änderung betrifft nicht die Signal-Logik)

---

## Phase 3 — Performance (später, niedrige Priorität)

### [ ] S-05 — Inkrementelle Indikator-Updates

**Dateien:** Alle `addins/*.rs` + `common.rs`

> **Wichtig:** Dies ist ein Architektur-Trade-off. Aktuell sind alle Strategien **stateless** — jeder `on_candle`-Aufruf berechnet alle Indikatoren ab Index 0 neu. Das ist:
> - **Einfach, korrekt, parity-freundlich** (keine versteckten State-Bugs)
> - **Langsam** (O(n²) für Backtests)
>
> Für **Live-Trading** (1 Bar pro Aufruf) ist es irrelevant. Für den **Phase-3-Optimizer** (500–1000 Trials × 18.000 Bars) ist es der dominante Kostenfaktor. Ein Refactor zu inkrementellen Updates würde:
> - Eine `update_*`-Methode pro Indikator erfordern, die nur die neueste Bar verarbeitet
> - State pro Indikator im Strategy-Struct erfordern (bricht aktuelle Statelessness)
> - Neue Parity-Tests für den inkrementellen Pfad erfordern
>
> **Empfehlung:** Nur umsetzen wenn Phase-3-Optimizer-Durchsatz zum Bottleneck wird. Aufwand ca. 4–8 h.

**Betroffene Indikatoren und Code-Stellen:**

| Indikator | Datei | Funktion | Zustand |
|---|---|---|---|
| ADX | `common.rs:118` | `calc_adx` | Muss `tr_s`, `pdm_s`, `mdm_s`, `adx` als State halten |
| ATR | `ut_bot.rs:43` | `calc_atr` | State: letzter `atr`-Wert (Wilder-Smoothing) |
| SMI | `ut_bot.rs:158` | `calc_smi` | State: last `diff_kd`, `rng_kd`, `smi` (EMA-Smoothing-Enden) |
| UT Bot Trail | `ut_bot.rs:248` | `calc_ut_bot_trail` | State: `prev_trail`, `prev_direction` |
| EMA(200) | `ut_bot.rs:100` / `bb_rsi.rs:96` | `calc_ema` / `ema_series_from` | State: letzter EMA-Wert |
| Tenkan/Kijun | `ichimoku.rs:88` | `calc_midpoint_series` | State: keine (rolling max/min per window → kein inkrementeller Gewinn) |
| BB | `bb_rsi.rs:64` | `calc_bollinger_bands` | State: keine (reines Fenster → kein inkrementeller Gewinn) |
| RSI | `bb_rsi.rs:195` | `calc_rsi` | State: `avg_gain`, `avg_loss` (Wilder-Smoothing) |

**Implementierungs-Strategie:**
1. `StrategyAddin`-Trait um `fn update_state(&mut self, ctx: &Context)` erweitern (wird NACH `on_candle` aufgerufen)
2. Pro Indikator einen State-Struct definieren, der den letzten berechneten Wert + Smoothing-Zustand hält
3. `on_candle` nutzt weiterhin den vollständigen Pfad (für Korrektheit)
4. Neuer `update_state`-Pfad updated nur den inkrementellen Zustand
5. Separate Test-Matrix: inkrementell vs. vollständig muss identische Signale liefern

---

## Checkliste — Alle Tasks

### Phase 1
- [ ] S-06: BB+RSI Description/Category auf Trendfolge ändern
- [ ] S-06: `test_strategy_manifest` anpassen → `cargo test` grün
- [ ] S-08: `score_threshold.round()` in ichimoku.rs
- [ ] S-08: `cargo test addins::ichimoku` grün
- [ ] S-02: `chikou_confirms_long/short` + `calc_chikou_span` löschen
- [ ] S-02: `cargo build` + `cargo test addins::ichimoku` grün
- [ ] S-04: `shift`-Parameter aus Ichimoku-Manifest löschen
- [ ] S-04: `shift`-Variable aus `on_candle` löschen
- [ ] S-04: `cargo test addins::ichimoku` grün
- [ ] Phase 1: `cargo clippy` — 0 warnings
- [ ] Phase 1: Dart↔Rust-Parity (Ichimoku + BB+RSI) — grün

### Phase 2
- [ ] S-07: `tz_offset_hours`-Parameter ins UT-Bot-Manifest
- [ ] S-07: `tz_offset_hours` in `on_candle` lesen + `within_session`-Aufruf ändern
- [ ] S-07: Manifest-Test (Parameter-Count +1)
- [ ] S-07: `cargo test addins::ut_bot` grün
- [ ] S-01: Session-Parameter (×4) ins BB+RSI-Manifest
- [ ] S-01: Session-Parameter in `on_candle` lesen
- [ ] S-01: `within_session`-Aufruf VOR ADX-Snapshot einbauen
- [ ] S-01: Manifest-Test (Parameter-Count 13→17)
- [ ] S-01: `cargo test addins::bb_rsi` grün
- [ ] S-01: Sanity-Check: Session OFF → Byte-identische Trades
- [ ] S-03: `swing_lookback_bars` aus Ichimoku-Manifest löschen
- [ ] S-03: Manifest-Test anpassen
- [ ] S-03: `cargo test addins::ichimoku` grün
- [ ] Phase 2: `cargo clippy` — 0 warnings
- [ ] Phase 2: Dart↔Rust-Parity (alle 3 Strategien) — grün
- [ ] Phase 2: `flutter analyze` — 0 errors

### Phase 3 (später)
- [ ] S-05: `StrategyAddin`-Trait um `update_state` erweitern
- [ ] S-05: Inkrementelle State-Structs definieren (ADX, ATR, SMI, EMA)
- [ ] S-05: Inkrementelle `update_*`-Methoden implementieren
- [ ] S-05: Test-Matrix: inkrementell = vollständig (alle Indikatoren)
- [ ] S-05: Benchmark: 500-Trial Sweep vorher/nachher
- [ ] S-05: `cargo clippy` — 0 warnings

---

## Commit-Strategie

```
Phase 1: 1 Commit pro Finding (S-06, S-08, S-02, S-04)
Phase 2: 1 Commit pro Finding (S-07, S-01, S-03)
Phase 3: 1 Commit (S-05)
```

**Commit-Message-Format:** `fix(qa): S-XX <kurzbeschreibung> (Ref: 260528_QA_AUDIT_STRATEGY_REPORT)`
