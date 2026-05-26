# UT Bot Welle A2 — Fee-Realismus + Pfad-Klassifikation

**Datum:** 2026-05-26
**Phase:** 3.2 — Welle A2
**Strategie:** UT Bot Alerts (verbesserte Variante)
**Hypothese:** Welle-O2 UT-Bot Top-1 hatte 52 Trades und Profit −1.65 % auf
66 Tagen. Bitunix-VIP0 Taker 0.06 % × 2 Sides × 52 Trades = ~6.24 pp
Fee-Drag — annähernd 100 % der Gesamt-Verlust-Magnitude. Hypothese:
Fee ist der dominante Treiber, nicht die Strategy-Logik.

**Welle A2-Validation:** Re-Sweep auf identischem Search-Space + Candles
mit `fee_rate=0.0` als Sanity-Check. Wenn Zero-Fee >50 qualifizierte Trials
und Top-1 PF >> 1.0 erzeugt, war Fee dominant → A2-Maker wäre die
production-realistische Korrektur. Wenn nicht, ist die Strategy-Logik
strukturell limitiert und Fee-Adjustment löst das nicht.

Voller Sweep: [`ut_bot_zerofee_sweep_2026-05-26.md`](./ut_bot_zerofee_sweep_2026-05-26.md).
Welle-O2 Baseline: [`ut_bot_sweep_2026-05-24.md`](./ut_bot_sweep_2026-05-24.md).

---

## 1. Zwei-Wege-Vergleich Welle O2 (taker 0.06 %) vs Welle A2-Validation (0 %)

| Dimension | Welle O2 (taker) | Welle A2 (zerofee) | Δ |
|---|---:|---:|---:|
| Candles | 19297 | 19297 | 0 |
| Compute | 9089.7 s | 9641.0 s | +6.1 % |
| Trials | 500 | 500 | 0 |
| Seed | 42 | 42 | 0 |
| Qualified Trials | 2 / 500 (0.4 %) | **2 / 500 (0.4 %)** | **0** |
| Top-1 Trial-ID | 489 | **489** | identisch |
| Top-1 PF | 0.922 | **1.271** | **+0.349** |
| Top-1 Sharpe | −0.455 | **+1.568** | +2.02 |
| Top-1 Trades | 52 | 52 | 0 |
| Top-1 WR % | 19.23 | 19.23 | 0 |
| Top-1 MaxDD % | 11.87 | **8.07** | −3.80 |
| Top-1 profit % | −1.65 | **+4.64** | **+6.29** |
| Top-1 Bands hit | 1/5 (MaxDD) | 1/5 (MaxDD) | 0 |
| Top-2 PF | 0.681 | 0.926 | +0.245 |
| Top-2 profit % | −7.65 | −1.48 | +6.17 |

**Engine-Fee-Accounting validiert:** Identischer Top-1 Trial 489 in beiden
Sweeps (Search-Space + Seed deterministisch). Δ-Profit (+6.29 pp) matched
fast exakt das predicted Fee-Drag von `52 Trades × 0.06 % × 2 Sides = 6.24 pp`.
Die Engine zieht Fees korrekt ab; der Effekt von Fee-Variation auf das
Top-Equity ist gemessen und bounded.

## 2. Pfad-Klassifikation

Per Welle-A2-Brief-Definition:

| Outcome | Kriterium | Welle A2-Validation | Verdict |
|---|---|---|---|
| **a (Fee-dominiert)** | qualified > 50 UND Top-1 PF >> 1.0 | 2 qualified, PF=1.27 | **NEIN** |
| **b (Strategy-limitiert)** | qualified < 20 UND Top-1 PF < 1.5 | 2 qualified, PF=1.27 | **JA** strikt |

**Klassifikation: Outcome b — Strategy-Logik strukturell limitiert.**

XLSX-Band-Vergleich Top-1 zerofee:
- Trade-Count ∈ [80, 120]: 52 ✗ — **immer noch zu wenige Trades selbst ohne Fee**
- WR ∈ [48 %, 58 %]: 19.23 % ✗ — **Hauptdefekt, ~29 pp unter Lower-Band**
- PF ∈ [2.01, 2.61]: 1.271 ✗ — unter Lower-Band trotz Zero-Fee
- MaxDD < 17 %: 8.07 % ✓
- profit % ∈ [+98 %, +148 %]: +4.64 % ✗

Selbst bei kompletter Fee-Eliminierung erreicht Top-1 nur 1/5 Bands —
identisch zur Welle-O2-Bilanz. Der Bands-Hit-Count ist fee-invariant.

## 3. Warum Fee-Adjustment die Strategie nicht rettet

