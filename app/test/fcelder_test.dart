// fcelder — Screen 4 Elder Easy Home, elder setup by a child (QR + spoken
// consent + one big Yes), the Are-you-OK screen, the family's honest Silent
// Watch view and the phone-side client (no activity ever sent to the server).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/eldercare/are_you_ok_screen.dart';
import 'package:assisto/eldercare/elder_common.dart';
import 'package:assisto/eldercare/elder_easy_home.dart';
import 'package:assisto/eldercare/elder_join_screen.dart';
import 'package:assisto/eldercare/elder_setup_screen.dart';
import 'package:assisto/eldercare/elder_watch_screen.dart';
import 'package:assisto/eldercare/silent_watch_client.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'fcelder_fakes.dart';

AppState _state(String lang) {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 2, name: 'Rahima Begum', phone: '01711000002', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(lang),
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
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );

late FakeSilentWatchApi api;
late FakeSwNative native;
late SpokenRecorder voice;
int sosOpened = 0;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({SilentWatchClient.kEnabled: true});
    api = FakeSilentWatchApi();
    native = FakeSwNative();
    voice = SpokenRecorder();
    sosOpened = 0;
    ElderHooks.apiOverride = api;
    ElderHooks.voice = voice;
    ElderHooks.openSos = (_) async => sosOpened++;
    SilentWatchClient.native = native;
    SilentWatchClient.openAreYouOk = null;
  });

  group('Screen 4 — Elder Easy Home', () {
    testWidgets('greeting with name + time; five big buttons; each SAYS its name', (tester) async {
      await tester.pumpWidget(_app(const ElderEasyHome(debugFamily: fceFamily)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Rahima'), findsOneWidget);
      expect(find.byKey(const Key('fce-time')), findsOneWidget);
      for (final k in ['fce-ok', 'fce-call-1', 'fce-call-2', 'fce-talk', 'fce-danger']) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
        expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(96), reason: k);
      }
      expect(find.text('Call son'), findsOneWidget);
      expect(find.text('Call daughter'), findsOneWidget);

      // I am OK: spoken, the phone's ringing stopped, the server told
      await tester.tap(find.byKey(const Key('fce-ok')));
      await tester.pumpAndSettle();
      expect(voice.said, contains('I am OK'));
      expect(native.okCount, 1);
      expect(api.calls, contains('ok'));

      // Call son: spoken, then a big confirm (no pocket calls)
      await tester.tap(find.byKey(const Key('fce-call-1')));
      await tester.pumpAndSettle();
      expect(voice.said, contains('Call son'));
      expect(find.text('Call Arif?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('fce-danger')));
      await tester.tap(find.byKey(const Key('fce-danger')));
      await tester.pumpAndSettle();
      expect(voice.said, contains('Danger'));
      expect(sosOpened, 1);
      expect(native.notes, greaterThan(0)); // every tap = a sign of life (on the phone)
    });

    testWidgets('Bangla, dark, 200 % font: nothing clipped, no overflow', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(const ElderEasyHome(debugFamily: fceFamily), lang: 'bn', scale: 2, dark: true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('ছেলেকে কল'), findsOneWidget);
      expect(find.text('বিপদ'), findsOneWidget);
      // the time in Bangla digits
      final time = tester.widget<Text>(find.byKey(const Key('fce-time'))).data!;
      expect(RegExp(r'[0-9]').hasMatch(time), isFalse, reason: time);
    });

    testWidgets('no family number yet -> a big "Add a family number", never a dead button', (tester) async {
      await tester.pumpWidget(_app(const ElderEasyHome(debugFamily: [])));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fce-add-family')), findsOneWidget);
      expect(find.byKey(const Key('fce-call-1')), findsNothing);
    });

    test('son / daughter picked by relation (also typed in Bangla)', () {
      const all = [
        ElderContact(5, 'Nabil', '017', 'other'),
        ElderContact(6, 'Mita', '018', 'মেয়ে'),
        ElderContact(7, 'Arif', '019', 'son'),
      ];
      final p = pickCallTargets(all);
      expect(p.first!.name, 'Arif');
      expect(p.second!.name, 'Mita');
      final q = pickCallTargets(const [ElderContact(5, 'Nabil', '017', 'other')]);
      expect(q.first!.name, 'Nabil');
      expect(q.second, isNull);
    });
  });

  group('Elder setup by a child', () {
    testWidgets('child: pick in one tap -> options -> QR + code', (tester) async {
      await tester.pumpWidget(_app(ElderSetupScreen(debugPeople: [
        {'user_id': 2, 'name': 'Ammu', 'relation': 'mother'},
        {'user_id': 4, 'name': 'Nabil', 'relation': 'other'},
      ])));
      await tester.pumpAndSettle();
      expect(find.text('Pick whose phone first'), findsOneWidget);
      await tester.tap(find.byKey(const Key('fce-who-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('6 h'));
      await tester.ensureVisible(find.text('Nabil').last);
      await tester.tap(find.text('Nabil').last);
      await tester.ensureVisible(find.byKey(const Key('fce-setup-make')));
      await tester.tap(find.byKey(const Key('fce-setup-make')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('setup:2:6:4'));
      expect(find.byKey(const Key('fce-qr')), findsOneWidget);
      expect(find.text('KQ7M2XPA'), findsOneWidget);
    });

    testWidgets('child with no family yet: benefit + big Add + how', (tester) async {
      await tester.pumpWidget(_app(const ElderSetupScreen(debugPeople: [])));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fce-setup-add')), findsOneWidget);
      expect(find.text('Add your parent to your family first'), findsOneWidget);
    });

    testWidgets('elder: spoken consent, ONE big Yes -> everything armed + battery guide', (tester) async {
      await tester.pumpWidget(_app(const ElderJoinScreen(debugPreview: {
        'child_name': 'Arif', 'hours': 4,
        'plan': {'easy_home': true, 'carecall': true, 'silent_watch': true},
      })));
      await tester.pumpAndSettle();
      expect(find.text('Arif wants to make this phone easy for you'), findsOneWidget);
      expect(find.textContaining('Only an alert goes to your family'), findsOneWidget);
      await tester.tap(find.byKey(const Key('fce-consent-listen')));
      await tester.pumpAndSettle();
      expect(voice.said.last, contains('Do you agree?'));
      expect(native.armed, isEmpty, reason: 'nothing before the Yes');
      await tester.ensureVisible(find.byKey(const Key('fce-consent-yes')));
      await tester.tap(find.byKey(const Key('fce-consent-yes')));
      await tester.pumpAndSettle();
      expect(api.calls.any((c) => c.startsWith('accept:')), isTrue);
      expect(native.armed, hasLength(1));
      expect(native.armed.single['token'], 'fake-test-token-aaaaaaaaaaaaaaaa');
      expect((native.armed.single['table'] as List).length, 48);
      expect(find.byKey(const Key('fce-join-battery')), findsOneWidget);
      expect(await SilentWatchClient.isOn(), isTrue);
    });

    test('the QR link: only lifeassisto.com /e/<8 letters>', () {
      expect(ElderJoinScreen.codeFrom('https://lifeassisto.com/e/KQ7M2XPA'), 'KQ7M2XPA');
      expect(ElderJoinScreen.codeFrom('/e/kq7m2xpa'), 'KQ7M2XPA');
      expect(ElderJoinScreen.codeFrom('https://evil.example/e/KQ7M2XPA'), isNull);
      expect(ElderJoinScreen.codeFrom('/e/SHORT'), isNull);
      expect(ElderJoinScreen.codeFrom('/pc/KQ7M2XPA'), isNull);
    });
  });

  group('Are you OK? (elder) and the family view', () {
    testWidgets('Are you OK: spoken on open; I am OK stops the phone and the alert', (tester) async {
      await tester.pumpWidget(_app(const AreYouOkScreen()));
      await tester.pump();
      await tester.pump();
      expect(voice.said.first, contains('Are you OK?'));
      await tester.tap(find.byKey(const Key('fce-ask-ok')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(native.okCount, 1);
      expect(api.calls, contains('ok'));
    });

    testWidgets('family: alert first, I am checking; no alert says "No alert", never "OK"', (tester) async {
      await tester.pumpWidget(_app(ElderWatchScreen(debugStatus: fceWatching())));
      await tester.pumpAndSettle();
      expect(find.textContaining('did not answer'), findsOneWidget);
      await tester.tap(find.byKey(const Key('fce-watch-ack-2')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('ack:9'));

      await tester.pumpWidget(_app(ElderWatchScreen(key: UniqueKey(), debugStatus: fceWatching(status: ''))));
      await tester.pumpAndSettle();
      expect(find.text('No alert'), findsOneWidget);
      expect(find.textContaining('All OK'), findsNothing);
      await tester.tap(find.byKey(const Key('fce-watch-test-2')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('test:2'));
    });
  });

  group('phone-side client', () {
    test('app open = a sign of life ON THE PHONE; a ringing ask opens Are-you-OK instead', () async {
      var opened = 0;
      SilentWatchClient.openAreYouOk = (_) async => opened++;
      await SilentWatchClient.onResume(api);
      expect(native.notes, 1);
      expect(api.calls.where((c) => c == 'ok' || c.startsWith('activity')), isEmpty);
      native.stage = 2;
      native.notes = 0;
      final ctx = _FakeContext();
      await SilentWatchClient.onResume(api, context: ctx);
      expect(opened, 1);
      expect(native.notes, 0, reason: 'the ring itself is never a sign of life');
    });

    test('not opted in: nothing happens', () async {
      SharedPreferences.setMockInitialValues({});
      await SilentWatchClient.onResume(api);
      await SilentWatchClient.noteActivity();
      expect(native.notes, 0);
      expect(native.armed, isEmpty);
    });
  });
}

class _FakeContext extends Fake implements BuildContext {
  @override
  bool get mounted => true;
}
