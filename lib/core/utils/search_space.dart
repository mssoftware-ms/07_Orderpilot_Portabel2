/// Welle O3-B2-5: parser for the `search_space_yaml` column written by
/// the Python optimizer CLI.
///
/// Recognised shape (verified on bb_rsi / ut_bot / ichimoku DBs):
///
/// ```yaml
/// strategy_name: bb_rsi
/// parameters:
///   adx_threshold:
///     type: Float
///     min: 25.0
///     max: 45.0
///     log: false
///   adx_use_di_confluence:
///     type: Bool
///   rsi_period:
///     type: Int
///     min: 2
///     max: 7
/// fixed:
///   adx_filter_enabled: 1.0
///   adx_period: 14.0
/// ```
///
/// Only the `parameters:` section is surfaced. `fixed:` is intentionally
/// ignored — those values are constants, not optimization axes, and the
/// Welle-B2-5 convergence plot must NEVER offer them as a y-axis pick.
library;

import 'package:yaml/yaml.dart';

/// Supported parameter type tags. Matches the strings the Python writer
/// emits in the `type:` field.
enum ParamSpecType { intRange, floatRange, boolean }

class ParamSpec {
  final String name;
  final ParamSpecType type;
  final double? min;
  final double? max;
  final bool log;

  const ParamSpec({
    required this.name,
    required this.type,
    this.min,
    this.max,
    this.log = false,
  });

  bool get isNumeric =>
      type == ParamSpecType.intRange || type == ParamSpecType.floatRange;
}

/// Parses [yaml] and returns the optimized parameter list (sorted by name
/// so the UI dropdown is stable across DB swaps).
///
/// Tolerates:
///   - empty input → empty list
///   - missing `parameters:` key → empty list
///   - per-parameter type tag with different casing (`Float` / `float`)
///   - missing `min`/`max` on Bool entries
///   - extra unknown keys on parameter entries (logged as a no-op)
///
/// Throws nothing on malformed payloads — the caller (UI) can treat an
/// empty list as "convergence plot unavailable".
List<ParamSpec> parseSearchSpace(String yaml) {
  if (yaml.trim().isEmpty) return const [];
  final dynamic root;
  try {
    root = loadYaml(yaml);
  } on Object {
    return const [];
  }
  if (root is! YamlMap) return const [];
  final params = root['parameters'];
  if (params is! YamlMap) return const [];

  final out = <ParamSpec>[];
  for (final entry in params.entries) {
    final name = entry.key?.toString() ?? '';
    final body = entry.value;
    if (name.isEmpty || body is! YamlMap) continue;
    final typeRaw = body['type']?.toString() ?? '';
    final type = _parseType(typeRaw);
    if (type == null) continue;
    final spec = ParamSpec(
      name: name,
      type: type,
      min: type == ParamSpecType.boolean
          ? null
          : _toDouble(body['min']),
      max: type == ParamSpecType.boolean
          ? null
          : _toDouble(body['max']),
      log: body['log'] == true,
    );
    out.add(spec);
  }
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

ParamSpecType? _parseType(String s) {
  switch (s.toLowerCase()) {
    case 'int':
    case 'integer':
      return ParamSpecType.intRange;
    case 'float':
    case 'double':
      return ParamSpecType.floatRange;
    case 'bool':
    case 'boolean':
      return ParamSpecType.boolean;
  }
  return null;
}

double? _toDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}
