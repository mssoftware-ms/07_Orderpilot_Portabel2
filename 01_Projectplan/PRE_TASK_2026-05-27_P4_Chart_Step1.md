# Pre-Task Welle P4-Chart Step-1 — Live Candlestick + BB + RSI

**Issued:** 2026-05-27 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem
**Base:** `13d11d1` (origin/main, inkl. B4.4 Live-Toggle Enable)

---

## ⚠️ Pre-Task-Disclaimer

Sichere Zwischenwelle (kein Geld-Risiko, kein Live-Pfad-Touch). Gibt Maik Zeit, den B4.4-Live-Toggle-Flow ausgiebig zu smoke-en, bevor P4P Step-2 (Real-Order-Routing) drankommt.

Code-Skizzen weiterhin unverifizierte Hypothesen. Engine-Refactor in P4C-1 ist die heikelste Stelle — `phase1_reference_backtest` muss bit-exakt grün bleiben.

---

## 1. Scope

**Chart-Tab finalisieren** — `ComingSoonBanner` raus, echter Live-Candlestick-Chart mit BB+RSI-Overlay. Visuelle Strategy-Validation in Real-Time. **Bit-exakt zur Engine**, damit ein Chart-Signal nicht von einem Backtest-/Paper-Signal abweicht.

**In Scope:**
- Engine-Refactor: BB + RSI aus `backtest_service.dart` in `indicators.dart` extrahieren (no-functional-change, Engine ruft jetzt indicators)
- **ChartProvider** mit Binance REST initial-load + WebSocket live-updates (`binance_websocket.dart` aus B4-1 wiederverwenden)
- **Live-Candlestick-Chart** via `candlesticks: ^2.1.0` (bereits in pubspec)
- **BB-Overlay** (Upper / Middle / Lower) direkt auf Candle-Chart
- **RSI Sub-Chart** mit 30 / 70-Schwellen
- **Symbol/Timeframe-Picker** funktional verdrahtet
- `ComingSoonBanner` aus `chart_screen.dart` entfernen
- BB-Period / Stddev konfigurierbar via Provider (Default: bbPeriod=20, stddev=2.0, rsiPeriod=14)

**Out-of-Scope (spätere Wellen):**
- Sync from Backtest (Chart übernimmt Symbol/TF von BacktestProvider) — optional, kommt wenn UX-Bedarf da
- Sync from Paper-Trading (Live-Position-Markers auf Chart) — eigene Welle
- Drawing-Tools (Trendlines, Fibonacci, etc.) — eigene Welle / Phase-5
- Multi-Indicator-Pane (mehrere Indikatoren parallel) — eigene Welle
- Multi-Symbol-Views (Watchlist mit mehreren Charts) — Phase-5
- Volume-Pane unter dem Chart — kann später kommen
- Touch-Pinch-Zoom / Pan auf Mobile — wenn das candlesticks-Package das schon kann, Bonus; sonst Standard-Range-Buttons

---

## 2. Kontext

### Vorhandener Code

- **`lib/ui/screens/chart_screen.dart`** (136 Zeilen): Layout-Preview mit `ComingSoonBanner`, Symbol-Dropdown, Timeframe-Chips, zwei Placeholder-Container (Chart-Bereich + RSI-Bereich). State nur lokal (`_selectedSymbol`, `_selectedTimeframe`).
- **`lib/services/binance_websocket.dart`** (B4-1): `BinanceKlineStream` mit `Stream<KlineUpdate>` + Reconnect + `closedOnly`. Wiederverwendbar.
- **`lib/services/binance_api_client.dart`**: REST-Client mit `downloadHistory(symbol, interval, days)`. Wiederverwendbar für initial-load.
- **`lib/services/indicators.dart`**: hat `swingLow`, `swingHigh`, `calcAtr`, `_emaSeriesFrom`, `calcEma`, Ichimoku-Suite. **Hat aber kein BB + RSI** — die liegen inline in `backtest_service.dart`. P4C-1 extrahiert sie.
- **`lib/services/backtest_service.dart`**:
  - Z. 66: Doc-Comment verweist auf `calc_bollinger_bands_ema` in Rust
  - Z. 642: zweite BB-Berechnung-Stelle
  - Inline `bbCenter/bbUpper/bbLower/rsi[i]` Berechnungen in den BB+RSI- / UT-Bot- / Ichimoku-Backtest-Pfaden — finden und extrahieren
