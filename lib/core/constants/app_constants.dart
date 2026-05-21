/// Application-wide constants
class AppConstants {
  // API endpoints
  static const String binanceBaseUrl = 'https://api.binance.com';
  static const String binanceKlinesEndpoint = '/api/v3/klines';
  static const String bitunixWsUrl = 'wss://ws.bitunix.com/stream';

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
