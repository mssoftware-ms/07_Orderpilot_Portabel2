import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';

void main() {
  group('BacktestService', () {
    // Generate synthetic candle data with a trend + mean-reversion pattern
    List<CandleData> _generateCandles(int count, {double startPrice = 50000}) {
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
      final candles = _generateCandles(5);
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
      final candles = _generateCandles(500);
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
      final candles = _generateCandles(500);
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
      final candles = _generateCandles(500);
      final result1 = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: const BbRsiParams(bbPeriod: 10, rsiPeriod: 7),
      );
      final result2 = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0006,
        params: const BbRsiParams(bbPeriod: 30, rsiPeriod: 21),
      );

      // Different params should produce different results
      // (not necessarily, but with synthetic data they should differ)
      expect(result1.metrics.totalTrades != result2.metrics.totalTrades ||
             result1.metrics.totalPnl != result2.metrics.totalPnl, isTrue);
    });

    test('fees are tracked correctly', () {
      final candles = _generateCandles(500);
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
      final candles = _generateCandles(200);
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
      final candles = _generateCandles(500);
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

  group('TradeRecord', () {
    test('isWin returns correctly', () {
      const winner = TradeRecord(
        entryTimestamp: 0, exitTimestamp: 1,
        direction: 'LONG', entryPrice: 100, exitPrice: 110,
        quantity: 1, pnl: 10, pnlPercent: 10, fees: 0.1,
        exitReason: 'TP',
      );
      const loser = TradeRecord(
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
