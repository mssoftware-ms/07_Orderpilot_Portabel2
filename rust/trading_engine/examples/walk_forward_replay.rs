//! Walk-Forward replay CLI — Phase-3.1 Welle W2.
//!
//! Re-runs the qualified trials from a Welle-O2 single-period study under
//! a rolling-window walk-forward and persists every result into a fresh
//! SQLite database. The original Welle-O2 `studies-*.db` is opened
//! read-only and never mutated — the walk-forward results land in a new
//! `--output-db` so the on-disk artefact for the original sweep stays
//! bit-identical and the walk-forward audit trail is a separate file.
//!
//! # CLI
//! ```text
//! cargo run --release --example walk_forward_replay -- \
//!     --study      01_Projectplan/optimizer_studies/studies-ichimoku.db \
//!     --strategy   ichimoku \
//!     --candles    01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json \
//!     --top-n      109 \
//!     --train-bars 4392 \
//!     --validate-bars 1464 \
//!     --step-bars  1464 \
//!     --stability-penalty 0.5 \
//!     --output-csv 01_Projectplan/optimizer_studies/walk_forward_top109_ichimoku.csv \
//!     --output-db  01_Projectplan/optimizer_studies/studies-ichimoku-wf.db \
//!     --seed       42
//! ```
//!
//! # Trial selection
//! `--top-n` is read against the **qualified** trial pool (score >
//! `NEG_INFINITY`). If the study has fewer qualified trials than
//! requested, a warning is printed and every qualified trial is replayed.
//!
//! # Sanity checkpoint
//! Before the batch run, the highest-ranked trial is replayed in
//! isolation. If its wall-clock cost exceeds `FIRST_TRIAL_SANITY_LIMIT_SECS`
//! (60 s), the CLI exits with an error: that's the Welle-O2-bench
//! extrapolation threshold beyond which the 109-trial batch would no
//! longer fit the ~2 h compute budget.
//!
//! # `--seed` semantics
//! The walk-forward runner is deterministic given (params, candles,
//! config); the seed is accepted for audit-trail / future-extension
//! reasons (e.g. randomized split order) but currently flows nowhere.
//! Its value is echoed into the study name so a re-run with a different
//! seed produces a distinct study row instead of an `UNIQUE` violation.

use std::fs::{create_dir_all, read_to_string, File};
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{bail, Context, Result};
use chrono::Utc;

use trading_engine::backtest::BacktestConfig;
use trading_engine::models::{Candle, Timeframe};
use trading_engine::optimizer::{
    run_walk_forward_trial, score_constraints_for_strategy, ScoreConstraints, StrategyKind,
    StudyStorage, TrialResult, WalkForwardConfig, WalkForwardResult,
};

// ─── Constants ───────────────────────────────────────────────────────────────

const INITIAL_BALANCE: f64 = 10_000.0;
const FEE_RATE: f64 = 0.0006;
const SLIPPAGE_BPS: f64 = 0.0;
const DEFAULT_SEED: u64 = 42;
const DEFAULT_TOP_N: usize = 109;
const DEFAULT_STABILITY_PENALTY: f64 = 0.5;
const DEFAULT_TRAIN_BARS: usize = 4392;
const DEFAULT_VALIDATE_BARS: usize = 1464;
const DEFAULT_STEP_BARS: usize = 1464;
const FIRST_TRIAL_SANITY_LIMIT_SECS: f64 = 60.0;
const PROGRESS_EVERY: usize = 10;
const REPLAY_DATE: &str = "2026-05-25";

// ─── CLI args ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct CliArgs {
    study_db: PathBuf,
    strategy: StrategyKind,
    candles_path: PathBuf,
    top_n: usize,
    train_bars: usize,
    validate_bars: usize,
    step_bars: usize,
    stability_penalty: f64,
    output_csv: PathBuf,
    output_db: PathBuf,
    seed: u64,
}

fn parse_strategy(arg: &str) -> Result<StrategyKind> {
    Ok(match arg {
        "bb_rsi" => StrategyKind::BbRsi,
        "ut_bot" => StrategyKind::UtBot,
        "ichimoku" => StrategyKind::Ichimoku,
        other => bail!(
            "unknown strategy '{}' (expected bb_rsi | ut_bot | ichimoku)",
            other
        ),
    })
}

