# ut_bot Production Sweep (Welle O2)

**Datum:** 2026-05-24  
**Phase:** 3 — Welle O2  
**Asset/TF:** BTCUSDT / 5m  
**Range:** 2024-01-01 → 2024-03-08  
**Candles:** 19297  
**Trials:** 500  
**Seed:** 42  
**Score-Constraints:** max_drawdown_cap_pct = 17, min_trades = 50  
**Engine:** Bitunix-VIP0 0.06 % Taker-Fee pro Seite, 10.000 USDT Startkapital, F-04 Next-Bar-Open, slippage_bps = 0  
**Compute:** 9089.7s reine Sweep-Zeit (18179.4 ms/trial)  

---

## 1. Trial-Qualification

2 / 500 Trials qualifiziert (0.4 %).  
498 Trials disqualifiziert (max_drawdown_cap_pct > 17 oder total_trades < 50 oder profit_factor nicht endlich).

**Befund:** Disqualifikation getrieben überwiegend durch `total_trades < 50`, vereinzelt durch `max_drawdown > 17 %`. Die zwei qualifizierten Trials liegen genau auf der Trade-Count-Grenze (52, 55) und beide sind **netto-verlustbringend** (PF < 1.0). Der Sweep zeigt einen Trade-Off im Parameter-Raum: viele Trades ⇒ niedriger PF (mean-reversion-overhead durch Fees), wenige Trades ⇒ hoher PF aber unter `min_trades`. Konsistent mit Welle-R3 (`regime_filter_diagnose_2026-05-24.md` §3.2): C0 baseline 131 Trades PF 0.535, C2 thr=35 nur 8 Trades aber PF 2.34.

## 2. Top-10

| Rank | Trial | Score | PF | Sharpe | Trades | WR % | MaxDD % | profit % | final equity |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 489 | 0.9224 | 0.922 | -0.455 | 52 | 19.23 | 11.87 | -1.65 | 9835.19 |
| 2 | 345 | 0.6812 | 0.681 | -2.409 | 55 | 23.64 | 10.62 | -7.65 | 9234.63 |
| 3 | 0 | -inf | 1.224 | +0.903 | 17 | 23.53 | 5.23 | +2.14 | 10214.19 |
| 4 | 1 | -inf | -0.000 | -4.691 | 3 | 0.00 | 2.38 | -2.38 | 9762.47 |
| 5 | 2 | -inf | -0.000 | -0.443 | 2 | 0.00 | 1.18 | -0.24 | 9976.02 |
| 6 | 3 | -inf | -0.000 | -2.995 | 2 | 0.00 | 1.36 | -1.35 | 9865.43 |
| 7 | 4 | -inf | 0.000 | +0.000 | 0 | 0.00 | 0.00 | +0.00 | 10000.00 |
| 8 | 5 | -inf | -0.000 | -1.758 | 1 | 0.00 | 2.31 | -1.48 | 9851.89 |
| 9 | 6 | -inf | 0.000 | +0.000 | 0 | 0.00 | 0.00 | +0.00 | 10000.00 |
| 10 | 7 | -inf | -0.000 | -2.173 | 1 | 0.00 | 0.56 | -0.49 | 9951.10 |

## 3. XLSX-Band-Check (Top-5)

XLSX-Targets (ut_bot):  
- Trade-Count ∈ [80, 120]  
- WR ∈ [48 %, 58 %]  
- PF ∈ [2.01, 2.61]  
- MaxDD < 17 %  
- profit % ∈ [+98 %, +148 %]

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
| `adx_threshold` | 27.401123930589534 |
| `adx_use_di_confluence` | 0 |
| `atr_period` | 4 |
| `ema_period` | 293 |
| `key_value` | 1.2086896919646817 |
| `risk_per_trade` | 0.02354158265734616 |
| `session_filter_enabled` | 0 |
| `smi_cross_above_zero` | 0 |
| `smi_d_smoothing` | 2 |
| `smi_k_smoothing` | 4 |
| `smi_length` | 10 |
| `swing_lookback_bars` | 18 |
| `tp_rr_ratio` | 3.200910012754526 |

## 5. Distribution (qualifizierte Trials)

### Profit-Factor
```
     0.681– 0.711 │    1  ████████████████████████████████████████
     0.711– 0.741 │    0  
     0.741– 0.772 │    0  
     0.772– 0.802 │    0  
     0.802– 0.832 │    0  
     0.832– 0.862 │    0  
     0.862– 0.892 │    0  
     0.892– 0.922 │    1  ████████████████████████████████████████
```

