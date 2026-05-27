# Pre-Task Welle P4P (Phase-4-Prep) Step-1 — Bitunix Futures Connector Foundation

**Issued:** 2026-05-27 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem
**Base:** `65f6546` (origin/main, inkl. B4.2 Step-2 Smoke-Test)
**Target exchange:** **Bitunix Futures** (`https://fapi.bitunix.com`) — Maiks Hinweis-URL

---

## ⚠️ Vorwort — Risiko-Kontext und Code-Skizzen-Disclaimer

Dies ist die erste Welle, die echte Exchange-API berührt. Selbst read-only Calls treffen Production-Endpoints — **kein offizielles Bitunix-Testnet bekannt**. Konsequenzen für den Brief:

- **Live-Order-Pfade sind in dieser Welle dauerhaft NICHT funktional.** `placeOrder` / `cancelOrder` werfen `LiveTradingDisabledException`. Step-3 (Risk-Limits / Kill-Switch) MUSS davor sein.
- Auth-Tests gegen Production sind read-only (`getBalance`, `getPositions`, `getOpenOrders`) — risikofrei, modifizieren nichts.
- Secret-Storage muss platform-secure sein (DPAPI auf Windows, Keychain auf macOS, libsecret auf Linux via `flutter_secure_storage`).

Code-Skizzen in diesem Brief sind weiterhin **unverifizierte Hypothesen** (siehe Memory-Lessons aus B2/B3/B2.1-2). Bitunix-API-spezifische Stellen (Signing-Algo, Endpoint-Paths, Response-Schemas) bitte **vor Implementierung gegen die aktuelle Doc verifizieren**:
- API-Intro: `https://www.bitunix.com/api-docs/futures/common/introduction.html`
- Signing-Doc: `https://www.bitunix.com/api-docs/futures/common/sign.html` (vorher Status-200 prüfen — bei meinem Recherche-Fetch warf die URL einen 404; vermutlich URL-Drift, der parallel-CC findet den aktuellen Pfad)
- WebSocket-Doc: über das Navigations-Menü auf der API-Doc-Seite

---

## 1. Scope

**Foundation für den späteren Live-Trading-Connector** — schafft Auth, Read-Only-Account-Sichtbarkeit und einen Stub-Order-Layer hinter mehreren Flags. Kein einziger Live-Trade wird ausgelöst.

**In Scope:**
- Bitunix Futures **REST-Auth-Layer** (Double-SHA-256-Signing, kein HMAC)
- **Secrets-Storage** für API-Key + Secret via `flutter_secure_storage`
- **Read-Only-REST-Calls**: `getAccountBalance`, `getOpenPositions`, `getOpenOrders`
- **Order-Stubs**: `placeOrder` / `cancelOrder` werfen `LiveTradingDisabledException`
- **Account-Screen / Settings-Tab**: Key-Eingabe, „Test Connection", Balance/Positionen Read-Only-Anzeige
- **Live-Toggle**: in dieser Welle **dauerhaft disabled** mit Tooltip *„Pending Risk-Layer (Welle B4 Step-3)"*
- Strikte Trennung: PaperTradingProvider bleibt komplett unberührt, kein Bitunix-Aufruf von der Paper-Seite

**Out-of-Scope** (spätere P4-Wellen):
- Tatsächliches Live-Order-Routing (P4 Step-2 nach B4 Step-3)
- Order-Lifecycle-Tracking, Position-Sync zwischen App ↔ Exchange (P4 Step-2)
- WebSocket-User-Streams (eigene Welle P4 Step-3 mit reconnect/private-channel-auth)
- OCO-Orders, Bracket-Orders, Conditional-Orders (später)
- Multi-Exchange-Support (nur Bitunix, nicht abstrahiert auf generisches `ExchangeAdapter`-Interface — kommt wenn ein zweiter Connector dazu)

---

## 2. Kontext

### Bitunix Futures API — aktuelle Erkenntnisse (Stand 2026-05-27, **verifizieren!**)

