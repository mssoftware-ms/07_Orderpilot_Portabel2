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

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};

use crate::backtest::BacktestConfig;
use crate::models::Candle;

use super::runner::run_optimization_trial;
use super::scoring::StrategyKind;
use super::{ScoreConstraints, TrialMetrics, TrialParams};

/// Selection of the stability-penalized aggregation formula applied to a
/// trial's per-split OOS profit-factor vector. Welle W1/W2 shipped only
/// `MeanStdPenalty`; Welle W3 introduces the two robust alternatives so
/// the survivor pool is not dictated by a handful of high-PF outliers.
///
/// # Variants
/// - `MeanStdPenalty { penalty }` — legacy: `mean(OOS_PF) − std(OOS_PF) · penalty`
/// - `MedianIqr { iqr_penalty }`  — robust: `median(OOS_PF) − iqr(OOS_PF) · iqr_penalty`
/// - `TrimmedMean { trim_pct }`   — robust: trim top + bottom `trim_pct` first,
///   then `trimmed_mean − trimmed_std · 0.5` (the inner penalty is fixed
///   because the trimming itself is the primary outlier defense).
///
/// All sanitization (NaN / ±Inf → 0.0) happens once inside
/// `compute_aggregated_score`; each variant therefore only sees finite
/// inputs.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StabilityScoreMethod {
    /// Welle-W1/W2 default. `penalty` weights the OOS standard deviation
    /// subtracted from the mean; `0.5` reproduces the legacy formula.
    MeanStdPenalty { penalty: f64 },
    /// Bailey-de-Prado-robust: rank statistic over the OOS series.
    /// `iqr_penalty` weights the interquartile range subtracted from the
    /// median. Linear-interpolation percentiles (numpy / R Type-7).
    MedianIqr { iqr_penalty: f64 },
    /// Trim `trim_pct` of the OOS series off each tail (floor on n ·
    /// trim_pct), then score the remaining centre as `trimmed_mean − 0.5
    /// · trimmed_std`. `trim_pct = 0.2` removes 20 % top + 20 % bottom.
    TrimmedMean { trim_pct: f64 },
}

impl StabilityScoreMethod {
    /// Welle-W1/W2 legacy default — `mean − std · 0.5`.
    pub fn legacy_default() -> Self {
        Self::MeanStdPenalty { penalty: 0.5 }
    }
}

/// Configuration for a rolling-window walk-forward run.
///
/// All counts are in candle bars (not calendar days) — the splitter is
/// timeframe-agnostic; the caller chooses bar counts that map to the
/// desired calendar window for the timeframe being studied.
///
/// # Backward compatibility
/// `stability_method` was added in Welle W3 with `#[serde(default)]`, so
/// pre-W3 `config_json` blobs in the Welle-W2 SQLite store
/// (`walk_forward_trials.config_json`) deserialize cleanly: `None` falls
/// back to `MeanStdPenalty { penalty: stability_penalty }` via
/// [`WalkForwardConfig::stability_method`].
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct WalkForwardConfig {
    /// Number of bars in each training (in-sample) window.
    pub train_bars: usize,
    /// Number of bars in each validate (out-of-sample) window.
    pub validate_bars: usize,
    /// Bars advanced between consecutive splits. Set equal to
    /// `validate_bars` for non-overlapping OOS tiling.
    pub step_bars: usize,
    /// Legacy penalty multiplier applied to the OOS standard deviation
    /// when `stability_method` is `None` (Welle-W1/W2 default `0.5`).
    /// When `stability_method` is `Some`, this field is *informational
    /// only* — the chosen method carries its own penalty.
    pub stability_penalty: f64,
    /// Welle-W3 stability scoring method. `None` reproduces the legacy
    /// `mean(OOS_PF) − std(OOS_PF) · stability_penalty` formula bit-for-
    /// bit so existing Welle-W2 results stay reproducible.
    #[serde(default)]
    pub stability_method: Option<StabilityScoreMethod>,
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
            stability_method: None,
        }
    }

    /// Resolve the effective stability-scoring method: returns the
    /// explicit `stability_method` when set; otherwise falls back to
    /// `MeanStdPenalty { penalty: self.stability_penalty }` to honour the
    /// legacy Welle-W1/W2 contract for any deserialized pre-W3 config.
    pub fn stability_method(&self) -> StabilityScoreMethod {
        self.stability_method
            .unwrap_or(StabilityScoreMethod::MeanStdPenalty { penalty: self.stability_penalty })
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

// ─── Trial Runner ────────────────────────────────────────────────────────────

/// Result for one (train, validate) split inside a walk-forward trial.
/// Carries the raw `TrialMetrics` from both windows so the aggregation
/// layer (and the SQLite store) can recompute or re-display any
/// per-split diagnostic without re-running the backtest.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WalkForwardSplitResult {
    pub split_index: usize,
    pub train_metrics: TrialMetrics,
    pub validate_metrics: TrialMetrics,
}

/// Outcome of one full walk-forward trial: per-split metrics plus
/// aggregated stability-penalized score.
///
/// # Aggregated score
/// ```text
/// aggregated_score = mean(OOS_PF) - std(OOS_PF) * stability_penalty
/// ```
/// computed over **sanitized** OOS profit factors (NaN / ±Inf → 0.0).
/// If every split's raw OOS PF is non-finite (e.g. zero gross loss
/// across all validate windows, indicating no meaningful trades),
/// `aggregated_score = f64::NEG_INFINITY` so the trial sorts to the
/// bottom of any Top-N query — identical sentinel convention to
/// Welle-O1 `score_trial`.
///
/// # Why stability over raw mean
/// A trial whose OOS-PF distribution is `[3.0, 0.1, 3.0, 0.1, …]`
/// (mean ≈ 1.55) is dangerous in Live-Trading despite its high mean —
/// it's one regime-shift away from a 0.1-PF stretch. The penalty
/// pushes the optimizer toward `[1.5, 1.5, 1.5, …]` style trials
/// where mean and worst converge.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WalkForwardResult {
    pub trial_id: u32,
    pub params: TrialParams,
    pub splits: Vec<WalkForwardSplitResult>,
    pub aggregated_score: f64,
    pub mean_oos_pf: f64,
    pub std_oos_pf: f64,
    pub worst_oos_pf: f64,
    pub mean_is_pf: f64,
    /// Mean IS-PF minus mean OOS-PF — positive values indicate
    /// overfitting (in-sample beat out-of-sample).
    pub is_oos_decay: f64,
}

