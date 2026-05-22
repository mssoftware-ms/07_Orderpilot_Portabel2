# QA-Koordinator-Workflow — OrderPilot Portabel2

**Datum:** 22. Mai 2026 (rev2 — rekonstruiert nach Datenverlust + Anpassungen)
**Geltungsbereich:** Phase 1 (Engine-Korrektheit) und Phase 2 (Strategie-Treue)
**Plan-Referenz:** `01_Projectplan/260522_Gesamtplan_Phase1-3.md` rev2
**QA-Audit:** `260522_0246_QA_AUDIT_REPORT.md` (rekonstruiert)
**Operations-Owner (Coding):** Maik @ Claude Code in WSL2/tmux
**QA / Coordination:** Claude in Desktop-Chat (dieses Dokument lebt hier)

---

## 0. Vorgeschichte und Lessons Learned

Dieses Dokument wurde am 22.05.2026 ~10:51 geschrieben, dann durch eine Branch-Switch-Aktion in GitHub Desktop aus der Working-Copy gelöscht (war nie committed). Wiederhergestellt am 22.05.2026 ~11:30 aus dem Chat-Verlauf. Konsequenz: **GitHub Desktop wird in diesem Repo nicht mehr verwendet.** Alle Git-Operationen ausschließlich über CLI (WSL2 oder PowerShell), und jede neue Datei wird **vor dem nächsten Branch-Switch committed**.

---

## 1. Rollenverteilung

### Was der QA-Koordinator (ich) macht
- Plan-Owner: Plan-Datei wird nur von mir editiert, mit Rationale-Eintrag in Section 12 (Änderungshistorie)
- Pre-Task-Briefing: vor jedem Finding gebe ich dir den genauen Claude-Code-Prompt
- Post-Task-Review: ich prüfe deinen Status-Brief gegen die Akzeptanzkriterien aus dem Plan
- Test-Audit: ist der Test ehrlich? red-then-green nachgewiesen? deckt er den Bug ab oder nur einen Happy-Path?
- Status-Log: ich führe die Tabelle in Section 7 dieses Dokuments
- Eskalation: ich blockiere Phase-Wechsel wenn Akzeptanz nicht voll erfüllt
- Plan-Drift-Schutz: weicht ein Brief unkommentiert vom Plan ab → STOPP

### Was der QA-Koordinator NICHT macht
- Code schreiben (das macht Claude Code in deiner tmux-Session)
- Tests schreiben (Claude Code; ich review nur)
- Direkte Commits ins Repo
- Live-Trading-Entscheidungen
- Strategie-Wahl (du als User)

### Was Claude Code (Operations) macht
- Branches anlegen, Code editieren, Tests schreiben, Commits
- TDD strikt: Test red → Fix green → Refactor → Commit
- Brief schreiben nach jedem Finding (Template Section 4)
- Bei Unklarheit: stoppt und fragt dich, nicht improvisieren

---

## 2. Datei-Anker (was Claude Code zu Beginn jeder Session laden muss)

```bash
cd /mnt/d/03_Git/02_Python/07_Orderpilot_Portabel2
claude code
> /add 01_Projectplan/260522_Gesamtplan_Phase1-3.md
> /add 01_Projectplan/260522_Workflow_QA_Koordinator.md
> /add 260522_0246_QA_AUDIT_REPORT.md
```

Erst wenn alle drei geladen sind, beginnt Arbeit.

---

## 3. WSL2-Toolchain-Setup (Pre-Phase-1, einmalig)

Da du in WSL2 arbeiten willst (`flutter: command not found` beim Baseline-Run), brauchen wir Flutter und Rust in WSL2:

