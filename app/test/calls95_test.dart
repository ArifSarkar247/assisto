// calls95 — call ring delivery >= 95 %:
//  * caller: "Calling" until the callee phone CONFIRMS the push (the server
//    flips the phase to ringing on the native delivered ack), then
//    "Ringing" + ringback; Bangla + English labels
//  * per-brand setup checklist: realme / OPPO / vivo / Xiaomi / Infinix /
//    Tecno get autostart + vendor battery + battery optimisation; Walton /
//    Symphony (near-stock) get battery optimisation only
//  * a never-delivered missed call brings the checklist back
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/ring_checklist.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/services/oem_guide.dart';

import 'c2_calls_fakes.dart';

Future<void> settle() => pumpEventQueue(times: 30);

class _Native implements RingCheckNative {
  _Native(this.info);
  OemInfo? info;
  @override
  Future<bool?> notificationsEnabled() async => true;
  @override
  Future<bool?> callChannelOk() async => true;
  @override
  Future<bool?> canFullScreen() async => true;
  @override
  Future<OemInfo?> oemInfo() async => info;
  @override
  Future<bool> fixNotifications() async => true;
  @override
  Future<bool> fixCallChannel() async => true;
  @override
  Future<bool> fixFullScreen() async => true;
  @override
  Future<OemOpen> openOemStep(String nativeStep) async => OemOpen.oem;
}

void main() {
  group('caller: Calling until delivered, then Ringing', () {
    test('no ringback before the phone confirmed the push', () async {
      final m = FakeCallMedia(), s = FakeSignaling(), snd = FakeSounds();
      final c = CallController(
        media: m,
        signaling: s,
        sounds: snd,
        video: false,
        outgoing: true,
        memberId: 7,
        reconnectGrace: const Duration(milliseconds: 20),
        reconnectGiveUp: const Duration(milliseconds: 400),
        statusEvery: const Duration(seconds: 30),
        statsEvery: const Duration(seconds: 30),
        setupRetryDelays: const [Duration.zero, Duration.zero],
      );
      await c.start();
      expect(c.phase, CallPhase.calling);
      // a resend round-trip still says calling: nothing changes
      s.state('calling');
      await settle();
      expect(c.phase, CallPhase.calling);
      expect(snd.log, isNot(contains('ringback')));
      // native delivered ack -> server phase "ringing"
      s.state('ringing');
      await settle();
      expect(c.phase, CallPhase.ringing);
      expect(snd.log, contains('ringback'));
      await c.hangup();
    });

    test('labels exist in both languages and differ', () {
      for (final l in const [Locale('en'), Locale('bn')]) {
        final t = lookupAppLocalizations(l);
        expect(t.c2CallCalling, isNotEmpty);
        expect(t.c2CallRinging, isNotEmpty);
        expect(t.c2CallCalling, isNot(t.c2CallRinging));
      }
    });
  });

  group('per-brand setup checklist', () {
    List<String> keysFor(String manufacturer, String brand) => ringCheckRows(
            RingFacts(
                notifications: true,
                callChannel: true,
                oem: OemInfo(
                    manufacturer: manufacturer,
                    brand: brand,
                    sdkInt: 33,
                    batteryOptIgnored: false,
                    bgRestricted: false)))
        .map((r) => r.key)
        .toList();

    const aggressive = [
      ('realme', 'realme'),
      ('OPPO', 'OPPO'),
      ('vivo', 'vivo'),
      ('Xiaomi', 'Redmi'),
      ('INFINIX MOBILITY LIMITED', 'Infinix'),
      ('TECNO MOBILE LIMITED', 'TECNO'),
    ];
    for (final (man, brand) in aggressive) {
      test('$brand: autostart + vendor battery + optimisation offered', () {
        final keys = keysFor(man, brand);
        expect(keys,
            containsAll(['oem_autostart', 'oem_oemBattery', 'oem_batteryOpt']));
        expect(isProblemOemFamily(detectOemFamily(man, brand)), isTrue);
        // every step with a settings screen has a Fix target
        expect(OemStepId.autostart.nativeStep, 'autostart');
        expect(OemStepId.oemBattery.nativeStep, 'oem_battery');
        expect(OemStepId.batteryOpt.nativeStep, 'battery_opt');
      });
    }

    for (final brand in const ['Walton', 'Symphony']) {
      test('$brand (near-stock): battery optimisation only', () {
        final keys = keysFor(brand, brand);
        expect(keys.where((k) => k.startsWith('oem_')), ['oem_batteryOpt']);
        expect(isProblemOemFamily(detectOemFamily(brand, brand)), isFalse);
      });
    }
  });

  group('missed ring brings the checklist back', () {
    setUp(() {
      RingChecklist.attention.value = false;
      RingChecklist.isAndroid = () => true;
    });

    test('realme: confirmed by-hand steps reset, snooze cleared', () async {
      SharedPreferences.setMockInitialValues({
        RingChecklist.confirmedKey: ['oem_autostart', 'oem_oemBattery',
          'oem_lockRecent', 'x_other'],
        RingChecklist.bannerHiddenUntilKey:
            DateTime.now().add(const Duration(days: 5)).millisecondsSinceEpoch,
      });
      final n = _Native(const OemInfo(
          manufacturer: 'realme', brand: 'realme', sdkInt: 33,
          batteryOptIgnored: true, bgRestricted: false));
      final need = await RingChecklist.onMissedRing(using: n);
      expect(need, isTrue);
      expect(RingChecklist.attention.value, isTrue);
      expect(await RingChecklist.confirmed(), {'x_other'});
      expect(await RingChecklist.bannerAllowed(), isTrue);
    });

    test('Walton with optimisation off: nothing to nag about', () async {
      SharedPreferences.setMockInitialValues({});
      final n = _Native(const OemInfo(
          manufacturer: 'Walton', brand: 'Walton', sdkInt: 33,
          batteryOptIgnored: true, bgRestricted: false));
      expect(await RingChecklist.onMissedRing(using: n), isFalse);
      expect(RingChecklist.attention.value, isFalse);
    });

    test('not Android: no-op', () async {
      RingChecklist.isAndroid = () => false;
      SharedPreferences.setMockInitialValues({});
      expect(await RingChecklist.onMissedRing(using: _Native(null)), isFalse);
    });
  });
}