/// Sanitize a single profit-factor reading: NaN / ±Inf → 0.0, finite
/// values pass through unchanged. Pure function.
fn sanitize_pf(pf: f64) -> f64 {
    if pf.is_finite() {
        pf
    } else {
        0.0
    }
}

/// Median over a pre-sorted slice of sanitized finite `f64`. Empty →
/// `0.0` (caller responsibility to avoid). Sharing the sorted slice
/// with `compute_iqr_sorted` lets `MedianIqr` scoring sort once.
fn compute_median_sorted(sorted: &[f64]) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    if n % 2 == 1 {
        sorted[n / 2]
    } else {
        (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}

/// Linear-interpolation percentile (numpy `linear` / R Type-7). `p` in
/// `[0.0, 1.0]`. Caller passes a slice of sanitized finite `f64`. Pure
/// function — takes a pre-sorted slice to allow median + IQR to share
/// one sort.
fn percentile_sorted(sorted: &[f64], p: f64) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    if n == 1 {
        return sorted[0];
    }
    let idx = (n - 1) as f64 * p;
    let lo = idx.floor() as usize;
    let hi = idx.ceil() as usize;
    if lo == hi {
        sorted[lo]
    } else {
        let frac = idx - lo as f64;
        sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}

/// Interquartile range — `q75 − q25` on a slice of sanitized finite
/// `f64`. Pre-sorted slice required (cheap: callers sort once for
/// median + IQR together).
fn compute_iqr_sorted(sorted: &[f64]) -> f64 {
    percentile_sorted(sorted, 0.75) - percentile_sorted(sorted, 0.25)
}

/// Mean + (population) standard deviation of the centred slice after
/// trimming `trim_pct` of the values off each tail (floor on
/// `n · trim_pct`). Never trims more than half the values; degenerate
/// inputs (`hi <= lo`) return `(0.0, 0.0)`.
fn compute_trimmed_mean_std(values: &[f64], trim_pct: f64) -> (f64, f64) {
    let n = values.len();
    if n == 0 {
        return (0.0, 0.0);
    }
    let mut sorted: Vec<f64> = values.to_vec();
    sorted.sort_by(|a, b| {
        a.partial_cmp(b)
            .expect("compute_trimmed_mean_std requires finite values")
    });
    let raw_trim = (n as f64 * trim_pct).floor() as usize;
    let trim = raw_trim.min(n / 2);
    let lo = trim;
    let hi = n - trim;
    if hi <= lo {
        return (0.0, 0.0);
    }
    let slice = &sorted[lo..hi];
    let len = slice.len() as f64;
    let mean = slice.iter().sum::<f64>() / len;
    let variance = slice.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / len;
    (mean, variance.sqrt())
}

/// Inner penalty applied to the trimmed-std term inside the
/// `TrimmedMean` variant. Hardcoded because the trim already provides
/// the primary outlier defense — the std subtraction is a secondary
/// tiebreaker and would be redundant if exposed as a knob.
const TRIMMED_STD_PENALTY: f64 = 0.5;

/// Compute the aggregated stability-penalized score from the per-split
/// OOS profit factors under `method`. Pure function — sanitizes
/// non-finite inputs to `0.0` once, then dispatches.
///
/// # Empty input
/// Returns `f64::NEG_INFINITY` for the empty slice to keep the
/// sentinel convention consistent with the rest of the optimizer
/// (disqualified trials sort to the bottom of any Top-N query).
pub fn compute_aggregated_score(
    oos_pfs: &[f64],
    method: &StabilityScoreMethod,
) -> f64 {
    if oos_pfs.is_empty() {
        return f64::NEG_INFINITY;
    }
    let sanitized: Vec<f64> = oos_pfs.iter().map(|&pf| sanitize_pf(pf)).collect();
    match method {
        StabilityScoreMethod::MeanStdPenalty { penalty } => {
            let n = sanitized.len() as f64;
            let mean = sanitized.iter().sum::<f64>() / n;
            let variance = sanitized.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n;
            let std = variance.sqrt();
            mean - std * penalty
        }
        StabilityScoreMethod::MedianIqr { iqr_penalty } => {
            let mut sorted = sanitized.clone();
            sorted.sort_by(|a, b| {
                a.partial_cmp(b)
                    .expect("sanitized values are finite by construction")
            });
            let median = compute_median_sorted(&sorted);
            let iqr = compute_iqr_sorted(&sorted);
            median - iqr * iqr_penalty
        }
        StabilityScoreMethod::TrimmedMean { trim_pct } => {
            let (mean_t, std_t) = compute_trimmed_mean_std(&sanitized, *trim_pct);
            mean_t - std_t * TRIMMED_STD_PENALTY
        }
    }
}

/// Aggregate per-split results into a `WalkForwardResult`. Pure
/// function — no engine calls, no I/O — so the score formula can be
/// unit-tested against handcrafted split sequences without paying the
/// backtest cost.
///
/// # Disqualification sentinel
/// When every split's raw OOS PF is non-finite the aggregated score is
/// set to `f64::NEG_INFINITY` regardless of the chosen method —
/// preserves the Welle-O1 convention used across the optimizer pipeline.
///
/// # Panics
/// Never; `splits` must be non-empty (caller responsibility).
pub fn aggregate_walk_forward_with_method(
    trial_id: u32,
    params: TrialParams,
    splits: Vec<WalkForwardSplitResult>,
    method: &StabilityScoreMethod,
) -> WalkForwardResult {
    debug_assert!(
        !splits.is_empty(),
        "aggregate_walk_forward_with_method requires non-empty splits"
    );
    let n = splits.len() as f64;

    let any_finite_oos = splits
        .iter()
        .any(|s| s.validate_metrics.profit_factor.is_finite());

    let oos_pfs: Vec<f64> = splits
        .iter()
        .map(|s| sanitize_pf(s.validate_metrics.profit_factor))
        .collect();
    let is_pfs: Vec<f64> = splits
        .iter()
        .map(|s| sanitize_pf(s.train_metrics.profit_factor))
        .collect();

    let mean_oos = oos_pfs.iter().sum::<f64>() / n;
    let variance_oos = oos_pfs
        .iter()
        .map(|x| (x - mean_oos).powi(2))
        .sum::<f64>()
        / n;
    let std_oos = variance_oos.sqrt();
    let worst_oos = oos_pfs.iter().copied().fold(f64::INFINITY, f64::min);
    let mean_is = is_pfs.iter().sum::<f64>() / n;

    let aggregated = if any_finite_oos {
        compute_aggregated_score(&oos_pfs, method)
    } else {
        f64::NEG_INFINITY
    };

    WalkForwardResult {
        trial_id,
        params,
        splits,
        aggregated_score: aggregated,
        mean_oos_pf: mean_oos,
        std_oos_pf: std_oos,
        worst_oos_pf: worst_oos,
        mean_is_pf: mean_is,
        is_oos_decay: mean_is - mean_oos,
    }
}

/// Welle-W1/W2 back-compat wrapper for callers that pre-date the
/// `StabilityScoreMethod` dispatch. Identical behavior to
/// `aggregate_walk_forward_with_method(..., &MeanStdPenalty { penalty })`.
pub fn aggregate_walk_forward(
    trial_id: u32,
    params: TrialParams,
    splits: Vec<WalkForwardSplitResult>,
    stability_penalty: f64,
) -> WalkForwardResult {
    aggregate_walk_forward_with_method(
        trial_id,
        params,
        splits,
        &StabilityScoreMethod::MeanStdPenalty {
            penalty: stability_penalty,
        },
    )
}

// ─── Survivor Criteria ───────────────────────────────────────────────────────

/// Hard-constraint gate applied to a `WalkForwardResult` after the
/// rolling-window backtests are scored. A trial that fails **any**
/// criterion is rejected as not-a-survivor; the soft-score (mean −
/// penalty × std) only ranks the survivors against each other.
///
/// # Why four gates instead of one composite score
/// The composite `aggregated_score` collapses overfitting, stability,
/// and floor performance into a single number — a 1.5-mean / 0-std trial
/// scores the same as a 3.0-mean / 1.5-std trial. The four hard gates
/// surface those orthogonal failure modes individually so QA can read
/// off *why* a trial was rejected (or relax exactly the constraint that
/// killed the population).
///
/// # Defaults (Phase-3.1 Welle W2 Ichimoku)
/// | gate              | default | rationale                          |
/// |-------------------|---------|------------------------------------|
/// | `min_mean_oos_pf` | `1.3`   | floor PF on the validate set (≥ ~3 × round-trip fees) |
/// | `max_std_oos_pf`  | `1.0`   | reject wild OOS swings (1.0 PF-σ)  |
/// | `max_is_oos_decay`| `0.7`   | reject IS-PF > OOS-PF by 0.7 (overfitting band) |
/// | `min_worst_oos_pf`| `0.6`   | no single split below 0.6 PF (no disaster regime) |
///
/// These thresholds are an initial Welle-W2 estimate; QA may relax them
/// against the observed distribution if the survivor pool collapses.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct SurvivorCriteria {
    /// Lower bound on `mean_oos_pf`.
    pub min_mean_oos_pf: f64,
    /// Upper bound on `std_oos_pf`.
    pub max_std_oos_pf: f64,
    /// Upper bound on `is_oos_decay` (= mean_is − mean_oos). Positive
    /// values indicate overfitting; the cap rejects strategies whose
    /// in-sample fit collapses on out-of-sample.
    pub max_is_oos_decay: f64,
    /// Lower bound on `worst_oos_pf` — the worst single validate-window
    /// profit factor across the splits.
    pub min_worst_oos_pf: f64,
}

