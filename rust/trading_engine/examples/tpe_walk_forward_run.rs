//! TPE × Walk-Forward production CLI — Phase-3.1 Welle W3.5.
//!
//! Drives a Tree-structured Parzen Estimator over a rolling-window
//! walk-forward objective. The W3a survivor pool from the Welle-W3-3
//! output (`studies-ichimoku-wf-w3a.db`) seeds the TPE history so the
//! first suggestions are already biased toward the validated cluster.
//! Each TPE proposal is scored by `run_walk_forward_trial` under the
//! same Welle-W3a config (train=4392, validate=2196, step=2196,
//! `StabilityScoreMethod::MedianIqr`), and the resulting
//! `WalkForwardResult` is persisted into a fresh output DB.
//!
//! # CLI
//! ```text
//! cargo run --release --example tpe_walk_forward_run -- \
//!   --wf-study     01_Projectplan/optimizer_studies/studies-ichimoku-wf-w3a.db \
//!   --candles      01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
//!   --search-space 01_Projectplan/search_spaces/ichimoku_tpe_w3.yaml \
//!   --n-trials     200 \
//!   --train-bars   4392 --validate-bars 2196 --step-bars 2196 \
//!   --stability-method median --stability-penalty 0.5 \
//!   --warm-start-criteria-min-mean-oos-pf 1.3 \
//!   --warm-start-criteria-max-std-oos-pf 1.5 \
//!   --warm-start-criteria-min-worst-oos-pf 0.3 \
//!   --warm-start-criteria-max-is-oos-decay 0.7 \
//!   --seed 42 \
//!   --output-csv 01_Projectplan/optimizer_studies/tpe_top_ichimoku.csv \
//!   --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-tpe.db
//! ```
//!
//! # Why no `--strategy` flag
//! Phase-3.1 Welle W3.5 targets Ichimoku exclusively (the W3a study and
//! W3 TPE search space are both Ichimoku-specific). Hard-coding the
//! strategy here keeps the CLI surface minimal; a future BB+RSI / UT-Bot
//! TPE run will live in its own example file with its own search-space
//! YAML.
//!
//! # Warm-start fail-fast
//! TPE's KDE degenerates below ~10 qualified samples (Silverman
//! bandwidth collapses, l / g split has too few points). The CLI
//! aborts before the first suggest when the warm-start pool is smaller
//! than `MIN_WARM_START_SURVIVORS = 10`, with a hint to relax the
//! survivor criteria.

use std::fs::{create_dir_all, read_to_string, File};
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{bail, Context, Result};
use chrono::Utc;

use trading_engine::backtest::BacktestConfig;
use trading_engine::models::{Candle, Timeframe};
use trading_engine::optimizer::{
    parse_search_space_str, run_walk_forward_trial, score_constraints_for_strategy, survives,
    ScoreConstraints, SearchSpace, StabilityScoreMethod, StrategyKind, StudyStorage,
    SurvivorCriteria, TpeEngine, TrialMetrics, TrialResult, WalkForwardConfig, WalkForwardResult,
    DEFAULT_GAMMA, DEFAULT_N_EI_CANDIDATES, MIN_HISTORY_FOR_TPE,
};

// ─── Constants ───────────────────────────────────────────────────────────────

const INITIAL_BALANCE: f64 = 10_000.0;
const FEE_RATE: f64 = 0.0006;
const SLIPPAGE_BPS: f64 = 0.0;
const TIMEFRAME: Timeframe = Timeframe::H1;
const DEFAULT_N_TRIALS: u32 = 200;
const DEFAULT_TRAIN_BARS: usize = 4392;
const DEFAULT_VALIDATE_BARS: usize = 2196;
const DEFAULT_STEP_BARS: usize = 2196;
const DEFAULT_STABILITY_PENALTY: f64 = 0.5;
const DEFAULT_TRIM_PCT: f64 = 0.2;
const DEFAULT_SEED: u64 = 42;
const FIRST_TRIAL_SANITY_LIMIT_SECS: f64 = 30.0;
const MIN_WARM_START_SURVIVORS: usize = 10;
const PROGRESS_EVERY: u32 = 10;
const REPLAY_DATE: &str = "2026-05-26";

// ─── CLI args ────────────────────────────────────────────────────────────────

/// CLI selection for the Welle-W3 stability score method — mirrors the
/// walk_forward_replay enum so users see the same flag semantics across
/// both CLIs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StabilityMethodArg {
    Mean,
    Median,
    Trimmed,
}

impl StabilityMethodArg {
    fn parse(s: &str) -> Result<Self> {
        match s {
            "mean" => Ok(Self::Mean),
            "median" => Ok(Self::Median),
            "trimmed" => Ok(Self::Trimmed),
            other => bail!(
                "unknown --stability-method '{}' (expected mean | median | trimmed)",
                other,
            ),
        }
    }

    fn into_method(self, stability_penalty: f64, trim_pct: f64) -> StabilityScoreMethod {
        match self {
            Self::Mean => StabilityScoreMethod::MeanStdPenalty {
                penalty: stability_penalty,
            },
            Self::Median => StabilityScoreMethod::MedianIqr {
                iqr_penalty: stability_penalty,
            },
            Self::Trimmed => StabilityScoreMethod::TrimmedMean { trim_pct },
        }
    }
}

#[derive(Debug, Clone)]
struct CliArgs {
    wf_study: PathBuf,
    candles_path: PathBuf,
    search_space_path: PathBuf,
    n_trials: u32,
    train_bars: usize,
    validate_bars: usize,
    step_bars: usize,
    stability_method: StabilityMethodArg,
    stability_penalty: f64,
    trim_pct: f64,
    warm_start_criteria: SurvivorCriteria,
    tpe_gamma: f64,
    tpe_ei_candidates: usize,
    seed: u64,
    output_csv: PathBuf,
    output_db: PathBuf,
}

