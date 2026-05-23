/// F-03b regression: Dart mid-trade equity recording must match the Rust
/// engine bit-for-bit.
///
/// Plan-rev3 §3.4 F-03b (post-F-03 follow-up): the Dart engine recorded
/// `equity = balance + unrealized_pnl` on every bar during an open
/// position, which silently DROPS the reserved margin
/// (`alloc = entry_notional + entry_fee`) — equity values went strongly
/// negative through long positions and inflated the Sharpe denominator.
/// Rust's `BacktestEngine::current_equity` (rust/.../backtest/mod.rs:349)
/// has the F-02c-aware formula:
///
///   if no position:  equity = balance
///   else:            equity = balance + alloc + unrealized
///                            - entry_fee - estimated_exit_fee
///
/// This file pins three contracts:
///   1. mid-trade LONG  equity matches the formula on direct primitives
///   2. mid-trade SHORT equity matches the formula on direct primitives
///   3. cross-engine equity-curve parity on the 200-candle F-01 fixture,
///      sampled at several mid-trade indices (1e-9 tolerance, no widening)
library;

import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:math' as math;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/services/equity.dart';
import 'package:trading_app/src/bridge/api.dart' as rust;
import 'package:trading_app/src/bridge/frb_generated.dart';

// ───────── primitive-formula tests (Test 1 + 2) ─────────

