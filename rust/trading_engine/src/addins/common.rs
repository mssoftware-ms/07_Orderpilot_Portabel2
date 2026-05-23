//! Strategy-agnostic helpers shared across multiple add-ins.
//!
//! Phase-2 Welle I2-0 (engineering plan §4.1 Rule-of-Three) extracts the
//! session filter from `addins/ut_bot.rs` because the Ichimoku strategy
//! needs the same window check. The original `is_in_session` had Berlin
//! UTC+1 hard-coded; [`within_session`] takes the timezone offset as a
//! parameter so future addins (alt-asset, US sessions, etc.) can reuse it
//! without forking the helper again.
//!
//! Dart mirror: `lib/services/strategy_common.dart`. Behavior is locked
//! bit-identical between the two engines.

/// Return `true` if the bar's `timestamp_ms` falls inside the local-hour
/// window `[start_hour, end_hour)` when interpreted in the fixed local
/// timezone `UTC + tz_offset_hours`.
///
/// Conventions (locked for Dart↔Rust parity):
///
/// - `tz_offset_hours`: integer hours east of UTC (Berlin standard = `1`).
///   No DST handling — the helper is intentionally deterministic; callers
///   for DST-sensitive assets must pre-shift the timestamp.
/// - `start_hour == end_hour` → degenerate window → returns `false`
///   (filter is a no-op rather than silently activating 24/7).
/// - `start_hour < end_hour` → straightforward inclusive-exclusive window
///   (so `end_hour = 23` excludes 23:00:00 itself).
/// - `start_hour > end_hour` → overnight wrap-around window
///   `[start_hour, 24) ∪ [0, end_hour)`.
/// - Hours are taken modulo 24 (so passing `25` is treated as `1`).
pub fn within_session(
    timestamp_ms: i64,
    start_hour: u32,
    end_hour: u32,
    tz_offset_hours: i32,
) -> bool {
    let secs_utc = timestamp_ms.div_euclid(1000);
    let secs_local = secs_utc + (tz_offset_hours as i64) * 3600;
    let hour = (secs_local.div_euclid(3600).rem_euclid(24)) as u32;
    let start = start_hour.rem_euclid(24);
    let end = end_hour.rem_euclid(24);
    if start == end {
        return false;
    }
    if start < end {
        hour >= start && hour < end
    } else {
        hour >= start || hour < end
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: build a UTC timestamp for `hour` (0..23) on 2024-01-15.
    /// With `tz_offset_hours = 1` the local hour equals `hour_utc + 1`
    /// (mod 24), matching the Berlin-no-DST convention used by UT-Bot.
    fn ts_at_utc_hour(hour: i64) -> i64 {
        // 2024-01-15 00:00:00 UTC = 1705276800000 ms (no DST in January).
        const BASE_UTC_MS: i64 = 1_705_276_800_000;
        BASE_UTC_MS + hour * 3_600_000
    }

    // ── UT-Bot baseline parity (Berlin = UTC+1) ─────────────────────────
    // These six tests preserve the exact contracts the pre-refactor
    // `is_in_session(ts, start, end)` had — same fixture, same start/end,
    // tz_offset_hours = 1. If any of them flips, UT-Bot behavior has
    // drifted and Welle-I2-0-1 has shipped a bug.

    #[test]
    fn test_within_session_inside_window() {
        // Window 09:00–23:00 Berlin (= 08:00–22:00 UTC).
        // UTC 10:00 → local 11:00 → inside.
        assert!(within_session(ts_at_utc_hour(10), 9, 23, 1));
    }

    #[test]
    fn test_within_session_before_window() {
        // UTC 03:00 → local 04:00 → outside (before 09:00).
        assert!(!within_session(ts_at_utc_hour(3), 9, 23, 1));
    }

    #[test]
    fn test_within_session_at_window_start_inclusive() {
        // UTC 08:00 → local 09:00 exactly → inside (`>= start`).
        assert!(within_session(ts_at_utc_hour(8), 9, 23, 1));
    }

    #[test]
    fn test_within_session_at_window_end_exclusive() {
        // UTC 22:00 → local 23:00 exactly → outside (`< end`).
        assert!(!within_session(ts_at_utc_hour(22), 9, 23, 1));
    }

    #[test]
    fn test_within_session_overnight_wrap() {
        // Window 22:00–06:00 Berlin: bars at local 23 and local 02
        // are inside, bar at local 10 is outside.
        // local 23 = UTC 22
        assert!(within_session(ts_at_utc_hour(22), 22, 6, 1));
        // local 02 = UTC 01
        assert!(within_session(ts_at_utc_hour(1), 22, 6, 1));
        // local 10 = UTC 09
        assert!(!within_session(ts_at_utc_hour(9), 22, 6, 1));
    }

    #[test]
    fn test_within_session_degenerate_window_is_off() {
        // start == end → no-op (always returns false). Pins the
        // documented degenerate behavior so an accidental `start=end`
        // config does not silently enable a 24/7 filter.
        assert!(!within_session(ts_at_utc_hour(10), 12, 12, 1));
    }

    // ── tz_offset_hours parameter ───────────────────────────────────────

    #[test]
    fn test_within_session_utc_zero_offset() {
        // tz_offset_hours = 0 → local equals UTC, no shift.
        // UTC 09:00 → local 09:00 → inside [09, 23).
        assert!(within_session(ts_at_utc_hour(9), 9, 23, 0));
        // UTC 08:00 → local 08:00 → outside [09, 23).
        assert!(!within_session(ts_at_utc_hour(8), 9, 23, 0));
    }

    #[test]
    fn test_within_session_negative_offset_west_of_utc() {
        // tz_offset_hours = -5 (e.g. US Eastern Standard Time).
        // UTC 14:00 → local 09:00 → inside [09, 23).
        assert!(within_session(ts_at_utc_hour(14), 9, 23, -5));
        // UTC 13:00 → local 08:00 → outside.
        assert!(!within_session(ts_at_utc_hour(13), 9, 23, -5));
    }

    #[test]
    fn test_within_session_hours_modulo_24() {
        // Hours outside [0, 24) are reduced mod 24. Window (25, 47, 1)
        // ≡ (1, 23, 1) → UTC 10:00 + Berlin = local 11:00 → inside.
        assert!(within_session(ts_at_utc_hour(10), 25, 47, 1));
    }
}
