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
/// intra-candle TP path (F-02 contract): 30-candle downward drift trains
/// BB low, then a 4-candle surge pushes close above upper BB and RSI > 70
/// → SHORT entry at the surge top. The next candle has `low = 0` which
/// crosses any positive TP, so the position closes intra-bar via TP and
/// the rest of the tail does not re-enter.
List<CandleData> _buildShortTpFixture() {
  const baseTs = 1_700_000_000_000;
  final candles = <CandleData>[];

  for (int i = 0; i < 30; i++) {
    final close = 100.0 - i * 0.5;
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: close + 0.1,
      high: close + 0.3,
      low: close - 0.3,
      close: close,
      volume: 1_000.0,
    ));
  }

  final surge = [100.0, 110.0, 120.0, 130.0];
  for (int j = 0; j < surge.length; j++) {
    final i = 30 + j;
    final close = surge[j];
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: close - 0.5,
      high: close + 0.5,
      low: close - 0.5,
      close: close,
      volume: 1_000.0,
    ));
  }

  // TP-exit candle: low=0 crosses any positive TP.
  candles.add(CandleData(
    timestamp: baseTs + 34 * 3_600_000,
    open: 130.0,
    high: 130.0,
    low: 0.0,
    close: 110.0,
    volume: 1_000.0,
  ));

  // Flat tail — close=110 stays above BB middle, no re-entry possible.
  for (int i = 35; i < 60; i++) {
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: 110.0,
      high: 110.5,
      low: 109.5,
      close: 110.0,
      volume: 1_000.0,
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
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
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