fn print_usage() {
    let defaults = SurvivorCriteria::default();
    eprintln!(
        "usage: tpe_walk_forward_run \\\n\
         \t--wf-study <db>         W3a walk-forward DB (warm-start source) \\\n\
         \t--candles <json>        full Welle-O2 candle series \\\n\
         \t--search-space <yaml>   TPE-narrowed search space (e.g. ichimoku_tpe_w3.yaml) \\\n\
         \t[--n-trials N]          TPE trial budget (default {}) \\\n\
         \t[--train-bars N]        training-window bars (default {}) \\\n\
         \t[--validate-bars N]     validate-window bars (default {}) \\\n\
         \t[--step-bars N]         bars per slide (default {}) \\\n\
         \t[--stability-method M]  mean | median | trimmed (default median) \\\n\
         \t[--stability-penalty F] std/iqr penalty (default {}) \\\n\
         \t[--trim-pct F]          tail fraction trimmed (default {}; trimmed only) \\\n\
         \t[--warm-start-criteria-min-mean-oos-pf F]   warm-start floor (default {}) \\\n\
         \t[--warm-start-criteria-max-std-oos-pf F]    warm-start cap (default {}) \\\n\
         \t[--warm-start-criteria-max-is-oos-decay F]  warm-start cap (default {}) \\\n\
         \t[--warm-start-criteria-min-worst-oos-pf F]  warm-start floor (default {}) \\\n\
         \t[--tpe-gamma F]         top-quantile split (default {}) \\\n\
         \t[--tpe-ei-candidates N] EI candidate pool (default {}) \\\n\
         \t[--seed N]              audit seed (default {}) \\\n\
         \t--output-csv <path>     Top-N TPE CSV export \\\n\
         \t--output-db <path>      fresh SQLite for TPE walk-forward rows",
        DEFAULT_N_TRIALS,
        DEFAULT_TRAIN_BARS,
        DEFAULT_VALIDATE_BARS,
        DEFAULT_STEP_BARS,
        DEFAULT_STABILITY_PENALTY,
        DEFAULT_TRIM_PCT,
        defaults.min_mean_oos_pf,
        defaults.max_std_oos_pf,
        defaults.max_is_oos_decay,
        defaults.min_worst_oos_pf,
        DEFAULT_GAMMA,
        DEFAULT_N_EI_CANDIDATES,
        DEFAULT_SEED,
    );
}

fn parse_args() -> Result<CliArgs> {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    parse_args_from(&raw)
}

/// Testable arg parser. Accepts arguments without the program-name
/// element (i.e. what `std::env::args().skip(1)` produces).
fn parse_args_from(raw: &[String]) -> Result<CliArgs> {
    if raw.is_empty() || raw.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        bail!("missing required arguments");
    }

    let mut wf_study: Option<PathBuf> = None;
    let mut candles_path: Option<PathBuf> = None;
    let mut search_space_path: Option<PathBuf> = None;
    let mut n_trials: u32 = DEFAULT_N_TRIALS;
    let mut train_bars: usize = DEFAULT_TRAIN_BARS;
    let mut validate_bars: usize = DEFAULT_VALIDATE_BARS;
    let mut step_bars: usize = DEFAULT_STEP_BARS;
    let mut stability_method = StabilityMethodArg::Median;
    let mut stability_penalty: f64 = DEFAULT_STABILITY_PENALTY;
    let mut trim_pct: f64 = DEFAULT_TRIM_PCT;
    let mut warm_start_criteria = SurvivorCriteria::default();
    let mut tpe_gamma = DEFAULT_GAMMA;
    let mut tpe_ei_candidates = DEFAULT_N_EI_CANDIDATES;
    let mut seed: u64 = DEFAULT_SEED;
    let mut output_csv: Option<PathBuf> = None;
    let mut output_db: Option<PathBuf> = None;

    let mut i = 0;
    while i < raw.len() {
        let key = raw[i].as_str();
        let val = raw.get(i + 1).map(String::as_str);
        let need =
            || -> Result<&str> { val.with_context(|| format!("flag '{}' requires a value", key)) };
        match key {
            "--wf-study" => wf_study = Some(PathBuf::from(need()?)),
            "--candles" => candles_path = Some(PathBuf::from(need()?)),
            "--search-space" => search_space_path = Some(PathBuf::from(need()?)),
            "--n-trials" => n_trials = need()?.parse().with_context(|| "--n-trials must be u32")?,
            "--train-bars" => {
                train_bars = need()?
                    .parse()
                    .with_context(|| "--train-bars must be usize")?
            }
            "--validate-bars" => {
                validate_bars = need()?
                    .parse()
                    .with_context(|| "--validate-bars must be usize")?
            }
            "--step-bars" => {
                step_bars = need()?
                    .parse()
                    .with_context(|| "--step-bars must be usize")?
            }
            "--stability-method" => stability_method = StabilityMethodArg::parse(need()?)?,
            "--stability-penalty" => {
                stability_penalty = need()?
                    .parse()
                    .with_context(|| "--stability-penalty must be f64")?
            }
            "--trim-pct" => trim_pct = need()?.parse().with_context(|| "--trim-pct must be f64")?,
            "--warm-start-criteria-min-mean-oos-pf" => {
                warm_start_criteria.min_mean_oos_pf = need()?
                    .parse()
                    .with_context(|| "--warm-start-criteria-min-mean-oos-pf must be f64")?
            }
            "--warm-start-criteria-max-std-oos-pf" => {
                warm_start_criteria.max_std_oos_pf = need()?
                    .parse()
                    .with_context(|| "--warm-start-criteria-max-std-oos-pf must be f64")?
            }
            "--warm-start-criteria-max-is-oos-decay" => {
                warm_start_criteria.max_is_oos_decay = need()?
                    .parse()
                    .with_context(|| "--warm-start-criteria-max-is-oos-decay must be f64")?
            }
            "--warm-start-criteria-min-worst-oos-pf" => {
                warm_start_criteria.min_worst_oos_pf = need()?
                    .parse()
                    .with_context(|| "--warm-start-criteria-min-worst-oos-pf must be f64")?
            }
            "--tpe-gamma" => {
                tpe_gamma = need()?.parse().with_context(|| "--tpe-gamma must be f64")?
            }
            "--tpe-ei-candidates" => {
                tpe_ei_candidates = need()?
                    .parse()
                    .with_context(|| "--tpe-ei-candidates must be usize")?
            }
            "--seed" => seed = need()?.parse().with_context(|| "--seed must be u64")?,
            "--output-csv" => output_csv = Some(PathBuf::from(need()?)),
            "--output-db" => output_db = Some(PathBuf::from(need()?)),
            other => bail!("unknown flag '{}'", other),
        }
        i += 2;
    }

    if !(0.0..0.5).contains(&trim_pct) {
        bail!(
            "--trim-pct must be in [0.0, 0.5) (got {}); higher values would trim every value",
            trim_pct,
        );
    }
    if !(0.0 < tpe_gamma && tpe_gamma < 1.0) {
        bail!("--tpe-gamma must be in (0.0, 1.0) (got {})", tpe_gamma);
    }
    if tpe_ei_candidates == 0 {
        bail!("--tpe-ei-candidates must be > 0");
    }

    Ok(CliArgs {
        wf_study: wf_study.context("--wf-study is required")?,
        candles_path: candles_path.context("--candles is required")?,
        search_space_path: search_space_path.context("--search-space is required")?,
        n_trials,
        train_bars,
        validate_bars,
        step_bars,
        stability_method,
        stability_penalty,
        trim_pct,
        warm_start_criteria,
        tpe_gamma,
        tpe_ei_candidates,
        seed,
        output_csv: output_csv.context("--output-csv is required")?,
        output_db: output_db.context("--output-db is required")?,
    })
}

