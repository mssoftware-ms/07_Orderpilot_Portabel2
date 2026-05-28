/// Application-wide constants
class AppConstants {
  // API endpoints
  static const String binanceBaseUrl = 'https://api.binance.com';
  static const String binanceKlinesEndpoint = '/api/v3/klines';

  /// Bitunix Futures REST base URL — see Welle P4P (Phase-4-Prep) Step-1.
  /// Auth-Tests run against production (no public testnet); only read-only
  /// calls are exercised. Live order paths are gated behind Welle B4 Step-3.
  static const String bitunixFuturesBaseUrl = 'https://fapi.bitunix.com';

  // Default trading parameters
  static const double defaultInitialCapital = 10000.0;
  static const double defaultFeeRate = 0.0006; // Bitunix VIP0 taker
  static const int defaultCandleCount = 1000;

  // Supported symbols
  static const List<String> supportedSymbols = ['BTCUSDT', 'ETHUSDT'];

  // Supported timeframes.
  //
  // Welle P4C-H-1: `'3h'` was removed because Binance Spot's kline
  // endpoint has no 3h interval — selecting it left the chart frozen
  // on a silent WS connect failure. `'30m'` takes its slot so the chip
  // row keeps eight entries (no UI re-layout) and the whitelist stays
  // a strict subset of Binance's documented kline intervals
  // (`1s, 1m, 3m, 5m, 15m, 30m, 1h, 2h, 4h, 6h, 8h, 12h, 1d, 3d, 1w, 1M`).
  static const List<String> supportedTimeframes = [
    '1m', '5m', '15m', '30m', '1h', '2h', '4h', '1d',
  ];

  /// Binance Spot kline-interval whitelist as documented at
  /// <https://developers.binance.com/docs/binance-spot-api-docs/web-socket-streams#kline-candlestick-streams>.
  /// Used by [AppConstantsAssertions] (see test) to pin
  /// [supportedTimeframes] against the upstream set so future
  /// additions can't repeat the `'3h'` mistake.
  static const Set<String> binanceSpotKlineIntervals = {
    '1s', '1m', '3m', '5m', '15m', '30m',
    '1h', '2h', '4h', '6h', '8h', '12h',
    '1d', '3d', '1w', '1M',
  };

  // BB+RSI defaults
  static const int defaultBBPeriod = 20;
  static const double defaultBBStdDev = 2.0;
  static const int defaultRSIPeriod = 14;
  static const double defaultRSIOversold = 30.0;
  static const double defaultRSIOverbought = 70.0;
}
