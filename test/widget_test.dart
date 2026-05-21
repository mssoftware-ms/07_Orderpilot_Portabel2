import 'package:flutter_test/flutter_test.dart';

import 'package:trading_app/main.dart';

void main() {
  testWidgets('App scaffold renders with navigation', (WidgetTester tester) async {
    await tester.pumpWidget(const TradingApp());

    // Verify bottom navigation items exist
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Chart'), findsOneWidget);
    expect(find.text('Backtest'), findsOneWidget);
    expect(find.text('Paper'), findsOneWidget);
    expect(find.text('Strategies'), findsOneWidget);

    // Verify dashboard screen is shown by default
    expect(find.text('Dashboard'), findsOneWidget);
  });
}
