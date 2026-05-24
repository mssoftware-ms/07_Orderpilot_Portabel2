/// Dart-fallback backtest tests for the UT Bot Alerts strategy
/// (`BacktestService.runUtBot`).
///
/// Welle U2-4 contract:
/// - Dart-fallback engine reproduces deterministically across runs on
///   the same input (no hidden RNG / time-of-day branching).
/// - The execution loop reuses the F-04 Step A/B/C/D ordering of
///   [BacktestService.runBbRsi] so SL/TP/BE-trail semantics stay
///   identical between the two strategies.
/// - Indicator-level Dart↔Rust parity is owned by the shared
///   reference values in `test/services/indicators_test.dart` — every
///   ATR / SMI / trail value lines up bit-for-bit between the two
///   engines, so a strategy-level divergence can only come from the
///   execution-loop layer (this file).
///
/// Welle U2-4 ESKALATIONS-MARKER (per task description):
///   On purely-synthetic fixtures the strict spec confluence
///   (EMA-trend + UT-Bot direction flip + SMI cross-up-below-zero)
///   tends to produce ZERO trades — the three indicators rarely align
///   on a synthetic candle path because SMI shoots above zero faster
///   than the trail flips after a sharp reversal, and on gentle
///   recoveries the trail never flips at all. This is the
///   "0 trades on parity fixture" case flagged in the Welle-U2 plan.
///   The decision (strict-below-zero vs CC-Empfehlung
///   `cross-OVER-zero relaxation`) is owned by Welle U3 with real
///   market data; see the Welle-U2 final brief.
///
/// Cross-engine FFI parity through the full UT-Bot strategy is
/// intentionally out of scope here — it requires a new
/// `run_ut_bot_backtest` FRB endpoint + codegen pass; tracked as a
/// follow-up commit (see Welle-U2 final brief).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';

