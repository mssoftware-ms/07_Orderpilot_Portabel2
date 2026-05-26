//! Statistical gates for Phase-3.1 Welle W4 — PBO + DSR.
//!
//! This module supplies the Bailey-de-Prado (2014) Probability of
//! Backtest Overfitting (PBO) and Deflated Sharpe Ratio (DSR) tests as
//! pure functions over slim input structs. The Welle W4 production
//! flow feeds the union of Welle-W3a survivors + Welle-W3.5 TPE trials
//! through both gates to decide whether any single trial is robust
//! enough to nominate as a production-default candidate (PBO < 0.5
//! pool-level + DSR > 0.95 trial-level).
//!
//! # PBO — Combinatorially Symmetric Cross-Validation
//! Given a matrix `M[trial][split]` of out-of-sample profit factors,
//! enumerate every `C(S, S/2)` partition of the `S` splits into an
//! "IS-test" and complementary "OOS-test" subset. For each partition:
//!   1. Pick the trial whose mean PF on the IS-test subset is highest
//!   2. Rank that trial's mean PF on the OOS-test subset against the
//!      whole pool (ascending: 1 = worst, N = best, ties → midrank)
//!   3. Map to relative rank `r = rank / (N + 1)` ∈ (0, 1)
//!   4. logit = log(r / (1-r))
//!
//! `PBO = P(logit < 0)` = fraction of partitions where the IS-best
//! trial overfits. Convention: `PBO < 0.5` ⇒ robust pool, ≥ 0.7 ⇒
//! the selection methodology is dominated by noise.
//!
//! # DSR — Multiple-Testing-Corrected Sharpe Significance
//! Given a single trial's observed Sharpe ratio (plus the pool size
//! `N`, the sample skew/kurtosis of returns, and the number of return
//! observations `T`), the Deflated Sharpe Ratio is
//!
//! ```text
//! Z*  = (SR - E[max SR | N, H0]) * sqrt(T - 1)
//!       / sqrt(1 - γ_3 * SR + (γ_4 - 1)/4 * SR²)
//! DSR = Φ(Z*)
//! ```
//!
//! where γ_3 is the sample skewness and γ_4 is the **raw** (NOT excess)
//! kurtosis of returns (i.e. γ_4 = 3.0 for a normal). The variance
//! denominator is the Mertens (2002) standard-error correction; the
//! `E[max SR | N, H0]` term applies the Bailey-de-Prado 2014 expected
//! maximum Sharpe under the null hypothesis of zero true skill across
//! `N` trials. Convention: `DSR > 0.95` ⇒ trial robust against
//! multiple-testing bias.
//!
//! # Numerical helpers
//! - `standard_normal_cdf` uses the Abramowitz-Stegun 7.1.26 erf
//!   approximation (accuracy ~1.5e-7 over R).
//! - `inverse_standard_normal_cdf` uses Acklam's (2010) rational
//!   approximation (accuracy ~1.15e-9 for p ∈ (0, 1)).
//! - `combinations` enumerates `C(n, k)` in lexicographic order,
//!   shared between PBO and any future combinatorial gate.
//!
//! All public types are `Serialize` / `Deserialize` so the W4-2 CLI
//! can round-trip `PboResult` / `DsrResult` through JSON or SQLite
//! without bespoke encoders.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};

// ─── PBO ─────────────────────────────────────────────────────────────────────

/// Input to `calculate_pbo` — the OOS profit-factor matrix and the
/// CSCV partition size.
///
/// `matrix[trial][split]` is the OOS profit factor for that
/// `(trial, split)` pair. All rows must have the same length.
/// `n_splits_per_side` is the size of one half of the CSCV partition:
/// for `S` splits the canonical Bailey-de-Prado setup uses
/// `n_splits_per_side = S / 2` so the IS-test and OOS-test subsets
/// are equal-sized complements.
#[derive(Debug, Clone)]
pub struct PboInput {
    /// `matrix[trial][split]` — OOS profit factors. NaN / ±Inf are
    /// sanitized to `0.0` inside `calculate_pbo` so a single
    /// pathological split does not poison the entire partition.
    pub matrix: Vec<Vec<f64>>,
    /// Size of one side of the CSCV partition. Must satisfy
    /// `2 * n_splits_per_side <= n_splits`.
    pub n_splits_per_side: usize,
}

/// Pool-level PBO robustness verdict.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PboRobustness {
    /// `PBO < 0.5` — the selection method generalizes; IS-best
    /// trials tend to also rank high OOS.
    Robust,
    /// `0.5 ≤ PBO < 0.7` — borderline; further validation required
    /// before declaring a production-default.
    Marginal,
    /// `PBO ≥ 0.7` — the IS-best trial is typically a poor OOS
    /// performer; the selection methodology is dominated by noise.
    Weak,
}