- **`lib/core/constants/app_constants.dart`**: `supportedSymbols`, `supportedTimeframes` (verifizieren dass die TF-Liste mit `BinanceKlineStream` matched)
- **`lib/core/logging/app_log.dart`**: für WS-Disconnect-Warnings

### Neue Dependencies

```yaml
dependencies:
  candlesticks: ^2.1.0  # bereits in pubspec.yaml (B-Stream-Vorbereitung)
```

Keine neuen Deps nötig. `candlesticks` ist seit Projekt-Start drin.

### candlesticks Package — Pre-Verify

`candlesticks: ^2.1.0` ist alte Version (newest available laut B4-1 pubspec-Hinweis ist 3.0.1, aber wir haben locked 2.1.0). Vor P4C-3 verifizieren:
- API `Candlesticks(candles: List<Candle>, ...)` — Candle ist `class Candle { DateTime date; double open, high, low, close, volume; }`
- BB-Overlay-Support: hat `candlesticks` 2.1 das nativ, oder muss Custom Painter drüberlegen?
- Wenn Custom-Painter nötig: Plan-B-Hinweis im Brief, parallel-CC entscheidet

**Wenn 2.1.0 BB-Overlay nicht supportet:** Auf 3.0.1 upgrade oder zu `fl_chart` (auch in pubspec) ausweichen. Beide Optionen sind OK, parallel-CC darf entscheiden — Endbericht-Hinweis.

### Engine-Refactor-Risiko

`phase1_reference_backtest` ist 11/11 grün und 91 Trades bit-exakt Dart↔Rust 1e-9. Wenn die BB+RSI-Extraktion auch nur **ein einziges Bit** drift, bricht der Test. Mitigation:
- P4C-1 extrahiert **nur**, ohne irgendeine Berechnung zu ändern
- Engine-Code ruft `indicators.bbBands(...)` statt inline — Rest unverändert
- Tests in `indicators_test.dart` (neu) mit known-good-Werten aus dem Phase-1-Reference-Backtest-Run
- Wenn `phase1_reference_backtest` nach P4C-1 nicht grün ist → STOPP, Diff suchen

---

## 3. Commit-Plan (5 atomare Commits)

### COMMIT P4C-1: Extract BB + RSI helpers to indicators.dart

**Files:**
- `lib/services/indicators.dart`:
  - Neue Funktion `List<double>? calcBollingerBandsSMA(List<double> closes, int period, double stdDev)` → returns concatenated [upper, middle, lower] OR three separate Funktionen (`bbUpper`, `bbMiddle`, `bbLower`). **Empfehlung:** ein Wrapper-Typ `class BollingerBands { final List<double> upper, middle, lower; }` + Funktion `calcBollingerBands(...)`.
  - Neue Funktion `calcBollingerBandsEMA(...)` analog für `BbMaType.ema` (siehe `backtest_service.dart` Z. 66)
  - Neue Funktion `List<double>? calcRsi(List<double> closes, int period)` mit Wilder-Smoothing (mirror der Rust-Implementation in `bb_rsi.rs`)
  - **CRITICAL:** Die extrahierten Funktionen müssen byte-für-byte dieselben Werte liefern wie der bisherige inline-Code. Implementierung 1:1 kopieren, KEINE „Optimierung" / Refactor / Typkorrektur.
- `lib/services/backtest_service.dart`:
  - Inline-BB-Berechnung an Z. 66, 642 (und sonstigen Stellen mit `bbUpper = bbCenter + std * stdDev`) durch Aufruf von `indicators.calcBollingerBands(...)` ersetzen
  - Inline-RSI-Berechnung durch Aufruf von `indicators.calcRsi(...)` ersetzen

