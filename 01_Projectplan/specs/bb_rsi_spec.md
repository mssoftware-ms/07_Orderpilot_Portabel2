# BB+RSI — Specification

**Quelle:** https://youtu.be/5EP3EBy7AGo (Kanal: Aaron / Hauptkanal-Test, Original-Idee von „Trading Laab“)
**Transkript:** `01_Projectplan/transskript bb+rsi.txt`
**Ranking-Eintrag:** Platz 20, Profit 1.0864 (108.64 %) nach 100 Trades, WR 38 %, R:R 1:3, PF 1.88, Max-DD 14 %, Zeitraum 284 Tage
**Asset/TF im Video:** Nasdaq-100-Futures (NQ) im Beispiel-Backtest; Autor sagt explizit „Strategie funktioniert in jedem Markt“ → wir testen auf **BTCUSDT 1h** (Phase-1-Konvention)
**Erstellt:** 2026-05-23
**Spec-Autor:** chat-session phase-2-task-1 (commit folgt)

> **WICHTIG — Drei Varianten im Video:**
> Das Video stellt drei aufeinanderfolgende Varianten vor. Die **XLSX-Ranking-Zahlen (Platz 20) gehören zur dritten = „verbesserten“ Variante.** Diese Spec dokumentiert daher die *verbesserte* Variante als kanonisch und führt die ersten beiden Varianten in §9 als Optimierungs-Historie auf, weil der Autor sie selbst verworfen hat.

---

## 1. Indikatoren (mit Parametern aus Video — kanonische verbesserte Variante)