/// Result of `calculate_pbo` — pool-level overfitting probability and
/// the underlying logit distribution.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PboResult {
    /// `P(IS-best trial OOS-rank < median)` ∈ `[0.0, 1.0]`.
    pub pbo_score: f64,
    /// Number of CSCV partitions considered = `C(n_splits, n_splits_per_side)`.
    pub n_combinations: usize,
    /// One logit value per partition. Negative ⇒ overfit on that
    /// partition; positive ⇒ best-IS generalized.
    pub logit_distribution: Vec<f64>,
    /// Pool verdict — derived from `pbo_score` using
    /// `< 0.5 → Robust`, `< 0.7 → Marginal`, else `Weak`.
    pub robustness_indicator: PboRobustness,
}

/// Compute the Bailey-de-Prado Probability of Backtest Overfitting
/// via Combinatorially Symmetric Cross-Validation.
///
/// # Errors
/// - `matrix` empty or under 2 trials (`PBO` is meaningless for a
///   single-row pool — the IS-best is trivially the OOS-best).
/// - Row-length mismatch.
/// - `n_splits_per_side == 0` or `2 * n_splits_per_side > n_splits`
///   (no complementary OOS subset can be formed).
pub fn calculate_pbo(input: &PboInput) -> Result<PboResult> {
    let n_trials = input.matrix.len();
    if n_trials < 2 {
        bail!(
            "calculate_pbo: need ≥ 2 trials for a meaningful pool, got {}",
            n_trials,
        );
    }
    let n_splits = input.matrix[0].len();
    if n_splits == 0 {
        bail!("calculate_pbo: trial 0 has zero splits");
    }
    for (i, row) in input.matrix.iter().enumerate() {
        if row.len() != n_splits {
            bail!(
                "calculate_pbo: row {} has {} splits, expected {}",
                i,
                row.len(),
                n_splits,
            );
        }
    }
    if input.n_splits_per_side == 0 {
        bail!("calculate_pbo: n_splits_per_side must be ≥ 1");
    }
    if 2 * input.n_splits_per_side > n_splits {
        bail!(
            "calculate_pbo: 2 * n_splits_per_side ({}) > n_splits ({}); \
             no complementary OOS subset can be formed",
            2 * input.n_splits_per_side,
            n_splits,
        );
    }

    // Sanitize NaN/±Inf → 0.0. A single pathological split would
    // otherwise propagate through both the IS-mean and the OOS-rank
    // computations and skew the entire pool's PBO.
    let matrix: Vec<Vec<f64>> = input
        .matrix
        .iter()
        .map(|row| row.iter().map(|&v| if v.is_finite() { v } else { 0.0 }).collect())
        .collect();

    let all_splits: Vec<usize> = (0..n_splits).collect();
    let is_combos = combinations(&all_splits, input.n_splits_per_side);

    let mut logits = Vec::with_capacity(is_combos.len());
    let n_trials_f = n_trials as f64;

    for is_combo in &is_combos {
        let oos_combo: Vec<usize> = all_splits
            .iter()
            .filter(|s| !is_combo.contains(s))
            .copied()
            .collect();

        // Per-trial IS mean and OOS mean.
        let is_means: Vec<f64> = matrix
            .iter()
            .map(|row| mean_at_indices(row, is_combo))
            .collect();
        let oos_means: Vec<f64> = matrix
            .iter()
            .map(|row| mean_at_indices(row, &oos_combo))
            .collect();

        // IS-best trial — lex-first wins on ties (deterministic).
        let best_trial = argmax(&is_means);

        // OOS midrank of best_trial (ascending: 1 = worst). Ties contribute
        // 0.5 each so the mid-rank is robust to identical OOS scores.
        let target = oos_means[best_trial];
        let mut rank = 1.0;
        for (j, &m) in oos_means.iter().enumerate() {
            if j == best_trial {
                continue;
            }
            if m < target {
                rank += 1.0;
            } else if m == target {
                rank += 0.5;
            }
        }

        // Relative rank r ∈ (0, 1) — division by (N+1) avoids the 0/1
        // endpoints and keeps the logit finite for every partition.
        let r = rank / (n_trials_f + 1.0);
        let logit = (r / (1.0 - r)).ln();
        logits.push(logit);
    }

    // PBO = fraction of partitions with logit < 0 = best-IS overfit.
    let n_overfit = logits.iter().filter(|l| **l < 0.0).count();
    let pbo_score = n_overfit as f64 / logits.len() as f64;

    let robustness_indicator = if pbo_score < 0.5 {
        PboRobustness::Robust
    } else if pbo_score < 0.7 {
        PboRobustness::Marginal
    } else {
        PboRobustness::Weak
    };

    Ok(PboResult {
        pbo_score,
        n_combinations: logits.len(),
        logit_distribution: logits,
        robustness_indicator,
    })
}

