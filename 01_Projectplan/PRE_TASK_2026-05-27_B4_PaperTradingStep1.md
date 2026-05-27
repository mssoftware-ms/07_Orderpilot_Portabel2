# Pre-Task Welle B4 — Paper-Trading Step-1 (Live-Signal-Observer + Virtual-Fills)

**Issued:** 2026-05-27 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem grünen Commit
**Base:** `7c36779` (origin/main, inkl. O3-B1 + Logging + O3-B2 + O3-B3)

---

## 1. Scope

Paper-Trading-Modul **Step-1**: ersetzt das `ComingSoonBanner` durch ein funktionsfähiges Live-Observer-System. User sieht, was die aktive Strategie in **Real-Time** auf einem Binance-Spot-Symbol macht — inkl. **virtueller Fills** (kein Exchange-Connector, kein echtes Geld). Schließt den Loop:

```
CLI-Optimizer → Studies-Viewer → Strategy-Management (Apply Trial)
              → Backtest (Historisch validieren)
              → Paper-Trading (LIVE virtuell ausführen)   ← B4 fügt das hinzu
```

**In Scope:**
- Binance Spot WebSocket Kline-Stream (`wss://stream.binance.com:9443/ws`)
- `PaperTradingProvider` (State + Engine-Tick + virtuelle Fills + Equity-Curve)
- `PaperTradingScreen` redesign (ersetzt ComingSoonBanner komplett)
- „Sync from Backtest"-Button: kopiert `BacktestProvider.config` → Paper-Session-Config
- Start/Stop-Controls, Connection-Status
- AppLog-Integration für Disconnect / Engine-Errors

**Explizit Out-of-Scope (für Step-2/3 + P4-Live):**
- Bitunix-Connector / echter Exchange-API-Call (P4-Live, separate 2-4-Wochen-Welle)
- Order-Lifecycle (Pending / PartiallyFilled / Cancelled) — Step-1 nutzt simple Market-Fills @ close
- Slippage-Modell (Step-1 = 0 slippage, exact mid)
- Realistic-Latency-Simulation (Step-1 = instant fill am Bar-Close)
- Mehrere parallele Sessions (Step-1 = max. 1 aktive Session)
- Persistence der Session über App-Restart (Step-1 = In-Memory only)
- Risk-Limits / Kill-Switch / Daily-Loss-Cap (Step-3)
- Order-Book-basierte Fills mit Bid/Ask-Spread (Step-2)

---

## 2. Kontext

### Vorhandener Code

- **`lib/ui/screens/paper_trading_screen.dart`** (122 Zeilen): reiner Placeholder mit `ComingSoonBanner` + Mock-Cards. Wird in B4-3 vollständig ersetzt.
- **`lib/services/binance_api_client.dart`**: nur REST-Client (`/api/v3/klines`). **Kein** WebSocket. B4-1 fügt eine separate WS-Komponente hinzu.
- **`lib/services/rust_bridge.dart`** Zeilen 485-498: `startPaperTrading` / `stopPaperTrading` sind TODO-Stubs (Rust returns false). **Step-1 nutzt diese nicht** — Signal-Generation läuft pure Dart via `BacktestService.runXxx` (siehe unten).
- **`lib/services/backtest_service.dart`**: hat `runBbRsi(candles, …)` / `runUtBot` / `runIchimoku`. Step-1 ruft diese **per Candle-Window** auf (rolling 500-Candle-Lookback) und liest **den letzten Trade** aus dem Ergebnis, um zu sehen ob die Strategie gerade `entry` / `exit` signalisiert hätte.
  - **Trade-off:** Das ist nicht so effizient wie eine echte `signalForCandle(candle, state, params)`-Funktion. Aber es vermeidet eine Engine-API-Erweiterung in Step-1. Step-2 darf das refactoren.
- **`BacktestProvider`**: hat `config: BacktestConfig` mit `strategyKind`, `strategyParams`, `symbol`, `timeframe`, `initialBalance`, `feeRate`. Wird in B4-3 als Sync-Quelle gelesen, aber NICHT modifiziert (Paper-Session hat eigenen State).
- **`AppLog`**: für WS-Disconnect-Warnings und Engine-Errors per Tick.

### Daten-Pipeline

```
Binance WS  ──► KlineUpdate Stream ──► PaperTradingProvider.onTick
                                            │
                                            ├─► append to candleBuffer (max 500)
                                            ├─► BacktestService.runXxx(candleBuffer, params)
                                            ├─► read last trade (entry/exit?)
                                            ├─► update positions + equity
                                            └─► notifyListeners
```

### Symbol/Timeframe-Constraints

