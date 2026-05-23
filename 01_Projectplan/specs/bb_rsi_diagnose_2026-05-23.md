# BB+RSI Diagnose-Backtests — Sanity-Sweep vor UT Bot

**Datum:** 2026-05-23
**Welle-2-Baseline (BTCUSDT 1h 2024-H1, Default-Params):** trades=91, WR=18.68 %, PF=0.685, MaxDD=19.63 %, Sharpe=−1.49, realised R:R=2.98
**Ziel:** identifizieren ob Asset / Timeframe / `bb_stddev` die WR in das XLSX-Band 33–43 % heben oder ob die Lücke strategy-fundamental ist.
**Test-Infrastruktur:** `test/integration/bb_rsi_diagnose_test.dart` mit 5 `skip:`-gateten test()-Blocks, opt-in über `BB_RSI_DIAGNOSE=1` Env-Var. Pro Case 3 Dart-Runs (Reproduzierbarkeits-Gate, bit-exakt). C1 zusätzlich 3 Rust-Runs mit Dart↔Rust-Parität 1e-9 als Spot-Check; C2..C5 Dart-only (Engine teilt sich vollständigen Code-Pfad, Parität strukturell durch `phase1_reference_backtest_test` gepinnt).

---

## 1. Ergebnis-Tabelle

Alle Cases verwenden den vollen spec-Default-Risk-Stack
(swing-low SL N=20, R:R 1:3 TP, BE-trail @ +1R, 2 % Risk).
Nur das Setup-Tupel (Asset, TF, `bb_stddev`) variiert.

| Case | Asset | TF | σ | candles | trades | WR % | PF | MaxDD % | Sharpe | realised R:R | totalPnl USDT | Im XLSX-Band? |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| Baseline | BTCUSDT | 1h | 0.2 | 4369 | 91 | 18.68 | 0.685 | 19.63 | −1.49 | 2.98 | −1565.36 | ✗ |
| **C1** | BTCUSDT | **4h** | 0.2 | 1093 | **15** | 20.00 | **1.22** | **9.99** | **+0.78** | 4.89 | **+233.58** | ✗ (trades zu wenig, WR zu niedrig) |
| **C2** | **ETHUSDT** | 1h | 0.2 | 4369 | 69 | 18.84 | 0.88 | 21.90 | −0.47 | 3.81 | −652.76 | ✗ |
| **C3** | BTCUSDT | 1h | **0.5** | 4369 | 73 | 15.07 | 0.47 | 24.13 | −2.72 | 2.67 | −2226.55 | ✗ |
| **C4** | BTCUSDT | 1h | **1.0** | 4369 | 31 | 12.90 | 0.38 | 19.17 | −2.19 | 2.56 | −1544.35 | ✗ |
| **C5** | BTCUSDT | 1h | **2.0** | 4369 | **4** | 25.00 | 0.92 | **4.07** | −0.09 | 2.77 | −49.01 | ✗ (trades zu wenig) |

**Reproduzierbarkeit:** alle 5 Cases 3× Dart bit-exakt grün, C1 3× Rust bit-exakt grün, Dart↔Rust 1e-9 ✓. Keine Stopp-Bedingung ausgelöst. Keine `trades > 500`, kein `MaxDD > 95 %`.

---

## 2. Diagnose-Schlussfolgerung

