/// Welle O3-B4: Multi-DB profitable-trial leaderboard.
///
/// Reads from a [StudiesLibrary], opens each pinned (existing,
/// readable) DB sequentially, calls [StudiesDb.topNProfitable] with a
/// generous per-DB limit, merges, sorts globally, and truncates to
/// [limit]. Per-DB cap is `limit * 2` so a strategy with many high
/// scorers can still dominate the global slice — we trade slight
/// over-fetch for correctness near the boundary.
///
/// Concurrency: a monotonic [_generation] counter discards the result
/// of any recompute that was superseded by a newer one (pin/unpin or
/// filter change mid-flight). The UI coalesces rapid user input
/// (slider `onChangeEnd`), so no timer-debounce is needed here.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/leaderboard_row.dart';
import '../../services/studies_db.dart';
import 'studies_library.dart';

class AggregateLeaderboard extends ChangeNotifier {
  final StudiesLibrary library;
  AggregateLeaderboard({required this.library}) {
    library.addListener(_onLibraryChange);
  }

  int minTrades = 20;
  int limit = 10;
  // Welle O3-B4-12: default sort is PnL, not score. Real production
  // studies write score=-inf for nearly every trial (constraint penalty),
  // so a score-ranked default would order the profitable trials
  // arbitrarily. PnL is the natural ranking for a "profitable runs" board.
  String sortBy = 'pnl';

  List<LeaderboardRow> _rows = const [];
  List<LeaderboardRow> get rows => _rows;

  bool _loading = false;
  bool get loading => _loading;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  int _generation = 0;

  void _onLibraryChange() {
    // Library mutations (pin/unpin/refresh) trigger a recompute. Cheap
    // path — no debounce, the UI debounces user input upstream.
    unawaited(recompute());
  }

  Future<void> recompute() async {
    _loading = true;
    _errorMessage = null;
    notifyListeners();
    final gen = ++_generation;

    final pinned = library.entries
        .where((e) => e.pinned && !library.isMissing(e))
        .toList(growable: false);

    final merged = <LeaderboardRow>[];
    for (final entry in pinned) {
      if (gen != _generation) return; // stale — drop result
      final db = StudiesDb();
      try {
        await db.open(entry.path);
        final batch = await db.topNProfitable(
          minTrades: minTrades,
          limit: limit * 2,
          sortBy: sortBy,
        );
        merged.addAll(batch);
      } catch (e, st) {
        AppLog.warn(
            'AggregateLeaderboard', 'Skipping ${entry.path}: $e', e, st);
      } finally {
        await db.close();
      }
    }

    if (gen != _generation) return;

    merged.sort(_comparatorFor(sortBy));
    _rows = merged.take(limit).toList(growable: false);
    _loading = false;
    notifyListeners();
  }

  int Function(LeaderboardRow, LeaderboardRow) _comparatorFor(String key) {
    switch (key) {
      case 'pnl':
        return (a, b) =>
            b.trial.metrics.totalPnl.compareTo(a.trial.metrics.totalPnl);
      case 'sharpe':
        return (a, b) => b.trial.metrics.sharpeRatio
            .compareTo(a.trial.metrics.sharpeRatio);
      case 'pf':
        return (a, b) => b.trial.metrics.profitFactor
            .compareTo(a.trial.metrics.profitFactor);
      case 'trades':
        return (a, b) => b.trial.metrics.totalTrades
            .compareTo(a.trial.metrics.totalTrades);
      case 'winRate':
        return (a, b) =>
            b.trial.metrics.winRate.compareTo(a.trial.metrics.winRate);
      case 'score':
      default:
        return (a, b) => b.trial.score.compareTo(a.trial.score);
    }
  }

  @override
  void dispose() {
    library.removeListener(_onLibraryChange);
    super.dispose();
  }
}