// ─── DSR ─────────────────────────────────────────────────────────────────────

/// Input to `calculate_dsr` — one trial's observed Sharpe plus the
/// pool-size / return-shape parameters needed by the variance
/// correction and the Bailey-de-Prado E[max] term.
#[derive(Debug, Clone, Copy)]
pub struct DsrInput {
    /// Observed Sharpe ratio of this trial.
    pub trial_sharpe: f64,
    /// Number of independent trials in the search pool — drives the
    /// `E[max SR | N, H0]` penalty.
    pub n_trials: usize,
    /// Sample skewness of returns (3rd standardized central moment).
    pub skew: f64,
    /// **Raw** kurtosis of returns (NOT excess kurtosis). Normal
    /// distribution → 3.0; reject inputs `< 1.0` (no real distribution
    /// has kurtosis below 1).
    pub kurtosis: f64,
    /// Number of return observations behind the trial's Sharpe.
    /// Drives the standard-error scaling.
    pub n_observations: usize,
}

/// Trial-level DSR robustness verdict.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DsrRobustness {
    /// `DSR > 0.95` — trial significantly outperforms the
    /// multiple-testing-corrected null.
    Robust,
    /// `0.70 ≤ DSR ≤ 0.95` — directional signal but not significant
    /// at conventional thresholds.
    Marginal,
    /// `DSR < 0.70` — indistinguishable from the multi-testing null.
    Weak,
}

/// Result of `calculate_dsr` — the deflated Sharpe probability plus
/// the intermediate diagnostics needed to debug surprising values.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DsrResult {
    /// `Φ(Z*)` ∈ `[0.0, 1.0]` — probability that the trial's true
    /// Sharpe exceeds the multiple-testing-corrected H0 threshold.
    pub dsr_score: f64,
    /// Bailey-de-Prado E[max SR_n | N trials, true SR = 0].
    pub expected_max_sharpe_under_h0: f64,
    /// Normalized test statistic `(SR - E[max]) / σ_SR`.
    pub z_star: f64,
    /// Verdict derived from `dsr_score`.
    pub robustness_indicator: DsrRobustness,
}

/// Compute the Bailey-de-Prado Deflated Sharpe Ratio for a single
/// trial inside a pool of `N` candidates.
///
/// # Errors
/// - Non-finite `trial_sharpe` / `skew` / `kurtosis`.
/// - `kurtosis < 1.0` (impossible for any real distribution; flags a
///   bad upstream stat).
/// - `n_trials == 0` or `n_observations < 2`.
/// - The Mertens variance denominator goes non-positive — the input
///   skew/kurtosis combination is internally inconsistent.
pub fn calculate_dsr(input: &DsrInput) -> Result<DsrResult> {
    if input.n_trials == 0 {
        bail!("calculate_dsr: n_trials must be ≥ 1");
    }
    if input.n_observations < 2 {
        bail!(
            "calculate_dsr: n_observations must be ≥ 2 for variance estimation (got {})",
            input.n_observations,
        );
    }
    if !input.trial_sharpe.is_finite() {
        bail!(
            "calculate_dsr: trial_sharpe must be finite (got {})",
            input.trial_sharpe,
        );
    }
    if !input.skew.is_finite() || !input.kurtosis.is_finite() {
        bail!(
            "calculate_dsr: skew and kurtosis must be finite (got skew={}, kurtosis={})",
            input.skew,
            input.kurtosis,
        );
    }
    if input.kurtosis < 1.0 {
        bail!(
            "calculate_dsr: raw kurtosis must be ≥ 1.0 (got {}); \
             remember the API expects RAW kurtosis, not excess",
            input.kurtosis,
        );
    }

    // E[max SR | N, H0]. For N == 1 there is no multiple-testing
    // correction — the formula degenerates and we set E[max] = 0.
    let expected_max_sharpe_under_h0 = if input.n_trials == 1 {
        0.0
    } else {
        bailey_de_prado_expected_max(input.n_trials)
    };

    // Mertens 2002 variance denominator. (γ_4 - 1)/4 uses RAW kurtosis;
    // for normal returns this collapses to 0.5 · SR², matching Lo (2002).
    let sr = input.trial_sharpe;
    let var_factor =
        1.0 - input.skew * sr + ((input.kurtosis - 1.0) / 4.0) * sr * sr;
    if var_factor <= 0.0 {
        bail!(
            "calculate_dsr: degenerate Mertens variance factor = {:.6e} ≤ 0 \
             (skew={}, kurtosis={}, sharpe={}); the input moments are \
             internally inconsistent",
            var_factor,
            input.skew,
            input.kurtosis,
            sr,
        );
    }
    let sigma_sr = (var_factor / (input.n_observations as f64 - 1.0)).sqrt();

    let z_star = (sr - expected_max_sharpe_under_h0) / sigma_sr;
    let dsr_score = standard_normal_cdf(z_star);

    let robustness_indicator = if dsr_score > 0.95 {
        DsrRobustness::Robust
    } else if dsr_score >= 0.70 {
        DsrRobustness::Marginal
    } else {
        DsrRobustness::Weak
    };

    Ok(DsrResult {
        dsr_score,
        expected_max_sharpe_under_h0,
        z_star,
        robustness_indicator,
    })
}

