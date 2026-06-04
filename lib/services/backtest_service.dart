/// Pure-Dart backtest engine implementing BB+RSI mean-reversion strategy.
///
/// This mirrors the Rust trading_engine logic so the Flutter UI can run
/// backtests without needing the native FFI bridge at runtime.
library;

import 'dart:math' as math;

import '../core/models/candle.dart';
import '../core/models/timeframe.dart';
import '../core/models/trade.dart';
import 'equity.dart';
import 'indicators.dart';
import 'sharpe.dart';
import 'strategy_common.dart';

// ─── Engine-specific result models ──────────────────────────────────────────
// Trade and metrics types are imported from lib/core/models/trade.dart —
// see F-06 (test/regression/f06_model_unification_test.dart).

/// A single point on the equity curve.
class EquityPoint {
  final int timestamp;
  final double equity;
  final double drawdown;
  final double drawdownPct;

  const EquityPoint({
    required this.timestamp,
    required this.equity,
    required this.drawdown,
    required this.drawdownPct,
  });
}

/// Complete backtest result.
class BacktestResult {
  final BacktestMetrics metrics;
  final List<EquityPoint> equityCurve;
  final List<ClosedTrade> trades;

  /// Snapshot of the still-open position at the end of the run, populated
  /// only when the caller passed `extractOpenPosition: true` (default
  /// `false`). The default path keeps the legacy force-close-at-last-bar
  /// behaviour (`exitReason == 'End of Data'`) so the Phase-1 reference
  /// backtest stays bit-exact — see Welle B4.2-1 brief.
  final OpenPositionSnapshot? openPosition;

  const BacktestResult({
    required this.metrics,
    required this.equityCurve,
    required this.trades,
    this.openPosition,
  });
}

// ─── BB+RSI Strategy Parameters ─────────────────────────────────────────────

/// Moving-average basis for the Bollinger Bands middle line.
///
/// Encoded numerically when forwarded to the Rust engine
/// (`bb_ma_type` strategy parameter: 0=SMA, 1=EMA) so it round-trips
/// through the f64-typed parameter map. The stddev component is
/// independent of the basis (always window-SMA stddev) so band-width is
/// comparable across MA-type switches — see
/// `calc_bollinger_bands_ema` in `rust/trading_engine/src/addins/bb_rsi.rs`.
enum BbMaType {
  /// Simple Moving Average basis (default, backwards-compatible).
  sma(0.0),

  /// Exponential Moving Average basis (Phase-2 video-spec trend filter).
  ema(1.0);

  const BbMaType(this.rustParamValue);

  /// Numeric encoding sent to the Rust engine's `bb_ma_type` parameter.
  final double rustParamValue;
}

class BbRsiParams {
  final int bbPeriod;
  final double bbStdDev;

  /// Basis MA type for the BB middle line. Default [BbMaType.sma] keeps
  /// the legacy Phase-1 behavior bit-exact; the upcoming video-spec
  /// trend filter (Diff D-01) uses [BbMaType.ema].
  final BbMaType bbMaType;

  final int rsiPeriod;
  final double rsiOversold;
  final double rsiOverbought;

  /// Swing-low / swing-high lookback (Diff D-07).
  ///
  /// Spec §4 algorithmic SL definition: long SL = `min(low[i - N .. i - 1])`,
  /// short SL = `max(high[i - N .. i - 1])` where `N = swingLookbackBars`.
  /// Default 20 matches the Rust manifest and approximates a ~one-day
  /// lookback on 1h candles. Must equal the Rust `swing_lookback_bars`
  /// parameter for Dart↔Rust parity.
  final int swingLookbackBars;

  /// TP distance as a multiple of the swing-derived SL distance (Diff D-06).
  ///
  /// Spec §5: R:R 1:3 → `tpRrRatio = 3.0` (default). At signal time the
  /// engine sets TP = entry-proxy ± ratio × |entry-proxy − sl_price|,
  /// using the signal-bar close as entry proxy (the actual fill is at
  /// the next bar's open per F-04). Must equal the Rust `tp_rr_ratio`
  /// parameter for Dart↔Rust parity.
  final double tpRrRatio;

  /// Equity fraction risked per trade (Diff D-09).
  ///
  /// Spec §8: `qty = (equity × risk_per_trade) / |entry − sl|`. The
  /// strategy converts this into a per-signal `size_fraction` at signal
  /// time using the signal-bar close as entry proxy. Default 0.02 = 2 %
  /// per spec; range bounded by the manifest 0.001–1.0. If the formula
  /// produces a notional > balance (very tight SL), the engine clamps
  /// to full-balance allocation (spec §8 "naive Clamp"). Must equal
  /// the Rust `risk_per_trade` parameter for Dart↔Rust parity.
  final double riskPerTrade;

  /// One-side slippage in basis points applied at each execution
  /// (entry and exit) against the trader. Plan rev2 §3.4 F-04 sets the
  /// default to 0 bps for Binance / Bitunix BTC + ETH at retail size;
  /// raise for thin alts or large orders. Must match the Rust
  /// BacktestConfig.slippage_bps for Dart↔Rust parity.
  final double slippageBps;

  /// Welle R2-2 ADX regime filter quartet. All four default to "off" so
  /// a fresh [BbRsiParams] behaves byte-identical to the pre-R2 contract
  /// — the Phase-1 reference backtest and the BB+RSI Dart↔Rust parity
  /// test stay green without touching their fixtures.
  ///
  /// When [adxFilterEnabled] is `true` the engine computes
  /// `(adx, +DI, -DI)` once per bar from the bar history up to and
  /// including the signal bar and routes the entry through
  /// `regimePassesFilter` (see `strategy_common.dart`) before queuing
  /// a pending order. Field shape mirrors `bb_rsi_manifest()` /
  /// `ut_bot_manifest()` / `ichimoku_manifest()` bit-for-bit so the
  /// Welle-R3 acceptance backtest can sweep an IDENTICAL parameter
  /// axis across strategies.
  final bool adxFilterEnabled;
  final double adxThreshold;
  final int adxPeriod;
  final bool adxUseDiConfluence;

  /// Defaults match the video-spec "verbesserte Variante" — see
  /// `01_Projectplan/specs/bb_rsi_spec.md` §1, Diff D-01 + D-02
  /// (BB(200, EMA, 0.2σ) + RSI(3, 20/80)) plus Diff D-06 R:R 1:3 TP,
  /// Diff D-07 swing-SL N=20, and Diff D-09 risk-2 % sizing. Mirrors
  /// the bb_rsi_manifest() defaults in `rust/trading_engine/src/addins/bb_rsi.rs`.
  const BbRsiParams({
    this.bbPeriod = 200,
    this.bbStdDev = 0.2,
    this.bbMaType = BbMaType.ema,
    this.rsiPeriod = 3,
    this.rsiOversold = 20.0,
    this.rsiOverbought = 80.0,
    this.swingLookbackBars = 20,
    this.tpRrRatio = 3.0,
    this.riskPerTrade = 0.02,
    this.slippageBps = 0.0,
    this.adxFilterEnabled = false,
    this.adxThreshold = 25.0,
    this.adxPeriod = 14,
    this.adxUseDiConfluence = false,
  });

  /// Snake-case keys used by the optimizer studies (`trials.params_json`).
  /// Order is deterministic for stable diffs in tests.
  static const Set<String> trialParamKeys = {
    'bb_period',
    'bb_stddev',
    'bb_ma_type',
    'rsi_period',
    'rsi_oversold',
    'rsi_overbought',
    'swing_lookback_bars',
    'tp_rr_ratio',
    'risk_per_trade',
    'slippage_bps',
    'adx_filter_enabled',
    'adx_threshold',
    'adx_period',
    'adx_use_di_confluence',
  };

  /// Serialize to the `Map<String, double>` shape used by optimizer trials.
  /// Bools are encoded as 0.0/1.0; enums by their `rustParamValue`.
  Map<String, double> toMap() => {
        'bb_period': bbPeriod.toDouble(),
        'bb_stddev': bbStdDev,
        'bb_ma_type': bbMaType.rustParamValue,
        'rsi_period': rsiPeriod.toDouble(),
        'rsi_oversold': rsiOversold,
        'rsi_overbought': rsiOverbought,
        'swing_lookback_bars': swingLookbackBars.toDouble(),
        'tp_rr_ratio': tpRrRatio,
        'risk_per_trade': riskPerTrade,
        'slippage_bps': slippageBps,
        'adx_filter_enabled': adxFilterEnabled ? 1.0 : 0.0,
        'adx_threshold': adxThreshold,
        'adx_period': adxPeriod.toDouble(),
        'adx_use_di_confluence': adxUseDiConfluence ? 1.0 : 0.0,
      };

  /// Build params from an optimizer trial map. Missing keys fall back to the
  /// default value for that field so a mismatched-strategy apply (e.g. a
  /// BB+RSI card consuming a UT-Bot trial) stays well-defined instead of
  /// throwing. Int-typed fields cast via `.toInt()` (truncate), not
  /// `.round()` — optimizer values are already integral.
  factory BbRsiParams.fromMap(Map<String, double> m) {
    const d = BbRsiParams();
    return BbRsiParams(
      bbPeriod: m['bb_period']?.toInt() ?? d.bbPeriod,
      bbStdDev: m['bb_stddev'] ?? d.bbStdDev,
      bbMaType: _bbMaTypeFromDouble(m['bb_ma_type']) ?? d.bbMaType,
      rsiPeriod: m['rsi_period']?.toInt() ?? d.rsiPeriod,
      rsiOversold: m['rsi_oversold'] ?? d.rsiOversold,
      rsiOverbought: m['rsi_overbought'] ?? d.rsiOverbought,
      swingLookbackBars:
          m['swing_lookback_bars']?.toInt() ?? d.swingLookbackBars,
      tpRrRatio: m['tp_rr_ratio'] ?? d.tpRrRatio,
      riskPerTrade: m['risk_per_trade'] ?? d.riskPerTrade,
      slippageBps: m['slippage_bps'] ?? d.slippageBps,
      adxFilterEnabled:
          _boolFromDouble(m['adx_filter_enabled']) ?? d.adxFilterEnabled,
      adxThreshold: m['adx_threshold'] ?? d.adxThreshold,
      adxPeriod: m['adx_period']?.toInt() ?? d.adxPeriod,
      adxUseDiConfluence:
          _boolFromDouble(m['adx_use_di_confluence']) ?? d.adxUseDiConfluence,
    );
  }
}

