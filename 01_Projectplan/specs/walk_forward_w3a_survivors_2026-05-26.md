# Walk-Forward W3a Survivors — Ichimoku (Extended Validate + Median Score)

**Datum:** 2026-05-26
**Phase:** 3.1 — Welle W3a (Validate-Window-Erweiterung + Median-Stability)
**Source-Studie:** `production_ichimoku_n1000_seed42_2026-05-24` (Welle O2)
**Walk-Forward-DB:** `01_Projectplan/optimizer_studies/studies-ichimoku-wf-w3a.db`
**Walk-Forward-CSV:** `01_Projectplan/optimizer_studies/walk_forward_w3a_top109_ichimoku.csv`
**Walk-Forward-Konfig:** train=4392 bars (≈6 mo), validate=2196 bars (≈3 mo), step=2196 bars (no overlap), `StabilityScoreMethod = MedianIqr { iqr_penalty: 0.5 }`, 6 splits pro Trial
**Engine-Compute:** 13m24s, 7.4s/trial avg (W2 war 25m28s / 14.0s — 6 statt 9 splits)

---

## 1. Headline

- **2 / 109 Trials passen DEFAULT-`SurvivorCriteria`** (W2: 0 / 109). Erstes Mal, dass strict-defaults Survivors liefern.
- Survivors: Trial **688** (rank 6, agg=1.436) und Trial **36** (rank 53, agg=0.868). Beide auch in der W2-relaxed Survivor-Liste (688 = W2-rank 14).
- Bindende Gates W3a: `worst_oos_pf ≥ 0.6` → 105 / 109 fail (W2: 109 / 109); `std_oos_pf ≤ 1.0` → 80 / 109 fail (W2: 109 / 109).
- **Welle-O2 Top-1 (Trial 515) kollabiert: W2-rank 6 → W3a-rank 108.** `mean_oos = 25.69`, `std = 50.91`, `median ≪ mean` — MedianIqr identifiziert PF-Outlier-Trials korrekt als instabil. Bailey-de-Prado-Signal bestätigt.
- **Welle-W3a-Default-Survivor-Pool ablöst W2-Relaxed-Pool für TPE-Warm-Start** — Pool ist nur 2 Trials groß; siehe §4 für TPE-Warm-Start-Erweiterung mit W3a-Top-10.

---

## 2. Distribution (alle 109 Walk-Forward-Trials)

| Metric           |     min |     p10 |     p25 |     p50 |     p75 |     p90 |     max |
|------------------|--------:|--------:|--------:|--------:|--------:|--------:|--------:|
| `aggregated_score` (MedianIqr) | -42.046 |  0.071 |  0.481 |  0.836 |  1.097 |  1.302 |  1.810 |
| `mean_oos_pf`    |   1.243 |   1.455 |   1.624 |   2.098 |   2.905 |  20.770 | 169.101 |
| `std_oos_pf`     |   0.511 |   0.816 |   0.996 |   1.603 |   2.789 |  43.030 | 372.209 |
| `worst_oos_pf`   |   0.000 |   0.000 |   0.197 |   0.314 |   0.431 |   0.504 |   0.749 |
| `is_oos_decay`   | -166.13 |  -21.40 |   -1.03 |   -0.43 |   -0.23 |   -0.11 |    0.11 |

### 2.1 Verbesserung gegenüber W2

| Metric            |    W2 (1464, mean-std) |   W3a (2196, median-iqr) | Δ |
|-------------------|-----------------------:|-------------------------:|---|
| `mean_oos_pf` p50 |                  8.536 |                    2.098 | −75 % (Outlier-Dominanz weg) |
| `std_oos_pf` min  |                  1.138 |                    0.511 | −55 % |
| `std_oos_pf` p50  |                 19.194 |                    1.603 | −92 % |
| `worst_oos_pf` p75|                  0.222 |                    0.431 | +94 % |
| `worst_oos_pf` max|                  0.508 |                    0.749 | +47 % |

**Diagnostische Beobachtungen:**

