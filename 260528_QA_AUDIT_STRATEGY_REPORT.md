# QA Audit — Trading Strategies

**Datum:** 28. Mai 2026
**Scope:** Rust Strategy Implementations (bb_rsi.rs, ut_bot.rs, ichimoku.rs, common.rs)
**Projekt:** OrderPilot Portabel — Phase 2/3 Trading Engine
**Dokument-ID:** `260528_QA_AUDIT_STRATEGY_REPORT`
**Vorgänger-Audit:** `260522_0246_QA_AUDIT_REPORT.md` (F-01 bis F-08)

---

## 1. Executive Summary

Die drei in Rust implementierten Trading-Strategien (BB+RSI, UT Bot, Ichimoku Cloud Retest) sind **video-treu und mathematisch korrekt** implementiert — alle wurden als **Pfad C** klassifiziert: XLSX-Targets auf BTC/USDT nicht erreichbar, da die Original-Videos auf NQ bzw. EUR/USD Forex mit fundamental anderer Microstructure liefen. Die Implementierungen weisen **gute Testabdeckung, minutiöse Dart↔Rust-Paritäts-Locks und saubere Indikator-Helper** aus. Dennoch wurden im Audit **8 neue Findings (S-01 bis S-08)** identifiziert, die sich auf inkonsistente Strategie-Parameter, ungenutzten Dead Code, Performance-Bedenken (O(n²)-Indikator-Neuberechnung) und eine fehlende Session-Filter-Implementierung in BB+RSI konzentrieren. **Kein Critical-Finding** — alle Strategien sind funktional korrekt, die Issues betreffen Wartbarkeit, Konsistenz und Optimierungspotential.

**Gesamtbewertung:** Gut — produktionsreif für den Phase-3-Optimizer-Lab-Betrieb. Empfohlene Fixes vor dem Phase-3-Tag.

---

## 2. Findings-Matrix

| ID | Severity | Kategorie | Titel | Strategie | Datei & Zeile |
|---|---|---|---|---|---|
| **S-01** | `HIGH` | Inkonsistenz | BB+RSI Session-Filter fehlt (Spec §7 verlangt, nicht implementiert) | BB+RSI | `bb_rsi.rs:496-601` (Manifest ohne session-Parameter) |
| **S-02** | `MEDIUM` | Dead Code | `chikou_confirms_long` / `chikou_confirms_short` definiert aber nie aufgerufen | Ichimoku | `ichimoku.rs:288-306` (Hilfsfunktionen ungenutzt) |
| **S-03** | `MEDIUM` | Inkonsistenz | `swing_lookback_bars` im Ichimoku-Manifest deklariert, aber Strategie nutzt Kijun/Cloud-SL | Ichimoku | `ichimoku.rs:823-830` (Parameter), `ichimoku.rs:707-717` (SL-Logik ignoriert ihn) |
| **S-04** | `MEDIUM` | Inkonsistenz | `shift`-Parameter im Ichimoku-Manifest wird von Strategie ignoriert (nutzt hartkodiertes `CLOUD_SHIFT_BARS=26`) | Ichimoku | `ichimoku.rs:533` vs. `ichimoku.rs:159` |
| **S-05** | `MEDIUM` | Performance | O(n²)-Indikator-Neuberechnung pro Bar (ADX, SMI, ATR werden jedes `on_candle` ab Index 0 neu berechnet) | Alle | `common.rs:386`, `ut_bot.rs:489-493`, `ichimoku.rs:580-583` |
| **S-06** | `LOW` | Code-Qualität | Manifest `description` der BB+RSI-Strategie beschreibt Mean Reversion, obwohl Code Trendfolge implementiert (Spec §1) | BB+RSI | `bb_rsi.rs:502-505` |
| **S-07** | `LOW` | Inkonsistenz | TZ-Offset-Handhabung inkonsistent: UT Bot hartkodiert UTC+1, Ichimoku hat `tz_offset_hours`-Parameter, BB+RSI fehlt ganz | UT Bot, Ichimoku, BB+RSI | `ut_bot.rs:504`, `ichimoku.rs:540`, `bb_rsi.rs` |
| **S-08** | `LOW` | Code-Qualität | `score_threshold`-Parameter wird von f64 nach i32 gecastet — fragile Typ-Konvertierung bei nicht-ganzzahligen Werten | Ichimoku | `ichimoku.rs:534` |

