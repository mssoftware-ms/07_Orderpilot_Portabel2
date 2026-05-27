/// Bitunix Futures read-only response models — Welle P4P Step-1.
///
/// Schemas verified against the official Bitunix doc:
///   * `https://www.bitunix.com/api-docs/futures/account/get_single_account.html`
///   * `https://www.bitunix.com/api-docs/futures/position/get_pending_positions.html`
///   * `https://www.bitunix.com/api-docs/futures/trade/get_pending_orders.html`
///
/// Every numeric field comes back as a JSON string from the exchange — we
/// keep the raw `String` representation alongside a parsed `double?` so the
/// UI can render the exchange's exact precision and downstream math can
/// still consume the numeric form. Unknown fields are tolerated (forward
/// compat); missing required fields fall back to safe defaults so a
/// schema drift downgrades gracefully to "0 / empty" rather than blowing
/// up the read-only sync.
library;

/// Parse a Bitunix numeric string to `double?`. Returns `null` for `null`,
/// empty, or unparseable input so the UI can show a `—` placeholder
/// instead of crashing on schema drift.
double? _parseDouble(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  if (raw is String) {
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }
  return null;
}

int? _parseInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is double) return raw.toInt();
  if (raw is String) {
    if (raw.isEmpty) return null;
    return int.tryParse(raw);
  }
  return null;
}

String _str(Object? raw) => raw == null ? '' : raw.toString();

// ─── Balance ────────────────────────────────────────────────────────────────

/// One entry of `GET /api/v1/futures/account` — a single margin coin's
/// balance snapshot. The Bitunix call always queries one [marginCoin] at a
/// time, so the provider holds the single most recently fetched entry.
class BitunixBalance {
  final String marginCoin;
  final double? available;
  final double? frozen;
  final double? margin;
  final double? transfer;
  final String positionMode; // ONE_WAY | HEDGE
  final double? crossUnrealizedPNL;
  final double? isolationUnrealizedPNL;
  final double? bonus;

  const BitunixBalance({
    required this.marginCoin,
    this.available,
    this.frozen,
    this.margin,
    this.transfer,
    this.positionMode = '',
    this.crossUnrealizedPNL,
    this.isolationUnrealizedPNL,
    this.bonus,
  });

  factory BitunixBalance.fromJson(Map<String, dynamic> json) => BitunixBalance(
        marginCoin: _str(json['marginCoin']),
        available: _parseDouble(json['available']),
        frozen: _parseDouble(json['frozen']),
        margin: _parseDouble(json['margin']),
        transfer: _parseDouble(json['transfer']),
        positionMode: _str(json['positionMode']),
        crossUnrealizedPNL: _parseDouble(json['crossUnrealizedPNL']),
        isolationUnrealizedPNL: _parseDouble(json['isolationUnrealizedPNL']),
        bonus: _parseDouble(json['bonus']),
      );

  /// Unrealized PnL aggregated across cross + isolation buckets — useful
  /// for the Balance-Card summary line.
  double get totalUnrealizedPNL =>
      (crossUnrealizedPNL ?? 0) + (isolationUnrealizedPNL ?? 0);
}

// ─── Position ───────────────────────────────────────────────────────────────

enum BitunixPositionSide { long, short, unknown }

BitunixPositionSide _parseSide(Object? raw) {
  switch (_str(raw).toUpperCase()) {
    case 'LONG':
    case 'BUY':
      return BitunixPositionSide.long;
    case 'SHORT':
    case 'SELL':
      return BitunixPositionSide.short;
    default:
      return BitunixPositionSide.unknown;
  }
}

/// One entry of `GET /api/v1/futures/position/get_pending_positions`.
class BitunixPosition {
  final String positionId;
  final String symbol;
  final double? qty;
  final double? entryValue;
  final BitunixPositionSide side;
  final String marginMode; // ISOLATION | CROSS
  final String positionMode; // ONE_WAY | HEDGE
  final int? leverage;
  final double? fee;
  final double? funding;
  final double? realizedPNL;
  final double? margin;
  final double? unrealizedPNL;
  final double? liqPrice;
  final double? marginRate;
  final double? avgOpenPrice;
  final int? ctime;
  final int? mtime;

