// fcsos — Family Care v3 SCREEN 2 (SOS sender) + SCREEN 3 (SOS receiver):
//   * countdown 5 -> 0 in Bangla digits; Cancel sends NOTHING; Send now sends
//     at once; the countdown end sends by itself (one press id);
//   * sent: N people ringing, who is going, the 30 s sound only after the SOS
//     (auto only when the mic is already allowed; else a clear button), Stop
//     uploads; "Sent by mistake" asks, then tells everyone (reason mistake);
//   * no internet: SMS from MY SIM to the 2 chosen people (sms: URI with both
//     numbers + the map link), keeps retrying with the SAME press id;
//   * receiver: who / when / live place / sound / who is going / nearest
//     police + hospital / blood group; I am going; Call; the country's
//     emergency number; "sent by mistake" turns the page green; the alarm
//     stops on any action; push payload -> alarm route parsing;
//   * dark + 200 % text + Bangla: no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/family_sos/sos_alarm_screen.dart';
import 'package:assisto/family_sos/sos_sender_screen.dart';
import 'package:assisto/family_sos/sos_setup_card.dart';
import 'package:assisto/family_sos/sos_sms.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/sos_ladder_card.dart';

import 'fcsos_fakes.dart';

Widget _app(Widget child, {String lang = 'en', bool dark = false, double scale = 1.0}) {
  final app = AppState()
    ..api = ApiClient()
    ..locale = Locale(lang)
    ..user = AppUser(
        id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    ),
  );
}

List<SosSmsContact> _sms() =>
    const [SosSmsContact('Ammu', '01711200002'), SosSmsContact('Bhai', '01711200003')];

