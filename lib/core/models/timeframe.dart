/// Candle timeframe — mirrors the Rust `Timeframe` enum used by the FFI
/// backtest engine.
///
/// Naming and value set are kept identical to the Rust side so the two
/// engines can be cross-referenced 1:1 (Plan §3.4 F-03 numerical
/// equivalence).
library;

enum Timeframe {
  m1,
  m5,
  m15,
  m30,
  h1,
  h4,
  d1,
  w1;

  /// Exchange-style label (e.g. '1h'), matching Rust `Timeframe::as_str`.
  String get label => switch (this) {
        Timeframe.m1 => '1m',
        Timeframe.m5 => '5m',
        Timeframe.m15 => '15m',
        Timeframe.m30 => '30m',
        Timeframe.h1 => '1h',
        Timeframe.h4 => '4h',
        Timeframe.d1 => '1d',
        Timeframe.w1 => '1w',
      };
}
