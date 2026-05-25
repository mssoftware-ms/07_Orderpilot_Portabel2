//! End-to-end walk-forward integration test — Phase-3.1 Welle W1-4.
//!
//! Drives `run_walk_forward_trial` against the Welle-O2 single-trial
//! runner on synthetic 500-bar fixtures, persists results through the
//! W1-3 SQLite layer, and pins three behaviors that downstream Welle-W2
//! production sweeps depend on:
//!
//!   (a) Smoke: 500-bar synthetic candles + Ichimoku-default params
//!       under config(train=200, validate=50, step=50) produce exactly
//!       6 splits and round-trip persistence works end-to-end.
//!   (b) Stability sanity: handcrafted split pair where Trial A has a
//!       flat OOS PF distribution and Trial B is volatile with the
//!       same mean; the W1-2 score formula ranks A above B even though
//!       B's mean is marginally higher.
//!   (c) Reproducibility: identical inputs run twice must produce
//!       bit-identical aggregated stats + per-split metric finite
//!       components.
//!   (d) Cross-process / cross-reopen determinism: persist, drop the
//!       connection, reopen the on-disk database, read back via
//!       top_n_walk_forward, and confirm the deserialized splits_json
//!       reproduces the live aggregated_score byte-for-byte.

use std::collections::BTreeMap;

use tempfile::NamedTempFile;

use trading_engine::backtest::BacktestConfig;
use trading_engine::models::{Candle, Timeframe};
use trading_engine::optimizer::{
    aggregate_walk_forward, run_walk_forward_trial, ScoreConstraints, StrategyKind,
    StudyStorage, TrialMetrics, TrialParams, WalkForwardConfig, WalkForwardSplitResult,
};

// ─── Fixtures ────────────────────────────────────────────────────────────────

/// Deterministic synthetic 1-hour candle series — identical inputs
/// always produce identical output (pure function of `n`).
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

fn wf_config(train: usize, validate: usize, step: usize) -> WalkForwardConfig {
    WalkForwardConfig {
        train_bars: train,
        validate_bars: validate,
        step_bars: step,
        stability_penalty: 0.5,
    }
}

fn metrics_with_pf(pf: f64, trades: u32) -> TrialMetrics {
    TrialMetrics {
        total_trades: trades,
        total_pnl: 100.0,
        win_rate: 55.0,
        sharpe_ratio: 1.0,
        max_drawdown_pct: 8.0,
        profit_factor: pf,
        final_equity: 10_100.0,
    }
}

fn handcraft_split(i: usize, train_pf: f64, validate_pf: f64) -> WalkForwardSplitResult {
    WalkForwardSplitResult {
        split_index: i,
        train_metrics: metrics_with_pf(train_pf, 50),
        validate_metrics: metrics_with_pf(validate_pf, 50),
    }
}

// ─── (a) Smoke + Persistence ─────────────────────────────────────────────────

/// 500-candle synthetic + Ichimoku-default params under (train=200,
/// validate=50, step=50) yields exactly 6 splits. Every split is
/// persisted, top_n_walk_forward returns the single trial.
#[test]
fn walk_forward_smoke_persists_six_splits_for_ichimoku_default() {
    let candles = synthetic_candles(500);
    let config = wf_config(200, 50, 50);

    let result = run_walk_forward_trial(
        StrategyKind::Ichimoku,
        515,
        ichimoku_default_params(),
        &candles,
        &config,
        h1_base_config(),
        &permissive_constraints(),
    )
    .expect("smoke run must succeed on 500 candles");

    assert_eq!(result.splits.len(), 6, "expected 6 splits, got {}", result.splits.len());
    assert_eq!(result.trial_id, 515);

    // Persist + read back.
    let db = NamedTempFile::new().unwrap();
    let storage = StudyStorage::open(db.path()).unwrap();
    let study_id = storage
        .create_study("wf_smoke_ichimoku", "ichimoku", "yaml-placeholder")
        .unwrap();
    storage
        .insert_walk_forward_trial(study_id, &result, &config)
        .unwrap();

    assert_eq!(storage.count_walk_forward_trials(study_id).unwrap(), 1);

    let top = storage.top_n_walk_forward(study_id, 5).unwrap();
    assert_eq!(top.len(), 1, "exactly one trial persisted");
    assert_eq!(top[0].trial_id, 515);
    assert_eq!(top[0].splits.len(), 6);
}