```bash
# In WSL2:

# 1. Flutter installieren (Linux-Variante)
cd ~
git clone https://github.com/flutter/flutter.git -b stable
echo 'export PATH="$PATH:$HOME/flutter/bin"' >> ~/.bashrc
source ~/.bashrc
flutter doctor   # zeigt fehlende Linux-Abhängigkeiten

# 2. Linux-Build-Deps für Flutter Desktop (Ubuntu/Debian)
sudo apt update
sudo apt install -y clang cmake git ninja-build pkg-config \
    libgtk-3-dev liblzma-dev libstdc++-12-dev curl unzip xz-utils zip

# 3. Rust installieren
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env

# 4. flutter_rust_bridge_codegen (für F-01)
cargo install flutter_rust_bridge_codegen --version 2.12.0

# 5. Im Projekt-Verzeichnis verifizieren
cd /mnt/d/03_Git/02_Python/07_Orderpilot_Portabel2
flutter --version       # mind. 3.22
cargo --version         # mind. 1.75
flutter pub get
cd rust/trading_engine && cargo build && cd ../..
flutter test 2>&1 | tail -5
cd rust/trading_engine && cargo test 2>&1 | tail -5
```

**Caveat WSL2 + Flutter Desktop:** Linux-GUI-Apps aus WSL2 brauchen WSLg (default ab Windows 11) oder X-Server. Für die reine Test-Suite (`flutter test`) und Backtest-Engine ist GUI nicht nötig — Tests laufen headless. UI-Manual-Test wäre weiterhin auf Windows nativ via `flutter run -d windows` einfacher; aber für Phase 1 ist Test-Suite ausreichend.

**Alternative falls WSL2-Install zu aufwendig:** Toolchain-Aufruf via Windows-Binaries aus WSL2:
```bash
alias flutter='/mnt/c/Users/maiks/dev/flutter/bin/flutter.bat'
alias cargo='/mnt/c/Users/maiks/.cargo/bin/cargo.exe'
```
Diese Variante ist langsamer (Pfad-Translation pro Aufruf), aber spart Disk und Setup. Entscheidung liegt bei dir, wenn du `flutter doctor` durchhast.

---

## 4. Pro-Finding-Workflow

```
1. Maik:  Liest den Finding-Abschnitt im Plan
2. Maik:  Übergibt Claude Code den Pre-Task-Prompt (Section 6 für jedes F-XX)
3. CC:    Wechselt auf den Finding-Branch
4. CC:    Schreibt den Test (red) — committen!
5. CC:    Implementiert den Fix (green) — committen!
6. CC:    Verifiziert manuell die Akzeptanz aus dem Plan
7. CC:    Erstellt Status-Brief (Template Section 5)
8. Maik:  Schickt Brief in den Desktop-Chat
9. Ich:   Review gegen Akzeptanz, dann APPROVE oder REJECT mit konkretem Punkt
10. CC:   Bei APPROVE → Squash-Merge in sprint/phase-1-engine-correct
          Bei REJECT  → Fix der Reject-Punkte, neuer Brief
11. Ich:  Status-Log-Update (Section 8)
```

**Goldregel:** Schritt 4 (Test red) ist nicht optional. Brief muss zeigen, dass der Test ohne Fix gerot ist und mit Fix grün.

**Pre-Commit-Pflicht:** Vor jedem Branch-Switch ALLES committen oder stashen. Niemals Working-Copy mit uncommitted Files lassen wenn der Branch wechselt — genau das war Auslöser unseres Datenverlusts heute Morgen.

---

## 5. Status-Brief Template

Jeder Brief geht in den Desktop-Chat in dieser Form (Markdown):

```
## Brief: F-XX
Branch:        fix/f-XX-…
Commits:       <hash1> Test (red) | <hash2> Fix (green) | <hash3> Refactor
Tests added:   <pfad zur neuen Testdatei>
Test output:
  flutter test: PASS (X/X, Y warnings)
  cargo test:   PASS (X/X)
Test red verifiziert: ja, mit `git checkout <hash1>~1; flutter test` lief der
  Test rot. Output beigefügt: ...
Akzeptanz (Plan §3.4):
  [x] Akzeptanz-Punkt 1 …
  [x] Akzeptanz-Punkt 2 …
  [ ] Akzeptanz-Punkt 3 — offen, weil: …
Manuelle Verifikation: <wie verifiziert, mit Ergebnis>
Offene QA-Frage: keine | <Frage>
```