---

## 3. Detail-Findings

### 3.1 Backend-Logik & Spec-Konformität

#### S-01 [HIGH] BB+RSI Session-Filter nicht implementiert

- **Problem:** Die BB+RSI Spec §7 verlangt explizit: „Session-Filter: Ja — Entries nur zwischen 09:00 und 23:00 (Lokalzeit Berlin)". Der Filter ist im BB+RSI-Manifest **nicht deklariert** (kein `session_filter_enabled`-Parameter unter den 13 Parametern), und die `on_candle`-Implementierung ruft `within_session` **nie auf**. UT Bot und Ichimoku haben den Filter korrekt implementiert.
- **Betroffene Dateien:**
  - `rust/trading_engine/src/addins/bb_rsi.rs:496-601` — Manifest ohne session-Parameter
  - `rust/trading_engine/src/addins/bb_rsi.rs:287-479` — `on_candle` ohne Session-Check
- **Auswirkung:** BB+RSI feuert Entries 24/7 auf BTC/USDT, während die Spec London-+NY-Session-only vorschreibt. Die Pfad-C-Diagnose (WR 18.68 %) würde sich mit Session-Filter weiter verschlechtern (weniger Trades, potentiell noch niedrigere WR), da die Spec-Outperformance-These auf Session-Volumen basiert.
- **Empfehlung:** Session-Filter-Parameter (identisch zu UT Bot/Ichimoku) ins BB+RSI-Manifest aufnehmen und in `on_candle` vor den Entry-Checks aufrufen. Falls eine bewusste Abweichung von der Spec vorliegt, in §12 des Spec-Dokuments dokumentieren.

#### S-02 [MEDIUM] Ungenutzte Chikou-Span-Helfer im Ichimoku-Modul

- **Problem:** Die Funktionen `chikou_confirms_long` (Zeile 288) und `chikou_confirms_short` (Zeile 301) implementieren die **klassische** Chikou-Span-Definition (`close[i] > close[i-26]`). Die `detect_entry`-Funktion (Zeile 433) verwendet jedoch die **video-spec-konforme** Cloud-basierte Chikou-Definition (`close > cloud_chikou_upper`). Die klassischen Helfer sind damit **toter Code** — sie werden nirgends aufgerufen, haben aber vollständige Implementierungen, Docs und keine Tests.
- **Betroffene Datei:** `rust/trading_engine/src/addins/ichimoku.rs:288-306`
- **Auswirkung:** Verwirrung bei zukünftigen Maintainern — zwei konkurrierende Chikou-Definitionen im selben Modul. Die klassische Definition ist kanonisch für Ichimoku, die video-spec-konforme ist es für *diese* Strategie.
- **Empfehlung:** Entweder (a) Löschen und in Git-History belassen, oder (b) mit `#[allow(dead_code)]` markieren und Doc-Kommentar ergänzen dass die video-spec von der klassischen Definition abweicht.

#### S-03 [MEDIUM] `swing_lookback_bars` im Ichimoku-Manifest ohne Funktion

- **Problem:** Der Parameter `swing_lookback_bars` (Default 20, Range 5–100) ist im Ichimoku-Manifest deklariert (Zeile 823–830), wird aber **nie in `on_candle` verwendet**. Die Ichimoku-SL-Logik nutzt `ichimoku_sl_long(kijun_i, current_cloud_lower)` (Zeile 707) — also Kijun/Cloud-basierte SLs, keine Swing-basierten. Der Code-Kommentar sagt: "swing_lookback_bars is currently unused by the Ichimoku SL (kept in the manifest so a Phase-3 hybrid SL variant can opt in without breaking the parameter map)."
- **Betroffene Datei:** `rust/trading_engine/src/addins/ichimoku.rs:823-830`
- **Auswirkung:** Nutzer-Verwirrung — ein im UI angezeigter Parameter, der das Strategie-Verhalten nicht beeinflusst. Verletzt das Principle of Least Surprise.
- **Empfehlung:** Entweder (a) aus Manifest entfernen und bei Bedarf in Phase 3 wieder hinzufügen, oder (b) im UI als "inaktiv / reserved for Phase 3" markieren.

