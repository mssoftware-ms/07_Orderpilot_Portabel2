/// F-02c Dart SHORT-position balance accounting regression.
///
/// Mirrors `rust/trading_engine/tests/regression_f02c_short_balance.rs`.
/// Locks in the contract that `BacktestService.runBbRsi` produces a final
/// equity == `initial_balance + sum(net_pnl)` for any closed sequence of
/// trades, including SHORTs.
///
/// Before F-02c, the Dart engine's SHORT-close branch double-counted
/// `entryFee` (used `entry_price * quantity` instead of the original
/// `alloc = entry_price*quantity + entryFee`), so each closed short
/// shifted balance by `-entry_fee` relative to the correct accounting.
/// On the parity fixture this compounded across 6 short trades into a
/// ~36 USD downward drift on top of the larger Rust-side bug.
///
/// `BacktestService.runBbRsi` is the only public entry point on the Dart
/// engine, so we drive it via a hand-crafted candle fixture that
/// guarantees a single BB+RSI short entry and a follow-up TP/SL hit. The
/// final equity is read from the last equityCurve point.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';

/// Build a fixture that produces exactly one SHORT trade closed via the
/// intra-candle TP path under Phase-2 trend-follow + RSI-cross entry
/// + R:R 1:3 take-profit (Diff D-04 + D-05 + D-06). Post-D-06 the TP is
/// distance-based, so the swing-high SL must stay close to entry for
/// the TP to remain reachable:
///   1. 20 flat candles at 100 train BB(20).
///   2. 14-bar mild ascent (+0.5 per bar, 100 → 107) drives RSI(14) to
///      ~100 while keeping swing-high ≈ 107.5 close to the eventual
///      entry price (≈95).
///   3. Single crash bar (close=95) takes price below the lower band
///      AND crosses RSI down through 70 → SHORT signal pending at
///      index 34, filled at the open of index 35.
///   4. Exit candle at index 35 with low=0 trips the R:R 1:3 TP at 57.5
///      (= 95 − 3 × 12.5).
///   5. Flat tail at 92 — RSI converges, no re-entry possible.
List<CandleData> _buildShortTpFixture() {
  const baseTs = 1_700_000_000_000;
  final candles = <CandleData>[];

  for (int i = 0; i < 20; i++) {
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: 100.1, high: 100.3, low: 99.7, close: 100.0, volume: 1_000.0,
    ));
  }

  for (int i = 0; i < 14; i++) {
    final close = 100.0 + (i + 1) * 0.5; // 100.5, 101.0, …, 107.0
    candles.add(CandleData(
      timestamp: baseTs + (20 + i) * 3_600_000,
      open: close - 0.25, high: close + 0.5, low: close - 0.5,
      close: close, volume: 1_000.0,
    ));
  }

  // Crash bar — close=95 < lower(~96.6), RSI(14) crosses DOWN through 70.
  candles.add(CandleData(
    timestamp: baseTs + 34 * 3_600_000,
    open: 106.5, high: 107.0, low: 95.0, close: 95.0, volume: 1_000.0,
  ));

  // TP-exit candle: low=0 trips R:R 1:3 TP at 57.5.
  candles.add(CandleData(
    timestamp: baseTs + 35 * 3_600_000,
    open: 95.0, high: 95.5, low: 0.0, close: 92.0, volume: 1_000.0,
  ));

  // Flat tail at 92 — no re-entry possible.
  for (int i = 36; i < 60; i++) {
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: 92.0, high: 92.5, low: 91.5, close: 92.0, volume: 1_000.0,
    ));
  }
  return candles;
}

void main() {
  group('F-02c §3.4 Dart SHORT balance accounting', () {
    test('final equity after a closed short matches initial + net_pnl', () {
      const initialBalance = 10_000.0;
      const feeRate = 0.001; // 0.1%

      final candles = _buildShortTpFixture();
      // F-02c verifies engine balance accounting on SHORT trades — pin
      // Phase-1 BB(20, SMA, 2.0σ) + RSI(14, 30/70) so the hand-crafted
      // surge fixture continues to trigger the canonical short entry.
      // Default shift (Diff D-01/D-02) is irrelevant to the balance-update
      // arithmetic this test pins.
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        params: const BbRsiParams(
          bbPeriod: 20,
          bbStdDev: 2.0,
          bbMaType: BbMaType.sma,
          rsiPeriod: 14,
          rsiOversold: 30.0,
          rsiOverbought: 70.0,
          swingLookbackBars: 20,
          tpRrRatio: 3.0,
          riskPerTrade: 0.02,
        ),
      );

      final shortTpTrade = result.trades.firstWhere(
        (t) => t.direction == 'SHORT' && t.exitReason == 'TakeProfit',
        orElse: () => throw StateError(
            'F-02c: fixture must produce a SHORT TP trade. If this fails, '
            'check the BB+RSI fixture, not the balance assertion below.'),
      );

      final totalPnl =
          result.trades.fold<double>(0.0, (sum, t) => sum + t.pnl);
      final finalEquity = result.equityCurve.last.equity;
      final expected = initialBalance + totalPnl;

      expect(
        finalEquity,
        closeTo(expected, 1e-9),
        reason:
            'F-02c: final equity must equal initial_balance + sum(net_pnl). '
            'Pre-F-02c the SHORT close branch used entry_price*quantity '
            'instead of alloc = entry_price*quantity + entry_fee, so the '
            'returned margin was short by one entry_fee per closed short — '
            'compounds across multi-short fixtures. trade.pnl=${shortTpTrade.pnl}',
      );
    });

    // LONG-only sanity is covered by the existing Rust unit-tests in
    // rust/trading_engine/src/backtest/mod.rs (test_basic_long_trade,
    // test_fee_deduction, test_bitunix_vip0_fees, test_take_profit_hit,
    // test_equity_curve_drawdown) and by the LONG branch of the F-02c
    // mixed_long_then_short Rust regression — F-02c's direction-agnostic
    // formula reduces algebraically to the pre-fix LONG expression, so
    // those green tests already prove the LONG path is untouched.
  });
}