// ─── (b) Stability-Score Sanity ──────────────────────────────────────────────

/// Trial A: flat OOS PF [1.5; 6] → mean=1.5, std=0, agg=1.5
/// Trial B: volatile OOS PF [3.0, 0.1, 3.0, 0.1, 3.0, 0.1] → mean=1.55,
/// std≈1.45, agg = 1.55 - 1.45*0.5 = 0.825 (exact by formula).
/// Persisted side-by-side, top_n_walk_forward returns A first.
#[test]
fn stability_score_ranks_flat_trial_above_volatile_with_same_mean() {
    let a_splits: Vec<_> = (0..6).map(|i| handcraft_split(i, 1.5, 1.5)).collect();
    let b_pfs = [3.0, 0.1, 3.0, 0.1, 3.0, 0.1];
    let b_splits: Vec<_> = (0..6)
        .map(|i| handcraft_split(i, 1.5, b_pfs[i]))
        .collect();

    let a = aggregate_walk_forward(101, TrialParams::new(), a_splits, 0.5);
    let b = aggregate_walk_forward(202, TrialParams::new(), b_splits, 0.5);

    // Mean check: B's mean (1.55) is marginally higher, so a pure
    // mean-based ranking would prefer B — confirming the stability
    // penalty is what flips the order.
    assert!(b.mean_oos_pf > a.mean_oos_pf, "B's raw mean must exceed A's");
    assert!(
        a.aggregated_score > b.aggregated_score,
        "stability must win: a_agg={} (mean={}, std={}) vs b_agg={} (mean={}, std={})",
        a.aggregated_score,
        a.mean_oos_pf,
        a.std_oos_pf,
        b.aggregated_score,
        b.mean_oos_pf,
        b.std_oos_pf,
    );

    // Persisted ordering must mirror the in-memory ranking.
    let db = NamedTempFile::new().unwrap();
    let storage = StudyStorage::open(db.path()).unwrap();
    let study_id = storage.create_study("wf_stability", "ichimoku", "yaml").unwrap();
    let config = wf_config(200, 50, 50);
    storage.insert_walk_forward_trial(study_id, &a, &config).unwrap();
    storage.insert_walk_forward_trial(study_id, &b, &config).unwrap();

    let top = storage.top_n_walk_forward(study_id, 5).unwrap();
    assert_eq!(top[0].trial_id, 101, "A must rank first");
    assert_eq!(top[1].trial_id, 202, "B must rank second");
}

// ─── (c) Reproducibility ─────────────────────────────────────────────────────

/// Two consecutive runs with identical inputs must produce identical
/// aggregated stats and identical per-split finite metric components.
/// This is the contract that lets Welle-W2 commit a `studies-*-wf.db`
/// snapshot as a reproducible binary artefact.
#[test]
fn run_walk_forward_trial_is_bit_reproducible_for_identical_inputs() {
    let candles = synthetic_candles(500);
    let config = wf_config(200, 50, 50);

    let a = run_walk_forward_trial(
        StrategyKind::Ichimoku,
        7,
        ichimoku_default_params(),
        &candles,
        &config,
        h1_base_config(),
        &permissive_constraints(),
    )
    .unwrap();
    let b = run_walk_forward_trial(
        StrategyKind::Ichimoku,
        7,
        ichimoku_default_params(),
        &candles,
        &config,
        h1_base_config(),
        &permissive_constraints(),
    )
    .unwrap();

    assert_eq!(a.aggregated_score, b.aggregated_score);
    assert_eq!(a.mean_oos_pf, b.mean_oos_pf);
    assert_eq!(a.std_oos_pf, b.std_oos_pf);
    assert_eq!(a.worst_oos_pf, b.worst_oos_pf);
    assert_eq!(a.mean_is_pf, b.mean_is_pf);
    assert_eq!(a.is_oos_decay, b.is_oos_decay);
    assert_eq!(a.splits.len(), b.splits.len());
    for (sa, sb) in a.splits.iter().zip(b.splits.iter()) {
        assert_eq!(sa.split_index, sb.split_index);
        assert_eq!(sa.train_metrics.total_trades, sb.train_metrics.total_trades);
        assert_eq!(sa.validate_metrics.total_trades, sb.validate_metrics.total_trades);
        assert_eq!(sa.train_metrics.final_equity, sb.train_metrics.final_equity);
        assert_eq!(sa.validate_metrics.final_equity, sb.validate_metrics.final_equity);
    }
}