Wenn ein Punkt nicht erfüllt ist, **muss** er als offen markiert sein. Nicht weglassen.

---

## 6. Pre-Task-Prompts (zum Copy-Paste in Claude Code)

### Setup (vor F-05/F-06)

```
Wir starten Phase 1 nach Plan §10. Aktionen in dieser Reihenfolge:

1. Auf den bestehenden Sprint-Branch wechseln (der existiert schon):
   git fetch origin
   git checkout sprint/phase-1-engine-correct
   git pull --ff-only origin sprint/phase-1-engine-correct
   git merge main --no-ff   # damit der jüngste main-State (Plan/Transkripte)
                            # auch im Sprint-Branch ist
   git push origin sprint/phase-1-engine-correct

2. In lib/services/optimization_service.dart oben die folgenden Zeilen
   einfügen (genauer Wortlaut aus Plan §3.3):

   // =============================================================================
   // FROZEN: Phase 1+2 NOT COMPLETE.
   // Engine bugs (F-02..F-04) and strategy verification (Phase 2) are open.
   // Any results from this service are unreliable until Gesamtplan section 5 unlocked.
   // DO NOT delete, DO NOT use in UI. Re-enable per checklist in Gesamtplan section 5.
   // =============================================================================

3. In allen UI-Aufrufen von OptimizationService: Disabled-State + Tooltip
   "wartet auf Phase 2 (siehe 260522_Gesamtplan_Phase1-3.md §3.3)"

4. flutter analyze && flutter test && cd rust/trading_engine && cargo test
   → ALLES muss grün bleiben

5. git add -A && git commit -m "chore: freeze optimization_service.dart pre-engine-fix"
   git push origin sprint/phase-1-engine-correct

6. Brief an QA mit Commit-Hash und Test-Output.
```

### F-05: Cache-Key Endtime-Rounding

```
F-05 nach Plan §3.4 (Cache-Key Endtime-Rounding).

Branch:  fix/f-05-cache-endtime-rounding (von sprint/phase-1-engine-correct)

git checkout sprint/phase-1-engine-correct
git checkout -b fix/f-05-cache-endtime-rounding

TDD strict:
1. Test schreiben in test/regression/f05_cache_key_stability_test.dart
   — wie im Plan vorgegeben, exakter Code-Snippet.
2. Test laufen lassen, MUSS rot sein. Output speichern.
3. Commit: "test(F-05): cache key stability regression (red)"
4. Fix in lib/services/binance_api_client.dart:
   endMs = (endMs ~/ 3600000) * 3600000
   im _buildCacheKey (oder Pendant).
5. Test grün laufen. Voller Test-Suite-Lauf grün.
6. Manuelle Verifikation: 5× downloadHistory für denselben Range im
   Range einer Stunde → Cache-Verzeichnis hat genau 1 Datei.
7. Commit: "fix(F-05): round cache key endtime to last full hour"
8. Brief an QA nach Template §5.

WICHTIG: Test-Datei niemals nachher umschreiben oder löschen.
```

### F-06: Modell-Konsolidierung

```
F-06 nach Plan §3.4 (Modell-Konsolidierung).

Branch:  refactor/f-06-unify-trade-models (von sprint/phase-1-engine-correct)

Schritte:
1. grep -r "class BacktestMetrics\|class TradeRecord\|class ClosedTrade" lib/
   → exakte Stellen identifizieren, im Brief listen.
2. Test schreiben in test/regression/f06_model_unification_test.dart, der
   prüft dass nur EINE BacktestMetrics-Klasse importierbar ist
   (z.B. via Assertion auf Type-Identity nach Import).
3. Test rot.
4. Lokale TradeRecord und BacktestMetrics in backtest_service.dart löschen.
5. ClosedTrade und BacktestMetrics aus lib/core/models/trade.dart als
   einzige Quelle. RustBacktestMetrics in rust_bridge.dart wird zu DTO mit
   toBacktestMetrics()-Konverter.
6. flutter analyze → 0 Warnungen
7. Alle 59+ Flutter-Tests grün
8. Commit-Sequenz wie F-05.
9. Brief an QA.
```

