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
///
/// The pane is intentionally non-interactive — Phase-5 will land
/// pan/zoom + crosshair if the UX demands them. For Welle P4C-3 the
/// chart is a read-only visualisation driven by `ChartProvider`.
library;

import 'package:flutter/material.dart';

import '../../core/models/candle.dart';
import '../../services/indicators.dart';
import '../themes/app_theme.dart';

/// Candlestick + BB overlay pane.
///
/// Empty-state safe: when [candles] is empty (loading / error) the
/// pane shows a placeholder so the widget tree never has to swap
/// between fundamentally different layouts.
class CandlestickChartPane extends StatelessWidget {
  final List<CandleData> candles;
  final BollingerBands? bb;

  const CandlestickChartPane({
    super.key,
    required this.candles,
    this.bb,
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
      painter: _CandlestickPainter(candles: candles, bb: bb),
      size: Size.infinite,
    );
  }
}

class _CandlestickPainter extends CustomPainter {
  final List<CandleData> candles;
  final BollingerBands? bb;

  _CandlestickPainter({required this.candles, this.bb});

  @override
  void paint(Canvas canvas, Size size) {
    final n = candles.length;
    if (n == 0 || size.width <= 0 || size.height <= 0) return;

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

    double xForBar(int i) => (i + 0.5) * (size.width / n);
    double yForPrice(double p) =>
        size.height - ((p - minY) / yRange) * size.height;

    // ── Candle width: 60 % of the slot, capped so a 500-candle view
    // still leaves a visible gap between adjacent bars.
    final slot = size.width / n;
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
      final h = (bot - top).clamp(1.0, size.height);
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
    return oldDelegate.candles != candles || oldDelegate.bb != bb;
  }
}
