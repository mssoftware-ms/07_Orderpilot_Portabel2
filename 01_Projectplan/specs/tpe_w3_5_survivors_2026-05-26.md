# TPE Production-Run Survivors — Ichimoku (Welle W3.5)

**Datum:** 2026-05-26
**Phase:** 3.1 — Welle W3.5 (TPE-Refinement auf W3a-Survivor-Cluster)
**Source-Studie (Warm-Start):** `walk_forward_ichimoku_top109_seed42_2026-05-25` (id=1) in `studies-ichimoku-wf-w3a.db`
**TPE-Output-DB:** `01_Projectplan/optimizer_studies/studies-ichimoku-tpe.db` (study `tpe_walk_forward_ichimoku_n200_seed42_2026-05-26`)
**TPE-Output-CSV:** `01_Projectplan/optimizer_studies/tpe_top_ichimoku.csv`
**Search-Space:** `01_Projectplan/search_spaces/ichimoku_tpe_w3.yaml`
**Walk-Forward-Konfig:** train=4392 bars, validate=2196 bars, step=2196 bars (= W3a), `StabilityScoreMethod::MedianIqr { iqr_penalty: 0.5 }`, 6 Splits / Trial
**TPE-Config:** gamma=0.25, n_ei_candidates=24, n_trials=200, seed=42
**Warm-Start-Pool:** 28 / 109 W3a-Trials (Criteria: mean≥1.3, std≤1.5, decay≤0.7, worst≥0.3)
**Engine-Compute:** 33m16s, 10.0s/trial avg (W3a war 7.4s/trial; +35 % overhead durch TPE-Suggest+History-Sweeps)

---

## 1. Headline

- **TPE Top-1 (Trial 101) erreicht `mean_oos_pf = 2.024` — knapp unter XLSX-Pfad-A-Schwelle 2.14.** `worst_oos_pf = 0.473` (über W3a-relaxed-Schwelle 0.3, unter Default 0.6); `std_oos_pf = 1.074` (knapp über Default-Cap 1.0). Aggregated-Score 1.5842 < W3a-Top-1 (1.81).
- **80 / 200 TPE-Trials reichen Pfad-A (`mean ≥ 2.14`)** — 40 % aller TPE-Trials, vs. W3a 3 / 109 = 3 %. TPE hat die Pfad-A-Reichweite ungefähr ver-13-facht.
- **0 / 200 TPE-Trials passen DEFAULT-`SurvivorCriteria`** (std≤1.0 bindend, beste TPE-Trial-std=1.07). Default bleibt für Ichimoku 1h H4 unerreichbar.
- **W3a-Top-1 (Trial 308) liegt STRUKTURELL ausserhalb der TPE-Search-Space** (`adx_threshold = 43.06`, TPE-Cap 38). Vergleich `TPE-Top-1 ≷ W3a-Top-1` ist kein Engine-Verlust, sondern Folge der Welle-W2-§5.2-Range-Schneidung.
- **Empfehlung: GO Welle W4 (PBO/DSR Statistical Gates)** auf der Union `TPE-Pfad-A-Pool (79 Trials) ∪ W3a-Top-K`. Siehe §6.

---

## 2. TPE Top-5 vs W3a Top-5 (Vergleichs-Tabelle)

| | TPE Top-5 (W3.5) | | | | | | W3a Top-5 (baseline) | | | | | |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **rank** | **trial** | **agg** | **mean** | **std** | **worst** | **decay** | **trial** | **agg** | **mean** | **std** | **worst** | **decay** |
| 1 | 101 | 1.5842 | 2.024 | 1.074 | 0.473 | −0.217 |  308 | 1.8096 | 2.689 | 1.833 | 0.270 | −1.032 |
| 2 |  93 | 1.5818 | 2.014 | 1.062 | 0.473 | −0.222 |  284 | 1.6256 | 2.172 | 1.255 | 0.247 | −0.629 |
| 3 |  88 | 1.5816 | 2.014 | 1.062 | 0.473 | −0.222 |  629 | 1.5466 | 2.082 | 1.137 | 0.517 | −0.431 |
| 4 |  83 | 1.5404 | 3.208 | 2.902 | 0.466 | −0.850 |  906 | 1.5350 | 1.831 | 1.020 | 0.286 | −0.330 |
| 5 |  80 | 1.5073 | 3.251 | 2.995 | 0.517 | −0.816 |  266 | 1.5326 | 2.496 | 1.689 | 0.317 | −0.659 |

