# Phase-3.1 Welle W4 — PBO + DSR statistical-gates results

Datum: 2026-05-26
Branch: `main` · Commit-Range: `d5f7167..HEAD`
Compute: ~3s (PBO + DSR sind closed-form; kein Backtest-Lauf)
Tool: `cargo run --release --example stat_gates_run`

## 1. Zusammenfassung

Der Union-Pool aus Welle-W3a-Survivors und der Welle-W3.5-TPE-Production
besteht aus **86 Trials** (79 TPE-Pfad-A + 7 W3a forced-include). Beide
statistischen Gates schlagen extreme Warnsignale:

- **Pool-PBO = 1.0000** — jede der 20 CSCV-Partitionen produziert einen
  Best-IS-Trial, der im OOS-Pendant unter den Median rutscht. `Weak`.
- **DSR-Verteilung**: 0 robust (>0.95), 0 marginal (0.70-0.95), **86
  weak (<0.70)**. Top-1-DSR = **0.207** (Trial 688 W3a).

Damit **scheitert die Pfad-A-Reach-Hypothese der Welle-W3.5** an beiden
unabhängigen Multiple-Testing-Korrekturen. Kein Trial qualifiziert sich
als Production-Default-Kandidat.

**Empfehlung**: Phase-3.1 ohne Production-Pick schließen, Walk-Forward
Validation und PBO/DSR-Resultate als Phase-Output dokumentieren. Welle
W4.5 (erweiterte TPE-Caps) wäre nur sinnvoll, falls QA zusätzlich
glaubt, dass die Caps strukturell die Stabilität der Trials einschränkt
— die PBO=1.0-Diagnose deutet aber auf ein methodisches statt
parametrisches Problem hin.

## 2. Workflow

```bash
cargo run --release --example stat_gates_run -- \
  --tpe-db   01_Projectplan/optimizer_studies/studies-ichimoku-tpe.db \
  --w3a-db   01_Projectplan/optimizer_studies/studies-ichimoku-wf-w3a.db \
  --candles  01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
  --output-csv 01_Projectplan/optimizer_studies/stat_gates_union_pool.csv \
  --output-db  01_Projectplan/optimizer_studies/stat_gates_results.db \
  --seed 42
```

Konfiguration:

| Parameter | Wert | Quelle |
|-----------|------|--------|
| Pfad-A Floor `mean_oos_pf` | ≥ 2.14 | W3.5-Reach |
| Pfad-A Floor `worst_oos_pf` | ≥ 0.30 | W3.5-Reach |
| W3a Top-N | 5 (308, 284, 629, 906, 266) | W4-Plan |
| W3a Default-Survivors | 2 (688, 36) | `SurvivorCriteria::default()` |
| CSCV `n_splits_per_side` | 3 (= n_splits/2) | Bailey-de-Prado |
| DSR sample size | n_splits = 6 | Walk-Forward OOS |

## 3. Pool-Zusammensetzung

| Source | Trials | Selektor |
|--------|-------:|----------|
| TPE Pfad-A | 79 | mean_oos_pf ≥ 2.14 AND worst_oos_pf ≥ 0.30 |
| W3a Top-5 | 5 | argmax(aggregated_score) |
| W3a Default-Survivors | 2 | `SurvivorCriteria::default()` |
| Union (dedupe) | **86** | (source_db, trial_id) |

Dedupe-Ergebnis: keine Kollisionen zwischen W3a-Top-5 {308, 284, 629,
906, 266} und W3a-Default-Survivors {688, 36}, keine Cross-DB-
Kollisionen (TPE und W3a haben disjunkte Parameter-Räume; identische
`trial_id`-Werte sind unterschiedliche Trials und beide bleiben im
Pool).

## 4. PBO — Probability of Backtest Overfitting

### 4.1 Resultat

```
Pool-PBO    = 1.0000   (n_combinations = 20)
Robustness  = Weak     (Schwelle ≥ 0.7)
Logit-Mean  ≈ −5.4    (alle 20 Partitionen logit < 0)
```

Bei `n_splits = 6` und `n_splits_per_side = 3` ergibt `C(6, 3) = 20`
CSCV-Partitionen. Auf **jeder einzelnen** dieser 20 Partitionen rutscht
der IS-Best-Trial im OOS-Subset unter den Median des 86-Trial-Pools.

### 4.2 Interpretation

PBO = 1.0 ist das maximale Overfitting-Signal des CSCV-Verfahrens.
Es bedeutet:

- Es existiert **kein** Trial, der konsistent über verschiedene
  Split-Kombinationen hinweg dominiert.
