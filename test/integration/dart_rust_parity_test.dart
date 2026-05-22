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

/// 200 deterministic candles: 50 000 baseline + sinusoid (amplitude 8 000,
/// period 30 candles). Empirically chosen to trigger ~12 BB(20)+RSI(14)
/// entries on the Dart ground-truth engine, with non-trivial win rate
/// (~92 %) and a large |totalPnl| — both required so any engine drift
/// > 1e-9 produces an unambiguous failure.
///
/// QA note: the original spec asked for 60 candles, but BB(20)/RSI(14)
/// need warm-up + several cycles to penetrate the BB band. 200 candles
/// is the minimum size that survives the warm-up with reliable trade
/// generation; cf. the probe results documented in the PR description.
///
/// All values are IEEE-754 f64 and round-trip cleanly through JSON,
/// so the same candle stream reaches the Rust engine bit-identical.
List<CandleData> _generateFixture() {
  final candles = <CandleData>[];
  const baseTs = 1700000000000; // 2023-11-14 22:13:20 UTC
  const baseline = 50000.0;
  const amplitude = 8000.0;
  const period = 30.0;
  for (int i = 0; i < 200; i++) {
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
      },
      skip: 'F-01 establishes parity test infrastructure. PnL/WR/Equity '
          'asserts are expected RED until F-02 implements Dart-side SL/TP '
          'tracking (see 260522_Gesamtplan_Phase1-3.md §3.4 F-02). F-02 '
          'will remove this skip and make the test green.',
    );
  });
}