### F-01: FFI Bridge wiring

```
F-01 nach Plan §3.4 (FFI Bridge wiring). KRITISCH und groß.

Voraussetzung: F-05 und F-06 müssen APPROVED und gemergt sein.

Branch: feat/f-01-wire-frb (von sprint/phase-1-engine-correct)

VOR ARBEITSBEGINN: Stoppe und liefere mir einen PRE-FLIGHT-Brief mit:
  - Welche Version flutter_rust_bridge_codegen ist installiert? (cargo install --list)
  - Welches Target-OS testest du heute? (Linux native via WSL2? Windows via flutter run?)
  - Hat ldd Zugriff auf nötige System-Libs?
  - Gibt es bestehende lib/src/rust/ Files aus früherem Codegen-Versuch?

Erst nach meinem GO arbeiten:

1. Test schreiben: test/integration/dart_rust_parity_test.dart
   — Referenz-Candle-Set (z.B. 100 Candles BTCUSDT 1h January 2024)
   — Run via Dart-Service, run via Rust-Bridge (sobald aktiv)
   — Assert: totalPnl, winRate, finalEquity closeTo mit 1e-9
2. Test rot (weil Rust-Bridge noch nicht aktiv).
3. flutter_rust_bridge_codegen generate
4. Generierte Files unter lib/src/rust/frb_generated.dart einbinden
5. CMakeLists.txt (Linux desktop) anpassen — Rust .so referenzieren
   Falls Windows desktop auch geprüft werden soll: separater Schritt
6. _nativeAvailable von hardcoded false auf async _probeNative() umstellen
7. Codegen-Schritt in Build-Skripte ergänzen
8. Test grün auf WSL2-Linux.
9. Windows-Verification: separater Commit, wenn WSL2 grün.
10. Android: vertagt auf Phase 3.

Brief an QA mit allen 5 Akzeptanz-Punkten aus Plan §3.4 F-01.
```

### F-02: SL/TP Exit-Rules (Dart-Fallback)

```
F-02 nach Plan §3.4 (Stop-Loss / Take-Profit).

Voraussetzung: F-01 APPROVED.

Branch: fix/f-02-sl-tp-exit-rules

1. Rust-Test in rust/trading_engine/tests/regression_f02.rs schreiben:
   - Long-Position, Candle mit low < entry-sl_distance
   - Assert: ExitReason::StopLoss, exit_price ≈ sl_price ± 1e-9
   - Analog: Short + TP-Hit
2. Test grün (Rust-Side war laut QA-Report bereits korrekt — verifiziere!)
   Falls grün on first run → das ist OK, aber dokumentier es im Brief
   damit klar ist dass der Test redundant war.
3. Dart-Test in test/regression/f02_sl_tp_test.dart:
   - Dart BacktestService mit gleichen Inputs
   - Aktuell: rot (Dart hat keine SL/TP-Logik)
4. Fix in lib/services/backtest_service.dart:
   - Pro Candle: low <= sl || high >= tp prüfen
   - Korrekten Exit-Preis + ExitReason setzen
5. Dart-Test grün.
6. Numerical Equivalence Test (aus F-01) weiterhin grün → CRITICAL
   Falls nicht: Dart und Rust haben unterschiedliche SL/TP-Semantik.
   Dann STOPP und Brief an QA mit Diff der Outputs.
7. Brief an QA.
```

### F-03: Sharpe-Annualisierung pro Timeframe

