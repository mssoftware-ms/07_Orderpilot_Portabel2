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

/// Compute the UT Bot ATR-trailing-stop line and per-bar direction
/// (close-vs-trail bias) over a candle stream.
///
/// Pinescript reference: QuantNomad's "UT Bot Alerts" — see Spec §1 of
/// `01_Projectplan/specs/ut_bot_spec.md`. Convention locked for
/// Dart↔Rust parity (mirrors `calc_ut_bot_trail` in
/// `rust/trading_engine/src/addins/ut_bot.rs`):
///
/// ```text
/// nLoss = keyValue * ATR(atrPeriod)
/// trail[i] = max(trail[i-1], close[i] - nLoss)   if close[i] > trail[i-1] AND close[i-1] > trail[i-1]
///          = min(trail[i-1], close[i] + nLoss)   if close[i] < trail[i-1] AND close[i-1] < trail[i-1]
///          = close[i] - nLoss                     if close[i] > trail[i-1] (else)
///          = close[i] + nLoss                     if close[i] < trail[i-1] (else)
/// direction[i] = +1 if close > trail[i]
///              = -1 if close < trail[i]
///              =  0 during ATR warm-up (NaN ATR before first valid)
/// ```
///
/// Seed: at the first valid ATR index we adopt `trail = close - nLoss`
/// (Pinescript `nz(xATRTrailingStop[1], 0)` plus the positive-prices
/// fall-through branch).
///
/// Returns `null` if input lengths mismatch, the slices are empty, or
/// the ATR series contains no valid value.
({List<double> trail, List<int> direction})? calcUtBotTrail(
  List<double> closes,
  List<double> atr,
  double keyValue,
) {
  if (closes.length != atr.length) return null;
  final n = closes.length;
  if (n == 0) return null;

  final trail = List<double>.filled(n, double.nan);
  final direction = List<int>.filled(n, 0);

  int firstValid = -1;
  for (int i = 0; i < n; i++) {
    if (!atr[i].isNaN) {
      firstValid = i;
      break;
    }
  }
  if (firstValid < 0) return null;

  final seedNLoss = keyValue * atr[firstValid];
  trail[firstValid] = closes[firstValid] - seedNLoss;
  if (closes[firstValid] > trail[firstValid]) {
    direction[firstValid] = 1;
  } else if (closes[firstValid] < trail[firstValid]) {
    direction[firstValid] = -1;
  } else {
    direction[firstValid] = 0;
  }

  for (int i = firstValid + 1; i < n; i++) {
    final nloss = keyValue * atr[i];
    final prevTrail = trail[i - 1];
    final close = closes[i];
    final prevClose = closes[i - 1];

    double newTrail;
    if (close > prevTrail && prevClose > prevTrail) {
      final candidate = close - nloss;
      newTrail = candidate > prevTrail ? candidate : prevTrail;
    } else if (close < prevTrail && prevClose < prevTrail) {
      final candidate = close + nloss;
      newTrail = candidate < prevTrail ? candidate : prevTrail;
    } else if (close > prevTrail) {
      newTrail = close - nloss;
    } else {
      newTrail = close + nloss;
    }

    trail[i] = newTrail;
    if (close > newTrail) {
      direction[i] = 1;
    } else if (close < newTrail) {
      direction[i] = -1;
    } else {
      direction[i] = direction[i - 1];
    }
  }

  return (trail: trail, direction: direction);
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

// ─── Ichimoku rolling-window primitives (Phase-2 Welle I1) ──────────────────

/// Maximum of `values[endIdx + 1 - period ..= endIdx]` — the highest
/// value across the last `period` samples **including the bar at
/// `endIdx` itself**.
///
/// `endIdx` is **inclusive** — at index `i` with `period = N`, the
/// helper looks at the `N` bars ending at bar `i`. This matches the
/// Ichimoku convention `HH_N = highest(high, N)` (Spec §1) and the
/// pandas-ta `ta.highest` / Pinescript `ta.highest` operators.
///
/// Returns `double.nan` when the window cannot be filled:
/// - `period == 0`
/// - `values` is empty
/// - `endIdx >= values.length`
/// - `period > endIdx + 1` (warm-up region — fewer than `period`
///   samples available at or before `endIdx`)
///
/// NaN samples inside a valid window propagate (any NaN ⇒ NaN result),
/// matching the Pinescript/pandas-ta semantics where `na` poisons the
/// aggregate. Locked bit-identical against `rolling_max` in
/// `rust/trading_engine/src/addins/ichimoku.rs`.
double rollingMax(List<double> values, int endIdx, int period) {
  if (period == 0 ||
      values.isEmpty ||
      endIdx >= values.length ||
      period > endIdx + 1) {
    return double.nan;
  }
  final start = endIdx + 1 - period;
  double max = double.negativeInfinity;
  for (int i = start; i <= endIdx; i++) {
    final v = values[i];
    if (v.isNaN) return double.nan;
    if (v > max) max = v;
  }
  return max;
}

/// Minimum of `values[endIdx + 1 - period ..= endIdx]` — the lowest
/// value across the last `period` samples **including the bar at
/// `endIdx` itself**.
///
/// Mirror of [rollingMax] for the lows side. Same inclusive-`endIdx`
/// convention, same NaN/warm-up semantics. Locked bit-identical against
/// `rolling_min` in `rust/trading_engine/src/addins/ichimoku.rs`.
double rollingMin(List<double> values, int endIdx, int period) {
  if (period == 0 ||
      values.isEmpty ||
      endIdx >= values.length ||
      period > endIdx + 1) {
    return double.nan;
  }
  final start = endIdx + 1 - period;
  double min = double.infinity;
  for (int i = start; i <= endIdx; i++) {
    final v = values[i];
    if (v.isNaN) return double.nan;
    if (v < min) min = v;
  }
  return min;
}

// ─── Tenkan-Sen / Kijun-Sen midpoint lines (Phase-2 Welle I1) ───────────────

/// Shared midpoint-series builder backing both [calcTenkanSen] and
/// [calcKijunSen]: `(HH_N + LL_N) / 2` over a rolling window of size
/// `period`. Returns `null` on hard input errors (mismatched lengths,
/// zero period, or fewer candles than `period`). Otherwise produces a
/// list of length `highs.length` with `double.nan` in the warm-up
/// region (`i < period - 1`).
List<double>? _midpointSeries(
  List<double> highs,
  List<double> lows,
  int period,
) {
  if (period == 0 || highs.length != lows.length) return null;
  final n = highs.length;
  if (n < period) return null;
  final out = List<double>.filled(n, double.nan);
  for (int i = period - 1; i < n; i++) {
    final hh = rollingMax(highs, i, period);
    final ll = rollingMin(lows, i, period);
    if (hh.isNaN || ll.isNaN) continue;
    out[i] = (hh + ll) / 2.0;
  }
  return out;
}

/// Compute the **Tenkan-Sen** (Conversion Line) series.
///
/// `Tenkan-Sen[i] = (highest(high, period) + lowest(low, period)) / 2`
/// over the window `[i + 1 - period ..= i]` (Spec §1.1, default
/// `period = 9`). Indices `0..period - 1` are `double.nan` (warm-up).
/// Returns `null` on mismatched lengths, zero period, or insufficient
/// data. Locked bit-identical against `calc_tenkan_sen` in
/// `rust/trading_engine/src/addins/ichimoku.rs`.
List<double>? calcTenkanSen(
  List<double> highs,
  List<double> lows,
  int period,
) =>
    _midpointSeries(highs, lows, period);

/// Compute the **Kijun-Sen** (Base Line) series.
///
/// Same midpoint math as [calcTenkanSen], differing only in the
/// canonical period (Spec default `period = 26`). Two distinct
/// functions keep the strategy call sites self-documenting.
List<double>? calcKijunSen(
  List<double> highs,
  List<double> lows,
  int period,
) =>
    _midpointSeries(highs, lows, period);

// ─── Senkou-Span A / B (cloud edges, Phase-2 Welle I1) ──────────────────────

/// Canonical Ichimoku cloud-shift in bars (Spec §1.1). Hardcoded here
/// because every read-anchor helper below assumes this value — making
/// it a parameter would change three signatures simultaneously and
/// force every strategy to thread it through. Locked bit-identical
/// against `CLOUD_SHIFT_BARS` in `addins/ichimoku.rs`.
const int cloudShiftBars = 26;

/// Compute **Senkou-Span A** = `(Tenkan + Kijun) / 2`.
///
/// Output is stored **time-aligned to the bar at which both inputs
/// were computed** — there is NO future-shift baked into storage. The
/// visual `+26`-bar shift happens at read time via the explicit
/// read-anchor helpers [futureSenkouAtI] and [pastSenkouAtIMinus26].
///
/// Returns `null` on mismatched lengths. NaN inputs propagate per-bar.
/// Locked bit-identical against `calc_senkou_span_a` in Rust.
List<double>? calcSenkouSpanA(List<double> tenkan, List<double> kijun) {
  if (tenkan.length != kijun.length) return null;
  final n = tenkan.length;
  final out = List<double>.filled(n, double.nan);
  for (int i = 0; i < n; i++) {
    final t = tenkan[i];
    final k = kijun[i];
    if (!t.isNaN && !k.isNaN) {
      out[i] = (t + k) / 2.0;
    }
  }
  return out;
}

/// Compute **Senkou-Span B** = `(HH_period + LL_period) / 2`.
///
/// Same midpoint math as Tenkan/Kijun with the canonical 52-bar window
/// (Spec §1.1 default `period = 52`). Storage convention identical to
/// [calcSenkouSpanA] — no future-shift in storage; reads go through
/// the explicit helpers. Locked bit-identical against
/// `calc_senkou_span_b` in Rust.
List<double>? calcSenkouSpanB(
  List<double> highs,
  List<double> lows,
  int period,
) =>
    _midpointSeries(highs, lows, period);

// ─── Senkou-Span read anchors (explicit time-shift semantics) ───────────────
//
// These three helpers exist so strategy code reads self-documentingly
// instead of indexing raw `span[i]` / `span[i - 26]` without context.
// All three are pure index-into-list; the only purpose is to pin
// temporal intent at every call site (Spec §1.1).

/// Read the Senkou-Span value computed at bar [i] — no time-shift
/// interpretation. Returns `double.nan` for `i >= span.length`.
double senkouAtI(List<double> span, int i) {
  if (i >= span.length) return double.nan;
  return span[i];
}

/// Read the Senkou-Span value that, when visualized on a chart, will
/// be plotted at bar `i + 26` — the "still-projected" cloud computed
/// at bar [i]. Numerically identical to [senkouAtI] because the visual
/// `+26`-shift happens at chart-render time, NOT in storage. Exists so
/// strategy call sites state intent.
double futureSenkouAtI(List<double> span, int i) => senkouAtI(span, i);

/// Read the Senkou-Span value that gets visualized **at bar [i]
/// itself** — the cloud currently plotted at bar [i], computed 26 bars
/// ago. Returns `null` if `i < cloudShiftBars` (no prior history) or
/// `i - cloudShiftBars` is past the list end.
///
/// Workhorse for Ichimoku confluence at bar `i`: to ask "is the close
/// above the current cloud?", compare `close[i]` to
/// `pastSenkouAtIMinus26(spanA, i)` and `pastSenkouAtIMinus26(spanB, i)`.
double? pastSenkouAtIMinus26(List<double> span, int i) {
  if (i < cloudShiftBars) return null;
  final j = i - cloudShiftBars;
  if (j >= span.length) return null;
  return span[j];
}

// ─── Chikou-Span (lagging line, Phase-2 Welle I1) ──────────────────────────

/// Compute the **Chikou-Span** (Lagging Line) series.
///
/// Definition (Spec §1.1): Chikou-Span is the close price, visualized
/// shifted 26 bars backward. The visual displacement happens at
/// chart-render time, NOT in storage — the helper returns a verbatim
/// copy of [closes]. Locked bit-identical against `calc_chikou_span`
/// in Rust.
List<double> calcChikouSpan(List<double> closes) =>
    List<double>.of(closes, growable: false);

/// Chikou-Span confirmation for a **long** entry at bar [i].
///
/// Rule (Spec §1.1): the Chikou-Span — visually plotted at bar `i-26`
/// with value `close[i]` — must be above the historical close at that
/// bar, i.e. `close[i] > close[i - 26]`. Returns `null` if
/// `i < cloudShiftBars` (no prior history) or `i >= closes.length`.
bool? chikouConfirmsLong(List<double> closes, int i) {
  if (i < cloudShiftBars || i >= closes.length) return null;
  return closes[i] > closes[i - cloudShiftBars];
}

/// Chikou-Span confirmation for a **short** entry at bar [i]. Mirror
/// of [chikouConfirmsLong]: requires `close[i] < close[i - 26]`.
bool? chikouConfirmsShort(List<double> closes, int i) {
  if (i < cloudShiftBars || i >= closes.length) return null;
  return closes[i] < closes[i - cloudShiftBars];
}

// ─── Ichimoku confluence score (Spec §12.2) ────────────────────────────────

/// Per-component weight used by [calcIchimokuScore]: three independent
/// components × ±[scoreWeight] = a [-60, +60] range. Strategies refer
/// to `3 * scoreWeight` instead of the literal `60`. Locked bit-identical
/// against `SCORE_WEIGHT` in Rust.
const int scoreWeight = 20;

/// Compute the Ichimoku confluence score at bar [i].
///
/// Sum of three independent ±[scoreWeight] components (Spec §12.2):
///
/// 1. **Cross** — Tenkan vs Kijun at bar `i`.
/// 2. **Color** — past-visible cloud (`spanA[i-26]` vs `spanB[i-26]`).
/// 3. **Distance** — close vs visible-cloud band
///    (`max(past_a, past_b)` / `min(past_a, past_b)`).
///
/// Total range `[-60, +60]`. Spec §12.2 entry threshold is `±60` (full
/// confluence). Past-cloud reads use [pastSenkouAtIMinus26]. Inputs
/// that are `NaN` or out of bounds suppress only the affected
/// component (rest of the score still tallies). Locked bit-identical
/// against `calc_ichimoku_score` in Rust.
int calcIchimokuScore(
  List<double> tenkan,
  List<double> kijun,
  List<double> spanA,
  List<double> spanB,
  List<double> close,
  int i,
) {
  if (i >= tenkan.length || i >= kijun.length || i >= close.length) {
    return 0;
  }

  int score = 0;

  final t = tenkan[i];
  final k = kijun[i];
  if (!t.isNaN && !k.isNaN) {
    if (t > k) {
      score += scoreWeight;
    } else if (t < k) {
      score -= scoreWeight;
    }
  }

  final pastA = pastSenkouAtIMinus26(spanA, i);
  final pastB = pastSenkouAtIMinus26(spanB, i);
  if (pastA != null && pastB != null && !pastA.isNaN && !pastB.isNaN) {
    if (pastA > pastB) {
      score += scoreWeight;
    } else if (pastA < pastB) {
      score -= scoreWeight;
    }

    final c = close[i];
    if (!c.isNaN) {
      final top = pastA > pastB ? pastA : pastB;
      final bottom = pastA < pastB ? pastA : pastB;
      if (c > top) {
        score += scoreWeight;
      } else if (c < bottom) {
        score -= scoreWeight;
      }
    }
  }

  return score;
}