fn timeframe_for(kind: StrategyKind) -> Timeframe {
    match kind {
        StrategyKind::BbRsi => Timeframe::H4,
        StrategyKind::UtBot => Timeframe::M5,
        StrategyKind::Ichimoku => Timeframe::H1,
    }
}

fn print_usage() {
    eprintln!(
        "usage: walk_forward_replay \\\n\
         \t--study <db>           Welle-O2 study DB to read trials from \\\n\
         \t--strategy <name>      bb_rsi | ut_bot | ichimoku \\\n\
         \t--candles <json>       candle file (full Welle-O2 series) \\\n\
         \t[--top-n N]            qualified-trial pool size (default {}) \\\n\
         \t[--train-bars N]       training-window bars (default {}) \\\n\
         \t[--validate-bars N]    validate-window bars (default {}) \\\n\
         \t[--step-bars N]        bars per slide (default {}) \\\n\
         \t[--stability-penalty F] OOS-std penalty (default {}) \\\n\
         \t--output-csv <path>    Top-N CSV export \\\n\
         \t--output-db <path>     fresh SQLite for walk-forward rows \\\n\
         \t[--seed N]             audit seed (default {})",
        DEFAULT_TOP_N,
        DEFAULT_TRAIN_BARS,
        DEFAULT_VALIDATE_BARS,
        DEFAULT_STEP_BARS,
        DEFAULT_STABILITY_PENALTY,
        DEFAULT_SEED,
    );
}

fn parse_args() -> Result<CliArgs> {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    if raw.is_empty() || raw.iter().any(|a| a == "--help" || a == "-h") {
        print_usage();
        bail!("missing required arguments");
    }

    let mut study_db: Option<PathBuf> = None;
    let mut strategy: Option<StrategyKind> = None;
    let mut candles_path: Option<PathBuf> = None;
    let mut top_n: usize = DEFAULT_TOP_N;
    let mut train_bars: usize = DEFAULT_TRAIN_BARS;
    let mut validate_bars: usize = DEFAULT_VALIDATE_BARS;
    let mut step_bars: usize = DEFAULT_STEP_BARS;
    let mut stability_penalty: f64 = DEFAULT_STABILITY_PENALTY;
    let mut output_csv: Option<PathBuf> = None;
    let mut output_db: Option<PathBuf> = None;
    let mut seed: u64 = DEFAULT_SEED;

    let mut i = 0;
    while i < raw.len() {
        let key = raw[i].as_str();
        let val = raw.get(i + 1).map(String::as_str);
        let need = || -> Result<&str> {
            val.with_context(|| format!("flag '{}' requires a value", key))
        };
        match key {
            "--study" => study_db = Some(PathBuf::from(need()?)),
            "--strategy" => strategy = Some(parse_strategy(need()?)?),
            "--candles" => candles_path = Some(PathBuf::from(need()?)),
            "--top-n" => top_n = need()?.parse().with_context(|| "--top-n must be usize")?,
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
                step_bars = need()?.parse().with_context(|| "--step-bars must be usize")?
            }
            "--stability-penalty" => {
                stability_penalty = need()?
                    .parse()
                    .with_context(|| "--stability-penalty must be f64")?
            }
            "--output-csv" => output_csv = Some(PathBuf::from(need()?)),
            "--output-db" => output_db = Some(PathBuf::from(need()?)),
            "--seed" => seed = need()?.parse().with_context(|| "--seed must be u64")?,
            other => bail!("unknown flag '{}'", other),
        }
        i += 2;
    }

    Ok(CliArgs {
        study_db: study_db.context("--study is required")?,
        strategy: strategy.context("--strategy is required")?,
        candles_path: candles_path.context("--candles is required")?,
        top_n,
        train_bars,
        validate_bars,
        step_bars,
        stability_penalty,
        output_csv: output_csv.context("--output-csv is required")?,
        output_db: output_db.context("--output-db is required")?,
        seed,
    })
}

// ─── IO helpers ──────────────────────────────────────────────────────────────

