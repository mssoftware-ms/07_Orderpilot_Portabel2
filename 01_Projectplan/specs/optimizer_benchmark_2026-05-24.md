# Optimizer Trial-Wrapper Compute-Benchmark (Welle O2 Pre-Flight)

**Datum:** 2026-05-24
**Phase:** 3 — Welle O2 (Production Sweeps)
**Strategien:** BB+RSI Var3 · UT Bot v1 · Ichimoku Cloud Retest (Welle-O1 Search-Spaces, Welle-R4 ADX-Filter immer an)
**Engine-Konfiguration:** Bitunix-VIP0 0.06 % Taker-Fee pro Seite, 10.000 USDT Startkapital, F-04 Next-Bar-Open-Execution, slippage_bps = 0
**Daten-Pipeline:** `tool/fetch_sweep_data.dart` → `01_Projectplan/optimizer_data/*.json` (gitignored, regenerable, Binance public klines)
**Mess-Werkzeug:** `cargo run --release --example sweep_benchmark` — 10 Trials pro Strategie auf realen Candles, gleiche Code-Pfade wie der Production-Sweep (`RandomSearchEngine::run_study` → `run_optimization_trial` → SQLite-Insert).
**Ziel:** Vor dem 1000-Trial-Sweep verlässlich extrapolieren, wie lange die drei Sweeps zusammen brauchen, und gegen die im Welle-O2-Brief gesetzten Eskalations-Gates abklopfen.

---

## 1. Mess-Setup

Drei Strategien, drei reale Candle-Reihen exakt im Welle-O2-Brief-Setup:

| Strategie | Asset | TF | Range | Candles | DB-Cap | min_trades |
|---|:---:|:---:|---|---:|---:|---:|
| BB+RSI | BTCUSDT | 4h | 2024-01-01 → 2024-07-01 | 1093 | 19.0 % | 30 |
| UT Bot | BTCUSDT | 5m | 2024-01-01 → 2024-03-08 | 19297 | 17.0 % | 50 |
| Ichimoku | BTCUSDT | 1h | 2023-04-01 → 2025-05-02 | 18289 | 15.0 % | 60 |

Seed 42, 10 Trials, `BacktestConfig { initial_balance: 10_000, fee_rate: 0.0006, slippage_bps: 0.0, timeframe: ... }`. Storage als wegwerfbares SQLite unter `target/sweep_benchmark.db`, damit Disk-I/O dieselbe ist wie im Production-Sweep (kein in-memory).

---

## 2. Roh-Messung

```
   bb_rsi   candles=01093  10 trials in   0.53s  ⇒    52.53 ms/trial
   ut_bot   candles=19297  10 trials in 225.06s  ⇒  22505.96 ms/trial
 ichimoku   candles=18289  10 trials in 298.25s  ⇒  29825.26 ms/trial
```

Hardware: WSL2-Linux (Windows-Host), Cargo release-Profil mit `-O3`. Single-Thread, kein rayon.

---

## 3. Extrapolation auf 1000 Trials

| Strategie | ms/Trial | 1000-Trial ETA | 500-Trial ETA |
|---|---:|---:|---:|
| BB+RSI | 52.5 | 0.015 h ≈ 53 s | 0.007 h ≈ 26 s |
| UT Bot | 22 506 | **6.25 h** | 3.13 h |
| Ichimoku | 29 825 | **8.28 h** | 4.14 h |

Total bei 1000/1000/1000 → 14.55 h. Total bei 1000/500/500 → 7.28 h. Total bei 1000/500/1000 → 11.41 h.

---

## 4. Eskalations-Gates (Welle-O2-Brief §SCHRITT-0)

| Gate (Brief-Wortlaut) | Trigger | Beobachtung | Verdikt |
|---|---|---|---|
| BB+RSI > 1 h ETA trotz 1093 Candles → Regression seit Phase 2 → STOPP | > 1.0 h | 0.015 h | **PASS** |
| UT-Bot > 4 h ETA → reduziere auf n_trials = 500, dokumentiere | > 4.0 h | 6.25 h | **TRIGGER → 500** |
| UT-Bot > 8 h ETA → STOPP, Optimierungs-Vorschlag (rayon, defer) | > 8.0 h | 6.25 h | PASS |
| Ichimoku (kein expliziter Gate im Brief) | — | 8.28 h | siehe §5 |

Für UT-Bot greift die im Brief explizit benannte Reduktion auf 500 Trials. Für Ichimoku gibt es keinen expliziten Gate, aber die ETA liegt jenseits der UT-Bot-STOPP-Schwelle, was eine analoge Behandlung nahelegt.

---

## 5. Entscheidung — Trial-Counts für die drei Sweeps

Der Welle-O2-Brief setzt eine Gesamt-Compute-Envelope von **4–12 h**. Mit Brief-Default (1000/1000/1000) lägen wir bei 14.55 h, also über der Envelope. Zwei plausible Pläne stehen offen:

