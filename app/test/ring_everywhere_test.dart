// ring-everywhere (owner 24 Oct: "CALLS MUST RING LIKE WHATSAPP ON EVERY
// PHONE"):
//  * the native ring (IncomingCall.kt) and Dart compute the SAME notification
//    id / ringtone channel id (Kotlin helpers mirrored here with fixed values)
//  * ONE notification per call id: Dart draws nothing while the native ring
//    (or an earlier Dart ring for a resent push) is showing
//  * the calls ring checklist: row states, attention badge, confirm flow,
//    Fix buttons, no clipped text at 360 px x 2.0, Bangla + English
//  * caller side: "calling" until the ringing ack, then "ringing"
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_sound_prefs.dart';
import 'package:assisto/calls/ring_checklist.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/push_notifier.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/ring_checklist_screen.dart';
import 'package:assisto/services/oem_guide.dart';

class _FakeNative implements RingCheckNative {
  bool? notif = true;
  bool? channel = true;
  bool? fsi = true;
  OemInfo? info = const OemInfo(
      manufacturer: 'Xiaomi', brand: 'Redmi', model: 'Note 12', sdkInt: 34,
      release: '14', batteryOptIgnored: false, bgRestricted: false);
  final fixes = <String>[];

  @override
  Future<bool?> notificationsEnabled() async => notif;
  @override
  Future<bool?> callChannelOk() async => channel;
  @override
  Future<bool?> canFullScreen() async => fsi;
  @override
  Future<OemInfo?> oemInfo() async => info;
  @override
  Future<bool> fixNotifications() async {
    fixes.add('notifications');
    notif = true;
    return true;
  }

  @override
  Future<bool> fixCallChannel() async {
    fixes.add('channel');
    return true;
  }

  @override
  Future<bool> fixFullScreen() async {
    fixes.add('fsi');
    fsi = true;
    return true;
  }

  @override
  Future<OemOpen> openOemStep(String nativeStep) async {
    fixes.add(nativeStep);
    return OemOpen.oem;
  }
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0}) => MediaQuery(
      data: MediaQueryData(
          size: const Size(360, 800), textScaler: TextScaler.linear(scale)),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    );

