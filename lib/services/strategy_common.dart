/// Strategy-agnostic helpers shared across multiple Dart-fallback engines.
///
/// Phase-2 Welle I2-0 mirrors `rust/trading_engine/src/addins/common.rs`
/// so the Dart backtest engine stays bit-identical to the native Rust
/// engine. New entries belong here once a second engine (Ichimoku) starts
/// consuming the same helper that UT-Bot already uses — keeping them in
/// `backtest_service.dart` would force every strategy file to know about
/// every other strategy's window/conversion code.
///
/// Phase-2.5 Welle R1 adds [calcAdx] (Average Directional Index, Wilder
/// 1978) as the engine-shared regime helper. Welle R2 wires it into all
/// three strategies (UT-Bot, BB+RSI, Ichimoku); placing it here from
/// day one avoids the `calc_atr` mistake of localising a soon-to-be-shared
/// helper inside one strategy file.
library;

/// Return `true` if [timestampMs] falls inside the local-hour window
/// `[startHour, endHour)` when interpreted in the fixed local timezone
/// `UTC + tzOffsetHours`.
///
/// Conventions (locked for Dart↔Rust parity, mirror of `within_session`
/// in `rust/trading_engine/src/addins/common.rs`):
///
/// - [tzOffsetHours]: integer hours east of UTC (Berlin standard = `1`).
///   No DST handling — the helper is intentionally deterministic;
///   callers for DST-sensitive assets must pre-shift the timestamp.
/// - `startHour == endHour` → degenerate window → returns `false`
///   (filter is a no-op rather than silently activating 24/7).
/// - `startHour < endHour` → standard inclusive-exclusive window
///   (so `endHour = 23` excludes 23:00:00 itself).
/// - `startHour > endHour` → overnight wrap-around window
///   `[startHour, 24) ∪ [0, endHour)`.
/// - Hours are taken modulo 24 (so passing `25` is treated as `1`).
bool withinSession(
  int timestampMs,
  int startHour,
  int endHour,
  int tzOffsetHours,
) {
  final secsUtc = timestampMs ~/ 1000;
  final secsLocal = secsUtc + tzOffsetHours * 3600;
  final hour = ((secsLocal ~/ 3600) % 24).toInt();
  final start = startHour % 24;
  final end = endHour % 24;
  if (start == end) return false;
  if (start < end) {
    return hour >= start && hour < end;
  }
  return hour >= start || hour < end;
}

// ─── ADX (Average Directional Index, Wilder 1978) ──────────────────────────

