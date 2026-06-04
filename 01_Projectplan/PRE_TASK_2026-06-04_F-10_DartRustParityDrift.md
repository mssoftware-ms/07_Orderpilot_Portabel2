# Pre-Task F-10 — Phase-1 Dart↔Rust Parity Drift (~51 USDT)

**Issued:** 2026-06-04 by QA-Koordinator (Windows-CC)
**Target executor:** parallel-CC in WSL2/tmux
**Branch:** `main`, atomare Commits, push nach jedem grünen Commit
**Base:** `15b7429` (origin/main, inkl. O3-B4 Studies Library + O3-B4-10 path-canonicalization + Audit-Trailer)

---

## 0. Befund (verifiziert)

`test/integration/phase1_reference_backtest_test.dart` failt nach frischem `bash tool/build_rust.sh release` auf der `closeTo 1e-9`-Parity-Assertion. Reproduziert in O3-B4-POST_TASK §5:

```
Trades:    91   (Dart & Rust identisch, 3/3 deterministisch je Engine)
Dart-PnL:  -1565.358744  USDT  (3/3 bit-identisch)
Rust-PnL:  -1514.059742  USDT  (3/3 bit-identisch)
Drift:    ~51 USDT       (PnL-Sign gleich, beide loss, Drift = ~3.3 %)
```

**Was der Test nicht failt:**
- Dart-Determinismus (2 von 4 Assertions) — ✅
- Rust-Determinismus (3 von 4 Assertions) — ✅
- `totalTrades` (Dart == Rust == 91) — ✅
- Sanity (`totalTrades > 0`) — ✅

**Was failt:**
- `expect(r.totalPnl, closeTo(d.totalPnl, 1e-9))` — Drift > 51 USDT
- konsequenterweise `winRate`/`sharpeRatio`/`maxDrawdown`/`maxDrawdownPercent` (PnL-derived)

**Memory-Eintrag `project-regression-guards.md` wurde am 2026-06-04 auf die neuen Dart/Rust-Werte aktualisiert.** Der frühere `-2071.38`-Wert ist Geschichte (`01_Projectplan/specs/bb_rsi_diff.md:40`).

---

## 1. Scope

**Ziel:** Phase-1-Reference-Backtest auf `1e-9`-Parität Dart↔Rust zurückbringen ohne den Trade-Count (91) zu verändern.

**Strikt:** Der Fix muss VERHALTENSGLEICH sein — keine neue Strategie-Logik, keine neuen Parameter-Defaults, keine Indikator-Änderungen. Reiner Berechnungs-Drift-Fix.

**Out-of-scope:**
- Engine-Performance (S-05 O(n²) RSI bleibt)
- Strategy-Verhalten (BB(20,2.0)+RSI(14,30/70) Strict-Spec bleibt)
- UI / Studies (kein Touch O3-B*-Code)
- `dart_rust_parity_test.dart` BB+RSI-Sinus-Fixture skip-Status (Welle I2-3)

---

## 2. Kontext: was wir wissen

### 2.1 Identische Bar-Order-Logik bewiesen

Trade-Count identisch (91) **und** beide Engines deterministisch je 3 Runs → Entry-/Exit-Bedingungen, Bar-Iteration, Pending-Queue-Mechanik sind bit-äquivalent. F-04 + F-09 hatten genau das fixiert.

→ **Der Drift sitzt NICHT in der Signal-Logik. Er sitzt in der PnL-Berechnung.**

### 2.2 Engine-Commits seit Baseline-Freeze (2026-05-26)

Folgende Engine-/Backtest-Commits sind nach `-2071.38`/139-Trades gelandet und kommen als Drift-Quelle in Frage:

| Commit | Subject | Verdacht-Score |
|---|---|---|
| `86a6199` | fix risk sizing and TP handling | **hoch** — Sizing ist multiplikativ in jeden Trade |
| `28bdca0` | fix(N-08): fee-adjusted allocation budgets for entry + exit fees | **hoch** — Fee-Allocation ändert effektive Position-Size |
| `7eeeb5f` | fix(N-15): slippage applied to SL stop-loss closures | **mittel** — wirkt nur auf SL-getriggerte Exits |
| `7c3e903` | fix(N-13,N-14,N-18): entry fee does not shrink position, div-0 guard, simplified current_equity | **hoch** — `current_equity`-Simplifikation kann Equity-Akkumulationsfolge ändern |
| `52ce16b` | fix(N-09,N-11,N-12,N-21,N-22,N-23,N-24): remaining low/medium fixes | mittel — Batch-Fix, Detail unklar |

Hypothese: Einer dieser Fixes ist nur in einer Engine (Dart oder Rust) konsequent angewandt, oder beide haben subtile Reihenfolge-Unterschiede (z. B. `entry_fee` zuerst vom Equity abziehen vs. zuerst vom Notional).

### 2.3 Architektur — wo PnL pro Trade berechnet wird

