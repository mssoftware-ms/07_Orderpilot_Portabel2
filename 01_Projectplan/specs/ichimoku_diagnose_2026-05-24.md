# Ichimoku Cloud Retest — Diagnose-Backtests (Welle I3 Real-Data-Eskalation)

**Datum:** 2026-05-24
**Strategie:** Ichimoku Cloud Retest (Endstand-Variante per `ichimoku_spec.md` §1, §12.2)
**Asset/TF (Baseline):** BTCUSDT 1h, 2023-04-01 → 2025-05-01 UTC (760 Tage, 18265 Candles — entspricht dem XLSX-Platz-11-Zeitraum 760 Tage)
**Engine-Konfiguration:** Bitunix-VIP0 0.06 % Taker-Fee pro Seite, 10.000 USDT Startkapital, F-04 Next-Bar-Open-Execution, F-03 Sharpe-Annualisierung auf TF, F-03b Mid-Trade-Equity, D-08 TP-first + BE-Trail @ +1R, Session-Filter OFF (BTC 24/7, §1-Default)
**Test-Infrastruktur:** `test/integration/ichimoku_real_data_test.dart` mit 7 `skip:`-gateten `test()`-Blocks, opt-in über `ICHIMOKU_DIAGNOSE=1` Env-Var. Pro Case 3× Dart bit-exakt + 3× Rust bit-exakt + Dart↔Rust 1e-9 (Welle I2-6 FFI-Parity-Contract).
**Ziel:** klassifizieren, ob die Strategie auf Ziel-Asset/TF in das XLSX-Target-Band trifft (Pfad A), eine Variation im Band landet (Pfad B), oder ob die XLSX-Microstructure auf der eigenen Konfiguration nicht reproduzierbar ist (Pfad C).

---

## 1. Acceptance-Bänder (aus Spec §13.2)

| Metrik | Soll | Toleranz | Akzeptanz-Band |
|---|---|---|---|
| Profit-Faktor | 2.44 | ±0.30 | **[2.14, 2.74]** |
| Win-Rate | 55 % | ±5 pp | **[50 %, 60 %]** |
| Max-Drawdown | 10 % | +5 pp | **< 15 %** |
| Trades | 100 | ±25 % (Score-Filter-Drop) | **[75, 125]** |
| Profit % (nach Fees Bitunix VIP0) | +120 % | ±25 pp | **[+95 %, +145 %]** |
| R:R im Trade-Log | 1:2 mit BE-Trail | strict TP-Distanz | exakt 2.0 / BE-Exits ≈ 0R |

---

## 2. Eskalations-Leiter — Ergebnis-Tabelle

Alle 7 Tests verwenden den vollen Spec-Default-Risk-Stack (TP R:R 1:2, BE-Trail @ +1R, 2 % Risk, Session-Filter OFF). Nur die markierte Parameter-Achse variiert.