/// Compute the Average Directional Index (ADX) with its +DI / -DI
/// components, using Wilder's two-stage smoothing (1978).
///
/// Convention (locked for Dart↔Rust parity, mirrors `calc_adx` in
/// `rust/trading_engine/src/addins/common.rs`):
///
/// 1. **True Range** — identical to `calcAtr` in `indicators.dart`:
///    `tr[0] = high[0] - low[0]`,
///    `tr[i] = max(high[i] - low[i], |high[i] - close[i-1]|,
///                 |low[i]  - close[i-1]|)` for `i >= 1`.
/// 2. **Directional Movement** — `+dm[0] = -dm[0] = 0`; for `i >= 1`:
///    - `up   = high[i]  - high[i - 1]`
///    - `down = low[i-1] - low[i]`
///    - `+dm[i] = up   if up > down && up   > 0 else 0`
///    - `-dm[i] = down if down > up && down > 0 else 0`
/// 3. **Wilder smoothing** (RMA) of TR, +DM, -DM. Seed at index
///    `period - 1`: `mean(tr[0..period])`, etc. — matches the `calcAtr`
///    seed convention. For `i >= period`:
///    `tr_s[i] = (tr_s[i-1] * (period - 1) + tr[i]) / period`.
/// 4. **Directional Indicators** at `i >= period - 1`:
///    `+DI[i] = 100 * +dm_s[i] / tr_s[i]` (0 if `tr_s == 0`).
/// 5. **Directional Index** `DX[i] = 100 * |+DI - -DI| / (+DI + -DI)`
///    (0 if `+DI + -DI == 0`).
/// 6. **ADX** = Wilder smoothing of DX. Seed at `i = 2 * period - 2`:
///    `mean(DX[period - 1 ..= 2 * period - 2])` — i.e. the first
///    `period` valid DX values. For `i >= 2 * period - 1`:
///    `adx[i] = (adx[i-1] * (period - 1) + dx[i]) / period`.
///
/// Returns `null` if [period] is `0`, the input lists have mismatched
/// lengths, or fewer than [period] candles are supplied (i.e. not even
/// the first +DI / -DI can be seeded). When `period <= n < 2*period - 1`
/// the function still returns a record with valid `plusDi` / `minusDi`
/// values from index `period - 1` onward, but the `adx` list stays
/// entirely `double.nan` — useful for callers that need DI exposure
/// without waiting for the full ADX warm-up.
///
/// Returned record holds three `List<double>` of length `closes.length`:
/// the smoothed ADX line plus the per-bar +DI and -DI components.
({List<double> adx, List<double> plusDi, List<double> minusDi})? calcAdx(
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
  final periodD = period.toDouble();

  // Step 1: TR (identical to calcAtr) and +DM / -DM per bar.
  final tr = List<double>.filled(n, 0.0);
  final pdm = List<double>.filled(n, 0.0);
  final mdm = List<double>.filled(n, 0.0);
  tr[0] = highs[0] - lows[0];
  for (int i = 1; i < n; i++) {
    final hl = highs[i] - lows[i];
    final hpc = (highs[i] - closes[i - 1]).abs();
    final lpc = (lows[i] - closes[i - 1]).abs();
    double m = hl;
    if (hpc > m) m = hpc;
    if (lpc > m) m = lpc;
    tr[i] = m;

    final up = highs[i] - highs[i - 1];
    final down = lows[i - 1] - lows[i];
    if (up > down && up > 0.0) pdm[i] = up;
    if (down > up && down > 0.0) mdm[i] = down;
  }

  // Step 2: Wilder smoothing of TR, +DM, -DM. Seed at index period - 1
  // from the mean of the first `period` raw values — same convention as
  // calcAtr so the seed indices align bit-for-bit between helpers.
  final trS = List<double>.filled(n, double.nan);
  final pdmS = List<double>.filled(n, double.nan);
  final mdmS = List<double>.filled(n, double.nan);
  double sumTr = 0.0, sumPdm = 0.0, sumMdm = 0.0;
  for (int i = 0; i < period; i++) {
    sumTr += tr[i];
    sumPdm += pdm[i];
    sumMdm += mdm[i];
  }
  trS[period - 1] = sumTr / periodD;
  pdmS[period - 1] = sumPdm / periodD;
  mdmS[period - 1] = sumMdm / periodD;
  for (int i = period; i < n; i++) {
    trS[i] = (trS[i - 1] * (periodD - 1.0) + tr[i]) / periodD;
    pdmS[i] = (pdmS[i - 1] * (periodD - 1.0) + pdm[i]) / periodD;
    mdmS[i] = (mdmS[i - 1] * (periodD - 1.0) + mdm[i]) / periodD;
  }

  // Step 3: +DI / -DI / DX at every index where smoothed TR is defined.
  // TR_s == 0 (constant flat market) → no movement at all → DI = DX = 0.
  // DI sum == 0 → directional movement cancels → DX = 0 (numerator
  // is also 0).
  final plusDi = List<double>.filled(n, double.nan);
  final minusDi = List<double>.filled(n, double.nan);
  final dx = List<double>.filled(n, double.nan);
  for (int i = period - 1; i < n; i++) {
    final trv = trS[i];
    if (trv > 0.0) {
      final pdi = 100.0 * pdmS[i] / trv;
      final mdi = 100.0 * mdmS[i] / trv;
      plusDi[i] = pdi;
      minusDi[i] = mdi;
      final sumDi = pdi + mdi;
      dx[i] = sumDi > 0.0 ? 100.0 * (pdi - mdi).abs() / sumDi : 0.0;
    } else {
      plusDi[i] = 0.0;
      minusDi[i] = 0.0;
      dx[i] = 0.0;
    }
  }

  // Step 4: ADX = Wilder smoothing of DX. Seed at i = 2*period - 2 from
  // the mean of the first `period` valid DX values. Requires at least
  // 2*period - 1 candles to land a seed; otherwise the adx list stays
  // entirely NaN and the function still returns the record so callers
  // can use +DI / -DI.
  final adx = List<double>.filled(n, double.nan);
  final adxSeedIdx = 2 * period - 2;
  if (n > adxSeedIdx) {
    double sumDx = 0.0;
    for (int i = period - 1; i <= adxSeedIdx; i++) {
      sumDx += dx[i];
    }
    adx[adxSeedIdx] = sumDx / periodD;
    for (int i = adxSeedIdx + 1; i < n; i++) {
      adx[i] = (adx[i - 1] * (periodD - 1.0) + dx[i]) / periodD;
    }
  }

  return (adx: adx, plusDi: plusDi, minusDi: minusDi);
}
