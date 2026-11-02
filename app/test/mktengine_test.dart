// mktengine: Marketing Engine v1 — the app side of the owner's journey with a
// fake server: welcome → questionnaire (single / text / multi, draft saved
// per step) → plan built → approve / reject / copy → follow-up turned on via
// retention → honest publish note; flag-off / error / no-retention states;
// bn + en, dark and 200 % text with no overflow on every gallery state.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/mktengine/mkt_engine_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'mktengine_fakes.dart';
import 'mktengine_shots.dart';

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        key: UniqueKey(),
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

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

late AppLocalizations en;
late AppLocalizations bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });

  testWidgets('welcome -> questionnaire saves each step -> plan built', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final f = FakeMkt('empty', false);
    await tester.pumpWidget(_app(MktEngineScreen(source: f)));
    await _settle(tester);
    expect(find.text(en.mktWelcomeTitle), findsOneWidget);
    expect(find.text(en.mktHonestLine), findsOneWidget);
    await tester.tap(find.text(en.mktStart));
    await _settle(tester);
    // step 1: single choice required
    await tester.tap(find.text(en.mktNext));
    await _settle(tester);
    expect(find.text(en.mktAnswerFirst), findsOneWidget);
    await tester.tap(find.text('Grocery / daily needs'));
    await tester.tap(find.text(en.mktNext));
    await _settle(tester);
    expect(f.calls, contains('save_partial'));
    // step 2: text
    await tester.enterText(find.byType(TextField), 'Mirpur, Dhaka');
    await tester.tap(find.text(en.mktNext));
    await _settle(tester);
    // step 3: multi
    await tester.tap(find.text('Facebook Page'));
    await tester.tap(find.text(en.mktNext));
    await _settle(tester);
    // step 4: optional text -> build
    expect(find.text(en.mktOptional), findsOneWidget);
    await tester.tap(find.text(en.mktBuildPlan));
    await _settle(tester, 20);
    expect(f.calls, containsAllInOrder(['save', 'generate']));
  });

  testWidgets('plan: real numbers shown, approve / reject, follow-up on, honest publish', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final f = FakeMkt('data', false);
    await tester.pumpWidget(_app(MktEngineScreen(source: f)));
    await _settle(tester);
    expect(find.textContaining('৳350'), findsWidgets);
    expect(find.text(en.mktPublishPending), findsOneWidget);   // approved post, Meta not approved
    expect(find.text(en.mktPublishFb), findsNothing);           // never a dead "post" button
    await tester.tap(find.text(en.mktFactsTitle));
    await _settle(tester);
    expect(find.text('Miniket rice 5 kg × 12'), findsOneWidget);
    // approve the calendar
    await tester.tap(find.text(en.mktApprove).first);
    await _settle(tester);
    expect(f.calls, contains('edit:calendar:approved'));
    // conversion: one follow-up on already, one ready to turn on
    await tester.tap(find.text(en.mktSecConversion));
    await _settle(tester);
    expect(find.text(en.mktFollowOn), findsOneWidget);
    await tester.ensureVisible(find.text(en.mktFollowActivate));
    await tester.tap(find.text(en.mktFollowActivate));
    await _settle(tester);
    expect(f.calls, contains('activate:fu_thanks_review'));
    expect(find.text(en.mktActivated), findsOneWidget);
  });

  testWidgets('no retention switch -> honest note, no activate button', (tester) async {
    await tester.pumpWidget(_app(MktEngineScreen(source: FakeMkt('noretention', false), initialSection: 'conversion')));
    await _settle(tester);
    expect(find.text(en.mktFollowNeedsRetention), findsOneWidget);
    expect(find.text(en.mktFollowActivate), findsNothing);
  });

  testWidgets('flag off and load error are honest', (tester) async {
    await tester.pumpWidget(_app(MktEngineScreen(source: FakeMkt('off', false))));
    await _settle(tester);
    expect(find.text(en.mktOffTitle), findsOneWidget);
    await tester.pumpWidget(_app(MktEngineScreen(source: FakeMkt('fail', false))));
    await _settle(tester);
    expect(find.text(en.mktLoadErrorTitle), findsOneWidget);
    expect(find.text(en.mktRetry), findsOneWidget);
  });

  testWidgets('Bangla: Bangla labels and digits', (tester) async {
    await tester.pumpWidget(_app(MktEngineScreen(source: FakeMkt('data', true)), lang: 'bn'));
    await _settle(tester);
    expect(find.text(bn.mktTitle), findsOneWidget);
    expect(find.text(bn.mktApprovedCount('৩', '৬')), findsOneWidget);
  });

  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('every state, $lang, dark=$dark, 200% text: no overflow', (tester) async {
        tester.view.physicalSize = const Size(1080, 2340); // 360 dp wide
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        for (final e in mktengineShots.entries) {
          await tester.pumpWidget(_app(e.value(lang), lang: lang, scale: 2.0, dark: dark));
          await _settle(tester);
          expect(tester.takeException(), isNull, reason: e.key);
        }
      });
    }
  }
}