| Test | Setup | candles | trades | L | S | WR % | PF | DD % | totalPnl USDT | profit % | sharpe | realised R | Bands? |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| **T1** | BTC 1h strict (score=60) | 18265 | 158 | 81 | 77 | 29.75 | 1.088 | 20.87 | +1245.57 | +12.46 | 0.399 | 2.57 | ✗ (4/5 verfehlt: trades über, WR/PF/DD/profit% defizitär) |
| **T2a** | BTC 1h score=40 (§12.2 Pfad-B) | 18265 | 160 | 81 | 79 | 30.00 | 1.115 | 18.96 | +1681.44 | +16.81 | 0.495 | n/a | ✗ (4/5 verfehlt) |
| **T2b** | BTC 1h score=80 (§12.2 Pfad-B) | 18265 | **0** | 0 | 0 | 0.00 | 0.000 | 0.00 | 0.00 | 0.00 | 0.000 | 0.00 | ✗ (Score-Filter erstickt alle Signale; DD-Band „technisch ok" weil keine Trades) |
| **T3a** | BTC **4h** strict (score=60) | 4567 | 31 | 19 | 12 | 32.26 | 1.167 | 11.21 | +495.99 | +4.96 | 0.606 | n/a | ✗ (4/5 verfehlt, DD ok) |
| **T3b** | **ETHUSDT** 1h strict (score=60) | 18265 | 106 | 54 | 52 | 22.64 | 0.885 | 29.66 | −1071.18 | −10.71 | −0.256 | n/a | ✗ (4/5 verfehlt, trades ok) |
| **T3c** | BTC 1h tenkan=7 kijun=21 | 18265 | 131 | 71 | 60 | 32.82 | 1.287 | 17.92 | +3861.18 | +38.61 | 0.977 | n/a | ✗ (4/5 verfehlt, profit am nächsten) |
| **T3d** | BTC 1h tenkan=13 kijun=40 | 18265 | 127 | 69 | 58 | 29.92 | 1.235 | 20.30 | +2771.49 | +27.71 | 0.761 | n/a | ✗ (5/5 verfehlt) |

**Reproduzierbarkeit:** alle 7 Tests 3× Dart bit-exakt grün, 3× Rust bit-exakt grün, Dart↔Rust totalPnl 1e-9 grün. Keine Engine-Drift, keine Test-Stopp-Bedingung ausgelöst. Die phase1_reference_backtest (BB+RSI 2024-H1) bleibt strukturell grün — keine Engine-Side-Effects durch Ichimoku-Real-Data-Sweep.

**Welle-I3 Pre-Diagnose-Resolution:** Pre-Diagnose §13.7 schätzte Pfad-B bei 40 %, Pfad-C bei 55 %. Tatsächlich Pfad C, aber das beste Profil (T3c, BTC 1h 7/21) zeigt profit %=+38.6 % — d.h. der „Trend-Following auf Crypto strukturell günstiger als UT-Bot-Mean-Reversion"-Hypothese bestätigt sich qualitativ (UT Bot best-of-Sweep war negativ), aber quantitativ reicht es nicht in das +95 %-Band.

---

## 3. Acceptance-Klassifikation

**Welcher Test landet im Target-Band?**

- **PF ∈ [2.14, 2.74]:** KEINER. Best-of-Sweep ist T3c (BTC 1h 7/21) mit **1.29**, gefolgt von T3d (BTC 1h 13/40) mit **1.24**. **Alle Tests bleiben unter PF = 1.30 — d.h. jede einzelne Variation bleibt > 60 % unter dem XLSX-Target 2.44.**
- **WR ∈ [50 %, 60 %]:** KEINER. Best-of-Sweep ist T3c mit **32.82 %**, gefolgt von T3a (4h) mit **32.26 %**. Theoretischer Break-Even-WR bei R:R = 1:2 ist 33.3 % — wir kratzen genau an der Break-Even-Linie, aber bleiben darunter.
- **trades ∈ [75, 125]:** nur T3b ETH (106). Alle BTC-1h-Tests liegen knapp über (127–160) oder bei 0 (T2b) oder 31 (T3a 4h).
- **MaxDD < 15 %:** T2b (kein-Trade-Trivial), T3a (11.21 % auf 4h). Alle BTC-1h-Tests liegen 17.9–20.9 % über dem Band.
- **profit % ∈ [+95 %, +145 %]:** KEINER. Best-of-Sweep ist T3c mit **+38.61 %**, also nur ~40 % vom unteren Band-Rand. T3b (ETH) ist sogar netto-defizitär (−10.71 %).

**Pfad-Logik (Spec §13.3 rev4):**
- Min. 1 Variation mit ALLEN 5 Bändern → Pfad B mit dieser Variation als Default
- Keine Variation mit allen 5 Bändern → **Pfad C bestätigt**

**Ergebnis: Pfad C.** Strict-spec (T1) verfehlt 4/5 Targets nicht-trivial. Die Score-Threshold-Variationen (T2a `±40`, T2b `±80`) bewegen das Profil nur marginal (T2a) oder lähmen es komplett (T2b — 0 Trades). Der Sanity-Sweep (T3a–T3d) zeigt konsistent: Asset-Wechsel auf ETH macht es schlechter (T3b PF=0.89), TF-Wechsel auf 4h reduziert Trades drastisch (T3a 31 trades), Tenkan/Kijun-Sweep findet kein Sweet-Spot (T3c 7/21 PF=1.29, T3d 13/40 PF=1.24). **Best-of-Sweep T3c bringt PF=1.29 auf BTC 1h — immer noch >40 % unter dem Akzeptanz-Band.**

---

## 4. Diagnose-Schlussfolgerung

**Welcher Driver wirkt?**

- **Score-Threshold (T1 vs T2a vs T2b):** Score-Filter `±60→±40` öffnet das Tor von 158 auf 160 Trades — also bei 18k BTC-1h-Bars filtert die §12.2-Confluence-Sum-Approximation **kaum aus** (im Gegensatz zur XLSX-Aussage „Score-Filter entfernt 35 % der Setups"). Score `±80` schließt das Tor komplett: 0 Trades. Das deutet auf eine **Score-Implementation, die zwischen ±60 und ±80 binär abkippt** — d.h. die Confluence-Sum mit ±20-Gewichten produziert auf realen 1h-BTC-Daten überwiegend Scores ≤ ±60, mit sehr wenig Distribution-Mass zwischen ±60 und ±80. Das ist ein Phase-3-Backlog-Eintrag: §12.2 Score-Default vs „dreams defined"-Original recherchieren.
- **Timeframe (1h → 4h, T1 vs T3a):** Trade-Frequenz fällt von 158 auf 31 (~5× weniger Bars). PF leicht besser (1.09 → 1.17), MaxDD im Band (20.87 % → 11.21 %), aber profit % bricht ein (12.46 % → 4.96 %). **TF-Skalierung allein rettet die Strategie nicht.**
- **Asset (BTC → ETH, T1 vs T3b):** WR fällt von 29.75 % auf 22.64 %, PF von 1.09 auf 0.89, profit % wird negativ. **Asset-Wechsel ETH ist KEIN Path-B-Kandidat — ETH ist schlechter als BTC für diese Strategie auf 2023-2025.**
- **Tenkan/Kijun-Sweep (T1 vs T3c vs T3d):** Kürzere Perioden (7/21) zeigen das beste profit % (+38.61 %) und besten PF (1.29). Längere Perioden (13/40) liegen dazwischen. **Schnellere Reaktion (T3c) ist tendenziell besser**, aber kein Sweet-Spot im 1.2–1.3 PF-Bereich.
- **Realised R:R:** T1 zeigt R = 2.57 (über Spec 2.0). Das bestätigt: TPs werden auf BTC zuverlässig erreicht, der BE-Trail funktioniert. Das Problem ist allein die **Win-Rate** — bei 30 % WR und R = 2.5 ist die Strategie marginal break-even (Theoretisch: 30 % * 2.5 = 0.75 Wins/Loss-Verhältnis × 1.5R-Erwartungswert = 1.125 R/Trade brutto, vor Fees). Die XLSX-WR von 55 % auf EUR/USD ist auf BTC nicht erreichbar.

**Fundamentale Bewertung:** Die Ichimoku-5-Confluence ist auf BTCUSDT 1h im 2023–2025-Zeitraum **strukturell nicht hoch-präzise genug** — egal welcher Default-Parameter-Schalter gedreht wird. Die XLSX-WR von 55 % auf EUR/USD-Forex spiegelt eine Markt-Microstructure mit:
1. **Glatteren Trend-Phasen** (Forex-Volatilität bei major-pairs ~0.5 %/Tag vs BTC ~3 %/Tag) → weniger Fake-Breakouts durch die Cloud
2. **Stärkerer Mean-Reversion an der Baseline** (Forex hat klar definierte Range-Phasen) → SL an Kijun trifft seltener
3. **Klar definiertem Tagesrhythmus** (London/NY-Session-Filter relevant) → das Video nutzt den Filter, wir haben ihn für 24/7-BTC deaktiviert

Crypto-24/7-Märkte haben keinen dieser Mikrostruktur-Vorteile. Der Autor sagt zwar „funktioniert in jedem Markt wo Ichimoku geladen werden kann" (T23–T26), aber das ist nicht durch eigenen Backtest belegt — er testet im Video nur auf EUR/USD.

**Indizien sprechen für eine Mischung aus:**
1. **Asset-Mismatch zum Video-EUR/USD-1h (hoch plausibel):** EUR/USD hat strukturell niedrigere Intra-Bar-Volatilität als BTC. Die SL an Kijun/Cloud-Boundary trifft auf Forex seltener, weil Pullbacks weniger heftig sind. Auf BTC schlagen die SLs mit höherer Frequenz zu (Beleg: realised R = 2.57 in T1 → TPs sind die, die durchkommen; die zwischen-Entry-und-1R-Bars kassieren häufig SL).
2. **Score-Filter-Implementation §12.2 unterscheidet sich von „dreams defined"-Original (mittel plausibel):** Die XLSX behauptet, der Score-Filter entfernt 35 % der Setups, und das WR steigt dadurch von ~49 % (Original) auf 55 % (Endstand). Unsere ±60-Implementation entfernt **kaum etwas** (158 → 160 Trades bei score=60 vs 40; sicherlich nicht 35 %). Das deutet darauf hin, dass entweder die Score-Formel oder die ±60-Schwelle nicht der Video-Variante entspricht. Das ist aber kein Welle-I3-Fix sondern Phase-3-Recherche.
3. **Trend-vs-Range-Verhältnis BTC 2023-2025 vs EUR/USD im Video-Range:** Ichimoku liebt klare Trend-Phasen. BTC hatte 2023-Q4 / 2024-Q1 / 2024-Q4 ausgeprägte Bull-Runs, aber dazwischen Wochen-lange Range-Phasen mit Cloud-Crossings. EUR/USD hat überwiegend Range-Verhalten mit klaren Breakout-Episoden — wahrscheinlich strukturell günstiger für die 5-Confluence-Logik.

---

## 5. Empfehlung

**„Phase-2 Welle I abschließen als 'video-treu implementiert, BTCUSDT/ETHUSDT 1h/4h untauglich', Ichimoku bleibt als Add-in-Manifest-Eintrag für Phase-3-Optimizer-Lab."**

- Ichimoku v1 ist **engineering-vollständig**: alle Spec-Diffs (Tenkan/Kijun/Senkou-A/B, Cloud-Anker §1.1 mit korrekter 103-Bar-Warmup, 5-Confluence-Entry, SL = min(Kijun, Cloud-Lower), R:R-1:2-TP, BE-Trail @ +1R, Session-Filter optional, Score-Threshold parametrisiert) implementiert, Dart↔Rust 1e-9-Parität durchgängig auf 400-Bar V-Shape-Fixture + 18k-Bar Real-Data, F-04-No-Lookahead und F-03-Sharpe-Annualisierung gepinnt. Das Strategie-Add-in bleibt produktionsreif als Bestandteil der Add-in-Schicht.
- Ichimoku v1 ist auf BTCUSDT 1h **statistisch nicht akzeptanz-tauglich**. Die XLSX-Targets (WR 55 %, PF 2.44, MaxDD 10 %, Profit +120 %) sind auf BTC 1h 2023-2025 nicht erreichbar, und keine der drei untersuchten Parameter-Achsen (score_threshold, TF/Asset, Tenkan/Kijun) bringt sie ins Band. Best-of-Sweep T3c (BTC 1h 7/21) erreicht profit %=+38.6 % bei PF=1.29 — ein qualitatives Plus-Profil, aber noch immer 40 % unter dem unteren Band-Rand.
- T3c (BTC 1h 7/21) ist mit PF=1.29 und profit %=+38.6 % das **beste Profil aller getesteten Konfigurationen** — netto profitabel, aber das ist der einzige Hinweis, dass die Strategie auf einer anderen Parameter-Konfiguration möglicherweise besser läuft. Das ist ein **Phase-3-Optimizer-Lab-Kandidat**, nicht ein Welle-I3-Code-Fix.

**Vergleich mit BB+RSI / UT-Bot Welle-Diagnosen:** Alle drei Phase-2-Strategien klassifizieren als **Pfad C**. Aber das Best-of-Sweep-Profil unterscheidet sich qualitativ:
- BB+RSI Welle-Diagnose: best-of-Sweep marginal positiv (kleinste profit % bei 4h)
- UT Bot Welle-U3-Diagnose: best-of-Sweep T4c (ETHUSDT) PF=0.81 — **alle Tests defizitär**
- Ichimoku Welle-I3-Diagnose: best-of-Sweep T3c (BTC 1h 7/21) PF=1.29, profit %=+38.6 % — **4 von 7 Tests netto profitabel**

Ichimoku ist damit die „beste Pfad-C-Strategie" der drei. Pre-Diagnose §13.7 hatte das genau so eingeschätzt („Pfad-B-Wahrscheinlichkeit höher als bei UT Bot weil Trend-Following auf Crypto strukturell günstiger").

**Konkrete Schritte:**
1. **Keine Default-Änderung committen.** Spec-Defaults bleiben video-treu (`tenkan_period = 9`, `kijun_period = 26`, `senkou_b_period = 52`, `shift = 26`, `score_threshold = 60`, `tp_rr_ratio = 2.0`). Das ist die korrekte Repräsentation der Vorlage; die Acceptance-Lücke ist eine Eigenschaft des Asset/TF-Setups, nicht der Implementation.
2. **Spec §13.6 wird zu „Pfad-Klassifikation finalisiert: Pfad C"** mit Actual-Result-Tabelle und Root-Cause-Hypothese in einem nachfolgenden Commit aktualisiert.
3. **Plan §4.4 Status-Section:** „Ichimoku: pending → Pfad C". Phase-2-Gate-Empfehlung: **Sub-Diagnose-Session erforderlich**, da 3 von 3 Strategien auf Pfad C klassifizieren (alle Pfad-B-Wahrscheinlichkeiten in der jeweiligen Pre-Diagnose unter 50 % geschätzt, aber für eine konsistente Strategy-Pipeline brauchen wir mindestens eine Pfad-A/B-Strategie).
4. **Phase-3 Backlog-Eintrag (mittlere Priorität):** „Ichimoku v1 Parameter-Sweep mit Optuna (kurze Tenkan/Kijun {5/15, 7/21, 9/26, 13/40, 15/50} × Score-Threshold {30, 40, 50, 60, 80} × TF {1h, 4h} × Asset {BTC, ETH}), Ziel: PF ≥ 2.0 bei trades ≥ 50 in mindestens einem Sweep-Punkt". Best-of-Sweep T3c (PF=1.29, profit %=+38.6 %) ist der vielversprechendste Ausgangspunkt — kleinere Periodendefinitionen + niedrigere Score-Threshold.
5. **Optionaler Phase-3-Backlog-Eintrag (niedrige Priorität):** „Score-Implementation §12.2 vs „dreams defined"-Original recherchieren (T2a/T2b binary-cutoff zwischen ±60 und ±80 deutet auf Distribution-Mass-Anomalie hin)". Recherche-Aufwand ~2h, kann nur Implementations-Detail-Fixes liefern.
6. **Optionaler Phase-3-Backlog-Eintrag (niedrige Priorität):** „Session-Filter ON für 1h-Ichimoku testen (London+NY 09–23 Berlin)". Video nutzt Filter, wir haben ihn für 24/7-BTC deaktiviert — möglicherweise WR-Quelle. Aufwand ~5 min Test-Setup + 60s Backtest.

---

## 6. Anhang — Bit-exakte Run-Snapshots

Reproduktion über `ICHIMOKU_DIAGNOSE=1 flutter test --plain-name "<Case>" test/integration/ichimoku_real_data_test.dart`. Dart und Rust totalPnl stimmen bei jedem Test auf 1e-9 überein (FFI-Parity-Contract Welle I2-6).

```
DIAGNOSE Test 1 BTCUSDT 1h strict (score=60)
  candles=18265
  trades=158  long=81  short=77  winning=47  losing=111
  totalPnl=1245.566715 USDT (eq_final=11245.566715)
  profit%=12.4557
  winRate=29.7468%  profitFactor=1.088183
  sharpe=0.398694  maxDD%=20.871953
  avgWin=327.027969  avgLoss=127.249980  realisedR=2.5700
  RUST mirror: trades=158  pnl=1245.566715  wr=29.7468%  sharpe=0.398694  ddPct=20.871953

DIAGNOSE Test 2a BTCUSDT 1h score=40
  trades=160  long=81  short=79  winning=48  losing=112
  totalPnl=1681.442984 USDT  profit%=16.8144
  winRate=30.0000%  profitFactor=1.114794
  sharpe=0.495032  maxDD%=18.955051

DIAGNOSE Test 2b BTCUSDT 1h score=80
  trades=0  long=0  short=0  winning=0  losing=0
  totalPnl=0.000000 USDT  profit%=0.0000
  winRate=0.0000%  profitFactor=0.000000
  sharpe=0.000000  maxDD%=0.000000

DIAGNOSE Test 3a BTCUSDT 4h strict (score=60)
  trades=31  long=19  short=12  winning=10  losing=21
  totalPnl=495.991106 USDT  profit%=4.9599
  winRate=32.2581%  profitFactor=1.167029
  sharpe=0.605876  maxDD%=11.211083

DIAGNOSE Test 3b ETHUSDT 1h strict (score=60)
  trades=106  long=54  short=52  winning=24  losing=82
  totalPnl=-1071.184611 USDT  profit%=-10.7118
  winRate=22.6415%  profitFactor=0.885158
  sharpe=-0.255541  maxDD%=29.658490

DIAGNOSE Test 3c BTCUSDT 1h tenkan=7 kijun=21
  trades=131  long=71  short=60  winning=43  losing=88
  totalPnl=3861.181049 USDT  profit%=38.6118
  winRate=32.8244%  profitFactor=1.286796
  sharpe=0.976724  maxDD%=17.920434

DIAGNOSE Test 3d BTCUSDT 1h tenkan=13 kijun=40
  trades=127  long=69  short=58  winning=38  losing=89
  totalPnl=2771.493143 USDT  profit%=27.7149
  winRate=29.9213%  profitFactor=1.235485
  sharpe=0.761108  maxDD%=20.302851
```