Future<void> _tapKey(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 150);
  await tester.ensureVisible(f);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(f);
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Kotlin mirrors (IncomingCall.kt)', () {
    test('notification id = FNV-1a 31-bit of "call-<id>"', () {
      // the SAME constants are what IncomingCall.notificationId returns
      expect(PushPayload.stableHash('call-123'), 888175380);
      expect(PushPayload.stableHash('call-990001'), 159271317);
      final p = PushPayload({'kind': 'call', 'call_id': '123'});
      expect(p.notificationId, 888175380);
      // a cancel / resend for the same call shares the id
      expect(PushPayload({'kind': 'call_cancel', 'call_id': '123'}).notificationId,
          888175380);
      expect(PushPayload({'kind': 'call', 'call_id': '123', 'attempt': '2'})
          .notificationId, 888175380);
    });

    test('ringtone channel id = IncomingCall.channelIdFor', () {
      expect(CallSoundPrefs.channelIdFor(null), 'calls');
      expect(CallSoundPrefs.channelIdFor(''), 'calls');
      expect(CallSoundPrefs.channelIdFor('content://media/external/audio/media/42'),
          'calls_uyh5');
    });
  });

  group('one notification per call id', () {
    final shows = <Map<dynamic, dynamic>>[];
    var active = <Map<String, Object?>>[];
    const fln = MethodChannel('dexterous.com/flutter/local_notifications');

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({});
      PushNotifier.ackRetryWait = Duration.zero;
      PushNotifier.debugActiveIds = null;
      shows.clear();
      active = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fln, (call) async {
        switch (call.method) {
          case 'getActiveNotifications':
            return active;
          case 'show':
            final a = call.arguments as Map;
            shows.add(a);
            active.add({'id': a['id'], 'tag': null});
            return null;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fln, null);
      debugDefaultTargetPlatformOverride = null;
    });

    PushPayload ring() => PushPayload.fromData({
          'kind': 'call', 'call_id': '123', 'caller_name': 'Karim',
          'title': 'Karim is calling', 'body': 'Voice call', 'lang': 'en',
          'channel': 'calls',
        });

    test('native ring already showing -> Dart draws nothing', () async {
      active = [
        {'id': ring().notificationId, 'tag': null}
      ];
      await PushNotifier.show(ring());
      expect(shows, isEmpty);
    });

    test('no native ring -> Dart draws it once, same id', () async {
      await PushNotifier.show(ring());
      expect(shows, hasLength(1));
      expect(shows.single['id'], ring().notificationId);
      // the resent push for the same call: still ONE notification
      await PushNotifier.show(PushPayload.fromData(
          {...ring().data, 'attempt': '1'}));
      expect(shows, hasLength(1));
    });

    test('debug override + a missed call is never suppressed', () async {
      PushNotifier.debugActiveIds = {ring().notificationId};
      expect(await PushNotifier.callRingShowing(ring().notificationId), isTrue);
      expect(await PushNotifier.callRingShowing(1), isFalse);
      await PushNotifier.show(PushPayload.fromData({
        'kind': 'missed_call', 'call_id': '123', 'group_key': 'caller-9',
        'title': 'Missed call from Karim', 'lang': 'en',
        'channel': 'missed_calls',
      }));
      expect(shows, hasLength(1));
    });
  });

  group('checklist rows (pure)', () {
    const xiaomi = OemInfo(manufacturer: 'Xiaomi', brand: 'Redmi', sdkInt: 33,
        batteryOptIgnored: true, bgRestricted: false);

    test('near-stock phone with everything allowed -> no attention', () {
      final rows = ringCheckRows(const RingFacts(
          notifications: true, callChannel: true, fullScreen: true,
          oem: OemInfo(manufacturer: 'Walton', brand: 'Walton', sdkInt: 33,
              batteryOptIgnored: true, bgRestricted: false)));
      expect(rows.map((r) => r.key),
          ['notifications', 'callChannel', 'oem_batteryOpt']);
      expect(ringNeedsAttention(rows), isFalse);
    });

    test('notifications off -> Missing, channel row hidden', () {
      final rows = ringCheckRows(const RingFacts(notifications: false, oem: xiaomi));
      expect(rows.first.state, RingCheckState.missing);
      expect(rows.any((r) => r.id == RingCheckId.callChannel), isFalse);
      expect(ringNeedsAttention(rows), isTrue);
    });

    test('Android 14 without full-screen -> Missing row', () {
      final rows = ringCheckRows(const RingFacts(
          notifications: true, callChannel: true, fullScreen: false,
          oem: OemInfo(manufacturer: 'Google', sdkInt: 34, batteryOptIgnored: true)));
      final fsi = rows.firstWhere((r) => r.id == RingCheckId.fullScreen);
      expect(fsi.state, RingCheckState.missing);
      // Android 13: no full-screen row at all
      final r13 = ringCheckRows(const RingFacts(
          notifications: true, fullScreen: true,
          oem: OemInfo(manufacturer: 'Google', sdkInt: 33, batteryOptIgnored: true)));
      expect(r13.any((r) => r.id == RingCheckId.fullScreen), isFalse);
    });

    test('Xiaomi autostart is "Check" until the user confirms it', () {
      var rows = ringCheckRows(const RingFacts(
          notifications: true, callChannel: true, oem: xiaomi));
      final auto = rows.firstWhere((r) => r.step == OemStepId.autostart);
      expect(auto.state, RingCheckState.check);
      expect(ringNeedsAttention(rows), isTrue);
      rows = ringCheckRows(const RingFacts(
          notifications: true, callChannel: true, oem: xiaomi,
          confirmed: {'oem_autostart', 'oem_oemBattery', 'oem_lockRecent'}));
      expect(ringNeedsAttention(rows), isFalse);
    });

    test('Samsung: unrestricted + sleeping apps; Infinix/Tecno: autostart', () {
      final s = ringCheckRows(const RingFacts(
          notifications: true, callChannel: true,
          oem: OemInfo(manufacturer: 'samsung', sdkInt: 34, batteryOptIgnored: false)));
      expect(s.map((r) => r.key),
          containsAll(['oem_samsungUnrestricted', 'oem_oemBattery']));
      final t = ringCheckRows(const RingFacts(
          notifications: true, callChannel: true,
          oem: OemInfo(manufacturer: 'INFINIX MOBILITY LIMITED', brand: 'Infinix',
              sdkInt: 30, batteryOptIgnored: true)));
      expect(t.map((r) => r.key), contains('oem_autostart'));
    });

    test('Android cannot tell (null) never counts as missing', () {
      final rows = ringCheckRows(const RingFacts());
      expect(ringNeedsAttention(rows), isFalse);
    });
  });

  group('checklist screen + badge', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      RingChecklist.attention.value = false;
      RingChecklist.isAndroid = () => true;
    });

    testWidgets('missing rows, Fix, confirm -> all OK (en)', (tester) async {
      final n = _FakeNative()..notif = false;
      RingChecklist.native = n;
      await tester.pumpWidget(_app(RingChecklistScreen(native: n)));
      await _settle(tester);
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.ringCheckIntro), findsOneWidget);
      expect(find.byKey(const Key('ring-state-notifications')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('ring-state-notifications'))).data,
          t.ringCheckStatusMissing);
      expect(RingChecklist.attention.value, isTrue);
      await tester.tap(find.byKey(const Key('ring-fix-notifications')));
      await _settle(tester);
      expect(n.fixes, ['notifications']);
      expect(tester.widget<Text>(find.byKey(const Key('ring-state-notifications'))).data,
          t.ringCheckStatusOk);
      // every Fix opens something (Xiaomi autostart -> the vendor screen)
      await _tapKey(tester, find.byKey(const Key('ring-fix-oem_autostart')));
      expect(n.fixes, contains('autostart'));
      // by-hand-only (lock in recents): no Fix button, only "I've done it"
      expect(find.byKey(const Key('ring-fix-oem_lockRecent'), skipOffstage: false),
          findsNothing);
      for (final k in ['oem_autostart', 'oem_oemBattery', 'oem_lockRecent']) {
        await _tapKey(tester, find.byKey(Key('ring-confirm-$k')));
      }
      // battery optimisation is checkable: still Missing until Android says so
      expect(RingChecklist.attention.value, isTrue);
      n.info = const OemInfo(manufacturer: 'Xiaomi', brand: 'Redmi', sdkInt: 34,
          batteryOptIgnored: true, bgRestricted: false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(RingChecklist.attention.value, isFalse);
      await tester.scrollUntilVisible(find.byKey(const Key('ring-check-summary')), -400);
      expect(find.text(t.ringCheckAllOk), findsOneWidget);
    });

    testWidgets('Bangla, 360 px at text scale 2.0: nothing overflows',
        (tester) async {
      final n = _FakeNative()
        ..notif = true
        ..fsi = false;
      RingChecklist.native = n;
      await tester.pumpWidget(
          _app(RingChecklistScreen(native: n, firstRun: true), lang: 'bn', scale: 2.0));
      await _settle(tester);
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      expect(find.text(bn.ringCheckTitle), findsOneWidget);
      expect(find.text(bn.ringCheckStatusMissing, skipOffstage: false),
          findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.byKey(const Key('ring-check-later')), 300);
      expect(tester.takeException(), isNull);
    });

    testWidgets('badge + My Circle banner follow attention; Later snoozes',
        (tester) async {
      final n = _FakeNative()..notif = false;
      RingChecklist.native = n;
      await tester.pumpWidget(_app(const Scaffold(
          body: Column(children: [
        RingCheckBanner(),
        RingCheckBadge(child: Icon(Icons.settings_rounded)),
      ]))));
      await _settle(tester);
      expect(find.byKey(const Key('ring-check-banner')), findsOneWidget);
      expect(find.byKey(const Key('ring-check-badge')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ring-banner-later')));
      await _settle(tester);
      expect(find.byKey(const Key('ring-check-banner')), findsNothing);
      expect(await RingChecklist.bannerAllowed(), isFalse);
      expect(await RingChecklist.bannerAllowed(
          now: DateTime.now().add(const Duration(days: 8))), isTrue);
      RingChecklist.attention.value = false;
      await tester.pump();
      expect(find.byKey(const Key('ring-check-badge')), findsNothing);
    });

    test('refresh: not Android -> never a badge', () async {
      RingChecklist.isAndroid = () => false;
      RingChecklist.native = _FakeNative()..notif = false;
      await RingChecklist.refresh();
      expect(RingChecklist.attention.value, isFalse);
    });
  });

  group('caller ring state', () {
    test('"calling" until the callee phone acks, then "ringing"', () {
      expect(phaseFromServer('calling'), CallPhase.calling);
      expect(phaseFromServer('ringing'), CallPhase.ringing);
      expect(phaseFromServer('accepted'), CallPhase.accepted);
    });
  });
}
