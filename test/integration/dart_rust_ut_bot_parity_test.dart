/// F-01 Dart ↔ Rust UT Bot backtest parity regression.
///
/// Pins the contract that the native Rust engine (via flutter_rust_bridge)
/// and the pure-Dart fallback engine produce numerically identical results
/// for the UT Bot Alerts (verbesserte Variante) strategy on a fixed
/// deterministic candle fixture.
///
/// Test surface (Welle U2-5):
///
///   1. `ut bot parity smoke` — fixture must produce a non-zero Dart
///      trade count so the numerical assertions below cannot become
///      tautologies of `0 == 0`. We use the same fast-warm-up parameter
///      set as `test/services/ut_bot_backtest_test.dart` rather than the
///      strict spec defaults (ema=200) because the latter would require
///      ≥ 200 active bars beyond warm-up and we still want a compact
///      fixture. The Phase-2 acceptance backtest exercises the strict
///      defaults on real BTCUSDT 5min data (Welle U3 Test 1).
///
///   2. `ut bot parity numerical` — totalPnl, winRate, sharpe, drawdown
///      must match between engines within 1e-9. Tolerance mirrors the
///      BB+RSI parity test (`dart_rust_parity_test.dart`) — any wider
///      drift indicates real engine divergence (fee ordering, rounding
///      mode, indicator formula) and MUST be investigated rather than
///      papered over.
///
///   3. `ut bot parity determinism` — repeating each engine three times
///      on the same fixture produces bit-identical metrics. Pins the
///      "no hidden RNG / no time-of-day branching" invariant on both
///      sides of the bridge.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/rust_bridge.dart';

/// 400 deterministic candles produced by a fixed linear-congruential
/// random walk around a 100 baseline (clamped to [80, 120]). The chaotic
/// micro-reversals of a random walk happen to align the three UT-Bot
/// confluence conditions (EMA trend, ATR-trail direction flip, SMI cross
/// while still on the matching side of zero) often enough to trigger
/// both Long AND Short entries on the strict spec — a property that
/// every "designed" shape we probed in Welle U2-5 (pure sinusoid,
/// triangular wave, drop+recovery, sawtooth, square wave) failed to
/// have, because directional flips and SMI crosses kept landing on
/// different bars. See `test/services/ut_bot_backtest_test.dart`
/// ESKALATIONS-MARKER for the same observation on the U2-4 synth shape.
///
/// The LCG (`s = s * 1103515245 + 12345`, mask to 31 bits, seed 12345)
/// is the textbook glibc rand48 lower bits — fully deterministic and
/// reproduces bit-identically on any platform. Step size is bounded to
/// ~±3.3 so the random walk does not drift outside the clamp window.
///
/// All values are IEEE-754 f64 and round-trip cleanly through JSON, so
/// the same candle stream reaches the Rust engine bit-identical.
List<CandleData> _generateFixture() {
  final closes = <double>[];
  int s = 12345;
  double price = 100.0;
  closes.add(price);
  while (closes.length < 400) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    final step = ((s % 200) - 100) / 30.0; // ~[-3.3, +3.3]
    price = (price + step).clamp(80.0, 120.0);
    closes.add(price);
  }

  const baseTs = 1700000000000; // 2023-11-14 22:13:20 UTC
  final candles = <CandleData>[
    for (int i = 0; i < closes.length; i++)
      CandleData(
        timestamp: baseTs + i * 300000, // 5-minute candles
        open: closes[i] - 0.3,
        high: closes[i] + 1.2,
        low: closes[i] - 1.2,
        close: closes[i],
        volume: 1000.0 + i,
      ),
  ];
  assert(candles.length == 400, 'fixture must be 400 candles, got ${candles.length}');
  return candles;
}