// ─── Numerical helpers ──────────────────────────────────────────────────────

/// Bailey-de-Prado (2014) expected maximum Sharpe under the null
/// hypothesis of zero true skill across `n_trials` independent
/// candidates:
/// `E[max SR_n | N, H0] = (1 - γ) * Φ^{-1}(1 - 1/N) + γ * Φ^{-1}(1 - 1/(N·e))`
/// where γ = Euler-Mascheroni ≈ 0.5772.
fn bailey_de_prado_expected_max(n_trials: usize) -> f64 {
    const EULER_MASCHERONI: f64 = 0.577_215_664_901_532_9_f64;
    let n = n_trials as f64;
    let q1 = 1.0 - 1.0 / n;
    let q2 = 1.0 - 1.0 / (n * std::f64::consts::E);
    let z1 = inverse_standard_normal_cdf(q1);
    let z2 = inverse_standard_normal_cdf(q2);
    (1.0 - EULER_MASCHERONI) * z1 + EULER_MASCHERONI * z2
}

/// Standard normal CDF `Φ(x)` via the Abramowitz-Stegun erf
/// approximation. Accuracy ~1.5e-7 over the real line.
fn standard_normal_cdf(x: f64) -> f64 {
    0.5 * (1.0 + erf(x / std::f64::consts::SQRT_2))
}