**Rust:** `rust/trading_engine/src/addins/bb_rsi.rs` + Engine-Core
- `position_size_pct_fee_aware(entry, sl, risk, fee)` Z.183 — fee-aware Sizing
- `position_size_pct(entry, sl_dist, risk)` Z.204 — Legacy ohne Fees

**Dart:** `lib/services/backtest_service.dart`
- Spiegelt die Rust-Logik (Z.918 Kommentar: „Rust `position_size_pct` helper / 100")
- Bit-Parität ist explizites Design-Goal des Files

→ **Beide Sizing-Funktionen müssen byte-by-byte denselben Multiplikations-Pfad gehen**. Wenn z. B. Dart `100.0 * risk / denominator` als `(100 * risk) / denom` und Rust als `100 * (risk / denom)` rechnet, sind die letzten ULPs schon weg — bei 91 Trades akkumuliert sich das.

---

## 3. Diagnose-Plan (verbindlich — systematic-debugging-Geist)

### Phase A — Erste-Divergenz lokalisieren (TDD-Diagnose-Test)

**Subtask A.1:** Schreibe `test/integration/dart_rust_first_divergence_test.dart`. Lädt BTCUSDT 1h 2024-H1, läuft Dart und Rust parallel, gibt den **ersten** Trade aus, bei dem die per-Trade-PnL um mehr als `1e-12` divergiert. Output-Format:

```
First divergence at trade #N:
  entry_ts       = …
  exit_ts        = …
  exit_reason    = …
  dart.pnl       = …
  rust.pnl       = …
  delta          = …
  dart.size_pct  = …
  rust.size_pct  = …
  dart.entry_fee = …
  rust.entry_fee = …
  dart.exit_fee  = …
  rust.exit_fee  = …
```

Der Test selbst failt mit dem Report. Trade-Count-Match wird vorher als Sanity asserted (wenn der schon nicht stimmt, ist der Drift woanders).

**Subtask A.2:** Lauf den Test, ARCHIVIERE den Output unter `01_Projectplan/F-10_first_divergence_report.txt`. Erste Eingrenzung damit ist gemacht.

### Phase B — Subsystem identifizieren

Nach Phase-A-Output ist klar **welcher** Bereich driftet. Wahrscheinliche Forks:

**B.1 — Sizing driftet (`size_pct` schon unterschiedlich):**
- Vergleich `position_size_pct_fee_aware` Rust vs. Dart byte-exact (Operator-Reihenfolge, Klammern, Clamp).
- Bias-Hypothese: einer der beiden hat noch den Pre-N-08-Code.

**B.2 — Sizing identisch, aber `entry_fee` driftet:**
- Vergleich Fee-Application-Reihenfolge (N-13: „entry fee does not shrink position").
- Suche nach Stellen, wo Equity oder Notional VOR fee-Abzug oder NACH fee-Abzug zur Multiplikation genutzt werden.

**B.3 — Sizing + Fees identisch, aber `exit_fee` oder Slippage driftet:**
- N-15 Slippage auf SL-Closes: läuft das wirklich auf beiden Seiten?
- TP/SL-Hit-Preise vergleichen (engine könnte high/low-Vergleich anders rounden).

**B.4 — Alles per-Trade identisch, aber kumulativer Equity-Stand driftet:**
- N-18 „simplified current_equity": Summations-Reihenfolge unterschiedlich?
- Kahan-Summation Dart vs. Rust trivial-Add — unwahrscheinlich, aber check.

### Phase C — Fix + Parity wiederherstellen

Fix anwenden auf der Engine-Seite, die vom Strict-Spec-Sollverhalten abweicht. Falls beide abweichen oder unklar ist welche „richtig" ist — auf die fee-aware-Soll-Formel aus `bb_rsi.rs:174-200` einigen (die ist mathematisch hergeleitet, der Block-Kommentar dokumentiert die Formel explizit).

Atomarer Commit pro behobenem N-Finding. Falls mehrere driften, mehrere Commits.

### Phase D — Verify + Lock

**Subtask D.1:** Phase-1-Test grün (`closeTo 1e-9` hält bei 91 Trades).
**Subtask D.2:** `dart_rust_first_divergence_test.dart` muss jetzt **leere divergence** zeigen — der Test bleibt im Repo als Lock gegen erneutes Driften (passes-on-no-divergence + fails-on-any).
**Subtask D.3:** Memory `project-regression-guards.md` final-update mit dem dann-gemeinsamen PnL-Wert (Dart == Rust nach Fix).

---

## 4. Error / Edge cases (was nicht passieren darf)

| Risiko | Verhalten |
|---|---|
| Trade-Count ändert sich beim Fix (z. B. 91 → 90) | **STOPP.** Signal-Logik wurde versehentlich angefasst — revert + Diagnose-Brief. |
| `closeTo 1e-9` passt, aber Dart-PnL hat sich verschoben | Memory-Update auf den neuen gemeinsamen Wert; Phase-1-Test bleibt unverändert. |
| Fix erfordert Schema-Änderung am `params_json` | Out-of-scope, eskalieren — separater Brief. |
| `tool/build_rust.sh release` failed | F-10 abbrechen, Build-Fix vorziehen (eigener Brief). |
| Subtask A-Diagnose-Test selbst hängt unter FakeAsync | `tester.runAsync` (Lesson `testing_runasync_in_widget_tests`). Sollte aber nicht relevant sein — Test ist plain `test()`, kein `testWidgets`. |

---

## 5. CI/Build-Hardening (Subtask)

`tool/build_rust.sh release` als Pflicht-Vorschritt vor jedem `flutter test`-Lauf, der Engine-Code berührt. Empfehlung Subtask **F-10-CI**:

**Option 1:** Pre-test-Hook in `.claude/settings.json` der `tool/build_rust.sh release` ausführt, wenn Dateien unter `rust/**` modified sind.
**Option 2:** README-Hinweis + Memory-Eintrag (Convention).
**Option 3:** `tool/test_with_rust.sh`-Wrapper, der Build + Test sequenziell ausführt.

QA-Koordinator-Empfehlung: **Option 1** (am robustesten, der menschliche Fehler-Pfad „vergessen" verschwindet ganz). Executor entscheidet — wenn Hook zu invasiv ist (z. B. wegen Worktrees), Option 3 reicht.

---

## 6. Sub-Tasks (Reihenfolge / atomare Commits)

| # | Subtask | Branch-Commit-Subject |
|---|---|---|
| A.1 | First-Divergence-Diagnose-Test (failing, mit Report) | `test(F-10-A.1): dart_rust_first_divergence diagnostic test` |
| A.2 | Diagnose-Lauf + Report archivieren | `docs(F-10-A.2): archive first divergence report` |
| B.x | Subsystem-Lokalisierung + Fix (Anzahl Commits = Anzahl driftender Subsysteme) | `fix(F-10-B.<sub>): <subsystem> parity` z. B. `fix(F-10-B.1): position_size_pct_fee_aware parity` |
| D.1 | Phase-1-Test grün | (impliziert durch B-Commits) |
| D.2 | Divergence-Test bleibt als Regression-Guard im Repo | (im selben Commit wie der letzte B-Fix) |
| D.3 | Memory + POST_TASK final-update | `chore(F-10-D.3): memory + post_task with final parity values` |
| CI | Build-Hardening (Option 1/2/3) | `chore(F-10-CI): rust build mandatory before flutter test` |

Jeder Subtask = ein grüner Commit, dann push.

---

## 7. Sign-Off-Checkliste (QA-Koordinator)

- [ ] First-Divergence-Test in main + Report archiviert
- [ ] Subsystem-Fix(es) gepusht, jeder einzeln grün
- [ ] `tool/build_rust.sh release` + `flutter test test/integration/phase1_reference_backtest_test.dart` **vollständig grün** auf Windows
- [ ] Trade-Count weiterhin 91 (Dart == Rust)
- [ ] `dart_rust_first_divergence_test.dart` zeigt keine Divergenz mehr (Test passt)
- [ ] CI/Build-Hardening-Subtask gepusht
- [ ] Memory `project-regression-guards.md` final mit gemeinsamen Werten aktualisiert
- [ ] `01_Projectplan/POST_TASK_2026-06-04_F-10_DartRustParityDrift.md` geschrieben

---

## 8. Offene Fragen für Executor (parallel-CC)

- **Q1:** Reicht für die First-Divergence ein per-Trade-Loop, oder muss auch die Equity-Curve pro Bar abgegriffen werden? Empfehlung: erst per-Trade — wenn alle Trades identisch sind aber Final-PnL nicht, dann erst per-Bar.
- **Q2:** Falls der Drift in beiden Engines an unterschiedlichen Stellen sitzt (z. B. Dart hat N-13 nicht angewandt, Rust hat es), in welcher Reihenfolge fixen? Empfehlung: pro Subsystem committen (B.1 alleine, dann re-run Test, dann B.2). Atomar.
- **Q3:** Build-Hardening Option 1 (Hook) — vor dem Implementieren mit Windows-CC abklären, ob es auf parallel-CC's WSL2-Setup ohne Konflikte läuft.
- **Q4:** Falls Phase-A keine per-Trade-Divergenz findet (PnL pro Trade identisch, aber Summe nicht) — Kahan-Summation-Verdacht in `equity.dart` / `equity.rs`. Frei-Tag: würde Phase B.4 sein.

---

## 9. Working-Tree-Hinweis

`.claude/scheduled_tasks.lock` ist als M-File harmlos (automatisches Tracking, nicht user-content). Wie in O3-B4 nicht aufräumen, nicht commiten.

Vor F-10 Start: `git status --short` sollte sauber sein bis auf die Lock-File.
