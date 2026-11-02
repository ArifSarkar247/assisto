// playall — 8 Nov ALL-features Play launch: Google Play "prominent
// disclosure" + declared-but-unused guards.
//
//  1. Every runtime permission ask in lib/ is preceded (same file, a few
//     lines above) by an in-app disclosure, or is on the short, reasoned
//     allow-list below (SOS moments never get an extra screen; in-context
//     screens that ARE the disclosure).
//  2. The disclosures say what Play's policy text requires (bn + en):
//     "location" + "even when the app is closed or not in use" for the
//     features that keep location with the app closed.
//  3. askLocationWithReason: the reason comes first; "Not now" never
//     prompts Android.
//  4. The Play bundle never ships the unused wake-word microphone service,
//     nor background location / SMS / call-log / accessibility & co.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/voice/va_wake.dart';
import 'package:assisto/widgets/at_disclosure.dart';
import 'package:assisto/widgets/permission_reason.dart';

/// A runtime-permission request (Android shows its own prompt).
final _ask = RegExp(r'Geolocator\.requestPermission\(|'
    r'Permission\.(location|locationWhenInUse|locationAlways|microphone|camera|contacts|phone|bluetoothConnect|sms)\.request\(\)|'
    r'\]\.request\(\)|requestAuthorization\(|_source\.request\(\)|src\.request\(\)|\bp\.request\(\)|'
    // playaudit2: implicit asks — WebRTC getUserMedia and the camera plugin
    // prompt Android for mic/camera on their own; camera_screen's gate.
    r'getUserMedia\(|CameraController\(|_perms\.request\(\)');

/// In-app disclosures that may come right before an ask.
const _markers = [
  'showPermissionReason(',
  'askLocationWithReason(',
  'AtDisclosure.show(',
  'C1Disclosure(',
  'VaConfirmSheet.reason(',
  'IntruderConsentScreen.ask(',
  'mc2PermLocBody', // share-location sheet's own disclosure dialog
  'md1PermContinue', // chat media/mic disclosure dialog
  'arBtPermAllow', // audio route: Bluetooth disclosure sheet
];
const _lookBack = 45; // lines

/// file -> why an ask there has no disclosure right above it.
const _allowed = <String, String>{
  'lib/widgets/permission_reason.dart': 'the helper itself',
  'lib/widgets/emergency_sos_panel.dart':
      'SOS moment: never an extra screen during an emergency; the SOS button says location is sent',
  'lib/widgets/voice_sos_service.dart':
      'SOS moment (spoken phrase); Voice SOS asked mic+location with permVoiceSos when armed',
  'lib/p3/assisto_sheet.dart':
      'SOS moment, right after the user confirmed "Send SOS"',
  'lib/screens/journey_sos_screen.dart': 'SOS moment inside a Safe Journey',
  'lib/screens/smartwatch_screen.dart':
      'the Connect Health Connect card (swConnectBody) is the disclosure; HC shows its own rationale',
  'lib/screens/vehicle_obd_screen.dart':
      'Bluetooth (nearby devices) after the user tapped Read dongle; not a disclosure category',
  'lib/screens/camera/camera_permission_gate.dart':
      'the camera explain state is shown before request()',
  'lib/screens/voice_assistant_settings_screen.dart':
      'wake word: hidden (VaWake.shipped=false) + its own confirm dialog first',
  'lib/voice/va_actions.dart':
      'contacts: VaConfirmSheet.reason; phone: after the user confirmed Call now',
  'lib/train/dest_voice_recorder.dart':
      'destination alarm voice clip: dest_alarm_screen._record shows showPermissionReason(PermKind.mic) first',
  'lib/services/device_contacts_source.dart':
      'the contacts source; callers show C1Disclosure first (checked below)',
  'lib/screens/messenger/contacts_screen.dart':
      '_allow() runs only from the C1 disclosure stage (CmStage.disclosure)',
  // playaudit2 — implicit mic/camera prompts, each in context:
  'lib/calls/webrtc_media.dart':
      'calls: only after the user started/answered a call (Android prompt in context); '
          'child emergency audio opens it only after its visible notice (kid_audio_child.dart)',
  'lib/screens/shop_live_rtc.dart':
      'Shop Box live view: the box phone sits on the open Shop Box screen the owner set up',
  'lib/screens/shop_box_mode_screen.dart':
      'Shop Box mode: the camera opens only after the user pressed Start on that screen',
  'lib/screens/camera/camera_screen.dart':
      'camera: the CameraPermissionGate explain state comes first; the controller starts only when granted',
};

