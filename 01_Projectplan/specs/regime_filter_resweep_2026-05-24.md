# ADX Regime Filter — Welle R4 Re-Sweep (Dart↔Rust 1e-9 Parity Enforced)

**Datum:** 2026-05-24
**Phase:** 2.5 — Welle R4 (Rust ADX Wiring Real-Data Re-Verifikation)
**Strategien:** BB+RSI Var3 · UT Bot v1 · Ichimoku Cloud Retest (Spec-Defaults, Endstand)
**Engine-Konfiguration:** Bitunix-VIP0 0.06 % Taker-Fee pro Seite, 10.000 USDT Startkapital, F-04 Next-Bar-Open-Execution
**Build-Vorbedingung:** `bash tool/build_rust.sh` (refresh `libtrading_engine.{so,dll}`) — Welle R3 hat diesen Schritt verpasst und einen stalen Pre-Welle-R2 .so geladen, was den falschen „Rust-Wiring-Bug"-Befund erzeugte.
**Test-Erweiterung gegenüber R3:** `test/integration/regime_filter_sweep_test.dart` validiert jetzt **PnL + Sharpe + MaxDD** bit-exakt zwischen Dart und Rust (R3: nur PnL). Plus setUpAll staleness-guard, der pre-Welle-R2 Binaries fail-fast detektiert.
**Resultat:** Alle **12/12 Sweep-Configs** zeigen Dart↔Rust 1e-9 Bit-Parität — der R3-Befund „Rust ignoriert ADX-Filter" ist als STALE-BINARY-Artefakt identifiziert und resolved.

---

## 1. Sweep-Matrix (identisch zu R3)

| Config | adx_filter_enabled | adx_threshold | adx_use_di_confluence |
|---|:---:|---:|:---:|
| C0 baseline | false | — | — |
| C1 thr=25 | true | 25 | false |
| C2 thr=35 | true | 35 | false |
| C3 thr=25 +DI | true | 25 | true |

| Strategie | Asset | TF | Range | Candles |
|---|:---:|:---:|---|---:|
| BB+RSI | BTCUSDT | 4h | 2024-01-01 → 2024-07-01 | 1093 |
| UT Bot | BTCUSDT | 5m | 2024-01-01 → 2024-03-07 | 19009 |
| Ichimoku | BTCUSDT | 1h | 2023-04-01 → 2025-05-01 | 18265 |

---

## 2. Re-Sweep Resultate — Dart UND Rust pro Config (bit-exakt 1e-9)

### 2.1 BB+RSI Var3 · BTC 4h · 2024-H1 (1093 Candles)

| Config | engine | trades | WR % | PF | DD % | totalPnl USDT | profit % | sharpe | realised R |
|---|:---:|---:|---:|---:|---:|---:|---:|---:|---:|
| C0 baseline | Dart | 15 | 20.00 | 1.222 | 9.996 | +233.583080 | +2.34 | 0.784653 | 4.89 |
| C0 baseline | Rust | 15 | 20.00 | 1.222 | 9.996 | +233.583080 | +2.34 | 0.784653 | 4.89 |
| C1 thr=25 | Dart | 11 | 18.18 | 0.950 | 10.429 | −62.249693 | −0.62 | −0.081279 | 4.27 |
| C1 thr=25 | Rust | 11 | 18.18 | 0.950 | 10.429 | −62.249693 | −0.62 | −0.081279 | 4.27 |
| C2 thr=35 | Dart | 6 | 33.33 | **4.888** | **4.566** | **+966.859484** | +9.67 | 3.586742 | 9.78 |
| C2 thr=35 | Rust | 6 | 33.33 | **4.888** | **4.566** | **+966.859484** | +9.67 | 3.586742 | 9.78 |
| C3 thr=25 +DI | Dart | 3 | 33.33 | 2.657 | 2.761 | +367.739845 | +3.68 | 2.092772 | 5.31 |
| C3 thr=25 +DI | Rust | 3 | 33.33 | 2.657 | 2.761 | +367.739845 | +3.68 | 2.092772 | 5.31 |

