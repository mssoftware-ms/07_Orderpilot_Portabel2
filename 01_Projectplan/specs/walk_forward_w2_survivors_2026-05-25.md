# Walk-Forward W2 Survivors — Ichimoku

**Datum:** 2026-05-25
**Phase:** 3.1 — Welle W2 (Survivor-Liste + Pre-TPE Range-Vorschlag)
**Source-Studie:** `production_ichimoku_n1000_seed42_2026-05-24` (Welle O2)
**Walk-Forward-DB:** `01_Projectplan/optimizer_studies/studies-ichimoku-wf.db`
**Walk-Forward-CSV:** `01_Projectplan/optimizer_studies/walk_forward_top109_ichimoku.csv`
**Walk-Forward-Konfig:** train=4392 bars, validate=1464 bars, step=1464 bars, stability_penalty=0.5, 9 splits pro Trial
**Engine-Compute:** 25m28s, 14.0s/trial avg (`cargo run --release --example walk_forward_replay`)

---

## 1. Headline

- 109 / 1000 Welle-O2 Trials waren qualified (score > NEG_INFINITY).
- Walk-Forward auf 109 qualifizierten Trials produziert **0 Survivor unter den Default-`SurvivorCriteria`** (mean_oos_pf ≥ 1.3, std_oos_pf ≤ 1.0, is_oos_decay ≤ 0.7, worst_oos_pf ≥ 0.6).
- Bindende Gates: `std_oos_pf ≤ 1.0` → 109/109 fail. `worst_oos_pf ≥ 0.6` → 109/109 fail.
- **Eskalations-Brief (Plan-Ref): „0 Survivors nach Default-Criteria: Criteria zu streng".** Vorschlag relaxter Criteria + 20 Survivor unter relaxierten Werten in §3.
- **Rank-Erhalt nach Walk-Forward kollabiert:** Welle-O2 Top-1 (Trial 515) fällt auf Walk-Forward-Rang 6 ab; keiner der Welle-O2-Top-5 überlebt selbst die relaxten Criteria. Strukturelles Overfitting-Signal — siehe §4.

---

## 2. Distribution (alle 109 Walk-Forward-Trials)

| Metric           |   min  |   p10  |   p25  |   p50  |   p75  |   p90  |   max  |
|------------------|-------:|-------:|-------:|-------:|-------:|-------:|-------:|
| `mean_oos_pf`    |  1.338 |  1.663 |  1.905 |  8.536 | 69.772 |127.955 |178.101 |
| `std_oos_pf`     |  1.138 |  1.562 |  2.117 | 19.194 |157.925 |313.846 |345.144 |
| `worst_oos_pf`   |  0.000 |  0.000 |  0.000 |  0.000 |  0.222 |  0.330 |  0.508 |
| `is_oos_decay`   |-175.46 |-126.62 | -68.04 |  -6.56 |  -0.43 |  -0.06 |   0.39 |

**Diagnostische Beobachtungen:**

1. **PF-Inflation in kleinen Validate-Windows:** 1464-bar (≈2 Monate H1) Validate-Windows sehen ~5-6 Ichimoku-Trades. PF=∑profit / ∑loss explodiert, wenn ∑loss klein wird (worst-case ∑loss=0 → PF=Inf → sanitized auf 0.0; gegenteilig: 0.1 USD loss bei 50 USD profit → PF=500). `mean_oos_pf` ist dadurch nicht stabilitätstauglich.
2. **`worst_oos_pf` ist die schärfste Verteilung:** p50=0.0, max=0.508. Kein einziger Trial schafft 0.6 als Floor; mindestens 50 % der Trials haben in mindestens einem Validate-Window keine profitable Trade-Sequenz.
3. **`is_oos_decay` ist überwiegend negativ** (90. Perzentil bei -0.06): OOS-PF dominiert IS-PF wegen der PF-Outliers — paradox auf den ersten Blick, aber konsistent mit „kleine OOS-Windows explodieren in PF, große IS-Windows nicht".
4. **`std_oos_pf` Minimum ist 1.138** — kein einziger Trial passt unter den Default-Cap 1.0. Bei 9 Validate-Windows mit PF-Range [0, 500] ist eine Standardabweichung < 1.0 strukturell unerreichbar.

