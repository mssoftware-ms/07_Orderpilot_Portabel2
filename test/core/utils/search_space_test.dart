/// Tests for the Welle O3-B2-5 search_space_yaml parser.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/core/utils/search_space.dart';

const _bbRsiYaml = '''
strategy_name: bb_rsi
parameters:
  adx_threshold:
    type: Float
    min: 25.0
    max: 45.0
    log: false
  adx_use_di_confluence:
    type: Bool
  bb_period:
    type: Int
    min: 100
    max: 300
  rsi_period:
    type: Int
    min: 2
    max: 7
fixed:
  adx_filter_enabled: 1.0
  adx_period: 14.0
''';

const _ichimokuYaml = '''
strategy_name: ichimoku
parameters:
  kijun_period:
    type: Int
    min: 21
    max: 40
  senkou_b_period:
    type: Int
    min: 40
    max: 70
  shift:
    type: Int
    min: 20
    max: 30
fixed:
  tz_offset_hours: 1.0
''';

const _utBotYaml = '''
strategy_name: ut_bot
parameters:
  key_value:
    type: Float
    min: 1.0
    max: 5.0
    log: false
  atr_period:
    type: Int
    min: 1
    max: 5
''';

void main() {
  test('parses BB+RSI search-space and ignores fixed section', () {
    final params = parseSearchSpace(_bbRsiYaml);
    // 4 optimized parameters, fixed values not surfaced.
    expect(params.length, 4);
    expect(params.map((p) => p.name).toList(),
        ['adx_threshold', 'adx_use_di_confluence', 'bb_period', 'rsi_period']);

    final adx = params.firstWhere((p) => p.name == 'adx_threshold');
    expect(adx.type, ParamSpecType.floatRange);
    expect(adx.min, 25.0);
    expect(adx.max, 45.0);
    expect(adx.log, isFalse);

    final boolParam =
        params.firstWhere((p) => p.name == 'adx_use_di_confluence');
    expect(boolParam.type, ParamSpecType.boolean);
    expect(boolParam.min, isNull);
    expect(boolParam.max, isNull);

    final bb = params.firstWhere((p) => p.name == 'bb_period');
    expect(bb.type, ParamSpecType.intRange);
    expect(bb.min, 100.0);
    expect(bb.max, 300.0);

    // No 'adx_filter_enabled' (fixed) — must be absent.
    expect(params.any((p) => p.name == 'adx_filter_enabled'), isFalse);
    expect(params.any((p) => p.name == 'tz_offset_hours'), isFalse);
  });

  test('parses Ichimoku search-space (3 Int params)', () {
    final params = parseSearchSpace(_ichimokuYaml);
    expect(params.length, 3);
    expect(params.every((p) => p.type == ParamSpecType.intRange), isTrue);
  });

  test('parses UT-Bot search-space (Float + Int mix, no `fixed:`)', () {
    final params = parseSearchSpace(_utBotYaml);
    expect(params.length, 2);
    final names = params.map((p) => p.name).toSet();
    expect(names, {'key_value', 'atr_period'});
  });

  test('empty / missing parameters returns empty list', () {
    expect(parseSearchSpace(''), isEmpty);
    expect(parseSearchSpace('strategy_name: foo\n'), isEmpty);
    expect(parseSearchSpace('parameters:\n'), isEmpty);
  });

  test('malformed YAML returns empty list (no throw)', () {
    expect(parseSearchSpace('::: not yaml'), isEmpty);
    expect(parseSearchSpace('parameters: oops'), isEmpty);
  });

  test('case-insensitive type tag and unknown type skipped', () {
    const yaml = '''
parameters:
  a:
    type: float
    min: 1
    max: 2
  b:
    type: STRING
    min: 0
    max: 0
  c:
    type: Int
    min: 1
    max: 10
''';
    final params = parseSearchSpace(yaml);
    expect(params.length, 2);
    expect(params.map((p) => p.name).toList(), ['a', 'c']);
  });
}