fn load_candles(path: &Path) -> Result<Vec<Candle>> {
    let file =
        File::open(path).with_context(|| format!("open candles {}", path.display()))?;
    let candles: Vec<Candle> = serde_json::from_reader(BufReader::new(file))
        .with_context(|| format!("parse candles {}", path.display()))?;
    Ok(candles)
}

/// Load the qualified subset of Welle-O2 trials from `study_db`, sorted
/// by descending score. Truncates to `top_n` and warns if the qualified
/// pool is smaller than requested.
fn load_qualified_trials(
    study_db: &Path,
    strategy: StrategyKind,
    top_n: usize,
) -> Result<(Vec<TrialResult>, i64, String)> {
    let storage = StudyStorage::open(study_db)
        .with_context(|| format!("open welle-o2 study {}", study_db.display()))?;
    let studies = storage.list_studies()?;
    let target = studies
        .iter()
        .find(|s| s.strategy == strategy.as_str())
        .with_context(|| {
            format!(
                "no study for strategy '{}' in {}",
                strategy.as_str(),
                study_db.display()
            )
        })?;

    // Fetch a generous top-N first so qualified vs disqualified can be
    // partitioned without a second SQL query. `top_n_trials` returns
    // descending score; NEG_INFINITY rows sort last.
    let pool = storage.top_n_trials(target.id, 1_000_000)?;
    let qualified: Vec<TrialResult> = pool
        .into_iter()
        .filter(|t| t.score.is_finite())
        .collect();

    if qualified.is_empty() {
        bail!(
            "study '{}' contains no qualified trials (every score is NEG_INFINITY)",
            target.name
        );
    }

    let take = top_n.min(qualified.len());
    if top_n > qualified.len() {
        eprintln!(
            "warn: requested top-n={} but only {} trials qualified in study '{}'; \
             replaying all {} qualified trials",
            top_n,
            qualified.len(),
            target.name,
            qualified.len()
        );
    }

    let selected = qualified.into_iter().take(take).collect();
    Ok((selected, target.id, target.name.clone()))
}

// ─── CSV writer ──────────────────────────────────────────────────────────────

