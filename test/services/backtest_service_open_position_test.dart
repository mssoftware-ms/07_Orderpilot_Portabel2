/// Welle B4.2-1 — BacktestResult.openPosition + opt-in extraction.
///
/// Verifies the additive `extractOpenPosition` parameter on the three
/// strategy entry points:
///   - default `false` preserves the legacy 'End of Data' force-close
///     (phase1_reference_backtest_test depends on this — bit-exact)
///   - `true` snapshots the still-open position into
///     [BacktestResult.openPosition] (with SL/TP) and drops the
///     sentinel trade
///   - the snapshot equality / immutability contract holds
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/core/models/trade.dart';
import 'package:trading_app/services/backtest_service.dart';

/// Deterministic LCG fixture — same shape as the parity-test fixtures
/// in this repo. Tuned to produce reliable BB+RSI signals on a fast
/// (small-period) configuration.
List<CandleData> _lcgFixture(int n) {
  final closes = <double>[];
  int s = 12345;
  double price = 100.0;
  closes.add(price);
  while (closes.length < n) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    final step = ((s % 200) - 100) / 30.0;
    price = (price + step).clamp(80.0, 120.0);
    closes.add(price);
  }
  const baseTs = 1700000000000;
  return [
    for (int i = 0; i < closes.length; i++)
      CandleData(
        timestamp: baseTs + i * 60000,
        open: closes[i] - 0.3,
        high: closes[i] + 1.2,
        low: closes[i] - 1.2,
        close: closes[i],
        volume: 1000.0 + i,
      ),
  ];
}

/// Fast BB+RSI tuning — reliably produces open positions on the 400-bar
/// LCG fixture (matches the paper_trading_provider_test fixture).
const _fastBbRsi = BbRsiParams(
  bbPeriod: 20,
  bbStdDev: 0.2,
  bbMaType: BbMaType.ema,
  rsiPeriod: 3,
  rsiOversold: 30.0,
  rsiOverbought: 70.0,
  swingLookbackBars: 5,
  tpRrRatio: 3.0,
  riskPerTrade: 0.02,
);

