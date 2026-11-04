// k1-wake — pure-Dart "Hey Assisto" logic: decider (same cases as Python +
// Kotlin), sensitivity mapping, server config parsing, the native config
// JSON, the enable gate (disclosure) and the locked-phone action policy.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/voice/va_wake.dart';
import 'package:assisto/voice/va_wake_logic.dart';
import 'package:assisto/voice/voice_intents.dart';

void main() {
  group('WakeDecider (mirror of detector.py / OwwEngine.kt)', () {
    test('threshold', () {
      final d = WakeDecider(0.5);
      expect(d.feed(0.49), isFalse);
      expect(d.feed(0.5), isTrue);
    });
    test('patience: two frames in a row', () {
      final d = WakeDecider(0.5, patience: 2);
      expect(d.feed(0.9), isFalse);
      expect(d.feed(0.1), isFalse);
      expect(d.feed(0.9), isFalse);
      expect(d.feed(0.9), isTrue);
    });
    test('cooldown blocks a double trigger', () {
      final d = WakeDecider(0.5, cooldownMs: 2000);
      expect(d.feed(0.9, 0), isTrue);
      expect(d.feed(0.9, 80), isFalse);
      expect(d.feed(0.9, 1999), isFalse);
      expect(d.feed(0.9, 2000), isTrue);
    });
    test('one hour stream: 100/101 is one wake', () {
      final d = WakeDecider(0.9);
      var n = 0;
      for (var i = 0; i < 45000; i++) {
        final s = (i == 100 || i == 101 || i == 5000 || i == 30000) ? 0.95 : 0.0;
        if (d.feed(s)) n++;
      }
      expect(n, 3);
    });
  });

  group('sensitivity mapping', () {
    const th = WakeThresholds(low: 0.8, normal: 0.6, high: 0.4);
    test('levels -> threshold + patience', () {
      expect(WakeDecider.forLevel(WakeLevel.low, th).threshold, 0.8);
      expect(WakeDecider.forLevel(WakeLevel.low, th).patience, 2);
      expect(WakeDecider.forLevel(WakeLevel.normal, th).patience, 1);
      expect(WakeDecider.forLevel(WakeLevel.high, th).threshold, 0.4);
    });
    test('parse + bad values', () {
      expect(WakeLevelX.parse('high'), WakeLevel.high);
      expect(WakeLevelX.parse(null), WakeLevel.low); // wakeword default = fewest false wakes
      expect(WakeLevelX.parse('loud'), WakeLevel.low);
      final t = WakeThresholds.fromJson({'low': 0.2, 'normal': 0.6, 'high': 0.9});
      expect(t.low, 0.6); // never below normal
      expect(t.high, 0.6); // never above normal
      final d = WakeThresholds.fromJson({'normal': 'x', 'low': 5});
      expect(d.normal, 0.5);
      expect(d.low, 0.7);
    });
  });

  group('server config', () {
    Map<String, dynamic> cfg({bool available = true, List<Map>? files}) => {
          'wake': {
            'available': available,
            'reason': available ? '' : 'model_pending',
            'version': '2026.10.22',
            'window_samples': 12400,
            'frames': 16,
            'files': files ??
                [
                  {'role': 'e2e', 'name': 'assisto_embed_e2e.onnx', 'sha256': 'a' * 64, 'size': 1000},
                  {'role': 'wake', 'name': 'assisto_wake.onnx', 'sha256': 'B' * 64, 'size': 500},
                ],
            'thresholds': {'low': 0.8, 'normal': 0.6, 'high': 0.4},
          }
        };
    test('parses e2e model set', () {
      final c = VaWakeConfig.fromJson(cfg());
      expect(c.available, isTrue);
      expect(c.backend, 'e2e');
      expect(c.totalBytes, 1500);
      expect(c.files[1].sha256, 'b' * 64);
      expect(c.thresholds.normal, 0.6);
    });
    test('pending / incomplete / unsafe names are not available', () {
      expect(VaWakeConfig.fromJson(cfg(available: false)).available, isFalse);
      expect(
          VaWakeConfig.fromJson(cfg(files: [
            {'role': 'wake', 'name': 'assisto_wake.onnx', 'sha256': 'a' * 64}
          ])).available,
          isFalse);
      expect(
          VaWakeConfig.fromJson(cfg(files: [
            {'role': 'e2e', 'name': '../x.onnx', 'sha256': 'a' * 64},
            {'role': 'wake', 'name': 'w.onnx', 'sha256': 'a' * 64},
          ])).available,
          isFalse);
      expect(const VaWakeConfig().reason, 'model_pending');
    });
    test('native config JSON carries level, thresholds, hashes, texts', () {
      final c = VaWakeConfig.fromJson(cfg());
      final j = jsonDecode(VaWake.nativeConfig(
          c, {'e2e': '/d/e.onnx', 'wake': '/d/w.onnx'}, WakeLevel.low, {'title': 'T'}));
      expect(j['backend'], 'e2e');
      expect(j['level'], 'low');
      expect(j['thresholds']['low'], 0.8);
      expect(j['sha256']['wake'], 'b' * 64);
      expect(j['files']['e2e'], '/d/e.onnx');
      expect(j['texts']['title'], 'T');
      expect(j['windowSamples'], 12400);
      // wakeword: never listens on a locked phone unless the user said yes
      expect(j['lockedOk'], isFalse);
      final j2 = jsonDecode(VaWake.nativeConfig(c, {'e2e': '/d/e.onnx', 'wake': '/d/w.onnx'},
          WakeLevel.low, {'title': 'T'}, lockedOk: true));
      expect(j2['lockedOk'], isTrue);
    });
  });

  group('enable gate (disclosure first, only when it can run)', () {
    WakeBlock g({bool model = true, String reason = '', bool engine = true, bool disc = false}) =>
        VaWakeGate.check(
            modelAvailable: model,
            serverReason: reason,
            engineBundled: engine,
            disclosureAccepted: disc);
    test('no model -> coming soon, never the disclosure', () {
      expect(g(model: false), WakeBlock.modelPending);
      expect(g(model: false, reason: 'licence_pending'), WakeBlock.licencePending);
    });
    test('old app build -> engine missing', () {
      expect(g(engine: false), WakeBlock.engineMissing);
    });
    test('disclosure required before first enable', () {
      expect(g(disc: false), WakeBlock.needsDisclosure);
      expect(g(disc: true), WakeBlock.none);
    });
  });

  group('native status', () {
    test('parse', () {
      final s = WakeStatus.fromNative({
        'state': 'paused',
        'reason': 'user',
        'pausedUntil': 1800000000000,
        'wanted': true,
        'level': 'high'
      });
      expect(s.run, WakeRun.paused);
      expect(s.isOn, isTrue);
      expect(s.pausedUntil, isNotNull);
      expect(s.level, WakeLevel.high);
      expect(WakeStatus.fromNative(null).run, WakeRun.unknown);
      expect(WakeStatus.fromNative({'state': 'engine_missing'}).run, WakeRun.engineMissing);
    });
    test('blocked by Android -> needs one tap', () {
      expect(
          WakeStatus.fromNative({'state': 'error', 'reason': 'fgs_blocked', 'wanted': true})
              .needsRestart,
          isTrue);
      expect(WakeStatus.fromNative({'state': 'stopped', 'wanted': false}).needsRestart,
          isFalse);
    });
  });

  group('locked-phone policy', () {
    VaIntent i(String raw) => VoiceIntentParser.parse(raw);
    test('harmless actions run while locked', () {
      for (final a in [VaAction.torchOn, VaAction.sos, VaAction.alarm, VaAction.timer, VaAction.youtube]) {
        expect(VaLockPolicy.needsUnlock(VaIntent(a, 'x')), isFalse, reason: '$a');
      }
    });
    test('personal actions need unlock', () {
      for (final a in [
        VaAction.call, VaAction.sms, VaAction.whatsapp, VaAction.openApp,
        VaAction.openScreen, VaAction.navigate, VaAction.mapSearch,
        VaAction.reminder, VaAction.expense,
      ]) {
        expect(VaLockPolicy.needsUnlock(VaIntent(a, 'x')), isTrue, reason: '$a');
      }
    });
    test('time / weather questions are harmless, personal questions are not', () {
      expect(VaLockPolicy.isHarmlessQuery("what's the time"), isTrue);
      expect(VaLockPolicy.isHarmlessQuery('will it rain today'), isTrue);
      expect(VaLockPolicy.isHarmlessQuery('koyta baje'), isTrue);
      expect(VaLockPolicy.isHarmlessQuery('ajker abohawa kemon'), isTrue);
      expect(VaLockPolicy.isHarmlessQuery('\u0995\u09df\u099f\u09be \u09ac\u09be\u099c\u09c7'), isTrue);
      expect(VaLockPolicy.isHarmlessQuery('\u0986\u099c\u0995\u09c7 \u0986\u09ac\u09b9\u09be\u0993\u09af\u09bc\u09be \u0995\u09c7\u09ae\u09a8'), isTrue);
      expect(VaLockPolicy.isHarmlessQuery('read my messages'), isFalse);
      expect(VaLockPolicy.isHarmlessQuery('what time is my meeting'), isFalse);
      expect(VaLockPolicy.isHarmlessQuery('amar balance koto'), isFalse);
      expect(VaLockPolicy.isHarmlessQuery('tell me a joke'), isFalse);
      expect(VaLockPolicy.isHarmlessQuery(''), isFalse);
    });
    test('parsed commands follow the policy', () {
      expect(VaLockPolicy.needsUnlock(i('call ammu')), isTrue);
      expect(VaLockPolicy.needsUnlock(i('turn on the torch')), isFalse);
      expect(VaLockPolicy.needsUnlock(i('set an alarm for 7 am')), isFalse);
    });
  });
}
