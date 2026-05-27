/// Bitunix Futures connector exception hierarchy — Welle P4P Step-1.
///
/// All exceptions live in their own file so the connector code (REST client,
/// provider, UI) can `import` them without dragging in the full client surface.
library;

/// Hard-thrown by every order-routing path until Welle B4 Step-3 lands the
/// risk layer (kill switch, daily-loss cap, position-size guard). Carries a
/// fixed message that points the reader at the next gate so a developer who
/// stumbles across it knows where to look. The message is also surfaced to
/// the user verbatim in the Account screen's Live-Trading tooltip.
class LiveTradingDisabledException implements Exception {
  final String message;

  const LiveTradingDisabledException([
    this.message =
        'Live trading requires Welle B4 Step-3 risk layer (kill-switch, '
        'daily-loss cap). placeOrder / cancelOrder are intentionally disabled.',
  ]);

  @override
  String toString() => 'LiveTradingDisabledException: $message';
}

/// Bitunix-side authentication failure — bad signature, expired timestamp,
/// missing api-key, or a key that has been revoked on the exchange side.
/// Always raised on HTTP 401/403 so the provider can surface a single
/// "Authentication failed" status to the user without exposing the
/// underlying response body (which may echo headers).
class BitunixAuthException implements Exception {
  final String message;
  final int? statusCode;

  const BitunixAuthException(this.message, [this.statusCode]);

  @override
  String toString() => 'BitunixAuthException'
      '${statusCode != null ? '($statusCode)' : ''}: $message';
}

/// Catch-all for non-auth Bitunix API errors. Carries the HTTP status and
/// optionally the raw body so a developer debugging an unexpected response
/// can see what came back; the provider scrubs this before logging to keep
/// the body off the user-visible log panel.
class BitunixApiException implements Exception {
  final int statusCode;
  final String message;
  final String? body;

  const BitunixApiException(this.statusCode, this.message, [this.body]);

  @override
  String toString() => 'BitunixApiException($statusCode): $message';
}
