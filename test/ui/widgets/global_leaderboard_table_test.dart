import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/models/leaderboard_row.dart';
import 'package:trading_app/core/models/trial.dart';
import 'package:trading_app/core/models/trial_metrics.dart';
import 'package:trading_app/ui/widgets/global_leaderboard_table.dart';

LeaderboardRow _row({
  required int trialId,
  required String strategy,
  required double pnl,
  required double score,
}) =>
    LeaderboardRow(
      trial: Trial(
        id: trialId,
        studyId: 1,
        trialId: trialId,
        params: const {'x': 0.5},
        metrics: TrialMetrics(
          totalTrades: 30,
          totalPnl: pnl,
          winRate: 50.0,
          sharpeRatio: 1.0,
          maxDrawdownPct: 5.0,
          profitFactor: 1.5,
          finalEquity: 1000 + pnl,
        ),
        score: score,
        createdAt: DateTime.utc(2026, 6, 4),
      ),
      strategy: strategy,
      studyName: '${strategy}_study',
      studyDbId: 1,
      dbPath: '/x/$strategy.db',
    );

void main() {
  testWidgets('renders rows and empty hint when empty', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: GlobalLeaderboardTable(rows: const [])),
    ));
    expect(find.text('No profitable trials yet — pin some DBs above.'),
        findsOneWidget);
  });

  testWidgets('renders one row per LeaderboardRow', (tester) async {
    final rows = [
      _row(trialId: 1, strategy: 'ichimoku', pnl: 200, score: 2.1),
      _row(trialId: 2, strategy: 'bb_rsi', pnl: 100, score: 1.5),
    ];
    await tester.binding.setSurfaceSize(const Size(1600, 600));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: GlobalLeaderboardTable(rows: rows)),
    ));
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
    expect(find.text('ichimoku'), findsOneWidget);
    expect(find.text('bb_rsi'), findsOneWidget);
  });

  testWidgets('tap on row opens detail sheet', (tester) async {
    final rows = [
      _row(trialId: 7, strategy: 'ichimoku', pnl: 200, score: 2.1),
    ];
    await tester.binding.setSurfaceSize(const Size(1600, 800));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: GlobalLeaderboardTable(rows: rows)),
    ));
    await tester.tap(find.text('7'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Trial 7'), findsOneWidget);
    expect(find.text('Parameters'), findsOneWidget);
    // The study name also appears in the table's Study column behind the
    // modal sheet, so scope the assertion to the sheet subtree to prove
    // the detail sheet itself surfaces the originating study name.
    expect(
        find.descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.text('ichimoku_study'),
        ),
        findsOneWidget,
        reason: 'detail sheet shows the originating study name');
  });
}
