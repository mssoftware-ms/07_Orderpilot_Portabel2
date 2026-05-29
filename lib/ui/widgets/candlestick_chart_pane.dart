/// Welle P4C-3 candlestick + Bollinger-Bands renderer.
///
/// A self-contained [CustomPaint]-based chart pane: the project's
/// pubspec ships `candlesticks: ^2.1.0`, but that package only exposes
/// a top-toolbar API and no per-bar indicator overlay hook. Rather
/// than upgrade the dependency or replace it with `fl_chart` (which
/// has no candlestick series in 0.70.x), the chart tab now owns a
/// minimal pure-Flutter renderer:
///
/// - Candle bodies + wicks scaled to the (min low … max high) range of
///   the supplied window.
/// - Three Bollinger Bands lines overlaid in screen-space using the
///   same scale.
/// - A right-hand price axis and a bottom time axis (Welle P4C-H-3):
///   Maik's smoke surfaced that the chart showed neither price (y) nor
///   time (x), so the plot area is now inset to make room for labels.
///
/// The pane is intentionally non-interactive — Phase-5 will land
/// pan/zoom + crosshair if the UX demands them. For Welle P4C-3 the
/// chart is a read-only visualisation driven by `ChartProvider`.
library;

import 'package:flutter/material.dart';
// `intl` also exports a (Bidi) `TextDirection`; hide it so the
// dart:ui/material `TextDirection.ltr` used by the label painter wins.
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/models/candle.dart';
import '../../services/indicators.dart';
import '../themes/app_theme.dart';

/// Width reserved on the right edge for the price-axis labels.
const double kChartRightAxisWidth = 58.0;

/// Height reserved at the bottom for the time-axis labels.
const double kChartBottomAxisHeight = 16.0;

/// Price labels drawn on the right axis (within the 5–7 spec).
const int kChartPriceLabelCount = 6;

/// Time labels drawn on the bottom axis (within the 4–6 spec).
const int kChartTimeLabelCount = 5;

/// Font size for both axis label rows. Small enough that five time
/// labels never collide across a phone-width pane.
const double kChartAxisFontSize = 9.0;

/// Candlestick + BB overlay pane.
///
/// Empty-state safe: when [candles] is empty (loading / error) the
/// pane shows a placeholder so the widget tree never has to swap
/// between fundamentally different layouts.
class CandlestickChartPane extends StatelessWidget {
  final List<CandleData> candles;
  final BollingerBands? bb;

  /// Active timeframe label (e.g. `'1m'`, `'1h'`, `'1d'`). Drives the
  /// time-axis label format only — the candle geometry is timeframe
  /// agnostic.
  final String timeframe;

  const CandlestickChartPane({
    super.key,
    required this.candles,
    this.bb,
    this.timeframe = '1h',
  });

