# UT Bot Alerts — Diagnose-Backtests (Welle U3 Real-Data-Eskalation)

**Datum:** 2026-05-23
**Strategie:** UT Bot Alerts (verbesserte Variante per `ut_bot_spec.md` §1)
**Asset/TF (Baseline):** BTCUSDT 5min, 2024-01-01 → 2024-03-07 UTC (66 Tage, 19009 Candles — entspricht dem Video-NQ-Zeitraum bit-genau)
**Engine-Konfiguration:** Bitunix-VIP0 0.06 % Taker-Fee pro Seite, 10.000 USDT Startkapital, F-04 Next-Bar-Open-Execution, F-03 Sharpe-Annualisierung auf TF, F-03b Mid-Trade-Equity, D-08 TP-first + BE-Trail @ +1R
**Test-Infrastruktur:** `test/integration/ut_bot_real_data_test.dart` mit 7 `skip:`-gateten `test()`-Blocks, opt-in über `UT_BOT_DIAGNOSE=1` Env-Var. Pro Case 3× Dart bit-exakt + 3× Rust bit-exakt + Dart↔Rust 1e-9 (Welle U2-5 FFI-Parity-Contract).
**Ziel:** klassifizieren, ob die Strategie auf Ziel-Asset/TF in das XLSX-Target-Band trifft (Pfad A), eine Variation im Band landet (Pfad B), oder ob die XLSX-Microstructure auf der eigenen Konfiguration nicht reproduzierbar ist (Pfad C).

---

## 1. Acceptance-Bänder (aus Spec §13.2)

| Metrik | Soll | Toleranz | Akzeptanz-Band |
|---|---|---|---|
| Profit-Faktor | 2.31 | ±0.30 | **[2.01, 2.61]** |
| Win-Rate | 53 % | ±5 pp | **[48 %, 58 %]** |
| Max-Drawdown | 12 % | +5 pp | **< 17 %** |
| Trades | 100 | ±20 % | **[80, 120]** |
| R:R | 1:2 (mit BE-Trail) | exakt 2.0 | exakt 2.0 / BE-Exits ≈ 0R |

---

## 2. Eskalations-Leiter — Ergebnis-Tabelle

Alle 7 Tests verwenden den vollen Spec-Default-Risk-Stack (Swing-Lookback N=20, R:R 1:2, BE-Trail @ +1R, 2 % Risk). Nur die markierte Parameter-Achse variiert.

| Test | Setup | candles | trades | L | S | WR % | PF | DD % | totalPnl USDT | sharpe | realised R | Bands? |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| **T1** | BTC 5m strict (k=2) | 19009 | 131 | 71 | 60 | 24.43 | 0.535 | 19.79 | −1527.13 | −5.76 | 1.65 | ✗ (alle 4 verfehlt) |
| **T2** | BTC 5m strict (k=3, §12.1) | 19009 | 58 | 35 | 23 | 20.69 | 0.280 | 12.09 | −1142.66 | −6.64 | 1.07 | ✗ (3/4 verfehlt, DD ok) |
| **T3** | BTC 5m smi_cross_above_zero=1 (k=2, §12.5) | 19009 | 53 | 34 | 19 | 20.75 | 0.640 | 8.34 | −833.58 | −2.97 | 2.44 | ✗ (3/4 verfehlt, DD ok) |
| **T4a** | BTC **15m** strict (k=2) | 6337 | 28 | 13 | 15 | 21.43 | 0.480 | 10.10 | −719.65 | −5.55 | 1.76 | ✗ (3/4 verfehlt, DD ok) |
| **T4b** | BTC **1h** strict (k=2) | 1585 | 7 | 2 | 5 | **0.00** | 0.000 | 5.15 | −515.17 | −16.34 | 0.00 | ✗ (kein Gewinner überhaupt) |
| **T4c** | **ETHUSDT** 5m strict (k=2) | 19009 | 135 | 62 | 73 | 24.44 | 0.810 | 12.45 | −727.59 | −2.21 | 2.50 | ✗ (3/4 verfehlt, DD ok) |
| **T4d** | BTC 5m (key=1.5, atr=5) | 19009 | 160 | 94 | 66 | 29.38 | 0.720 | 15.80 | −1207.31 | −3.79 | 1.73 | ✗ (3/4 verfehlt, DD ok) |
| **T4e** | BTC 5m (key=5.0, atr=10) | 19009 | **2** | 1 | 1 | 50.00 | 0.368 | 2.08 | −132.47 | −2.15 | 0.37 | ✗ (Trades zu wenig, PF crash) |

