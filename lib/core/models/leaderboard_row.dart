/// Welle O3-B4: a single Global-Leaderboard row.
///
/// Wraps a [Trial] with the denormalized originating strategy + study
/// name + DB path so the cross-DB table and its detail sheet do not
/// need a second JOIN or a back-reference to the owning [StudiesDb].
library;

import 'trial.dart';

class LeaderboardRow {
  final Trial trial;
  final String strategy;
  final String studyName;
  final int studyDbId;
  final String dbPath;

  const LeaderboardRow({
    required this.trial,
    required this.strategy,
    required this.studyName,
    required this.studyDbId,
    required this.dbPath,
  });

  String get rowKey => '$dbPath#$studyDbId#${trial.trialId}';
}
