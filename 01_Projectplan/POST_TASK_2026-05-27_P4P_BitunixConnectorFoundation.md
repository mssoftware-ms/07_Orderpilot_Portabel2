# Post-Task Welle P4P (Phase-4-Prep) — Bitunix Futures Connector Foundation

**Issued:** 2026-05-27 by parallel-CC (WSL2)
**Recipient:** QA-Koordinator (Windows-CC) / Maik
**Branch:** `main` (alle 5 Commits gepusht auf `origin/main`)
**Base:** `2fe4121` (pre-task brief commit)
**Target exchange:** Bitunix Futures (`https://fapi.bitunix.com`) — read-only only

---

## 1. Commit-Hashes

| Commit | Hash | Subject |
|---|---|---|
| P4P-1 | `32e6ef7` | feat(phase-P4P-1): Bitunix futures double-SHA-256 signer + secure storage |
| P4P-2 | `03618fd` | feat(phase-P4P-2): Bitunix futures REST client (read-only + order stubs) |
| P4P-3 | `126f281` | feat(phase-P4P-3): BitunixConnectionProvider state for read-only sync |
| P4P-4 | `a36580a` | feat(phase-P4P-4): Account screen with read-only sync + disabled live toggle |
| P4P-5 | `01e36cc` | test(phase-P4P-5): end-to-end smoke + hard live-disabled guarantee |

Alle 5 Commits sind atomar, jeder läuft solo grün und ist auf `origin/main` gepusht (`git log 2fe4121..HEAD` listet exakt diese 5).

---

## 2. Test-Status

### Finale Gates (nach P4P-5)

| Gate | Stand | Detail |
|---|---|---|
| `flutter analyze lib/ test/` | ✅ Clean | 0 issues |
| `flutter test` (gesamt) | ✅ **483 passed**, 0 failed, 34 skipped | +66 ggü. B4.2-Baseline (417) |
| `phase1_reference_backtest_test` | ✅ **8/8 grün** | Frozen-Contract intakt — kein Rust-/Strategy-Touch in P4P |
| `dart_rust_parity_test` (BB+RSI) | ✅ grün | unverändert |
| `dart_rust_ut_bot_parity_test` | ✅ grün | unverändert |
| `dart_rust_ichimoku_parity_test` | ✅ grün | unverändert |
| `f06_model_unification_test` | ✅ grün | unverändert |
| `cargo clippy --all-targets -- -D warnings` | ✅ 0 warnings | (kein Rust-Touch in P4P) |
| `cargo test --release` | ✅ 3 passed, 0 failed | (kein Rust-Touch in P4P) |
| **Live-Disabled-Regression** | ✅ 9 Tests pinned | `placeOrder` + `cancelOrder` werfen unconditional in jeder Konfiguration |
| B1..B4.2 Bestand | ✅ grün | unverändert |

### Neue P4P-Tests (zur Baseline 417)

| Datei | Tests | Status |
|---|---|---|
| `test/services/bitunix_auth_test.dart` | 14 | ✅ alle grün |
| `test/services/bitunix_client_test.dart` | 17 | ✅ alle grün |
| `test/features/exchange/bitunix_connection_provider_test.dart` | 14 | ✅ alle grün |
| `test/ui/screens/account_screen_test.dart` | 12 | ✅ alle grün |
| `test/services/bitunix_live_disabled_test.dart` | 8 | ✅ alle grün |
| `test/integration/bitunix_connector_smoke_test.dart` | 1 (E2E) | ✅ grün |
| **Total neu** | **66** | |

417 + 66 = 483 ✓ (deckt sich mit `flutter test`-Endergebnis).

---

## 3. Manuelle Smoke-Test-Aufgabe an Maik

Bitte über `Start.bat` (Windows) den Account-Flow einmal durchgehen — **read-only Test-API-Key/Secret** verwenden (oder eines neu mit `nur` Read-Permissions in der Bitunix-Konsole anlegen):

1. **Tab "Account" öffnen** (siebter Tab, Icon `account_balance_wallet`) → leerer Zustand: Credentials-Card prominent, Status = "Disconnected".
2. **API Key + Secret eingeben** → "Save & Connect" tappen.
3. **Erwarteter Verlauf:** Status springt kurz auf "Connecting…" (warningAmber), dann "Connected" (bullGreen) wenn die Credentials gültig sind.
4. **Balance-Card** erscheint (Available/Frozen/Margin/Transferable/Unrealized PnL/Position mode).
5. **Open-Positions-Card** erscheint (DataTable, leer wenn keine offenen Positionen — sonst Symbol/Side/Qty/Entry/Lev/PnL).
6. **Live-Trading-Card:**
   - Switch ist **disabled** (grau, nicht tappbar).
   - "Step-3 pending"-Pill (warningAmber) ist sichtbar oben rechts.
   - Hover über den Switch → Tooltip *"Live trading requires Welle B4 Step-3 risk layer (kill-switch, daily-loss cap). Currently disabled."*
   - Tap-Versuch auf den Switch ändert NICHTS.