1. **3-Monats-Validate stabilisiert PF radikal.** Median-Std drittelt sich auf 1.6, der unterhalbliegende Cap-Default (1.0) wird zumindest erreichbar (29 / 109 schaffen ihn, W2: 0).
2. **Worst-OOS-PF verbessert, bleibt aber bindend.** W2: 109 / 109 unter 0.6; W3a: 105 / 109 unter 0.6 — vier Trials klettern erstmals über die Schwelle (Worst-PF max wächst von 0.508 auf 0.749). Struktureller Constraint hält trotzdem.
3. **Median korrigiert Outlier-Inflation.** Mean-OOS-PF p90 = 20.77 zeigt: die Outlier-Trials sind noch da, die Aggregation gibt ihnen nur kein Gewicht mehr. Trial 515 ist das Lehrbuch-Beispiel (siehe §3).
4. **Decay flankiert das Pattern.** p25 = −1.03 heißt: für 75 % der Trials läuft die OOS-PF (rohe Mean) der IS-PF spürbar voraus → erneut Outlier-Artefakt. Median würde das nivellieren; W3a misst weiter Mean-Decay als diagnostische Größe, score-relevant ist es nicht mehr.

---

## 3. Welle-O2-Top-N → W3a Rank-Verschiebung

| Welle-O2 Rang | Trial | O2-Score | W2-Rank | **W3a-Rank** | W3a mean_oos | W3a std_oos | W3a worst_oos | Survivor? |
|--------------:|------:|---------:|--------:|-------------:|-------------:|------------:|--------------:|:---------:|
|             1 |   515 |    2.163 |       6 |      **108** |        25.69 |       50.91 |         0.575 |     ✗ (worst-grenze; agg=−1.74) |
|             2 |   306 |    2.015 |      20 |       58     |         2.84 |        2.60 |         0.624 |     ✗ (std) |
|             3 |   494 |    1.806 |      11 |       93     |        18.56 |       36.74 |         0.460 |     ✗ (std, worst) |
|             4 |   836 |    1.681 |      66 |       16     |        14.44 |       26.64 |         0.454 |     ✗ (std, worst; agg=1.23) |

**Konklusion:** Trial 515 war Welle-O2-Top-1, W2-Top-6 (durch PF-Inflation), W3a-Vorletzter (108). Trial 836 zeigt die Gegenrichtung: W2-Rank 66 (schlecht) → W3a-Rank 16 (gut), weil sein Median trotz Outlier-Mean=14.44 robust ist. MedianIqr re-ranked aggressiv in beide Richtungen — die Bailey-de-Prado-Hypothese „Single-Period-Ranking ist OOS-irrelevant" wird empirisch bestätigt. **Keiner der Welle-O2 Top-4 überlebt unter Default-Criteria** (worst-PF und/oder std-PF Caps).

---

## 4. W2-Relaxed-Top-10 → W3a-Verhalten

Cross-Method-Validation: bleiben die in W2-relaxed gefundenen Survivors auch unter W3a robust?

| W2-Relaxed Rang | Trial | W2 agg | **W3a Rank** | W3a agg | W3a mean_oos | W3a std_oos | W3a worst_oos | W3a Survivor? |
|----------------:|------:|-------:|-------------:|--------:|-------------:|------------:|--------------:|:-------------:|
|               1 |   570 |  1.114 |       29     |   1.088 |         1.56 |        0.73 |         0.291 |     ✗ (worst) |
|               2 |   739 |  1.081 |       95     |   0.216 |         1.46 |        1.00 |         0.440 |     ✗ (worst, std-grenze) |
|               3 |   109 |  1.028 |      101     |   0.025 |         2.86 |        2.28 |         0.487 |     ✗ (std, worst) |
|               4 |   343 |  1.016 |       31     |   1.080 |         1.83 |        1.11 |         0.316 |     ✗ (std, worst) |
|               5 |   777 |  0.972 |       41     |   0.990 |         1.63 |        1.04 |         0.209 |     ✗ (std, worst) |
|               6 |   387 |  0.967 |       68     |   0.712 |         2.26 |        1.90 |         0.504 |     ✗ (std, worst) |
|               7 |   778 |  0.955 |       12     |   1.302 |         1.87 |        1.01 |         0.257 |     ✗ (std-grenze, worst) |
|               8 |     0 |  0.933 |       34     |   1.044 |         1.60 |        0.79 |         0.440 |     ✗ (worst) |
|               9 |   402 |  0.931 |       85     |   0.412 |         1.42 |        0.86 |         0.465 |     ✗ (worst) |
|              10 |   445 |  0.918 |        9     |   1.340 |         2.70 |        2.79 |         0.593 |     ✗ (std, worst-grenze) |

