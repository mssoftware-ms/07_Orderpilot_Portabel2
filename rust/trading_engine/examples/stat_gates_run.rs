//! PBO + DSR statistical-gates CLI — Phase-3.1 Welle W4.
//!
//! Builds the union of Welle-W3a survivors and the Welle-W3.5 TPE
//! production-run trials, applies the Bailey-de-Prado 2014 PBO
//! (pool-level) and DSR (per-trial) tests via the
//! `optimizer::stat_gates` module, and writes the verdict to CSV +
//! SQLite. Pure analysis on top of two read-only walk-forward
//! databases — no backtest engine calls, no candle iteration. The
//! `--candles` flag is accepted but unused at the moment (reserved
//! for the future companion run that would re-confirm the union
//! pool's metrics on the same candle series).
//!
//! # CLI
//! ```text
//! cargo run --release --example stat_gates_run -- \
//!   --tpe-db   01_Projectplan/optimizer_studies/studies-ichimoku-tpe.db \
//!   --w3a-db   01_Projectplan/optimizer_studies/studies-ichimoku-wf-w3a.db \
//!   --candles  01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
//!   --output-csv 01_Projectplan/optimizer_studies/stat_gates_union_pool.csv \
//!   --output-db  01_Projectplan/optimizer_studies/stat_gates_results.db
//! ```
//!
//! # Union-Pool composition
//! The default union (matching the W4-2 plan):
//!
//! 1. TPE trials passing `mean_oos_pf ≥ 2.14` AND `worst_oos_pf ≥ 0.3`
//!    (the Pfad-A reach criterion).
//! 2. W3a top-5 by `aggregated_score` (sentinel for the
//!    cross-search-space cluster).
//! 3. W3a trials passing `SurvivorCriteria::default()` (Welle-W2
//!    default-criteria pool — Trial 688 + Trial 36).
//!
//! Dedupe by `(source_db, trial_id)` — TPE and W3a use disjoint
//! parameter spaces and disjoint trial-id ranges, so collisions are
//! limited to the W3a-top-5 ∩ W3a-default-survivors corner case
//! (currently disjoint, but the code handles overlap regardless).
//!
//! # DSR mapping
//! Walk-forward results expose one sharpe per `(trial, split)` pair.
//! For DSR we treat the n_splits OOS sharpes as the sample,
//! `trial_sharpe = mean(OOS sharpes)`, sample skew / raw kurtosis
//! computed on the same vector, `n_observations = n_splits`. This is
//! the most conservative valid mapping — Mertens' variance
//! correction stays sample-driven instead of relying on per-trade
//! return assumptions that the optimizer never observed.

use std::collections::HashSet;
use std::fs::{create_dir_all, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use chrono::Utc;
use rusqlite::{params, Connection};

use trading_engine::optimizer::{
    calculate_dsr, calculate_pbo, survives, DsrInput, DsrResult, DsrRobustness, PboInput,
    PboResult, PboRobustness, StrategyKind, StudyStorage, SurvivorCriteria, WalkForwardResult,
    WalkForwardSplitResult,
};

// ─── Constants ──────────────────────────────────────────────────────────────

const DEFAULT_PFAD_A_MIN_MEAN_OOS_PF: f64 = 2.14;
const DEFAULT_PFAD_A_MIN_WORST_OOS_PF: f64 = 0.3;
const DEFAULT_PBO_SPLITS_PER_SIDE: usize = 3;
const DEFAULT_W3A_TOP_N: usize = 5;
const DEFAULT_SEED: u64 = 42;
const REPLAY_DATE: &str = "2026-05-26";
const TPE_SOURCE_LABEL: &str = "tpe";
const W3A_SOURCE_LABEL: &str = "w3a";

// ─── CLI args ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct CliArgs {
    tpe_db: PathBuf,
    w3a_db: PathBuf,
    /// Reserved for future re-confirmation runs; currently unused.
    candles_path: Option<PathBuf>,
    output_csv: PathBuf,
    output_db: PathBuf,
    pfad_a_min_mean_oos_pf: f64,
    pfad_a_min_worst_oos_pf: f64,
    pbo_splits_per_side: usize,
    include_w3a_top_n: usize,
    include_w3a_default_survivors: bool,
    seed: u64,
}

fn print_usage() {
    eprintln!(
        "usage: stat_gates_run \\\n\
         \t--tpe-db <db>              TPE walk-forward DB (e.g. studies-ichimoku-tpe.db) \\\n\
         \t--w3a-db <db>              W3a walk-forward DB (e.g. studies-ichimoku-wf-w3a.db) \\\n\
         \t[--candles <json>]         candle file (reserved; currently unused) \\\n\
         \t--output-csv <path>        union-pool CSV with PBO + DSR per trial \\\n\
         \t--output-db <path>         SQLite DB receiving pool + per-trial gates rows \\\n\
         \t[--pfad-a-min-mean-oos-pf F]  TPE filter floor (default {}) \\\n\
         \t[--pfad-a-min-worst-oos-pf F] TPE filter floor (default {}) \\\n\
         \t[--pbo-splits-per-side N]     CSCV half-size (default {}) \\\n\
         \t[--include-w3a-top-n N]       force-include top-N W3a trials (default {}) \\\n\
         \t[--include-w3a-default-survivors on|off]  include W3a default-criteria pool (default on) \\\n\
         \t[--seed N]                     audit seed (default {})",
        DEFAULT_PFAD_A_MIN_MEAN_OOS_PF,
        DEFAULT_PFAD_A_MIN_WORST_OOS_PF,
        DEFAULT_PBO_SPLITS_PER_SIDE,
        DEFAULT_W3A_TOP_N,
        DEFAULT_SEED,
    );
}

