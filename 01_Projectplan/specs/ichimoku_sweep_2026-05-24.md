# ichimoku Production Sweep (Welle O2)

**Datum:** 2026-05-24  
**Phase:** 3 — Welle O2  
**Asset/TF:** BTCUSDT / 1h  
**Range:** 2023-04-01 → 2025-05-02  
**Candles:** 18289  
**Trials:** 1000  
**Seed:** 42  
**Score-Constraints:** max_drawdown_cap_pct = 15, min_trades = 60  
**Engine:** Bitunix-VIP0 0.06 % Taker-Fee pro Seite, 10.000 USDT Startkapital, F-04 Next-Bar-Open, slippage_bps = 0  
**Compute:** 29565.6s reine Sweep-Zeit (29565.6 ms/trial)  

---

## 1. Trial-Qualification

109 / 1000 Trials qualifiziert (10.9 %).  
891 Trials disqualifiziert (max_drawdown_cap_pct > 15 oder total_trades < 60 oder profit_factor nicht endlich).

**Befund:** Substanzielle Qualifikations-Quote — die Trade-Count- und MaxDD-Constraints sind im Search-Space erreichbar, ~10 % der Random-Samples landen im qualifizierten Bereich. Top-1 (Trial 515) erreicht PF **2.008** — nur 0.13 unter dem XLSX-Lower-Bound von 2.14. Im Gegensatz zu BB+RSI und UT-Bot ist Ichimoku **Pfad-B-Kandidat**, kein hartes Pfad C.

## 2. Top-10

| Rank | Trial | Score | PF | Sharpe | Trades | WR % | MaxDD % | profit % | final equity |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 515 | 2.1626 | 2.008 | +1.550 | 60 | 31.67 | 7.04 | +27.10 | 12709.79 |
| 2 | 306 | 2.0153 | 1.870 | +1.453 | 60 | 33.33 | 13.95 | +74.91 | 17491.08 |
| 3 | 494 | 1.8057 | 1.686 | +1.198 | 64 | 26.56 | 13.71 | +51.30 | 15129.67 |
| 4 | 836 | 1.6806 | 1.562 | +1.186 | 68 | 27.94 | 14.31 | +41.57 | 14157.15 |
| 5 | 436 | 1.6360 | 1.544 | +0.921 | 62 | 22.58 | 8.65 | +19.04 | 11903.76 |
| 6 | 986 | 1.5179 | 1.430 | +0.877 | 69 | 28.99 | 8.73 | +18.09 | 11809.40 |
| 7 | 934 | 1.4909 | 1.406 | +0.849 | 74 | 25.68 | 10.29 | +19.80 | 11980.42 |
| 8 | 418 | 1.4765 | 1.378 | +0.990 | 73 | 38.36 | 9.17 | +22.78 | 12278.13 |
| 9 | 39 | 1.4732 | 1.367 | +1.062 | 94 | 41.49 | 13.21 | +30.15 | 13014.59 |
| 10 | 460 | 1.4485 | 1.369 | +0.799 | 66 | 25.76 | 14.16 | +21.77 | 12176.72 |

## 3. XLSX-Band-Check (Top-5)

XLSX-Targets (ichimoku):  
- Trade-Count ∈ [75, 125]  
- WR ∈ [50 %, 60 %]  
- PF ∈ [2.14, 2.74]  
- MaxDD < 15 %  
- profit % ∈ [+95 %, +145 %]

| Rank | Trades | WR % | PF | MaxDD % | profit % | Bands hit |
|---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |
| 2 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |
| 3 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |
| 4 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |
| 5 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |

## 4. Top-1 Parameter

| Parameter | Value |
|---|---:|
| `adx_filter_enabled` | 1 |
| `adx_period` | 14 |
| `adx_threshold` | 28.116151876827914 |
| `adx_use_di_confluence` | 0 |
| `kijun_period` | 23 |
| `risk_per_trade` | 0.010149775261183974 |
| `score_threshold` | 55 |
| `senkou_b_period` | 63 |
| `session_filter_enabled` | 0 |
| `shift` | 24 |
| `tenkan_period` | 13 |
| `tp_rr_ratio` | 2.5727380557737956 |