- Welcher Trial die IS-Best-Position einnimmt, ist nahezu vollständig
  davon abhängig, welche 3 Splits zufällig in der IS-Test-Hälfte
  landen — der Pool ist von Selection-Noise dominiert.
- Das Konvention-Verdict `PBO < 0.5 = robust` ist um den Faktor 2
  verfehlt; auch eine deutliche Relaxierung der Stability-Gates würde
  die strukturelle Diagnose nicht ändern.

Per Welle-W4-Plan §"ESKALATIONS-STOPP wenn":
> PBO > 0.9 (extreme overfitting): nicht direkt Stopp, aber sehr
> starker Hinweis dass die ganze Phase-3.1-Methodik unrettbar ist

Dieser Hinweis ist hier **gegeben**.

## 5. DSR — Deflated Sharpe Ratio

### 5.1 Pool-Statistik

```
E[max SR_n | N = 86, H0]   = 2.477
DSR-Verteilung   : 0 robust (>0.95)
                  0 marginal (0.70..0.95)
                 86 weak (<0.70)
DSR-Range        : [0.0001, 0.2067]
DSR-Mean         : 0.0373
```

E[max] = 2.477 bedeutet: unter der Nullhypothese (keine echte
Skill-Differenz, 86 IID-Trials) erwarten wir den Maximum-Sharpe bei
ca. 2.48. Selbst der beste beobachtete `mean_oos_sharpe` = 1.87 (Trial
688) liegt **unter** diesem Wert — daher Z* < 0 und DSR < 0.5 für
alle Trials.

### 5.2 Top-10 nach DSR

| Rank | Source | Trial | mean_oos_pf | std_oos_pf | worst_oos_pf | mean_oos_sharpe | Sample-Skew | Sample-Kurt | DSR | Z* | Robust |
|----:|:-------|----:|------------:|-----------:|-------------:|----------------:|------------:|------------:|----:|---:|:-------|
| 1 | w3a | **688** | 2.0705 | 0.960 | 0.666 | 1.8689 | −0.467 | 2.020 | **0.2067** | −0.818 | weak |
| 2 | w3a | 266 | 2.4957 | 1.689 | 0.317 | 1.6779 | −0.763 | 2.218 | 0.1565 | −1.009 | weak |
| 3 | tpe | 80 | 3.2511 | 2.995 | 0.517 | 1.7181 | −0.372 | 2.104 | 0.1393 | −1.084 | weak |
| 4 | tpe | 83 | 3.2075 | 2.902 | 0.466 | 1.6782 | −0.493 | 2.187 | 0.1369 | −1.095 | weak |
| 5 | tpe | 82 | 3.1025 | 2.968 | 0.515 | 1.6148 | −0.289 | 2.143 | 0.0974 | −1.296 | weak |
| 6 | w3a | 629 | 2.0824 | 1.137 | 0.517 | 1.5383 | −0.503 | 1.508 | 0.0725 | −1.457 | weak |
| 7 | tpe | 23  | 18.5026* | 37.396 | 0.541 | 1.5213 | −0.251 | 2.118 | 0.0667 | −1.501 | weak |
| 8 | w3a | 284 | 2.1717 | 1.255 | 0.247 | 1.2344 | −1.058 | 2.751 | 0.0535 | −1.611 | weak |
| 9 | tpe | 137 | 2.3881 | 1.588 | 0.417 | 1.1880 | −1.126 | 2.712 | 0.0464 | −1.681 | weak |
| 10 | tpe | 121 | 2.3585 | 1.567 | 0.417 | 1.1725 | −1.152 | 2.738 | 0.0447 | −1.699 | weak |

\* Trial 23 (TPE) ist ein PF-Outlier: ein einzelner Validate-Split hat
PF=102 (extrem profitabel auf einer kurzen Phase). Der hohe Mean-PF
wird vom proportional hohen `std_oos_pf` kompensiert — DSR-mäßig
nicht relevant.

### 5.3 Beobachtungen

- **Beide Top-DSR-Trials kommen aus W3a, nicht aus TPE** (Trial 688
  und 266 sind W3a-Survivors mit Parametern AUSSERHALB des
  TPE-Suchraums). Das stützt die in W3.5 dokumentierte
  Cross-Search-Space-Hypothese: TPE hat eine Region erforscht, aber
  die robusten Punkte liegen am Rand oder ausserhalb dieser Region.
- **Sample-Kurtosis floored auf [1.5, 2.8]**, nicht extrem — die
  Mertens-Variance-Korrektur bleibt gutmütig.
- **Sample-Skew überwiegend negativ** (−0.25 bis −1.15) — die per-Split
  OOS-Sharpe-Verteilung hat einen langen linken Tail. Das verschärft
  die DSR-Penalty leicht (1 − γ_3·SR > 1 für SR > 0 und γ_3 < 0).

