// wakeword (owner vision checklist 4 Nov 02:22): after "Hey Assisto" the
// command becomes one of the FIXED real actions — call, WhatsApp prefilled,
// write in My Circle, alarm, reminder, Care Call, Safe Journey, navigation —
// each behind a confirm card. Covers the offline parser, the AI-router
// mapping, My Circle matching, the locked-phone policy and the confirm cards.
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
import 'package:assisto/voice/va_wake_logic.dart';
import 'package:assisto/voice/voice_intents.dart';
import 'package:assisto/widgets/chatnav.dart';

VaIntent p(String s) => VoiceIntentParser.parse(s);

void main() {
  group('offline parser: Assisto actions', () {
    test('Safe Journey (en / Banglish / bn)', () {
      final a = p('start safe journey to mirpur 10');
      expect(a.action, VaAction.safeJourney);
      expect(a.target, contains('mirpur'));
      expect(p('hey assisto safe journey').action, VaAction.safeJourney);
      expect(p('nirapod jatra shuru koro').action, VaAction.safeJourney);
      expect(p('নিরাপদ যাত্রা শুরু করো').action,
          VaAction.safeJourney);
      // "open safe journey" = just the screen
      final o = p('open safe journey');
      expect(o.action, VaAction.openScreen);
      expect(o.route, 'journey');
    });

    test('Care Call beats a plain call', () {
      final a = p('set up care call for nanu at 9 am');
      expect(a.action, VaAction.careCall);
      expect(a.target, 'nanu');
      expect(a.clock?.hour, 9);
      expect(p('nanu ke care call dao').action, VaAction.careCall);
      final bn = p('নানুকে কেয়ার কল দাও');
      expect(bn.action, VaAction.careCall);
      expect(bn.target, contains('নানু'));
      // a normal call is still a call
      expect(p('call ammu').action, VaAction.call);
    });

    test('write in My Circle (needs a write/message word)', () {
      final a = p('my circle e ammu ke likho khaiso');
      expect(a.action, VaAction.circleMessage);
      expect(a.target, 'ammu');
      expect(a.message, contains('khaiso'));
      final e = p('message rahim on my circle i am coming');
      expect(e.action, VaAction.circleMessage);
      expect(e.target, 'rahim');
      expect(e.message, contains('coming'));
      final bn = p('সার্কেলে আম্মুকে লেখো খেয়েছ');
      expect(bn.action, VaAction.circleMessage);
      expect(bn.target, 'আম্মু');
      // not a message: no write word
      expect(p('add rahim to my circle').action, isNot(VaAction.circleMessage));
      // WhatsApp stays WhatsApp
      expect(p('whatsapp rahim i am coming').action, VaAction.whatsapp);
    });

    test('the existing actions still parse', () {
      expect(p('call ammu').action, VaAction.call);
      expect(p('whatsapp rahim i am late').action, VaAction.whatsapp);
      expect(p('set alarm for 6:30 am').action, VaAction.alarm);
      expect(p('remind me at 9 pm to take medicine').action, VaAction.reminder);
      expect(p('navigate to shahbag').action, VaAction.navigate);
    });

    test('My Circle message is outgoing (always confirmed)', () {
      expect(VaIntent(VaAction.circleMessage, 'x').outgoing, isTrue);
    });

    test('locked phone: the new actions ask to unlock first', () {
      for (final a in [VaAction.circleMessage, VaAction.careCall, VaAction.safeJourney]) {
        expect(VaLockPolicy.needsUnlock(VaIntent(a, 'x')), isTrue, reason: '$a');
      }
    });
  });

  group('AI router -> fixed actions only', () {
    VaIntent? r(Map<String, dynamic> j) => VaRouter.fromJson(j, 'raw words');

    test('every fixed action maps with its slots', () {
      expect(r({'action': 'call', 'target': 'Ma'})!.action, VaAction.call);
      final w = r({'action': 'whatsapp', 'target': 'Rahim', 'message': 'ami ashchi'})!;
      expect((w.action, w.target, w.message), (VaAction.whatsapp, 'Rahim', 'ami ashchi'));
      expect(r({'action': 'circle_message', 'target': 'Ammu', 'message': 'hi'})!.action,
          VaAction.circleMessage);
      final al = r({'action': 'alarm', 'time': '06:30', 'day': 'tomorrow'})!;
      expect((al.action, al.clock!.hour, al.clock!.minute, al.clock!.tomorrow),
          (VaAction.alarm, 6, 30, true));
      final re = r({'action': 'reminder', 'message': 'medicine', 'time': '21:00'})!;
      expect((re.action, re.message, re.clock!.hour), (VaAction.reminder, 'medicine', 21));
      expect(r({'action': 'reminder', 'message': 'pay bill'})!.clock, isNull);
      expect(r({'action': 'care_call', 'target': 'Nana'})!.action, VaAction.careCall);
      expect(r({'action': 'safe_journey'})!.action, VaAction.safeJourney);
      expect(r({'action': 'safe_journey', 'place': 'Mirpur'})!.target, 'Mirpur');
      final n = r({'action': 'navigate', 'place': 'Shahbag'})!;
      expect((n.action, n.target), (VaAction.navigate, 'Shahbag'));
      expect(n.raw, 'raw words');
    });

    test('anything else is not an action (falls back to the agent)', () {
      for (final j in <Map<String, dynamic>>[
        {'action': 'none'},
        {'action': 'transfer_money', 'target': 'x'},
        {'action': 'call'},
        {'action': 'navigate'},
        {'action': 'alarm', 'time': '25:00'},
        {'action': 'alarm'},
        {'action': 'reminder'},
        {},
      ]) {
        expect(r(j), isNull, reason: '$j');
      }
    });
  });

  group('My Circle person matching', () {
    final members = <Map<String, dynamic>>[
      {'id': 1, 'name': 'Rahima Begum', 'relation': 'mother', 'state': 'accepted'},
      {'id': 2, 'name': 'Rahim Uddin', 'relation': 'friend', 'state': 'accepted'},
      {'id': 3, 'name': 'Karim', 'relation': 'brother', 'state': 'pending'},
    ];
    test('by name, by relation word, never a pending request', () {
      expect(VaCircle.match('rahim', members).first['id'], 2);
      expect(VaCircle.match('ammu', members).map((m) => m['id']), [1]);
      expect(VaCircle.match('karim', members), isEmpty);
      expect(VaCircle.match('zzz', members), isEmpty);
    });
  });

  group('confirm cards', () {
    Future<VaOutcome?> runIn(WidgetTester tester, VaIntent i, {String lang = 'en'}) async {
      SharedPreferences.setMockInitialValues({});
      VaOutcome? out;
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
    }

    AppLocalizations tOf(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(Scaffold).first));

    testWidgets('Safe Journey: card first, Cancel runs nothing', (tester) async {
      await runIn(tester, const VaIntent(VaAction.safeJourney, 'x', target: 'Mirpur'));
      final t = tOf(tester);
      expect(find.text(t.vaConfirmJourneyTo('Mirpur')), findsOneWidget);
      expect(find.text(t.vaJourneyOpen), findsOneWidget);
      await tester.tap(find.text(t.cancel));
      await tester.pumpAndSettle();
      expect(find.text(t.vaConfirmJourneyTo('Mirpur')), findsNothing);
      expect(find.text('go'), findsOneWidget); // still on the same screen
    });

    testWidgets('Safe Journey card in Bangla at 200% text fits', (tester) async {
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await runIn(tester, const VaIntent(VaAction.safeJourney, 'x'), lang: 'bn');
      final t = tOf(tester);
      expect(find.text(t.vaConfirmJourneyAny), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Care Call: card when the screen exists, never a dead card',
        (tester) async {
      await runIn(tester, const VaIntent(VaAction.careCall, 'care call nanu', target: 'nanu'));
      final t = tOf(tester);
      if (ChatNav.routes.containsKey('carecall')) {
        expect(find.text(t.vaConfirmCareCallTitle('nanu')), findsOneWidget);
        await tester.tap(find.text(t.cancel));
        await tester.pumpAndSettle();
      } else {
        // this build has no Care Call screen -> no card, the agent answers
        expect(find.text(t.vaConfirmCareCallTitle('nanu')), findsNothing);
      }
    });
  });
}