### 2.2 UT Bot v1 · BTC 5m · 66 Tage (19009 Candles)

| Config | engine | trades | WR % | PF | DD % | totalPnl USDT | profit % | sharpe | realised R |
|---|:---:|---:|---:|---:|---:|---:|---:|---:|---:|
| C0 baseline | Dart | 131 | 24.43 | 0.535 | 19.792 | −1527.128688 | −15.27 | −5.755180 | 1.65 |
| C0 baseline | Rust | 131 | 24.43 | 0.535 | 19.792 | −1527.128688 | −15.27 | −5.755180 | 1.65 |
| C1 thr=25 | Dart | 35 | 22.86 | 0.695 | 8.322 | −354.006135 | −3.54 | −2.012543 | 2.35 |
| C1 thr=25 | Rust | 35 | 22.86 | 0.695 | 8.322 | −354.006135 | −3.54 | −2.012543 | 2.35 |
| C2 thr=35 | Dart | 8 | 37.50 | **2.339** | **2.920** | **+277.629613** | +2.78 | 2.550824 | 3.90 |
| C2 thr=35 | Rust | 8 | 37.50 | **2.339** | **2.920** | **+277.629613** | +2.78 | 2.550824 | 3.90 |
| C3 thr=25 +DI | Dart | 23 | 21.74 | 0.667 | 7.218 | −300.416022 | −3.00 | −1.891414 | 2.40 |
| C3 thr=25 +DI | Rust | 23 | 21.74 | 0.667 | 7.218 | −300.416022 | −3.00 | −1.891414 | 2.40 |

### 2.3 Ichimoku · BTC 1h · 760 Tage (18265 Candles)

| Config | engine | trades | WR % | PF | DD % | totalPnl USDT | profit % | sharpe | realised R |
|---|:---:|---:|---:|---:|---:|---:|---:|---:|---:|
| C0 baseline | Dart | 158 | 29.75 | 1.088 | 20.872 | +1245.566715 | +12.46 | 0.398694 | 2.57 |
| C0 baseline | Rust | 158 | 29.75 | 1.088 | 20.872 | +1245.566715 | +12.46 | 0.398694 | 2.57 |
| C1 thr=25 | Dart | 119 | 28.57 | 0.996 | 18.298 | −51.060065 | −0.51 | 0.069786 | 2.49 |
| C1 thr=25 | Rust | 119 | 28.57 | 0.996 | 18.298 | −51.060065 | −0.51 | 0.069786 | 2.49 |
| C2 thr=35 | Dart | 89 | 31.46 | 1.184 | **12.695** | **+1679.690076** | +16.80 | 0.567017 | 2.58 |
| C2 thr=35 | Rust | 89 | 31.46 | 1.184 | **12.695** | **+1679.690076** | +16.80 | 0.567017 | 2.58 |
| C3 thr=25 +DI | Dart | 119 | 28.57 | 0.987 | 18.298 | −147.803833 | −1.48 | 0.042179 | 2.47 |
| C3 thr=25 +DI | Rust | 119 | 28.57 | 0.987 | 18.298 | −147.803833 | −1.48 | 0.042179 | 2.47 |

---

## 3. Bit-Parität-Validierung

`test/integration/regime_filter_sweep_test.dart::_assertDartRustParity` enforced pro Config:
- `expect(rust.totalTrades, equals(dart.totalTrades))` — Trade-Count exakt
- `expect(rust.totalPnl, closeTo(dart.totalPnl, 1e-9))` — PnL ±1e-9 USDT
- `expect(rust.sharpeRatio, closeTo(dart.sharpeRatio, 1e-9))` — Sharpe ±1e-9
- `expect(rust.maxDrawdownPercent, closeTo(dart.maxDrawdownPercent, 1e-9))` — MaxDD% ±1e-9

