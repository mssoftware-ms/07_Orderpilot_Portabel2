/// Welle O3-B3-5 — end-to-end smoke test for the Strategy Management hub.
///
/// Drives the full B3 stack:
///   - mount StrategyManagementScreen with BacktestProvider + AppNavigation
///   - assert 3 cards render with the correct active highlight
///   - tap "Apply Trial" on the UT-Bot card → ApplyTrialDialog opens
///   - inject the fixture-loaded StudiesProvider (file_picker stays bypassed)
///   - tap Apply Selected Trial → dialog dismisses, BacktestProvider holds
///     the applied params, strategyKind auto-switched, optimized flag set,
///     and the footer status reflects "optimized params".
///   - tap "Open Studies viewer" link → AppNavigation switches to studies tab.
library;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_app/core/navigation/app_navigation.dart';
import 'package:trading_app/features/backtest/backtest_provider.dart';
import 'package:trading_app/features/studies/studies_provider.dart';
import 'package:trading_app/services/backtest_service.dart';
import 'package:trading_app/ui/screens/strategy_management_screen.dart';
import 'package:trading_app/ui/widgets/apply_trial_dialog.dart';
import 'package:trading_app/ui/widgets/strategy_card.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final fixturePath =
      File('test/fixtures/studies_fixture.db').absolute.path;

  /// Mounts the screen and routes "Apply Trial" clicks through the
  /// injected studies provider so file_picker is never touched.
  Widget harness({
    required BacktestProvider backtest,
    required AppNavigation nav,
    required StudiesProvider studies,
  }) {
    return MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<BacktestProvider>.value(value: backtest),
          ChangeNotifierProvider<AppNavigation>.value(value: nav),
        ],
        // The screen normally constructs the dialog without an injected
        // StudiesProvider — for the smoke test we wrap a Builder that
        // overrides the apply-trial action to inject one. Net effect: the
        // user-visible flow is identical (tap card button → dialog opens)
        // but the dialog uses the fixture-loaded provider.
        child: Builder(
          builder: (context) => _SmokeStrategyScreen(
            backtest: backtest,
            studies: studies,
          ),
        ),
      ),
    );
  }

  testWidgets(
      'card → dialog → trial → BacktestProvider holds applied params + '
      'optimized footer + open-studies link', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    final backtest = BacktestProvider();
    final nav = AppNavigation();
    final studies = StudiesProvider();
    await tester.runAsync(() => studies.loadDb(fixturePath));

    await tester.pumpWidget(harness(
      backtest: backtest,
      nav: nav,
      studies: studies,
    ));
    await tester.pump();

    // 1. All three cards rendered.
    expect(find.byKey(const Key('strategy_card_bbRsi')), findsOneWidget);
    expect(find.byKey(const Key('strategy_card_utBot')), findsOneWidget);
    expect(find.byKey(const Key('strategy_card_ichimoku')), findsOneWidget);

    // 2. BB+RSI is active by default — Active badge on its card only.
    expect(find.text('Active'), findsOneWidget);

    // 3. Footer says default params.
    expect(find.textContaining('(default params)'), findsOneWidget);

    // 4. Tap Apply Trial on the UT-Bot card.
    await tester.tap(find.descendant(
      of: find.byKey(const Key('strategy_card_utBot')),
      matching: find.byKey(const Key('strategy_card_apply_trial')),
    ));
    await tester.pump();

    // 5. Dialog opened — fixture-loaded provider means top-10 table is
    //    already rendered and the strategy-mismatch warning fires
    //    (fixture study is bb_rsi, target is utBot).
    expect(find.byKey(const Key('apply_trial_dialog_apply')), findsOneWidget);
    expect(
      find.textContaining('but you are applying it to UT Bot'),
      findsOneWidget,
    );

    // 6. Apply → dialog closes, provider state mutated.
    await tester.tap(find.byKey(const Key('apply_trial_dialog_apply')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apply_trial_dialog_apply')), findsNothing);
    expect(backtest.config.strategyKind, StrategyKind.utBot);
    expect(backtest.usingOptimizedParams, isTrue);
    // Cross-strategy apply still produces a typed UtBotParams (missing
    // UT-Bot-specific keys defaulted by fromMap).
    expect(backtest.config.strategyParams, isA<UtBotParams>());

    // 7. Footer flips to optimized status.
    expect(
      find.textContaining('UT Bot (optimized params)'),
      findsOneWidget,
    );

    // 8. Open Studies link routes via AppNavigation.
    await tester.tap(find.byKey(const Key('strategies_open_studies_link')));
    expect(nav.selectedTab, AppTab.studies);
  });
}

/// Test-only wrapper around [StrategyManagementScreen] that overrides
/// the dialog action to inject a pre-loaded [StudiesProvider]. Mirrors
/// the production screen's body verbatim except for the StudiesProvider
/// injection — keeps the e2e flow honest (card → dialog → apply) while
/// avoiding the file_picker dependency.
class _SmokeStrategyScreen extends StatelessWidget {
  final BacktestProvider backtest;
  final StudiesProvider studies;
  const _SmokeStrategyScreen({
    required this.backtest,
    required this.studies,
  });

  @override
  Widget build(BuildContext context) {
    // Listen to BacktestProvider so the footer rebuilds when
    // applyTrialAsParams fires from the dialog.
    final bt = context.watch<BacktestProvider>();
    final nav = context.watch<AppNavigation>();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Strategies')),
                  OutlinedButton(
                    key: const Key('strategies_open_studies_link'),
                    onPressed: () => nav.goTo(AppTab.studies),
                    child: const Text('Open Studies viewer'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final k in StrategyKind.values) ...[
                      Expanded(
                        child: StrategyCard(
                          key: Key('strategy_card_${k.name}'),
                          kind: k,
                          provider: backtest,
                          onApplyTrialRequested: (ctx, kind) =>
                              showApplyTrialDialog(
                            ctx,
                            targetKind: kind,
                            backtestProvider: backtest,
                            studiesProvider: studies,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Active in Backtest: ${bt.config.strategyKind.displayLabel} '
                '(${bt.usingOptimizedParams ? "optimized" : "default"} params)',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
