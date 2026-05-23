/// F-01 Dart ↔ Rust BB+RSI backtest parity regression.
///
/// Pins the contract that the native Rust engine (via flutter_rust_bridge)
/// and the pure-Dart fallback engine produce numerically identical results
/// on a fixed deterministic 200-candle fixture.
///
/// Test surface is split in two:
///
///   1. `parity smoke …` — active and green after F-01: native lib loads,
///      ping returns a real Rust string, isNativeAvailable flips to true,
///      and the fixture produces a non-zero Dart trade count so the
///      numerical assertions below cannot become tautologies once enabled.
///
///   2. `parity numerical …` — gated behind a `skip:` argument until F-02.
///      The Rust engine emits intra-candle SL/TP exits, the Dart engine
///      does not; closing that gap is owned by F-02 (Dart-side SL/TP
///      tracking). When F-02 lands, drop the skip — no other change to
///      this file should be needed.
///
/// Tolerance is `1e-9`: any wider drift indicates a real logic divergence
/// between the engines (rounding mode, ordering of fee deduction, etc.) and
/// MUST NOT be papered over by widening the tolerance.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/rust_bridge.dart';

/// 400 deterministic candles: 50 000 baseline + sinusoid (amplitude 8 000,
/// period 30 candles). The Phase-2 video-spec defaults push the BB MA
/// lookback to 200 (Diff D-01), so a 200-candle fixture would land
/// exactly on the warm-up boundary and produce 0 trades. 400 candles
/// give ~200 active bars with multiple sinusoid cycles — enough to
/// trigger BB(200, EMA, 0.2σ)+RSI(3, 20/80) entries on both bands.
///
/// QA note: the original Phase-1 spec used 200 candles for BB(20)+RSI(14)
/// (cf. PR history). Bumping to 400 preserves the test's purpose (any
/// engine drift > 1e-9 produces an unambiguous failure) under the new
/// defaults without coupling the parity contract to specific strategy
/// parameters — both engines must still agree bit-for-bit on whatever
/// the current defaults compute.
///
/// All values are IEEE-754 f64 and round-trip cleanly through JSON,
/// so the same candle stream reaches the Rust engine bit-identical.
List<CandleData> _generateFixture() {
  final candles = <CandleData>[];
  const baseTs = 1700000000000; // 2023-11-14 22:13:20 UTC
  const baseline = 50000.0;
  const amplitude = 8000.0;
  const period = 30.0;
  for (int i = 0; i < 400; i++) {
    final phase = 2 * math.pi * i / period;
    final price = baseline + amplitude * math.sin(phase);
    candles.add(CandleData(
      timestamp: baseTs + i * 3600000,
      open: price - 20,
      high: price + 100,
      low: price - 100,
      close: price,
      volume: 1000.0 + i,
    ));
  }
  return candles;
}

void main() {
  const initialBalance = 10000.0;
  const feeRate = 0.0006;

  setUpAll(() async {
    await RustBridge.initialize();
  });

  group('F-01 Dart ↔ Rust parity', () {
    test('parity smoke: ping + native available + sanity trade', () async {
      // ── (1) RustLib smoke: ping returns a non-empty string. ──────────
      final reply = await RustBridge.ping();
      expect(reply, isNotEmpty,
          reason: 'ping must return a non-empty string from the native '
              'engine after RustBridge.initialize()');

      // ── (2) Native engine probed successfully. ───────────────────────
      expect(
        RustBridge.isNativeAvailable,
        isTrue,
        reason:
            'F-01 probes the native engine in RustBridge.initialize() and '
            'flips _nativeAvailable=true on success. If this fails, the '
            'cdylib is missing or the FFI surface is broken.',
      );

      // ── (3) Fixture sanity: Dart engine produces non-zero trades, ────
      //       so the numerical parity test (once enabled by F-02) is not
      //       a tautology of 0 == 0.
      final candles = _generateFixture();
      final dartResult = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );
      expect(
        dartResult.metrics.totalTrades,
        greaterThan(0),
        reason: 'fixture must trigger BB+RSI entries on the Dart engine; '
            'otherwise the numerical parity asserts would be tautological',
      );
    });

    test(
      'parity numerical: pnl/wr/equity match within 1e-9',
      () async {
        final candles = _generateFixture();
        final dartResult = BacktestService.runBbRsi(
          candles: candles,
          initialBalance: initialBalance,
          feeRate: feeRate,
        );

        final rustMetrics = await RustBridge.runBacktest(
          candles: candles,
          initialBalance: initialBalance,
          feeRate: feeRate,
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

        final dartFinalEquity = initialBalance + dartResult.metrics.totalPnl;
        final rustFinalEquity = initialBalance + rustMetrics.totalPnl;
        expect(rustFinalEquity, closeTo(dartFinalEquity, 1e-9));

        // F-03b (Plan-rev3 §3.4): Sharpe must match bit-for-bit between
        // engines now that the equity series itself is identical at 1e-9
        // (see test/regression/f03b_mid_trade_equity_test.dart). 1e-9
        // tolerance — wider drift indicates a real divergence and MUST be
        // investigated rather than papered over.
        expect(
          rustMetrics.sharpeRatio,
          closeTo(dartResult.metrics.sharpeRatio, 1e-9),
          reason: 'sharpeRatio divergence > 1e-9 violates F-03b numerical '
              'equivalence — both engines must produce identical equity '
              'series and run them through the same annualizedSharpe',
        );
        // F-03c (Plan-rev3 §3.4): maxDrawdown / maxDrawdownPercent now
        // share a single definition across engines — the industry-standard
        // running-peak formula over the per-candle equity curve. Before
        // F-03c, Rust walked settled trade PnL only (ignoring intra-trade
        // excursions) and produced ~33x smaller values than Dart on this
        // fixture. 1e-9 tolerance — identical f64 operations on the same
        // equity series, no sqrt or accumulated rounding involved.
        expect(
          rustMetrics.maxDrawdown,
          closeTo(dartResult.metrics.maxDrawdown, 1e-9),
          reason: 'maxDrawdown divergence > 1e-9 indicates the engines '
              'are no longer running the same running-peak drawdown on '
              'the same equity series — investigate F-03b equity parity '
              'or F-03c drawdown helper, do NOT widen the tolerance',
        );
        expect(
          rustMetrics.maxDrawdownPercent,
          closeTo(dartResult.metrics.maxDrawdownPercent, 1e-9),
        );
        // Sanity: Sharpe and drawdown must be non-trivial on this fixture
        // so the parity checks are not tautologies of 0 == 0.
        expect(dartResult.metrics.sharpeRatio.abs(), greaterThan(0.0));
        expect(rustMetrics.sharpeRatio.abs(), greaterThan(0.0));
        expect(dartResult.metrics.maxDrawdown, greaterThan(0.0));
        expect(rustMetrics.maxDrawdown, greaterThan(0.0));
      },
    );
  });
}