#### S-04 [MEDIUM] `shift`-Parameter ignoriert — hartkodiertes `CLOUD_SHIFT_BARS`

- **Problem:** Das Ichimoku-Manifest deklariert einen `shift`-Parameter (Default 26.0, Range 5–100). Die Strategie implementiert jedoch alle Read-Anchors (`past_senkou_at_i_minus_26`, `future_senkou_at_i`, etc.) mit der hartkodierten Konstanten `CLOUD_SHIFT_BARS = 26` (Zeile 159). Der `shift`-Wert aus den Parametern wird **zwar gelesen** (Zeile 533: `let shift = ctx.param_or("shift", 26.0) as usize;`), aber **nie in der Cloud-Logik verwendet**. Der Code-Kommentar bestätigt: "the manifest's `shift` parameter exists for documentation and Phase-3 experimentation, not to override the canonical Ichimoku 26-bar visual shift" (Zeile 595-599).
- **Betroffene Datei:** `rust/trading_engine/src/addins/ichimoku.rs:533` vs. `ichimoku.rs:159`
- **Auswirkung:** Gleiche Kategorie wie S-03 — toter Parameter im UI. Zusätzlich: wenn ein Nutzer `shift = 13` setzt, erwartet er verändertes Verhalten, bekommt aber unverändertes.
- **Empfehlung:** Parameter aus Manifest entfernen oder tatsächlich in den Read-Anchors verwenden (dann alle `26`-Literale durch `shift` ersetzen und Warm-Up-Berechnung anpassen).

---

### 3.2 Code-Qualität & Performance

#### S-05 [MEDIUM] O(n²) Indikator-Neuberechnung pro Bar

- **Problem:** Alle drei Strategien berechnen ihre Indikator-Serien **vollständig ab Index 0 neu** in jedem `on_candle`-Aufruf:
  - **BB+RSI:** `calc_bollinger_bands` / `calc_rsi` auf `ctx.closes(i+1)` (volles Fenster)
  - **UT Bot:** `calc_ema`, `calc_atr`, `calc_ut_bot_trail`, `calc_smi` — alle über `closes[..=i]`
  - **Ichimoku:** `calc_tenkan_sen`, `calc_kijun_sen`, `calc_senkou_span_a`, `calc_senkou_span_b` — alle über `highs[..=i]` / `lows[..=i]`
  - **ADX (common.rs):** `calc_adx(&highs, &lows, &closes, adx_period)` — jedes `on_candle` vollständig ab 0
- **Auswirkung:** Für einen Backtest mit N Kerzen ergibt sich O(n²) Laufzeit:
  - 760-Tage-1h ≈ 18.000 Kerzen → ~162M Indikator-Berechnungen (18k × 9k avg)
  - Dies ist der dominante Kostenfaktor in den Phase-3-Optimizer-Sweeps (500–1000 Trials)
  - Kein Bug — die Strategien sind **stateless by design**, aber das Design ist nicht performant
- **Empfehlung:** Für Phase-3-Optimizer: inkrementelle Indikator-Updates implementieren, die nur die jeweils letzte Bar berechnen. Dies ist ein Architektur-Trade-off (stateless = einfach, korrekt, parity-freundlich vs. stateful = schnell, komplexer, parity-anfällig). Für den Optimizer-Lab-Betrieb akzeptabel, für Live-Trading (eine Bar pro Schritt) irrelevant. **Niedrige Priorität, da kein funktionaler Defekt.**

#### S-06 [LOW] BB+RSI Manifest-Description beschreibt Mean Reversion statt Trendfolge