**Beobachtungen:**

1. **5 / 10 W2-Relaxed-Top-Trials bleiben W3a-Top-50** (rank ≤ 50). Cross-Method-Stabilität ~50 %.
2. **2 / 10 bleiben W3a-Top-15** (Trial 445 → rank 9, Trial 778 → rank 12). Diese sind Hot-Candidates für TPE-Warm-Start, auch wenn sie keine W3a-Default-Survivors sind.
3. **Welle-W3a-Default-Survivors (688, 36) finden sich beide in W2-Relaxed-Top-20** (688 = W2-rank 14, 36 = W2-rank 11). Kein Survivor erscheint neu — die W3-Refinements eliminieren Falsch-Positive, fügen aber keine neuen Trials hinzu.

---

## 5. Survivor-Detail

### 5.1 Default-Criteria-Survivors (2 / 109)

| rank | trial | agg   | mean_oos | std_oos | worst_oos | mean_is | decay   |
|-----:|------:|------:|---------:|--------:|----------:|--------:|--------:|
|    6 |   688 | 1.436 |    2.070 |   0.960 |     0.666 |   1.704 | −0.367 |
|   53 |    36 | 0.868 |    1.430 |   0.542 |     0.749 |   1.348 | −0.082 |

**Param-Werte:**

| Param            | Trial 688 | Trial 36 | W2-Survivor-Range (n=20) | Anmerkung |
|------------------|----------:|---------:|-------------------------:|-----------|
| `tenkan_period`  |        12 |       12 |                    7..13 | Beide am oberen Rand |
| `kijun_period`   |        34 |       25 |                   21..39 | wide Spread |
| `senkou_b_period`|        69 |       54 |                   40..69 | wide Spread |
| `shift`          |        30 |       21 |                   20..30 | komplementär |
| `score_threshold`|        51 |       51 |                   40..60 | identisch (51) |
| `tp_rr_ratio`    |     1.533 |    2.829 |                1.50..2.51 | komplementär (low / high) |
| `risk_per_trade` |    0.0143 |   0.0106 |              0.010..0.022 | beide unteres Drittel |
| `adx_threshold`  |     36.98 |    28.92 |                  25..37  | komplementär |
| `adx_use_di_confluence` | 0  |        1 |                      0/1 | komplementär |

**Konklusion:** Nur 3 von 9 Parametern (tenkan, score_threshold, risk_per_trade) konvergieren zwischen den beiden Default-Survivors. TPE-Warm-Start auf nur 2 Trials wäre praktisch random — der Pool muss erweitert werden.

### 5.2 Relaxed-Survivor-Augmentation (für TPE-Warm-Start)

Vorschlag: TPE-Warm-Start nicht auf 2 Default-Survivors, sondern auf **W3a-Top-15 unter relaxierten Criteria** (`max_std_oos_pf=1.5`, `min_worst_oos_pf=0.3`). Begründung:

| Criterion           | Default | **Relaxed (W3a)** | Begründung |
|---------------------|--------:|------------------:|------------|
| `min_mean_oos_pf`   |     1.3 |             **1.3** | 108 / 109 bestehen, Floor passt. |
| `max_std_oos_pf`    |     1.0 |             **1.5** | Default-Cap durch 3-Monats-Validate erreicht (29 / 109), aber Pool zu klein für KDE. 1.5 cut bei p49 → mehr Diversität. |
| `max_is_oos_decay`  |     0.7 |             **0.7** | 109 / 109 bestehen. |
| `min_worst_oos_pf`  |     0.6 |             **0.3** | Default unerreichbar für 96 % (p75 = 0.43). 0.3 cut bei p47 → 50/50 diskriminativ. |

**Verifizierter Relaxed-Survivor-Pool (W3a):** 28 / 109 Trials. CLI-Aufruf:

