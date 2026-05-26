# BB+RSI Welle A1 — Pfad-Klassifikation (1h TF-Mismatch-Validierung)

**Datum:** 2026-05-26
**Phase:** 3.2 — Welle A1
**Strategie:** BB+RSI
**Hypothese:** Welle-O2 4h-Sweep produzierte 0/1000 qualifizierte Trials weil
das XLSX-Trade-Band [80, 120] auf 4h strukturell unerreichbar ist. Auf 1h
(4× mehr Candles) sollte das Volumen-Problem strukturell entschärft sein.
Voller Sweep: [`bb_rsi_1h_sweep_2026-05-26.md`](./bb_rsi_1h_sweep_2026-05-26.md).
Welle-O2 4h Referenz: [`bb_rsi_sweep_2026-05-24.md`](./bb_rsi_sweep_2026-05-24.md).

---

## 1. Vergleich Welle O2 (4h) vs Welle A1 (1h)

| Dimension | Welle O2 (4h) | Welle A1 (1h) | Δ |
|---|---:|---:|---:|
| Candles | 1093 | 4368 | ×4.0 |
| Compute | 42.1 s | 340.7 s | ×8.1 |
| Qualified Trials | 0 / 1000 (0.0 %) | **13 / 1000 (1.3 %)** | +13 |
| Max Trades observed | 10 (Trial 7) | **64 (Trial 998)** | ×6.4 |
| Top-1 Trades | 0 (alle score = −∞) | **42** | +42 |
| Top-1 PF | n/a | **1.545** | n/a |
| Top-1 Sharpe | n/a | **+1.78** | n/a |
| Top-1 WR | n/a | **30.95 %** | n/a |
| Top-1 MaxDD | n/a | **15.41 %** | n/a |
| Top-1 profit % | n/a | **+22.46 %** | n/a |
| Top-1 Bands hit | n/a | **1/5** (MaxDD only) | n/a |

**Strukturelle Verbesserung bestätigt:** 1h löst das Volume-Problem teilweise
(13 statt 0 qualifizierte Trials, max 64 statt 10 Trades), aber die XLSX-Band
[80, 120] bleibt **außer Reichweite**. Trade-Volume-Skalierung ist **nicht
linear** zur Candle-Anzahl (×4.0 Candles → ×6.4 max-Trades — die ADX-Filter-
Disqualifikations-Rate sinkt zusätzlich, weil 4h-ADX(14) gröberer Glättungs-
Faktor ist als 1h-ADX(14)).

## 2. Pfad-Klassifikation

Per Welle-A1-Brief-Definition:

| Pfad | Kriterium | Welle A1 1h | Verdict |
|---|---|---|---|
| **A** | Top-1 alle 5/5 Bands hit | 1/5 | **NEIN** |
| **B** | Top-1 3-4/5 Bands hit UND qualified > 50 | 1/5 + 13 qualified | **NEIN** strikt |
| **C** | Top-1 < 3/5 Bands hit ODER qualified < 30 | 1/5 + 13 qualified | **JA** strikt |

**Klassifikation: Pfad C (mit signifikanter Verbesserung vs 4h).**

Nuance — Pfad C ist nicht das Gleiche wie Welle O2 4h:
- **Welle O2 4h:** Pfad C **strikt** (0/1000 qualifiziert, kein edge-positives Sample)
- **Welle A1 1h:** Pfad C **mit edge-positivem Top-Kandidaten** — Top-1 hat
  Sharpe +1.78, PF 1.545 (nur 0.035 unter XLSX-Lower [1.58]), profit +22.46 %
  auf 6 Monaten. Strategy is **profitable but small-volume on 1h** — eine
  qualitativ andere Aussage als „strukturell unprofitable on 4h".

## 3. Konvergenz-Analyse Top-10

Welche Param-Werte dominieren Top-10? Erkennen wir, wo der echte Edge sitzt?