| Aspekt | Wert |
|---|---|
| Base REST | `https://fapi.bitunix.com` |
| WebSocket | Doc-Navigation, nicht im Intro-Endpoint genannt — parallel-CC sucht aktuellen Pfad |
| Auth-Header | `api-key`, `nonce` (32-bit random string), `timestamp` (ms UTC), `sign`, `Content-Type: application/json` |
| Signing | **Double SHA-256** (nicht HMAC): `sign = SHA256(SHA256(nonce + timestamp + api-key + queryParams + body) + secretKey)`, Body mit allen Spaces entfernt |
| Timestamp-Toleranz | ±60s sonst rejected |
| Testnet/Sandbox | **Kein offizielles bekannt** — Auth-Tests gegen Production (read-only) |
| Fees (per Memory) | VIP0 Taker 0.06 %, Maker 0.02 % |

### Vorhandener Code

- **`lib/services/binance_websocket.dart`** (B4-1): Vorbild für WebSocket-Patterns (Reconnect, Status-Stream). Bitunix-WS kommt eigene Welle, hier nur als Referenz für Patterns.
- **`lib/services/binance_api_client.dart`**: Vorbild für REST-Client-Struktur (Retry, Exponential-Backoff, Logging via `AppLog`).
- **`lib/core/logging/app_log.dart`**: Auth-Fehler / Connection-Probleme dort routen.
- **`lib/core/constants/app_constants.dart`**: vermutlich passende Stelle für Bitunix-URL-Konstanten.
- **Kein `lib/services/websocket_client.dart` mehr** (laut Glob — Memory-Audit `260522_0246` markierte einen alten `BitunixWebSocketClient` als Dead Code, der wurde inzwischen entfernt). Diese Welle baut neu, **nicht reanimieren**.

### Neue Dependencies

```yaml
dependencies:
  # Secure storage of API credentials (DPAPI/Keychain/libsecret)
  flutter_secure_storage: ^9.0.0
  # SHA-256 hashing for the Bitunix double-hash signature
  crypto: ^3.0.3
```

**Vor B4P-1 verifizieren:** `flutter_secure_storage ^9.0.0` Windows-Desktop-Support — die Package-Doc bestätigen, sonst Fallback auf encrypted file via `encrypt` package + Master-Password-Prompt.

### Signing-Beispiel (skizze, unverifiziert)

```dart
String sign({
  required String nonce,
  required int timestampMs,
  required String apiKey,
  required String queryParams,   // sorted, ASCII-ascending, "key1value1key2value2"
  required String body,           // JSON, all whitespace removed
  required String secretKey,
}) {
  final digest1Input = '$nonce$timestampMs$apiKey$queryParams$body';
  final digest1 = sha256.convert(utf8.encode(digest1Input)).toString();   // hex
  final digest2 = sha256.convert(utf8.encode(digest1 + secretKey)).toString();
  return digest2;
}
```

**Verifizierungs-Pflicht:** Bitunix-Doc liefert (vermutlich) ein Reference-Example mit bekannten Input → Output. Test muss das matchen, sonst sind alle Calls rejected.

---

## 3. Commit-Plan (5 atomare Commits)

### COMMIT P4P-1: Bitunix Auth-Signer + Secrets-Storage

**Files:**
- `pubspec.yaml`: `flutter_secure_storage`, `crypto` (+ ggf. `encrypt` als Fallback)
- `lib/services/bitunix_auth.dart` (neu):
  - `class BitunixCredentials { String apiKey; String secret; }` (immutable)
  - `class BitunixSigner` mit `static String sign({nonce, timestampMs, apiKey, queryParams, body, secretKey})`
  - `class BitunixSecretsStore` mit `Future<void> save(BitunixCredentials)`, `Future<BitunixCredentials?> load()`, `Future<void> clear()` — wrappt `flutter_secure_storage`
  - **Strikt:** Credentials werden **nie** geloggt (auch nicht in `AppLog.warn`/`error` — Stack-Traces müssen Credentials maskieren wenn sie versehentlich durchschlagen)
