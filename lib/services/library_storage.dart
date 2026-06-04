/// Welle O3-B4: pin-state persistence for the Studies Library.
///
/// SharedPreferences-backed (single JSON-encoded String at the key
/// [_key]). Chose SharedPreferences over a file in AppSupport for
/// dep parity with Welle B4.3 (Risk Layer) and zero new packages —
/// this is the PRE_TASK §10 Q2 deviation.
///
/// Schema version is `1`; future schemas read the `version` field and
/// either migrate or reset (corrupt-JSON / unknown-version → empty
/// list + AppLog.warn — never crash).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/logging/app_log.dart';
import '../core/models/library_entry.dart';

class LibraryStorage {
  static const String _key = 'studies_library_v1';
  static const int _schemaVersion = 1;

  Future<List<LibraryEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        AppLog.warn('LibraryStorage',
            'Stored payload is not a JSON object — resetting.');
        return const [];
      }
      final version = (decoded['version'] as num?)?.toInt() ?? 0;
      if (version != _schemaVersion) {
        AppLog.warn('LibraryStorage',
            'Unknown schema version $version — resetting.');
        return const [];
      }
      final entries = decoded['entries'];
      if (entries is! List) return const [];
      final out = <LibraryEntry>[];
      for (final e in entries) {
        if (e is Map) {
          try {
            out.add(LibraryEntry.fromJson(Map<String, Object?>.from(e)));
          } catch (err, st) {
            AppLog.warn(
                'LibraryStorage', 'Skipped malformed entry: $err', err, st);
          }
        }
      }
      return out;
    } catch (e, st) {
      AppLog.warn('LibraryStorage',
          'Failed to decode library — resetting. $e', e, st);
      return const [];
    }
  }

  Future<void> save(List<LibraryEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode({
      'version': _schemaVersion,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
    await prefs.setString(_key, payload);
  }
}