**Tests:**
- `test/services/indicators_bb_rsi_test.dart` (neu):
  - **Test: BB-SMA mit bekanntem Input** (z.B. 25 sequentielle Close-Werte 100.0..124.0, period=20, stdDev=2.0 → erwartete Werte hardcoded)
  - **Test: BB-SMA bei zu wenig Candles** (period > len) → returns null
  - **Test: BB-EMA mit bekanntem Input** (analog)
  - **Test: RSI mit bekanntem Input** (10 sequentielle Werte, period=5, Wilder-Smooth)
  - **Test: RSI bei zu wenig Candles** → returns null
  - **Test: Roundtrip — vor P4C-1 extrahierten Engine-Werte (z.B. RSI auf Phase-1-Reference-Candles bar 100) müssen exakt mit indicators.calcRsi reproduzierbar sein**

**Gates (zusätzlich zum Standard):**
- `phase1_reference_backtest` **muss bit-exakt grün bleiben** — wenn der Refactor irgendwo eine Berechnung leicht ändert, bricht 91-Trades-Match. Vor dem Commit: Test isoliert laufen lassen.

**Pattern-Referenz:** `lib/services/indicators.dart` Funktion `calcAtr` (Z. 61) als Stil-Vorlage für Bands-Compute-Funktionen.

**Eskalations-Pfad:** Wenn `phase1_reference_backtest` nach P4C-1 fehlschlägt:
1. `git diff` zur Backtest-Service-Mod prüfen
2. Erstmal `inline-BB` und `indicators.calcBollingerBands` per Unit-Test gegen den gleichen Input vergleichen
3. Wenn Drift detected: STOPP, Diagnose-Brief mit dem genauen Diff

**Commit msg:**
```
refactor(phase-P4C-1): extract BB + RSI helpers into indicators.dart

Pulls the Bollinger Bands (SMA + EMA basis) and RSI (Wilder smoothing)
computations out of the inline backtest_service paths into reusable
pure functions in indicators.dart. Engine call sites now delegate
through the helpers; no algorithmic change. phase1_reference_backtest
remains bit-exact Dart↔Rust 1e-9. The chart layer (P4C-2..5) will
reuse the same helpers so a chart-rendered indicator can never drift
from the engine-computed signal.
```

---

### COMMIT P4C-2: ChartProvider + Binance live data

**Files:**
- `lib/features/chart/chart_provider.dart` (neu):
  - `ChangeNotifier`
  - State:
    - `String symbol` (default `'BTCUSDT'`)
    - `String timeframe` (default `'1h'`)
    - `List<CandleData> candles` (Ring-Buffer, capped 500)
    - `BollingerBands? bb`
    - `List<double>? rsi`
    - `int bbPeriod` (default 20), `double bbStdDev` (default 2.0), `int rsiPeriod` (default 14)
    - `ChartStatus { idle, loading, live, reconnecting, error }`
    - `String? errorMessage`
  - Methoden:
    - `Future<void> load({String? symbol, String? timeframe})` — initial REST load via `BinanceApiClient` + start WS-Stream
    - `void setSymbol(String s)` / `void setTimeframe(String tf)` — restart-Stream wenn unterschiedlich
    - `void setIndicatorParams({int? bbPeriod, double? bbStdDev, int? rsiPeriod})` — recompute, kein Stream-restart
    - `void dispose()` — WS-Subs canceln (Memory-Hint aus B4-1)
  - Indicator-Recompute bei jedem Tick: `bb = indicators.calcBollingerBands(closes, bbPeriod, bbStdDev)`, `rsi = indicators.calcRsi(closes, rsiPeriod)`
  - Catches in async-Pfaden → `AppLog.error` + `errorMessage`
- `lib/main.dart`: `ChangeNotifierProvider(create: (_) => ChartProvider())` im MultiProvider

