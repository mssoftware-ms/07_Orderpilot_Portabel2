//! Walk-Forward analysis primitives — Phase-3.1 Welle W1.
//!
//! This module supplies the strategy-agnostic infrastructure for rolling-
//! window walk-forward backtests on top of the Welle-O1/O2 single-trial
//! runner. Welle W1 lands the splitter (this commit), the trial runner
//! (W1-2), and the SQLite persistence layer (W1-3); Welle W2 re-runs the
//! qualified Top-109 Ichimoku trials and produces the pre-TPE survivor
//! list.
//!
//! # Why rolling window, not expanding window
//! BTC microstructure shifts non-trivially across a 2-year horizon
//! (post-FTX → post-ETF → halving regime change). An expanding-window
//! walk-forward would weight a 2-year-old training set the same as a
//! 1-month-old one when fitting the most recent validate slice; a rolling
//! window keeps every validate slice anchored to a comparably-recent
//! train slice and therefore measures the strategy's stability against
//! the regime drift we actually care about for Live-Trading.
//!
//! # Convention
//! - `train_bars`: training window size (default for Ichimoku 1h ≈ 6 mo)
//! - `validate_bars`: out-of-sample window size (default ≈ 2 mo)
//! - `step_bars`: advance per split — set equal to `validate_bars` so
//!   the OOS windows tile without overlap (classical Bailey walk-forward).
//!
//! # `f64` count semantics
//! All boundaries are `usize` candle indices; range pairs are
//! half-open `[start, end)` so `slice[range.0..range.1]` gives exactly
//! `range.1 - range.0` candles.

use serde::{Deserialize, Serialize};

/// Configuration for a rolling-window walk-forward run.
///
/// All counts are in candle bars (not calendar days) — the splitter is
/// timeframe-agnostic; the caller chooses bar counts that map to the
/// desired calendar window for the timeframe being studied.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct WalkForwardConfig {
    /// Number of bars in each training (in-sample) window.
    pub train_bars: usize,
    /// Number of bars in each validate (out-of-sample) window.
    pub validate_bars: usize,
    /// Bars advanced between consecutive splits. Set equal to
    /// `validate_bars` for non-overlapping OOS tiling.
    pub step_bars: usize,
    /// Penalty multiplier applied to the OOS standard deviation when
    /// computing the aggregated score. `0.5` is the Welle-W1 default
    /// (stability matters but is not the sole objective).
    pub stability_penalty: f64,
}

impl WalkForwardConfig {
    /// Ichimoku 1h-MVP default — 6-month train, 2-month validate, non-
    /// overlapping OOS tiles. On the 18289-candle BTCUSDT_1h_2023-2025
    /// dataset this yields 9 splits.
    pub fn ichimoku_default() -> Self {
        Self {
            train_bars: 4392,    // ≈ 6 months × 30 days × 24 h
            validate_bars: 1464, // ≈ 2 months × 30 days × 24 h
            step_bars: 1464,
            stability_penalty: 0.5,
        }
    }
}

/// One concrete (train, validate) slice of a candle series.
///
/// Ranges are half-open `[start, end)` so `slice[range.0..range.1]` has
/// length `range.1 - range.0` exactly.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct WalkForwardSplit {
    /// 0-based position in the generated split sequence.
    pub split_index: usize,
    /// Training-window range `(start_idx, end_idx_exclusive)`.
    pub train_range: (usize, usize),
    /// Validation-window range `(start_idx, end_idx_exclusive)`,
    /// guaranteed to immediately follow `train_range`.
    pub validate_range: (usize, usize),
}

