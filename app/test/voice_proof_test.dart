// voice-proof (18 Nov): owner gaps in voice / text actions + "Hey Assisto".
//  * "call ammu" finds the My Circle person first (free Assisto call) —
//    before, only the phonebook + SIM call existed;
//  * a spoken expense (money) shows a confirm card before anything is saved;
//  * "open CCTV" / Bangla opens Assisto's own CCTV (route watchman);
//  * a phone with NO speech service records + transcribes on the server
//    (before: a dead-end message), and the server recording stops by itself
//    after the voice ends (before: 45 s or a tap — bad after "Hey Assisto").
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/voice/va_actions.dart';
import 'package:assisto/voice/va_assisto_actions.dart';
import 'package:assisto/voice/voice_intents.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/voice_input.dart';

VaIntent p(String s) => VoiceIntentParser.parse(s, detectRoute: ChatNav.detectRoute);

void main() {
  group('open CCTV by voice / text', () {
    test('English, Banglish and Bangla open route watchman', () {
      for (final s in [
        'open cctv',
        'Hey Assisto, open CCTV',
        'show my cameras',
        'open the shop camera',
        'cctv kholo',
        'সিসিটিভি খোলো', // sisitivi kholo
        'সিসি ক্যামেরা দেখাও', // cc camera dekhao
        'দোকানের ক্যামেরা খোলো', // dokaner camera kholo
      ]) {
        final i = p(s);
        expect(i.action, VaAction.openScreen, reason: s);
        expect(i.route, 'watchman', reason: s);
      }
    });
    test('a reminder or a call that mentions CCTV stays that action', () {
      expect(p('remind me to check the cctv at 9 pm').action, VaAction.reminder);
      expect(p('call the cctv technician').action, VaAction.call);
    });
    test('chat open-phrase (offline) knows CCTV too', () {
      expect(ChatNav.detectRoute('open cctv'), 'watchman');
      expect(ChatNav.detectRoute('show my security cameras'), 'watchman');
      expect(ChatNav.routes.containsKey('watchman'), isTrue);
    });
  });

  group('the 8 actions parse from text (en + bn)', () {
    test('each lands on its fixed action', () {
      expect(p('call ammu').action, VaAction.call);
      expect(p('আম্মুকে কল দাও').action, VaAction.call);
      expect(p('my circle e ammu ke likho ami pouchechi').action, VaAction.circleMessage);
      expect(p('remind me to pay the electricity bill tomorrow at 9 am').action, VaAction.reminder);
      expect(p('কাল সকাল ৮টায় ওষুধ খাওয়ার কথা মনে করিয়ে দিও').action,
          VaAction.reminder);
      final e = p('spent 250 taka on rickshaw');
      expect(e.action, VaAction.expense);
      expect(e.amount, 250);
      expect(p('রিকশায় ২৫০ টাকা খরচ').action, VaAction.expense);
      expect(p('start safe journey to Mirpur').action, VaAction.safeJourney);
      expect(p('নিরাপদ যাত্রা শুরু করো').action, VaAction.safeJourney);
      expect(p('help me i am in danger').action, VaAction.sos);
      expect(p('আমাকে বাঁচাও').action, VaAction.sos);
      expect(p('open cctv').route, 'watchman');
      // a question is not an action -> the AI answers
      expect(p('what is the price of rice in dhaka today').action, VaAction.unknown);
    });
    test('outgoing ones are always confirmed', () {
      expect(p('call ammu').outgoing, isTrue);
      expect(p('help me i am in danger').outgoing, isTrue);
      expect(p('my circle e ammu ke likho ami pouchechi').outgoing, isTrue);
    });
  });

  group('server voice typing: end of speech (VadEndpointer)', () {
    test('room noise only: stops after 8 s and reports no speech', () {
      final v = VadEndpointer();
      var stopped = false;
      for (var k = 0; k < 79; k++) {
        stopped = v.feed(-52 + (k % 3).toDouble());
      }
      expect(stopped, isFalse);
      expect(v.feed(-51), isTrue);
      expect(v.heardSpeech, isFalse);
    });
    test('speech then 1.8 s quiet: stops, speech heard', () {
      final v = VadEndpointer();
      for (var k = 0; k < 5; k++) {
        expect(v.feed(-55), isFalse);
      }
      for (var k = 0; k < 15; k++) {
        expect(v.feed(-22), isFalse);
      }
      var n = 0;
      while (!v.feed(-54)) {
        n++;
        expect(n, lessThan(40));
      }
      expect(v.heardSpeech, isTrue);
      expect(n, inInclusiveRange(16, 19)); // ~1.8 s at 100 ms
    });
    test('a short pause between words never cuts the sentence', () {
      final v = VadEndpointer();
      for (var k = 0; k < 5; k++) {
        v.feed(-55);
      }
      for (var round = 0; round < 4; round++) {
        for (var k = 0; k < 8; k++) {
          expect(v.feed(-25), isFalse);
        }
        for (var k = 0; k < 6; k++) {
          expect(v.feed(-54), isFalse); // 0.6 s pause
        }
      }
      expect(v.ended, isFalse);
    });
    test('a silent / broken level stream (-160, NaN) never counts as speech', () {
      final v = VadEndpointer(noSpeechMs: 1000);
      for (var k = 0; k < 9; k++) {
        expect(v.feed(k.isEven ? -160 : double.nan), isFalse);
      }
      expect(v.feed(-160), isTrue);
      expect(v.heardSpeech, isFalse);
    });
  });

  group('no speech service on the phone -> server voice typing', () {
    test('rule: mic allowed, server on, not a language course', () {
      expect(VoiceDictation.useServerWhenNoEngine(micDenied: false, serverOff: false), isTrue);
      expect(VoiceDictation.useServerWhenNoEngine(micDenied: true, serverOff: false), isFalse);
      expect(VoiceDictation.useServerWhenNoEngine(micDenied: false, serverOff: true), isFalse);
      expect(
          VoiceDictation.useServerWhenNoEngine(
              micDenied: false, serverOff: false, learnLocale: 'ko-KR'),
          isFalse);
    });
  });

  group('confirm cards (money + calls)', () {
    tearDown(() => VaCircle.debugMembers = null);

    Future<VaOutcome?> Function() runIn(WidgetTester tester, VaIntent i,
        {String lang = 'en'}) {
      VaOutcome? out;
      return () async {
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(ChangeNotifierProvider<AppState>(
          create: (_) => AppState(),
          child: MaterialApp(
            locale: Locale(lang),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: AssistoTheme.light,
            home: Builder(
                builder: (c) => Scaffold(
                      body: Center(
                        child: FilledButton(
                            key: const Key('go'),
                            onPressed: () async => out = await VaExecutor(c).run(i),
                            child: const Text('go')),
                      ),
                    )),
          ),
        ));
        await tester.tap(find.byKey(const Key('go')));
        await tester.pumpAndSettle();
        return out;
      };
    }

    AppLocalizations tOf(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(Scaffold).first));

    testWidgets('call a My Circle person: free Assisto call card, Cancel calls nobody',
        (tester) async {
      VaCircle.debugMembers = [
        {'id': 7, 'name': 'Rahima Begum', 'relation': 'mother', 'state': 'accepted'},
        {'id': 8, 'name': 'Karim', 'relation': 'brother', 'state': 'pending'},
      ];
      await runIn(tester, const VaIntent(VaAction.call, 'call ammu', target: 'ammu'))();
      final t = tOf(tester);
      expect(find.text(t.vaConfirmCallTitle('Rahima Begum')), findsOneWidget);
      expect(find.text(t.vaCircleCallLabel), findsWidgets);
      expect(find.text(t.vaCallNow), findsOneWidget);
      await tester.tap(find.text(t.cancel));
      await tester.pumpAndSettle();
      expect(find.text(t.vaConfirmCallTitle('Rahima Begum')), findsNothing);
      expect(find.text('go'), findsOneWidget); // no call screen opened
    });

    testWidgets('a call to a phone number skips My Circle', (tester) async {
      VaCircle.debugMembers = [
        {'id': 7, 'name': '01711000000', 'state': 'accepted'},
      ];
      await runIn(tester,
          const VaIntent(VaAction.call, 'call 01711000000', target: '01711000000'))();
      final t = tOf(tester);
      expect(find.text(t.vaCircleCallLabel), findsNothing);
      if (find.text(t.cancel).evaluate().isNotEmpty) {
        await tester.tap(find.text(t.cancel));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('expense: confirm card first; Cancel saves nothing', (tester) async {
      await runIn(tester,
          const VaIntent(VaAction.expense, 'spent 250 taka on rickshaw',
              amount: 250, category: 'transport', message: 'rickshaw'))();
      final t = tOf(tester);
      final app = Provider.of<AppState>(tester.element(find.byType(Scaffold).first), listen: false);
      expect(find.text(t.vaConfirmExpenseTitle('৳250', t.vaCatTransport)), findsOneWidget);
      expect(find.text(t.save), findsOneWidget);
      await tester.tap(find.text(t.cancel));
      await tester.pumpAndSettle();
      expect(app.txns.items, isEmpty);
    });

    testWidgets('expense card in Bangla fits a small phone', (tester) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await runIn(tester,
          const VaIntent(VaAction.expense, 'x', amount: 1200, category: 'food'),
          lang: 'bn')();
      final t = tOf(tester);
      expect(find.textContaining(t.vaCatFood), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
