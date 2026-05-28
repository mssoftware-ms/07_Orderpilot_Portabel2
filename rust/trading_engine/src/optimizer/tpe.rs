//! Tree-structured Parzen Estimator (TPE) engine — Phase-3.1 Welle W3-5.
//!
//! TPE is the Bayesian-optimization variant Optuna uses by default. We
//! implement it in Rust to keep the Phase-1/2/3 stack monolingual; the
//! algorithm is small and the call surface mirrors `RandomSearchEngine`
//! so existing CLI / persistence code drops in unchanged.
//!
//! # The algorithm in one paragraph
//! After enough observations have been collected:
//! 1. Sort the qualified history by score (descending — we maximize).
//! 2. Split at the `gamma`-quantile: top γ% form the "good" set `l(x)`;
//!    the rest are the "bad" set `g(x)`.
//! 3. For each parameter, build a Parzen-window KDE over `l` and over
//!    `g`. Continuous parameters use a Gaussian kernel with Silverman-
//!    rule bandwidth; categorical / boolean parameters use Laplace-
//!    smoothed empirical frequencies (KDE in zero-dimensional space).
//! 4. Sample `n_ei_candidates` candidates from `l(x)` and pick the one
//!    that maximizes `log(l(x) / g(x))` — the Expected-Improvement
//!    proxy that drives TPE's exploit/explore trade-off.
//!
//! # Warm-start from walk-forward survivors
//! The Welle W3 plan calls for seeding TPE with the W3a-relaxed survivor
//! pool so the first suggestion already sits inside the validated
//! region. `warm_start(history)` accepts any `Vec<TrialResult>` — the
//! caller converts `WalkForwardResult` to `TrialResult` (using
//! `aggregated_score` as `score`) before passing it in.
//!
//! # Early-trial fallback
//! TPE's KDE is degenerate with fewer than ~8 qualified observations:
//! Silverman's bandwidth collapses, and the l / g split has too few
//! samples per side for meaningful density ratios. Until the history
//! reaches `MIN_HISTORY_FOR_TPE`, the engine falls back to pure
//! random sampling (same draws as `RandomSearchEngine` at the same
//! seed).

use std::f64::consts::PI;

use anyhow::Result;
use rand::distributions::{Distribution, Uniform};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};

use crate::backtest::BacktestConfig;
use crate::models::Candle;

use super::runner::run_optimization_trial;
use super::scoring::StrategyKind;
use super::{ParameterSpec, ScoreConstraints, SearchSpace, StudyStorage, TrialParams, TrialResult};

// ─── Constants ──────────────────────────────────────────────────────────────

/// Top-quantile fraction used to split the history into l (good) and g
/// (bad). 0.25 follows the Optuna default — the upper quarter of
/// observed trials seeds the next exploitation candidates.
pub const DEFAULT_GAMMA: f64 = 0.25;
/// Number of EI candidates sampled from l(x) per parameter before
/// picking the one with the highest `log(l/g)` ratio. 24 is the Optuna
/// default — a sweet spot between TPE compute cost and exploration.
pub const DEFAULT_N_EI_CANDIDATES: usize = 24;
/// Minimum qualified-history size before TPE takes over from pure
/// random. Below this, Silverman's bandwidth becomes meaningless and
/// the l / g split has too few points per side.
pub const MIN_HISTORY_FOR_TPE: usize = 8;
/// Floor on Silverman bandwidth as a fraction of the parameter range —
/// protects the Gaussian KDE from collapsing to a delta when all `l`
/// samples sit at the same value (e.g. categorical-like coordinates).
const BANDWIDTH_FLOOR_FRACTION: f64 = 0.05;
/// Laplace-smoothing pseudo-count added to every categorical / boolean
/// bin before computing the l/g ratio — keeps the ratio finite when a
/// category is absent from either side.
const CATEGORICAL_SMOOTHING: f64 = 1.0;

// ─── Engine ─────────────────────────────────────────────────────────────────

/// Seedable TPE engine. Mirrors `RandomSearchEngine` in API surface so
/// the persistence / CLI layer treats both interchangeably.
pub struct TpeEngine {
    rng: StdRng,
    history: Vec<TrialResult>,
    gamma: f64,
    n_ei_candidates: usize,
}

impl TpeEngine {
    /// Build an engine seeded by `seed`. Two engines with the same
    /// `seed`, the same warm-start history, and the same report
    /// sequence emit identical suggestions (asserted in tests).
    pub fn new(seed: u64) -> Self {
        Self {
            rng: StdRng::seed_from_u64(seed),
            history: Vec::new(),
            gamma: DEFAULT_GAMMA,
            n_ei_candidates: DEFAULT_N_EI_CANDIDATES,
        }
    }