**Win-Rate-Mathematik:** Top-1 zerofee hat WR=19.23 % und `tp_rr_ratio=3.20`.
Die break-even-Win-Rate für asymmetrisches TP/SL ist `1/(1+R)` = `1/(1+3.2)` =
**23.8 %**. Top-1 liegt **4.6 pp unter dem Break-Even** selbst ohne Fees.

Empirisch korrigiert (gross PF = 1.271 statt 1.0): Die tatsächliche
Reward/Risk-Verhältnis ist effektiv höher als `tp_rr_ratio` (Trailing-Stop +
partial-TP-Effekte heben winners über das nominelle TP-Target). Aber
selbst mit dem gross-positiven PF=1.27 ist die Edge so dünn, dass kleinste
zusätzliche Kosten (slippage, partial-fill-rejection, funding) die
Profitabilität wieder kippen.

**Maker-Fee-Extrapolation (nicht ausgeführt):** Bitunix-VIP0 Maker
0.02 % × 2 Sides = 4 bps round-trip = 0.04 %. Auf 52 Trades = 2.08 pp
Fee-Drag (vs 6.24 pp taker, vs 0 pp zerofee). Predicted Top-1 Maker-Profit:
+4.64 % − 2.08 % = **+2.56 %**, Predicted Top-1 Maker-PF: **~1.10**.
Beide weiterhin **deutlich unter XLSX-Band** (PF 2.01-2.61, profit 98-148 %).

→ **A2-Maker-Sweep nicht durchgeführt**, weil Outcome b-Kriterium die
Hypothese falsifiziert: Fee ist nicht der dominante Blocker. Compute-Spar:
~2.5 h.

## 4. Root-Cause-Konvergenz mit §13.5 (2026-05-23 Welle-U3-Diagnose)

§13.5 etablierte die „Confluence-Inkompatibilität auf Krypto-5min"-These:
UT-Bot kombiniert Trend-Filter (EMA-200) mit Mean-Reversion-Trigger
(SMI-Cross-While-Same-Sign-Zero). Auf NQ-5min profitiert dieser Mix vom
auctions-getriebenen Open-/Close-Mean-Reversion-Verhalten. Auf 24/7-Krypto
existieren diese Mikrostruktur-Vorteile nicht; die zwei Filter sind
gegenläufig kalibriert, was die ~30 pp Win-Rate-Lücke (19-24 % statt
48-58 % Target) konsistent erklärt.

**Welle-A2-Verschärfung:** §13.5 wurde mit `fee_rate=0.06 %` etabliert.
Die Zero-Fee-Variation hält die Win-Rate auf 19.23 % konstant (identisches
Top-1, identischer Trades+WR-Wert) — die Mikrostruktur-Lücke ist **nicht
fee-induziert**, sondern signal-strukturell. Fee-Modellierung war die
naheliegende externe Erklärung; nach A2-Validation kann sie aus dem
Erklärungs-Raum ausgeschlossen werden.

**Welle-R3-C2-Befund-Reconciliation:** Welle-R3 C2 (adx_thr=35) erzeugte
8 Trades PF=2.34 mit +2.8 % Profit — innerhalb des XLSX-PF-Bands aber
weit unter `min_trades=50`. Welle-A2 bestätigt: diese hohe Edge per-Trade
ist nicht von der Strategy ableitbar; sie ist eine Selektion auf die
~5 % der Marktphasen, in denen UT-Bot's EMA200-SMI-Confluence funktioniert.
Auf 24/7-Krypto sind diese Phasen zu selten für das XLSX-Trade-Band.

## 5. Cross-Strategy-Insight (BB+RSI A1 vs UT-Bot A2)

| Dimension | BB+RSI Welle A1 (1h TF) | UT-Bot Welle A2 (zerofee) |
|---|---|---|
| Test-Hypothese | TF-Mismatch (4h zu wenig Candles) | Fee-Drag dominant |
| Qualified-Verbesserung | 0 → 13 / 1000 (+13) | 2 → 2 / 500 (0) |
| Top-1 PF-Verbesserung | n/a → 1.545 | 0.922 → 1.271 (+0.35) |
| Top-1 Bands-hit | n/a → 1/5 | 1/5 → 1/5 (0) |
| Pfad-C-Verdikt | **mit Verbesserung** | **strikt konfirmiert** |
| Verbleibender Hebel | Strukturelle Search-Space-Erweiterung | Strukturelle Logik-Inkompatibilität |

**Schlussfolgerung:** BB+RSI hat noch verbleibende strukturelle Hebel
(Welle A1.1 ADX optional, A1.2 ADX-Threshold lowering, evtl. weitere
TF/Asset-Variationen). UT-Bot hat keinen vergleichbaren Hebel mehr —
zwei strukturelle Hypothesen (Mikrostruktur §13.5, Fee §A2) sind getestet
und beide falsifiziert/bestätigt-aber-unzureichend. UT-Bot bleibt
**Pfad C ohne weiteres Phase-3.2-Sub-Pfad-Potential** auf BTCUSDT 5m
mit dem aktuellen Search-Space + always-on ADX-Filter.