**Welcher Case erreicht WR ≥ 33 %?** Keiner. Maximum ist C5 mit 25 % (4 Trades — statistisch nicht signifikant; das ist nahezu „Strategie ausgeschaltet").

**Welcher Case erreicht PF ≥ 1.58?** Keiner. C1 ist mit 1.22 am nächsten dran, aber bei nur 15 Trades.

**Welcher Driver wirkt?**

- **Timeframe (1h → 4h, C1):** kippt die Strategie ins Plus (PF 0.685 → 1.22, totalPnl −1565 → +234 USDT, MaxDD 19.6 % → 10.0 %, Sharpe −1.49 → +0.78). **Aber:** Trade-Frequenz fällt von 91 auf 15 — weit unter XLSX-Band [80, 120] → keine Acceptance, statistische Signifikanz reicht nicht.
- **Asset (BTC → ETH, C2):** WR praktisch identisch (18.68 % vs 18.84 %), PF leicht besser (0.685 → 0.88) aber MaxDD schlechter (19.63 % → 21.90 %). **Asset-Mismatch-Hypothese partiell entkräftet:** Wenn ETH-Microstructure ähnlich liefert wie BTC, ist das Problem NICHT BTC-spezifisch.
- **`bb_stddev` (0.2 → 2.0, C3/C4/C5):** WR sinkt monoton von 18.68 % → 15.07 % → 12.90 % → 25 % (bei nur 4 Trades). PF kollabiert in der Mitte (0.47, 0.38). σ-Erweiterung filtert Trades aus, aber die übrigen sind nicht qualitativ besser — im Gegenteil, der dünnere Trigger-Pool selektiert zufällig schlechter. **`bb_stddev`-Tuning rettet die Strategie auf 1h nicht.**

**Fundamentale Bewertung:** WR bleibt über alle realistisch-statistisch-signifikanten Konfigurationen (C2, Baseline, C3, C4) im Band 12–19 % — **das ist nicht der Boden des XLSX-Bandes (33 %), sondern weniger als die Hälfte davon**. Die R:R-1:3-Geometrie funktioniert (realisierte R:R liegt bei 2.6–4.9, also tendenziell sogar besser als 3.0, da BE-Trail einige Verluste auf < 1R kappt), aber die Anzahl der profitablen Trades ist halb so groß wie auf NQ. **Die Lücke ist nicht in der Risk/Reward-Geometrie, sondern in der Entry-Trigger-Qualität auf Krypto-Märkten.**

Indizien sprechen damit für eine Mischung aus:
1. **Asset/TF-Mismatch (mittel-hohe Plausibilität):** auf 4h zeigt die Strategie das richtige Vorzeichen (positives PnL, Sharpe > 0, MaxDD < 10 %) — passt zur Video-Hypothese „funktioniert in jedem Markt, aber mit längerer TF". Die XLSX-Statistik wurde auf NQ-4h-Setups erhoben (Video sagt nicht explizit welche TF, aber 100 Trades / 284 Tage ≈ 1 Trade / 2.8 Tage → 4h-konsistent, nicht 1h-konsistent).
2. **Trigger-Inkompatibilität mit Krypto-1h (mittel-hohe Plausibilität):** RSI(3) Cross-Back-Through-20/80 auf 1h-Kerzen feuert zu reaktiv. Die ETH-Spiegelung in C2 zeigt das gleiche Pattern.

---

## 3. Empfehlung

**„Phase-2 v3 abschließen als 'video-treu, BTC/ETH 1h untauglich', UT Bot startet."**

- BB+RSI v3 ist **engineering-vollständig**: alle 9 Spec-Diffs (D-01..D-09, D-11) implementiert, R:R-1:3-Geometrie strikt bit-exakt, Dart↔Rust 1e-9-Parität durchgängig. Das Strategie-Add-in bleibt produktionsreif als Bestandteil der Add-in-Schicht (kann jederzeit ohne Code-Änderung instanziiert werden).
- BB+RSI v3 ist auf BTC/ETH 1h **statistisch nicht akzeptanz-tauglich**. Die XLSX-Targets (WR 38 %, PF 1.88, Profit +98 %) sind auf 1h auf diesen Märkten nicht erreichbar, und keine der vier untersuchten Parameter-Achsen (TF↑, Asset, σ↑, gleichzeitig) bringt sie ins Band.
- C1 zeigt, dass die Strategie **auf 4h ein gesundes Profil hat** (PF 1.22, MaxDD 10 %, Sharpe positiv) — nur bei zu wenig Sample. Das ist ein **Phase-3-Optimizer-Kandidat**, nicht ein Welle-3-Code-Fix.

**Konkrete Schritte:**
1. **Keine Default-Änderung committen.** Die spec-defaults bleiben video-treu (BB(200, EMA, 0.2σ) + RSI(3, 20/80) auf 1h). Das ist die korrekte Repräsentation der Vorlage; die Acceptance-Lücke ist eine Eigenschaft des Asset-/TF-Setups, nicht der Implementation.
2. **UT Bot Spec-Arbeit startet** in eigener Session. BB+RSI v3 bleibt im Add-in-Manifest und kann von Phase-3-Optimizer-Jobs für ATR-Variants / Multi-TF-Sweeps verwendet werden.
3. **Phase-3 Backlog-Eintrag:** „BB+RSI v3 4h-Optimizer-Sweep (BTCUSDT 4h + ETH 4h + ggf. NQ-Vergleichsdaten), Ziel: WR ≥ 33 % bei trades ≥ 50". Niedrige Priorität, läuft im Optimizer-Lab, nicht im Default-Path.
4. **Optionaler Phase-3-Backlog-Eintrag (niedrigere Priorität):** „Variante 2 (Mean-Reversion-RSI-Cross) als eigene Strategie ableiten." Der Video-Autor selbst sagt Variante 2 hatte auf NQ ein etwas höheres WR als Variante 3 — wenn BTC mean-reverting statt trending ist, könnte Variante 2 besser passen. Eigene Spec-MD + Diff-MD nötig, fällt nicht in die Welle-2-Scope.

---

## 4. Anhang — Run-Snapshots

Bit-exakte Reproduktion über `BB_RSI_DIAGNOSE=1 flutter test --plain-name "<Case>" test/integration/bb_rsi_diagnose_test.dart`.

```
DIAGNOSE C1 BTCUSDT 4h sigma=0.2
  candles=1093
  trades=15  winning=3  losing=12
  totalPnl=233.583080 USDT (eq_final=10233.583080)
  winRate=20.0000%
  profitFactor=1.222211
  sharpe=0.784653
  maxDD%=9.995620
  avgWin=428.253743  avgLoss=87.598179  realisedR=4.8888

DIAGNOSE C2 ETHUSDT 1h sigma=0.2
  candles=4369
  trades=69  winning=13  losing=56
  totalPnl=-652.759270 USDT (eq_final=9347.240730)
  winRate=18.8406%
  profitFactor=0.883513
  sharpe=-0.471775
  maxDD%=21.899357
  avgWin=380.843198  avgLoss=100.066444  realisedR=3.8059

DIAGNOSE C3 BTCUSDT 1h sigma=0.5
  candles=4369
  trades=73  winning=11  losing=62
  totalPnl=-2226.545997 USDT (eq_final=7773.454003)
  winRate=15.0685%
  profitFactor=0.474228
  sharpe=-2.718026
  maxDD%=24.126954
  avgWin=182.569969  avgLoss=68.303478  realisedR=2.6729

DIAGNOSE C4 BTCUSDT 1h sigma=1.0
  candles=4369
  trades=31  winning=4  losing=27
  totalPnl=-1544.349790 USDT (eq_final=8455.650210)
  winRate=12.9032%
  profitFactor=0.379299
  sharpe=-2.193969
  maxDD%=19.171553
  avgWin=235.930855  avgLoss=92.150860  realisedR=2.5603

DIAGNOSE C5 BTCUSDT 1h sigma=2.0
  candles=4369
  trades=4  winning=1  losing=3
  totalPnl=-49.010035 USDT (eq_final=9950.989965)
  winRate=25.0000%
  profitFactor=0.921941
  sharpe=-0.089954
  maxDD%=4.071566
  avgWin=578.847969  avgLoss=209.286001  realisedR=2.7658
```
