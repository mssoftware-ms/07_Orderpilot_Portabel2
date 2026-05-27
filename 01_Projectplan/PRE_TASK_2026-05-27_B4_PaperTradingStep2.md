# Pre-Task Welle B4 Step-2 — Paper-Trading Lifecycle, SL/TP, Slippage, Gap-Recovery

**Issued:** 2026-05-27 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem
**Base:** `e092009` (origin/main, inkl. B4 Step-1)

---

## ⚠️ Vorwort — Pre-Task-Code-Skizzen sind Hypothesen

In den letzten drei Wellen (B2, B3, B2.1-2) haben meine Code-Skizzen jeweils einen subtilen Bug erzeugt, den der parallel-CC beim Implementieren erkennen und korrigieren musste. Lessons:
- B2: `sqfliteFfiInit` vor `WidgetsFlutterBinding.ensureInitialized()` → falsche Reihenfolge
- B3: `applyOptimizedParams`-Wrapper ohne Edge-Case-Erhalt → B1-Tests gebrochen
- B2.1-2: DraggableScrollableSheet-Handle außerhalb der ListView → nicht draggable

**Konsequenz:** Code-Skizzen in diesem Brief sind **unverifizierte Vorschläge**. Bei Flutter-API-Patterns oder Engine-internem Verhalten **bestehende Vorbilder im Repo als Blueprint nehmen** (siehe „Pattern-Referenzen" unter den Commits), nicht die Skizze blind übernehmen.

---

## 1. Scope

Paper-Trading **Step-2** — vier orthogonale Erweiterungen, die Step-1 in einen realistischen Spot-Paper-Tracker verwandeln:

1. **SL/TP-Surface** für die offene Position (Step-1 zeigt `—`, weil ClosedTrade SL/TP nicht trägt)
2. **Slippage-Modell** sichtbar in der UI + realistische Defaults (Engine kann das schon — siehe Kontext)
3. **Order-Trail** (Event-Log, NICHT volle Lifecycle-State-Machine — siehe Out-of-scope)
4. **Gap-Recovery** via REST nach WS-Reconnect (Backfill fehlender Candles)

**Out-of-Scope** (Step-3 / P4-Live):
- Volle Order-Lifecycle-State-Machine (Pending→PartiallyFilled→Cancelled) — Engine ist Market-Only, Lifecycle wäre Overengineering
- Limit-Orders / Market-on-Close / OCO-Orders
- Bitunix-Connector / echter Exchange (P4-Live)
- Risk-Limits / Kill-Switch / Daily-Loss-Cap (Step-3)
- Multi-Position-Support (Engine ist single-position)

---

## 2. Kontext

### Vorhandener Code (relevante Touchpoints)

**Engine-Side:**
- `lib/services/backtest_service.dart` Z. 114-119: `BbRsiParams.slippageBps: double = 0.0` **existiert bereits**. Analog vermutlich in `UtBotParams` / `IchimokuParams` — vor B4.2-2 verifizieren.
- `BacktestResult` Z. 37-47: hat `metrics`, `equityCurve`, `trades` — **kein openPosition-Field**. B4.2-1 muss dieses Feld additiv einführen (siehe unten).
- `BacktestService.runBbRsi/runUtBot/runIchimoku`: force-closen aktuell die letzte Open-Position mit `exitReason == 'End of Data'`. Step-1 PaperTradingProvider liest diesen Sentinel als „position still open". Das funktioniert, lässt aber slPrice/tpPrice unter den Tisch fallen.

**Paper-Side:**
- `lib/features/paper/paper_position.dart` Z. 38-41: `slPrice`, `tpPrice` sind nullable und in Step-1 **immer null** (siehe Doc-Comment Z. 8-12).
- `lib/features/paper/paper_session.dart` Z. 133-144: `openPosition: PaperPosition?`, `closedTrades`, `equity`, `equityCurve` — alle mutable, refreshed jeden Tick.
- `lib/features/paper/paper_trading_provider.dart` Z. 264-279: PaperPosition-Reconstruction aus `result.trades.last` (mit `exitReason == 'End of Data'`-Sentinel). **Schwachstelle:** `slPrice/tpPrice` nicht gesetzt.
- `lib/services/binance_websocket.dart`: WS-Client mit Reconnect (B4-1). Hat `onReconnectSuccess`-Hook nicht, aber `KlineConnectionStatus.running` nach Reconnect ist erkennbar (Status-Stream-Pattern).
- `lib/services/binance_api_client.dart`: REST-Client mit `downloadHistory(symbol, interval, days)` und `fetchHistoricalKlines(symbol, interval, startMs, endMs, limit)`. **Existiert** für Backfill.

**Tests:**
- `test/regression/f06_model_unification_test.dart`: prüft `ClosedTrade`-Equality Dart↔Rust. **WICHTIG:** wenn `ClosedTrade` neue Felder bekommt, muss Rust mitziehen oder die Felder müssen nullable + Default null sein, damit Equality nicht bricht.
- `test/integration/phase1_reference_backtest_test.dart`: 91 Trades bit-exakt. **FROZEN.** Bricht wenn die Engine die letzte Open-Position nicht mehr force-closed.

### Engine-Surface-Strategie für openPosition (B4.2-1)

Drei Optionen, **empfohlen Option B**:

**Option A — ClosedTrade extend um nullable slPrice/tpPrice**
- Pro: minimal-invasiv, schon existing Trade-Stream
- Contra: Rust-Pfad muss mitziehen oder f06_model_unification bricht; auch die letzte Position bleibt force-closed → `exitReason == 'End of Data'`-Hack bleibt
- **Verworfen** wegen Rust-FFI-Bind

**Option B (empfohlen) — BacktestResult extend um optional `openPosition: OpenPositionSnapshot?`**
- BacktestService.runXxx bekommt einen **optionalen Parameter** `extractOpenPosition: bool = false` (default false ⇒ bit-exakter Backward-Compat zu B1)
- Wenn `true`: letzte ungeschlossene Position fließt in `result.openPosition` (mit slPrice/tpPrice), **nicht** in `result.trades`. Default `false` behält das aktuelle Force-Close-Verhalten und phase1_reference_backtest bleibt grün.
- PaperTradingProvider ruft mit `extractOpenPosition: true` — nimmt direkt `result.openPosition` statt das `'End of Data'`-Sentinel-Spiel
- Pro: additiv, kein Rust-Touch (PaperTradingProvider nutzt Dart-Engine direkt, Rust-FFI nicht), Force-Close-Hack rauswerfbar
- Contra: zweite Code-Pfad in der Engine (extractOpenPosition true/false), Tests für beide Pfade nötig

**Option C — separate Helper-Funktion `deriveOpenPositionContext(candles, signalBarIdx, kind, params)`**
- Pro: Engine völlig unverändert
- Contra: doppelte SL/TP-Logik in Dart vs. Engine — Drift-Risiko. Verworfen, weil Drift schwer testbar.

**Entscheidung im Pre-Task: Option B.** Wenn der parallel-CC beim Implementieren in einen Edge-Case läuft (z. B. Rust-FFI ruft die Methode auf), darf er auf Option A umschwenken — aber mit Begründung im Endbericht.

### OpenPositionSnapshot Datenmodell-Skizze (unverifiziert)

```dart
// lib/core/models/trade.dart (additiv, unverifiziert)
class OpenPositionSnapshot {
  final String direction;     // 'LONG' | 'SHORT'
  final int openedAt;          // entry-fill bar timestamp (ms)
  final double entryPrice;
  final double quantity;
  final double slPrice;
  final double tpPrice;
  final double entryFee;
  // mark-to-market wird nicht hier gespeichert — das ist Provider-Side

  const OpenPositionSnapshot({...});
}
```

Falls Rust-FFI später mitziehen muss: nullable Feld in JSON-Payload, Dart-Default = null.

---

## 3. Commit-Plan (5 atomare Commits)

### COMMIT B4.2-1: BacktestResult.openPosition + opt-in extraction

**Files:**
- `lib/core/models/trade.dart`: neue `class OpenPositionSnapshot` (Pure-Dart, immutable)
- `lib/services/backtest_service.dart`:
  - `BacktestResult` bekommt `final OpenPositionSnapshot? openPosition;` (nullable, default null)
  - `runBbRsi/runUtBot/runIchimoku` bekommen `bool extractOpenPosition = false` Parameter
  - Wenn `true`: letzte ungeschlossene Position **nicht** als ClosedTrade in `trades` aufnehmen, stattdessen in `openPosition` mit slPrice/tpPrice aus den signal-bar internen Variablen
  - Default `false` → bit-exakt zu B1 (phase1_reference_backtest unverändert)
- `lib/features/paper/paper_trading_provider.dart`:
  - Aufruf `runBbRsi(..., extractOpenPosition: true)` ersetzen
  - PaperPosition-Reconstruction nutzt `result.openPosition` direkt (slPrice/tpPrice gefüllt)
  - Force-Close-Sentinel-Logik (`exitReason == 'End of Data'`) **entfernen** (sentinel-trade kommt mit `extractOpenPosition: true` nicht mehr in `trades`)

**Tests:**
- `test/services/backtest_service_open_position_test.dart` (neu):
  - `extractOpenPosition: false` → result unverändert zu B1, openPosition == null, trades-Count identisch
  - `extractOpenPosition: true` → letzte Position in openPosition, trades-Count um 1 niedriger als Default-Pfad
  - openPosition.slPrice / tpPrice match die signal-bar-Werte (für BB+RSI: Swing-Low/High berechnet aus letzter N Candles)
- `test/integration/phase1_reference_backtest_test.dart`: **bleibt unverändert grün** — nutzt Default-Pfad
- `test/features/paper/paper_trading_provider_test.dart` (erweitern):
  - PaperPosition.slPrice / tpPrice nicht mehr null bei Position-Open
  - Force-Close-Hack-Test entfernt (Logik geändert)

**Pattern-Referenz:** keine direkte — Engine-Mod. Vor Implementierung den BB+RSI-Engine-Code (`backtest_service.dart` BbRsiBacktest-Klasse) lesen, um zu sehen wie die SL/TP-Variablen pro Bar aktuell geführt werden.

**Commit msg:**
```
feat(phase-B4.2-1): BacktestResult.openPosition + opt-in extraction

Adds an optional OpenPositionSnapshot field to BacktestResult, populated
when callers pass extractOpenPosition: true. The default path
(extractOpenPosition: false) keeps the bit-exact force-close behavior
that phase1_reference_backtest depends on. PaperTradingProvider now
calls with extractOpenPosition: true and reads result.openPosition
directly, dropping the 'End of Data' sentinel hack and surfacing
slPrice + tpPrice on the live PaperPosition card.
```

---

### COMMIT B4.2-2: Slippage-UI + realistische Defaults

**Files:**
- `lib/features/paper/paper_session.dart`:
  - `PaperConfig` bekommt `double slippageBps = 5.0` (default 5 bps für Spot)
  - Wenn die `strategyParams` ein `slippageBps`-Field haben (BbRsiParams hat es schon — Z. 119): bei `start()` automatisch `strategyParams` mit `PaperConfig.slippageBps` mergen
  - **Verifizieren vor B4.2-2:** Haben UtBotParams + IchimokuParams ebenfalls `slippageBps`? Wenn nicht, in der Engine ergänzen ist Step-3 — Pre-Task-Stopp und Brief.
- `lib/ui/screens/paper_trading_screen.dart`:
  - Im Pending-Config-Card oder Active-Session-Card ein neues Slippage-Slider (0–20 bps) hinzufügen
  - Default-Anzeige: „5 bps (Binance Spot retail)"
  - Slider disabled während running (Slippage gilt für die ganze Session)

**Tests:**
- `test/features/paper/paper_trading_provider_test.dart` (erweitern):
  - PaperConfig.slippageBps default 5.0
  - `start(config)` mergt slippageBps in strategyParams
  - Slippage propagiert zu BacktestService → trade.entryPrice spiegelt slippageBps ungleich 0 wider
- `test/ui/screens/paper_trading_screen_test.dart` (erweitern):
  - Slippage-Slider sichtbar in idle-State
  - disabled während running

**Pattern-Referenz:** `lib/ui/widgets/param_slider.dart` für Slider-Style.

**Commit msg:**
```
feat(phase-B4.2-2): paper session slippage UI with retail defaults

PaperConfig gains a session-level slippageBps (default 5 bps for spot
retail), which is merged into the active strategyParams on start().
The screen surfaces a slider (0-20 bps) in the pending-config card,
disabled while running so slippage stays stable for the session.
Engine support is pre-existing in BbRsiParams.slippageBps — Step-2
just exposes it.
```

---

### COMMIT B4.2-3: Order-Trail (Event-Log)

**Files:**
- `lib/features/paper/order_event.dart` (neu):
  - `class OrderEvent { DateTime timestamp; OrderEventKind kind; String message; }`
  - `enum OrderEventKind { signalReceived, positionOpened, positionClosed, slHit, tpHit, sessionStarted, sessionStopped, wsReconnect }`
- `lib/features/paper/paper_session.dart`:
  - `final List<OrderEvent> orderTrail` (mutable, cap 100 last events)
- `lib/features/paper/paper_trading_provider.dart`:
  - Bei `start()`: append `sessionStarted`
  - Bei jedem Tick mit neuem Entry/Exit: append `positionOpened` / `positionClosed` mit Direction + Price
  - Bei Exit-Reason `'SL'` / `'TP'`: append `slHit` / `tpHit`
  - Bei `stop()`: append `sessionStopped`
  - Bei WS-Reconnect-Success: append `wsReconnect`
- `lib/ui/screens/paper_trading_screen.dart`:
  - Neue „Order Trail"-Card unter „Recent Trades"
  - Kompakte Liste, jüngste oben, max 20 sichtbar
  - Color-coding: sessionStart/Stop = grau, positionOpened = cyan, positionClosed = grün/rot je nach P&L, slHit = rot, tpHit = grün

**Tests:**
- `test/features/paper/order_event_test.dart` (neu): Konstruktor, Equality
- `test/features/paper/paper_trading_provider_test.dart` (erweitern):
  - Event-Trail nach start: enthält sessionStarted
  - Nach Tick mit Position-Open: positionOpened-Event mit Direction
  - Trail ist auf 100 capped
- `test/ui/screens/paper_trading_screen_test.dart` (erweitern): Trail-Card rendert mit Events

**Pattern-Referenz:** `lib/core/logging/app_log.dart` für Ring-Buffer-Pattern.

**Commit msg:**
```
feat(phase-B4.2-3): paper session order trail event log

Adds an OrderEvent ring buffer (cap 100) to PaperSession plus
emission points in PaperTradingProvider for sessionStarted /
positionOpened / positionClosed / slHit / tpHit / sessionStopped /
wsReconnect. The screen renders an "Order Trail" card under the
recent trades with color-coded entries.
```

---

### COMMIT B4.2-4: Gap-Recovery via REST after WS reconnect

**Files:**
- `lib/services/binance_api_client.dart`: vermutlich keine Änderung (existing `fetchHistoricalKlines` reicht)
- `lib/features/paper/paper_trading_provider.dart`:
  - Beim WS-Status-Transition `reconnecting → running` (also Reconnect erfolgreich):
    1. Letzten Buffer-Candle-Timestamp lesen (`lastTickMs`)
    2. `BinanceApiClient.fetchHistoricalKlines(symbol, tf, startMs: lastTickMs + 1, endMs: now, limit: 1000)`
    3. Dedupe by timestamp, append zu Buffer (tail-trim auf 500 wenn nötig)
    4. Trigger Replay-Tick (`onTick(virtual_last_candle)`) — verarbeitet die backfilled Candles als wäre die Session ununterbrochen
    5. Emit `wsReconnect`-OrderEvent mit `"backfilled N candles"` Message
    6. AppLog.info `"Backfilled N candles after WS reconnect"`
  - Fehler beim Backfill (z. B. Binance-REST-API down): AppLog.warn + weiter mit leerem Backfill (Session bleibt running, Gap wird stillschweigend hingenommen)

**Tests:**
- `test/features/paper/paper_trading_provider_test.dart` (erweitern):
  - Mock-WS disconnect → 3 Mock-REST-Candles zurück → expect Buffer wuchs um 3, Replay lief
  - Mock-REST-Failure → expect Session bleibt running, AppLog.warn fired
  - Backfill mit 0 neuen Candles (REST returns []) → no-op, kein Replay
  - Dedupe: REST returns 2 Candles die schon im Buffer sind → Buffer-Size unverändert

**Pattern-Referenz:** `lib/services/binance_api_client.dart` für REST-Call-Pattern. `lib/features/backtest/backtest_provider.dart` für isolate-compute-Pattern (falls REST-Decode UI-Thread blockt — unwahrscheinlich, aber für >500 Candles bedenken).

**⚠️ Eskalations-Pfad:** Wenn `fetchHistoricalKlines` mit `startMs > endMs` (z. B. WS-Reconnect war instant) crasht statt einer leeren Liste zurückzugeben: Pre-Check in PaperTradingProvider einbauen (`if startMs >= now: skip backfill`).

**Commit msg:**
```
feat(phase-B4.2-4): REST gap-recovery after WS reconnect

When the kline WebSocket transitions from reconnecting back to running,
PaperTradingProvider backfills the missing window via the existing
BinanceApiClient REST endpoint, dedupes against the current buffer,
and replays the engine on the merged candle list. REST failures are
logged via AppLog.warn without killing the session.
```

---

### COMMIT B4.2-5: End-to-End smoke test

**Files:**
- `test/integration/paper_trading_step2_smoke_test.dart` (neu):
  - Sequence:
    1. `start(config: { symbol: BTCUSDT, tf: 1m, kind: bbRsi, params: ..., slippageBps: 5.0 })`
    2. Mock-WS emittiert 100 closed Candles → expect Buffer fills, ≥1 Trade closed, openPosition vielleicht non-null
    3. Mock-WS disconnect simulieren (Status → reconnecting)
    4. Mock-REST gibt 5 candles zurück (gap-fill)
    5. Mock-WS Status → running (Reconnect-Success)
    6. expect: Buffer enthält ursprüngliche 100 + 5 backfilled = ≤500 nach trim, OrderTrail enthält `wsReconnect`-Event mit `backfilled 5`
    7. expect: openPosition (falls vorhanden) hat slPrice/tpPrice non-null
    8. `stop()` — clean disconnect, alle Subscriptions cancelled
  - Verifiziert NICHT: Slippage-UI (das ist UI-Test, nicht Integration)

**Pattern-Referenz:** `test/integration/paper_trading_smoke_test.dart` (B4-5) als Vorlage.

**Commit msg:**
```
test(phase-B4.2-5): end-to-end step-2 smoke test

Drives the full Step-2 stack: session start with 5 bps slippage,
100-candle tick stream, mid-session WS disconnect, REST gap-recovery
of 5 candles, reconnect, expect openPosition surfaces slPrice/tpPrice
and the order trail records the reconnect with the backfill count.
```

---

## 4. Gates pro Commit

| Gate | Erwartung |
|---|---|
| `flutter analyze` | 0 issues |
| `cargo clippy --all-targets -- -D warnings` | 0 warnings (kein Rust-Touch geplant) |
| `cargo test --release` | alle grün (kein Rust-Touch geplant) |
| `flutter test` (gesamt) | **B4-Baseline 385 + neue B4.2-Tests grün** |
| `phase1_reference_backtest_test` | **8/8 grün, 91 Trades bit-exakt Dart↔Rust 1e-9** (FROZEN, KRITISCH — Default-Pfad `extractOpenPosition: false` darf nicht brechen) |
| `f06_model_unification_test` | grün (ClosedTrade-Schema unverändert; OpenPositionSnapshot ist additives Feld auf BacktestResult, kein ClosedTrade-Touch) |
| `dart_rust_*_parity_test` | grün (kein Rust-Touch) |
| B1/B2/B3/B2.1/B4-Bestand-Tests | grün |
| Push direkt nach grünem Commit | ✓ |

---

## 5. Eskalations-Stopp

- `phase1_reference_backtest` bricht: **KRITISCH, sofort STOPP** (Default-Pfad `extractOpenPosition: false` muss bit-exakt zu B1 sein)
- `f06_model_unification_test` bricht: ClosedTrade-Schema-Drift → BacktestResult-Mod prüfen, OpenPositionSnapshot darf nicht in ClosedTrade-Equality einsickern
- Slippage-Verifikation: wenn `UtBotParams.slippageBps` oder `IchimokuParams.slippageBps` **nicht existieren** → Pre-Task-Stopp, Engine-Erweiterung wäre Step-3-Scope, Brief an QA mit Diagnose
- Gap-Recovery mit `startMs >= now`: REST-API könnte crashen → Pre-Check `if startMs >= now: skip backfill` einbauen
- Engine-extractOpenPosition-Pfad produziert NaN/Inf in slPrice/tpPrice (z. B. wenn signal-bar im Warm-up): Pre-Check + AppLog.warn + nullable belassen (UI rendert „—" wie in Step-1)
- WS-Reconnect-Storm (10 reconnects in 60s) triggert 10 REST-Backfills → Rate-Limit-Risk bei Binance. Mitigation: Backfill-Cooldown 30s (zweiter Reconnect innerhalb 30s skippt Backfill, vertraut auf nächsten Tick).
- Order-Trail-Events leaken zwischen Sessions (start/stop/start ohne clear): Test mit 3-fach start/stop muss leere Trail nach jedem `start()` zeigen

---

## 6. Endbericht (nach B4.2-5)

Brief an QA mit:
1. **5 Commit-Hashes** in Tabelle
2. **Test-Status-Tabelle** (alle Gates, neue Tests gegenüber B4-Baseline 385)
3. **Manueller Smoke-Test-Aufgabe an Maik:**
   - Paper-Tab → Sync from Backtest → Slippage-Slider sichtbar mit 5 bps default
   - Start → 1m-Timeframe → Position öffnet sich → **slPrice + tpPrice sichtbar** (nicht mehr „—")
   - WLAN aus → Reconnecting → WLAN an → OrderTrail-Card zeigt „Reconnected, backfilled N candles"
   - OrderTrail-Card scrollbar mit allen Events seit Session-Start
   - Stop → clean
4. **Push-Status**
5. **Anomalien** (z. B. Engine-extractOpenPosition Edge-Cases bei Warm-up, Slippage in den anderen Strategy-Params, REST-Rate-Limit-Beobachtungen)
6. **Empfehlung nächste Welle:**
   - B4 Step-3 (Risk-Limits / Kill-Switch / Daily-Loss-Cap)?
   - A1.1/A1.2 ADX-Sub-Sweep?
   - B2.1 ruvector.db?
   - Phase-4-Prep (Bitunix-Connector)?
   - Chart-Tab fertigstellen (Coming-Soon-Banner entfernen)?

---

## 7. Aufwand & Risiko

- **Geschätzt:** 5-7h Engineering, 5 Commits
- **Hauptrisiko:** B4.2-1 (Engine extractOpenPosition-Pfad). Wenn der parallel-CC merkt, dass die SL/TP-Internals pro Strategy unterschiedlich exponiert sind und ein Helper-Refactor nötig ist, kann die Welle auf 8-10h wachsen. In dem Fall: Endbericht mit Notiz statt Stopp.
- **Sekundärrisiko:** Slippage-Param-Verfügbarkeit pro Strategy. **Vor B4.2-2 verifizieren** — wenn UtBot/Ichimoku kein `slippageBps`-Field haben, ist das ein Pre-Task-Stopp und Engine-Erweiterung ist Step-3.

---

## 8. Sign-off

QA-Koordinator wartet auf Maik-Sign-off bevor dieser Brief an parallel-CC weitergereicht wird.
