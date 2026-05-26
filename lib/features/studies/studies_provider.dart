/// State management for the Welle O3-B2 Studies viewer.
///
/// Wraps [StudiesDb] and surfaces the currently-loaded DB path, the list
/// of studies inside it, the currently-selected study, that study's
/// trials + derived top-10 view, plus loading / error state for the UI.
///
/// Every async-failure path routes through `AppLog.error` so DB-open
/// and parse failures surface in the dashboard's System Log panel
/// (rather than being swallowed silently).
library;

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../core/models/study.dart';
import '../../core/models/trial.dart';
import '../../services/studies_db.dart';

class StudiesProvider extends ChangeNotifier {
  final StudiesDb _db;

  StudiesProvider({StudiesDb? db}) : _db = db ?? StudiesDb();

  String? _dbPath;
  List<Study> _studies = const [];
  Study? _selectedStudy;
  List<Trial> _trials = const [];
  List<Trial> _top10 = const [];
  bool _isLoading = false;
  String? _errorMessage;

  String? get dbPath => _dbPath;
  List<Study> get studies => _studies;
  Study? get selectedStudy => _selectedStudy;
  List<Trial> get trials => _trials;
  List<Trial> get top10 => _top10;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// True once a DB has been opened AND at least one study parsed.
  bool get hasData => _selectedStudy != null;

  /// Opens the SQLite file at [path], loads the list of studies, and
  /// auto-selects the first one (with its trials + top-10 view).
  ///
  /// On failure: stores the error message, fires AppLog.error, and
  /// leaves the previous state untouched (UI shows the error banner).
  Future<void> loadDb(String path) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await _db.open(path);
      final studies = await _db.listStudies();
      if (studies.isEmpty) {
        // Open succeeded but the file has no studies — clear state and
        // surface the empty-state to the UI.
        _dbPath = path;
        _studies = const [];
        _selectedStudy = null;
        _trials = const [];
        _top10 = const [];
        _isLoading = false;
        notifyListeners();
        return;
      }
      _dbPath = path;
      _studies = studies;
      await _selectStudyInternal(studies.first);
      _isLoading = false;
      notifyListeners();
    } catch (e, st) {
      _errorMessage = 'Failed to load DB: $e';
      AppLog.error('StudiesProvider',
          'loadDb($path) failed: $e', e, st);
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Switches the currently-selected study. Reloads its trials + top-10.
  Future<void> selectStudy(int studyId) async {
    final match = _studies.where((s) => s.id == studyId).toList();
    if (match.isEmpty) {
      AppLog.warn('StudiesProvider',
          'selectStudy($studyId) — no matching study in current DB');
      return;
    }
    _isLoading = true;
    notifyListeners();
    try {
      await _selectStudyInternal(match.first);
      _isLoading = false;
      notifyListeners();
    } catch (e, st) {
      _errorMessage = 'Failed to load study $studyId: $e';
      AppLog.error('StudiesProvider',
          'selectStudy($studyId) failed: $e', e, st);
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _selectStudyInternal(Study s) async {
    _selectedStudy = s;
    // Top-10 first (cheap, separate SQL LIMIT 10) so the UI can render
    // immediately even for 1000-trial DBs; full trial list follows.
    _top10 = await _db.top10(s.id);
    _trials = await _db.listTrials(s.id);
  }

  /// Reloads the currently-selected study (and the underlying DB list).
  /// Useful after the user re-runs an optimizer CLI against the same file.
  Future<void> reload() async {
    final path = _dbPath;
    if (path == null) return;
    await loadDb(path);
  }

  /// Reset to the initial empty state. Closes the open DB handle.
  void clear() {
    _dbPath = null;
    _studies = const [];
    _selectedStudy = null;
    _trials = const [];
    _top10 = const [];
    _isLoading = false;
    _errorMessage = null;
    // Best-effort close — never throws on the consumer side.
    unawaited(_db.close());
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_db.close());
    super.dispose();
  }
}

/// Local replacement for `package:async`'s `unawaited` — keeps the
/// signature visible in catch-sites without pulling in a new dep.
void unawaited(Future<void>? future) {
  // No-op — purely an analyzer hint.
}
