# Post-Task F-10 — Phase-1 Dart↔Rust Parity Drift (RESOLVED)

**Completed:** 2026-06-04 by parallel-CC (WSL2/tmux)
**Branch:** `main` — pushed `bdbf95e..a24f1b5`
**Base:** `bdbf95e` (F-10 pre-task spec commit)

---

## 1. Outcome

Phase-1 dart↔rust parity restored to `1e-9` at **91 trades**, drift `0.000000`.
Both engines now agree on the Rust-canonical PnL.

| Metric | Before (pre-F-10) | After (F-10) |
|---|---|---|
| Dart total PnL | **-1565.358744** | **-1514.059742** |
| Rust total PnL | -1514.059742 | -1514.059742 |
| Drift | ~51.30 USDT (3.3 %) | **0.000000** |
| Trade count (Dart == Rust) | 91 | **91** |
| Dart sharpe / ddPct | (diverged) | -1.469840 / 19.322983 % (== Rust) |

The Dart side moved onto the Rust value (Rust was the strict-spec-correct
engine — its fee-aware formula `bb_rsi.rs:183-201` is the documented soll).

## 2. Root cause (two Rust-only fixes never ported to Dart)

The first-divergence diagnostic isolated the drift to **position sizing**
(identical entry/exit prices and timestamps, `quantity` differing by ratio
`0.97325` at trade #0). That ratio decomposes exactly into two findings:

- **N-08 — fee-aware sizing (dominant, ~2.7 %/trade).** All three Rust
  strategies emit `size_pct` via `position_size_pct_fee_aware`
  (`bb_rsi.rs:497/521`, `ut_bot.rs:566/585`, `ichimoku.rs:711/732`). The
  Dart engines still used the legacy no-fee `risk * entry / sl_dist`
  (== Rust `position_size_pct`, the helper the strategies no longer call).
- **N-13 — entry fee does not shrink the position (residual `1/(1-fee)`).**
  Rust `open_position` sets `quantity = alloc / entry_price` (`mod.rs:496`);
  Dart used `(alloc - fee) / entry_price`.

`0.97325 = (fee_aware/legacy) / (1 - fee_rate)` — both factors compose to the
observed ratio, confirmed empirically by re-running the diagnostic after each
fix (51.30 → -0.63 → 0.000000 USDT drift).

## 3. Blast radius (3 strategies, by necessity)

The N-13 fix changes the `quantity` semantics that the **shared**
`midTradeEquity` helper (`lib/services/equity.dart`) assumes, so the helper
had to change too — which forced bringing all three Dart strategies
(bb_rsi / ut_bot / ichimoku) to N-08 + N-13 for internal coherence. Approved
by the QA-Koordinator (scope question, 2026-06-04: "Alle 3 Strategien").

Bonus: the **ut_bot** (pre-fix drift 13.30 USDT) and **ichimoku** (2.77 USDT)
parity tests were ALREADY red on `bdbf95e` with the identical pattern; the
same fix makes them green.

The `f03b_mid_trade_equity_test.dart` primitive expectations encoded the
cancelled-fee Dart-only formula (10097.9 / 10098.1) that never matched Rust;
corrected to the true `current_equity` values (10096.9 / 10097.1).

## 4. Commits (atomic, per PRE_TASK §6)

| Commit | Subject |
|---|---|
| `2b759d4` | test(F-10-A.1): dart_rust_first_divergence diagnostic test |
| `ba761dd` | docs(F-10-A.2): archive first divergence report |
| `f5528b7` | fix(F-10-B.1): fee-aware position sizing parity (N-08) |
| `abec298` | fix(F-10-B.2): entry fee does not shrink position (N-13) |
| `a24f1b5` | chore(F-10-CI): rust build mandatory before flutter test |

First-divergence report archived at:
**`01_Projectplan/F-10_first_divergence_report.txt`**

## 5. Verification

- Fresh `bash tool/build_rust.sh release` (exit 0) before every run.
- **Full suite: 672 passed / 34 skipped / 0 failed** (WSL2).
- `phase1_reference_backtest_test.dart`: Dart 3× bit-exact ✓, Rust 3× bit-exact
  ✓, Dart vs Rust 1e-9 ✓.
- `dart_rust_first_divergence_test.dart`: `first_divergence = NONE` (active
  regression lock).
- ut_bot + ichimoku parity tests: green.

## 6. Sign-off checklist (PRE_TASK §7)

- [x] First-Divergence-Test in main + Report archiviert
- [x] Subsystem-Fix(es) gepusht, jeder einzeln grün (B.1 dann B.2, re-run dazwischen)
- [~] `build_rust.sh release` + `flutter test phase1` **vollständig grün** —
      **verifiziert auf WSL2; Windows-Verifikation steht aus.** Per O3-B4-Lesson
      zählt WSL2-grün allein nicht — bitte Windows-CC bestätigt den Windows-Lauf.
- [x] Trade-Count weiterhin 91 (Dart == Rust)
- [x] `dart_rust_first_divergence_test.dart` zeigt keine Divergenz mehr
- [x] CI/Build-Hardening-Subtask gepusht (Option 3: `tool/test_with_rust.sh`;
      Option 1 Hook bewusst nicht gewählt — Q3 WSL2/Worktree-Risiko)
- [x] Memory `project-regression-guards.md` final mit gemeinsamem Wert -1514.059742
- [x] `POST_TASK_2026-06-04_F-10_DartRustParityDrift.md` geschrieben

## 7. Open items for QA-Koordinator (Windows-CC)

1. **Windows-green confirmation** of the full suite (hard sign-off item, §7.3).
2. Optional: enable the settings.json pre-test hook (PRE_TASK §5 Option 1) for
   an unforgettable rebuild guarantee, if the WSL2/worktree concern (Q3) clears.
3. The skipped `dart_rust_parity_test.dart` (BB+RSI sinus fixture, 0 trades)
   stays skipped — Welle I2-3, untouched, out of F-10 scope.