```bash
cargo run --release --example walk_forward_replay -- \
  --study 01_Projectplan/optimizer_studies/studies-ichimoku.db \
  --strategy ichimoku \
  --candles 01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
  --output-csv 01_Projectplan/optimizer_studies/walk_forward_w3a_top109_ichimoku.csv \
  --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-wf-w3a.db \
  --skip-replay \
  --min-mean-oos-pf 1.3 --max-std-oos-pf 1.5 \
  --max-is-oos-decay 0.7 --min-worst-oos-pf 0.3
```

Diese Pool-Liste ist nicht in dieser Spec persistiert (CLI rechnet sie zur Laufzeit, deterministisch) — sie wird als Eingabe für `TpeEngine::warm_start` in Welle W3.5 (TPE-Production-Run) verwendet.

Per-Gate-Fail-Verteilung im 28-Trial-Pool (= warum 81 Trials ausgeschlossen sind):
- `mean_oos_pf < 1.30`:  1 / 109 (fast jeder Trial hat eine Mean-PF ≥ 1.3 — Floor passt)
- `std_oos_pf > 1.50`:  59 / 109 (PF-Volatilität bleibt das Haupthindernis)
- `worst_oos_pf < 0.30`: 50 / 109 (~ Hälfte hat mindestens eine PF-Phase unter 0.3)
- `is_oos_decay > 0.70`:  0 / 109 (Overfitting unkritisch unter W3a)

---

## 6. Plan-§4.4-Update-Vorschlag

**Phase 3.1 Welle W3a — Status: GO Welle W3.5 (TPE-Production-Run)**

- W3-1: `StabilityScoreMethod` + `compute_aggregated_score` (Median/IQR + Trimmed-Mean).
- W3-2: CLI `--stability-method` + `--trim-pct` Flags.
- W3-3: 109-Trial Re-Run unter 3-Monats-Validate + MedianIqr — 2 / 109 Default-Survivors.
- W3-4: diese Spec — Survivor-Liste + TPE-Warm-Start-Pool-Vorschlag.
- W3-5 (nächster Commit, **diese** Session): `TpeEngine` mit `warm_start`.

**Engine-Caveat (W3a-Reissue):** Worst-OOS-PF bleibt das bindende Constraint (105 / 109 fail Default). Selbst mit 3-Monats-Validate-Windows hat die Strategy mindestens in einem Window <0.6 PF-Phasen. Live-Trading muss dies in Risk-Management abbilden (max-drawdown Cap, regime-switch Detection).

**Welle-W3.5-Caveat:** TPE-Warm-Start auf nur 2 Default-Survivors ist KDE-degeneriert (n<5 → keine sinnvolle Bandwidth-Schätzung, Silverman fällt auf 0 zurück). Welle W3.5 muss den relaxed-28-Pool verwenden, sonst läuft TPE praktisch random.

---

## 7. Reproduzierbarkeit

```bash
# 1. W3a Walk-Forward-Replay (~13 min, 109 trials × 6 splits):
cargo run --release --example walk_forward_replay -- \
  --study 01_Projectplan/optimizer_studies/studies-ichimoku.db \
  --strategy ichimoku \
  --candles 01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
  --top-n 109 \
  --train-bars 4392 --validate-bars 2196 --step-bars 2196 \
  --stability-method median --stability-penalty 0.5 \
  --output-csv 01_Projectplan/optimizer_studies/walk_forward_w3a_top109_ichimoku.csv \
  --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-wf-w3a.db \
  --seed 42

# 2. Survivor-Filter unter Default-Criteria (~1 s, --skip-replay):
cargo run --release --example walk_forward_replay -- \
  --study 01_Projectplan/optimizer_studies/studies-ichimoku.db \
  --strategy ichimoku \
  --candles 01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
  --output-csv 01_Projectplan/optimizer_studies/walk_forward_w3a_top109_ichimoku.csv \
  --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-wf-w3a.db \
  --skip-replay
```

Beide Schritte sind deterministisch (Seed = 42, BTreeMap-Param-Ordering, SQLite-Schema-Migration idempotent, `StabilityScoreMethod` serde-roundtrip pinned).

---

_QA-Sign-off-Ready: 4 atomare W3-Commits in `main` (W3-1, W3-2, W3-3, W3-4). W3-5 (TPE-Engine) folgt im nächsten Commit derselben Session._
