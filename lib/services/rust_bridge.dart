/// Rust Bridge - Interface to the Rust trading_engine crate.
///
/// This file provides Dart wrappers around the Rust FFI functions exposed
/// by flutter_rust_bridge. When the full codegen pipeline runs during build,
/// the auto-generated bindings will be placed in lib/src/rust/frb_generated.dart
/// and this file will delegate to them.
///
/// For now, this provides the API contract and fallback implementations
/// for development/testing without the native library.
library;

import 'dart:convert';

// ─── Data Models (mirrors Rust structs) ──────────────────────────────────────

/// Mirrors the Rust `Candle` struct.
class RustCandle {
  final int timestamp;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const RustCandle({
    required this.timestamp,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory RustCandle.fromJson(Map<String, dynamic> json) {
    return RustCandle(
      timestamp: json['timestamp'] as int,
      open: (json['open'] as num).toDouble(),
      high: (json['high'] as num).toDouble(),
      low: (json['low'] as num).toDouble(),
      close: (json['close'] as num).toDouble(),
      volume: (json['volume'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp,
        'open': open,
        'high': high,
        'low': low,
        'close': close,
        'volume': volume,
      };

  bool get isBullish => close >= open;
  double get bodySize => (close - open).abs();
  double get range => high - low;
}

/// Mirrors the Rust `Signal` enum.
enum SignalType { enterLong, enterShort, exit, moveStop, noAction }

class RustSignal {
  final SignalType type;
  final double? sl;
  final List<double> tp;
  final double sizePct;
  final String? exitReason;
  final double? newSl;

  const RustSignal({
    required this.type,
    this.sl,
    this.tp = const [],
    this.sizePct = 100.0,
    this.exitReason,
    this.newSl,
  });

  bool get isActionable => type != SignalType.noAction;
  bool get isEntry =>
      type == SignalType.enterLong || type == SignalType.enterShort;
  bool get isExit => type == SignalType.exit;

  static RustSignal noAction() =>
      const RustSignal(type: SignalType.noAction);

  static RustSignal enterLong({double? sl, List<double>? tp, double sizePct = 100.0}) =>
      RustSignal(type: SignalType.enterLong, sl: sl, tp: tp ?? [], sizePct: sizePct);

  static RustSignal enterShort({double? sl, List<double>? tp, double sizePct = 100.0}) =>
      RustSignal(type: SignalType.enterShort, sl: sl, tp: tp ?? [], sizePct: sizePct);

  static RustSignal exit(String reason) =>
      RustSignal(type: SignalType.exit, exitReason: reason);
}

/// Mirrors the Rust `BacktestMetrics` struct.
class RustBacktestMetrics {
  final int totalTrades;
  final int winningTrades;
  final int losingTrades;
  final double winRate;
  final double profitFactor;
  final double totalPnl;
  final double totalPnlPercent;
  final double maxDrawdown;
  final double maxDrawdownPercent;
  final double sharpeRatio;

  const RustBacktestMetrics({
    required this.totalTrades,
    required this.winningTrades,
    required this.losingTrades,
    required this.winRate,
    required this.profitFactor,
    required this.totalPnl,
    required this.totalPnlPercent,
    required this.maxDrawdown,
    required this.maxDrawdownPercent,
    required this.sharpeRatio,
  });

  factory RustBacktestMetrics.empty() => const RustBacktestMetrics(
        totalTrades: 0,
        winningTrades: 0,
        losingTrades: 0,
        winRate: 0,
        profitFactor: 0,
        totalPnl: 0,
        totalPnlPercent: 0,
        maxDrawdown: 0,
        maxDrawdownPercent: 0,
        sharpeRatio: 0,
      );

  factory RustBacktestMetrics.fromJson(Map<String, dynamic> json) {
    return RustBacktestMetrics(
      totalTrades: json['total_trades'] as int,
      winningTrades: json['winning_trades'] as int,
      losingTrades: json['losing_trades'] as int,
      winRate: (json['win_rate'] as num).toDouble(),
      profitFactor: (json['profit_factor'] as num).toDouble(),
      totalPnl: (json['total_pnl'] as num).toDouble(),
      totalPnlPercent: (json['total_pnl_percent'] as num).toDouble(),
      maxDrawdown: (json['max_drawdown'] as num).toDouble(),
      maxDrawdownPercent: (json['max_drawdown_percent'] as num).toDouble(),
      sharpeRatio: (json['sharpe_ratio'] as num).toDouble(),
    );
  }
}

// ─── Rust Bridge Interface ───────────────────────────────────────────────────

/// Primary interface to the Rust trading engine.
///
/// In production builds, these methods delegate to flutter_rust_bridge
/// auto-generated FFI bindings. In development/test mode, they return
/// mock/fallback data.
class RustBridge {
  static bool _initialized = false;
  static bool _nativeAvailable = false;

  /// Initialize the Rust bridge.
  /// Call this once at app startup (e.g., in main.dart).
  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      // In production, this would load the native library:
      // await RustLib.init();
      _nativeAvailable = false; // Will be true when native lib is linked
      _initialized = true;
      // ignore: avoid_print
      print('[RustBridge] Initialized (native: $_nativeAvailable)');
    } catch (e) {
      _initialized = true;
      _nativeAvailable = false;
      // ignore: avoid_print
      print('[RustBridge] Fallback mode - native library not available: $e');
    }
  }

  /// Check if the native Rust library is available.
  static bool get isNativeAvailable => _nativeAvailable;

  /// Ping the Rust engine to verify connectivity.
  static Future<String> ping() async {
    if (_nativeAvailable) {
      // return await api.ping();
    }
    return 'pong from Dart fallback (Rust engine not yet linked)';
  }

  /// Get the Rust engine version.
  static Future<String> getVersion() async {
    if (_nativeAvailable) {
      // return await api.getVersion();
    }
    return '0.1.0 (Dart fallback)';
  }

  /// Get supported timeframes from the Rust engine.
  static Future<List<String>> getSupportedTimeframes() async {
    if (_nativeAvailable) {
      // return await api.getSupportedTimeframes();
    }
    return ['1m', '5m', '15m', '30m', '1h', '4h', '1d', '1w'];
  }

  /// Create a test candle (for bridge verification).
  static Future<RustCandle> createTestCandle() async {
    if (_nativeAvailable) {
      // final c = await api.createTestCandle();
      // return RustCandle(timestamp: c.timestamp, ...);
    }
    return const RustCandle(
      timestamp: 1716307200000,
      open: 67500.0,
      high: 68200.0,
      low: 67100.0,
      close: 67850.0,
      volume: 1234.56,
    );
  }

  /// Get the sample strategy manifest as JSON.
  static Future<String> getSampleManifest() async {
    if (_nativeAvailable) {
      // return await api.getSampleManifest();
    }
    return jsonEncode({
      'id': 'bb_rsi_v1',
      'name': 'Bollinger Bands + RSI Mean Reversion',
      'version': '1.0.0',
      'author': 'Trading App Team',
      'description':
          'Buy when price touches lower BB and RSI < 30, exit at middle BB or RSI > 70',
      'category': 'MeanReversion',
      'timeframes': ['15m', '1h', '4h'],
      'parameters': [
        {'name': 'bb_period', 'display_name': 'BB Period', 'default': 20.0, 'min': 10.0, 'max': 50.0, 'step': 1.0},
        {'name': 'bb_stddev', 'display_name': 'BB Std Dev', 'default': 2.0, 'min': 1.0, 'max': 3.0, 'step': 0.1},
        {'name': 'rsi_period', 'display_name': 'RSI Period', 'default': 14.0, 'min': 7.0, 'max': 30.0, 'step': 1.0},
        {'name': 'rsi_oversold', 'display_name': 'RSI Oversold', 'default': 30.0, 'min': 20.0, 'max': 40.0, 'step': 1.0},
        {'name': 'rsi_overbought', 'display_name': 'RSI Overbought', 'default': 70.0, 'min': 60.0, 'max': 80.0, 'step': 1.0},
      ],
    });
  }

  // ─── Future API (will be implemented with full Rust bridge) ──────────────

  /// Run a backtest with the given parameters.
  /// Will delegate to Rust engine once native library is linked.
  static Future<RustBacktestMetrics> runBacktest({
    required String symbol,
    required String timeframe,
    required int candleCount,
    required double initialCapital,
    required double feeRate,
    required Map<String, double> strategyParams,
  }) async {
    // TODO: Delegate to Rust engine
    return RustBacktestMetrics.empty();
  }

  /// Start paper trading with live data.
  static Future<bool> startPaperTrading({
    required String symbol,
    required String timeframe,
    required double initialCapital,
    required Map<String, double> strategyParams,
  }) async {
    // TODO: Delegate to Rust engine
    return false;
  }

  /// Stop paper trading.
  static Future<void> stopPaperTrading() async {
    // TODO: Delegate to Rust engine
  }
}