fn parse_on_off(s: &str) -> Result<bool> {
    match s {
        "on" | "true" | "1" => Ok(true),
        "off" | "false" | "0" => Ok(false),
        other => bail!("expected 'on' or 'off', got '{}'", other),
    }
}

fn parse_args() -> Result<CliArgs> {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    parse_args_from(&raw)
}

/// Testable arg parser. Accepts args without the program-name element.
fn parse_args_from(raw: &[String]) -> Result<CliArgs> {
    if raw.is_empty() || raw.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        bail!("missing required arguments");
    }

    let mut tpe_db: Option<PathBuf> = None;
    let mut w3a_db: Option<PathBuf> = None;
    let mut candles_path: Option<PathBuf> = None;
    let mut output_csv: Option<PathBuf> = None;
    let mut output_db: Option<PathBuf> = None;
    let mut pfad_a_min_mean_oos_pf = DEFAULT_PFAD_A_MIN_MEAN_OOS_PF;
    let mut pfad_a_min_worst_oos_pf = DEFAULT_PFAD_A_MIN_WORST_OOS_PF;
    let mut pbo_splits_per_side = DEFAULT_PBO_SPLITS_PER_SIDE;
    let mut include_w3a_top_n = DEFAULT_W3A_TOP_N;
    let mut include_w3a_default_survivors = true;
    let mut seed = DEFAULT_SEED;

    let mut i = 0;
    while i < raw.len() {
        let key = raw[i].as_str();
        let val = raw.get(i + 1).map(String::as_str);
        let need =
            || -> Result<&str> { val.with_context(|| format!("flag '{}' requires a value", key)) };
        match key {
            "--tpe-db" => tpe_db = Some(PathBuf::from(need()?)),
            "--w3a-db" => w3a_db = Some(PathBuf::from(need()?)),
            "--candles" => candles_path = Some(PathBuf::from(need()?)),
            "--output-csv" => output_csv = Some(PathBuf::from(need()?)),
            "--output-db" => output_db = Some(PathBuf::from(need()?)),
            "--pfad-a-min-mean-oos-pf" => {
                pfad_a_min_mean_oos_pf = need()?
                    .parse()
                    .with_context(|| "--pfad-a-min-mean-oos-pf must be f64")?
            }
            "--pfad-a-min-worst-oos-pf" => {
                pfad_a_min_worst_oos_pf = need()?
                    .parse()
                    .with_context(|| "--pfad-a-min-worst-oos-pf must be f64")?
            }
            "--pbo-splits-per-side" => {
                pbo_splits_per_side = need()?
                    .parse()
                    .with_context(|| "--pbo-splits-per-side must be usize")?
            }
            "--include-w3a-top-n" => {
                include_w3a_top_n = need()?
                    .parse()
                    .with_context(|| "--include-w3a-top-n must be usize")?
            }
            "--include-w3a-default-survivors" => {
                include_w3a_default_survivors = parse_on_off(need()?)?
            }
            "--seed" => seed = need()?.parse().with_context(|| "--seed must be u64")?,
            other => bail!("unknown flag '{}'", other),
        }
        i += 2;
    }

    Ok(CliArgs {
        tpe_db: tpe_db.context("--tpe-db is required")?,
        w3a_db: w3a_db.context("--w3a-db is required")?,
        candles_path,
        output_csv: output_csv.context("--output-csv is required")?,
        output_db: output_db.context("--output-db is required")?,
        pfad_a_min_mean_oos_pf,
        pfad_a_min_worst_oos_pf,
        pbo_splits_per_side,
        include_w3a_top_n,
        include_w3a_default_survivors,
        seed,
    })
}

// ─── Union pool ─────────────────────────────────────────────────────────────

/// One member of the union pool — origin + the walk-forward result
/// needed for PBO / DSR.
#[derive(Debug, Clone)]
struct PoolEntry {
    source_db: String,
    result: WalkForwardResult,
}

/// Load every walk_forward_trials row for the most-recent
/// `strategy`-matching study in `db_path`.
fn load_all_wf_results(db_path: &Path, strategy: StrategyKind) -> Result<Vec<WalkForwardResult>> {
    let storage =
        StudyStorage::open(db_path).with_context(|| format!("open {}", db_path.display()))?;
    let studies = storage.list_studies()?;
    let target = studies
        .iter()
        .filter(|s| s.strategy == strategy.as_str())
        .max_by_key(|s| s.id)
        .with_context(|| format!("no '{}' study in {}", strategy.as_str(), db_path.display()))?;
    let n = storage.count_walk_forward_trials(target.id)? as usize;
    if n == 0 {
        bail!(
            "study '{}' (id={}) has zero walk_forward_trials rows",
            target.name,
            target.id,
        );
    }
    storage.top_n_walk_forward(target.id, n)
}

/// Apply the Pfad-A reach filter to a slice of TPE walk-forward results.
fn filter_pfad_a(
    trials: &[WalkForwardResult],
    min_mean_oos_pf: f64,
    min_worst_oos_pf: f64,
) -> Vec<WalkForwardResult> {
    trials
        .iter()
        .filter(|r| r.mean_oos_pf >= min_mean_oos_pf && r.worst_oos_pf >= min_worst_oos_pf)
        .cloned()
        .collect()
}