- `lib/core/constants/app_constants.dart`: `bitunixFuturesBaseUrl = 'https://fapi.bitunix.com'`

**Tests:**
- `test/services/bitunix_auth_test.dart`:
  - **Test: Sign reproduces a known-good hash** — gegen Bitunix-Doc-Example (parallel-CC erstellt den Test mit den von der Doc gelieferten Werten; **wenn die Doc kein Example liefert: Test gegen einen selbst-fixierten Wert, der mit einer unabhängigen Python/Node-SHA256-Implementierung verifiziert wurde** — Memory-Hint)
  - **Test: empty body still produces deterministic sign** (Edge: GET-Requests ohne body)
  - **Test: BitunixSecretsStore roundtrip** (save → load → match)
  - **Test: BitunixSecretsStore clear** (load nach clear == null)

**Pattern-Referenz:** keine direkte — fresh code. `crypto` package ist Standard-Flutter.

**Eskalations-Pfad:** Wenn `flutter_secure_storage` auf Windows-Desktop crashed (bekannte Race-Condition mit DPAPI bei manchen Setups): in den Endbericht aufnehmen, parallel-CC darf `encrypt` + Master-Password-Prompt als Fallback einbauen. Andere Tests bleiben grün.

**Commit msg:**
```
feat(phase-P4P-1): Bitunix futures double-SHA-256 signer + secure storage

Adds the auth foundation for the future Bitunix futures connector:
double-SHA-256 signing (sign = SHA256(SHA256(nonce+ts+key+qs+body)+secret))
against the documented algorithm, and a flutter_secure_storage wrapper
that keeps the API key/secret out of the source tree and out of any
log output. Credentials never appear in toString / AppLog payloads —
a regression test asserts this contract.
```

---

### COMMIT P4P-2: Bitunix REST Client (read-only + order stubs)

**Files:**
- `lib/services/bitunix_client.dart` (neu):
  - `class BitunixClient` mit Konstruktor `BitunixClient(BitunixCredentials creds, {http.Client? httpClient})` für Test-Injection
  - Methoden (alle async, alle nutzen `BitunixSigner` + Bitunix-Headers):
    - `Future<BitunixBalance> getAccountBalance()` — `GET /api/v1/futures/account`
    - `Future<List<BitunixPosition>> getOpenPositions()` — `GET /api/v1/futures/position`
    - `Future<List<BitunixOrder>> getOpenOrders()` — `GET /api/v1/futures/order/get_pending_orders`
    - `Future<void> placeOrder(...)` — **throw `LiveTradingDisabledException('Live trading enabled requires Welle B4 Step-3 Risk-Layer')`**
    - `Future<void> cancelOrder(...)` — **gleiches throw**
  - Endpoint-Paths sind **best-guess basierend auf typischen Futures-API-Konventionen** — parallel-CC verifiziert die exakten Pfade gegen die Doc; bei Drift Endbericht-Hinweis
  - Retry-Logic + AppLog.warn bei Network-Errors (Pattern wie `BinanceApiClient`)
- `lib/core/models/bitunix_models.dart` (neu): `BitunixBalance`, `BitunixPosition`, `BitunixOrder` als immutable Dart-Klassen mit `fromJson` factory
- `lib/services/bitunix_exceptions.dart` (neu): `LiveTradingDisabledException`, `BitunixApiException(statusCode, message, body)`, `BitunixAuthException(message)`

**Tests:**
- `test/services/bitunix_client_test.dart`:
  - **Test: getAccountBalance with mock HTTP returns parsed BitunixBalance** — Fixture-JSON aus Bitunix-Doc-Example (oder selbst-erfunden mit dokumentiertem Schema)
  - **Test: getOpenPositions parses list correctly**
  - **Test: getOpenOrders parses list correctly**
  - **Test: placeOrder throws LiveTradingDisabledException unconditionally**
  - **Test: cancelOrder throws LiveTradingDisabledException unconditionally**
  - **Test: 401/403 throws BitunixAuthException with friendly message**
  - **Test: 5xx triggers retry with backoff** (Pattern aus binance_api_client_test.dart)

