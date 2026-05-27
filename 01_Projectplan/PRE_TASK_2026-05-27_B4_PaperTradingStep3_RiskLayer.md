# Pre-Task Welle B4 Step-3 — Risk-Layer (unblocks P4P Live-Mode)

**Issued:** 2026-05-27 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem
**Base:** `2131e35` (origin/main, inkl. P4P + gitignore-Update)

---

## ⚠️ Risiko-Kontext

Diese Welle ist der **Schlüssel zwischen Paper-Trading und Live-Trading**. Sie baut den Risk-Layer, der den dauerhaft disabled `Live-Trading`-Toggle aus P4P-4 zum ersten Mal **enable-bar** macht — aber **nur unter strikten Gates**. Implementierungs-Fehler hier können dazu führen, dass die nächste Welle (P4P Step-2, Live-Order-Routing) versehentlich gegen echtes Geld feuert. Konsequenzen:

- **Live-Toggle wird auch nach dieser Welle NICHT aktivierbar** — er wird nur **vorbereitet**. Die letzte Enable-Schwelle (explizite User-Confirmation per Dialog) bleibt **separate Welle B4 Step-4** oder Teil von P4P Step-2.
- Risk-Settings sind **persistent** (via flutter_secure_storage oder normaler shared_preferences — siehe Kontext).
- Kill-Switch wirkt **sofort und global**: alle aktiven Sessions stoppen, Live-Toggle wird auf disabled gezwungen, Reset-Button wieder freigeben.
- Memory-Lesson aus B3 (Deprecated-Wrapper-Edge-Cases) gilt analog: **der Live-Toggle-Enable-Pfad muss explizit dokumentierte Vorbedingungen haben, sonst slipt versehentliches Enable durch**.

Code-Skizzen in diesem Brief sind weiterhin **unverifizierte Hypothesen**. Bei Architektur-Entscheidungen (RiskManager als Provider oder Singleton, Settings-Persistenz-Backend) Pattern-Referenzen im Repo nutzen.

---

## 1. Scope

**Risk-Layer-Foundation**, die als Gate vor jeder Order-Auslösung (Paper UND zukünftig Live) konsultiert wird. Vier Risk-Limits, ein Kill-Switch, ein konfigurierbarer Bypass-Modus (für Paper-Trading, nicht für Live).

**In Scope:**
- **`RiskManager` Provider** (zentraler Gate-Keeper, ChangeNotifier)
- **`RiskConfig`** persistent: max_position_risk_pct, max_daily_loss_pct, max_drawdown_pct, max_consecutive_losses
- **`RiskAssessment`** Snapshot: aktueller daily PnL, current drawdown, consecutive losses, all-gates-pass-Flag
- **Kill-Switch**: sofortiges global stop, prominent in Paper-Screen + Account-Screen
- **Live-Toggle-Unlock-Vorbedingung**: `LiveModeEligibility { allRiskGatesActive: bool, exchangeConnected: bool, killSwitchInactive: bool }` — separat von dem eigentlichen Switch-Enable (das kommt in einer Folge-Welle)
- **PaperTradingProvider-Integration**: `RiskManager.canOpenPosition` gate vor jedem Order-Open
- **Risk-Settings-Screen** oder Risk-Section im Account-Screen

**Out-of-Scope (Folge-Wellen):**
- Live-Toggle tatsächlich enable-able machen + explicit user-confirm-Dialog (B4 Step-4 oder P4P Step-2)
- Order-Lifecycle-Tracking gegen Exchange (P4P Step-2)
- Hedging-Limits / Margin-Type-Constraints / Cross- vs Isolated-Margin (Phase-4-Live)
- Position-Sizing-Algorithmen (z.B. Kelly, Fixed-Fractional) — RiskManager **prüft nur Limits**, sizing bleibt Strategie-Sache
- Trailing-Drawdown vs Static-Drawdown (Step-3 nimmt statisch: ratio gegen `initialBalance`; Trailing kommt wenn Bedarf besteht)
- Risk-pro-Symbol oder pro-Strategy (Step-3 ist session-global)