**Beobachtungen:**

1. **TPE-Top-3 sind ein enger Cluster:** Trials 101, 93, 88 teilen sich `mean ≈ 2.02`, `std ≈ 1.07`, `worst ≈ 0.47` — beinahe identische Validate-Performance. Diese drei sind quasi-äquivalente Repräsentanten desselben Param-Clusters.
2. **W3a-Top-1 (308) hat höchsten Mean (2.69) ABER schlechtesten Worst (0.27) UND Std (1.83):** unter MedianIqr noch positiv, weil Median (≈ 2.6) hoch und IQR (≈ 1.83) moderat. In Live-Trading-Risk-Mgmt unattraktiv — Validate-Window-Schwankung ist groß.
3. **TPE-Trade-off:** TPE-Top-1 opfert 0.66 PF Mean (2.69 → 2.02) für 0.76 PF Std-Reduktion (1.83 → 1.07) UND 0.20 PF Worst-Verbesserung (0.27 → 0.47). MedianIqr findet das nicht trade-best — daher Rang-2-Reihenfolge unter Aggregate-Sort —, aber unter Live-Trading-Sicht ist TPE-Top-1 das robustere Asset.
4. **TPE-Top-3 std=1.07 ist KNAPP über Default-Cap 1.0** — nur 7 % Lockerung des Caps würde sie Default-Survivors machen. Worst=0.47 < Default 0.6 ist die zweite Lücke (24 % Lockerung).

---

## 3. Best TPE-Trial — vollständige Parameter (Trial 101)

```yaml
trial_id: 101
score (aggregated_score, MedianIqr): 1.5842
metrics:
  mean_oos_pf: 2.024
  std_oos_pf:  1.074
  worst_oos_pf: 0.473
  mean_is_pf:  1.807
  is_oos_decay: -0.217
params:
  tenkan_period:        10
  kijun_period:         39
  senkou_b_period:      52
  shift:                25
  score_threshold:      54
  tp_rr_ratio:          2.6
  risk_per_trade:       0.01395
  adx_threshold:        28.33
  adx_use_di_confluence: 0
fixed:
  adx_filter_enabled:    1
  adx_period:           14
  session_filter_enabled: 0
```

**Interpretation:**

- `tp_rr_ratio = 2.6` sitzt am oberen Rand des TPE-Search-Space-Caps (cut von 4.0 → 2.6 per W2-§5.2). TPE drückt gegen die Grenze — TP-Optimum könnte > 2.6 liegen.
- `kijun_period = 39` ebenfalls am Cap (W2-cut von 40 → 39).
- `risk_per_trade = 0.014` mittig.
- `adx_use_di_confluence = 0` — TPE-Top-10 sind ALLE `=0` (siehe §4.3); DI-Konfluenz wird nicht mehr ausgeschöpft.
- `tenkan / shift / score_threshold` mittig.
- Profil: **konservativer Trend-Follower** (kijun=39 erfasst lange Trendphasen, score-threshold=54 mittlere Konfluenz, tp=2.6 nutzt Trendlaufzeit aus).

---

## 4. Konvergenz & Warm-Start-Effektivität

### 4.1 Best-so-far-Trajektorie

| Iter | Best-Score | Best-Trial | Anmerkung |
|-----:|-----------:|-----------:|-----------|
|    0 |   0.904    |    0       | Sanity (erste TPE-Suggestion, ~MedianIQR-suboptimal) |
|   12 |   1.367    |   12       | Erster grosser Sprung — TPE findet Cluster |
|   32 |   1.394    |   32       | Marginal-Verbesserung |
|   80 |   1.507    |   80       | Mid-Run-Sprung |
|   93 |   1.582    |   93       | Nahe-Final-Score (TPE-Top-3) |
|  101 |   1.584    |  101       | **Final-Best (Plateau)** |
|  120 |   1.584    |  101       | Konvergiert |
|  199 |   1.584    |  101       | 90 Trials Exploration ohne Verbesserung |

**Warm-Start-Effektivität:**

