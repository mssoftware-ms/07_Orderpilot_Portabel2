/// Welle O3-B3-4 — cross-screen tab navigation hook.
///
/// The main scaffold owns the currently-selected tab; without a way for
/// peer screens to request a tab switch the Strategy-Management screen
/// cannot offer an "Open Studies viewer" quick-link. This minimal
/// [ChangeNotifier] exposes the selected index + an `goTo` method so the
/// scaffold can subscribe and re-render, and any screen can call
/// `context.read<AppNavigation>().goTo(AppTab.studies)`.
library;

import 'package:flutter/foundation.dart';

/// Stable tab identifiers. Order MUST mirror `_AppScaffoldState._screens`
/// in `lib/main.dart` because the enum's built-in `index` is the value
/// fed back into the scaffold's selection state.
enum AppTab {
  home,
  chart,
  backtest,
  studies,
  paperTrading,
  strategies,
}

class AppNavigation extends ChangeNotifier {
  int _selectedIndex;

  AppNavigation({int initialIndex = 0}) : _selectedIndex = initialIndex;

  int get selectedIndex => _selectedIndex;

  AppTab get selectedTab =>
      (_selectedIndex >= 0 && _selectedIndex < AppTab.values.length)
          ? AppTab.values[_selectedIndex]
          : AppTab.home;

  void goToIndex(int index) {
    if (index == _selectedIndex) return;
    _selectedIndex = index;
    notifyListeners();
  }

  void goTo(AppTab tab) => goToIndex(tab.index);
}
