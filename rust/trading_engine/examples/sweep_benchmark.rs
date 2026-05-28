//! Pre-flight compute benchmark for the Welle-O2 production sweeps.
//!
//! Runs N trials per strategy on the SAME real-data candle series the
//! production sweep will see, times them, and prints an extrapolated ETA
//! for the planned 1000-trial sweep. Decision gates per the Welle-O2
//! brief (verdicts printed; final decision lives in the spec MD):
//!
//! - UT-Bot ETA > 8 h  → STOPP, requires rayon parallelism or deferred
//! - UT-Bot ETA > 4 h  → reduce `n_trials` to 500, document in spec
//! - BB+RSI ETA > 1 h  → performance regression vs Phase-2, STOPP
//! - Ichimoku: no explicit gate; the brief's 4–12 h total-compute envelope
//!   governs whether to reduce trials there too.
//!
//! Data files are produced by `tool/fetch_sweep_data.dart` and live
//! gitignored at `01_Projectplan/optimizer_data/`. Filenames are pinned
//! to the brief's ranges (no CLI args — this benchmark is intentionally
//! single-purpose for the Welle-O2 decision).
//!
//! Exit code is always 0 when measurement succeeds; the verdicts are
//! informational. The decision to STOP / reduce trials / proceed lives
//! in `01_Projectplan/specs/optimizer_benchmark_2026-05-24.md`.
//!
//! Usage:
//!     cargo run --release --example sweep_benchmark -p trading_engine

use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context, Result};

use trading_engine::backtest::BacktestConfig;
use trading_engine::models::{Candle, Timeframe};
use trading_engine::optimizer::{
    parse_search_space, score_constraints_for_strategy, RandomSearchEngine, StrategyKind,
    StudyStorage,
};

const BENCH_TRIALS: u32 = 10;
const TARGET_TRIALS: u32 = 1000;
const SEED: u64 = 42;
const INITIAL_BALANCE: f64 = 10_000.0;
const FEE_RATE: f64 = 0.0006; // Bitunix VIP0 taker
const SLIPPAGE_BPS: f64 = 0.0; // Plan rev2 §3.4

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("crate dir has a great-grandparent")
        .to_path_buf()
}

fn load_candles(path: &Path) -> Result<Vec<Candle>> {
    let file = File::open(path).with_context(|| format!("open candles file {}", path.display()))?;
    let candles: Vec<Candle> = serde_json::from_reader(BufReader::new(file))
        .with_context(|| format!("parse candles JSON {}", path.display()))?;
    Ok(candles)
}

struct StrategyJob {
    kind: StrategyKind,
    data_file: &'static str,
    yaml_file: &'static str,
    timeframe: Timeframe,
    eta_warn_hours: f64,
    eta_stop_hours: f64,
}

const JOBS: &[StrategyJob] = &[
    StrategyJob {
        kind: StrategyKind::BbRsi,
        data_file: "01_Projectplan/optimizer_data/BTCUSDT_4h_2024-01-01_2024-07-01.json",
        yaml_file: "01_Projectplan/search_spaces/bb_rsi.yaml",
        timeframe: Timeframe::H4,
        // BB+RSI is the small dataset; >1h ETA = regression.
        eta_warn_hours: 1.0,
        eta_stop_hours: 1.0,
    },
    StrategyJob {
        kind: StrategyKind::UtBot,
        data_file: "01_Projectplan/optimizer_data/BTCUSDT_5m_2024-01-01_2024-03-08.json",
        yaml_file: "01_Projectplan/search_spaces/ut_bot.yaml",
        timeframe: Timeframe::M5,
        // UT-Bot is the critical path; 4h → reduce trials, 8h → STOPP.
        eta_warn_hours: 4.0,
        eta_stop_hours: 8.0,
    },
    StrategyJob {
        kind: StrategyKind::Ichimoku,
        data_file: "01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json",
        yaml_file: "01_Projectplan/search_spaces/ichimoku.yaml",
        timeframe: Timeframe::H1,
        eta_warn_hours: 4.0,
        eta_stop_hours: 8.0,
    },
];