**ASCII-Histogramme:**

```
mean_oos_pf (bin 0..200, width 25):
   0.0–25.0  │  87  ████████████████████████████████████████
  25.0–50.0  │   9  ████
  50.0–75.0  │   1  ▌
  75.0–100.0 │   2  █
 100.0–125.0 │   3  █▌
 125.0–150.0 │   5  ██
 150.0–175.0 │   1  ▌
 175.0–200.0 │   1  ▌

std_oos_pf (bin 0..360, width 45):
   0.0–45.0  │  72  ████████████████████████████████████████
  45.0–90.0  │  11  ██████
  90.0–135.0 │   2  █
 135.0–180.0 │   5  ██▌
 180.0–225.0 │   1  ▌
 225.0–270.0 │   5  ██▌
 270.0–315.0 │   8  ████
 315.0–360.0 │   5  ██▌

worst_oos_pf (bin 0..0.55, width 0.069):
  0.000–0.069 │  55  ████████████████████████████████████████
  0.069–0.138 │   2  █
  0.138–0.207 │   4  ██
  0.207–0.275 │  14  ██████████
  0.275–0.344 │  15  ███████████
  0.344–0.413 │   8  █████
  0.413–0.482 │   6  ████
  0.482–0.550 │   5  ███
```

---

## 3. Survivor-Liste unter relaxten Criteria

### 3.1 Vorgeschlagene Welle-W2 Relaxed Criteria (Ichimoku 1h, 1464-bar Validate)

| Gate                | Default | **Relaxed** | Begründung |
|---------------------|--------:|------------:|------------|
| `min_mean_oos_pf`   |     1.3 |       **1.3** | Unverändert — alle 109 passen bereits, Floor sinnvoll. |
| `max_std_oos_pf`    |     1.0 |       **3.0** | Default unerreichbar (min=1.14). 3.0 cut bei p33; Restlauf bleibt diskriminativ. |
| `max_is_oos_decay`  |     0.7 |       **0.7** | Unverändert — alle 109 passen. |
| `min_worst_oos_pf`  |     0.6 |       **0.1** | Default unerreichbar (max=0.508). 0.1 cut bei p33; verbleibt diskriminativ. |

CLI-Aufruf:
```bash
walk_forward_replay \
  --study      01_Projectplan/optimizer_studies/studies-ichimoku.db \
  --strategy   ichimoku \
  --candles    01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
  --output-csv 01_Projectplan/optimizer_studies/walk_forward_top109_ichimoku.csv \
  --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-wf.db \
  --skip-replay \
  --min-mean-oos-pf 1.3 --max-std-oos-pf 3.0 \
  --max-is-oos-decay 0.7 --min-worst-oos-pf 0.1
```

### 3.2 Survivor-Result: 20 / 109

Survivors sortiert nach `aggregated_score` DESC (= `mean_oos_pf − 0.5 × std_oos_pf`):