// ─── IO helpers ──────────────────────────────────────────────────────────────

fn load_candles(path: &Path) -> Result<Vec<Candle>> {
    let file = File::open(path).with_context(|| format!("open candles {}", path.display()))?;
    let candles: Vec<Candle> = serde_json::from_reader(BufReader::new(file))
        .with_context(|| format!("parse candles {}", path.display()))?;
    Ok(candles)
}

/// Pull every walk_forward_trial row from `wf_study` for the most-recent
/// study (highest id) matching `strategy`.
fn load_wf_trials(wf_study: &Path, strategy: StrategyKind) -> Result<Vec<WalkForwardResult>> {
    let storage = StudyStorage::open(wf_study)
        .with_context(|| format!("open --wf-study {}", wf_study.display()))?;
    let studies = storage.list_studies()?;
    let target = studies
        .iter()
        .filter(|s| s.strategy == strategy.as_str())
        .max_by_key(|s| s.id)
        .with_context(|| {
            format!(
                "no '{}' study in --wf-study {}",
                strategy.as_str(),
                wf_study.display()
            )
        })?;
    let count = storage.count_walk_forward_trials(target.id)? as usize;
    if count == 0 {
        bail!(
            "study '{}' (id={}) has zero walk_forward_trials rows",
            target.name,
            target.id,
        );
    }
    storage.top_n_walk_forward(target.id, count)
}

/// Convert a `WalkForwardResult` into a `TrialResult` for TPE
/// consumption. `score = aggregated_score`; `metrics` carries a zero
/// stub (TPE only reads `score` and `params`).
fn wf_to_trial_result(wf: &WalkForwardResult) -> TrialResult {
    TrialResult {
        trial_id: wf.trial_id,
        params: wf.params.clone(),
        metrics: TrialMetrics {
            total_trades: 0,
            total_pnl: 0.0,
            win_rate: 0.0,
            sharpe_ratio: 0.0,
            max_drawdown_pct: 0.0,
            profit_factor: 0.0,
            final_equity: 0.0,
        },
        score: wf.aggregated_score,
    }
}

// ─── CSV writer ──────────────────────────────────────────────────────────────

fn write_tpe_csv(results: &[WalkForwardResult], path: &Path) -> Result<()> {
    let mut file = File::create(path).with_context(|| format!("create CSV {}", path.display()))?;
    let mut param_keys: Vec<&String> = results
        .first()
        .map(|r| r.params.values.keys().collect())
        .unwrap_or_default();
    param_keys.sort();
    write!(
        file,
        "rank,trial_id,aggregated_score,mean_oos_pf,std_oos_pf,worst_oos_pf,\
         mean_is_pf,is_oos_decay,n_splits"
    )?;
    for k in &param_keys {
        write!(file, ",p_{}", k)?;
    }
    writeln!(file)?;

    for (i, r) in results.iter().enumerate() {
        write!(
            file,
            "{},{},{},{},{},{},{},{},{}",
            i + 1,
            r.trial_id,
            r.aggregated_score,
            r.mean_oos_pf,
            r.std_oos_pf,
            r.worst_oos_pf,
            r.mean_is_pf,
            r.is_oos_decay,
            r.splits.len(),
        )?;
        for k in &param_keys {
            let v = r.params.values.get(*k).copied().unwrap_or(f64::NAN);
            write!(file, ",{}", v)?;
        }
        writeln!(file)?;
    }
    Ok(())
}

// ─── Format helpers ──────────────────────────────────────────────────────────

fn fmt_duration_secs(secs: f64) -> String {
    let total = secs.round() as i64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    if h > 0 {
        format!("{:>2}h{:02}m{:02}s", h, m, s)
    } else if m > 0 {
        format!("{:>2}m{:02}s", m, s)
    } else {
        format!("{:>2}s", s)
    }
}

