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
import 'dart:io' show File, Platform;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../core/logging/app_log.dart';
import '../core/models/candle.dart';
import '../core/models/trade.dart';
import '../src/bridge/api.dart' as rust;
import '../src/bridge/frb_generated.dart';

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
  final double? tp;
  final double sizePct;
  final String? exitReason;
  final double? newSl;

  const RustSignal({
    required this.type,
    this.sl,
    this.tp,
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

  static RustSignal enterLong({double? sl, double? tp, double sizePct = 100.0}) =>
      RustSignal(type: SignalType.enterLong, sl: sl, tp: tp, sizePct: sizePct);

  static RustSignal enterShort({double? sl, double? tp, double sizePct = 100.0}) =>
      RustSignal(type: SignalType.enterShort, sl: sl, tp: tp, sizePct: sizePct);

  static RustSignal exit(String reason) =>
      RustSignal(type: SignalType.exit, exitReason: reason);
}

/// FFI data-transfer object mirroring the Rust `BacktestMetrics` struct.
///
/// This is **not** a parallel metrics class — it carries the raw Rust payload
/// across the bridge and is converted to the canonical [BacktestMetrics]
/// (lib/core/models/trade.dart) via [toBacktestMetrics] before use by the
/// rest of the app (F-06).
///
/// `totalFees` and `candlesProcessed` are not (yet) part of the Rust payload;
/// they are passed through the converter from the FFI call site that knows
/// the input candle count and fee accounting. This is the deliberate
/// minimum-viable shape for F-06; full field parity with the Rust struct is
/// owned by F-01 (FFI Bridge).
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

  /// Convert this FFI DTO into the canonical [BacktestMetrics] used by the
  /// rest of the app.
  ///
  /// [totalFees] and [candlesProcessed] are accepted as parameters because
  /// the Rust struct does not (yet) carry them; F-01 owns extending the FFI
  /// payload. F-06 only guarantees that the converter exists and produces
  /// the canonical type.
  BacktestMetrics toBacktestMetrics({
    double totalFees = 0,
    int candlesProcessed = 0,
  }) {
    return BacktestMetrics(
      totalTrades: totalTrades,
      winningTrades: winningTrades,
      losingTrades: losingTrades,
      winRate: winRate,
      profitFactor: profitFactor,
      totalPnl: totalPnl,
      totalPnlPercent: totalPnlPercent,
      maxDrawdown: maxDrawdown,
      maxDrawdownPercent: maxDrawdownPercent,
      sharpeRatio: sharpeRatio,
      totalFees: totalFees,
      candlesProcessed: candlesProcessed,
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
  ///
  /// Idempotent — calling more than once is a no-op. After return,
  /// [isNativeAvailable] reflects whether subsequent calls will hit the
  /// native engine (true) or the pure-Dart fallback (false). Initialisation
  /// never throws; FFI failures degrade silently to the fallback path so
  /// the app still boots when running on a host without the cdylib.
  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      final ext = _findDevLibrary();
      if (ext != null) {
        await RustLib.init(externalLibrary: ext);
      } else {
        await RustLib.init();
      }
      // Probe with the cheapest possible call. If the symbol resolves and
      // returns a non-empty string, the engine is wired correctly.
      final pong = await rust.ping();
      _nativeAvailable = pong.isNotEmpty;
      _initialized = true;
      // ignore: avoid_print
      print('[RustBridge] Native engine active: $pong');
    } catch (e, st) {
      _initialized = true;
      _nativeAvailable = false;
      AppLog.warn('RustBridge',
          'Native engine not available, falling back to Dart: $e', e, st);
      // ignore: avoid_print
      print('[RustBridge] Native engine not available, '
          'falling back to Dart: $e');
    }
  }

  /// Locate the cargo-built `libtrading_engine.{so,dylib,dll}` for dev/test
  /// runs. Production `flutter build` uses the cargokit-bundled library and
  /// gets `null` here, falling through to [RustLib.init]'s default lookup.
  static ExternalLibrary? _findDevLibrary() {
    String? name;
    if (Platform.isLinux) {
      name = 'libtrading_engine.so';
    } else if (Platform.isMacOS) {
      name = 'libtrading_engine.dylib';
    } else if (Platform.isWindows) {
      name = 'trading_engine.dll';
    }
    if (name == null) return null;

    for (final profile in const ['release', 'debug']) {
      final path = 'rust/trading_engine/target/$profile/$name';
      if (File(path).existsSync()) {
        return ExternalLibrary.open(path);
      }
    }
    return null;
  }

  /// Check if the native Rust library is available.
  static bool get isNativeAvailable => _nativeAvailable;

  /// Ping the Rust engine to verify connectivity.
  static Future<String> ping() async {
    if (_nativeAvailable) return rust.ping();
    return 'pong from Dart fallback (Rust engine not yet linked)';
  }

  /// Get the Rust engine version.
  static Future<String> getVersion() async {
    if (_nativeAvailable) return rust.getVersion();
    return '0.1.0 (Dart fallback)';
  }

  /// Get supported timeframes from the Rust engine.
  static Future<List<String>> getSupportedTimeframes() async {
    if (_nativeAvailable) return rust.getSupportedTimeframes();
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

  /// Run a BB+RSI backtest on the given candles.
  ///
  /// Delegates to the Rust `run_bb_rsi_backtest` FFI function when the native
  /// engine is available; returns an empty [BacktestMetrics] with a logged
  /// warning otherwise. The returned [BacktestMetrics] is the canonical type
  /// from `lib/core/models/trade.dart` (F-06) — same type the pure-Dart
  /// `BacktestService.runBbRsi` produces, so callers can swap engines without
  /// adapting downstream consumers.
  ///
  /// [strategyParams] is a JSON-compatible parameter override map (e.g.
  /// `{'bb_period': 25, 'rsi_oversold': 28}`). Empty = use Rust defaults.
  ///
  /// `totalFees` and `candlesProcessed` are read from the BacktestResult
  /// top-level (not from BacktestMetrics) — see the FFI wrapper rationale
  /// at [RustBacktestMetrics].
  static Future<BacktestMetrics> runBacktest({
    required List<CandleData> candles,
    required double initialBalance,
    required double feeRate,
    Map<String, double> strategyParams = const {},
  }) async {
    if (!_nativeAvailable) {
      // ignore: avoid_print
      print('[RustBridge] runBacktest called without native engine — '
          'returning empty metrics');
      return BacktestMetrics.empty();
    }

    final candlesJson =
        jsonEncode(candles.map((c) => c.toRustJson()).toList());
    final paramsJson = jsonEncode(strategyParams);

    final responseJson = await rust.runBbRsiBacktest(
      candlesJson: candlesJson,
      paramsJson: paramsJson,
      initialBalance: initialBalance,
      feeRate: feeRate,
    );

    final decoded = jsonDecode(responseJson) as Map<String, dynamic>;
    if (decoded.containsKey('error')) {
      throw Exception('Rust backtest failed: ${decoded['error']}');
    }

    final metricsJson = decoded['metrics'] as Map<String, dynamic>;
    final totalFees = (decoded['total_fees'] as num).toDouble();
    final candlesProcessed = decoded['candles_processed'] as int;

    final rustMetrics = RustBacktestMetrics.fromJson(metricsJson);
    return rustMetrics.toBacktestMetrics(
      totalFees: totalFees,
      candlesProcessed: candlesProcessed,
    );
  }

  /// Run a UT Bot Alerts (verbesserte Variante) backtest on the given candles.
  ///
  /// Mirrors [runBacktest] for the second Phase-2 strategy. Delegates to
  /// `run_ut_bot_backtest` via flutter_rust_bridge when the native engine
  /// is available; logs a warning and returns an empty [BacktestMetrics]
  /// otherwise — same fail-soft contract as the BB+RSI wrapper.
  ///
  /// [strategyParams] is a JSON-compatible parameter override map matching
  /// the keys in `ut_bot_manifest()` (e.g. `{'key_value': 3.0, 'atr_period': 5}`).
  /// Empty = use Rust defaults (strict spec per `ut_bot_spec.md` §1).
  static Future<BacktestMetrics> runUtBotBacktest({
    required List<CandleData> candles,
    required double initialBalance,
    required double feeRate,
    Map<String, double> strategyParams = const {},
  }) async {
    if (!_nativeAvailable) {
      // ignore: avoid_print
      print('[RustBridge] runUtBotBacktest called without native engine — '
          'returning empty metrics');
      return BacktestMetrics.empty();
    }

    final candlesJson =
        jsonEncode(candles.map((c) => c.toRustJson()).toList());
    final paramsJson = jsonEncode(strategyParams);

    final responseJson = await rust.runUtBotBacktest(
      candlesJson: candlesJson,
      paramsJson: paramsJson,
      initialBalance: initialBalance,
      feeRate: feeRate,
    );

    final decoded = jsonDecode(responseJson) as Map<String, dynamic>;
    if (decoded.containsKey('error')) {
      throw Exception('Rust UT Bot backtest failed: ${decoded['error']}');
    }

    final metricsJson = decoded['metrics'] as Map<String, dynamic>;
    final totalFees = (decoded['total_fees'] as num).toDouble();
    final candlesProcessed = decoded['candles_processed'] as int;

    final rustMetrics = RustBacktestMetrics.fromJson(metricsJson);
    return rustMetrics.toBacktestMetrics(
      totalFees: totalFees,
      candlesProcessed: candlesProcessed,
    );
  }

  /// Run an Ichimoku Cloud Retest backtest on the given candles.
  ///
  /// Mirrors [runBacktest] / [runUtBotBacktest] for the third Phase-2
  /// strategy. Delegates to `run_ichimoku_backtest` via flutter_rust_
  /// bridge when the native engine is available; logs a warning and
  /// returns an empty [BacktestMetrics] otherwise — same fail-soft
  /// contract as the BB+RSI / UT-Bot wrappers.
  ///
  /// [strategyParams] is a JSON-compatible parameter override map
  /// matching the keys in `ichimoku_manifest()` (e.g.
  /// `{'score_threshold': 40, 'kijun_period': 30}`). Empty = use Rust
  /// defaults (strict-spec per Spec §1 / §12.2).
  static Future<BacktestMetrics> runIchimokuBacktest({
    required List<CandleData> candles,
    required double initialBalance,
    required double feeRate,
    Map<String, double> strategyParams = const {},
  }) async {
    if (!_nativeAvailable) {
      // ignore: avoid_print
      print('[RustBridge] runIchimokuBacktest called without native engine — '
          'returning empty metrics');
      return BacktestMetrics.empty();
    }

    final candlesJson =
        jsonEncode(candles.map((c) => c.toRustJson()).toList());
    final paramsJson = jsonEncode(strategyParams);

    final responseJson = await rust.runIchimokuBacktest(
      candlesJson: candlesJson,
      paramsJson: paramsJson,
      initialBalance: initialBalance,
      feeRate: feeRate,
    );

    final decoded = jsonDecode(responseJson) as Map<String, dynamic>;
    if (decoded.containsKey('error')) {
      throw Exception('Rust Ichimoku backtest failed: ${decoded['error']}');
    }

    final metricsJson = decoded['metrics'] as Map<String, dynamic>;
    final totalFees = (decoded['total_fees'] as num).toDouble();
    final candlesProcessed = decoded['candles_processed'] as int;

    final rustMetrics = RustBacktestMetrics.fromJson(metricsJson);
    return rustMetrics.toBacktestMetrics(
      totalFees: totalFees,
      candlesProcessed: candlesProcessed,
    );
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