/// Pick the top-`n` W3a trials by `aggregated_score`. The caller is
/// responsible for passing trials in any order; this helper sorts.
fn select_w3a_top_n(trials: &[WalkForwardResult], n: usize) -> Vec<WalkForwardResult> {
    let mut sorted: Vec<WalkForwardResult> = trials.to_vec();
    sorted.sort_by(|a, b| {
        b.aggregated_score
            .partial_cmp(&a.aggregated_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    sorted.into_iter().take(n).collect()
}

/// Filter W3a trials with the Welle-W2 default survivor criteria
/// (Trial 688 + Trial 36 on the current Welle-W3a study).
fn select_w3a_default_survivors(trials: &[WalkForwardResult]) -> Vec<WalkForwardResult> {
    let criteria = SurvivorCriteria::default();
    trials
        .iter()
        .filter(|r| survives(r, &criteria))
        .cloned()
        .collect()
}

/// Build the union pool, deduping by `(source_db, trial_id)` so a
/// single trial that qualifies through multiple selection paths
/// (e.g. W3a Top-N AND W3a Default-Survivor) appears only once.
fn build_union_pool(
    tpe_filtered: Vec<WalkForwardResult>,
    w3a_top: Vec<WalkForwardResult>,
    w3a_default: Vec<WalkForwardResult>,
) -> Vec<PoolEntry> {
    let mut seen: HashSet<(String, u32)> = HashSet::new();
    let mut pool: Vec<PoolEntry> = Vec::new();
    for r in tpe_filtered {
        let key = (TPE_SOURCE_LABEL.to_string(), r.trial_id);
        if seen.insert(key) {
            pool.push(PoolEntry {
                source_db: TPE_SOURCE_LABEL.to_string(),
                result: r,
            });
        }
    }
    for r in w3a_top.into_iter().chain(w3a_default) {
        let key = (W3A_SOURCE_LABEL.to_string(), r.trial_id);
        if seen.insert(key) {
            pool.push(PoolEntry {
                source_db: W3A_SOURCE_LABEL.to_string(),
                result: r,
            });
        }
    }
    pool
}

// ─── Per-trial DSR mapping ──────────────────────────────────────────────────

/// Sanitize a single non-finite reading to `0.0`. Same convention
/// used in `stat_gates::calculate_pbo` and `walk_forward::sanitize_pf`.
fn finite_or_zero(v: f64) -> f64 {
    if v.is_finite() {
        v
    } else {
        0.0
    }
}

/// Extract the per-split validate sharpes from one walk-forward
/// result, sanitizing NaN / ±Inf to `0.0`. Order follows the
/// `splits` Vec which is itself ordered by `split_index`.
fn validate_sharpes(splits: &[WalkForwardSplitResult]) -> Vec<f64> {
    splits
        .iter()
        .map(|s| finite_or_zero(s.validate_metrics.sharpe_ratio))
        .collect()
}

/// Extract per-split validate profit factors with the same
/// sanitization convention.
fn validate_pfs(splits: &[WalkForwardSplitResult]) -> Vec<f64> {
    splits
        .iter()
        .map(|s| finite_or_zero(s.validate_metrics.profit_factor))
        .collect()
}

/// Sample mean of a slice of finite `f64`. Returns `0.0` for the
/// empty slice (caller responsibility to avoid).
fn sample_mean(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.iter().sum::<f64>() / values.len() as f64
}

/// Sample variance (population estimator with `1/n`). Pure helper
/// used to compose skew + raw kurtosis below.
fn sample_variance(values: &[f64], mean: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / values.len() as f64
}

/// Fisher-Pearson sample skewness — the third standardized central
/// moment, normalised by the population variance. Returns `0.0`
/// when variance is non-positive (delta distribution).
fn sample_skew(values: &[f64]) -> f64 {
    let mean = sample_mean(values);
    let var = sample_variance(values, mean);
    if var <= 0.0 {
        return 0.0;
    }
    let n = values.len() as f64;
    let m3 = values.iter().map(|x| (x - mean).powi(3)).sum::<f64>() / n;
    m3 / var.powf(1.5)
}

/// **Raw** (non-excess) sample kurtosis — fourth standardized
/// central moment. Floor at `1.0` (the impossibility lower bound for
/// any real distribution); `0.0` variance returns `3.0`
/// (normal-distribution reference, the conservative choice for
/// downstream DSR variance correction).
fn sample_kurtosis_raw(values: &[f64]) -> f64 {
    let mean = sample_mean(values);
    let var = sample_variance(values, mean);
    if var <= 0.0 {
        return 3.0;
    }
    let n = values.len() as f64;
    let m4 = values.iter().map(|x| (x - mean).powi(4)).sum::<f64>() / n;
    let kurt = m4 / (var * var);
    kurt.max(1.0)
}

/// Standard deviation of `values` (population estimator with `1/n`).
fn sample_std(values: &[f64]) -> f64 {
    let mean = sample_mean(values);
    sample_variance(values, mean).sqrt()
}

// ─── Output schema ──────────────────────────────────────────────────────────

const STAT_GATES_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS stat_gates_pool (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL UNIQUE,
    pool_size       INTEGER NOT NULL,
    pbo_score       REAL NOT NULL,
    pbo_robustness  TEXT NOT NULL,
    n_combinations  INTEGER NOT NULL,
    seed            INTEGER NOT NULL,
    created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS stat_gates_trial (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    pool_id             INTEGER NOT NULL,
    source_db           TEXT NOT NULL,
    trial_id            INTEGER NOT NULL,
    mean_oos_pf         REAL NOT NULL,
    std_oos_pf          REAL NOT NULL,
    worst_oos_pf        REAL NOT NULL,
    mean_oos_sharpe     REAL NOT NULL,
    std_oos_sharpe      REAL NOT NULL,
    sample_skew         REAL NOT NULL,
    sample_kurtosis     REAL NOT NULL,
    n_observations      INTEGER NOT NULL,
    dsr_score           REAL NOT NULL,
    dsr_z_star          REAL NOT NULL,
    dsr_e_max_h0        REAL NOT NULL,
    dsr_robustness      TEXT NOT NULL,
    created_at          TEXT NOT NULL,
    FOREIGN KEY (pool_id) REFERENCES stat_gates_pool(id)
);

CREATE INDEX IF NOT EXISTS stat_gates_trial_pool_dsr_idx
    ON stat_gates_trial(pool_id, dsr_score DESC);
"#;

fn ensure_output_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(STAT_GATES_SCHEMA)
        .context("apply stat_gates schema")?;
    Ok(())
}

// ─── Per-trial row & CSV writer ─────────────────────────────────────────────

/// One row of the union-pool CSV / SQLite output. Holds everything
/// needed to write the CSV header + body in a single pass and to
/// insert one `stat_gates_trial` row in the same loop.
#[derive(Debug, Clone)]
struct TrialRow {
    source_db: String,
    trial_id: u32,
    mean_oos_pf: f64,
    std_oos_pf: f64,
    worst_oos_pf: f64,
    mean_oos_sharpe: f64,
    std_oos_sharpe: f64,
    sample_skew: f64,
    sample_kurtosis_raw: f64,
    n_observations: usize,
    dsr: DsrResult,
}

fn build_trial_rows(pool: &[PoolEntry], n_trials: usize) -> Result<Vec<TrialRow>> {
    let mut rows = Vec::with_capacity(pool.len());
    for entry in pool {
        let sharpes = validate_sharpes(&entry.result.splits);
        if sharpes.len() < 2 {
            bail!(
                "trial {} from {} has only {} splits; DSR requires ≥ 2",
                entry.result.trial_id,
                entry.source_db,
                sharpes.len(),
            );
        }
        let mean_sharpe = sample_mean(&sharpes);
        let std_sharpe = sample_std(&sharpes);
        let skew = sample_skew(&sharpes);
        let kurtosis_raw = sample_kurtosis_raw(&sharpes);
        let n_obs = sharpes.len();
        let dsr = calculate_dsr(&DsrInput {
            trial_sharpe: mean_sharpe,
            n_trials,
            skew,
            kurtosis: kurtosis_raw,
            n_observations: n_obs,
        })
        .with_context(|| {
            format!(
                "calculate_dsr trial {} ({})",
                entry.result.trial_id, entry.source_db,
            )
        })?;
        rows.push(TrialRow {
            source_db: entry.source_db.clone(),
            trial_id: entry.result.trial_id,
            mean_oos_pf: entry.result.mean_oos_pf,
            std_oos_pf: entry.result.std_oos_pf,
            worst_oos_pf: entry.result.worst_oos_pf,
            mean_oos_sharpe: mean_sharpe,
            std_oos_sharpe: std_sharpe,
            sample_skew: skew,
            sample_kurtosis_raw: kurtosis_raw,
            n_observations: n_obs,
            dsr,
        });
    }
    Ok(rows)
}

fn dsr_robustness_label(r: DsrRobustness) -> &'static str {
    match r {
        DsrRobustness::Robust => "robust",
        DsrRobustness::Marginal => "marginal",
        DsrRobustness::Weak => "weak",
    }
}

fn pbo_robustness_label(r: PboRobustness) -> &'static str {
    match r {
        PboRobustness::Robust => "robust",
        PboRobustness::Marginal => "marginal",
        PboRobustness::Weak => "weak",
    }
}

fn write_union_pool_csv(path: &Path, pool_pbo: &PboResult, rows: &[TrialRow]) -> Result<()> {
    let mut file = File::create(path).with_context(|| format!("create CSV {}", path.display()))?;
    writeln!(
        file,
        "rank,source_db,trial_id,mean_oos_pf,std_oos_pf,worst_oos_pf,\
         mean_oos_sharpe,std_oos_sharpe,sample_skew,sample_kurtosis_raw,\
         n_observations,pbo_pool_score,pbo_pool_robustness,\
         dsr_score,dsr_z_star,dsr_e_max_h0,dsr_robustness"
    )?;
    let pbo_label = pbo_robustness_label(pool_pbo.robustness_indicator);
    let mut ranked: Vec<&TrialRow> = rows.iter().collect();
    ranked.sort_by(|a, b| {
        b.dsr
            .dsr_score
            .partial_cmp(&a.dsr.dsr_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    for (i, r) in ranked.iter().enumerate() {
        writeln!(
            file,
            "{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
            i + 1,
            r.source_db,
            r.trial_id,
            r.mean_oos_pf,
            r.std_oos_pf,
            r.worst_oos_pf,
            r.mean_oos_sharpe,
            r.std_oos_sharpe,
            r.sample_skew,
            r.sample_kurtosis_raw,
            r.n_observations,
            pool_pbo.pbo_score,
            pbo_label,
            r.dsr.dsr_score,
            r.dsr.z_star,
            r.dsr.expected_max_sharpe_under_h0,
            dsr_robustness_label(r.dsr.robustness_indicator),
        )?;
    }
    Ok(())
}

// ─── SQLite output ──────────────────────────────────────────────────────────

fn persist_results(
    conn: &Connection,
    pool_name: &str,
    seed: u64,
    pool_pbo: &PboResult,
    rows: &[TrialRow],
) -> Result<i64> {
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO stat_gates_pool \
         (name, pool_size, pbo_score, pbo_robustness, n_combinations, seed, created_at) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            pool_name,
            rows.len() as i64,
            pool_pbo.pbo_score,
            pbo_robustness_label(pool_pbo.robustness_indicator),
            pool_pbo.n_combinations as i64,
            seed as i64,
            now,
        ],
    )
    .with_context(|| format!("insert stat_gates_pool '{}'", pool_name))?;
    let pool_id = conn.last_insert_rowid();
    for r in rows {
        conn.execute(
            "INSERT INTO stat_gates_trial \
             (pool_id, source_db, trial_id, mean_oos_pf, std_oos_pf, worst_oos_pf, \
              mean_oos_sharpe, std_oos_sharpe, sample_skew, sample_kurtosis, n_observations, \
              dsr_score, dsr_z_star, dsr_e_max_h0, dsr_robustness, created_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
            params![
                pool_id,
                r.source_db,
                r.trial_id as i64,
                r.mean_oos_pf,
                r.std_oos_pf,
                r.worst_oos_pf,
                r.mean_oos_sharpe,
                r.std_oos_sharpe,
                r.sample_skew,
                r.sample_kurtosis_raw,
                r.n_observations as i64,
                r.dsr.dsr_score,
                r.dsr.z_star,
                r.dsr.expected_max_sharpe_under_h0,
                dsr_robustness_label(r.dsr.robustness_indicator),
                Utc::now().to_rfc3339(),
            ],
        )
        .with_context(|| format!("insert stat_gates_trial {}/{}", r.source_db, r.trial_id))?;
    }
    Ok(pool_id)
}

// ─── Console summary ────────────────────────────────────────────────────────

fn print_top_table(label: &str, rows: &[&TrialRow]) {
    println!();
    println!("{}", label);
    println!(
        " rank source trial_id  mean_oos_pf  std_oos_pf  worst_oos_pf  mean_oos_sharpe  dsr_score  z_star  robustness"
    );
    for (i, r) in rows.iter().enumerate() {
        println!(
            "  {:>3}  {:<4}  {:>7}    {:>7.4}     {:>6.3}      {:>6.3}        {:>7.4}      {:>6.4}  {:>+6.3}   {}",
            i + 1,
            r.source_db,
            r.trial_id,
            r.mean_oos_pf,
            r.std_oos_pf,
            r.worst_oos_pf,
            r.mean_oos_sharpe,
            r.dsr.dsr_score,
            r.dsr.z_star,
            dsr_robustness_label(r.dsr.robustness_indicator),
        );
    }
}

fn print_summary(pool_pbo: &PboResult, rows: &[TrialRow]) {
    let n_dsr_robust = rows
        .iter()
        .filter(|r| r.dsr.robustness_indicator == DsrRobustness::Robust)
        .count();
    let n_dsr_marginal = rows
        .iter()
        .filter(|r| r.dsr.robustness_indicator == DsrRobustness::Marginal)
        .count();
    let n_dsr_weak = rows
        .iter()
        .filter(|r| r.dsr.robustness_indicator == DsrRobustness::Weak)
        .count();
    println!();
    println!(
        "Pool PBO score: {:.4}  (n_combinations = {})  ⇒  {}",
        pool_pbo.pbo_score,
        pool_pbo.n_combinations,
        pbo_robustness_label(pool_pbo.robustness_indicator),
    );
    println!(
        "DSR composition: {} robust (> 0.95),  {} marginal (0.70-0.95),  {} weak (< 0.70)",
        n_dsr_robust, n_dsr_marginal, n_dsr_weak,
    );
    let mut ranked: Vec<&TrialRow> = rows.iter().collect();
    ranked.sort_by(|a, b| {
        b.dsr
            .dsr_score
            .partial_cmp(&a.dsr.dsr_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let top10: Vec<&TrialRow> = ranked.iter().take(10).copied().collect();
    print_top_table("Top-10 by DSR:", &top10);
}

// ─── Main ───────────────────────────────────────────────────────────────────

fn main() -> Result<()> {
    let args = parse_args()?;

    let strategy = StrategyKind::Ichimoku;
    println!(
        "[stat-gates] loading TPE from {} and W3a from {}",
        args.tpe_db.display(),
        args.w3a_db.display(),
    );
    let tpe_all = load_all_wf_results(&args.tpe_db, strategy)?;
    let w3a_all = load_all_wf_results(&args.w3a_db, strategy)?;
    println!(
        "[stat-gates] loaded {} TPE trials, {} W3a trials",
        tpe_all.len(),
        w3a_all.len(),
    );

    let tpe_filtered = filter_pfad_a(
        &tpe_all,
        args.pfad_a_min_mean_oos_pf,
        args.pfad_a_min_worst_oos_pf,
    );
    println!(
        "[stat-gates] TPE Pfad-A filter: {} / {} trials \
         (mean_oos_pf ≥ {:.2} AND worst_oos_pf ≥ {:.2})",
        tpe_filtered.len(),
        tpe_all.len(),
        args.pfad_a_min_mean_oos_pf,
        args.pfad_a_min_worst_oos_pf,
    );

    let w3a_top = if args.include_w3a_top_n > 0 {
        select_w3a_top_n(&w3a_all, args.include_w3a_top_n)
    } else {
        Vec::new()
    };
    let w3a_default = if args.include_w3a_default_survivors {
        select_w3a_default_survivors(&w3a_all)
    } else {
        Vec::new()
    };
    println!(
        "[stat-gates] W3a forced-include: top-{} ({} trials) + default-survivors ({} trials)",
        args.include_w3a_top_n,
        w3a_top.len(),
        w3a_default.len(),
    );

    let pool = build_union_pool(tpe_filtered, w3a_top, w3a_default);
    let n_tpe = pool
        .iter()
        .filter(|p| p.source_db == TPE_SOURCE_LABEL)
        .count();
    let n_w3a = pool
        .iter()
        .filter(|p| p.source_db == W3A_SOURCE_LABEL)
        .count();
    println!(
        "[stat-gates] union pool: {} trials  ({} TPE + {} W3a)",
        pool.len(),
        n_tpe,
        n_w3a,
    );

    if pool.len() < 30 {
        bail!(
            "ESCALATION: union pool size {} < 30 — statistical gates would not be \
             aussagekräftig. Loosen --pfad-a-min-mean-oos-pf / --pfad-a-min-worst-oos-pf \
             before retry or rerun the TPE production batch.",
            pool.len(),
        );
    }

    // PBO matrix — per-trial per-split validate profit factors.
    let n_splits = pool[0].result.splits.len();
    for (i, p) in pool.iter().enumerate() {
        if p.result.splits.len() != n_splits {
            bail!(
                "pool entry {} ({}/{}) has {} splits, expected {}",
                i,
                p.source_db,
                p.result.trial_id,
                p.result.splits.len(),
                n_splits,
            );
        }
    }
    let matrix: Vec<Vec<f64>> = pool
        .iter()
        .map(|p| validate_pfs(&p.result.splits))
        .collect();
    let pool_pbo = calculate_pbo(&PboInput {
        matrix,
        n_splits_per_side: args.pbo_splits_per_side,
    })
    .context("calculate_pbo on union pool")?;
    println!(
        "[stat-gates] PBO: n_splits={}, n_splits_per_side={} ⇒ {} CSCV partitions",
        n_splits, args.pbo_splits_per_side, pool_pbo.n_combinations,
    );

    let rows = build_trial_rows(&pool, pool.len())?;

    if let Some(parent) = args.output_csv.parent() {
        if !parent.as_os_str().is_empty() {
            create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
        }
    }
    write_union_pool_csv(&args.output_csv, &pool_pbo, &rows)?;
    println!("[stat-gates] wrote CSV {}", args.output_csv.display());

    if let Some(parent) = args.output_db.parent() {
        if !parent.as_os_str().is_empty() {
            create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
        }
    }
    let conn = Connection::open(&args.output_db)
        .with_context(|| format!("open --output-db {}", args.output_db.display()))?;
    ensure_output_schema(&conn)?;
    let pool_name = format!("union_pool_ichimoku_w4_seed{}_{}", args.seed, REPLAY_DATE,);
    let pool_id = persist_results(&conn, &pool_name, args.seed, &pool_pbo, &rows)?;
    println!(
        "[stat-gates] persisted pool '{}' (id={}) + {} per-trial rows to {}",
        pool_name,
        pool_id,
        rows.len(),
        args.output_db.display(),
    );

    print_summary(&pool_pbo, &rows);

    if let Some(p) = &args.candles_path {
        // Reserved-flag echo so log readers can audit what the user
        // intended; no candle file IO happens in this CLI.
        println!(
            "[stat-gates] --candles {} accepted (reserved; not consumed in W4-2)",
            p.display(),
        );
    }

    println!();
    println!(
        "Finished at {} (replay_date={})",
        Utc::now().to_rfc3339(),
        REPLAY_DATE,
    );
    Ok(())
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;
    use trading_engine::optimizer::{TrialMetrics, TrialParams, WalkForwardSplitResult};

    // ── Fixtures ────────────────────────────────────────────────────────

    fn split(idx: usize, validate_pf: f64, validate_sharpe: f64) -> WalkForwardSplitResult {
        WalkForwardSplitResult {
            split_index: idx,
            train_metrics: TrialMetrics {
                total_trades: 20,
                total_pnl: 0.0,
                win_rate: 50.0,
                sharpe_ratio: 0.0,
                max_drawdown_pct: 5.0,
                profit_factor: 1.0,
                final_equity: 10_000.0,
            },
            validate_metrics: TrialMetrics {
                total_trades: 15,
                total_pnl: 100.0,
                win_rate: 55.0,
                sharpe_ratio: validate_sharpe,
                max_drawdown_pct: 4.0,
                profit_factor: validate_pf,
                final_equity: 10_100.0,
            },
        }
    }

    fn synth_wf(trial_id: u32, pfs: &[f64], sharpes: &[f64], agg: f64) -> WalkForwardResult {
        assert_eq!(pfs.len(), sharpes.len());
        let splits: Vec<WalkForwardSplitResult> = pfs
            .iter()
            .zip(sharpes.iter())
            .enumerate()
            .map(|(i, (&pf, &s))| split(i, pf, s))
            .collect();
        let mean_pf = pfs.iter().copied().sum::<f64>() / pfs.len() as f64;
        WalkForwardResult {
            trial_id,
            params: TrialParams::new(),
            splits,
            aggregated_score: agg,
            mean_oos_pf: mean_pf,
            std_oos_pf: 0.0,
            worst_oos_pf: pfs.iter().copied().fold(f64::INFINITY, f64::min),
            mean_is_pf: 1.0,
            is_oos_decay: 0.0,
        }
    }

    fn seed_w3a_like_db(db_path: &Path) {
        let storage = StudyStorage::open(db_path).unwrap();
        let id = storage
            .create_study("seed_w3a", StrategyKind::Ichimoku.as_str(), "yaml")
            .unwrap();
        // 3 trials with varying mean/worst so the default-survivor
        // filter selects exactly the third one (mirrors Trial 688 in
        // the production W3a study).
        let cfg = trading_engine::optimizer::WalkForwardConfig::ichimoku_default();
        let lo = synth_wf(0, &[0.5, 0.5, 0.5, 0.5, 0.5, 0.5], &[0.0; 6], 0.4);
        let mid = synth_wf(1, &[1.2, 1.2, 1.2, 1.2, 1.2, 1.2], &[0.5; 6], 1.0);
        let hi = synth_wf(
            2,
            &[2.5, 2.0, 1.8, 1.5, 1.2, 0.8],
            &[1.5, 1.0, 0.8, 0.5, 0.2, 0.0],
            1.6,
        );
        storage.insert_walk_forward_trial(id, &lo, &cfg).unwrap();
        storage.insert_walk_forward_trial(id, &mid, &cfg).unwrap();
        storage.insert_walk_forward_trial(id, &hi, &cfg).unwrap();
    }

    fn seed_tpe_like_db(db_path: &Path) {
        let storage = StudyStorage::open(db_path).unwrap();
        let id = storage
            .create_study("seed_tpe", StrategyKind::Ichimoku.as_str(), "yaml")
            .unwrap();
        let cfg = trading_engine::optimizer::WalkForwardConfig::ichimoku_default();
        // Two trials: one passing Pfad-A (mean=2.25, worst=1.0),
        // one failing (mean=0.683).
        let pass = synth_wf(
            100,
            &[3.5, 3.0, 2.5, 2.0, 1.5, 1.0],
            &[1.2, 1.0, 0.8, 0.5, 0.3, 0.1],
            2.0,
        );
        let fail = synth_wf(
            101,
            &[1.5, 1.0, 0.8, 0.5, 0.2, 0.1],
            &[0.3, 0.2, 0.1, 0.0, -0.1, -0.2],
            0.5,
        );
        storage.insert_walk_forward_trial(id, &pass, &cfg).unwrap();
        storage.insert_walk_forward_trial(id, &fail, &cfg).unwrap();
    }

    // ── parse_args_from ─────────────────────────────────────────────────

    fn min_args() -> Vec<String> {
        vec![
            "--tpe-db".into(),
            "tpe.db".into(),
            "--w3a-db".into(),
            "w3a.db".into(),
            "--output-csv".into(),
            "out.csv".into(),
            "--output-db".into(),
            "out.db".into(),
        ]
    }

    #[test]
    fn parse_args_minimum_set_uses_documented_defaults() {
        let a = parse_args_from(&min_args()).unwrap();
        assert!((a.pfad_a_min_mean_oos_pf - DEFAULT_PFAD_A_MIN_MEAN_OOS_PF).abs() < 1e-12);
        assert!((a.pfad_a_min_worst_oos_pf - DEFAULT_PFAD_A_MIN_WORST_OOS_PF).abs() < 1e-12);
        assert_eq!(a.pbo_splits_per_side, DEFAULT_PBO_SPLITS_PER_SIDE);
        assert_eq!(a.include_w3a_top_n, DEFAULT_W3A_TOP_N);
        assert!(a.include_w3a_default_survivors);
        assert_eq!(a.seed, DEFAULT_SEED);
        assert!(a.candles_path.is_none());
    }

    #[test]
    fn parse_args_rejects_unknown_flag() {
        let mut raw = min_args();
        raw.extend(["--nope".into(), "value".into()]);
        assert!(parse_args_from(&raw).is_err());
    }

    #[test]
    fn parse_args_w3a_default_survivors_off_disables_pool() {
        let mut raw = min_args();
        raw.extend(["--include-w3a-default-survivors".into(), "off".into()]);
        let a = parse_args_from(&raw).unwrap();
        assert!(!a.include_w3a_default_survivors);
    }

    // ── DB loaders + filters ────────────────────────────────────────────

    #[test]
    fn load_all_wf_results_reads_seeded_w3a_db() {
        let db = NamedTempFile::new().unwrap();
        seed_w3a_like_db(db.path());
        let all = load_all_wf_results(db.path(), StrategyKind::Ichimoku).unwrap();
        assert_eq!(all.len(), 3);
    }

    #[test]
    fn filter_pfad_a_keeps_trials_passing_both_floors() {
        // mean = (3.5+3.0+2.5+2.0+1.5+1.0)/6 = 2.25, worst = 1.0
        let pass = synth_wf(0, &[3.5, 3.0, 2.5, 2.0, 1.5, 1.0], &[0.5; 6], 2.0);
        // mean = 0.683
        let fail_mean = synth_wf(1, &[1.5, 1.0, 0.8, 0.5, 0.2, 0.1], &[0.0; 6], 0.5);
        // mean = 2.52, worst = 0.1
        let fail_worst = synth_wf(2, &[3.0, 3.0, 3.0, 3.0, 3.0, 0.1], &[0.0; 6], 1.5);
        let filtered = filter_pfad_a(&[pass, fail_mean, fail_worst], 2.14, 0.3);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].trial_id, 0);
    }

    #[test]
    fn select_w3a_top_n_returns_highest_aggregated_first() {
        let trials = vec![
            synth_wf(0, &[1.0; 6], &[0.0; 6], 0.5),
            synth_wf(1, &[1.0; 6], &[0.0; 6], 1.5),
            synth_wf(2, &[1.0; 6], &[0.0; 6], 1.0),
        ];
        let top2 = select_w3a_top_n(&trials, 2);
        assert_eq!(top2.len(), 2);
        assert_eq!(top2[0].trial_id, 1);
        assert_eq!(top2[1].trial_id, 2);
    }

    #[test]
    fn select_w3a_default_survivors_matches_default_criteria() {
        let pass = WalkForwardResult {
            trial_id: 0,
            params: TrialParams::new(),
            splits: vec![],
            aggregated_score: 1.5,
            mean_oos_pf: 1.6,
            std_oos_pf: 0.5,
            worst_oos_pf: 0.7,
            mean_is_pf: 1.2,
            is_oos_decay: -0.4,
        };
        let mut fail = pass.clone();
        fail.trial_id = 1;
        fail.worst_oos_pf = 0.5; // below default min 0.6
        let survivors = select_w3a_default_survivors(&[pass, fail]);
        assert_eq!(survivors.len(), 1);
        assert_eq!(survivors[0].trial_id, 0);
    }

    // ── Union-pool dedupe ───────────────────────────────────────────────

    #[test]
    fn build_union_pool_dedupes_w3a_top_and_default_survivors() {
        let r = synth_wf(99, &[2.0; 6], &[0.5; 6], 1.5);
        let pool = build_union_pool(Vec::new(), vec![r.clone()], vec![r]);
        assert_eq!(
            pool.len(),
            1,
            "same W3a trial in both selectors must collapse"
        );
        assert_eq!(pool[0].source_db, W3A_SOURCE_LABEL);
        assert_eq!(pool[0].result.trial_id, 99);
    }

    #[test]
    fn build_union_pool_keeps_collisions_across_distinct_sources() {
        // TPE and W3a happen to both have a trial_id = 5 — they are
        // *different* trials by construction (disjoint parameter
        // spaces) and must both appear in the union.
        let tpe = synth_wf(5, &[2.0; 6], &[1.0; 6], 1.5);
        let w3a = synth_wf(5, &[1.5; 6], &[0.7; 6], 1.0);
        let pool = build_union_pool(vec![tpe], vec![w3a], Vec::new());
        assert_eq!(pool.len(), 2);
    }

    // ── DSR / sample-stat helpers ───────────────────────────────────────

    #[test]
    fn sample_skew_zero_for_symmetric_input() {
        let values = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        assert!(sample_skew(&values).abs() < 1e-12);
    }

    #[test]
    fn sample_kurtosis_returns_three_for_zero_variance_input() {
        // Floor convention: constant input has no defined kurtosis;
        // we return 3.0 (normal-distribution reference) so the
        // downstream DSR variance correction stays well-conditioned.
        let values = vec![2.0; 6];
        assert!((sample_kurtosis_raw(&values) - 3.0).abs() < 1e-12);
    }

    #[test]
    fn sample_kurtosis_above_one_floor_for_real_data() {
        let values = vec![-1.0, 1.0];
        // Bernoulli {±1}: m4 = 1, var² = 1, kurt = 1.
        assert!((sample_kurtosis_raw(&values) - 1.0).abs() < 1e-12);
    }

    // ── build_trial_rows ────────────────────────────────────────────────

    #[test]
    fn build_trial_rows_produces_one_row_per_pool_entry() {
        let entries = vec![
            PoolEntry {
                source_db: TPE_SOURCE_LABEL.into(),
                result: synth_wf(
                    0,
                    &[2.5, 2.2, 1.8, 1.5, 1.2, 1.0],
                    &[1.0, 0.8, 0.6, 0.4, 0.2, 0.0],
                    1.5,
                ),
            },
            PoolEntry {
                source_db: W3A_SOURCE_LABEL.into(),
                result: synth_wf(
                    1,
                    &[1.5, 1.2, 1.0, 1.0, 1.0, 0.8],
                    &[0.3, 0.2, 0.1, 0.1, 0.1, 0.0],
                    1.0,
                ),
            },
        ];
        let rows = build_trial_rows(&entries, 2).unwrap();
        assert_eq!(rows.len(), 2);
        // Both DSR scores must lie in [0, 1].
        for r in &rows {
            assert!(r.dsr.dsr_score >= 0.0 && r.dsr.dsr_score <= 1.0);
        }
        // Mean sharpe agrees with the seeded series.
        let r0_expected = sample_mean(&[1.0, 0.8, 0.6, 0.4, 0.2, 0.0]);
        assert!((rows[0].mean_oos_sharpe - r0_expected).abs() < 1e-12);
    }

    // ── End-to-end on synth DBs ─────────────────────────────────────────

    #[test]
    fn end_to_end_smoke_on_synthetic_dbs_writes_csv_and_db() {
        let tpe = NamedTempFile::new().unwrap();
        let w3a = NamedTempFile::new().unwrap();
        seed_tpe_like_db(tpe.path());
        seed_w3a_like_db(w3a.path());

        let tpe_all = load_all_wf_results(tpe.path(), StrategyKind::Ichimoku).unwrap();
        let w3a_all = load_all_wf_results(w3a.path(), StrategyKind::Ichimoku).unwrap();
        let tpe_filtered = filter_pfad_a(&tpe_all, 2.14, 0.3);
        let w3a_top = select_w3a_top_n(&w3a_all, 3);
        let w3a_default = select_w3a_default_survivors(&w3a_all);

        // Expect: 1 TPE Pfad-A + 3 W3a Top-3, with at most 1 overlap
        // between Top-3 and Default-Survivors on this synthetic DB
        // (Trial 2 passes both gates).
        let pool = build_union_pool(tpe_filtered, w3a_top, w3a_default);
        assert!(pool.len() >= 3, "got pool size {}", pool.len());

        let n_splits = pool[0].result.splits.len();
        let matrix: Vec<Vec<f64>> = pool
            .iter()
            .map(|p| validate_pfs(&p.result.splits))
            .collect();
        // Cap the n_splits_per_side at floor(n_splits/2) — synthetic
        // data uses 6 splits per trial, matching the production
        // walk-forward.
        let pool_pbo = calculate_pbo(&PboInput {
            matrix,
            n_splits_per_side: n_splits / 2,
        })
        .unwrap();
        assert!(pool_pbo.n_combinations > 0);

        let rows = build_trial_rows(&pool, pool.len()).unwrap();

        let csv = NamedTempFile::new().unwrap().into_temp_path();
        write_union_pool_csv(csv.as_ref(), &pool_pbo, &rows).unwrap();
        let content = std::fs::read_to_string(&csv).unwrap();
        let mut lines = content.lines();
        let header = lines.next().unwrap();
        assert!(
            header.starts_with("rank,source_db,trial_id"),
            "got {}",
            header
        );
        let data_lines: Vec<&str> = lines.collect();
        assert_eq!(data_lines.len(), rows.len());

        let db = NamedTempFile::new().unwrap();
        let conn = Connection::open(db.path()).unwrap();
        ensure_output_schema(&conn).unwrap();
        let pool_id = persist_results(&conn, "synth_pool", 42, &pool_pbo, &rows).unwrap();
        assert!(pool_id > 0);
        let n_persisted: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM stat_gates_trial WHERE pool_id = ?1",
                params![pool_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(n_persisted as usize, rows.len());
    }
}