// ─── (d) Cross-Reopen Determinism ────────────────────────────────────────────

/// Persist a walk-forward result to disk, drop the connection, reopen
/// in a fresh `StudyStorage`, and confirm:
///
/// 1. The aggregated stat columns (stored as `REAL` f64) round-trip
///    **bit-identically** between live and restored.
/// 2. The per-split `splits_json` JSON column produces a deserialized
///    `WalkForwardResult` whose finite f64 fields agree with the
///    original within `≤ 1 ULP` (≈ `5e-12` relative). `serde_json` +
///    `ryu` use shortest-roundtrip f64 formatting that is parser-stable
///    but not always bit-identical on parse-back, so the per-split
///    metric f64 bits may shift by a single ULP after the JSON cycle.
/// 3. Re-persisting the live result a second time into a separate DB
///    produces **byte-identical** `splits_json` content — the
///    cross-process determinism contract that Welle-W2 sweep DB hash
///    stability claims rest on.
#[test]
fn persisted_walk_forward_result_matches_recomputed_after_reopen() {
    let candles = synthetic_candles(500);
    let config = wf_config(200, 50, 50);

    let live = run_walk_forward_trial(
        StrategyKind::Ichimoku,
        42,
        ichimoku_default_params(),
        &candles,
        &config,
        h1_base_config(),
        &permissive_constraints(),
    )
    .unwrap();

    let db = NamedTempFile::new().unwrap();
    let study_id;
    {
        let storage = StudyStorage::open(db.path()).unwrap();
        study_id = storage
            .create_study("wf_xprocess", "ichimoku", "yaml-placeholder")
            .unwrap();
        storage.insert_walk_forward_trial(study_id, &live, &config).unwrap();
    }
    // Connection dropped — reopen.
    let storage = StudyStorage::open(db.path()).unwrap();
    let restored_top = storage.top_n_walk_forward(study_id, 1).unwrap();
    assert_eq!(restored_top.len(), 1);
    let restored = &restored_top[0];

    // (1) REAL-column f64s must match bit-for-bit.
    assert_eq!(restored.aggregated_score, live.aggregated_score);
    assert_eq!(restored.mean_oos_pf, live.mean_oos_pf);
    assert_eq!(restored.std_oos_pf, live.std_oos_pf);
    assert_eq!(restored.worst_oos_pf, live.worst_oos_pf);
    assert_eq!(restored.mean_is_pf, live.mean_is_pf);
    assert_eq!(restored.is_oos_decay, live.is_oos_decay);

    // Params survive the BTreeMap-backed JSON serialization with byte-
    // identical key ordering, so deep equality is well-defined here.
    assert_eq!(restored.params, live.params);

    // (2) Per-split f64 fields tolerate ≤1 ULP drift through the JSON
    // round-trip; total_trades (integer) and split_index must match
    // exactly.
    assert_eq!(restored.splits.len(), live.splits.len());
    fn approx_eq(a: f64, b: f64) -> bool {
        if !a.is_finite() || !b.is_finite() {
            return false;
        }
        let scale = a.abs().max(b.abs()).max(1.0);
        (a - b).abs() <= scale * 1e-12
    }
    for (rs, ls) in restored.splits.iter().zip(live.splits.iter()) {
        assert_eq!(rs.split_index, ls.split_index);
        assert_eq!(rs.train_metrics.total_trades, ls.train_metrics.total_trades);
        assert_eq!(rs.validate_metrics.total_trades, ls.validate_metrics.total_trades);
        assert!(
            approx_eq(rs.train_metrics.final_equity, ls.train_metrics.final_equity),
            "train final_equity ULP-drift: {} vs {}",
            rs.train_metrics.final_equity,
            ls.train_metrics.final_equity,
        );
        assert!(
            approx_eq(rs.validate_metrics.final_equity, ls.validate_metrics.final_equity),
            "validate final_equity ULP-drift: {} vs {}",
            rs.validate_metrics.final_equity,
            ls.validate_metrics.final_equity,
        );
    }

    // (3) Byte-identical `splits_json` across two independent persist
    // cycles. This is the actual cross-process determinism property:
    // the on-disk bytes are stable, even though their f64 parse may
    // differ from the live source by ≤1 ULP.
    let db_b = NamedTempFile::new().unwrap();
    let storage_b = StudyStorage::open(db_b.path()).unwrap();
    let study_id_b = storage_b
        .create_study("wf_xprocess_b", "ichimoku", "yaml-placeholder")
        .unwrap();
    storage_b.insert_walk_forward_trial(study_id_b, &live, &config).unwrap();

    let bytes_a = read_splits_json_bytes(db.path(), study_id);
    let bytes_b = read_splits_json_bytes(db_b.path(), study_id_b);
    assert_eq!(
        bytes_a, bytes_b,
        "splits_json bytes must be identical across two independent persist cycles",
    );

    // Bonus: a fresh recomputation with the same inputs reproduces the
    // live aggregated_score bit-for-bit.
    let recomputed = run_walk_forward_trial(
        StrategyKind::Ichimoku,
        42,
        ichimoku_default_params(),
        &candles,
        &config,
        h1_base_config(),
        &permissive_constraints(),
    )
    .unwrap();
    assert_eq!(recomputed.aggregated_score, live.aggregated_score);
}

