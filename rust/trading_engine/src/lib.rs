//! Trading Engine - Rust strategy engine for the Trading App.
//!
//! This crate provides:
//! - Core data structures for OHLCV candle data and trade records
//! - The `StrategyAddin` trait system for pluggable trading strategies
//! - Signal enum for strategy decisions (EnterLong, EnterShort, Exit, etc.)
//! - Context struct for providing market data to strategies
//! - Flutter Rust Bridge API functions for cross-platform integration

pub mod api;
pub mod models;
pub mod strategy;