/// Decode a 0.0/1.0 double back into a bool. Returns null when the value
/// is absent so [BbRsiParams.fromMap] / [UtBotParams.fromMap] /
/// [IchimokuParams.fromMap] can fall back to the default. Treats any
/// value other than `0.0` as `true` to match `bool(v)`-style semantics
/// of the Python optimizer side.
bool? _boolFromDouble(double? v) {
  if (v == null) return null;
  return v != 0.0;
}

/// Decode the `bb_ma_type` enum from its 0.0/1.0 double encoding.
/// Returns null when absent so the caller can fall back to the default.
BbMaType? _bbMaTypeFromDouble(double? v) {
  if (v == null) return null;
  // Tolerate floating-point noise around the integer encoding.
  return v < 0.5 ? BbMaType.sma : BbMaType.ema;
}

// ─── UT Bot Strategy Parameters ─────────────────────────────────────────────

/// Parameters for [BacktestService.runUtBot] — pure-Dart mirror of
/// `ut_bot_manifest()` in `rust/trading_engine/src/addins/ut_bot.rs`.
///
/// All defaults match the Rust manifest bit-for-bit so the engines stay
/// in lock-step without a parameter map dance. Spec §1 of
/// `01_Projectplan/specs/ut_bot_spec.md` documents the source for every
/// default; the QA decisions for the open questions (key_value default,
/// SMI variant, session filter scope, helper location) are recorded in
/// the commit history for Welle U2-3.
class UtBotParams {
  final int emaPeriod;
  final double keyValue;
  final int atrPeriod;
  final int smiLength;
  final int smiKSmoothing;
  final int smiDSmoothing;
  final int swingLookbackBars;
  final double tpRrRatio;
  final double riskPerTrade;
  final bool sessionFilterEnabled;
  final int sessionStartHourLocal;
  final int sessionEndHourLocal;
  final double slippageBps;

  /// Path-B toggle per `01_Projectplan/specs/ut_bot_spec.md` §12.5.
  /// Default `false` = strict spec (Long fires only while SMI < 0,
  /// Short only while SMI > 0). Set `true` to flip the zero-line gate
  /// for the Welle-U3 Path-B experiment.
  final bool smiCrossAboveZero;

  /// Welle R2-3 ADX regime filter quartet — see [BbRsiParams] for the
  /// shared rationale. Defaults disabled so the pre-R2 UT-Bot path is
  /// byte-identical (dart_rust_ut_bot_parity_test stays green without
  /// touching the fixture).
  final bool adxFilterEnabled;
  final double adxThreshold;
  final int adxPeriod;
  final bool adxUseDiConfluence;

  const UtBotParams({
    this.emaPeriod = 200,
    this.keyValue = 2.0,
    this.atrPeriod = 1,
    this.smiLength = 14,
    this.smiKSmoothing = 5,
    this.smiDSmoothing = 3,
    this.swingLookbackBars = 20,
    this.tpRrRatio = 2.0,
    this.riskPerTrade = 0.02,
    this.sessionFilterEnabled = false,
    this.sessionStartHourLocal = 9,
    this.sessionEndHourLocal = 23,
    this.slippageBps = 0.0,
    this.smiCrossAboveZero = false,
    this.adxFilterEnabled = false,
    this.adxThreshold = 25.0,
    this.adxPeriod = 14,
    this.adxUseDiConfluence = false,
  });

  /// Snake-case keys used by the optimizer studies (`trials.params_json`).
  static const Set<String> trialParamKeys = {
    'ema_period',
    'key_value',
    'atr_period',
    'smi_length',
    'smi_k_smoothing',
    'smi_d_smoothing',
    'swing_lookback_bars',
    'tp_rr_ratio',
    'risk_per_trade',
    'session_filter_enabled',
    'session_start_hour_local',
    'session_end_hour_local',
    'slippage_bps',
    'smi_cross_above_zero',
    'adx_filter_enabled',
    'adx_threshold',
    'adx_period',
    'adx_use_di_confluence',
  };

  Map<String, double> toMap() => {
        'ema_period': emaPeriod.toDouble(),
        'key_value': keyValue,
        'atr_period': atrPeriod.toDouble(),
        'smi_length': smiLength.toDouble(),
        'smi_k_smoothing': smiKSmoothing.toDouble(),
        'smi_d_smoothing': smiDSmoothing.toDouble(),
        'swing_lookback_bars': swingLookbackBars.toDouble(),
        'tp_rr_ratio': tpRrRatio,
        'risk_per_trade': riskPerTrade,
        'session_filter_enabled': sessionFilterEnabled ? 1.0 : 0.0,
        'session_start_hour_local': sessionStartHourLocal.toDouble(),
        'session_end_hour_local': sessionEndHourLocal.toDouble(),
        'slippage_bps': slippageBps,
        'smi_cross_above_zero': smiCrossAboveZero ? 1.0 : 0.0,
        'adx_filter_enabled': adxFilterEnabled ? 1.0 : 0.0,
        'adx_threshold': adxThreshold,
        'adx_period': adxPeriod.toDouble(),
        'adx_use_di_confluence': adxUseDiConfluence ? 1.0 : 0.0,
      };

  factory UtBotParams.fromMap(Map<String, double> m) {
    const d = UtBotParams();
    return UtBotParams(
      emaPeriod: m['ema_period']?.toInt() ?? d.emaPeriod,
      keyValue: m['key_value'] ?? d.keyValue,
      atrPeriod: m['atr_period']?.toInt() ?? d.atrPeriod,
      smiLength: m['smi_length']?.toInt() ?? d.smiLength,
      smiKSmoothing: m['smi_k_smoothing']?.toInt() ?? d.smiKSmoothing,
      smiDSmoothing: m['smi_d_smoothing']?.toInt() ?? d.smiDSmoothing,
      swingLookbackBars:
          m['swing_lookback_bars']?.toInt() ?? d.swingLookbackBars,
      tpRrRatio: m['tp_rr_ratio'] ?? d.tpRrRatio,
      riskPerTrade: m['risk_per_trade'] ?? d.riskPerTrade,
      sessionFilterEnabled:
          _boolFromDouble(m['session_filter_enabled']) ?? d.sessionFilterEnabled,
      sessionStartHourLocal:
          m['session_start_hour_local']?.toInt() ?? d.sessionStartHourLocal,
      sessionEndHourLocal:
          m['session_end_hour_local']?.toInt() ?? d.sessionEndHourLocal,
      slippageBps: m['slippage_bps'] ?? d.slippageBps,
      smiCrossAboveZero:
          _boolFromDouble(m['smi_cross_above_zero']) ?? d.smiCrossAboveZero,
      adxFilterEnabled:
          _boolFromDouble(m['adx_filter_enabled']) ?? d.adxFilterEnabled,
      adxThreshold: m['adx_threshold'] ?? d.adxThreshold,
      adxPeriod: m['adx_period']?.toInt() ?? d.adxPeriod,
      adxUseDiConfluence:
          _boolFromDouble(m['adx_use_di_confluence']) ?? d.adxUseDiConfluence,
    );
  }
}

// ─── Ichimoku Strategy Parameters ───────────────────────────────────────────

/// Parameters for [BacktestService.runIchimoku] — pure-Dart mirror of
/// `ichimoku_manifest()` in `rust/trading_engine/src/addins/ichimoku.rs`.
///
/// Defaults match the Rust manifest bit-for-bit per Spec §1 / §12.2 so
/// the engines stay in lock-step without a parameter-map dance.
/// `shift` and `swingLookbackBars` are documentation-only knobs on the
/// Ichimoku side (the past-cloud read-anchor helper hardcodes a 26-bar
/// visual shift; the SL anchors are kijun + cloud, not swing-points) —
/// they are kept in the param list so a Phase-3 hybrid variant can
/// surface them without breaking the parameter map.
class IchimokuParams {
  final int tenkanPeriod;
  final int kijunPeriod;
  final int senkouBPeriod;
  final int shift;
  final int scoreThreshold;
  final double tpRrRatio;
  final double riskPerTrade;
  final int swingLookbackBars;
  final bool sessionFilterEnabled;
  final int sessionStartHour;
  final int sessionEndHour;
  final int tzOffsetHours;
  final double slippageBps;

  /// Welle R2-4 ADX regime filter quartet — see [BbRsiParams] for the
  /// shared rationale. Defaults disabled so the pre-R2 Ichimoku path
  /// is byte-identical (dart_rust_ichimoku_parity stays bit-exact green).
  final bool adxFilterEnabled;
  final double adxThreshold;
  final int adxPeriod;
  final bool adxUseDiConfluence;

  const IchimokuParams({
    this.tenkanPeriod = 9,
    this.kijunPeriod = 26,
    this.senkouBPeriod = 52,
    this.shift = 26,
    this.scoreThreshold = 60,
    this.tpRrRatio = 2.0,
    this.riskPerTrade = 0.02,
    this.swingLookbackBars = 20,
    this.sessionFilterEnabled = false,
    this.sessionStartHour = 9,
    this.sessionEndHour = 23,
    this.tzOffsetHours = 1,
    this.slippageBps = 0.0,
    this.adxFilterEnabled = false,
    this.adxThreshold = 25.0,
    this.adxPeriod = 14,
    this.adxUseDiConfluence = false,
  });

  /// Snake-case keys used by the optimizer studies (`trials.params_json`).
  static const Set<String> trialParamKeys = {
    'tenkan_period',
    'kijun_period',
    'senkou_b_period',
    'shift',
    'score_threshold',
    'tp_rr_ratio',
    'risk_per_trade',
    'swing_lookback_bars',
    'session_filter_enabled',
    'session_start_hour',
    'session_end_hour',
    'tz_offset_hours',
    'slippage_bps',
    'adx_filter_enabled',
    'adx_threshold',
    'adx_period',
    'adx_use_di_confluence',
  };