**Pattern-Referenz:** `lib/services/binance_api_client.dart` für Client-Struktur, Retry, AppLog. **Aber:** Bitunix-Auth-Headers sind anders als Binance-Auth-Headers — nicht 1:1 kopieren.

**Commit msg:**
```
feat(phase-P4P-2): Bitunix futures REST client (read-only + order stubs)

Read-only endpoints for account/positions/orders backed by the P4P-1
auth layer, plus deliberate stubs for placeOrder/cancelOrder that
throw LiveTradingDisabledException. Order routing stays gated behind
the Step-3 risk layer; this commit only proves we can authenticate
and read state. Endpoint paths are documented inline and TODO-marked
for verification against the live Bitunix doc if they drift.
```

---

### COMMIT P4P-3: BitunixConnectionProvider (state)

**Files:**
- `lib/features/exchange/bitunix_connection_provider.dart` (neu):
  - `ChangeNotifier`
  - State: `BitunixCredentials?`, `BitunixConnectionStatus { disconnected, connecting, connected, error }`, `errorMessage`, `BitunixBalance?` (last fetched), `List<BitunixPosition>` (last fetched), `List<BitunixOrder>` (last fetched), `DateTime? lastSyncAt`
  - Methoden: `Future<void> loadStoredCredentials()`, `Future<void> connect(BitunixCredentials creds)`, `Future<void> disconnect()`, `Future<void> refresh()` (re-fetch balance + positions + orders)
  - Alle async-Pfade in try/catch → `AppLog.error` + `errorMessage`
- `lib/main.dart`: ChangeNotifierProvider eingehängt

**Tests:**
- `test/features/exchange/bitunix_connection_provider_test.dart`:
  - **Test: connect success** — Mock-Client returns balance, status transitioniert disconnected → connecting → connected
  - **Test: connect with bad creds** — Mock-Client throws BitunixAuthException, status → error, AppLog.error fired
  - **Test: refresh updates lastSyncAt and overwrites previous state**
  - **Test: disconnect clears all state including in-memory credentials**
  - **Test: loadStoredCredentials returns null when no stored** (provider init can call this safely)

**Pattern-Referenz:** `lib/features/paper/paper_trading_provider.dart` für ChangeNotifier-Struktur, `lib/features/studies/studies_provider.dart` für load-then-fetch-Pattern.

**Commit msg:**
```
feat(phase-P4P-3): BitunixConnectionProvider state for read-only sync

Tracks connection status, last-fetched balance/positions/orders, and
the last sync timestamp. Connect/disconnect/refresh route through the
P4P-2 REST client and surface auth failures via AppLog.error + a
user-friendly errorMessage. No order-routing paths exist here —
those stay in BitunixClient as throwing stubs.
```

---

### COMMIT P4P-4: Account-Screen + Settings + Live-Toggle (disabled)

**Files:**
- `lib/ui/screens/account_screen.dart` (neu): „Account" Tab
  - Section A: **Credentials-Card** — API-Key Input (visible), Secret Input (passwort-style, obscureText), Save-Button (ruft BitunixSecretsStore.save + connect), Clear-Button
  - Section B: **Connection-Status-Card** — Disconnected/Connecting/Connected/Error mit Farbpunkt, „Test Connection"-Button (= refresh), letztes Sync-Timestamp
  - Section C: **Balance-Card** — Wallet-Balance, Available-Balance, Unrealized-PnL (nur wenn Connected)
  - Section D: **Open-Positions-Card** — DataTable mit Symbol/Side/Quantity/Entry/Mark/PnL (nur wenn Connected)
  - Section E: **Live-Trading-Card** — **Switch dauerhaft `value: false`, `onChanged: null`** + Tooltip *„Live trading requires Welle B4 Step-3 Risk-Layer (Kill-Switch, Daily-Loss-Cap). Currently disabled."* + Step-3-Pending-Hinweis als rote Pille