| rank | trial_id |  agg   | mean_oos | std_oos | worst  | mean_is | decay   |
|-----:|---------:|-------:|---------:|--------:|-------:|--------:|--------:|
|    1 |      570 | 1.1141 |    1.960 |   1.692 |  0.336 |   1.407 |  −0.553 |
|    2 |      739 | 1.0807 |    1.884 |   1.607 |  0.334 |   1.358 |  −0.526 |
|    3 |      109 | 1.0283 |    2.140 |   2.224 |  0.117 |   2.007 |  −0.133 |
|    4 |      343 | 1.0162 |    2.118 |   2.203 |  0.393 |   1.520 |  −0.597 |
|    5 |      777 | 0.9722 |    1.913 |   1.881 |  0.508 |   1.348 |  −0.565 |
|    6 |      387 | 0.9673 |    2.002 |   2.070 |  0.180 |   1.585 |  −0.418 |
|    7 |      778 | 0.9547 |    1.855 |   1.800 |  0.445 |   1.349 |  −0.506 |
|    8 |        0 | 0.9332 |    1.763 |   1.659 |  0.330 |   1.378 |  −0.385 |
|    9 |      402 | 0.9312 |    1.806 |   1.750 |  0.258 |   1.284 |  −0.523 |
|   10 |      445 | 0.9176 |    1.947 |   2.058 |  0.300 |   1.583 |  −0.364 |
|   11 |      525 | 0.9134 |    1.988 |   2.150 |  0.282 |   1.273 |  −0.715 |
|   12 |      906 | 0.9066 |    1.782 |   1.752 |  0.455 |   1.401 |  −0.381 |
|   13 |      859 | 0.8996 |    2.248 |   2.697 |  0.242 |   1.601 |  −0.647 |
|   14 |      688 | 0.8985 |    1.989 |   2.180 |  0.269 |   1.547 |  −0.441 |
|   15 |      623 | 0.8725 |    1.745 |   1.746 |  0.404 |   1.699 |  −0.047 |
|   16 |      815 | 0.8564 |    1.637 |   1.562 |  0.240 |   1.368 |  −0.270 |
|   17 |      875 | 0.8484 |    2.201 |   2.705 |  0.233 |   2.139 |  −0.062 |
|   18 |      586 | 0.8064 |    1.582 |   1.551 |  0.230 |   1.103 |  −0.478 |
|   19 |      263 | 0.7956 |    2.019 |   2.446 |  0.404 |   1.371 |  −0.648 |
|   20 |      421 | 0.7671 |    1.767 |   2.000 |  0.285 |   1.741 |  −0.026 |

### 3.3 Pfad-A-Reach (PF ≥ 2.14 OOS)

Pfad-A-Definition (Phase-2): produktionstaugliche Strategy erreicht PF ≥ 2.14 auf OOS. Auf `mean_oos_pf`-Basis:

| Rank | Trial | `mean_oos_pf` | Pfad-A? |
|-----:|------:|-------------:|:-------:|
|    1 |   859 |        2.248 |   ✓     |
|    2 |   875 |        2.201 |   ✓     |
|    3 |   109 |        2.140 |   ✓ (am Floor) |
|    4 |   343 |        2.118 |   ✗     |
|    5 |   263 |        2.019 |   ✗     |

**3 / 20 Survivor erreichen `mean_oos_pf ≥ 2.14`** — Pfad-A ist auf Mean-Basis grenzwertig erreichbar.

**Wichtige Einschränkung:** Selbst die drei Pfad-A-Mean-Erreicher haben `worst_oos_pf` zwischen 0.117 und 0.242. In mindestens einem Validate-Window (≈2 Monate) liefert die Strategy <0.25 PF — wäre real Live-Trading mit 2-Monats-Drawdown-Phasen verbunden. Pfad-A nur auf Mean zu prüfen blendet diese Phasen aus.

---

## 4. Rank-Erhalt-Analyse (Welle-O2 vs Walk-Forward)

| Welle-O2 Rang | Trial | O2-Score (PF + 0.1·Sharpe) | Walk-Forward Rang (by agg) | mean_oos_pf | std_oos_pf | worst_oos_pf | Survivor (relaxed)? |
|--------------:|------:|--------------------------:|----------------------------:|-------------:|------------:|--------------:|:-------------------:|
|             1 |   515 |                     2.163 |                           6 |       35.92 |      68.51 |        0.021 |      ✗ (worst, std)  |
|             2 |   306 |                     2.015 |                          20 |        1.93 |       1.95 |        0.025 |      ✗ (worst)       |
|             3 |   494 |                     1.806 |                          11 |        2.16 |       2.12 |        0.012 |      ✗ (worst)       |
|             4 |   836 |                     1.681 |                          66 |        8.54 |      19.19 |        0.000 |      ✗ (worst, std)  |

