# Ichimoku Cloud Retest — Specification

**Quelle:** https://youtu.be/qqbGvb0pjrI ("Ichimoku Cloud Retest: KI-optimierte Trading Strategie für 130% Profit – So klappt's!")
**Transkript:** `01_Projectplan/transskript ichimoku cloud retest.txt`
**Ranking-Eintrag:** Sheet 1 Platz **11**, TF **1h**, R:R **1:2**, Zeitraum **760 Tage**, WR **55 %**, Profit nach 100 Trades **+130 %**, MaxDD **10 %**, PF **2.44**, AAR **0.6243**. (Sheet 2 "Gap bereinigt": Platz 10 — identische Zahlen, also kein Sheet-Unterschied wie bei UT Bot.)
**Asset/TF im Video:** **EUR/USD 1h** im Forex-Markt (T20–T28: „sind auf dem Euro US-Dollar im Forex Markt unterwegs … wir uns wieder stundenkerzen anzeigen"). Autor sagt explizit „ihr könnt die Strategie aber in jedem Markt anwenden wo der chimoko geladen werden kann" (T23–T26).
**Erstellt:** 2026-05-23
**Spec-Autor:** chat-session phase-2-task-3 (commit folgt)

> **WICHTIG — Zwei Varianten im Video + ein Vorgänger-Video:**
> Das Video stellt sich selbst als **Retest** einer 18-Monate-älteren Original-Strategie vor (T1–T18). Daraus entstehen drei Iterationen im XLSX-Ranking:
> 1. **Original (Vorgänger-Video, ca. 2024-Q4):** XLSX Sheet 1 Platz **28** — „Durchbruch im Trading: 100x getestete Ichimoku Cloud Strategie" (https://youtu.be/nZsEsRd6OTQ), 1h, R:R 1:2, 334 Tage, **WR 49 %, Profit +94 %**, MaxDD 8 %, PF 1.92. **Im aktuellen Transkript nur als Referenz erwähnt („94% Profit nach 100 Trades", T11–T15) — nicht reimplementiert.**
> 2. **Retest-Zwischenstufe „nur Risikomanagement angepasst":** Im Transkript T160–T172. **WR 57 %, Profit +112 %, MaxDD 14 %.** Verbesserung: SL großzügiger an Baseline/Cloud statt knapp am Entry. **Vom Autor selbst nicht als Endprodukt klassifiziert.**
> 3. **Retest-Endstand „mit Ichimoku-Score-Filter" ← KANONISCH (XLSX-Platz 11):** Im Transkript T197–T291. **WR 55 % (XLSX) bzw. 60 % (Video-Audio T262, dann revidiert „3 % über erstem Ergebnis" T276–T277 ≈ 57 %), Profit +130 %, MaxDD 10 %, PF 2.44.** Verbesserung gegenüber Zwischenstufe: zusätzlicher Ichimoku-Score-Indikator als 5. Confluence-Bedingung filtert „qualitativ schlechtere Signale" heraus (T237–T240).
>
> Die **XLSX-Ranking-Zahlen (Platz 11) gehören zum Retest-Endstand (3.).** Diese Spec dokumentiert daher die *Endstand-Variante* als kanonisch. Die Zwischenstufe (2.) und das Vorgänger-Original (1.) werden in §9 als Iterations-Historie aufgeführt.

