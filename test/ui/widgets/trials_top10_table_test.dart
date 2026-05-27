/// Widget tests for the Welle O3-B2-4 TrialsTop10Table.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/trial.dart';
import 'package:trading_app/core/models/trial_metrics.dart';
import 'package:trading_app/ui/widgets/trials_top10_table.dart';

Trial _trial({
  required int id,
  required int trialId,
  required double score,
  int totalTrades = 5,
  double totalPnl = 100.0,
  double winRate = 60.0,
  double sharpe = 1.5,
  double maxDd = 3.0,
  double profitFactor = 2.0,
  Map<String, double> params = const {'bb_period': 200.0, 'bb_stddev': 0.5},
}) {
  return Trial(
    id: id,
    studyId: 1,
    trialId: trialId,
    params: params,
    metrics: TrialMetrics(
      totalTrades: totalTrades,
      totalPnl: totalPnl,
      winRate: winRate,
      sharpeRatio: sharpe,
      maxDrawdownPct: maxDd,
      profitFactor: profitFactor,
      finalEquity: 10000.0 + totalPnl,
    ),
    score: score,
    createdAt: DateTime.utc(2026, 5, 26),
  );
}

Future<void> _pump(WidgetTester tester, List<Trial> trials) async {
  await tester.binding.setSurfaceSize(const Size(1400, 800));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TrialsTop10Table(trials: trials),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders 10 trial rows', (tester) async {
    final trials = List.generate(10, (i) =>
        _trial(id: i + 1, trialId: i, score: 2.0 - i * 0.1));
    await _pump(tester, trials);

    expect(find.byKey(const Key('trials-top10-table')), findsOneWidget);
    // 10 rank labels (#1..#10) — one per visible row.
    for (int i = 1; i <= 10; i++) {
      expect(find.text('#$i'), findsOneWidget,
          reason: 'expected rank label #$i for one of the 10 rows');
    }
  });

  testWidgets('renders empty hint when no trials', (tester) async {
    await _pump(tester, const []);
    expect(find.text('No trials in this study yet.'), findsOneWidget);
  });

  testWidgets('default sort is by score descending (best first)',
      (tester) async {
    final trials = [
      _trial(id: 1, trialId: 0, score: 0.5),
      _trial(id: 2, trialId: 1, score: 2.0),
      _trial(id: 3, trialId: 2, score: 1.0),
    ];
    await _pump(tester, trials);

    // The score column shows 3-decimal strings, and the highest-score row
    // (2.0 / "2.000") must precede the others. We assert that the global
    // top-down ordering on screen reflects DESC sort by score.
    final score20 = tester.getCenter(find.text('2.000'));
    final score10 = tester.getCenter(find.text('1.000'));
    final score05 = tester.getCenter(find.text('0.500'));
    expect(score20.dy, lessThan(score10.dy));
    expect(score10.dy, lessThan(score05.dy));
  });

  testWidgets('tap on a row opens the detail sheet with params',
      (tester) async {
    final trials = [
      _trial(
        id: 1,
        trialId: 42,
        score: 1.5,
        params: const {'bb_period': 250.0, 'rsi_oversold': 25.0},
      ),
    ];
    await _pump(tester, trials);

    // The Trial column shows "42" — tap that cell to fire onSelectChanged.
    await tester.tap(find.text('42'));
    await tester.pumpAndSettle();

    expect(find.text('Trial 42'), findsOneWidget);
    expect(find.text('Parameters'), findsOneWidget);
    expect(find.text('bb_period'), findsOneWidget);
    expect(find.text('rsi_oversold'), findsOneWidget);
    expect(find.text('Metrics'), findsOneWidget);
  });

  testWidgets('non-finite score renders greyed-out with no-trades suffix',
      (tester) async {
    final trials = [
      _trial(id: 1, trialId: 0, score: double.negativeInfinity),
    ];
    await _pump(tester, trials);

    expect(find.text('— (no trades)'), findsOneWidget);
  });

  // ─── Welle O3-B2.1-2 — draggable detail sheet ─────────────────────────────
  //
  // Windows smoke-test surfaced that the previous fixed-height sheet
  // (50% of screen, no drag) hid params/metrics under the OS taskbar.
  // The sheet now wraps a DraggableScrollableSheet so the user can pull
  // it up to 95% of screen height, with a visible drag-handle affordance
  // and a SafeArea-aware modal envelope.
  group('Trial detail sheet — draggable (Welle O3-B2.1-2)', () {
    Future<void> tapAndOpenSheet(WidgetTester tester) async {
      final trials = [
        _trial(
          id: 1,
          trialId: 42,
          score: 1.5,
          params: const {'bb_period': 250.0, 'rsi_oversold': 25.0},
        ),
      ];
      await _pump(tester, trials);
      await tester.tap(find.text('42'));
      await tester.pumpAndSettle();
    }

    testWidgets('tap on row renders a DraggableScrollableSheet',
        (tester) async {
      await tapAndOpenSheet(tester);
      expect(find.byType(DraggableScrollableSheet), findsOneWidget,
          reason:
              'detail sheet must wrap its content in a DraggableScrollableSheet '
              'so the user can pull it up past the taskbar');
    });

    testWidgets('drag handle is visible at top of sheet', (tester) async {
      await tapAndOpenSheet(tester);
      expect(find.byKey(const Key('trial-detail-drag-handle')),
          findsOneWidget);
    });

    testWidgets('dragging the handle upward expands the sheet '
        '(scrollController threading wired)', (tester) async {
      await tapAndOpenSheet(tester);

      // Baseline: top edge of the sheet content. The drag handle sits
      // at the very top of the sheet, so its dy doubles as a proxy for
      // the sheet's top edge.
      final handle = find.byKey(const Key('trial-detail-drag-handle'));
      final topBefore = tester.getTopLeft(handle).dy;

      // Drag the handle upward. With the DSS scrollController threaded
      // into the inner ListView, this must grow the sheet (top moves up,
      // dy decreases). Without threading, the gesture would be eaten by
      // the ListView's own scroll and the sheet would not resize.
      await tester.drag(handle, const Offset(0, -200));
      await tester.pumpAndSettle();

      final topAfter = tester.getTopLeft(handle).dy;
      expect(topAfter, lessThan(topBefore),
          reason:
              'sheet top must move up after dragging handle up — '
              'verifies DraggableScrollableSheet is actually wired '
              'to the inner scrollable via scrollController threading');
    });
  });
}
