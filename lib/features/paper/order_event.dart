/// Paper-trading event-log entry — Welle B4.2-3.
///
/// One row of the "Order Trail" card on the Paper-Trading screen. Each
/// [OrderEvent] is a small, immutable value carrying the timestamp, the
/// kind of event (entry, exit, lifecycle, WS), and a short human-readable
/// message. PaperTradingProvider keeps a ring-buffered list of the most
/// recent [kOrderTrailCap] entries on the active [PaperSession].
library;

import 'package:flutter/foundation.dart';

/// Maximum number of events kept on the live session order trail.
/// 100 entries ≈ 50 round-trip trades plus lifecycle/WS chatter — enough
/// for any one-shot UI inspection without unbounded memory growth.
const int kOrderTrailCap = 100;

/// Discrete kinds of paper-trading events emitted into the order trail.
///
/// `signalReceived` is reserved for a future pending-order surface the
/// engine does not yet expose; the provider currently emits everything
/// else. Keeping it in the enum freezes the wire shape so a Phase-3
/// extension can fill it in without breaking persisted serialisations
/// (if those ever exist).
enum OrderEventKind {
  signalReceived,
  positionOpened,
  positionClosed,
  slHit,
  tpHit,
  sessionStarted,
  sessionStopped,
  wsReconnect,
}

@immutable
class OrderEvent {
  /// UTC wall-clock timestamp the event was recorded by the provider.
  /// Distinct from the engine-bar timestamp on closed trades so the UI
  /// can show real-time event ordering across multiple engine ticks.
  final DateTime timestamp;

  final OrderEventKind kind;

  /// Pre-formatted, short, human-readable label rendered as the row
  /// body in the order-trail card.
  final String message;

  const OrderEvent({
    required this.timestamp,
    required this.kind,
    required this.message,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OrderEvent &&
          timestamp == other.timestamp &&
          kind == other.kind &&
          message == other.message;

  @override
  int get hashCode => Object.hash(timestamp, kind, message);

  @override
  String toString() =>
      'OrderEvent(${kind.name}, ${timestamp.toIso8601String()}, $message)';
}