7. **"Test Connection" tappen** (Refresh-Icon im Status-Card) → Last-sync-Timestamp aktualisiert sich.
8. **"Clear stored" tappen** → Status → "Disconnected", Cards weg, Secure-Storage geleert.

### Erwartete Anomalien beim ersten Probelauf

- **Endpoint-Schema-Drift:** Sollte Bitunix andere Field-Namen in `data` als die in `bitunix_models.dart` erwarteten liefern (z.B. `walletBalance` statt `available`), bleiben die UI-Felder als `—`. Kein Crash. Bitte Screenshot vom JSON-Body schicken (DevTools-Network-Tab oder `AppLog` "BitunixClient: Expected …" Einträge) — wir patchen `fromJson` flexibler.
- **DPAPI-Stabilität:** `flutter_secure_storage` läuft auf Windows-Desktop über DPAPI. Sollte beim ersten `Save & Connect` ein nativer Crash auftauchen (rare race bei DPAPI-Init), gibt es zwei Fallback-Optionen: (a) App neu starten und nochmal probieren — DPAPI initialisiert beim zweiten Versuch meist sauber; (b) wir bauen den `encrypt` + Master-Password-Fallback ein (geplant, falls reproducible).

---

## 4. Push-Status

| Commit | gepusht auf `origin/main`? |
|---|---|
| `32e6ef7` P4P-1 | ✅ |
| `03618fd` P4P-2 | ✅ |
| `126f281` P4P-3 | ✅ |
| `a36580a` P4P-4 | ✅ |
| `01e36cc` P4P-5 | ✅ |

`git status` ist clean (außer `.claude/` und `01_Projectplan/POST_TASK_2026-05-27_P4P_*.md` selbst). Maiks `.xlsx` nicht angefasst.

---

## 5. Anomalien & Diskussionspunkte

### 5.1 Signing-Algo-Verifikation — bestanden ✓

Der Bitunix-Sign-Algorithmus wurde gegen die offizielle Doc verifiziert (`https://www.bitunix.com/api-docs/futures/common/sign.html`). Das Python-Beispiel der Doc reproduziert den Hash `00397cd1e52c7dce3258067324363b6361fabc9178a0912b330c138db8745655`. Unsere Dart-Implementierung in `BitunixSigner.sign()` liefert exakt diesen Hash für identische Inputs — gepinnt als Regression-Test `BitunixSigner reproduces the doc Python-example sign hash`.

**Wichtig:** digest1 wird als **Hex-String** in den zweiten SHA-256 gespeist (nicht als raw bytes). Body-Whitespace wird vor dem Signing entfernt (`BitunixSigner.stripBodyWhitespace`). Nonce: 32 Hex-Chars (128-bit Entropie). Timestamp: Unix-ms UTC.

### 5.2 Endpoint-Pfade — verifiziert ✓

Die best-guess-Endpoint-Pfade aus dem Pre-Task wurden gegen die echte Doc geprüft und korrigiert:

| Pre-Task best-guess | Verifizierter Pfad | Status |
|---|---|---|
| `/api/v1/futures/account` | `/api/v1/futures/account?marginCoin=USDT` | ✓ exakt, `marginCoin` required |
| `/api/v1/futures/position` | `/api/v1/futures/position/get_pending_positions` | korrigiert |
| `/api/v1/futures/order/get_pending_orders` | `/api/v1/futures/trade/get_pending_orders` | korrigiert (`trade/`, nicht `order/`) |

Response-Schemas wurden gegen die Doc-Samples verifiziert. `data` ist bei Balance/Positions ein Array, bei Orders ein Objekt mit `orderList`/`total`. Unsere Models tolerieren fehlende Felder (Forward-Compat).

### 5.3 flutter_secure_storage — auf `^9.2.4` gepinnt

Pre-Task hat `^9.0.0` vorgeschlagen. Stable ist aktuell `10.3.1` (publiziert vor 6h), aber Major-Bump → potenziell breaking. Wir pinnen konservativ auf `^9.2.4` (letzte stable in der 9-Serie). Wenn Maik einen 10.x-Crash auf Windows sieht, würden wir den Bump erwägen.

