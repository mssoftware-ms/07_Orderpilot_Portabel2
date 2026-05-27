# Pre-Task Welle B4 Step-4 — Live-Toggle Enable-Logic + Confirm-Dialog

**Issued:** 2026-05-27 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem
**Base:** `e8ed0b4` (origin/main, inkl. B4.3 Risk-Layer komplett)

---

## ⚠️ Sicherheits-Kontext — letzte Schwelle zum Live-Pfad

Diese Welle entfernt das `onChanged: null` aus dem Live-Trading-Toggle, das seit P4P-4 die strukturelle Garantie war, dass kein User versehentlich Live-Mode aktivieren kann. Nach dieser Welle ist der Switch **enable-bar**, aber:

- **Nur wenn alle 3 Eligibility-Gates passen** (`allRiskGatesActive && exchangeConnected && killSwitchInactive`)
- **Nur über einen expliziten Confirm-Dialog** mit klarer Warnung
- **Auto-Disable** wenn irgendein Gate während Live-Mode falsy wird
- **`BitunixClient.placeOrder/cancelOrder` werfen weiterhin `LiveTradingDisabledException`** — die echte Order-Routing-Implementierung kommt in P4P Step-2. Diese Welle schaltet nur den UI-Toggle frei.

Das bedeutet: **selbst wenn ein User Live-Toggle aktiviert UND die Strategie ein Signal feuert, wird KEIN echter Trade ausgelöst** — der `LiveTradingDisabledException`-Layer aus P4P bleibt unverändert. Wir bauen nur den UI-Pfad, nicht das Order-Routing.

Code-Skizzen weiterhin unverifizierte Hypothesen. Pattern-Referenzen nutzen.

---

## 1. Scope

**Live-Toggle UI-Pfad öffnen**, nichts anderes. Order-Routing-Implementation explizit out-of-scope.

**In Scope:**
- `RiskConfig.liveTradingEnabled: bool` (default false), persistiert
- `RiskManager.enableLiveTrading()` / `disableLiveTrading()` mit Persistierung + AppLog
- `account_screen.dart:529` `onChanged: null` → echte Logic:
  - Switch nur interaktiv (enabled), wenn `eligibility.isEligible == true`
  - Flip OFF → ON: ConfirmDialog mit detaillierter Warnung (3 Punkte: real money, exchange-API calls, Risk-Layer guards aktiv)
  - Confirm → `riskManager.enableLiveTrading()` + sichtbare Status-Änderung
  - Cancel → Switch bleibt OFF
  - Flip ON → OFF: **kein** Confirm-Dialog (sofortiges Disable, immer erlaubt — Safety-Pfad)
- **Auto-Disable**: `account_screen.dart` listened auf Eligibility-Changes. Wenn `liveTradingEnabled == true && eligibility.isEligible == false` → sofortiges `disableLiveTrading()` + `AppLog.warn` + Snackbar/Toast Information
- 4 existing Live-Disabled-Regression-Tests **angepasst**: pinnen jetzt nicht mehr `onChanged: null`, sondern dass der Switch nur enable-bar ist wenn alle Eligibility-Gates passen + ConfirmDialog blockiert das Enable

**Out-of-Scope:**
- BitunixClient.placeOrder/cancelOrder Implementation (P4P Step-2 nach dieser Welle)
- PaperTradingProvider Live-Mode-Branch (würde `BitunixClient.placeOrder` rufen — kommt erst, wenn dieser nicht mehr throws)
- WebSocket-User-Streams (P4P Step-2)
- Order-Lifecycle (Pending/PartiallyFilled/Cancelled — P4P Step-3 oder später)

---

## 2. Kontext

### Vorhandener Code (relevant)

