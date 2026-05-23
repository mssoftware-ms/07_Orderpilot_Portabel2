# {Strategie} — Specification

**Quelle:** {YouTube-Link aus Ranking}
**Transkript:** `01_Projectplan/transskript {name}.txt`
**Ranking-Eintrag:** Platz {n}, Profit {x}, WR {y}%, R:R {z}
**Asset/TF im Video:** {symbol} / {timeframe}
**Erstellt:** {datum}
**Spec-Autor:** {chat-session / commit}

---

## 1. Indikatoren (mit Parametern aus Video)

| Indikator | Parameter | Quelle im Transkript (Zeile/Sekunde) |
|---|---|---|
| {Name} | Period={...}, Source={close/hl2}, ... | {z.B. T01:24} |
| {...} | {...} | {...} |

---

## 2. Entry — Long

- **Bedingung 1:** ...
- **Bedingung 2:** ...
- **(alle Bedingungen MÜSSEN gleichzeitig erfüllt sein, sofern nicht anders vermerkt)**

Bestätigungs-Bar (falls Video das verlangt): {ja/nein, welche Logik}

---

## 3. Entry — Short

- **Bedingung 1:** ...
- ...

---

## 4. Exit — Stop Loss

- **Platzierung:** {z.B. „letztes Swing-Low – 1 ATR", „X% unter Entry", „BB-Lower"}
- **Logik:** {fix / dynamic / trailing}
- **Update-Regel** (bei trailing): {Bedingung}

---

## 5. Exit — Take Profit

- **Methode:** {z.B. „1× SL als R", „R:R 1:2", „BB-Middle"}
- **Partial TP:** {ja/nein, bei welcher R-Stufe}
- **Trailing nach TP:** {ja/nein}

---

## 6. Exit — Signal (regulär)

- **Bedingung:** ...
- **Direction:** {Close-on-signal-against / close-on-explicit-signal-only}

---

## 7. Filter / Zusatzregeln

- **Trendfilter:** {ja/nein, wie}
- **Volatilitätsfilter:** {ja/nein, wie}
- **Session-Filter:** {ja/nein, welche Zeiten}
- **Re-Entry nach SL:** {erlaubt / verboten / nach X Bars}
- **Maximal offene Positionen:** {1 / N}

---

## 8. Position Sizing

- **Risk pro Trade:** {% des Equity}
- **Formel:** `position_size = (equity × risk_pct) / abs(entry − sl)`
- **Pyramiding:** {ja/nein, max Stufen}

---

## 9. Besonderheiten / Optimierungen vom Video-Autor

- (z.B. „RSI-Threshold von 30/70 auf 20/80 verschoben")
- (z.B. „BB von 20/2 auf 30/2.5 angepasst")
- (z.B. „nur in NY-Session aktiviert")

---

## 10. Bekannte Limitierungen / Warnungen vom Autor

- (z.B. „Nur Trending-Märkte, im Range-Markt vermeiden")
- (z.B. „funktioniert schlecht auf <15min")

---

## 11. Mapping Spec → Code

| Spec-Bedingung | Code-Datei | Funktion / Block |
|---|---|---|
| {z.B. „RSI < 30"} | `rust/trading_engine/src/addins/{name}.rs` | `on_candle` Zeile {n} |
| ... | ... | ... |

---

## 12. Abweichungen von der Vorlage (bewusst)

(Falls die Implementierung *nicht* dem Video folgt — Begründung hier dokumentieren. Beispiele: Maker-Order-Constraint aus Fee-Optimierung, plausibler Tippfehler im Video, …)

- **Abweichung:** ...
- **Begründung:** ...

---

## 13. Acceptance für Implementierung

Backtest auf {Asset}/{TF} über {Range aus XLSX}:

| Metrik | Video-Wert | Toleranz | Akzeptanz-Band |
|---|---|---|---|
| Profit-Faktor | {X} | ±0.3 | [{X-0.3}, {X+0.3}] |
| Win-Rate | {Y}% | ±5pp | [{Y-5}%, {Y+5}%] |
| Max-Drawdown | {Z}% | +5pp | < {Z+5}% |
| Trades | {N} | ±20% | [{N×0.8}, {N×1.2}] |

Plus:
- Unit-Tests pro Entry-/Exit-Bedingung (TDD-Stil) grün
- Dart-Rust Parity 1e-9 auf einer 200-Candle-Synthese-Fixture
- Phase-1-Reference-Backtest (BTCUSDT 1h 2024-H1) bleibt grün (kein Engine-Drift)