- Binance Spot, **derselbe Symbol-Pool wie der Backtest** (`AppConstants.supportedSymbols`).
- Timeframes 1m/5m/15m/1h sinnvoll. 4h/1d auch erlaubt, aber Step-1 dokumentiert „erwartet aktive Trades nur in 1m-15m Zeitrahmen".
- WebSocket-Stream-Name: `{symbol_lower}@kline_{interval}` (z.B. `btcusdt@kline_1m`).
- **Closed-Candle-Filter:** nur Events mit `k.x == true` (Candle is closed) emitten — sonst flackert die Strategie auf in-flight-Ticks.

### Engine-Tick-Pragmatik (Step-1)

Statt eine neue `signalForCandle`-API in der Engine zu fordern (das wäre Step-2 / Rust-FFI-Welle), nutzt Step-1 ein **Rolling-Window-Replay**:

1. Halte einen Ring-Buffer von max. 500 letzten geschlossenen Candles im Provider.
2. Pro WS-Tick (= neuer geschlossener Candle):
   - Append zu Buffer (Tail-trim auf 500).
   - Ruf `BacktestService.runXxx(buffer, initialBalance, feeRate, params)`.
   - Inspect `result.trades.last`:
     - Wenn `last.entryTimestamp == lastTickTimestamp` → **entry-Signal jetzt** → öffne virtuelle Position.
     - Wenn `last.exitTimestamp == lastTickTimestamp` → **exit-Signal jetzt** → schließe Position.
   - Update `currentEquity` aus Buffer-Last-Close + offene Position (Mark-to-Market).
3. Result: User sieht **denselben Trade-Pfad**, den ein Backtest auf denselben Candles produzieren würde — mit Live-Daten.

**Achtung:** Diese Mechanik wiederholt die ganze Backtest-Engine pro Tick. Bei 1m-Timeframe = 1× pro Minute = OK. Bei 1s-Tick (wenn Maik später feinere TFs will) = unbrauchbar — dann muss Step-2 die echte streaming-`signalForCandle`-API einziehen.

### Status-Symbolik

- **Idle**: noch nie gestartet
- **Connecting**: WS-Handshake läuft
- **Running**: WS connected, candle-Updates kommen
- **Reconnecting**: WS verloren, Backoff-Retry läuft
- **Stopped**: User hat Stop geklickt
- **Error**: nicht-recovery-bar (z.B. ungültiges Symbol)

---

## 3. Commit-Plan (5 atomare Commits)

### COMMIT B4-1: Binance WebSocket Kline-Stream Client

**Files:**
- `lib/services/binance_websocket.dart` (neu):
  - `class BinanceKlineStream`:
    - `Stream<KlineUpdate> connect({required String symbol, required String interval, bool closedOnly = true})`
    - `void disconnect()`
    - Internal: `WebSocket` + heartbeat ping/pong, exponential-backoff reconnect (1s, 2s, 4s, 8s, 16s, capped)
    - JSON-Parse: `e: kline, k: {t, T, s, i, o, h, l, c, v, x, ...}`
    - `closedOnly: true` filtert auf `k.x == true`
  - `class KlineUpdate { int openTime, closeTime, double open, high, low, close, volume; bool isClosed }`
- `pubspec.yaml`: dependency `web_socket_channel: ^3.0.0` (idiomatic Flutter WS package, supports Linux/macOS/Windows/web)

**Tests:**
- `test/services/binance_websocket_test.dart`:
  - Mock-WS-Server via `web_socket_channel` test utilities
  - Parse-Test mit echtem Binance-Payload-Sample (siehe Binance API-Doc)
  - `closedOnly=true` filtert in-flight ticks raus
  - Reconnect-Backoff (mock disconnect → expect retry after 1s)
  - Auf disconnect → `AppLog.warn` fired

**Commit msg:**
```
feat(phase-B4-1): Binance kline WebSocket client with reconnect

Adds BinanceKlineStream — a Stream<KlineUpdate> over Binance Spot's
{symbol}@kline_{interval} channel. Filters in-flight ticks by default
(closedOnly), so downstream consumers only see fully-closed candles.
Exponential-backoff reconnect with AppLog.warn on disconnect keeps
the paper-trading session resilient to transient network drops.
```

### COMMIT B4-2: PaperTradingProvider + virtual-fill engine

**Files:**
- `lib/features/paper/paper_position.dart` (neu): `PaperPosition { side, entryPrice, quantity, slPrice, tpPrice, openedAt }`
- `lib/features/paper/paper_session.dart` (neu): `PaperSession { config (PaperConfig), status, candleBuffer, openPosition, trades (List<ClosedTrade>), equity, equityCurve }`
- `lib/features/paper/paper_trading_provider.dart` (neu):
  - `ChangeNotifier`
  - `void start(PaperConfig config)` — startet WS, init Session
  - `void stop()` — disconnect, status=stopped
  - `void onTick(KlineUpdate)` — siehe Engine-Tick-Pragmatik in Sektion 2
  - `void syncFromBacktest(BacktestProvider)` — kopiert config-Felder (symbol, tf, kind, params, balance, feeRate)
  - All async/try-catch → `AppLog.error` + status=Error