// ─── Core loop ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
struct TpeRunConfig {
    n_trials: u32,
    seed: u64,
    tpe_gamma: f64,
    tpe_ei_candidates: usize,
    /// `Some(secs)` to abort if the first trial exceeds the wall-clock
    /// budget — `None` skips the sanity check (used by tests on
    /// fixtures where compute is sub-second anyway).
    sanity_limit_secs: Option<f64>,
    /// `true` enables the periodic progress print — set `false` in
    /// tests to keep CI output clean.
    print_progress: bool,
}

#[derive(Debug)]
struct TpeRunSummary {
    trials_persisted: usize,
    best_aggregated_score: f64,
    best_trial_index: u32,
    sanity_secs: f64,
    batch_secs: f64,
}

/// Drive the TPE × walk-forward loop end-to-end, persisting every
/// `WalkForwardResult` into `output_storage` under `study_id`. Pure
/// over the inputs — no env / fs access beyond `output_storage`.
#[allow(clippy::too_many_arguments)]
fn run_tpe_walk_forward(
    candles: &[Candle],
    warm_start: Vec<WalkForwardResult>,
    space: &SearchSpace,
    wf_config: &WalkForwardConfig,
    base_config: BacktestConfig,
    constraints: &ScoreConstraints,
    output_storage: &mut StudyStorage,
    study_id: i64,
    cfg: TpeRunConfig,
) -> Result<TpeRunSummary> {
    if warm_start.len() < MIN_WARM_START_SURVIVORS {
        bail!(
            "ESCALATION: warm-start pool only {} trials — needs ≥ {} so TPE's KDE \
             does not degenerate. Loosen --warm-start-criteria-* flags before retry.",
            warm_start.len(),
            MIN_WARM_START_SURVIVORS,
        );
    }
    if cfg.n_trials == 0 {
        bail!("--n-trials must be > 0");
    }

    let warm_start_history: Vec<TrialResult> = warm_start.iter().map(wf_to_trial_result).collect();

    let mut engine = TpeEngine::new(cfg.seed)
        .with_gamma(cfg.tpe_gamma)
        .with_n_ei_candidates(cfg.tpe_ei_candidates);
    engine.warm_start(warm_start_history);

    // ─── Sanity: first trial in isolation ────────────────────────────────
    let first_params = engine.suggest(space);
    let sanity_start = Instant::now();
    let first_result = run_walk_forward_trial(
        StrategyKind::Ichimoku,
        0,
        first_params.clone(),
        candles,
        wf_config,
        base_config.clone(),
        constraints,
    )
    .with_context(|| "TPE sanity (first trial) failed")?;
    let sanity_secs = sanity_start.elapsed().as_secs_f64();
    if let Some(limit) = cfg.sanity_limit_secs {
        if sanity_secs > limit {
            bail!(
                "ESCALATION: first TPE trial wall-clock {:.1}s exceeds limit {:.1}s — \
                 {}-trial budget would blow ~{:.1}h. Check engine performance before retry.",
                sanity_secs,
                limit,
                cfg.n_trials,
                sanity_secs * cfg.n_trials as f64 / 3600.0,
            );
        }
    }
    output_storage.insert_walk_forward_trial(study_id, &first_result, wf_config)?;
    engine.report(TrialResult {
        trial_id: 0,
        params: first_params,
        metrics: zero_metrics(),
        score: first_result.aggregated_score,
    });

    let mut best = first_result.aggregated_score;
    let mut best_index: u32 = 0;
    if cfg.print_progress {
        println!(
            "[tpe-wf] sanity ok: trial 0/{}, agg={:.4}, mean_oos={:.3}, std_oos={:.3}, worst_oos={:.3} ({:.1}s)",
            cfg.n_trials,
            first_result.aggregated_score,
            first_result.mean_oos_pf,
            first_result.std_oos_pf,
            first_result.worst_oos_pf,
            sanity_secs,
        );
    }

    // ─── Batch loop ──────────────────────────────────────────────────────
    let batch_start = Instant::now();
    for i in 1..cfg.n_trials {
        let params = engine.suggest(space);
        let result = run_walk_forward_trial(
            StrategyKind::Ichimoku,
            i,
            params.clone(),
            candles,
            wf_config,
            base_config.clone(),
            constraints,
        )
        .with_context(|| format!("TPE trial {}/{} failed", i, cfg.n_trials))?;
        output_storage.insert_walk_forward_trial(study_id, &result, wf_config)?;
        if result.aggregated_score > best {
            best = result.aggregated_score;
            best_index = i;
        }
        engine.report(TrialResult {
            trial_id: i,
            params,
            metrics: zero_metrics(),
            score: result.aggregated_score,
        });

        let done = i + 1;
        let final_tick = done == cfg.n_trials;
        if cfg.print_progress && (done % PROGRESS_EVERY == 0 || final_tick) {
            let elapsed = batch_start.elapsed().as_secs_f64();
            let per_trial = elapsed / i as f64;
            let remaining = (cfg.n_trials - done) as f64 * per_trial;
            println!(
                "[tpe-wf] progress {}/{}  elapsed={}  eta={}  best={:.4}  (~{:.1}s/trial)",
                done,
                cfg.n_trials,
                fmt_duration_secs(elapsed),
                fmt_duration_secs(remaining),
                best,
                per_trial,
            );
        }
    }
    let batch_secs = batch_start.elapsed().as_secs_f64();

    let trials_persisted = output_storage.count_walk_forward_trials(study_id)? as usize;
    if trials_persisted != cfg.n_trials as usize {
        bail!(
            "persistence audit: expected {} rows, found {} in walk_forward_trials",
            cfg.n_trials,
            trials_persisted,
        );
    }

    Ok(TpeRunSummary {
        trials_persisted,
        best_aggregated_score: best,
        best_trial_index: best_index,
        sanity_secs,
        batch_secs,
    })
}

fn zero_metrics() -> TrialMetrics {
    TrialMetrics {
        total_trades: 0,
        total_pnl: 0.0,
        win_rate: 0.0,
        sharpe_ratio: 0.0,
        max_drawdown_pct: 0.0,
        profit_factor: 0.0,
        final_equity: 0.0,
    }
}

