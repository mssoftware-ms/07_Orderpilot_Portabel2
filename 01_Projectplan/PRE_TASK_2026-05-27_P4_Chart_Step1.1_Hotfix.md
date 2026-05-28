# Pre-Task Welle P4-Chart Step-1.1 — Hotfix (Findings aus Maik-Smoke)

**Issued:** 2026-05-27 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem
**Base:** `7509aa2` (origin/main, inkl. P4-Chart Step-1)

---

## ⚠️ Pre-Task-Disclaimer

Hotfix-Welle für **drei konkrete Findings aus Maik-Smoke** auf P4-Chart Step-1. Zwei echte Bugs (3h-Timeframe broken, Live-Tick fehlt, Reconnect greift nicht) plus ein UX-Gap (keine x/y-Achsen-Beschriftung). Ohne diese Welle ist der Chart-Tab funktional halb-broken auf main.

Code-Skizzen weiterhin unverifizierte Hypothesen. Vor Bug-Fix immer reproduce → diagnose → fix → regression-test.

---

## 1. Scope

Drei Findings aus dem Smoke:

### Finding #1: 3h-Timeframe broken
- `app_constants.dart` Z. 22 listet `'3h'` — aber **Binance Spot supportet kein 3h**
- Binance unterstützt: `1m, 3m, 5m, 15m, 30m, 1h, 2h, 4h, 6h, 8h, 12h, 1d, 3d, 1w, 1M`
- Folge: WS-Connect mit `interval=3h` schlägt fehl, der Chart bleibt leer/idle
- Bestand `1m, 5m, 15m, 1h, 2h, 4h, 1d` funktioniert (von Maik bestätigt)

### Finding #2: Live-Tick fehlt auf 1m, kein Reconnect
- Maik wartet 1-2 min auf 1m-Timeframe → kein neuer Candle, BB/RSI nicht aktualisiert
- WLAN aus für 1min → kein „reconnecting"-Status, kein wieder „live"
- Symbol-Lowercasing in `binance_websocket.dart:208` ist OK (`_symbol = symbol.toLowerCase()`)
- Reconnect-Mechanismus existiert (`_reconnectTimer`, `_reconnectAttempts`) aber greift nicht bei real-Windows-WLAN-Drop
- **Ursache unklar** — der parallel-CC muss reproduce → root-cause-analysis

### Finding #3 (UX): Keine x/y-Achsen-Beschriftung
- Plan-C (CustomPaint in `lib/ui/widgets/candlestick_chart_pane.dart`) hat keine Achsen
- User sieht keinen Preis (y-Skala) und keinen Zeitraum (x-Skala) — UX-Standard-Erwartung enttäuscht
- War im P4-Chart Pre-Task nicht explizit gefordert — mein Versäumnis

**Out-of-Scope (P4-Chart Step-2 / Phase-5):**
- Zoom / Pan / Crosshair / Touch-Gestures (war schon im Step-1-Pre-Task als Phase-5 markiert)
- Volume-Pane
- Drawing-Tools (Trendlines, Fibonacci)
- Sync from Backtest (Symbol/TF aus BacktestProvider)
- Live-Position-Markers vom Paper-Trading

---

## 2. Kontext

### Vorhandener Code (relevant)

- **`lib/core/constants/app_constants.dart`** Z. 21-23: `supportedTimeframes`-Liste enthält `'3h'`
- **`lib/features/chart/chart_provider.dart`**: ChartProvider mit WS + REST + Indicator-Recompute. **`_onKline`** Z. 285 schreibt updates in den Buffer, **`_onWsStatusChange`** Z. 299 mappt WS-Status zu Provider-Status. Beide Pfade sind kandidat für Live-Tick-Bug.
- **`lib/services/binance_websocket.dart`**: `BinanceKlineStream` mit `connect(symbol, interval, closedOnly: true)`, Reconnect via `_reconnectTimer`. **`_reconnectAttempts`** zählt mit, `maxReconnectAttempts` ist `null` (kein hardcap) per default.
- **`lib/ui/widgets/candlestick_chart_pane.dart`**: CustomPaint mit Candle + BB-Linien-Rendering. **Hat noch keine Achsen-Beschriftung**.
- **`lib/ui/widgets/rsi_indicator_pane.dart`**: fl_chart LineChart — hat möglicherweise schon Achsen via fl_chart default.