**Reproduzierbarkeit:** alle 8 Tests 3× Dart bit-exakt grün, 3× Rust bit-exakt grün, Dart↔Rust totalPnl 1e-9 grün. Keine Engine-Drift, keine Test-Stopp-Bedingung (`trades > 500`, `MaxDD > 95 %`) ausgelöst.

**Welle-U2-4 Eskalations-Marker-Resolution:** Auf realen 19000 BTCUSDT-5min-Candles fired die strict-spec Confluence **131-mal** (T1), das ist signifikant über null — die im U2-4-Marker beschriebene „0 Trades auf Synth-Fixtures"-Beobachtung ist eindeutig ein Artefakt der synthetischen Fixture-Form (Sinusoid / Drop-Recovery / Triangle / Square / Sawtooth produzieren keine zufälligen Mikro-Reversals, die alle drei Bedingungen gleichzeitig auf demselben Bar synchronisieren — randomisierte Walks und reale Marktdaten tun das hingegen mehrfach pro Tag).

---

## 3. Acceptance-Klassifikation

**Welcher Test landet im Target-Band?**

- **PF ∈ [2.01, 2.61]:** KEINER. Best-of-Sweep ist T4c (ETHUSDT) mit **0.81**, gefolgt von T3 (cross_above_zero) mit **0.64**. **Alle Tests bleiben unter PF = 1.0 — d.h. jede einzelne Variation ist netto-defizitär.**
- **WR ∈ [48 %, 58 %]:** nur T4e mit 50 % — aber dort nur 2 Trades insgesamt (1 Win, 1 Loss), statistisch bedeutungslos und PF=0.37 trotzdem extrem schlecht.
- **trades ∈ [80, 120]:** KEINER. Naheste Werte: T1 (131, knapp über Band), T2 (58, knapp unter), T4c (135 ETH), T4d (160 mit k=1.5).
- **MaxDD < 17 %:** 7 von 8 (alle außer T1 mit 19.79 %).

**Pfad-Logik (Spec §13.3 rev4):**
- Min. 1 Variation mit ALLEN 4 Bändern → Pfad B mit dieser Variation als Default
- Keine Variation mit allen 4 Bändern → **Pfad C bestätigt**

**Ergebnis: Pfad C.** Die strict-spec Variante (T1) verfehlt 4/4 Targets. Die zwei Path-B-Erweiterungen (T2 key=3, T3 smi_cross_above_zero=1) verfehlen je 3/4. Die TF-Variationen (T4a 15m, T4b 1h) zeigen mit zunehmender TF immer weniger Trades und KEINE Gewinner auf 1h. Die Asset-Variation (T4c ETH) zeigt das gleiche WR/PF-Profil wie BTC — d.h. das Problem ist NICHT BTC-spezifisch. Der Parameter-Sweep (T4d, T4e) bewegt PF nur zwischen 0.37 und 0.72 — kein Sweet-Spot existiert in dem getesteten Raum.

---

## 4. Diagnose-Schlussfolgerung

**Welcher Driver wirkt?**

- **Timeframe (5min → 15min → 1h, T1/T4a/T4b):** Trade-Frequenz fällt monoton (131 → 28 → 7), aber WR und PF brechen ein statt zu steigen. Auf 1h ist die Strategie nicht nur unter-traded sondern produziert **0 Gewinner**. Das ist das genaue Gegenteil des BB+RSI-Sanity-Sweep-Befundes (dort kippte 1h → 4h ins Plus). **TF-Skalierung rettet UT Bot nicht.**
- **Asset (BTC → ETH, T1 vs T4c):** WR identisch (24.43 % vs 24.44 %), PF leicht besser (0.535 → 0.810) aber immer noch deutlich unter 1.0. **Asset-Mismatch-Hypothese widerlegt:** Wenn ETH dasselbe Profil produziert, ist BTC nicht das Problem.
- **`key_value` (1.5 → 2 → 3 → 5, T4d/T1/T2/T4e):** WR bewegt sich zwischen 20.7 % und 50 % (T4e bei 2 Trades), aber PF bleibt bei 0.28–0.72. Der Sensitivity-Knob filtert Signale aus, ändert aber nicht die Gewinn-/Verlust-Verteilung der überlebenden Signale.
- **Zero-Line-Gate-Inversion (`smi_cross_above_zero`, T1 vs T3):** ändert das Selektionskriterium qualitativ (53 vs 131 Trades, andere Signal-Lage), bringt PF von 0.535 auf 0.640. **Die Path-B-Vermutung aus Spec §12.5 — der Transkript-Wortlaut sei sub-optimal — wird durch T3 NICHT bestätigt; die relaxe Variante ist nur marginal besser, immer noch deutlich unter 1.0.**

