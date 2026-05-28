/// Welle P4C-3 — ChartScreen widget tests.
///
/// Verifies the high-level wiring of the rewritten chart tab:
/// - The ComingSoonBanner is gone.
/// - Symbol dropdown / timeframe chips drive `ChartProvider`.
/// - The connection-status pill reflects `ChartStatus`.
///
/// A fake [ChartProvider] subclass keeps the tests off the network —
/// we never call the real `load()` path, so the WS factory and the
/// REST hook stay un-invoked.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:trading_app/core/models/candle.dart';
import 'package:trading_app/features/chart/chart_provider.dart';
import 'package:trading_app/services/indicators.dart';
import 'package:trading_app/ui/screens/chart_screen.dart';

class _FakeChartProvider extends ChartProvider {
  _FakeChartProvider();

  ChartStatus _injectedStatus = ChartStatus.idle;
  List<CandleData> _injectedCandles = const [];
  BollingerBands? _injectedBb;

  String? lastSetSymbol;
  String? lastSetTimeframe;
  int loadCount = 0;

  void inject({
    ChartStatus? status,
    List<CandleData>? candles,
    BollingerBands? bb,
  }) {
    if (status != null) _injectedStatus = status;
    if (candles != null) _injectedCandles = candles;
    if (bb != null) _injectedBb = bb;
    notifyListeners();
  }

  @override
  ChartStatus get status => _injectedStatus;

  @override
  List<CandleData> get candles => _injectedCandles;

  @override
  BollingerBands? get bb => _injectedBb;

  @override
  Future<void> load({String? symbol, String? timeframe}) async {
    loadCount++;
    // Skip the REST + WS path entirely in the widget tests.
  }

  @override
  Future<void> setSymbol(String value) async {
    lastSetSymbol = value;
  }

  @override
  Future<void> setTimeframe(String value) async {
    lastSetTimeframe = value;
  }
}

Widget _host(_FakeChartProvider p) {
  return MaterialApp(
    home: ChangeNotifierProvider<ChartProvider>.value(
      value: p,
      child: const ChartScreen(),
    ),
  );
}

void main() {
  testWidgets('renders without the legacy ComingSoonBanner',
      (tester) async {
    final p = _FakeChartProvider();
    await tester.pumpWidget(_host(p));
    await tester.pump();

    // Pin the legacy banner copy to ensure the rewrite did not leak
    // the placeholder back into the tree (the widget itself has been
    // deleted in Welle P4C-5).
    expect(find.text('Live Chart — In Development'), findsNothing);
  });

  testWidgets('mount triggers a single provider load()', (tester) async {
    final p = _FakeChartProvider();
    await tester.pumpWidget(_host(p));
    await tester.pump();

    expect(p.loadCount, 1);

    // A subsequent rebuild (rebuild triggered via notifyListeners)
    // must not re-issue the initial load.
    p.inject(status: ChartStatus.live);
    await tester.pump();
    expect(p.loadCount, 1);
  });

  testWidgets('symbol dropdown change calls provider.setSymbol',
      (tester) async {
    final p = _FakeChartProvider();
    await tester.pumpWidget(_host(p));
    await tester.pump();

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    // 'ETHUSDT' is the second supported symbol (see AppConstants).
    await tester.tap(find.text('ETHUSDT').last);
    await tester.pumpAndSettle();

    expect(p.lastSetSymbol, 'ETHUSDT');
  });

  testWidgets('timeframe chip tap calls provider.setTimeframe',
      (tester) async {
    final p = _FakeChartProvider();
    await tester.pumpWidget(_host(p));
    await tester.pump();

    // '15m' is in the supported timeframes list.
    await tester.tap(find.widgetWithText(ChoiceChip, '15m'));
    await tester.pump();

    expect(p.lastSetTimeframe, '15m');
  });

  testWidgets('connection pill reflects provider.status', (tester) async {
    final p = _FakeChartProvider();
    await tester.pumpWidget(_host(p));
    await tester.pump();

    // Initial idle state.
    expect(find.text('idle'), findsOneWidget);

    p.inject(status: ChartStatus.loading);
    await tester.pump();
    expect(find.text('loading'), findsOneWidget);

    p.inject(status: ChartStatus.live);
    await tester.pump();
    expect(find.text('live'), findsOneWidget);

    p.inject(status: ChartStatus.reconnecting);
    await tester.pump();
    expect(find.text('reconnecting'), findsOneWidget);

    p.inject(status: ChartStatus.error);
    await tester.pump();
    expect(find.text('error'), findsOneWidget);
  });

  testWidgets('candle pane shows placeholder when buffer is empty',
      (tester) async {
    final p = _FakeChartProvider();
    await tester.pumpWidget(_host(p));
    await tester.pump();

    expect(find.text('No candles yet'), findsOneWidget);
  });

  testWidgets('candle pane hides placeholder when candles arrive',
      (tester) async {
    final p = _FakeChartProvider();
    await tester.pumpWidget(_host(p));
    await tester.pump();

    p.inject(
      candles: [
        for (int i = 0; i < 5; i++)
          CandleData(
            timestamp: i * 60_000,
            open: 100.0 + i,
            high: 101.0 + i,
            low: 99.0 + i,
            close: 100.5 + i,
            volume: 1,
          ),
      ],
    );
    await tester.pump();

    expect(find.text('No candles yet'), findsNothing);
  });
}