---

## 2. Kontext

### Bestehende Code-Struktur

- **`lib/features/paper/paper_trading_provider.dart`**: hat `start/stop/onTick`. Order-Open passiert via `BacktestService`-Result → `session.openPosition`-Set in `_processTick`. Hier muss der `RiskManager.canOpenPosition`-Gate rein.
- **`lib/features/paper/paper_session.dart`**: `PaperSession` hat `equity`, `totalPnl`, `equityCurve`. Daily-Loss-Tracking lässt sich daraus ableiten, **wenn session-startedAtMs als Anker für „heute" genutzt wird** (in Step-3 reicht das, kein wirkliches UTC-day-rollover).
- **`lib/features/exchange/bitunix_connection_provider.dart`**: `BitunixConnectionStatus`. Wird vom RiskManager **gelesen, nicht geschrieben** (loose coupling).
- **`lib/ui/screens/account_screen.dart`** Z. 388-442: Live-Toggle mit `onChanged: null` + Step-3-pending-pill. Diese Welle lässt den `onChanged: null` **unverändert** — die Schwelle bleibt drin, RiskManager bereitet nur die `eligibility` vor, die der NÄCHSTE Welle den Toggle freischaltet.
- **`lib/core/logging/app_log.dart`**: Risk-Breach-Events → `AppLog.warn` (User-actionable) oder `AppLog.error` (Kill-Switch-Trigger).

### Settings-Persistenz

Zwei Optionen:
- **`shared_preferences`** (Standard Flutter, key-value, plaintext): OK für Risk-Limits (keine Secrets)
- **`flutter_secure_storage`** (von P4P bereits in Repo): Overkill für Limits, aber konsistent mit Bitunix-Secrets-Storage

**Empfehlung: `shared_preferences`** für Risk-Config (nicht-sensitiv, lesbar in Dev-Tools). Plus pubspec-Dependency `shared_preferences: ^2.2.0`.

### Daily-Reset-Logik

Pragmatisch für Step-3: „Daily" = seit `session.startedAtMs`. Echtes UTC-Day-Rollover (Reset um 00:00 UTC) ist Step-3.1, falls Bedarf besteht.

### Kill-Switch-Wirkung

Aktiviert via Button + Confirm-Dialog:
1. Paper-Session: sofort `stop()` (cancelt WS-Subs, finalisiert Session)
2. Live-Mode-Eligibility: `killSwitchInactive = false` → Live-Toggle bleibt disabled
3. Persistiert in RiskConfig als `killSwitchActive: bool`, der User muss aktiv „Reset Kill-Switch"-Button drücken um wieder zu enable-n

Kill-Switch ist **session-übergreifend**: einmal aktiviert bleibt er aktiv, auch nach App-Restart, bis User explizit reset.

---

## 3. Commit-Plan (5 atomare Commits)

### COMMIT B4.3-1: RiskConfig + RiskAssessment + RiskManager core

**Files:**
- `lib/features/risk/risk_config.dart` (neu):
  - `class RiskConfig` immutable: `double maxPositionRiskPct` (default 5.0), `double maxDailyLossPct` (default 3.0), `double maxDrawdownPct` (default 10.0), `int maxConsecutiveLosses` (default 5), `bool killSwitchActive` (default false)
  - `factory RiskConfig.defaults()` / `RiskConfig.fromMap(Map<String,dynamic>)` / `toMap()`
  - JSON-Serialization für shared_preferences
- `lib/features/risk/risk_assessment.dart` (neu):
  - `enum RiskGate { positionRisk, dailyLoss, drawdown, consecutiveLosses, killSwitch }`
  - `class RiskAssessment` immutable: `double currentDailyPnlPct`, `double currentDrawdownPct`, `int currentConsecutiveLosses`, `bool killSwitchActive`, `Set<RiskGate> breachedGates`, `bool allGatesPass`