/// Inverse standard normal CDF `Φ^{-1}(p)` via Acklam's (2010)
/// rational approximation. Accuracy ~1.15e-9 for `p ∈ (0, 1)`.
/// Returns `±∞` at the boundary.
fn inverse_standard_normal_cdf(p: f64) -> f64 {
    if p <= 0.0 {
        return f64::NEG_INFINITY;
    }
    if p >= 1.0 {
        return f64::INFINITY;
    }
    // Acklam's coefficients — central, lower-tail, and upper-tail
    // rational regions joined at p ≈ 0.02425 / 0.97575.
    const A: [f64; 6] = [
        -3.969_683_028_665_376e1,
        2.209_460_984_245_205e2,
        -2.759_285_104_469_687e2,
        1.383_577_518_672_69e2,
        -3.066_479_806_614_716e1,
        2.506_628_277_459_239e0,
    ];
    const B: [f64; 5] = [
        -5.447_609_879_822_406e1,
        1.615_858_368_580_409e2,
        -1.556_989_798_598_866e2,
        6.680_131_188_771_972e1,
        -1.328_068_155_288_572e1,
    ];
    const C: [f64; 6] = [
        -7.784_894_002_430_293e-3,
        -3.223_964_580_411_365e-1,
        -2.400_758_277_161_838e0,
        -2.549_732_539_343_734e0,
        4.374_664_141_464_968e0,
        2.938_163_982_698_783e0,
    ];
    const D: [f64; 4] = [
        7.784_695_709_041_462e-3,
        3.224_671_290_700_398e-1,
        2.445_134_137_142_996e0,
        3.754_408_661_907_416e0,
    ];
    const P_LOW: f64 = 0.02425;
    const P_HIGH: f64 = 1.0 - P_LOW;

    if p < P_LOW {
        let q = (-2.0 * p.ln()).sqrt();
        (((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    } else if p <= P_HIGH {
        let q = p - 0.5;
        let r = q * q;
        (((((A[0] * r + A[1]) * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * q
            / (((((B[0] * r + B[1]) * r + B[2]) * r + B[3]) * r + B[4]) * r + 1.0)
    } else {
        let q = (-2.0 * (1.0 - p).ln()).sqrt();
        -((((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0))
    }
}

/// Error function approximation (Abramowitz-Stegun 7.1.26). Accuracy
/// ~1.5e-7 over `R`.
fn erf(x: f64) -> f64 {
    const A1: f64 = 0.254_829_592;
    const A2: f64 = -0.284_496_736;
    const A3: f64 = 1.421_413_741;
    const A4: f64 = -1.453_152_027;
    const A5: f64 = 1.061_405_429;
    const P: f64 = 0.327_591_1;
    let sign = if x < 0.0 { -1.0 } else { 1.0 };
    let ax = x.abs();
    let t = 1.0 / (1.0 + P * ax);
    let y = 1.0 - (((((A5 * t + A4) * t) + A3) * t + A2) * t + A1) * t * (-ax * ax).exp();
    sign * y
}

/// Mean of `row[idx]` over `idx ∈ indices`. Empty `indices` returns
/// `0.0` (caller responsibility to avoid).
fn mean_at_indices(row: &[f64], indices: &[usize]) -> f64 {
    if indices.is_empty() {
        return 0.0;
    }
    indices.iter().map(|&i| row[i]).sum::<f64>() / indices.len() as f64
}

/// Index of the first occurrence of the maximum value in `slice`.
/// Empty slice returns `0` (caller responsibility to avoid).
fn argmax(slice: &[f64]) -> usize {
    let mut best = 0usize;
    let mut best_value = f64::NEG_INFINITY;
    for (i, &v) in slice.iter().enumerate() {
        if v > best_value {
            best_value = v;
            best = i;
        }
    }
    best
}

/// Enumerate all `C(n, k)` combinations of `k`-sized subsets of
/// `items`, in lexicographic order of indices. Pure function; no
/// allocation beyond the output `Vec`.
///
/// `k == 0` returns `[vec![]]` (one empty combination, by
/// convention); `k > n` returns `vec![]` (no combinations possible).
fn combinations<T: Copy>(items: &[T], k: usize) -> Vec<Vec<T>> {
    let n = items.len();
    if k == 0 {
        return vec![Vec::new()];
    }
    if k > n {
        return Vec::new();
    }

    let mut result = Vec::new();
    let mut indices: Vec<usize> = (0..k).collect();
    loop {
        result.push(indices.iter().map(|&i| items[i]).collect());
        // Standard next-combination step in lex order.
        let mut i = k;
        let advanced = loop {
            if i == 0 {
                break false;
            }
            i -= 1;
            if indices[i] < i + n - k {
                indices[i] += 1;
                for j in (i + 1)..k {
                    indices[j] = indices[j - 1] + 1;
                }
                break true;
            }
        };
        if !advanced {
            return result;
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── Numerical helpers ────────────────────────────────────────────────

    #[test]
    fn standard_normal_cdf_pins_known_values() {
        assert!((standard_normal_cdf(0.0) - 0.5).abs() < 1e-6);
        // Φ(1.96) ≈ 0.975
        assert!((standard_normal_cdf(1.96) - 0.975).abs() < 1e-3);
        // Φ(-1.96) ≈ 0.025
        assert!((standard_normal_cdf(-1.96) - 0.025).abs() < 1e-3);
        // Φ(3) ≈ 0.99865
        assert!((standard_normal_cdf(3.0) - 0.99865).abs() < 1e-4);
    }

    #[test]
    fn inverse_standard_normal_cdf_pins_known_values() {
        assert!(inverse_standard_normal_cdf(0.5).abs() < 1e-6);
        // Φ^{-1}(0.975) ≈ 1.95996
        assert!((inverse_standard_normal_cdf(0.975) - 1.959_963_984_540_054).abs() < 1e-6);
        // Φ^{-1}(0.025) ≈ -1.95996
        assert!(
            (inverse_standard_normal_cdf(0.025) + 1.959_963_984_540_054).abs() < 1e-6
        );
        // Φ^{-1}(0.99) ≈ 2.3263
        assert!((inverse_standard_normal_cdf(0.99) - 2.326_347_874_040_842).abs() < 1e-5);
        assert!(inverse_standard_normal_cdf(0.0).is_infinite());
        assert!(inverse_standard_normal_cdf(1.0).is_infinite());
    }

    #[test]
    fn bailey_de_prado_expected_max_pins_n_100_and_n_1000() {
        // N = 100 → ~2.5321 (hand-calculated using Φ^{-1}(0.99) and
        // Φ^{-1}(1 - 1/(100·e))).
        let e100 = bailey_de_prado_expected_max(100);
        assert!(
            (e100 - 2.5321).abs() < 1e-2,
            "E[max | N=100] = {:.5}, expected ≈ 2.5321",
            e100,
        );
        // N = 1000 → ~3.2518
        let e1000 = bailey_de_prado_expected_max(1000);
        assert!(
            (e1000 - 3.2518).abs() < 1e-2,
            "E[max | N=1000] = {:.5}, expected ≈ 3.2518",
            e1000,
        );
    }

    #[test]
    fn combinations_enumerates_exact_binomial_count() {
        // C(6, 3) = 20
        let combos = combinations(&(0..6usize).collect::<Vec<_>>(), 3);
        assert_eq!(combos.len(), 20);
        // C(4, 2) = 6
        let combos = combinations(&(0..4usize).collect::<Vec<_>>(), 2);
        assert_eq!(combos.len(), 6);
        // C(5, 0) = 1 (empty combo)
        let combos = combinations(&(0..5usize).collect::<Vec<_>>(), 0);
        assert_eq!(combos.len(), 1);
        assert!(combos[0].is_empty());
        // C(3, 5) = 0
        let combos = combinations(&(0..3usize).collect::<Vec<_>>(), 5);
        assert_eq!(combos.len(), 0);
    }

    #[test]
    fn combinations_lexicographic_order() {
        let combos = combinations(&[0usize, 1, 2, 3], 2);
        assert_eq!(
            combos,
            vec![
                vec![0, 1],
                vec![0, 2],
                vec![0, 3],
                vec![1, 2],
                vec![1, 3],
                vec![2, 3],
            ]
        );
    }

    // ── PBO ──────────────────────────────────────────────────────────────

    /// All-trials-identical pool: every partition's IS-best ties with
    /// the whole pool, so its OOS midrank is `(N+1)/2` and `logit = 0`.
    /// PBO must therefore be 0.0 (no partition produces a strictly
    /// negative logit).
    #[test]
    fn pbo_zero_when_every_trial_identical() {
        let matrix = vec![vec![1.0; 6]; 5];
        let input = PboInput {
            matrix,
            n_splits_per_side: 3,
        };
        let r = calculate_pbo(&input).unwrap();
        assert_eq!(r.n_combinations, 20);
        assert!(r.pbo_score.abs() < 1e-12, "PBO = {}, expected 0.0", r.pbo_score);
        assert_eq!(r.robustness_indicator, PboRobustness::Robust);
    }

    /// Strong-overfit pool: two trials whose per-split PFs are
    /// perfectly anti-correlated force the IS-best trial to be the
    /// OOS-worst on every partition. With a two-trial pool the
    /// OOS-rank of the IS-best is always 1 (worst), so PBO = 1.0.
    /// Three-trial constructions with a flat-middle reference instead
    /// degenerate into mid-rank ties (logit = 0) on most CSCV
    /// partitions — the strict `< 0` PBO criterion would not flag
    /// those as overfit, which is correct but uninformative for the
    /// pathological case.
    #[test]
    fn pbo_one_for_perfectly_anti_correlated_two_trial_pool() {
        let matrix = vec![
            vec![3.0, 3.0, 3.0, 0.1, 0.1, 0.1], // early specialist
            vec![0.1, 0.1, 0.1, 3.0, 3.0, 3.0], // late specialist
        ];
        let r = calculate_pbo(&PboInput {
            matrix,
            n_splits_per_side: 3,
        })
        .unwrap();
        assert!(
            (r.pbo_score - 1.0).abs() < 1e-12,
            "expected PBO = 1.0 for perfect anti-correlation, got {}",
            r.pbo_score,
        );
        assert_eq!(r.robustness_indicator, PboRobustness::Weak);
        // Every partition should produce a strictly negative logit
        // — best-IS lands at the bottom of the 2-trial OOS rank.
        assert!(r.logit_distribution.iter().all(|l| *l < 0.0));
    }

    /// `C(6, 3) = 20` partitions, regardless of pool composition.
    #[test]
    fn pbo_combinations_count_matches_six_choose_three() {
        let matrix = vec![vec![1.0, 2.0, 1.5, 0.8, 1.1, 1.6]; 4];
        let r = calculate_pbo(&PboInput {
            matrix,
            n_splits_per_side: 3,
        })
        .unwrap();
        assert_eq!(r.n_combinations, 20);
        assert_eq!(r.logit_distribution.len(), 20);
    }

    /// NaN / ±Inf inputs sanitize to `0.0` rather than poisoning the
    /// per-partition means. A single NaN must not nuke the whole PBO
    /// computation.
    #[test]
    fn pbo_sanitizes_nan_and_inf_inputs_to_zero() {
        let matrix = vec![
            vec![1.0, f64::NAN, 1.0, 1.0, f64::INFINITY, 1.0],
            vec![1.0, 1.0, 1.0, 1.0, 1.0, 1.0],
            vec![0.5, 0.5, 0.5, 0.5, 0.5, 0.5],
        ];
        let r = calculate_pbo(&PboInput {
            matrix,
            n_splits_per_side: 3,
        })
        .unwrap();
        // Must complete without error and produce a finite PBO.
        assert!(r.pbo_score.is_finite());
        assert!(r.logit_distribution.iter().all(|l| l.is_finite()));
    }

    #[test]
    fn pbo_rejects_mismatched_row_lengths() {
        let matrix = vec![vec![1.0; 6], vec![1.0; 5]];
        let err = calculate_pbo(&PboInput {
            matrix,
            n_splits_per_side: 3,
        });
        assert!(err.is_err());
    }

    #[test]
    fn pbo_rejects_invalid_n_splits_per_side() {
        let matrix = vec![vec![1.0; 6], vec![1.0; 6]];
        // n_splits_per_side = 0
        assert!(calculate_pbo(&PboInput {
            matrix: matrix.clone(),
            n_splits_per_side: 0,
        })
        .is_err());
        // 2 * n_splits_per_side > n_splits
        assert!(calculate_pbo(&PboInput {
            matrix,
            n_splits_per_side: 4,
        })
        .is_err());
    }

    #[test]
    fn pbo_rejects_too_few_trials() {
        let matrix = vec![vec![1.0; 6]];
        let err = calculate_pbo(&PboInput {
            matrix,
            n_splits_per_side: 3,
        });
        assert!(err.is_err());
    }

    /// Robustness thresholds: assignment must follow the
    /// `< 0.5 → Robust`, `< 0.7 → Marginal`, `≥ 0.7 → Weak`
    /// convention specified in `PboRobustness`.
    #[test]
    fn pbo_robustness_thresholds_match_documented_bands() {
        let cases = [
            (0.0, PboRobustness::Robust),
            (0.49, PboRobustness::Robust),
            (0.50, PboRobustness::Marginal),
            (0.69, PboRobustness::Marginal),
            (0.70, PboRobustness::Weak),
            (1.0, PboRobustness::Weak),
        ];
        for (pbo, expected) in cases {
            let actual = if pbo < 0.5 {
                PboRobustness::Robust
            } else if pbo < 0.7 {
                PboRobustness::Marginal
            } else {
                PboRobustness::Weak
            };
            assert_eq!(actual, expected, "PBO = {}", pbo);
        }
    }

    // ── DSR ──────────────────────────────────────────────────────────────

    /// Normal returns + single-trial pool: the Bailey formula collapses
    /// to `Z = SR · sqrt(T-1) / sqrt(1 + 0.5·SR²)` (Lo 2002). For
    /// `SR = 1.0`, `T = 6`, raw kurtosis = 3, skew = 0:
    /// Z ≈ 1.0 · sqrt(5) / sqrt(1.5) ≈ 1.826  ⇒  DSR ≈ Φ(1.826) ≈ 0.966.
    #[test]
    fn dsr_normal_returns_single_trial_matches_lo_2002() {
        let r = calculate_dsr(&DsrInput {
            trial_sharpe: 1.0,
            n_trials: 1,
            skew: 0.0,
            kurtosis: 3.0,
            n_observations: 6,
        })
        .unwrap();
        let z_expected = 1.0_f64 * 5.0_f64.sqrt() / 1.5_f64.sqrt();
        assert!(
            (r.z_star - z_expected).abs() < 1e-9,
            "Z* = {}, expected ≈ {}",
            r.z_star,
            z_expected,
        );
        let dsr_expected = standard_normal_cdf(z_expected);
        assert!(
            (r.dsr_score - dsr_expected).abs() < 1e-9,
            "DSR = {}, expected ≈ {}",
            r.dsr_score,
            dsr_expected,
        );
        assert_eq!(r.expected_max_sharpe_under_h0, 0.0);
    }

    /// Increasing the pool size lowers DSR for the same observed Sharpe —
    /// the multiple-testing penalty bites.
    #[test]
    fn dsr_higher_trial_count_lowers_score() {
        let base = DsrInput {
            trial_sharpe: 1.5,
            n_trials: 1,
            skew: 0.0,
            kurtosis: 3.0,
            n_observations: 100,
        };
        let r1 = calculate_dsr(&base).unwrap();
        let r100 = calculate_dsr(&DsrInput {
            n_trials: 100,
            ..base
        })
        .unwrap();
        let r1000 = calculate_dsr(&DsrInput {
            n_trials: 1000,
            ..base
        })
        .unwrap();
        assert!(
            r1.dsr_score > r100.dsr_score,
            "DSR(N=1)={:.4} must exceed DSR(N=100)={:.4}",
            r1.dsr_score,
            r100.dsr_score,
        );
        assert!(
            r100.dsr_score > r1000.dsr_score,
            "DSR(N=100)={:.4} must exceed DSR(N=1000)={:.4}",
            r100.dsr_score,
            r1000.dsr_score,
        );
        assert!(r1.expected_max_sharpe_under_h0 == 0.0);
        assert!(r1000.expected_max_sharpe_under_h0 > r100.expected_max_sharpe_under_h0);
    }

    /// `n_trials == 1` ⇒ no E[max] correction is applied.
    #[test]
    fn dsr_single_trial_skips_multiple_testing_correction() {
        let r = calculate_dsr(&DsrInput {
            trial_sharpe: 0.5,
            n_trials: 1,
            skew: 0.1,
            kurtosis: 3.5,
            n_observations: 252,
        })
        .unwrap();
        assert_eq!(r.expected_max_sharpe_under_h0, 0.0);
    }

    /// Extreme skew/kurtosis should still produce a finite DSR as long
    /// as the Mertens denominator stays positive.
    #[test]
    fn dsr_extreme_skew_kurtosis_remains_finite() {
        let r = calculate_dsr(&DsrInput {
            trial_sharpe: 0.8,
            n_trials: 50,
            skew: -2.0,
            kurtosis: 10.0,
            n_observations: 500,
        })
        .unwrap();
        assert!(r.dsr_score.is_finite());
        assert!(r.z_star.is_finite());
        assert!(r.expected_max_sharpe_under_h0.is_finite());
    }

    #[test]
    fn dsr_rejects_non_finite_inputs() {
        let base = DsrInput {
            trial_sharpe: 1.0,
            n_trials: 10,
            skew: 0.0,
            kurtosis: 3.0,
            n_observations: 100,
        };
        assert!(calculate_dsr(&DsrInput {
            trial_sharpe: f64::NAN,
            ..base
        })
        .is_err());
        assert!(calculate_dsr(&DsrInput {
            skew: f64::INFINITY,
            ..base
        })
        .is_err());
        assert!(calculate_dsr(&DsrInput {
            kurtosis: f64::NAN,
            ..base
        })
        .is_err());
    }

    #[test]
    fn dsr_rejects_invalid_kurtosis_below_one() {
        let err = calculate_dsr(&DsrInput {
            trial_sharpe: 1.0,
            n_trials: 10,
            skew: 0.0,
            kurtosis: 0.5,
            n_observations: 100,
        });
        assert!(err.is_err(), "kurtosis < 1.0 must error");
    }

    #[test]
    fn dsr_rejects_invalid_n_inputs() {
        let base = DsrInput {
            trial_sharpe: 1.0,
            n_trials: 10,
            skew: 0.0,
            kurtosis: 3.0,
            n_observations: 100,
        };
        assert!(calculate_dsr(&DsrInput { n_trials: 0, ..base }).is_err());
        assert!(calculate_dsr(&DsrInput {
            n_observations: 1,
            ..base
        })
        .is_err());
    }

    /// Bailey-de-Prado warn when the Mertens variance denominator
    /// collapses — e.g. extreme positive skew with a large positive
    /// Sharpe and low kurtosis.
    #[test]
    fn dsr_errors_when_mertens_denom_goes_non_positive() {
        // 1 - 10*2 + (3-1)/4 * 4 = 1 - 20 + 2 = -17 < 0
        let err = calculate_dsr(&DsrInput {
            trial_sharpe: 2.0,
            n_trials: 10,
            skew: 10.0,
            kurtosis: 3.0,
            n_observations: 100,
        });
        assert!(err.is_err(), "must error on negative variance denominator");
    }

    #[test]
    fn dsr_robustness_thresholds_match_documented_bands() {
        let cases = [
            (0.0, DsrRobustness::Weak),
            (0.50, DsrRobustness::Weak),
            (0.70, DsrRobustness::Marginal),
            (0.94, DsrRobustness::Marginal),
            (0.95, DsrRobustness::Marginal), // boundary: > 0.95 is Robust
            (0.951, DsrRobustness::Robust),
            (1.0, DsrRobustness::Robust),
        ];
        for (dsr, expected) in cases {
            let actual = if dsr > 0.95 {
                DsrRobustness::Robust
            } else if dsr >= 0.70 {
                DsrRobustness::Marginal
            } else {
                DsrRobustness::Weak
            };
            assert_eq!(actual, expected, "DSR = {}", dsr);
        }
    }

    /// Round-trip: PboResult and DsrResult serialize / deserialize
    /// through serde_json bit-identically. This is the requirement
    /// that lets the W4-2 CLI persist a JSON column without a custom
    /// encoder.
    #[test]
    fn results_roundtrip_through_serde_json() {
        let pbo = PboResult {
            pbo_score: 0.35,
            n_combinations: 20,
            logit_distribution: vec![-0.5, 0.0, 1.2, -1.5],
            robustness_indicator: PboRobustness::Robust,
        };
        let json = serde_json::to_string(&pbo).unwrap();
        let back: PboResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.pbo_score, pbo.pbo_score);
        assert_eq!(back.n_combinations, pbo.n_combinations);
        assert_eq!(back.logit_distribution, pbo.logit_distribution);
        assert_eq!(back.robustness_indicator, pbo.robustness_indicator);

        let dsr = DsrResult {
            dsr_score: 0.98,
            expected_max_sharpe_under_h0: 2.5,
            z_star: 2.05,
            robustness_indicator: DsrRobustness::Robust,
        };
        let json = serde_json::to_string(&dsr).unwrap();
        let back: DsrResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.dsr_score, dsr.dsr_score);
        assert_eq!(
            back.expected_max_sharpe_under_h0,
            dsr.expected_max_sharpe_under_h0
        );
        assert_eq!(back.z_star, dsr.z_star);
        assert_eq!(back.robustness_indicator, dsr.robustness_indicator);
    }
}