- **`lib/ui/screens/account_screen.dart` Z. 472**: `const liveEnabled = false;` — wird abgeschafft, durch `riskManager.config.liveTradingEnabled` ersetzt
- **`lib/ui/screens/account_screen.dart` Z. 529**: `onChanged: null` — wird zur echten Logic
- **`lib/features/risk/risk_config.dart`**: bekommt neues Feld `bool liveTradingEnabled = false`. `toMap`/`fromMap`/`copyWith` müssen das Feld mitführen — Memory `pretask_lesson_deprecated_wrapper_edge_cases.md` analog: copyWith muss alle bestehenden Felder behalten.
- **`lib/features/risk/risk_manager.dart`**: bekommt `enableLiveTrading()` / `disableLiveTrading()` Methoden. Pattern wie `activateKillSwitch()` / `resetKillSwitch()` aus B4.3-1.
- **`lib/features/risk/live_mode_eligibility.dart`**: bleibt unverändert. Doc-Comment Z. 11-12 sagt explizit *„The next wave only has to thread `LiveModeEligibility.isEligible` into the switch's `onChanged` parameter and add the confirm-dialog"* — exactly what this wave does.
- **4 Live-Disabled-Regression-Tests** (laut B4.3-Endbericht):
  - `account_screen_test`, `account_screen_risk_test`, `bitunix_connector_smoke_test`, `risk_layer_smoke_test`
  - Diese Tests pinnen aktuell `onChanged == null`. Müssen angepasst werden: Switch ist enable-bar **abhängig** von Eligibility, ConfirmDialog appears bei Enable-Attempt.

### Confirm-Dialog-Inhalt

Vorschlag (Skizze, kann der parallel-CC anpassen wenn UX-Sinn macht):

```
Title: "Activate Live Trading?"
Body:
  This will enable real-money trading on Bitunix Futures.

  Before continuing, confirm you understand:
  • The Risk-Layer guards (position risk, daily loss, drawdown,
    consecutive losses) are configured and will block trades
    that breach the caps.
  • The kill switch is currently inactive — trades can fire.
  • Strategy signals will be routed to Bitunix via authenticated
    API calls. You are responsible for the outcomes.

  Activate Live Trading?

Actions: [Cancel] [Activate Live Trading]  (destructive style)
```

### Auto-Disable-Trigger

Account-Screen `build()` evaluiert Eligibility neu bei jedem `notifyListeners()` von RiskManager / BitunixConnectionProvider. Auto-Disable-Hook:

```dart
@override
Widget build(BuildContext context) {
  final risk = context.watch<RiskManager>();
  final exchange = context.watch<BitunixConnectionProvider>();
  final eligibility = LiveModeEligibility.evaluate(
    riskManager: risk, exchangeProvider: exchange,
  );

  // Auto-Disable: wenn Live aktiv aber Eligibility weg → sofort off
  if (risk.config.liveTradingEnabled && !eligibility.isEligible) {
    // ABER: nicht direkt in build! Post-frame callback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      risk.disableLiveTrading(reason: 'Eligibility lost');
      // optional: Snackbar via ScaffoldMessenger
    });
  }
  // ... rest of build
}
```

**Gotcha:** State-Mutation in `build()` ist illegal in Flutter. `WidgetsBinding.instance.addPostFrameCallback` ist der saubere Weg. Memory-Tag dafür: nicht direkt mutieren, immer postFrame.

---

## 3. Commit-Plan (2 atomare Commits)

### COMMIT B4.4-1: RiskConfig.liveTradingEnabled + RiskManager methods

**Files:**
- `lib/features/risk/risk_config.dart`:
  - Neues Feld `final bool liveTradingEnabled` (default false)
  - `toMap`/`fromMap`/`copyWith` mitziehen
  - Equality/hashCode mit dem neuen Feld
- `lib/features/risk/risk_manager.dart`:
  - `Future<void> enableLiveTrading()`: `_config = _config.copyWith(liveTradingEnabled: true)` + persist + `AppLog.warn('RiskManager', 'Live trading enabled')` + `notifyListeners()`
  - `Future<void> disableLiveTrading({String reason = 'manual'})`: invertiert + `AppLog.warn(reason)` + persist + notify

**Tests:**
- `test/features/risk/risk_config_test.dart` erweitern:
  - Default `liveTradingEnabled == false`
  - Roundtrip toMap→fromMap mit liveTradingEnabled=true
  - copyWith preserves liveTradingEnabled
- `test/features/risk/risk_manager_test.dart` erweitern:
  - `enableLiveTrading` flips state to true + persists + fires AppLog.warn
  - `disableLiveTrading(reason: 'manual')` flips back + log includes reason
  - `disableLiveTrading(reason: 'Eligibility lost')` includes reason in log
  - Kill-Switch active → `enableLiveTrading()` ist **idempotent-throwing** ODER no-op? (Vorschlag: no-op + AppLog.warn — Kill-Switch hat Vorrang)