| Parameter | Search-Space | Top-10 Werte | Konvergenz |
|---|---|---|---|
| `adx_threshold` | [25.0, 45.0] | [25.7, 25.8, 26.3, 27.3, 27.7, 29.1, 30.0, 32.9, 35.3, 37.2] — Median 28.5 | **Lower-End** (7/10 < 30) |
| `bb_stddev` | [0.2, 1.0] | [0.21, 0.22, 0.24, 0.24, 0.31, 0.34, 0.39, 0.43, 0.61, 0.68] — Median 0.33 | **Low** (7/10 < 0.45) — enge BBs |
| `rsi_period` | [2, 14] (Welle A1 widened) | [2, 2, 2, 2, 2, 2, 3, 3, 3, 2] | **Komplett am Lower** (alle 2-3) |
| `swing_lookback_bars` | [10, 30] | [11, 11, 12, 13, 13, 13, 13, 14, 15, 19] — Median 13 | **Concentrated** [11-15] |
| `bb_period` | [50, 300] (Welle A1 widened) | [78, 113, 129, 142, 150, 210, 234, 262, 263, 299] — Median 180 | **Sehr breit verteilt** (kein klarer Sweet-Spot) |
| `tp_rr_ratio` | [1.5, 4.0] | [1.55, 1.84, 2.43, 2.48, 2.49, 2.94, 3.18, 3.39, 3.74, 3.76] | Breit verteilt |
| `risk_per_trade` | [0.01, 0.03] | [0.010, 0.011, 0.014, 0.016, 0.017, 0.020, 0.020, 0.022, 0.024, 0.029] | Breit verteilt |
| `adx_use_di_confluence` | Bool | 6× false, 4× true (Top-1: false) | Schwacher Trend zu false |

**Insights aus Welle-A1-Search-Space-Erweiterung:**

1. **`rsi_period 2..14` Erweiterung war NICHT der Hebel.** Kein einziger Top-10-
   Kandidat nutzt RSI(8..14). RSI(2-3) bleibt dominant — der „klassische
   RSI(14)"-Hypothese ist empirisch widerlegt für BB+RSI auf BTCUSDT 1h.
2. **`bb_period 50..300` Erweiterung produziert valide Kandidaten am Lower-End
   (bb_period 78, 113, 129, 142, 150 sind alle in Top-10),** aber auch am
   Upper-End (262, 263, 299). Range-Erweiterung war nützlich aber kein
   dominanter Erfolg-Faktor.
3. **`adx_threshold` clustert am Lower-Bound [25-30].** Eine weitere Lowering
   würde mehr Trades bringen — der ADX-Filter ist der dominante Trade-Cutter.

## 4. Root-Cause-Update zu §13.5 (NQ vs BTC Microstructure)

§13.5 Hypothese: Video wurde auf NQ entwickelt; BTC-1h hat zu viel Noise für
RSI(3)-Pullback-Trigger; BTC-4h hat zu wenige Setups. Welle A1 verfeinert:

**Drei Constraints konkurrieren auf BTC 1h:**

1. **Phase-1-Reference (BB(20, 2σ) + RSI(14, 30/70), KEIN ADX):** 91 Trades —
   **in XLSX-Band [80, 120] ✓** — aber edge-negativ (WR 18.68 %, PF 0.685,
   Profit −15.65 %, MaxDD 19.63 %). **„Volumen ohne Edge."**
2. **Welle A1 Top-1 (BB(262, 0.31σ) + RSI(2), ADX-on Threshold 25.8):**
   42 Trades — unter XLSX-Lower [80] ✗ — aber edge-positiv (WR 30.95 %,
   PF 1.55, Profit +22.46 %, MaxDD 15.41 %). **„Edge ohne Volumen."**
3. **Welle A1 max-Trade Trial 998 (64 Trades):** Profit −2.63 %, PF 0.92.
   **„Mehr Volumen, weniger Edge."**

Die Edge-Volumen-Trade-off ist **strikt monoton** im Welle-A1-Sample: höhere
ADX-Threshold + tighter RSI-Bands → weniger Trades, höherer PF. Die XLSX-
Band [80, 120] Trades + PF [1.58, 2.18] **liegen im Param-Raum nicht
gleichzeitig erreichbar** auf BTC 1h mit dem Welle-R4 always-on ADX-Filter.

§13.5 NQ-vs-BTC-Microstructure-Hypothese **verschärft sich:** BTC braucht
ADX-Filter um Edge zu erzeugen, NQ vermutlich nicht — die XLSX-Video-Targets
sind auf einem Asset gemessen, das ohne Trend-Filter genug Edge hat, weil die
Microstructure (Session-Open/Close-Phasen, institutioneller Flow) das
Signal-Noise-Verhältnis bereits selbst-filtert.