## 6. Hypothesen für weitere Sub-Wellen (NICHT empfohlen)

Vollständigkeitshalber dokumentiert; alle drei sind **NICHT** empfohlen
basierend auf §3 + §5.

### 6a. Welle A2.1 — Maker-Sweep trotz Outcome b

**Hypothese:** Maker-Fee + leicht reduzierter Search-Space könnte Top-1
Bands von 1/5 → 2/5 schieben.

**Erwartung:** Predicted Maker-Top-1 PF ~1.10 (vs XLSX-Lower 2.01). PF-Band
nicht erreichbar; bands-Hit bleibt 1/5 (MaxDD-only).

**Aufwand:** ~2.5 h Compute + ~30 min Analyse.

**Wert:** Niedrig. Predicted-Outcome lässt sich aus §1+§3 closed-form ableiten.

### 6b. Welle A2.2 — ETH-5m oder BTC-15m TF-Variant

**Hypothese:** §13.5 sagt UT-Bot ist krypto-mikrostruktur-inkompatibel;
ein anderes Krypto-Asset/TF könnte zufällig eine kompatiblere
Mikrostruktur haben.

**Erwartung:** Diagnose §4 Punkt 2 (Welle-U3) hat 7 Variationen getestet —
alle defizitär (best-of-sweep PF=0.81 auf ETHUSDT 5min). 8. Variation
unwahrscheinlich abweichend.

**Aufwand:** ~3-4 h pro TF/Asset (Candle-Fetch + Sweep + MD).

**Wert:** Sehr niedrig. Sample-Space ist bereits in Welle-U3 abgedeckt.

### 6c. Welle A2.3 — Search-Space-Bias auf Edge-Regime (key_value ≥ 2.5, adx_threshold ≥ 35)

**Hypothese:** Welle-O2 Original-Sweep hat das Many-Signal vs Selective
Bimodal aufgedeckt. Bias-Sweep auf Selective-Regime könnte mehr Trials
in den High-PF-Bereich verschieben — aber Trade-Count fällt synchron.

**Erwartung:** Many Trials erreichen PF > 2.0, aber alle disqualified
wegen `min_trades < 50`. Würde Welle-R3-C2-Befund duplizieren, ohne
neuen Insight.

**Aufwand:** ~30 min Search-Space-YAML + ~2.5 h Compute.

**Wert:** Niedrig. Validiert eine Hypothese, die schon implizit durch
Welle-R3-C2 belegt ist.

## 7. Spec-Update-Empfehlung

Append §13.7 in [`ut_bot_spec.md`](./ut_bot_spec.md):

1. Welle-A2-Klassifikation = Outcome b (Strategy-limitiert, nicht
   fee-limitiert)
2. Δ-Profit (+6.29 pp) matched predicted Fee-Drag (6.24 pp) → Engine-Fee-
   Accounting validiert
3. Win-Rate-Mathematik: 19.23 % < break-even 23.8 % bei tp_rr=3.2 — strukturell
   sub-break-even
4. §13.5-Microstructure-Hypothese behält Geltung; A2 entfernt Fee aus der
   Erklärungs-Set
5. Verweis auf dieses Doc
6. §13.6 Phase-3-Backlog (mittlere Priorität) wird auf **niedrige Priorität**
   herabgestuft — Welle-A2-Resultat reduziert Erwartungs-Wahrscheinlichkeit
   für ETH-Multi-TF-Sweep zusätzlich

## 8. Endurteil + Brief-Antwort

**Pfad C strikt konfirmiert über das Fee-Spektrum {0 %, 0.06 %} (extrapoliert
auch 0.02 % Maker).**

UT-Bot ist auf BTCUSDT 5m strukturell limitiert durch die Confluence-
Inkompatibilität auf 24/7-Krypto-Mikrostruktur (§13.5). Fee-Adjustment ist
**Symptom-Behandlung ohne Edge-Verbesserung**. Maker-Variante würde
prediktiv +2.5 % Profit liefern, aber XLSX-Band-Reach bleibt unmöglich.

**Empfehlung an QA:** Phase 3.2 close + Tag setzen. Keine weiteren UT-Bot-
Sub-Wellen empfohlen. BB+RSI Welle A1.1/A1.2 bleiben als optionale
Backlog-Items für Phase-3-Optimizer-Tail-Wave.

---

_Verfasst nach Sweep `cargo run --release --example production_sweep -- ut_bot 500 42 zerofee`._
