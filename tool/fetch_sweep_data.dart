/// One-shot data-prep helper for Phase-3 Welle O2 production sweeps.
///
/// Fetches three BTCUSDT candle ranges from Binance public API via
/// `BinanceApiClient` and writes them as Rust-`Candle`-compatible JSON to
/// `01_Projectplan/optimizer_data/`. The JSON shape (`{timestamp, open,
/// high, low, close, volume}`) matches `rust/trading_engine/src/models/
/// candle.rs::Candle` exactly, so the Rust sweep examples can
/// `serde_json::from_reader` straight into `Vec<Candle>` with zero
/// transformation.
///
/// Ranges (per Welle-O2 brief):
///   BB+RSI    : BTCUSDT 4h , 2024-01-01..2024-07-01  (~1086 candles)
///   UT Bot    : BTCUSDT 5m , 2024-01-01..2024-03-08  (~19000 candles)
///   Ichimoku  : BTCUSDT 1h , 2023-04-01..2025-05-02  (~18250 candles)
///
/// Idempotent: existing JSON files are skipped (re-fetch with `--force`).
/// Output files are gitignored — they are large and regenerable.
///
/// Usage (from repo root):
///     dart run tool/fetch_sweep_data.dart
///     dart run tool/fetch_sweep_data.dart --force
library;

import 'dart:convert';
import 'dart:io';

import 'package:trading_app/services/binance_api_client.dart';

const _outputDir = '01_Projectplan/optimizer_data';
const _intervalMs1h = 60 * 60 * 1000;
const _intervalMs5m = 5 * 60 * 1000;
const _intervalMs4h = 4 * 60 * 60 * 1000;

class _Range {
  final String symbol;
  final String interval;
  final int intervalMs;
  final int startMs;
  final int endMs;
  final String label;

  const _Range({
    required this.symbol,
    required this.interval,
    required this.intervalMs,
    required this.startMs,
    required this.endMs,
    required this.label,
  });

  String get filename =>
      '${symbol}_${interval}_${_iso(startMs)}_${_iso(endMs)}.json';

  static String _iso(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }
}

const _ranges = <_Range>[
  // BB+RSI 4h: 2024-01-01 00:00 UTC -- 2024-07-01 00:00 UTC (exclusive)
  _Range(
    symbol: 'BTCUSDT',
    interval: '4h',
    intervalMs: _intervalMs4h,
    startMs: 1704067200000,
    endMs: 1719792000000,
    label: 'BB+RSI sweep (Phase-1 reference range)',
  ),
  // UT-Bot 5m: 2024-01-01 00:00 UTC -- 2024-03-08 00:00 UTC (exclusive)
  // 66 days * 288 candles/day = 19008 candles
  _Range(
    symbol: 'BTCUSDT',
    interval: '5m',
    intervalMs: _intervalMs5m,
    startMs: 1704067200000,
    endMs: 1709856000000,
    label: 'UT-Bot sweep (66-day window)',
  ),
  // Ichimoku 1h: 2023-04-01 00:00 UTC -- 2025-05-02 00:00 UTC (exclusive)
  // 762 days * 24 = 18288 candles
  _Range(
    symbol: 'BTCUSDT',
    interval: '1h',
    intervalMs: _intervalMs1h,
    startMs: 1680307200000,
    endMs: 1746144000000,
    label: 'Ichimoku sweep (2-year window)',
  ),
];

Future<List<Map<String, dynamic>>> _fetchRange(
  BinanceApiClient client,
  _Range range,
) async {
  final all = <Map<String, dynamic>>[];
  final seen = <int>{};
  var cursor = range.startMs;
  while (cursor < range.endMs) {
    final batch = await client.fetchHistoricalKlines(
      symbol: range.symbol,
      interval: range.interval,
      startTime: cursor,
      endTime: range.endMs,
      limit: 1000,
    );
    if (batch.isEmpty) break;
    for (final c in batch) {
      if (seen.add(c.timestamp)) {
        all.add(c.toJson());
      }
    }
    cursor = batch.last.timestamp + range.intervalMs;
    if (batch.length < 1000) break;
  }
  all.sort((a, b) =>
      (a['timestamp'] as int).compareTo(b['timestamp'] as int));
  return all;
}

Future<void> main(List<String> args) async {
  final force = args.contains('--force');
  final outDir = Directory(_outputDir);
  if (!await outDir.exists()) {
    await outDir.create(recursive: true);
    stdout.writeln('created $_outputDir/');
  }

  BinanceApiClient.enableLogging = true;
  final client = BinanceApiClient();
  try {
    for (final range in _ranges) {
      final path = '$_outputDir/${range.filename}';
      final file = File(path);
      if (!force && await file.exists()) {
        final size = await file.length();
        stdout.writeln('skip  $path (${size ~/ 1024} KiB, exists)');
        continue;
      }
      stdout.writeln('fetch ${range.label}');
      stdout.writeln('      ${range.symbol} ${range.interval}  '
          '${_Range._iso(range.startMs)} → ${_Range._iso(range.endMs)}');
      final stopwatch = Stopwatch()..start();
      final candles = await _fetchRange(client, range);
      stopwatch.stop();
      final json = const JsonEncoder.withIndent(null).convert(candles);
      await file.writeAsString(json);
      stdout.writeln('write $path  '
          '(${candles.length} candles, ${json.length ~/ 1024} KiB, '
          '${stopwatch.elapsed.inSeconds}s)');
    }
  } finally {
    client.dispose();
  }

  stdout.writeln('done.');
  exit(0);
}