List<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

Widget _app(Locale locale, Future<void> Function(BuildContext) onTap) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
                key: const Key('go'),
                onPressed: () => onTap(ctx),
                child: const Text('go')),
          ),
        ),
      ),
    );

void main() {
  group('source guard: a disclosure before every permission ask', () {
    test('no unexplained runtime permission request in lib/', () {
      final bad = <String>[];
      final usedAllow = <String>{};
      for (final f in _dartFiles('lib')) {
        final path = f.path.replaceAll('\\', '/');
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (l.trimLeft().startsWith('//')) continue;
          if (!_ask.hasMatch(l)) continue;
          final from = (i - _lookBack).clamp(0, i);
          final ctx = lines.sublist(from, i + 1).join('\n');
          if (_markers.any(ctx.contains)) continue;
          if (_allowed.containsKey(path)) {
            usedAllow.add(path);
            continue;
          }
          bad.add('$path:${i + 1}: ${l.trim()}');
        }
      }
      expect(bad, isEmpty,
          reason: 'show showPermissionReason / askLocationWithReason (or the '
              "feature's own disclosure) before Android's prompt");
      // no stale allow-list rows (a file that no longer asks must leave)
      final stale = _allowed.keys
          .where((k) => k != 'lib/widgets/permission_reason.dart')
          .where((k) => !usedAllow.contains(k) && File(k).existsSync())
          .where((k) => !_ask.hasMatch(File(k).readAsStringSync()));
      expect(stale, isEmpty);
    });

    test('contacts are read only after the C1 disclosure', () {
      final share = File('lib/messaging/share/share_flow.dart').readAsStringSync();
      expect(share.indexOf('C1Disclosure('),
          lessThan(share.indexOf('st = await src.request()')));
      final screen =
          File('lib/screens/messenger/contacts_screen.dart').readAsStringSync();
      expect(screen, contains('CmStage.disclosure'));
    });

    test('security actions and account deletion never PROMPT for location', () {
      for (final p in [
        'lib/services/security_guard.dart',
        'lib/screens/delete_account_screen.dart',
      ]) {
        final s = File(p).readAsStringSync();
        expect(s.contains('Geolocator.requestPermission('), isFalse, reason: p);
      }
    });

    test('Safe Journey start and Voice SOS use their own disclosures', () {
      final j = File('lib/screens/journey_start_screen.dart').readAsStringSync();
      expect(j, contains('PermKind.journey'));
      final v = File('lib/screens/voice_sos_screen.dart').readAsStringSync();
      expect(v, contains('PermKind.voiceSos'));
      // location is asked while arming, so a real SOS never waits on a prompt
      expect(v.indexOf('PermKind.voiceSos'),
          lessThan(v.indexOf('Geolocator.requestPermission(')));
      final at = File('lib/widgets/at_disclosure.dart').readAsStringSync();
      expect(at, contains('at100DiscLocBody2'));
    });
  });

  group('disclosure wording (Play location policy)', () {
    for (final loc in const [Locale('en'), Locale('bn')]) {
      testWidgets('${loc.languageCode}: background-style features say so',
          (tester) async {
        final t = await AppLocalizations.delegate.load(loc);
        final closed = loc.languageCode == 'en'
            ? 'even when the app is closed or not in use'
            : 'অ্যাপ বন্ধ থাকলেও বা ব্যবহার না করলেও';
        final word = loc.languageCode == 'en' ? 'location' : 'লোকেশন';
        for (final s in [t.permJourneyLoc, t.permVoiceSos, t.at100DiscLocBody2]) {
          expect(s, contains(closed));
          expect(s, contains(word));
          expect(s, contains(loc.languageCode == 'en' ? 'for ads' : 'বিজ্ঞাপনে'));
        }
        // the one-off reason is honest: only while using the app
        expect(t.permLocation2, contains(word));
        expect(t.permLocation2.contains(closed), isFalse);
        if (loc.languageCode == 'bn') {
          // strict bn: Bangla digits only
          for (final s in [t.permJourneyLoc, t.at100DiscLocBody2]) {
            expect(RegExp(r'[0-9]').hasMatch(s), isFalse, reason: s);
          }
        }
      });
    }

    testWidgets('journey disclosure dialog: 48dp buttons, 200% text, bn',
        (tester) async {
      tester.view.physicalSize = const Size(400 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(_app(const Locale('bn'),
          (c) => showPermissionReason(c, PermKind.journey)));
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('perm-reason-journey')), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final k in ['perm-reason-yes', 'perm-reason-no']) {
        final sz = tester.getSize(find.byKey(Key(k)));
        expect(sz.height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('anti-theft location disclosure shows the new text (en)',
        (tester) async {
      await tester.pumpWidget(_app(const Locale('en'),
          (c) => AtDisclosure.show(c, AtDisclosureKind.location)));
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();
      expect(find.textContaining('even when the app is closed or not in use'),
          findsOneWidget);
    });
  });

  group('askLocationWithReason', () {
    testWidgets('reason first; Not now never prompts Android', (tester) async {
      var asked = 0;
      LocationPermission? got;
      await tester.pumpWidget(_app(const Locale('en'), (c) async {
        got = await askLocationWithReason(c,
            check: () async => LocationPermission.denied,
            request: () async {
              asked++;
              return LocationPermission.whileInUse;
            });
      }));
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('perm-reason-location')), findsOneWidget);
      await tester.tap(find.byKey(const Key('perm-reason-no')));
      await tester.pumpAndSettle();
      expect(asked, 0);
      expect(got, LocationPermission.denied);

      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('perm-reason-yes')));
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(got, LocationPermission.whileInUse);
    });

    testWidgets('already granted / blocked: no dialog, no prompt',
        (tester) async {
      for (final state in [
        LocationPermission.whileInUse,
        LocationPermission.deniedForever,
      ]) {
        var asked = 0;
        await tester.pumpWidget(_app(const Locale('bn'), (c) async {
          await askLocationWithReason(c,
              check: () async => state,
              request: () async {
                asked++;
                return state;
              });
        }));
        await tester.tap(find.byKey(const Key('go')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(asked, 0);
      }
    });
  });

  group('foreground services: Dart starts only declared types', () {
    test('every ForegroundServiceTypes.* used in lib/ is microphone or location', () {
      final used = <String>{};
      final starters = <String>{};
      for (final f in _dartFiles('lib')) {
        final src = f.readAsStringSync();
        for (final m in RegExp(r'ForegroundServiceTypes\.([a-zA-Z]+)').allMatches(src)) {
          used.add(m.group(1)!);
          starters.add(f.path.replaceAll('\\', '/'));
        }
      }
      expect(used.difference({'microphone', 'location'}), isEmpty,
          reason: 'a new FGS type needs the manifest, a Play Console declaration '
              '(owner_actions/PLAY_FGS_DECLARATION_BN.md) and a video first');
      // each starter is described in the Play FGS declaration
      expect(starters, containsAll(<String>[
        'lib/widgets/voice_sos_service.dart',
        'lib/calls/call_keepalive.dart',
        'lib/services/journey_tracker.dart',
        'lib/train/train_fgs.dart',
      ]));
      expect(starters.difference({
        'lib/widgets/voice_sos_service.dart',
        'lib/calls/call_keepalive.dart',
        'lib/services/journey_tracker.dart',
        'lib/train/train_fgs.dart',
      }), isEmpty, reason: 'new FGS starter: add it to PLAY_FGS_DECLARATION_BN.md + this list');
    });

    test('child emergency audio: visible notice before the call', () {
      final k = File('lib/calls/kid_audio_child.dart').readAsStringSync();
      expect(k, contains('kauNoticeTitle'));
      final notice = k.indexOf('await showNotice(texts(name)');
      expect(notice, greaterThan(0));
      expect(notice, lessThan(k.indexOf("'notice_shown': true")));
      expect(k.indexOf("'notice_shown': true"), lessThan(k.indexOf('await openCall(')));
    });
  });

  group('Play manifest: declared == used', () {
    final ci = File('../.github/workflows/android.yml').readAsStringSync();
    final play = ci.substring(ci.indexOf('Build + sign release AAB (Google Play)'));

    test('the unused wake-word mic service is removed from the Play bundle', () {
      // the wake word is not shipped in any build...
      expect(VaWake.shipped, isFalse);
      expect(ci.contains('ASSISTO_WAKE_WORD=true'), isFalse);
      // ...so the Play step strips WakeWordService and the gate checks it
      expect(play, contains('Play manifest: WakeWordService removed'));
      expect(play, contains('for C in voice.WakeWordService GeolocatorLocationService'));
    });

    test('the Play gate forbids every undeclared sensitive permission', () {
      for (final p in [
        'ACCESS_BACKGROUND_LOCATION',
        'QUERY_ALL_PACKAGES',
        'SEND_SMS',
        'READ_SMS',
        'READ_CALL_LOG',
        'READ_PHONE_STATE',
        'SYSTEM_ALERT_WINDOW',
        'BIND_ACCESSIBILITY_SERVICE',
        'FOREGROUND_SERVICE_CAMERA',
        'USE_EXACT_ALARM',
        'MANAGE_EXTERNAL_STORAGE',
      ]) {
        expect(play, contains(p), reason: p);
      }
    });

    test('the generated manifest never requests them either', () {
      final requested = RegExp(
              r'uses-permission android:name="android\.permission\.([A-Za-z_.]+)"(?![^>]*tools:node="remove")')
          .allMatches(ci)
          .map((m) => m.group(1)!)
          .toSet();
      for (final p in [
        'ACCESS_BACKGROUND_LOCATION',
        'QUERY_ALL_PACKAGES',
        'SEND_SMS',
        'READ_SMS',
        'READ_CALL_LOG',
        'READ_PHONE_STATE',
        'SYSTEM_ALERT_WINDOW',
        'FOREGROUND_SERVICE_CAMERA',
        'USE_EXACT_ALARM',
      ]) {
        expect(requested.contains(p), isFalse, reason: p);
      }
      // playaudit2: every foreground-service type in the generated manifest
      // is one we declare in Play Console (mic + location), and every
      // FOREGROUND_SERVICE_* permission matches one of them.
      final types = RegExp(r'foregroundServiceType="([a-zA-Z|]+)"')
          .allMatches(ci)
          .expand((m) => m.group(1)!.split('|'))
          .toSet();
      expect(types, {'microphone', 'location'});
      final fgsPerms = requested.where((p) => p.startsWith('FOREGROUND_SERVICE_')).toSet();
      expect(fgsPerms, {'FOREGROUND_SERVICE_MICROPHONE', 'FOREGROUND_SERVICE_LOCATION'});
      // the foreground-service types we DO declare (Play FGS form): mic + location
      expect(requested, containsAll(<String>[
        'FOREGROUND_SERVICE_MICROPHONE',
        'FOREGROUND_SERVICE_LOCATION',
      ]));
    });
  });
}
