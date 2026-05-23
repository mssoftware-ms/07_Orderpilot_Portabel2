/// Strategy-agnostic helpers shared across multiple Dart-fallback engines.
///
/// Phase-2 Welle I2-0 mirrors `rust/trading_engine/src/addins/common.rs`
/// so the Dart backtest engine stays bit-identical to the native Rust
/// engine. New entries belong here once a second engine (Ichimoku) starts
/// consuming the same helper that UT-Bot already uses — keeping them in
/// `backtest_service.dart` would force every strategy file to know about
/// every other strategy's window/conversion code.
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
