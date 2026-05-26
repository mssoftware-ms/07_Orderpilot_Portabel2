/// Optuna-style study row from the `studies` table.
///
/// Welle O3-B2: read-only mirror of the schema written by the Python
/// optimizer CLI (`scripts/run_*_optimization.py`). The Flutter UI never
/// writes; B2 is a viewer.
library;

class Study {
  final int id;
  final String name;
  final String strategy;
  final String searchSpaceYaml;
  final DateTime createdAt;
  final String? commitHash;

  const Study({
    required this.id,
    required this.name,
    required this.strategy,
    required this.searchSpaceYaml,
    required this.createdAt,
    this.commitHash,
  });

  factory Study.fromRow(Map<String, Object?> row) => Study(
        id: row['id'] as int,
        name: row['name'] as String,
        strategy: row['strategy'] as String,
        searchSpaceYaml: row['search_space_yaml'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        commitHash: row['commit_hash'] as String?,
      );
}
