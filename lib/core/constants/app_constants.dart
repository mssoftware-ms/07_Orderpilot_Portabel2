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

  // Supported timeframes
  static const List<String> supportedTimeframes = [
    '1m', '5m', '15m', '1h', '2h', '3h', '4h', '1d',
  ];

  // BB+RSI defaults
  static const int defaultBBPeriod = 20;
  static const double defaultBBStdDev = 2.0;
  static const int defaultRSIPeriod = 14;
  static const double defaultRSIOversold = 30.0;
  static const double defaultRSIOverbought = 70.0;
}
