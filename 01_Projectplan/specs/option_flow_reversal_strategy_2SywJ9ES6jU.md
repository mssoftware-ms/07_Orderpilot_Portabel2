# Option-Flow Reversal/Breakout - Strategie-Extraktion aus 2SywJ9ES6jU

**Quelle:** `01_Projectplan/strategien/youtube/youtube/2SywJ9ES6jU-2SywJ9ES6jU.md`  
**YouTube:** https://www.youtube.com/watch?v=2SywJ9ES6jU&t=292s  
**Erstellt:** 2026-05-28  
**Status:** umsetzbarer Forschungs-Prototyp, keine Profit-Garantie

## 1. Kurzfazit

Die im Video gemeinte Strategie ist keine klassische Indikatorstrategie. Der behauptete Edge ist:

1. **Richtungsbias aus hoeherem Timeframe:** Auf 4h wird ein Marktzyklus bzw. eine Welle bestimmt. Der Beginn/Wechsel wird ueber Strukturbruch, Fibonacci-Retracement um den 78er-Bereich und eine Preis-Zeit-Projektion bewertet.
2. **Intraday-Level aus Optionsdaten:** Fuer den Handelstag werden Levels aus Options-Flow, Strike-Interesse, Open Interest bzw. Gamma-/Absicherungsbereichen abgeleitet.
3. **Entry am Level:** Erst wenn der Preis das Level erreicht, wird gehandelt. Reversal, wenn Orderflow/Absorption zeigt, dass das Level haelt. Breakout, wenn grosses Volumen das Level akzeptiert und neue Preisentdeckung startet.
4. **Risikokern:** sehr kleiner Stop, mehrere kleine Versuche im gleichen Bias erlaubt, ca. 0,3 % Risiko pro Versuch, Tageslimit ca. 1 %, Freitag eher meiden.

Das Video gibt die exakten Optionsformeln nicht offen preis. Darum ist die realistischste verwertbare Strategie ein **Level-first Framework**: echte Options-/Gamma-Level einspeisen, dann mit klaren Entry-/Exit-Regeln testen.

## 2. Evidenz aus dem Transkript

| Stelle | Extrahierte Aussage |
|---|---|
| 02:00 | Vorab eingezeichnete Levels werden angeblich punktgenau getestet; Entries starten am Top/Bottom der Bewegung. |
| 30:00-36:00 | Indikatoren/Daten dienen der Analyse, nicht als blinde Buy/Sell-Signale; Strategie soll nach Backtesting einfach handelbar sein. |
| 39:00-43:00 | Trend-/Wellenfrage ist zentral: Welche Welle ist aktiv, welche bricht den Zyklus? Die neue Methode ersetzt subjektive Swing-Auswahl durch feste Daten. |
| 45:00-49:00 | 4h-Abwaerts-/Aufwaertszyklus wird ueber Struktur, Makrodaten, Fibonacci-Bereich und Preis-Zeit-Projektion legitimiert. |
| 51:00-56:00 | Intraday kommen Levels aus Optionsdaten/Option Flow/Strike-Absicherung hinzu; an diesen Levels wird nach Reversal oder Breakout gesucht. |
| 54:00-55:00 | Deepcharts/Orderflow-Absorption wird als Entry-Hilfe genannt: Level wird angelaufen, dort absorbiert/akkumuliert, dann dreht der Markt. |
| 58:00-63:00 | Angegebene Zielwerte: 60-65 % Winrate, bei Praezision bis ca. 67-70 %, 4R-5R moeglich durch kleine Stops. |
| 59:00-60:00 | Freitag schlechter wegen Akkumulation; beste Tage laut Video Dienstag/Mittwoch, Breakout-Umfeld bevorzugt. |
| 62:00-67:00 | Risiko ca. 1-2 % pro Tag, ca. 0,3-0,35 % pro Trade; nach ca. 1 % Tagesverlust stoppen. |
| 64:00-65:00 | Nicht vor dem Level einsteigen. Bei Short-Bias nach Stop weiter Short suchen, aber mit besserem Verhaeltnis. |