void main() {
  group('F-03b midTradeEquity formula (Plan §3.4 mirror of Rust current_equity)', () {
    test('long mid-trade: equity = balance + alloc + unrealized - entry_fee - est_exit_fee', () {
      // Spec example (per task brief):
      //   balance_before=10000, entry=100, qty=10, fee_rate=0.001, mark=110
      //   alloc = 100*10 + 1 = 1001
      //   balance_after_open = 10000 - 1001 = 8999
      //   unrealized = (110 - 100) * 10 = 100
      //   est_exit_fee = 110 * 10 * 0.001 = 1.1
      //   equity = 8999 + 1001 + 100 - 1 - 1.1 = 10097.9
      final got = midTradeEquity(
        balance: 8999,
        entryPrice: 100,
        quantity: 10,
        entryFee: 1,
        markPrice: 110,
        feeRate: 0.001,
        isLong: true,
      );
      expect(got, closeTo(10097.9, 1e-9));
    });

    test('short mid-trade: unrealized has opposite sign', () {
      // Same primitives, short side: position profits when price falls.
      //   mark=90 (was 100), unrealized_short = (100-90)*10 = 100
      //   est_exit_fee = 90 * 10 * 0.001 = 0.9
      //   equity = 8999 + 1001 + 100 - 1 - 0.9 = 10098.1
      final got = midTradeEquity(
        balance: 8999,
        entryPrice: 100,
        quantity: 10,
        entryFee: 1,
        markPrice: 90,
        feeRate: 0.001,
        isLong: false,
      );
      expect(got, closeTo(10098.1, 1e-9));
    });

    test('no position: equity = balance, ignores mark price and fee', () {
      // Sanity: when no position is open the helper must collapse to
      // the bare balance (mirrors the `None` arm of Rust current_equity).
      // We model "no position" by callers not invoking midTradeEquity at
      // all; this test pins that midTradeEquity does NOT silently fudge
      // a zero-quantity position into a non-trivial value.
      final got = midTradeEquity(
        balance: 12345.67,
        entryPrice: 100,
        quantity: 0,
        entryFee: 0,
        markPrice: 200,
        feeRate: 0.001,
        isLong: true,
      );
      // With qty=0, alloc=0, unrealized=0, est_exit_fee=0 → equity=balance.
      expect(got, closeTo(12345.67, 1e-9));
    });
  });

  // ───────── integration: cross-engine equity-curve parity (Test 3) ─────────

  group('F-03b dart↔rust equity curve parity (1e-9)', () {
    setUpAll(() async {
      final ext = _findDevLibrary();
      if (ext != null) {
        await RustLib.init(externalLibrary: ext);
      } else {
        await RustLib.init();
      }
    });

    test('equity series matches at sampled mid-trade indices', () async {
      final candles = _generateFixture();
      const initialBalance = 10000.0;
      const feeRate = 0.0006;

      // F-03b verifies cross-engine equity-curve parity, not strategy
      // logic — pin Phase-1 BB(20, SMA, 2.0σ) + RSI(14, 30/70) so the
      // 200-candle fixture continues to trigger trades on both engines.
      // The Phase-2 default BB(200) would sit on the warm-up boundary
      // and produce 0 trades on this fixture.
      const pinnedParams = BbRsiParams(
        bbPeriod: 20,
        bbStdDev: 2.0,
        bbMaType: BbMaType.sma,
        rsiPeriod: 14,
        rsiOversold: 30.0,
        rsiOverbought: 70.0,
        swingLookbackBars: 20,
        tpRrRatio: 3.0,
        riskPerTrade: 0.02,
      );

      final dart = BacktestService.runBbRsi(
        candles: candles,
        initialBalance: initialBalance,
        feeRate: feeRate,
        params: pinnedParams,
      );
      final dartEq = dart.equityCurve.map((p) => p.equity).toList();

      // Mirror the Dart parameters into the Rust call so both engines
      // run the same strategy (numerical encoding: bb_ma_type 0=SMA).
      const pinnedParamsJson =
          '{"bb_period":20,"bb_stddev":2.0,"bb_ma_type":0,'
          '"rsi_period":14,"rsi_oversold":30,"rsi_overbought":70,'
          '"swing_lookback_bars":20,"tp_rr_ratio":3.0,'
          '"risk_per_trade":0.02}';
      final candlesJson = jsonEncode(candles.map((c) => c.toRustJson()).toList());
      final resp = await rust.runBbRsiBacktest(
        candlesJson: candlesJson,
        paramsJson: pinnedParamsJson,
        initialBalance: initialBalance,
        feeRate: feeRate,
      );
      final decoded = jsonDecode(resp) as Map<String, dynamic>;
      if (decoded.containsKey('error')) {
        fail('Rust backtest failed: ${decoded['error']}');
      }
      final ecArr = decoded['equity_curve'] as List<dynamic>;
      final rustEq = ecArr
          .map((p) =>
              ((p as Map<String, dynamic>)['equity'] as num).toDouble())
          .toList();

      expect(dartEq.length, equals(rustEq.length),
          reason: 'equity curves must have one point per candle on both sides');

      // Sample several mid-trade indices (chosen to span both Long and
      // Short positions and pre/post warmup). 1e-9 tolerance — wider drift
      // indicates a real divergence.
      for (final i in const [34, 50, 100, 150, 180]) {
        expect(dartEq[i], closeTo(rustEq[i], 1e-9),
            reason: 'equity[$i]: dart=${dartEq[i]} rust=${rustEq[i]}');
      }
      // And full-curve check at end: final candle equity (no open position
      // expected after end-of-data force-close) must also match.
      expect(dartEq.last, closeTo(rustEq.last, 1e-9),
          reason: 'final equity must match: dart=${dartEq.last} rust=${rustEq.last}');
    });
  });
}

ExternalLibrary? _findDevLibrary() {
  String? name;
  if (Platform.isLinux) {
    name = 'libtrading_engine.so';
  } else if (Platform.isMacOS) {
    name = 'libtrading_engine.dylib';
  } else if (Platform.isWindows) {
    name = 'trading_engine.dll';
  }
  if (name == null) return null;
  for (final profile in const ['release', 'debug']) {
    final path = 'rust/trading_engine/target/$profile/$name';
    if (File(path).existsSync()) return ExternalLibrary.open(path);
  }
  return null;
}

List<CandleData> _generateFixture() {
  final candles = <CandleData>[];
  const baseTs = 1700000000000;
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
