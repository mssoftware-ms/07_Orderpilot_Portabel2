import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'core/logging/app_log.dart';
import 'core/navigation/app_navigation.dart';
import 'features/backtest/backtest_provider.dart';
import 'features/exchange/bitunix_connection_provider.dart';
import 'features/paper/paper_trading_provider.dart';
import 'features/studies/studies_provider.dart';
import 'ui/themes/app_theme.dart';
import 'ui/screens/account_screen.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/chart_screen.dart';
import 'ui/screens/backtest_screen.dart';
import 'ui/screens/paper_trading_screen.dart';
import 'ui/screens/strategy_management_screen.dart';
import 'ui/screens/studies_screen.dart';

void main() {
  // Welle O3-B2: sqfliteFfiInit MUST run before runApp and before any
  // file_picker call so the Studies viewer can open Optuna-style .db
  // files via the FFI backend on desktop platforms (Linux/macOS/Windows).
  // On the (non-web) host, swap the global databaseFactory to the FFI
  // variant. On web, the studies viewer is disabled at build time.
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const TradingApp());
}

class TradingApp extends StatelessWidget {
  const TradingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BacktestProvider()),
        ChangeNotifierProvider(create: (_) => StudiesProvider()),
        ChangeNotifierProvider(create: (_) => PaperTradingProvider()),
        ChangeNotifierProvider(
          create: (_) =>
              BitunixConnectionProvider()..loadStoredCredentials(),
        ),
        ChangeNotifierProvider(create: (_) => AppNavigation()),
        ChangeNotifierProvider<AppLogStore>.value(value: AppLog.instance),
      ],
      child: MaterialApp(
        title: 'Trading App',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const AppScaffold(),
      ),
    );
  }
}

/// Main scaffold with adaptive navigation:
/// - BottomNavigationBar on narrow screens (mobile / portrait)
/// - NavigationRail on wide screens (desktop / landscape)
class AppScaffold extends StatelessWidget {
  const AppScaffold({super.key});

  static const _screens = <Widget>[
    HomeScreen(),
    ChartScreen(),
    BacktestScreen(),
    StudiesScreen(),
    PaperTradingScreen(),
    StrategyManagementScreen(),
    AccountScreen(),
  ];

  static const _navItems = <_NavItem>[
    _NavItem(icon: Icons.dashboard_outlined, selectedIcon: Icons.dashboard, label: 'Home'),
    _NavItem(icon: Icons.candlestick_chart_outlined, selectedIcon: Icons.candlestick_chart, label: 'Chart'),
    _NavItem(icon: Icons.history_outlined, selectedIcon: Icons.history, label: 'Backtest'),
    _NavItem(icon: Icons.analytics_outlined, selectedIcon: Icons.analytics, label: 'Studies'),
    _NavItem(icon: Icons.play_circle_outline, selectedIcon: Icons.play_circle_filled, label: 'Paper'),
    _NavItem(icon: Icons.extension_outlined, selectedIcon: Icons.extension, label: 'Strategies'),
    _NavItem(icon: Icons.account_balance_wallet_outlined, selectedIcon: Icons.account_balance_wallet, label: 'Account'),
  ];

  static const double _wideBreakpoint = 720;

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<AppNavigation>();
    final selectedIndex = nav.selectedIndex;
    final isWide = MediaQuery.of(context).size.width >= _wideBreakpoint;

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: selectedIndex,
              onDestinationSelected: nav.goToIndex,
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Icon(Icons.show_chart, color: AppColors.accentCyan, size: 32),
              ),
              destinations: _navItems
                  .map((item) => NavigationRailDestination(
                        icon: Icon(item.icon),
                        selectedIcon: Icon(item.selectedIcon),
                        label: Text(item.label),
                      ))
                  .toList(),
            ),
            const VerticalDivider(width: 1, thickness: 0.5, color: AppColors.divider),
            Expanded(child: _screens[selectedIndex]),
          ],
        ),
      );
    }

    return Scaffold(
      body: _screens[selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: selectedIndex,
        onTap: nav.goToIndex,
        items: _navItems
            .map((item) => BottomNavigationBarItem(
                  icon: Icon(item.icon),
                  activeIcon: Icon(item.selectedIcon),
                  label: item.label,
                ))
            .toList(),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const _NavItem({required this.icon, required this.selectedIcon, required this.label});
}
