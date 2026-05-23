/// F-02 Dart SL/TP intra-candle exit regression.
///
/// Pins the same contract as the Rust `tests/regression_f02.rs` test:
/// when the BB+RSI strategy attaches an absolute SL / TP price to a new
/// position, the Dart [BacktestService] MUST close the position at the
/// SL/TP price as soon as a candle's `low` (long SL / short TP) or
/// `high` (long TP / short SL) penetrates that level — NOT at the
/// candle close, NOT at end-of-data.
///
/// Before F-02 (§3.4 of `260522_Gesamtplan_Phase1-3.md`) the Dart engine
/// ignored SL/TP entirely: positions only exited on the indicator-based
/// signals (BB middle cross / RSI extreme) or at end-of-data. These two
/// tests are RED under that pre-F-02 behaviour and GREEN once the engine
/// wires SL/TP through the entry path and runs the intra-candle check.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';

/// Build a fixture that deterministically:
///   1. Trains BB(20) + RSI(14) on a clean +0.5 / candle upward drift, so
///      RSI sits near 100 and BB sits near +106.
///   2. Crashes the price hard at indices 30–33 to push close below the
///      lower BB and force RSI < 30 → BB+RSI emits a LONG entry on
///      candle index 33.
///   3. Inserts an exit candle at index 34 whose `low = 0.0` guarantees
///      `candle.low ≤ SL` no matter how the SL is computed; close stays
///      at 60 so the BB-middle / RSI indicator exit does NOT fire and
///      we can be sure any exit observed comes from the SL path.
///   4. Holds the price flat afterwards so end-of-data is the only
///      possible exit if SL handling is missing.
List<CandleData> _buildLongSlFixture() {
  const baseTs = 1_700_000_000_000;
  final candles = <CandleData>[];

  // Phase 1: upward drift, 30 candles, +0.5 per candle.
  for (int i = 0; i < 30; i++) {
    final close = 100.0 + i * 0.5;
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: close - 0.1,
      high: close + 0.3,
      low: close - 0.3,
      close: close,
      volume: 1_000.0,
    ));
  }

  // Phase 2: sharp crash over 4 candles → BB lower drops, RSI plunges.
  final crash = [100.0, 90.0, 80.0, 70.0];
  for (int j = 0; j < crash.length; j++) {
    final i = 30 + j;
    final close = crash[j];
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: close + 0.5,
      high: close + 0.5,
      low: close - 0.5,
      close: close,
      volume: 1_000.0,
    ));
  }

  // Phase 3: exit candle — spike to low=0 so any positive SL is hit,
  // close back to 60 so BB-middle cross / RSI exit does NOT trigger.
  candles.add(CandleData(
    timestamp: baseTs + 34 * 3_600_000,
    open: 70.0,
    high: 70.0,
    low: 0.0,
    close: 60.0,
    volume: 1_000.0,
  ));

  // Phase 4: tail – flat at 60 so no indicator-based exit fires.
  for (int i = 35; i < 60; i++) {
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: 60.0,
      high: 60.5,
      low: 59.5,
      close: 60.0,
      volume: 1_000.0,
    ));
  }
  return candles;
}

/// Mirror of [_buildLongSlFixture] for the short / TP scenario.
///
///   1. Downward drift trains BB(20) low and pulls RSI near 0.
///   2. Sharp surge pushes close above upper BB and RSI > 70 → SHORT entry.
///   3. Exit candle has `low = 0.0` which sits below any positive TP
///      (TP = BB middle ≈ 90+), so the short TP is hit intra-candle.
///      Close stays at 110 so the BB-middle indicator exit does NOT fire.
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

  candles.add(CandleData(
    timestamp: baseTs + 34 * 3_600_000,
    open: 130.0,
    high: 130.0,
    low: 0.0,
    close: 110.0,
    volume: 1_000.0,
  ));

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
  group('F-02 §3.4 Dart SL/TP intra-candle exits', () {
    test('long position closes at SL when next candle penetrates the level',
        () {
      final candles = _buildLongSlFixture();
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10_000.0,
        feeRate: 0.0,
      );

      expect(result.trades, isNotEmpty,
          reason:
              'fixture must trigger at least one BB+RSI long entry — if this '
              'fails the crash-drop sequence is no longer pushing close below '
              'lower BB with RSI < 30; rebuild the fixture, do NOT delete the '
              'assertion.');

      // Find the canonical SL-exit long trade (entered on the deep-crash candle
      // close=70, exited next bar on low=0). Other trades in the fixture's
      // flat tail are not the F-02 contract under test.
      final trade = result.trades.firstWhere(
        (t) => t.direction == 'LONG' &&
            t.exitReason == 'StopLoss' &&
            t.entryPrice == 70.0,
        orElse: () => throw StateError(
            'F-02: fixture must produce a LONG SL trade entered at close=70 '
            '(the deep-crash candle). Pre-F-02 this position closes at "BB '
            'Middle" or "End of Data", never with exitReason="StopLoss".'),
      );
      expect(trade.exitPrice, lessThan(trade.entryPrice),
          reason: 'long SL is always strictly below entry price');
      expect(trade.exitPrice, greaterThan(0.0),
          reason:
              'SL must equal the absolute SL price computed at entry, not '
              'the exit candle low (which is 0.0 in the fixture)');
      expect(trade.exitPrice, isNot(closeTo(60.0, 1e-9)),
          reason:
              'pre-F-02 the position would close on the exit candle close '
              '(=60); post-F-02 it closes at the BB-derived SL price intra-bar');
      expect(trade.pnl, lessThan(0.0),
          reason: 'a long stop-loss is by definition a losing trade');
    });

    test('short position closes at TP when next candle penetrates the level',
        () {
      final candles = _buildShortTpFixture();
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10_000.0,
        feeRate: 0.0,
      );

      expect(result.trades, isNotEmpty,
          reason:
              'fixture must trigger at least one BB+RSI short entry — if '
              'this fails the surge-up sequence is no longer pushing close '
              'above upper BB with RSI > 70; rebuild the fixture.');

      // Find the canonical TP-exit short trade (entered on the surge top
      // close=130, exited next bar on low=0). Earlier surge candles may have
      // produced a separate SL-exit trade; that is not the F-02 contract here.
      final trade = result.trades.firstWhere(
        (t) => t.direction == 'SHORT' &&
            t.exitReason == 'TakeProfit' &&
            t.entryPrice == 130.0,
        orElse: () => throw StateError(
            'F-02: fixture must produce a SHORT TP trade entered at close=130 '
            '(the surge top). Pre-F-02 this position would close at "BB Middle" '
            'on the indicator path, never with exitReason="TakeProfit".'),
      );
      expect(trade.exitPrice, lessThan(trade.entryPrice),
          reason:
              'a profitable short closes below entry — TP for a short is '
              'always strictly below the entry price');
      expect(trade.exitPrice, greaterThan(0.0),
          reason:
              'TP must equal the absolute TP price (BB middle), not the exit '
              'candle low which is 0.0');
      expect(trade.exitPrice, isNot(closeTo(110.0, 1e-9)),
          reason:
              'pre-F-02 the position would close on the exit candle close '
              '(=110); post-F-02 it closes at the BB-derived TP price intra-bar');
      expect(trade.pnl, greaterThan(0.0),
          reason: 'a short take-profit is by definition a winning trade');
    });
  });
}
