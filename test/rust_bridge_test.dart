import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/services/rust_bridge.dart';

void main() {
  group('RustBridge', () {
    setUpAll(() async {
      await RustBridge.initialize();
    });

    test('ping returns response', () async {
      final result = await RustBridge.ping();
      expect(result, isNotEmpty);
      expect(result, contains('pong'));
    });

    test('getVersion returns version', () async {
      final version = await RustBridge.getVersion();
      expect(version, contains('0.1.0'));
    });

    test('getSupportedTimeframes returns valid list', () async {
      final timeframes = await RustBridge.getSupportedTimeframes();
      expect(timeframes, isNotEmpty);
      expect(timeframes, contains('1h'));
      expect(timeframes, contains('1m'));
      expect(timeframes, contains('4h'));
    });

    test('createTestCandle returns valid candle', () async {
      final candle = await RustBridge.createTestCandle();
      expect(candle.timestamp, greaterThan(0));
      expect(candle.open, greaterThan(0));
      expect(candle.high, greaterThanOrEqualTo(candle.open));
      expect(candle.close, greaterThan(0));
      expect(candle.isBullish, isTrue);
    });

    test('getSampleManifest returns valid JSON', () async {
      final json = await RustBridge.getSampleManifest();
      final manifest = jsonDecode(json) as Map<String, dynamic>;
      expect(manifest['id'], 'bb_rsi_v1');
      expect(manifest['name'], contains('Bollinger'));
      expect(manifest['parameters'], isList);
      expect((manifest['parameters'] as List).length, 5);
    });
  });

  group('RustCandle', () {
    test('fromJson creates valid candle', () {
      final json = {
        'timestamp': 1716307200000,
        'open': 67500.0,
        'high': 68200.0,
        'low': 67100.0,
        'close': 67850.0,
        'volume': 1234.56,
      };
      final candle = RustCandle.fromJson(json);
      expect(candle.timestamp, 1716307200000);
      expect(candle.isBullish, isTrue);
      expect(candle.bodySize, closeTo(350.0, 0.01));
      expect(candle.range, closeTo(1100.0, 0.01));
    });

    test('toJson roundtrips correctly', () {
      const candle = RustCandle(
        timestamp: 1000,
        open: 100.0,
        high: 110.0,
        low: 95.0,
        close: 105.0,
        volume: 500.0,
      );
      final json = candle.toJson();
      final restored = RustCandle.fromJson(json);
      expect(restored.timestamp, candle.timestamp);
      expect(restored.open, candle.open);
      expect(restored.close, candle.close);
    });
  });

  group('RustSignal', () {
    test('noAction is not actionable', () {
      final signal = RustSignal.noAction();
      expect(signal.isActionable, isFalse);
      expect(signal.isEntry, isFalse);
      expect(signal.isExit, isFalse);
    });

    test('enterLong is actionable entry', () {
      final signal = RustSignal.enterLong(sl: 95.0, tp: 110.0, sizePct: 50.0);
      expect(signal.isActionable, isTrue);
      expect(signal.isEntry, isTrue);
      expect(signal.isExit, isFalse);
      expect(signal.sl, 95.0);
      expect(signal.sizePct, 50.0);
    });

    test('exit is actionable exit', () {
      final signal = RustSignal.exit('RSI overbought');
      expect(signal.isActionable, isTrue);
      expect(signal.isExit, isTrue);
      expect(signal.isEntry, isFalse);
      expect(signal.exitReason, 'RSI overbought');
    });
  });
}