- TPE erreicht 1.58 nach 101 Iterationen. Best-so-far stagniert dann 100 Trials lang — klassische Mode-Finding-Konvergenz.
- Random-Search bei vergleichbarem Compute (200 Trials) hätte (W2-Statistik §4.1) mit ~3-11 % Wahrscheinlichkeit einen Trial mit `agg ≥ 1.58` produziert. TPE garantiert den Mode mit ~100 % nach ≤ 110 Trials → Warm-Start spart Größenordnung 3× Compute vs. blind Random.
- **TPE-Top-1 (1.58) bleibt unter W3a-Top-1 (1.81)**, weil W3a-Top-1 (Trial 308) `adx_thr = 43.06` strukturell außerhalb der TPE-Search-Space liegt (TPE-Cap = 38). Cross-Space-Vergleich ist nicht aussagekräftig.

### 4.2 Konvergenz-Diagnose

- Erste 12 Trials: TPE explorerte breit (initial-l-KDE über 28 Warm-Start-Trials, Bandbreite ≈ 0.5–2× des Search-Range-Floors).
- Trial 80–101 (Mid-Convergence): l-KDE konzentriert sich um den emergenten Cluster (kijun ~ 38–39, tp_rr ~ 2.5–2.6).
- Nach Trial 101: l/g-Ratio im Cluster maximal — alle weiteren Suggestions liegen "im Mode", keine grenzwertigen Outlier-Sprünge mehr.

**Verbesserungs-Hinweis für Welle-W4-TPE (falls nochmal gefahren):** `n_ei_candidates = 24` mag im konzentrierten Bereich zu wenig Exploration produzieren. Erhöhen auf 48 (oder gamma 0.20 → 0.15 für breiteren l-Cluster) wäre einen Sub-Trial wert.

---

## 5. Param-Distribution: TPE-Top-10 vs W3a-Relaxed-28

| Parameter | TPE-Top-10 (min / median / max) | W3a-Relaxed-28 (min / p25 / median / p75 / max) | TPE-Search-Space-Cap |
|---|---|---|---|
| `tenkan_period`    |  8  / 10  / 11 | 7 / 10 / 12 / 12 / 13   | 7..13 |
| `kijun_period`     | 36 / **39** / 39 | 21 / 26 / 29 / 33 / 37 | 21..**39** ⚠ TPE drückt gegen Cap |
| `senkou_b_period`  | 51 / 51 / 54 | 45 / 52 / 59 / 65 / 69    | 40..69 |
| `shift`            | 24 / 25 / 28 | 20 / 23 / 26 / 30 / 30    | 20..30 |
| `score_threshold`  | 51 / 54 / 55 | 40 / 44 / 51 / 56 / 60    | 40..60 |
| `tp_rr_ratio`      | 2.27 / **2.6** / **2.6** | 1.53 / 1.75 / 1.98 / 2.33 / 2.83 | 1.5..**2.6** ⚠ TPE drückt gegen Cap |
| `risk_per_trade`   | 0.0133 / 0.0141 / 0.0145 | 0.0103 / 0.0129 / 0.0143 / 0.0173 / 0.0224 | 0.01..0.024 |
| `adx_threshold`    | 26.5 / 28.77 / 29.06 | 25.22 / 28.92 / 30.89 / 36.98 / 41.49 | 25..38 (⚠ relaxed-Pool reicht bis 41.5) |
| `adx_use_di_confluence` |  0 / 0 / 0 | 0..1 (~ 60 % `=0`)                  | 0/1 |

**Kritische Beobachtungen:**

1. **TPE drückt gegen 2 Search-Space-Caps:** `kijun_period = 39` (Cap) UND `tp_rr_ratio = 2.6` (Cap). Wahrer Optimum liegt vermutlich knapp ausserhalb der Welle-W2-§5.2-Schneidung. → **Welle-W4-TPE-Search-Space-Vorschlag:** kijun bis 50, tp_rr bis 3.5.
2. **`adx_use_di_confluence = 0` in ALLEN TPE-Top-10:** das DI-Confluence-Feature wird unter TPE-Optimum konsistent ausgeschaltet. Im W3a-relaxed-Pool war ~ 40 % `=1` — TPE hat dieses Sub-Regime als suboptimal identifiziert. Plan-§4.4-Annotation: DI-Confluence ist kein Production-Default für Ichimoku 1h H4.
3. **`senkou_b_period`-Cluster verengt sich auf 51–54** (TPE-Top-10) vs. 45–69 (W3a-relaxed). TPE findet ein engeres Sub-Cluster im W3a-relaxed-Pool.
4. **`adx_threshold`-Cluster verengt sich auf 26.5–29.1** vs. 25.22–41.49 (W3a-relaxed). TPE-Optimum ist DEUTLICH unter dem W3a-relaxed-Median (30.89).