### Binance Spot Klines — supported Intervals

Per Binance API-Doc (Stand 2026): `1s, 1m, 3m, 5m, 15m, 30m, 1h, 2h, 4h, 6h, 8h, 12h, 1d, 3d, 1w, 1M`.

**Vor B4.4-Smoke**: 1s ist Binance-only neuere Variante, könnte UI-Polling-Overhead haben — bewusst weglassen. 1M (Monthly) ist Trader-Overkill, weglassen.

**Vorschlag für `supportedTimeframes`:**
```dart
static const List<String> supportedTimeframes = [
  '1m', '5m', '15m', '30m', '1h', '2h', '4h', '1d',
];
```
**Diff zu jetzt:** `3h` raus, `30m` rein. Liste bleibt 8 Einträge — keine UI-Layout-Änderung in den Chip-Reihen nötig.

### Live-Tick-Bug — Diagnose-Hypothesen

Ungeordnet, der parallel-CC priorisiert beim reproduce:

**Hypothese A:** `_onKline` wird gerufen aber `notifyListeners` triggert kein Rebuild
- Test: einfach `print('TICK')` in `_onKline` einbauen, dev-build, 1m laufen lassen, sehen ob Print erscheint
- Wenn ja: Provider funktioniert, UI-Subscription ist das Problem
- Wenn nein: WS-Listener greift nicht

**Hypothese B:** `BinanceKlineStream.connect(closedOnly: true)` filtert zu strikt
- Binance emittiert pro candle alle 1-2s ein `kline` event, das mit `k.x = true` markiert ist erst wenn die candle GESCHLOSSEN ist
- ChartProvider nutzt `closedOnly: true` per default in `_attachStream` (Z. 258-261) — kein expliziter Parameter, vermutlich default true
- Test: parallel-CC öffnet temporär `closedOnly: false` → sieht ob ANY tick durchkommt

**Hypothese C:** ConnectionStatus bleibt auf `connecting`, wechselt nicht auf `running`
- `_onWsStatusChange` Z. 309: `case running` → `_setStatus(live)`
- Wenn der WS nie `running` emittiert (z.B. weil die WebSocket selbst broken auf Windows), bleibt der Provider auf `loading` und Updates kommen nicht durch
- Test: AppLog.warn in jedem `_onWsStatusChange`-case einbauen, beobachten was emittiert wird

**Hypothese D:** Race zwischen `_loadGeneration` checks und WS-Attach
- `load()` ruft `_attachStream()`. Wenn der Stream sehr schnell ein `running`-Event emittiert (synchron), kommt das in `_onWsStatusChange` **vor** dem `_setStatus(live)` am Ende von `load()`. Beide setzen `live`, das ist OK.
- Aber wenn der Stream zwischen `_attachStream()` und `_setStatus(live)` einen ersten kline-Event emittiert, läuft `_onKline` mit `_status == loading` und macht den Status-Switch korrekt: `if (_status != ChartStatus.live) _setStatus(ChartStatus.live);` (Z. 292)
- Sollte funktionieren — Hypothese D ist unwahrscheinlich

### Reconnect-Bug — Diagnose-Hypothesen

**Hypothese E:** Windows-WebSocket-Library detected WLAN-Drop nicht
- `web_socket_channel` auf Windows-Desktop nutzt `dart:io WebSocket` mit OS-TCP-Stack
- WLAN-aus für 1min kann zu „connection halb-offen" führen — TCP weiß noch nicht dass es weg ist
- Default TCP-Timeout auf Windows ist ~7min (TCP Keepalive)
- Mitigation: Ping/Pong-Heartbeat auf Application-Layer einbauen (Binance schickt vermutlich kein Ping; wir müssen senden)