  Map<String, double> toMap() => {
        'tenkan_period': tenkanPeriod.toDouble(),
        'kijun_period': kijunPeriod.toDouble(),
        'senkou_b_period': senkouBPeriod.toDouble(),
        'shift': shift.toDouble(),
        'score_threshold': scoreThreshold.toDouble(),
        'tp_rr_ratio': tpRrRatio,
        'risk_per_trade': riskPerTrade,
        'swing_lookback_bars': swingLookbackBars.toDouble(),
        'session_filter_enabled': sessionFilterEnabled ? 1.0 : 0.0,
        'session_start_hour': sessionStartHour.toDouble(),
        'session_end_hour': sessionEndHour.toDouble(),
        'tz_offset_hours': tzOffsetHours.toDouble(),
        'slippage_bps': slippageBps,
        'adx_filter_enabled': adxFilterEnabled ? 1.0 : 0.0,
        'adx_threshold': adxThreshold,
        'adx_period': adxPeriod.toDouble(),
        'adx_use_di_confluence': adxUseDiConfluence ? 1.0 : 0.0,
      };

  factory IchimokuParams.fromMap(Map<String, double> m) {
    const d = IchimokuParams();
    return IchimokuParams(
      tenkanPeriod: m['tenkan_period']?.toInt() ?? d.tenkanPeriod,
      kijunPeriod: m['kijun_period']?.toInt() ?? d.kijunPeriod,
      senkouBPeriod: m['senkou_b_period']?.toInt() ?? d.senkouBPeriod,
      shift: m['shift']?.toInt() ?? d.shift,
      scoreThreshold: m['score_threshold']?.toInt() ?? d.scoreThreshold,
      tpRrRatio: m['tp_rr_ratio'] ?? d.tpRrRatio,
      riskPerTrade: m['risk_per_trade'] ?? d.riskPerTrade,
      swingLookbackBars:
          m['swing_lookback_bars']?.toInt() ?? d.swingLookbackBars,
      sessionFilterEnabled:
          _boolFromDouble(m['session_filter_enabled']) ?? d.sessionFilterEnabled,
      sessionStartHour:
          m['session_start_hour']?.toInt() ?? d.sessionStartHour,
      sessionEndHour: m['session_end_hour']?.toInt() ?? d.sessionEndHour,
      tzOffsetHours: m['tz_offset_hours']?.toInt() ?? d.tzOffsetHours,
      slippageBps: m['slippage_bps'] ?? d.slippageBps,
      adxFilterEnabled:
          _boolFromDouble(m['adx_filter_enabled']) ?? d.adxFilterEnabled,
      adxThreshold: m['adx_threshold'] ?? d.adxThreshold,
      adxPeriod: m['adx_period']?.toInt() ?? d.adxPeriod,
      adxUseDiConfluence:
          _boolFromDouble(m['adx_use_di_confluence']) ?? d.adxUseDiConfluence,
    );
  }
}

// ─── Internal position tracking ─────────────────────────────────────────────

class _OpenPosition {
  final bool isLong;
  final double entryPrice;
  final double quantity;
  final int entryTimestamp;
  final double entryFee;

  /// Absolute stop-loss price (null = no SL attached at entry).
  /// Mutated by the D-08 break-even trail; the original distance is
  /// preserved in [initialSlDistance] so the +1R check still works
  /// after the SL is pulled to entry. Mirrors `Position::stop_loss`
  /// in the Rust engine.
  double? stopLoss;

  /// Absolute take-profit price (null = no TP attached at entry).
  /// Mirrors `Position::take_profit` in the Rust engine.
  final double? takeProfit;

  /// Original SL distance at entry (`|entryPrice − stopLoss|` at open).
  /// Captured once and never updated; used by the D-08 break-even
  /// trail to know when +1R has been reached even after [stopLoss]
  /// has been pulled to entry. `null` when the position opened
  /// without an SL — in that case BE-trail does not fire.
  final double? initialSlDistance;

  /// True once the D-08 break-even trail has pulled [stopLoss] to
  /// [entryPrice]. Permanent — no further trailing or re-application.
  bool breakevenApplied;

  _OpenPosition({
    required this.isLong,
    required this.entryPrice,
    required this.quantity,
    required this.entryTimestamp,
    required this.entryFee,
    this.stopLoss,
    this.takeProfit,
    this.initialSlDistance,
  }) : breakevenApplied = false;
}

// ─── Pending order (F-04 next-bar-open execution) ────────────────────────────

/// A trade decision made at bar `i`, filled at bar `i+1`'s open. Plan §3.4
/// F-04: strategy signals must NOT execute at the bar that produced them
/// (that uses information unavailable at order-send time — look-ahead).
sealed class _PendingOrder {}

class _PendingEnterLong extends _PendingOrder {
  final double stopLoss;
  final double takeProfit;

  /// Fraction of available balance to allocate to this entry (Diff D-09).
  /// `1.0` falls back to the legacy full-balance allocation; risk-sized
  /// strategy paths derive this from `riskPerTrade × entry / sl_distance`,
  /// clamped to `[0, 1]`.
  final double sizeFraction;
  _PendingEnterLong(this.stopLoss, this.takeProfit, this.sizeFraction);
}

class _PendingEnterShort extends _PendingOrder {
  final double stopLoss;
  final double takeProfit;

  /// See [_PendingEnterLong.sizeFraction]; mirror for the short side.
  final double sizeFraction;
  _PendingEnterShort(this.stopLoss, this.takeProfit, this.sizeFraction);
}

// Diff D-11 removed the BB-middle / RSI-extreme indicator exits, so
// the pending-order queue no longer carries `_PendingExit` entries —
// positions close exclusively via Step B intra-bar SL/TP, or via the
// end-of-data force-close in `runBbRsi`.

// ─── Backtest Engine ────────────────────────────────────────────────────────

