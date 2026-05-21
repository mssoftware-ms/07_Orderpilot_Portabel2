import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants/app_constants.dart';
import '../core/models/candle.dart';

/// Client for fetching historical candle data from Binance REST API
class BinanceApiClient {
  final http.Client _client;

  BinanceApiClient({http.Client? client}) : _client = client ?? http.Client();

  /// Fetch historical klines/candles from Binance
  Future<List<CandleData>> fetchKlines({
    required String symbol,
    required String interval,
    int limit = AppConstants.defaultCandleCount,
    int? startTime,
    int? endTime,
  }) async {
    final queryParams = <String, String>{
      'symbol': symbol.toUpperCase(),
      'interval': interval,
      'limit': limit.toString(),
    };
    if (startTime != null) queryParams['startTime'] = startTime.toString();
    if (endTime != null) queryParams['endTime'] = endTime.toString();

    final uri = Uri.parse(
      '${AppConstants.binanceBaseUrl}${AppConstants.binanceKlinesEndpoint}',
    ).replace(queryParameters: queryParams);

    final response = await _client.get(uri);

    if (response.statusCode != 200) {
      throw Exception('Binance API error: ${response.statusCode} ${response.body}');
    }

    final List<dynamic> data = jsonDecode(response.body);
    return data.map((e) => CandleData.fromBinanceJson(e as List<dynamic>)).toList();
  }

  void dispose() => _client.close();
}
