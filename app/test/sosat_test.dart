// sosat — Family SOS + anti-theft sweep, on the phone (no plugins):
//   * SOS is never blocked by a missing emergency number (old dead end);
//   * hold-to-send (a plain tap only explains; TalkBack double-tap sends);
//   * the escalation ladder: waiting -> rerung -> call 999 / seen / offline
//     SMS step, bn digits, never auto-dials;
//   * countdown digits in Bangla;
//   * "More ways to send SOS": honest "turn protection on first", settings
//     pushed to the native engine in the ACTIVE language only, the fall row
//     hidden while its flag is off;
//   * fall detection: consent before switching on; the "Are you OK?" screen
//     (practice sends nothing; real "I'm OK" names the held fall);
//   * dark mode + 200% text without overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/fall_detect_screen.dart';
import 'package:assisto/screens/sos_triggers_screen.dart';
import 'package:assisto/services/sos_trigger_settings.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';
import 'package:assisto/widgets/safety_sos_countdown.dart';
import 'package:assisto/widgets/sos_ladder_card.dart';

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  @override
  Future<Map<String, dynamic>> getJson(String path) async => {};
  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};
}

Widget _app(Widget child,
    {String lang = 'en',
    bool dark = false,
    double scale = 1.0,
    bool a11y = false}) {
  final app = AppState()
    ..api = _Api()
    ..locale = Locale(lang)
    ..user = AppUser(
        id: 1, name: 'A', phone: '01712345678', email: '',
        autonomyLevel: 2, language: lang)
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
          data: MediaQuery.of(c).copyWith(
              textScaler: TextScaler.linear(scale), accessibleNavigation: a11y),
          child: w!),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

Map<String, dynamic> _ladder(String stage, {int seen = 0}) => {
      'stage': stage,
      'total': 2,
      'seen': seen,
      'recipients': [
        {'name': 'Ma', 'status': 'sent', 'received': true, 'seen': seen > 0},
        {'name': 'Bhai', 'status': 'no_device', 'received': false, 'seen': false},
      ],
    };

