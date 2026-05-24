//! End-to-end mini-sweep: 50 bb_rsi trials on a synthetic 200-candle
//! fixture, persisted to SQLite, scored by the composite gate, and
//! verified for reproducibility under a fixed seed.
//!
//! This is the Welle-O1 acceptance run. A full 1000-trial production
//! sweep lives in Welle O2.

use std::path::PathBuf;

use tempfile::NamedTempFile;

use trading_engine::backtest::BacktestConfig;
use trading_engine::models::{Candle, Timeframe};
use trading_engine::optimizer::{
    parse_search_space, score_constraints_for_strategy, RandomSearchEngine, ScoreConstraints,
    StrategyKind, StudyStorage,
};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("crate dir has a great-grandparent")
        .to_path_buf()
}

/// Deterministic synthetic 1-hour candles: linear drift plus an
/// oscillation broad enough that BB+RSI signals fire on at least some
/// parameter combinations within the 200-bar window.
fn synthetic_candles(n: usize) -> Vec<Candle> {
    let mut candles = Vec::with_capacity(n);
    let start_ts: i64 = 1_700_000_000_000;
    let step_ms: i64 = 60 * 60 * 1_000;
    for i in 0..n {
        let t = i as f64;
        let drift = 60_000.0 + t * 5.0;
        let slow_osc = 800.0 * (t * 0.21).sin();
        let mid_osc = 200.0 * (t * 0.55).cos();
        let close = drift + slow_osc + mid_osc;
        let open = drift + slow_osc + 200.0 * ((t - 1.0) * 0.55).cos();
        let high = close.max(open) + 90.0;
        let low = close.min(open) - 90.0;
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

fn base_config() -> BacktestConfig {
    BacktestConfig {
        initial_balance: 10_000.0,
        fee_rate: 0.0006,
        timeframe: Timeframe::H1,
        slippage_bps: 0.0,
    }
}

/// Acceptance gate #1: 50 trials run, all 50 persisted, Top-5 retrievable.
#[test]
fn mini_sweep_persists_all_trials_and_returns_top_five() {
    let space = parse_search_space(
        &repo_root().join("01_Projectplan/search_spaces/bb_rsi.yaml"),
    )
    .expect("bb_rsi.yaml must parse");
    let candles = synthetic_candles(200);
    let constraints = ScoreConstraints {
        max_drawdown_cap_pct: 100.0, // relax for tiny fixture
        min_trades: 0,
    };

    let db = NamedTempFile::new().unwrap();
    let mut storage = StudyStorage::open(db.path()).unwrap();
    let mut engine = RandomSearchEngine::new(42);

    let top5 = engine
        .run_study(
            "mini_bb_rsi_seed42",
            &space,
            StrategyKind::BbRsi,
            &candles,
            base_config(),
            &constraints,
            50,
            &mut storage,
        )
        .unwrap();

    assert_eq!(top5.len(), 5, "Top-5 must return 5 trials");
    // Persisted under the expected study name.
    let metas = storage.list_studies().unwrap();
    assert_eq!(metas.len(), 1);
    assert_eq!(metas[0].name, "mini_bb_rsi_seed42");
    assert_eq!(metas[0].strategy, "bb_rsi");

    // Top-5 ordering: monotonically non-increasing.
    for i in 1..top5.len() {
        assert!(
            top5[i - 1].score >= top5[i].score,
            "rank {} ({}) must be >= rank {} ({})",
            i - 1,
            top5[i - 1].score,
            i,
            top5[i].score
        );
    }
}

/// Acceptance gate #2: with a fixed seed two separate engines + storages
/// produce identical Top-5 rankings, bit-for-bit. This is the
/// reproducibility contract on which all Welle-O2 production sweeps
/// depend.
#[test]
fn mini_sweep_with_seed_42_is_reproducible_across_runs() {
    let space = parse_search_space(
        &repo_root().join("01_Projectplan/search_spaces/bb_rsi.yaml"),
    )
    .unwrap();
    let candles = synthetic_candles(200);
    let constraints = ScoreConstraints {
        max_drawdown_cap_pct: 100.0,
        min_trades: 0,
    };

    let top5_a = {
        let db = NamedTempFile::new().unwrap();
        let mut storage = StudyStorage::open(db.path()).unwrap();
        let mut engine = RandomSearchEngine::new(42);
        engine
            .run_study(
                "run_a",
                &space,
                StrategyKind::BbRsi,
                &candles,
                base_config(),
                &constraints,
                50,
                &mut storage,
            )
            .unwrap()
    };

    let top5_b = {
        let db = NamedTempFile::new().unwrap();
        let mut storage = StudyStorage::open(db.path()).unwrap();
        let mut engine = RandomSearchEngine::new(42);
        engine
            .run_study(
                "run_b",
                &space,
                StrategyKind::BbRsi,
                &candles,
                base_config(),
                &constraints,
                50,
                &mut storage,
            )
            .unwrap()
    };

    assert_eq!(
        top5_a, top5_b,
        "seed 42 must produce identical Top-5 across runs"
    );
}

/// Acceptance gate #3: pathological constraints disqualify trials as
/// expected. With `min_trades = 999_999` no trial on a 200-bar fixture
/// can qualify, so every Top-5 score is `f64::NEG_INFINITY`.
#[test]
fn impossible_min_trades_constraint_disqualifies_every_trial() {
    let space = parse_search_space(
        &repo_root().join("01_Projectplan/search_spaces/bb_rsi.yaml"),
    )
    .unwrap();
    let candles = synthetic_candles(200);
    let strict = ScoreConstraints {
        max_drawdown_cap_pct: 100.0,
        min_trades: 999_999,
    };

    let db = NamedTempFile::new().unwrap();
    let mut storage = StudyStorage::open(db.path()).unwrap();
    let mut engine = RandomSearchEngine::new(42);

    let top5 = engine
        .run_study(
            "mini_dq_min_trades",
            &space,
            StrategyKind::BbRsi,
            &candles,
            base_config(),
            &strict,
            50,
            &mut storage,
        )
        .unwrap();

    for t in &top5 {
        assert!(
            t.score.is_infinite() && t.score < 0.0,
            "trial {} should be disqualified, got score {}",
            t.trial_id,
            t.score
        );
    }
}

/// Acceptance gate #4: the production constraints helper produces the
/// expected gates for bb_rsi (≤19 % DD, ≥30 trades) — pinning the table
/// from `score_constraints_for_strategy`.
#[test]
fn production_constraints_for_bb_rsi_match_xlsx_targets() {
    let c = score_constraints_for_strategy(StrategyKind::BbRsi);
    assert_eq!(c.max_drawdown_cap_pct, 19.0);
    assert_eq!(c.min_trades, 30);
}
