/// F-04 regression: no look-ahead bias (Dart engine).
///
/// Spec §3.4 F-04:
///   A strategy signal generated on candle `i` (with information up to and
///   including `candle[i].close`) MUST be executed at the OPEN of candle
///   `i+1`, not at the close of candle `i`. The pre-F-04 Dart engine
///   opened positions at `candle[i].close` which is a textbook look-ahead
///   bug: the strategy is reading information it would not have at the
///   moment the order is sent.
///
/// F-04 strukturelle Verifikation: Signal-Bar i führt zu Execution beim
/// open von Bar i+1, NICHT beim close von Bar i. Bit-exakte Lag-Assertion
/// auf Entry-Timestamp und Entry-Preis. Die semantische „Look-Ahead
/// favourisiert die Strategie"-Assertion ist auf der 200-Candle Sinus-
/// Fixture nicht testbar (Fixture-Konvention `open = price - 20` dreht
/// den Effekt um). Sie wird im Phase-1-Gate Reference-Backtest auf
/// BTCUSDT 1h 2024-01..06 verifiziert (Plan §3.5).
///
/// Tolerance: 1e-9 for the open-match. Slippage default is 0 bps per
/// Plan rev2 normative paragraph.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';

/// Fixture that produces at least one trade under the Phase-2 trend-
/// follow + RSI-cross entry logic (Diff D-03..D-05): 20 flat candles +
/// 14-bar decline to drive RSI(14) ≈ 0 + a single surge bar that
/// crosses RSI through 30 and pushes close > upper → LONG signal +
/// SL-exit candle with low=0 + flat tail.
///
/// Replaces the previous sinusoidal F-01 parity fixture, which never
/// satisfies the cross condition AND close-extreme requirement on the
/// same bar — under Phase-2 logic it would yield 0 trades, turning
/// this regression into a tautology.
List<CandleData> _generateParityFixture() {
  const baseTs = 1700000000000;
  final candles = <CandleData>[];

  // Phase 1: 20 flat candles at 100.0.
  for (int i = 0; i < 20; i++) {
    candles.add(CandleData(
      timestamp: baseTs + i * 3600000,
      open: 99.9, high: 100.3, low: 99.7, close: 100.0, volume: 1000.0 + i,
    ));
  }
  // Phase 2: 14-bar decline.
  for (int i = 0; i < 14; i++) {
    final close = 100.0 - (i + 1) * 2.0;
    candles.add(CandleData(
      timestamp: baseTs + (20 + i) * 3600000,
      open: close + 0.5, high: close + 0.5, low: close - 0.5,
      close: close, volume: 1000.0 + 20 + i,
    ));
  }
  // Phase 3: surge bar that triggers the LONG signal.
  candles.add(CandleData(
    timestamp: baseTs + 34 * 3600000,
    open: 72.5, high: 120.5, low: 72.0, close: 120.0, volume: 1034.0,
  ));
  // Phase 4: SL-exit candle. open=119.0 (≠ signal-bar close=120.0) so
  // the F-04 "entry price != prior bar's close" smoking-gun assertion
  // has a non-trivial gap to detect; low=0 trips placeholder SL ≈ middle.
  candles.add(CandleData(
    timestamp: baseTs + 35 * 3600000,
    open: 119.0, high: 120.0, low: 0.0, close: 110.0, volume: 1035.0,
  ));
  // Phase 5: flat tail at 110.
  for (int i = 36; i < 200; i++) {
    candles.add(CandleData(
      timestamp: baseTs + i * 3600000,
      open: 110.0, high: 110.5, low: 109.5, close: 110.0, volume: 1000.0 + i,
    ));
  }
  return candles;
}

/// Find a candle by its timestamp. Returns the index, or -1 if absent.
int _indexOfTimestamp(List<CandleData> candles, int ts) {
  for (int i = 0; i < candles.length; i++) {
    if (candles[i].timestamp == ts) return i;
  }
  return -1;
}

void main() {
  const initialBalance = 10000.0;
  const feeRate = 0.0006;

  group('F-04 no lookahead bias', () {
    test(
      'every trade entryPrice equals its bar\'s open, not the previous bar\'s close',
      () {
        final candles = _generateParityFixture();
        // F-04 verifies engine no-lookahead arithmetic (entry executes at
        // next bar's open, not signal bar's close) — pin Phase-1
        // BB(20, SMA, 2.0σ) + RSI(14, 30/70) so the 200-candle fixture
        // continues to trigger trades. The Phase-2 default BB(200) would
        // sit exactly on the warm-up boundary and yield 0 trades on a
        // 200-candle fixture, turning the F-04 assertion into a tautology.
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
          ),
        );

        expect(
          result.trades,
          isNotEmpty,
          reason: 'parity fixture must produce trades — otherwise the F-04 '
              'regression would be a tautology of 0 == 0',
        );

        for (final trade in result.trades) {
          final entryIdx = _indexOfTimestamp(candles, trade.entryTimestamp);
          expect(
            entryIdx,
            isNonNegative,
            reason:
                'trade.entryTimestamp ${trade.entryTimestamp} must reference '
                'a real candle in the fixture',
          );

          final entryCandle = candles[entryIdx];
          // Default slippage = 0 → entry executes bit-exact at the bar open.
          expect(
            trade.entryPrice,
            closeTo(entryCandle.open, 1e-9),
            reason: 'entry must execute at the bar OPEN (next-bar-open rule)',
          );

          // Smoking gun: prior bar's close MUST differ from entry price.
          // In the parity fixture every candle has close - open = 20, so
          // this inequality is mechanical, not depending on which bar
          // signalled.
          if (entryIdx > 0) {
            final priorClose = candles[entryIdx - 1].close;
            expect(
              (trade.entryPrice - priorClose).abs(),
              greaterThan(1e-6),
              reason: 'entry_price MUST NOT equal candle[entryIdx-1].close '
                  '— that pattern is the F-04 look-ahead bug',
            );
          }
        }
      },
    );
  });
}