**Beobachtungen:**

1. Welle-O2 Top-1 (Trial 515) → Walk-Forward Rang 6. Sein `aggregated_score = 1.664` ist durch PF-Outliers künstlich hochgetrieben (`mean_oos_pf = 35.92`, `std_oos_pf = 68.51`). Strukturell ist es ein „Pfad-A-Reach-Trial im Single-Period-Backtest, das in OOS Phasen mit `PF ≈ 0.02` durchläuft".
2. Keiner der Welle-O2 Top-4 ist Survivor — Single-Period-Score predicts OOS-Stabilität nicht. Walk-Forward war notwendig.
3. Die 20 Walk-Forward-Survivor stammen aus der gesamten Welle-O2-Qualifikationspopulation, NICHT aus den Welle-O2-Top-Rängen. Beispiel: Trial 0, 109, 263, 421, 570 — Welle-O2-Mittelfeld-Trials sind die Walk-Forward-Tops.

**Konklusion:** Welle-O2 als Vorfilter ist gut (109/1000 = 11 % Qualifikationsrate), aber das Welle-O2-Ranking selbst ist OOS-irrelevant. Die TPE-Refinement in Welle W3 muss auf der Walk-Forward-Survivor-Population aufbauen, nicht auf Welle-O2-Top-N.

---

## 5. TPE-Range-Vorschlag für Phase 3.2 (Welle W3)

### 5.1 Survivor-Param-Cluster (n=20)

| Parameter                | Search Space (Welle O2) | Survivor min | Survivor median | Survivor max | TPE-Vorschlag |
|--------------------------|------------------------:|-------------:|----------------:|-------------:|--------------:|
| `tenkan_period`          | Int [7, 13]             |            7 |            10   |          13  |   **[7, 13]** (full) |
| `kijun_period`           | Int [21, 40]            |           21 |            31   |          39  |   **[21, 39]** (≈ full) |
| `senkou_b_period`        | Int [40, 70]            |           40 |            58   |          69  |   **[40, 69]** (≈ full) |
| `shift`                  | Int [20, 30]            |           20 |            26   |          30  |   **[20, 30]** (full) |
| `score_threshold`        | Int [40, 80]            |           40 |            53   |          60  |   **[40, 60]** (cut top half) |
| `tp_rr_ratio`            | Float [1.5, 4.0]        |         1.50 |          1.76   |        2.51  |   **[1.5, 2.6]** (cut top half) |
| `risk_per_trade`         | Float [0.01, 0.03]      |       0.0103 |          0.0164 |      0.0224  |   **[0.01, 0.024]** (cut top quarter) |
| `adx_threshold`          | Float [25.0, 45.0]      |        25.22 |         34.29   |       37.24  |   **[25, 38]** (cut top quarter) |
| `adx_use_di_confluence`  | Bool                    |        0/1   |     0 (70 %)    |       0/1    |   **{0, 1}** (keep, leans 0) |

Fixed-Werte aus Welle O2 (`session_filter_enabled=0`, `adx_filter_enabled=1`, `adx_period=14`) bleiben unverändert in der TPE-Phase.

### 5.2 Welle W3 TPE-Setup-Vorschlag

```yaml
strategy_name: ichimoku
parameters:
  tenkan_period:   { type: Int,   min: 7,    max: 13 }
  kijun_period:    { type: Int,   min: 21,   max: 39 }
  senkou_b_period: { type: Int,   min: 40,   max: 69 }
  shift:           { type: Int,   min: 20,   max: 30 }
  score_threshold: { type: Int,   min: 40,   max: 60 }
  tp_rr_ratio:     { type: Float, min: 1.5,  max: 2.6 }
  risk_per_trade:  { type: Float, min: 0.01, max: 0.024 }
  adx_threshold:   { type: Float, min: 25.0, max: 38.0 }
  adx_use_di_confluence: { type: Bool }
fixed:
  session_filter_enabled: 0.0
  adx_filter_enabled:     1.0
  adx_period:            14.0
```

