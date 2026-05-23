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

/// Build a fixture that deterministically produces one LONG SL trade
/// under the Phase-2 trend-follow + RSI-cross entry logic (Diff D-03 +
/// D-05):
///   1. Phase 1 — 20 flat candles at 100 train the BB(20) basis.
///   2. Phase 2 — 14-bar decline (-2 per bar, 100 → 72) drives RSI(14)
///      down to ~0; the BB stddev widens.
///   3. Phase 3 — single surge bar (close=120) pushes price above the
///      upper band AND makes RSI cross UP through 30 → LONG entry
///      pending at index 34, filled at the open of index 35.
///   4. Phase 4 — exit candle at index 35 with low=0 trips the SL
///      placeholder (= BB middle at the signal bar ≈ 90).
///   5. Phase 5 — flat tail at 110 prevents re-entry (RSI no longer
///      crosses through 30; BB upper stabilises above close).
List<CandleData> _buildLongSlFixture() {
  const baseTs = 1_700_000_000_000;
  final candles = <CandleData>[];

  // Phase 1: 20 flat candles at 100.0 — BB(20) warmup.
  for (int i = 0; i < 20; i++) {
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: 99.9, high: 100.3, low: 99.7, close: 100.0, volume: 1_000.0,
    ));
  }

  // Phase 2: 14-bar decline pulls RSI(14) to ~0 and widens BB stddev.
  for (int i = 0; i < 14; i++) {
    final close = 100.0 - (i + 1) * 2.0; // 98, 96, …, 72
    candles.add(CandleData(
      timestamp: baseTs + (20 + i) * 3_600_000,
      open: close + 0.5, high: close + 0.5, low: close - 0.5,
      close: close, volume: 1_000.0,
    ));
  }

  // Phase 3: surge bar — close=120 > upper(~113), RSI(14) crosses UP
  // through 30 (jumps from ~0 to ~65). Signal emitted; fill at index 35.
  candles.add(CandleData(
    timestamp: baseTs + 34 * 3_600_000,
    open: 72.5, high: 120.5, low: 72.0, close: 120.0, volume: 1_000.0,
  ));

  // Phase 4: SL-exit candle. Fill at open=120 (slippage 0), then
  // intra-bar low=0 hits SL ≈ 90.5 (BB middle at the signal bar).
  candles.add(CandleData(
    timestamp: baseTs + 35 * 3_600_000,
    open: 120.0, high: 120.0, low: 0.0, close: 110.0, volume: 1_000.0,
  ));

  // Phase 5: flat tail at 110 — no re-entry possible.
  for (int i = 36; i < 60; i++) {
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: 110.0, high: 110.5, low: 109.5, close: 110.0, volume: 1_000.0,
    ));
  }
  return candles;
}

/// Mirror of [_buildLongSlFixture] for the SHORT / TP scenario:
/// 20 flat + 14-bar ascent (drives RSI ~100) + crash bar (close=80
/// below lower BB, RSI crosses DOWN through 70) + TP-exit candle
/// (low=0 hits TP placeholder = 2*lower-middle) + flat tail at 90.
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
    final close = 100.0 + (i + 1) * 2.0; // 102, 104, …, 128
    candles.add(CandleData(
      timestamp: baseTs + (20 + i) * 3_600_000,
      open: close - 0.5, high: close + 0.5, low: close - 0.5,
      close: close, volume: 1_000.0,
    ));
  }

  // Crash bar — close=80 < lower(~86), RSI(14) crosses DOWN through 70.
  candles.add(CandleData(
    timestamp: baseTs + 34 * 3_600_000,
    open: 127.5, high: 128.0, low: 80.0, close: 80.0, volume: 1_000.0,
  ));

  // TP-exit candle. Fill short at open=80, intra-bar low=0 hits the
  // TP placeholder (2*lower - middle ≈ 63 well below 0… actually well
  // above 0, so any low=0 trips it).
  candles.add(CandleData(
    timestamp: baseTs + 35 * 3_600_000,
    open: 80.0, high: 80.0, low: 0.0, close: 90.0, volume: 1_000.0,
  ));

  for (int i = 36; i < 60; i++) {
    candles.add(CandleData(
      timestamp: baseTs + i * 3_600_000,
      open: 90.0, high: 90.5, low: 89.5, close: 90.0, volume: 1_000.0,
    ));
  }
  return candles;
}