Future<void> _hold(WidgetTester tester) async {
  final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('sosat-sos-hold'))));
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
    SosTriggerSettings.push = (m) async => true;
  });

  group('Emergency SOS panel', () {
    testWidgets('no emergency number saved: SOS still goes to My Circle (no dead end)',
        (tester) async {
      var sent = 0;
      await tester.pumpWidget(_app(EmergencySosPanel(
        contacts: const [],
        countdownSeconds: 0,
        onNoContact: () {},
        locate: () async => (23.75, 90.39),
        sendSos: (la, ln) async {
          sent++;
          expect(la, 23.75);
          return {'recipients': 2};
        },
        ladderLoad: () async => _ladder('waiting'),
      )));
      await _hold(tester);
      expect(sent, 1);
      expect(find.byKey(const ValueKey('sosat-ladder')), findsOneWidget);
      expect(find.text('SOS sent to 2 — waiting for someone to open it'), findsOneWidget);
      // the steps are offered, nothing is dialled by itself
      expect(find.byKey(const ValueKey('sosat-999')), findsOneWidget);
      expect(find.byKey(const ValueKey('sosat-add-numbers')), findsOneWidget);
    });

    testWidgets('a plain tap only explains "hold"; nothing is sent', (tester) async {
      var sent = 0;
      await tester.pumpWidget(_app(EmergencySosPanel(
        contacts: const [],
        countdownSeconds: 0,
        onNoContact: () {},
        sendSos: (la, ln) async {
          sent++;
          return {'recipients': 1};
        },
      )));
      await tester.tap(find.byKey(const ValueKey('sosat-sos-hold')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(sent, 0);
      expect(find.text('Hold the button for 1 second to send SOS'), findsOneWidget);
    });

    testWidgets('TalkBack: a double-tap is the whole gesture', (tester) async {
      final h = tester.ensureSemantics();
      var sent = 0;
      await tester.pumpWidget(_app(
        EmergencySosPanel(
          contacts: const [],
          countdownSeconds: 0,
          onNoContact: () {},
          locate: () async => null,
          sendSos: (la, ln) async {
            sent++;
            return {'recipients': 1};
          },
          ladderLoad: () async => _ladder('waiting'),
        ),
        a11y: true,
      ));
      expect(find.bySemanticsLabel('Emergency SOS'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('sosat-sos-hold')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(sent, 1);
      h.dispose();
    });

    testWidgets('offline: the SMS-from-my-SIM step leads', (tester) async {
      await tester.pumpWidget(_app(EmergencySosPanel(
        contacts: const [
          {'name': 'Ma', 'phone': '01710000000'}
        ],
        countdownSeconds: 0,
        onNoContact: () {},
        locate: () async => null,
        sendSos: (la, ln) async => throw Exception('offline'),
      )));
      await _hold(tester);
      expect(find.text('No internet — send an SMS instead'), findsOneWidget);
      final sms = tester.widget<FilledButton>(find.descendant(
          of: find.byKey(const ValueKey('sosat-sms')), matching: find.byType(FilledButton)).first);
      expect(sms.onPressed, isNotNull);
    });
  });

  group('escalation ladder card', () {
    for (final (stage, text) in [
      ('rerung', 'Rung again — call them now'),
      ('call_999', 'No answer yet — call 999'),
      ('no_one', 'Nobody could be alerted in the app'),
      ('resolved', 'You are marked safe'),
    ]) {
      testWidgets('stage $stage', (tester) async {
        await tester.pumpWidget(_app(SosLadderCard(
          contacts: const [
            {'name': 'Ma', 'phone': '01710000000'}
          ],
          load: () async => _ladder(stage),
        )));
        await tester.pump();
        await tester.pump();
        expect(find.text(text), findsOneWidget);
        if (stage == 'resolved') {
          expect(find.byKey(const ValueKey('sosat-999')), findsNothing);
        }
      });
    }

    testWidgets('Bangla: digits and words in bn only', (tester) async {
      await tester.pumpWidget(_app(
          SosLadderCard(load: () async => _ladder('seen', seen: 1)),
          lang: 'bn'));
      await tester.pump();
      await tester.pump();
      expect(find.text('২ জনের মধ্যে ১ জন আপনার SOS দেখেছেন'), findsOneWidget);
    });
  });

  testWidgets('countdown shows Bangla digits under bn', (tester) async {
    await tester.pumpWidget(_app(Builder(
        builder: (c) => TextButton(
            onPressed: () => SafetySosCountdown.show(c, 5), child: const Text('go'))),
        lang: 'bn'));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();
    expect(find.text('৫'), findsOneWidget);
    expect(find.text('5'), findsNothing);
    await tester.tap(find.byType(FilledButton).last); // cancel
    await tester.pump(const Duration(milliseconds: 300));
  });

  group('More ways to send SOS', () {
    testWidgets('protection off: one big "turn it on" button, switches disabled, fall hidden',
        (tester) async {
      await tester.pumpWidget(_app(SizedBox(
          height: 900,
          child: SosTriggersScreen(isRunning: () async => false, fallFlagOn: false))));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('sosat-turn-on-protection')), findsOneWidget);
      final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('sosat-lock')));
      expect(sw.onChanged, isNull);
      expect(find.byKey(const ValueKey('sosat-fall')), findsNothing);
    });

    testWidgets('protection on: switching lock-screen SOS pushes bn texts only',
        (tester) async {
      Map<String, Object>? pushed;
      SosTriggerSettings.push = (m) async {
        pushed = m;
        return true;
      };
      await tester.pumpWidget(_app(
          SizedBox(
              height: 900,
              child: SosTriggersScreen(isRunning: () async => true, fallFlagOn: true)),
          lang: 'bn'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('sosat-fall')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sosat-lock')));
      await tester.pump();
      await tester.pump();
      expect(pushed!['lock_on'], true);
      expect(pushed!['power_on'], false);
      expect(pushed!['sosArmTitle'], '১০ সেকেন্ডে SOS যাবে');
      expect(pushed!['fallOk'], 'আমি ঠিক আছি');
    });
  });

  group('fall detection', () {
    testWidgets('switching on asks consent first, then pushes fall_on', (tester) async {
      Map<String, Object>? pushed;
      SosTriggerSettings.push = (m) async {
        pushed = m;
        return true;
      };
      await tester.pumpWidget(_app(SizedBox(
          height: 1200,
          child: FallDetectScreen(
              isRunning: () async => true, pending: () async => {'pending': null}))));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('sosat-experimental')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sosat-fall-switch')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Turn on fall detection?'), findsOneWidget);
      expect(pushed, isNull); // nothing before consent
      await tester.tap(find.text('Turn on'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(pushed!['fall_on'], true);
      expect(pushed!['fall_window_s'], 60);
    });

    testWidgets('protection off: honest button, switch disabled', (tester) async {
      await tester.pumpWidget(_app(SizedBox(
          height: 1200,
          child: FallDetectScreen(
              isRunning: () async => false, pending: () async => {'pending': null}))));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('sosat-fall-protection')), findsOneWidget);
      final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('sosat-fall-switch')));
      expect(sw.onChanged, isNull);
    });

    testWidgets('practice sends nothing', (tester) async {
      var calls = 0;
      await tester.pumpWidget(_app(SizedBox(
          height: 1200,
          child: FallCheckScreen(
              practiceSeconds: 60, imOk: (_) async => calls++))));
      await tester.pump();
      expect(find.byKey(const ValueKey('sosat-practice-banner')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sosat-im-ok')));
      await tester.pump();
      expect(calls, 0);
    });

    testWidgets('real "I\'m OK" names the held fall; bn clock digits', (tester) async {
      String? got;
      await tester.pumpWidget(_app(
          SizedBox(
              height: 1200,
              child: FallCheckScreen(
                  clientId: 'fall-abc', seconds: 75, imOk: (c) async => got = c)),
          lang: 'bn'));
      await tester.pump();
      expect(find.textContaining('১:১৫'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sosat-im-ok')));
      await tester.pump();
      expect(got, 'fall-abc');
    });
  });

  group('dark mode + 200% text', () {
    for (final lang in ['bn', 'en']) {
      testWidgets('ladder + triggers render without overflow ($lang)', (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 1600));
        await tester.pumpWidget(_app(
            SosLadderCard(
                contacts: const [
                  {'name': 'Ma', 'phone': '01710000000'}
                ],
                load: () async => _ladder('call_999')),
            lang: lang,
            dark: true,
            scale: 2.0));
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(_app(
            SizedBox(
                height: 1600,
                child: SosTriggersScreen(isRunning: () async => false, fallFlagOn: true)),
            lang: lang,
            dark: true,
            scale: 2.0));
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.binding.setSurfaceSize(null);
      });
    }
  });
}
