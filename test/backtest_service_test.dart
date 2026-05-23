import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/core/models/trade.dart';
import 'package:trading_app/services/backtest_service.dart';

void main() {
  group('BacktestService', () {
    // Generate synthetic candle data with a trend + mean-reversion pattern
    List<CandleData> generateCandles(int count, {double startPrice = 50000}) {
      final candles = <CandleData>[];
      double price = startPrice;
      final baseTs = DateTime(2024, 1, 1).millisecondsSinceEpoch;

      for (int i = 0; i < count; i++) {
        // Create a sinusoidal price pattern to trigger BB+RSI entries
        final wave = 2000 * (i % 60 < 30 ? -1.0 + (i % 30) / 15.0 : 1.0 - ((i % 30)) / 15.0);
        price = startPrice + wave;
        final high = price + 100;
        final low = price - 100;
        candles.add(CandleData(
          timestamp: baseTs + i * 3600000, // 1h candles
          open: price - 20,
          high: high,
          low: low,
          close: price,
          volume: 1000 + i.toDouble(),
        ));
      }
      return candles;
    }

    test('returns empty result for insufficient data', () {
      final candles = generateCandles(5);
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
      );

      expect(result.metrics.totalTrades, 0);
      expect(result.trades, isEmpty);
      expect(result.equityCurve, isEmpty);
    });

    test('runs successfully with sufficient candle data', () {
      final candles = generateCandles(500);
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
      );

      expect(result.equityCurve.length, candles.length);
      expect(result.metrics.candlesProcessed, candles.length);
      // Initial equity should match initial balance
      expect(result.equityCurve.first.equity, 10000.0);
    });

    test('metrics fields are consistent', () {
      final candles = generateCandles(500);
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
      );

      final m = result.metrics;
      expect(m.totalTrades, m.winningTrades + m.losingTrades);
      if (m.totalTrades > 0) {
        expect(m.winRate, closeTo((m.winningTrades / m.totalTrades) * 100, 0.01));
      }
      expect(m.profitFactor, greaterThanOrEqualTo(0));
      expect(m.profitFactor, lessThanOrEqualTo(999.99));
      expect(m.maxDrawdownPercent, greaterThanOrEqualTo(0));
    });

    test('custom params are respected', () {
      // Phase-2 trend-follow + RSI cross trigger needs a dip+surge
      // pattern to produce trades; the triangular wave from
      // generateCandles doesn't align the cross with the close-extreme.
      // Build a small dip+surge inline so both BB(10) and BB(30) on
      // pinned Phase-1 SMA + RSI(7)/RSI(21) generate non-identical
      // engine output.
      final candles = <CandleData>[];
      final baseTs = DateTime(2024, 1, 1).millisecondsSinceEpoch;
      for (int i = 0; i < 25; i++) {
        candles.add(CandleData(
          timestamp: baseTs + i * 3600000,
          open: 99.9, high: 100.3, low: 99.7, close: 100.0, volume: 1000.0,
        ));
      }
      for (int i = 0; i < 14; i++) {
        final close = 100.0 - (i + 1) * 2.0;
        candles.add(CandleData(
          timestamp: baseTs + (25 + i) * 3600000,
          open: close + 0.5, high: close + 0.5, low: close - 0.5,
          close: close, volume: 1000.0,
        ));
      }
      candles.add(CandleData(
        timestamp: baseTs + 39 * 3600000,
        open: 72.5, high: 120.5, low: 72.0, close: 120.0, volume: 1000.0,
      ));
      candles.add(CandleData(
        timestamp: baseTs + 40 * 3600000,
        open: 119.0, high: 120.0, low: 0.0, close: 110.0, volume: 1000.0,
      ));
      for (int i = 41; i < 100; i++) {
        candles.add(CandleData(
          timestamp: baseTs + i * 3600000,
          open: 110.0, high: 110.5, low: 109.5, close: 110.0, volume: 1000.0,
        ));
      }

      // Custom-params discriminator post-D-07: with swing-low SL the basis
      // (SMA vs EMA) no longer drives SL placement, so we discriminate via
      // bbStdDev. result1 uses a narrow band (σ=1.0) → the surge close=120
      // exceeds upper(≈97) → signal fires + SL trade. result2 uses a wide
      // band (σ=4.0) → upper(≈136) sits above close=120 → no signal fires.
      // The totalTrades differ on the same candle stream, which is exactly
      // what "custom params are respected" needs to prove.
      final result1 = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: const BbRsiParams(
          bbPeriod: 10,
          bbStdDev: 1.0,
          bbMaType: BbMaType.sma,
          rsiPeriod: 7,
          rsiOversold: 30.0,
          rsiOverbought: 70.0,
          swingLookbackBars: 20,
        ),
      );
      final result2 = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: const BbRsiParams(
          bbPeriod: 10,
          bbStdDev: 4.0,
          bbMaType: BbMaType.sma,
          rsiPeriod: 7,
          rsiOversold: 30.0,
          rsiOverbought: 70.0,
          swingLookbackBars: 20,
        ),
      );

      expect(
        result1.metrics.totalTrades != result2.metrics.totalTrades ||
            result1.metrics.totalPnl != result2.metrics.totalPnl,
        isTrue,
      );
    });

    test('fees are tracked correctly', () {
      final candles = generateCandles(500);
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.001, // 0.1% fee
      );

      if (result.trades.isNotEmpty) {
        final tradeFees = result.trades.fold<double>(0, (s, t) => s + t.fees);
        expect(result.metrics.totalFees, closeTo(tradeFees, 0.01));
        expect(result.metrics.totalFees, greaterThan(0));
      }
    });

    test('equity curve timestamps are monotonically increasing', () {
      final candles = generateCandles(200);
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
      );

      for (int i = 1; i < result.equityCurve.length; i++) {
        expect(result.equityCurve[i].timestamp,
            greaterThan(result.equityCurve[i - 1].timestamp));
      }
    });

    test('trade records have valid timestamps and prices', () {
      final candles = generateCandles(500);
      final result = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
      );

      for (final trade in result.trades) {
        expect(trade.exitTimestamp, greaterThanOrEqualTo(trade.entryTimestamp));
        expect(trade.entryPrice, greaterThan(0));
        expect(trade.exitPrice, greaterThan(0));
        expect(trade.quantity, greaterThan(0));
        expect(trade.direction, anyOf('LONG', 'SHORT'));
        expect(trade.exitReason, isNotEmpty);
      }
    });
  });

  group('EquityPoint', () {
    test('holds correct data', () {
      const ep = EquityPoint(
        timestamp: 1000000,
        equity: 10500.0,
        drawdown: 100.0,
        drawdownPct: 0.95,
      );
      expect(ep.timestamp, 1000000);
      expect(ep.equity, 10500.0);
    });
  });

  group('ClosedTrade', () {
    test('isWin returns correctly', () {
      const winner = ClosedTrade(
        entryTimestamp: 0, exitTimestamp: 1,
        direction: 'LONG', entryPrice: 100, exitPrice: 110,
        quantity: 1, pnl: 10, pnlPercent: 10, fees: 0.1,
        exitReason: 'TP',
      );
      const loser = ClosedTrade(
        entryTimestamp: 0, exitTimestamp: 1,
        direction: 'SHORT', entryPrice: 100, exitPrice: 110,
        quantity: 1, pnl: -10, pnlPercent: -10, fees: 0.1,
        exitReason: 'SL',
      );
      expect(winner.isWin, isTrue);
      expect(loser.isWin, isFalse);
    });
  });
}