## 3. Begriffsklaerung aus Recherche

- **Strike Price:** Der Strike ist der Ausuebungspreis einer Option. CME erklaert, dass Optionsprodukte mehrere Strike-Preise um den zugrunde liegenden Futurespreis listen. Quelle: [CME Group](https://www.cmegroup.com/education/courses/introduction-to-options/what-is-exercise-price-strike.hideHeader.hideFooter.hideSubnav.hideAddThisExt.educationIframe.html.html.html).
- **Gamma Exposure / GEX:** Praktische GEX-Anbieter beschreiben Gamma-Levels als Zonen, an denen Market-Maker-Hedging Support, Resistance oder Beschleunigung erzeugen kann. Das ist eine plausible Erklaerung fuer die im Video gemeinten Options-Absicherungslevels, aber nicht identisch mit einer garantierten Wendestelle. Quellen: [GEXMetrix](https://www.gexmetrix.com/blog/gamma-exposure), [GEXRadar](https://gexradar.io/what-is-gamma-exposure).
- **Absorption:** Deepcharts beschreibt Absorption als Orderflow-Situation, in der grosse aggressive Orders auf passive Gegenliquiditaet treffen und der Preis nicht weiterkommt. Das passt zur Video-Aussage, am Level auf Respekt/Rejection zu warten. Quelle: [Deepcharts Helpcenter](https://www.deepcharts.com/helpcenter/deepdom/article/absorption).
- **Deribit Optionsdaten:** Deribit stellt ueber `public/get_book_summary_by_currency` aktuelle Summary-Daten inklusive Open Interest und Volumen fuer Optionsinstrumente bereit. Das reicht fuer Live-Level-Exports, aber nicht fuer einen historischen Optionslevel-Backtest ohne archivierte Snapshots. Quelle: [Deribit API Docs](https://docs.deribit.com/api-reference/market-data/public-get_book_summary_by_currency).

## 4. Handelslogik

### 4.1 Hoeherer Timeframe: Bias

**Arbeits-Timeframe:** 4h.

Long-Bias:
- Ein markantes Swing-Low wurde gebildet.
- Danach entsteht ein hoeheres Hoch oder ein Bruch der vorherigen Abwaertsstruktur.
- Der Ruecklauf respektiert ein tiefes Fibonacci-Retracement, bevorzugt 78,6 % bis 88,6 %, ohne das Ausgangstief sauber zu brechen.
- Preis-Zeit-Projektion zeigt, dass das Ziel innerhalb eines plausiblen Zyklus erreichbar ist.

Short-Bias:
- Spiegelbild: markantes Swing-High, tieferes Tief, tieferes Hoch.
- Ruecklauf in den 78,6 %- bis 88,6 %-Bereich wird respektiert.
- Zielprojektion zeigt nach unten.

Neutral:
- Keine klare 4h-Welle.
- Preis zwischen widerspruechlichen Optionslevels.
- Freitag oder stark akkumulatives Verhalten ohne Ausbruch.

### 4.2 Intraday-Level

Primaere Variante:
- Taeglich echte Optionsdaten beziehen: Strike, Open Interest, Volumen, Delta, Gamma, Verfall.
- Levels bilden aus: hohem Open Interest, Gamma-Walls, Zero-Gamma/Gamma-Flip, auffaelligem Call-/Put-Flow.
- Levelrichtung taggen:
  - `short`: obere Hedge-/Resistance-Zone.
  - `long`: untere Hedge-/Support-Zone.
  - `breakout`: Level, dessen Akzeptanz Momentum erwarten laesst.

Fallback fuer das Lab:
- Ohne Optionsdaten werden prior-day high/low, Pivot-R382/S382 und runde Preiszonen als Proxy genutzt. Das beweist nicht den Options-Edge, testet aber die Execution- und Risk-Mechanik.

### 4.3 Entry-Regeln

Gilt fuer Long und Short:
- Nur handeln, wenn 4h-Bias und Levelrichtung nicht widersprechen.
- Nicht vor dem Level handeln.
- Touch-Kriterium: Candle handelt durch das Level oder Close liegt innerhalb `0.18 ATR(14)` vom Level.
- Volumenfilter: aktuelle Candle mindestens `1.25` Standardabweichungen ueber 48-Candle-Volumenmittel.

Reversal-Long:
- Preis testet Long-Level.
- Candle schliesst wieder oberhalb des Levels.
- Unterer Wick ist mindestens 35 % der Candle-Range.
- Entry auf Close oder konservativer auf naechstem Open.

Reversal-Short:
- Preis testet Short-Level.
- Candle schliesst wieder unterhalb des Levels.
- Oberer Wick ist mindestens 35 % der Candle-Range.
- Entry auf Close oder konservativer auf naechstem Open.

Breakout-Modus:
- Preis schliesst klar jenseits des Levels.
- Volumen ist erhoeht.
- Optional Retest des Levels abwarten.
- Nur in Richtung des 4h-Bias oder bei eindeutigem Bias-Wechsel.

### 4.4 Exit und Management

- Initialer Stop: hinter dem Level oder `0.45 ATR(14)`, je nachdem was weiter entfernt ist.
- Ziel 1: 2R, dort optional Teilgewinn und Stop auf Breakeven.
- Ziel 2: 4R bis 5R, passend zur Video-Aussage.
- Restposition: dynamischer Stop unter/ueber lokalen 5m-Swings.
- Nach Stop darf ein zweiter/dritter Versuch in gleicher Richtung erfolgen, solange Tagesrisiko nicht erreicht ist und das Level-Setup intakt bleibt.

### 4.5 Risk Rules

- Risiko pro Versuch: 0,30 % Equity.
- Maximaler Tagesverlust: 0,90 % bis 1,00 %.
- Nach 2-3 Verlusten am selben Level nur noch handeln, wenn das R:R besser wird oder ein Breakout-Setup entsteht.
- Freitag standardmaessig auslassen oder nur nach gesonderter Statistik handeln.

## 5. Prueflabor

Proxy-Prototyp auf historischen BTCUSDT-5m-Candles:

```bash
python 01_Projectplan/strategien/youtube/youtube/option_flow_reversal_lab.py \
  --candles 01_Projectplan/optimizer_data/BTCUSDT_5m_2024-01-01_2024-03-08.json
```

Parameter-/Robustheitslauf:

```bash
python 01_Projectplan/strategien/youtube/youtube/option_flow_reversal_lab.py \
  --candles 01_Projectplan/optimizer_data/BTCUSDT_5m_2024-01-01_2024-03-08.json \
  --sweep
```

Trade-Log und Profitabilitaets-Gates ausgeben:

```bash
python 01_Projectplan/strategien/youtube/youtube/option_flow_reversal_lab.py \
  --candles 01_Projectplan/optimizer_data/BTCUSDT_5m_2024-01-01_2024-03-08.json \
  --evaluate-gates \
  --trades-output 01_Projectplan/strategien/youtube/youtube/option_flow_reversal_trades.csv
```

Aktuelle Deribit-BTC-Optionslevels exportieren:

```bash
python 01_Projectplan/strategien/youtube/youtube/deribit_options_levels.py \
  --output 01_Projectplan/strategien/youtube/youtube/deribit_btc_options_levels.csv
```

Deribit-BTC-Optionslevels als fortlaufendes Archiv sammeln:

```bash
python 01_Projectplan/strategien/youtube/youtube/deribit_options_levels.py \
  --output 01_Projectplan/strategien/youtube/youtube/deribit_btc_options_levels_archive.csv \
  --append
```

Mit externen Optionslevels testen:

```bash
python 01_Projectplan/strategien/youtube/youtube/option_flow_reversal_lab.py \
  --candles 01_Projectplan/optimizer_data/BTCUSDT_5m_2024-01-01_2024-03-08.json \
  --levels 01_Projectplan/strategien/youtube/youtube/options_levels.csv
```

CSV-Schema:

```csv
timestamp,price,direction,source
1704205800000,45000,short,gex_call_wall
1704205800000,43000,long,gex_put_wall
```

## 6. Acceptance Gates

Eine echte Umsetzung darf erst als profitabel gelten, wenn mindestens diese Gates erreicht sind:

| Gate | Mindestwert |
|---|---:|
| Trades | >= 200 |
| Profit Factor nach Fees | >= 1.50 |
| Winrate | >= 55 % bei mindestens 2.5R Durchschnittsziel oder >= 60 % bei 2R |
| Max Drawdown | < 15 % |
| Out-of-sample PF | >= 50 % des In-sample PF |
| Fee-to-target | durchschnittliches Ziel > 3x Roundtrip-Fee |

Das Lab kann diese Gates mit `--evaluate-gates` maschinell pruefen. Ein einzelner Backtest ohne Train/Validation-Split setzt das Out-of-sample-Gate bewusst auf `false`, damit aus einem isolierten Lauf keine robuste Profitabilitaet abgeleitet wird.

## 7. Aktueller Realitaetscheck

Das Video liefert starke Behauptungen, aber nicht die proprietaere Formel fuer Optionslevels. Deshalb ist die Strategie erst dann wirklich pruefbar, wenn echte Leveldaten verfuegbar sind. Das beigefuegte Lab simuliert mit OHLCV-Proxy-Levels nur die Mechanik: Level-Touch, Rejection/Absorption-Proxy, Risiko, R-Multiple, 4h-Bias, Taker-Fee und Freitag-Filter.

Fresh Lab Runs auf `BTCUSDT_5m_2024-01-01_2024-03-08.json`:

| Variante | Trades | Brutto-WR | Brutto-PF | Netto-PF nach 0,06 % Taker je Seite | Netto-R | Bewertung |
|---|---:|---:|---:|---:|---:|---|
| Proxy Default mit 4h-Bias | 4 | 50,00 % | 4,00 | 3,05 | +5,04R | Mechanisch profitabel, aber viel zu wenig Trades |
| Proxy Default ohne 4h-Bias | 11 | 36,36 % | 2,29 | 0,97 | -0,36R | Brutto sieht gut aus, Fees zerlegen den Edge |
| Sweep Top-Validierung mit 4h-Bias | 2 | 50,00 % | n/a | 4,01 | +3,54R | Keine statistische Aussage, nur Hypothese |
| Sweep Top-Validierung ohne 4h-Bias | 5 | 40,00 % | n/a | 1,00 | +0,03R | Praktisch breakeven |
| Aktuelle Deribit-Level gegen 2024-Candles | 0 | 0,00 % | 0,00 | 0,00 | 0,00R | Korrekt 0, weil aktuelle Level nicht historisch gelten |

Gate-Auswertung des Proxy Default mit 4h-Bias:

| Gate | Ergebnis | Bewertung |
|---|---:|---|
| Trades >= 200 | 4 | Fail |
| Netto-PF >= 1,50 | 3,05 | Pass |
| Winrate >= 55 % bei 4R-Ziel | 50,00 % | Fail |
| Max Drawdown < 15 % | 0,74 % | Pass |
| Ziel > 3x Roundtrip-Fee | 22,42x | Pass |
| Out-of-sample PF | nicht in Single-Run bewertet | Fail |

Interpretation: Die Proxy-Version findet keine 60-65 % WR wie im Video. Sobald Taker-Gebuehren realistisch als R-Abzug gerechnet werden, ist der Proxy ohne 4h-Bias nicht tragfaehig. Mit 4h-Bias verbessert sich die Qualitaet, aber die Signalzahl faellt unter jede statistische Mindestgrenze. Das bestaetigt die wichtigste Schlussfolgerung: Die Strategie steht oder faellt mit den echten Options-/Gamma-Leveln, nicht mit einfachen prior-day OHLCV-Proxys.

Naechster sinnvoller Schritt: Deribit-Level taeglich mit dem Archivmodus sammeln oder historische Optionssnapshots beschaffen, dann denselben Backtest mit echten Tageslevels gegen den Proxy vergleichen. Ohne diese Daten ist eine "sehr profitable" Klassifikation nicht belegbar.