- `lib/main.dart`: 7. Tab „Account" mit `Icons.account_balance_wallet_outlined` / `Icons.account_balance_wallet`, einsortiert zwischen Strategies und (kein weiterer Tab); plus `AppTab.account` Enum-Eintrag (siehe Memory `project_app_navigation.md` — Enum + _screens + _navItems synchron halten)

**Tests:**
- `test/ui/screens/account_screen_test.dart`:
  - **Test: Empty state shows Credentials-Card prominent** (kein Connected-Indicator, Sections C+D nicht da)
  - **Test: Save button calls SecretsStore + Provider.connect** (mit Mock-Provider)
  - **Test: Live-Toggle is always disabled regardless of connection status** — sowohl bei disconnected als auch bei connected zeigt der Switch `enabled: false`. **KRITISCHER Regression-Guard:** ohne Step-3-Risk-Layer darf der Toggle nie aktivierbar werden.
  - **Test: Tooltip auf Live-Toggle enthält Step-3-Hinweis**
  - **Test: Balance-Card render mit Mock-BitunixBalance**
  - **Test: Position-Card DataTable rendert mit Mock-Liste**

**Pattern-Referenz:** `lib/ui/screens/strategy_management_screen.dart` für Multi-Section-Layout. `lib/ui/widgets/strategy_card.dart` für Card-Komposition. ⚠️ **Sheet-Modals** falls nötig: B2.1-2-Pattern (`isScrollControlled: true`, `useSafeArea: true`, `DraggableScrollableSheet` mit Handle als erstes Kind der ListView — Memory `pretask_lesson_draggable_sheet_handle.md`).

**Commit msg:**
```
feat(phase-P4P-4): Account screen with read-only sync + disabled live toggle

New Account tab carries credential entry, connection test, and read-
only sync of balance/positions/orders. The Live-Trading switch is
hard-disabled with a tooltip pointing at the pending Welle B4 Step-3
risk layer — a regression test asserts the switch stays disabled even
when fully connected, so an accidental enable in the future cannot
slip through.
```

---

### COMMIT P4P-5: End-to-End Smoke + Live-Disabled-Guarantee

**Files:**
- `test/integration/bitunix_connector_smoke_test.dart` (neu):
  - Sequence:
    1. Pump `MaterialApp` mit `BitunixConnectionProvider` + Mock-Client + Mock-SecretsStore
    2. Navigate to Account-Tab
    3. Enter mock-key + mock-secret → Save → Provider.connect ruft Mock-Client → Status → Connected
    4. expect Balance-Card und Position-Card visible mit Mock-Werten
    5. expect Live-Toggle disabled
    6. Try to force-enable Live-Toggle programmatically (z.B. via `tester.tap` auf disabled Switch) → State bleibt unverändert
    7. Clear → State zurück auf disconnected, alle Secrets gelöscht (Mock-Store.load returns null)
- `test/services/bitunix_live_disabled_test.dart` (neu): isolated regression
  - **Test: BitunixClient.placeOrder always throws** — auch wenn man via Reflection / Test-only-Subclass den exception path umgehen will (best effort)
  - **Test: BitunixClient.cancelOrder always throws**

**Commit msg:**
```
test(phase-P4P-5): end-to-end smoke + hard live-disabled guarantee

Drives the full P4P stack with mocks: credential save → connect →
balance + positions visible → live toggle stays disabled. A separate
regression file pins the LiveTradingDisabledException contract on
placeOrder/cancelOrder so the Step-2 enable path can't slip in
silently before the Step-3 risk layer lands.
```

---

## 4. Gates pro Commit

| Gate | Erwartung |
|---|---|
| `flutter analyze` | 0 issues |
| `cargo clippy --all-targets -- -D warnings` | 0 warnings (kein Rust-Touch) |
| `cargo test --release` | alle grün (kein Rust-Touch) |
| `flutter test` (gesamt) | **B4.2-Baseline 417 + neue P4P-Tests grün** |
| `phase1_reference_backtest_test` | 8/8 grün (KRITISCH) |
| `f06_model_unification_test` | grün |
| `dart_rust_*_parity_test` | grün |
| B1/B2/B3/B2.1/B4/B4.2-Bestand-Tests | grün |
| **Live-Disabled-Regression** | `placeOrder` + `cancelOrder` werfen unconditionally |
| Push direkt nach grünem Commit | ✓ |

