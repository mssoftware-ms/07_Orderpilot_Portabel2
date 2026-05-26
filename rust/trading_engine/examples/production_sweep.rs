//! Production parameter sweep for one strategy.
//!
//! CLI:
//!     cargo run --release --example production_sweep -- \
//!         <strategy> <n_trials> [seed] [tf_variant]
//!
//!     strategy   ∈ { bb_rsi, ut_bot, ichimoku }
//!     n_trials   = positive integer (per Welle-O2 brief: 500 or 1000)
//!     seed       = u64, default 42
//!     tf_variant ∈ { main, 1h } (default: main). Welle A1 uses
//!                  `bb_rsi 1000 42 1h` to validate the TF-mismatch
//!                  hypothesis from the Welle-O2 bb_rsi 4h sweep.
//!
//! Outputs (all under `01_Projectplan/`, variant suffix `_{variant}`
//! when not `main`):
//!     optimizer_studies/studies-<strategy>[_variant].db
//!     optimizer_studies/top10-<strategy>[_variant].csv
//!     specs/<strategy>[_variant]_sweep_<SWEEP_DATE>.md
//!
//! Each invocation creates a FRESH study row inside the DB (study name
//! includes `variant`, `n_trials`, `seed`, and the date). Re-running
//! with the same args therefore errors on UNIQUE name conflict —
//! re-run with a new seed or rename the DB to overwrite.
//!
//! The study DB sticks under `01_Projectplan/` because it is the
//! source-of-truth for Top-N reproducibility (committed alongside
//! the report MD). Total size stays < 10 MB per sweep (5 KB / trial).