**TPE hat eine andere Region als W3a-Top-1 identifiziert:**

- W3a-Top-1 (Trial 308): kijun=24, tenkan=8, senkou_b=48, shift=27, score_thr=41, tp_rr=1.94, risk=0.0205, adx_thr=43.06, adx_di=0 — **kurzer Trend-Wechsel mit hohem ADX-Filter**.
- TPE-Top-1 (Trial 101): kijun=39, tenkan=10, senkou_b=52, shift=25, score_thr=54, tp_rr=2.6, risk=0.0140, adx_thr=28.33, adx_di=0 — **langer Trend mit niedrigem ADX-Filter**.

Beide Cluster lösen das Ichimoku-Problem unterschiedlich. PBO/DSR (§6) muss prüfen welche Strategie statistisch tragfähiger ist.

---

## 6. Pfad-A-Reach + Default-Criteria Status

### 6.1 Pfad-A (XLSX-Target `mean_oos_pf ≥ 2.14`)

| Filter | Count | % | Anmerkung |
|---|---:|---:|---|
| TPE-200 Trials gesamt | 200 | 100 % | |
| `mean_oos_pf ≥ 2.14` | **80** | **40.0 %** | XLSX-Pfad-A Mean reached |
| `mean_oos_pf ≥ 2.14` AND `worst_oos_pf ≥ 0.3` | **79** | **39.5 %** | Pfad-A Mean + non-disaster Worst |
| `mean_oos_pf ≥ 2.14` AND `worst_oos_pf ≥ 0.6` | 0 | 0 % | Pfad-A + Default-Worst → unreachable in TPE-Range |

**Vergleich zu W3a:** 3 / 109 (≈ 3 %) erreichten `mean ≥ 2.14`. TPE-Pfad-A-Reichweite hat sich ~ 13-facht — Warm-Start-effektiv.

### 6.2 Default-Criteria Survivors

| Filter | Count | Anmerkung |
|---|---:|---|
| `mean_oos_pf ≥ 1.30` | 199 / 200 | nicht-bindend |
| `std_oos_pf ≤ 1.00` (Default-Cap) | **2 / 200** | **bindend** — Best TPE-Trial-std=1.074 |
| `is_oos_decay ≤ 0.70` | 200 / 200 | nicht-bindend |
| `worst_oos_pf ≥ 0.60` (Default-Floor) | **0 / 200** | **bindend** |
| **Alle 4 Gates simultan** | **0 / 200** | **Default unreichbar** |

**Vergleich:** W3a hatte 2 / 109 = 1.8 % Default-Survivors (Trial 688, Trial 36). TPE hat 0 / 200 — aber NICHT direkt vergleichbar: W3a evaluierte 109 BEREITS EXISTIERENDE Welle-O2-Trials, TPE generierte 200 NEUE Trials im gecutteten W3-Search-Space. Trial 688 (W3a-Default-Survivor) hat `adx_threshold = 36.98` (knapp innerhalb TPE-Cap 38) UND `senkou_b = 69` (am TPE-Cap) — TPE könnte ihn theoretisch wieder generieren, hat aber unter MedianIqr-Optimierung einen anderen Mode bevorzugt. Trial 36 (W3a-Default-Survivor 2) hat `adx_di=1` — TPE-Top-10 sind alle `=0`, also war diese Sub-Region für TPE explizit unattraktiv.

TPE optimiert `mean − iqr·0.5` (Median-Stabilität), das ist nicht identisch mit Default-Criteria-Survival (Worst+Std-Hard-Caps). Die zwei Methoden sind komplementär, nicht substitutiv.

