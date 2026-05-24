# bb_rsi Production Sweep (Welle O2)

**Datum:** 2026-05-24  
**Phase:** 3 — Welle O2  
**Asset/TF:** BTCUSDT / 4h  
**Range:** 2024-01-01 → 2024-07-01  
**Candles:** 1093  
**Trials:** 1000  
**Seed:** 42  
**Score-Constraints:** max_drawdown_cap_pct = 19, min_trades = 30  
**Engine:** Bitunix-VIP0 0.06 % Taker-Fee pro Seite, 10.000 USDT Startkapital, F-04 Next-Bar-Open, slippage_bps = 0  
**Compute:** 42.1s reine Sweep-Zeit (42.1 ms/trial)  

---

## 1. Trial-Qualification

0 / 1000 Trials qualifiziert (0.0 %).  
1000 Trials disqualifiziert (max_drawdown_cap_pct > 19 oder total_trades < 30 oder profit_factor nicht endlich).

**Befund:** Disqualifikation getrieben durch `total_trades < 30`, NICHT durch Drawdown oder PF-Pathologie. Der trade-reichste Trial der 1000 (Trial 7 in Top-10 §2) hat 10 Trades — noch ein Faktor 3 unter der Constraint. Auf 1093 4h-Candles produziert kein Search-Space-Sample im YAML 30+ Trades. Konsistent mit Welle-R3-Real-Data-Sweep (`regime_filter_diagnose_2026-05-24.md` §2.1): BB+RSI C0-Baseline ohne ADX-Filter zeigte 15 Trades, alle ADX-Configs 3-11 Trades.

## 2. Top-10

| Rank | Trial | Score | PF | Sharpe | Trades | WR % | MaxDD % | profit % | final equity |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0 | -inf | 0.000 | +0.000 | 0 | 0.00 | 0.00 | +0.00 | 10000.00 |
| 2 | 1 | -inf | 0.000 | +0.000 | 0 | 0.00 | 0.00 | +0.00 | 10000.00 |
| 3 | 2 | -inf | 5.566 | +2.453 | 4 | 50.00 | 3.95 | +8.88 | 10888.00 |
| 4 | 3 | -inf | -0.000 | -0.021 | 2 | 0.00 | 4.47 | -0.16 | 9984.29 |
| 5 | 4 | -inf | 0.000 | +0.000 | 0 | 0.00 | 0.00 | +0.00 | 10000.00 |
| 6 | 5 | -inf | 88.201 | +1.393 | 3 | 33.33 | 3.96 | +4.66 | 10465.55 |
| 7 | 6 | -inf | 0.000 | +0.000 | 0 | 0.00 | 0.00 | +0.00 | 10000.00 |
| 8 | 7 | -inf | 1.109 | +0.281 | 10 | 20.00 | 9.65 | +1.29 | 10129.08 |
| 9 | 8 | -inf | -0.000 | +0.050 | 1 | 0.00 | 7.14 | -0.11 | 9988.73 |
| 10 | 9 | -inf | 0.000 | +0.000 | 0 | 0.00 | 0.00 | +0.00 | 10000.00 |

## 3. XLSX-Band-Check (Top-5)

XLSX-Targets (bb_rsi):  
- Trade-Count ∈ [80, 120]  
- WR ∈ [33 %, 43 %]  
- PF ∈ [1.58, 2.18]  
- MaxDD < 19 %  
- profit % ∈ [+83 %, +133 %]

| Rank | Trades | WR % | PF | MaxDD % | profit % | Bands hit |
|---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |
| 2 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |
| 3 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |
| 4 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |
| 5 | ✗ | ✗ | ✗ | ✓ | ✗ | **1/5** |

**Hinweis:** Die obige Tabelle ist die Rank-Order bei `score = -inf` für alle Trials → SQLite sortiert sekundär nach insertion-id, daher die `trial_id 0..9` Reihenfolge ohne PF-Bezug. Echte Top-Kandidaten nach Trade-Count: Trial 7 (10 Trades, PF 1.109), Trial 2 (4 Trades, PF 5.566), Trial 3 (2 Trades), Trial 5 (3 Trades, PF 88.2 = ~1 Gewinner-dominated). Kein Sample produziert genug Trades, um die `min_trades = 30` Constraint zu erfüllen.

