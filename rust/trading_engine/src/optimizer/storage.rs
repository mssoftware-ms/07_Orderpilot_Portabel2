//! SQLite-backed storage for optimizer studies and trials.
//!
//! # Schema
//!
//! ```sql
//! studies(
//!   id                INTEGER PRIMARY KEY,
//!   name              TEXT NOT NULL UNIQUE,
//!   strategy          TEXT NOT NULL,
//!   search_space_yaml TEXT NOT NULL,
//!   created_at        TEXT NOT NULL,
//!   commit_hash       TEXT
//! );
//!
//! trials(
//!   id           INTEGER PRIMARY KEY,
//!   study_id     INTEGER NOT NULL REFERENCES studies(id),
//!   trial_id     INTEGER NOT NULL,
//!   params_json  TEXT NOT NULL,
//!   metrics_json TEXT NOT NULL,
//!   score        REAL NOT NULL,
//!   created_at   TEXT NOT NULL
//! );
//!
//! CREATE INDEX trials_study_score_idx ON trials(study_id, score DESC);
//! ```
//!
//! # Why `bundled` rusqlite
//! The `bundled` feature embeds the SQLite C amalgamation into the crate
//! build. Without it, rusqlite would link against a system sqlite3 — on
//! WSL2 that pulls in the host's libsqlite3-dev (often missing or
//! version-skewed), making the trading_engine crate non-portable.
//!
//! # NaN / Inf sanitization
//! `TrialMetrics` can carry `NaN` (e.g. zero-gross-loss profit_factor) or
//! `±Inf` (overflow on huge equity moves). `serde_json` rejects these on
//! deserialization, so this layer rewrites them to `0.0` *before*
//! serializing `metrics_json`. The `score` column stores the raw
//! `f64::NEG_INFINITY` for disqualified trials — SQLite REAL preserves
//! it bit-for-bit and `ORDER BY score DESC` sorts those rows last.

use std::path::Path;

use anyhow::{Context as _, Result};
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use super::{TrialMetrics, TrialParams, TrialResult};

/// Wrapper around the optimizer SQLite database connection.
pub struct StudyStorage {
    conn: Connection,
}

/// Lightweight metadata row for `list_studies()`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StudyMeta {
    pub id: i64,
    pub name: String,
    pub strategy: String,
    pub created_at: String,
    pub commit_hash: Option<String>,
}