**Tests:**
- `test/features/chart/chart_provider_test.dart` (neu):
  - `load()` ruft REST + startet WS, status transitioniert
  - WS-Tick appends Candle, recomputes BB+RSI
  - `setSymbol(neu)` cancelt alte Sub + neuer load
  - `setIndicatorParams` recomputes ohne Stream-restart
  - dispose cancelt WS-Subscription
  - WS-disconnect → status=reconnecting, AppLog.warn
  - REST-Failure beim Load → status=error, errorMessage gesetzt
  - **Test: WS-Tick mit closed=false wird gefiltert** (closedOnly per default in BinanceKlineStream)

**Pattern-Referenz:** `lib/features/paper/paper_trading_provider.dart` für Stream-Subscription-Lifecycle, `lib/features/studies/studies_provider.dart` für load-then-listen-Pattern.

**Commit msg:**
```
feat(phase-P4C-2): ChartProvider with live Binance kline stream

State container for the chart tab: holds the 500-candle ring buffer,
the active symbol/timeframe, and the indicator parameters
(bbPeriod / bbStdDev / rsiPeriod). load() does a REST backfill then
attaches the BinanceKlineStream from B4-1; setSymbol/setTimeframe
restart the stream; setIndicatorParams just recomputes locally.
Indicator computations route through the P4C-1 helpers in
indicators.dart so the chart and the engine agree byte-for-byte.
```

---

### COMMIT P4C-3: ChartScreen rewrite — Candlestick + BB-Overlay

**Files:**
- `lib/ui/screens/chart_screen.dart`:
  - **`ComingSoonBanner` entfernen** (Import + Widget)
  - Stateless oder Provider-watching State
  - Layout:
    - Top: Symbol-Dropdown + Timeframe-Chips (wie heute, aber wired zu `ChartProvider`)
    - Mid (flex: 3): `Candlesticks(candles: provider.candles.map(toLibCandle).toList(), ...)` + **BB-Overlay**
    - Bottom (flex: 1): RSI-Placeholder bleibt vorerst (kommt in P4C-4)
  - BB-Overlay via:
    - **Plan A:** `candlesticks` 2.1.0 natives Indicator-Overlay (falls Package das supportet)
    - **Plan B:** `CustomPaint` über dem Candlestick-Bereich, rendert die drei BB-Linien per Path → vor dem Commit klar testen, was funktioniert
  - Connection-Status-Pille oben rechts (live / reconnecting / error)
- `lib/ui/widgets/coming_soon_banner.dart`: **nicht löschen** — wird ggf. noch von Strategies/Paper genutzt? Vor dem Commit suchen ob noch Verwendungen außerhalb chart_screen — falls nicht, Datei mit löschen

**Tests:**
- `test/ui/screens/chart_screen_test.dart` (neu, oder erweitern wenn schon vorhanden):
  - Renders ohne ComingSoonBanner
  - Symbol-Dropdown-Change ruft `provider.setSymbol`
  - Timeframe-Chip-Tap ruft `provider.setTimeframe`
  - Connection-Status-Pille reflektiert provider.status

**Pattern-Referenz:** `lib/ui/widgets/equity_curve_chart.dart` (falls fl_chart-Beispiel im Repo), sonst `candlesticks` Package-Doc.

**⚠️ Eskalations-Pfad:** Wenn `candlesticks` 2.1.0 weder native BB-Overlay noch ein sauberes Custom-Painter-Hook anbietet:
- Plan B: Upgrade auf `candlesticks` 3.0.1 (newer API, vielleicht inline-overlays)
- Plan C: Komplett auf `fl_chart` Candlestick-Series umsteigen
- Beide sind OK — parallel-CC entscheidet und meldet die Wahl im Endbericht

**Commit msg:**
```
feat(phase-P4C-3): chart screen rewrite — live candlesticks + BB overlay

Replaces the coming-soon placeholder with a real candlestick chart
driven by ChartProvider. The Bollinger Bands upper/middle/lower lines
overlay the candles directly so a chart-rendered band matches the
engine-rendered band (same indicators.dart helper). Symbol dropdown
and timeframe chips are now wired to provider state. The RSI pane
stays a placeholder for one more commit (P4C-4).
```