void main() {
  group('B4.2-1: extractOpenPosition contract', () {
    test('default false produces no openPosition snapshot', () {
      final candles = _lcgFixture(400);

      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: _fastBbRsi,
      );

      expect(result.openPosition, isNull,
          reason: 'Default path keeps the legacy force-close behaviour — '
              'openPosition must stay null so phase1_reference_backtest '
              'remains bit-exact.');
    });

    test('default false is bit-exact compared to omitting the parameter', () {
      // Triple-check the default value: passing extractOpenPosition: false
      // explicitly must produce a result identical to the no-arg call. Any
      // drift here means a default-value typo silently flipped the path.
      final candles = _lcgFixture(400);

      final implicit = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: _fastBbRsi,
      );
      final explicit = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: _fastBbRsi,
        extractOpenPosition: false,
      );

      expect(explicit.metrics.totalTrades, implicit.metrics.totalTrades);
      expect(explicit.metrics.totalPnl, implicit.metrics.totalPnl);
      expect(explicit.metrics.totalFees, implicit.metrics.totalFees);
      expect(explicit.metrics.sharpeRatio, implicit.metrics.sharpeRatio);
      expect(explicit.trades.length, implicit.trades.length);
      expect(explicit.openPosition, isNull);
      expect(implicit.openPosition, isNull);
    });

    test('extractOpenPosition: true populates SL/TP on the live position', () {
      final candles = _lcgFixture(400);

      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: _fastBbRsi,
        extractOpenPosition: true,
      );

      // The fast BB+RSI configuration on this 400-bar LCG fixture leaves
      // a position open at the last bar — verified by the paper-trading
      // smoke test. If this fixture ever stops producing an open position,
      // the assertion below will fail loudly so the test can be retuned.
      expect(result.openPosition, isNotNull,
          reason: 'Fast BB+RSI on 400-bar LCG must leave an open position at '
              'the end of the window — fixture changed?');
      final snap = result.openPosition!;
      expect(snap.direction, anyOf('LONG', 'SHORT'));
      expect(snap.entryPrice, greaterThan(0));
      expect(snap.quantity, greaterThan(0));
      expect(snap.entryFee, greaterThanOrEqualTo(0));
      expect(snap.slPrice, isNotNull,
          reason: 'BB+RSI always attaches a swing-based SL at entry.');
      expect(snap.tpPrice, isNotNull,
          reason: 'BB+RSI always attaches an R:R-derived TP at entry.');
      expect(snap.slPrice!.isFinite, isTrue);
      expect(snap.tpPrice!.isFinite, isTrue);
      // SL placement vs the signal-bar close has the right sign — TP can
      // collide with entryPrice on degenerate slippage-induced fills so
      // we don't compare TP vs entry. The SL ↔ TP separation alone is
      // enough to catch a long/short swap.
      expect(snap.slPrice!, isNot(equals(snap.tpPrice!)));
      if (snap.isLong) {
        expect(snap.slPrice!, lessThan(snap.tpPrice!));
      } else {
        expect(snap.slPrice!, greaterThan(snap.tpPrice!));
      }
    });

    test('extractOpenPosition: true drops the End-of-Data sentinel trade', () {
      // The default path force-closes the position with reason 'End of Data'
      // → trades contains one extra sentinel trade. The opt-in path drops
      // that sentinel and surfaces the position via openPosition instead.
      final candles = _lcgFixture(400);

      final defaultRun = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: _fastBbRsi,
      );
      final extractedRun = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: _fastBbRsi,
        extractOpenPosition: true,
      );

      // The number of trades drops by exactly one when an open position
      // exists. If the fixture happens to NOT leave a position open at the
      // last bar, both runs would tie — but the previous test asserts the
      // fixture does leave one open, so we know the delta here is 1.
      expect(extractedRun.trades.length, defaultRun.trades.length - 1,
          reason: 'extractOpenPosition: true must drop exactly the sentinel '
              "'End of Data' trade from the trades list.");
      // No remaining trade should carry the sentinel exitReason.
      final hasSentinel = extractedRun.trades.any(
          (t) => t.exitReason == 'End of Data');
      expect(hasSentinel, isFalse,
          reason: 'End of Data sentinel trade must be absent from the '
              'extracted-path trades list.');
    });

    test('extractOpenPosition: true works for UT-Bot and Ichimoku too', () {
      final candles = _lcgFixture(400);

      // Both strategies use the same engine end-of-data branch so we just
      // exercise the path here — strict signal-firing is covered by the
      // BB+RSI tests above.
      final ut = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: const UtBotParams(emaPeriod: 50, atrPeriod: 14),
        extractOpenPosition: true,
      );
      final ich = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: const IchimokuParams(),
        extractOpenPosition: true,
      );

      // Whether or not these fixtures happen to trigger a position, the
      // openPosition contract must hold (null or fully populated, no
      // half-baked snapshot leaking through).
      for (final snap in [ut.openPosition, ich.openPosition]) {
        if (snap != null) {
          expect(snap.entryPrice.isFinite, isTrue);
          expect(snap.quantity, greaterThan(0));
          if (snap.slPrice != null) expect(snap.slPrice!.isFinite, isTrue);
          if (snap.tpPrice != null) expect(snap.tpPrice!.isFinite, isTrue);
        }
      }
    });
  });

  group('B4.2-1: OpenPositionSnapshot value semantics', () {
    test('equality compares all fields incl. null SL/TP', () {
      const a = OpenPositionSnapshot(
        direction: 'LONG',
        openedAt: 1700000000000,
        entryPrice: 100.0,
        quantity: 1.5,
        entryFee: 0.6,
        slPrice: 95.0,
        tpPrice: 115.0,
      );
      const b = OpenPositionSnapshot(
        direction: 'LONG',
        openedAt: 1700000000000,
        entryPrice: 100.0,
        quantity: 1.5,
        entryFee: 0.6,
        slPrice: 95.0,
        tpPrice: 115.0,
      );
      const c = OpenPositionSnapshot(
        direction: 'LONG',
        openedAt: 1700000000000,
        entryPrice: 100.0,
        quantity: 1.5,
        entryFee: 0.6,
        // SL / TP intentionally omitted → null
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.isLong, isTrue);
      expect(c.isLong, isTrue);
    });
  });
}
