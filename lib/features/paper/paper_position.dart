/// Open virtual position in a paper-trading session.
///
/// Re-derived after every WS tick by reading
/// [BacktestResult.openPosition], which the engine populates when called
/// with `extractOpenPosition: true` — see Welle B4.2-1.
///
/// `slPrice` and `tpPrice` come from the engine snapshot and stay
/// nullable so warm-up edge cases (NaN/Inf in the SL/TP placement) and
/// future non-SL strategies render as "—" instead of leaking degenerate
/// floats to the UI.
library;

import 'package:flutter/foundation.dart';

@immutable
class PaperPosition {
  /// `'LONG'` or `'SHORT'`. Matches [ClosedTrade.direction] casing so
  /// the same widgets render both.
  final String direction;

  /// Actual filled entry price (next-bar-open × slippage factor
  /// inside the engine).
  final double entryPrice;

  /// Filled quantity, derived from `risk × balance × signal-bar close`
  /// (Diff D-09 sizing) inside the engine.
  final double quantity;

  /// Unix ms timestamp of the FILL bar (next bar after the signal).
  /// Matches `ClosedTrade.entryTimestamp` so PaperPosition can be
  /// derived directly from the engine's last trade entry.
  final int openedAt;

  /// Absolute SL price at entry. Null when the engine snapshot reports
  /// a missing or non-finite SL — UI renders "—".
  final double? slPrice;

  /// Absolute TP price at entry. Null under the same conditions as
  /// [slPrice].
  final double? tpPrice;

  const PaperPosition({
    required this.direction,
    required this.entryPrice,
    required this.quantity,
    required this.openedAt,
    this.slPrice,
    this.tpPrice,
  });

  bool get isLong => direction == 'LONG';

  /// Notional value at entry (`entryPrice × quantity`).
  double get entryNotional => entryPrice * quantity;

  /// Unrealized P&L at the given mark price (gross — fee-free, since
  /// the engine already deducted the entry fee from the available
  /// balance; the future exit fee is unknown until close).
  double unrealizedPnl(double markPrice) {
    final delta = isLong ? markPrice - entryPrice : entryPrice - markPrice;
    return delta * quantity;
  }

  /// Unrealized P&L as a percentage of entry notional.
  double unrealizedPnlPercent(double markPrice) {
    final notional = entryNotional;
    if (notional <= 0) return 0.0;
    return (unrealizedPnl(markPrice) / notional) * 100.0;
  }
}