    /// Override the default `gamma` (0.25). Must be in `(0.0, 1.0)`.
    pub fn with_gamma(mut self, gamma: f64) -> Self {
        assert!(
            gamma > 0.0 && gamma < 1.0,
            "gamma must be in (0.0, 1.0), got {}",
            gamma
        );
        self.gamma = gamma;
        self
    }

    /// Override the default candidate-pool size (24). Must be `> 0`.
    pub fn with_n_ei_candidates(mut self, n: usize) -> Self {
        assert!(n > 0, "n_ei_candidates must be > 0, got {}", n);
        self.n_ei_candidates = n;
        self
    }

    /// Read-only access to the engine's recorded history (useful for
    /// tests and audit reporting).
    pub fn history(&self) -> &[TrialResult] {
        &self.history
    }

    /// Seed the history before the first `suggest`. Typical use:
    /// convert `WalkForwardResult`s from the W3a survivor pool to
    /// `TrialResult`s (`score = aggregated_score`) and pass them in
    /// so TPE's first suggestion is already near a validated cluster.
    /// Overwrites any prior history.
    pub fn warm_start(&mut self, history: Vec<TrialResult>) {
        self.history = history;
    }

    /// Append one observation to the history. Calls should pair with
    /// `suggest`: TPE uses the running history to bias each next
    /// suggestion.
    pub fn report(&mut self, result: TrialResult) {
        self.history.push(result);
    }

    /// Suggest one `TrialParams` from `space`. When the qualified
    /// history is smaller than `MIN_HISTORY_FOR_TPE`, falls back to
    /// pure-random sampling (identical to `RandomSearchEngine::sample`
    /// at the same seed state).
    pub fn suggest(&mut self, space: &SearchSpace) -> TrialParams {
        let qualified: Vec<TrialResult> = self
            .history
            .iter()
            .filter(|t| t.score.is_finite())
            .cloned()
            .collect();

        if qualified.len() < MIN_HISTORY_FOR_TPE {
            return self.random_sample(space);
        }

        let (l_set, g_set) = split_history(&qualified, self.gamma);
        if l_set.is_empty() || g_set.is_empty() {
            return self.random_sample(space);
        }

        let mut params = TrialParams::new();
        for (name, spec) in &space.parameters {
            let l_vals: Vec<f64> = l_set
                .iter()
                .filter_map(|t| t.params.values.get(name).copied())
                .collect();
            let g_vals: Vec<f64> = g_set
                .iter()
                .filter_map(|t| t.params.values.get(name).copied())
                .collect();
            let suggested =
                suggest_param(&mut self.rng, spec, &l_vals, &g_vals, self.n_ei_candidates);
            params.insert(name.clone(), suggested);
        }
        for (name, &value) in &space.fixed {
            params.insert(name.clone(), value);
        }
        params
    }

    /// Run a full TPE-driven study: optionally warm-start, then
    /// `n_trials` iterations of `suggest → score → report → persist`.
    /// Returns the persisted Top-5.
    #[allow(clippy::too_many_arguments)]
    pub fn run_study(
        &mut self,
        name: &str,
        space: &SearchSpace,
        strategy: StrategyKind,
        candles: &[Candle],
        base_config: BacktestConfig,
        constraints: &ScoreConstraints,
        n_trials: u32,
        storage: &mut StudyStorage,
    ) -> Result<Vec<TrialResult>> {
        let yaml = serde_yaml::to_string(space)?;
        let study_id = storage.create_study(name, strategy.as_str(), &yaml)?;

        for i in 0..n_trials {
            let params = self.suggest(space);
            let result = run_optimization_trial(
                strategy,
                i,
                params,
                candles,
                base_config.clone(),
                constraints,
            );
            storage.insert_trial(study_id, &result)?;
            self.report(result.clone());
            if (i + 1) % 100 == 0 {
                log::info!(
                    target: "optimizer",
                    "[{}] trial {}/{} score={}",
                    name,
                    i + 1,
                    n_trials,
                    result.score,
                );
            }
        }

        storage.top_n_trials(study_id, 5)
    }

    fn random_sample(&mut self, space: &SearchSpace) -> TrialParams {
        let mut params = TrialParams::new();
        for (name, spec) in &space.parameters {
            params.insert(name.clone(), random_sample_one(&mut self.rng, spec));
        }
        for (name, &value) in &space.fixed {
            params.insert(name.clone(), value);
        }
        params
    }
}

// ─── History split ──────────────────────────────────────────────────────────