- `lib/main.dart`: `ChangeNotifierProvider(create: (_) => PaperTradingProvider())` im MultiProvider

**Tests:**
- `test/features/paper/paper_trading_provider_test.dart`:
  - start → status transitions idle → connecting → running
  - onTick mit 100 synthetic candles (LCG-fixture, BB+RSI defaults) → expect ≥1 trade closed in session.trades
  - stop → WS disconnect, status=stopped
  - syncFromBacktest kopiert exakt symbol/tf/kind/params/balance/feeRate
  - Engine-error pro Tick → AppLog.error, session continues (status bleibt running)
  - Position lifecycle: open via entry-signal, mark-to-market via mid-Tick, close via exit-signal

**Commit msg:**
```
feat(phase-B4-2): PaperTradingProvider with rolling-window engine ticks

State + lifecycle for a single paper-trading session. Each closed-candle
tick from BinanceKlineStream appends to a 500-candle ring buffer and
replays the active strategy via BacktestService; the last trade in the
result drives virtual position open/close. Engine errors per tick are
logged to AppLog without killing the session. syncFromBacktest mirrors
the active BacktestProvider config into the paper session.
```

### COMMIT B4-3: PaperTradingScreen redesign

**Files:**
- `lib/ui/screens/paper_trading_screen.dart` (rewrite, 122 → ~300 Zeilen):
  - Top: **Status-Card** (Idle/Connecting/Running/Reconnecting/Stopped/Error mit Farbpunkt — grau/amber/grün/amber/grau/rot) + Start/Stop-Button + "Sync from Backtest"-Quicklink
  - **Active-Session-Card**: strategy + symbol + timeframe + initial balance + current equity + P&L absolut/% + tick-count
  - **Open-Position-Card** (wenn aktiv): side, entry-price, current mark-price, unrealized P&L, SL/TP-Levels
  - **Recent-Trades-Table** (DataTable wie B2-4 trials_top10_table, aber für `ClosedTrade`): Time, Side, Entry, Exit, Qty, PnL, Reason
  - **Mini-Equity-Curve** (fl_chart LineChart, kompakt): equity over time seit Session-Start
- Entfernt `coming_soon_banner.dart`-Import.

**Tests:**
- `test/ui/screens/paper_trading_screen_test.dart`:
  - Idle-State rendert "Start"-Button, kein Sync-Conflict
  - Running-State zeigt Active-Session-Card + Tick-Counter steigt
  - Sync-Button kopiert Backtest-Config sichtbar
  - Stop-Button transitioniert auf stopped
  - Open-Position-Card erscheint nur wenn session.openPosition != null

**Commit msg:**
```
feat(phase-B4-3): paper trading screen with live session UI

Replaces the ComingSoonBanner with a live paper-trading dashboard:
status indicator, active session card, open position with mark-to-
market unrealized P&L, recent trades table, and a mini equity curve.
Sync-from-Backtest button mirrors the active backtest config into the
session in one click.
```

### COMMIT B4-4: Symbol/Timeframe-Validation + connection resilience

**Files:**
- `lib/features/paper/paper_trading_provider.dart` (extend):
  - Validate `config.symbol` gegen `AppConstants.supportedSymbols` → error wenn nicht
  - Validate `config.timeframe` gegen Binance-WS-erlaubte Intervalle (`1m, 3m, 5m, 15m, 30m, 1h, 2h, 4h, 1d, 1w`)
  - On WS reconnect-success after disconnect → status zurück auf `running` (nicht `connecting`)
  - Wenn 5 Reconnect-Versuche failed → status=Error, AppLog.error, session stays stopped
- `lib/ui/screens/paper_trading_screen.dart` (small):
  - Reconnect-Counter sichtbar bei status=Reconnecting

**Tests:**
- `test/features/paper/paper_trading_provider_test.dart` (extend):
  - Invalid symbol → status=Error, AppLog.error
  - Invalid timeframe → status=Error
  - 5 mock-disconnects → status=Error nach dem 5.

**Commit msg:**
```
feat(phase-B4-4): paper session input validation + reconnect cap

Symbol gates against AppConstants.supportedSymbols, timeframe against
the Binance WS-supported interval set. The reconnect loop caps at 5
attempts before tipping the session into Error — preventing infinite
backoff when the underlying WS is structurally unavailable.
```

### COMMIT B4-5: End-to-End Smoke-Test (synthetic candle stream)

