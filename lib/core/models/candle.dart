/// Represents a single OHLCV candlestick.
///
/// This is the canonical candle model used throughout the Flutter app.
/// It can be constructed from:
///   - Binance REST API kline arrays ([fromBinanceKline])
///   - JSON maps ([fromJson]) for cache deserialization
///
/// And converted to:
///   - JSON maps ([toJson]) for cache serialization
///   - Rust-engine-compatible JSON ([toRustJson]) for the FFI bridge
///
/// ## Example – Fetch BTC/USDT 1h data for the last 30 days
/// ```dart
/// final client = BinanceApiClient();
/// final candles = await client.downloadHistory(
///   symbol: 'BTCUSDT',
///   interval: '1h',
///   days: 30,
/// );
/// // Convert for Rust engine
/// final rustJson = candles.map((c) => c.toRustJson()).toList();
/// ```
class CandleData {
  /// Unix timestamp in milliseconds (UTC, candle open time).
  final int timestamp;

  /// Opening price.
  final double open;

  /// Highest price during the period.
  final double high;

  /// Lowest price during the period.
  final double low;

  /// Closing price.
  final double close;

  /// Base-asset trading volume during the period.
  final double volume;

  const CandleData({
    required this.timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  // ─── Factory constructors ─────────────────────────────────────────────

  /// Parse a Binance kline array.
  ///
  /// Binance REST `/api/v3/klines` returns each candle as a JSON array:
  /// ```
  /// [
  ///   1499040000000,      // 0  Open time (ms)
  ///   "0.01634000",       // 1  Open
  ///   "0.80000000",       // 2  High
  ///   "0.01575800",       // 3  Low
  ///   "0.01577100",       // 4  Close
  ///   "148976.11427815",  // 5  Volume
  ///   1499644799999,      // 6  Close time (ms)
  ///   "2434.19055334",    // 7  Quote asset volume
  ///   308,                // 8  Number of trades
  ///   "1756.87402397",    // 9  Taker buy base volume
  ///   "28.46694368",      // 10 Taker buy quote volume
  ///   "17928899.62484339" // 11 Ignore
  /// ]
  /// ```
  factory CandleData.fromBinanceKline(List<dynamic> kline) {
    return CandleData(
      timestamp: kline[0] as int,
      open: double.parse(kline[1] as String),
      high: double.parse(kline[2] as String),
      low: double.parse(kline[3] as String),
      close: double.parse(kline[4] as String),
      volume: double.parse(kline[5] as String),
    );
  }

  /// Alias kept for backward compatibility.
  factory CandleData.fromBinanceJson(List<dynamic> json) =
      CandleData.fromBinanceKline;

  /// Deserialize from a JSON map (e.g. from cache).
  factory CandleData.fromJson(Map<String, dynamic> json) {
    return CandleData(
      timestamp: json['timestamp'] as int,
      open: (json['open'] as num).toDouble(),
      high: (json['high'] as num).toDouble(),
      low: (json['low'] as num).toDouble(),
      close: (json['close'] as num).toDouble(),
      volume: (json['volume'] as num).toDouble(),
    );
  }

  // ─── Serialization ────────────────────────────────────────────────────

  /// Serialize to a JSON map (for caching / generic use).
  Map<String, dynamic> toJson() => {
        'timestamp': timestamp,
        'open': open,
        'high': high,
        'low': low,
        'close': close,
        'volume': volume,
      };

  /// Serialize to the exact JSON format expected by the Rust trading engine.
  ///
  /// The Rust `Candle` struct uses the same field names, so this is
  /// identical to [toJson] but exists as a named method for clarity.
  Map<String, dynamic> toRustJson() => toJson();

  // ─── Derived properties ───────────────────────────────────────────────

  /// The candle open time as a [DateTime] (UTC).
  DateTime get dateTime =>
      DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);

  /// Whether this candle is bullish (close ≥ open).
  bool get isBullish => close >= open;

  /// Whether this candle is bearish (close < open).
  bool get isBearish => close < open;

  /// Absolute body size |close − open|.
  double get bodySize => (close - open).abs();

  /// Full range (high − low).
  double get range => high - low;

  /// Mid-price (high + low) / 2.
  double get midpoint => (high + low) / 2.0;

  // ─── Equality & display ───────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CandleData &&
          timestamp == other.timestamp &&
          open == other.open &&
          high == other.high &&
          low == other.low &&
          close == other.close &&
          volume == other.volume;

  @override
  int get hashCode => Object.hash(timestamp, open, high, low, close, volume);

  @override
  String toString() =>
      'CandleData(ts=$timestamp, O=$open, H=$high, L=$low, C=$close, V=$volume)';
}
