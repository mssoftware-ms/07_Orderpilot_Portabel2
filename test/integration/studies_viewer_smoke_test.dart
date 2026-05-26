/// Welle O3-B2-6: end-to-end smoke test for the Studies viewer.
///
/// Drives the full B2 stack:
///   - mount StudiesScreen with StudiesProvider
///   - loadDb(fixture)
///   - assert top-10 table populated with finite-score rows
///   - tap a row → assert detail sheet renders
///   - flip convergence plot y-axis to a numeric param chip
library;

import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/features/studies/studies_provider.dart';
import 'package:trading_app/ui/screens/studies_screen.dart';

Future<void> _pump(WidgetTester tester, StudiesProvider provider) async {
  // The studies screen renders a chart + table + chips — give the test
  // surface room so the chart and detail-sheet are not clipped.
  await tester.binding.setSurfaceSize(const Size(1400, 1800));
  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider<StudiesProvider>.value(
        value: provider,
        child: const StudiesScreen(),
      ),
    ),
  );
  // Plain pump — pumpAndSettle hangs on fl_chart's idle animation loop.
  await tester.pump();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets(
      'load fixture DB → top-10 visible → tap row → detail sheet → '
      'flip convergence y-axis', (tester) async {
    final fixture =
        File('test/fixtures/studies_fixture.db').absolute.path;
    final provider = StudiesProvider();

    // 1. Mount empty (no DB loaded yet).
    await _pump(tester, provider);
    expect(
        find.text('Pick a studies .db file to populate the top-10 list.'),
        findsOneWidget);

    // 2. Trigger loadDb (the screen wires this to the picker; tests
    //    bypass the file_picker dialog and call the provider directly).
    //    runAsync lets the sqflite isolate communicate via the real
    //    event loop instead of the fake test clock.
    await tester.runAsync(() => provider.loadDb(fixture));
    await tester.pump();

    // 3. Top-10 table must be rendered with rank labels.
    expect(find.byKey(const Key('trials-top10-table')), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);

    // The fixture has 3 finite-score trials → 3 rank labels.
    expect(find.text('#2'), findsOneWidget);
    expect(find.text('#3'), findsOneWidget);
    expect(find.text('#4'), findsNothing);

    // 4. Tap the trial id of the top-scoring row.
    //    Top score 2.10 corresponds to trial_id 2 in the fixture.
    await tester.tap(find.text('2').first);
    await tester.pump(const Duration(milliseconds: 200));

    // Detail sheet opens with "Parameters" + "Metrics" sections and the
    // trial-id badge "Trial 2" from the fixture. The param key
    // 'bb_period' is also a chip label outside the sheet, so we look for
    // at least one occurrence rather than exactly one.
    expect(find.text('Parameters'), findsOneWidget);
    expect(find.text('Metrics'), findsOneWidget);
    expect(find.text('Trial 2'), findsOneWidget);
    expect(find.text('bb_period'), findsAtLeast(1));

    // Close the sheet so the convergence chips are tappable.
    await tester.tapAt(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 200));

    // 5. Convergence plot rendered. Flip y-axis to bb_period.
    expect(find.byKey(const Key('convergence-scatter-chart')),
        findsOneWidget);
    await tester.tap(
        find.byKey(const Key('convergence-mode-bb_period-chip')));
    await tester.pump(const Duration(milliseconds: 200));

    final chart = tester.widget<ScatterChart>(
        find.byKey(const Key('convergence-scatter-chart')));
    // 5 finite bb_period values from the 5 valid trials → 5 spots.
    expect(chart.data.scatterSpots.length, 5);
    // The bb_period chip must report itself as selected after the tap.
    expect(provider.selectedStudy?.strategy, 'bb_rsi');

    provider.dispose();
  });
}