void main() {
  group('BacktestService.runUtBot', () {
    /// 200-candle synthesis fixture: ramp-up + downtrend + slow recovery
    /// + final surge. Walks every code path (warm-up gate clears, all
    /// indicators populate, pending-order queue cycles) without
    /// requiring any specific signal to fire — that decision is owned
    /// by Welle U3 on real BTCUSDT data.
    List<CandleData> synthFixture200() {
      const baseTs = 1700000000000;
      final closes = <double>[];
      for (int i = 0; i < 50; i++) {
        closes.add(100.0 + i * 0.4); // 100 → 119.6
      }
      for (int i = 0; i < 100; i++) {
        closes.add(120.0 - (i + 1) * 0.4); // 119.6 → 80
      }
      for (int i = 0; i < 50; i++) {
        closes.add(80.0 + (i + 1) * 0.4); // 80.4 → 100
      }
      return [
        for (int i = 0; i < closes.length; i++)
          CandleData(
            timestamp: baseTs + i * 300_000,
            open: closes[i] - 0.5,
            high: closes[i] + 1.0,
            low: closes[i] - 1.0,
            close: closes[i],
            volume: 1000.0 + i,
          ),
      ];
    }

    // Fast-warm-up parameter set so the 200-bar fixture clears warm-up
    // far inside the candle window. Spec-defaults (ema=200, smi=14/5/3)
    // are exercised through the Welle U3 BTCUSDT 5min backtest.
    const fastParams = UtBotParams(
      emaPeriod: 30,
      keyValue: 1.0,
      atrPeriod: 1,
      smiLength: 5,
      smiKSmoothing: 3,
      smiDSmoothing: 3,
      swingLookbackBars: 5,
      tpRrRatio: 2.0,
      riskPerTrade: 0.02,
    );

    test('returns empty result when candles below EMA warm-up', () {
      final candles = [
        for (int i = 0; i < 20; i++)
          CandleData(
            timestamp: i * 60000,
            open: 100,
            high: 101,
            low: 99,
            close: 100,
            volume: 1,
          ),
      ];
      final result = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0,
        // Spec default emaPeriod=200 → 20 candles < 200 → empty result.
      );
      expect(result.metrics.totalTrades, 0);
      expect(result.trades, isEmpty);
      expect(result.metrics.candlesProcessed, 20);
    });

    test('runs end-to-end on 200-candle synthesis fixture without panic', () {
      // Welle U2-4 plan: "200-Candle-Parity-Fixture" must at minimum
      // run cleanly end-to-end. Whether it produces trades is a
      // separate concern owned by Welle U3 — see ESKALATIONS-MARKER
      // in the library header.
      final candles = synthFixture200();
      final result = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0006,
        params: fastParams,
      );
      expect(result.metrics.candlesProcessed, candles.length);
      // Equity curve covers every bar (Step D fires unconditionally).
      expect(result.equityCurve.length, candles.length);
      // Trade list is well-formed regardless of count (may be 0 on this
      // synthetic fixture — Welle-U3 real-data backtest is the actual
      // signal-emission gate).
      expect(result.metrics.totalTrades, greaterThanOrEqualTo(0));
      expect(result.trades.length, result.metrics.totalTrades);
    });

    test('deterministic: 3 identical runs produce identical metrics', () {
      // The Dart engine has no hidden RNG / time-of-day branching, so
      // three runs over the same fixture must agree bit-for-bit. This
      // pins the determinism contract that the F-01 parity test relies
      // on (same input → same output, with no float-noise drift). The
      // assertion is meaningful even when `totalTrades == 0` because
      // it covers the equity curve point-by-point.
      final candles = synthFixture200();
      final r1 = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0006,
        params: fastParams,
      );
      final r2 = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0006,
        params: fastParams,
      );
      final r3 = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0006,
        params: fastParams,
      );
      expect(r2.metrics.totalPnl, equals(r1.metrics.totalPnl));
      expect(r3.metrics.totalPnl, equals(r1.metrics.totalPnl));
      expect(r2.metrics.totalTrades, equals(r1.metrics.totalTrades));
      expect(r2.metrics.winRate, equals(r1.metrics.winRate));
      expect(r2.metrics.profitFactor, equals(r1.metrics.profitFactor));
      expect(r2.metrics.maxDrawdown, equals(r1.metrics.maxDrawdown));
      expect(r2.metrics.sharpeRatio, equals(r1.metrics.sharpeRatio));
      expect(r2.equityCurve.length, r1.equityCurve.length);
      for (int i = 0; i < r1.equityCurve.length; i++) {
        expect(r2.equityCurve[i].equity, r1.equityCurve[i].equity,
            reason: 'equity drift at index $i');
        expect(r2.equityCurve[i].drawdown, r1.equityCurve[i].drawdown);
      }
      for (int i = 0; i < r1.trades.length; i++) {
        expect(r2.trades[i].entryTimestamp, r1.trades[i].entryTimestamp);
        expect(r2.trades[i].exitTimestamp, r1.trades[i].exitTimestamp);
        expect(r2.trades[i].entryPrice, r1.trades[i].entryPrice);
        expect(r2.trades[i].exitPrice, r1.trades[i].exitPrice);
        expect(r2.trades[i].pnl, r1.trades[i].pnl);
      }
    });

    test('default params on real-shape fixture also run without panic', () {
      // Spec-default params (ema=200, smi=14/5/3) require ≥ 200 bars
      // warm-up. Provide a 400-bar fixture so we exercise the same
      // execution path used by the eventual BTCUSDT 5min backtest.
      const baseTs = 1700000000000;
      final closes = <double>[];
      for (int i = 0; i < 400; i++) {
        final base = 100.0 + 0.02 * i;
        final phase = 6.283185307 * i / 80.0;
        final wave = 6.0 *
            (1 -
                0.5 * (i % 80) / 40.0 +
                0.3 * (phase % 1.0)); // crude pseudo-sinusoid
        closes.add(base + wave);
      }
      final candles = [
        for (int i = 0; i < closes.length; i++)
          CandleData(
            timestamp: baseTs + i * 300_000,
            open: closes[i] - 0.3,
            high: closes[i] + 0.7,
            low: closes[i] - 0.7,
            close: closes[i],
            volume: 1000.0 + i,
          ),
      ];
      final result = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0006,
      );
      expect(result.metrics.candlesProcessed, candles.length);
      expect(result.equityCurve.length, candles.length);
    });

    test('smi_cross_above_zero toggle produces different trade list', () {
      // Path-B toggle (Spec §12.5): same fixture, same other params, only
      // the zero-line gate flips. The strict-spec run and the relaxed run
      // MUST NOT produce identical trade lists — otherwise the toggle is
      // not actually wired through. We don't pin "more" or "fewer" trades
      // here because that depends on the fixture; we only pin "different".
      //
      // Fixture: 400-bar LCG random walk (seed 12345, ±3.3 step, clamped
      // to [80,120]) — same shape as the FFI parity test, picked because
      // it actually fires UT-Bot entries on the strict spec while the
      // 200-bar designed synth shapes do not.
      final candles = <CandleData>[];
      int s = 12345;
      double price = 100.0;
      final closes = <double>[price];
      while (closes.length < 400) {
        s = (s * 1103515245 + 12345) & 0x7fffffff;
        final step = ((s % 200) - 100) / 30.0;
        price = (price + step).clamp(80.0, 120.0);
        closes.add(price);
      }
      const baseTs = 1700000000000;
      for (int i = 0; i < closes.length; i++) {
        candles.add(CandleData(
          timestamp: baseTs + i * 300000,
          open: closes[i] - 0.3,
          high: closes[i] + 1.2,
          low: closes[i] - 1.2,
          close: closes[i],
          volume: 1000.0 + i,
        ));
      }

      final strict = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0,
        params: fastParams,
      );
      final relaxed = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000,
        feeRate: 0.0,
        params: const UtBotParams(
          emaPeriod: 30,
          keyValue: 1.0,
          atrPeriod: 1,
          smiLength: 5,
          smiKSmoothing: 3,
          smiDSmoothing: 3,
          swingLookbackBars: 5,
          tpRrRatio: 2.0,
          smiCrossAboveZero: true,
        ),
      );
      expect(
        strict.metrics.totalTrades + relaxed.metrics.totalTrades,
        greaterThan(0),
        reason: 'fixture must trigger at least one entry across the two '
            'modes; otherwise the toggle assertion is vacuous',
      );
      expect(
        relaxed.metrics.totalTrades,
        isNot(equals(strict.metrics.totalTrades)),
        reason: 'cross_above_zero toggle must change the trade count on a '
            'fixture that fires entries — otherwise the parameter is not '
            'reaching `detect_entry`',
      );
    });

    test('session filter never increases the trade count vs filter-off', () {
      // Lower-bound sanity: enabling the filter cannot produce MORE
      // trades than disabling it (the filter only ever blocks entries).
      // True whether the unfiltered run produces 0 or N trades.
      final candles = synthFixture200();
      final filtered = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0,
        params: const UtBotParams(
          emaPeriod: 30,
          keyValue: 1.0,
          atrPeriod: 1,
          smiLength: 5,
          smiKSmoothing: 3,
          smiDSmoothing: 3,
          swingLookbackBars: 5,
          tpRrRatio: 2.0,
          sessionFilterEnabled: true,
          sessionStartHourLocal: 12,
          sessionEndHourLocal: 14,
        ),
      );
      final unfiltered = BacktestService.runUtBot(
        candles: candles,
        initialBalance: 10000.0,
        feeRate: 0.0,
        params: fastParams,
      );
      expect(
        filtered.metrics.totalTrades,
        lessThanOrEqualTo(unfiltered.metrics.totalTrades),
      );
    });

    // ── Welle R2-3 ADX regime filter wiring ─────────────────────────
    //
    // Uses the same LCG fixture as the dart_rust_ut_bot_parity test —
    // known to trigger ≥ 1 UT-Bot entry on the fast-warmup parameter
    // set so the "disabled = baseline" pin is not a tautology. DI-
    // confluence semantics are pinned bit-for-bit on the helper by
    // `test/services/strategy_common_test.dart::regimePassesFilter`.

    List<CandleData> lcgFixture400() {
      final closes = <double>[];
      int s = 12345;
      double price = 100.0;
      closes.add(price);
      while (closes.length < 400) {
        s = (s * 1103515245 + 12345) & 0x7fffffff;
        final step = ((s % 200) - 100) / 30.0;
        price = (price + step).clamp(80.0, 120.0);
        closes.add(price);
      }
      const baseTs = 1700000000000;
      return [
        for (int i = 0; i < closes.length; i++)
          CandleData(
            timestamp: baseTs + i * 300000,
            open: closes[i] - 0.3,
            high: closes[i] + 1.2,
            low: closes[i] - 1.2,
            close: closes[i],
            volume: 1000.0 + i,
          ),
      ];
    }

    test('ADX filter disabled = baseline on UT-Bot LCG fixture', () {
      final candles = lcgFixture400();
      final baseline = BacktestService.runUtBot(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
        params: fastParams,
      );
      final explicit = BacktestService.runUtBot(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
        params: const UtBotParams(
          emaPeriod: 30, keyValue: 1.0, atrPeriod: 1,
          smiLength: 5, smiKSmoothing: 3, smiDSmoothing: 3,
          swingLookbackBars: 5, tpRrRatio: 2.0, riskPerTrade: 0.02,
          adxFilterEnabled: false,
        ),
      );
      expect(baseline.metrics.totalTrades, greaterThan(0));
      expect(explicit.metrics.totalTrades,
          equals(baseline.metrics.totalTrades));
      expect(explicit.metrics.totalPnl, equals(baseline.metrics.totalPnl));
    });

    test('ADX filter high threshold blocks all UT-Bot entries', () {
      final candles = lcgFixture400();
      final blocked = BacktestService.runUtBot(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
        params: const UtBotParams(
          emaPeriod: 30, keyValue: 1.0, atrPeriod: 1,
          smiLength: 5, smiKSmoothing: 3, smiDSmoothing: 3,
          swingLookbackBars: 5, tpRrRatio: 2.0, riskPerTrade: 0.02,
          adxFilterEnabled: true,
          adxThreshold: 100.0,
          adxPeriod: 14,
        ),
      );
      expect(blocked.metrics.totalTrades, equals(0));
    });

    test('ADX filter threshold 0 + no confluence = baseline UT-Bot', () {
      // adx_period=5 → warmup 8 bars ≪ ema=30 + smi gate → pass-through.
      final candles = lcgFixture400();
      final baseline = BacktestService.runUtBot(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
        params: fastParams,
      );
      final passthrough = BacktestService.runUtBot(
        candles: candles, initialBalance: 10000.0, feeRate: 0.0006,
        params: const UtBotParams(
          emaPeriod: 30, keyValue: 1.0, atrPeriod: 1,
          smiLength: 5, smiKSmoothing: 3, smiDSmoothing: 3,
          swingLookbackBars: 5, tpRrRatio: 2.0, riskPerTrade: 0.02,
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