- `test/integration/risk_layer_smoke_test.dart` (B4.3) **bleibt grün** — `liveTradingEnabled` ist neues Feld, B4.3-Tests prüfen es nicht

**Commit msg:**
```
feat(phase-B4.4-1): RiskConfig.liveTradingEnabled + RiskManager toggle methods

Adds the persistent boolean RiskConfig.liveTradingEnabled (default
false) and RiskManager.enableLiveTrading/disableLiveTrading methods
that flip + persist + log. The kill-switch retains precedence:
calling enableLiveTrading while the kill switch is active is a
logged no-op, not a state flip. The pre-existing Live-Disabled
contract (BitunixClient.placeOrder/cancelOrder still throw) stays
unchanged — this commit only carries the toggle bit.
```

---

### COMMIT B4.4-2: account_screen onChanged + Confirm-Dialog + Auto-Disable

**Files:**
- `lib/ui/screens/account_screen.dart` Z. 472-529 area:
  - Entferne `const liveEnabled = false;`
  - `final liveEnabled = risk.config.liveTradingEnabled;`
  - Switch:
    - `value: liveEnabled`
    - `onChanged: eligibility.isEligible ? (v) => _handleLiveToggle(context, risk, v) : null`
  - Neue Method `Future<void> _handleLiveToggle(BuildContext context, RiskManager risk, bool target)`:
    - Wenn `target == false`: direkt `risk.disableLiveTrading(reason: 'manual')`, kein Dialog
    - Wenn `target == true`: ConfirmDialog (siehe Skizze in Sektion 2). Confirm → `risk.enableLiveTrading()`. Cancel → nichts (state bleibt)
  - **Auto-Disable-Hook** in `build()`:
    ```dart
    if (risk.config.liveTradingEnabled && !eligibility.isEligible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        risk.disableLiveTrading(reason: 'Eligibility lost');
        // Optional: ScaffoldMessenger zeigt Toast/Snackbar
      });
    }
    ```
  - Update Comment-Block: `// CRITICAL: onChanged stays null` ersetzen durch neue Doc, die das Eligibility-Gating + ConfirmDialog dokumentiert
- 4 Test-Files anpassen:
  - **`test/ui/screens/account_screen_test.dart`**: Test „switch is disabled when eligibility false" + Test „switch is enabled when eligibility true" + Test „flip ON shows ConfirmDialog" + Test „confirm enables live trading" + Test „cancel does not enable" + Test „flip OFF skips dialog"
  - **`test/ui/screens/account_screen_risk_test.dart`**: Auto-Disable-Test: setup mit `liveTradingEnabled=true`, then trigger eligibility loss (z.B. activate kill-switch) → expect `liveTradingEnabled` becomes false post-frame
  - **`test/integration/bitunix_connector_smoke_test.dart`**: Update Live-Disabled-Assertion zu Eligibility-Gated-Assertion
  - **`test/integration/risk_layer_smoke_test.dart`**: Update um Live-Enable-Flow zu testen (mit allen 3 Gates → Confirm → enabled; dann Kill-Switch → auto-disabled)

**Tests neue (ggf. in eigenes File):**
- `test/ui/screens/account_screen_live_toggle_test.dart` (neu, falls eigenes File sinnvoller als bestehende erweitern):
  - 8-10 Tests die das Toggle-Verhalten umfassend abdecken

**Commit msg:**
```
feat(phase-B4.4-2): live toggle enable flow + auto-disable on eligibility loss

Replaces account_screen's structural onChanged: null with an
eligibility-gated handler. The switch is interactable iff all three
LiveModeEligibility conjuncts pass; flipping it ON pops a confirm
dialog spelling out the real-money implication, while flipping OFF
skips the dialog (safety-first). A post-frame auto-disable hook
flips the toggle back off the moment any eligibility gate breaks
(e.g. the user activates the kill switch while live mode was on),
and writes an AppLog.warn entry with the reason.

BitunixClient.placeOrder/cancelOrder still throw — order routing
lands in P4P Step-2. This commit only opens the UI path.
```

---

## 4. Gates pro Commit

