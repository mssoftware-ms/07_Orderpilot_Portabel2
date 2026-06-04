/// Welle O3-B4: value objects for the multi-DB Studies Library.
///
/// [LibraryEntry] is the canonical per-DB record (path + pin-state +
/// cached health). [LibraryHealth] is the lightweight count snapshot
/// rendered as the library health dot. Both have forward-compatible
/// JSON codecs — unknown fields are tolerated on read.
library;

class LibraryHealth {
  final int studyCount;
  final int profitableTrialCount;
  final int totalTrialCount;
  final int dbMtimeMs;

  const LibraryHealth({
    required this.studyCount,
    required this.profitableTrialCount,
    required this.totalTrialCount,
    required this.dbMtimeMs,
  });

  factory LibraryHealth.fromJson(Map<String, Object?> j) => LibraryHealth(
        studyCount: (j['studyCount'] as num?)?.toInt() ?? 0,
        profitableTrialCount:
            (j['profitableTrialCount'] as num?)?.toInt() ?? 0,
        totalTrialCount: (j['totalTrialCount'] as num?)?.toInt() ?? 0,
        dbMtimeMs: (j['dbMtimeMs'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
        'studyCount': studyCount,
        'profitableTrialCount': profitableTrialCount,
        'totalTrialCount': totalTrialCount,
        'dbMtimeMs': dbMtimeMs,
      };
}

class LibraryEntry {
  final String path;
  final bool pinned;
  final DateTime addedAt;
  final DateTime? lastScannedAt;
  final LibraryHealth? health;

  const LibraryEntry({
    required this.path,
    required this.pinned,
    required this.addedAt,
    this.lastScannedAt,
    this.health,
  });

  factory LibraryEntry.fromJson(Map<String, Object?> j) => LibraryEntry(
        path: j['path'] as String,
        pinned: j['pinned'] as bool? ?? false,
        addedAt: DateTime.parse(j['addedAt'] as String),
        lastScannedAt: j['lastScannedAt'] is String
            ? DateTime.parse(j['lastScannedAt'] as String)
            : null,
        health: j['health'] is Map
            ? LibraryHealth.fromJson(
                Map<String, Object?>.from(j['health'] as Map))
            : null,
      );

  Map<String, Object?> toJson() => {
        'path': path,
        'pinned': pinned,
        'addedAt': addedAt.toUtc().toIso8601String(),
        if (lastScannedAt != null)
          'lastScannedAt': lastScannedAt!.toUtc().toIso8601String(),
        if (health != null) 'health': health!.toJson(),
      };

  LibraryEntry copyWith({
    bool? pinned,
    DateTime? lastScannedAt,
    LibraryHealth? health,
  }) =>
      LibraryEntry(
        path: path,
        pinned: pinned ?? this.pinned,
        addedAt: addedAt,
        lastScannedAt: lastScannedAt ?? this.lastScannedAt,
        health: health ?? this.health,
      );
}