/// Read the raw `splits_json` text for the single trial belonging to
/// `study_id`. Used by the cross-process determinism test to assert
/// byte-stability of the on-disk JSON payload.
fn read_splits_json_bytes(db_path: &std::path::Path, study_id: i64) -> String {
    let conn = rusqlite::Connection::open(db_path).unwrap();
    conn.query_row(
        "SELECT splits_json FROM walk_forward_trials WHERE study_id = ?1 LIMIT 1",
        rusqlite::params![study_id],
        |row| row.get::<_, String>(0),
    )
    .unwrap()
}

// ─── (e) TrialParams key-ordering sanity ─────────────────────────────────────

/// Final guard: `TrialParams` uses `BTreeMap`, so two insertion orders
/// produce byte-identical JSON. This is the cross-process determinism
/// property that the W1 walk-forward DB inherits from the Welle-O2 fix.
#[test]
fn trial_params_json_independent_of_insertion_order() {
    let mut a = TrialParams::new();
    a.insert("kijun_period", 26.0);
    a.insert("tenkan_period", 9.0);
    a.insert("senkou_b_period", 52.0);

    let mut b = TrialParams::new();
    b.insert("senkou_b_period", 52.0);
    b.insert("kijun_period", 26.0);
    b.insert("tenkan_period", 9.0);

    let json_a = serde_json::to_string(&a).unwrap();
    let json_b = serde_json::to_string(&b).unwrap();
    assert_eq!(json_a, json_b);

    // And the deserialized values agree as well — sanity on the
    // BTreeMap iteration order.
    let a_back: TrialParams = serde_json::from_str(&json_a).unwrap();
    let b_back: TrialParams = serde_json::from_str(&json_b).unwrap();
    assert_eq!(a_back.values.keys().collect::<Vec<_>>(), b_back.values.keys().collect::<Vec<_>>());
    let _: &BTreeMap<String, f64> = &a_back.values;
}