- `lib/features/risk/risk_manager.dart` (neu):
  - `class RiskManager extends ChangeNotifier`
  - State: `RiskConfig _config`, `RiskAssessment _lastAssessment`
  - Methoden:
    - `Future<void> loadConfig()` / `Future<void> saveConfig(RiskConfig)` via shared_preferences
    - `RiskAssessment assess(PaperSession session)` — pure function (gibt Assessment zurück, kein State-Mutation)
    - `bool canOpenPosition(PaperSession session, {required double proposedPositionSize})` — `assess()` + position-Size-Check, returns `false` wenn irgendein Gate breached
    - `Future<void> activateKillSwitch({required String reason})` — sets `killSwitchActive = true`, persists, AppLog.error mit reason
    - `Future<void> resetKillSwitch()` — sets `killSwitchActive = false`, persists, AppLog.warn
  - `pubspec.yaml`: `shared_preferences: ^2.2.0`

**Tests:**
- `test/features/risk/risk_config_test.dart`:
  - Roundtrip toMap → fromMap mit allen Feldern
  - Defaults sind sinnvoll (5/3/10/5/false)
- `test/features/risk/risk_assessment_test.dart`:
  - Constructor mit allGatesPass derived from breachedGates.isEmpty
- `test/features/risk/risk_manager_test.dart`:
  - `loadConfig` returns defaults when nothing stored
  - `saveConfig` persists, next `loadConfig` returns saved
  - `assess` mit fresh session (no trades) → allGatesPass true
  - `assess` mit session-PnL < -3% von initialBalance → dailyLoss-gate breached
  - `assess` mit drawdown > 10% → drawdown-gate breached
  - `assess` mit 5 consecutive losses → consecutiveLosses-gate breached
  - `canOpenPosition` mit proposedSize > 5% of equity → positionRisk-gate breached
  - `activateKillSwitch` persistiert + fires AppLog.error
  - `resetKillSwitch` reverts state
  - Kill-Switch active → `canOpenPosition` returns false unconditionally

**Pattern-Referenz:** `lib/features/paper/paper_trading_provider.dart` für ChangeNotifier-Struktur, `lib/core/utils/param_storage.dart` für persistent-storage-Pattern (file-basiert, nicht shared_preferences — hier divergieren wir bewusst, weil Risk-Settings einfacher sind).

**Eskalations-Pfad:** Wenn `shared_preferences` auf Desktop instabil ist (selten, aber möglich): Fallback auf eine JSON-Datei in `~/.trading_app/risk_config.json` analog `param_storage.dart`. Endbericht-Hinweis.

**Commit msg:**
```
feat(phase-B4.3-1): RiskManager core + persistent RiskConfig

Adds the foundation of the risk layer: a RiskConfig (max position
risk %, daily loss cap, drawdown cap, consecutive-losses cap,
kill-switch flag) persisted via shared_preferences, a pure-function
RiskAssessment producer, and a RiskManager ChangeNotifier that
gates canOpenPosition. The kill-switch sticks across app restarts —
once tripped, only an explicit reset re-enables trading. AppLog
surfaces breaches at warn level and kill-switch activations at
error level.
```

---

### COMMIT B4.3-2: PaperTradingProvider integration

**Files:**
- `lib/features/paper/paper_trading_provider.dart`:
  - Konstruktor bekommt optionalen `RiskManager? riskManager` Parameter (für DI in Tests; production ruft mit dem Provider-Instance)
  - In `_processTick`, **vor** `session.openPosition = PaperPosition(...)`:
    1. `final assessment = riskManager.assess(session)`
    2. Wenn `!assessment.allGatesPass`:
       - `AppLog.warn('PaperTradingProvider', 'Position open blocked by risk gates: ${assessment.breachedGates}')`
       - Emit OrderEvent `riskBlocked` (neuer OrderEventKind)
       - `return` ohne Position-Open
    3. Wenn `proposedSize > maxPositionRisk%`:
       - Same blocking pattern
  - `lib/features/paper/order_event.dart`: `OrderEventKind` um `riskBlocked` erweitern, color in UI = orange/amber

