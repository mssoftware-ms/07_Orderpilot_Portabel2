//! Strategy Add-ins module.
//!
//! Contains concrete strategy implementations of the `StrategyAddin` trait.

pub mod bb_rsi;
pub mod ut_bot;

pub use bb_rsi::BbRsiStrategy;
pub use ut_bot::UtBotStrategy;