### Option A — Volle 1000 für BB+RSI + Ichimoku, 500 für UT-Bot

| Strategie | n_trials | ETA |
|---|---:|---:|
| BB+RSI | 1000 | 0.015 h |
| UT Bot | 500 | 3.13 h |
| Ichimoku | 1000 | 8.28 h |
| **Total** | | **≈ 11.4 h** |

Pro: Folgt dem Brief wortgetreu (Reduktion nur dort, wo der Brief sie nennt). Ichimoku bekommt die volle 1000-Trial-Auflösung, weil der Search-Space mit 9 Achsen relativ klein ist und 500 Trials laut Bergstra & Bengio die Sweep-Spots leicht verfehlen können.
Contra: 11.4 h ist am oberen Rand der Envelope; eine Compile-Unterbrechung mitten in Ichimoku kostet teuer.

### Option B — Symmetrische Reduktion auf 500 für UT-Bot und Ichimoku

| Strategie | n_trials | ETA |
|---|---:|---:|
| BB+RSI | 1000 | 0.015 h |
| UT Bot | 500 | 3.13 h |
| Ichimoku | 500 | 4.14 h |
| **Total** | | **≈ 7.3 h** |

Pro: Liegt mit 7.3 h klar in der Brief-Envelope, defensiver gegen Crashes, bewahrt eine konsistente Trial-Quote (≥500) für alle "echten" Sweeps.
Contra: Ichimoku verliert 500 Trials gegenüber dem Brief-Default. Wenn Welle-O2-Insights stark vom Top-1-Trial getrieben sind, hat Option A leicht mehr Auflösung.

### Empfehlung

**Option A** für maximale Brief-Treue: nur dort kürzen, wo der Brief explizit kürzt; Ichimoku läuft voll. Total-Compute 11.4 h liegt drin, und das Sweep-Run-Script committet pro Strategie atomar, sodass Crashes nicht das BB+RSI-Result mit reißen.

---

## 6. Wahl für Welle O2 (locked)

| Strategie | n_trials | Seed | ETA |
|---|---:|---:|---:|
| BB+RSI | **1000** | 42 | 0.015 h |
| UT Bot | **500** | 42 | 3.13 h |
| Ichimoku | **1000** | 42 | 8.28 h |
| **Total** | | | **11.43 h** |

Pro Strategie wird ein atomarer Commit gepusht, mit `studies-{strategy}.db` als Persistenz und einem `{strategy}_sweep_2026-05-24.md` Sweep-Bericht (Top-10, Distribution-Histograms, XLSX-Band-Check).

---

## 7. Reproduzierbarkeit

`RandomSearchEngine::new(42)` + identische Search-Space-YAML + identische Candle-Reihe → bit-identische Top-N. Die Integration-Tests in `tests/integration_optimizer_mini.rs` pinnen das auf der synthetischen 200-Bar-Fixture; auf realer Daten gilt derselbe Determinism-Contract.

`tool/fetch_sweep_data.dart` ist idempotent. Sollte ein Re-Fetch nötig sein (z.B. wenn Binance retroaktiv Candles korrigiert), `--force` setzen und die Studies-DB neu erzeugen.

---

## 8. Folge-Schritte

1. ✅ Compute-Benchmark dokumentiert.
2. ⏳ `production_sweep` Beispiel-Binary anlegen (CLI: strategy + n_trials + seed → DB + Report-MD).
3. ⏳ BB+RSI 1000-Trial Sweep (Commit O2-1, ≤ 1 Minute Laufzeit).
4. ⏳ UT-Bot 500-Trial Sweep (Commit O2-2, ≈ 3 h).
5. ⏳ Ichimoku 1000-Trial Sweep (Commit O2-3, ≈ 8 h).
6. ⏳ Cross-Strategy-Konsolidierung (Commit O2-4) plus Plan §4.4 Update.

---

## 9. Risiken / Eskalation

- **Trial-Wrapper non-deterministisch trotz Seed 42:** würde die Welle-O2-Repro-Garantie brechen. Pre-Flight-Check: zwei aufeinanderfolgende `cargo test --release integration_optimizer_mini` müssen identische Top-5 liefern. Falls nicht: SOFORT STOPP, Diagnose-Brief.
- **Mid-Sweep-Crash auf Ichimoku:** der Sweep-Runner committet pro Trial in die SQLite — ein Crash auf Trial 500/1000 verliert nur den verbleibenden Hälfte. Re-Start: dieselbe Studie-Name + neue Trial-IDs ab `n_existing + 1` (TODO im Sweep-Binary: `--resume`-Flag, sonst Re-Run von 0).
- **Disk-Space:** Studies-DBs bleiben ≤ 10 MB (1000 Trials × ~5 KB Trial-JSON). 11 KB pro Trial sind das geprüfte Maximum auf den Welle-O1-Mini-Sweeps. Total < 25 MB für alle drei DBs.