**Files:**
- `test/integration/paper_trading_smoke_test.dart` (neu):
  - Inject mock `Stream<KlineUpdate>` (statt echter WS) via constructor-injection in PaperTradingProvider (Provider sollte `BinanceKlineStream` als optionalen Dependency akzeptieren)
  - Emit 200 LCG-fixture candles
  - Expect: status running, candleBuffer fills, ≥1 trade closed, equity != initial
  - Stop → status=stopped, WS-Stream cleanly cancelled

**Commit msg:**
```
test(phase-B4-5): end-to-end paper trading smoke test

Drives the full B4 stack with a synthetic 200-candle stream injected
via constructor: provider start → tick replay → trade lifecycle →
equity update → clean stop. No external network or WS dependency.
```

---

## 4. Gates pro Commit

| Gate | Erwartung |
|---|---|
| `flutter analyze` | 0 issues |
| `cargo clippy --all-targets -- -D warnings` | 0 warnings (kein Rust-Touch) |
| `cargo test --release` | alle grün (kein Rust-Touch) |
| `flutter test` (gesamt) | alle B3-Baseline-348 grün + neue B4-Tests grün |
| `phase1_reference_backtest_test` | **8/8 grün, 91 Trades bit-exakt Dart↔Rust 1e-9** (FROZEN, KRITISCH) |
| `dart_rust_*_parity_test` | alle grün |
| B1/B2/B3-Tests | grün (Backward-Compat aller Provider/Screens) |
| Push | Direkt nach grünem Commit |

---

## 5. Eskalations-Stopp

Sofort STOPP + Diagnose-Brief wenn:

- `phase1_reference_backtest` bricht (KRITISCH, immer)
- WebSocket-Connect failt auf Linux/macOS/Windows wegen Plattform-Lib-Mismatch (`web_socket_channel` sollte das abdecken — wenn nicht: Diagnose)
- Engine-Tick im Rolling-Window-Replay produziert NaN/Inf in Equity → numerischer Bug, Diagnose
- BacktestService-Aufruf pro Tick blockt UI-Thread > 100ms → **Move to isolate via `compute(...)`** (wie schon in BacktestProvider gelöst) ODER reduziere Buffer auf 200 candles, je nach Profiling
- Reconnect-Loop führt zu Memory-Leak (akkumulierte Listener auf WS-Stream) → dispose-Hygiene prüfen
- Session-State leakt zwischen Start/Stop-Zyklen (z.B. Position aus alter Session sichtbar nach Restart) → State-Reset in `start()` strikt enforcen

---

## 6. Endbericht (nach B4-5)

Brief an QA mit:
1. **5 Commit-Hashes** in Tabelle
2. **Test-Status-Tabelle** (alle Gates, finaler Stand, neue Tests gegenüber B3-Baseline 348)
3. **Manueller Smoke-Test-Aufgabe an Maik:**
   - Start.bat → Paper-Tab → "Sync from Backtest"
   - "Start" → Status wechselt Idle → Connecting → Running
   - Auf 1m-Timeframe ein paar Minuten warten → mind. 1 Tick verifizieren (Tick-Counter +1)
   - Wenn Strategie auf den Candle reagiert: Open-Position-Card erscheint
   - "Stop" → saubere Disconnect, Status=Stopped
   - Internet-Disconnect simulieren (WiFi off für 30s) → Status=Reconnecting → bei Reconnect zurück auf Running
4. **Push-Status** (alle 5 Commits auf origin/main?)
5. **Anomalien** (z.B. Tick-Latency, Engine-Tick-Performance, WS-Edge-Cases auf Windows)
6. **Empfehlung nächste Welle:**
   - B4 Step-2 (Order-Lifecycle + Slippage-Modell)?
   - A1.1/A1.2 ADX-Sub-Sweep?
   - B2.1 ruvector.db?
   - Phase-4-Prep (Bitunix-Connector)?

---

## 7. Aufwand & Risiko

- **Geschätzt:** 1 Session, 6-8h Engineering (größer als B3 wegen WS + Engine-Tick-Pragmatik)
- **Hauptrisiko:** Engine-Tick-Performance — Rolling-Window-Replay pro Tick könnte auf 1h-Timeframe + 500-Candle-Buffer den UI-Thread blockieren. **Pre-Check vor B4-2:** auf einem 200-Candle-Fixture die `BacktestService.runBbRsi`-Duration messen. Wenn > 50ms → in `compute(...)` umstellen.
- **Sekundärrisiko:** WebSocket-Resilience auf Windows — Firewall, Proxy, IPv6-Edge-Cases. `web_socket_channel` ist Standard, sollte aber bei Maik (Windows) explizit lokal getestet werden.

---

## 8. Sign-off

QA-Koordinator wartet auf Maik-Sign-off **nach erfolgreichem Smoke-Test B2 + B3** bevor dieser Brief an parallel-CC weitergereicht wird.
