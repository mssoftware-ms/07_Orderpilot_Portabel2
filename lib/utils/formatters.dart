import 'package:intl/intl.dart';

/// Formatting helpers for the trading app
class Formatters {
  static final _currencyFormat = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
  static final _percentFormat = NumberFormat('##0.00');
  static final _priceFormat = NumberFormat('#,##0.00');
  static final _dateFormat = DateFormat('yyyy-MM-dd HH:mm');

  static String currency(double value) => _currencyFormat.format(value);
  static String percent(double value) => '${_percentFormat.format(value)}%';
  static String price(double value) => _priceFormat.format(value);
  static String dateTime(DateTime dt) => _dateFormat.format(dt);
  static String fromTimestamp(int ms) => _dateFormat.format(DateTime.fromMillisecondsSinceEpoch(ms));
}