  const BitunixPosition({
    required this.positionId,
    required this.symbol,
    this.qty,
    this.entryValue,
    this.side = BitunixPositionSide.unknown,
    this.marginMode = '',
    this.positionMode = '',
    this.leverage,
    this.fee,
    this.funding,
    this.realizedPNL,
    this.margin,
    this.unrealizedPNL,
    this.liqPrice,
    this.marginRate,
    this.avgOpenPrice,
    this.ctime,
    this.mtime,
  });

  factory BitunixPosition.fromJson(Map<String, dynamic> json) =>
      BitunixPosition(
        positionId: _str(json['positionId']),
        symbol: _str(json['symbol']),
        qty: _parseDouble(json['qty']),
        entryValue: _parseDouble(json['entryValue']),
        side: _parseSide(json['side']),
        marginMode: _str(json['marginMode']),
        positionMode: _str(json['positionMode']),
        leverage: _parseInt(json['leverage']),
        fee: _parseDouble(json['fee']),
        funding: _parseDouble(json['funding']),
        realizedPNL: _parseDouble(json['realizedPNL']),
        margin: _parseDouble(json['margin']),
        unrealizedPNL: _parseDouble(json['unrealizedPNL']),
        liqPrice: _parseDouble(json['liqPrice']),
        marginRate: _parseDouble(json['marginRate']),
        avgOpenPrice: _parseDouble(json['avgOpenPrice']),
        ctime: _parseInt(json['ctime']),
        mtime: _parseInt(json['mtime']),
      );
}

// ─── Order ──────────────────────────────────────────────────────────────────

/// One entry of `GET /api/v1/futures/trade/get_pending_orders`. The doc
/// returns these inside `data.orderList`; the client unpacks that for us.
class BitunixOrder {
  final String orderId;
  final String? clientId;
  final String symbol;
  final double? qty;
  final double? tradeQty;
  final double? price;
  final BitunixPositionSide side;
  final String orderType; // LIMIT | MARKET | ...
  final String status; // NEW | PART_FILLED | ...
  final double? fee;
  final double? realizedPNL;
  final double? tpPrice;
  final double? slPrice;
  final int? ctime;
  final int? mtime;
  final int? leverage;
  final String positionMode;
  final String marginMode;

  const BitunixOrder({
    required this.orderId,
    this.clientId,
    required this.symbol,
    this.qty,
    this.tradeQty,
    this.price,
    this.side = BitunixPositionSide.unknown,
    this.orderType = '',
    this.status = '',
    this.fee,
    this.realizedPNL,
    this.tpPrice,
    this.slPrice,
    this.ctime,
    this.mtime,
    this.leverage,
    this.positionMode = '',
    this.marginMode = '',
  });

  factory BitunixOrder.fromJson(Map<String, dynamic> json) => BitunixOrder(
        orderId: _str(json['orderId']),
        clientId: json['clientId'] == null ? null : _str(json['clientId']),
        symbol: _str(json['symbol']),
        qty: _parseDouble(json['qty']),
        tradeQty: _parseDouble(json['tradeQty']),
        price: _parseDouble(json['price']),
        side: _parseSide(json['side']),
        orderType: _str(json['orderType']),
        status: _str(json['status']),
        fee: _parseDouble(json['fee']),
        realizedPNL: _parseDouble(json['realizedPNL']),
        tpPrice: _parseDouble(json['tpPrice']),
        slPrice: _parseDouble(json['slPrice']),
        ctime: _parseInt(json['ctime']),
        mtime: _parseInt(json['mtime']),
        leverage: _parseInt(json['leverage']),
        positionMode: _str(json['positionMode']),
        marginMode: _str(json['marginMode']),
      );
}