/// Generate the full sequence of `(train, validate)` splits for
/// `total_bars` candles under `config`. Strategy-agnostic — the splitter
/// knows nothing about indicators, signals, or PnL.
///
/// # Returned splits
/// For split `k = 0..N`:
/// - `train_range  = [k*step,                 k*step + train_bars)`
/// - `validate_range = [k*step + train_bars,  k*step + train_bars + validate_bars)`
///
/// `N` is the largest integer with `k*step + train_bars + validate_bars
/// <= total_bars`, i.e. the validate window must fully fit. Partial
/// final windows are dropped, not truncated.
///
/// # Edge cases
/// - `total_bars < train_bars + validate_bars` → empty `Vec` (caller's
///   job to surface this as an error).
/// - `step_bars == 0` → empty `Vec` (would otherwise loop forever).
///
/// # Why an inclusive split count formula
/// `count = ⌊(total - train - validate) / step⌋ + 1` (when feasible).
/// The `+ 1` reflects that `k = 0` is already a valid split.
pub fn generate_splits(
    config: &WalkForwardConfig,
    total_bars: usize,
) -> Vec<WalkForwardSplit> {
    if config.step_bars == 0 {
        return Vec::new();
    }
    let min_required = config.train_bars + config.validate_bars;
    if total_bars < min_required {
        return Vec::new();
    }
    let slack = total_bars - min_required;
    let count = slack / config.step_bars + 1;

    let mut out = Vec::with_capacity(count);
    for k in 0..count {
        let train_start = k * config.step_bars;
        let train_end = train_start + config.train_bars;
        let validate_start = train_end;
        let validate_end = validate_start + config.validate_bars;
        out.push(WalkForwardSplit {
            split_index: k,
            train_range: (train_start, train_end),
            validate_range: (validate_start, validate_end),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(train: usize, validate: usize, step: usize) -> WalkForwardConfig {
        WalkForwardConfig {
            train_bars: train,
            validate_bars: validate,
            step_bars: step,
            stability_penalty: 0.5,
        }
    }

    #[test]
    fn classical_split_count_matches_textbook_formula() {
        // 1000 candles, train=200, validate=50, step=50:
        // k*50 + 200 + 50 <= 1000  ⇒  k <= 750/50 = 15  ⇒  16 splits.
        let splits = generate_splits(&cfg(200, 50, 50), 1000);
        assert_eq!(splits.len(), 16);
    }

    #[test]
    fn non_overlapping_oos_when_step_equals_validate() {
        let splits = generate_splits(&cfg(200, 50, 50), 1000);
        for i in 1..splits.len() {
            let prev = splits[i - 1].validate_range;
            let cur = splits[i].validate_range;
            assert!(
                cur.0 >= prev.1,
                "validate windows must not overlap: split[{}].validate = {:?}, split[{}].validate = {:?}",
                i - 1,
                prev,
                i,
                cur,
            );
        }
    }

    #[test]
    fn returns_empty_when_total_smaller_than_train_plus_validate() {
        // 240 candles can't host train=200 + validate=50 (= 250).
        let splits = generate_splits(&cfg(200, 50, 50), 240);
        assert!(splits.is_empty());
    }

    #[test]
    fn exactly_one_split_when_total_equals_train_plus_validate() {
        // 250 candles with train=200, validate=50, step=50 → single split.
        let splits = generate_splits(&cfg(200, 50, 50), 250);
        assert_eq!(splits.len(), 1);
        let only = splits[0];
        assert_eq!(only.split_index, 0);
        assert_eq!(only.train_range, (0, 200));
        assert_eq!(only.validate_range, (200, 250));
    }

    #[test]
    fn ichimoku_default_on_18289_candles_yields_nine_splits() {
        let splits = generate_splits(&WalkForwardConfig::ichimoku_default(), 18289);
        assert_eq!(splits.len(), 9, "got {} splits, expected 9", splits.len());

        // Spot-check boundaries against the convention:
        // split 0:   train=[0, 4392),     validate=[4392, 5856)
        // split 8:   train=[11712, 16104), validate=[16104, 17568)
        let first = splits[0];
        assert_eq!(first.train_range, (0, 4392));
        assert_eq!(first.validate_range, (4392, 5856));

        let last = splits[splits.len() - 1];
        assert_eq!(last.split_index, 8);
        assert_eq!(last.train_range, (11712, 16104));
        assert_eq!(last.validate_range, (16104, 17568));
        // Last validate end-index must fit within the 18289-candle series.
        assert!(last.validate_range.1 <= 18289);
    }

    #[test]
    fn partial_final_validate_window_is_dropped_not_truncated() {
        // 999 candles, train=200, validate=50, step=50:
        // 15 splits fit completely (k=0..14, last validate ends at 14*50+250=950).
        // k=15 would need validate end-index 15*50 + 250 = 1000 > 999 → dropped.
        let splits = generate_splits(&cfg(200, 50, 50), 999);
        assert_eq!(splits.len(), 15);
        let last = splits[splits.len() - 1];
        assert_eq!(last.validate_range, (900, 950));
    }

    #[test]
    fn property_train_window_length_constant_across_splits() {
        let config = cfg(200, 50, 50);
        for splits in [
            generate_splits(&config, 300),
            generate_splits(&config, 500),
            generate_splits(&config, 1000),
            generate_splits(&config, 18289),
        ] {
            for s in &splits {
                assert_eq!(
                    s.train_range.1 - s.train_range.0,
                    config.train_bars,
                    "train window length must equal config.train_bars",
                );
                assert_eq!(
                    s.validate_range.1 - s.validate_range.0,
                    config.validate_bars,
                    "validate window length must equal config.validate_bars",
                );
            }
        }
    }

    #[test]
    fn property_train_end_equals_validate_start() {
        let splits = generate_splits(&cfg(200, 50, 50), 1000);
        for s in &splits {
            assert_eq!(
                s.train_range.1, s.validate_range.0,
                "train end must touch validate start (no gap, no overlap)",
            );
        }
    }

    #[test]
    fn property_validate_end_bounded_by_total() {
        // No split's validate-window may exceed the candle series length.
        for &total in &[251usize, 500, 999, 1000, 18289] {
            let splits = generate_splits(&cfg(200, 50, 50), total);
            for s in &splits {
                assert!(
                    s.validate_range.1 <= total,
                    "split[{}].validate_range = {:?} exceeds total {}",
                    s.split_index,
                    s.validate_range,
                    total,
                );
            }
        }
    }

    #[test]
    fn step_zero_returns_empty_rather_than_looping_forever() {
        let bad = WalkForwardConfig {
            train_bars: 200,
            validate_bars: 50,
            step_bars: 0,
            stability_penalty: 0.5,
        };
        let splits = generate_splits(&bad, 1000);
        assert!(splits.is_empty());
    }

    #[test]
    fn split_indices_are_zero_based_and_monotonic() {
        let splits = generate_splits(&cfg(200, 50, 50), 1000);
        for (i, s) in splits.iter().enumerate() {
            assert_eq!(s.split_index, i);
        }
    }
}