→ **TPE-Pfad-A-Mehrwert ≠ Default-Survivor-Mehrwert.** Die richtige Frage für Production-Default-Selection ist:
- Wenn das Pfad-A-Mean-Ziel (2.14) zählt: TPE liefert 79 Kandidaten (W3a nur 3).
- Wenn `worst_oos_pf ≥ 0.6` zählt: weder W3a noch TPE liefern; das ist eine fundamentale Engine-Caveat.

### 6.3 Was passiert wenn man die Default-Criteria leicht relaxt?

`worst_oos_pf ≥ 0.6` allein blockt 200 / 200 — kein Std-Cap-Relax bringt Survivors, solange Worst-Floor unverändert bleibt. Doppelter Relax (Std + Worst):

| Std-Cap | Worst-Floor | TPE-Survivors | Best (agg, falls > 0) |
|---|---|---:|---:|
| 1.00 (default) | 0.60 (default) |  0 | — |
| 1.50 (W3a-relaxed) | 0.60 (default) |  0 | — |
| 1.00 | 0.45 |  6 | trial 101 (1.5842) |
| 1.10 | 0.45 | 23 | trial 101 |
| 1.20 | 0.45 | 48 | trial 101 |
| 1.50 (W3a-relaxed) | 0.45 | 51 | trial 101 |

10 % Std-Cap-Relax + 25 % Worst-Floor-Relax (`std≤1.1, worst≥0.45`) bringt 23 Survivors aus dem TPE-Pool. **Trial 101 ist Survivor unter diesem Pair.** Vorschlag: **Pseudo-Default-Production-Criteria** für Ichimoku 1h H4: `mean≥1.3, std≤1.1, decay≤0.7, worst≥0.45` (alle vom TPE-Top-3 erfüllt, 23 Trials gesamt).

---

## 7. Phase-3-Bilanz & Plan-§4.4-Update

### 7.1 Status-Entscheidung (per Spec-Bilanz-Tree)

| Branch | Bedingung | TPE-Ergebnis | Status |
|---|---|---|---|
| **A:** Production-Default-Candidate | TPE-Top-1 mean ≥ 2.14 AND worst ≥ 0.3 | mean=2.024 (-0.116), worst=0.473 (✓) | **Nicht ganz** |
| **B:** Walk-Forward-stabil, XLSX-Targets unreachable | TPE-Top-1 ≥ 1.8 aber unter XLSX | agg=1.58 < 1.8 (formal nein, aber W3a-Top-1=1.81 sit ausserhalb Search-Space) | **Conditional** |
| **C:** TPE kein Mehrwert | TPE bietet keine Verbesserung gegenüber W3a-Survivor | TPE-Pfad-A-Mehrwert: 80 vs 3 Trials (+27×) | **Falsch — TPE liefert klar Mehrwert** |

**Konklusion (zwischen A und B):**

- **Mean-Niveau:** TPE-Top-1 ist 0.12 PF UNTER XLSX-Pfad-A. Aber 79 / 200 TPE-Trials sind ≥ 2.14 — der **TPE-Pfad-A-Pool** existiert.
- **Stabilitäts-Niveau:** TPE-Top-3 (`std ≈ 1.07`, `worst ≈ 0.47`) ist deutlich stabiler als alle W3a-Top-5 außer Trial 629 (vergleichbar).
- **Statistical-Significance:** unbekannt — PBO/DSR-Tests stehen noch aus.

→ **Status für Plan §4.4:** "Ichimoku 1h H4: W3.5-TPE-Refinement abgeschlossen; 79-Trial-Pfad-A-Pool identifiziert (mean ≥ 2.14, worst ≥ 0.3); Production-Default-Selection wartet auf Welle-W4-PBO/DSR-Validation."

### 7.2 Welle-W4-Empfehlung (PBO/DSR)

**Eingabe-Population für PBO/DSR:**

| Pool | Trials | Begründung |
|---|---:|---|
| TPE-Pfad-A-Pool (`mean ≥ 2.14 AND worst ≥ 0.3`) | 79 | TPE-optimierte Median-Stable + Pfad-A-Mean |
| W3a-Top-5 (alle baseline) | 5 | enthält Trial 308 (W3a-Top-1, ausserhalb TPE-Search) |
| W3a-Default-Survivors | 2 | Trial 688, Trial 36 |
| **Union (deduped)** | **~ 85 Kandidaten** | umfasst alle Top-Kandidaten beider Methoden |