  @override
  Widget build(BuildContext context) {
    if (candles.isEmpty) {
      return const Center(
        child: Text(
          'No candles yet',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      );
    }
    return CustomPaint(
      painter: _CandlestickPainter(
        candles: candles,
        bb: bb,
        timeframe: timeframe,
      ),
      size: Size.infinite,
    );
  }
}

// ─── Pure axis helpers (unit-tested via candlestick_chart_pane_test) ──────

/// Evenly spaced price tick values spanning `[minY, maxY]` inclusive.
/// Returns a single value for a degenerate range so callers can still
/// render one label without dividing by zero.
List<double> chartPriceTicks(
  double minY,
  double maxY, {
  int count = kChartPriceLabelCount,
}) {
  if (count < 2 || maxY <= minY) return [minY];
  final step = (maxY - minY) / (count - 1);
  return [for (int i = 0; i < count; i++) minY + step * i];
}

/// Decimal places for an axis price label, derived from the tick step
/// so adjacent labels stay distinguishable (BTC at 60k → 0 decimals,
/// a sub-cent alt → 6) without trailing noise.
int chartPriceDecimals(double step) {
  final s = step.abs();
  if (s >= 100) return 0;
  if (s >= 1) return 2;
  if (s >= 0.01) return 4;
  return 6;
}

/// Format a price for an axis label at the given precision.
String chartFormatPrice(double price, int decimals) =>
    price.toStringAsFixed(decimals);

/// Candle indices to label on the time axis — evenly spaced with the
/// first and last always included, de-duplicated for short windows.
List<int> chartTimeTickIndices(int n, {int count = kChartTimeLabelCount}) {
  if (n <= 0) return const [];
  if (n <= count) return [for (int i = 0; i < n; i++) i];
  final out = <int>{};
  for (int i = 0; i < count; i++) {
    out.add(((n - 1) * i / (count - 1)).round());
  }
  return out.toList()..sort();
}

/// `DateFormat` pattern bucket per timeframe. Intraday minutes show the
/// wall-clock only; hourly buckets add the date with a pinned `:00`
/// minute; daily+ drop the time entirely.
String chartTimeLabelPattern(String timeframe) {
  switch (timeframe) {
    case '1s':
    case '1m':
    case '3m':
    case '5m':
    case '15m':
    case '30m':
      return 'HH:mm';
    case '1h':
    case '2h':
    case '4h':
    case '6h':
    case '8h':
    case '12h':
      return 'MM-dd HH:00';
    case '1d':
    case '3d':
    case '1w':
    case '1M':
      return 'yyyy-MM-dd';
    default:
      return 'MM-dd HH:mm';
  }
}

/// Format a candle open time (kept in UTC, matching the rest of the
/// app) for the bottom time axis.
String chartFormatTime(DateTime time, String timeframe) =>
    DateFormat(chartTimeLabelPattern(timeframe)).format(time);

class _CandlestickPainter extends CustomPainter {
  final List<CandleData> candles;
  final BollingerBands? bb;
  final String timeframe;

  _CandlestickPainter({
    required this.candles,
    this.bb,
    required this.timeframe,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = candles.length;
    if (n == 0 || size.width <= 0 || size.height <= 0) return;

    // ── Inset the plot area so the axes have room. Bail out if the
    // pane is too small to host both the chart and its labels.
    final plotW = size.width - kChartRightAxisWidth;
    final plotH = size.height - kChartBottomAxisHeight;
    if (plotW <= 0 || plotH <= 0) return;

    // ── Y-range across candles + BB so the bands are guaranteed to
    // fit inside the canvas (otherwise the upper band can clip off
    // the top when prices push close to it).
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final c in candles) {
      if (c.low < minY) minY = c.low;
      if (c.high > maxY) maxY = c.high;
    }
    final localBb = bb;
    if (localBb != null) {
      // Skip warm-up zeros: any band value at 0.0 is the warm-up init
      // used by `calcBollingerBands`. Including those collapses the
      // Y-range to [0 .. price] which makes the candles invisible.
      for (int i = 0; i < n; i++) {
        final u = localBb.upper[i];
        final l = localBb.lower[i];
        if (u > 0 && u > maxY) maxY = u;
        if (l > 0 && l < minY) minY = l;
      }
    }
    if (minY == maxY) {
      // Degenerate input — a flat series. Add a 1 % padding so the
      // candle bodies don't collapse to zero height.
      minY -= 1;
      maxY += 1;
    }
    final yRange = maxY - minY;

    double xForBar(int i) => (i + 0.5) * (plotW / n);
    double yForPrice(double p) => plotH - ((p - minY) / yRange) * plotH;

    // ── Price axis first so its gridlines sit behind the candles.
    _drawPriceAxis(canvas, minY, maxY, yForPrice, plotW);

    // ── Candle width: 60 % of the slot, capped so a 500-candle view
    // still leaves a visible gap between adjacent bars.
    final slot = plotW / n;
    final bodyW = (slot * 0.6).clamp(1.0, 12.0).toDouble();
    final wickPaint = Paint()
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final bullPaint = Paint()..color = AppColors.bullGreen;
    final bearPaint = Paint()..color = AppColors.bearRed;

    for (int i = 0; i < n; i++) {
      final c = candles[i];
      final x = xForBar(i);
      final isBull = c.close >= c.open;
      final body = isBull ? bullPaint : bearPaint;
      wickPaint.color = body.color;
      // Wick: high → low line through the centre.
      canvas.drawLine(
        Offset(x, yForPrice(c.high)),
        Offset(x, yForPrice(c.low)),
        wickPaint,
      );
      // Body: open ↔ close rect.
      final yOpen = yForPrice(c.open);
      final yClose = yForPrice(c.close);
      final top = yOpen < yClose ? yOpen : yClose;
      final bot = yOpen < yClose ? yClose : yOpen;
      // Doji safety: a candle with open==close would render as a
      // zero-height rect (invisible). Pin a 1 px minimum so the
      // viewer can still see the bar exists.
      final h = (bot - top).clamp(1.0, plotH);
      final rect = Rect.fromLTWH(x - bodyW / 2, top, bodyW, h);
      canvas.drawRect(rect, body);
    }

    // ── BB overlay. Each band is a polyline across the valid range.
    if (localBb != null) {
      _drawBand(canvas, localBb.upper, xForBar, yForPrice,
          AppColors.accentCyan.withAlpha(180));
      _drawBand(canvas, localBb.middle, xForBar, yForPrice,
          AppColors.textMuted.withAlpha(180));
      _drawBand(canvas, localBb.lower, xForBar, yForPrice,
          AppColors.accentCyan.withAlpha(180));
    }

    // ── Time axis on top of everything so labels are never occluded.
    _drawTimeAxis(canvas, n, xForBar, plotW, plotH);
  }