void main() {
  group('F-02 §3.4 Dart SL/TP intra-candle exits', () {
    test('long position closes at SL when next candle penetrates the level',
        () {
      // Phase-2 entry (Diff D-03 + D-05): long requires close > upper
      // AND RSI cross UP through oversold. The fixture pre-builds a
      // 14-bar decline (drives RSI(14) to ~0), then a single surge bar
      // crosses RSI back through 30 with close > upper → LONG signal,
      // filled next bar where low=0 trips the SL placeholder. Phase-1
      // BB(20, SMA, 2.0σ) + RSI(14, 30/70) is pinned so the test is
      // decoupled from the strategy default shift.
      final candles = _buildLongSlFixture();
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10_000.0,
        feeRate: 0.0,
        params: const BbRsiParams(
          bbPeriod: 20,
          bbStdDev: 2.0,
          bbMaType: BbMaType.sma,
          rsiPeriod: 14,
          rsiOversold: 30.0,
          rsiOverbought: 70.0,
          swingLookbackBars: 20,
        ),
      );

      expect(result.trades, isNotEmpty,
          reason:
              'fixture must trigger at least one BB+RSI long entry — if '
              'this fails the dip+surge sequence is no longer producing '
              'close > upper with RSI cross-up through 30; rebuild the '
              'fixture, do NOT delete the assertion.');

      // Single LONG SL trade in this fixture: entry at the surge bar
      // (index 34), fill at index 35 open=120 (slippage 0), then low=0
      // intra-bar trips the SL placeholder (= BB middle ≈ 90).
      final trade = result.trades.firstWhere(
        (t) => t.direction == 'LONG' && t.exitReason == 'StopLoss',
        orElse: () => throw StateError(
            'F-02: fixture must produce a LONG SL trade. Pre-F-02 this '
            'position closes at "BB Middle" or "End of Data", never with '
            'exitReason="StopLoss".'),
      );
      expect(trade.entryPrice, equals(120.0),
          reason: 'long entry fills at the SL-candle open (slippage 0)');
      expect(trade.exitPrice, lessThan(trade.entryPrice),
          reason: 'long SL is always strictly below entry price');
      expect(trade.exitPrice, greaterThan(0.0),
          reason:
              'SL must equal the absolute SL price computed at entry, not '
              'the exit candle low (which is 0.0 in the fixture)');
      expect(trade.exitPrice, isNot(closeTo(110.0, 1e-9)),
          reason:
              'pre-F-02 the position would close on the exit candle close '
              '(=110); post-F-02 it closes at the BB-derived SL price intra-bar');
      expect(trade.pnl, lessThan(0.0),
          reason: 'a long stop-loss is by definition a losing trade');
    });

    test('short position closes at TP when next candle penetrates the level',
        () {
      // Mirror of the long-SL test: 14-bar ascent (drives RSI > 70),
      // then a crash bar crosses RSI down through 70 with close < lower
      // → SHORT signal. Fill at next bar's open, intra-bar low=0 trips
      // the TP placeholder.
      final candles = _buildShortTpFixture();
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10_000.0,
        feeRate: 0.0,
        params: const BbRsiParams(
          bbPeriod: 20,
          bbStdDev: 2.0,
          bbMaType: BbMaType.sma,
          rsiPeriod: 14,
          rsiOversold: 30.0,
          rsiOverbought: 70.0,
          swingLookbackBars: 20,
        ),
      );

      expect(result.trades, isNotEmpty,
          reason:
              'fixture must trigger at least one BB+RSI short entry — if '
              'this fails the rise+crash sequence is no longer producing '
              'close < lower with RSI cross-down through 70; rebuild the '
              'fixture.');

      // Single SHORT TP trade: signal at crash bar (index 34), fill at
      // index 35 open=80 (slippage 0), low=0 intra-bar trips TP
      // placeholder (= 2*lower - middle ≈ 63).
      final trade = result.trades.firstWhere(
        (t) => t.direction == 'SHORT' && t.exitReason == 'TakeProfit',
        orElse: () => throw StateError(
            'F-02: fixture must produce a SHORT TP trade. Pre-F-02 this '
            'position would close at "BB Middle" on the indicator path, '
            'never with exitReason="TakeProfit".'),
      );
      expect(trade.entryPrice, equals(80.0),
          reason: 'short entry fills at the TP-candle open (slippage 0)');
      expect(trade.exitPrice, lessThan(trade.entryPrice),
          reason:
              'a profitable short closes below entry — TP for a short is '
              'always strictly below the entry price');
      expect(trade.exitPrice, greaterThan(0.0),
          reason:
              'TP must equal the absolute TP price (BB-derived), not the exit '
              'candle low which is 0.0');
      expect(trade.exitPrice, isNot(closeTo(90.0, 1e-9)),
          reason:
              'pre-F-02 the position would close on the exit candle close '
              '(=90); post-F-02 it closes at the BB-derived TP price intra-bar');
      expect(trade.pnl, greaterThan(0.0),
          reason: 'a short take-profit is by definition a winning trade');
    });
  });
}
