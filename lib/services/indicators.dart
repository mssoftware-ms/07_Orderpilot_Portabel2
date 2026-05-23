/// Pure indicator helpers shared across the Dart backtest engine.
///
/// These mirror the algorithms in `rust/trading_engine/src/addins/bb_rsi.rs`
/// bit-for-bit so the Dart fallback engine and the native Rust engine
/// agree to 1e-9 on the same input. New entries belong here (not inlined
/// in `backtest_service.dart`) so a future LSP / lightweight-charts plot
/// can reuse them without dragging in the whole backtest engine.
library;

/// Compute the swing low: minimum value across the given `lows`.
///
/// Convention (locked for Dart↔Rust parity, see `swing_low` in
/// `rust/trading_engine/src/addins/bb_rsi.rs`): the caller selects which
/// bars to feed, the helper does no slicing.
/// `01_Projectplan/specs/bb_rsi_spec.md` §4 defines the swing-low SL for
/// a long entry at bar `i` as `min(low[i - N .. i - 1])` — the N bars
/// BEFORE the signal bar, exclusive of the signal bar itself.
/// Returns `null` if `lows` is empty.
double? swingLow(List<double> lows) {
  if (lows.isEmpty) return null;
  var min = double.infinity;
  for (final v in lows) {
    if (v < min) min = v;
  }
  return min;
}

/// Compute the swing high: maximum value across the given `highs`.
///
/// Mirror of [swingLow] for the short side. Spec §4 short-entry SL is
/// `max(high[i - N .. i - 1])` — N highs before the signal bar, exclusive.
double? swingHigh(List<double> highs) {
  if (highs.isEmpty) return null;
  var max = double.negativeInfinity;
  for (final v in highs) {
    if (v > max) max = v;
  }
  return max;
}

/// Compute the Exponential Moving Average over a full close-price history.
///
/// Convention (locked for Dart↔Rust parity, see `calc_ema` in
/// `rust/trading_engine/src/addins/bb_rsi.rs`):
/// - Returns `null` if `period == 0` or `values.length < period`.
/// - Alpha = `2 / (period + 1)` — the standard "smoothing factor".
/// - The EMA is **SMA-seeded**: the first `period` values are averaged
///   to form the initial EMA, then `ema = alpha * v + (1 - alpha) * ema`
///   is applied recursively for every subsequent value. Matches TA-Lib,
///   pandas-ta, and TradingView (`ta.ema`).
/// - When `values.length == period`, the result equals the seed SMA.
///
/// EMA is path-dependent: feeding only the last N closes restarts the
/// seed from a different SMA and drifts compared to the cumulative
/// computation. Callers must therefore pass the full prior-close
/// history `closes.sublist(0, i + 1)`, mirroring the F-02b RSI contract.
double? calcEma(List<double> values, int period) {
  if (period == 0 || values.length < period) {
    return null;
  }
  final alpha = 2.0 / (period + 1);
  double ema = 0.0;
  for (int i = 0; i < period; i++) {
    ema += values[i];
  }
  ema /= period;
  for (int i = period; i < values.length; i++) {
    ema = alpha * values[i] + (1.0 - alpha) * ema;
  }
  return ema;
}
