//! Strategy Add-ins module.
//!
//! Contains concrete strategy implementations of the `StrategyAddin` trait
//! plus shared helpers in [`common`] used by more than one strategy.

pub mod bb_rsi;
pub mod common;
pub mod ut_bot;

pub use bb_rsi::BbRsiStrategy;
pub use ut_bot::UtBotStrategy;