**Fundamentale Bewertung:** Die UT-Bot-EMA200-SMI-Confluence ist auf BTCUSDT/ETHUSDT 5min im 2024-Q1-Zeitraum **strukturell unprofitabel** — egal welcher Default-Parameter-Schalter gedreht wird. Das R:R = 1:2 (realisiert 1.65–2.50 in T1–T4d) liefert nicht genug Gewinn-Multiplikator, um den niedrigen WR (~20–25 %) auszugleichen. Theoretisch bräuchte die Strategie WR ≈ 33 % bei R:R = 1:2 als Break-Even — wir sehen 20–25 %. Die Diskrepanz von ~10 pp ist über alle Parameter-Achsen stabil.

**Indizien sprechen für eine Mischung aus:**
1. **Asset/TF-Mismatch zum Video-NQ-5min (hoch plausibel):** NQ-5min hat strukturelle Mean-Reversion-Tendenz aus Open-/Close-Auctions, Microstructure-Auswirkungen der Future-Roll-Termine, und liquidere Tages-Sessions. Krypto-24/7-Märkte haben keinen dieser Mikrostruktur-Vorteile. Der Autor sagt zwar „funktioniert in jedem Markt" (T25–T26), aber das ist nicht durch eigenen Backtest belegt — er testet im Video nur auf NQ.
2. **Trigger-Inkompatibilität auf Krypto-5min (hoch plausibel):** Der SMI-Cross-While-Below-Zero (Long-Trigger) ist eine Mean-Reversion-Signatur. In starken Krypto-Trends (z.B. BTC Q1/2024 +60 %) ist der SMI lange über null und triggert nur in Pullbacks — wo die EMA(200) bereits gegen die Mean-Reversion läuft. Die zwei Filter sind gegenläufig kalibriert für Krypto-Volatilität.
3. **Welle-U3 Path-B-Toggle bewirkt keinen Quantensprung:** `smi_cross_above_zero=true` testet exakt die „Pro-Trend"-Variante (Long bei SMI-Cross-Up-while-above-zero) und kommt nur auf PF=0.64 — auch das ist nicht ausreichend. D.h. weder Mean-Reversion- noch Pro-Trend-Lesart des SMI-Filters rettet die Strategie auf Krypto-5min.

---

## 5. Empfehlung

**„Phase-2 v3 abschließen als 'video-treu implementiert, BTC/ETH 5min/15min/1h untauglich', UT Bot bleibt als Add-in-Manifest-Eintrag für Phase-3-Optimizer-Lab."**

- UT Bot v3 (verbesserte Variante) ist **engineering-vollständig**: alle Spec-Diffs (ATR-Wilder, SMI-Blau-1993, UT-Bot-Trail, EMA-200-Filter, Swing-SL, R:R-1:2-TP, BE-Trail @ +1R, Session-Filter optional, Path-B-Toggle `smi_cross_above_zero`) implementiert, Dart↔Rust 1e-9-Parität durchgängig auf 400-Bar Random-Walk-Fixture + 19k-Bar Real-Data, F-04-No-Lookahead und F-03-Sharpe-Annualisierung gepinnt. Das Strategie-Add-in bleibt produktionsreif als Bestandteil der Add-in-Schicht.
- UT Bot v3 ist auf BTCUSDT 5min **statistisch nicht akzeptanz-tauglich**. Die XLSX-Targets (WR 53 %, PF 2.31, MaxDD 12 %, Profit +123 %) sind auf 5min in 2024-Q1 nicht erreichbar, und keine der vier untersuchten Parameter-Achsen (key_value, ATR-period, smi_cross_above_zero, TF, Asset) bringt sie ins Band.
- T4c (ETHUSDT) zeigt mit PF=0.81 das beste Profil aller getesteten Konfigurationen — immer noch defizitär, aber das ist der einzige Hinweis dass die Strategie auf einem anderen Asset/TF-Mix möglicherweise besser läuft. Das ist ein **Phase-3-Optimizer-Lab-Kandidat**, nicht ein Welle-3-Code-Fix.

