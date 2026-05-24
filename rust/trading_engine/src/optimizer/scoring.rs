//! Composite-score function and strategy-specific score constraints.
//!
//! # Score formula
//!
//! ```text
//! score = profit_factor + max(0.0, sharpe_ratio) * 0.1
//! ```
//!
//! with three disqualification gates that short-circuit to
//! `f64::NEG_INFINITY`:
//!
//! 1. `max_drawdown_pct > constraints.max_drawdown_cap_pct`
//! 2. `total_trades < constraints.min_trades`
//! 3. `profit_factor` is `NaN` or infinite (e.g. zero gross loss)
//!
//! Profit-Factor is the optimizer's primary objective because the Phase-2
//! XLSX targets are PF-anchored; the small Sharpe bonus is a tie-breaker
//! between two trials with the same PF, preferring smoother equity curves.
//!
//! # Strategy-specific constraints
//! Drawdown caps are XLSX-target + 5 pp tolerance; min-trade counts pick
//! the sample-size floor where the Profit-Factor reading stops being a
//! single-trade artifact for that strategy's natural cadence.

use super::{ScoreConstraints, TrialMetrics};

/// Compute the composite score for a single trial. Returns
/// `f64::NEG_INFINITY` if any disqualification gate fails.
pub fn score_trial(metrics: &TrialMetrics, constraints: &ScoreConstraints) -> f64 {
    if metrics.max_drawdown_pct > constraints.max_drawdown_cap_pct {
        return f64::NEG_INFINITY;
    }
    if metrics.total_trades < constraints.min_trades {
        return f64::NEG_INFINITY;
    }
    if !metrics.profit_factor.is_finite() {
        return f64::NEG_INFINITY;
    }

    let pf = metrics.profit_factor;
    let sharpe_bonus = if metrics.sharpe_ratio > 0.0 {
        metrics.sharpe_ratio * 0.1
    } else {
        0.0
    };
    pf + sharpe_bonus
}

/// The optimizer-target strategies recognized by Welle O1.
///
/// Stored as a strongly-typed enum (rather than passing strategy strings)
/// so callers can never typo "BB+RSI" / "bb_rsi" / "BBRsi" inconsistently
/// across study creation and constraint lookup.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StrategyKind {
    BbRsi,
    UtBot,
    Ichimoku,
}

impl StrategyKind {
    /// Canonical lowercase identifier matching the `strategy_name` in YAML
    /// search-space files and the SQLite `strategy` column.
    pub fn as_str(&self) -> &'static str {
        match self {
            StrategyKind::BbRsi => "bb_rsi",
            StrategyKind::UtBot => "ut_bot",
            StrategyKind::Ichimoku => "ichimoku",
        }
    }
}

/// Strategy-specific `ScoreConstraints` for the Welle O1 MVP sweep.
///
/// Drawdown caps are XLSX-target + 5 pp tolerance; min-trade counts pick
/// a statistically meaningful sample floor for each strategy's natural
/// cadence on H1 / M5 / H1 timeframes respectively.
pub fn score_constraints_for_strategy(kind: StrategyKind) -> ScoreConstraints {
    match kind {
        StrategyKind::BbRsi => ScoreConstraints {
            max_drawdown_cap_pct: 19.0,
            min_trades: 30,
        },
        StrategyKind::UtBot => ScoreConstraints {
            max_drawdown_cap_pct: 17.0,
            min_trades: 50,
        },
        StrategyKind::Ichimoku => ScoreConstraints {
            max_drawdown_cap_pct: 15.0,
            min_trades: 60,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn baseline_metrics() -> TrialMetrics {
        TrialMetrics {
            total_trades: 100,
            total_pnl: 500.0,
            win_rate: 55.0,
            sharpe_ratio: 1.5,
            max_drawdown_pct: 10.0,
            profit_factor: 1.8,
            final_equity: 10_500.0,
        }
    }

    fn baseline_constraints() -> ScoreConstraints {
        ScoreConstraints {
            max_drawdown_cap_pct: 20.0,
            min_trades: 30,
        }
    }

    #[test]
    fn disqualifies_when_drawdown_exceeds_cap() {
        let mut m = baseline_metrics();
        m.max_drawdown_pct = 25.0;
        assert_eq!(score_trial(&m, &baseline_constraints()), f64::NEG_INFINITY);
    }

    #[test]
    fn passes_when_drawdown_exactly_equals_cap() {
        // Cap is inclusive on the passing side — only *strictly greater*
        // disqualifies. Documenting this so the constraint is unambiguous.
        let mut m = baseline_metrics();
        m.max_drawdown_pct = 20.0;
        assert!(score_trial(&m, &baseline_constraints()).is_finite());
    }

    #[test]
    fn disqualifies_when_trades_below_min() {
        let mut m = baseline_metrics();
        m.total_trades = 10;
        assert_eq!(score_trial(&m, &baseline_constraints()), f64::NEG_INFINITY);
    }

    #[test]
    fn disqualifies_when_profit_factor_is_nan() {
        let mut m = baseline_metrics();
        m.profit_factor = f64::NAN;
        assert_eq!(score_trial(&m, &baseline_constraints()), f64::NEG_INFINITY);
    }

    #[test]
    fn disqualifies_when_profit_factor_is_infinite() {
        let mut m = baseline_metrics();
        m.profit_factor = f64::INFINITY;
        assert_eq!(score_trial(&m, &baseline_constraints()), f64::NEG_INFINITY);
    }

    #[test]
    fn composite_score_is_pf_plus_sharpe_bonus_when_qualified() {
        // PF = 1.8, Sharpe = 1.5 → bonus = 0.15 → score = 1.95
        let score = score_trial(&baseline_metrics(), &baseline_constraints());
        assert!((score - 1.95).abs() < 1e-12, "got {}", score);
    }

    #[test]
    fn negative_sharpe_does_not_subtract_from_score() {
        let mut m = baseline_metrics();
        m.sharpe_ratio = -0.5;
        // bonus floored at 0 → score = pf
        let score = score_trial(&m, &baseline_constraints());
        assert!((score - 1.8).abs() < 1e-12, "got {}", score);
    }

    #[test]
    fn zero_sharpe_does_not_add_to_score() {
        let mut m = baseline_metrics();
        m.sharpe_ratio = 0.0;
        let score = score_trial(&m, &baseline_constraints());
        assert!((score - 1.8).abs() < 1e-12, "got {}", score);
    }

    #[test]
    fn strategy_constraints_match_xlsx_targets_plus_tolerance() {
        let bb = score_constraints_for_strategy(StrategyKind::BbRsi);
        assert_eq!(bb.max_drawdown_cap_pct, 19.0);
        assert_eq!(bb.min_trades, 30);

        let ut = score_constraints_for_strategy(StrategyKind::UtBot);
        assert_eq!(ut.max_drawdown_cap_pct, 17.0);
        assert_eq!(ut.min_trades, 50);

        let ich = score_constraints_for_strategy(StrategyKind::Ichimoku);
        assert_eq!(ich.max_drawdown_cap_pct, 15.0);
        assert_eq!(ich.min_trades, 60);
    }

    #[test]
    fn strategy_kind_as_str_matches_yaml_strategy_name() {
        assert_eq!(StrategyKind::BbRsi.as_str(), "bb_rsi");
        assert_eq!(StrategyKind::UtBot.as_str(), "ut_bot");
        assert_eq!(StrategyKind::Ichimoku.as_str(), "ichimoku");
    }
}