| Indikator | Parameter | Quelle im Transkript (Zeile) |
|---|---|---|
| Bollinger Bands | Period = **200**, MA-Typ = **EMA**, StdDev-Multiplier = **0.2**, Source = close | T254–T270 („erhöt die Länge … von 30 auf 200 und wird als moving average Typ den EMA aus die Standardabweichung reduzieren wir auf 0,2") |
| RSI | Period = **3**, Levels Oversold = **20**, Overbought = **80**, Source = close | T255–T260 („statt der sehr hohen Länge von 13 reduzieren wir diese auf 3 … Level … 80 und 20") |
| Sessions-Filter | London + New York Session, 09:00–23:00 Lokalzeit | T146–T153 („nur entries suchen die zwischen 9 und 23 Uhr liegen also wähend der volumenstarken London und New York Session") |

> Die BB werden in der verbesserten Variante als **Trendfilter** (nicht mehr als Mean-Reversion-Anker) interpretiert: Preis ÜBER der oberen Band = Uptrend, UNTER der unteren Band = Downtrend. Die Fläche zwischen den Bands ist eine **No-Trading-Zone** (T272 „die Bänder unsere nicht Trading Zone darstellt").

---

## 2. Entry — Long

- **Bedingung 1 (Trend):** Close > BB-Upper (EMA-basiert, Period 200, 0.2σ) — also Preis **über** der gesamten BB-Konstruktion (T274–T278)
- **Bedingung 2 (Trigger):** RSI(3) kreuzt das 20-Level von **unten nach oben** (T279–T280: „warten wir nur noch darauf dass der RSI das 20er Level von unten nach oben kreuzt")
- **Alle Bedingungen MÜSSEN gleichzeitig erfüllt sein.**
- **Bestätigungs-Bar / Execution:** Beim **Open der nächsten Kerze** (T280–T282 „können wir wieder beim Open der nächsten Kerze unseren byrade eröffnen")

---

## 3. Entry — Short

- **Bedingung 1 (Trend):** Close < BB-Lower (EMA-basiert, Period 200, 0.2σ) — also Preis **unter** der gesamten BB-Konstruktion (T294–T296)
- **Bedingung 2 (Trigger):** RSI(3) kreuzt das 80-Level von **oben nach unten** (T297–T298)
- **Alle Bedingungen gleichzeitig.**
- **Execution:** Beim Open der nächsten Kerze (T298–T299)

---

## 4. Exit — Stop Loss

- **Platzierung Long:** unter dem letzten Swing Low / „sin von Tiefpunkt" vor Entry (T282–T283: „der stopl kommt unter den letzten sin von Tiefpunkt bzw Swing low")
- **Platzierung Short:** über dem letzten Swing High / „sin von Hochpunkt" (T300–T301)
- **Logik:** initial **fix**, anschließend **Break-Even-Trail** (siehe §5 Partial-Logik)
- **Update-Regel:** Sobald **1R Profit** (entspricht risk-reward 1:1) erreicht ist → SL auf Entry-Preis ziehen (Break-Even) (T287–T293 „sobald der Preis ein einfaches risk reward von ein Z ein erreicht hat werden wir den StopLoss auf dem Break Even ziehen")

### Algorithmische Swing-Definition (Phase-2-Entscheidung, 2026-05-23)

Der Video-Autor zeichnet Swing-Low/Swing-High manuell. Für die Backtest-Implementierung legen wir folgende deterministische Definition fest (QA-Sign-off Phase-2 Welle-1):

- **Parameter:** `swing_lookback_bars` (Default: **20**, Range 5–100, Step 1)
- **Long-Entry SL:**
  ```
  sl_price = min(low[entry_idx - N .. entry_idx - 1])
  ```
  d. h. das niedrigste `low` der letzten `N` Kerzen **vor** dem Signal-Bar.
- **Short-Entry SL:**
  ```
  sl_price = max(high[entry_idx - N .. entry_idx - 1])
  ```
  d. h. das höchste `high` der letzten `N` Kerzen vor dem Signal-Bar.

**Begründung der Default-Wahl N=20:** Auf 1h-Kerzen entspricht das einem ~Tages-Lookback (24 Stunden ≈ 24 Kerzen, abgerundet 20 für Round-Number-Robustheit). Long genug um plausible Swings zu erfassen, kurz genug für reaktive SL-Platzierung. Bei Bedarf optimierbar in Phase 3.

**Phase-3 Alternative (nicht in Welle 2):** ATR-basierter SL über die UT-Bot-Strategy, sobald deren ATR-Indikator integriert ist. Beide Varianten bleiben dann als optimierbarer Schalter im Strategie-Manifest.

**Implementierungs-Status (Stand Welle-1):** noch nicht implementiert; SL-Placeholder im Code ist aktuell `bb.middle` (geometrisch aus den BB). Welle 2 ersetzt das durch obige Swing-Definition (Diff D-07).

---

## 5. Exit — Take Profit

- **Methode:** **R:R 1:3** (TP-Distanz = 3 × SL-Distanz vom Entry) (T284–T285 „für den Tech Profit ziehen wir auf ein risk reward von 1:3 ab")
- **Partial TP:** **Nein.** Der Autor zieht nicht teilweise glatt, sondern setzt bei 1R den SL auf Break-Even (siehe §4 Update-Regel) und lässt den Trade ansonsten unverändert bis TP / BE-Stop läuft.
- **Trailing nach TP:** Nicht erwähnt (Trade endet bei TP-Treffer).

---

## 6. Exit — Signal (regulär)

- **Im Video nicht erwähnt → default: keine signal-basierten Exits.** Position bleibt bis entweder TP oder SL/BE-Stop trifft.
- Insbesondere **kein** „Exit bei BB-Mitte" oder „Exit bei gegenüberliegendem RSI-Extrem" — das wäre ein Mean-Reversion-Konstrukt und passt nicht zur Trendfolge-Logik der verbesserten Variante.

---

## 7. Filter / Zusatzregeln

- **Trendfilter:** Ja — die EMA-200-basierten BB(0.2σ) sind selbst der Trendfilter (siehe §1, §2, §3). Es gibt keinen *zusätzlichen* externen Trendfilter.
- **Volatilitätsfilter:** Im Video nicht erwähnt → default: keine Restriktion.
- **Session-Filter:** Ja — Entries nur zwischen **09:00 und 23:00** (Lokalzeit des Autors, mutmaßlich Berlin = London-Open bis New-York-Close, T149–T151). Außerhalb dieses Fensters: keine neuen Entries; offene Positionen laufen weiter bis SL/TP.
- **Re-Entry nach SL:** Im Video nicht erwähnt → default: erlaubt, sobald wieder ein gültiges Entry-Setup erscheint.
- **Maximal offene Positionen:** 1 (impliziert durch die Linearität der Erzählung; im Video nicht explizit erwähnt → default 1).

---

## 8. Position Sizing

- **Risk pro Trade:** **2 % des Equity** (T164–T166 „bei 2% Risiko pro Trade und unserem festen risk reard von 1 Z2 bei 8% Verlust herauskommen" — Bezug ist Strategie 2, übernommen für Strategie 3 da nicht widersprochen)
- **Formel:** `position_size = (equity × 0.02) / abs(entry − sl)`
- **Pyramiding:** Nein (max 1 Position, siehe §7).
- **Gebühren-Annahme im Video:** 0.1 % pro Trade (T326 „Nachgebühren von 0,1% pro Trade liegen wir entsprechend 10% darunter") — abweichend von Phase-1-Konvention (Bitunix VIP0 = 0.06 %).

---

## 9. Besonderheiten / Optimierungen vom Video-Autor

Der Autor durchläuft drei Iterationen. Reihenfolge und Begründungen aus dem Transkript:

| Iteration | BB | RSI | Entry-Logik | R:R | Ergebnis 100 Trades | Verworfen weil… |
|---|---|---|---|---|---|---|
| **Variante 1** „Original tradinglap" (T78–T184) | SMA, 30, 2.0 | 14, 25/75 | Bullische/bärische **Divergenz** zwischen Preis und RSI (versteckt + regulär) + Preis außerhalb BB | 1:2 | WR 32 %, ~−8 % nach Gebühren, MaxDD 22 % | „späte Bestätigung der Divergenz" — Preis schon weggelaufen wenn Signal erscheint |
| **Variante 2** „BB-Close + RSI-Cross" (T188–T240) | SMA, 30, 2.0 | 14, 25/75 | Preis außerhalb BB + RSI im Extrem + RSI **kreuzt zurück** durch Level | 1:2 | WR 40 %, +33.8 % (vor Gebühren 23.8 %), MaxDD 20 % | Profitable aber Underperformance vs Buy-and-Hold NDX (~50 %) |
| **Variante 3** „verbessert" ← **KANONISCH** (T251–T336) | **EMA, 200, 0.2** (Trendfilter) | **3, 20/80** | Preis JENSEITS der BB (Trendseite) + RSI(3) kreuzt 20 bzw 80 | **1:3** | WR 38 %, **+108 %** (Nachgebühren 98 %), MaxDD ~14 %, NQ-Outperformance gegen ~20 % | — (gewählt) |

**Konzeptioneller Bruch zwischen Variante 2 und 3:**
- Variante 1+2 = **Mean Reversion**: BB-Touch ist „weit weg vom Mittelwert" → setze auf Reversion zur Mitte.
- Variante 3 = **Trendfolge mit Pullback**: BB-Touch markiert *Trendrichtung*; RSI-Cross zurück ist der **Pullback-Re-Entry** im Trend.

Diese Unterscheidung ist für die Code-Diff entscheidend: die existierende Implementierung folgt erkennbar einem Mean-Reversion-Pattern (BB Period 20, σ 2.0, RSI(14) 30/70, Exit bei BB-Mitte), passt also weder zu Variante 2 (kein RSI-Cross-Trigger) noch zu Variante 3 (kein EMA-Trendfilter, falsche RSI-Periode, kein R:R 1:3).

---

## 10. Bekannte Limitierungen / Warnungen vom Autor

- **Erfolgsabhängig vom Risikomanagement und Stop-Loss-Erfahrung** (T340–T349 „in diesem Fall die Erfahrung wo der StopLoss platziert werden muss"). Das **Swing-Low/High für SL ist subjektiv** — algorithmische Definition fehlt.
- **Psychologische Komponente:** Autor warnt vor Strategy-Switching nach „sieben Trades in Folge verlieren" (T352–T354).
- **WR ist niedrig (38 %)** — die Strategie ist nur durch das **R:R 1:3** profitabel; bei R:R-Drift unter 1:2 droht Negativität.
- **Backtest-Zeitraum nur 284 Tage / 100 Trades** — schwache statistische Signifikanz (Variante 3 hat den Schluss-Drawdown von Variante 2 nicht erlebt).

---

## 11. Mapping Spec → Code

(Das ist die Brücke zum Diff-MD; hier stehen *welche* Code-Funktionen die jeweilige Spec-Regel abbilden müssten — ob sie sie korrekt abbilden ist Sache der Diff-Analyse.)

| Spec-Bedingung | Code-Datei | Funktion / Block | Aktueller Status (Vorschau) |
|---|---|---|---|
| BB-Parameter (EMA, 200, 0.2) | `rust/trading_engine/src/addins/bb_rsi.rs` | `calc_bollinger_bands` (Zeile 55) + `bb_rsi_manifest()` defaults | **Abweichung** — Code nutzt SMA, Default 20, 2.0 |
| BB-Parameter Dart | `lib/services/backtest_service.dart` | `BbRsiParams` (Zeile 49–71) | **Abweichung** — Defaults 20, 2.0 |
| RSI(3) statt RSI(14) | beide | manifest defaults / `BbRsiParams` | **Abweichung** — Code nutzt 14 |
| RSI-Levels 20/80 statt 30/70 | beide | manifest defaults | **Abweichung** — Code nutzt 30/70 |
| Long-Entry: Close > BB-Upper + RSI-Cross-Up durch 20 | `bb_rsi.rs:237` | `if price <= bb.lower && rsi < rsi_oversold` | **Fundamental anders** — Code triggert auf BB-**unten**-Touch (Mean Reversion) |
| Short-Entry: Close < BB-Lower + RSI-Cross-Down durch 80 | `bb_rsi.rs:245` | `if price >= bb.upper && rsi > rsi_overbought` | **Fundamental anders** — Code triggert auf BB-**oben**-Touch |
| RSI-**Cross**-Logik (Level wird durchquert, nicht Level-Wert) | beide | – | **Fehlt komplett** — Code prüft nur Schwellwert, keinen Cross |
| Exit: TP bei R:R 1:3 + BE-Stop bei 1R | beide | – | **Fehlt komplett** — Code hat Exit-bei-BB-Mitte/RSI-Gegenseite, keinen R-basierten TP, keinen BE-Trail |
| Session-Filter 09:00–23:00 | beide | – | **Fehlt komplett** |
| Risk pro Trade 2 % + Sizing-Formel | `lib/services/backtest_service.dart:243–272` | `_PendingEnterLong` Fill | **Abweichung** — Code allokiert *gesamten* `balance` auf den Trade (kein Risk-Sizing) |
| SL = letztes Swing Low/High | beide | `Signal::long(Some(bb.lower − (bb.middle − bb.lower)), …)` (bb_rsi.rs:241) | **Abweichung** — Code setzt SL geometrisch aus BB (Reflection unter Lower-Band) |
| Trendfilter EMA-200 als Pre-Condition | beide | – | **Fehlt** (BB(20, SMA) ≠ EMA(200)) |

---

## 12. Abweichungen von der Vorlage (bewusst)

Diese Section dokumentiert Abweichungen, bei denen die Implementierung *bewusst* von der Video-Vorlage abweicht. Übrige Code-vs-Spec-Diffs stehen im **Diff-MD** (`bb_rsi_diff.md`).

**12.1 Phase-1-Erbe (Mean-Reversion-Testvehikel)**
- **Abweichung:** Die Phase-1-Implementierung wurde nicht aus dieser Video-Spec abgeleitet, sondern als generisches BB+RSI-Mean-Reversion-Pattern aufgesetzt (siehe Phase-1-Plan §3.5, Reference-Backtest BTCUSDT 1h 2024-H1).
- **Begründung:** Phase 1 hatte das Ziel „Engine-Korrektheit beweisen", nicht „Video-Strategy exakt reproduzieren". Die BB+RSI-Logik in Phase 1 ist daher eher ein **Testvehikel** als die finale Strategie.
- **Konsequenz für Phase 2:** Code wird in Welle 1 (Diff D-01..D-05, D-11) auf die Spec-Trendfolge umgestellt und in Welle 2 (D-06..D-09) auf Risk-2 %/R:R-1:3-Sizing.

**12.2 Algorithmische Swing-Definition für SL (D-07-Entscheidung)**
- **Abweichung:** Der Video-Autor zeichnet Swing-Low/Swing-High manuell. Wir verwenden stattdessen eine deterministische `swing_lookback_bars`-Definition (siehe §4: rolling `min(low)` / `max(high)` über die letzten N Kerzen vor Signal-Bar; Default N=20).
- **Begründung:** (a) Reproduzierbarkeit — manuelle Swing-Auswahl ist nicht backtestbar. (b) Walk-Forward — der Optimizer in Phase 3 kann N tunen. (c) ATR-basierte Variante wird über die UT-Bot-Strategy nachgereicht.
- **Konsequenz:** Backtest-Trades können sich von „handgepickten" Swings des Autors leicht unterscheiden; die R:R-1:3-Akzeptanz aus §13 bleibt aber direktes Soll-Maß.

---

## 13. Acceptance für Implementierung

Backtest auf **BTCUSDT 1h** über **284 Tage** (Video-Zeitraum), aktuell zu wählen z. B. **2024-01-01 … 2024-10-11** (1h, mind. 100 Trades realisiert):

| Metrik | Video-Wert (XLSX Platz 20) | Toleranz | Akzeptanz-Band |
|---|---|---|---|
| Profit-Faktor | **1.88** | ±0.30 | [1.58, 2.18] |
| Win-Rate | **38 %** | ±5 pp | [33 %, 43 %] |
| Max-Drawdown | **14 %** | +5 pp | < 19 % |
| Trades (100-Trade-Reihe) | **100** | ±20 % | [80, 120] |
| Profit nach 100 Trades | **+108.64 %** (vor Gebühren), **+98.64 %** (nach 0.1 % Gebühren) | ±25 pp | [+83 %, +133 %] vor Gebühren |
| R:R durchschnittlich | **1:3** (fix) | strict | exakt 3.0 (BE-Stop akzeptiert) |

**Hinweis zu Acceptance bei Bitunix-Gebühren:** Phase-1-Konvention nutzt 0.06 % (Bitunix VIP0), Video nutzt 0.1 %. Bei 0.06 % sollte der Nachgebühren-Profit *höher* liegen als die 98.64 % aus dem Video — z. B. ~104 % bei 100 Trades à 1 % Notional. Toleranz wird auf die Vor-Gebühren-Zahl angewendet, dann separat verifiziert dass Gebühren-Anteil < 12 % des Brutto-Profits ist.

**Plus (Engine-Korrektheits-Gate, Phase-1 Vorgabe bleibt):**
- Unit-Tests pro Entry-/Exit-Bedingung (TDD-Stil) grün — neu: `test_long_entry_close_above_bb_and_rsi_cross_up`, `test_short_entry_close_below_bb_and_rsi_cross_down`, `test_breakeven_after_1r`, `test_session_filter_blocks_off_hours`, …
- Dart↔Rust-Parität 1e-9 auf einer 200-Candle-Synthese-Fixture **mit den neuen Defaults**
- Phase-1-Reference-Backtest (BTCUSDT 1h 2024-H1) bleibt strukturell grün: Reproduzierbarkeit (3×), Dart↔Rust-Parität, `totalTrades > 0`. **Die numerischen Werte (pnl, winRate, sharpe, maxDD, trades) werden sich verschieben** — der Test asserted darauf nicht hart, aber der gedruckte Report-Wert (Phase-1-Diagnoselauf: pnl ≈ −2071.38 USDT, 139 Trades) ist Geschichte und muss in Phase 2 neu dokumentiert werden.
