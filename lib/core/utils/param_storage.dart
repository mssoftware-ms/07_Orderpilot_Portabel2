/// Persistent storage for optimized BB+RSI parameters.
///
/// Stores optimized parameters per symbol+timeframe combination as a JSON file
/// in the app's documents directory. Falls back to default parameters when
/// no optimized values are available.
library;

import 'dart:convert';
import 'dart:io';

import '../../services/backtest_service.dart';

/// Manages persistent storage of optimized strategy parameters.
class OptimizedParamsStorage {
  /// Custom storage directory (for testing or override).
  final String? _customDir;

  /// In-memory cache of loaded params.
  final Map<String, BbRsiParams> _cache = {};

  OptimizedParamsStorage({String? storageDir}) : _customDir = storageDir;

  // ─── Public API ─────────────────────────────────────────────────────────

  /// Save optimized parameters for a symbol+timeframe pair.
  Future<void> saveOptimizedParams(
    String symbol,
    String timeframe,
    BbRsiParams params,
  ) async {
    final data = await _loadAllData();
    final key = _key(symbol, timeframe);
    data[key] = _paramsToJson(params);
    _cache[key] = params;
    await _saveAllData(data);
  }

  /// Load optimized parameters for a symbol+timeframe pair.
  /// Returns null if no optimized parameters exist.
  Future<BbRsiParams?> loadOptimizedParams(
    String symbol,
    String timeframe,
  ) async {
    final key = _key(symbol, timeframe);

    // Check in-memory cache first
    if (_cache.containsKey(key)) return _cache[key];

    final data = await _loadAllData();
    if (data.containsKey(key)) {
      final params = _paramsFromJson(data[key] as Map<String, dynamic>);
      _cache[key] = params;
      return params;
    }
    return null;
  }

  /// Check if optimized parameters exist for a symbol+timeframe pair.
  Future<bool> hasOptimizedParams(String symbol, String timeframe) async {
    final key = _key(symbol, timeframe);
    if (_cache.containsKey(key)) return true;
    final data = await _loadAllData();
    return data.containsKey(key);
  }

  /// Delete optimized parameters for a symbol+timeframe pair.
  Future<void> deleteOptimizedParams(String symbol, String timeframe) async {
    final key = _key(symbol, timeframe);
    _cache.remove(key);
    final data = await _loadAllData();
    data.remove(key);
    await _saveAllData(data);
  }

  /// Clear all stored parameters.
  Future<void> clearAll() async {
    _cache.clear();
    final file = await _getFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// List all stored symbol+timeframe combinations.
  Future<List<String>> listStoredKeys() async {
    final data = await _loadAllData();
    return data.keys.toList();
  }

  // ─── Internal helpers ───────────────────────────────────────────────────

  String _key(String symbol, String timeframe) => '${symbol}_$timeframe';

  Future<File> _getFile() async {
    final dir = _customDir ?? await _getStorageDir();
    final directory = Directory(dir);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File('$dir/optimized_params.json');
  }

  Future<String> _getStorageDir() async {
    // Use path_provider if available, otherwise fallback to temp
    // For desktop/testing, use a predictable location
    try {
      // Try to use path_provider's getApplicationDocumentsDirectory
      // If not available (e.g., in tests), fall back to temp
      final homeDir = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.systemTemp.path;
      return '$homeDir/.trading_app';
    } catch (_) {
      return '${Directory.systemTemp.path}/trading_app';
    }
  }

  Future<Map<String, dynamic>> _loadAllData() async {
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          return jsonDecode(content) as Map<String, dynamic>;
        }
      }
    } catch (_) {
      // Corrupted file – return empty
    }
    return {};
  }

  Future<void> _saveAllData(Map<String, dynamic> data) async {
    final file = await _getFile();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    await file.writeAsString(jsonStr);
  }

  Map<String, dynamic> _paramsToJson(BbRsiParams p) => {
        'bb_period': p.bbPeriod,
        'bb_stddev': p.bbStdDev,
        'rsi_period': p.rsiPeriod,
        'rsi_oversold': p.rsiOversold,
        'rsi_overbought': p.rsiOverbought,
      };

  BbRsiParams _paramsFromJson(Map<String, dynamic> json) => BbRsiParams(
        bbPeriod: json['bb_period'] as int,
        bbStdDev: (json['bb_stddev'] as num).toDouble(),
        rsiPeriod: json['rsi_period'] as int,
        rsiOversold: (json['rsi_oversold'] as num).toDouble(),
        rsiOverbought: (json['rsi_overbought'] as num).toDouble(),
      );
}