**Hypothese F:** Reconnect-Logic in `BinanceKlineStream` greift nur bei expliziten Connection-Errors, nicht bei Stille
- Wenn der WS einfach 60s lang nichts emittiert (weil WLAN aus), passt die Code-Logik vermutlich nicht
- Mitigation: Stale-Detection — wenn > 2x das erwartete Tick-Intervall ohne Update, manuell disconnect + reconnect

---

## 3. Commit-Plan (3 atomare Commits)

### COMMIT P4C-H-1: Fix 3h timeframe + sync Binance interval whitelist

**Files:**
- `lib/core/constants/app_constants.dart` Z. 21-23:
  - `'3h'` → `'30m'` (oder `3h` ersetzen und `30m` an die richtige Position einsortieren)
  - Neue Liste: `['1m', '5m', '15m', '30m', '1h', '2h', '4h', '1d']`
- `lib/services/binance_websocket.dart` (falls dort eine Whitelist gibt): mit der konstantierten Binance-Liste synchronisieren
- `lib/features/paper/paper_trading_provider.dart` (falls die TF-Validation darauf verweist, B4-4 hat das addiert): konsistent halten

**Tests:**
- `test/core/constants/app_constants_test.dart` (neu falls nicht existiert):
  - Test: `supportedTimeframes` enthält kein `'3h'`
  - Test: Alle Werte in `supportedTimeframes` sind in der Binance-Spot-Klines-Whitelist
  - Test: `'30m'` ist enthalten (zur Doku der neuen Liste)
- `test/features/chart/chart_provider_timeframe_test.dart` (neu):
  - Test: `setTimeframe('30m')` succeeds (mock-WS returns success on `btcusdt@kline_30m`)
  - Test: `setTimeframe('3h')` → wirft / oder erzeugt einen `AppLog.error` (defensive)

**Commit msg:**
```
fix(phase-P4C-H-1): drop unsupported 3h timeframe, sync Binance whitelist

Maik's smoke-test surfaced that selecting the 3h timeframe leaves the
chart frozen — Binance Spot's kline endpoint has no 3h interval, so
the WS connect call silently fails. Removes '3h' from
AppConstants.supportedTimeframes and adds '30m' in its place,
matching the Binance-supported set used elsewhere in the app
(paper_trading interval whitelist). A static test pins the list
against the documented Binance interval set so future additions
can't repeat the mistake.
```

---

### COMMIT P4C-H-2: Fix live-tick + reconnect resilience

**Files:**
- `lib/features/chart/chart_provider.dart`:
  - **VOR dem Fix:** Diagnose-Logs in `_onKline`, `_onWsStatusChange`, `_onStreamError` einbauen (temporär, AppLog.warn) und gegen real Binance laufen lassen — herausfinden welche Hypothese aus Sektion 2 zutrifft
  - **Fix** abhängig von Hypothese:
    - Hypothese A/C: UI-Subscription-Pfad — vermutlich kein Code-Fix nötig, sondern `notifyListeners` an einer Stelle nachziehen
    - Hypothese B: `closedOnly: false` für **die ersten Sekunden** nach connect → kontroverse, fragwürdig; besser bleibt closedOnly true und der Test rechnet damit dass 1m candles 60s brauchen
    - Hypothese E/F: Stale-Detection einbauen — Timer im ChartProvider, der bei > 2× Tick-Intervall ohne Update das WS-Stream resettet
  - **Stale-Detection (empfohlen):**
    ```dart
    Timer? _staleWatchdog;
    DateTime? _lastTickAt;

    void _onKline(KlineUpdate update) {
      _lastTickAt = DateTime.now();
      // ... rest
    }

    void _startStaleWatchdog() {
      _staleWatchdog?.cancel();
      final intervalMs = _timeframeToMs(_timeframe);
      _staleWatchdog = Timer.periodic(
        Duration(milliseconds: intervalMs * 2),
        (_) {
          if (_lastTickAt == null) return;
          final elapsed = DateTime.now().difference(_lastTickAt!).inMilliseconds;
          if (elapsed > intervalMs * 2.5) {
            AppLog.warn(_tag, 'Stale stream detected (no tick for ${elapsed}ms), reconnecting');
            _restartStream();
          }
        },
      );
    }
    ```
    - `_timeframeToMs('1m')` = 60_000, `'5m'` = 300_000, etc.
    - Timer cancellt in `dispose` + bei `_detachStream`