---

## 5. Eskalations-Stopp

- `phase1_reference_backtest` bricht: KRITISCH, STOPP
- **Signing reproduziert nicht den Bitunix-Doc-Example-Hash:** STOPP, alle weiteren Calls würden 401-rejected. Doc-Pfad nochmal verifizieren, ggf. alternativen Signing-Pfad probieren (z.B. SHA-256 mit anderen Field-Reihenfolge).
- `flutter_secure_storage` auf Windows-Desktop crashed beim ersten `save` oder `load`: Fallback auf `encrypt` + Master-Password-Prompt einbauen, im Endbericht erwähnen.
- **Live-Toggle wird versehentlich enable-bar:** sofort STOPP (sicherheitskritisch). Test in P4P-4 muss das schon im CI fangen.
- Bitunix-Response-Schema weicht von den dokumentierten Feldern ab (z.B. `balance` statt `walletBalance`): in `BitunixBalance.fromJson` flexibel parsen, Endbericht mit Diff-Hinweis.
- Read-only-Calls geben in Production-Bitunix bei einem leeren Account 404 statt 200+empty-list zurück: `fromJson` muss das tolerieren, AppLog.warn statt error.
- **Credentials leaken in einem AppLog-Eintrag (auch im StackTrace):** sofort STOPP, AppLog-Filter einbauen der die known-credential-Felder maskiert.

---

## 6. Endbericht (nach P4P-5)

Brief an QA mit:
1. **5 Commit-Hashes** in Tabelle
2. **Test-Status-Tabelle** (alle Gates, neue Tests gegenüber B4.2-Baseline 417)
3. **Manueller Smoke-Test-Aufgabe an Maik:**
   - Account-Tab öffnen → leer
   - Test-API-Key + Secret eingeben (Maik hat ein read-only-Test-Konto bei Bitunix oder erstellt eins) → Save
   - "Test Connection" → Connected ✓
   - Balance + Open-Positions sichtbar (auch wenn 0/empty)
   - **Live-Toggle ist disabled, Tooltip zeigt Step-3-Hinweis**
   - Clear → State weg
4. **Push-Status** (alle 5 Commits auf origin/main?)
5. **Anomalien:**
   - Signing-Algo Verifizierungs-Hash-Match?
   - `flutter_secure_storage` Plattform-Stabilität?
   - Endpoint-Path-Drift gegenüber Doc?
   - Response-Schema-Drift?
6. **Empfehlung nächste Welle:**
   - B4 Step-3 (Risk-Layer) — **dringend empfohlen, weil Live-Mode davon abhängt**
   - oder Chart-Tab fertigstellen
   - oder A1.1/A1.2 ADX-Sub-Sweep
   - oder P4P Step-2 (WebSocket-User-Streams für Live-Position-Updates) — empfohlen erst nach Step-3

---

## 7. Aufwand & Risiko

- **Geschätzt:** 7-9h Engineering, 5 Commits (größer als B4.2 wegen Auth-Komplexität und 1× neuer Screen)
- **Hauptrisiko:** **Signing-Algorithmus.** Wenn der Hash nicht stimmt, ist jeder API-Call 401-rejected. Parallel-CC sollte den Test gegen einen mit Python/Node verifizierten Hash machen, bevor er gegen die echte API testet.
- **Sekundärrisiko:** `flutter_secure_storage` Windows-Desktop-Reliability. Bei Crash: encrypt-Fallback dokumentieren.
- **Tertiärrisiko:** Live-Toggle könnte versehentlich aktivierbar werden. Hartcodierter Disable + Test-Regression als Guard.

---

## 8. Sign-off

QA-Koordinator wartet auf Maik-Sign-off bevor dieser Brief an parallel-CC weitergereicht wird.