**Tests:**
- `test/features/paper/paper_trading_provider_risk_test.dart` (neu):
  - Mock-RiskManager returns allGatesPass=false → onTick mit Trade-Signal → keine PaperPosition gesetzt, OrderEvent `riskBlocked` emittet
  - Mock-RiskManager allGatesPass=true → normal position-open
  - Mock-RiskManager Kill-Switch active → canOpenPosition returns false → no position
  - Bestand-Tests (B4.2) bleiben grün (default `riskManager = null` → ungated, kein Regression)

**Pattern-Referenz:** `lib/features/paper/paper_trading_provider.dart` selbst (B4.2-3 OrderEvent-Pattern für riskBlocked).

**Commit msg:**
```
feat(phase-B4.3-2): paper trading risk gate before position open

PaperTradingProvider consults RiskManager.assess + canOpenPosition
before opening a virtual position. Breach paths log via AppLog.warn,
emit a new riskBlocked OrderEvent, and skip the position without
killing the session — so the user can watch the strategy continue
to signal while seeing why nothing executes. The risk manager is
injected as a nullable constructor argument for backwards-compat
with B4 step-1/2 tests.
```

---

### COMMIT B4.3-3: Risk-Settings UI (eigene Section im Account-Screen)

**Files:**
- `lib/ui/screens/account_screen.dart`:
  - Neue Section direkt unter **Live-Trading-Card**: „Risk Limits"
  - 4 Slider:
    - Max Position Risk % (range 0.5-10, step 0.5, default 5)
    - Max Daily Loss % (range 1-10, step 0.5, default 3)
    - Max Drawdown % (range 5-30, step 1, default 10)
    - Max Consecutive Losses (range 3-15, step 1, default 5)
  - „Save Risk Limits"-Button → `RiskManager.saveConfig`
  - Aktuelle Assessment-Anzeige: 4 kleine Cards mit Live-Werten (current daily PnL %, current drawdown %, consecutive losses, kill-switch status)
- `lib/main.dart`: `ChangeNotifierProvider(create: (_) => RiskManager()..loadConfig())` im MultiProvider

**Tests:**
- `test/ui/screens/account_screen_risk_test.dart` (neu):
  - Risk-Settings-Section rendert mit Default-Werten
  - Slider-Drag updates pending state
  - Save-Button ruft `riskManager.saveConfig` mit den Slider-Werten
  - Assessment-Cards rendern Live-Werte

**Pattern-Referenz:** `lib/ui/widgets/param_slider.dart` für Slider-Style, `lib/features/paper/paper_session.dart` UI in Account-Screen für Slider-Layout.

**Commit msg:**
```
feat(phase-B4.3-3): risk limits UI in account screen

Adds a Risk Limits section to the account screen with four sliders
(position risk %, daily loss %, drawdown %, consecutive losses) and
a live assessment readout showing the current values against the
configured caps. Save persists via RiskManager; the kill-switch
status is surfaced as a separate badge.
```

---

### COMMIT B4.3-4: Kill-Switch (Paper-Screen + Account-Screen)

**Files:**
- `lib/ui/screens/paper_trading_screen.dart`:
  - Prominenter „🛑 KILL SWITCH" Button oben rechts in der Status-Card (red, large)
  - onPressed → ConfirmDialog: *„Activate Kill-Switch? This stops the active session and blocks new sessions until you manually reset it."*
  - Confirm → `riskManager.activateKillSwitch(reason: 'manual')` + `paperTradingProvider.stop()`