class BacktestService {
  /// Run a BB+RSI backtest on the given candle data.
  ///
  /// `timeframe` defaults to [Timeframe.h1] for backward compatibility with
  /// the parity fixture; pass the actual candle timeframe to get a correct
  /// annualized Sharpe (Plan §3.4 F-03).
  ///
  /// `extractOpenPosition` (Welle B4.2-1, default `false`) toggles whether
  /// a still-open position at the last bar is force-closed with
  /// `exitReason == 'End of Data'` (legacy bit-exact behaviour required by
  /// the Phase-1 reference backtest) or extracted into
  /// [BacktestResult.openPosition] without entering [BacktestResult.trades].
  /// The paper-trading provider passes `true` so it can surface live SL/TP
  /// on the open-position card; every other caller (backtest provider,
  /// optimizer, parity tests) keeps the default.
  static BacktestResult runBbRsi({
    required List<CandleData> candles,
    required double initialBalance,
    required double feeRate,
    BbRsiParams params = const BbRsiParams(),
    Timeframe timeframe = Timeframe.h1,
    bool extractOpenPosition = false,
  }) {
    if (candles.length < params.bbPeriod + 1) {
      return BacktestResult(
        metrics: BacktestMetrics(
          totalTrades: 0, winningTrades: 0, losingTrades: 0,
          winRate: 0, profitFactor: 0, totalPnl: 0, totalPnlPercent: 0,
          maxDrawdown: 0, maxDrawdownPercent: 0, sharpeRatio: 0,
          totalFees: 0, candlesProcessed: candles.length,
        ),
        equityCurve: [],
        trades: [],
      );
    }

    // Pre-compute indicators via the P4C-1 helpers in indicators.dart.
    // The helpers carry the legacy warm-up-init semantics (BB: 0.0, RSI:
    // 50.0) so the bit-exact Dart↔Rust parity suite stays pinned. The
    // strategy loop never reads warm-up bars (`startIdx >= bbPeriod`
    // and `>= rsiPeriod + 1`), but the legacy fill values are kept for
    // any downstream consumer that does.
    final closes = candles.map((c) => c.close).toList();
    final bb = calcBollingerBands(
      closes,
      params.bbPeriod,
      params.bbStdDev,
      params.bbMaType == BbMaType.sma ? BbBasis.sma : BbBasis.ema,
    )!;
    final bbUpper = bb.upper;
    final bbLower = bb.lower;
    // The middle band is still computed (and lives on `bb.middle` for the
    // chart layer) but is no longer consumed by the entry/exit block —
    // Diff D-11 retired the BB-middle indicator exit; Diff D-06 anchored
    // the TP to `tpRrRatio * sl_distance` instead of band geometry.
    final rsiValues = calcRsi(closes, params.rsiPeriod) ??
        List<double>.filled(candles.length, 50);

    // ── Welle R2-2 ADX regime filter pre-compute ───────────────────────
    // Pre-compute ADX/+DI/-DI series ONCE when the filter is enabled.
    // Mirrors the Rust on_candle path numerically (same `calc_adx`/
    // `calcAdx` algorithm, same warm-up convention). Skipping the
    // compute when disabled keeps the pre-R2 hot path bit-exact.
    final highs = [for (final c in candles) c.high];
    final lows = [for (final c in candles) c.low];
    List<double>? adxSeries;
    List<double>? plusDiSeries;
    List<double>? minusDiSeries;
    if (params.adxFilterEnabled) {
      final adxOut = calcAdx(highs, lows, closes, params.adxPeriod);
      if (adxOut != null) {
        adxSeries = adxOut.adx;
        plusDiSeries = adxOut.plusDi;
        minusDiSeries = adxOut.minusDi;
      }
    }

    // Strategy execution
    double balance = initialBalance;
    double peakEquity = initialBalance;
    double maxDrawdown = 0;
    double maxDrawdownPct = 0;
    double totalFees = 0;
    _OpenPosition? position;
    _PendingOrder? pending;

    final trades = <ClosedTrade>[];
    final equityCurve = <EquityPoint>[];
    final returns = <double>[];
    double prevEquity = initialBalance;

    // Previous bar's RSI for the Diff D-05 cross check. Rotated at the
    // end of each post-warm-up iteration so the first cross can fire on
    // bar `startIdx + 1` at the earliest — mirrors the Rust
    // BbRsiStrategy's `prev_rsi` state semantics.
    double? prevRsi;

    // Diff D-07 widens the warm-up gate to also cover the swing-low/high
    // window: signals can only fire when `swingLookbackBars` candles are
    // available BEFORE the signal bar (exclusive of it), otherwise the
    // SL would be undefined. Mirrors the Rust strategy's `start_idx`
    // computation (rust/.../addins/bb_rsi.rs) so both engines emit signals
    // on the same set of bars.
    final startIdx = math.max(
      math.max(params.bbPeriod, params.rsiPeriod + 1),
      params.swingLookbackBars,
    );
    final slipFactor = params.slippageBps / 10000.0;

    // Local helper: close the open position at `exitPrice` and record the
    // ClosedTrade. Direction-agnostic balance update mirrors close_position
    // in rust/.../backtest/mod.rs:311-348 bit-exact (F-02c).
    void closePosition(double exitPrice, int exitTs, String reason) {
      final pos = position!;
      final exitNotional = pos.quantity * exitPrice;
      final exitFee = exitNotional * feeRate;
      totalFees += exitFee;

      final grossPnl = pos.isLong
          ? (exitPrice - pos.entryPrice) * pos.quantity
          : (pos.entryPrice - exitPrice) * pos.quantity;
      final netPnl = grossPnl - pos.entryFee - exitFee;
      final entryNotional = pos.entryPrice * pos.quantity;
      final pnlPct = entryNotional > 0 ? (netPnl / entryNotional) * 100 : 0.0;
      final alloc = entryNotional + pos.entryFee;
      // D-09 partial alloc: return reserved margin + realised PnL to the
      // current balance (no longer assumed zero pre-close). Legacy
      // full-balance path: balance==0 pre-close, so `+= alloc + netPnl`
      // collapses to the pre-D-09 `= alloc + netPnl` semantics.
      balance += alloc + netPnl;

      trades.add(ClosedTrade(
        entryTimestamp: pos.entryTimestamp,
        exitTimestamp: exitTs,
        direction: pos.isLong ? 'LONG' : 'SHORT',
        entryPrice: pos.entryPrice,
        exitPrice: exitPrice,
        quantity: pos.quantity,
        pnl: netPnl,
        pnlPercent: pnlPct,
        fees: pos.entryFee + exitFee,
        exitReason: reason,
      ));
      position = null;
    }

    for (int i = 0; i < candles.length; i++) {
      final candle = candles[i];

      // F-04 bar order: A pending → B SL/TP intra-bar → C strategy decisions
      // queue new pending → D equity. Mirrors rust/.../backtest/mod.rs::run
      // exactly so the parity test stays bit-identical to 1e-9.

      // ── Step A: Execute pending order at this bar's OPEN (F-04). ──
      // The decision was made at the previous bar's close; the fill happens
      // at this bar's open with one-side slippage against the trader.
      if (pending != null) {
        switch (pending) {
          case _PendingEnterLong p:
            final entryPrice = candle.open * (1 + slipFactor);
            // D-09 partial alloc: alloc = balance × sizeFraction (legacy
            // sizeFraction=1.0 collapses to the pre-D-09 full-balance
            // allocation). Fee scales with alloc, not balance, so the
            // close_position math still resolves to
            // `balance += alloc + net_pnl` post-D-09.
            final alloc = balance * p.sizeFraction;
            final fee = alloc * feeRate;
            final qty = (alloc - fee) / entryPrice;
            position = _OpenPosition(
              isLong: true,
              entryPrice: entryPrice,
              quantity: qty,
              entryTimestamp: candle.timestamp,
              entryFee: fee,
              stopLoss: p.stopLoss,
              takeProfit: p.takeProfit,
              initialSlDistance: (entryPrice - p.stopLoss).abs(),
            );
            balance -= alloc;
            totalFees += fee;
          case _PendingEnterShort p:
            final entryPrice = candle.open * (1 - slipFactor);
            final alloc = balance * p.sizeFraction;
            final fee = alloc * feeRate;
            final qty = (alloc - fee) / entryPrice;
            position = _OpenPosition(
              isLong: false,
              entryPrice: entryPrice,
              quantity: qty,
              entryTimestamp: candle.timestamp,
              entryFee: fee,
              stopLoss: p.stopLoss,
              takeProfit: p.takeProfit,
              initialSlDistance: (p.stopLoss - entryPrice).abs(),
            );
            balance -= alloc;
            totalFees += fee;
        }
        pending = null;
      }

      // ── Step B: intra-bar exits, TP-first ordering (D-08). ──
      // Convention rewritten in D-08:
      //   a) TP check  — if `high ≥ TP` (long) / `low ≤ TP` (short) the
      //      limit order fills; exit at TP and skip the rest.
      //   b) BE-trail  — if no TP and the bar reached +1R, pull the SL
      //      to entry once and lock the flag.
      //   c) SL check  — using the possibly-updated SL.
      //
      // Pre-D-08 Dart resolved same-bar SL+TP in favour of SL (matching
      // the Rust pre-D-08 convention). That priority turns the BE-trail
      // into a strict loss for the trader on any bar that touches the TP
      // and retraces: BE would pull SL to entry, then SL-first would
      // close at entry instead of letting the TP fill. TP-first resolves
      // the ambiguity in favour of the limit order; both engines apply
      // the same rule so Dart↔Rust parity is preserved.
      final posPre = position;
      if (posPre != null) {
        final tpHitFirst = posPre.takeProfit != null &&
            (posPre.isLong
                ? candle.high >= posPre.takeProfit!
                : candle.low <= posPre.takeProfit!);
        if (tpHitFirst) {
          closePosition(posPre.takeProfit!, candle.timestamp, 'TakeProfit');
        } else {
          if (!posPre.breakevenApplied && posPre.initialSlDistance != null) {
            final dist = posPre.initialSlDistance!;
            final reached = posPre.isLong
                ? candle.high >= posPre.entryPrice + dist
                : candle.low <= posPre.entryPrice - dist;
            if (reached) {
              posPre.stopLoss = posPre.entryPrice;
              posPre.breakevenApplied = true;
            }
          }
          final slHit = posPre.stopLoss != null &&
              (posPre.isLong
                  ? candle.low <= posPre.stopLoss!
                  : candle.high >= posPre.stopLoss!);
          if (slHit) {
            closePosition(posPre.stopLoss!, candle.timestamp, 'StopLoss');
          }
        }
      }

      // ── Step C: Strategy decisions queue a pending order for next bar. ──
      // Entry conditions (no position) AND indicator-based exit conditions
      // (BB middle / opposite RSI extreme) both queue pending; only the
      // price-triggered SL/TP exits in Step B fill on the same bar.
      // Skipped during indicator warm-up.
      if (i >= startIdx) {
        final close = candle.close;
        final rsi = rsiValues[i];

        if (pending == null) {
          final lower = bbLower[i];
          final upper = bbUpper[i];
          // Diff D-06: TP is no longer derived from BB-middle geometry —
          // it is `tpRrRatio * sl_distance` from the signal-bar close.
          // `bbMiddle[i]` stays populated for the EMA-basis state but is
          // not consumed by the entry block anymore.

          if (position == null) {
            // Diff D-03/D-04 + Diff D-05 + Diff D-07: trend-follow + RSI
            // cross-back through the oversold/overbought level + swing-
            // low / swing-high SL placement (video spec §2/§3/§4).
            //   Long  ⇔ close > upper AND prev_rsi < oversold AND rsi ≥ oversold
            //   Short ⇔ close < lower AND prev_rsi > overbought AND rsi ≤ overbought
            // Null prev_rsi (first bar after warm-up) suppresses the
            // cross — no signal possible. SL is the swing-low (long) or
            // swing-high (short) of the `swingLookbackBars` bars BEFORE
            // the signal bar (exclusive). Degenerate swings
            // (swing-low ≥ close for a long, swing-high ≤ close for a
            // short) suppress the signal so the engine never opens with
            // the SL on the wrong side of entry. The TP placeholder is
            // still the BB-geometry mirror from Diff D-04; D-06 converts
            // it to the R:R 1:3 contract.
            final prev = prevRsi;
            if (prev != null) {
              final preLows = <double>[];
              final preHighs = <double>[];
              for (int j = i - params.swingLookbackBars; j < i; j++) {
                preLows.add(candles[j].low);
                preHighs.add(candles[j].high);
              }
              final slLong = swingLow(preLows);
              final slShort = swingHigh(preHighs);
              // Welle R2-2: once the BB+RSI confluence + swing
              // sanity holds, the ADX regime gate (when enabled) has
              // the last word. When disabled, `adxSeries == null` and
              // the closure returns `true` — pre-R2 path bit-exact.
              bool regimeOk(bool isLong) {
                if (!params.adxFilterEnabled) return true;
                if (adxSeries == null ||
                    plusDiSeries == null ||
                    minusDiSeries == null) {
                  return false;
                }
                return regimePassesFilter(
                  adxSeries[i],
                  plusDiSeries[i],
                  minusDiSeries[i],
                  params.adxThreshold,
                  isLong,
                  params.adxUseDiConfluence,
                );
              }

              if (slLong != null &&
                  slShort != null &&
                  close > upper &&
                  prev < params.rsiOversold &&
                  rsi >= params.rsiOversold &&
                  slLong < close &&
                  regimeOk(true)) {
                // Diff D-06: TP = entry-proxy + ratio * sl_distance.
                // The signal-bar close is the entry-price proxy; the
                // actual fill at the next bar's open may differ slightly
                // under non-zero slippage (the asymmetric impact on R:R
                // is documented in the Welle-2 QA brief).
                final slDistanceLong = close - slLong;
                final tpLong = close + params.tpRrRatio * slDistanceLong;
                // Diff D-09 + N-08: fee-aware risk sizing — mirrors the Rust
                // `position_size_pct_fee_aware(price, sl, risk, fee) / 100`
                // (bb_rsi.rs:497). The legacy `risk × entry / sl_dist` form
                // over-sized every position and caused the F-10 parity drift.
                final sizeLong = positionSizePctFeeAware(
                      close,
                      slLong,
                      params.riskPerTrade,
                      feeRate,
                    ) /
                    100.0;
                pending = _PendingEnterLong(slLong, tpLong, sizeLong);
              } else if (slLong != null &&
                  slShort != null &&
                  close < lower &&
                  prev > params.rsiOverbought &&
                  rsi <= params.rsiOverbought &&
                  slShort > close &&
                  regimeOk(false)) {
                final slDistanceShort = slShort - close;
                final tpShort =
                    close - params.tpRrRatio * slDistanceShort;
                // N-08: fee-aware risk sizing (mirror of bb_rsi.rs:521).
                final sizeShort = positionSizePctFeeAware(
                      close,
                      slShort,
                      params.riskPerTrade,
                      feeRate,
                    ) /
                    100.0;
                pending = _PendingEnterShort(slShort, tpShort, sizeShort);
              }
            }
          }
          // Diff D-11 (Phase-2): BB-middle and RSI-extreme indicator
          // exits removed. Positions are closed exclusively by SL/TP
          // (Step B intra-bar) or end-of-data force-close.
        }

        // Rotate prevRsi for the next iteration regardless of whether a
        // decision fired this bar, mirroring Rust's `state.last_rsi`
        // rotation in on_candle.
        prevRsi = rsi;
      }

      // ── Step D: equity + drawdown + per-candle return. ──
      // F-03b: equity is recorded against the POST-trade position state.
      final double equity;
      final posForEquity = position;
      if (posForEquity == null) {
        equity = balance;
      } else {
        equity = midTradeEquity(
          balance: balance,
          entryPrice: posForEquity.entryPrice,
          quantity: posForEquity.quantity,
          entryFee: posForEquity.entryFee,
          markPrice: candle.close,
          feeRate: feeRate,
          isLong: posForEquity.isLong,
        );
      }

      if (equity > peakEquity) peakEquity = equity;
      final dd = peakEquity - equity;
      final ddPct = peakEquity > 0 ? (dd / peakEquity) * 100 : 0.0;
      if (dd > maxDrawdown) maxDrawdown = dd;
      if (ddPct > maxDrawdownPct) maxDrawdownPct = ddPct;

      equityCurve.add(EquityPoint(
        timestamp: candle.timestamp,
        equity: equity,
        drawdown: dd,
        drawdownPct: ddPct,
      ));

      if (i > 0) {
        final ret = prevEquity > 0 ? (equity - prevEquity) / prevEquity : 0.0;
        returns.add(ret);
      }
      prevEquity = equity;
    }

    // End-of-data: any pending order is discarded (no next bar to fill on).
    // Default path (`extractOpenPosition: false`) force-closes any still-open
    // position at the last bar's close with reason 'End of Data', no slippage
    // (mark-to-last). Matches Rust backtest/mod.rs::run end-of-loop handling
    // and keeps the Phase-1 reference backtest bit-exact.
    // Opt-in path (`extractOpenPosition: true`) snapshots the open position
    // into the [openPositionSnapshot] return value instead — used by the
    // paper-trading provider to surface live SL/TP. Trades remain unchanged.
    pending = null;
    OpenPositionSnapshot? openPositionSnapshot;
    if (position != null && candles.isNotEmpty) {
      if (extractOpenPosition) {
        openPositionSnapshot = _snapshotOpenPosition(position!);
        position = null;
      } else {
        final lastCandle = candles.last;
        closePosition(lastCandle.close, lastCandle.timestamp, 'End of Data');
      }
    }

    // Compute aggregate metrics
    final winningTrades = trades.where((t) => t.pnl > 0).toList();
    final losingTrades = trades.where((t) => t.pnl <= 0).toList();
    final totalPnl = trades.fold<double>(0, (s, t) => s + t.pnl);
    final totalPnlPct = initialBalance > 0 ? (totalPnl / initialBalance) * 100 : 0.0;
    final winRate = trades.isNotEmpty
        ? (winningTrades.length / trades.length) * 100
        : 0.0;

    final grossProfit = winningTrades.fold<double>(0, (s, t) => s + t.pnl);
    final grossLoss = losingTrades.fold<double>(0, (s, t) => s + t.pnl.abs());
    double profitFactor = grossLoss > 0 ? grossProfit / grossLoss : 0;
    if (profitFactor > 999.99) profitFactor = 999.99;
    if (grossLoss == 0 && grossProfit > 0) profitFactor = 999.99;

    // Sharpe ratio (F-03): timeframe-aware annualization over equity-curve
    // returns. Identical formula to rust/.../models/metrics.rs, so the two
    // engines produce numerically equivalent Sharpe values on the same
    // candle stream + timeframe.
    final sharpe = annualizedSharpe(returns, timeframe);

    return BacktestResult(
      metrics: BacktestMetrics(
        totalTrades: trades.length,
        winningTrades: winningTrades.length,
        losingTrades: losingTrades.length,
        winRate: winRate,
        profitFactor: profitFactor,
        totalPnl: totalPnl,
        totalPnlPercent: totalPnlPct,
        maxDrawdown: maxDrawdown,
        maxDrawdownPercent: maxDrawdownPct,
        sharpeRatio: sharpe,
        totalFees: totalFees,
        candlesProcessed: candles.length,
      ),
      equityCurve: equityCurve,
      trades: trades,
      openPosition: openPositionSnapshot,
    );
  }