  /// Lay out a single axis label string with the shared muted style.
  TextPainter _label(String text) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: kChartAxisFontSize,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _drawPriceAxis(
    Canvas canvas,
    double minY,
    double maxY,
    double Function(double) yForPrice,
    double plotW,
  ) {
    final ticks = chartPriceTicks(minY, maxY);
    final step = ticks.length > 1 ? (ticks[1] - ticks[0]) : (maxY - minY);
    final decimals = chartPriceDecimals(step);
    final gridPaint = Paint()
      ..color = AppColors.border.withAlpha(60)
      ..strokeWidth = 0.5;
    final plotH = yForPrice(minY);
    for (final price in ticks) {
      final y = yForPrice(price);
      canvas.drawLine(Offset(0, y), Offset(plotW, y), gridPaint);
      final tp = _label(chartFormatPrice(price, decimals));
      // Vertically centre on the tick, but keep the top/bottom labels
      // fully inside the pane.
      final ty = (y - tp.height / 2).clamp(0.0, plotH - tp.height);
      tp.paint(canvas, Offset(plotW + 4, ty));
    }
  }

  void _drawTimeAxis(
    Canvas canvas,
    int n,
    double Function(int) xForBar,
    double plotW,
    double plotH,
  ) {
    for (final i in chartTimeTickIndices(n)) {
      final tp = _label(chartFormatTime(candles[i].dateTime, timeframe));
      // Centre under the bar, clamped so the edge labels stay readable.
      final tx = (xForBar(i) - tp.width / 2).clamp(0.0, plotW - tp.width);
      tp.paint(canvas, Offset(tx, plotH + 2));
    }
  }

  void _drawBand(
    Canvas canvas,
    List<double> series,
    double Function(int) xForBar,
    double Function(double) yForPrice,
    Color color,
  ) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final path = Path();
    var started = false;
    for (int i = 0; i < series.length; i++) {
      final v = series[i];
      // Skip warm-up: `calcBollingerBands` leaves indices before
      // `period - 1` at 0.0 (matches the legacy engine
      // initialisation). Treating those as real points would draw a
      // diagonal from the origin into the chart.
      if (v == 0) {
        started = false;
        continue;
      }
      final p = Offset(xForBar(i), yForPrice(v));
      if (!started) {
        path.moveTo(p.dx, p.dy);
        started = true;
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CandlestickPainter oldDelegate) {
    return oldDelegate.candles != candles ||
        oldDelegate.bb != bb ||
        oldDelegate.timeframe != timeframe;
  }
}
