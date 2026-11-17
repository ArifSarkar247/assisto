// gap-sos — feature gap lane for Emergency + SOS (owner order 17 Nov 10:10).
// Every gap fixed in owner_actions/gaps/sos_BN.md has a test here:
//   G1 (P0) Emergency SOS offline -> keeps retrying the SAME press, also
//           after the screen closes; goes out when the internet is back;
//   G2 (P0) Bangla-digit / spaced numbers -> the SMS + call steps dial the
//           real number (before: stripped to nothing);
//   G3 (P1) family SOS screen offline -> Back no longer drops the SOS;
//   G4 (P1) alarm page that cannot load -> still shows the place from the push;
//   G5 (P1) the 2 "SMS people" from Get SOS ready are used by the hub's SOS;
//   G6 (P1) emergency card edits saved offline are sent, not overwritten;
//   G7 (P1) a hand-typed number with letters / too short is refused;
//   G8 (P2) a finger that scrolls on the SOS button is not a hold.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/family_sos/sos_alarm_screen.dart';
import 'package:assisto/family_sos/sos_retry.dart';
import 'package:assisto/family_sos/sos_sender_screen.dart';
import 'package:assisto/family_sos/sos_sms.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/emergency_hub_screen.dart';
import 'package:assisto/screens/emergency_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';
import 'package:assisto/widgets/sos_button.dart';
import 'package:assisto/widgets/sos_ladder_card.dart';

import 'fcsos_fakes.dart';

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final puts = <Map<String, dynamic>>[];
  int gets = 0;
  Map<String, dynamic> server = {'contacts': []};

  @override
  Future<Map<String, dynamic>> getJson(String path) async => {};
  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};
  @override
  Future<Map<String, dynamic>> getEmergency() async {
    gets++;
    return server;
  }

  @override
  Future<void> putEmergency(Map<String, dynamic> body) async {
    puts.add(body);
  }
}

Widget _app(Widget child, {String lang = 'en', ApiClient? api, bool scroll = true}) {
  final app = AppState()
    ..api = api ?? _Api()
    ..locale = Locale(lang)
    ..user = AppUser(
        id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: scroll ? Scaffold(body: SingleChildScrollView(child: child)) : child,
    ),
  );
}

