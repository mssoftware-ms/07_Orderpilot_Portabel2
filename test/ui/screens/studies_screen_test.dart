/// Widget tests for the Welle O3-B2-3 Studies screen skeleton.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:trading_app/features/studies/studies_provider.dart';
import 'package:trading_app/ui/screens/studies_screen.dart';

Future<void> _pump(WidgetTester tester, StudiesProvider provider) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider<StudiesProvider>.value(
        value: provider,
        child: const StudiesScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeStudiesProvider extends StudiesProvider {
  String? _fakeError;
  bool _fakeLoading = false;
  String? _fakeDbPath;

  void setError(String? msg) {
    _fakeError = msg;
    notifyListeners();
  }

  void setLoading(bool v) {
    _fakeLoading = v;
    notifyListeners();
  }

  void setDbPath(String? path) {
    _fakeDbPath = path;
    notifyListeners();
  }

  @override
  String? get errorMessage => _fakeError ?? super.errorMessage;

  @override
  bool get isLoading => _fakeLoading || super.isLoading;

  @override
  String? get dbPath => _fakeDbPath ?? super.dbPath;
}

void main() {
  testWidgets('Empty-state: no DB loaded shows pick-a-db hints',
      (tester) async {
    final p = StudiesProvider();
    await _pump(tester, p);

    expect(find.text('Studies'), findsOneWidget); // AppBar title
    expect(find.text('Optimizer studies database'), findsOneWidget);
    expect(
        find.text(
            'Pick a studies .db file to populate the top-10 list.'),
        findsOneWidget);
    expect(find.text('Top-10 trials'), findsOneWidget);
    expect(find.text('Convergence plot'), findsOneWidget);
    expect(find.byKey(const Key('studies-pick-db-button')),
        findsOneWidget);
    // Reload button is hidden until a DB is picked.
    expect(find.byKey(const Key('studies-reload-button')), findsNothing);
    p.dispose();
  });

  testWidgets('Loading indicator visible while isLoading=true',
      (tester) async {
    final p = _FakeStudiesProvider();
    p.setLoading(true);
    // CircularProgressIndicator never settles, so we pump one frame
    // instead of pumpAndSettle.
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<StudiesProvider>.value(
          value: p,
          child: const StudiesScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('studies-loading-indicator')),
        findsOneWidget);
    p.dispose();
  });

  testWidgets('Error banner appears when errorMessage is set',
      (tester) async {
    final p = _FakeStudiesProvider();
    p.setDbPath('/tmp/foo.db');
    p.setError('Failed to load DB: not found');
    await _pump(tester, p);

    expect(find.byKey(const Key('studies-error-banner')), findsOneWidget);
    expect(find.textContaining('Failed to load DB'), findsOneWidget);
    p.dispose();
  });

  testWidgets('Reload button surfaces once a DB has been picked',
      (tester) async {
    final p = _FakeStudiesProvider();
    p.setDbPath('/tmp/some.db');
    await _pump(tester, p);

    expect(find.byKey(const Key('studies-reload-button')), findsOneWidget);
    p.dispose();
  });
}