- `lib/services/binance_websocket.dart`:
  - Optional: WebSocket ping-keepalive auf Application-Layer (alle 30s ein ping-frame). Binance unterstützt das per `pong`-frame-Response. Verifiziert dass die TCP-Connection lebt.
  - **Wenn das Stale-Detection-Pattern im ChartProvider funktioniert, ist Keepalive Step-2 — entscheidet der parallel-CC**

**Tests:**
- `test/features/chart/chart_provider_test.dart` erweitern:
  - **Test: Stale-watchdog reconnects after 2.5x interval without tick**
    - Setup: Mock-WS, advance time mit `FakeAsync` (oder Test-Clock), keine Ticks
    - Expect: Provider ruft `_restartStream` (verify via reconnect-count)
  - **Test: Watchdog wird gecancelt bei dispose** (kein Timer leak)
  - **Test: WS-disconnect-event triggert status=reconnecting + AppLog.warn**
- `test/services/binance_websocket_test.dart` erweitern:
  - falls ping-keepalive eingebaut: Test mit Mock-WS, verify ping-frame nach 30s

**⚠️ Live-Test (manuell durch parallel-CC):**
- Vor Push: gegen echten Binance-WS testen, 5 Min auf 1m-Timeframe laufen lassen, beobachten:
  - Ein Tick alle ~60s? ✓
  - WLAN aus → nach 2 min ein „stale detected" log? Reconnect? ✓
  - WLAN wieder an → Stream resumed? ✓

**Commit msg:**
```
fix(phase-P4C-H-2): stale-stream watchdog + visible reconnect status

Maik's smoke-test surfaced two related defects: 1m candles never
ticked into the live chart, and pulling the wifi for a minute
neither tripped the reconnecting status pill nor recovered when
the wifi came back. Adds a per-timeframe stale-stream watchdog
that detaches + reattaches the WS once we miss 2.5x the expected
tick interval. The reconnect path now logs via AppLog.warn so an
incident can be diagnosed after the fact, and the status pill
reflects the transitions correctly.
```

---

### COMMIT P4C-H-3: Add price + time axis labels to candlestick chart

**Files:**
- `lib/ui/widgets/candlestick_chart_pane.dart`:
  - Im CustomPaint-`paint()`-Method:
    - **Y-Axis (rechts):** 5-7 horizontal verteilte Preis-Labels in `AppColors.textMuted`, Format `${price.toStringAsFixed(decimals)}` mit `decimals` dynamic (kleinere Werte mehr Dezimalstellen)
    - **X-Axis (unten):** 4-6 verteilte Zeit-Labels, Format abhängig vom Timeframe:
      - `1m/5m/15m/30m` → `HH:mm`
      - `1h/2h/4h` → `MM-dd HH:00`
      - `1d` → `yyyy-MM-dd`
    - Labels in einem 20-30px hohen Rand unten/rechts gezeichnet, Chart-Render-Area entsprechend kleiner
  - Optional: Hover/Tap-Crosshair als Step-2 markieren (NICHT in dieser Welle)

**Tests:**
- `test/ui/widgets/candlestick_chart_pane_test.dart`:
  - Render mit 100 candles, screenshot-vergleich (golden-test) ODER pixel-counts unten/rechts > 0
  - Verschiedene Timeframes → unterschiedliche X-Label-Formate (string-content-check)
  - Empty candles → kein crash