---

### COMMIT P4C-4: RSI Sub-Chart + Indicator Param Controls

**Files:**
- `lib/ui/widgets/rsi_indicator_pane.dart` (neu): `fl_chart` LineChart mit:
  - X-Axis: synced mit oberer Candlestick-Range (zoom/pan optional)
  - Y-Axis: 0-100
  - 30 / 70 als horizontale gestrichelte Linien (oversold/overbought)
  - RSI-Line in `AppColors.accentCyan`
- `lib/ui/screens/chart_screen.dart`:
  - RSI-Placeholder durch `RsiIndicatorPane(values: provider.rsi)` ersetzen
  - Optional: kleines Settings-Sheet-Button (BB-Period, Stddev, RSI-Period) → ruft `provider.setIndicatorParams`

**Tests:**
- `test/ui/widgets/rsi_indicator_pane_test.dart` (neu):
  - Rendert mit `rsi` Liste
  - 30/70-Lines visible
  - Empty rsi → leerer Chart (kein crash)

**Pattern-Referenz:** falls `equity_curve_chart.dart` im Repo existiert (B4-3 hat sie für PaperTrading gebaut) — als fl_chart-LineChart-Vorlage nutzen.

**Commit msg:**
```
feat(phase-P4C-4): RSI sub-chart + optional indicator param sheet

Replaces the RSI placeholder with a real fl_chart LineChart driven
by ChartProvider.rsi, with 30 and 70 dashed thresholds. An optional
settings sheet lets the user tune bbPeriod/bbStdDev/rsiPeriod
without restarting the stream — recomputation is local-only via
setIndicatorParams.
```

---

### COMMIT P4C-5: End-to-End Smoke + ComingSoonBanner-Cleanup

**Files:**
- `test/integration/chart_screen_smoke_test.dart` (neu):
  - Mock `BinanceKlineStream` + Mock `BinanceApiClient`
  - Sequence:
    1. Pump `ChartScreen` with `ChartProvider`-Mock
    2. Trigger `load()` mit Mock-REST-Response (z.B. 100 Candles)
    3. expect: Candlestick visible, BB-Overlay visible (Plan-A oder Plan-B)
    4. Emit 5 weitere closed-Candles über Mock-WS
    5. expect: Buffer wuchs, BB+RSI recomputed
    6. Switch symbol via Dropdown → expect provider.setSymbol called + neuer load
    7. Dispose → expect WS-Subs cancelled
- `lib/ui/widgets/coming_soon_banner.dart`: falls keine anderen Verwendungen (Grep nach `ComingSoonBanner`), Datei löschen + Test-Files ggf. anpassen

**Commit msg:**
```
test(phase-P4C-5): end-to-end chart smoke + coming-soon cleanup

Drives the full chart stack with mocks: initial REST backfill,
WS-stream attach, indicator recompute on each tick, symbol switch,
clean dispose. The coming-soon banner widget is removed entirely
since the chart tab was the last consumer.
```

---

## 4. Gates pro Commit

| Gate | Erwartung |
|---|---|
| `flutter analyze` | 0 issues |
| `cargo clippy --all-targets -- -D warnings` | 0 warnings (kein Rust-Touch) |
| `cargo test --release` | alle grün (kein Rust-Touch) |
| `flutter test` (gesamt) | **B4.4-Baseline 568 + neue P4C-Tests grün** |
| `phase1_reference_backtest_test` | **8/8 (oder 11/11) grün, bit-exakt Dart↔Rust 1e-9** (KRITISCH — der P4C-1-Refactor darf NICHTS daran ändern) |
| `f06_model_unification_test` | grün |
| `dart_rust_*_parity_test` | grün |
| `bitunix_live_disabled_test` | grün (8 Pinned-Tests unverändert) |
| B1..B4.4 Bestand | grün |
| Push direkt nach grünem Commit | ✓ |