Future<void> _hold(WidgetTester tester) async {
  final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('sosat-sos-hold'))));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: EmergencySosPanel.holdMs + 100));
  await g.up();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    SosRetry.stop();
  });

  group('G2 numbers', () {
    test('cleanPhone: Bangla digits become 0-9; spaces/dashes dropped', () {
      expect(cleanPhone('০১৭১১-২০০০০২'), '01711200002');
      expect(cleanPhone('+৮৮০ ১৭১১ ২০০০০২'), '+8801711200002');
      expect(cleanPhone('01711 200002'), '01711200002');
      expect(cleanPhone('ab'), '');
    });

    testWidgets('ladder SMS + call use the clean number; a nameless contact reads "Call <number>"',
        (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(_app(SosLadderCard(
        contacts: const [
          {'name': '', 'phone': '০১৭১১ ২০০০০২'}
        ],
        offline: true,
        smsBody: 'help',
        openUri: (u) async => opened.add(u),
      )));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sosat-sms')));
      await tester.pump();
      expect(opened.last.toString(), startsWith('sms:01711200002?body='));
      expect(find.textContaining('01711200002'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('sosat-call-family')));
      await tester.pump();
      expect(opened.last.toString(), 'tel:01711200002');
    });
  });

  group('G1 Emergency SOS offline keeps trying', () {
    testWidgets('same press id, goes out when the internet is back; ladder turns online',
        (tester) async {
      var fails = 1;
      final calls = <String>[];
      await tester.pumpWidget(_app(EmergencySosPanel(
        contacts: const [
          {'name': 'Ma', 'phone': '01710000000'}
        ],
        countdownSeconds: 0,
        onNoContact: () {},
        locate: () async => (23.75, 90.39),
        ladderLoad: () async => {'stage': 'seen', 'total': 1, 'seen': 1, 'recipients': []},
        sendSos: (la, ln) async {
          calls.add('$la');
          if (fails-- > 0) throw Exception('offline');
          return {'recipients': 2};
        },
      )));
      await _hold(tester);
      expect(calls.length, 1);
      expect(SosRetry.active, isTrue);
      expect(find.byKey(const ValueKey('sos-still-trying')), findsOneWidget);
      expect(find.text('No internet — send an SMS instead'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.length, 2, reason: 'retried once the internet is back');
      expect(SosRetry.active, isFalse);
      expect(find.byKey(const ValueKey('sos-still-trying')), findsNothing);
      expect(find.text('No internet — send an SMS instead'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('closing the screen does NOT drop the unsent SOS; Stop trying does',
        (tester) async {
      var fails = 1;
      var sent = 0;
      await tester.pumpWidget(_app(EmergencySosPanel(
        contacts: const [],
        countdownSeconds: 0,
        onNoContact: () {},
        locate: () async => null,
        sendSos: (la, ln) async {
          sent++;
          if (fails-- > 0) throw Exception('offline');
          return {'recipients': 1};
        },
      )));
      await _hold(tester);
      await tester.pumpWidget(const SizedBox()); // the user leaves the screen
      expect(SosRetry.active, isTrue);
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(milliseconds: 100));
      expect(sent, 2);
      expect(SosRetry.active, isFalse);

      // Stop trying
      SosRetry.start(clientId: 'x', send: () async => throw Exception('offline'));
      SosRetry.stop();
      expect(SosRetry.trying.value, isFalse);
    });

    test('gives up after maxTries (about 30 minutes)', () {
      expect(SosRetry.maxTries * 15, greaterThanOrEqualTo(1800));
    });
  });

  group('G3 family SOS screen offline', () {
    testWidgets('Back while offline: the same press still goes out', (tester) async {
      final api = FakeFcSosApi(failSends: 1);
      await tester.pumpWidget(_app(
          SosSenderScreen(
            api: api,
            recorder: FakeSosRecorder(allowed: false),
            locate: () async => (23.7461, 90.3742),
            smsContacts: const [SosSmsContact('Ammu', '01711200002')],
            country: 'BD',
            openUri: (u) async {},
            retryEvery: const Duration(seconds: 3),
          ),
          scroll: false));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fcs-send-now')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('fcs-offline')), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // Back / screen closed
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 300));
      final sends = api.calls.where((c) => c.startsWith('send')).toList();
      expect(sends.length, 2);
      expect(sends.map((c) => c.split(':')[1]).toSet().length, 1, reason: 'same press id');
      expect(SosRetry.active, isFalse);
    });
  });

  group('G10 hub SOS -> the full SOS page', () {
    testWidgets('after a sent SOS: one tap target opens the full page', (tester) async {
      await tester.pumpWidget(_app(EmergencySosPanel(
        contacts: const [],
        countdownSeconds: 0,
        onNoContact: () {},
        locate: () async => null,
        ladderLoad: () async => {'stage': 'seen', 'total': 1, 'seen': 1, 'recipients': []},
        sendSos: (la, ln) async => {'recipients': 2},
      )));
      await _hold(tester);
      expect(find.byKey(const ValueKey('sos-open-full')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('sos-open-full'))).height,
          greaterThanOrEqualTo(48));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('startSent: opens on the sent page, sends nothing again, mistake works',
        (tester) async {
      final api = FakeFcSosApi();
      // a tall phone: the sent page is a lazy list
      tester.view.physicalSize = const Size(1080, 9000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
          SosSenderScreen(
            api: api,
            recorder: FakeSosRecorder(allowed: false),
            locate: () async => (23.7461, 90.3742),
            smsContacts: const [],
            country: 'BD',
            openUri: (u) async {},
            startSent: true,
            startRecipients: 2,
          ),
          scroll: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('fcs-sent')), findsOneWidget);
      expect(api.calls.where((c) => c.startsWith('send')), isEmpty);
      await tester.ensureVisible(find.byKey(const ValueKey('fcs-mistake')));
      await tester.tap(find.byKey(const ValueKey('fcs-mistake')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('fcs-mistake-yes')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.calls, contains('resolve:mistake'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('G12 SosButton never reads "SOS SOS"', () {
    test('a leading SOS + dash is dropped from the visible line', () {
      expect(SosButton.visibleLine('SOS — জরুরি কল'), 'জরুরি কল');
      expect(SosButton.visibleLine('SOS - Emergency call'), 'Emergency call');
      expect(SosButton.visibleLine('Emergency — alert my family'), 'Emergency — alert my family');
      expect(SosButton.visibleLine('SOS'), 'SOS');
    });

    for (final lang in ['bn', 'en']) {
      testWidgets('Safe Journey / Safety label ($lang): one SOS (the icon) + a clear line',
          (tester) async {
        await tester.pumpWidget(_app(Builder(
            builder: (c) => SosButton(
                label: AppLocalizations.of(c).sosgapSosButtonLine, onPressed: () {})),
            lang: lang));
        await tester.pump();
        final line = tester.widget<Text>(find.byKey(const ValueKey('sos-button-line'))).data!;
        expect(line.contains('SOS'), isFalse);
        expect(line, lang == 'bn' ? 'জরুরি — পরিবারকে জানান' : 'Emergency — alert my family');
        // the old label also renders without the doubled word
        await tester.pumpWidget(_app(Builder(
            builder: (c) => SosButton(
                label: AppLocalizations.of(c).emergencySosButton, onPressed: () {})),
            lang: lang));
        await tester.pump();
        expect(
            tester.widget<Text>(find.byKey(const ValueKey('sos-button-line'))).data!.contains('SOS'),
            isFalse);
      });
    }
  });

  group('G4 alarm page without internet', () {
    testWidgets('the place from the push is shown (not "no location")', (tester) async {
      final api = _FailingEventApi();
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
          SosAlarmScreen(data: fcsPush('en'), api: api, sound: FakeAlarmSound(), country: 'BD'),
          scroll: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('fcs-where')), findsOneWidget);
      // this phone is in Bangladesh: 999, never the generic 112
      expect(find.text('Call 999'), findsOneWidget);
      expect(find.byKey(const ValueKey('fcs-open-map')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('G5 hub uses the 2 SMS people', () {
    testWidgets('offline SOS: the call step names the chosen SMS person', (tester) async {
      SharedPreferences.setMockInitialValues({'safety_sos_cd': '0'});
      Settings.resetForTest();
      FeatureFlags.instance.debugOverride = null;
      tester.view.physicalSize = const Size(1080, 9000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
          EmergencyHubScreen(
            dial: (_, n) async {},
            sendSos: (la, ln) async => throw Exception('offline'),
            locate: () async => null,
            famCard: () async => const {},
            smsPeople: () async => const [SosSmsContact('Ammu', '01711200002')],
          ),
          scroll: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await _hold(tester);
      expect(find.textContaining('Ammu'), findsWidgets);
      expect(find.byKey(const ValueKey('sosat-add-numbers')), findsNothing);
      SosRetry.stop();
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('G6 + G7 emergency card', () {
    testWidgets('offline edits are sent on the next open, not overwritten', (tester) async {
      SharedPreferences.setMockInitialValues({
        'emergency_card_cache': jsonEncode({
          'name': 'A',
          'contacts': [
            {'name': 'Ma', 'phone': '01710000000', 'relation': ''}
          ]
        }),
        EmergencyScreen.dirtyKey: '1',
      });
      final api = _Api();
      await tester.pumpWidget(_app(const EmergencyScreen(), api: api, scroll: false));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(api.gets, 0, reason: 'the older server copy must not overwrite');
      expect(api.puts.single['contacts'].first['phone'], '01710000000');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(EmergencyScreen.dirtyKey), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no offline edits: the server copy loads as before', (tester) async {
      final api = _Api();
      await tester.pumpWidget(_app(const EmergencyScreen(), api: api, scroll: false));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(api.gets, 1);
      expect(api.puts, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('G8 scroll is not a hold', () {
    testWidgets('finger moves on the button -> no countdown, nothing sent', (tester) async {
      var sent = 0;
      await tester.pumpWidget(_app(EmergencySosPanel(
        contacts: const [],
        countdownSeconds: 0,
        onNoContact: () {},
        locate: () async => null,
        sendSos: (la, ln) async {
          sent++;
          return {'recipients': 1};
        },
      )));
      final g = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('sosat-sos-hold'))));
      await tester.pump();
      await g.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: EmergencySosPanel.holdMs + 300));
      await g.up();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(sent, 0);
    });
  });
}

class _FailingEventApi extends FakeFcSosApi {
  @override
  Future<Map<String, dynamic>> event(int deliveryId) async => throw Exception('offline');
}