> **Architektur-Hinweis Green-Field:**
> Anders als der Phase-1-Plan annimmt („Strategien (aktuell im Code): bb_rsi.rs, ichimoku.rs, ut_bot.rs", §1 Header), existiert **`ichimoku.rs` aktuell nicht im Repo.** Stand HEAD = `74a08b9`, enthält `rust/trading_engine/src/addins/` nur `bb_rsi.rs` und `ut_bot.rs`. Section 11 mappt die Spec daher auf **geplante** Code-Locations; ein begleitender Engineering-Plan (`ichimoku_engineering_plan.md`) dokumentiert die Implementierungs-Wellen.

> **Asset-Mismatch-Vorab-Hinweis:**
> Das Video läuft auf **EUR/USD 1h Forex** — wir haben **keinen direkten EUR/USD-Feed über Binance**. Backtest erfolgt auf **BTCUSDT 1h** (Phase-1-Konvention) als bewusste Path-B-Abweichung. Begründung in §12.1. Konzeptionell ist Ichimoku ein reiner Trend-Following-Indikator (keine Mean-Reversion-Komponente wie UT-Bot-SMI), daher wird die Asset-Migration-Wahrscheinlichkeit erfolgreicher eingeschätzt als bei UT Bot — siehe Pre-Diagnose im Brief an QA.

---

## 1. Indikatoren (mit Parametern aus Video — kanonische Retest-Endstand-Variante)

| Indikator | Parameter | Quelle im Transkript (Zeile) |
|---|---|---|
| **Tenkan-Sen** (Conversion Line) | Periode = **9**, Berechnung `(high_max(9) + low_min(9)) / 2`, **kein Shift** | T31–T35 („wir bedienen uns am Standard von Trading view … wobei wir in der Input Section die Werte beibehalten"), Style: Grün (T36–T37) |
| **Kijun-Sen** (Base Line) | Periode = **26**, Berechnung `(high_max(26) + low_min(26)) / 2`, **kein Shift** | T31–T35 (Standard), T52–T54 (Funktion „rote baseline … kurz bzw langfristige markteinstiege") |
| **Senkou-Span A** (Leading Span A) | Berechnung `(Tenkan + Kijun) / 2`, **Shift +26 Bars FORWARD** | T31–T35 (Standard), T59–T64 („die Wolke … läuft 26 Perioden vor dem Preis und bestätigt den Trend") |
| **Senkou-Span B** (Leading Span B) | Periode = **52**, Berechnung `(high_max(52) + low_min(52)) / 2`, **Shift +26 Bars FORWARD** | T31–T35 (Standard), T59–T64 |
| **Chikou-Span** (Lagging Span) | Berechnung `close[i]`, **Shift −26 Bars BACKWARD** (visuell), Vergleichs-Anker bei `close[i] vs cloud[i-26]` | T65–T70 („gelben Leggings span der … 26 Perioden hinter dem Preis herläuft und als zusätzliche Bestätigung des Trends dient") |
| **Cloud (Wolke)** | Bereich zwischen Senkou-Span A und Senkou-Span B; **„grün" wenn Senkou_A > Senkou_B, „rot" wenn Senkou_A < Senkou_B**, 30 % Transparenz im Video-Chart (visuell), 26 Bars vor dem Preis projiziert | T44–T64 |
| **Ichimoku Score** ([dreams defined], MultiTF) | Default-Gewichtungen aus Indikator-Standard. **Perioden + Displacement um Faktor 4 erhöht** (Tenkan 9→36, Kijun 26→104, Senkou-B 52→208, Displacement 26→104), damit der Indikator das 4h-Verhalten auf dem 1h-Chart liefert ohne explizites Multi-TF-Setting (das laut Autor zu Repaint-Risiko führt, T220–T234). **Score-Bereich „grün" = Long-Setup-Bestätigung, „rot" = Short-Setup-Bestätigung.** Konkreter Schwellwert nicht numerisch im Video genannt. **Siehe §12.2 für Implementations-Default.** | T200–T217 (Score-Indikator auswählen + Standard-Einstellungen), T217–T234 (Faktor-4-Skalierung für MTF-Verhalten ohne Repaint), T243–T250 (Score grün/rot als Confluence-Bedingung) |
| **Sessions-Filter** | London + New York Session, Lokalzeit Berlin **09:00–23:00** (analog UT Bot Spec §7) | T143–T155 („ich werde nur entries suchen die zwischen 9 und 23 Uhr liegen also während der volumenstarken London und New York Session") |

### 1.1 Senkou-Span-Shift-Konvention (kritisch für Backtest-Korrektheit)

Die Senkou-Spans werden **visuell** 26 Bars in die Zukunft projiziert. Für den Backtest gibt es daher **drei mögliche Lese-Anker** pro Span, die in der Implementierung sauber unterschieden werden müssen:

| Anker | Was bedeutet das? | Welche Quell-Bar liefert den Wert? |
|---|---|---|
| **Cloud-bei-i (current cloud)** | Wert der Cloud an der aktuellen Bar-Position i, wie sie auf dem Chart zum Trigger-Zeitpunkt aussieht | Senkou_A_i wurde aus Tenkan_{i-26} und Kijun_{i-26} berechnet. Senkou_B_i wurde aus `high_max(52)_{i-26}` und `low_min(52)_{i-26}` berechnet. **Past-data only** — kein Look-Ahead. |
| **Cloud-bei-i+26 (future cloud)** | Wert der Cloud 26 Bars voraus, wie sie auf dem Chart visuell „vor dem Preis" gezeichnet ist | Senkou_A_{i+26} wird aus Tenkan_i und Kijun_i berechnet. Senkou_B_{i+26} wird aus `high_max(52)_i` und `low_min(52)_i` berechnet. **Werte sind bei Bar i bekannt** — kein Look-Ahead. Nur die visuelle Anzeige ist 26 Bars verschoben. |
| **Chikou-Vergleichs-Anker (close_i vs cloud_{i-26})** | Chikou-Span ist `close[i]`, visuell bei Bar-Position `i-26` gezeichnet. Bedingung „Chikou oberhalb Cloud" = `close_i > Cloud-bei-{i-26}` | Cloud-bei-{i-26} wurde aus Bar-Daten bei `i-52` berechnet. Das ist Past-data weit aus der Vergangenheit. **Kein Look-Ahead.** |

**Backtest-Trigger-Logik bei Bar i (alle Werte aus Past-data verfügbar):**
- Bedingung „Preis über Cloud" → `close_i > max(Senkou_A_i, Senkou_B_i)` mit Werten von Bar i-26
- Bedingung „Future-Cloud grün" → `Senkou_A_{i+26} > Senkou_B_{i+26}` berechnet aus heutigen Bar-i-Werten
- Bedingung „Tenkan über Kijun" → `Tenkan_i > Kijun_i`
- Bedingung „Chikou über Cloud" → `close_i > max(Senkou_A_{i-26}, Senkou_B_{i-26})` mit Werten aus Bar i-52

**Mindest-Warmup für volle Ichimoku-Confluence:** `max(senkou_b_period, 2 * shift + senkou_b_period - 1) = 103 Bars` (default-params: senkou_b=52, shift=26).

**Herleitung** (korrigiert 2026-05-23 nach Welle-I2-Implementation, vorherige Spec-Berechnung `78 = 52 + 26` zählte nur c1, nicht c4):
- Bedingung c1 „Preis über Cloud“ liest Senkou_A_i und Senkou_B_i; diese wurden bei i-26 berechnet aus high_max(52). Erste Validität: i = 51 + 26 = 77, also Bar **78**.
- Bedingung c4 „Chikou über Cloud“ liest Senkou bei i-26, deren Berechnung bereits Senkou-B-Validität bei i-26-26 = i-52 braucht. Senkou-B bei Bar-Index i-52 verlangt high_max(52)-Lookback bis i-52-51 = i-103. Erste Validität: i = 103, also Bar **104**.
- Die strengere c4-Bedingung dominiert: **`start_idx = (senkou_b_period - 1) + 2 * shift = 103`**, erstes Confluence-evaluable Bar ist also Index 103.

Code-Referenz: `rust/trading_engine/src/addins/ichimoku.rs::ICHIMOKU_WARMUP_BARS`.

---

## 2. Entry — Long

Alle **fünf** Bedingungen MÜSSEN gleichzeitig erfüllt sein:

- **Bedingung 1 (Preis über Cloud):** `close_i > max(Senkou_A_i, Senkou_B_i)` — der Close der aktuellen Bar liegt über dem oberen Cloud-Rand (T73–T75: „muss der Preis zunächst über dem Ichimoku Cloud schließen")
- **Bedingung 2 (Future-Cloud grün):** `Senkou_A_{i+26} > Senkou_B_{i+26}` — die Cloud-Projektion 26 Bars voraus ist grün (Span A über Span B). Werte werden aus Bar-i-Daten berechnet (kein Look-Ahead, siehe §1.1). (T75–T80: „anschließend muss die 26 Perioden vorauslaufende Wolke grün gefärbt sein")
- **Bedingung 3 (Tenkan über Kijun):** `Tenkan_i > Kijun_i` (T80–T83: „wobei wir hier noch die grüne conversion line über der roten baseline liegen muss")
- **Bedingung 4 (Chikou über Cloud):** `close_i > max(Senkou_A_{i-26}, Senkou_B_{i-26})` — der Chikou-Span (= aktueller Close, visuell 26 Bars zurück gezeichnet) liegt über der Cloud bei der Position 26 Bars zurück. (T84–T87: „lassen wir uns durch den gelben Legging span den Trend bestätigen welcher oberhalb der Wolke schließen muss")
- **Bedingung 5 (Ichimoku-Score grün):** `ichimoku_score_i ≥ score_long_threshold` — der Score-Indikator liefert einen Wert im grünen Bereich. **Schwellwert siehe §12.2.** (T243–T245: „nicht viel ändern außer dass ein fünfter Punkt hinzukommt bei dem der Score im grünen Bereich liegen muss")

**Execution:** Beim **Open der nächsten Kerze** (T87–T90: „beim Open der nächsten Kerze mit unserer byyorder in den Trade einsteigen") — entspricht F-04-Konvention der Engine.

**Session-Filter:** Entry nur, wenn Bar-Timestamp innerhalb 09:00–23:00 Lokalzeit Berlin (London + NY Session, T149–T155).

---

## 3. Entry — Short

Alle **fünf** Bedingungen MÜSSEN gleichzeitig erfüllt sein (Spiegel zu Long):

- **Bedingung 1 (Preis unter Cloud):** `close_i < min(Senkou_A_i, Senkou_B_i)` (T108–T110: „der Preis befindet sich deutlich unterhalb der Wolke")
- **Bedingung 2 (Future-Cloud rot):** `Senkou_A_{i+26} < Senkou_B_{i+26}` (T110–T112: „wobei diese bei der aktuellen Kerze aber für wichtiger nach 26 Perioden wieder rot gefärbt ist")
- **Bedingung 3 (Kijun über Tenkan):** `Kijun_i > Tenkan_i` (T113–T115: „die rote baseline liegt seit einigen Kerzen bereits über der Conversion Line")
- **Bedingung 4 (Chikou unter Cloud):** `close_i < min(Senkou_A_{i-26}, Senkou_B_{i-26})` (T115–T116: „auch der leingsb befindet sich unterhalb der Wolke")
- **Bedingung 5 (Ichimoku-Score rot):** `ichimoku_score_i ≤ score_short_threshold` (T249–T250: „der scoreindikator muss ich im roten Bereich zum Zeitpunkt des Signals befinden")

**Execution:** Beim Open der nächsten Kerze (T116–T118).

**Session-Filter:** Entry nur, wenn Bar-Timestamp innerhalb 09:00–23:00 Lokalzeit Berlin.

---

## 4. Exit — Stop Loss

- **Platzierung Long (Retest-Verbesserung „großzügig"):** Der niedrigere von zwei Kandidaten:
  - `sl_kijun_long = Kijun_i` (Baseline-Anker)
  - `sl_cloud_long = min(Senkou_A_i, Senkou_B_i)` (Cloud-Bottom-Anker)
  - **`sl_long = min(sl_kijun_long, sl_cloud_long)`** — der „großzügigere" (= weiter unter dem Entry) Anker

  (T91–T97: „dieser richtet sich entweder an der roten baseline oder der Wolke aus … hier ist die Baseline inklusive Wolke ein guter Punkt"; T188–T194 Retest-Korrektur: „der stopl großzügiger an der Baseline bzw der Wolke gesetzt werden sollte")

- **Platzierung Short:** Spiegel — der höhere von zwei Kandidaten:
  - `sl_kijun_short = Kijun_i`
  - `sl_cloud_short = max(Senkou_A_i, Senkou_B_i)` (Cloud-Top-Anker)
  - **`sl_short = max(sl_kijun_short, sl_cloud_short)`**

  (T118–T122: „damit der StopLoss oberhalb der Wolke zu weit weg vom Einstieg liegt platziere ich diesen leicht oberhalb der roten baseline" — Original-Variante mit manueller Wahl; Retest-Variante „großzügig" entspricht der Cloud-Top-Wahl)

- **Logik:** initial **fix**, anschließend **Break-Even-Trail bei +1R** (siehe §5).

- **Algorithmische SL-Distanz-Sanity:** `abs(entry - sl) > 0` (degenerate Fall ausschließen, falls Kijun oder Cloud exakt auf dem Close liegen). Bei degenerate → `NoAction` statt Entry-Signal.

---

## 5. Exit — Take Profit

- **Methode:** **R:R 1:2** mit zweistufiger BE-Mechanik (identisch zu UT Bot Spec §5 und Original-Ichimoku-Variante):
  1. **Stufe 1 — TP bei +1R erreicht:** SL wird auf Break-Even gezogen UND TP-Distanz wird auf 2R hochgesetzt. Wörtlich T98–T106: „den Take Profit ziehen wir auf ein risk reward von ein Z2 ab … beim Erreichen eines einfachen risk rewards den stopl auf dem Brick even ziehen"; identisch im Short T123–T127.
  2. **Stufe 2 — TP bei +2R:** Trade endet bei 2R-Treffer oder am BE-Stop, je nachdem was zuerst passiert.
- **Pragmatische Engine-Abbildung (siehe §11):** Setze beim Entry **direkt** `tp = entry + 2R` (Long) bzw. `entry - 2R` (Short). Die Engine-BE-Mechanik (`BacktestEngine::run` Step 2b, D-08) zieht automatisch bei +1R den SL auf Entry. Semantisch äquivalent (TP-first-Konflikt-Auflösung in Step 2a):
  - Trade endet bei +2R → TP-Hit (Win)
  - Trade endet zwischen +1R und +2R durch Retracement → BE-Stop (PnL ≈ 0 vor Fees)
  - Trade endet vor +1R → Original-SL (Loss)
- **Partial TP:** **Nein.** 100 % der Position bis Final-Exit (analog UT Bot).
- **Trailing nach TP:** Nicht erwähnt (Trade endet beim 2R-Hit).

---

## 6. Exit — Signal (regulär)

- **Im Video nicht erwähnt → default: keine signal-basierten Exits.** Position bleibt bis entweder TP (2R) oder SL/BE-Stop trifft.
- Insbesondere **kein** Exit bei Tenkan/Kijun-Cross-Back, **kein** Exit bei Cloud-Re-Entry (Preis kreuzt zurück in die Cloud), **kein** Exit bei Ichimoku-Score-Wechsel. Das wäre eine andere Strategy (re-entry-Logik) und wird vom Video nicht beschrieben.

---

## 7. Filter / Zusatzregeln

- **Trendfilter:** Implizit über die fünf Confluence-Bedingungen (Cloud-Position + Future-Cloud-Farbe + Tenkan/Kijun-Reihenfolge + Chikou-Bestätigung + Score). Kein zusätzlicher EMA wie bei UT Bot.
- **Volatilitätsfilter:** Im Video nicht erwähnt → default: keine Restriktion.
- **Session-Filter:** Ja — Entries nur während **London + New York Session** (T143–T155: „nur entries suchen die zwischen 9 und 23 Uhr liegen also während der volumenstarken London und New York Session"). **Lokalzeit Berlin 09:00–23:00**, identisch zur UT-Bot-Konvention (Spec §7 dort). Außerhalb dieses Fensters: keine neuen Entries; offene Positionen laufen weiter bis SL/TP.
- **Max-Trades-pro-Session:** Im Video nicht erwähnt → default: keine Begrenzung.
- **Re-Entry nach SL:** Im Video nicht erwähnt → default: erlaubt, sobald wieder ein gültiges Entry-Setup erscheint.
- **Maximal offene Positionen:** 1 (impliziert; im Video nicht widersprochen).

---

## 8. Position Sizing

- **Risk pro Trade:** **2 % des Equity** (T280–T283: „bei einem Fest risk reward von 1 Z2 und bei 2% Risiko pro Trade")
- **Formel:** `position_size = (equity × 0.02) / abs(entry − sl)` (identisch zu BB+RSI Spec §8 und UT Bot Spec §8; in der Engine via `position_size_pct` Helper aus `bb_rsi.rs` umgesetzt — siehe Engineering-Plan).
- **Pyramiding:** Nein (max 1 Position).
- **Gebühren-Annahme im Video:** Autor erwähnt explizit „nach Abzug von Gebühren bleiben davon noch ca 120% übrig" (T282–T284) — also Video-Profit **+130 % vor Fees, +120 % nach Fees**. Für Forex-Spread-Annahme im Backtest siehe §12.1.

---

## 9. Besonderheiten / Optimierungen vom Video-Autor

Der Retest-Endstand entstand in drei Iterationen über zwei Videos:

| Iteration | Quelle | TF / Range | WR | Profit | MaxDD | PF | Verbesserung gegenüber Vorgänger |
|---|---|---|---|---|---|---|---|
| **1. Original-Vorgänger** (XLSX Platz 28, https://youtu.be/nZsEsRd6OTQ) | Vorgänger-Video | EUR/USD 1h, 334 Tage | 49 % | +94 % | 8 % | 1.92 | — (Baseline) |
| **2. Retest-Zwischenstufe „Risikomanagement-only"** (T160–T172) | aktuelles Transkript | EUR/USD 1h, ~760 Tage | 57 % | +112 % | 14 % | n/a | SL „großzügig" an Baseline/Cloud statt knapp am Entry (T188–T194: „der stopl großzügiger an der Baseline bzw der Wolke gesetzt werden sollte") |
| **3. Retest-Endstand „mit Score-Filter"** ← **KANONISCH** (XLSX Platz 11) | aktuelles Transkript | EUR/USD 1h, 760 Tage | **55 %** | **+130 %** | **10 %** | **2.44** | + Ichimoku-Score-Filter als 5. Confluence-Bedingung; entfernt 35 von 135 Setups (T262–T268), davon einige Winner und einige Loser → netto WR leicht runter aber Profit hoch + MaxDD runter (T284–T291) |

**Konzeptioneller Kommentar zum Score-Filter:**
- Der Score-Indikator wurde vom Autor via Perplexity-AI-Recherche identifiziert (T196–T201), ist also keine algorithmische Eigenleistung sondern ein Community-Indikator (dreams defined, TradingView).
- Das **Periode/Displacement × 4** ist ein bewusster Trick um Multi-Timeframe-Verhalten auf dem 1h-Chart darzustellen, **ohne** das eigentliche Multi-TF-Setting des Indikators zu aktivieren — der Autor begründet das mit Repaint-Risiko bei MTF-Indikatoren (T220–T234: „der Wert immer erst wie in diesem Fall nach vier einstundenkerzen final berechnet hat innerhalb dieser Zeitspanne kann es noch zu Schwankungen kommen").
- Diese Trickserei ist **algorithmisch reproduzierbar** (Standard-Ichimoku-Score auf 1h-Chart mit verlängerten Perioden ≡ Ichimoku-Score auf 4h-Chart, bis auf Bar-Alignment), aber die **konkrete Score-Formel** wird im Video nicht offengelegt — siehe §12.2.

**Verworfene Originalwahl:** Der Autor zeichnete SL ursprünglich „möglichst knapp beim Einstieg" und erkannte selbst, dass „die Wahrscheinlichkeit für einen unmittelbaren Pullback ist vergleichsweise hoch deshalb" (T180–T187). Die Retest-Verbesserung „großzügig an Baseline/Cloud" wird daher als die kanonische SL-Regel in §4 verwendet.

---

## 10. Bekannte Limitierungen / Warnungen vom Autor

- **Bar-Replay-Pflicht für korrekte Backtests:** Der Autor warnt, dass „durch einfaches Scrollen auf dem Chart nicht möglich die exakten Einstiegssignale auszumachen" sind, weil Senkou-Spans 26 Bars voraus und Chikou 26 Bars zurück gezeichnet werden (T132–T136). Für unsere Engine ist das **kein Problem** — wir berechnen alle Werte aus Past-data, siehe §1.1.
- **Ichimoku-Score-Indikator nicht reproduzierbar dokumentiert:** Die Pinescript-Source des „dreams defined Ichimoku Score" ist im Video nicht verlinkt. Es gibt **mehrere TradingView-Indikatoren** mit Namen „Ichimoku Score" oder „Ichimoku Score Multi-Timeframe" — unsere Wahl in §12.2 ist eine Annäherung, kein bit-exakter Klon.
- **Backtest-Zeitraum für Retest = 2 Jahre 1 Monat / 100 Trades:** Statistisch besser als BB+RSI (284 Tage) und UT Bot (66 Tage), aber für ein 1h-Asset trotzdem dünn. Walk-Forward in Phase 3 weiter relevant.
- **Sehr wenige Trades pro Jahr:** ~50 Trades/Jahr bei 1h-TF mit 5 Confluence-Bedingungen. Das ist ein Trend-Following-Pattern — in Range-Märkten wird Ichimoku wenig bis gar nicht feuern.
- **Asset-Frage Forex vs Crypto:** Video läuft auf EUR/USD. Wir backtesten auf BTCUSDT — Pre-Diagnose-Einschätzung in §13.7.
- **Score-Filter entfernt 35 % der Setups (T263–T268):** Das ist eine relativ aggressive Filterung. Bei Übertragung auf ein anderes Asset (BTCUSDT) könnte der Score-Filter die Trade-Anzahl auf < 50 drücken — Volume-Risiko für die XLSX-Acceptance-Akzeptanz (Soll: 100 Trades ±20 % = [80, 120]).
- **Forex-Spread vs Crypto-Fees:** Forex EUR/USD typischer Spread ~1 Pip ≈ 0.01 % bei major-pair-retail. BTCUSDT Bitunix VIP0 = 0.06 % pro Seite. Die Crypto-Fees sind ~12× teurer per Trade. Bei R:R 1:2 mit Win-Rate 55 % heißt das: Forex-PnL pro Win = 2R - 0.02 % ≈ 2R; Crypto-PnL pro Win = 2R - 0.12 % ≈ 2R - 6 % bei 2 %-Risk-Sizing → das frisst ~3 % vom Profit pro Win. Über 100 Trades = ~150 % → ~140 %. Das bleibt im Akzeptanzband, ist aber zu beachten.

---

## 11. Mapping Spec → Code (geplant, GREEN-FIELD)

Da der Ichimoku-Code im Repo noch nicht existiert, mappt diese Section die Spec-Bedingungen auf **geplante** Code-Locations. Die `*` markierten Helpers existieren bereits aus der BB+RSI- oder UT-Bot-Implementierung und werden wiederverwendet.

| Spec-Bedingung | Code-Datei (geplant) | Funktion / Block | Status |
|---|---|---|---|
| Rolling `high_max(N)` und `low_min(N)` über N letzte Bars | `rust/trading_engine/src/addins/ichimoku.rs` (neu, pub helpers) ODER reused via existierende swing_high/swing_low | `calc_rolling_max(highs, period)` und `calc_rolling_min(lows, period)` — leicht-different von `swing_high`/`swing_low` (die Phase-2-Konvention für Swings ist „rolling über die letzten N Bars **exklusive der aktuellen**"; Ichimoku braucht **inklusive der aktuellen**) | **NEU** (oder param-erweiterte Variante der bestehenden) |
| Tenkan-Sen = `(high_max(9) + low_min(9)) / 2` | `addins/ichimoku.rs` (neu) | `calc_tenkan(highs, lows, period=9)` | **NEU** |
| Kijun-Sen = `(high_max(26) + low_min(26)) / 2` | `addins/ichimoku.rs` (neu) | `calc_kijun(highs, lows, period=26)` | **NEU** |
| Senkou-Span A = `(Tenkan + Kijun) / 2`, future-shift +26 | `addins/ichimoku.rs` (neu) | `calc_senkou_a(highs, lows, tenkan_period, kijun_period) -> (current_at_i, future_at_i_plus_26)` (returns tuple weil beide Anker gebraucht werden, siehe §1.1) | **NEU** |
| Senkou-Span B = `(high_max(52) + low_min(52)) / 2`, future-shift +26 | `addins/ichimoku.rs` (neu) | `calc_senkou_b(highs, lows, period=52) -> (current_at_i, future_at_i_plus_26)` | **NEU** |
| Chikou-Vergleichs-Anker `close_i vs cloud_{i-26}` | `addins/ichimoku.rs` (neu) | im `on_candle`: `let cloud_at_i_minus_26 = (computed from highs/lows at i-52..i-26)` | **NEU** |
| Cloud-Farbe / Cloud-Bounds Helper | `addins/ichimoku.rs` (neu) | `cloud_upper(span_a, span_b) = max(span_a, span_b)`, `cloud_lower(span_a, span_b) = min(span_a, span_b)`, `cloud_is_green(span_a, span_b) = span_a > span_b` | **NEU** |
| Ichimoku-Score (Annäherung — siehe §12.2) | `addins/ichimoku.rs` (neu) | `calc_ichimoku_score(...)` mit gewählter Default-Implementation aus §12.2 | **NEU** |
| Ichimoku-Score Dart-Parität | `lib/services/indicators.dart` (neu) | `calculateIchimokuScore(...)` identisch | **NEU** |
| Tenkan/Kijun Dart-Parität | `lib/services/indicators.dart` (neu) | `calculateTenkan(candles, period)`, `calculateKijun(candles, period)` | **NEU** |
| Senkou-A/B Dart-Parität | `lib/services/indicators.dart` (neu) | `calculateSenkouA(...)`, `calculateSenkouB(...)` | **NEU** |
| Long-Entry-Confluence (5 Bedingungen) | `addins/ichimoku.rs` | `on_candle` Confluence-Block | **NEU** |
| Short-Entry-Confluence (5 Bedingungen) | `addins/ichimoku.rs` | `on_candle` Confluence-Block | **NEU** |
| SL = `min(kijun, cloud_lower)` (Long) | `addins/ichimoku.rs` | `compute_sl_long(kijun_i, span_a_i, span_b_i)` | **NEU** |
| SL = `max(kijun, cloud_upper)` (Short) | `addins/ichimoku.rs` | `compute_sl_short(kijun_i, span_a_i, span_b_i)` | **NEU** |
| R:R 1:2 TP-Distanz | `addins/ichimoku.rs` | `tp = price ± 2.0 * sl_distance` direkt in Signal-Emission | **NEU** (analog UT Bot, Default 2.0) |
| BE-Trail bei +1R | `rust/trading_engine/src/backtest/mod.rs`* | `BacktestEngine::run` Step 2b — bereits aktiv (D-08) | **Engine-Mechanik existiert** |
| Risk-2 %-Sizing | `addins/ichimoku.rs` | `position_size_pct(price, sl_distance, 0.02)`* aus `bb_rsi.rs` | **Helper existiert** |
| Session-Filter (09:00–23:00 Lokalzeit Berlin) | `addins/ichimoku.rs` ODER reused von UT Bot | **Architektur-Entscheidung offen, siehe §12.3** | **NEU** im Ichimoku-Modul, ggf. Refactor zu Shared |
| Session-Filter Dart-Parität | `lib/services/backtest_service.dart` | analog | **NEU** |
| Strategy-Manifest-Registrierung | `rust/trading_engine/src/addins/mod.rs` | `pub mod ichimoku; pub use ichimoku::IchimokuStrategy;` | **NEU** |
| Dart-Fallback der gesamten Strategy | `lib/services/backtest_service.dart` | neuer `IchimokuParams` + Strategy-Branch | **NEU** |

---

## 12. Abweichungen von der Vorlage (bewusst)

### 12.1 Asset/TF: BTCUSDT statt EUR/USD (Path-B-Kandidat)

- **Abweichung:** Video läuft auf EUR/USD 1h Forex. Backtest erfolgt auf **BTCUSDT 1h** (Phase-1-Konvention für 1h-Strategien, identisch zu BB+RSI).
- **Begründung:**
  - Kein EUR/USD-Feed über Binance verfügbar.
  - Phase-2-Konvention: BB+RSI hat auf BTCUSDT 1h getestet (Pfad C-Klassifikation), UT Bot auf BTCUSDT 5min (Pfad C). Ichimoku auf BTCUSDT 1h hält die TF-Konsistenz zu BB+RSI.
  - Ichimoku ist ein reiner **Trend-Following**-Indikator. Crypto-Märkte haben in 2024–2025 mehrere klare Trend-Phasen (Bull-Run Q1/Q2 2024, Consolidation Q3, Bull-Run Q4) — strukturell günstig für Ichimoku, anders als die Mean-Reversion-Confluence von UT Bot.
- **Fee-Konvention:** Bitunix VIP0 Standard 0.06 % pro Seite (analog BB+RSI und UT Bot, siehe §10 Fee-Analyse).
- **Path-Klassifikation-Konsequenz:** Wenn Backtest die XLSX-Targets erreicht → Pfad B (bewusste Asset-Abweichung); wenn nicht → Mandatory Sanity-Sweep (§13.3), dann ggf. Pfad C.
- **QA-Entscheidung (offen):** Ist BTCUSDT 1h die richtige Wahl, oder soll auch ETHUSDT 1h (alternatives Crypto-Asset) oder BTCUSDT 4h (langsamerer TF für Trend-Indikator) als Default-Backtest-Setup gewählt werden? Vorschlag: BTCUSDT 1h als Default, ETHUSDT 1h + BTCUSDT 4h als Sanity-Sweep-Achse.

### 12.2 Ichimoku-Score-Indikator: Default-Implementation

- **Abweichung:** Pinescript-Source des „dreams defined Ichimoku Score" ist im Video nicht verlinkt. Es gibt mehrere TradingView-Indikatoren mit ähnlichem Namen.
- **Gewählte Default-Implementation:** Wir bauen einen **Confluence-Score** aus den fünf Standard-Ichimoku-Signalen, gewichtet 1:1, normalisiert auf [-100, +100]:

  ```
  score = 20 * sign(close - cloud_upper)                       # Cloud-Position
        + 20 * sign(senkou_a_future - senkou_b_future)         # Future-Cloud-Farbe
        + 20 * sign(tenkan - kijun)                            # Conversion vs Base
        + 20 * sign(close - cloud_at_i_minus_26)               # Chikou-Position
        + 20 * sign(kijun_slope_over_5_bars)                   # Kijun-Trend (Momentum-Proxy)
  ```

  - `score ≥ +60` → „grün" (Long-Confluence-Bestätigung)
  - `score ≤ -60` → „rot" (Short-Confluence-Bestätigung)
  - `-60 < score < +60` → neutral (keine Bestätigung)

  **Periode-Multiplikator ×4:** alle period-basierten Komponenten (Tenkan 9→36, Kijun 26→104, Senkou-B 52→208, Cloud-at-i-minus-26 → cloud-at-i-minus-104) für die Score-Berechnung skaliert. Das nähert das 4h-Verhalten auf dem 1h-Chart an (T217–T234).

- **Begründung:**
  - Diese Implementation reproduziert die im Video genannten **Score-Komponenten konzeptionell**: cross-Logik, Farb-Logik, Distanz-Logik (T209–T214: „crosses breakouts Farben oder relative Entfernungen").
  - Schwellwert ±60 entspricht „3 von 5 Komponenten zeigen in dieselbe Richtung" — eine konservative Hürde, die starke Confluence-Signale verlangt.
  - Periode-×4 ist explizit im Video gefordert (T217–T219).
- **Risiko (Path-C-Kandidat):** Wenn die echte „dreams defined"-Implementation deutlich anders gewichtet (z.B. Pivot-Highs/-Lows einbezieht oder eine andere Score-Skala benutzt), kann unsere Default-Implementation andere Setups filtern als das Video. Phase-3-Backlog-Eintrag (analog UT Bot Spec §13.6): „Ichimoku-Score dreams-defined-Original recherchieren und Default ersetzen".
- **QA-Frage offen:** Soll Default-Threshold `±60` (= 3 von 5 Komponenten in Richtung), `±40` (= 2 von 5), oder `±80` (= 4 von 5) sein? Vorschlag: `±60` als ehrlicher Mittelweg.

### 12.3 Session-Filter — Strategy-intern vs Engine-shared (Wiederholung des UT-Bot-Themas)

- **Abweichung:** Identisch zum UT-Bot-Spec §12.2: Session-Filter wird auch von BB+RSI Spec §7 verlangt, ist dort nicht implementiert.
- **Status nach UT Bot:** UT Bot hat den Session-Filter UT-Bot-lokal implementiert mit TODO-Marker für Engine-Shared (Welle U2-3, Commit folgt aus UT Bot Engineering Plan).
- **Ichimoku-Entscheidung:**
  - **(a) Duplikat in `ichimoku.rs`** (schnellster Pfad — Code-Verdoppelung)
  - **(b) Refactor zu `addins/common.rs` jetzt** (sauberer — UT-Bot-Session-Filter mit-bewegen, BB+RSI bleibt explizit aus dem Refactor-Scope, weil Session-Filter dort nicht aktiv)
- **Pragmatische Default-Entscheidung:** Option **(b)** — da Ichimoku die **dritte** Strategie ist, die denselben Session-Filter braucht (UT-Bot-Engineering-Plan-§3-Frage-1 sagte „extract to common once a third strategy needs them"). Aufwand: ~30 min für Refactor + UT-Bot-Re-Test.
- **QA-Entscheidung offen:** OK mit Refactor zu `addins/common.rs` jetzt? Falls QA das ablehnt → Duplikat-Option (a) mit eigenem TODO.

### 12.4 SL-Sanity-Check (algorithmische Robustheit)

- **Abweichung:** Das Video lässt den SL „großzügig an Baseline ODER Cloud" — also einen manuellen Entscheidungsspielraum. Wir entscheiden algorithmisch via `min(kijun, cloud_lower)` für Long bzw. `max(kijun, cloud_upper)` für Short (§4).
- **Begründung:** Algorithmische Eindeutigkeit ist Pflicht für Backtest-Reproduzierbarkeit. „Großzügig" bedeutet im Trader-Sprachgebrauch „weiter weg vom Entry" → der niedrigere Anker für Long, der höhere Anker für Short. Das ist die einzige plausible Lese-Wahl.
- **Test-Beleg-Pflicht:** Unit-Test mit synthetischer Bar, in der Kijun = 99.5 und Cloud_lower = 99.0, Entry = 100 → SL_long = 99.0 (Cloud-Wahl), R = 1.0; ein zweiter Test mit Kijun = 99.0 und Cloud_lower = 99.5 → SL_long = 99.0 (Kijun-Wahl).

### 12.5 Future-Cloud-Bedingung — algorithmische Lese-Schärfe

- **Abweichung:** Video sagt „die 26 Perioden vorauslaufende Wolke grün gefärbt" (T76–T77). Wir lesen das strict als `senkou_a_at_{i+26} > senkou_b_at_{i+26}` mit ≥-Toleranz `> 0.0` (nicht `>= 0.0`).
- **Begründung:** Strict-`>` ist die korrekte Lese-Wahl für „grün gefärbt"; bei `Senkou_A = Senkou_B` (flat-cloud) wäre die Wolke optisch transparent / weder grün noch rot → kein Confluence-Trigger.
- **Risiko:** Falls die XLSX-Targets nur mit `>=` erreichbar sind → §12.5 wird im Diagnose-MD als Path-B-Kandidat dokumentiert.

---

## 13. Acceptance für Implementierung

### 13.1 Acceptance-Pfade nach Plan §4.4 (rev4)

Drei mögliche Acceptance-Ausgänge (identisch zu BB+RSI und UT Bot):

1. **Pfad A — Im Toleranz-Band:** Code reproduziert XLSX-Targets auf BTCUSDT 1h (Asset-Abweichung von EUR/USD ist Path-B-Element, siehe §12.1; falls *zusätzlich* alle anderen Metriken im Band → effektiv Pfad B). → GO Phase 3 als **produktiver Default-Kandidat**.
2. **Pfad B — Bewusste Abweichung dokumentiert:** XLSX-Targets erreicht **mit** dokumentierten Abweichungen (§12.1 Asset BTCUSDT statt EUR/USD, §12.2 Score-Implementation, ggf. §12.3 Session-Refactor, §12.5 strict-`>` Future-Cloud). → GO Phase 3 als **produktiver Default-Kandidat** mit dokumentierter Abweichung.
3. **Pfad C — Video-treu implementiert, aber Targets auf Ziel-Asset/TF nicht erreichbar:** Spec-Diffs alle implementiert, Engine-Korrektheit beweisbar, aber XLSX-Targets reflektieren EUR/USD-Forex-Microstructure, die auf BTCUSDT nicht reproduzierbar ist. **Voraussetzung: Mandatory Sanity-Sweep** (siehe §13.3), dokumentiert als `01_Projectplan/specs/ichimoku_diagnose_{date}.md`. Strategy bleibt als Phase-3-Optimizer-Lab-Kandidat im Manifest.

### 13.2 XLSX-Targets (Soll-Werte aus Ranking-Platz 11, Video EUR/USD 1h)

Backtest auf **BTCUSDT 1h** über **760 Tage** (Video-Zeitraum-Äquivalent — z.B. 2023-04-01 bis 2025-05-01, exaktes Range-Mapping in Welle I3):

| Metrik | Video-Wert (XLSX Platz 11) | Toleranz | Akzeptanz-Band |
|---|---|---|---|
| Profit-Faktor | **2.44** | ±0.30 | [2.14, 2.74] |
| Win-Rate | **55 %** | ±5 pp | [50 %, 60 %] |
| Max-Drawdown | **10 %** | +5 pp | < 15 % |
| Trades (100-Trade-Reihe-Äquivalent) | **100** ± Score-Filter-Drop | ±25 % (Score-Filter macht den Anchor unsicher) | [75, 125] |
| Profit nach 100 Trades (vor Fees) | **+130 %** | ±25 pp | [+105 %, +155 %] |
| Profit nach 100 Trades (nach Fees Bitunix VIP0) | **+120 %** (Video gibt nach-Fees-Wert explizit, T282–T284) | ±25 pp | [+95 %, +145 %] |
| R:R im Trade-Log | **1:2** mit BE-Trail | strict TP-Distanz | exakt 2.0 (BE-Exits akzeptiert als „R=0") |

### 13.3 Mandatory Sanity-Sweep (vor Path-C-Klassifikation Pflicht)

Falls der Welle-I3-Baseline-Backtest auf BTCUSDT 1h die XLSX-Targets verfehlt:

| Variation | Setup | Zweck |
|---|---|---|
| **TF-Sweep** | BTCUSDT **4h** und **15min** mit denselben Default-Parametern | Prüfen, ob 1h-Bar-Anzahl die Score-Filterung zu aggressiv macht (4h ≈ 1/4 der Bars, höhere Per-Bar-Signifikanz); 15min als Gegenpol |
| **Asset-Sweep** | **ETHUSDT 1h** mit denselben Default-Parametern | Prüfen, ob BTC-spezifische Trend-Charakteristik das Problem ist |
| **Score-Threshold-Sweep** | BTCUSDT 1h, `score_long_threshold` ∈ {+40, +60, +80}, `score_short_threshold` ∈ {-40, -60, -80} (symmetrisch) | Prüfen, ob §12.2-Threshold das Problem ist (Volume vs Quality Trade-off) |

**Klassifikations-Logik:**
- Mindestens eine Variation im Band → kein Pfad C; Empfehlung als Pfad B mit Default-Anpassung.
- Alle außerhalb des Bandes → Pfad C bestätigt.

### 13.4 Engine-Korrektheits-Gate (Phase-1-Vorgabe bleibt erfüllt)

Unabhängig vom Acceptance-Pfad **vor** Phase-2-Tag grün:

- Unit-Tests pro Entry-/Exit-Bedingung grün:
  - Tenkan-Konvergenz (Test mit monotonem Preis-Anstieg → Tenkan = (high+low)/2 bei letzter Bar)
  - Kijun-Konvergenz analog
  - Senkou-A-Future-Shift-Korrektheit (Senkou_A bei i+26 = (Tenkan_i + Kijun_i)/2)
  - Senkou-B-Future-Shift-Korrektheit
  - Chikou-Vergleichs-Anker (close_i vs Cloud bei i-26 mit Cloud-Werten aus i-52)
  - Cloud-Bound-Helpers (cloud_upper = max, cloud_lower = min)
  - Ichimoku-Score-Komponenten (jede der 5 Komponenten isoliert)
  - Long-Confluence (alle 5 Bedingungen einzeln + alle gemeinsam)
  - Short-Confluence
  - SL-Wahl Long (Kijun vs Cloud-Lower, jeweils niedrigerer gewinnt)
  - SL-Wahl Short
  - R:R 1:2 TP-Distanz
  - Session-Filter (innen / vor / nach Fenster + Edge-Bars)
- Dart↔Rust-Parität 1e-9 auf einer **400-Candle**-Synthese-Fixture (länger als BB+RSI/UT-Bot wegen 78-Bar-Warmup-Pflicht). Fixture muss mindestens einen erfolgreichen Long-Entry und einen erfolgreichen Short-Entry enthalten — siehe Engineering-Plan-Welle I2 für Fixture-Design-Notiz (analog UT-Bot-U2-5: Random-Walk eher als Sinusoid).
- Phase-1-Reference-Backtest (BTCUSDT 1h 2024-H1, BB+RSI) bleibt **strukturell** grün (Reproduzierbarkeit 3×, Parität, `totalTrades > 0`) — kein Engine-Drift durch Ichimoku-Hinzufügung.
- `flutter analyze` 0 Warnungen, `cargo clippy` 0 Warnungen.

### 13.5 Reproduzierbarkeit auf BTCUSDT 1h

- 3× consecutive Backtest-Runs auf identischen Input-Daten produzieren bit-identische Trade-Liste (analog BB+RSI / UT Bot Pflicht).
- `totalTrades` > 0 (sonst ist die Konfiguration degeneriert).

### 13.6 Pfad-Klassifikation: **Pfad C** (Welle I3 finalisiert 2026-05-24)

**Status:** Welle I3 abgeschlossen. Eskalations-Leiter aus 7 Real-Data-Tests (Strict-Spec + 2× Score-Threshold-Sweep + 4× Sanity-Sweep) auf BTCUSDT 1h / 4h und ETHUSDT 1h über 760 Tage 2023-04-01 → 2025-05-01 dokumentiert in `01_Projectplan/specs/ichimoku_diagnose_2026-05-24.md`.

**Actual-Result-Tabelle (BTCUSDT 1h strict-spec Baseline, T1):**

| Metrik | XLSX-Target | Akzeptanz-Band | Actual (T1) | im Band? |
|---|---|---|---|:---:|
| Profit-Faktor | 2.44 | [2.14, 2.74] | **1.088** | ✗ |
| Win-Rate | 55 % | [50 %, 60 %] | **29.75 %** | ✗ |
| Max-Drawdown | 10 % | < 15 % | **20.87 %** | ✗ |
| Trades | 100 | [75, 125] | **158** | ✗ (über) |
| Profit % (nach Fees) | +120 % | [+95 %, +145 %] | **+12.46 %** | ✗ |

**Best-of-Sweep (T3c BTCUSDT 1h tenkan=7 kijun=21):** PF=1.29, WR=32.82 %, MaxDD=17.92 %, trades=131, profit %=+38.61 %. Netto profitabel, aber 4/5 Bänder verfehlt; nur trades-Wert knapp über Band. **Keine Variation erreicht alle 5 Bänder.**

**Pfad-Klassifikation: Pfad C** (video-treu implementiert, XLSX-Targets reflektieren EUR/USD-Forex-Microstructure, die auf BTCUSDT 1h nicht reproduzierbar ist).

**Root-Cause-Hypothese (siehe Diagnose-MD §4):**
1. **Asset-Mismatch zum Video-EUR/USD-1h:** EUR/USD hat strukturell niedrigere Intra-Bar-Volatilität als BTC → SL an Kijun/Cloud trifft auf Forex seltener. Auf BTC kassieren viele Trades SL zwischen Entry und +1R (realised R = 2.57 in T1 zeigt: die Wins erreichen TP voll, das WR-Defizit kommt aus den Verlierern).
2. **Score-Implementation §12.2 weicht von „dreams defined"-Original ab:** T2a (score=40) vs T1 (score=60) ändert die Trade-Anzahl nur um 2 (160 vs 158), T2b (score=80) erstickt komplett (0 Trades). Die XLSX behauptet 35 % Setup-Filterung — wir sehen ~1 %. Score-Distribution-Anomalie auf BTC-1h-Daten.
3. **Trend-vs-Range-Verhältnis BTC vs EUR/USD:** Ichimoku-5-Confluence braucht klare Trend-Phasen. BTC 2023-2025 hatte Bull-Runs, aber dazwischen Wochen-lange Range-Phasen mit Cloud-Crossings, die das WR erodieren.

**Phase-3-Konsequenz:** Ichimoku v1 bleibt im Add-in-Manifest als **Phase-3-Optimizer-Lab-Kandidat** (Default-Defaults bleiben video-treu, keine Default-Änderung in Welle I3). Backlog-Einträge in Diagnose-MD §5 (Punkte 4–6).

**Pre-Diagnose-Reflektion:** §13.7 hatte Pfad-B-Wahrscheinlichkeit bei 40 % und Pfad-C bei 55 % geschätzt. Tatsächlich Pfad C, aber das Pfad-B-Argument war qualitativ richtig: Ichimoku ist die „beste Pfad-C-Strategie" der drei Phase-2-Strategien (4/7 Tests netto profitabel vs UT Bot 0/8). Das Trend-Following-Profil ist auf Crypto strukturell günstiger als die Mean-Reversion-Confluence von UT Bot, reicht aber nicht für das XLSX-Target-Band.

### 13.7 Pre-Diagnose-Einschätzung (vor Welle I3)

- **Pfad-A-Wahrscheinlichkeit:** Niedrig (gleicher Asset-Mismatch wie UT Bot) — der reine Asset-Wechsel EUR/USD → BTCUSDT macht Pfad A nahezu unmöglich.
- **Pfad-B-Wahrscheinlichkeit:** **Höher als bei UT Bot.** Begründung:
  - Ichimoku ist **konzeptionell trend-following** ohne Mean-Reversion-Komponente. Auf BTCUSDT 2023–2025 gab es ausgeprägte Trends (Bull-Run Q4 2023, Q1+Q2 2024, Q4 2024) → strukturell günstig.
  - Asset-Mismatch ist **kategorisch verschieden** zu UT Bot: UT-Bot-SMI nutzt Mean-Reversion-Signaturen aus NQ-Auctions, die auf Crypto fehlen. Ichimoku-Cloud nutzt nur Trend + Momentum-Confluence, die in beiden Asset-Klassen vorkommen.
  - 1h-TF statt 5min — keine Microstructure-Probleme (Wick-Volatility, Spread-Noise).
  - Score-Filter ist eine Quality-Hürde, kein Mean-Reversion-Filter — übertragbar.
- **Pfad-C-Wahrscheinlichkeit:** Mittel — falls Score-Filter zu wenige BTC-Signale durchlässt (< 50 Trades in 760 Tagen → unter Akzeptanz-Volume-Band) oder die Score-Implementation §12.2 zu konservativ ist.
- **Geschätzte finale Verteilung (Best-Guess):**
  - Pfad A: 5 % (rein zufällig)
  - Pfad B: 40 % (Asset-Adaption mit ±5pp WR-Toleranz)
  - Pfad C: 55 % (wahrscheinlichster Ausgang — Asset-Mismatch dominiert)
- **Vergleich zu UT Bot:** UT Bot Pre-Diagnose-Pfad-A/B-Chance war geschätzt < 20 %, tatsächlich Pfad C. Ichimoku-Chance auf Pfad A oder B liegt höher (~45 %), weil das Trend-Following-Charakteristikum auf Crypto strukturell günstiger ist.

---

## 14. Offene Fragen für QA-Sign-off vor Welle I2-Start

(Zusammenfassung der inline-Fragen, vollständige Diskussion in Engineering-Plan §3.)

1. **§12.1 — Asset-Wahl Default:** BTCUSDT 1h als Default + ETHUSDT 1h + BTCUSDT 4h als Sanity-Sweep? Oder anderer Default?
2. **§12.2 — Score-Implementation:** Default-Threshold ±60 (3-of-5-Konvergenz) OK? Score-Formel als „Confluence-Sum mit ±20-Gewichten" OK, oder andere Variante?
3. **§12.3 — Session-Filter-Refactor:** Refactor zu `addins/common.rs` jetzt (mit UT-Bot-Re-Test) oder Duplikat in `ichimoku.rs`?
4. **§12.5 — Strict-`>` vs `>=` Future-Cloud:** OK mit strict?
5. **Engineering-Plan-Größe:** Welle I2 wird voraussichtlich groß (~12–16 h, mehr als UT Bot wegen Future-Shift). Splitting in ein-PR-pro-Indikator-Helper (analog BB+RSI / UT Bot Atomic-Commits) OK?