/// Same fast-warm-up parameter set used by
/// `test/services/ut_bot_backtest_test.dart` so the parity test stays
/// decoupled from the strict-spec ema=200 defaults — Welle U3 owns the
/// real-data backtest at those defaults.
const UtBotParams _fastParams = UtBotParams(
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

/// JSON params map mirroring [_fastParams] for the Rust FFI call. Keys
/// must match the `ut_bot_manifest()` parameter names bit-for-bit.
const Map<String, double> _fastParamsRust = {
  'ema_period': 30,
  'key_value': 1.0,
  'atr_period': 1,
  'smi_length': 5,
  'smi_k_smoothing': 3,
  'smi_d_smoothing': 3,
  'swing_lookback_bars': 5,
  'tp_rr_ratio': 2.0,
  'risk_per_trade': 0.02,
};

void main() {
  const initialBalance = 10000.0;
  const feeRate = 0.0006;

  setUpAll(() async {
    await RustBridge.initialize();
  });

  group('F-01 Dart ↔ Rust UT Bot parity', () {
    test('ut bot parity smoke: native available + sanity trade', () async {
      expect(
        RustBridge.isNativeAvailable,
        isTrue,
        reason:
            'native engine must be loaded; cargo build artefacts in '
            'rust/trading_engine/target/release/ are required for this test',
      );

      final candles = _generateFixture();
      final dartResult = BacktestService.runUtBot(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        params: _fastParams,
      );
      expect(
        dartResult.metrics.totalTrades,
        greaterThan(0),
        reason: 'fixture must trigger at least one UT-Bot entry on the Dart '
            'engine; otherwise the numerical parity asserts would be '
            'tautological. If this fails after a strategy change, redesign '
            'the fixture rather than weakening the assertion.',
      );
    });

    test('ut bot parity numerical: pnl/wr/sharpe/dd match within 1e-9',
        () async {
      final candles = _generateFixture();
      final dartResult = BacktestService.runUtBot(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        params: _fastParams,
      );

      final rustMetrics = await RustBridge.runUtBotBacktest(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        strategyParams: _fastParamsRust,
      );

      expect(
        rustMetrics.totalTrades,
        equals(dartResult.metrics.totalTrades),
        reason: 'totalTrades must match exactly — divergence here points to '
            'an entry-condition or warm-up-gate mismatch between engines',
      );
      expect(
        rustMetrics.totalPnl,
        closeTo(dartResult.metrics.totalPnl, 1e-9),
        reason: 'totalPnl divergence > 1e-9 indicates real engine drift — '
            'do NOT widen tolerance, investigate ordering/rounding instead',
      );
      expect(
        rustMetrics.winRate,
        closeTo(dartResult.metrics.winRate, 1e-9),
      );
      expect(
        rustMetrics.profitFactor,
        closeTo(dartResult.metrics.profitFactor, 1e-9),
      );

      final dartFinalEquity = initialBalance + dartResult.metrics.totalPnl;
      final rustFinalEquity = initialBalance + rustMetrics.totalPnl;
      expect(rustFinalEquity, closeTo(dartFinalEquity, 1e-9));

      // F-03b / F-03c: equity series and running-peak drawdown share a
      // single definition across engines, so Sharpe and drawdown must
      // also match at 1e-9.
      expect(
        rustMetrics.sharpeRatio,
        closeTo(dartResult.metrics.sharpeRatio, 1e-9),
      );
      expect(
        rustMetrics.maxDrawdown,
        closeTo(dartResult.metrics.maxDrawdown, 1e-9),
      );
      expect(
        rustMetrics.maxDrawdownPercent,
        closeTo(dartResult.metrics.maxDrawdownPercent, 1e-9),
      );

      // Sanity: dd and sharpe must be non-trivial so the asserts above
      // are not 0 == 0. (totalTrades > 0 is already pinned by the smoke
      // test; that gates the entire parity surface.)
      expect(dartResult.metrics.maxDrawdown, greaterThan(0.0));
      expect(rustMetrics.maxDrawdown, greaterThan(0.0));
    });

    test('ut bot parity determinism: 3x Dart and 3x Rust bit-exact',
        () async {
      // Determinism contract: same input → same output, no float-noise
      // drift across repeated runs. The Dart-fallback determinism test
      // (`test/services/ut_bot_backtest_test.dart`) already pins this for
      // the Dart engine; this test extends the contract across the FFI
      // boundary by exercising both engines three times.
      final candles = _generateFixture();

      final d1 = BacktestService.runUtBot(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        params: _fastParams,
      );
      final d2 = BacktestService.runUtBot(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        params: _fastParams,
      );
      final d3 = BacktestService.runUtBot(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        params: _fastParams,
      );

      expect(d2.metrics.totalPnl, equals(d1.metrics.totalPnl));
      expect(d3.metrics.totalPnl, equals(d1.metrics.totalPnl));
      expect(d2.metrics.totalTrades, equals(d1.metrics.totalTrades));

      final r1 = await RustBridge.runUtBotBacktest(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        strategyParams: _fastParamsRust,
      );
      final r2 = await RustBridge.runUtBotBacktest(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        strategyParams: _fastParamsRust,
      );
      final r3 = await RustBridge.runUtBotBacktest(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        strategyParams: _fastParamsRust,
      );

      expect(r2.totalPnl, equals(r1.totalPnl));
      expect(r3.totalPnl, equals(r1.totalPnl));
      expect(r2.totalTrades, equals(r1.totalTrades));
      expect(r2.sharpeRatio, equals(r1.sharpeRatio));
      expect(r2.maxDrawdown, equals(r1.maxDrawdown));
    });
  });
}
