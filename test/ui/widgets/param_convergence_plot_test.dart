/// Widget tests for the Welle O3-B2-5 ParamConvergencePlot.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/trial.dart';
import 'package:trading_app/core/models/trial_metrics.dart';
import 'package:trading_app/ui/widgets/param_convergence_plot.dart';

const _yaml = '''
strategy_name: bb_rsi
parameters:
  bb_period:
    type: Int
    min: 100
    max: 300
  bb_stddev:
    type: Float
    min: 0.2
    max: 1.0
''';

Trial _t(int id, double score, {double bbPeriod = 200.0,
    double bbStddev = 0.5}) =>
    Trial(
      id: id + 1,
      studyId: 1,
      trialId: id,
      params: {'bb_period': bbPeriod, 'bb_stddev': bbStddev},
      metrics: const TrialMetrics(
        totalTrades: 4,
        totalPnl: 100.0,
        winRate: 50.0,
        sharpeRatio: 1.0,
        maxDrawdownPct: 2.0,
        profitFactor: 1.5,
        finalEquity: 10100.0,
      ),
      score: score,
      createdAt: DateTime.utc(2026, 5, 26),
    );

Future<void> _pump(WidgetTester tester, List<Trial> trials,
    {String yaml = _yaml}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 800));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ParamConvergencePlot(
          trials: trials,
          searchSpaceYaml: yaml,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders without crash on -inf scores', (tester) async {
    final trials = [
      _t(0, double.negativeInfinity),
      _t(1, 1.5),
      _t(2, double.negativeInfinity),
      _t(3, 2.0),
      _t(4, 0.5),
    ];
    await _pump(tester, trials);
    expect(find.byKey(const Key('convergence-scatter-chart')),
        findsOneWidget);
  });

  testWidgets('empty trial list renders the no-trials hint',
      (tester) async {
    await _pump(tester, const []);
    expect(find.text('No trials to plot yet.'), findsOneWidget);
    expect(find.byKey(const Key('convergence-scatter-chart')), findsNothing);
  });

  testWidgets(
      'switching y-axis to a numeric param swaps the chart datasource',
      (tester) async {
    final trials = [
      _t(0, 1.0, bbPeriod: 100),
      _t(1, 1.5, bbPeriod: 200),
      _t(2, 2.0, bbPeriod: 300),
    ];
    await _pump(tester, trials);

    // The score chip is selected by default.
    final scoreChip = tester
        .widget<ChoiceChip>(find.byKey(const Key('convergence-mode-score-chip')));
    expect(scoreChip.selected, isTrue);

    // Tap the bb_period chip.
    await tester.tap(
        find.byKey(const Key('convergence-mode-bb_period-chip')));
    await tester.pumpAndSettle();

    final scoreChipAfter = tester
        .widget<ChoiceChip>(find.byKey(const Key('convergence-mode-score-chip')));
    expect(scoreChipAfter.selected, isFalse);

    // The ScatterChart should have re-rendered with new spots.
    final chart = tester.widget<ScatterChart>(
        find.byKey(const Key('convergence-scatter-chart')));
    final spots = chart.data.scatterSpots;
    // 3 trials, all finite bb_period → 3 spots.
    expect(spots.length, 3);
    // y-coords must equal the bb_period values (100, 200, 300).
    final ys = spots.map((s) => s.y).toSet();
    expect(ys, {100.0, 200.0, 300.0});
  });

  testWidgets('only numeric params surface as chips (Bool excluded)',
      (tester) async {
    const yamlWithBool = '''
parameters:
  bb_period:
    type: Int
    min: 100
    max: 300
  use_di:
    type: Bool
''';
    final trials = [_t(0, 1.0)];
    await _pump(tester, trials, yaml: yamlWithBool);

    expect(find.byKey(const Key('convergence-mode-bb_period-chip')),
        findsOneWidget);
    // Bool param must NOT have a chip (no y-axis numeric range).
    expect(find.byKey(const Key('convergence-mode-use_di-chip')),
        findsNothing);
  });
}
