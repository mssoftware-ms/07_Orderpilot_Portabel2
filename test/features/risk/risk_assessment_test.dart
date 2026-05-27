/// Welle B4.3-1 — [RiskAssessment] value-object coverage.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/features/risk/risk_assessment.dart';

void main() {
  group('RiskAssessment.neutral', () {
    test('all-gates-pass and zeroed indicators', () {
      final a = RiskAssessment.neutral();
      expect(a.currentDailyPnlPct, 0.0);
      expect(a.currentDrawdownPct, 0.0);
      expect(a.currentConsecutiveLosses, 0);
      expect(a.killSwitchActive, isFalse);
      expect(a.breachedGates, isEmpty);
      expect(a.allGatesPass, isTrue);
    });
  });

  group('allGatesPass', () {
    test('true exactly when breachedGates is empty', () {
      final none = RiskAssessment(
        currentDailyPnlPct: -1.0,
        currentDrawdownPct: 2.0,
        currentConsecutiveLosses: 1,
        killSwitchActive: false,
        breachedGates: const <RiskGate>{},
      );
      expect(none.allGatesPass, isTrue);

      final single = RiskAssessment(
        currentDailyPnlPct: -4.5,
        currentDrawdownPct: 0,
        currentConsecutiveLosses: 0,
        killSwitchActive: false,
        breachedGates: const {RiskGate.dailyLoss},
      );
      expect(single.allGatesPass, isFalse);
    });
  });

  group('gateBreached', () {
    test('reports the specific gate', () {
      final a = RiskAssessment(
        currentDailyPnlPct: 0,
        currentDrawdownPct: 0,
        currentConsecutiveLosses: 0,
        killSwitchActive: true,
        breachedGates: const {RiskGate.killSwitch},
      );
      expect(a.gateBreached(RiskGate.killSwitch), isTrue);
      expect(a.gateBreached(RiskGate.dailyLoss), isFalse);
    });
  });

  group('breachedGates is unmodifiable', () {
    test('mutating the source set after construction has no effect', () {
      final src = <RiskGate>{RiskGate.dailyLoss};
      final a = RiskAssessment(
        currentDailyPnlPct: -5,
        currentDrawdownPct: 0,
        currentConsecutiveLosses: 0,
        killSwitchActive: false,
        breachedGates: src,
      );
      src.add(RiskGate.drawdown);
      expect(a.breachedGates, hasLength(1));
      expect(() => a.breachedGates.add(RiskGate.drawdown),
          throwsUnsupportedError);
    });
  });

  group('equality', () {
    test('value equality ignores set ordering', () {
      final a = RiskAssessment(
        currentDailyPnlPct: -3,
        currentDrawdownPct: 5,
        currentConsecutiveLosses: 2,
        killSwitchActive: false,
        breachedGates: const {RiskGate.dailyLoss, RiskGate.drawdown},
      );
      final b = RiskAssessment(
        currentDailyPnlPct: -3,
        currentDrawdownPct: 5,
        currentConsecutiveLosses: 2,
        killSwitchActive: false,
        breachedGates: const {RiskGate.drawdown, RiskGate.dailyLoss},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing breached gates compare unequal', () {
      final a = RiskAssessment(
        currentDailyPnlPct: 0,
        currentDrawdownPct: 0,
        currentConsecutiveLosses: 0,
        killSwitchActive: false,
        breachedGates: const {RiskGate.dailyLoss},
      );
      final b = RiskAssessment(
        currentDailyPnlPct: 0,
        currentDrawdownPct: 0,
        currentConsecutiveLosses: 0,
        killSwitchActive: false,
        breachedGates: const {RiskGate.drawdown},
      );
      expect(a, isNot(b));
    });
  });
}