## 6. Pfad-A-Reach-Final-Check

Welle-W3.5-Plan-§4.4-Akzeptanzkriterien (re-validiert in Welle W4):

| Kriterium | Schwelle | Gemessen | Status |
|-----------|----------|---------:|:-------|
| Pool-PBO | < 0.5 (robust) | 1.0000 | **NEIN** |
| Top-1-DSR | > 0.95 (robust) | 0.2067 | **NEIN** |
| Union-Pool-Size | ≥ 30 | 86 | OK |

Pfad-A-Reach-Verdict: **NICHT erreicht**. Beide statistischen Gates
verfehlt.

## 7. Empfehlung

### 7.1 Primärempfehlung: Phase-3.1 schliessen

Die kombinierte PBO=1.0 + Top-DSR=0.21-Diagnose ist methodisch
robust und sehr stark — sie signalisiert, dass die aktuelle
Phase-3.1-Methodik (Random-Search → Walk-Forward → TPE-Refinement)
**strukturell** keinen produktionsreifen Trial isoliert hat. Welle W5
sollte daher die Phase-3.1-Verlobung **nicht** an einen
Production-Default-Pick koppeln; stattdessen:

1. Welle-W3a-Walk-Forward-Survivor-Set (109 Trials) und
   Welle-W3.5-TPE-Production-Output (200 Trials) als Phase-3.1-Output
   einfrieren.
2. Welle W4-Diagnose (PBO=1.0, alle DSR<0.5) als Begründung in den
   Phase-3.1-Tag aufnehmen.
3. Phase-3.2 (Live-Trading-Kandidatengenerator) **nicht** mit einem
   automatisch ausgewählten Default starten, sondern mit dem
   Walk-Forward-Tooling, das QA in W2/W3 etabliert hat, im
   Paper-Trading-Modus.

### 7.2 Alternativ: Welle W4.5 (Erweiterte Caps)

Falls QA glaubt, dass die TPE-Caps (`kijun ≤ 39`, `tp_rr ≤ 2.6`) der
Grund für die strukturelle Instabilität sind, kann eine W4.5-Runde
mit:

- `kijun ∈ [9, 78]` (verdoppelt)
- `tp_rr ∈ [1.0, 4.0]` (erweitert)
- erneutem 200-Trial-TPE × Walk-Forward
- gefolgt von erneutem PBO + DSR auf dem neuen Union-Pool

versucht werden. Erwartung: marginale Verbesserung, da die
PBO=1.0-Diagnose primär ein Sample-Size-Problem ist (6 OOS-Splits
gegen 86 Trials). Eine Erweiterung der Suchspaces ändert nicht die
fundamentale Mehrfach-Test-Schwäche.

### 7.3 Welle W5-Tag-Empfehlung

**`GO Phase-3.1 closed`** (Primärempfehlung 7.1).

Konkret:

- Tag `phase-3.1-walkforward-only` auf HEAD (`242cd7d` nach W4-2).
- Tag-Annotation:
  ```
  Phase-3.1 closed without production-default pick. Walk-Forward
  Validation (Welle W3a, 109 trials) + TPE Production Refinement
  (Welle W3.5, 200 trials) + Bailey-de-Prado PBO/DSR statistical
  gates (Welle W4, 86-trial union pool) form the deliverable.
  Pool PBO = 1.0, Top-1 DSR = 0.21 — no trial is statistically
  distinguishable from multi-testing noise. Phase-3.2 will reuse
  the W3a/W3.5 trial pool as paper-trading candidates without
  automated default selection.
  ```

## 8. Artefakte

| Pfad | Inhalt |
|------|--------|
| `01_Projectplan/optimizer_studies/stat_gates_union_pool.csv` | 86 Trials, sortiert nach DSR descending; vollständige Per-Trial-Stats |
| `01_Projectplan/optimizer_studies/stat_gates_results.db` | SQLite mit `stat_gates_pool` (1 Pool-Row) + `stat_gates_trial` (86 Per-Trial-Rows) |
| `rust/trading_engine/src/optimizer/stat_gates.rs` | PBO + DSR pure functions (Welle W4-1) |
| `rust/trading_engine/examples/stat_gates_run.rs` | Union-Pool-Builder + CLI (Welle W4-2) |
| `01_Projectplan/specs/stat_gates_w4_results_2026-05-26.md` | dieses Dokument (Welle W4-3) |

Reproduzierbarkeit: deterministisch (PBO + DSR sind closed-form;
kein RNG involviert). `--seed 42` wird in `stat_gates_pool.seed`
persistiert für Audit, hat aber keinen Einfluss auf den Output.