impl StudyStorage {
    /// Open (or create) the SQLite database at `path` and run the schema
    /// migration. Idempotent: running on an existing DB is a no-op.
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)
            .with_context(|| format!("failed to open sqlite at {}", path.display()))?;
        Self::ensure_schema(&conn)?;
        Ok(Self { conn })
    }

    /// Open an in-memory database — primarily for tests.
    #[cfg(test)]
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().context("failed to open in-memory sqlite")?;
        Self::ensure_schema(&conn)?;
        Ok(Self { conn })
    }

    fn ensure_schema(conn: &Connection) -> Result<()> {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS studies (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                name              TEXT NOT NULL UNIQUE,
                strategy          TEXT NOT NULL,
                search_space_yaml TEXT NOT NULL,
                created_at        TEXT NOT NULL,
                commit_hash       TEXT
            );

            CREATE TABLE IF NOT EXISTS trials (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                study_id     INTEGER NOT NULL,
                trial_id     INTEGER NOT NULL,
                params_json  TEXT NOT NULL,
                metrics_json TEXT NOT NULL,
                score        REAL NOT NULL,
                created_at   TEXT NOT NULL,
                FOREIGN KEY (study_id) REFERENCES studies(id)
            );

            CREATE INDEX IF NOT EXISTS trials_study_score_idx
                ON trials(study_id, score DESC);
            "#,
        )
        .context("failed to apply schema migration")?;
        Ok(())
    }

    /// Insert a new study row. Returns the auto-assigned `study_id`.
    /// Returns an error if `name` already exists (UNIQUE constraint).
    pub fn create_study(
        &self,
        name: &str,
        strategy: &str,
        search_space_yaml: &str,
    ) -> Result<i64> {
        let now = Utc::now().to_rfc3339();
        self.conn
            .execute(
                "INSERT INTO studies (name, strategy, search_space_yaml, created_at) \
                 VALUES (?1, ?2, ?3, ?4)",
                params![name, strategy, search_space_yaml, now],
            )
            .with_context(|| format!("failed to create study '{}'", name))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Insert a single trial row for `study_id`. The `score` column is
    /// stored as raw `f64` (preserving `NEG_INFINITY` for disqualified
    /// trials); `params_json` and `metrics_json` are sanitized of
    /// NaN/Inf before serialization so the JSON survives a round-trip.
    pub fn insert_trial(&self, study_id: i64, trial: &TrialResult) -> Result<()> {
        let params_json =
            serde_json::to_string(&trial.params).context("serialize TrialParams")?;
        let metrics_json = serde_json::to_string(&sanitize_metrics(&trial.metrics))
            .context("serialize TrialMetrics")?;
        let now = Utc::now().to_rfc3339();
        self.conn
            .execute(
                "INSERT INTO trials \
                 (study_id, trial_id, params_json, metrics_json, score, created_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    study_id,
                    trial.trial_id,
                    params_json,
                    metrics_json,
                    trial.score,
                    now
                ],
            )
            .context("failed to insert trial")?;
        Ok(())
    }

    /// Return the top-`n` trials for `study_id`, ordered by descending
    /// score. Disqualified trials (score = `NEG_INFINITY`) sort last and
    /// are only returned if `n` exceeds the qualified count.
    pub fn top_n_trials(&self, study_id: i64, n: usize) -> Result<Vec<TrialResult>> {
        let mut stmt = self.conn.prepare(
            "SELECT trial_id, params_json, metrics_json, score \
             FROM trials \
             WHERE study_id = ?1 \
             ORDER BY score DESC \
             LIMIT ?2",
        )?;
        let rows = stmt
            .query_map(params![study_id, n as i64], |row| {
                let trial_id: u32 = row.get::<_, i64>(0)? as u32;
                let params_json: String = row.get(1)?;
                let metrics_json: String = row.get(2)?;
                let score: f64 = row.get(3)?;
                Ok((trial_id, params_json, metrics_json, score))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        let mut out = Vec::with_capacity(rows.len());
        for (trial_id, params_json, metrics_json, score) in rows {
            let params: TrialParams =
                serde_json::from_str(&params_json).context("deserialize TrialParams")?;
            let metrics: TrialMetrics =
                serde_json::from_str(&metrics_json).context("deserialize TrialMetrics")?;
            out.push(TrialResult {
                trial_id,
                params,
                metrics,
                score,
            });
        }
        Ok(out)
    }

    /// Return all studies, newest first.
    pub fn list_studies(&self) -> Result<Vec<StudyMeta>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, name, strategy, created_at, commit_hash \
             FROM studies \
             ORDER BY created_at DESC",
        )?;
        let rows = stmt
            .query_map([], |row| {
                Ok(StudyMeta {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    strategy: row.get(2)?,
                    created_at: row.get(3)?,
                    commit_hash: row.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Convenience: look up a study by name.
    pub fn study_id_by_name(&self, name: &str) -> Result<Option<i64>> {
        let id = self
            .conn
            .query_row(
                "SELECT id FROM studies WHERE name = ?1",
                params![name],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        Ok(id)
    }
}

/// Replace NaN / ±Inf fields with `0.0` so that `serde_json` can
/// round-trip the resulting `TrialMetrics`. Pure function — no side
/// effects on the caller's metrics.
fn sanitize_metrics(m: &TrialMetrics) -> TrialMetrics {
    fn finite_or_zero(v: f64) -> f64 {
        if v.is_finite() {
            v
        } else {
            0.0
        }
    }
    TrialMetrics {
        total_trades: m.total_trades,
        total_pnl: finite_or_zero(m.total_pnl),
        win_rate: finite_or_zero(m.win_rate),
        sharpe_ratio: finite_or_zero(m.sharpe_ratio),
        max_drawdown_pct: finite_or_zero(m.max_drawdown_pct),
        profit_factor: finite_or_zero(m.profit_factor),
        final_equity: finite_or_zero(m.final_equity),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    fn sample_trial(id: u32, score: f64) -> TrialResult {
        let mut params = TrialParams::new();
        params.insert("bb_period", 200.0 + id as f64);
        TrialResult {
            trial_id: id,
            params,
            metrics: TrialMetrics {
                total_trades: 50,
                total_pnl: 100.0 + id as f64,
                win_rate: 55.0,
                sharpe_ratio: 1.0,
                max_drawdown_pct: 10.0,
                profit_factor: 1.5,
                final_equity: 10_100.0,
            },
            score,
        }
    }

    #[test]
    fn open_creates_schema_on_fresh_database() {
        let storage = StudyStorage::open_in_memory().unwrap();
        // Empty study list on a fresh DB.
        assert!(storage.list_studies().unwrap().is_empty());
    }

    #[test]
    fn open_is_idempotent_on_existing_database() {
        let file = NamedTempFile::new().unwrap();
        let _first = StudyStorage::open(file.path()).unwrap();
        let second = StudyStorage::open(file.path()).unwrap();
        // Reopening must not error and must see the same (empty) state.
        assert!(second.list_studies().unwrap().is_empty());
    }

    #[test]
    fn create_study_returns_unique_id_and_appears_in_list() {
        let storage = StudyStorage::open_in_memory().unwrap();
        let id_a = storage
            .create_study("study_a", "bb_rsi", "yaml-content-a")
            .unwrap();
        let id_b = storage
            .create_study("study_b", "ut_bot", "yaml-content-b")
            .unwrap();
        assert_ne!(id_a, id_b);
        let metas = storage.list_studies().unwrap();
        assert_eq!(metas.len(), 2);
        assert!(metas.iter().any(|m| m.name == "study_a"));
        assert!(metas.iter().any(|m| m.name == "study_b"));
    }

    #[test]
    fn duplicate_study_name_returns_error() {
        let storage = StudyStorage::open_in_memory().unwrap();
        storage.create_study("dup", "bb_rsi", "yaml").unwrap();
        let err = storage.create_study("dup", "bb_rsi", "yaml");
        assert!(err.is_err());
    }

    #[test]
    fn insert_then_top_n_returns_results_ordered_by_score_desc() {
        let storage = StudyStorage::open_in_memory().unwrap();
        let study_id = storage
            .create_study("sweep_001", "bb_rsi", "yaml")
            .unwrap();

        let scores = [1.2, 2.5, 0.7, 3.1, 1.9, 2.0, 0.4, 2.7, 1.1, 3.5];
        for (i, &s) in scores.iter().enumerate() {
            storage
                .insert_trial(study_id, &sample_trial(i as u32, s))
                .unwrap();
        }

        let top3 = storage.top_n_trials(study_id, 3).unwrap();
        assert_eq!(top3.len(), 3);
        assert_eq!(top3[0].score, 3.5);
        assert_eq!(top3[1].score, 3.1);
        assert_eq!(top3[2].score, 2.7);
        assert!(top3[0].score >= top3[1].score);
        assert!(top3[1].score >= top3[2].score);
    }

    #[test]
    fn top_n_with_n_smaller_than_study_size() {
        let storage = StudyStorage::open_in_memory().unwrap();
        let study_id = storage.create_study("twenty", "bb_rsi", "yaml").unwrap();
        for i in 0..20u32 {
            storage
                .insert_trial(study_id, &sample_trial(i, i as f64))
                .unwrap();
        }
        let top5 = storage.top_n_trials(study_id, 5).unwrap();
        assert_eq!(top5.len(), 5);
        let scores: Vec<f64> = top5.iter().map(|t| t.score).collect();
        assert_eq!(scores, vec![19.0, 18.0, 17.0, 16.0, 15.0]);
    }

    #[test]
    fn disqualified_trials_sort_last_and_preserve_neg_infinity_score() {
        let storage = StudyStorage::open_in_memory().unwrap();
        let study_id = storage.create_study("dq", "bb_rsi", "yaml").unwrap();
        storage
            .insert_trial(study_id, &sample_trial(0, f64::NEG_INFINITY))
            .unwrap();
        storage.insert_trial(study_id, &sample_trial(1, 2.0)).unwrap();
        storage.insert_trial(study_id, &sample_trial(2, 1.0)).unwrap();

        let top3 = storage.top_n_trials(study_id, 3).unwrap();
        assert_eq!(top3[0].score, 2.0);
        assert_eq!(top3[1].score, 1.0);
        assert!(top3[2].score.is_infinite() && top3[2].score < 0.0);
    }

    #[test]
    fn insert_trial_sanitizes_nan_metrics_before_serialization() {
        let storage = StudyStorage::open_in_memory().unwrap();
        let study_id = storage.create_study("nan", "bb_rsi", "yaml").unwrap();
        let mut trial = sample_trial(7, f64::NEG_INFINITY);
        trial.metrics.profit_factor = f64::NAN;
        trial.metrics.sharpe_ratio = f64::INFINITY;
        // Must not panic / return Err.
        storage.insert_trial(study_id, &trial).unwrap();
        let top = storage.top_n_trials(study_id, 1).unwrap();
        assert_eq!(top[0].trial_id, 7);
        // Sanitized: stored as 0.0.
        assert_eq!(top[0].metrics.profit_factor, 0.0);
        assert_eq!(top[0].metrics.sharpe_ratio, 0.0);
    }

    #[test]
    fn study_id_by_name_returns_none_for_unknown() {
        let storage = StudyStorage::open_in_memory().unwrap();
        assert!(storage.study_id_by_name("missing").unwrap().is_none());
        let id = storage.create_study("found", "bb_rsi", "yaml").unwrap();
        assert_eq!(storage.study_id_by_name("found").unwrap(), Some(id));
    }

    #[test]
    fn roundtrip_persists_after_reopen() {
        let file = NamedTempFile::new().unwrap();
        let study_id;
        {
            let storage = StudyStorage::open(file.path()).unwrap();
            study_id = storage.create_study("persist", "bb_rsi", "yaml").unwrap();
            storage
                .insert_trial(study_id, &sample_trial(42, 7.5))
                .unwrap();
        }
        // Drop closes the connection; re-open and re-read.
        let storage = StudyStorage::open(file.path()).unwrap();
        let top = storage.top_n_trials(study_id, 5).unwrap();
        assert_eq!(top.len(), 1);
        assert_eq!(top[0].trial_id, 42);
        assert_eq!(top[0].score, 7.5);
    }
}