**Konkrete Schritte:**
1. **Keine Default-Änderung committen.** Spec-Defaults bleiben video-treu (`key_value = 2.0`, `atr_period = 1`, `smi_length = 14`, `smi_k_smoothing = 5`, `smi_d_smoothing = 3`, `tp_rr_ratio = 2.0`, `smi_cross_above_zero = 0`). Das ist die korrekte Repräsentation der Vorlage; die Acceptance-Lücke ist eine Eigenschaft des Asset/TF-Setups, nicht der Implementation.
2. **Ichimoku-Spec-Arbeit startet** in eigener Session als letzte Phase-2-Strategie. UT Bot bleibt im Add-in-Manifest und kann von Phase-3-Optimizer-Jobs für TF-/Asset-/Param-Sweeps verwendet werden.
3. **Phase-3 Backlog-Eintrag (mittlere Priorität):** „UT Bot v3 ETH-Multi-TF-Sweep (ETHUSDT 5min/15min/1h + BTCUSDT 4h-Vergleich), Ziel: PF ≥ 1.5 bei trades ≥ 50". Geringere Erfolgswahrscheinlichkeit als der vergleichbare BB+RSI-4h-Backlog-Eintrag, weil hier ALLE Achsen versagen.
4. **Optionaler Phase-3-Backlog-Eintrag (niedrige Priorität):** „SMI-Variante Uday-spezifisch nachforschen und gegen Blau-1993-Standard backtesten (§12.4 QA-Frage)". Recherche-Aufwand ~1h, kann nur Implementations-Detail-Fixes liefern — die grundlegende Confluence-Inkompatibilität auf Krypto-5min bleibt davon unberührt.

---

## 6. Anhang — Bit-exakte Run-Snapshots

Reproduktion über `UT_BOT_DIAGNOSE=1 flutter test --plain-name "<Case>" test/integration/ut_bot_real_data_test.dart`. Dart und Rust totalPnl stimmen bei jedem Test auf 1e-9 überein (FFI-Parity-Contract Welle U2-5).

```
DIAGNOSE Test 1 BTCUSDT 5min strict (key=2.0)
  candles=19009
  trades=131  long=71  short=60  winning=32  losing=99
  totalPnl=-1527.128688 USDT (eq_final=8472.871312)
  winRate=24.4275%  profitFactor=0.534568
  sharpe=-5.755180  maxDD%=19.792244
  avgWin=54.811626  avgLoss=33.142431  realisedR=1.6538

DIAGNOSE Test 2 BTCUSDT 5min strict (key=3.0)
  candles=19009
  trades=58  long=35  short=23  winning=12  losing=46
  totalPnl=-1142.659113 USDT (eq_final=8857.340887)
  winRate=20.6897%  profitFactor=0.280350
  sharpe=-6.644415  maxDD%=12.086289
  avgWin=37.094971  avgLoss=34.517365  realisedR=1.0747

DIAGNOSE Test 3 BTCUSDT 5min cross_above_zero (key=2.0)
  candles=19009
  trades=53  long=34  short=19  winning=11  losing=42
  totalPnl=-833.575091 USDT (eq_final=9166.424909)
  winRate=20.7547%  profitFactor=0.640334
  sharpe=-2.965228  maxDD%=8.335751
  avgWin=134.914722  avgLoss=55.181834  realisedR=2.4449

DIAGNOSE Test 4a BTCUSDT 15m strict (key=2.0)
  candles=6337
  trades=28  long=13  short=15  winning=6  losing=22
  totalPnl=-719.651696 USDT (eq_final=9280.348304)
  winRate=21.4286%  profitFactor=0.479681
  sharpe=-5.550255  maxDD%=10.102650
  avgWin=110.574268  avgLoss=62.868059  realisedR=1.7588

DIAGNOSE Test 4b BTCUSDT 1h strict (key=2.0)
  candles=1585
  trades=7  long=2  short=5  winning=0  losing=7
  totalPnl=-515.169632 USDT (eq_final=9484.830368)
  winRate=0.0000%  profitFactor=0.000000
  sharpe=-16.341075  maxDD%=5.151696
  avgWin=0.000000  avgLoss=73.595662  realisedR=0.0000

DIAGNOSE Test 4c ETHUSDT 5m strict (key=2.0)
  candles=19009
  trades=135  long=62  short=73  winning=33  losing=102
  totalPnl=-727.587999 USDT (eq_final=9272.412001)
  winRate=24.4444%  profitFactor=0.809675
  sharpe=-2.207529  maxDD%=12.445733
  avgWin=93.796327  avgLoss=37.479086  realisedR=2.5026

DIAGNOSE Test 4d BTCUSDT 5m (key=1.5, atr=5)
  candles=19009
  trades=160  long=94  short=66  winning=47  losing=113
  totalPnl=-1207.309546 USDT (eq_final=8792.690454)
  winRate=29.3750%  profitFactor=0.719777
  sharpe=-3.786283  maxDD%=15.802986
  avgWin=65.980277  avgLoss=38.127280  realisedR=1.7305

DIAGNOSE Test 4e BTCUSDT 5m (key=5.0, atr=10)
  candles=19009
  trades=2  long=1  short=1  winning=1  losing=1
  totalPnl=-132.474563 USDT (eq_final=9867.525437)
  winRate=50.0000%  profitFactor=0.368088
  sharpe=-2.150871  maxDD%=2.080354
  avgWin=77.166184  avgLoss=209.640747  realisedR=0.3681
```
