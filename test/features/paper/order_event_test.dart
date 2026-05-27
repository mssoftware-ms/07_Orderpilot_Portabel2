/// Welle B4.2-3 — OrderEvent value semantics.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/features/paper/order_event.dart';

void main() {
  group('OrderEvent', () {
    test('constructor wires the three required fields', () {
      final ts = DateTime.utc(2026, 1, 1);
      const msg = 'LONG opened @ 100.50';
      final ev = OrderEvent(
        timestamp: ts,
        kind: OrderEventKind.positionOpened,
        message: msg,
      );
      expect(ev.timestamp, ts);
      expect(ev.kind, OrderEventKind.positionOpened);
      expect(ev.message, msg);
    });

    test('equality compares all fields', () {
      final ts = DateTime.utc(2026, 1, 1);
      final a = OrderEvent(
        timestamp: ts,
        kind: OrderEventKind.tpHit,
        message: 'TP hit @ 110',
      );
      final b = OrderEvent(
        timestamp: ts,
        kind: OrderEventKind.tpHit,
        message: 'TP hit @ 110',
      );
      final c = OrderEvent(
        timestamp: ts,
        kind: OrderEventKind.slHit,
        message: 'TP hit @ 110',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('all enum kinds are exposed for the wire surface', () {
      // Freezes the enum shape; future code touching OrderEventKind has
      // to consciously bump this assertion. Persisted serialisations
      // (none today, but the Phase-4 audit log will probably add one)
      // depend on this stability.
      expect(OrderEventKind.values, hasLength(8));
      expect(OrderEventKind.values, contains(OrderEventKind.signalReceived));
      expect(OrderEventKind.values, contains(OrderEventKind.positionOpened));
      expect(OrderEventKind.values, contains(OrderEventKind.positionClosed));
      expect(OrderEventKind.values, contains(OrderEventKind.slHit));
      expect(OrderEventKind.values, contains(OrderEventKind.tpHit));
      expect(OrderEventKind.values, contains(OrderEventKind.sessionStarted));
      expect(OrderEventKind.values, contains(OrderEventKind.sessionStopped));
      expect(OrderEventKind.values, contains(OrderEventKind.wsReconnect));
    });

    test('kOrderTrailCap pins the ring-buffer capacity at 100', () {
      expect(kOrderTrailCap, 100);
    });
  });
}