// ─── Main ────────────────────────────────────────────────────────────────────

fn main() -> Result<()> {
    let args = parse_args()?;

    let base_config = BacktestConfig {
        initial_balance: INITIAL_BALANCE,
        fee_rate: FEE_RATE,
        timeframe: TIMEFRAME,
        slippage_bps: SLIPPAGE_BPS,
    };
    let constraints = score_constraints_for_strategy(StrategyKind::Ichimoku);
    let wf_config = WalkForwardConfig {
        train_bars: args.train_bars,
        validate_bars: args.validate_bars,
        step_bars: args.step_bars,
        stability_penalty: args.stability_penalty,
        stability_method: Some(
            args.stability_method
                .into_method(args.stability_penalty, args.trim_pct),
        ),
    };

    let candles = load_candles(&args.candles_path)?;
    println!(
        "[tpe-wf] candles: {} bars from {}",
        candles.len(),
        args.candles_path.display()
    );

    let all_wf = load_wf_trials(&args.wf_study, StrategyKind::Ichimoku)?;
    let warm_start: Vec<WalkForwardResult> = all_wf
        .iter()
        .filter(|r| survives(r, &args.warm_start_criteria))
        .cloned()
        .collect();
    println!(
        "[tpe-wf] warm-start pool: {} / {} W3a trials pass criteria \
         (mean≥{:.2}, std≤{:.2}, decay≤{:.2}, worst≥{:.2})",
        warm_start.len(),
        all_wf.len(),
        args.warm_start_criteria.min_mean_oos_pf,
        args.warm_start_criteria.max_std_oos_pf,
        args.warm_start_criteria.max_is_oos_decay,
        args.warm_start_criteria.min_worst_oos_pf,
    );

    let space_yaml = read_to_string(&args.search_space_path)
        .with_context(|| format!("read --search-space {}", args.search_space_path.display()))?;
    let space = parse_search_space_str(&space_yaml)?;

    if let Some(parent) = args.output_db.parent() {
        if !parent.as_os_str().is_empty() {
            create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
        }
    }
    let mut output_storage = StudyStorage::open(&args.output_db)
        .with_context(|| format!("open output DB {}", args.output_db.display()))?;
    let study_name = format!(
        "tpe_walk_forward_ichimoku_n{}_seed{}_{}",
        args.n_trials, args.seed, REPLAY_DATE,
    );
    let study_id = output_storage.create_study(&study_name, "ichimoku", &space_yaml)?;
    println!(
        "[tpe-wf] output study '{}' (id={}) in {}",
        study_name,
        study_id,
        args.output_db.display(),
    );
    println!(
        "[tpe-wf] stability score method: {:?} (train={} bars, validate={} bars, step={} bars)",
        wf_config.stability_method(),
        wf_config.train_bars,
        wf_config.validate_bars,
        wf_config.step_bars,
    );
    println!(
        "[tpe-wf] TPE config: gamma={}, n_ei_candidates={}, n_trials={}, seed={}",
        args.tpe_gamma, args.tpe_ei_candidates, args.n_trials, args.seed,
    );
    if (warm_start.len() as f64) < MIN_HISTORY_FOR_TPE as f64 * 1.25 {
        println!(
            "[tpe-wf] WARN: warm-start pool size {} is close to MIN_HISTORY_FOR_TPE={}; \
             the first few TPE suggestions may still fall back to random sampling.",
            warm_start.len(),
            MIN_HISTORY_FOR_TPE,
        );
    }

    let summary = run_tpe_walk_forward(
        &candles,
        warm_start,
        &space,
        &wf_config,
        base_config,
        &constraints,
        &mut output_storage,
        study_id,
        TpeRunConfig {
            n_trials: args.n_trials,
            seed: args.seed,
            tpe_gamma: args.tpe_gamma,
            tpe_ei_candidates: args.tpe_ei_candidates,
            sanity_limit_secs: Some(FIRST_TRIAL_SANITY_LIMIT_SECS),
            print_progress: true,
        },
    )?;
    println!(
        "[tpe-wf] done: {} trials persisted in {} ({:.1}s avg/trial); \
         best agg={:.4} at trial #{}",
        summary.trials_persisted,
        fmt_duration_secs(summary.batch_secs + summary.sanity_secs),
        (summary.batch_secs + summary.sanity_secs) / summary.trials_persisted.max(1) as f64,
        summary.best_aggregated_score,
        summary.best_trial_index,
    );

    let tpe_top = output_storage.top_n_walk_forward(study_id, args.n_trials as usize)?;
    write_tpe_csv(&tpe_top, &args.output_csv)?;
    println!("[tpe-wf] wrote CSV {}", args.output_csv.display());

    print_top_table("Top-5 TPE", &tpe_top);
    let w3a_top: Vec<WalkForwardResult> = {
        let mut sorted = all_wf;
        sorted.sort_by(|a, b| {
            b.aggregated_score
                .partial_cmp(&a.aggregated_score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        sorted.into_iter().take(5).collect()
    };
    print_top_table("Top-5 W3a (baseline)", &w3a_top);

    println!();
    println!(
        "Finished at {} (replay_date={})",
        Utc::now().to_rfc3339(),
        REPLAY_DATE,
    );
    Ok(())
}

fn print_top_table(label: &str, top: &[WalkForwardResult]) {
    println!();
    println!("{}:", label);
    println!(" rank trial_id  aggregated  mean_oos  std_oos  worst_oos  mean_is  is_oos_decay");
    for (i, r) in top.iter().enumerate().take(5) {
        println!(
            "  {:>3}  {:>7}    {:>7.4}   {:>6.3}   {:>6.3}    {:>6.3}   {:>6.3}      {:>+6.3}",
            i + 1,
            r.trial_id,
            r.aggregated_score,
            r.mean_oos_pf,
            r.std_oos_pf,
            r.worst_oos_pf,
            r.mean_is_pf,
            r.is_oos_decay,
        );
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    //! Smoke + edge-case tests for the TPE × walk-forward CLI helpers.
    //! Hermetic — synthetic candles, in-memory SQLite, no fs access
    //! beyond `tempfile`. Real production validation happens via the
    //! W3.5-2 run, not in CI.
    use super::*;
    use tempfile::NamedTempFile;
    use trading_engine::models::Candle;
    use trading_engine::optimizer::{
        TrialMetrics, TrialParams, WalkForwardResult, WalkForwardSplitResult,
    };

    // ─── Synthetic fixtures ─────────────────────────────────────────────────

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

    fn smoke_wf_config() -> WalkForwardConfig {
        // train=500 + validate=200 + step=200 on 1500 candles
        //   splits = floor((1500 - 700) / 200) + 1 = 5
        // — matches the spec smoke recipe.
        WalkForwardConfig {
            train_bars: 500,
            validate_bars: 200,
            step_bars: 200,
            stability_penalty: 0.5,
            stability_method: Some(StabilityScoreMethod::MedianIqr { iqr_penalty: 0.5 }),
        }
    }

    fn smoke_base_config() -> BacktestConfig {
        BacktestConfig {
            initial_balance: INITIAL_BALANCE,
            fee_rate: FEE_RATE,
            timeframe: Timeframe::H1,
            slippage_bps: SLIPPAGE_BPS,
        }
    }

    fn smoke_constraints() -> ScoreConstraints {
        ScoreConstraints {
            max_drawdown_cap_pct: 100.0,
            min_trades: 0,
        }
    }

    fn smoke_search_space() -> SearchSpace {
        let yaml = r#"
strategy_name: ichimoku
parameters:
  tenkan_period: { type: Int, min: 7, max: 13 }
  kijun_period: { type: Int, min: 21, max: 39 }
  senkou_b_period: { type: Int, min: 40, max: 69 }
  shift: { type: Int, min: 20, max: 30 }
  score_threshold: { type: Int, min: 40, max: 60 }
  tp_rr_ratio: { type: Float, min: 1.5, max: 2.6 }
  risk_per_trade: { type: Float, min: 0.01, max: 0.024 }
  adx_threshold: { type: Float, min: 25.0, max: 38.0 }
  adx_use_di_confluence: { type: Bool }
fixed:
  session_filter_enabled: 0.0
  adx_filter_enabled: 1.0
  adx_period: 14.0
"#;
        parse_search_space_str(yaml).unwrap()
    }

    /// Open a fresh `StudyStorage` against a `tempfile::NamedTempFile`.
    /// The file must outlive `storage`; the caller keeps the
    /// `NamedTempFile` bound (with `_db = ...`) for the test lifetime.
    fn temp_storage() -> (NamedTempFile, StudyStorage) {
        let file = NamedTempFile::new().unwrap();
        let storage = StudyStorage::open(file.path()).unwrap();
        (file, storage)
    }

    fn synthetic_warm_start(n: usize) -> Vec<WalkForwardResult> {
        // Build n "qualified" WalkForwardResults with mildly varied
        // params and decreasing scores. Splits carry a single
        // representative metric pair — TPE consumes only score + params,
        // splits are along for the persistence roundtrip.
        (0..n)
            .map(|i| {
                let mut p = TrialParams::new();
                p.insert("tenkan_period", (9.0 + (i as f64) * 0.3).round().min(13.0));
                p.insert("kijun_period", (26.0 + (i as f64) * 0.7).round().min(39.0));
                p.insert(
                    "senkou_b_period",
                    (52.0 + (i as f64) * 1.0).round().min(69.0),
                );
                p.insert("shift", (26.0 + (i as f64) * 0.2).round().min(30.0));
                p.insert(
                    "score_threshold",
                    (50.0 + (i as f64) * 0.3).round().min(60.0),
                );
                p.insert("tp_rr_ratio", 1.8 + ((i as f64) * 0.05).min(0.7));
                p.insert("risk_per_trade", 0.012 + ((i as f64) * 0.0005).min(0.011));
                p.insert("adx_threshold", 30.0 + ((i as f64) * 0.4).min(7.0));
                p.insert("adx_use_di_confluence", if i % 2 == 0 { 1.0 } else { 0.0 });
                // Decreasing scores: best gets 1.4, worst gets ~0.4
                let agg = 1.4 - (i as f64) * 0.05;
                let m = TrialMetrics {
                    total_trades: 20,
                    total_pnl: 50.0,
                    win_rate: 55.0,
                    sharpe_ratio: 1.0,
                    max_drawdown_pct: 8.0,
                    profit_factor: 1.5,
                    final_equity: 10_050.0,
                };
                WalkForwardResult {
                    trial_id: 100 + i as u32,
                    params: p,
                    splits: vec![WalkForwardSplitResult {
                        split_index: 0,
                        train_metrics: m.clone(),
                        validate_metrics: m,
                    }],
                    aggregated_score: agg,
                    mean_oos_pf: 1.5,
                    std_oos_pf: 0.5,
                    worst_oos_pf: 0.5,
                    mean_is_pf: 1.7,
                    is_oos_decay: 0.2,
                }
            })
            .collect()
    }

    // ─── parse_args_from ────────────────────────────────────────────────────

    fn min_args() -> Vec<String> {
        vec![
            "--wf-study".into(),
            "wf.db".into(),
            "--candles".into(),
            "c.json".into(),
            "--search-space".into(),
            "space.yaml".into(),
            "--output-csv".into(),
            "out.csv".into(),
            "--output-db".into(),
            "out.db".into(),
        ]
    }

    #[test]
    fn parse_args_defaults_match_documented_values() {
        let args = parse_args_from(&min_args()).unwrap();
        assert_eq!(args.n_trials, DEFAULT_N_TRIALS);
        assert_eq!(args.train_bars, DEFAULT_TRAIN_BARS);
        assert_eq!(args.validate_bars, DEFAULT_VALIDATE_BARS);
        assert_eq!(args.step_bars, DEFAULT_STEP_BARS);
        assert_eq!(args.stability_method, StabilityMethodArg::Median);
        assert!((args.stability_penalty - DEFAULT_STABILITY_PENALTY).abs() < 1e-12);
        assert!((args.tpe_gamma - DEFAULT_GAMMA).abs() < 1e-12);
        assert_eq!(args.tpe_ei_candidates, DEFAULT_N_EI_CANDIDATES);
        assert_eq!(args.seed, DEFAULT_SEED);
    }

    #[test]
    fn parse_args_threads_warm_start_criteria_overrides() {
        let mut raw = min_args();
        raw.extend([
            "--warm-start-criteria-min-mean-oos-pf".into(),
            "1.3".into(),
            "--warm-start-criteria-max-std-oos-pf".into(),
            "1.5".into(),
            "--warm-start-criteria-max-is-oos-decay".into(),
            "0.7".into(),
            "--warm-start-criteria-min-worst-oos-pf".into(),
            "0.3".into(),
        ]);
        let args = parse_args_from(&raw).unwrap();
        assert!((args.warm_start_criteria.min_mean_oos_pf - 1.3).abs() < 1e-12);
        assert!((args.warm_start_criteria.max_std_oos_pf - 1.5).abs() < 1e-12);
        assert!((args.warm_start_criteria.max_is_oos_decay - 0.7).abs() < 1e-12);
        assert!((args.warm_start_criteria.min_worst_oos_pf - 0.3).abs() < 1e-12);
    }

    #[test]
    fn parse_args_rejects_tpe_gamma_outside_open_unit_interval() {
        let mut raw = min_args();
        raw.extend(["--tpe-gamma".into(), "1.0".into()]);
        let err = parse_args_from(&raw).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("--tpe-gamma must be in"),
            "expected gamma-range error, got: {}",
            msg,
        );
    }

    #[test]
    fn parse_args_rejects_zero_tpe_ei_candidates() {
        let mut raw = min_args();
        raw.extend(["--tpe-ei-candidates".into(), "0".into()]);
        let err = parse_args_from(&raw).unwrap_err();
        assert!(err.to_string().contains("--tpe-ei-candidates"));
    }

    #[test]
    fn parse_args_rejects_unknown_stability_method() {
        let mut raw = min_args();
        raw.extend(["--stability-method".into(), "harmonic".into()]);
        let err = parse_args_from(&raw).unwrap_err();
        assert!(err.to_string().contains("unknown --stability-method"));
    }

    // ─── Search-space YAML ──────────────────────────────────────────────────

    #[test]
    fn ichimoku_tpe_w3_yaml_loads_with_expected_param_set() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|p| p.parent())
            .expect("crate dir has great-grandparent")
            .join("01_Projectplan/search_spaces/ichimoku_tpe_w3.yaml");
        let yaml = read_to_string(&path).expect("yaml file present");
        let space = parse_search_space_str(&yaml).expect("yaml parses");
        assert_eq!(space.strategy_name, "ichimoku");
        for key in [
            "tenkan_period",
            "kijun_period",
            "senkou_b_period",
            "shift",
            "score_threshold",
            "tp_rr_ratio",
            "risk_per_trade",
            "adx_threshold",
            "adx_use_di_confluence",
        ] {
            assert!(
                space.parameters.contains_key(key),
                "missing parameter '{}'",
                key,
            );
        }
        for fkey in ["session_filter_enabled", "adx_filter_enabled", "adx_period"] {
            assert!(
                space.fixed.contains_key(fkey),
                "missing fixed param '{}'",
                fkey,
            );
        }
    }

    // ─── wf_to_trial_result ─────────────────────────────────────────────────

    #[test]
    fn wf_to_trial_result_uses_aggregated_score_and_propagates_params() {
        let mut p = TrialParams::new();
        p.insert("foo", 42.0);
        let wf = WalkForwardResult {
            trial_id: 7,
            params: p.clone(),
            splits: vec![],
            aggregated_score: 1.42,
            mean_oos_pf: 2.0,
            std_oos_pf: 0.5,
            worst_oos_pf: 1.0,
            mean_is_pf: 1.8,
            is_oos_decay: -0.2,
        };
        let t = wf_to_trial_result(&wf);
        assert_eq!(t.trial_id, 7);
        assert_eq!(t.params, p);
        assert!((t.score - 1.42).abs() < 1e-12);
        // metrics are zero-stubbed (TPE only reads score + params)
        assert_eq!(t.metrics.total_trades, 0);
        assert!((t.metrics.final_equity).abs() < 1e-12);
    }

    // ─── run_tpe_walk_forward — fail-fast ────────────────────────────────────

    #[test]
    fn run_tpe_walk_forward_bails_when_warm_start_below_threshold() {
        let candles = synthetic_candles(1500);
        let warm_start = synthetic_warm_start(8); // < MIN_WARM_START_SURVIVORS
        let space = smoke_search_space();
        let (_db, mut storage) = temp_storage();
        let study_id = storage
            .create_study("smoke_fail", "ichimoku", "yaml")
            .unwrap();

        let err = run_tpe_walk_forward(
            &candles,
            warm_start,
            &space,
            &smoke_wf_config(),
            smoke_base_config(),
            &smoke_constraints(),
            &mut storage,
            study_id,
            TpeRunConfig {
                n_trials: 5,
                seed: 42,
                tpe_gamma: DEFAULT_GAMMA,
                tpe_ei_candidates: DEFAULT_N_EI_CANDIDATES,
                sanity_limit_secs: None,
                print_progress: false,
            },
        )
        .unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("warm-start pool only 8 trials"),
            "expected warm-start fail-fast, got: {}",
            msg,
        );
    }

    #[test]
    fn run_tpe_walk_forward_bails_when_n_trials_zero() {
        let candles = synthetic_candles(1500);
        let warm_start = synthetic_warm_start(12);
        let space = smoke_search_space();
        let (_db, mut storage) = temp_storage();
        let study_id = storage
            .create_study("smoke_zero", "ichimoku", "yaml")
            .unwrap();
        let err = run_tpe_walk_forward(
            &candles,
            warm_start,
            &space,
            &smoke_wf_config(),
            smoke_base_config(),
            &smoke_constraints(),
            &mut storage,
            study_id,
            TpeRunConfig {
                n_trials: 0,
                seed: 42,
                tpe_gamma: DEFAULT_GAMMA,
                tpe_ei_candidates: DEFAULT_N_EI_CANDIDATES,
                sanity_limit_secs: None,
                print_progress: false,
            },
        )
        .unwrap_err();
        assert!(err.to_string().contains("--n-trials must be > 0"));
    }

    // ─── run_tpe_walk_forward — smoke ───────────────────────────────────────

    #[test]
    fn run_tpe_walk_forward_smoke_persists_n_trials_and_advances_history() {
        let candles = synthetic_candles(1500);
        let warm_start = synthetic_warm_start(12);
        let space = smoke_search_space();
        let (_db, mut storage) = temp_storage();
        let study_id = storage
            .create_study("smoke_run", "ichimoku", "yaml")
            .unwrap();

        let summary = run_tpe_walk_forward(
            &candles,
            warm_start,
            &space,
            &smoke_wf_config(),
            smoke_base_config(),
            &smoke_constraints(),
            &mut storage,
            study_id,
            TpeRunConfig {
                n_trials: 5,
                seed: 42,
                tpe_gamma: DEFAULT_GAMMA,
                tpe_ei_candidates: DEFAULT_N_EI_CANDIDATES,
                sanity_limit_secs: None,
                print_progress: false,
            },
        )
        .expect("smoke run must succeed");
        assert_eq!(summary.trials_persisted, 5);
        assert!(summary.best_aggregated_score.is_finite());

        // DB-side audit: 5 walk_forward_trials rows, sorted by score.
        let top = storage.top_n_walk_forward(study_id, 5).unwrap();
        assert_eq!(top.len(), 5);
        for w in top.windows(2) {
            // Disqualified trials (NEG_INFINITY) may appear at the end —
            // the order must be DESC, but successive equal scores are OK.
            assert!(
                w[0].aggregated_score >= w[1].aggregated_score
                    || w[0].aggregated_score.is_finite() != w[1].aggregated_score.is_finite(),
                "scores must be sorted DESC: {} vs {}",
                w[0].aggregated_score,
                w[1].aggregated_score,
            );
        }
    }

    // ─── run_tpe_walk_forward — reproducibility ─────────────────────────────

    #[test]
    fn run_tpe_walk_forward_is_reproducible_for_identical_inputs() {
        // Two engines with the same seed + warm-start + candles must
        // emit the same Top-1 aggregated_score (and the same param
        // set, since TPE is deterministic given the same RNG state).
        let candles = synthetic_candles(1500);
        let warm_start = synthetic_warm_start(12);
        let space = smoke_search_space();

        let run_once = || {
            let (_db, mut storage) = temp_storage();
            let study_id = storage.create_study("repro", "ichimoku", "yaml").unwrap();
            run_tpe_walk_forward(
                &candles,
                warm_start.clone(),
                &space,
                &smoke_wf_config(),
                smoke_base_config(),
                &smoke_constraints(),
                &mut storage,
                study_id,
                TpeRunConfig {
                    n_trials: 4,
                    seed: 123,
                    tpe_gamma: DEFAULT_GAMMA,
                    tpe_ei_candidates: DEFAULT_N_EI_CANDIDATES,
                    sanity_limit_secs: None,
                    print_progress: false,
                },
            )
            .unwrap();
            storage.top_n_walk_forward(study_id, 4).unwrap()
        };

        let a = run_once();
        let b = run_once();
        assert_eq!(a.len(), b.len());
        for (ra, rb) in a.iter().zip(b.iter()) {
            assert_eq!(ra.trial_id, rb.trial_id);
            assert_eq!(ra.params, rb.params);
            assert_eq!(ra.aggregated_score, rb.aggregated_score);
        }
    }

    // ─── CSV writer ─────────────────────────────────────────────────────────

    #[test]
    fn write_tpe_csv_emits_header_and_one_row_per_result() {
        let mut params = TrialParams::new();
        params.insert("kijun_period", 26.0);
        params.insert("tenkan_period", 9.0);
        let m = TrialMetrics {
            total_trades: 30,
            total_pnl: 50.0,
            win_rate: 55.0,
            sharpe_ratio: 1.0,
            max_drawdown_pct: 8.0,
            profit_factor: 1.5,
            final_equity: 10_050.0,
        };
        let r = WalkForwardResult {
            trial_id: 17,
            params,
            splits: vec![WalkForwardSplitResult {
                split_index: 0,
                train_metrics: m.clone(),
                validate_metrics: m,
            }],
            aggregated_score: 1.234,
            mean_oos_pf: 1.7,
            std_oos_pf: 0.1,
            worst_oos_pf: 1.6,
            mean_is_pf: 1.5,
            is_oos_decay: -0.2,
        };
        let path = NamedTempFile::new().unwrap().into_temp_path();
        write_tpe_csv(&[r], path.as_ref()).unwrap();
        let content = read_to_string(&path).unwrap();
        let mut lines = content.lines();
        let header = lines.next().expect("header line");
        assert!(header.starts_with(
            "rank,trial_id,aggregated_score,mean_oos_pf,std_oos_pf,worst_oos_pf,\
             mean_is_pf,is_oos_decay,n_splits"
        ));
        assert!(header.contains(",p_kijun_period,p_tenkan_period"));
        let row = lines.next().expect("data row");
        assert!(row.starts_with("1,17,1.234"));
    }
}