### Max-Drawdown %
```
     10.62– 10.78 │    1  ████████████████████████████████████████
     10.78– 10.93 │    0  
     10.93– 11.09 │    0  
     11.09– 11.24 │    0  
     11.24– 11.40 │    0  
     11.40– 11.55 │    0  
     11.55– 11.71 │    0  
     11.71– 11.87 │    1  ████████████████████████████████████████
```

### Trade-Count
```
      52–  52 │    1  ████████████████████████████████████████
      52–  53 │    0  
      53–  53 │    0  
      53–  54 │    0  
      54–  54 │    0  
      54–  54 │    0  
      54–  55 │    0  
      55–  55 │    1  ████████████████████████████████████████
```

---

## 6. Pfad-Klassifikation + Phase-3.1-Empfehlung

**Klassifikation:** **Pfad C confirmed** — XLSX-Targets ([80–120 Trades] ∧ [PF 2.01–2.61] ∧ [WR 48–58 %] ∧ [MaxDD < 17 %] ∧ [profit % +98–148 %]) sind auf BTCUSDT 5m 66-Tage mit dem aktuellen Search-Space + always-on ADX-Filter **strukturell unerreichbar**. Beide qualifizierten Trials (489, 345) erreichen Trade-Count knapp >50 aber PF < 1.0 — netto-Verlust.

**Root Cause:** Der Parameter-Raum trennt sich in zwei nicht-überlappende Regimes:
- **Many-Signal Regime** (ADX-Threshold niedrig, key_value niedrig): 50–130 Trades, aber Fee-Belastung übersteigt Edge → PF 0.5–1.0 (verlustreich).
- **Selective Regime** (ADX-Threshold hoch ≥35, key_value ≥2): hohe Edge per-Trade (PF 2–3), aber 3–15 Trades → disqualifiziert.

Die XLSX-Cell-Forderung "80–120 Trades AND PF 2.01–2.61" fordert beide Eigenschaften gleichzeitig, was die Strategie auf 5m-BTC mit Welle-R4-ADX-Filter nicht liefert. Top-1 Sweep-Trial (Trial 489) hat sehr niedrige `key_value`=1.21 und niedrige `adx_threshold`=27.4 → many-signal Regime → vorhersehbarer Fee-Dominanz-Verlust.

**Hypothesen für Phase 3.1 (Welle-O2.5):**
1. **Fee-Modell-Realismus prüfen:** Bitunix-VIP0 Taker 0.06 % pro Seite = 0.12 % round-trip. Der `key_value` × ATR macht TP/SL relativ zu ATR — wenn TP < 3 × round-trip-Fee, Strategie strukturell unprofitabel (`pipeline-sync-guard` Fee-to-ATR Validation). Auf 5m-Candles ist ATR klein, TP wahrscheinlich fee-dominiert.
2. **Search-Space-Reduktion auf high-PF Regime:** `key_value ∈ [2.5, 4.0]`, `adx_threshold ∈ [35, 50]`, `smi_length ∈ [10, 20]` — bewusste Bias auf selektive Setups. Dann Constraint `min_trades` auf 20 lockern, um Validierung zu ermöglichen.
3. **Maker-only Variant testen:** Limit-Order-Entry + Limit-TP/SL → round-trip-Fee fällt auf 0.04 %, TP-zu-Fee-Ratio verdreifacht sich. Engine-seitig (F-04 next-bar-open execution) braucht das eine separate Strategy-Variante.
4. **Range erweitern:** 66 Tage 5m = 19297 Candles ist ausreichend Datenmenge, aber 2024-H1 war ein starker Trend-Markt. Range auf 2024-2025 (ganzes Jahr) erweitern, um Regime-Mix zu testen.

**Empfehlung:** **Hypothese 1 (Fee-Realismus) zuerst** — schnell zu prüfen via `backtest-pipeline.skill` Fee-to-ATR-Validation. Wenn Fee-dominiert, dann Hypothese 3 (Maker-only) als strukturelle Korrektur. Hypothese 2 als Search-Space-Verfeinerung für Welle-O2.5. Hypothese 4 als statistischer Sanity-Check.

**Cross-Strategy-Insight:** UT-Bot zeigt ein **anderes** Pfad-C-Muster als BB+RSI:
- BB+RSI Pfad C: search space cannot generate enough trades (single-mode failure).
- UT-Bot Pfad C: search space generates either many low-PF or few high-PF trades, nie beides (bimodal failure).

Die UT-Bot-Bimodal-Struktur ist das **stärkere Phase-3.1-Signal**, weil es eine konkrete Hypothese (Fee-Dominanz) liefert statt eines Datenmangels.

---

_Generated by `cargo run --release --example production_sweep -- ut_bot 500 42` at 2026-05-24T20:20:14.445692485+00:00._