- `lib/ui/screens/account_screen.dart`:
  - In der Risk-Section: „Kill-Switch active"-Badge wenn aktiv, „Reset Kill-Switch"-Button (mit ConfirmDialog)
  - Reset → `riskManager.resetKillSwitch()`
- `lib/features/risk/risk_manager.dart`: hook für ConfirmDialog-Callback (oder Provider-Pattern)

**Tests:**
- `test/ui/screens/paper_trading_screen_kill_switch_test.dart` (neu):
  - Kill-Switch-Button visible in idle/running/stopped states
  - Tap → ConfirmDialog visible
  - Confirm → `riskManager.activateKillSwitch` called + `provider.stop` called
  - Cancel → nichts passiert
- `test/ui/screens/account_screen_kill_switch_reset_test.dart` (neu):
  - Reset-Button nur sichtbar wenn killSwitchActive
  - Tap → ConfirmDialog → Confirm → `riskManager.resetKillSwitch` called

**Pattern-Referenz:** `lib/ui/widgets/apply_trial_dialog.dart` für ConfirmDialog-Pattern (in B3 eingebaut).

**Commit msg:**
```
feat(phase-B4.3-4): kill-switch button + confirm-dialog flow

Adds a prominent red KILL SWITCH button to the paper trading screen
and a Reset Kill-Switch flow to the account screen risk section.
Both flows route through a ConfirmDialog so a mis-tap can't trigger
the global stop. The kill-switch state persists across app restarts
via RiskConfig — manual reset only.
```

---

### COMMIT B4.3-5: LiveModeEligibility + End-to-End Smoke

**Files:**
- `lib/features/risk/live_mode_eligibility.dart` (neu):
  - `class LiveModeEligibility` immutable: `bool allRiskGatesActive`, `bool exchangeConnected`, `bool killSwitchInactive`, `bool isEligible` (=alle drei true)
  - `static LiveModeEligibility evaluate({RiskManager riskManager, BitunixConnectionProvider exchangeProvider})` — pure function
- `lib/ui/screens/account_screen.dart`:
  - In der Live-Trading-Card unter dem disabled Switch eine **`LiveModeEligibility`-Readout-Sektion** (3 Checkmarks):
    - ✓/✗ Risk limits configured
    - ✓/✗ Exchange connected
    - ✓/✗ Kill-switch inactive
  - **Switch bleibt weiterhin `onChanged: null`** — die Enable-Schwelle kommt in einer Folge-Welle
- `test/integration/risk_layer_smoke_test.dart` (neu):
  - Full-Stack-Smoke: RiskManager + PaperTradingProvider + BitunixConnectionProvider in MultiProvider
  - Sequence:
    1. Defaults loaded → eligibility.isEligible = false (no exchange connected)
    2. Risk-Config save → first Checkmark turns ✓
    3. Mock-Bitunix connect → second Checkmark turns ✓
    4. expect: eligibility.isEligible still false (Switch still disabled — Folge-Welle), aber alle drei Checkmarks ✓
    5. Activate Kill-Switch → dritter Checkmark wird ✗
    6. Reset Kill-Switch → wieder alle drei ✓

**Commit msg:**
```
feat(phase-B4.3-5): live-mode eligibility readout + e2e smoke

Introduces LiveModeEligibility — a pure aggregate of the three
conditions that must hold before the live-trading toggle can be
enabled in a future wave (risk limits configured, exchange connected,
kill-switch inactive). The account screen renders the three conditions
as checkmarks under the still-disabled switch, so the user can see
exactly what's missing. The actual enable-of-the-switch is a separate
wave; this commit only prepares the gate.
```

---

## 4. Gates pro Commit