fn write_walk_forward_csv(results: &[WalkForwardResult], path: &Path) -> Result<()> {
    let mut file =
        File::create(path).with_context(|| format!("create CSV {}", path.display()))?;
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

// ─── Main ────────────────────────────────────────────────────────────────────

fn main() -> Result<()> {
    let args = parse_args()?;
    let constraints: ScoreConstraints = score_constraints_for_strategy(args.strategy);
    let base_config = BacktestConfig {
        initial_balance: INITIAL_BALANCE,
        fee_rate: FEE_RATE,
        timeframe: timeframe_for(args.strategy),
        slippage_bps: SLIPPAGE_BPS,
    };
    let wf_config = WalkForwardConfig {
        train_bars: args.train_bars,
        validate_bars: args.validate_bars,
        step_bars: args.step_bars,
        stability_penalty: args.stability_penalty,
    };

    // ─── Load candles + qualified trials ────────────────────────────────
    let candles = load_candles(&args.candles_path)?;
    println!(
        "[wf-replay] candles: {} bars from {}",
        candles.len(),
        args.candles_path.display()
    );

    let (trials, source_study_id, source_study_name) =
        load_qualified_trials(&args.study_db, args.strategy, args.top_n)?;
    println!(
        "[wf-replay] source study '{}' (id={}): replaying {} qualified trials",
        source_study_name,
        source_study_id,
        trials.len()
    );

    // ─── Open output DB + create fresh study row ────────────────────────
    if let Some(parent) = args.output_db.parent() {
        if !parent.as_os_str().is_empty() {
            create_dir_all(parent)
                .with_context(|| format!("mkdir {}", parent.display()))?;
        }
    }
    let storage = StudyStorage::open(&args.output_db)
        .with_context(|| format!("open output DB {}", args.output_db.display()))?;
    // Carry the source-study search-space text into the new study so the
    // walk-forward DB is self-describing (audit trail).
    let search_space_yaml = read_to_string(repo_search_space_path(args.strategy))
        .unwrap_or_else(|_| {
            format!(
                "# search space yaml unavailable for strategy {}",
                args.strategy.as_str()
            )
        });
    let new_study_name = format!(
        "walk_forward_{}_top{}_seed{}_{}",
        args.strategy.as_str(),
        trials.len(),
        args.seed,
        REPLAY_DATE,
    );
    let new_study_id =
        storage.create_study(&new_study_name, args.strategy.as_str(), &search_space_yaml)?;
    println!(
        "[wf-replay] output study '{}' (id={}) in {}",
        new_study_name,
        new_study_id,
        args.output_db.display()
    );

    // ─── Sanity: run the first (top-ranked) trial in isolation ─────────
    let first = trials.first().expect("trials non-empty by check above");
    println!(
        "[wf-replay] sanity: replaying first trial id={} (Welle-O2 score={:.4})",
        first.trial_id, first.score
    );
    let sanity_start = Instant::now();
    let first_result = run_walk_forward_trial(
        args.strategy,
        first.trial_id,
        first.params.clone(),
        &candles,
        &wf_config,
        base_config.clone(),
        &constraints,
    )
    .with_context(|| format!("first-trial sanity (trial_id={}) failed", first.trial_id))?;
    let sanity_secs = sanity_start.elapsed().as_secs_f64();
    println!(
        "[wf-replay] sanity ok: {} splits, aggregated_score={:.4}, mean_oos_pf={:.3}, \
         std_oos_pf={:.3}, is_oos_decay={:.3} ({:.1}s)",
        first_result.splits.len(),
        first_result.aggregated_score,
        first_result.mean_oos_pf,
        first_result.std_oos_pf,
        first_result.is_oos_decay,
        sanity_secs,
    );
    if sanity_secs > FIRST_TRIAL_SANITY_LIMIT_SECS {
        bail!(
            "ESCALATION: first-trial wall-clock {:.1}s exceeds limit {:.1}s — \
             109-trial batch would exceed the ~2h compute budget. Re-check engine \
             performance against the Welle-O2 bench (~6s/trial) before proceeding.",
            sanity_secs,
            FIRST_TRIAL_SANITY_LIMIT_SECS,
        );
    }
    storage.insert_walk_forward_trial(new_study_id, &first_result, &wf_config)?;
    let n_splits_first = first_result.splits.len();

    // ─── Batch replay (trial[1..]) ─────────────────────────────────────
    let batch_start = Instant::now();
    let mut all_results: Vec<WalkForwardResult> = Vec::with_capacity(trials.len());
    all_results.push(first_result);
    for (idx, trial) in trials.iter().enumerate().skip(1) {
        let r = run_walk_forward_trial(
            args.strategy,
            trial.trial_id,
            trial.params.clone(),
            &candles,
            &wf_config,
            base_config.clone(),
            &constraints,
        )
        .with_context(|| {
            format!(
                "walk-forward trial #{}/{} (trial_id={}) failed",
                idx + 1,
                trials.len(),
                trial.trial_id,
            )
        })?;
        storage.insert_walk_forward_trial(new_study_id, &r, &wf_config)?;
        all_results.push(r);

        let done = idx + 1; // 1-based count including the sanity trial
        if done % PROGRESS_EVERY == 0 || done == trials.len() {
            let elapsed = batch_start.elapsed().as_secs_f64();
            let per_trial = elapsed / (done - 1).max(1) as f64;
            let remaining = (trials.len() - done) as f64 * per_trial;
            println!(
                "[wf-replay] progress {}/{}  elapsed={}  eta={}  (~{:.1}s/trial)",
                done,
                trials.len(),
                fmt_duration_secs(elapsed),
                fmt_duration_secs(remaining),
                per_trial,
            );
        }
    }

    let total_secs = batch_start.elapsed().as_secs_f64() + sanity_secs;
    println!(
        "[wf-replay] done: {} trials × {} splits each in {} ({:.1}s avg/trial)",
        trials.len(),
        n_splits_first,
        fmt_duration_secs(total_secs),
        total_secs / trials.len().max(1) as f64,
    );

    // ─── Persistence audit ─────────────────────────────────────────────
    let n_persisted = storage.count_walk_forward_trials(new_study_id)?;
    if n_persisted as usize != trials.len() {
        bail!(
            "persistence audit: expected {} rows, found {} in walk_forward_trials",
            trials.len(),
            n_persisted,
        );
    }
    println!(
        "[wf-replay] persisted {} walk_forward_trials rows in study_id={}",
        n_persisted, new_study_id,
    );

    // ─── Top-N pull-back + CSV + console ────────────────────────────────
    let top_all = storage.top_n_walk_forward(new_study_id, trials.len())?;
    write_walk_forward_csv(&top_all, &args.output_csv)?;
    println!("[wf-replay] wrote CSV {}", args.output_csv.display());

    println!();
    println!("Top-5 Walk-Forward (sorted by aggregated_score):");
    println!(
        " rank trial_id  aggregated  mean_oos  std_oos  worst_oos  mean_is  is_oos_decay"
    );
    for (i, r) in top_all.iter().enumerate().take(5) {
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
    println!();
    println!(
        "Finished at {} (replay_date={})",
        Utc::now().to_rfc3339(),
        REPLAY_DATE,
    );
    Ok(())
}

/// Locate the canonical search-space YAML for `strategy` relative to the
/// crate root. Returns the path even if the file is missing; callers
/// must tolerate `read_to_string` errors and fall back to a placeholder.
fn repo_search_space_path(strategy: StrategyKind) -> PathBuf {
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    repo_root
        .join("01_Projectplan/search_spaces")
        .join(format!("{}.yaml", strategy.as_str()))
}

#[cfg(test)]
mod tests {
    //! Smoke + edge-case tests for the walk-forward replay CLI helpers.
    //!
    //! `cargo test --example walk_forward_replay` drives these tests. They
    //! intentionally avoid spawning a child process — the helpers
    //! `load_qualified_trials` and `write_walk_forward_csv` are exercised
    //! directly so the tests stay fast (<1 s) and hermetic. End-to-end
    //! validation against the production studies-ichimoku.db happens via
    //! the W2-2 production run, not in CI.
    use super::*;
    use tempfile::NamedTempFile;
    use trading_engine::optimizer::{
        TrialMetrics, TrialParams, TrialResult, WalkForwardResult, WalkForwardSplitResult,
    };

    fn sample_trial(trial_id: u32, score: f64) -> TrialResult {
        let mut params = TrialParams::new();
        params.insert("tenkan_period", 9.0 + trial_id as f64);
        params.insert("kijun_period", 26.0);
        params.insert("senkou_b_period", 52.0);
        TrialResult {
            trial_id,
            params,
            metrics: TrialMetrics {
                total_trades: 60,
                total_pnl: 100.0,
                win_rate: 55.0,
                sharpe_ratio: 1.0,
                max_drawdown_pct: 8.0,
                profit_factor: 1.8,
                final_equity: 11_000.0,
            },
            score,
        }
    }

    fn seed_study(
        storage: &StudyStorage,
        strategy: StrategyKind,
        n_qualified: usize,
        n_disqualified: usize,
    ) -> i64 {
        let study_id = storage
            .create_study(
                &format!("seeded_{}_{}", strategy.as_str(), n_qualified),
                strategy.as_str(),
                "yaml-placeholder",
            )
            .unwrap();
        let mut next_id: u32 = 0;
        for i in 0..n_qualified {
            // descending scores so top_n_trials sorts intuitively
            let score = 2.5 - 0.001 * i as f64;
            storage
                .insert_trial(study_id, &sample_trial(next_id, score))
                .unwrap();
            next_id += 1;
        }
        for _ in 0..n_disqualified {
            storage
                .insert_trial(study_id, &sample_trial(next_id, f64::NEG_INFINITY))
                .unwrap();
            next_id += 1;
        }
        study_id
    }

    /// `load_qualified_trials` truncates to `top_n` when more qualified
    /// trials exist than requested.
    #[test]
    fn load_qualified_trials_truncates_to_top_n_when_pool_larger() {
        let db = NamedTempFile::new().unwrap();
        {
            let storage = StudyStorage::open(db.path()).unwrap();
            seed_study(&storage, StrategyKind::Ichimoku, 50, 5);
        }
        let (trials, _, _) =
            load_qualified_trials(db.path(), StrategyKind::Ichimoku, 3).unwrap();
        assert_eq!(trials.len(), 3, "must truncate to requested top-n");
        // All disqualified rows excluded.
        assert!(trials.iter().all(|t| t.score.is_finite()));
        // Sorted descending.
        for w in trials.windows(2) {
            assert!(w[0].score >= w[1].score);
        }
    }

    /// `load_qualified_trials` takes every qualified row when `top_n`
    /// exceeds the pool size — and prints a warning (visible to humans;
    /// behavior pinned via count check).
    #[test]
    fn load_qualified_trials_caps_at_pool_when_top_n_exceeds() {
        let db = NamedTempFile::new().unwrap();
        {
            let storage = StudyStorage::open(db.path()).unwrap();
            // 12 qualified, 3 disqualified — simulate the Ichimoku 109/1000
            // proportion on a tiny scale.
            seed_study(&storage, StrategyKind::Ichimoku, 12, 3);
        }
        let (trials, _, _) =
            load_qualified_trials(db.path(), StrategyKind::Ichimoku, 200).unwrap();
        assert_eq!(
            trials.len(),
            12,
            "must take all qualified trials, never NEG_INFINITY rows"
        );
        assert!(trials.iter().all(|t| t.score.is_finite()));
    }

    /// `load_qualified_trials` returns Err when every trial is
    /// disqualified — a config-error signal, not a per-trial failure.
    #[test]
    fn load_qualified_trials_errors_when_pool_empty() {
        let db = NamedTempFile::new().unwrap();
        {
            let storage = StudyStorage::open(db.path()).unwrap();
            seed_study(&storage, StrategyKind::Ichimoku, 0, 4);
        }
        let res = load_qualified_trials(db.path(), StrategyKind::Ichimoku, 5);
        assert!(res.is_err(), "all-disqualified pool must error");
    }

    /// CSV header lists the eight metric columns plus one `p_*` column
    /// per parameter, in sorted-key order. First data row contains the
    /// rank-1 trial's stats.
    #[test]
    fn write_walk_forward_csv_emits_header_and_first_data_row() {
        let mut params = TrialParams::new();
        params.insert("kijun_period", 26.0);
        params.insert("tenkan_period", 9.0);
        params.insert("senkou_b_period", 52.0);
        let splits = vec![
            WalkForwardSplitResult {
                split_index: 0,
                train_metrics: TrialMetrics {
                    total_trades: 30,
                    total_pnl: 50.0,
                    win_rate: 55.0,
                    sharpe_ratio: 1.0,
                    max_drawdown_pct: 8.0,
                    profit_factor: 1.5,
                    final_equity: 10_050.0,
                },
                validate_metrics: TrialMetrics {
                    total_trades: 10,
                    total_pnl: 20.0,
                    win_rate: 60.0,
                    sharpe_ratio: 0.9,
                    max_drawdown_pct: 6.0,
                    profit_factor: 1.7,
                    final_equity: 10_020.0,
                },
            },
        ];
        let result = WalkForwardResult {
            trial_id: 515,
            params,
            splits,
            aggregated_score: 1.234,
            mean_oos_pf: 1.7,
            std_oos_pf: 0.1,
            worst_oos_pf: 1.6,
            mean_is_pf: 1.5,
            is_oos_decay: -0.2,
        };

        let csv_path = NamedTempFile::new().unwrap().into_temp_path();
        write_walk_forward_csv(&[result], csv_path.as_ref()).unwrap();
        let content = read_to_string(&csv_path).unwrap();
        let mut lines = content.lines();
        let header = lines.next().expect("header line");
        // Header structure
        assert!(header.starts_with(
            "rank,trial_id,aggregated_score,mean_oos_pf,std_oos_pf,worst_oos_pf,\
             mean_is_pf,is_oos_decay,n_splits"
        ));
        // Sorted-key param columns
        assert!(
            header.contains(",p_kijun_period,p_senkou_b_period,p_tenkan_period"),
            "expected sorted-key param columns, got header: {}",
            header
        );

        let row = lines.next().expect("first data row");
        let mut fields = row.split(',');
        assert_eq!(fields.next(), Some("1"), "rank column");
        assert_eq!(fields.next(), Some("515"), "trial_id column");
        // Remaining fields just need to be present (numeric formatting
        // is delegated to f64::Display).
        assert_eq!(fields.count(), 10, "expected 10 remaining columns");
    }
}
