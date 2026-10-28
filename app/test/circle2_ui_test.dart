// circle2 (owner checklist on every chat/call screen):
//  * the video paywall moment is honest and has NO dead buttons: who pays,
//    a free "voice call instead", the real offer sheet, the points screen;
//  * an empty call log is not a dead end (benefit + big button + how-to),
//    and a failed load has a Retry;
//  * bn / en (Bangla digits in the how-to), dark, 200% text.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/circle_call_history_screen.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/paywall_sheet.dart';

import 'c2_calls_fakes.dart';

Widget _app(Widget home,
        {String lang = 'en', bool dark = false, double scale = 1}) =>
    MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
      darkTheme: AssistoTheme.dark,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    );

Widget _gate(String lang) => CircleCallScreen(
      member: {'id': 7, 'name': lang == 'bn' ? 'নাদিয়া' : 'Nadia'},
      kind: 'video',
      outgoing: true,
      controller: previewController(
          video: true,
          outgoing: true,
          phase: CallPhase.ended,
          reason: CallEndReason.upgrade),
    );

class _EmptyCallsApi extends ApiClient {
  _EmptyCallsApi({this.fail = false}) {
    token = 't';
  }
  bool fail;
  int loads = 0;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    loads++;
    if (fail) throw ApiException('down', 503);
    return {'groups': [], 'calls': []};
  }
}

AppState _state(ApiClient api, String lang) => AppState()
  ..api = api
  ..locale = Locale(lang)
  ..user = AppUser(
      id: 1, name: 'A', phone: '01712345678', email: '',
      autonomyLevel: 2, language: lang)
  ..loading = false;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => CircleCallScreen.debugGateAction = null);

  group('video paywall moment', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('who pays + voice instead + points ($lang)', (tester) async {
        final t = lookupAppLocalizations(Locale(lang));
        final acts = <String>[];
        CircleCallScreen.debugGateAction = acts.add;
        await tester.binding.setSurfaceSize(const Size(360, 800));
        await tester.pumpWidget(_app(_gate(lang), lang: lang));
        await tester.pump();
        expect(find.text(t.circleCallVideoPremiumTitle), findsWidgets);
        final who = t.circle2VideoWhoPays(lang == 'bn' ? 'নাদিয়া' : 'Nadia');
        expect(find.text(who), findsOneWidget);
        expect(find.text(t.circle2VoiceInstead), findsOneWidget);
        await tester.tap(find.byKey(const Key('circle2-gate-voice')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('circle2-gate-points')));
        await tester.pump();
        expect(acts, ['voice', 'points'],
            reason: 'both used to just close the screen (dead buttons)');
        await tester.binding.setSurfaceSize(null);
      });
    }

    testWidgets('Get Premium opens the real offer sheet (not a silent pop)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pumpWidget(_app(_gate('en')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('circle2-gate-premium')));
      await tester.pumpAndSettle();
      expect(find.byType(PaywallSheet), findsOneWidget);
      expect(find.byType(CircleCallScreen), findsOneWidget,
          reason: 'the gate stays under the sheet');
      await tester.binding.setSurfaceSize(null);
    });

    for (final dark in [false, true]) {
      testWidgets('200% text, ${dark ? 'dark' : 'light'}, bn: no overflow',
          (tester) async {
        CircleCallScreen.debugGateAction = (_) {};
        await tester.binding.setSurfaceSize(const Size(360, 740));
        await tester.pumpWidget(
            _app(_gate('bn'), lang: 'bn', dark: dark, scale: 2));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
            find.byKey(const Key('circle2-gate-points')), 120,
            scrollable: find.byType(Scrollable).first);
        expect(find.byKey(const Key('circle2-gate-points')), findsOneWidget);
        await tester.binding.setSurfaceSize(null);
      });
    }
  });

  group('empty call log', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('benefit + big button + how-to ($lang)', (tester) async {
        final t = lookupAppLocalizations(Locale(lang));
        await tester.binding.setSurfaceSize(const Size(360, 800));
        await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
            value: _state(_EmptyCallsApi(), lang),
            child: _app(const CircleCallHistoryScreen(), lang: lang)));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('circle2-calls-empty')), findsOneWidget);
        expect(find.text(t.circle2CallsEmptyBenefit), findsOneWidget);
        expect(find.text(t.circle2CallsEmptyHow), findsOneWidget);
        final cta = tester.widget<ButtonStyleButton>(find.descendant(
            of: find.byKey(const Key('circle2-calls-empty-cta')),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
        expect(cta.onPressed, isNotNull);
        if (lang == 'bn') {
          expect(t.circle2CallsEmptyHow, contains('১.'));
          expect(t.circle2CallsEmptyHow, isNot(contains('1.')));
        }
        await tester.binding.setSurfaceSize(null);
      });
    }

    testWidgets('a failed load says so and has Retry (no dead end)',
        (tester) async {
      final api = _EmptyCallsApi(fail: true);
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: _state(api, 'en'),
          child: _app(const CircleCallHistoryScreen())));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('circle2-calls-retry')), findsOneWidget);
      api.fail = false;
      await tester.tap(find.byKey(const Key('circle2-calls-retry')));
      await tester.pumpAndSettle();
      expect(api.loads, 2);
      expect(find.byKey(const Key('circle2-calls-empty-cta')), findsOneWidget);
    });

    testWidgets('200% text dark bn: no overflow', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 740));
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: _state(_EmptyCallsApi(), 'bn'),
          child: _app(const CircleCallHistoryScreen(),
              lang: 'bn', dark: true, scale: 2)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    });
  });
}