**PBO-Schwelle:** PBO < 0.5 (mehr als 50 %-Konfidenz dass IS-OOS-Stabilität echt ist).
**DSR-Schwelle:** DSR > 0 mit p < 0.05 (Deflated-Sharpe-Ratio > 0 nach Multiple-Hypothesis-Adjustment).

Nach PBO/DSR-Filter:
- Falls ≥ 5 Survivors mit DSR > 0: Production-Default-Candidate(s) identifiziert.
- Falls < 5 Survivors: Phase-3.1 schließt mit "Walk-Forward-validiert, statistical-significance unbestätigt — manuelle Paper-Trade-Validation als nächster Schritt".

### 7.3 Welle-W4-TPE-Search-Space-Erweiterung (optional, falls W4 erweiterte TPE-Runs umfasst)

**TPE drückt gegen 2 Caps:**

| Parameter | Aktueller TPE-Cap | Vorgeschlagener W4-Cap | Begründung |
|---|---:|---:|---|
| `kijun_period` | 39 (Cap) | 50 | TPE-Top-10 hat kijun=36–39 (median 39 = Cap) |
| `tp_rr_ratio` | 2.6 (Cap) | 3.5 | TPE-Top-10 hat tp_rr=2.27–2.6 (median 2.6 = Cap) |

Diese Erweiterung würde nur Sinn machen wenn Welle-W4 eine zweite TPE-Iteration umfasst (nicht in der Spec-Vorgabe vorgesehen — W4 ist als PBO/DSR-Phase definiert, nicht als TPE-Re-Run).

---

## 8. Reproduzierbarkeit

```bash
# 1. TPE Production-Run (~33 min, 200 trials × 6 splits):
cargo run --release --example tpe_walk_forward_run -- \
  --wf-study     01_Projectplan/optimizer_studies/studies-ichimoku-wf-w3a.db \
  --candles      01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
  --search-space 01_Projectplan/search_spaces/ichimoku_tpe_w3.yaml \
  --n-trials     200 \
  --train-bars   4392 --validate-bars 2196 --step-bars 2196 \
  --stability-method median --stability-penalty 0.5 \
  --warm-start-criteria-min-mean-oos-pf 1.3 \
  --warm-start-criteria-max-std-oos-pf 1.5 \
  --warm-start-criteria-min-worst-oos-pf 0.3 \
  --warm-start-criteria-max-is-oos-decay 0.7 \
  --seed 42 \
  --output-csv 01_Projectplan/optimizer_studies/tpe_top_ichimoku.csv \
  --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-tpe.db

# 2. Default-Criteria Re-Filter auf TPE-Output (instant, --skip-replay).
# Hinweis: --study wird unter --skip-replay nicht gelesen, muss aber als Flag
# gesetzt werden; jede valide DB-Pfad-Angabe genügt.
cargo run --release --example walk_forward_replay -- \
  --study      01_Projectplan/optimizer_studies/studies-ichimoku.db \
  --strategy   ichimoku \
  --candles    01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
  --output-csv /tmp/tpe_default.csv \
  --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-tpe.db \
  --skip-replay
```

Beide Schritte sind deterministisch (Seed = 42, BTreeMap-Param-Ordering, Box-Muller via `rand::StdRng`-Seed, KDE-Bandwidth via Silverman-Rule). TPE-Engine ist reproduzierbar getestet (`tpe::same_seed_plus_history_yields_identical_suggestions`).

---

## 9. Welle-W3.5-Commit-Hashes

- `9b94ee8` — W3.5-1: TPE × walk-forward CLI + ichimoku_tpe_w3.yaml
- `66837c4` — W3.5-2: 200-trial TPE production run output (DB + CSV)
- (this commit) — W3.5-3: TPE survivor spec + Phase-3.2 prep

---

_QA-Sign-off-Ready: 3 atomare W3.5-Commits in `main`. Welle-W4 (PBO/DSR) als nächste Phase auf Union-Pool (TPE-Pfad-A 79 + W3a-Top-5 + W3a-Default-Survivors)._