```
F-03 nach Plan §3.4 (Sharpe-Annualisierung).

Branch: fix/f-03-sharpe-tf-annualization
KANN PARALLEL zu F-02 laufen (getrenntes Worktree oder anderer tmux-Pane).

Mathe-Klärung aus Plan §3.4 F-03 ist die kanonische Quelle.

1. Test mit konstruiertem Returns-Stream:
   let returns = construct_returns(mean=0.001, stdev=0.002, n=8760);
   let expected = 0.001 / 0.002 * sqrt(8760);
   assert!((annualized_sharpe(returns, H1) - expected).abs() < 1e-6);
2. Test rot.
3. Implementierung in rust/trading_engine/src/models/metrics.rs:
   - enum Timeframe mit periods_per_year() Methode (1m=525600 .. 1d=365)
   - annualized_sharpe(returns, tf): mean/stdev * sqrt(tf.periods_per_year())
   - Period_returns = Equity-Curve-Returns (NICHT Trade-PnL!)
4. Dart-Pendant in lib/core/models/trade.dart bzw. metrics.dart
5. Numerical Equivalence Test Dart vs Rust grün.
6. Brief an QA.

ACHTUNG: Risk-free Rate = 0 (Crypto, kein Benchmark). NICHT konfigurierbar
machen ohne Plan-Update.
```

### F-04: Look-Ahead Bias + Slippage-Modell (Plan rev2 Defaults!)

```
F-04 nach Plan §3.4 (Look-Ahead Bias). Plan rev2 hat Slippage-Defaults
korrigiert — Default 0, nicht 5!

Voraussetzung: F-02 und F-03 APPROVED.

Branch: fix/f-04-look-ahead-bias

1. Test in tests/regression_f04.rs:
   - Referenz-Candle-Set (BTCUSDT 1h, 2024-H1)
   - Run mit ExecutionMode::CloseSame → PnL_old
   - Run mit ExecutionMode::OpenNext, slippage_bps=0 → PnL_new
   - Assert: PnL_new < PnL_old (Look-Ahead-Removal senkt PnL)
2. Test rot.
3. Fix in rust/trading_engine/src/backtest/mod.rs:
   - Signal Candle i → Execution Open Candle i+1
   - slippage_bps default 0 (Plan rev2 Section §3.4 F-04)
   - fee_rate bleibt separat (existing parameter, default 10 bps)
   - Last-Candle-Edge-Case: Close[N-1] glattstellen
4. Test grün.
5. UI-Default in lib/features/backtest/backtest_provider.dart anpassen:
   slippage_bps=0, fee_rate=10 bps
6. Numerical Equivalence Test grün.
7. Brief an QA.

ACHTUNG: Test ASSERTS dass PnL SINKT. Wenn der Test grün ist OHNE dass
PnL sinkt, hast du den Look-Ahead nicht entfernt. Brief MUSS old_pnl
und new_pnl explizit nennen.
```

### F-07 / F-08: Entscheidung Backtest-only oder Live-Daten

```
F-07 + F-08 nach Plan §3.4. Vor Implementierung: Entscheidungs-Brief.

Brief an QA mit folgenden Punkten beantwortet:
1. Soll die App weiterhin Bitunix-WebSocket-Daten anzeigen können?
   - Wenn nein: BitunixWebSocketClient löschen, Dependencies aus pubspec.yaml
     entfernen, PaperTradingScreen + chart_screen.dart als "in Phase 4"
     gekennzeichnet (Banner).
   - Wenn ja: F-08 ist XL-Task (3-5 Tage). Empfehlung: nach Phase 3.
2. Empfehlung aus Plan: in Phase 1 LÖSCHEN (Backtest-only Fokus),
   Live-Feature nach Phase 3 neu entscheiden.

Erst nach Maiks Entscheidung implementieren.
```

---

## 7. Tag-für-Tag Phase 1 (Idealverlauf)

### Tag 1 — Toolchain + Cache + Models

| Slot | Aktion | Owner |
|---|---|---|
| Vormittag | WSL2 Toolchain-Setup (Section 3 oben) | Maik |
| Vormittag | Setup-Prompt (Section 6 "Setup") | CC |
| Vormittag | F-05 Branch + Test red + Fix + Brief | CC, tmux Pane A |
| Vormittag | F-06 Branch + Test red + Fix + Brief | CC, tmux Pane B |
| Mittag | Briefe in den Desktop-Chat | Maik |
| Mittag | QA-Review beide | Ich |
| Nachmittag | Bei APPROVE: Merge in sprint-Branch, Test-Suite grün | CC |
| Nachmittag | Status-Log update | Ich |

### Tag 2 — FFI Bridge (alleinstehend)

