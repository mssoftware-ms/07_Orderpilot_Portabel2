/// Widget tests for the Welle O3-B3-3 ApplyTrialDialog.
library;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/features/studies/studies_provider.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/ui/widgets/apply_trial_dialog.dart';

Future<void> _pumpDialog(
  WidgetTester tester, {
  required StrategyKind targetKind,
  required BacktestProvider backtest,
  StudiesProvider? studies,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              key: const Key('open_dialog'),
              onPressed: () => showApplyTrialDialog(
                ctx,
                targetKind: targetKind,
                backtestProvider: backtest,
                studiesProvider: studies,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open_dialog')));
  await tester.pump();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final fixturePath =
      File('test/fixtures/studies_fixture.db').absolute.path;

  group('ApplyTrialDialog empty state', () {
    testWidgets('renders empty state with picker button', (tester) async {
      final backtest = BacktestProvider();
      await _pumpDialog(tester,
          targetKind: StrategyKind.bbRsi, backtest: backtest);
      expect(find.byKey(const Key('apply_trial_dialog_pick_db')),
          findsOneWidget);
      expect(
          find.text('Load an optimizer studies .db to see its trials.'),
          findsOneWidget);
      expect(find.byKey(const Key('apply_trial_dialog_apply')),
          findsOneWidget);
    });

    testWidgets('Apply button disabled until a trial is selected',
        (tester) async {
      final backtest = BacktestProvider();
      await _pumpDialog(tester,
          targetKind: StrategyKind.bbRsi, backtest: backtest);
      final apply = tester.widget<ElevatedButton>(
          find.byKey(const Key('apply_trial_dialog_apply')));
      expect(apply.onPressed, isNull);
    });
  });

  group('ApplyTrialDialog loaded state', () {
    testWidgets('top-10 table renders after loadDb fixture', (tester) async {
      final backtest = BacktestProvider();
      final studies = StudiesProvider();
      await tester.runAsync(() => studies.loadDb(fixturePath));
      await _pumpDialog(tester,
          targetKind: StrategyKind.bbRsi,
          backtest: backtest,
          studies: studies);
      expect(find.byKey(const Key('trials-top10-table')), findsOneWidget);
      expect(find.byKey(const Key('apply_trial_dialog_trial_dropdown')),
          findsOneWidget);
    });

    testWidgets('apply button calls applyTrialAsParams on backtest provider',
        (tester) async {
      final backtest = BacktestProvider();
      final studies = StudiesProvider();
      await tester.runAsync(() => studies.loadDb(fixturePath));
      await _pumpDialog(tester,
          targetKind: StrategyKind.bbRsi,
          backtest: backtest,
          studies: studies);

      // Sanity: a finite-score trial is auto-selected.
      final bestFinite = studies.top10
          .where((t) => t.scoreIsFinite)
          .toList()
          .first;

      await tester.tap(find.byKey(const Key('apply_trial_dialog_apply')));
      await tester.pumpAndSettle();

      expect(backtest.usingOptimizedParams, isTrue);
      expect(backtest.config.strategyKind, StrategyKind.bbRsi);
      // The applied bb_period from the selected trial.
      final bp = backtest.config.strategyParams as BbRsiParams;
      final expectedBb = bestFinite.params['bb_period']?.toInt();
      if (expectedBb != null) {
        expect(bp.bbPeriod, expectedBb);
      }
      // Dialog should be dismissed.
      expect(find.byKey(const Key('apply_trial_dialog_apply')),
          findsNothing);
    });

    testWidgets('strategy mismatch surfaces warning banner', (tester) async {
      final backtest = BacktestProvider();
      final studies = StudiesProvider();
      await tester.runAsync(() => studies.loadDb(fixturePath));
      // Open with UT-Bot as target — fixture study is 'bb_rsi' → mismatch.
      await _pumpDialog(tester,
          targetKind: StrategyKind.utBot,
          backtest: backtest,
          studies: studies);
      expect(
        find.textContaining('but you are applying it to UT Bot'),
        findsOneWidget,
      );
    });

    testWidgets('cancel closes dialog without touching backtest provider',
        (tester) async {
      final backtest = BacktestProvider();
      final studies = StudiesProvider();
      await tester.runAsync(() => studies.loadDb(fixturePath));
      await _pumpDialog(tester,
          targetKind: StrategyKind.bbRsi,
          backtest: backtest,
          studies: studies);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backtest.usingOptimizedParams, isFalse);
      expect(find.byKey(const Key('apply_trial_dialog_apply')),
          findsNothing);
    });
  });
}
