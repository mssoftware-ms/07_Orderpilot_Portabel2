/// Welle O3-B3 — params toMap / fromMap roundtrip + tolerant decoder tests.
///
/// Covers:
///   - Round-trip identity `defaults → toMap → fromMap` for BB+RSI, UT-Bot,
///     and Ichimoku param classes.
///   - Missing keys fall back to defaults (cross-strategy apply must not
///     throw — see Welle-O3-B3 escalation rule for fromMap-with-defaults).
///   - Int-typed fields cast via `.toInt()` (truncate), matching the
///     optimizer side. Stored as `200.0` → `200`, stored as `12.9` → `12`
///     (would round to 13). This is the off-by-one guard.
///   - Bool fields decode 0.0 → false, anything else → true.
///   - BbMaType enum round-trips through its 0.0/1.0 encoding.
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_app/services/backtest_service.dart';

void main() {
  group('BbRsiParams toMap/fromMap', () {
    test('defaults round-trip identically', () {
      const p = BbRsiParams();
      final m = p.toMap();
      final back = BbRsiParams.fromMap(m);
      expect(back.bbPeriod, p.bbPeriod);
      expect(back.bbStdDev, p.bbStdDev);
      expect(back.bbMaType, p.bbMaType);
      expect(back.rsiPeriod, p.rsiPeriod);
      expect(back.rsiOversold, p.rsiOversold);
      expect(back.rsiOverbought, p.rsiOverbought);
      expect(back.swingLookbackBars, p.swingLookbackBars);
      expect(back.tpRrRatio, p.tpRrRatio);
      expect(back.riskPerTrade, p.riskPerTrade);
      expect(back.slippageBps, p.slippageBps);
      expect(back.adxFilterEnabled, p.adxFilterEnabled);
      expect(back.adxThreshold, p.adxThreshold);
      expect(back.adxPeriod, p.adxPeriod);
      expect(back.adxUseDiConfluence, p.adxUseDiConfluence);
    });

    test('custom values round-trip identically', () {
      const p = BbRsiParams(
        bbPeriod: 227,
        bbStdDev: 0.5247214065846215,
        bbMaType: BbMaType.ema,
        rsiPeriod: 7,
        rsiOversold: 26.061366415865905,
        rsiOverbought: 76.2243526927804,
        swingLookbackBars: 12,
        tpRrRatio: 1.5081302408823998,
        riskPerTrade: 0.010686856359099122,
        slippageBps: 0.0,
        adxFilterEnabled: true,
        adxThreshold: 35.53114818005548,
        adxPeriod: 14,
        adxUseDiConfluence: false,
      );
      final back = BbRsiParams.fromMap(p.toMap());
      expect(back.bbPeriod, 227);
      expect(back.bbStdDev, closeTo(0.5247214065846215, 1e-12));
      expect(back.bbMaType, BbMaType.ema);
      expect(back.rsiPeriod, 7);
      expect(back.adxFilterEnabled, isTrue);
      expect(back.adxUseDiConfluence, isFalse);
    });

    test('empty map yields defaults (cross-strategy safety)', () {
      final back = BbRsiParams.fromMap(const {});
      const d = BbRsiParams();
      expect(back.bbPeriod, d.bbPeriod);
      expect(back.bbStdDev, d.bbStdDev);
      expect(back.adxFilterEnabled, d.adxFilterEnabled);
    });

    test('int fields use .toInt() truncate, not .round()', () {
      // Optimizer writes integral values as doubles (200.0). If an older
      // run wrote 12.9 we must NOT bump to 13 — keeps Param-grenzen tight.
      final back = BbRsiParams.fromMap(const {
        'bb_period': 200.0,
        'rsi_period': 12.9,
        'swing_lookback_bars': 19.999999,
      });
      expect(back.bbPeriod, 200);
      expect(back.rsiPeriod, 12); // .round() would give 13
      expect(back.swingLookbackBars, 19); // .round() would give 20
    });

    test('bb_ma_type encoding round-trips both values', () {
      final sma = BbRsiParams.fromMap(const {'bb_ma_type': 0.0});
      final ema = BbRsiParams.fromMap(const {'bb_ma_type': 1.0});
      expect(sma.bbMaType, BbMaType.sma);
      expect(ema.bbMaType, BbMaType.ema);
    });

    test('bool fields treat any non-zero as true', () {
      final on = BbRsiParams.fromMap(const {
        'adx_filter_enabled': 1.0,
        'adx_use_di_confluence': 1.0,
      });
      final off = BbRsiParams.fromMap(const {
        'adx_filter_enabled': 0.0,
        'adx_use_di_confluence': 0.0,
      });
      expect(on.adxFilterEnabled, isTrue);
      expect(on.adxUseDiConfluence, isTrue);
      expect(off.adxFilterEnabled, isFalse);
      expect(off.adxUseDiConfluence, isFalse);
    });
  });

  group('UtBotParams toMap/fromMap', () {
    test('defaults round-trip identically', () {
      const p = UtBotParams();
      final back = UtBotParams.fromMap(p.toMap());
      expect(back.emaPeriod, p.emaPeriod);
      expect(back.keyValue, p.keyValue);
      expect(back.atrPeriod, p.atrPeriod);
      expect(back.smiLength, p.smiLength);
      expect(back.smiKSmoothing, p.smiKSmoothing);
      expect(back.smiDSmoothing, p.smiDSmoothing);
      expect(back.swingLookbackBars, p.swingLookbackBars);
      expect(back.tpRrRatio, p.tpRrRatio);
      expect(back.riskPerTrade, p.riskPerTrade);
      expect(back.sessionFilterEnabled, p.sessionFilterEnabled);
      expect(back.sessionStartHourLocal, p.sessionStartHourLocal);
      expect(back.sessionEndHourLocal, p.sessionEndHourLocal);
      expect(back.slippageBps, p.slippageBps);
      expect(back.smiCrossAboveZero, p.smiCrossAboveZero);
      expect(back.adxFilterEnabled, p.adxFilterEnabled);
      expect(back.adxThreshold, p.adxThreshold);
      expect(back.adxPeriod, p.adxPeriod);
      expect(back.adxUseDiConfluence, p.adxUseDiConfluence);
    });

    test('real-trial keys (subset from studies-ut_bot.db) reconstruct',
        () {
      // This subset is exactly what the optimizer writes — verifies the
      // mapper handles missing session_*_hour_local / slippage_bps gracefully.
      const trial = {
        'adx_filter_enabled': 1.0,
        'adx_period': 14.0,
        'adx_threshold': 35.53114818005548,
        'adx_use_di_confluence': 0.0,
        'atr_period': 4.0,
        'ema_period': 181.0,
        'key_value': 1.1030284538648683,
        'risk_per_trade': 0.0182991369237072,
        'session_filter_enabled': 0.0,
        'smi_cross_above_zero': 0.0,
        'smi_d_smoothing': 5.0,
        'smi_k_smoothing': 3.0,
        'smi_length': 5.0,
        'swing_lookback_bars': 29.0,
        'tp_rr_ratio': 2.765373406116185,
      };
      final p = UtBotParams.fromMap(trial);
      expect(p.atrPeriod, 4);
      expect(p.emaPeriod, 181);
      expect(p.keyValue, closeTo(1.1030284538648683, 1e-12));
      expect(p.adxFilterEnabled, isTrue);
      expect(p.sessionFilterEnabled, isFalse);
      expect(p.smiLength, 5);
    });
  });

  group('IchimokuParams toMap/fromMap', () {
    test('defaults round-trip identically', () {
      const p = IchimokuParams();
      final back = IchimokuParams.fromMap(p.toMap());
      expect(back.tenkanPeriod, p.tenkanPeriod);
      expect(back.kijunPeriod, p.kijunPeriod);
      expect(back.senkouBPeriod, p.senkouBPeriod);
      expect(back.shift, p.shift);
      expect(back.scoreThreshold, p.scoreThreshold);
      expect(back.tpRrRatio, p.tpRrRatio);
      expect(back.riskPerTrade, p.riskPerTrade);
      expect(back.swingLookbackBars, p.swingLookbackBars);
      expect(back.sessionFilterEnabled, p.sessionFilterEnabled);
      expect(back.adxFilterEnabled, p.adxFilterEnabled);
      expect(back.adxThreshold, p.adxThreshold);
      expect(back.adxPeriod, p.adxPeriod);
    });

    test('real-trial keys (subset from studies-ichimoku.db) reconstruct',
        () {
      const trial = {
        'adx_filter_enabled': 1.0,
        'adx_period': 14.0,
        'adx_threshold': 35.53114818005548,
        'adx_use_di_confluence': 0.0,
        'kijun_period': 33.0,
        'risk_per_trade': 0.018118035164615534,
        'score_threshold': 41.0,
        'senkou_b_period': 52.0,
        'session_filter_enabled': 0.0,
        'shift': 28.0,
        'tenkan_period': 12.0,
        'tp_rr_ratio': 1.828197222918587,
      };
      final p = IchimokuParams.fromMap(trial);
      expect(p.tenkanPeriod, 12);
      expect(p.kijunPeriod, 33);
      expect(p.senkouBPeriod, 52);
      expect(p.shift, 28);
      expect(p.scoreThreshold, 41);
      expect(p.adxFilterEnabled, isTrue);
      // Missing keys (e.g. swing_lookback_bars, tz_offset_hours) → defaults.
      expect(p.swingLookbackBars, 20);
      expect(p.tzOffsetHours, 1);
    });
  });

  group('trialParamKeys cover toMap output', () {
    // Guards against drift: when someone adds a field but forgets to add
    // its key to trialParamKeys, applyTrialAsParams' unknown-key warning
    // would spuriously fire.
    test('BbRsiParams.trialParamKeys equals toMap().keys', () {
      const p = BbRsiParams();
      expect(p.toMap().keys.toSet(), BbRsiParams.trialParamKeys);
    });
    test('UtBotParams.trialParamKeys equals toMap().keys', () {
      const p = UtBotParams();
      expect(p.toMap().keys.toSet(), UtBotParams.trialParamKeys);
    });
    test('IchimokuParams.trialParamKeys equals toMap().keys', () {
      const p = IchimokuParams();
      expect(p.toMap().keys.toSet(), IchimokuParams.trialParamKeys);
    });
  });
}
