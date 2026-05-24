//! YAML loader for `SearchSpace` files.
//!
//! Search-space files live under `01_Projectplan/search_spaces/<strategy>.yaml`
//! and are read by the optimizer at study start. This thin loader pairs
//! `serde_yaml` parsing with the domain-level `SearchSpace::validate()` gate
//! so that ill-formed search spaces fail at load time rather than mid-trial.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result};

use super::SearchSpace;

/// Parse a `SearchSpace` from a YAML file on disk.
///
/// Returns an error if the file cannot be read, the YAML is malformed,
/// or the resulting `SearchSpace` fails its internal validation
/// (e.g. `min >= max` on a `Float` spec, empty `Categorical` values).
pub fn parse_search_space(path: &Path) -> Result<SearchSpace> {
    let contents = fs::read_to_string(path)
        .with_context(|| format!("failed to read search-space YAML at {}", path.display()))?;
    parse_search_space_str(&contents)
        .with_context(|| format!("invalid search-space YAML at {}", path.display()))
}

/// Parse a `SearchSpace` from an in-memory YAML string. Useful for tests
/// and for callers that already have the contents in memory.
pub fn parse_search_space_str(yaml: &str) -> Result<SearchSpace> {
    let space: SearchSpace =
        serde_yaml::from_str(yaml).context("failed to deserialize SearchSpace from YAML")?;
    space.validate().map_err(anyhow::Error::msg)?;
    Ok(space)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::optimizer::ParameterSpec;
    use std::path::PathBuf;

    fn repo_root() -> PathBuf {
        // CARGO_MANIFEST_DIR resolves to rust/trading_engine; up two levels
        // is the repo root that hosts 01_Projectplan/.
        let crate_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        crate_dir
            .parent()
            .and_then(|p| p.parent())
            .expect("crate dir has a great-grandparent")
            .to_path_buf()
    }

    #[test]
    fn parses_bb_rsi_yaml_into_valid_search_space() {
        let path = repo_root().join("01_Projectplan/search_spaces/bb_rsi.yaml");
        let space = parse_search_space(&path).expect("bb_rsi.yaml must parse");
        assert_eq!(space.strategy_name, "bb_rsi");
        assert!(space.parameters.contains_key("bb_period"));
        assert!(space.parameters.contains_key("adx_use_di_confluence"));
        match space.parameters.get("bb_period").unwrap() {
            ParameterSpec::Int { min, max } => {
                assert_eq!(*min, 100);
                assert_eq!(*max, 300);
            }
            other => panic!("bb_period must be Int, got {:?}", other),
        }
        assert_eq!(space.fixed.get("bb_ma_type").copied(), Some(1.0));
        assert_eq!(space.fixed.get("adx_filter_enabled").copied(), Some(1.0));
    }

    #[test]
    fn parses_ut_bot_yaml_into_valid_search_space() {
        let path = repo_root().join("01_Projectplan/search_spaces/ut_bot.yaml");
        let space = parse_search_space(&path).expect("ut_bot.yaml must parse");
        assert_eq!(space.strategy_name, "ut_bot");
        assert!(space.parameters.contains_key("smi_length"));
        assert!(space.parameters.contains_key("smi_cross_above_zero"));
    }

    #[test]
    fn parses_ichimoku_yaml_into_valid_search_space() {
        let path = repo_root().join("01_Projectplan/search_spaces/ichimoku.yaml");
        let space = parse_search_space(&path).expect("ichimoku.yaml must parse");
        assert_eq!(space.strategy_name, "ichimoku");
        assert!(space.parameters.contains_key("tenkan_period"));
        assert!(space.parameters.contains_key("score_threshold"));
    }

    #[test]
    fn parser_rejects_missing_required_field() {
        // strategy_name is required by SearchSpace
        let yaml = r#"
parameters:
  bb_period: { type: Int, min: 100, max: 300 }
"#;
        let err = parse_search_space_str(yaml).unwrap_err();
        let msg = format!("{:#}", err);
        assert!(
            msg.to_lowercase().contains("strategy_name")
                || msg.to_lowercase().contains("missing field"),
            "expected error to mention strategy_name; got: {}",
            msg
        );
    }

    #[test]
    fn parser_rejects_invalid_range() {
        let yaml = r#"
strategy_name: bb_rsi
parameters:
  bb_period: { type: Int, min: 300, max: 100 }
"#;
        let err = parse_search_space_str(yaml).unwrap_err();
        let msg = format!("{:#}", err);
        assert!(
            msg.contains("must be <"),
            "expected min < max error; got: {}",
            msg
        );
    }

    #[test]
    fn parser_rejects_log_uniform_with_nonpositive_min() {
        let yaml = r#"
strategy_name: bb_rsi
parameters:
  some_param: { type: Float, min: 0.0, max: 1.0, log: true }
"#;
        let err = parse_search_space_str(yaml).unwrap_err();
        let msg = format!("{:#}", err);
        assert!(
            msg.contains("log-uniform"),
            "expected log-uniform error; got: {}",
            msg
        );
    }

    #[test]
    fn parser_rejects_unknown_parameter_spec_type() {
        let yaml = r#"
strategy_name: bb_rsi
parameters:
  bad: { type: NotARealType, min: 0, max: 1 }
"#;
        let err = parse_search_space_str(yaml).unwrap_err();
        let msg = format!("{:#}", err);
        assert!(
            msg.to_lowercase().contains("unknown")
                || msg.to_lowercase().contains("variant")
                || msg.to_lowercase().contains("notarealtype"),
            "expected unknown-variant error; got: {}",
            msg
        );
    }
}