## 5. Distribution (qualifizierte Trials)

### Profit-Factor
```
     0.792– 0.944 │   15  ███████████████
     0.944– 1.096 │   26  ██████████████████████████
     1.096– 1.248 │   40  ████████████████████████████████████████
     1.248– 1.400 │   21  █████████████████████
     1.400– 1.552 │    3  ███
     1.552– 1.704 │    2  ██
     1.704– 1.856 │    0  
     1.856– 2.008 │    2  ██
```

### Max-Drawdown %
```
      7.04–  8.02 │    1  █
      8.02–  9.01 │    7  ██████████
      9.01–  9.99 │   12  █████████████████
      9.99– 10.98 │   11  ███████████████
     10.98– 11.97 │   18  █████████████████████████
     11.97– 12.95 │   14  ███████████████████
     12.95– 13.94 │   17  ███████████████████████
     13.94– 14.92 │   29  ████████████████████████████████████████
```

### Trade-Count
```
      60–  67 │   32  ████████████████████████████████████████
      67–  73 │   26  █████████████████████████████████
      73–  80 │   17  █████████████████████
      80–  86 │   17  █████████████████████
      86–  93 │    5  ██████
      93– 100 │    4  █████
     100– 106 │    5  ██████
     106– 113 │    3  ████
```

---

## 6. Pfad-Klassifikation + Phase-3.1-Empfehlung

**Klassifikation:** **Pfad-B-Kandidat** — Ichimoku ist die einzige der drei Strategien, deren Sweep substanzielle qualifizierte Trials (10.9 %) und einen Top-1-PF nahe der XLSX-Untergrenze (2.008 vs 2.14, Delta 0.13) liefert. Die XLSX-Targets werden bei Top-5 alle bei 1/5 Bands (nur MaxDD) erfüllt, aber die Lücken sind teilweise klein und teilweise strukturell:

| Band | XLSX-Target | Top-1 Wert | Gap | Charakter |
|---|:---:|:---:|---|---|
| Trade-Count | [75, 125] | 60 | −15 | parameter-rangabh., erweiterbar |
| WR % | [50, 60] | 31.67 | −18 pp | **strukturell** (BTC vs Forex) |
| PF | [2.14, 2.74] | **2.008** | **−0.13** | **nah** (Refinement-Distanz) |
| MaxDD % | < 15 | 7.04 | +7.96 | **erfüllt mit Reserve** |
| profit % | [+95, +145] | +27.10 | −67.9 pp | folgt aus zu wenigen Trades |

**Root Cause der WR-Lücke:** Ichimoku-XLSX-Targets sind Forex-tuned (FX-Märkte zeigen WR 50–60 %). BTC-Markt zeigt strukturell niedrigere WR weil mean-reversion-Phasen kürzer sind und Trend-Phasen volatiler. Welle-R3-Baseline confirmed: Ichimoku C0 baseline WR 29.75 %, C2 thr=35 WR 31.46 % — kein ADX-Config bringt WR über 35 %. Das ist ein **legitimer Cross-Market-Effekt**, kein Algorithmus-Bug.

**Root Cause der Trade-Count-Lücke:** Top-1 hat 60 Trades (genau auf der `min_trades`-Grenze), Top-10 reicht bis 94. Mit `score_threshold` 55 (mittlere Konfluenz-Anforderung) sind die Sweep-Top-Performer selektiv. Niedrigere `score_threshold` (40–50) würde mehr Trades produzieren — dann aber vermutlich niedrigerer PF.