| Gate | Erwartung |
|---|---|
| `flutter analyze` | 0 issues |
| `cargo clippy --all-targets -- -D warnings` | 0 warnings (kein Rust-Touch) |
| `cargo test --release` | alle grün (kein Rust-Touch) |
| `flutter test` (gesamt) | **P4P-Baseline 483 + neue B4.3-Tests grün** |
| `phase1_reference_backtest_test` | 8/8 grün (KRITISCH) |
| `f06_model_unification_test` | grün |
| `dart_rust_*_parity_test` | grün |
| B1..P4P Bestand-Tests | grün |
| **LIVE-DISABLED-REGRESSION** (P4P-5 Tests + Account-Screen Switch) | grün — `onChanged: null` bleibt in dieser Welle UNVERÄNDERT |
| Push direkt nach grünem Commit | ✓ |

---

## 5. Eskalations-Stopp

- `phase1_reference_backtest` bricht: KRITISCH, STOPP
- **Live-Toggle wird in dieser Welle versehentlich enable-bar**: SOFORT STOPP, sicherheitskritisch. Diese Welle bereitet nur die Eligibility-Aggregation vor; der `onChanged: null` muss unverändert bleiben.
- B4.2-Tests brechen wegen RiskManager-Default-Verhalten: RiskManager als `null` injizierbar lassen, default = ungated (kein Regression in B4-Bestand)
- `shared_preferences` auf Windows-Desktop instabil: Fallback auf JSON-File via `param_storage.dart`-Pattern, Endbericht-Hinweis
- Kill-Switch wirkt nicht sofort (z.B. Race mit gerade-laufendem onTick): Test mit aktivem Tick → Kill-Switch → expect Position nicht geöffnet
- Risk-Assessment falsch berechnet (z.B. drawdown vs daily-loss verwechselt): Unit-Tests gegen explicit fixture sessions

---

## 6. Endbericht (nach B4.3-5)

Brief an QA mit:
1. **5 Commit-Hashes** in Tabelle
2. **Test-Status-Tabelle** (alle Gates, neue Tests gegenüber P4P-Baseline 483)
3. **Manueller Smoke-Test-Aufgabe an Maik:**
   - Account-Tab → Risk-Limits-Section → Slider verschieben → Save → App neu starten → Werte sind persistent
   - Paper-Tab → 🛑 KILL SWITCH klicken → ConfirmDialog → Confirm → Session stoppt
   - Account-Tab → „Reset Kill-Switch" → ConfirmDialog → Confirm → Kill-Switch inaktiv
   - Account-Tab → Live-Trading-Card → 3 Checkmarks zeigen den Eligibility-Status
   - **Live-Toggle bleibt disabled** (Folge-Welle enabled das)
4. **Push-Status**
5. **Anomalien:** shared_preferences-Stabilität, Race-Conditions im Kill-Switch, Assessment-Edge-Cases
6. **Empfehlung nächste Welle:**
   - B4 Step-4 (Live-Toggle Enable-Logik + explicit user-confirm-Dialog) — letzte Schwelle vor Live-Mode
   - oder P4P Step-2 (WebSocket-User-Streams für Live-Position-Updates)
   - oder Chart-Tab finalisieren
   - oder A1.1/A1.2 ADX-Sub-Sweep

---

## 7. Aufwand & Risiko

- **Geschätzt:** 6-9h Engineering, 5 Commits
- **Hauptrisiko:** Versehentliches Enable des Live-Toggles. Mitigation: dieser Brief schreibt explizit *„`onChanged: null` bleibt unverändert"*, Test pinnt das Pattern weiterhin.
- **Sekundärrisiko:** RiskManager-Coupling an PaperTradingProvider könnte Bestand-Tests brechen. Mitigation: optionaler Konstruktor-Parameter, default null = ungated.
- **Tertiärrisiko:** shared_preferences-Plattform-Issues (selten). Mitigation: Fallback-Plan dokumentiert.

---

## 8. Sign-off

QA-Koordinator wartet auf Maik-Sign-off bevor dieser Brief an parallel-CC weitergereicht wird.