- **Problem:** Die `bb_rsi_manifest()`-Description (Zeile 502–505) lautet: "Mean-reversion strategy: enter when price touches a Bollinger Band extreme with confirming RSI, exit at the middle band or opposite RSI extreme." Die tatsächliche Implementierung (Spec-Variante 3, verbesserte Variante) interpretiert BB jedoch als **Trendfilter**: Preis über BB-Upper = Uptrend, RSI-Cross = Pullback-Re-Entry. Exit erfolgt über SL/TP, nicht über BB-Mitte (D-11 hat BB-Mitte-Exits entfernt). Auch die Kategorie ist `StrategyCategory::MeanReversion` (Zeile 506), sollte aber `StrategyCategory::Trend` sein.
- **Betroffene Datei:** `rust/trading_engine/src/addins/bb_rsi.rs:502-506`
- **Auswirkung:** Falsche Kategorisierung im UI (Strategie-Auswahl, Filterung). Der Spec selbst klassifiziert die Variante 3 explizit als „Trendfolge mit Pullback".
- **Empfehlung:** Description und Category auf Trend-following aktualisieren.

#### S-07 [LOW] Inkonsistente TZ-Offset-Parametrisierung

- **Problem:** Die drei Strategien handhaben den Zeitzonen-Offset für den Session-Filter uneinheitlich:
  - **UT Bot:** `within_session(current_ts, session_start, session_end, 1)` — UTC+1 hartkodiert
  - **Ichimoku:** `within_session(current_ts, session_start, session_end, tz_offset)` — parametrisiert via `tz_offset_hours`
  - **BB+RSI:** Session-Filter fehlt komplett (S-01)
- **Betroffene Dateien:** `ut_bot.rs:504`, `ichimoku.rs:538-540`, `common.rs:41`
- **Auswirkung:** Wenn ein Nutzer UT Bot auf einen non-Berlin-Markt konfigurieren will (z.B. Tokyo-Session), muss er den Code ändern, während Ichimoku dies per Parameter unterstützt.
- **Empfehlung:** UT Bot ebenfalls auf `tz_offset_hours`-Parameter migrieren (analog Ichimoku). BB+RSI bei Implementierung des Session-Filters gleich mit parametrisierbarem Offset versehen.

#### S-08 [LOW] Fragile f64→i32-Konvertierung für `score_threshold`

- **Problem:** In `ichimoku.rs:534` wird der `score_threshold`-Parameter von f64 nach i32 gecastet:
  ```rust
  let score_threshold = ctx.param_or("score_threshold", 60.0) as i32;
  ```
  Der Parameter hat `step = 5.0` und `default = 60.0`, sodass alle per UI wählbaren Werte ganzzahlig sind. Allerdings würde ein Wert wie `60.00000000000001` (Floating-Point-Rundung) zu `60` truncaten, nicht runden. Im Extremfall könnte jemand per API/Config `60.9` setzen, was zu `60` statt des erwarteten `61` führen würde.
- **Betroffene Datei:** `rust/trading_engine/src/addins/ichimoku.rs:534`
- **Auswirkung:** Gering — Parameter-Schema limitiert auf Step 5.0 und Range [20, 100], sodass nur ganzzahlige Vielfache erreichbar sind. Trotzdem fragil.
- **Empfehlung:** `score_threshold.round() as i32` statt `as i32` verwenden, um Floating-Point-Rundungsfehler zu neutralisieren.

---

## 4. Behebungsplan

```
Phase 1 (Quick Wins, < 2 h)          Phase 2 (Konsistenz, 2–4 h)         Phase 3 (Performance, 4–8 h)
┌─────────────┐                       ┌──────────────────┐                ┌──────────────────────┐
│ S-06: Beschr│                       │ S-01: BB+RSI     │                │ S-05: Inkrementelle │
│ S-08: f64→  │                       │ Session-Filter   │                │ Indikator-Updates   │
│     i32 cast│                       │ S-07: UT Bot TZ  │                │ (niedrige Prio)     │
│ S-02: Dead  │                       │ S-03: Ichimoku   │                └──────────────────────┘
│     Code    │                       │ swing_lookback   │
│ S-04: shift │                       │ S-04: shift      │
└─────────────┘                       └──────────────────┘
```

### Phase 1: Quick Wins (geschätzt < 2 h)

| ID | Aktion | Aufwand |
|---|---|---|
| **S-06** | BB+RSI-Manifest: `description` + `category` auf Trendfolge aktualisieren | **S** |
| **S-08** | `score_threshold.round() as i32` in `ichimoku.rs:534` | **S** |
| **S-02** | `chikou_confirms_long/short` entweder löschen oder mit `#[allow(dead_code)]` + Doc versehen | **S** |
| **S-04** | `shift`-Parameter aus Ichimoku-Manifest entfernen ODER in Cloud-Anchors verwenden | **S** |