**Commit msg:**
```
feat(phase-P4C-H-3): price + time axis labels on candlestick chart

The Plan-C CustomPaint renderer had no axis annotations, so users
couldn't read prices or timestamps off the chart — a basic UX
expectation missed in the Step-1 brief. Adds a right-hand price
ladder with 5-7 evenly-spaced labels (precision adapts to the
visible range) and a bottom time axis with 4-6 labels whose format
adapts to the timeframe (HH:mm for intraday, MM-dd HH:00 for hourly,
yyyy-MM-dd for daily). Zoom/pan/crosshair remain Phase-5 scope.
```

---

## 4. Gates pro Commit

| Gate | Erwartung |
|---|---|
| `flutter analyze` | 0 issues |
| `cargo clippy --all-targets -- -D warnings` | 0 warnings (kein Rust-Touch) |
| `cargo test --release` | alle grün (kein Rust-Touch) |
| `flutter test` (gesamt) | **P4C-Baseline 608 + neue Hotfix-Tests grün** |
| `phase1_reference_backtest_test` | grün (KRITISCH) |
| `f06_model_unification_test`, `dart_rust_*_parity_test` | grün |
| `bitunix_live_disabled_test` 8 Pinned | grün (unverändert) |
| B1..P4C-Bestand-Tests | grün |
| Push direkt nach grünem Commit | ✓ |

---

## 5. Eskalations-Stopp

- `phase1_reference_backtest` bricht: KRITISCH, STOPP
- Live-Tick-Bug lässt sich nicht reproduzieren (z.B. weil Binance bei Maiks Test-Zeit kurz down war): parallel-CC dokumentiert das im Endbericht und baut Stale-Detection trotzdem ein (defensive)
- Reconnect-Fix verursacht Reconnect-Storm bei sehr instabilem WLAN: Cooldown 30s zwischen Reconnect-Versuchen (Pattern aus B4.2-4 `kBackfillCooldownMs`)
- Achsen-Labels überlappen bei kleinem Viewport: dynamic font-size oder weniger Labels
- Stale-Watchdog feuert false-positive bei langer Marktphase ohne Trades (gibt es bei 1m BTCUSDT nicht, aber bei exotischen Symbolen): Schwelle auf 5× statt 2.5× erhöhen wenn das Symptom kommt

---

## 6. Endbericht (nach P4C-H-3)

Brief an QA mit:
1. **3 Commit-Hashes** in Tabelle
2. **Test-Status-Tabelle** (alle Gates, neue Tests gegenüber P4C-Baseline 608)
3. **Diagnose-Log für Bug #2** (Live-Tick): welche Hypothese (A-F) zutraf, was wurde gefixt
4. **Manueller Smoke-Test-Re-Run-Aufgabe an Maik** (alle 4 Smoke-Punkte aus dem Step-1-Endbericht, jetzt grüne Haken erwartet)
5. **Push-Status**
6. **Anomalien** (z.B. Reconnect-Verhalten auf Windows-WLAN-Drop, Achsen-Label-Edge-Cases)
7. **Empfehlung nächste Welle:**
   - P4P Step-2 (Bitunix Real-Order-Routing) — wenn Step-1 + Step-1.1-Smoke alle grün
   - A1.1/A1.2 ADX-Sub-Sweep — sicher, parallel
   - P4-Chart Step-2 (Zoom/Pan/Crosshair, Sync from Backtest)

---

## 7. Aufwand & Risiko

- **Geschätzt:** 3 Commits, ~3-5h Engineering
- **Hauptrisiko:** Live-Tick-Bug-Reproduce — wenn die Ursache nicht in 1h gefunden ist, Stale-Detection als defensive Maßnahme einbauen und im Endbericht die nicht-reproducete Hypothese als Tech-Debt vermerken
- **Sekundärrisiko:** Achsen-Labels visuell zu busy oder zu sparse — bei realer App nochmal nachjustieren (Maik sieht das im Smoke)

---

## 8. Sign-off

QA-Koordinator wartet auf Maik-Sign-off bevor dieser Brief an parallel-CC weitergereicht wird.
