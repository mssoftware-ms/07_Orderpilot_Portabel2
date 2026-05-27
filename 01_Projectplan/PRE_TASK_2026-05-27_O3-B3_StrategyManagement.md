# Pre-Task Welle O3-B3 — Strategy-Management-Screen (Apply-Trial-Loop)

**Issued:** 2026-05-27 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem grünen Commit
**Base:** `2150311` (origin/main, inkl. O3-B1 + Logging + O3-B2)

---

## 1. Scope

`StrategyManagementScreen` ist aktuell **Placeholder mit hardcoded Cards** ohne Funktion. O3-B3 wandelt ihn in den UX-Hub um, der den Loop **CLI-Optimizer → Studies → Strategy-Management → Backtest** schließt:

- 3 Strategy-Cards (BB+RSI, UT-Bot, Ichimoku) — live aus `StrategyKind` enum
- Pro Card: Current-Params-Summary, "Apply Trial from Study"-Button, Reset-to-Defaults
- "Apply Trial"-Dialog: DB-Picker → Trial-Liste → Apply → BacktestProvider hat neue Params
- Generalisierter `applyOptimizedParams` (heute BB+RSI-only) → funktioniert für alle 3 Strategien

**Out-of-scope** (für spätere Wellen):
- Strategy-Store-UI / Install / Premium-Badges (Mockup bleibt entfernt oder kommt als „Coming Soon")
- Multi-Symbol-Apply (Trial gilt für genau ein Symbol/Timeframe — UI muss das nicht anzeigen)
- Strategy-Editor / Custom-Strategy-Upload (lange Welle, nicht hier)
- Diffing zweier Trials (B3.1 falls Bedarf)

---

## 2. Kontext

### Vorhandener Code (relevant)

- **`lib/features/backtest/backtest_provider.dart`** (zentrale Klasse, lesen vor Commit B3-1!):
  - `enum StrategyKind { bbRsi, utBot, ichimoku }` mit `displayLabel`
  - `setStrategyKind(StrategyKind)` — switched + lädt Defaults via `defaultParamsFor(kind)`
  - `updateStrategyParams(Object params)` — type-asserted gegen aktiven `strategyKind`
  - `applyOptimizedParams(BbRsiParams params)` — **BB+RSI-only**, no-ops bei UT-Bot/Ichimoku, Kommentar: *„Welle O3-B1 OOS"* — **das hier räumt B3 auf**
  - Flag `_usingOptimizedParams` (bool) wird in `setStrategyKind` / `updateSymbol` / `updateTimeframe` / `updateStrategyParams` resettet
- **Param-Klassen** (`lib/services/backtest_service.dart`): `BbRsiParams`, `UtBotParams`, `IchimokuParams` — haben **kein fromMap/toMap** (B3-1 fügt fromMap hinzu)
- **`lib/ui/screens/strategy_management_screen.dart`**: 122 Zeilen, vollständig hardcoded — wird in B3-4 ersetzt
- **`StudiesProvider`** (B2): `loadDb`, `selectedStudy`, `top10` — kann recyclet werden für den Apply-Dialog
- **`Trial`** (B2): `params: Map<String, double>` ist bereits unwrapped (`{"values": {...}}` Wrapper entfernt)
- **`AppLog`**: für Catch-Logging in allen neuen async-Pfaden

### Trial-Params-Mapping pro Strategy

Aus den DB-Sample-Inspektionen + `search_space_yaml`:

| StrategyKind | Trial.params keys (subset, alle als double) |
|---|---|
| `bbRsi` | bb_period, bb_stddev, rsi_period, rsi_oversold, rsi_overbought, adx_*, risk_per_trade, swing_lookback_bars, tp_rr_ratio |
| `utBot` | key_value, atr_period, smi_length, smi_k, smi_d, swing_lookback_bars, tp_rr_ratio, risk_per_trade, adx_* |
| `ichimoku` | tenkan_period, kijun_period, senkou_b_period, shift, score_threshold, tp_rr_ratio, risk_per_trade, swing_lookback_bars, adx_* |

**Kritisch:** Int-Params (bb_period, rsi_period, etc.) werden in der DB als `double` gespeichert (`1.0`, `200.0` etc.). Beim Mapping `.toInt()` casten, **nicht `.round()`** — die Optimizer-Werte sind bereits ganzzahlig.

### DB-zu-Strategy-Filter

Die `.db`-Files in `01_Projectplan/optimizer_studies/`:
- `studies-bb_rsi.db`, `studies-bb_rsi_1h.db` → `strategy='bb_rsi'`
- `studies-ut_bot.db`, `studies-ut_bot_zerofee.db` → `strategy='ut_bot'`
- `studies-ichimoku.db`, `studies-ichimoku-tpe.db`, `studies-ichimoku-wf.db`, `studies-ichimoku-wf-w3a.db` → `strategy='ichimoku'`

Apply-Dialog soll **per Card-Context** vorgefiltert öffnen — wenn die Card für UT-Bot ist, sind nur `studies-ut_bot*.db` relevant. User kann aber manuell andere DBs laden.

---

## 3. Commit-Plan (5 atomare Commits)

### COMMIT B3-1: Param-fromMap-Factories + generalisierter applyTrialAsParams

**Files:**
- `lib/services/backtest_service.dart`:
  - `BbRsiParams.fromMap(Map<String, double>)` — fehlende Keys nehmen Default-Wert
  - `UtBotParams.fromMap(Map<String, double>)` — dito
  - `IchimokuParams.fromMap(Map<String, double>)` — dito
- `lib/features/backtest/backtest_provider.dart`:
  - Neue Methode `void applyTrialAsParams({required StrategyKind kind, required Map<String, double> trialParams})`:
    - Setzt `strategyKind` (wenn unterschiedlich)
    - Baut typed Params via `*.fromMap(trialParams)`
    - Setzt `strategyParams`, setzt `_usingOptimizedParams = true`
    - Logt via `AppLog.warn` wenn unbekannte Keys im trialParams (zur Sichtbarkeit von Schema-Drift)
  - `applyOptimizedParams(BbRsiParams)` bleibt als deprecated wrapper (Backward-Compat zu B1-Tests):
    ```dart
    @Deprecated('Use applyTrialAsParams instead — supports all StrategyKinds')
    void applyOptimizedParams(BbRsiParams params) {
      applyTrialAsParams(
        kind: StrategyKind.bbRsi,
        trialParams: params.toMap(),  // toMap auch hinzufügen
      );
    }
    ```

**Tests:**
- `test/services/backtest_service_params_fromMap_test.dart`:
  - Roundtrip `toMap → fromMap` für jede Param-Klasse identisch
  - `fromMap` mit fehlenden Keys → Defaults
  - `fromMap` mit Int-Keys als Double (`200.0`) → `.toInt()`, nicht `.round()`
- `test/features/backtest/backtest_provider_apply_trial_test.dart`:
  - `applyTrialAsParams` switched Strategy + setzt Params
  - `_usingOptimizedParams` → true
  - Unbekannter Key in trialParams → `AppLog.warn` fired, restliche Apply läuft durch
  - `applyOptimizedParams` (deprecated) delegiert korrekt

**Commit msg:**
```
feat(phase-O3-B3): generalize applyOptimizedParams to all StrategyKinds

Adds fromMap factories on BbRsiParams/UtBotParams/IchimokuParams plus
a new applyTrialAsParams(kind, trialParams) on BacktestProvider that
atomically swaps strategy + applies the trial's parameter values. The
legacy BB+RSI-only applyOptimizedParams becomes a deprecated wrapper
that delegates through. Unknown keys in trialParams are surfaced via
AppLog.warn so schema drift between optimizer runs stays visible.
```

### COMMIT B3-2: StrategyCard-Widget

**Files:**
- `lib/ui/widgets/strategy_card.dart` (neu):
  - Stateless, nimmt `StrategyKind` + `BacktestProvider` (via context.watch)
  - Header: displayLabel + Category-Badge + "Active"-Indicator wenn `provider.config.strategyKind == kind`
  - Body: kompakte Param-Liste (3-5 wichtigste Params per `Wrap` mit kleinen Chips)
    - z.B. für BB+RSI: `bb_period=200`, `rsi_period=14`, `adx_filter=on`
  - Footer: 3 Buttons
    - **"Activate"** (nur wenn nicht aktiv): `provider.setStrategyKind(kind)`
    - **"Apply Trial"** (immer enabled): öffnet `ApplyTrialDialog` (B3-3)
    - **"Reset"** (nur wenn `_usingOptimizedParams` oder Params != Defaults): `provider.resetParamsToDefaults()`
  - "Optimized params active" Hinweis wenn `_usingOptimizedParams && active`

**Tests:**
- `test/ui/widgets/strategy_card_test.dart`:
  - Render mit/ohne active
  - Activate-Button switched provider
  - Reset-Button setzt Defaults
  - Apply-Button öffnet Dialog (Mock via show callback)

**Commit msg:**
```
feat(phase-O3-B3): strategy card widget with activate/apply/reset

Renders a card per StrategyKind that watches BacktestProvider for
the active strategy + current params. Three actions: Activate (when
not active), Apply Trial (always, opens dialog), Reset (when params
differ from defaults). Active card surfaces the "optimized params
active" indicator.
```

### COMMIT B3-3: ApplyTrialDialog

**Files:**
- `lib/ui/widgets/apply_trial_dialog.dart` (neu):
  - `showApplyTrialDialog(BuildContext, StrategyKind targetKind) → Future<void>`
  - Dialog-Body (eigener `StatefulWidget`):
    1. DB-Picker (file_picker) — Filter-Vorschlag: nur DBs deren Filename `targetKind.name` enthält
    2. Studies-Dropdown (falls multi-study DB)
    3. Top-10 Trials-Tabelle (reuse `trials_top10_table.dart` aus B2-4) — readonly
    4. "Apply Selected Trial"-Button → ruft `BacktestProvider.applyTrialAsParams(...)` + schließt Dialog
  - Warnung wenn `selectedStudy.strategy != targetKind.name`: User darf trotzdem applien (z.B. ut_bot-zerofee auf ut_bot)
  - Internally instanziiert eigene `StudiesDb`-Instanz (NICHT die globale `StudiesProvider` — keine Cross-Talk zum Studies-Tab)

**Tests:**
- `test/ui/widgets/apply_trial_dialog_test.dart`:
  - Dialog rendert mit Empty-State
  - Nach DB-Load: Trials sichtbar
  - Apply-Klick triggert provider.applyTrialAsParams mit korrekten Args
  - strategy-mismatch zeigt Warnung

**Commit msg:**
```
feat(phase-O3-B3): apply-trial dialog with strategy-aware DB filter

Modal dialog opened from a StrategyCard's "Apply Trial" button.
Suggests matching study DBs by filename, lists the top-10 trials,
and on Apply calls BacktestProvider.applyTrialAsParams with the
target StrategyKind and selected trial's params. Mismatched-strategy
selections are allowed but surfaced with a warning to prevent silent
cross-strategy applies.
```

### COMMIT B3-4: StrategyManagementScreen redesign

**Files:**
- `lib/ui/screens/strategy_management_screen.dart`:
  - Komplettes Rewrite — entfernt hardcoded Cards
  - Header: "Strategies" + Subtitle "Apply optimization results to the active backtest"
  - 3 `StrategyCard` (B3-2) nebeneinander auf Wide, vertikal auf Mobile
  - „Open Studies Viewer" Quick-Link (nav zu Studies-Tab)
  - Optional: am Footer ein „Currently active in Backtest: `displayLabel` (params: optimized/default)" Status-Bar
- `lib/main.dart`: keine Änderung (Tab existiert schon)

**Tests:**
- `test/ui/screens/strategy_management_screen_test.dart`:
  - 3 StrategyCard-Widgets rendern
  - Active-Card-Highlight folgt provider state
  - Open-Studies-Quicklink navigiert (verify route push)

**Commit msg:**
```
feat(phase-O3-B3): strategy management screen as apply-trial hub

Replaces the placeholder cards with three live StrategyCards driven
by BacktestProvider. Adds a quick-link to the Studies viewer so the
loop CLI-optimizer → studies → strategy-management → backtest can be
walked without leaving the navigation rail.
```

### COMMIT B3-5: End-to-End Smoke-Test

**Files:**
- `test/integration/strategy_management_smoke_test.dart`:
  - Pump `MaterialApp` mit `BacktestProvider` + Test-Fixture-DB (reuse `test/fixtures/studies_fixture.db` aus B2)
  - 3 Cards sichtbar
  - Tap "Apply Trial" auf UT-Bot-Card → Dialog öffnet
  - Trigger DB-Load (manuell, da file_picker mockbar — direkt provider.loadDb call)
  - Tap erstes Trial → Apply → Dialog schließt
  - `BacktestProvider.config.strategyKind == utBot` & params != defaults

**Commit msg:**
```
test(phase-O3-B3): end-to-end strategy management apply-trial loop

Drives the full B3 path: card render → apply-trial dialog → DB load
→ trial select → BacktestProvider holds the applied params. Verifies
strategy auto-switch and optimized-params indicator transition.
```

---

## 4. Gates pro Commit

| Gate | Erwartung |
|---|---|
| `flutter analyze` | 0 issues |
| `cargo clippy --all-targets -- -D warnings` | 0 warnings (kein Rust-Touch) |
| `cargo test --release` | alle grün (kein Rust-Touch) |
| `flutter test` (gesamt) | alle vorhandenen grün + neue B3-Tests grün |
| `phase1_reference_backtest_test` | **8/8 grün, 91 Trades bit-exakt Dart↔Rust 1e-9** (FROZEN, KRITISCH) |
| `dart_rust_*_parity_test` | alle grün |
| Vorhandene `backtest_provider_test.dart` Tests inkl. deprecated `applyOptimizedParams` | grün |
| Push | Direkt nach grünem Commit |

---

## 5. Eskalations-Stopp

Sofort STOPP + Diagnose-Brief wenn:

- `phase1_reference_backtest` bricht (KRITISCH, immer)
- `applyOptimizedParams` (deprecated wrapper) brichst Backward-Compat-Tests aus B1 → **Wrapper-Logik prüfen, nicht Tests anpassen**
- `*.fromMap` mit echtem Top-10-Trial einer der DBs in `01_Projectplan/optimizer_studies/` produziert NaN/Inf in der Engine → **Mapping-Bug, Diagnose**
- `Int`-Cast mit `.round()` statt `.toInt()` → Off-by-one bei Param-Grenzen → **explizit `.toInt()` testen**
- Apply-Dialog hängt bei file_picker (re-occurring B2-Pattern) → Init-Reihenfolge wieder prüfen
- Strategy-Mismatch-Apply (z.B. BB+RSI-Trial auf UT-Bot-Card) crasht statt Warnung → **fromMap muss fehlende Keys via Defaults füllen, nicht throwen**

---

## 6. Endbericht (nach B3-5)

Brief an QA mit:
1. **5 Commit-Hashes** in Tabelle
2. **Test-Status-Tabelle** (alle Gates, finaler Stand, neue Tests gegenüber B2-Baseline 307)
3. **Manueller Smoke-Test-Aufgabe an Maik:**
   - Start.bat → Strategies-Tab → 3 Cards sichtbar
   - Apply-Trial auf BB+RSI → studies-bb_rsi.db laden → erstes Trial Apply → Backtest-Tab zeigt diese Params
   - Wiederholen für UT-Bot und Ichimoku
   - Cross-Strategy-Apply (BB+RSI-Trial auf UT-Bot) → Warnung wird angezeigt
4. **Push-Status** (alle 5 Commits auf origin/main?)
5. **Anomalien** (z.B. Mapping-Edge-Cases, unerwartete Param-Keys, file_picker-Reibungen)
6. **Empfehlung nächste Welle:**
   - B2.1 (ruvector.db) als next?
   - B4 Paper-Trading-Modul Step-1?
   - A1.1/A1.2 (ADX-Sub-Sweep) als Engineering-Welle?
   - Oder Phase-4-Vorbereitung?

---

## 7. Aufwand & Risiko

- **Geschätzt:** 0.5-1 Session, 3-5h Engineering (kleiner als B1/B2 weil baut auf B2 auf)
- **Hauptrisiko:** Param-Mapping `.toInt()` vs `.round()` — bei BB+RSI `bb_period=200.0` ist trivial, bei Edge-Werten wie `12.9999999` aus älteren Optimizer-Versionen kann es differieren. **Tests müssen Werte direkt aus echten DBs samplen.**
- **Sekundärrisiko:** `Backward-Compat` der deprecated `applyOptimizedParams` — die B1-Tests dürfen nicht brechen.

---

## 8. Sign-off

QA-Koordinator wartet auf Maik-Sign-off bevor dieser Brief an parallel-CC weitergereicht wird.