use std::fs::{create_dir_all, File};
use std::io::{BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{bail, Context, Result};
use chrono::Utc;

use trading_engine::backtest::BacktestConfig;
use trading_engine::models::{Candle, Timeframe};
use trading_engine::optimizer::{
    parse_search_space, score_constraints_for_strategy, RandomSearchEngine, ScoreConstraints,
    StrategyKind, StudyStorage, TrialResult,
};

// ─── Config ──────────────────────────────────────────────────────────────────

const INITIAL_BALANCE: f64 = 10_000.0;
const FEE_RATE: f64 = 0.0006; // Bitunix VIP0 taker
const SLIPPAGE_BPS: f64 = 0.0;
const DEFAULT_SEED: u64 = 42;
const DEFAULT_VARIANT: &str = "main";
// Bumped per sweep date (study_name + output filenames embed this).
const SWEEP_DATE: &str = "2026-05-26";

/// Per-strategy data file, search-space YAML, timeframe, XLSX target
/// bands, and per-variant labels for the report MD header.
struct StrategyConfig {
    kind: StrategyKind,
    data_file: &'static str,
    yaml_file: &'static str,
    timeframe: Timeframe,
    asset_label: &'static str,
    timeframe_label: &'static str,
    range_label: &'static str,
    /// Variant identifier (e.g. `main`, `1h`). Drives output filename
    /// suffixes and study_name uniqueness so multiple variants of the
    /// same strategy can coexist in the same DB / specs/ directory.
    variant: &'static str,
    /// Phase + wave label injected into the report MD (`Phase: ...`).
    phase_label: &'static str,
    /// Wave label injected into the report MD title (`# ... Production
    /// Sweep (<sweep_label>)`).
    sweep_label: &'static str,
    // XLSX-Band-Check thresholds:
    trades_band: (u32, u32),
    win_rate_band_pct: (f64, f64),
    profit_factor_band: (f64, f64),
    max_drawdown_cap_pct: f64,
    profit_pct_band: (f64, f64),
}

fn config_for(kind: StrategyKind, variant: &str) -> Result<StrategyConfig> {
    match (kind, variant) {
        (StrategyKind::BbRsi, "main") => Ok(StrategyConfig {
            kind,
            data_file: "01_Projectplan/optimizer_data/BTCUSDT_4h_2024-01-01_2024-07-01.json",
            yaml_file: "01_Projectplan/search_spaces/bb_rsi.yaml",
            timeframe: Timeframe::H4,
            asset_label: "BTCUSDT",
            timeframe_label: "4h",
            range_label: "2024-01-01 → 2024-07-01",
            variant: "main",
            phase_label: "3 — Welle O2",
            sweep_label: "Welle O2",
            trades_band: (80, 120),
            win_rate_band_pct: (33.0, 43.0),
            profit_factor_band: (1.58, 2.18),
            max_drawdown_cap_pct: 19.0,
            profit_pct_band: (83.0, 133.0),
        }),
        (StrategyKind::BbRsi, "1h") => Ok(StrategyConfig {
            kind,
            data_file: "01_Projectplan/optimizer_data/BTCUSDT_1h_2024-01-01_2024-07-01.json",
            yaml_file: "01_Projectplan/search_spaces/bb_rsi_1h.yaml",
            timeframe: Timeframe::H1,
            asset_label: "BTCUSDT",
            timeframe_label: "1h",
            range_label: "2024-01-01 → 2024-07-01",
            variant: "1h",
            phase_label: "3.2 — Welle A1",
            sweep_label: "Welle A1 (TF-mismatch hypothesis)",
            trades_band: (80, 120),
            win_rate_band_pct: (33.0, 43.0),
            profit_factor_band: (1.58, 2.18),
            max_drawdown_cap_pct: 19.0,
            profit_pct_band: (83.0, 133.0),
        }),
        (StrategyKind::UtBot, "main") => Ok(StrategyConfig {
            kind,
            data_file: "01_Projectplan/optimizer_data/BTCUSDT_5m_2024-01-01_2024-03-08.json",
            yaml_file: "01_Projectplan/search_spaces/ut_bot.yaml",
            timeframe: Timeframe::M5,
            asset_label: "BTCUSDT",
            timeframe_label: "5m",
            range_label: "2024-01-01 → 2024-03-08",
            variant: "main",
            phase_label: "3 — Welle O2",
            sweep_label: "Welle O2",
            trades_band: (80, 120),
            win_rate_band_pct: (48.0, 58.0),
            profit_factor_band: (2.01, 2.61),
            max_drawdown_cap_pct: 17.0,
            profit_pct_band: (98.0, 148.0),
        }),
        (StrategyKind::Ichimoku, "main") => Ok(StrategyConfig {
            kind,
            data_file: "01_Projectplan/optimizer_data/BTCUSDT_1h_2023-04-01_2025-05-02.json",
            yaml_file: "01_Projectplan/search_spaces/ichimoku.yaml",
            timeframe: Timeframe::H1,
            asset_label: "BTCUSDT",
            timeframe_label: "1h",
            range_label: "2023-04-01 → 2025-05-02",
            variant: "main",
            phase_label: "3 — Welle O2",
            sweep_label: "Welle O2",
            trades_band: (75, 125),
            win_rate_band_pct: (50.0, 60.0),
            profit_factor_band: (2.14, 2.74),
            max_drawdown_cap_pct: 15.0,
            profit_pct_band: (95.0, 145.0),
        }),
        (k, v) => bail!(
            "unknown variant '{}' for strategy '{}' (supported: bb_rsi:[main|1h], ut_bot:[main], ichimoku:[main])",
            v,
            k.as_str()
        ),
    }
}

/// Filename suffix derived from variant. `main` stays empty for
/// backwards compatibility with existing Welle-O2 file naming.
fn variant_marker(variant: &str) -> String {
    if variant == DEFAULT_VARIANT {
        String::new()
    } else {
        format!("_{}", variant)
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("crate dir has a great-grandparent")
        .to_path_buf()
}

fn load_candles(path: &Path) -> Result<Vec<Candle>> {
    let file = File::open(path)
        .with_context(|| format!("open candles {}", path.display()))?;
    let candles: Vec<Candle> = serde_json::from_reader(BufReader::new(file))
        .with_context(|| format!("parse candles {}", path.display()))?;
    Ok(candles)
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

// ─── Histogram ───────────────────────────────────────────────────────────────

/// 8-bucket histogram between `min` and `max` (inclusive). Values
/// outside the range clamp into edge buckets. Returns
/// `[(bucket_min, bucket_max, count), ...]` for pretty printing.
fn histogram(
    values: &[f64],
    min: f64,
    max: f64,
    buckets: usize,
) -> Vec<(f64, f64, usize)> {
    if buckets == 0 || values.is_empty() || max <= min {
        return Vec::new();
    }
    let width = (max - min) / buckets as f64;
    let mut counts = vec![0usize; buckets];
    for &v in values {
        let idx = if v <= min {
            0
        } else if v >= max {
            buckets - 1
        } else {
            (((v - min) / width).floor() as usize).min(buckets - 1)
        };
        counts[idx] += 1;
    }
    (0..buckets)
        .map(|i| (min + i as f64 * width, min + (i + 1) as f64 * width, counts[i]))
        .collect()
}

fn ascii_histogram(hist: &[(f64, f64, usize)], label_fmt: &str) -> String {
    let max_count = hist.iter().map(|t| t.2).max().unwrap_or(0).max(1);
    let mut out = String::new();
    for (lo, hi, count) in hist {
        let bar_len = (*count as f64 / max_count as f64 * 40.0).round() as usize;
        let bar = "█".repeat(bar_len);
        let label = match label_fmt {
            "pct" => format!("{:>6.2}–{:>6.2}", lo, hi),
            "int" => format!("{:>4.0}–{:>4.0}", lo, hi),
            _ => format!("{:>6.3}–{:>6.3}", lo, hi),
        };
        out.push_str(&format!("    {} │ {:>4}  {}\n", label, count, bar));
    }
    out
}

// ─── XLSX Band Check ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
struct BandCheck {
    trades_ok: bool,
    win_rate_ok: bool,
    profit_factor_ok: bool,
    max_drawdown_ok: bool,
    profit_pct_ok: bool,
}

impl BandCheck {
    fn from_trial(trial: &TrialResult, cfg: &StrategyConfig) -> Self {
        let trades = trial.metrics.total_trades;
        let wr = trial.metrics.win_rate;
        let pf = trial.metrics.profit_factor;
        let dd = trial.metrics.max_drawdown_pct;
        let profit_pct = (trial.metrics.final_equity - INITIAL_BALANCE)
            / INITIAL_BALANCE
            * 100.0;
        BandCheck {
            trades_ok: trades >= cfg.trades_band.0 && trades <= cfg.trades_band.1,
            win_rate_ok: wr >= cfg.win_rate_band_pct.0 && wr <= cfg.win_rate_band_pct.1,
            profit_factor_ok: pf >= cfg.profit_factor_band.0
                && pf <= cfg.profit_factor_band.1,
            max_drawdown_ok: dd < cfg.max_drawdown_cap_pct,
            profit_pct_ok: profit_pct >= cfg.profit_pct_band.0
                && profit_pct <= cfg.profit_pct_band.1,
        }
    }

    fn count(&self) -> usize {
        [
            self.trades_ok,
            self.win_rate_ok,
            self.profit_factor_ok,
            self.max_drawdown_ok,
            self.profit_pct_ok,
        ]
        .into_iter()
        .filter(|b| *b)
        .count()
    }
}

// ─── CSV + MD Writers ────────────────────────────────────────────────────────

fn write_top10_csv(top: &[TrialResult], path: &Path) -> Result<()> {
    let mut file = File::create(path)
        .with_context(|| format!("create CSV {}", path.display()))?;
    // Discover param keys from the first available trial — every trial
    // in one study carries the same param schema regardless of whether
    // the score gate passed.
    let mut param_keys: Vec<&String> = top
        .first()
        .map(|t| t.params.values.keys().collect())
        .unwrap_or_default();
    param_keys.sort();
    write!(file, "rank,trial_id,score,profit_factor,sharpe,trades,win_rate_pct,max_dd_pct,final_equity")?;
    for k in &param_keys {
        write!(file, ",p_{}", k)?;
    }
    writeln!(file)?;
    for (i, t) in top.iter().enumerate() {
        write!(
            file,
            "{},{},{},{},{},{},{},{},{}",
            i + 1,
            t.trial_id,
            t.score,
            t.metrics.profit_factor,
            t.metrics.sharpe_ratio,
            t.metrics.total_trades,
            t.metrics.win_rate,
            t.metrics.max_drawdown_pct,
            t.metrics.final_equity,
        )?;
        for k in &param_keys {
            let v = t.params.values.get(*k).copied().unwrap_or(f64::NAN);
            write!(file, ",{}", v)?;
        }
        writeln!(file)?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn write_report_md(
    path: &Path,
    cfg: &StrategyConfig,
    candles: usize,
    n_trials: u32,
    seed: u64,
    elapsed_secs: f64,
    all_trials: &[TrialResult],
    top_n: &[TrialResult],
    constraints: &ScoreConstraints,
) -> Result<()> {
    let qualified: Vec<&TrialResult> = all_trials
        .iter()
        .filter(|t| t.score.is_finite())
        .collect();
    let qualified_count = qualified.len();
    let disq_count = all_trials.len() - qualified_count;

    // Histograms on qualified trials only — disq trials have score=-inf
    // and uninteresting metric clusters at 0.
    let pfs: Vec<f64> = qualified.iter().map(|t| t.metrics.profit_factor).collect();
    let dds: Vec<f64> = qualified.iter().map(|t| t.metrics.max_drawdown_pct).collect();
    let trades: Vec<f64> = qualified
        .iter()
        .map(|t| t.metrics.total_trades as f64)
        .collect();

    let pf_min = pfs.iter().cloned().fold(f64::INFINITY, f64::min);
    let pf_max = pfs.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let dd_min = dds.iter().cloned().fold(f64::INFINITY, f64::min);
    let dd_max = dds.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let tr_min = trades.iter().cloned().fold(f64::INFINITY, f64::min);
    let tr_max = trades.iter().cloned().fold(f64::NEG_INFINITY, f64::max);

    let pf_hist = histogram(&pfs, pf_min, pf_max, 8);
    let dd_hist = histogram(&dds, dd_min, dd_max, 8);
    let tr_hist = histogram(&trades, tr_min, tr_max, 8);

    let mut md = String::new();
    md.push_str(&format!(
        "# {} Production Sweep ({})\n\n",
        cfg.kind.as_str(),
        cfg.sweep_label
    ));
    md.push_str(&format!("**Datum:** {}  \n", SWEEP_DATE));
    md.push_str(&format!("**Phase:** {}  \n", cfg.phase_label));
    md.push_str(&format!(
        "**Asset/TF:** {} / {}  \n",
        cfg.asset_label, cfg.timeframe_label
    ));
    md.push_str(&format!("**Range:** {}  \n", cfg.range_label));
    md.push_str(&format!("**Candles:** {}  \n", candles));
    md.push_str(&format!("**Trials:** {}  \n", n_trials));
    md.push_str(&format!("**Seed:** {}  \n", seed));
    md.push_str(&format!(
        "**Score-Constraints:** max_drawdown_cap_pct = {}, min_trades = {}  \n",
        constraints.max_drawdown_cap_pct, constraints.min_trades
    ));
    md.push_str(
        "**Engine:** Bitunix-VIP0 0.06 % Taker-Fee pro Seite, 10.000 USDT Startkapital, F-04 Next-Bar-Open, slippage_bps = 0  \n",
    );
    md.push_str(&format!(
        "**Compute:** {:.1}s reine Sweep-Zeit ({:.1} ms/trial)  \n\n",
        elapsed_secs,
        elapsed_secs * 1000.0 / n_trials as f64
    ));
    md.push_str("---\n\n");

    // ─── Qualification stats ────────────────────────────────────────────
    md.push_str("## 1. Trial-Qualification\n\n");
    let qual_ratio = qualified_count as f64 / all_trials.len().max(1) as f64 * 100.0;
    md.push_str(&format!(
        "{} / {} Trials qualifiziert ({:.1} %).  \n",
        qualified_count,
        all_trials.len(),
        qual_ratio
    ));
    md.push_str(&format!(
        "{} Trials disqualifiziert (max_drawdown_cap_pct > {} oder total_trades < {} oder profit_factor nicht endlich).\n\n",
        disq_count, constraints.max_drawdown_cap_pct, constraints.min_trades
    ));

    // ─── Top-10 ────────────────────────────────────────────────────────
    md.push_str("## 2. Top-10\n\n");
    md.push_str("| Rank | Trial | Score | PF | Sharpe | Trades | WR % | MaxDD % | profit % | final equity |\n");
    md.push_str("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n");
    for (i, t) in top_n.iter().enumerate().take(10) {
        let profit_pct =
            (t.metrics.final_equity - INITIAL_BALANCE) / INITIAL_BALANCE * 100.0;
        md.push_str(&format!(
            "| {} | {} | {:.4} | {:.3} | {:+.3} | {} | {:.2} | {:.2} | {:+.2} | {:.2} |\n",
            i + 1,
            t.trial_id,
            t.score,
            t.metrics.profit_factor,
            t.metrics.sharpe_ratio,
            t.metrics.total_trades,
            t.metrics.win_rate,
            t.metrics.max_drawdown_pct,
            profit_pct,
            t.metrics.final_equity,
        ));
    }
    md.push('\n');

    // ─── XLSX Band Check Top-5 ──────────────────────────────────────────
    md.push_str("## 3. XLSX-Band-Check (Top-5)\n\n");
    md.push_str(&format!(
        "XLSX-Targets ({}):  \n",
        cfg.kind.as_str()
    ));
    md.push_str(&format!(
        "- Trade-Count ∈ [{}, {}]  \n",
        cfg.trades_band.0, cfg.trades_band.1
    ));
    md.push_str(&format!(
        "- WR ∈ [{} %, {} %]  \n",
        cfg.win_rate_band_pct.0, cfg.win_rate_band_pct.1
    ));
    md.push_str(&format!(
        "- PF ∈ [{}, {}]  \n",
        cfg.profit_factor_band.0, cfg.profit_factor_band.1
    ));
    md.push_str(&format!(
        "- MaxDD < {} %  \n",
        cfg.max_drawdown_cap_pct
    ));
    md.push_str(&format!(
        "- profit % ∈ [+{} %, +{} %]\n\n",
        cfg.profit_pct_band.0, cfg.profit_pct_band.1
    ));
    md.push_str("| Rank | Trades | WR % | PF | MaxDD % | profit % | Bands hit |\n");
    md.push_str("|---:|:---:|:---:|:---:|:---:|:---:|:---:|\n");
    for (i, t) in top_n.iter().enumerate().take(5) {
        let bc = BandCheck::from_trial(t, cfg);
        let hit = |b: bool| if b { "✓" } else { "✗" };
        md.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | **{}/5** |\n",
            i + 1,
            hit(bc.trades_ok),
            hit(bc.win_rate_ok),
            hit(bc.profit_factor_ok),
            hit(bc.max_drawdown_ok),
            hit(bc.profit_pct_ok),
            bc.count(),
        ));
    }
    md.push('\n');

    // ─── Top-1 details ──────────────────────────────────────────────────
    if let Some(top1) = top_n.first() {
        md.push_str("## 4. Top-1 Parameter\n\n");
        let mut keys: Vec<&String> = top1.params.values.keys().collect();
        keys.sort();
        md.push_str("| Parameter | Value |\n|---|---:|\n");
        for k in keys {
            let v = top1.params.values.get(k).copied().unwrap_or(f64::NAN);
            md.push_str(&format!("| `{}` | {} |\n", k, v));
        }
        md.push('\n');
    }

    // ─── Histograms ─────────────────────────────────────────────────────
    md.push_str("## 5. Distribution (qualifizierte Trials)\n\n");
    md.push_str("### Profit-Factor\n```\n");
    md.push_str(&ascii_histogram(&pf_hist, ""));
    md.push_str("```\n\n");
    md.push_str("### Max-Drawdown %\n```\n");
    md.push_str(&ascii_histogram(&dd_hist, "pct"));
    md.push_str("```\n\n");
    md.push_str("### Trade-Count\n```\n");
    md.push_str(&ascii_histogram(&tr_hist, "int"));
    md.push_str("```\n\n");

    md.push_str("---\n\n");
    md.push_str(&format!(
        "_Generated by `cargo run --release --example production_sweep -- {} {} {} {}` at {}._\n",
        cfg.kind.as_str(),
        n_trials,
        seed,
        cfg.variant,
        Utc::now().to_rfc3339(),
    ));

    let mut file = File::create(path)
        .with_context(|| format!("create report {}", path.display()))?;
    file.write_all(md.as_bytes())?;
    Ok(())
}

// ─── Main ────────────────────────────────────────────────────────────────────

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        bail!(
            "usage: production_sweep <strategy> <n_trials> [seed] [tf_variant]\n  strategy ∈ {{ bb_rsi, ut_bot, ichimoku }}\n  tf_variant ∈ {{ main, 1h }} (default: main)"
        );
    }
    let strategy = parse_strategy(&args[1])?;
    let n_trials: u32 = args[2].parse().context("n_trials must be u32")?;
    let seed: u64 = if args.len() >= 4 {
        args[3].parse().context("seed must be u64")?
    } else {
        DEFAULT_SEED
    };
    let variant: &str = if args.len() >= 5 {
        args[4].as_str()
    } else {
        DEFAULT_VARIANT
    };
    if n_trials < 10 {
        bail!("n_trials < 10 is not a meaningful sweep");
    }

    let cfg = config_for(strategy, variant)?;
    let marker = variant_marker(cfg.variant);
    let root = repo_root();

    // ─── Load candles + space ───────────────────────────────────────────
    let candles = load_candles(&root.join(cfg.data_file))?;
    let space = parse_search_space(&root.join(cfg.yaml_file))?;
    let constraints = score_constraints_for_strategy(strategy);
    let config = BacktestConfig {
        initial_balance: INITIAL_BALANCE,
        fee_rate: FEE_RATE,
        timeframe: cfg.timeframe,
        slippage_bps: SLIPPAGE_BPS,
    };

    // ─── Open SQLite DB ────────────────────────────────────────────────
    let studies_dir = root.join("01_Projectplan/optimizer_studies");
    create_dir_all(&studies_dir).context("mkdir optimizer_studies")?;
    let db_path = studies_dir.join(format!("studies-{}{}.db", strategy.as_str(), marker));
    let mut storage = StudyStorage::open(&db_path)?;

    let study_name = format!(
        "production_{}{}_n{}_seed{}_{}",
        strategy.as_str(),
        marker,
        n_trials,
        seed,
        SWEEP_DATE,
    );

    println!(
        "[{}] starting sweep: {} candles, {} trials, seed={}",
        study_name,
        candles.len(),
        n_trials,
        seed
    );

    // ─── Run sweep ─────────────────────────────────────────────────────
    let mut engine = RandomSearchEngine::new(seed);
    let start = Instant::now();
    let _top5 = engine.run_study(
        &study_name,
        &space,
        strategy,
        &candles,
        config,
        &constraints,
        n_trials,
        &mut storage,
    )?;
    let elapsed = start.elapsed();

    // ─── Fetch full trial set + Top-100 for report ─────────────────────
    let study_id = storage
        .study_id_by_name(&study_name)?
        .expect("just created");
    // Use top_n_trials with high N to fetch all trials (sorted by score
    // desc). For 1000 trials this is fine — SQLite is fast.
    let top_all = storage.top_n_trials(study_id, n_trials as usize)?;
    let top10: Vec<TrialResult> = top_all.iter().take(10).cloned().collect();

    println!(
        "[{}] done in {:.2}s ({:.1} ms/trial)",
        study_name,
        elapsed.as_secs_f64(),
        elapsed.as_secs_f64() * 1000.0 / n_trials as f64,
    );

    // ─── Console Top-5 report ──────────────────────────────────────────
    println!();
    println!("Top-5:");
    println!("rank trial_id    score     PF   Sharpe trades   WR%  MaxDD%   profit%   final_eq");
    for (i, t) in top_all.iter().enumerate().take(5) {
        let profit_pct =
            (t.metrics.final_equity - INITIAL_BALANCE) / INITIAL_BALANCE * 100.0;
        println!(
            "  {}  {:>7}  {:>7.3}  {:>5.3} {:>+6.3} {:>6} {:>5.2} {:>6.2}  {:>+7.2}  {:>9.2}",
            i + 1,
            t.trial_id,
            t.score,
            t.metrics.profit_factor,
            t.metrics.sharpe_ratio,
            t.metrics.total_trades,
            t.metrics.win_rate,
            t.metrics.max_drawdown_pct,
            profit_pct,
            t.metrics.final_equity,
        );
    }

    // ─── Write Top-10 CSV ──────────────────────────────────────────────
    let csv_path = studies_dir.join(format!("top10-{}{}.csv", strategy.as_str(), marker));
    write_top10_csv(&top10, &csv_path)?;
    println!("wrote {}", csv_path.display());

    // ─── Write Report MD ───────────────────────────────────────────────
    let report_path = root
        .join("01_Projectplan/specs")
        .join(format!("{}{}_sweep_{}.md", strategy.as_str(), marker, SWEEP_DATE));
    write_report_md(
        &report_path,
        &cfg,
        candles.len(),
        n_trials,
        seed,
        elapsed.as_secs_f64(),
        &top_all,
        &top10,
        &constraints,
    )?;
    println!("wrote {}", report_path.display());

    Ok(())
}
