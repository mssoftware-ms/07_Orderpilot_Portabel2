/// Lightweight app-wide log sink for surfacing errors and warnings to the UI.
///
/// Usage from anywhere (no BuildContext required):
///
/// ```dart
/// try {
///   ...
/// } catch (e, st) {
///   AppLog.error('SomeTag', 'Something went wrong', e, st);
/// }
/// ```
///
/// The UI subscribes to [AppLog.instance] via `Provider` / `Consumer` and
/// renders the [entries] list. Entries are kept in an in-memory ring buffer
/// (no persistence, no isolate-crossing — isolate-internal failures must
/// propagate to the outer catch in the main isolate to surface here).
library;

import 'package:flutter/foundation.dart';

enum LogLevel { warning, error }

@immutable
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });
}

/// In-memory ring buffer of log entries. Listenable for UI rebuilds.
class AppLogStore extends ChangeNotifier {
  AppLogStore({this.capacity = 200});

  final int capacity;
  final List<LogEntry> _entries = [];

  /// Newest entry first.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  int get count => _entries.length;
  int get errorCount =>
      _entries.where((e) => e.level == LogLevel.error).length;
  int get warningCount =>
      _entries.where((e) => e.level == LogLevel.warning).length;

  void add(LogEntry entry) {
    _entries.insert(0, entry);
    if (_entries.length > capacity) {
      _entries.removeRange(capacity, _entries.length);
    }
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}

/// Static facade — call from any try/catch site, including services and
/// async code that has no [BuildContext].
class AppLog {
  AppLog._();

  /// Shared store instance. Registered in `main.dart` via
  /// `ChangeNotifierProvider.value(value: AppLog.instance)` so widgets can
  /// `context.watch<AppLogStore>()`.
  static final AppLogStore instance = AppLogStore();

  static void warn(String tag, String message,
      [Object? error, StackTrace? stackTrace]) {
    _emit(LogLevel.warning, tag, message, error, stackTrace);
  }

  static void error(String tag, String message,
      [Object? error, StackTrace? stackTrace]) {
    _emit(LogLevel.error, tag, message, error, stackTrace);
  }

  static void _emit(LogLevel level, String tag, String message, Object? error,
      StackTrace? stackTrace) {
    instance.add(LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stackTrace,
    ));
    if (kDebugMode) {
      // ignore: avoid_print
      print('[${level.name.toUpperCase()}] [$tag] $message'
          '${error != null ? ' :: $error' : ''}');
    }
  }
}