### Phase 2: Strategie-Konsistenz (geschätzt 2–4 h)

| ID | Aktion | Aufwand |
|---|---|---|
| **S-01** | BB+RSI Session-Filter implementieren (Manifest-Parameter + `on_candle`-Aufruf) | **M** |
| **S-07** | UT Bot von hartkodiertem `1` auf `tz_offset_hours`-Parameter migrieren | **S** |
| **S-03** | `swing_lookback_bars` aus Ichimoku-Manifest entfernen (oder Phase-3-Hybrid-SL implementieren) | **S** |

### Phase 3: Performance (geschätzt 4–8 h, niedrige Priorität)

| ID | Aktion | Aufwand |
|---|---|---|
| **S-05** | Inkrementelle Indikator-Updates für ADX/ATR/SMI/Tenkan/Kijun (stateful Caching) | **L** |

---

## 5. Risiko-Bewertung

| Risiko | Eintritts-Wkt. | Schaden bei Eintritt | Betroffene Findings |
|---|---|---|---|
| **Session-Filter-Drifts zwischen Strategien:** BB+RSI feuert 24/7, UT Bot/Ichimoku nur in Session — unterschiedliche Trade-Frequenz verzerrt Strategie-Vergleiche im Optimizer | Mittel | Mittel | S-01, S-07 |
| **Nutzer-Frust durch tote UI-Parameter:** `swing_lookback_bars` und `shift` im Ichimoku-UI ohne Effekt | Hoch | Niedrig | S-03, S-04 |
| **Verwirrung durch konkurrierende Chikou-Definitionen:** Zukünftiger Maintainer implementiert fälschlich klassische Chikou-Logik | Niedrig | Mittel | S-02 |
| **Optimizer-Durchsatz limitiert durch O(n²):** 500-Trial Sweep dauert ~2–4h statt potenziell ~20–40 min | Hoch | Mittel | S-05 |
| **Falsche Strategie-Kategorie im UI:** BB+RSI wird unter MeanReversion geführt statt Trend | Niedrig | Niedrig | S-06 |

---

## 6. Vergleich mit Vorgänger-Audit (260522_0246)

Das Vorgänger-Audit identifizierte überwiegend Architektur-Probleme (unverdrahtete Rust-FFI, fehlende SL/TP-Simulation, Look-Ahead-Execution-Bias). Der aktuelle Stand zeigt:

| Vorgänger-Finding | Status Mai 2026 | Kommentar |
|---|---|---|
| **F-01** (Rust unverdrahtet) | Teilweise gelöst | Strategien sind in Rust voll implementiert, FFI-Bridge existiert. Dart-Fallback weiterhin aktiv — siehe HANDOFF-Doc. |
| **F-02** (Fehlende SL/TP) | **Gelöst** | Alle drei Strategien emittieren SL + TP + size_pct via `Signal::Enter{Long,Short}` |
| **F-03** (Sharpe-Formel) | **Gelöst** | Rust Engine hat korrekte Sharpe-Annualisierung via `sqrt(periods_per_year)` |
| **F-04** (Look-Ahead Bias) | **Dokumentiert** | Signale auf Close-Bar-i, Fill auf Open-Bar-i+1 per F-04-Konvention in allen Specs dokumentiert |
| **F-05** (Cache-Bypassing) | Unbekannt | Betrifft Dart/Flutter-API-Layer, nicht im Rust-Strategie-Scope |
| **F-06** (Redundante Modelle) | Unbekannt | Betrifft Dart/Flutter-Layer |
| **F-07** (Dead Code) | Unbekannt | Betrifft Dart/Flutter-Layer |
| **F-08** (UI unvollständig) | Unbekannt | Betrifft Dart/Flutter-Layer |

---

*Audit durchgeführt: 2026-05-28. Scope: Rust-Strategie-Implementierungen (`addins/bb_rsi.rs`, `addins/ut_bot.rs`, `addins/ichimoku.rs`, `addins/common.rs`) und zugehörige Strategy-Specs.*