**Resultat:** Alle 12 Configs (3 Strategien × 4 ADX-Configs) bestehen alle 4 Assertion-Gates. Welle R2-Wiring + Welle R1 `calc_adx` Helper liefern bit-exakte Dart↔Rust Mirror auf realer BTC-Historie.

---

## 4. Pfad-Klassifikation (unverändert gegenüber R3 §3 — Dart-Resultate sind identisch zu R3)

| Strategie | Pfad | Best-Config | Best-Bands | Phase-3-Empfehlung |
|---|:---:|:---:|:---:|---|
| BB+RSI | C | C3 thr=25 +DI | 3/5 | ADX-augmented Optimizer-Range, längeres Test-Window für Trade-Count |
| UT Bot | C | C2 thr=35 | 2/5 (PF im Band!) | ADX-augmented Optimizer-Range default-aktiv, Vorzeichen-Flip von −15 % auf +3 % |
| Ichimoku | C | C2 thr=35 | 2/5 (DD im Band!) | ADX-augmented Optimizer-Range, DI-Confluence redundant |

Phase-2-Gate-Outcome: **B (Pfad C mit Phase-3-Optimizer-Insight)** — keine Strategie trifft alle 5 XLSX-Bänder, aber alle drei zeigen merkliche Verbesserung in mindestens einer Achse durch C2 (thr=35). Plan §4.4 rev5 §B legitimes Phase-2-Resultat.

---

## 5. Root-Cause-Befund Welle R4

**Symptom (R3):** Rust-Mirror der 12 Sweep-Tests zeigte für C1/C2/C3 identische Werte zu C0 — Rust ignoriert ADX-Filter auf realen BTC-Daten.

**Hypothesen (R3 §4):** H3 `ctx.in_position` manual-set / H5 `engine.run` Context-Build-Pfad / H1 FP-Akkumulation.

**Tatsächliche Root-Cause:** STALE `libtrading_engine.so` (Linux dev FFI path: `rust/trading_engine/target/release/`). Das von R3 geladene Binary stammt aus einem Build vor Welle R2 — der Rust-Strategy-Code dort liest `adx_filter_enabled` gar nicht und produziert Baseline-Werte. Flutter `flutter test` invokiert NICHT `cargo build` auf .rs-Änderungen; das .so muss explizit per `bash tool/build_rust.sh` oder `cargo build --release --lib` aktualisiert werden.

**Verifikation:** Nach explizitem `cargo build --release --lib` ist der Rust-Binary mtime jünger als die Welle-R2-Source. Re-Sweep produziert dann bit-exakt Dart↔Rust 1e-9 Parität auf allen 12 Configs (Tabelle §2). Die Welle-R2 Strategy-Wiring (bb_rsi.rs, ut_bot.rs, ichimoku.rs ADX-Filter-Pfade) sowie die Welle-R1 `calc_adx` und `regime_passes_filter` Helper sind alle KORREKT — kein Code-Fix nötig.

**Schutzmaßnahmen (Welle R4-1 + R4-2):**
1. `tool/build_rust.sh` — convenience wrapper für cargo build
2. `regime_filter_sweep_test.dart` setUpAll staleness-guard — `threshold=100 → 0 trades` invariant auf 35-bar fixture invoked PRE-sweep; pre-Welle-R2 binary fails fast mit `rebuild required` message
3. `rust/trading_engine/tests/regression_adx_real_data.rs` — long-sequence (1100-bar LCG) Wiring-Pin, läuft über `cargo test` mit automatischem Rebuild

---

## 6. Phase-2-Gate-Status

**RESOLVED.** Engineering vollständig, Dart-only-Verifikation vollständig, Dart↔Rust 1e-9 Parität auf ALLEN 12 Sweep-Configs für PnL+Sharpe+MaxDD validiert.

**Phase-2-Tag** `v0.3.0-strategies-verified` ist freigegeben — QA setzt manuell nach Sign-off.