  /// Run a UT Bot Alerts (verbesserte Variante) backtest on the given
  /// candle data — pure-Dart mirror of the Rust [`UtBotStrategy`] in
  /// `rust/trading_engine/src/addins/ut_bot.rs`.
  ///
  /// Confluence-triggered trend follower per Spec §2/§3:
  ///   Long  ⇔ close > EMA AND direction flip −1→+1 AND SMI cross-up below 0
  ///   Short ⇔ close < EMA AND direction flip +1→−1 AND SMI cross-dn above 0
  ///   SL = swing-low / swing-high of `swingLookbackBars` pre-signal bars
  ///   TP = signal-bar close ± `tpRrRatio × |close − SL|`
  ///   Size = `riskPerTrade × close / sl_distance`, clamped to [0, 1]
  ///   BE-trail at +1R = engine-side D-08 mechanic (reused unchanged).
  ///
  /// The engine bar loop reuses the F-04 order from [runBbRsi] — Step A
  /// pending → Step B intra-bar SL/TP/BE → Step C strategy decisions →
  /// Step D equity — so the two strategies share the execution-order
  /// guarantees and equity-curve semantics required by the Phase-1
  /// gate (cf. `test/regression/f04_no_lookahead_test.dart`).
  ///
  /// `timeframe` defaults to [Timeframe.m5] per Spec §1 (NQ-5min in the
  /// video; we map to BTCUSDT 5min for the Phase-2 acceptance backtest).
  static BacktestResult runUtBot({
    required List<CandleData> candles,
    required double initialBalance,
    required double feeRate,
    UtBotParams params = const UtBotParams(),
    Timeframe timeframe = Timeframe.m5,
    bool extractOpenPosition = false,
  }) {
    final n = candles.length;
    // Sanity warm-up gate. EMA(200) dominates for the default Phase-2
    // configuration; smaller smi/atr periods always fit inside it.
    if (n < params.emaPeriod + 1) {
      return BacktestResult(
        metrics: BacktestMetrics(
          totalTrades: 0, winningTrades: 0, losingTrades: 0,
          winRate: 0, profitFactor: 0, totalPnl: 0, totalPnlPercent: 0,
          maxDrawdown: 0, maxDrawdownPercent: 0, sharpeRatio: 0,
          totalFees: 0, candlesProcessed: n,
        ),
        equityCurve: const [],
        trades: const [],
      );
    }

    final highs = [for (final c in candles) c.high];
    final lows = [for (final c in candles) c.low];
    final closes = [for (final c in candles) c.close];

    // Pre-compute indicator series ONCE (O(N) per series) — avoids the
    // O(N²) per-bar full-recompute that the StrategyAddin path uses on
    // the Rust side. Same numerical result either way; the pre-compute
    // is just the Dart-side optimization for the 19k-bar 5min backtest.

    // EMA series with NaN warm-up: SMA-seeded, alpha = 2/(period+1).
    final emaSeries = List<double>.filled(n, double.nan);
    {
      double sum = 0.0;
      for (int i = 0; i < params.emaPeriod; i++) {
        sum += closes[i];
      }
      double ema = sum / params.emaPeriod;
      emaSeries[params.emaPeriod - 1] = ema;
      final alpha = 2.0 / (params.emaPeriod + 1);
      for (int i = params.emaPeriod; i < n; i++) {
        ema = alpha * closes[i] + (1 - alpha) * ema;
        emaSeries[i] = ema;
      }
    }

    final atrSeries = calcAtr(highs, lows, closes, params.atrPeriod);
    if (atrSeries == null) return _emptyUtBotResult(n);

    final trailResult = calcUtBotTrail(closes, atrSeries, params.keyValue);
    if (trailResult == null) return _emptyUtBotResult(n);
    final directionSeries = trailResult.direction;

    final smiResult = calcSmi(
      highs,
      lows,
      closes,
      params.smiLength,
      params.smiKSmoothing,
      params.smiDSmoothing,
    );
    if (smiResult == null) return _emptyUtBotResult(n);
    final smiSeries = smiResult.smi;
    final signalSeries = smiResult.signal;

    // Warm-up gate aligned with the Rust strategy's `start_idx`.
    final smiSignalWarmup = (params.smiLength - 1) +
        (params.smiKSmoothing - 1) +
        2 * (params.smiDSmoothing - 1);
    final startIdx = [
      params.emaPeriod,
      params.atrPeriod,
      smiSignalWarmup + 1,
      params.swingLookbackBars,
    ].reduce((a, b) => a > b ? a : b);

    // ── Welle R2-3 ADX regime filter pre-compute ───────────────────────
    // Pre-compute ADX/+DI/-DI series ONCE when the filter is enabled.
    // Mirrors the Rust on_candle full-recompute algorithm bit-for-bit
    // via the shared `calcAdx` helper in strategy_common.dart. When
    // disabled, no ADX work happens — pre-R2 UT-Bot path bit-exact.
    List<double>? adxSeries;
    List<double>? plusDiSeries;
    List<double>? minusDiSeries;
    if (params.adxFilterEnabled) {
      final adxOut = calcAdx(highs, lows, closes, params.adxPeriod);
      if (adxOut != null) {
        adxSeries = adxOut.adx;
        plusDiSeries = adxOut.plusDi;
        minusDiSeries = adxOut.minusDi;
      }
    }

    // Strategy execution — shape mirrors runBbRsi's Step A/B/C/D pattern.
    double balance = initialBalance;
    double peakEquity = initialBalance;
    double maxDrawdown = 0;
    double maxDrawdownPct = 0;
    double totalFees = 0;
    _OpenPosition? position;
    _PendingOrder? pending;

    final trades = <ClosedTrade>[];
    final equityCurve = <EquityPoint>[];
    final returns = <double>[];
    double prevEquity = initialBalance;
    final slipFactor = params.slippageBps / 10000.0;

    void closePosition(double exitPrice, int exitTs, String reason) {
      final pos = position!;
      final exitNotional = pos.quantity * exitPrice;
      final exitFee = exitNotional * feeRate;
      totalFees += exitFee;

      final grossPnl = pos.isLong
          ? (exitPrice - pos.entryPrice) * pos.quantity
          : (pos.entryPrice - exitPrice) * pos.quantity;
      final netPnl = grossPnl - pos.entryFee - exitFee;
      final entryNotional = pos.entryPrice * pos.quantity;
      final pnlPct =
          entryNotional > 0 ? (netPnl / entryNotional) * 100 : 0.0;
      final alloc = entryNotional + pos.entryFee;
      balance += alloc + netPnl;

      trades.add(ClosedTrade(
        entryTimestamp: pos.entryTimestamp,
        exitTimestamp: exitTs,
        direction: pos.isLong ? 'LONG' : 'SHORT',
        entryPrice: pos.entryPrice,
        exitPrice: exitPrice,
        quantity: pos.quantity,
        pnl: netPnl,
        pnlPercent: pnlPct,
        fees: pos.entryFee + exitFee,
        exitReason: reason,
      ));
      position = null;
    }

    for (int i = 0; i < n; i++) {
      final candle = candles[i];

      // Step A — fill pending at this bar's open with slippage.
      if (pending != null) {
        switch (pending) {
          case _PendingEnterLong p:
            final entryPrice = candle.open * (1 + slipFactor);
            final alloc = balance * p.sizeFraction;
            final fee = alloc * feeRate;
            final qty = (alloc - fee) / entryPrice;
            position = _OpenPosition(
              isLong: true,
              entryPrice: entryPrice,
              quantity: qty,
              entryTimestamp: candle.timestamp,
              entryFee: fee,
              stopLoss: p.stopLoss,
              takeProfit: p.takeProfit,
              initialSlDistance: (entryPrice - p.stopLoss).abs(),
            );
            balance -= alloc;
            totalFees += fee;
          case _PendingEnterShort p:
            final entryPrice = candle.open * (1 - slipFactor);
            final alloc = balance * p.sizeFraction;
            final fee = alloc * feeRate;
            final qty = (alloc - fee) / entryPrice;
            position = _OpenPosition(
              isLong: false,
              entryPrice: entryPrice,
              quantity: qty,
              entryTimestamp: candle.timestamp,
              entryFee: fee,
              stopLoss: p.stopLoss,
              takeProfit: p.takeProfit,
              initialSlDistance: (p.stopLoss - entryPrice).abs(),
            );
            balance -= alloc;
            totalFees += fee;
        }
        pending = null;
      }

      // Step B — intra-bar TP-first, BE-trail, then SL (D-08 ordering).
      final posPre = position;
      if (posPre != null) {
        final tpHitFirst = posPre.takeProfit != null &&
            (posPre.isLong
                ? candle.high >= posPre.takeProfit!
                : candle.low <= posPre.takeProfit!);
        if (tpHitFirst) {
          closePosition(posPre.takeProfit!, candle.timestamp, 'TakeProfit');
        } else {
          if (!posPre.breakevenApplied && posPre.initialSlDistance != null) {
            final dist = posPre.initialSlDistance!;
            final reached = posPre.isLong
                ? candle.high >= posPre.entryPrice + dist
                : candle.low <= posPre.entryPrice - dist;
            if (reached) {
              posPre.stopLoss = posPre.entryPrice;
              posPre.breakevenApplied = true;
            }
          }
          final slHit = posPre.stopLoss != null &&
              (posPre.isLong
                  ? candle.low <= posPre.stopLoss!
                  : candle.high >= posPre.stopLoss!);
          if (slHit) {
            closePosition(posPre.stopLoss!, candle.timestamp, 'StopLoss');
          }
        }
      }

      // Step C — strategy decision queues a pending order for next bar.
      if (i >= startIdx && pending == null && position == null) {
        // Session filter (default off). Berlin-local hour-of-day using
        // fixed UTC+1 (no DST) — see `withinSession` in
        // `strategy_common.dart`. With BTC + filter-disabled this is a no-op.
        bool sessionOk = true;
        if (params.sessionFilterEnabled) {
          sessionOk = withinSession(
            candle.timestamp,
            params.sessionStartHourLocal,
            params.sessionEndHourLocal,
            1,
          );
        }
        if (sessionOk) {
          final ema = emaSeries[i];
          final dirPrev = directionSeries[i - 1];
          final dirNow = directionSeries[i];
          final smiPrev = smiSeries[i - 1];
          final sigPrev = signalSeries[i - 1];
          final smiNow = smiSeries[i];
          final sigNow = signalSeries[i];

          final flipUp = dirPrev == -1 && dirNow == 1;
          final flipDown = dirPrev == 1 && dirNow == -1;
          final smiCrossUp = smiPrev < sigPrev && smiNow >= sigNow;
          final smiCrossDown = smiPrev > sigPrev && smiNow <= sigNow;
          final smiBelowZero = smiNow < 0.0 && sigNow < 0.0;
          final smiAboveZero = smiNow > 0.0 && sigNow > 0.0;
          // Path-B zero-line gate (mirrors `detect_entry` in
          // rust/trading_engine/src/addins/ut_bot.rs).
          final smiLongOk =
              params.smiCrossAboveZero ? smiAboveZero : smiBelowZero;
          final smiShortOk =
              params.smiCrossAboveZero ? smiBelowZero : smiAboveZero;

          final allValid = !ema.isNaN &&
              !smiPrev.isNaN &&
              !sigPrev.isNaN &&
              !smiNow.isNaN &&
              !sigNow.isNaN;
          // Welle R2-3 ADX regime gate (closure mirrors BB+RSI shape).
          // Returns `true` when disabled — pre-R2 hot path bit-exact.
          bool regimeOk(bool isLong) {
            if (!params.adxFilterEnabled) return true;
            if (adxSeries == null ||
                plusDiSeries == null ||
                minusDiSeries == null) {
              return false;
            }
            return regimePassesFilter(
              adxSeries[i],
              plusDiSeries[i],
              minusDiSeries[i],
              params.adxThreshold,
              isLong,
              params.adxUseDiConfluence,
            );
          }

          if (allValid) {
            final price = candle.close;
            if (price > ema &&
                flipUp &&
                smiCrossUp &&
                smiLongOk &&
                regimeOk(true)) {
              final preLows = [
                for (int j = i - params.swingLookbackBars; j < i;
                    j++)
                  candles[j].low,
              ];
              final swing = swingLow(preLows);
              if (swing != null && swing < price) {
                final slDist = price - swing;
                final tp = price + params.tpRrRatio * slDist;
                // N-08: fee-aware risk sizing (mirror of ut_bot.rs:566).
                final size = positionSizePctFeeAware(
                      price,
                      swing,
                      params.riskPerTrade,
                      feeRate,
                    ) /
                    100.0;
                pending = _PendingEnterLong(swing, tp, size);
              }
            } else if (price < ema &&
                flipDown &&
                smiCrossDown &&
                smiShortOk &&
                regimeOk(false)) {
              final preHighs = [
                for (int j = i - params.swingLookbackBars; j < i;
                    j++)
                  candles[j].high,
              ];
              final swing = swingHigh(preHighs);
              if (swing != null && swing > price) {
                final slDist = swing - price;
                final tp = price - params.tpRrRatio * slDist;
                // N-08: fee-aware risk sizing (mirror of ut_bot.rs:585).
                final size = positionSizePctFeeAware(
                      price,
                      swing,
                      params.riskPerTrade,
                      feeRate,
                    ) /
                    100.0;
                pending = _PendingEnterShort(swing, tp, size);
              }
            }
          }
        }
      }

      // Step D — equity + drawdown + per-bar return.
      final double equity;
      final posForEquity = position;
      if (posForEquity == null) {
        equity = balance;
      } else {
        equity = midTradeEquity(
          balance: balance,
          entryPrice: posForEquity.entryPrice,
          quantity: posForEquity.quantity,
          entryFee: posForEquity.entryFee,
          markPrice: candle.close,
          feeRate: feeRate,
          isLong: posForEquity.isLong,
        );
      }
      if (equity > peakEquity) peakEquity = equity;
      final dd = peakEquity - equity;
      final ddPct = peakEquity > 0 ? (dd / peakEquity) * 100 : 0.0;
      if (dd > maxDrawdown) maxDrawdown = dd;
      if (ddPct > maxDrawdownPct) maxDrawdownPct = ddPct;
      equityCurve.add(EquityPoint(
        timestamp: candle.timestamp,
        equity: equity,
        drawdown: dd,
        drawdownPct: ddPct,
      ));
      if (i > 0) {
        final ret = prevEquity > 0 ? (equity - prevEquity) / prevEquity : 0.0;
        returns.add(ret);
      }
      prevEquity = equity;
    }

    // End-of-data: discard pending. Default path force-closes any still-open
    // position with 'End of Data'; opt-in path snapshots it instead (Welle B4.2-1).
    pending = null;
    OpenPositionSnapshot? openPositionSnapshot;
    if (position != null && candles.isNotEmpty) {
      if (extractOpenPosition) {
        openPositionSnapshot = _snapshotOpenPosition(position!);
        position = null;
      } else {
        final lastCandle = candles.last;
        closePosition(lastCandle.close, lastCandle.timestamp, 'End of Data');
      }
    }

    final winningTrades = trades.where((t) => t.pnl > 0).toList();
    final losingTrades = trades.where((t) => t.pnl <= 0).toList();
    final totalPnl = trades.fold<double>(0, (s, t) => s + t.pnl);
    final totalPnlPct =
        initialBalance > 0 ? (totalPnl / initialBalance) * 100 : 0.0;
    final winRate = trades.isNotEmpty
        ? (winningTrades.length / trades.length) * 100
        : 0.0;
    final grossProfit = winningTrades.fold<double>(0, (s, t) => s + t.pnl);
    final grossLoss = losingTrades.fold<double>(0, (s, t) => s + t.pnl.abs());
    double profitFactor = grossLoss > 0 ? grossProfit / grossLoss : 0;
    if (profitFactor > 999.99) profitFactor = 999.99;
    if (grossLoss == 0 && grossProfit > 0) profitFactor = 999.99;
    final sharpe = annualizedSharpe(returns, timeframe);

    return BacktestResult(
      metrics: BacktestMetrics(
        totalTrades: trades.length,
        winningTrades: winningTrades.length,
        losingTrades: losingTrades.length,
        winRate: winRate,
        profitFactor: profitFactor,
        totalPnl: totalPnl,
        totalPnlPercent: totalPnlPct,
        maxDrawdown: maxDrawdown,
        maxDrawdownPercent: maxDrawdownPct,
        sharpeRatio: sharpe,
        totalFees: totalFees,
        candlesProcessed: n,
      ),
      equityCurve: equityCurve,
      trades: trades,
      openPosition: openPositionSnapshot,
    );
  }

