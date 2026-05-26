# UT Bot Alerts — Specification

**Quelle:** https://youtu.be/_IXwe_2PZE8 (Kanal: derselbe Autor wie BB+RSI; Original-Idee von „Trades beim Mo")
**Transkript:** `01_Projectplan/transskript ut bot alerts.txt`
**Ranking-Eintrag:** Platz **13**, Profit **+123.06 %** nach 100 Trades, WR **53 %**, R:R **1:2**, PF **2.31**, Max-DD **12 %**, Zeitraum **66 Tage** (Sheet 1 „Ranking"; Sheet 2 „Gap bereinigt": Profit 118 %, PF 2.26 — Differenz < 5 pp, hier dokumentieren wir die `Ranking`-Werte als kanonisch).
**Asset/TF im Video:** Nasdaq-100-Futures (NQ) im Beispiel-Backtest; Autor sagt explizit „Strategie funktioniert genauso gut im Krypto oder Forex" (T25–T26) → wir testen auf **BTCUSDT 5min** (Phase-1-Konvention auf das Video-TF angepasst — abweichend von BB+RSI 1h, weil das Video diesmal auf 5min läuft).
**Erstellt:** 2026-05-23
**Spec-Autor:** chat-session phase-2-task-2 (commit folgt)

> **WICHTIG — Zwei Varianten im Video:**
> Das Video stellt zwei aufeinanderfolgende Varianten vor:
> 1. **Original-Variante „Mo's UT Bot + Linear Regression Candles + Sessions"** (T36–T100) — vom Autor selbst als unprofitabel verworfen (T126–T142: „die Strategie gibt überraschenderweise leider gar keine gute Figur ab … endgültig unprofitabel").
> 2. **Verbesserte Variante „UT Bot als Trendrichtungs-Filter + EMA-200 + Stochastic Momentum Index"** (T173–T277) — vom Autor als kanonisch markiert mit den XLSX-Ranking-Zahlen (WR 53 %, Profit 123 % nach 100 Trades, MaxDD 12 %).
>
> Die **XLSX-Ranking-Zahlen (Platz 13) gehören zur zweiten = „verbesserten" Variante.** Diese Spec dokumentiert daher die *verbesserte* Variante als kanonisch und führt die erste Variante in §9 als Optimierungs-Historie auf, weil der Autor sie selbst verworfen hat.