| Gate | Erwartung |
|---|---|
| `flutter analyze` | 0 issues |
| `cargo clippy --all-targets -- -D warnings` | 0 warnings (kein Rust-Touch) |
| `cargo test --release` | alle grün (kein Rust-Touch) |
| `flutter test` (gesamt) | **B4.3-Baseline 545 + neue B4.4-Tests grün** |
| `phase1_reference_backtest_test` | grün (KRITISCH) |
| `f06_model_unification_test` | grün |
| `dart_rust_*_parity_test` | grün |
| B1..B4.3 Bestand | grün |
| **Live-Order-Stub-Regression** (`bitunix_live_disabled_test.dart` 8 Pinned-Tests) | grün — `BitunixClient.placeOrder/cancelOrder` werfen weiterhin unconditional |
| Push direkt nach grünem Commit | ✓ |

---

## 5. Eskalations-Stopp

- `phase1_reference_backtest` bricht: KRITISCH, STOPP
- **`bitunix_live_disabled_test.dart` bricht**: SOFORT STOPP, sicherheitskritisch. Diese Welle darf den Order-Stub-Pfad nicht antasten.
- Auto-Disable-Hook triggert in `build()` direkt (statt postFrame): Endlos-Build-Loop → STOPP, fix mit `addPostFrameCallback`
- ConfirmDialog dismissable durch Tap-Outside ohne explizites Cancel: Standard Flutter `barrierDismissible: false` setzen (sicherheitskritisch — User MUSS aktiv Cancel oder Confirm wählen)
- Switch wird enable-bar OHNE dass alle Eligibility-Gates passen: Logic-Bug in `onChanged: eligibility.isEligible ? ... : null` — Test muss aktiv Eligibility-False-Pfad abdecken
- `_handleLiveToggle` ruft `enableLiveTrading()` ohne vorherigen Confirm-Click: Race zwischen Switch-State und Dialog → Lösung: Switch-Animation erst nach Dialog-Result
- Kill-Switch + Live-Toggle ON gleichzeitig: erwartetes Verhalten = Kill-Switch hat Vorrang, auto-disable greift sofort. Test verifiziert das.

---

## 6. Endbericht (nach B4.4-2)

Brief an QA mit:
1. **2 Commit-Hashes** in Tabelle
2. **Test-Status-Tabelle** (alle Gates, neue Tests gegenüber B4.3-Baseline 545)
3. **Manueller Smoke-Test-Aufgabe an Maik:**
   - Account-Tab → Risk Limits sind konfiguriert, Bitunix-Connected, Kill-Switch inactive → 3 Checkmarks ✓ → Live-Switch ist **enable-bar**
   - Flip ON → ConfirmDialog erscheint mit klarem Warning-Text → „Activate Live Trading" → Switch zeigt ON
   - Flip OFF → ohne Dialog sofort OFF
   - Flip ON → Confirm → Activate Kill-Switch → Switch **auto-disabled**, AppLog.warn-Entry sichtbar
   - App neu starten → `liveTradingEnabled` persistent (war es ON beim Stop, sollte nach Restart ON sein wenn Eligibility noch passt — sonst auto-disabled)
4. **Push-Status**
5. **Anomalien**
6. **Empfehlung nächste Welle:**
   - **P4P Step-2** (Bitunix-Order-Routing + WebSocket-User-Streams) — jetzt sinnvoll, weil Live-Toggle aktivierbar
   - oder Chart-Tab finalisieren
   - oder A1.1/A1.2 ADX-Sub-Sweep

---

## 7. Aufwand & Risiko

- **Geschätzt:** ~2h Engineering, 2 Commits
- **Hauptrisiko:** Auto-Disable-Hook in `build()` ohne postFrame → Build-Loop. Memory-Hint: state mutation never directly in build, immer addPostFrameCallback.
- **Sekundärrisiko:** Auto-Disable kann während Test-Race-Condition unerwartete States produzieren. Test mit `pumpAndSettle()` + `runAsync` falls Race auftaucht (Memory `testing_runasync_in_widget_tests.md`).
- **Tertiärrisiko:** ConfirmDialog `barrierDismissible: true` (Standard) lässt User per Tap-Outside dismissen ohne aktive Wahl. Sicherheits-relevant — explizit auf `false` setzen.

---

## 8. Sign-off

QA-Koordinator wartet auf Maik-Sign-off bevor dieser Brief an parallel-CC weitergereicht wird.
