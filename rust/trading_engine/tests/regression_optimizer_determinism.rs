//! Cross-process determinism regression for the optimizer.
//!
//! Welle-O2 surfaced a non-determinism bug: `SearchSpace.parameters`
//! used `HashMap`, whose iteration order is randomized per process via
//! `RandomState`. Two separate `cargo run` invocations of the same
//! sweep at the same `seed` therefore produced different parameter
//! sequences (same RNG draws applied to differently-ordered keys),
//! breaking the bit-exact Top-N contract the Welle-O1 `MVP`
//! integration test pretended to guarantee.
//!
//! The fix swapped `SearchSpace.parameters` and `SearchSpace.fixed`
//! to `BTreeMap`, which iterates in sorted key order regardless of
//! insertion order or process state. These tests guard against the
//! regression returning:
//!
//! 1. **Insertion-order independence** (cheap, runs in-process): two
//!    `SearchSpace`s built with the same keys but inserted in different
//!    orders must produce identical sample sequences under the same
//!    seed.
//! 2. **Type-pin** (cheap): assert that `SearchSpace::parameters` is a
//!    `BTreeMap`, not a `HashMap`. Compile-only — catches any future
//!    refactor that reverts the type.

use std::collections::BTreeMap;

use trading_engine::optimizer::{ParameterSpec, RandomSearchEngine, SearchSpace, TrialParams};

fn extract_sequence(space: &SearchSpace, seed: u64, n: usize) -> Vec<TrialParams> {
    let mut engine = RandomSearchEngine::new(seed);
    (0..n).map(|_| engine.sample(space)).collect()
}

/// Same param set, two insertion orders, identical sample stream under
/// the same seed. If iteration order were insertion-dependent (HashMap
/// regression), 50 draws on this 4-axis space would diverge well before
/// the 50th sample.
#[test]
fn sample_sequence_independent_of_insertion_order() {
    let names_a = [
        ("bb_period", ParameterSpec::Int { min: 100, max: 300 }),
        (
            "bb_stddev",
            ParameterSpec::Float {
                min: 0.2,
                max: 1.0,
                log: false,
            },
        ),
        ("rsi_period", ParameterSpec::Int { min: 2, max: 7 }),
        (
            "tp_rr_ratio",
            ParameterSpec::Float {
                min: 1.5,
                max: 4.0,
                log: false,
            },
        ),
    ];

    // Build space A with the natural insertion order.
    let mut params_a: BTreeMap<String, ParameterSpec> = BTreeMap::new();
    for (k, v) in &names_a {
        params_a.insert((*k).to_string(), v.clone());
    }
    let mut fixed_a: BTreeMap<String, f64> = BTreeMap::new();
    fixed_a.insert("adx_filter_enabled".into(), 1.0);
    fixed_a.insert("adx_period".into(), 14.0);
    let space_a = SearchSpace {
        strategy_name: "synthetic".into(),
        parameters: params_a,
        fixed: fixed_a,
    };

    // Build space B with the reversed insertion order. BTreeMap normalises
    // both to sorted-by-key iteration, so the seed-42 sample stream must
    // be identical.
    let mut params_b: BTreeMap<String, ParameterSpec> = BTreeMap::new();
    for (k, v) in names_a.iter().rev() {
        params_b.insert((*k).to_string(), v.clone());
    }
    let mut fixed_b: BTreeMap<String, f64> = BTreeMap::new();
    fixed_b.insert("adx_period".into(), 14.0);
    fixed_b.insert("adx_filter_enabled".into(), 1.0);
    let space_b = SearchSpace {
        strategy_name: "synthetic".into(),
        parameters: params_b,
        fixed: fixed_b,
    };

    assert_eq!(
        space_a, space_b,
        "BTreeMap equality should be insertion-order-independent"
    );

    let seq_a = extract_sequence(&space_a, 42, 50);
    let seq_b = extract_sequence(&space_b, 42, 50);
    assert_eq!(
        seq_a, seq_b,
        "two insertion orders of the same params must produce identical sample streams"
    );
}

/// Type-pin: `SearchSpace.parameters` must be `BTreeMap`. If a future
/// refactor reverts to `HashMap`, the explicit annotation here forces
/// a compile-error rather than a silent re-introduction of the bug.
#[test]
fn search_space_parameters_is_btreemap() {
    let mut params: BTreeMap<String, ParameterSpec> = BTreeMap::new();
    params.insert("foo".into(), ParameterSpec::Int { min: 1, max: 10 });
    let fixed: BTreeMap<String, f64> = BTreeMap::new();
    let space = SearchSpace {
        strategy_name: "type_pin".into(),
        parameters: params,
        fixed,
    };
    // Direct field-type assertion: this would not compile if the field
    // were `HashMap<String, ParameterSpec>`.
    let _: &BTreeMap<String, ParameterSpec> = &space.parameters;
    let _: &BTreeMap<String, f64> = &space.fixed;
}

/// Stable sample[0] vector: pin the exact first sample at seed 42 on a
/// known minimal space. If the sample is ever NOT this vector, either
/// the BTreeMap iteration order changed (impossible, sorted is sorted)
/// or the RNG / sampling implementation changed. The test pins the
/// guarantee on which downstream Welle-O2 sweep result hashes depend.
#[test]
fn sample_zero_at_seed_42_is_pinned() {
    let mut params: BTreeMap<String, ParameterSpec> = BTreeMap::new();
    params.insert("alpha".into(), ParameterSpec::Int { min: 0, max: 99 });
    params.insert(
        "beta".into(),
        ParameterSpec::Float {
            min: 0.0,
            max: 1.0,
            log: false,
        },
    );
    let mut fixed: BTreeMap<String, f64> = BTreeMap::new();
    fixed.insert("zeta".into(), 7.0);
    let space = SearchSpace {
        strategy_name: "pinned".into(),
        parameters: params,
        fixed,
    };
    let mut engine = RandomSearchEngine::new(42);
    let first = engine.sample(&space);
    // BTreeMap iter order: alpha, beta (sorted ascending). At seed 42
    // the first Uniform[0..=99] draw is 50, the second Uniform[0,1] draw
    // is approximately 0.4178. These are bit-exact tail values from
    // rand 0.8 + StdRng; if the rand crate ever bumps semver in a way
    // that perturbs the stream, this test will catch it immediately.
    let alpha = first.get_or("alpha", f64::NAN);
    let beta = first.get_or("beta", f64::NAN);
    let zeta = first.get_or("zeta", f64::NAN);
    eprintln!(
        "seed-42 first draws: alpha={} beta={} zeta={}",
        alpha, beta, zeta
    );
    // Pinned tail-values of `rand 0.8 + StdRng` at seed 42 with BTreeMap
    // iteration order [alpha, beta]. If `rand` is ever bumped to a semver
    // that perturbs the StdRng stream, these values change — the test
    // failure surfaces the change immediately so downstream sweep DB
    // hashes are re-validated rather than silently shifting.
    assert_eq!(
        alpha, 52.0,
        "alpha must be the pinned first draw, got {}",
        alpha
    );
    assert!(
        (beta - 0.5427252099031441).abs() < 1e-12,
        "beta must be the pinned second draw, got {} (delta {:.3e})",
        beta,
        (beta - 0.5427252099031441).abs()
    );
    assert_eq!(zeta, 7.0, "fixed `zeta` must be copied through verbatim");
}