## 5. Hypothesen für nächste Sub-Wellen

### 5a. Welle A1.1 (optional) — ADX optional im Search-Space

**Hypothese:** Falls `adx_filter_enabled: Bool` (statt Welle-R4-fixiert
1.0) im Search-Space erlaubt wäre, würde TPE/Random-Search möglicherweise
Edge-positive Konfigurationen ohne ADX-Filter finden, die XLSX-Trade-Band
[80, 120] erreichen.

**Erwartung (a priori):** Mit ADX off + RSI(3)-Pullback + asymmetrischer BB
würde sich der Sample-Raum vergrößern. Aber: Phase-1-Reference (no ADX, BB(20),
RSI(14)) ist edge-negativ. Hypothese: kein RSI(3) + no-ADX Config in 1000
Trials erreicht PF > 1.0.

**Aufwand:** 1 Search-Space-YAML + 1 Sweep-Run + 1 Analyse-MD ≈ 1 h Engineering
+ 6 min Compute.

**Wert:** Mittel — bestätigt oder widerlegt empirisch, dass ADX-on der einzige
Pfad zu edge-positiven Konfigurationen ist. Wenn ja: §13.6 Phase-3-Backlog kann
weiter eingegrenzt werden („no-ADX-Variante als sweepable strategy ausgeschlossen").

### 5b. Welle A1.2 (optional) — ADX-Threshold weiter lowering

**Hypothese:** Top-10 clustert am Lower-Bound 25-30 (Top-1 = 25.8). Mit
adx_threshold ∈ [15, 35] (statt [25, 45]) würden mehr Trades durch den
Filter kommen, bei möglicherweise gleichbleibendem PF.

**Erwartung:** Trade-Volume steigt linear mit ADX-Threshold-Lowering bis zu
einem Edge-Knick-Punkt. Welle A1.2 würde diesen Knick-Punkt empirisch
bestimmen.

**Aufwand:** Ähnlich Welle A1.1.

**Wert:** Niedrig-Mittel — eine zweite Verfeinerung im gleichen Sub-Pfad-C-
Cluster. Wenn der Knick-Punkt PF > 1.58 erreicht, wäre das ein Pfad-B-
Übergang. Aber unwahrscheinlich basierend auf der monotonen Edge-Volumen-
Trade-off in §4.

### 5c. Welle A2 (priorisiert) — UT-Bot Fee-Realismus

Welle A1 Klassifikation gibt **freien Pfad zu Welle A2.** Pfad C (mit
Verbesserung) bedeutet: BB+RSI ist auf BTC 1h **„edge-positive Lab-Kandidat
mit limitierter Trade-Volume"**, nicht „strukturell broken". Spec §13.6
„Phase-3-Optimizer-Backlog (niedrige Priorität)" bleibt gültig.

**Empfehlung:** GO Welle A2 (UT-Bot Fee-Realismus) direkt. A1.1/A1.2 als
Backlog-Items für Phase-3-Optimizer-Tail-Wave.

## 6. Spec-Update-Empfehlung

§13.8 Append in [`bb_rsi_spec.md`](./bb_rsi_spec.md) mit drei Zeilen:

1. Welle-A1-Klassifikation = Pfad C mit Verbesserung
2. Verweis auf dieses Doc
3. §13.6 Phase-3-Optimizer-Backlog bleibt unverändert; A1.1/A1.2 als optionale
   Sub-Wellen ergänzen wenn vor Production-Decision gebraucht

§13.5 NQ-vs-BTC-Microstructure-Hypothese bleibt unverändert (verschärft sich
empirisch durch Welle A1, aber die Hypothese-Aussage selbst ist gleich).

## 7. Endurteil + Brief-Antwort

**Pfad C (mit signifikanter Verbesserung vs 4h)** —
„edge-positive Lab-Kandidat mit XLSX-Trade-Band außer Reichweite auf 1h".

**Empfehlung an QA:** GO Welle A2 (UT-Bot Fee-Realismus) direkt, ohne
Welle A1.1/A1.2.

---

_Verfasst nach Sweep `cargo run --release --example production_sweep -- bb_rsi 1000 42 1h`._