impl Default for SurvivorCriteria {
    /// Welle-W2 Ichimoku defaults — see struct docs for rationale.
    fn default() -> Self {
        Self {
            min_mean_oos_pf: 1.3,
            max_std_oos_pf: 1.0,
            max_is_oos_decay: 0.7,
            min_worst_oos_pf: 0.6,
        }
    }
}

/// Apply every survivor gate; returns `true` iff every gate is
/// satisfied. Pure function — no I/O, no engine calls — so callers can
/// recompute survivor flags on the fly against tweaked criteria
/// without re-running the walk-forward backtests.
pub fn survives(result: &WalkForwardResult, criteria: &SurvivorCriteria) -> bool {
    result.mean_oos_pf >= criteria.min_mean_oos_pf
        && result.std_oos_pf <= criteria.max_std_oos_pf
        && result.is_oos_decay <= criteria.max_is_oos_decay
        && result.worst_oos_pf >= criteria.min_worst_oos_pf
}

/// Run one walk-forward trial: generate splits, score every (train,
/// validate) window via `run_optimization_trial`, then aggregate.
///
/// # Errors
/// Returns `Err` when `candles.len() < train_bars + validate_bars`
/// (i.e. `generate_splits` yields zero splits). Callers in production
/// sweeps should treat this as a configuration error, not a per-trial
/// failure — every trial in the study would hit the same condition.
///
/// # Per-split disqualification semantics
/// The runner does **not** disqualify individual splits — it collects
/// raw metrics for every window and lets the aggregator sanitize. A
/// validate window with zero trades / NaN PF therefore contributes a
/// sanitized 0.0 to the mean / std calculation, dragging the
/// aggregated score down (which is the correct behavior: a strategy
/// that misses an entire OOS window deserves to be penalized).
pub fn run_walk_forward_trial(
    strategy: StrategyKind,
    trial_id: u32,
    params: TrialParams,
    candles: &[Candle],
    config: &WalkForwardConfig,
    base_config: BacktestConfig,
    constraints: &ScoreConstraints,
) -> Result<WalkForwardResult> {
    let splits = generate_splits(config, candles.len());
    if splits.is_empty() {
        return Err(anyhow!(
            "walk-forward: insufficient data — {} candles cannot host one (train={} + validate={}) split (step={})",
            candles.len(),
            config.train_bars,
            config.validate_bars,
            config.step_bars,
        ));
    }

    let mut split_results = Vec::with_capacity(splits.len());
    for split in splits {
        let train_slice = &candles[split.train_range.0..split.train_range.1];
        let validate_slice = &candles[split.validate_range.0..split.validate_range.1];

        let train_trial = run_optimization_trial(
            strategy,
            trial_id,
            params.clone(),
            train_slice,
            base_config.clone(),
            constraints,
        );
        let validate_trial = run_optimization_trial(
            strategy,
            trial_id,
            params.clone(),
            validate_slice,
            base_config.clone(),
            constraints,
        );

        split_results.push(WalkForwardSplitResult {
            split_index: split.split_index,
            train_metrics: train_trial.metrics,
            validate_metrics: validate_trial.metrics,
        });
    }

    Ok(aggregate_walk_forward_with_method(
        trial_id,
        params,
        split_results,
        &config.stability_method(),
    ))
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
            stability_method: None,
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
            stability_method: None,
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

    // ─── Aggregation tests (pure, no backtests) ──────────────────────────────

    use crate::models::Timeframe;

    fn metrics_with_pf(pf: f64, trades: u32) -> TrialMetrics {
        TrialMetrics {
            total_trades: trades,
            total_pnl: 100.0,
            win_rate: 55.0,
            sharpe_ratio: 1.0,
            max_drawdown_pct: 10.0,
            profit_factor: pf,
            final_equity: 10_100.0,
        }
    }

    fn split(i: usize, train_pf: f64, validate_pf: f64) -> WalkForwardSplitResult {
        WalkForwardSplitResult {
            split_index: i,
            train_metrics: metrics_with_pf(train_pf, 50),
            validate_metrics: metrics_with_pf(validate_pf, 50),
        }
    }

    #[test]
    fn aggregate_score_constant_oos_zero_std_means_score_equals_mean() {
        let splits = vec![
            split(0, 1.5, 1.5),
            split(1, 1.5, 1.5),
            split(2, 1.5, 1.5),
        ];
        let result = aggregate_walk_forward(0, TrialParams::new(), splits, 0.5);
        assert!((result.aggregated_score - 1.5).abs() < 1e-12);
        assert!((result.mean_oos_pf - 1.5).abs() < 1e-12);
        assert!(result.std_oos_pf.abs() < 1e-12);
    }

    #[test]
    fn aggregate_score_volatile_oos_penalized_below_stable_with_same_mean() {
        // Trial A: stable [1.5, 1.5, 1.5, 1.5, 1.5, 1.5] → mean=1.5, std=0
        // Trial B: volatile [3.0, 0.1, 3.0, 0.1, 3.0, 0.1] → mean≈1.55, std≈1.45
        //   penalty 0.5 ⇒ B-score = 1.55 - 0.725 = 0.825
        // Acceptance: stability wins.
        let a_splits: Vec<_> = (0..6).map(|i| split(i, 1.5, 1.5)).collect();
        let b_pfs = [3.0, 0.1, 3.0, 0.1, 3.0, 0.1];
        let b_splits: Vec<_> = (0..6)
            .map(|i| split(i, 1.5, b_pfs[i]))
            .collect();
        let a = aggregate_walk_forward(1, TrialParams::new(), a_splits, 0.5);
        let b = aggregate_walk_forward(2, TrialParams::new(), b_splits, 0.5);
        assert!(
            a.aggregated_score > b.aggregated_score,
            "stable trial must score higher: a={} (mean={}, std={}), b={} (mean={}, std={})",
            a.aggregated_score,
            a.mean_oos_pf,
            a.std_oos_pf,
            b.aggregated_score,
            b.mean_oos_pf,
            b.std_oos_pf,
        );
        // Pinned numerical sanity: B aggregated ≈ 0.825 (precise per formula)
        assert!((b.aggregated_score - 0.825).abs() < 1e-9, "b={}", b.aggregated_score);
    }

    #[test]
    fn aggregate_score_all_nan_validate_returns_neg_infinity() {
        let splits = vec![
            split(0, 1.5, f64::NAN),
            split(1, 1.5, f64::NAN),
            split(2, 1.5, f64::INFINITY),
        ];
        let result = aggregate_walk_forward(0, TrialParams::new(), splits, 0.5);
        assert!(result.aggregated_score.is_infinite() && result.aggregated_score < 0.0);
    }

    #[test]
    fn aggregate_partial_disqualification_uses_zero_for_nan_splits() {
        // 3 finite (PF=2.0) + 1 NaN → sanitized PFs [2,2,2,0]
        // mean=1.5, var=((0.5)*3 + (1.5)^2)/4 = (0.75 + 2.25)/4 = 0.75 → std=√0.75≈0.866
        // aggregated = 1.5 - 0.866*0.5 ≈ 1.067
        let splits = vec![
            split(0, 1.0, 2.0),
            split(1, 1.0, 2.0),
            split(2, 1.0, 2.0),
            split(3, 1.0, f64::NAN),
        ];
        let result = aggregate_walk_forward(0, TrialParams::new(), splits, 0.5);
        assert!(result.aggregated_score.is_finite());
        assert!((result.mean_oos_pf - 1.5).abs() < 1e-9, "mean={}", result.mean_oos_pf);
        let expected_std = 0.75f64.sqrt();
        assert!(
            (result.std_oos_pf - expected_std).abs() < 1e-9,
            "std={} (expected {})",
            result.std_oos_pf,
            expected_std,
        );
        let expected_agg = 1.5 - expected_std * 0.5;
        assert!(
            (result.aggregated_score - expected_agg).abs() < 1e-9,
            "agg={} (expected {})",
            result.aggregated_score,
            expected_agg,
        );
    }

    #[test]
    fn aggregate_worst_oos_pf_is_minimum_of_sanitized_validate_pfs() {
        let splits = vec![
            split(0, 1.5, 2.5),
            split(1, 1.5, 0.7),
            split(2, 1.5, 1.8),
            split(3, 1.5, 1.2),
        ];
        let result = aggregate_walk_forward(0, TrialParams::new(), splits, 0.5);
        assert!((result.worst_oos_pf - 0.7).abs() < 1e-12);
    }

    #[test]
    fn aggregate_is_oos_decay_positive_when_train_outperforms_validate() {
        // train PFs all 3.0 → mean_is = 3.0
        // validate PFs all 1.5 → mean_oos = 1.5
        // decay = 1.5 (positive, indicating overfitting)
        let splits: Vec<_> = (0..4).map(|i| split(i, 3.0, 1.5)).collect();
        let result = aggregate_walk_forward(0, TrialParams::new(), splits, 0.5);
        assert!((result.mean_is_pf - 3.0).abs() < 1e-12);
        assert!((result.mean_oos_pf - 1.5).abs() < 1e-12);
        assert!((result.is_oos_decay - 1.5).abs() < 1e-12);
    }

    #[test]
    fn aggregate_sanitizes_nan_train_pf_to_zero_in_mean_is() {
        // train PFs [2.0, 2.0, NaN, 2.0] → sanitized [2,2,0,2] → mean=1.5
        let splits = vec![
            split(0, 2.0, 1.0),
            split(1, 2.0, 1.0),
            split(2, f64::NAN, 1.0),
            split(3, 2.0, 1.0),
        ];
        let result = aggregate_walk_forward(0, TrialParams::new(), splits, 0.5);
        assert!((result.mean_is_pf - 1.5).abs() < 1e-9);
    }

    // ─── Stability score methods (pure, no backtests) ───────────────────────

    #[test]
    fn median_iqr_score_on_uniform_data_matches_textbook_formula() {
        // [1,2,3,4,5] → median=3.0, q25=2.0, q75=4.0, iqr=2.0
        // score = 3.0 − 2.0 × 0.5 = 2.0
        let pfs = [1.0, 2.0, 3.0, 4.0, 5.0];
        let method = StabilityScoreMethod::MedianIqr { iqr_penalty: 0.5 };
        let score = compute_aggregated_score(&pfs, &method);
        assert!((score - 2.0).abs() < 1e-9, "score={}", score);
    }

    #[test]
    fn median_iqr_score_on_even_length_uses_midpoint_median() {
        // [1,2,3,4] → median=(2+3)/2=2.5
        // q25 = idx 0.75 → 1 + (2-1)*0.75 = 1.75
        // q75 = idx 2.25 → 3 + (4-3)*0.25 = 3.25
        // iqr = 1.5, score = 2.5 − 1.5×0.5 = 1.75
        let pfs = [1.0, 2.0, 3.0, 4.0];
        let method = StabilityScoreMethod::MedianIqr { iqr_penalty: 0.5 };
        let score = compute_aggregated_score(&pfs, &method);
        assert!((score - 1.75).abs() < 1e-9, "score={}", score);
    }

    #[test]
    fn trimmed_mean_score_removes_tails_then_penalizes_centred_std() {
        // [0.01, 1.0, 1.5, 2.0, 5.0], trim=0.2 → remove 1 from each tail
        // remaining [1.0, 1.5, 2.0] → mean=1.5, std=√(0.5/3)≈0.408
        // score = 1.5 − 0.408 × 0.5 ≈ 1.296
        let pfs = [0.01, 1.0, 1.5, 2.0, 5.0];
        let method = StabilityScoreMethod::TrimmedMean { trim_pct: 0.2 };
        let score = compute_aggregated_score(&pfs, &method);
        let expected_mean = 1.5_f64;
        let expected_std = (0.5_f64 / 3.0).sqrt();
        let expected = expected_mean - expected_std * TRIMMED_STD_PENALTY;
        assert!(
            (score - expected).abs() < 1e-9,
            "score={}, expected={}",
            score,
            expected,
        );
    }

    #[test]
    fn trimmed_mean_with_pct_below_per_sample_floor_keeps_all_values() {
        // n=4, trim_pct=0.2 → floor(0.8)=0 → keep all 4
        // mean=2.5, var=((-1.5)²+(-0.5)²+0.5²+1.5²)/4 = 1.25, std=√1.25
        // score = 2.5 − √1.25 × 0.5
        let pfs = [1.0, 2.0, 3.0, 4.0];
        let method = StabilityScoreMethod::TrimmedMean { trim_pct: 0.2 };
        let score = compute_aggregated_score(&pfs, &method);
        let expected = 2.5 - (1.25_f64).sqrt() * TRIMMED_STD_PENALTY;
        assert!(
            (score - expected).abs() < 1e-9,
            "score={}, expected={}",
            score,
            expected,
        );
    }

    #[test]
    fn mean_std_penalty_score_matches_legacy_aggregate_walk_forward() {
        // Backward-compat anchor: compute_aggregated_score under
        // MeanStdPenalty must produce the same number that
        // aggregate_walk_forward produced in Welle W1/W2.
        let pfs = [1.5, 2.0, 1.0, 1.5];
        let method = StabilityScoreMethod::MeanStdPenalty { penalty: 0.5 };
        let new_score = compute_aggregated_score(&pfs, &method);

        // Reference: hand-roll the legacy formula
        let n = pfs.len() as f64;
        let mean = pfs.iter().sum::<f64>() / n;
        let var = pfs.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n;
        let legacy = mean - var.sqrt() * 0.5;
        assert!(
            (new_score - legacy).abs() < 1e-12,
            "new={}, legacy={}",
            new_score,
            legacy,
        );
    }

    #[test]
    fn compute_aggregated_score_sanitizes_nan_inputs_before_dispatch() {
        // [NaN, 2.0, 2.0, 2.0] → sanitized [0, 2, 2, 2]
        // mean=1.5, var=(2.25+3·0.25)/4 = 0.75 → std=√0.75
        // score (MeanStdPenalty 0.5) = 1.5 − √0.75 × 0.5 ≈ 1.067
        let pfs = [f64::NAN, 2.0, 2.0, 2.0];
        let method = StabilityScoreMethod::MeanStdPenalty { penalty: 0.5 };
        let score = compute_aggregated_score(&pfs, &method);
        let expected = 1.5 - (0.75_f64).sqrt() * 0.5;
        assert!(
            (score - expected).abs() < 1e-9,
            "score={}, expected={}",
            score,
            expected,
        );
    }

    #[test]
    fn compute_aggregated_score_sanitizes_inf_inputs_for_median_iqr() {
        // [Inf, 1.0, 2.0, 3.0, 4.0] → sanitized [0, 1, 2, 3, 4]
        // sorted: [0,1,2,3,4] → median=2.0
        // q25 = idx 1.0 → 1.0, q75 = idx 3.0 → 3.0, iqr=2.0
        // score = 2.0 − 2.0 × 0.5 = 1.0
        let pfs = [f64::INFINITY, 1.0, 2.0, 3.0, 4.0];
        let method = StabilityScoreMethod::MedianIqr { iqr_penalty: 0.5 };
        let score = compute_aggregated_score(&pfs, &method);
        assert!((score - 1.0).abs() < 1e-9, "score={}", score);
    }

    #[test]
    fn compute_aggregated_score_on_empty_returns_neg_infinity() {
        let pfs: [f64; 0] = [];
        let method = StabilityScoreMethod::MeanStdPenalty { penalty: 0.5 };
        let score = compute_aggregated_score(&pfs, &method);
        assert!(score.is_infinite() && score < 0.0);
    }

    #[test]
    fn stability_method_serde_roundtrips_each_variant() {
        for m in [
            StabilityScoreMethod::MeanStdPenalty { penalty: 0.5 },
            StabilityScoreMethod::MedianIqr { iqr_penalty: 0.25 },
            StabilityScoreMethod::TrimmedMean { trim_pct: 0.2 },
        ] {
            let json = serde_json::to_string(&m).unwrap();
            let back: StabilityScoreMethod = serde_json::from_str(&json).unwrap();
            assert_eq!(back, m, "roundtrip failed for {:?}", m);
        }
    }

    #[test]
    fn walk_forward_config_default_method_falls_back_to_mean_std_penalty() {
        let cfg = WalkForwardConfig {
            train_bars: 100,
            validate_bars: 50,
            step_bars: 50,
            stability_penalty: 0.42,
            stability_method: None,
        };
        match cfg.stability_method() {
            StabilityScoreMethod::MeanStdPenalty { penalty } => {
                assert!(
                    (penalty - 0.42).abs() < 1e-12,
                    "penalty must echo stability_penalty when method is None, got {}",
                    penalty,
                );
            }
            other => panic!("expected MeanStdPenalty fallback, got {:?}", other),
        }
    }

    #[test]
    fn walk_forward_config_uses_explicit_method_when_set() {
        let cfg = WalkForwardConfig {
            train_bars: 100,
            validate_bars: 50,
            step_bars: 50,
            stability_penalty: 0.5,
            stability_method: Some(StabilityScoreMethod::MedianIqr { iqr_penalty: 0.3 }),
        };
        match cfg.stability_method() {
            StabilityScoreMethod::MedianIqr { iqr_penalty } => {
                assert!((iqr_penalty - 0.3).abs() < 1e-12);
            }
            other => panic!("expected MedianIqr, got {:?}", other),
        }
    }

    #[test]
    fn walk_forward_config_deserialises_pre_w3_json_without_method_key() {
        // Pre-W3 config_json blobs persisted by Welle W2 omit
        // `stability_method` entirely; the field must default to None
        // so survivor scoring stays reproducible on existing DBs.
        let legacy_json = r#"{
            "train_bars": 4392,
            "validate_bars": 1464,
            "step_bars": 1464,
            "stability_penalty": 0.5
        }"#;
        let parsed: WalkForwardConfig = serde_json::from_str(legacy_json).unwrap();
        assert_eq!(parsed.stability_method, None);
        assert!(matches!(
            parsed.stability_method(),
            StabilityScoreMethod::MeanStdPenalty { penalty } if (penalty - 0.5).abs() < 1e-12,
        ));
    }

    #[test]
    fn walk_forward_config_roundtrips_when_method_is_set() {
        let cfg = WalkForwardConfig {
            train_bars: 4392,
            validate_bars: 2196,
            step_bars: 2196,
            stability_penalty: 0.5,
            stability_method: Some(StabilityScoreMethod::TrimmedMean { trim_pct: 0.2 }),
        };
        let json = serde_json::to_string(&cfg).unwrap();
        let back: WalkForwardConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back, cfg);
    }

    #[test]
    fn aggregate_walk_forward_legacy_wrapper_matches_method_path_for_mean_std() {
        // The Welle-W1/W2 callsites pass `stability_penalty: f64` and
        // expect bit-identical aggregated scores. The shim must produce
        // the same number as the new method-based path.
        let splits = vec![
            split(0, 1.5, 2.0),
            split(1, 1.5, 1.0),
            split(2, 1.5, 1.5),
        ];
        let legacy = aggregate_walk_forward(0, TrialParams::new(), splits.clone(), 0.5);
        let via_method = aggregate_walk_forward_with_method(
            0,
            TrialParams::new(),
            splits,
            &StabilityScoreMethod::MeanStdPenalty { penalty: 0.5 },
        );
        assert_eq!(legacy.aggregated_score, via_method.aggregated_score);
        assert_eq!(legacy.mean_oos_pf, via_method.mean_oos_pf);
        assert_eq!(legacy.std_oos_pf, via_method.std_oos_pf);
        assert_eq!(legacy.worst_oos_pf, via_method.worst_oos_pf);
        assert_eq!(legacy.mean_is_pf, via_method.mean_is_pf);
        assert_eq!(legacy.is_oos_decay, via_method.is_oos_decay);
    }

    #[test]
    fn aggregate_walk_forward_with_method_routes_to_median_iqr() {
        // OOS PFs: [1,2,3,4,5] → median=3, iqr=2 → 3 − 2×0.5 = 2.0
        let splits = vec![
            split(0, 1.5, 1.0),
            split(1, 1.5, 2.0),
            split(2, 1.5, 3.0),
            split(3, 1.5, 4.0),
            split(4, 1.5, 5.0),
        ];
        let res = aggregate_walk_forward_with_method(
            0,
            TrialParams::new(),
            splits,
            &StabilityScoreMethod::MedianIqr { iqr_penalty: 0.5 },
        );
        assert!(
            (res.aggregated_score - 2.0).abs() < 1e-9,
            "aggregated={}, expected 2.0 under MedianIqr",
            res.aggregated_score,
        );
        // Sanity: the mean / std fields stay populated from the raw OOS
        // data, independent of the scoring method.
        assert!((res.mean_oos_pf - 3.0).abs() < 1e-12);
    }

    #[test]
    fn aggregate_walk_forward_with_method_preserves_neg_inf_sentinel_for_all_nan_oos() {
        // Disqualification sentinel: every OOS PF non-finite ⇒ score
        // must be NEG_INFINITY regardless of the chosen method. Method
        // gets sanitised inputs (zeros) and would otherwise return 0.0.
        let splits = vec![
            split(0, 1.5, f64::NAN),
            split(1, 1.5, f64::INFINITY),
            split(2, 1.5, f64::NEG_INFINITY),
        ];
        for method in [
            StabilityScoreMethod::MeanStdPenalty { penalty: 0.5 },
            StabilityScoreMethod::MedianIqr { iqr_penalty: 0.5 },
            StabilityScoreMethod::TrimmedMean { trim_pct: 0.2 },
        ] {
            let res = aggregate_walk_forward_with_method(
                0,
                TrialParams::new(),
                splits.clone(),
                &method,
            );
            assert!(
                res.aggregated_score.is_infinite() && res.aggregated_score < 0.0,
                "method {:?} must keep NEG_INFINITY sentinel, got {}",
                method,
                res.aggregated_score,
            );
        }
    }

    // ─── Survivor Criteria (pure, no backtests) ──────────────────────────────

    fn passing_result() -> WalkForwardResult {
        // Hits the Welle-W2 defaults with a small safety margin:
        // mean_oos=1.5 (>1.3), std_oos=0.5 (<1.0), decay=0.2 (<0.7),
        // worst_oos=0.9 (>0.6).
        WalkForwardResult {
            trial_id: 1,
            params: TrialParams::new(),
            splits: vec![],
            aggregated_score: 1.25,
            mean_oos_pf: 1.5,
            std_oos_pf: 0.5,
            worst_oos_pf: 0.9,
            mean_is_pf: 1.7,
            is_oos_decay: 0.2,
        }
    }

    #[test]
    fn survives_when_mean_oos_pf_meets_minimum_threshold() {
        let mut r = passing_result();
        r.mean_oos_pf = 1.3; // exactly at the gate
        assert!(survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn fails_when_mean_oos_pf_below_minimum_threshold() {
        let mut r = passing_result();
        r.mean_oos_pf = 1.29; // one bp under the gate
        assert!(!survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn survives_when_std_oos_pf_meets_maximum_threshold() {
        let mut r = passing_result();
        r.std_oos_pf = 1.0; // exactly at the cap
        assert!(survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn fails_when_std_oos_pf_above_maximum_threshold() {
        let mut r = passing_result();
        r.std_oos_pf = 1.01;
        assert!(!survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn survives_when_is_oos_decay_meets_maximum_threshold() {
        let mut r = passing_result();
        r.is_oos_decay = 0.7; // exactly at the cap
        assert!(survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn fails_when_is_oos_decay_above_maximum_threshold() {
        let mut r = passing_result();
        r.is_oos_decay = 0.71;
        assert!(!survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn survives_when_worst_oos_pf_meets_minimum_threshold() {
        let mut r = passing_result();
        r.worst_oos_pf = 0.6; // exactly at the gate
        assert!(survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn fails_when_worst_oos_pf_below_minimum_threshold() {
        let mut r = passing_result();
        r.worst_oos_pf = 0.59;
        assert!(!survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn survives_composite_when_all_four_criteria_satisfied() {
        let r = passing_result();
        assert!(survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn fails_composite_when_any_single_criterion_breaks_others_passing() {
        // Confirm the gate is AND-conjunctive — flipping any one of the
        // four off rejects the whole.
        let mut r = passing_result();
        r.std_oos_pf = 2.0;
        assert!(!survives(&r, &SurvivorCriteria::default()));
    }

    #[test]
    fn default_criteria_match_documented_welle_w2_thresholds() {
        let c = SurvivorCriteria::default();
        assert_eq!(c.min_mean_oos_pf, 1.3);
        assert_eq!(c.max_std_oos_pf, 1.0);
        assert_eq!(c.max_is_oos_decay, 0.7);
        assert_eq!(c.min_worst_oos_pf, 0.6);
    }

    #[test]
    fn survivor_criteria_are_serde_round_trippable() {
        // Persistence path: the CLI writes SurvivorCriteria into
        // config_json side-by-side with WalkForwardConfig (audit trail).
        let c = SurvivorCriteria {
            min_mean_oos_pf: 1.42,
            max_std_oos_pf: 0.75,
            max_is_oos_decay: 0.5,
            min_worst_oos_pf: 0.85,
        };
        let json = serde_json::to_string(&c).unwrap();
        let parsed: SurvivorCriteria = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, c);
    }

    // ─── Runner integration tests (with real backtests on synthetic data) ────

    fn synthetic_candles(n: usize) -> Vec<Candle> {
        let mut candles = Vec::with_capacity(n);
        let start_ts: i64 = 1_700_000_000_000;
        let step_ms: i64 = 60 * 60 * 1_000;
        for i in 0..n {
            let t = i as f64;
            let drift = 60_000.0 + t * 5.0;
            let osc = 800.0 * (t * 0.21).sin();
            let micro = 120.0 * (t * 1.7).cos();
            let close = drift + osc + micro;
            let open = drift + osc + 60.0 * ((t - 1.0) * 1.7).cos();
            let high = close.max(open) + 80.0;
            let low = close.min(open) - 80.0;
            let volume = 100.0 + 20.0 * (t * 0.13).sin().abs();
            candles.push(Candle::new(
                start_ts + (i as i64) * step_ms,
                open,
                high,
                low,
                close,
                volume,
            ));
        }
        candles
    }

    fn h1_base_config() -> BacktestConfig {
        BacktestConfig {
            initial_balance: 10_000.0,
            fee_rate: 0.0006,
            timeframe: Timeframe::H1,
            slippage_bps: 0.0,
        }
    }

    fn permissive_constraints() -> ScoreConstraints {
        ScoreConstraints {
            max_drawdown_cap_pct: 100.0,
            min_trades: 0,
        }
    }

    fn ichimoku_default_params() -> TrialParams {
        let mut p = TrialParams::new();
        p.insert("tenkan_period", 9.0);
        p.insert("kijun_period", 26.0);
        p.insert("senkou_b_period", 52.0);
        p.insert("shift", 26.0);
        p.insert("score_threshold", 60.0);
        p.insert("adx_filter_enabled", 0.0);
        p
    }

    #[test]
    fn run_walk_forward_trial_returns_err_when_candles_below_train_plus_validate() {
        let candles = synthetic_candles(240);
        let config = cfg(200, 50, 50);
        let result = run_walk_forward_trial(
            StrategyKind::Ichimoku,
            0,
            ichimoku_default_params(),
            &candles,
            &config,
            h1_base_config(),
            &permissive_constraints(),
        );
        assert!(result.is_err(), "240 candles must Err under train=200+validate=50");
    }

    #[test]
    fn run_walk_forward_trial_smoke_on_synthetic_data_produces_well_formed_result() {
        let candles = synthetic_candles(500);
        // train=200, validate=50, step=50 → ⌊(500-250)/50⌋+1 = 6 splits
        let config = cfg(200, 50, 50);
        let result = run_walk_forward_trial(
            StrategyKind::Ichimoku,
            515,
            ichimoku_default_params(),
            &candles,
            &config,
            h1_base_config(),
            &permissive_constraints(),
        )
        .expect("smoke run must succeed");
        assert_eq!(result.trial_id, 515);
        assert_eq!(result.splits.len(), 6);
        for s in &result.splits {
            // Validate metrics are populated (engine emits TrialMetrics
            // for every run, even zero-trade ones).
            assert!(s.validate_metrics.final_equity > 0.0);
        }
    }

    #[test]
    fn run_walk_forward_trial_is_reproducible_for_identical_inputs() {
        let candles = synthetic_candles(500);
        let config = cfg(200, 50, 50);
        let a = run_walk_forward_trial(
            StrategyKind::Ichimoku,
            42,
            ichimoku_default_params(),
            &candles,
            &config,
            h1_base_config(),
            &permissive_constraints(),
        )
        .unwrap();
        let b = run_walk_forward_trial(
            StrategyKind::Ichimoku,
            42,
            ichimoku_default_params(),
            &candles,
            &config,
            h1_base_config(),
            &permissive_constraints(),
        )
        .unwrap();
        // Compare every aggregated stat — split-level metrics may carry
        // NaN (PartialEq false), so use stat-level f64 equality.
        assert_eq!(a.trial_id, b.trial_id);
        assert_eq!(a.params, b.params);
        assert_eq!(a.splits.len(), b.splits.len());
        // Split-by-split: train+validate metric fields must match bit-
        // for-bit on the finite components.
        for (sa, sb) in a.splits.iter().zip(b.splits.iter()) {
            assert_eq!(sa.split_index, sb.split_index);
            assert_eq!(sa.train_metrics.total_trades, sb.train_metrics.total_trades);
            assert_eq!(sa.validate_metrics.total_trades, sb.validate_metrics.total_trades);
            assert_eq!(sa.train_metrics.final_equity, sb.train_metrics.final_equity);
            assert_eq!(sa.validate_metrics.final_equity, sb.validate_metrics.final_equity);
        }
        // Aggregated fields are sanitized → no NaN risk in equality.
        assert_eq!(a.mean_oos_pf, b.mean_oos_pf);
        assert_eq!(a.std_oos_pf, b.std_oos_pf);
        assert_eq!(a.worst_oos_pf, b.worst_oos_pf);
        assert_eq!(a.mean_is_pf, b.mean_is_pf);
        assert_eq!(a.is_oos_decay, b.is_oos_decay);
        assert_eq!(a.aggregated_score, b.aggregated_score);
    }
}
