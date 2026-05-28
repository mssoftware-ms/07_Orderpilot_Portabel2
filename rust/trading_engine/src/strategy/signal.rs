use serde::{Deserialize, Serialize};

use crate::models::ExitReason;

/// Trading signal emitted by a strategy add-in on each candle.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Signal {
    /// Enter a long position.
    EnterLong {
        /// Stop loss price (absolute).
        sl: Option<f64>,
        /// Take profit price levels (absolute).
        tp: Option<f64>,
        /// Position size as a percentage of available capital (0.0 - 100.0).
        size_pct: f64,
    },
    /// Enter a short position.
    EnterShort {
        /// Stop loss price (absolute).
        sl: Option<f64>,
        /// Take profit price levels (absolute).
        tp: Option<f64>,
        /// Position size as a percentage of available capital (0.0 - 100.0).
        size_pct: f64,
    },
    /// Exit the current position.
    Exit {
        /// Reason for exiting.
        reason: ExitReason,
    },
    /// Move the stop loss to a new price level.
    MoveStop {
        /// New stop loss price (absolute).
        new_sl: f64,
    },
    /// No action taken this candle.
    NoAction,
}

impl Signal {
    /// Create a simple long entry with default sizing.
    pub fn long(sl: Option<f64>, tp: Option<f64>) -> Self {
        Signal::EnterLong {
            sl,
            tp,
            size_pct: 100.0,
        }
    }

    /// Create a simple short entry with default sizing.
    pub fn short(sl: Option<f64>, tp: Option<f64>) -> Self {
        Signal::EnterShort {
            sl,
            tp,
            size_pct: 100.0,
        }
    }

    /// Create an exit signal with a reason string.
    pub fn exit(reason: &str) -> Self {
        Signal::Exit {
            reason: ExitReason::Signal(reason.to_string()),
        }
    }

    /// Returns true if this signal is actionable (not NoAction).
    pub fn is_actionable(&self) -> bool {
        !matches!(self, Signal::NoAction)
    }

    /// Returns true if this signal triggers a new position entry.
    pub fn is_entry(&self) -> bool {
        matches!(self, Signal::EnterLong { .. } | Signal::EnterShort { .. })
    }

    /// Returns true if this signal triggers a position exit.
    pub fn is_exit(&self) -> bool {
        matches!(self, Signal::Exit { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_signal_enter_long() {
        let signal = Signal::EnterLong {
            sl: Some(95.0),
            tp: Some(110.0),
            size_pct: 50.0,
        };
        assert!(signal.is_actionable());
        assert!(signal.is_entry());
        assert!(!signal.is_exit());
    }

    #[test]
    fn test_signal_enter_short() {
        let signal = Signal::EnterShort {
            sl: Some(115.0),
            tp: Some(90.0),
            size_pct: 100.0,
        };
        assert!(signal.is_actionable());
        assert!(signal.is_entry());
    }

    #[test]
    fn test_signal_exit() {
        let signal = Signal::Exit {
            reason: ExitReason::StopLoss,
        };
        assert!(signal.is_actionable());
        assert!(signal.is_exit());
        assert!(!signal.is_entry());
    }

    #[test]
    fn test_signal_move_stop() {
        let signal = Signal::MoveStop { new_sl: 98.0 };
        assert!(signal.is_actionable());
        assert!(!signal.is_entry());
        assert!(!signal.is_exit());
    }

    #[test]
    fn test_signal_no_action() {
        let signal = Signal::NoAction;
        assert!(!signal.is_actionable());
        assert!(!signal.is_entry());
        assert!(!signal.is_exit());
    }

    #[test]
    fn test_signal_helpers() {
        let long = Signal::long(Some(95.0), Some(110.0));
        match long {
            Signal::EnterLong { sl, tp, size_pct } => {
                assert_eq!(sl, Some(95.0));
                assert_eq!(tp, Some(110.0));
                assert_eq!(size_pct, 100.0);
            }
            _ => panic!("Expected EnterLong"),
        }

        let short = Signal::short(None, None);
        match short {
            Signal::EnterShort { sl, tp, size_pct } => {
                assert_eq!(sl, None);
                assert_eq!(tp, None);
                assert_eq!(size_pct, 100.0);
            }
            _ => panic!("Expected EnterShort"),
        }

        let exit = Signal::exit("RSI overbought");
        assert!(exit.is_exit());
    }

    #[test]
    fn test_signal_serialization() {
        let signal = Signal::EnterLong {
            sl: Some(95.0),
            tp: Some(110.0),
            size_pct: 50.0,
        };
        let json = serde_json::to_string(&signal).unwrap();
        let deserialized: Signal = serde_json::from_str(&json).unwrap();
        assert_eq!(signal, deserialized);
    }
}