  /// Run an Ichimoku Cloud Retest backtest on the given candle data —
  /// pure-Dart mirror of the Rust [`IchimokuStrategy`] in
  /// `rust/trading_engine/src/addins/ichimoku.rs`.
  ///
  /// 5-confluence triggered trend follower per Spec §2 / §3:
  ///   Long  ⇔ close > current_cloud_upper
  ///        AND span_a_future > span_b_future
  ///        AND tenkan > kijun
  ///        AND close > chikou_cloud_upper
  ///        AND score >= +scoreThreshold
  ///   Short = mirrored
  ///   SL_long  = min(kijun, current_cloud_lower)  (Spec §4)
  ///   SL_short = max(kijun, current_cloud_upper)
  ///   TP       = entry ± tpRrRatio × |entry − SL|  (Spec §5)
  ///   Size     = riskPerTrade × close / sl_distance, clamped to [0, 1]
  ///   BE-trail at +1R = engine-side D-08 mechanic (reused unchanged).
  ///
  /// Bar loop reuses the F-04 order from [runBbRsi] / [runUtBot] — Step A
  /// pending → Step B intra-bar SL/TP/BE → Step C strategy decisions →
  /// Step D equity — so the three strategies share execution-order and
  /// equity-curve semantics.
  ///
  /// `timeframe` defaults to [Timeframe.h1] per Spec §1.
  static BacktestResult runIchimoku({
    required List<CandleData> candles,
    required double initialBalance,
    required double feeRate,
    IchimokuParams params = const IchimokuParams(),
    Timeframe timeframe = Timeframe.h1,
    bool extractOpenPosition = false,
  }) {
    final n = candles.length;

    // Strict warm-up — Spec §1.1 / Rust strategy: c4 ("Chikou vs cloud
    // bei i-26") reads past-cloud anchors at index `i - 2*shift`,
    // requiring senkou_b at that index to be valid. Dominant constraint
    // for the default 52/26 setup: 51 + 52 = 103.
    final startIdx = (params.senkouBPeriod - 1) + 2 * params.shift;
    if (n <= startIdx) {
      return _emptyIchimokuResult(n);
    }

    final highs = [for (final c in candles) c.high];
    final lows = [for (final c in candles) c.low];
    final closes = [for (final c in candles) c.close];

    // Pre-compute indicator series ONCE (mirror of the Rust per-bar
    // recompute — numerically identical, just O(N) instead of O(N²)).
    final tenkanSeries = calcTenkanSen(highs, lows, params.tenkanPeriod);
    if (tenkanSeries == null) return _emptyIchimokuResult(n);
    final kijunSeries = calcKijunSen(highs, lows, params.kijunPeriod);
    if (kijunSeries == null) return _emptyIchimokuResult(n);
    final spanA = calcSenkouSpanA(tenkanSeries, kijunSeries);
    if (spanA == null) return _emptyIchimokuResult(n);
    final spanB = calcSenkouSpanB(highs, lows, params.senkouBPeriod);
    if (spanB == null) return _emptyIchimokuResult(n);

    // ── Welle R2-4 ADX regime filter pre-compute ───────────────────────
    // Pre-compute ADX/+DI/-DI series ONCE when the filter is enabled —
    // mirrors the Rust on_candle full-recompute via the shared `calcAdx`
    // helper. When disabled, no ADX work happens — pre-R2 Ichimoku path
    // bit-exact preserved (dart_rust_ichimoku_parity stays green).
    List<double>? adxSeries;
    List<double>? plusDiSeries;
    List<double>? minusDiSeries;
    if (params.adxFilterEnabled) {
      final adxOut = calcAdx(highs, lows, closes, params.adxPeriod);
      if (adxOut != null) {
        adxSeries = adxOut.adx;
        plusDiSeries = adxOut.plusDi;
        minusDiSeries = adxOut.minusDi;
      }
    }

    double balance = initialBalance;
    double peakEquity = initialBalance;
    double maxDrawdown = 0;
    double maxDrawdownPct = 0;
    double totalFees = 0;
    _OpenPosition? position;
    _PendingOrder? pending;

    final trades = <ClosedTrade>[];
    final equityCurve = <EquityPoint>[];
    final returns = <double>[];
    double prevEquity = initialBalance;
    final slipFactor = params.slippageBps / 10000.0;

    void closePosition(double exitPrice, int exitTs, String reason) {
      final pos = position!;
      final exitNotional = pos.quantity * exitPrice;
      final exitFee = exitNotional * feeRate;
      totalFees += exitFee;

      final grossPnl = pos.isLong
          ? (exitPrice - pos.entryPrice) * pos.quantity
          : (pos.entryPrice - exitPrice) * pos.quantity;
      final netPnl = grossPnl - pos.entryFee - exitFee;
      final entryNotional = pos.entryPrice * pos.quantity;
      final pnlPct =
          entryNotional > 0 ? (netPnl / entryNotional) * 100 : 0.0;
      final alloc = entryNotional + pos.entryFee;
      balance += alloc + netPnl;

      trades.add(ClosedTrade(
        entryTimestamp: pos.entryTimestamp,
        exitTimestamp: exitTs,
        direction: pos.isLong ? 'LONG' : 'SHORT',
        entryPrice: pos.entryPrice,
        exitPrice: exitPrice,
        quantity: pos.quantity,
        pnl: netPnl,
        pnlPercent: pnlPct,
        fees: pos.entryFee + exitFee,
        exitReason: reason,
      ));
      position = null;
    }

    for (int i = 0; i < n; i++) {
      final candle = candles[i];

      // Step A — fill pending at this bar's open with slippage.
      if (pending != null) {
        switch (pending) {
          case _PendingEnterLong p:
            final entryPrice = candle.open * (1 + slipFactor);
            final alloc = balance * p.sizeFraction;
            final fee = alloc * feeRate;
            final qty = (alloc - fee) / entryPrice;
            position = _OpenPosition(
              isLong: true,
              entryPrice: entryPrice,
              quantity: qty,
              entryTimestamp: candle.timestamp,
              entryFee: fee,
              stopLoss: p.stopLoss,
              takeProfit: p.takeProfit,
              initialSlDistance: (entryPrice - p.stopLoss).abs(),
            );
            balance -= alloc;
            totalFees += fee;
          case _PendingEnterShort p:
            final entryPrice = candle.open * (1 - slipFactor);
            final alloc = balance * p.sizeFraction;
            final fee = alloc * feeRate;
            final qty = (alloc - fee) / entryPrice;
            position = _OpenPosition(
              isLong: false,
              entryPrice: entryPrice,
              quantity: qty,
              entryTimestamp: candle.timestamp,
              entryFee: fee,
              stopLoss: p.stopLoss,
              takeProfit: p.takeProfit,
              initialSlDistance: (p.stopLoss - entryPrice).abs(),
            );
            balance -= alloc;
            totalFees += fee;
        }
        pending = null;
      }

      // Step B — intra-bar TP-first, BE-trail, then SL (D-08 ordering).
      final posPre = position;
      if (posPre != null) {
        final tpHitFirst = posPre.takeProfit != null &&
            (posPre.isLong
                ? candle.high >= posPre.takeProfit!
                : candle.low <= posPre.takeProfit!);
        if (tpHitFirst) {
          closePosition(
              posPre.takeProfit!, candle.timestamp, 'TakeProfit');
        } else {
          if (!posPre.breakevenApplied &&
              posPre.initialSlDistance != null) {
            final dist = posPre.initialSlDistance!;
            final reached = posPre.isLong
                ? candle.high >= posPre.entryPrice + dist
                : candle.low <= posPre.entryPrice - dist;
            if (reached) {
              posPre.stopLoss = posPre.entryPrice;
              posPre.breakevenApplied = true;
            }
          }
          final slHit = posPre.stopLoss != null &&
              (posPre.isLong
                  ? candle.low <= posPre.stopLoss!
                  : candle.high >= posPre.stopLoss!);
          if (slHit) {
            closePosition(
                posPre.stopLoss!, candle.timestamp, 'StopLoss');
          }
        }
      }

      // Step C — Ichimoku confluence decision queues pending for next bar.
      if (i >= startIdx && pending == null && position == null) {
        bool sessionOk = true;
        if (params.sessionFilterEnabled) {
          sessionOk = withinSession(
            candle.timestamp,
            params.sessionStartHour,
            params.sessionEndHour,
            params.tzOffsetHours,
          );
        }
        if (sessionOk) {
          final tenkanI = tenkanSeries[i];
          final kijunI = kijunSeries[i];
          final spanAFutureI = futureSenkouAtI(spanA, i);
          final spanBFutureI = futureSenkouAtI(spanB, i);

          // Past-cloud anchors. `pastSenkouAtIMinus26` uses the
          // hardcoded cloudShiftBars = 26 — same convention as Rust,
          // pinned bit-for-bit by indicators.dart.
          final pastAi = pastSenkouAtIMinus26(spanA, i);
          final pastBi = pastSenkouAtIMinus26(spanB, i);
          final pastAprev =
              pastSenkouAtIMinus26(spanA, i - cloudShiftBars);
          final pastBprev =
              pastSenkouAtIMinus26(spanB, i - cloudShiftBars);

          if (pastAi != null &&
              pastBi != null &&
              pastAprev != null &&
              pastBprev != null &&
              !tenkanI.isNaN &&
              !kijunI.isNaN &&
              !spanAFutureI.isNaN &&
              !spanBFutureI.isNaN &&
              !pastAi.isNaN &&
              !pastBi.isNaN &&
              !pastAprev.isNaN &&
              !pastBprev.isNaN) {
            final currentCloudUpper =
                pastAi > pastBi ? pastAi : pastBi;
            final currentCloudLower =
                pastAi < pastBi ? pastAi : pastBi;
            final chikouCloudUpper =
                pastAprev > pastBprev ? pastAprev : pastBprev;
            final chikouCloudLower =
                pastAprev < pastBprev ? pastAprev : pastBprev;

            final score = calcIchimokuScore(
                tenkanSeries, kijunSeries, spanA, spanB, closes, i);

            final close = candle.close;
            // Long confluence (Spec §2, all 5 strict `>`).
            final longC1 = close > currentCloudUpper;
            final longC2 = spanAFutureI > spanBFutureI;
            final longC3 = tenkanI > kijunI;
            final longC4 = close > chikouCloudUpper;
            final longC5 = score >= params.scoreThreshold;

            // Welle R2-4 ADX regime gate (closure mirrors BB+RSI /
            // UT-Bot shape). Returns true when disabled — pre-R2 hot
            // path bit-exact.
            bool regimeOk(bool isLong) {
              if (!params.adxFilterEnabled) return true;
              if (adxSeries == null ||
                  plusDiSeries == null ||
                  minusDiSeries == null) {
                return false;
              }
              return regimePassesFilter(
                adxSeries[i],
                plusDiSeries[i],
                minusDiSeries[i],
                params.adxThreshold,
                isLong,
                params.adxUseDiConfluence,
              );
            }

            if (longC1 && longC2 && longC3 && longC4 && longC5 &&
                regimeOk(true)) {
              // Spec §4: SL = min(kijun, cloud_lower) "großzügig".
              final sl = kijunI < currentCloudLower
                  ? kijunI
                  : currentCloudLower;
              final slDist = close - sl;
              if (slDist > 0) {
                final tp = close + params.tpRrRatio * slDist;
                // N-08: fee-aware risk sizing (mirror of ichimoku.rs:711).
                final size = positionSizePctFeeAware(
                      close,
                      sl,
                      params.riskPerTrade,
                      feeRate,
                    ) /
                    100.0;
                pending = _PendingEnterLong(sl, tp, size);
              }
            } else {
              // Short confluence (Spec §3, mirrored).
              final shortC1 = close < currentCloudLower;
              final shortC2 = spanAFutureI < spanBFutureI;
              final shortC3 = kijunI > tenkanI;
              final shortC4 = close < chikouCloudLower;
              final shortC5 = score <= -params.scoreThreshold;

              if (shortC1 && shortC2 && shortC3 && shortC4 && shortC5 &&
                  regimeOk(false)) {
                final sl = kijunI > currentCloudUpper
                    ? kijunI
                    : currentCloudUpper;
                final slDist = sl - close;
                if (slDist > 0) {
                  final tp = close - params.tpRrRatio * slDist;
                  // N-08: fee-aware risk sizing (mirror of ichimoku.rs:732).
                  final size = positionSizePctFeeAware(
                        close,
                        sl,
                        params.riskPerTrade,
                        feeRate,
                      ) /
                      100.0;
                  pending = _PendingEnterShort(sl, tp, size);
                }
              }
            }
          }
        }
      }

      // Step D — equity + drawdown + per-bar return.
      final double equity;
      final posForEquity = position;
      if (posForEquity == null) {
        equity = balance;
      } else {
        equity = midTradeEquity(
          balance: balance,
          entryPrice: posForEquity.entryPrice,
          quantity: posForEquity.quantity,
          entryFee: posForEquity.entryFee,
          markPrice: candle.close,
          feeRate: feeRate,
          isLong: posForEquity.isLong,
        );
      }
      if (equity > peakEquity) peakEquity = equity;
      final dd = peakEquity - equity;
      final ddPct = peakEquity > 0 ? (dd / peakEquity) * 100 : 0.0;
      if (dd > maxDrawdown) maxDrawdown = dd;
      if (ddPct > maxDrawdownPct) maxDrawdownPct = ddPct;
      equityCurve.add(EquityPoint(
        timestamp: candle.timestamp,
        equity: equity,
        drawdown: dd,
        drawdownPct: ddPct,
      ));
      if (i > 0) {
        final ret =
            prevEquity > 0 ? (equity - prevEquity) / prevEquity : 0.0;
        returns.add(ret);
      }
      prevEquity = equity;
    }

    // End-of-data: discard pending. Default path force-closes any still-open
    // position with 'End of Data'; opt-in path snapshots it instead (Welle B4.2-1).
    pending = null;
    OpenPositionSnapshot? openPositionSnapshot;
    if (position != null && candles.isNotEmpty) {
      if (extractOpenPosition) {
        openPositionSnapshot = _snapshotOpenPosition(position!);
        position = null;
      } else {
        final lastCandle = candles.last;
        closePosition(
            lastCandle.close, lastCandle.timestamp, 'End of Data');
      }
    }

    final winningTrades = trades.where((t) => t.pnl > 0).toList();
    final losingTrades = trades.where((t) => t.pnl <= 0).toList();
    final totalPnl = trades.fold<double>(0, (s, t) => s + t.pnl);
    final totalPnlPct =
        initialBalance > 0 ? (totalPnl / initialBalance) * 100 : 0.0;
    final winRate = trades.isNotEmpty
        ? (winningTrades.length / trades.length) * 100
        : 0.0;
    final grossProfit = winningTrades.fold<double>(0, (s, t) => s + t.pnl);
    final grossLoss =
        losingTrades.fold<double>(0, (s, t) => s + t.pnl.abs());
    double profitFactor = grossLoss > 0 ? grossProfit / grossLoss : 0;
    if (profitFactor > 999.99) profitFactor = 999.99;
    if (grossLoss == 0 && grossProfit > 0) profitFactor = 999.99;
    final sharpe = annualizedSharpe(returns, timeframe);

    return BacktestResult(
      metrics: BacktestMetrics(
        totalTrades: trades.length,
        winningTrades: winningTrades.length,
        losingTrades: losingTrades.length,
        winRate: winRate,
        profitFactor: profitFactor,
        totalPnl: totalPnl,
        totalPnlPercent: totalPnlPct,
        maxDrawdown: maxDrawdown,
        maxDrawdownPercent: maxDrawdownPct,
        sharpeRatio: sharpe,
        totalFees: totalFees,
        candlesProcessed: n,
      ),
      equityCurve: equityCurve,
      trades: trades,
      openPosition: openPositionSnapshot,
    );
  }

