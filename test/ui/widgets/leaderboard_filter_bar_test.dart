import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/features/studies/aggregate_leaderboard.dart';
import 'package:trading_app/features/studies/studies_library.dart';
import 'package:trading_app/services/library_storage.dart';
import 'package:trading_app/ui/widgets/leaderboard_filter_bar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders three controls with current values', (tester) async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: const []);
    final agg = AggregateLeaderboard(library: lib);
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: lib),
              ChangeNotifierProvider.value(value: agg),
            ],
            child: const LeaderboardFilterBar(),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('leaderboard-min-trades')), findsOneWidget);
    expect(find.byKey(const Key('leaderboard-sort')), findsOneWidget);
    expect(find.byKey(const Key('leaderboard-top-n')), findsOneWidget);
    expect(find.text('20'), findsOneWidget,
        reason: 'default min_trades label = 20');
  });

  testWidgets('sort dropdown change updates agg.sortBy + 1 recompute',
      (tester) async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: const []);
    final agg = _CountingAggregate(library: lib);
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: lib),
              ChangeNotifierProvider<AggregateLeaderboard>.value(value: agg),
            ],
            child: const LeaderboardFilterBar(),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('leaderboard-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PnL').last);
    await tester.pumpAndSettle();
    expect(agg.sortBy, 'pnl');
    expect(agg.recomputeCalls, 1,
        reason: 'a single dropdown change must trigger exactly one recompute');
  });

  testWidgets('slider drag fires recompute only on release (onChangeEnd)',
      (tester) async {
    final lib = StudiesLibrary(storage: LibraryStorage());
    await lib.boot(scanDirs: const []);
    final agg = _CountingAggregate(library: lib);
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: lib),
              ChangeNotifierProvider<AggregateLeaderboard>.value(value: agg),
            ],
            child: const LeaderboardFilterBar(),
          ),
        ),
      ),
    );
    // Drag the slider — simulate a press-drag-release gesture.
    final slider = find.byKey(const Key('leaderboard-min-trades'));
    final center = tester.getCenter(slider);
    await tester.dragFrom(center, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(agg.recomputeCalls, 1,
        reason: 'continuous drag must coalesce to a single recompute on release');
  });
}

class _CountingAggregate extends AggregateLeaderboard {
  int recomputeCalls = 0;
  _CountingAggregate({required super.library});

  @override
  Future<void> recompute() async {
    recomputeCalls++;
    notifyListeners();
  }
}