### 5.4 Live-Toggle-Belt-and-Braces

Drei Schichten verhindern accidentales Enable:
1. `BitunixConnectionProvider.liveTradingEnabled` ist ein hardcoded `false` Getter — kein Setter, keine Field-Backing.
2. Im `AccountScreen` ist `liveEnabled` eine `const bool liveEnabled = false;` lokal — auch ohne Provider-Read.
3. Der `SwitchListTile.onChanged: null` macht das Widget strukturell non-interaktiv.

Der CRITICAL Widget-Regression-Test (`account_screen_test.dart`: "switch stays disabled even when successfully connected") asserts alle drei Schichten nach einem erfolgreichen Connect. Der pinned-contract-Test (`bitunix_live_disabled_test.dart`) deckt `placeOrder` + `cancelOrder` mit 8 Szenarien ab.

### 5.5 Auth-Tests gegen Production — Bitunix hat KEIN Sandbox

Per Bitunix-Doc gibt es kein offizielles Testnet für Futures. Read-only Calls (`getAccountBalance` / `getOpenPositions` / `getOpenOrders`) sind risikofrei, sie modifizieren nichts. Live-Calls (`placeOrder` / `cancelOrder`) sind via Stubs blockiert. Daher: **bei P4P keine Risk-Exposure**, auch nicht beim manuellen Smoke-Test (Schritt 3 in Section 3).

### 5.6 Credentials-Maskierung

`BitunixCredentials.toString()` gibt `BitunixCredentials(apiKey: ***, secret: ***)` zurück — die echten Werte erscheinen NICHT im `AppLog`/Stack-Trace, auch nicht bei `'$creds'`-String-Interpolation. Zwei Regression-Tests pinnen dieses Verhalten (`toString never exposes`, `string interpolation does not leak`). Sollte ein Stack-Trace doch mal die Werte enthalten, lässt sich ein expliziter Filter in `AppLog._emit` einbauen — bisher nicht nötig.

---

## 6. Empfehlung nächste Welle

| Welle | Priorität | Begründung |
|---|---|---|
| **B4 Step-3 (Risk-Layer / Kill-Switch / Daily-Loss-Cap)** | 🔴 **dringend** | Ist hartes Pre-Requisite für jedes Live-Mode-Enable. Solange nicht da, bleiben die Order-Stubs in P4P-2 hardcoded. |
| P4P Step-2 (WebSocket User-Streams) | 🟡 mittel | Würde live-Position-/Order-Updates ohne Polling liefern. Sinnvoll erst nach B4 Step-3, weil Live-Updates ohne Live-Mode wenig Wert haben. |
| Chart-Tab Fertigstellung | 🟡 mittel | Längerfristig spürbarer UX-Gewinn als die Account-Tab-Polish. |
| A1.1 / A1.2 ADX-Sub-Sweep | 🟢 niedrig | Strategy-Tuning; orthogonal zum P4-Track. |

**Konkrete Empfehlung:** **B4 Step-3** als nächste Welle. Begründung:
- Ohne Risk-Layer kann der Live-Toggle in der UI nie freigeschaltet werden — die gesamte P4P-Foundation ist erst dann produktiv nutzbar.
- B4 Step-3 fügt KEIN Exchange-Risiko hinzu, weil es auf dem Paper-Trading-Provider arbeitet. Ist also relativ sicher.
- Es ist ein klar abgegrenzter Block (Kill-Switch + Daily-Loss-Cap + UI-Hooks), wahrscheinlich 3-4 atomare Commits.

---

## 7. Schluss

Alle Pre-Task-Eskalations-Stopps wurden ohne Trigger durchlaufen:
- ✓ Signing reproduziert den known-good Hash (P4P-1).
- ✓ `phase1_reference_backtest` bleibt 8/8 grün.
- ✓ `flutter_secure_storage` läuft (verifiziert via unit tests mit InMemory-Backend; Native-Plugin auf Windows ist im Smoke-Test zu validieren).
- ✓ Live-Toggle bleibt strukturell disabled — CI fängt jede Regression.
- ✓ Keine Credential-Leaks in Logs/Stack-Traces.
- ✓ Bitunix-Endpoint-Pfade nach Doc-Verifikation korrigiert.

Welle P4P abgeschlossen. Warte auf Maiks manuellen Smoke-Test, danach kann B4 Step-3 angepackt werden.
