use serde::{Deserialize, Serialize};

/// Represents a single OHLCV candlestick.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Candle {
    /// Unix timestamp in milliseconds.
    pub timestamp: i64,
    /// Opening price.
    pub open: f64,
    /// Highest price during the period.
    pub high: f64,
    /// Lowest price during the period.
    pub low: f64,
    /// Closing price.
    pub close: f64,
    /// Trading volume.
    pub volume: f64,
}

impl Candle {
    /// Create a new Candle.
    pub fn new(timestamp: i64, open: f64, high: f64, low: f64, close: f64, volume: f64) -> Self {
        Self {
            timestamp,
            open,
            high,
            low,
            close,
            volume,
        }
    }

    /// Returns whether this candle is bullish (close >= open).
    pub fn is_bullish(&self) -> bool {
        self.close >= self.open
    }

    /// Returns the body size (absolute difference between open and close).
    pub fn body_size(&self) -> f64 {
        (self.close - self.open).abs()
    }

    /// Returns the full range (high - low).
    pub fn range(&self) -> f64 {
        self.high - self.low
    }

    /// Returns the midpoint price ((high + low) / 2).
    pub fn midpoint(&self) -> f64 {
        (self.high + self.low) / 2.0
    }
}

/// Supported timeframes for candle data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Timeframe {
    M1,
    M5,
    M15,
    M30,
    H1,
    H4,
    D1,
    W1,
}

impl Timeframe {
    /// Returns the timeframe string used by exchanges (e.g., "1m", "1h").
    pub fn as_str(&self) -> &'static str {
        match self {
            Timeframe::M1 => "1m",
            Timeframe::M5 => "5m",
            Timeframe::M15 => "15m",
            Timeframe::M30 => "30m",
            Timeframe::H1 => "1h",
            Timeframe::H4 => "4h",
            Timeframe::D1 => "1d",
            Timeframe::W1 => "1w",
        }
    }

    /// Returns the duration of this timeframe in milliseconds.
    pub fn duration_ms(&self) -> i64 {
        match self {
            Timeframe::M1 => 60_000,
            Timeframe::M5 => 300_000,
            Timeframe::M15 => 900_000,
            Timeframe::M30 => 1_800_000,
            Timeframe::H1 => 3_600_000,
            Timeframe::H4 => 14_400_000,
            Timeframe::D1 => 86_400_000,
            Timeframe::W1 => 604_800_000,
        }
    }
}

/// Container for OHLCV data: a collection of candles for a specific symbol and timeframe.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OhlcvData {
    /// Trading symbol (e.g., "BTCUSDT").
    pub symbol: String,
    /// Timeframe of the candle data.
    pub timeframe: Timeframe,
    /// Ordered list of candles (oldest first).
    pub candles: Vec<Candle>,
}

impl OhlcvData {
    /// Create a new empty OhlcvData container.
    pub fn new(symbol: String, timeframe: Timeframe) -> Self {
        Self {
            symbol,
            timeframe,
            candles: Vec::new(),
        }
    }

    /// Append a candle to the data.
    pub fn push(&mut self, candle: Candle) {
        self.candles.push(candle);
    }

    /// Returns the number of candles.
    pub fn len(&self) -> usize {
        self.candles.len()
    }

    /// Returns true if there are no candles.
    pub fn is_empty(&self) -> bool {
        self.candles.is_empty()
    }

    /// Returns a slice of the last `n` candles.
    pub fn last_n(&self, n: usize) -> &[Candle] {
        let start = self.candles.len().saturating_sub(n);
        &self.candles[start..]
    }

    /// Returns the latest candle if available.
    pub fn latest(&self) -> Option<&Candle> {
        self.candles.last()
    }

    /// Returns a slice of close prices.
    pub fn closes(&self) -> Vec<f64> {
        self.candles.iter().map(|c| c.close).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_candle_new() {
        let candle = Candle::new(1000, 100.0, 110.0, 95.0, 105.0, 500.0);
        assert_eq!(candle.timestamp, 1000);
        assert_eq!(candle.open, 100.0);
        assert_eq!(candle.high, 110.0);
        assert_eq!(candle.low, 95.0);
        assert_eq!(candle.close, 105.0);
        assert_eq!(candle.volume, 500.0);
    }

    #[test]
    fn test_candle_bullish() {
        let bullish = Candle::new(1000, 100.0, 110.0, 95.0, 105.0, 500.0);
        assert!(bullish.is_bullish());

        let bearish = Candle::new(1000, 105.0, 110.0, 95.0, 100.0, 500.0);
        assert!(!bearish.is_bullish());

        let doji = Candle::new(1000, 100.0, 110.0, 95.0, 100.0, 500.0);
        assert!(doji.is_bullish()); // close == open is considered bullish
    }

    #[test]
    fn test_candle_body_size() {
        let candle = Candle::new(1000, 100.0, 110.0, 95.0, 105.0, 500.0);
        assert!((candle.body_size() - 5.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_candle_range() {
        let candle = Candle::new(1000, 100.0, 110.0, 95.0, 105.0, 500.0);
        assert!((candle.range() - 15.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_timeframe_as_str() {
        assert_eq!(Timeframe::M1.as_str(), "1m");
        assert_eq!(Timeframe::H1.as_str(), "1h");
        assert_eq!(Timeframe::D1.as_str(), "1d");
    }

    #[test]
    fn test_ohlcv_data() {
        let mut data = OhlcvData::new("BTCUSDT".to_string(), Timeframe::H1);
        assert!(data.is_empty());
        assert_eq!(data.len(), 0);

        data.push(Candle::new(1000, 100.0, 110.0, 95.0, 105.0, 500.0));
        data.push(Candle::new(2000, 105.0, 115.0, 100.0, 110.0, 600.0));

        assert_eq!(data.len(), 2);
        assert!(!data.is_empty());
        assert_eq!(data.latest().unwrap().close, 110.0);
        assert_eq!(data.closes(), vec![105.0, 110.0]);
        assert_eq!(data.last_n(1).len(), 1);
        assert_eq!(data.last_n(1)[0].close, 110.0);
    }

    #[test]
    fn test_candle_serialization() {
        let candle = Candle::new(1000, 100.0, 110.0, 95.0, 105.0, 500.0);
        let json = serde_json::to_string(&candle).unwrap();
        let deserialized: Candle = serde_json::from_str(&json).unwrap();
        assert_eq!(candle, deserialized);
    }
}
