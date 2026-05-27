/// Welle B4.3-1 — [RiskConfig] roundtrip + defaults coverage.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_app/features/risk/risk_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RiskConfig.defaults', () {
    test('matches the pre-task brief: 5/3/10/5/false/false', () {
      final cfg = RiskConfig.defaults();
      expect(cfg.maxPositionRiskPct, 5.0);
      expect(cfg.maxDailyLossPct, 3.0);
      expect(cfg.maxDrawdownPct, 10.0);
      expect(cfg.maxConsecutiveLosses, 5);
      expect(cfg.killSwitchActive, isFalse);
      expect(cfg.liveTradingEnabled, isFalse,
          reason: 'live trading must default OFF — never auto-enable');
    });
  });

  group('RiskConfig.toMap / fromMap', () {
    test('roundtrips every field', () {
      const cfg = RiskConfig(
        maxPositionRiskPct: 2.5,
        maxDailyLossPct: 4.0,
        maxDrawdownPct: 12.0,
        maxConsecutiveLosses: 7,
        killSwitchActive: true,
        liveTradingEnabled: true,
      );
      final roundtripped = RiskConfig.fromMap(cfg.toMap());
      expect(roundtripped, cfg);
      expect(roundtripped.liveTradingEnabled, isTrue);
    });

    test('legacy persisted blob without liveTradingEnabled defaults to false',
        () {
      // Pre-B4.4 configs were written without the new key — the loader
      // must gracefully treat the missing field as false rather than
      // throwing or surfacing a non-null state.
      final cfg = RiskConfig.fromMap(<String, dynamic>{
        'maxPositionRiskPct': 5.0,
        'maxDailyLossPct': 3.0,
        'maxDrawdownPct': 10.0,
        'maxConsecutiveLosses': 5,
        'killSwitchActive': false,
      });
      expect(cfg.liveTradingEnabled, isFalse);
    });

    test('tolerates int-typed numerics (JSON decoder rounding)', () {
      // jsonDecode may surface a whole-number double as int — the parser
      // must coerce it back via num.toDouble.
      final cfg = RiskConfig.fromMap(<String, dynamic>{
        'maxPositionRiskPct': 5,
        'maxDailyLossPct': 3,
        'maxDrawdownPct': 10,
        'maxConsecutiveLosses': 5,
        'killSwitchActive': false,
      });
      expect(cfg.maxPositionRiskPct, 5.0);
      expect(cfg.maxDailyLossPct, 3.0);
      expect(cfg.maxDrawdownPct, 10.0);
    });

    test('missing keys fall through to defaults', () {
      final cfg = RiskConfig.fromMap(<String, dynamic>{});
      expect(cfg, RiskConfig.defaults());
    });
  });

  group('RiskConfig.copyWith', () {
    test('only overrides the supplied fields', () {
      const base = RiskConfig(
        maxPositionRiskPct: 5.0,
        maxDailyLossPct: 3.0,
        maxDrawdownPct: 10.0,
        maxConsecutiveLosses: 5,
        killSwitchActive: false,
      );
      final updated = base.copyWith(killSwitchActive: true);
      expect(updated.killSwitchActive, isTrue);
      expect(updated.maxPositionRiskPct, base.maxPositionRiskPct);
      expect(updated.maxDailyLossPct, base.maxDailyLossPct);
      expect(updated.maxDrawdownPct, base.maxDrawdownPct);
      expect(updated.maxConsecutiveLosses, base.maxConsecutiveLosses);
      expect(updated.liveTradingEnabled, base.liveTradingEnabled);
    });

    test('copyWith(liveTradingEnabled: true) preserves every other field', () {
      const base = RiskConfig(
        maxPositionRiskPct: 4.0,
        maxDailyLossPct: 2.0,
        maxDrawdownPct: 8.0,
        maxConsecutiveLosses: 6,
        killSwitchActive: true,
      );
      final updated = base.copyWith(liveTradingEnabled: true);
      expect(updated.liveTradingEnabled, isTrue);
      expect(updated.maxPositionRiskPct, base.maxPositionRiskPct);
      expect(updated.maxDailyLossPct, base.maxDailyLossPct);
      expect(updated.maxDrawdownPct, base.maxDrawdownPct);
      expect(updated.maxConsecutiveLosses, base.maxConsecutiveLosses);
      expect(updated.killSwitchActive, base.killSwitchActive);
    });
  });

  group('RiskConfig equality + hash', () {
    test('liveTradingEnabled participates in equality', () {
      const a = RiskConfig(
        maxPositionRiskPct: 5.0,
        maxDailyLossPct: 3.0,
        maxDrawdownPct: 10.0,
        maxConsecutiveLosses: 5,
        killSwitchActive: false,
        liveTradingEnabled: false,
      );
      const b = RiskConfig(
        maxPositionRiskPct: 5.0,
        maxDailyLossPct: 3.0,
        maxDrawdownPct: 10.0,
        maxConsecutiveLosses: 5,
        killSwitchActive: false,
        liveTradingEnabled: true,
      );
      expect(a, isNot(b));
      expect(a.hashCode, isNot(b.hashCode));
    });
  });

  group('RiskConfig SharedPreferences persistence', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('loadFrom returns defaults when nothing is stored', () async {
      final prefs = await SharedPreferences.getInstance();
      final cfg = RiskConfig.loadFrom(prefs);
      expect(cfg, RiskConfig.defaults());
    });

    test('persistTo + loadFrom roundtrip across instances', () async {
      final prefs = await SharedPreferences.getInstance();
      const cfg = RiskConfig(
        maxPositionRiskPct: 7.5,
        maxDailyLossPct: 2.5,
        maxDrawdownPct: 15.0,
        maxConsecutiveLosses: 4,
        killSwitchActive: true,
        liveTradingEnabled: true,
      );
      await cfg.persistTo(prefs);

      final loaded = RiskConfig.loadFrom(prefs);
      expect(loaded, cfg);
      expect(loaded.liveTradingEnabled, isTrue,
          reason: 'live-trading bit must survive across app restarts');
    });

    test('loadFrom degrades to defaults on corrupt JSON', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kRiskConfigPrefsKey: 'not-valid-json{',
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = RiskConfig.loadFrom(prefs);
      expect(cfg, RiskConfig.defaults());
    });

    test('loadFrom degrades to defaults on non-map JSON', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kRiskConfigPrefsKey: '[1,2,3]',
      });
      final prefs = await SharedPreferences.getInstance();
      final cfg = RiskConfig.loadFrom(prefs);
      expect(cfg, RiskConfig.defaults());
    });
  });
}