/// Sort `qualified` by score DESC and partition into top γ% (l, "good")
/// and the remainder (g, "bad"). `n_l = max(1, ceil(n · gamma))`
/// guarantees both sides are non-empty whenever `qualified.len() ≥ 2`.
pub fn split_history(
    qualified: &[TrialResult],
    gamma: f64,
) -> (Vec<TrialResult>, Vec<TrialResult>) {
    let mut sorted: Vec<TrialResult> = qualified.to_vec();
    sorted.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .expect("qualified history scores are finite by caller contract")
    });
    let n = sorted.len();
    let raw = (n as f64 * gamma).ceil() as usize;
    let n_l = raw.max(1).min(n.saturating_sub(1).max(1));
    let g_part = sorted.split_off(n_l);
    (sorted, g_part)
}

// ─── Per-parameter suggestion ───────────────────────────────────────────────

fn suggest_param(
    rng: &mut StdRng,
    spec: &ParameterSpec,
    l_vals: &[f64],
    g_vals: &[f64],
    n_ei: usize,
) -> f64 {
    if l_vals.is_empty() {
        return random_sample_one(rng, spec);
    }
    match spec {
        ParameterSpec::Float { min, max, log } => {
            suggest_float(rng, *min, *max, *log, l_vals, g_vals, n_ei)
        }
        ParameterSpec::Int { min, max } => suggest_int(rng, *min, *max, l_vals, g_vals, n_ei),
        ParameterSpec::Bool => suggest_bool(rng, l_vals, g_vals),
        ParameterSpec::Categorical { values } => {
            suggest_categorical(rng, values.len(), l_vals, g_vals)
        }
    }
}

fn suggest_float(
    rng: &mut StdRng,
    min: f64,
    max: f64,
    log: bool,
    l_vals: &[f64],
    g_vals: &[f64],
    n_ei: usize,
) -> f64 {
    let (l_t, g_t, lo, hi): (Vec<f64>, Vec<f64>, f64, f64) = if log {
        let lt: Vec<f64> = l_vals.iter().map(|x| x.log10()).collect();
        let gt: Vec<f64> = g_vals.iter().map(|x| x.log10()).collect();
        (lt, gt, min.log10(), max.log10())
    } else {
        (l_vals.to_vec(), g_vals.to_vec(), min, max)
    };

    let range = hi - lo;
    let bw_l = silverman_bandwidth(&l_t).max(range * BANDWIDTH_FLOOR_FRACTION);
    let bw_g = silverman_bandwidth(&g_t).max(range * BANDWIDTH_FLOOR_FRACTION);

    let best_t = pick_best_candidate(rng, &l_t, bw_l, &g_t, bw_g, lo, hi, n_ei);
    if log {
        10f64.powf(best_t)
    } else {
        best_t
    }
}

fn suggest_int(
    rng: &mut StdRng,
    min: i64,
    max: i64,
    l_vals: &[f64],
    g_vals: &[f64],
    n_ei: usize,
) -> f64 {
    let lo = min as f64;
    let hi = max as f64;
    let range = hi - lo;
    // Floor bandwidth at 1.0 — sub-unit bandwidths on a discrete grid
    // collapse the KDE to delta-spikes around observed values.
    let bw_l = silverman_bandwidth(l_vals).max((range * BANDWIDTH_FLOOR_FRACTION).max(1.0));
    let bw_g = silverman_bandwidth(g_vals).max((range * BANDWIDTH_FLOOR_FRACTION).max(1.0));
    let best = pick_best_candidate(rng, l_vals, bw_l, g_vals, bw_g, lo, hi, n_ei);
    best.round().clamp(lo, hi)
}

fn suggest_bool(rng: &mut StdRng, l_vals: &[f64], g_vals: &[f64]) -> f64 {
    let bins = empirical_bins(l_vals, g_vals, 2);
    pick_best_bin(rng, &bins) as f64
}

fn suggest_categorical(
    rng: &mut StdRng,
    n_categories: usize,
    l_vals: &[f64],
    g_vals: &[f64],
) -> f64 {
    let bins = empirical_bins(l_vals, g_vals, n_categories);
    pick_best_bin(rng, &bins) as f64
}