> **Architektur-Hinweis Green-Field:**
> Anders als bei BB+RSI existiert für UT Bot **kein Code im Repo** (Phase-1-Plan §1 listete `ut_bot.rs` als „aktuell im Code", das war eine Plan-Annahme; Stand 2026-05-23 enthält `rust/trading_engine/src/addins/` nur `bb_rsi.rs`). Section 11 mappt die Spec daher auf **geplante** Code-Locations; ein begleitender Engineering-Plan (`ut_bot_engineering_plan.md`) dokumentiert die Implementierungs-Wellen.

---

## 1. Indikatoren (mit Parametern aus Video — kanonische verbesserte Variante)

| Indikator | Parameter | Quelle im Transkript (Zeile) |
|---|---|---|
| EMA-Trendfilter | Period = **200**, Source = close | T201–T211 („nach einem einfachen exponential moving average … nimmt den Standard von Trading view … ändert in der Input Section die Länge von 9 auf 200") |
| UT Bot Alerts (ATR-Trailing-Stop) | **Key-Value (Sensitivity) = 2 [vorläufig, siehe §12]**, **ATR-Periode = 1** | T65–T69 (Original-Variante: key 1→2, ATR 10→1) und T193–T196 (verbesserte Variante: „reduzieren wir noch die Sensitivität und erhöhen über einen Doppelklick in der Input Section den keyvue von z auf …"). Der Transkript-Text bricht ab („von z auf"); **siehe §12 Abweichung 12.1 für die Default-Begründung.** ATR-Periode bleibt bei 1 (im verbesserten Setup nicht erneut geändert). |
| Stochastic Momentum Index (Uday) | Default-Werte (% K / % D / Smoothing aus TradingView-Indikator-Default — Autor lässt explizit „behaltet die Werte in der inputsection bei", T216–T217) | T207–T220 |
| Sessions-Filter | London + New York Session (verbesserte Variante schaltet zusätzlich zur NY auch die London-Session zu, T184–T187) | T184–T187 |

> **ATR-Konvention für UT Bot:** Das TradingView-Original „UT Bot Alerts" von QuantNomad nutzt einen klassischen Wilder-ATR (siehe Repo `QuantNomad/utbot-alerts`). Wir lesen das parity-konform zu unserem bestehenden `calc_rsi` (Wilder-Smoothing) und definieren die ATR-Implementierung in §11 + Engineering-Plan-Welle U1 mit derselben Smoothing-Konvention.
>
> **UT-Bot-Trail-Linie (vereinfachte Pinescript-Formel, QuantNomad-Original):**
> ```
> nLoss = key_value * ATR(atr_period)
>
> # Trail-Linie (xATRTrailingStop):
> trail[i] = max(trail[i-1], close[i] - nLoss)   if close[i] > trail[i-1] AND close[i-1] > trail[i-1]
>          = min(trail[i-1], close[i] + nLoss)   if close[i] < trail[i-1] AND close[i-1] < trail[i-1]
>          = close[i] - nLoss                     if close[i] > trail[i-1] (sonst)
>          = close[i] + nLoss                     if close[i] < trail[i-1] (sonst)
>
> # Trail-Direction (Position-Bias des UT Bot):
> direction = +1 if close > trail  (UT-Bot „long" / Bar-Color grün)
>           = -1 if close < trail  (UT-Bot „short" / Bar-Color rot)
>
> # Klassische Buy/Sell-Signale (in der Original-Variante):
> buy_signal  = (direction crosses from -1 to +1) AND close > trail
> sell_signal = (direction crosses from +1 to -1) AND close < trail
> ```
> In der **verbesserten Variante** verwendet der Autor *nicht* die Buy/Sell-Signale selbst (T188–T194: „der signalanstieg war mir persönlich zu spät"), sondern nur das `direction`-Feld als Trendrichtungs-Indikator.

---

## 2. Entry — Long

- **Bedingung 1 (übergeordneter Trend):** `close > EMA(200)` (T228–T230: „muss ich der Preis oberhalb des 200 dmas befinden um uns auf ein übergeordneten Aufwärtstrend hinzuweisen")
- **Bedingung 2 (unmittelbarer Trend via UT Bot direction):** `ut_bot.direction == +1` UND auf dieser Bar wurde ein neues UT-Bot-„buy"-Direction-Flip beobachtet (T231–T234: „dann warten wir für die unmittelbare Trend Richtung darauf dass uns der ut bot alers Indikator ein neues bignal ausgibt"). Pragmatische Lesart: `direction[i] == +1 AND direction[i-1] == -1` — also nur direkt nach einem Trend-Flip, nicht auf jeder Folge-Bar.
- **Bedingung 3 (Entry-Trigger via Stochastic Momentum Index):** SMI-Linien-Cross UP (Index-Linie kreuzt Signal-Linie von unten nach oben) **unterhalb der Nullinie** (T235–T238: „bei dem wir ein crostes stochastic momentumindexindikators wichtig unterhalb der Nullinie erhalten")
- **Alle drei Bedingungen MÜSSEN gleichzeitig erfüllt sein.**
- **Bestätigungs-Bar / Execution:** Beim **Open der nächsten Kerze** (T240–T241 „so dass wir beim Open der nächsten Kerze unseren trade eröffnen") — entspricht F-04-Konvention der Engine.

---

## 3. Entry — Short

- **Bedingung 1 (übergeordneter Trend):** `close < EMA(200)` (T253–T255)
- **Bedingung 2 (unmittelbarer Trend via UT Bot direction):** `ut_bot.direction == -1` UND auf dieser Bar wurde ein neues UT-Bot-„sell"-Direction-Flip beobachtet (T255–T257: „der unmittelbare Trend ist beish was uns durch ein zilsignal des ut body alerts Indikators angezeigt wird"). Pragmatische Lesart: `direction[i] == -1 AND direction[i-1] == +1`.
- **Bedingung 3 (Entry-Trigger via SMI):** SMI-Linien-Cross DOWN (Index unter Signal) **oberhalb der Nullinie** (T258–T260)
- **Alle drei gleichzeitig.**
- **Execution:** Beim Open der nächsten Kerze (T261–T262)

---

## 4. Exit — Stop Loss

- **Platzierung Long:** unter dem letzten Swing Low / „sin von Tiefpunkt" vor Entry (T242–T243: „den StopLoss beim letzten sin von Tiefpunkt bzw lokalen Swing low setzen")
- **Platzierung Short:** über dem letzten Swing High (T263–T264: „den stopl setzen wir beim letzten sinnvollen Hochpunkt bzw Swing high")
- **Logik:** initial **fix**, anschließend **Break-Even-Trail bei +1R** (siehe §5)
- **Algorithmische Swing-Definition (Phase-2-Konvention):** identisch zur BB+RSI-Spec §4 (`swing_lookback_bars` Default = 20, rolling `min(low)` / `max(high)` über die letzten N Kerzen *vor* dem Signal-Bar, exklusive). Auf 5min-Kerzen entspricht N=20 einem ~100-Minuten-Lookback (etwa 1 Stunde 40); im Engineering-Plan wird diskutiert, ob N für 5min anders defaulten sollte als für 1h.

---

## 5. Exit — Take Profit

- **Methode:** **R:R 1:2** mit zweistufiger BE-Mechanik (T244–T249 für Long, T265–T270 für Short):
  1. **Stufe 1 — TP bei 1R erreicht:** SL wird auf Break-Even gezogen UND TP-Distanz wird auf 2R hochgesetzt. Wörtlich T246–T249: „ein einfaches risk RE von ein zu ein … pris hat dieses erreicht so dass wir den Tech Profit auf das Doppelte Risiko ziehen und den StopLoss auf den Brick even setzen".
  2. **Stufe 2 — TP bei 2R:** Trade endet bei 2R-Treffer oder am BE-Stop, je nachdem was zuerst passiert.
- **Pragmatische Engine-Abbildung (siehe §11):** Setze beim Entry **direkt** `tp = entry + 2R` (Long) bzw. `entry - 2R` (Short) und lass die bestehende BE-Trail-Mechanik der Engine (`BacktestEngine::run` Schritt 2b, gefixt in D-08) bei +1R automatisch den SL auf Entry ziehen. Das ist **semantisch äquivalent**:
  - Trade endet bei +2R → TP-Hit (Win)
  - Trade endet zwischen +1R und +2R durch Retracement → BE-Stop (Zero PnL, vor Fees)
  - Trade endet vor +1R → Original-SL (Loss)
- **Partial TP:** **Nein.** Der Autor zieht nicht teilweise glatt, sondern verschiebt nur den TP-Punkt und den SL-Punkt. Im Backtest = 100 % der Position bis Final-Exit.
- **Trailing nach TP:** Nicht erwähnt (Trade endet beim 2R-Hit).

---

## 6. Exit — Signal (regulär)

- **Im Video nicht erwähnt → default: keine signal-basierten Exits.** Position bleibt bis entweder TP (2R) oder SL/BE-Stop trifft.
- Insbesondere **kein** Exit bei UT-Bot-Trend-Flip in die Gegenrichtung und **kein** Exit bei SMI-Cross in die Gegenrichtung. Das wäre eine andere Strategy (re-entry-Logik) und wird vom Video nicht beschrieben.

---

## 7. Filter / Zusatzregeln

- **Trendfilter:** Ja — `EMA(200)` (siehe §1, §2 Bedingung 1, §3 Bedingung 1). Long nur über, Short nur unter.
- **Volatilitätsfilter:** Im Video nicht erwähnt → default: keine Restriktion.
- **Session-Filter:** Ja — Entries nur während **London + New York Session** (verbesserte Variante; T184–T187 „aber ich persönlich bevorzuge es auch die London Session mit zu inkludieren und schalte diese deset mit hinzu"). Konkretes Zeitfenster vom Video nicht numerisch spezifiziert; pragmatischer Default analog BB+RSI Spec §7: **09:00–23:00** Lokalzeit Berlin (= London-Open bis NY-Close). Außerhalb dieses Fensters: keine neuen Entries; offene Positionen laufen weiter bis SL/TP.
- **Max-Trades-pro-Session:** Original-Variante = 3 (T117–T119); **verbesserte Variante = nicht erwähnt** (T273–T275 „die gesamte London und New York Session mit"). Pragmatischer Default: **keine Begrenzung** in der verbesserten Variante.
- **Re-Entry nach SL:** Im Video nicht erwähnt → default: erlaubt, sobald wieder ein gültiges Entry-Setup erscheint.
- **Maximal offene Positionen:** 1 (impliziert; im Video nicht widersprochen).

---

## 8. Position Sizing

- **Risk pro Trade:** **2 % des Equity** (T284–T287: „kommen so bei 2% Risiko pro Trade auf ein Profit von sag und schreibe 123%")
- **Formel:** `position_size = (equity × 0.02) / abs(entry − sl)` (identisch zur BB+RSI-Spec §8; in der Engine via `position_size_pct` Helper aus `bb_rsi.rs` umgesetzt, der für UT Bot wiederverwendet werden kann — siehe Engineering-Plan)
- **Pyramiding:** Nein (max 1 Position).
- **Gebühren-Annahme im Video:** Autor erwähnt explizit „natürlich dass wir Gebühren für jeden trade abziehen müssen so dass sich auch unser Profit entsprechend reduziert" (T290–T293), gibt aber im Gegensatz zu BB+RSI keinen konkreten Fee-Wert an. Phase-1-Konvention bleibt Bitunix VIP0 = 0.06 % pro Seite.

---

## 9. Besonderheiten / Optimierungen vom Video-Autor

Der Autor durchläuft zwei Iterationen. Reihenfolge und Begründungen aus dem Transkript:

| Iteration | UT Bot | Trendfilter | Trigger | R:R | Session | Ergebnis 100 Trades | Verworfen weil… |
|---|---|---|---|---|---|---|---|
| **Variante 1** „Mo's Original" (T36–T100) | key=1, ATR=10 (Defaults?) bzw. ATR=1 nach kleinen Tweaks; **Buy/Sell-Signale direkt als Entry** | keine (außer Sessions) | UT Bot Buy/Sell + Linear Regression Candle schließt über/unter weißem MA + nur NY-Session | 1:1 oder 1:2 (Trade-Ausstieg via Linear-Regression-Cross-Back) | NY only, max 3 pro Session | WR ~60 %, Profit **+5 %** vor Gebühren / **negativ** nach Gebühren, durchschnittlicher Gewinn 0.74R, MaxDD nicht numerisch genannt | Linear-Regression-Candles glätten den Preis so stark, dass „der aktuelle Preis grundsätzlich nicht mehr korrekt ausgemacht werden kann" (T153–T156) → Mo's Backtest gibt utopisch gute R:R von 1:10 wegen Smoothing-Bias |
| **Variante 2** „verbessert" ← **KANONISCH** (T173–T277) | **key=2 oder höher [siehe §12]**, ATR=1, **Buy/Sell-Signale verworfen**, nur Direction als Trend-Filter | **EMA(200)** | EMA(200)-Trend + UT-Bot-Direction-Flip + **SMI-Cross unterhalb/oberhalb Nullinie** | **1:2 mit BE-Trail bei 1R** | London + NY, keine Trade-Begrenzung | WR **53 %**, Profit **+123 %** über 66 Tage, MaxDD **12 %** | — (gewählt) |

**Konzeptioneller Bruch zwischen Variante 1 und 2:**
- Variante 1 = **Pure UT-Bot-Signal-Trading mit Smooth-Chart-Trickserei** (geglättete Linear-Regression-Candles erzeugen scheinbar saubere Entries, die auf den Rohpreisen aber nicht reproduzierbar sind).
- Variante 2 = **Multi-Indikator-Confluence**: UT Bot dient nur noch als Trendrichtungs-Filter (low frequency), EMA(200) gibt den übergeordneten Bias, SMI liefert den eigentlichen Entry-Trigger (high frequency mit Cross-Logik analog zum BB+RSI-RSI-Cross).

Diese Unterscheidung ist für die Implementierung entscheidend: wir bauen **nur Variante 2**. Variante 1 wird nicht implementiert (linear regression candles sind kein eigener Indikator in unserer Engine und das Video selbst verwirft die Variante).

---

## 10. Bekannte Limitierungen / Warnungen vom Autor

- **Subjektive SL-Platzierung:** Der Autor zeichnet Swing-Low/Swing-High manuell (analog BB+RSI). Wir verwenden stattdessen die algorithmische `swing_lookback_bars`-Definition aus BB+RSI §4.
- **Stochastic-Momentum-Index-Variante nicht eindeutig:** Der Autor referenziert „diesen hier von Uday" (T207–T208) ohne Pinescript-Code zu zeigen. Es gibt mehrere SMI-Implementierungen auf TradingView mit demselben Namen — wir wählen einen vom Pinescript-Standard abgeleiteten Default und dokumentieren in §12 die Wahl.
- **Smoothing-Bias-Warnung:** Der Autor warnt explizit vor Strategien, die geglättete Preise als Entry-Trigger nutzen (T160–T172: „bitte passt deshalb bei solchen Indikatoren auf und schaut lieber zweimal hin"). Dies betrifft Variante 1, nicht Variante 2 — aber als Lesson für Phase 3 zu beachten: kein Indikator, der den Preis selbst smoothed, sollte als Entry-Trigger dienen.
- **Backtest-Zeitraum nur 66 Tage / 100 Trades** — sehr schwache statistische Signifikanz (kürzer als BB+RSI 284 Tage). Walk-Forward in Phase 3 ist hier besonders relevant.
- **5min-Timeframe — exchange-spezifische Microstructure:** Der Video-Backtest läuft auf NQ-5min. NQ und BTCUSDT haben fundamental andere 5min-Charakteristik (NQ pausiert nachts, BTC 24/7; NQ hat höheres Spread/Slippage-Risiko bei Retail-Größen, BTC bei Binance VIP0 quasi null). Phase-2-Risiko analog zu BB+RSI v3 (Pfad C möglich, siehe §13).

---

## 11. Mapping Spec → Code (geplant, GREEN-FIELD)

Da der UT-Bot-Code im Repo noch nicht existiert, mappt diese Section die Spec-Bedingungen auf **geplante** Code-Locations. Die `*` markierten Helpers existieren bereits aus der BB+RSI-Implementierung und werden wiederverwendet.

| Spec-Bedingung | Code-Datei (geplant) | Funktion / Block | Status |
|---|---|---|---|
| EMA(200) Trendfilter — Long: `close > EMA(200)`; Short: `close < EMA(200)` | `rust/trading_engine/src/addins/ut_bot.rs` (neu) | `on_candle` Trend-Gate-Block, ruft `calc_ema(&closes_full, 200)` aus `bb_rsi.rs` auf* | **Helper existiert** (Welle 1 für BB+RSI), Strategie-Block neu |
| EMA-Trendfilter Dart-Parität | `lib/services/indicators.dart` | `calculateEMA(closes, 200)`* | existiert (siehe BB+RSI-Parität) |
| ATR(period) Wilder-Smoothing | `rust/trading_engine/src/addins/ut_bot.rs` (neu, pub helper) | `calc_atr(highs, lows, closes, period)` — Wilder-Smoothing analog zu `calc_rsi` in `bb_rsi.rs` | **NEU** |
| ATR Dart-Parität | `lib/services/indicators.dart` (neu) | `calculateATR(candles, period)` mit identischer Wilder-Konvention | **NEU** |
| UT-Bot-Trail-Linie + Direction-State | `rust/trading_engine/src/addins/ut_bot.rs` (neu) | `UtBotState { trail: f64, prev_close: f64, direction: i8 }` + `update_trail(...)` pro Bar | **NEU** |
| UT-Bot Direction-Flip-Detection (Long-Entry-Bedingung 2) | `rust/trading_engine/src/addins/ut_bot.rs` (neu) | im `on_candle`: `if state.prev_direction == -1 && state.direction == +1 { ... }` | **NEU** |
| Stochastic Momentum Index (SMI) | `rust/trading_engine/src/addins/ut_bot.rs` (neu, pub helper) | `calc_smi(closes, highs, lows, k_period, d_period, smoothing)` — TradingView-Default-Konvention | **NEU** |
| SMI Dart-Parität | `lib/services/indicators.dart` (neu) | `calculateSMI(candles, ...)` mit identischer Konvention | **NEU** |
| SMI-Cross-Detection (Entry-Trigger Long: Index kreuzt Signal UP unterhalb Nullinie) | `rust/trading_engine/src/addins/ut_bot.rs` | im `on_candle`: `prev_index < prev_signal && index >= signal && index < 0.0 && signal < 0.0` | **NEU** |
| Swing-Low/High SL (Long unter swing_low, Short über swing_high) | `rust/trading_engine/src/addins/ut_bot.rs` | nutzt `swing_low(...)` und `swing_high(...)` aus `bb_rsi.rs`* via `pub use` oder Re-Import | **Helper existiert** (BB+RSI Welle 2) |
| R:R 1:2 TP-Distanz vom Signal-Bar-Close | `rust/trading_engine/src/addins/ut_bot.rs` | `tp = price ± 2.0 * sl_distance` direkt in der Signal-Emission | **NEU** (analog zu BB+RSI `tp_rr_ratio`-Parameter, Default hier 2.0 statt 3.0) |
| BE-Trail bei +1R | `rust/trading_engine/src/backtest/mod.rs`* | `BacktestEngine::run` Step 2b (`initial_sl_distance` + `breakeven_applied`) — bereits aktiv in D-08 | **Engine-Mechanik existiert** — keine Strategy-Änderung nötig |
| Risk-2 %-Sizing | `rust/trading_engine/src/addins/ut_bot.rs` | `position_size_pct(price, sl_distance, 0.02)`* aus `bb_rsi.rs` | **Helper existiert** (BB+RSI Welle 2) |
| Risk-Sizing Dart-Parität | `lib/services/backtest_service.dart` | `_PendingEnterLong`-Fill nutzt `sizePct`* aus Signal | existiert |
| Session-Filter (09:00–23:00 Lokalzeit Berlin) | `rust/trading_engine/src/addins/ut_bot.rs` ODER engine-shared | **Architektur-Entscheidung offen, siehe §12.2** | **NEU** (für beide Strategien gleich) |
| Session-Filter Dart-Parität | `lib/services/backtest_service.dart` | analog | **NEU** |
| Strategy-Manifest-Registrierung | `rust/trading_engine/src/addins/mod.rs` | `pub mod ut_bot; pub use ut_bot::UtBotStrategy;` | **NEU** |
| Dart-Fallback der gesamten Strategy | `lib/services/backtest_service.dart` | neuer `UtBotParams` + Strategy-Branch | **NEU** |

---

## 12. Abweichungen von der Vorlage (bewusst)

**12.1 Default für UT-Bot-Sensitivity (`key_value`) in Variante 2**

- **Abweichung:** Der Transkript-Text bricht an der entscheidenden Stelle ab („den keyvue von z auf …", T194–T196). Wir können den exakten Default nicht aus dem Video lesen.
- **Hypothese:** Aus dem Kontext „reduzieren wir noch die Sensitivität und erhöhen den keyvalue" — Variante-1-Wert war key=2 (T67); „erhöhen" bedeutet daher mindestens 3. Die häufigste Community-Konvention in YouTube-UT-Bot-Tutorials für „weniger Sensitivität" ist **key=3** auf 5min.
- **Default-Wahl:** `key_value = 2.0` als Spec-Default markieren (entspricht der TradingView-Default-Konfiguration des QuantNomad-Indikators), aber im Manifest `ParameterSchema` weit gefasste Range [0.5, 5.0] mit Step 0.5, damit Phase 3 das Tuning übernehmen kann.
- **Begründung:** Konservativster Default, der das Original-Verhalten erhält. Falls Reference-Backtest in Welle U3 deutlich zu viele/zu wenige Signale liefert (>200 oder <20 Trades), ist `key_value` der erste Parameter, der im Sanity-Sweep variiert wird.
- **QA-Frage offen:** Soll Default key=3 (häufige Community-Konvention für 5min) sein oder key=2 (TradingView-Default)? **Brief an QA enthält diese Frage explizit.**

**12.2 Architektur-Frage: Session-Filter — Strategy-intern vs Engine-shared**

- **Abweichung:** Der Session-Filter (09:00–23:00 Lokalzeit Berlin) wird von BB+RSI Spec §7 ebenfalls verlangt, ist dort aktuell aber nicht implementiert (Diff-MD listet als „Fehlt komplett"). UT Bot bringt denselben Bedarf.
- **Optionen:**
  - (a) `ut_bot.rs` implementiert seinen eigenen Session-Filter lokal (Duplikat-Risiko bei späterer BB+RSI-Nachrüstung).
  - (b) Ein neues Engine-shared `lib/strategy/session_filter.rs` (oder `addins/common.rs`) wird von beiden Strategien konsumiert.
- **Pragmatische Default-Entscheidung:** Option (a) für die erste UT-Bot-Implementierung, mit `TODO`-Marker für späteren Refactor zu (b). Begründung: Engineering-Plan-Welle U2 muss landen, bevor wir Refactor-Aufwand auf BB+RSI rückwirken lassen — sonst koppeln wir UT-Bot-Welle 2 an einen BB+RSI-Re-Test.
- **QA-Entscheidung erforderlich** bevor Engineering-Plan-Welle U2 startet.

**12.3 ATR-Smoothing-Konvention**

- **Abweichung:** QuantNomad's Pinescript-Original nutzt `ta.atr()` (Wilder-Smoothing, TradingView-Default). Wir folgen dieser Konvention.
- **Begründung:** Konsistent mit `calc_rsi` (Wilder) in unserer Engine; parity-konform zwischen Dart und Rust.
- **Test-Beleg-Pflicht:** Unit-Test mit synthetischer TR-Serie (konstant 1.0) muss ATR = 1.0 ergeben; weitere Test mit bekannter Wilder-Sequenz (z.B. konstant 1 für `period` Bars, dann konstant 2 → ATR konvergiert exponentiell zu 2 mit Faktor `(period-1)/period` pro Bar).

**12.4 SMI-Default-Variante**

- **Abweichung:** Es gibt mindestens vier verbreitete „Stochastic Momentum Index"-Varianten auf TradingView (Blau 1993, modifizierter Stoch RSI, Uday-Custom, etc.). Wir wählen den **Blau-1993-Standard** (Double-EMA-smoothed momentum) mit Default-Periode 14 / 5 / 3 (Length / K-Smoothing / D-Smoothing).
- **Begründung:** Das ist der namensgebende Original-Algorithmus und der Default-Wert in den meisten TradingView-Custom-Indikatoren mit dem Namen „Stochastic Momentum Index".
- **QA-Risiko:** Falls Uday's spezifische Variante davon abweicht, ist das ein Pfad-B-Kandidat (bewusste Abweichung dokumentiert). Engineering-Plan-Welle U2 enthält die SMI-Implementation als isolierten atomaren Commit, damit Variante-Wechsel ohne Rest-Strategy-Refactor möglich ist.
- **QA-Entscheidung (Welle U2-1, smi_length=14 konfirmiert):** Default bleibt Blau-1993 14/5/3. Uday-Variante-Recherche wird in §13.6 als Phase-3-Backlog-Eintrag geparkt.

**12.5 Path-B-Toggle `smi_cross_above_zero` (Welle U3 Sub-Commit)**

- **Abweichung:** Spec §2 Bedingung 3 verlangt SMI-Cross-UP **unterhalb** der Nullinie für Long; Spec §3 verlangt SMI-Cross-DOWN **oberhalb** der Nullinie für Short (Transkript-Wortlaut T235–T238 / T258–T260). Der Welle-U3-Real-Data-Backtest (siehe §13.5) zeigt unter diesen Default-Bedingungen WR ≈ 24 %, PF ≈ 0.53 — weit unter dem XLSX-Target.
- **Toggle:** Neuer Manifest-Parameter `smi_cross_above_zero` (default `0.0` = strict Spec). Wenn `1.0`, kehrt sich das Zero-Line-Gate um: Long verlangt SMI-Cross-UP-Above-Zero, Short verlangt SMI-Cross-DOWN-Below-Zero. Logik konsolidiert in `detect_entry()` (Rust) und gespiegelt in `BacktestService.runUtBot` (Dart).
- **Begründung:** Bewusste Abweichung als Path-B-Experiment. Diagnose-Hypothese: in starken Krypto-Trends ist der strict-spec Trigger (SMI < 0 für Long) eine Mean-Reversion-Signatur, die gegen den EMA(200)-Trend-Filter läuft. Die `smi_cross_above_zero=1`-Variante testet die Pro-Trend-Lesart.
- **Test-Beleg:** Drei Unit-Tests in `addins::ut_bot::tests` (Inversion-Long, Inversion-Short, strict-Mode-Pass-Through) plus ein Dart-Toggle-Test (`smi_cross_above_zero toggle produces different trade list`) auf der 400-Bar Random-Walk-Fixture.
- **Real-Data-Resultat:** PF=0.64 (Test 3, BTCUSDT 5min, key=2.0) — besser als strict-spec PF=0.53, aber immer noch deutlich unter dem Akzeptanzband. Toggle wird **nicht** als neuer Default vorgeschlagen; bleibt als Optimizer-Lab-Knob.

---

## 13. Acceptance für Implementierung

### 13.1 Acceptance-Pfade nach Plan §4.4 (rev4)

Drei mögliche Acceptance-Ausgänge pro Strategie:

1. **Pfad A — Im Toleranz-Band:** Code reproduziert XLSX-Targets auf dem Video-Asset/TF (oder einem nachgewiesenermassen äquivalenten). → GO Phase 3 als **produktiver Default-Kandidat**.
2. **Pfad B — Bewusste Abweichung dokumentiert:** Implementierung weicht vom Video ab (z.B. Fee-Optimierung, plausibler Tippfehler, SMI-Variante), Begründung in §12. → GO Phase 3 mit dokumentierter Abweichung als **produktiver Default-Kandidat**.
3. **Pfad C — Video-treu, aber Targets auf Ziel-Asset/TF nicht erreichbar:** alle Spec-Diffs implementiert (Engine-Korrektheit beweisbar), aber XLSX-Targets reflektieren Asset/TF-Microstructure aus dem Video, die auf der eigenen Ziel-Konfiguration nicht reproduzierbar ist. **Voraussetzung: Mandatory Sanity-Sweep** in mindestens drei Variationen (alternative TF auf demselben Asset, alternatives Asset auf derselben TF, Parameter-Sweep über die Haupt-Sensitivität — `key_value`), dokumentiert als `01_Projectplan/specs/ut_bot_diagnose_{date}.md`. Strategie bleibt im Add-in-Manifest als **Phase-3-Optimizer-Lab-Kandidat** statt produktiver Default.

### 13.2 XLSX-Targets (Soll-Werte aus Ranking-Platz 13, Video-NQ-5min)

Backtest auf **BTCUSDT 5min** über **66 Tage** (Video-Zeitraum-Äquivalent — z.B. ein 66-Tage-Slice aus 2024 oder 2025, je nach Datenverfügbarkeit; konkretes Range-Mapping erfolgt zum Backtest-Zeitpunkt in Welle U3):

| Metrik | Video-Wert (XLSX Platz 13) | Toleranz | Akzeptanz-Band |
|---|---|---|---|
| Profit-Faktor | **2.31** | ±0.30 | [2.01, 2.61] |
| Win-Rate | **53 %** | ±5 pp | [48 %, 58 %] |
| Max-Drawdown | **12 %** | +5 pp | < 17 % |
| Trades (100-Trade-Reihe) | **100** | ±20 % | [80, 120] |
| Profit nach 100 Trades | **+123.06 %** (Video sagt nicht explizit „vor" oder „nach" Gebühren; Autor erwähnt nur nachträgliches Fee-Abziehen, T290–T293) | ±25 pp | [+98 %, +148 %] (vor-Fees-Annahme) |
| R:R im Trade-Log | **1:2** mit BE-Trail (Mischung aus 0R-BE-Exits und 2R-TP-Hits) | strict TP-Distanz | exakt 2.0 (BE-Exits akzeptiert als „R=0") |

### 13.3 Mandatory Sanity-Sweep (vor Path-C-Klassifikation Pflicht, falls Welle U3-Baseline nicht im Band)

Falls der Welle-U3-Baseline-Backtest auf BTCUSDT 5min die XLSX-Targets verfehlt, sind **vor** der Path-C-Klassifikation folgende drei Variationen verpflichtend zu testen und in `ut_bot_diagnose_{date}.md` zu dokumentieren (Plan §4.4 rev4):

| Variation | Setup | Zweck |
|---|---|---|
| **TF-Sweep** | BTCUSDT **15min** und **1h** mit denselben Default-Parametern | Prüfen, ob 5min-Microstructure (Noise / Wick-Volatility) das Problem ist, analog zu BB+RSI 4h |
| **Asset-Sweep** | **ETHUSDT 5min** mit denselben Default-Parametern | Prüfen, ob BTC-spezifische Volatilität das Problem ist |
| **Parameter-Sweep** | BTCUSDT 5min, `key_value` ∈ {1.5, 2.0, 3.0, 5.0}, ATR-Period ∈ {1, 5, 10}, alles andere fix | Prüfen, ob Default-Wahl in §12.1 das Problem ist (insbesondere die `key_value`-Hypothese aus T194–T196) |

**Klassifikations-Logik:**
- Falls **mindestens eine Variation im Band landet** → kein Pfad C; Empfehlung als Pfad B mit Default-Anpassung.
- Falls **alle Variationen außerhalb des Bandes** → Pfad C bestätigt, Strategy bleibt als Phase-3-Optimizer-Lab-Kandidat im Manifest.

### 13.4 Engine-Korrektheits-Gate (Phase-1-Vorgabe bleibt erfüllt)

Unabhängig vom Acceptance-Pfad müssen folgende Gates **vor** dem Phase-2-Tag grün sein:

- Unit-Tests pro Entry-/Exit-Bedingung grün (mindestens: ATR-Wilder-Konvergenz, UT-Bot-Trail-Update, UT-Bot-Direction-Flip-Detection, SMI-Cross-Detection, Long-Entry-Confluence, Short-Entry-Confluence, Swing-SL-Korrektheit, R:R-1:2-TP-Distanz, Risk-Sizing, Session-Filter-Cutoff)
- Dart↔Rust-Parität 1e-9 auf einer 200-Candle-Synthese-Fixture (analog zur BB+RSI-Welle-1/2-Konvention; Fixture muss mindestens einen erfolgreichen Long-Entry und einen erfolgreichen Short-Entry enthalten)
- Phase-1-Reference-Backtest (BTCUSDT 1h 2024-H1, BB+RSI) bleibt **strukturell** grün (Reproduzierbarkeit 3×, Parität, `totalTrades > 0`) — kein Engine-Drift durch UT-Bot-Hinzufügung
- `flutter analyze` 0 Warnungen, `cargo clippy` 0 Warnungen

**Welle-U2-5 Resolution:** FFI-Parity-Contract eingelöst. Native engine over flutter_rust_bridge erreicht 1e-9 totalPnl / WR / Sharpe / MaxDrawdown gegen die Dart-Fallback-Engine auf der 400-Candle LCG-Random-Walk-Fixture (`test/integration/dart_rust_ut_bot_parity_test.dart`, 3 Tests). Fixture-Design-Notiz: synthetische Sinusoid-/Triangle-/Sawtooth-Shapes triggern keine UT-Bot-Strict-Spec-Entries; der Random-Walk produziert genug chaotische Mikro-Reversals, dass alle drei Confluence-Bedingungen (EMA + ATR-Direction-Flip + SMI-Cross-Below-Zero) auf demselben Bar zusammenfallen. Die im Welle-U2-4 ESKALATIONS-MARKER beschriebene „0 Trades auf Synth-Fixtures"-Beobachtung ist ein Artefakt der Fixture-Form, kein Strategie-Defekt.

### 13.5 Pfad-Klassifikation (Welle U3 final, 2026-05-23)

**Verdikt:** Pfad C (Video-treu implementiert, Targets auf Ziel-Asset/TF nicht erreichbar).

**Mandatory Sanity-Sweep (§13.3) durchgeführt** — alle 7 vorgeschriebenen Variationen plus zwei zusätzliche Path-B-Tests (T2 key=3 aus §12.1, T3 `smi_cross_above_zero=1` aus §12.5). **KEINE Variation erreicht alle vier Bänder gleichzeitig.** Best-of-Sweep ist T4c (ETHUSDT 5min) mit PF=0.81 — immer noch defizitär.

Vollständige Resultat-Tabelle, bit-exakte Run-Snapshots und Driver-Analyse: `01_Projectplan/specs/ut_bot_diagnose_2026-05-23.md`.

**Root-Cause-Hypothese (Diagnose §4 Punkt 2):** Die UT-Bot-EMA200-SMI-Confluence kombiniert einen Trend-Filter (EMA-200) mit einem Mean-Reversion-Trigger (SMI-Cross-While-Same-Sign-Zero). Auf NQ-5min (Video) profitiert dieser Mix vom auctions-getriebenen Open-/Close-Mean-Reversion-Verhalten und dem Future-Roll-Liquiditäts-Profile. Auf 24/7-Krypto-Märkten existieren diese Mikrostruktur-Vorteile nicht — die zwei Filter sind gegenläufig kalibriert für Krypto-Volatilität, was die ~10pp-Lücke im Win-Rate (20–25 % statt 53 % Target) konsistent über alle untersuchten Achsen erklärt.

**Final-Default-Parameter (unverändert gegenüber `ut_bot_manifest()`):** `key_value = 2.0`, `atr_period = 1`, `smi_length = 14`, `smi_k_smoothing = 5`, `smi_d_smoothing = 3`, `swing_lookback_bars = 20`, `tp_rr_ratio = 2.0`, `risk_per_trade = 0.02`, `session_filter_enabled = 0`, `smi_cross_above_zero = 0`. Die Defaults bleiben video-treu; die XLSX-Acceptance-Lücke ist eine Eigenschaft des Asset/TF-Setups, nicht der Implementation.

### 13.6 Phase-3-Konsequenz

- **Phase-2-Tag-Kriterium:** UT Bot v1 bleibt als Add-in-Manifest-Eintrag (`addins::ut_bot::UtBotStrategy`) registriert. Strategy-Code, Dart-Fallback und FFI-Bindings sind produktionsreif (Engine-Korrektheit per §13.4 grün, FFI-Parity per §13.4 Welle-U2-5-Resolution grün). Kein Default-Wechsel commitet.
- **Phase-3 Backlog (mittlere Priorität):** „UT Bot v1 ETH-Multi-TF-Sweep (ETHUSDT 5m/15m/1h + BTCUSDT 4h-Vergleich), Ziel PF ≥ 1.5 bei trades ≥ 50". Erwartung niedriger Erfolgswahrscheinlichkeit als der vergleichbare BB+RSI-4h-Backlog-Eintrag — bei BB+RSI lieferte 1h → 4h einen positiven Sweet-Spot (Diagnose 2026-05-23 C1), bei UT Bot zeigt 5m → 15m → 1h einen monotonen Performance-Abfall. **Nach Welle A2 (§13.7) auf niedrige Priorität herabgestuft.**
- **Phase-3 Backlog (niedrige Priorität):** „SMI Uday-spezifische Variante (§12.4) recherchieren und gegen Blau-1993-Standard backtesten". Recherche-Aufwand ~1h; kann nur Implementations-Detail-Fixes liefern, ohne die grundlegende Confluence-Inkompatibilität auf Krypto-5min anzugreifen.

### 13.7 Welle-A2 Fee-Realismus-Validierung (Phase 3.2, 2026-05-26)

**Verdikt:** **Outcome b — Strategy-Logik strukturell limitiert, nicht fee-limitiert.** Pfad C strikt konfirmiert über das gesamte Fee-Spektrum.

Welle-O2 (Taker 0.06 %) lieferte Top-1 Trial 489 mit PF=0.92, profit=−1.65 % auf 52 Trades. Hypothese: Bitunix-Taker-Fee = 52 × 0.12 % = 6.24 pp Fee-Drag dominiert die Verlust-Magnitude. Welle-A2-Validation re-sweept identischen Search-Space + Seed mit `fee_rate=0.0` (Sanity-Check, 500 Trials, 2.7 h Compute auf BTCUSDT 5m 2024-01-01 → 2024-03-08).

Result Zero-Fee: identischer Top-1 Trial 489 (deterministisch), PF=1.271, profit=+4.64 %. Δ-Profit (+6.29 pp) matched predicted Fee-Drag (+6.24 pp) → Engine-Fee-Accounting validiert. ABER: qualifizierter Trial-Count bleibt **2/500 (0.4 %) konstant**; XLSX-Band-Hit-Count bleibt **1/5 konstant** (nur MaxDD); WR=19.23 % bleibt konstant.

**Strategy-strukturelle Begründung:** Bei `tp_rr_ratio = 3.20` ist die break-even-Win-Rate `1/(1+R) = 23.8 %`. Top-1 WR=19.23 % liegt **4.6 pp unter Break-Even selbst ohne Fees**. Die Edge ist gross-positiv (PF=1.27) nur, weil Trailing-Stop + partial-TP-Effekte effective-R höher als nominal-`tp_rr` machen. Diese dünne Edge ist nicht fee-sensitiv genug, um Bands-Hit-Count zu verschieben.

**Maker-Variant (nicht ausgeführt):** Closed-form predicted aus §1 des Vergleichs-Docs: Maker round-trip 0.04 % × 52 Trades = 2.08 pp drag → predicted Top-1 maker-profit ≈ +2.56 %, PF ≈ 1.10. Weit unter XLSX-PF-Band [2.01, 2.61]. A2-Maker-Sweep ist **prediktiv-redundant**; Outcome b falsifiziert die Fee-Driver-Hypothese unabhängig vom Fee-Tier.

**Reconciliation mit §13.5:** Die „Confluence-Inkompatibilität auf Krypto-5min"-These (EMA200-SMI-Confluence + 24/7-Mikrostruktur) bleibt die einzige verbleibende Erklärung der ~30 pp WR-Lücke. Fee war die naheliegende externe Erklärung; nach Welle A2 kann sie aus dem Erklärungs-Raum ausgeschlossen werden. §13.5-These verschärft sich empirisch.

**Welle-R3-C2-Reconciliation:** Welle-R3 C2 (adx_thr=35) lieferte 8 Trades PF=2.34 — die High-PF-Selectivity ist Markt-Phasen-getrieben, nicht Strategy-edge-getrieben. Welle-A2 belegt: die Strategy hat keine selbst-induzierte Edge auf 24/7-Krypto-Volatilität.

**Belege:** [`ut_bot_fee_realism_2026-05-26.md`](./ut_bot_fee_realism_2026-05-26.md), [`ut_bot_zerofee_sweep_2026-05-26.md`](./ut_bot_zerofee_sweep_2026-05-26.md).

**Phase-3-Backlog-Update:** Der mittel-priorisierte ETH-Multi-TF-Sweep-Eintrag (§13.6) wird auf **niedrige Priorität** herabgestuft. Welle A2 reduziert die Erwartungs-Wahrscheinlichkeit zusätzlich: wenn Fee 100 % aus dem Verlust-Driver-Set entfernt wird und der Strategy-Edge trotzdem nur 4 pp positiv ist, sind weitere TF/Asset-Variationen Sample-Space-Lottery ohne strukturelle Begründung.

**Keine weiteren UT-Bot-Sub-Wellen empfohlen.** Phase 3.2 Welle-A2-Tail closed.
