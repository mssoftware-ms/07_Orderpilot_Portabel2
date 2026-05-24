/// Dart-fallback backtest tests for the Ichimoku Cloud Retest strategy
/// (`BacktestService.runIchimoku`).
///
/// Welle I2-4 contract:
/// - Dart-fallback engine reproduces deterministically across runs on
///   the same input (no hidden RNG / time-of-day branching). Same
///   contract as `runBbRsi` / `runUtBot`; pinned here as a separate
///   regression so a future engine-wide change cannot silently regress.
/// - The execution loop reuses the F-04 Step A/B/C/D ordering of
///   [BacktestService.runBbRsi] / [BacktestService.runUtBot] so
///   SL/TP/BE-trail semantics stay identical across all three Phase-2
///   strategies.
/// - Indicator-level Dart↔Rust parity is owned by the shared reference
///   values in `test/services/indicators_test.dart` — every Tenkan /
///   Kijun / Senkou / score value lines up bit-for-bit between the two
///   engines, so a strategy-level divergence can only come from the
///   execution-loop layer (this file) or the 5-confluence wiring in
///   `backtest_service.dart::runIchimoku`.
///
/// Strict-spec defaults vs synthetic fixtures:
///   The strict-spec 5-confluence (price + future cloud + tenkan/kijun +
///   chikou + score ≥ +60) is hard to trigger on small synthetic
///   fixtures — same observation as UT-Bot Welle U2-4. We therefore
///   test runIchimoku on a 200-candle ramp-up shape that DOES trigger
///   at least one EnterLong (with the strict-spec defaults), and on a
///   flat shape that produces ZERO entries (no false positives).
///   Real-data acceptance is owned by Welle I3 (BTCUSDT 1h backtest).
///
/// Cross-engine FFI parity is covered by
/// `test/integration/dart_rust_ichimoku_parity_test.dart` (Welle I2-5).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';