/// For each of `n_categories` integer bins, the smoothed probability
/// under l and under g. Caller picks the bin maximizing `l / g`.
fn empirical_bins(l_vals: &[f64], g_vals: &[f64], n_categories: usize) -> Vec<(f64, f64)> {
    let mut l_count = vec![CATEGORICAL_SMOOTHING; n_categories];
    let mut g_count = vec![CATEGORICAL_SMOOTHING; n_categories];
    for &v in l_vals {
        let i = (v.round() as i64).clamp(0, n_categories as i64 - 1) as usize;
        l_count[i] += 1.0;
    }
    for &v in g_vals {
        let i = (v.round() as i64).clamp(0, n_categories as i64 - 1) as usize;
        g_count[i] += 1.0;
    }
    let l_sum: f64 = l_count.iter().sum();
    let g_sum: f64 = g_count.iter().sum();
    (0..n_categories)
        .map(|i| (l_count[i] / l_sum, g_count[i] / g_sum))
        .collect()
}

/// Pick the bin whose `l(x) / g(x)` is largest. Tie-broken by lowest
/// index (deterministic given the bin order). `rng` is unused today
/// but the signature leaves room for an EI-candidate-style randomised
/// tie-break if categorical exploration turns out to be too aggressive.
fn pick_best_bin(_rng: &mut StdRng, bins: &[(f64, f64)]) -> usize {
    bins.iter()
        .enumerate()
        .max_by(|a, b| {
            let ra = a.1 .0 / a.1 .1;
            let rb = b.1 .0 / b.1 .1;
            ra.partial_cmp(&rb).unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|(i, _)| i)
        .unwrap_or(0)
}

/// Draw `n_ei` Gaussian perturbations centred on random `l_t` samples,
/// clamp to `[lo, hi]`, return the one with the highest `log(l/g)`.
#[allow(clippy::too_many_arguments)] // internal helper; collapsing into a config
                                     // struct just shifts the parameters one
                                     // level up without improving readability.
fn pick_best_candidate(
    rng: &mut StdRng,
    l_t: &[f64],
    bw_l: f64,
    g_t: &[f64],
    bw_g: f64,
    lo: f64,
    hi: f64,
    n_ei: usize,
) -> f64 {
    let candidates: Vec<f64> = (0..n_ei.max(1))
        .map(|_| {
            let idx = rng.gen_range(0..l_t.len());
            let z = box_muller_standard_normal(rng);
            (l_t[idx] + bw_l * z).clamp(lo, hi)
        })
        .collect();

    candidates
        .iter()
        .copied()
        .max_by(|&a, &b| {
            let ra = log_kde_ratio(a, l_t, bw_l, g_t, bw_g);
            let rb = log_kde_ratio(b, l_t, bw_l, g_t, bw_g);
            ra.partial_cmp(&rb).unwrap_or(std::cmp::Ordering::Equal)
        })
        .expect("candidates non-empty by n_ei.max(1)")
}

// ─── Gaussian KDE math ──────────────────────────────────────────────────────

fn log_kde_ratio(x: f64, l: &[f64], bw_l: f64, g: &[f64], bw_g: f64) -> f64 {
    gaussian_kde_log_pdf(x, l, bw_l) - gaussian_kde_log_pdf(x, g, bw_g)
}

/// `log p(x)` under a Parzen-Gaussian KDE with bandwidth `bw`.
/// Empty `samples` yields `-inf`; degenerate `bw == 0` is the caller's
/// responsibility to avoid (floor at `BANDWIDTH_FLOOR_FRACTION · range`).
pub fn gaussian_kde_log_pdf(x: f64, samples: &[f64], bw: f64) -> f64 {
    if samples.is_empty() || bw <= 0.0 {
        return f64::NEG_INFINITY;
    }
    let log_constant = -0.5 * (2.0 * PI).ln() - bw.ln();
    let log_components: Vec<f64> = samples
        .iter()
        .map(|&xi| {
            let z = (x - xi) / bw;
            log_constant - 0.5 * z * z
        })
        .collect();
    // log-sum-exp for numerical stability
    let max = log_components
        .iter()
        .copied()
        .fold(f64::NEG_INFINITY, f64::max);
    if !max.is_finite() {
        return f64::NEG_INFINITY;
    }
    let sum_exp: f64 = log_components.iter().map(|&lc| (lc - max).exp()).sum();
    max + sum_exp.ln() - (samples.len() as f64).ln()
}

/// Silverman's rule-of-thumb bandwidth: `h = 1.06 σ n^(-1/5)`. Returns
/// `0.0` for `n < 2` so callers can floor-out the degenerate case.
pub fn silverman_bandwidth(samples: &[f64]) -> f64 {
    let n = samples.len();
    if n < 2 {
        return 0.0;
    }
    let nf = n as f64;
    let mean = samples.iter().sum::<f64>() / nf;
    let variance = samples.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / nf;
    1.06 * variance.sqrt() * nf.powf(-0.2)
}

/// One draw from a standard normal via Box-Muller (no `rand_distr`
/// dep needed). Discards the second leg of each pair — slightly less
/// efficient than caching it but keeps the call site stateless.
fn box_muller_standard_normal(rng: &mut StdRng) -> f64 {
    // Uniform in (0, 1] to keep ln(u1) finite.
    let u1: f64 = 1.0 - rng.gen::<f64>();
    let u2: f64 = rng.gen();
    (-2.0 * u1.ln()).sqrt() * (2.0 * PI * u2).cos()
}

// ─── Random-fallback sampling ───────────────────────────────────────────────
// (Duplicates RandomSearchEngine::sample_one so TpeEngine does not need a
// dependency on the random_search module — keeping the two engines
// independent simplifies future extraction.)

fn random_sample_one(rng: &mut StdRng, spec: &ParameterSpec) -> f64 {
    match spec {
        ParameterSpec::Float { min, max, log } => {
            if *log {
                let lo = min.log10();
                let hi = max.log10();
                10f64.powf(Uniform::new_inclusive(lo, hi).sample(rng))
            } else {
                Uniform::new_inclusive(*min, *max).sample(rng)
            }
        }
        ParameterSpec::Int { min, max } => Uniform::new_inclusive(*min, *max).sample(rng) as f64,
        ParameterSpec::Bool => {
            if rng.gen_bool(0.5) {
                1.0
            } else {
                0.0
            }
        }
        ParameterSpec::Categorical { values } => rng.gen_range(0..values.len()) as f64,
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::optimizer::{TrialMetrics, TrialParams};
    use std::collections::BTreeMap;

    // ─── Test fixtures ──────────────────────────────────────────────────────

    fn trial_with_score(id: u32, x: f64, y: f64, score: f64) -> TrialResult {
        let mut params = TrialParams::new();
        params.insert("x", x);
        params.insert("y", y);
        TrialResult {
            trial_id: id,
            params,
            metrics: TrialMetrics {
                total_trades: 50,
                total_pnl: 100.0,
                win_rate: 55.0,
                sharpe_ratio: 1.0,
                max_drawdown_pct: 5.0,
                profit_factor: 1.8,
                final_equity: 10_100.0,
            },
            score,
        }
    }

    fn xy_space() -> SearchSpace {
        let mut params: BTreeMap<String, ParameterSpec> = BTreeMap::new();
        params.insert(
            "x".into(),
            ParameterSpec::Float {
                min: 0.0,
                max: 10.0,
                log: false,
            },
        );
        params.insert(
            "y".into(),
            ParameterSpec::Float {
                min: 0.0,
                max: 10.0,
                log: false,
            },
        );
        SearchSpace {
            strategy_name: "synthetic".into(),
            parameters: params,
            fixed: BTreeMap::new(),
        }
    }

    /// Toy 2-D objective with maximum at (3, 7): `score = -((x-3)² + (y-7)²)`.
    fn toy_score(params: &TrialParams) -> f64 {
        let x = params.get_or("x", f64::NAN);
        let y = params.get_or("y", f64::NAN);
        -((x - 3.0).powi(2) + (y - 7.0).powi(2))
    }

    // ─── KDE math ───────────────────────────────────────────────────────────

    #[test]
    fn silverman_bandwidth_on_unit_normal_sample_is_positive_and_decreases_with_n() {
        let small: Vec<f64> = (0..10).map(|i| (i as f64).sin()).collect();
        let large: Vec<f64> = (0..1000).map(|i| ((i as f64) * 0.013).sin()).collect();
        let h_small = silverman_bandwidth(&small);
        let h_large = silverman_bandwidth(&large);
        assert!(h_small > 0.0);
        assert!(h_large > 0.0);
        assert!(
            h_large < h_small,
            "n=1000 bandwidth ({}) should be smaller than n=10 ({})",
            h_large,
            h_small,
        );
    }

    #[test]
    fn silverman_bandwidth_on_lt_two_samples_returns_zero() {
        assert_eq!(silverman_bandwidth(&[]), 0.0);
        assert_eq!(silverman_bandwidth(&[2.5]), 0.0);
    }

    #[test]
    fn gaussian_kde_log_pdf_peaks_near_sample_centres() {
        // KDE built on samples around 0.0 should have higher density at
        // 0.0 than at 5.0.
        let samples = [-0.5, 0.0, 0.5, -0.1, 0.1];
        let bw = 0.5;
        let lp_center = gaussian_kde_log_pdf(0.0, &samples, bw);
        let lp_far = gaussian_kde_log_pdf(5.0, &samples, bw);
        assert!(
            lp_center > lp_far,
            "KDE log-pdf at centre ({}) must exceed far point ({})",
            lp_center,
            lp_far,
        );
    }

    #[test]
    fn gaussian_kde_log_pdf_on_empty_samples_or_zero_bw_returns_neg_inf() {
        assert!(gaussian_kde_log_pdf(0.0, &[], 1.0).is_infinite());
        assert!(gaussian_kde_log_pdf(0.0, &[1.0], 0.0).is_infinite());
    }

    // ─── History split ──────────────────────────────────────────────────────

    #[test]
    fn split_history_at_gamma_quartile_keeps_top_25_pct_in_l() {
        let history: Vec<TrialResult> = (0..20)
            .map(|i| trial_with_score(i, 0.5, 0.5, i as f64))
            .collect();
        let (l, g) = split_history(&history, 0.25);
        // ceil(20 * 0.25) = 5
        assert_eq!(l.len(), 5);
        assert_eq!(g.len(), 15);
        // Top scores end up in l (sorted desc)
        let top_scores: Vec<f64> = l.iter().map(|t| t.score).collect();
        assert_eq!(top_scores, vec![19.0, 18.0, 17.0, 16.0, 15.0]);
    }

    #[test]
    fn split_history_guarantees_non_empty_g_when_history_has_two_plus_entries() {
        let history = vec![
            trial_with_score(0, 1.0, 1.0, 5.0),
            trial_with_score(1, 1.0, 1.0, 1.0),
        ];
        let (l, g) = split_history(&history, 0.99);
        assert!(!l.is_empty());
        assert!(
            !g.is_empty(),
            "g must stay non-empty even when gamma forces n_l to clamp",
        );
        assert_eq!(l.len() + g.len(), 2);
    }

    #[test]
    fn split_history_on_single_entry_lands_it_in_l() {
        let history = vec![trial_with_score(0, 0.5, 0.5, 2.5)];
        let (l, g) = split_history(&history, 0.25);
        assert_eq!(l.len(), 1);
        assert_eq!(g.len(), 0);
    }

    // ─── Engine: random fallback when history is small ──────────────────────

    #[test]
    fn suggest_falls_back_to_random_below_min_history_threshold() {
        let space = xy_space();
        let mut engine = TpeEngine::new(7);
        // No warm-start, no reports — qualified.len() == 0 < MIN_HISTORY_FOR_TPE
        let p = engine.suggest(&space);
        let x = p.get_or("x", f64::NAN);
        let y = p.get_or("y", f64::NAN);
        assert!((0.0..=10.0).contains(&x));
        assert!((0.0..=10.0).contains(&y));
    }

    #[test]
    fn random_fallback_matches_random_search_at_identical_seed_state() {
        // TpeEngine in random-fallback mode produces the same first
        // draw as a RandomSearchEngine at the same seed — invariant
        // pinned for downstream code that swaps the two engines.
        let space = xy_space();
        let mut tpe = TpeEngine::new(11);
        let mut rs = crate::optimizer::RandomSearchEngine::new(11);
        let p_tpe = tpe.suggest(&space);
        let p_rs = rs.sample(&space);
        assert_eq!(p_tpe.get_or("x", -1.0), p_rs.get_or("x", -1.0));
        assert_eq!(p_tpe.get_or("y", -1.0), p_rs.get_or("y", -1.0));
    }

    // ─── Engine: determinism ────────────────────────────────────────────────

    #[test]
    fn same_seed_plus_history_yields_identical_suggestions() {
        let space = xy_space();
        let history: Vec<TrialResult> = (0..20)
            .map(|i| {
                let x = 3.0 + 0.1 * (i as f64).sin();
                let y = 7.0 + 0.1 * (i as f64).cos();
                trial_with_score(i, x, y, -((x - 3.0).powi(2) + (y - 7.0).powi(2)))
            })
            .collect();

        let mut a = TpeEngine::new(42);
        a.warm_start(history.clone());
        let mut b = TpeEngine::new(42);
        b.warm_start(history);

        for _ in 0..10 {
            let pa = a.suggest(&space);
            let pb = b.suggest(&space);
            assert_eq!(pa.get_or("x", -1.0), pb.get_or("x", -1.0));
            assert_eq!(pa.get_or("y", -1.0), pb.get_or("y", -1.0));
        }
    }

    #[test]
    fn different_seeds_diverge_within_a_few_suggestions() {
        let space = xy_space();
        let history: Vec<TrialResult> = (0..20)
            .map(|i| trial_with_score(i, 5.0, 5.0, i as f64))
            .collect();
        let mut a = TpeEngine::new(1);
        a.warm_start(history.clone());
        let mut b = TpeEngine::new(2);
        b.warm_start(history);
        let mut differ = false;
        for _ in 0..10 {
            let pa = a.suggest(&space);
            let pb = b.suggest(&space);
            if pa.get_or("x", -1.0) != pb.get_or("x", -1.0)
                || pa.get_or("y", -1.0) != pb.get_or("y", -1.0)
            {
                differ = true;
                break;
            }
        }
        assert!(
            differ,
            "two distinct seeds must diverge within 10 suggestions"
        );
    }

    // ─── Engine: warm-start biases toward survivor cluster ──────────────────

    #[test]
    fn warm_start_with_clustered_survivors_pulls_suggestions_toward_cluster() {
        // Warm-start with 20 "survivors" all clustered near (3, 7).
        // After warm-start, TPE suggestions should land predominantly
        // near the cluster (closer than random sampling would).
        let space = xy_space();
        let history: Vec<TrialResult> = (0..20)
            .map(|i| {
                let x = 3.0 + 0.3 * ((i as f64) * 0.31).sin();
                let y = 7.0 + 0.3 * ((i as f64) * 0.47).cos();
                trial_with_score(i, x, y, 10.0 - i as f64 * 0.1)
            })
            .collect();

        let mut tpe = TpeEngine::new(123);
        tpe.warm_start(history);

        let mut distances: Vec<f64> = Vec::new();
        for _ in 0..50 {
            let p = tpe.suggest(&space);
            let x = p.get_or("x", f64::NAN);
            let y = p.get_or("y", f64::NAN);
            distances.push(((x - 3.0).powi(2) + (y - 7.0).powi(2)).sqrt());
        }
        let mean_dist: f64 = distances.iter().sum::<f64>() / distances.len() as f64;
        // Random uniform on [0,10]² would average ≈ 4.5 from any
        // fixed centre; survivor-warmed TPE should pull the average
        // well below half of that.
        assert!(
            mean_dist < 2.5,
            "warm-started TPE mean distance from cluster centre = {} (expected < 2.5)",
            mean_dist,
        );
    }

    // ─── Engine: convergence on toy 2D objective ───────────────────────────

    #[test]
    fn online_loop_converges_toward_known_optimum_on_toy_2d_objective() {
        // Drive the engine through 80 trials of the toy objective
        // (max at (3, 7)); the second half of the run must produce
        // better scores on average than the first half.
        let space = xy_space();
        let mut tpe = TpeEngine::new(2026);

        let mut scores = Vec::with_capacity(80);
        for i in 0..80u32 {
            let params = tpe.suggest(&space);
            let score = toy_score(&params);
            scores.push(score);
            tpe.report(TrialResult {
                trial_id: i,
                params,
                metrics: TrialMetrics {
                    total_trades: 1,
                    total_pnl: 0.0,
                    win_rate: 0.0,
                    sharpe_ratio: 0.0,
                    max_drawdown_pct: 0.0,
                    profit_factor: 0.0,
                    final_equity: 0.0,
                },
                score,
            });
        }
        let first_half_mean: f64 = scores.iter().take(40).copied().sum::<f64>() / 40.0;
        let second_half_mean: f64 = scores.iter().skip(40).copied().sum::<f64>() / 40.0;
        assert!(
            second_half_mean > first_half_mean,
            "second-half mean ({}) must exceed first-half mean ({}) — TPE failed to improve",
            second_half_mean,
            first_half_mean,
        );
        // The best score recorded must be close to 0 (the optimum).
        let best = scores.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        assert!(
            best > -1.0,
            "best score over 80 trials ({}) must come within 1.0 of the optimum (= 0.0)",
            best,
        );
    }

    // ─── Engine: per-parameter spec coverage ────────────────────────────────

    #[test]
    fn suggest_handles_int_bool_categorical_and_fixed_params() {
        let mut params: BTreeMap<String, ParameterSpec> = BTreeMap::new();
        params.insert("x_int".into(), ParameterSpec::Int { min: 0, max: 100 });
        params.insert("flag".into(), ParameterSpec::Bool);
        params.insert(
            "mode".into(),
            ParameterSpec::Categorical {
                values: vec!["a".into(), "b".into(), "c".into()],
            },
        );
        let mut fixed = BTreeMap::new();
        fixed.insert("const".into(), 42.0);
        let space = SearchSpace {
            strategy_name: "mixed".into(),
            parameters: params,
            fixed,
        };

        let mut tpe = TpeEngine::new(7);
        // Warm-start with 10 results so the engine takes the TPE path.
        let history: Vec<TrialResult> = (0..10)
            .map(|i| {
                let mut p = TrialParams::new();
                p.insert("x_int", (10 + i * 5) as f64);
                p.insert("flag", if i % 2 == 0 { 1.0 } else { 0.0 });
                p.insert("mode", (i % 3) as f64);
                TrialResult {
                    trial_id: i as u32,
                    params: p,
                    metrics: TrialMetrics {
                        total_trades: 10,
                        total_pnl: 0.0,
                        win_rate: 0.0,
                        sharpe_ratio: 0.0,
                        max_drawdown_pct: 0.0,
                        profit_factor: 0.0,
                        final_equity: 0.0,
                    },
                    score: 1.0 + i as f64,
                }
            })
            .collect();
        tpe.warm_start(history);

        for _ in 0..20 {
            let p = tpe.suggest(&space);
            let xi = p.get_or("x_int", f64::NAN);
            assert!((0.0..=100.0).contains(&xi), "x_int out of bounds: {}", xi);
            assert!(xi.fract().abs() < 1e-9, "x_int must be integer: {}", xi);

            let flag = p.get_or("flag", f64::NAN);
            assert!(flag == 0.0 || flag == 1.0, "flag must be 0/1: {}", flag);

            let mode = p.get_or("mode", f64::NAN);
            assert!(
                mode == 0.0 || mode == 1.0 || mode == 2.0,
                "mode out of bounds: {}",
                mode,
            );

            let c = p.get_or("const", f64::NAN);
            assert_eq!(c, 42.0, "fixed param must be propagated verbatim");
        }
    }

    #[test]
    fn suggest_log_uniform_float_stays_within_bounds() {
        let mut params: BTreeMap<String, ParameterSpec> = BTreeMap::new();
        params.insert(
            "lr".into(),
            ParameterSpec::Float {
                min: 1e-4,
                max: 1e-1,
                log: true,
            },
        );
        let space = SearchSpace {
            strategy_name: "log".into(),
            parameters: params,
            fixed: BTreeMap::new(),
        };

        let mut tpe = TpeEngine::new(31);
        // Warm-start with 10 log-distributed trials
        let history: Vec<TrialResult> = (0..10)
            .map(|i| {
                let v = 10f64.powf(-4.0 + (i as f64) * 0.3);
                let mut p = TrialParams::new();
                p.insert("lr", v);
                TrialResult {
                    trial_id: i,
                    params: p,
                    metrics: TrialMetrics {
                        total_trades: 1,
                        total_pnl: 0.0,
                        win_rate: 0.0,
                        sharpe_ratio: 0.0,
                        max_drawdown_pct: 0.0,
                        profit_factor: 0.0,
                        final_equity: 0.0,
                    },
                    score: -(i as f64),
                }
            })
            .collect();
        tpe.warm_start(history);

        for _ in 0..40 {
            let p = tpe.suggest(&space);
            let v = p.get_or("lr", f64::NAN);
            assert!(
                (1e-4..=1e-1).contains(&v),
                "log-uniform lr escaped bounds: {}",
                v,
            );
        }
    }

    // ─── Engine: history + report API ───────────────────────────────────────

    #[test]
    fn report_appends_to_history_in_call_order() {
        let mut tpe = TpeEngine::new(0);
        let t0 = trial_with_score(0, 1.0, 2.0, 0.5);
        let t1 = trial_with_score(1, 3.0, 4.0, 0.7);
        tpe.report(t0.clone());
        tpe.report(t1.clone());
        assert_eq!(tpe.history().len(), 2);
        assert_eq!(tpe.history()[0], t0);
        assert_eq!(tpe.history()[1], t1);
    }

    #[test]
    fn warm_start_replaces_existing_history() {
        let mut tpe = TpeEngine::new(0);
        tpe.report(trial_with_score(0, 1.0, 2.0, 9.0));
        assert_eq!(tpe.history().len(), 1);
        let fresh = vec![
            trial_with_score(10, 0.0, 0.0, 1.0),
            trial_with_score(11, 1.0, 1.0, 2.0),
        ];
        tpe.warm_start(fresh.clone());
        assert_eq!(tpe.history(), fresh.as_slice());
    }

    // ─── Builder validation ─────────────────────────────────────────────────

    #[test]
    #[should_panic(expected = "gamma must be in (0.0, 1.0)")]
    fn with_gamma_rejects_value_outside_open_unit_interval() {
        let _ = TpeEngine::new(0).with_gamma(0.0);
    }

    #[test]
    #[should_panic(expected = "n_ei_candidates must be > 0")]
    fn with_n_ei_candidates_rejects_zero() {
        let _ = TpeEngine::new(0).with_n_ei_candidates(0);
    }
}