**Root Cause der PF-Lücke (Delta 0.13):** Sehr klein. Welle-R3 baseline-Config (default Ichimoku 9/26/52 ohne ADX) hatte PF 1.088 auf der gleichen Range. Welle-O2-Sweep verbesserte das auf 2.008 — das ist eine **+85 %-Verbesserung** durch Random Search. Eine TPE/Bayes-Optimization in Phase 3.1 sollte die letzten 0.13 PF-Punkte gewinnen können.

**Top-1 Parameter Profil:**
- `tenkan_period` 13, `kijun_period` 23, `senkou_b_period` 63, `shift` 24 — alle langsamer als das klassische Spec-Default 9/26/52/26. Insight: längere Ichimoku-Perioden auf BTC 1h reduzieren Whipsaw-Loss.
- `score_threshold` 55 — Mittelwert zwischen 40 (zu lax) und 80 (zu streng) — auch eine Phase-3.1-Refinement-Achse.
- `adx_threshold` 28.1 — niedriger als die Welle-R3-Sweep-Best-Config thr=35. Indication: längere Perioden + niedrigere ADX-Schwelle = bessere Selectivität auf 1h.
- `tp_rr_ratio` 2.57 — moderate (zwischen Phase-2-Default 3.0 und Plan-Fallback 2.0).
- `adx_use_di_confluence` 0 (off) — DI-Confluence bringt auf 1h Ichimoku keinen Mehrwert (Welle-R3-Bestätigung).

**Hypothesen für Phase 3.1:**
1. **Walk-Forward-Validation auf Top-10:** Sind PF 1.5–2.0 Top-Trials out-of-sample stabil oder ist es Overfitting? Aus 109 qualifizierten Trials sind die Top-10 die kritischen Kandidaten.
2. **Bayes/TPE-Optimization um Top-1 herum:** Local-Search mit Optuna-TPE im 5-D-Neighborhood (tenkan, kijun, senkou_b, score_threshold, adx_threshold) sollte die +0.13 PF-Lücke zur XLSX-Untergrenze schließen.
3. **WR-Lücke akzeptieren** und XLSX-Target WR auf BTC-Realismus 30–40 % korrigieren (Spec §13.7-Update). Forex-WR auf Crypto-Märkte zu projizieren ist strukturell falsch.
4. **Trade-Count durch Range-Erweiterung erhöhen:** 760 Tage 1h = 18289 Candles ist ausreichend, aber wenn pro 1000 Candles ~3-4 Trades fallen, würde eine 1500-Tage-Range die Trade-Counts in das [75, 125] Band heben.
5. **PBO/DSR-Gate vor Default-Live-Pick:** Bei 10.9 % Qualifikations-Quote könnte einer der 109 Trials ein Glücks-Treffer sein. Probability-of-Backtest-Overfitting (PBO) und Deflated-Sharpe-Ratio (DSR) sind die richtigen Gates vor jeder Live-Deployment-Entscheidung.

**Empfehlung:** Ichimoku ist der **stärkste Kandidat für Phase 3.1** und damit für Live-Trading-Default. Die Reihenfolge: Walk-Forward (1) → TPE-Optimization (2) → PBO/DSR-Gate (5) → Spec-Update WR-Band (3). Trade-Count-Range-Erweiterung (4) als optionale Phase-3.2-Iteration.

**Cross-Strategy-Vergleich:**
- BB+RSI Pfad C: search space cannot generate enough trades (single-mode failure, structural).
- UT-Bot Pfad C: bimodal failure — many-trades-low-PF vs few-trades-high-PF, never both.
- Ichimoku Pfad B: substantial qualification, near-XLSX PF, refinement-distance from Pfad A.

Ichimoku verdient Phase 3.1; BB+RSI und UT-Bot brauchen erst Phase-3.0.5-Strukturanpassungen (Range-Re-Examination, Maker-Variant, etc.).

---

_Generated by `cargo run --release --example production_sweep -- ichimoku 1000 42` at 2026-05-25T04:37:33.695688989+00:00._