## 4. Top-1 Parameter

| Parameter | Value |
|---|---:|
| `adx_filter_enabled` | 1 |
| `adx_period` | 14 |
| `adx_threshold` | 35.53114818005548 |
| `adx_use_di_confluence` | 0 |
| `bb_ma_type` | 1 |
| `bb_period` | 227 |
| `bb_stddev` | 0.5247214065846215 |
| `risk_per_trade` | 0.010686856359099122 |
| `rsi_overbought` | 76.2243526927804 |
| `rsi_oversold` | 26.061366415865905 |
| `rsi_period` | 7 |
| `swing_lookback_bars` | 12 |
| `tp_rr_ratio` | 1.5081302408823998 |

## 5. Distribution (qualifizierte Trials)

Keine qualifizierten Trials → Histograms leer.

```
PF Hist        keine qualifizierten Trials
MaxDD Hist     keine qualifizierten Trials
Trade Hist     keine qualifizierten Trials
```

Distribution-Hinweis: Über alle 1000 Trials produzieren ~60 % der Samples 0 Trades (BB-Period zu lang oder ADX-Threshold zu hoch). Die ~40 % mit Trades liegen im Bereich [1, 10]. Die brief-erwartete XLSX-Band [80, 120] Trades ist auf dieser Range strukturell außerhalb der Reichweite des Search-Space.

---

## 6. Pfad-Klassifikation + Phase-3.1-Empfehlung

**Klassifikation:** **Pfad C confirmed** — XLSX-Targets sind auf BTCUSDT 4h 2024-H1 mit dem aktuellen Search-Space + Welle-R4-Default-Constraints **strukturell unerreichbar**. Konsistent mit Welle-R3-Real-Data-Sweep-Befunden (`regime_filter_diagnose_2026-05-24.md` §3, Pfad-B-Check ergab kein ADX-Config > 15 Trades).

**Root Cause:** Search-Space + always-on ADX-Filter + 1093-Candle-Range generiert in 1000 Samples maximal 10 Trades pro Trial. Die `min_trades = 30` Score-Constraint disqualifiziert daher jedes Sample bevor PF/Sharpe überhaupt zählt. Die XLSX-Trade-Band [80, 120] liegt eine weitere Größenordnung darüber — selbst mit weichen Constraints unerreichbar auf 4h.

**Hypothesen für Phase 3.1 (Welle-O2.5):**
1. **Search-Space erweitern:** ADX-Filter optional (`adx_filter_enabled: Bool` statt fixiert 1.0), `bb_period` Lower-Bound auf 50, `rsi_period` bis 14. Erwartung: 20–40 Trades zustande.
2. **Range erweitern:** Statt 6 Monate 4h (1093 Candles) ein 24-Monate-Range (~4400 Candles, Faktor 4× Daten → ~60 Trades default). Mismatcht aber die XLSX-Range-Definition.
3. **Constraint lockern:** `min_trades = 10` (statistisch grenzwertig, aber zeigt Top-N) für Welle-O2.5 als Sanity-Pass.
4. **Timeframe-Mismatch klären:** XLSX [80, 120] Trades passt zu 1h (Faktor 4× → reichlich Default-Trades), nicht zu 4h. Vermutung: 4h in der XLSX-Spec ist Tippfehler oder Strategie sollte auf 1h optimiert werden (Spec §2 bestätigen).

**Empfehlung:** **Hypothese 4 zuerst prüfen** — wenn die XLSX-Spec 1h meinte, ist der gesamte 4h-Sweep ein Range-Mismatch und der Phase-3.1-Sweep läuft auf 1h. Wenn die XLSX-Spec 4h korrekt ist, dann Hypothese 1 (Search-Space erweitern, ADX-Filter freigeben) ausführen. Hypothese 2/3 als Fallback.

**Top-1 Parameter (siehe §4) sind nicht aussagekräftig für Phase 3.1** — der Sweep hat keinen edge-positiven Kandidaten gefunden, lediglich die Disqualifikations-Gates getriggert.

---

_Generated by `cargo run --release --example production_sweep -- bb_rsi 1000 42` at 2026-05-24T17:44:12.466548846+00:00._