| Slot | Aktion | Owner |
|---|---|---|
| Vormittag | Pre-Flight-Brief F-01 (Toolchain, Targets) | CC → mir |
| Vormittag | GO oder zurück | Ich |
| Tag durch | F-01 Implementation + Tests | CC, single tmux |
| Abend | Brief + QA-Review | Maik / ich |

### Tag 3 — SL/TP und Sharpe (parallel)

| Slot | Aktion | Owner |
|---|---|---|
| Vormittag | F-02 + F-03 Briefs vorab | CC |
| Tag durch | F-02 in Pane A, F-03 in Pane B | CC |
| Abend | Beide Briefe + QA-Review | Maik / ich |

### Tag 4 — Look-Ahead

| Slot | Aktion | Owner |
|---|---|---|
| Vormittag | F-04 (sequenziell, weil auf F-02+F-03 aufbaut) | CC |
| Nachmittag | Brief + QA-Review | Maik / ich |
| Nachmittag | Phase-1-Gate-Check (alle Akzeptanzkriterien §3.5) | Ich |

### Tag 5 — F-07/F-08 Entscheidung + Phase-1-Abschluss

| Slot | Aktion | Owner |
|---|---|---|
| Vormittag | Entscheidungs-Brief F-07/F-08 | CC → Maik → mir |
| Vormittag | Implementation der Entscheidung | CC |
| Mittag | Final Test Suite grün, Tag v0.2.0-engine-correct setzen | CC |
| Nachmittag | Phase 1 Retrospektive | Ich |

---

## 8. Status-Log (wird von mir geführt, Maik kann anhand checken)

| Finding | Branch | Test-Commit | Fix-Commit | QA-Sign-off | Merged in Sprint |
|---|---|---|---|---|---|
| WSL2-Toolchain | — | — | — | — | — |
| Setup (FROZEN-Banner) | sprint/phase-1-engine-correct | — | — | — | — |
| F-05 Cache | fix/f-05-cache-endtime-rounding | — | — | — | — |
| F-06 Models | refactor/f-06-unify-trade-models | — | — | — | — |
| F-01 FFI Bridge | feat/f-01-wire-frb | — | — | — | — |
| F-02 SL/TP | fix/f-02-sl-tp-exit-rules | — | — | — | — |
| F-03 Sharpe | fix/f-03-sharpe-tf-annualization | — | — | — | — |
| F-04 Look-Ahead | fix/f-04-look-ahead-bias | — | — | — | — |
| F-07/F-08 UI Mocks | refactor/f-07-decide-websocket | — | — | — | — |

Status-Werte: APPROVED, REJECTED (mit Punkten), BLOCKED (mit Grund), nicht angefangen.

---

## 9. Eskalations-Regeln (sofortiger STOPP)

Du brichst die Claude-Code-Session ab und schreibst mir, wenn:

1. **Test wird grün ohne dass er vorher rot war.** Bedeutet: Bug existierte gar nicht so wie beschrieben, oder Test ist nicht aussagekräftig. Brief an mich.
2. **Akzeptanz "interpretierbar"** gemacht wird (z.B. „eine Datei pro Range" → „selten zwei Dateien"). Eskalation an mich.
3. **Slippage / Fees / Sharpe-Formel** wird abweichend zum Plan implementiert ohne Rückfrage. Plan §3.4 ist normativ.
4. **optimization_service.dart** wird angefasst (außer FROZEN-Banner). Plan §3.3.
5. **Tests in test/ werden gelöscht, umbenannt oder ihre Assertions abgeschwächt**. Hard NO.
6. **Numerical Equivalence Test Dart vs Rust** wird grün, weil die Toleranz aufgeweicht wurde (von 1e-9 auf 1e-3 etc.). Auch hard NO.
7. **PR enthält Files außerhalb des Finding-Scopes**. Mix-up gehört in eigenen Commit/Branch.
8. **Phase-Sprung-Versuch**: niemand fängt F-02 vor F-01-APPROVED an. Section 7 ist verbindlich.
9. **Cost-Explosion**: wenn eine Claude-Code-Session mehr als ~$15 Token-Cost auf einen Finding nutzt (bei Opus 4.7 selten realistisch außer bei F-01), STOPP und Brief.
10. **Branch-Switch ohne Commit/Stash**: Working-Copy-Inhalt der nicht committed ist, niemals beim Wechsel zurücklassen. Lesson Learned aus heute Morgen.