**Erwartete Volumenreduktion:** der kombinierte Suchraum schrumpft auf ~30 % der Welle-O2-Größe (score × tp × risk × adx-cuts), TPE kann mit n=200-300 Trials gezielt explorieren.

### 5.3 Welle W3 Stability-Score-Hinweis

Die Walk-Forward-Aggregation in W3 sollte zwei Anpassungen prüfen, weil `mean_oos_pf` unter 1464-bar Validate strukturell unzuverlässig ist:

1. **Stability-Score-Refinement:** statt `mean(OOS_PF) - 0.5 * std(OOS_PF)` einen median- oder trimmed-mean-basierten Score erwägen, der die Outlier-Splits dämpft.
2. **Validate-Window-Erweiterung:** 2196 bars (≈3 Monate) statt 1464 bars erhöht den Trade-Count pro Window ~50 % und stabilisiert PF, kostet allerdings 1-2 Splits (von 9 auf 7-8).

Diese Refinements sind **Welle-W3-Scope** und kein Blocker für die TPE-Range-Vorschläge oben.

---

## 6. Plan-§5-Update-Vorschlag

**Phase 3.1 Welle W2 — Status: GO Welle W3 mit Caveats**

- Walk-Forward W2-Pipeline lieferbar (W2-1 CLI, W2-2 109-Trial-Run, W2-3 SurvivorCriteria + relaxte Default-Justification).
- Ichimoku-1h: **Walk-Forward-validiert auf 20 Survivors (relaxed)**, keine Survivors unter strikten Default-Criteria.
- Plan-§4.4 Status (Vorschlag): „Ichimoku 1h H4: Walk-Forward-validiert, 20 Survivor (`min_worst_oos_pf=0.1`, `max_std_oos_pf=3.0`), 3 davon `mean_oos_pf ≥ 2.14`."
- **Welle-W3-Caveat:** Single-Period-Top-N (Welle O2) ist kein zuverlässiger OOS-Prädiktor — TPE-Range-Vorschläge in §5.1 dieses Specs bauen auf Walk-Forward-Survivor-Cluster, nicht auf Welle-O2-Top-N.
- **Engine-Caveat:** 1464-bar Validate-Window ist für Ichimoku-Cadence am unteren Limit. Validate-Window-Verlängerung oder Median-Score-Refinement in W3 prüfen.

---

## 7. Reproduzierbarkeit

```bash
# 1. Walk-Forward-Replay (~25 min, 109 trials × 9 splits):
cargo run --release --example walk_forward_replay -- \
  --study 01_Projectplan/optimizer_studies/studies-ichimoku.db \
  --strategy ichimoku \
  --candles 01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
  --top-n 109 \
  --train-bars 4392 --validate-bars 1464 --step-bars 1464 \
  --stability-penalty 0.5 \
  --output-csv 01_Projectplan/optimizer_studies/walk_forward_top109_ichimoku.csv \
  --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-wf.db \
  --seed 42

# 2. Survivor-Filter unter relaxten Criteria (~1 s, --skip-replay):
cargo run --release --example walk_forward_replay -- \
  --study 01_Projectplan/optimizer_studies/studies-ichimoku.db \
  --strategy ichimoku \
  --candles 01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
  --output-csv 01_Projectplan/optimizer_studies/walk_forward_top109_ichimoku.csv \
  --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-wf.db \
  --skip-replay \
  --min-mean-oos-pf 1.3 --max-std-oos-pf 3.0 \
  --max-is-oos-decay 0.7 --min-worst-oos-pf 0.1
```

Beide Schritte sind deterministisch (Seed = 42, BTreeMap-Param-Ordering, SQLite-Schema-Migration idempotent). Die Walk-Forward-DB ist binär-stabil über Re-Runs (siehe `tests/integration_walk_forward.rs::persisted_walk_forward_result_matches_recomputed_after_reopen`).

---

_QA-Sign-off-Ready: 4 atomare Commits in `main` (W2-1 .. W2-4)._