---

## 5. Eskalations-Stopp

- `phase1_reference_backtest` bricht: **KRITISCH, sofort STOPP** — vor allem bei P4C-1 (Engine-Refactor). Die Extraktion muss byte-für-byte identisch sein.
- `f06_model_unification_test` bricht: ClosedTrade- oder BacktestResult-Schema-Drift — sollte hier nicht passieren, aber Check
- `dart_rust_*_parity_test` bricht: Engine-Refactor hat Berechnungen verändert → P4C-1 rollback und retry
- `candlesticks` 2.1.0 unterstützt kein BB-Overlay UND kein Custom-Painter-Hook: Eskalation auf 3.0.1 oder fl_chart Candlestick (siehe P4C-3 Eskalations-Pfad)
- WS-Connect crashed auf Linux/macOS/Windows: `binance_websocket.dart` aus B4-1 sollte das abdecken — wenn nicht: Diagnose
- Indicator-Recompute pro Tick blockt UI-Thread: bei 500-Candle-Buffer + BB + RSI = ~500ms? Profilen → falls > 50ms in `compute()`-Isolate verschieben (Pattern aus B4-2)
- ChartProvider leakt StreamSubscriptions bei rapidem Symbol-Switch: dispose-Hygiene strikt enforcen (Pattern aus PaperTradingProvider)

---

## 6. Endbericht (nach P4C-5)

Brief an QA mit:
1. **5 Commit-Hashes** in Tabelle
2. **Test-Status-Tabelle** (alle Gates, neue Tests gegenüber B4.4-Baseline 568)
3. **Manueller Smoke-Test-Aufgabe an Maik:**
   - Chart-Tab öffnen → kein ComingSoonBanner mehr ✓
   - Default-Anzeige: BTCUSDT 1h Candlestick mit BB-Overlay + RSI darunter ✓
   - Symbol-Dropdown wechseln → Chart re-loaded ✓
   - Timeframe-Chip → Chart re-loaded ✓
   - 1-2 Minuten warten auf 1m-Timeframe → mind. 1 live-Tick, Candle wächst rein ✓
   - WLAN aus → Connection-Pille → reconnecting → WLAN an → wieder live ✓
   - Optional: Settings-Sheet → BB-Period auf 50 → BB-Linien werden weiter, RSI bleibt gleich ✓
4. **Push-Status** (alle 5 Commits auf origin/main?)
5. **Anomalien:**
   - Welche candlesticks-Variante gewählt (Plan A / B / C)?
   - phase1_reference_backtest nach P4C-1 wirklich bit-exakt?
   - Indicator-Recompute-Performance auf 500-Candle-Buffer?
6. **Empfehlung nächste Welle:**
   - P4P Step-2 (Bitunix-Order-Routing) — empfohlen NUR wenn Maik B4.4-Smoke + dieser P4-Chart-Smoke grün
   - A1.1/A1.2 ADX-Sub-Sweep — sicher, parallel zu P4P-Wellen
   - P4-Chart Step-2 (Drawing-Tools / Sync from Backtest / Live-Position-Markers)

---

## 7. Aufwand & Risiko

- **Geschätzt:** 5 Commits, ~5-7h Engineering
- **Hauptrisiko:** P4C-1 Engine-Refactor — wenn BB/RSI-Extraktion nicht byte-exakt, bricht `phase1_reference_backtest`. Mitigation: 1:1-Kopie, Unit-Tests gegen Engine-Werte vor und nach dem Commit.
- **Sekundärrisiko:** `candlesticks` 2.1.0 Limitationen — Plan-B (fl_chart) als Eskalationspfad dokumentiert.
- **Tertiärrisiko:** Indicator-Recompute-Performance — `compute()`-Isolate als Fallback (B4-2-Pattern).

---

## 8. Sign-off

QA-Koordinator wartet auf Maik-Sign-off bevor dieser Brief an parallel-CC weitergereicht wird.