  /// Snapshot an internal [_OpenPosition] into the cross-engine
  /// [OpenPositionSnapshot] DTO. NaN / Inf values in SL/TP fall back to
  /// `null` so the UI renders "—" without leaking degenerate floats —
  /// matches the Welle B4.2-1 brief's edge-case mitigation.
  static OpenPositionSnapshot _snapshotOpenPosition(_OpenPosition pos) {
    final rawSl = pos.stopLoss;
    final rawTp = pos.takeProfit;
    return OpenPositionSnapshot(
      direction: pos.isLong ? 'LONG' : 'SHORT',
      openedAt: pos.entryTimestamp,
      entryPrice: pos.entryPrice,
      quantity: pos.quantity,
      entryFee: pos.entryFee,
      slPrice: (rawSl != null && rawSl.isFinite) ? rawSl : null,
      tpPrice: (rawTp != null && rawTp.isFinite) ? rawTp : null,
    );
  }

  static BacktestResult _emptyIchimokuResult(int candlesProcessed) {
    return BacktestResult(
      metrics: BacktestMetrics(
        totalTrades: 0, winningTrades: 0, losingTrades: 0,
        winRate: 0, profitFactor: 0, totalPnl: 0, totalPnlPercent: 0,
        maxDrawdown: 0, maxDrawdownPercent: 0, sharpeRatio: 0,
        totalFees: 0, candlesProcessed: candlesProcessed,
      ),
      equityCurve: const [],
      trades: const [],
    );
  }

  static BacktestResult _emptyUtBotResult(int candlesProcessed) {
    return BacktestResult(
      metrics: BacktestMetrics(
        totalTrades: 0, winningTrades: 0, losingTrades: 0,
        winRate: 0, profitFactor: 0, totalPnl: 0, totalPnlPercent: 0,
        maxDrawdown: 0, maxDrawdownPercent: 0, sharpeRatio: 0,
        totalFees: 0, candlesProcessed: candlesProcessed,
      ),
      equityCurve: const [],
      trades: const [],
    );
  }

}
