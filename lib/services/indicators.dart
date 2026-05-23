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

/// Compute the Average True Range (ATR) series with Wilder's smoothing.
///
/// Convention (locked for Dart↔Rust parity, mirrors `calc_atr` in
/// `rust/trading_engine/src/addins/ut_bot.rs`):
///
/// - True Range per bar:
///   - `tr[0] = high[0] - low[0]` (no prior close available; matches the
///     TradingView `ta.atr()` and QuantNomad UT-Bot-Alerts conventions)
///   - `tr[i] = max(high[i] - low[i], |high[i] - close[i-1]|,
///                  |low[i] - close[i-1]|)` for `i >= 1`
/// - Initial ATR is the simple average of the first `period` TR values:
///   `atr[period - 1] = mean(tr[0..period])`. Indices `0..period - 1` are
///   set to `double.nan` to flag the warm-up region (callers must use
///   `.isNaN` to skip).
/// - Wilder smoothing for subsequent bars:
///   `atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period`
///
/// Returns `null` if `period == 0`, if the input lists have mismatched
/// lengths, or if there are fewer than `period` candles. Otherwise the
/// returned `List<double>` has the same length as `closes`.
List<double>? calcAtr(
  List<double> highs,
  List<double> lows,
  List<double> closes,
  int period,
) {
  if (period == 0) return null;
  if (highs.length != closes.length || lows.length != closes.length) {
    return null;
  }
  final n = closes.length;
  if (n < period) return null;

  // True Range per bar — tr[0] is the seed (high - low only).
  final tr = List<double>.filled(n, 0.0);
  tr[0] = highs[0] - lows[0];
  for (int i = 1; i < n; i++) {
    final hl = highs[i] - lows[i];
    final hpc = (highs[i] - closes[i - 1]).abs();
    final lpc = (lows[i] - closes[i - 1]).abs();
    double m = hl;
    if (hpc > m) m = hpc;
    if (lpc > m) m = lpc;
    tr[i] = m;
  }

  // Warm-up: indices 0..period-1 are NaN, atr[period-1] = mean(tr[0..period]).
  final atr = List<double>.filled(n, double.nan);
  double sum = 0.0;
  for (int i = 0; i < period; i++) {
    sum += tr[i];
  }
  atr[period - 1] = sum / period;

  // Wilder smoothing for the remainder.
  for (int i = period; i < n; i++) {
    atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period;
  }

  return atr;
}

/// Compute the Stochastic Momentum Index (SMI, Blau 1993) and its EMA
/// signal line over a candle stream.
///
/// Variant: TradingView Pinescript-standard double-EMA-smoothed SMI per
/// `01_Projectplan/specs/ut_bot_spec.md` §12.4 (Blau-1993-Standard with
/// three free parameters: `length`, `kSmoothing`, `dSmoothing`).
///
/// Convention (locked for Dart↔Rust parity, mirrors `calc_smi` in
/// `rust/trading_engine/src/addins/ut_bot.rs`):
///
/// ```text
/// hh[i]   = highest(high, length) over the last `length` bars (inclusive)
/// ll[i]   = lowest(low,  length)
/// mid[i]  = (hh[i] + ll[i]) / 2
/// diff[i] = close[i] - mid[i]
/// rng[i]  = hh[i] - ll[i]
/// dk  = EMA(diff, kSmoothing);  dkd = EMA(dk, dSmoothing)
/// rk  = EMA(rng,  kSmoothing);  rkd = EMA(rk, dSmoothing)
/// smi[i]    = 200 * dkd[i] / rkd[i]   (NaN where rkd == 0)
/// signal[i] = EMA(smi, dSmoothing)
/// ```
///
/// Returns `null` if any period is zero, if input lists have mismatched
/// lengths, or if there is not enough data to seed the SMI itself
/// (warm-up = `length - 1 + kSmoothing - 1 + dSmoothing - 1`). The
/// returned record holds two `List<double>` of length `closes.length`
/// with `double.nan` in the warm-up region.
({List<double> smi, List<double> signal})? calcSmi(
  List<double> highs,
  List<double> lows,
  List<double> closes,
  int length,
  int kSmoothing,
  int dSmoothing,
) {
  if (length == 0 || kSmoothing == 0 || dSmoothing == 0) return null;
  if (highs.length != closes.length || lows.length != closes.length) {
    return null;
  }
  final n = closes.length;
  final smiStart = (length - 1) + (kSmoothing - 1) + (dSmoothing - 1);
  if (n <= smiStart) return null;

  // Step 1: per-bar diff (close - midpoint) and range (HH - LL).
  final diff = List<double>.filled(n, double.nan);
  final rng = List<double>.filled(n, double.nan);
  for (int i = length - 1; i < n; i++) {
    double hh = highs[i + 1 - length];
    double ll = lows[i + 1 - length];
    for (int j = i + 2 - length; j <= i; j++) {
      if (highs[j] > hh) hh = highs[j];
      if (lows[j] < ll) ll = lows[j];
    }
    diff[i] = closes[i] - (hh + ll) / 2.0;
    rng[i] = hh - ll;
  }

  // Step 2: double-EMA smooth both series. Dart mirror of
  // `ema_series_from` in the Rust module — SMA-seeded EMA matching the
  // Pinescript `ta.ema` convention.
  final diffK = _emaSeriesFrom(diff, kSmoothing, length - 1);
  final diffKd =
      _emaSeriesFrom(diffK, dSmoothing, length - 1 + kSmoothing - 1);
  final rngK = _emaSeriesFrom(rng, kSmoothing, length - 1);
  final rngKd =
      _emaSeriesFrom(rngK, dSmoothing, length - 1 + kSmoothing - 1);

  // Step 3: SMI = 200 * diff_kd / rng_kd, NaN-safe.
  final smi = List<double>.filled(n, double.nan);
  for (int i = smiStart; i < n; i++) {
    final dkd = diffKd[i];
    final rkd = rngKd[i];
    if (!dkd.isNaN && !rkd.isNaN && rkd > 0) {
      smi[i] = 200.0 * dkd / rkd;
    }
  }

  // Step 4: signal = EMA(SMI, dSmoothing).
  final signal = _emaSeriesFrom(smi, dSmoothing, smiStart);

  return (smi: smi, signal: signal);
}

/// Internal helper: SMA-seeded EMA series with explicit warm-up start.
/// Matches `ema_series_from` in `rust/trading_engine/src/addins/ut_bot.rs`
/// — output is `NaN` for indices `0..start + period - 1`, the SMA seed
/// is placed at `start + period - 1`, then the EMA recursion is applied.
List<double> _emaSeriesFrom(List<double> values, int period, int start) {
  final n = values.length;
  final out = List<double>.filled(n, double.nan);
  if (period == 0 || start + period > n) return out;
  final alpha = 2.0 / (period + 1);
  double ema = 0.0;
  for (int i = start; i < start + period; i++) {
    ema += values[i];
  }
  ema /= period;
  out[start + period - 1] = ema;
  for (int i = start + period; i < n; i++) {
    ema = alpha * values[i] + (1.0 - alpha) * ema;
    out[i] = ema;
  }
  return out;
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