SosSenderScreen _sender(FakeFcSosApi api,
        {FakeSosRecorder? rec, List<Uri>? opened, List<SosSmsContact>? sms}) =>
    SosSenderScreen(
      api: api,
      recorder: rec ?? FakeSosRecorder(),
      locate: () async => (23.7461, 90.3742),
      smsContacts: sms ?? _sms(),
      country: 'BD',
      openUri: (u) async => opened?.add(u),
      retryEvery: const Duration(seconds: 3),
    );

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SOS sender', () {
    testWidgets('countdown shows Bangla digits; Cancel sends nothing', (tester) async {
      final api = FakeFcSosApi(lang: 'bn');
      await tester.pumpWidget(_app(_sender(api), lang: 'bn'));
      await tester.pump();
      expect(find.text('৫'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('৪'), findsOneWidget);
      expect(find.text('এখনই পাঠান'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fcs-cancel')));
      await tester.pump(const Duration(seconds: 6));
      expect(api.calls.where((c) => c.startsWith('send')), isEmpty);
      await _dispose(tester);
    });

    testWidgets('Send now sends at once; sent page; mic allowed -> recording shown, Stop uploads',
        (tester) async {
      final api = FakeFcSosApi()
        ..goingList = [
          {'name': 'Bhai', 'at': '2026-11-09T04:41:00Z', 'me': false}
        ];
      final rec = FakeSosRecorder(allowed: true);
      await tester.pumpWidget(_app(_sender(api, rec: rec)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fcs-send-now')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.calls.where((c) => c.startsWith('send')).length, 1);
      expect(api.calls.first, contains(':23.7461'));
      expect(find.byKey(const ValueKey('fcs-sent')), findsOneWidget);
      expect(find.text("Your family's phones are ringing (3 people)"), findsOneWidget);
      expect(find.byKey(const ValueKey('fcs-recording')), findsOneWidget);
      expect(rec.calls, contains('start'));
      expect(find.textContaining('Bhai is on the way'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fcs-rec-stop')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.calls.any((c) => c.startsWith('audio:')), isTrue);
      expect(find.byKey(const ValueKey('fcs-sound-sent')), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('mic not allowed -> no recording until the user taps the button', (tester) async {
      final api = FakeFcSosApi();
      final rec = FakeSosRecorder(allowed: false);
      await tester.pumpWidget(_app(_sender(api, rec: rec)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fcs-send-now')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(rec.calls, isNot(contains('start')));
      expect(find.byKey(const ValueKey('fcs-rec-start')), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('the countdown end sends by itself', (tester) async {
      final api = FakeFcSosApi();
      await tester.pumpWidget(_app(_sender(api)));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pump(const Duration(milliseconds: 200));
      expect(api.calls.where((c) => c.startsWith('send')).length, 1);
      expect(find.byKey(const ValueKey('fcs-sent')), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('sent by mistake: asks, then tells everyone (reason mistake)', (tester) async {
      final api = FakeFcSosApi();
      await tester.pumpWidget(_app(_sender(api)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fcs-send-now')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('fcs-mistake')), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const ValueKey('fcs-mistake')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Tell everyone it was a mistake?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fcs-mistake-yes')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.calls, contains('resolve:mistake'));
      await _dispose(tester);
    });

    testWidgets('no internet: SMS to the 2 people with the map link; retry with the same id',
        (tester) async {
      final api = FakeFcSosApi(failSends: 1);
      final opened = <Uri>[];
      await tester.pumpWidget(_app(_sender(api, opened: opened)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fcs-send-now')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('fcs-offline')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fcs-sms-send')));
      await tester.pump();
      expect(opened.single.scheme, 'smsto');
      expect(opened.single.toString(), startsWith('smsto:01711200002;01711200003?body='));
      expect(Uri.decodeComponent(opened.single.query), contains('maps.google.com/?q=23.746100,90.374200'));
      // one by one (an SMS app that takes a single number)
      await tester.tap(find.byKey(const ValueKey('fcs-sms-one-01711200003')));
      await tester.pump();
      expect(opened.last.toString(), startsWith('smsto:01711200003?body='));
      // the internet is back: the SAME press goes out
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 300));
      final ids = api.calls.where((c) => c.startsWith('send')).map((c) => c.split(':')[1]).toSet();
      expect(ids.length, 1);
      expect(find.byKey(const ValueKey('fcs-sent')), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('no SMS people chosen -> a clear "choose 2" button (no dead end)', (tester) async {
      final api = FakeFcSosApi(failSends: 99);
      await tester.pumpWidget(_app(_sender(api, sms: const [])));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fcs-send-now')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('fcs-sms-pick')), findsOneWidget);
      expect(find.text('Call 999'), findsOneWidget);
      await _dispose(tester);
    });

    test('sms uri + body', () {
      final u = sosSmsUri(['+880 1711-200002', '01711200003', 'x'], 'Help me');
      expect(u.toString(), startsWith('smsto:+8801711200002;01711200003?body='));
      expect(sosSmsBody((l) => 'at $l', 'no gps', null), 'no gps');
      expect(cleanPhone('12'), '');
    });
  });

  group('SOS receiver', () {
    testWidgets('who / when / where / sound / going / nearby / info + I am going', (tester) async {
      final api = FakeFcSosApi();
      final sound = FakeAlarmSound();
      final opened = <Uri>[];
      await tester.pumpWidget(_app(SosAlarmScreen(
          data: fcsPush('en'), api: api, sound: sound, openUri: (u) async => opened.add(u))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(sound.calls, contains('start'));
      expect(api.calls, containsAll(['seen:41', 'event:41']));
      expect(find.text('Rina needs help'), findsOneWidget);
      expect(find.text('I am going'), findsOneWidget);
      expect(find.text('Call 999'), findsOneWidget);
      expect(find.text('Call Rina'), findsOneWidget);
      expect(find.textContaining('Live · updated 12 s ago'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('fcs-info')), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Dhanmondi Police Station'), findsOneWidget);
      expect(find.text('Labaid Hospital'), findsOneWidget);
      expect(find.text('Blood group: B+'), findsOneWidget);
      expect(find.textContaining('Bhai is on the way'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('fcs-going-btn')), -300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const ValueKey('fcs-going-btn')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.calls, contains('going:41'));
      expect(sound.calls, contains('stop'));
      expect(find.text('You said you are going'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('fcs-call-emergency')));
      await tester.pump();
      expect(opened.last.toString(), 'tel:999');
      await _dispose(tester);
    });

    testWidgets('sent by mistake -> green, no I am going, alarm stops', (tester) async {
      final api = FakeFcSosApi(ev: fcsEvent('bn', state: 'mistake', info: false));
      final sound = FakeAlarmSound();
      await tester.pumpWidget(_app(SosAlarmScreen(data: fcsPush('bn'), api: api, sound: sound), lang: 'bn'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('রিনা ভুল করে SOS চেপেছিলেন'), findsOneWidget);
      expect(find.byKey(const ValueKey('fcs-going-btn')), findsNothing);
      expect(sound.calls, contains('stop'));
      await _dispose(tester);
    });

    test('push payload -> alarm route', () {
      expect(SosAlarmScreen.wants(fcsPush('en')), isTrue);
      expect(SosAlarmScreen.wants({...fcsPush('en'), 'alert_kind': 'sos_resolved'}), isFalse);
      expect(SosAlarmScreen.wants({'kind': 'family_alert', 'delivery_id': '3'}), isFalse);
      final r = SosAlarmScreen.onGenerateRoute(RouteSettings(
          name: '/sos_alarm?p=${Uri.encodeComponent('{"kind":"sos","delivery_id":"9","alert_kind":"fall"}')}'));
      expect(r, isNotNull);
      expect(SosAlarmScreen.onGenerateRoute(const RouteSettings(name: '/other')), isNull);
    });
  });

  group('ladder card (qjourney reality 42576041400)', () {
    testWidgets('no phone could be rung (noOne) -> "I\'m safe now" still ends the SOS',
        (tester) async {
      var resolved = 0;
      await tester.pumpWidget(_app(Scaffold(
          body: SingleChildScrollView(
              child: SosLadderCard(
        load: () async => {
          'stage': 'no_one',
          'total': 1,
          'seen': 0,
          'recipients': [
            {'name': 'B', 'status': 'no_device', 'received': false, 'seen': false}
          ],
        },
        resolve: () async {
          resolved++;
          return {'ok': true};
        },
      )))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final safe = find.byKey(const ValueKey('sosat-safe'));
      expect(safe, findsOneWidget);
      await tester.ensureVisible(safe);
      await tester.tap(safe);
      await tester.pump(const Duration(milliseconds: 100));
      expect(resolved, 1);
      await _dispose(tester);
    });

    testWidgets('offline (never reached the server) -> no "I\'m safe now"', (tester) async {
      await tester.pumpWidget(_app(const Scaffold(
          body: SingleChildScrollView(child: SosLadderCard(offline: true)))));
      await tester.pump();
      expect(find.byKey(const ValueKey('sosat-safe')), findsNothing);
      await _dispose(tester);
    });
  });

  group('setup card', () {
    testWidgets('honest states + share switch', (tester) async {
      final api = FakeFcSosApi();
      await tester.pumpWidget(_app(Scaffold(
          body: ListView(children: [
        SosSetupCard(
            api: api,
            sms: const [],
            dndGranted: () async => false,
            dndEnsure: (a, b) async => false,
            dndOpen: () async => true,
            fullScreen: () async => false,
            fixFullScreen: () async => true),
      ]))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Not chosen yet — choose 2 people.'), findsOneWidget);
      expect(find.byKey(const ValueKey('fcs-setup-dnd-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('fcs-setup-full-btn')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fcs-setup-share')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.calls, contains('share:true'));
      await _dispose(tester);
    });
  });

  group('a11y', () {
    for (final lang in ['bn', 'en']) {
      testWidgets('dark + 200% text, $lang: sender phases + alarm do not overflow', (tester) async {
        tester.view.physicalSize = const Size(1080, 2340);
        tester.view.devicePixelRatio = 2.75;
        addTearDown(tester.view.reset);
        for (final ph in SosPhase.values) {
          await tester.pumpWidget(_app(
              SosSenderScreen(
                  key: ValueKey(ph),
                  api: FakeFcSosApi(lang: lang),
                  recorder: FakeSosRecorder(),
                  country: 'BD',
                  smsContacts: _sms(),
                  debugPhase: ph,
                  debugRecipients: 3,
                  debugRecState: 'recording'),
              lang: lang,
              dark: true,
              scale: 2.0));
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.takeException(), isNull, reason: '$ph');
        }
        await tester.pumpWidget(_app(
            SosAlarmScreen(
                data: fcsPush(lang),
                api: FakeFcSosApi(lang: lang),
                sound: FakeAlarmSound(),
                autoAlarm: false),
            lang: lang,
            dark: true,
            scale: 2.0));
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        await _dispose(tester);
      });
    }
  });
}
