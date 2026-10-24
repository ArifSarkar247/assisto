// at-heartbeat (owner 24 Oct): after a Play update the always-on engine was
// dead and opening the app did not bring it back. These tests prove:
//   * the restart rules (mirror of RestartPolicy.kt) per trigger / Android
//     level — Android 14+ background restart only with background location;
//   * the app-open path calls the native 'resume' (start with the stored
//     token) and NEVER asks for a SIM rebaseline;
//   * the one-time battery-optimisation guide.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/services/antitheft_logic.dart';
import 'package:assisto/services/antitheft_resume.dart';
import 'package:assisto/services/antitheft_service.dart';
import 'package:assisto/services/oem_guide.dart';

import 'tl1_fakes.dart';

const _channel = MethodChannel('com.assisto/antitheft');

const _texts = {
  'title': 'T',
  'body': 'B',
  'off': 'O',
  'resumeTitle': 'RT',
  'resumeBody': 'RB',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RestartRules (mirror of RestartPolicy.kt)', () {
    test('app open always restarts', () {
      for (final sdk in [26, 29, 31, 33, 34, 35, 36]) {
        expect(RestartRules.canStart(RestartRules.app, sdk, false), isTrue);
      }
    });

    test('update / boot restart on Android 8-13', () {
      for (final t in [RestartRules.update, RestartRules.boot]) {
        for (final sdk in [26, 28, 30, 31, 33]) {
          expect(RestartRules.canStart(t, sdk, false), isTrue, reason: '$t $sdk');
          expect(RestartRules.needsTapToResume(t, sdk, false), isFalse);
        }
      }
    });

    test('Android 14+ background restart needs background location', () {
      for (final t in [RestartRules.update, RestartRules.boot]) {
        for (final sdk in [34, 35, 36]) {
          expect(RestartRules.canStart(t, sdk, false), isFalse);
          expect(RestartRules.needsTapToResume(t, sdk, false), isTrue);
          expect(RestartRules.canStart(t, sdk, true), isTrue);
          expect(RestartRules.needsTapToResume(t, sdk, true), isFalse);
        }
      }
    });

    test('unknown trigger never starts; camera only from the open app', () {
      expect(RestartRules.canStart('quickboot', 30, true), isFalse);
      expect(RestartRules.allowCamera(RestartRules.app), isTrue);
      expect(RestartRules.allowCamera(RestartRules.boot), isFalse);
      expect(RestartRules.allowCamera(RestartRules.update), isFalse);
    });

    test('a restart compares to the SIM baseline, never re-records it', () {
      final m = SimEngineModel()..armRebaseline();
      m.debounceFired(['s1:47001']); // owner's SIM at switch-on: silent
      expect(m.alerts, isEmpty);
      // update / reboot / app open -> a fresh service start
      m.serviceStart();
      m.debounceFired(['s1:47001']);
      expect(m.alerts, isEmpty);
      expect(m.base, isNotNull);
      // a foreign SIM after the restart still alerts
      m.serviceStart();
      m.debounceFired(['s9:47002']);
      expect(m.alerts, ['inserted']);
    });
  });

  group('app open -> native resume', () {
    late List<MethodCall> calls;
    bool nativeResult = true;

    setUp(() {
      calls = [];
      nativeResult = true;
      AntiTheftResume.resetForTest();
      AntiTheftResume.throttle = const Duration(seconds: 20);
      AntiTheftResume.resumeNative = (n) => AntiTheftService.resume(notif: n);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.method == 'resume') return nativeResult;
        return null;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    test('calls resume (start with stored token), never a rebaseline', () async {
      final on = await AntiTheftResume.onAppOpen(_texts);
      expect(on, isTrue);
      expect(calls.map((c) => c.method), ['resume']);
      final args = Map<String, dynamic>.from(calls.single.arguments as Map);
      expect(args.containsKey('rebaseline'), isFalse);
      expect(args['notifTitle'], 'T');
      expect(args['resumeTitle'], 'RT');
      expect(args['resumeBody'], 'RB');
      // never the switch-on start
      expect(calls.where((c) => c.method == 'start'), isEmpty);
    });

    test('protection off -> false, nothing else called', () async {
      nativeResult = false;
      expect(await AntiTheftResume.onAppOpen(_texts), isFalse);
      expect(calls.map((c) => c.method), ['resume']);
    });

    test('throttled across a quick resume burst, then again later', () async {
      await AntiTheftResume.onAppOpen(_texts);
      await AntiTheftResume.onAppOpen(_texts);
      expect(calls.where((c) => c.method == 'resume'), hasLength(1));
      AntiTheftResume.throttle = Duration.zero;
      await AntiTheftResume.onAppOpen(_texts);
      expect(calls.where((c) => c.method == 'resume'), hasLength(2));
    });

    test('a missing native side never throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'boom');
      });
      expect(await AntiTheftService.resume(notif: _texts), isFalse);
      expect(await AntiTheftResume.onAppOpen(_texts), isFalse);
    });

    test('switch-on start carries the resume texts and rebaseline: true',
        () async {
      await AntiTheftService.start(
          engineToken: 'tok',
          apiBase: 'https://x/api',
          config: const {},
          notif: _texts,
          rebaseline: true);
      final s = calls.singleWhere((c) => c.method == 'start');
      final a = Map<String, dynamic>.from(s.arguments as Map);
      expect(a['rebaseline'], isTrue);
      expect(a['resumeTitle'], 'RT');
    });
  });

  group('one-time battery guide', () {
    Future<NavigatorState> pumpNav(WidgetTester tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
          navigatorKey: key, home: const Scaffold(body: Text('root'))));
      return key.currentState!;
    }

    testWidgets('shown once when Android says Assisto is battery-optimised',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      AntiTheftResume.native = FakeOemNative(tl1Phone('realme', ignored: false));
      final nav = await pumpNav(tester);
      final shown = await tester.runAsync(() =>
          AntiTheftResume.maybeShowBatteryGuide(nav, () => const Text('GUIDE')));
      await tester.pumpAndSettle();
      expect(shown, isTrue);
      expect(find.text('GUIDE'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AntiTheftResume.guidePrefKey), isTrue);
      expect(prefs.getBool(OemGuideGate.prefKey), isTrue);
      final again = await tester.runAsync(() =>
          AntiTheftResume.maybeShowBatteryGuide(nav, () => const Text('GUIDE')));
      expect(again, isFalse);
    });

    testWidgets('not shown when optimisation is already off or unknown',
        (tester) async {
      for (final ignored in [true, null]) {
        SharedPreferences.setMockInitialValues({});
        AntiTheftResume.native =
            FakeOemNative(tl1Phone('samsung', ignored: ignored));
        final nav = await pumpNav(tester);
        final shown = await tester.runAsync(() => AntiTheftResume
            .maybeShowBatteryGuide(nav, () => const Text('GUIDE')));
        expect(shown, isFalse, reason: 'ignored=$ignored');
      }
      SharedPreferences.setMockInitialValues({});
      AntiTheftResume.native = FakeOemNative(null);
      final nav = await pumpNav(tester);
      expect(
          await tester.runAsync(() => AntiTheftResume.maybeShowBatteryGuide(
              nav, () => const Text('GUIDE'))),
          isFalse);
    });

    testWidgets('never covers another screen', (tester) async {
      SharedPreferences.setMockInitialValues({});
      AntiTheftResume.native = FakeOemNative(tl1Phone('oppo', ignored: false));
      final nav = await pumpNav(tester);
      final shown = await tester.runAsync(() => AntiTheftResume
          .maybeShowBatteryGuide(nav, () => const Text('GUIDE'),
              stillOk: () => false));
      expect(shown, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AntiTheftResume.guidePrefKey), isNull,
          reason: 'not consumed: shown on a later open');
    });
  });
}