---

## 10. Phase-1-Gate-Check (Tag 5 oder wann immer alle Findings APPROVED)

Bevor wir Phase 2 starten, fahre ich diese Checkliste durch (entspricht Plan §3.5):

```
[ ] F-01..F-06 Finding-Tests grün, Tests existieren physisch
[ ] 59+ Flutter + 57+ Rust Tests grün (Vollständige Suite)
[ ] Numerical Equivalence Dart vs Rust mit tol=1e-9 grün
[ ] FROZEN-Banner in optimization_service.dart, UI-Disable funktioniert
[ ] flutter analyze: 0 Warnings
[ ] cargo clippy: 0 Warnings
[ ] Reference-Backtest reproduzierbar: BTCUSDT 1h 2024-01-01..2024-06-30, BB+RSI,
    3× Lauf → identische Zahlen (Sharpe, PnL, Win-Rate)
[ ] Git Tag v0.2.0-engine-correct gesetzt
[ ] Sprint-Branch in main gemergt
```

**Nur wenn ALLE Punkte grün:** Plan §3.5 erfüllt → Phase 2 darf starten.

---

## 11. Phase-2-Vorausschau (separates Workflow-Doc folgt)

Phase 2 hat einen anderen Workflow-Charakter (semi-interaktiv, weil Transkript-Lesung):
- 3 Transkripte sind im Repo: `transskript bb+rsi.txt`, `transskript ichimoku cloud retest.txt`, `transskript ut bot alerts.txt`
- Pro Strategie: erst Spec-MD aus Transkript schreiben, dann Diff gegen Code, dann Anpassung mit Test
- Acceptance: Backtest auf XLSX-Referenz-Setup im ±20%-Band

Separates Workflow-Doc bekommst du wenn Phase 1 grün ist. Phase-3-Entscheidung Rust-intern vs. Hermes fällt am Phase-2-Gate.

---

## 12. Sofort jetzt — die ersten 30 Minuten

Reihenfolge:

```bash
# 1. WSL2 Toolchain installieren (Section 3) — kann 15-20 min dauern
#    Flutter clone, Linux-Deps, Rust, flutter_rust_bridge_codegen

# 2. Im Projekt verifizieren dass alles läuft
cd /mnt/d/03_Git/02_Python/07_Orderpilot_Portabel2
flutter doctor
flutter pub get
flutter test 2>&1 | tail -10
cd rust/trading_engine && cargo test 2>&1 | tail -10
cd ../..

# 3. Brief an mich mit:
#    - flutter doctor output (oder zumindest "no issues found")
#    - flutter test ergebnis (X passed, Y failed, Z skipped)
#    - cargo test ergebnis
#    - bestätigt dass Plan + Workflow + QA-Audit gelesen
#    - bestätigt dass Setup-Prompt (Section 6) als nächstes ausgeführt wird
```

Wenn der Baseline-Brief steht und ich "GO Setup" gebe, führst du den Setup-Prompt aus Section 6 dieses Dokuments aus.

---

## 13. Änderungshistorie

| Datum | Änderung | Rationale |
|---|---|---|
| 2026-05-22 10:51 | initial | erste Fassung |
| 2026-05-22 11:30 | rev2 — rekonstruiert | Original durch GitHub-Desktop-Branch-Switch verloren. Neu: WSL2-Toolchain-Section, Section 0 Lessons Learned, Eskalations-Regel 10 (Branch-Switch ohne Commit), Phase-2-Vorausschau mit korrigierten Transkript-Dateinamen |

---

*Dokument-Stand: 22. Mai 2026 rev2. Owner: QA-Koordinator. Operations-Owner: Maik via Claude Code in WSL2.*