struct BenchResult {
    kind: StrategyKind,
    candles: usize,
    elapsed_secs: f64,
    ms_per_trial: f64,
    eta_1000_hours: f64,
    verdict: &'static str,
}

fn bench_one(job: &StrategyJob) -> Result<BenchResult> {
    let root = repo_root();
    let candles = load_candles(&root.join(job.data_file))?;
    let space = parse_search_space(&root.join(job.yaml_file))?;
    let constraints = score_constraints_for_strategy(job.kind);
    let config = BacktestConfig {
        initial_balance: INITIAL_BALANCE,
        fee_rate: FEE_RATE,
        timeframe: job.timeframe,
        slippage_bps: SLIPPAGE_BPS,
    };

    // Use a tempfile-backed in-memory SQLite for the bench so I/O isn't
    // confounded with engine work. (StudyStorage::open_in_memory is test-
    // only; the on-disk path with a NamedTempFile would write ~10 KiB of
    // SQL ops which is negligible but still noise. We'll just open a
    // throwaway file under target/ which Cargo gitignores.)
    let scratch = root.join("rust/trading_engine/target/sweep_benchmark.db");
    if scratch.exists() {
        std::fs::remove_file(&scratch).ok();
    }
    let mut storage = StudyStorage::open(&scratch)?;
    let mut engine = RandomSearchEngine::new(SEED);

    let start = Instant::now();
    let _top = engine.run_study(
        &format!("bench_{}_seed{}", job.kind.as_str(), SEED),
        &space,
        job.kind,
        &candles,
        config,
        &constraints,
        BENCH_TRIALS,
        &mut storage,
    )?;
    let elapsed = start.elapsed();

    let elapsed_secs = elapsed.as_secs_f64();
    let ms_per_trial = elapsed.as_secs_f64() * 1000.0 / BENCH_TRIALS as f64;
    let eta_1000_hours = (ms_per_trial * TARGET_TRIALS as f64) / 1000.0 / 3600.0;

    let verdict = if eta_1000_hours > job.eta_stop_hours {
        "STOP"
    } else if eta_1000_hours > job.eta_warn_hours {
        "WARN"
    } else {
        "GO"
    };

    Ok(BenchResult {
        kind: job.kind,
        candles: candles.len(),
        elapsed_secs,
        ms_per_trial,
        eta_1000_hours,
        verdict,
    })
}

fn main() -> Result<()> {
    println!(
        "Welle-O2 pre-flight benchmark — {} trials/strategy, seed={}",
        BENCH_TRIALS, SEED
    );
    println!();

    let mut results = Vec::with_capacity(JOBS.len());
    for job in JOBS {
        let r = bench_one(job)?;
        println!(
            "{:>9}  candles={:>5}  {} trials in {:>6.2}s  ⇒  {:>7.2} ms/trial  ⇒  1000-trial ETA = {:>5.2} h  [{}]",
            r.kind.as_str(),
            r.candles,
            BENCH_TRIALS,
            r.elapsed_secs,
            r.ms_per_trial,
            r.eta_1000_hours,
            r.verdict,
        );
        results.push(r);
    }

    println!();
    println!("Decision gates (per Welle-O2 brief):");
    for (job, r) in JOBS.iter().zip(&results) {
        println!(
            "  {:>9}  warn>{:.1}h  stop>{:.1}h  → {}",
            r.kind.as_str(),
            job.eta_warn_hours,
            job.eta_stop_hours,
            r.verdict,
        );
    }

    let total_eta: f64 = results.iter().map(|r| r.eta_1000_hours).sum();
    println!();
    println!(
        "Total ETA at full 1000 trials per strategy: {:.2} h",
        total_eta
    );
    println!(
        "Brief's overall compute envelope (Welle O2): 4–12 h. \
         See spec MD for the actual trial-count plan."
    );

    Ok(())
}
