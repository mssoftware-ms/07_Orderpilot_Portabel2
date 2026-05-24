//! Run the Welle-O1 mini-sweep and print a Top-5 report.
//!
//! Usage (from repo root):
//!     cargo run --release --example mini_sweep_report -p trading_engine
//!
//! This is a thin reporting wrapper around the same code paths used by
//! `tests/integration_optimizer_mini.rs`; it is *not* the production
//! sweep (Welle O2). 50 trials on a 200-bar synthetic fixture suffice
//! to sanity-check the pipeline end-to-end.

use std::path::PathBuf;

use anyhow::Result;
use tempfile::NamedTempFile;

use trading_engine::backtest::BacktestConfig;
use trading_engine::models::{Candle, Timeframe};
use trading_engine::optimizer::{
    parse_search_space, RandomSearchEngine, ScoreConstraints, StrategyKind, StudyStorage,
};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("crate dir has a great-grandparent")
        .to_path_buf()
}

/// Aggressive deterministic synth: random-walk closes seeded by index
/// hash, plus a low-frequency mean-reverting envelope. Produces RSI
/// extremes (the gentle-sine synth from the integration test stays
/// trapped in RSI 30..70 and never triggers BB+RSI entries).
fn synthetic_candles(n: usize) -> Vec<Candle> {
    let mut candles = Vec::with_capacity(n);
    let start_ts: i64 = 1_700_000_000_000;
    let step_ms: i64 = 60 * 60 * 1_000;
    let mut close: f64 = 60_000.0;
    for i in 0..n {
        // Splitmix-style integer hash → uniform on [-1, 1].
        let mut z = (i as u64).wrapping_mul(0x9E3779B97F4A7C15);
        z ^= z >> 30;
        z = z.wrapping_mul(0xBF58476D1CE4E5B5);
        z ^= z >> 27;
        z = z.wrapping_mul(0x94D049BB133111EB);
        z ^= z >> 31;
        let unit = ((z as i64) as f64) / (i64::MAX as f64);

        let t = i as f64;
        let envelope = 400.0 * (t * 0.045).sin();
        let step = unit * 250.0 + envelope * 0.1;
        let open = close;
        close += step;
        let high = open.max(close) + (unit.abs() * 120.0 + 40.0);
        let low = open.min(close) - (unit.abs() * 120.0 + 40.0);
        let volume = 100.0 + 25.0 * (t * 0.13).sin().abs();
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

fn main() -> Result<()> {
    let mut space =
        parse_search_space(&repo_root().join("01_Projectplan/search_spaces/bb_rsi.yaml"))?;
    // The production YAML keeps adx_filter_enabled=1.0 fixed and sweeps
    // adx_threshold 25..45. On synthetic candles ADX rarely climbs above
    // 25, blocking every signal. Disable the filter for the sanity
    // report so we see actual PF/Sharpe numbers from the pipeline.
    space.fixed.insert("adx_filter_enabled".into(), 0.0);
    // 800 bars gives bb_period 100..300 enough warm-up + trading window
    // to actually fire signals; the formal pipeline acceptance tests use
    // 200 bars per spec.
    let candles = synthetic_candles(800);
    let config = BacktestConfig {
        initial_balance: 10_000.0,
        fee_rate: 0.0006,
        timeframe: Timeframe::H1,
        slippage_bps: 0.0,
    };
    // Sweep-friendly constraints for the mini fixture (tiny sample size
    // can't satisfy the production min_trades / DD-cap gates).
    let constraints = ScoreConstraints {
        max_drawdown_cap_pct: 100.0,
        min_trades: 0,
    };

    let db = NamedTempFile::new()?;
    let mut storage = StudyStorage::open(db.path())?;
    let mut engine = RandomSearchEngine::new(42);

    let top5 = engine.run_study(
        "mini_bb_rsi_seed42",
        &space,
        StrategyKind::BbRsi,
        &candles,
        config,
        &constraints,
        50,
        &mut storage,
    )?;

    println!(
        "Welle O1 mini-sweep — bb_rsi, seed=42, 50 trials on {} synth candles (adx off)",
        candles.len()
    );
    println!("rank trial_id      score     PF      Sharpe   trades   maxDD%   final_eq");
    for (i, t) in top5.iter().enumerate() {
        println!(
            "  {} {:>8}  {:>8.4}  {:>5.3}  {:>+6.3}  {:>6}  {:>6.2}  {:>10.2}",
            i + 1,
            t.trial_id,
            t.score,
            t.metrics.profit_factor,
            t.metrics.sharpe_ratio,
            t.metrics.total_trades,
            t.metrics.max_drawdown_pct,
            t.metrics.final_equity,
        );
    }
    Ok(())
}