void main() {
  group('BacktestService.runIchimoku', () {
    /// 200-candle linear up-ramp. Strong steady drift → past-cloud
    /// anchors trail price; once warm-up (103 bars) clears, the
    /// 5-confluence has every chance to fire. Same shape as the Rust
    /// `uptrend_fixture(130)` in `addins/ichimoku.rs` tests, just
    /// longer so the BacktestService end-to-end loop has runway past
    /// the first entry.
    List<CandleData> uptrendFixture200() {
      const baseTs = 1700000000000;
      return [
        for (int i = 0; i < 200; i++)
          CandleData(
            timestamp: baseTs + i * 3600000, // 1h candles
            open: 100.0 + i * 0.5 - 0.2,
            high: 100.0 + i * 0.5 + 0.3,
            low: 100.0 + i * 0.5 - 0.3,
            close: 100.0 + i * 0.5,
            volume: 1000.0 + i,
          ),
      ];
    }

    /// Flat fixture: constant OHLCV. With strict `>` everywhere in the
    /// 5-confluence (Spec §12.5) and the score-component conditions
    /// likewise strict, zero entries can fire.
    List<CandleData> flatFixture200() {
      const baseTs = 1700000000000;
      return [
        for (int i = 0; i < 200; i++)
          CandleData(
            timestamp: baseTs + i * 3600000,
            open: 100.0,
            high: 101.0,
            low: 99.0,
            close: 100.0,
            volume: 1000.0,
          ),
      ];
    }

    test('runs end-to-end on uptrend fixture with default params', () {
      final candles = uptrendFixture200();
      final result = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0006,
      );

      // candlesProcessed reflects the input length unconditionally
      // (Step D runs for every bar including warm-up).
      expect(
        result.metrics.candlesProcessed,
        equals(candles.length),
        reason: 'every input candle must be touched by the equity-update step',
      );
      expect(
        result.equityCurve.length,
        equals(candles.length),
        reason: 'equity curve must cover the same bars as the input',
      );
      // Strict-spec defaults on a clean uptrend MUST trigger at least
      // one entry past the 103-bar warm-up — same fixture as the
      // Rust strategy-level integration test pins. If this fails after
      // a strategy change, investigate the 5-confluence wiring rather
      // than relaxing the assertion.
      expect(
        result.metrics.totalTrades,
        greaterThan(0),
        reason: 'uptrend fixture must trigger ≥ 1 Ichimoku entry past warm-up',
      );
    });

    test('flat fixture produces zero entries (strict `>` semantics)', () {
      final candles = flatFixture200();
      final result = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0006,
      );
      expect(
        result.metrics.totalTrades,
        equals(0),
        reason: 'flat OHLCV must never satisfy any of the strict `>` '
            'confluence components — degenerate equality on every '
            'comparison is by-design rejected (Spec §12.5)',
      );
    });

    test('reproducibility: 3x runs are bit-exact on same fixture', () {
      final candles = uptrendFixture200();
      BacktestResult run() => BacktestService.runIchimoku(
            candles: candles,
            initialBalance: 10000.0,
            feeRate: 0.0006,
          );

      final r1 = run();
      final r2 = run();
      final r3 = run();
      expect(r2.metrics.totalPnl, equals(r1.metrics.totalPnl));
      expect(r3.metrics.totalPnl, equals(r1.metrics.totalPnl));
      expect(r2.metrics.totalTrades, equals(r1.metrics.totalTrades));
      expect(r2.metrics.winRate, equals(r1.metrics.winRate));
      expect(r2.metrics.maxDrawdown, equals(r1.metrics.maxDrawdown));
      expect(r2.metrics.sharpeRatio, equals(r1.metrics.sharpeRatio));
    });

    test('insufficient candles returns empty result without crashing', () {
      // 50 candles is below the 103-bar warm-up gate; the engine must
      // return an empty BacktestResult rather than panicking.
      const baseTs = 1700000000000;
      final candles = [
        for (int i = 0; i < 50; i++)
          CandleData(
            timestamp: baseTs + i * 3600000,
            open: 100.0,
            high: 101.0,
            low: 99.0,
            close: 100.0,
            volume: 1000.0,
          ),
      ];
      final result = BacktestService.runIchimoku(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0006,
      );
      expect(result.metrics.totalTrades, equals(0));
      expect(result.trades, isEmpty);
      expect(result.equityCurve, isEmpty);
      expect(result.metrics.candlesProcessed, equals(50));
    });

    // ── Welle R2-4 ADX regime filter wiring ────────────────────────────
    //
    // Uses the same uptrend fixture as the smoke test (known to trigger
    // ≥ 1 Ichimoku entry). DI-confluence semantics are pinned bit-for-
    // bit on the helper by
    // `test/services/strategy_common_test.dart::regimePassesFilter`.

    test('ADX filter disabled = baseline on Ichimoku uptrend fixture', () {
      final candles = uptrendFixture200();
      final baseline = BacktestService.runIchimoku(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
      );
      final explicit = BacktestService.runIchimoku(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
        params: const IchimokuParams(adxFilterEnabled: false),
      );
      expect(baseline.metrics.totalTrades, greaterThan(0));
      expect(explicit.metrics.totalTrades,
          equals(baseline.metrics.totalTrades));
      expect(explicit.metrics.totalPnl, equals(baseline.metrics.totalPnl));
    });

    test('ADX filter high threshold blocks all Ichimoku entries', () {
      // Pure-linear uptrend drives ADX close to 100 → threshold above
      // the max-possible value is needed to guarantee blocking. 200 is
      // outside the manifest schema range but the engine path runs the
      // gate without validating, so it cleanly pins parameter consumption.
      final candles = uptrendFixture200();
      final blocked = BacktestService.runIchimoku(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
        params: const IchimokuParams(
          adxFilterEnabled: true,
          adxThreshold: 200.0,
          adxPeriod: 14,
        ),
      );
      expect(blocked.metrics.totalTrades, equals(0));
    });

    test('ADX filter threshold 0 + no confluence = baseline Ichimoku', () {
      // adx_period=5 → warmup 8 bars ≪ 103-bar Ichimoku gate → ADX is
      // always finite by the time the entry block runs → pure pass-
      // through under threshold=0 + no confluence.
      final candles = uptrendFixture200();
      final baseline = BacktestService.runIchimoku(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
      );
      final passthrough = BacktestService.runIchimoku(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
        params: const IchimokuParams(
          adxFilterEnabled: true,
          adxThreshold: 0.0,
          adxPeriod: 5,
          adxUseDiConfluence: false,
        ),
      );
      expect(passthrough.metrics.totalTrades,
          equals(baseline.metrics.totalTrades));
      expect(passthrough.metrics.totalPnl,
          equals(baseline.metrics.totalPnl));
    });
  });
}
